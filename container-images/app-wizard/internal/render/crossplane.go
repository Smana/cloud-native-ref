package render

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"sigs.k8s.io/yaml"
)

// CrossplaneRenderer shells out to `crossplane render` against the repo's
// composition files. It writes the claim to a temp file and parses the emitted
// YAML stream into kind/name pairs (best-effort role from kind).
type CrossplaneRenderer struct {
	// Binary is the crossplane CLI path (default "crossplane").
	Binary string
	// EngineBinary is passed as --crossplane-binary.
	//
	// Crossplane v2's render runs TWO things in Docker by default: the composition
	// functions AND the render engine itself. DevTargets below only addresses the
	// former. In a distroless pod there is no Docker daemon, so the engine half fails
	// with `cannot create Docker network for rendering`, no matter how the functions
	// are annotated. Pointing the engine at the local CLI is what makes rendering
	// possible without a Docker socket.
	//
	// Empty when the binary cannot be resolved, in which case the flag is omitted
	// rather than passed empty.
	EngineBinary string
	// CompositionPath / FunctionsPath / EnvConfigPath are absolute paths to the
	// composition, functions, and environmentconfig files.
	CompositionPath string
	FunctionsPath   string
	EnvConfigPath   string
	// DevTargets maps a Function name to a running gRPC endpoint (host:port). When
	// non-empty, Render overlays the "Development" runtime onto the functions file
	// so `crossplane render` connects to those endpoints (the in-pod function
	// sidecars) instead of pulling+running function images via Docker.
	DevTargets map[string]string
}

// NewCrossplaneRenderer builds a renderer. repoRoot anchors the relative
// composition paths.
func NewCrossplaneRenderer(repoRoot, compositionPath, functionsPath, envConfigPath string, devTargets map[string]string) *CrossplaneRenderer {
	abs := func(p string) string {
		if filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(repoRoot, p)
	}
	const binary = "crossplane"
	// Resolve once, here, rather than per render: if the CLI is missing we want that
	// visible in one place, and an unresolved path must not become `--crossplane-binary=`.
	enginePath, err := exec.LookPath(binary)
	if err != nil {
		enginePath = ""
	}
	return &CrossplaneRenderer{
		Binary:          binary,
		EngineBinary:    enginePath,
		CompositionPath: abs(compositionPath),
		FunctionsPath:   abs(functionsPath),
		EnvConfigPath:   abs(envConfigPath),
		DevTargets:      devTargets,
	}
}

// renderArgs builds the `crossplane render` argv.
func (r *CrossplaneRenderer) renderArgs(claimPath, functionsPath string) []string {
	args := []string{"render", claimPath, r.CompositionPath, functionsPath}
	if r.EnvConfigPath != "" {
		args = append(args, "--extra-resources", r.EnvConfigPath)
	}
	if r.EngineBinary != "" {
		args = append(args, "--crossplane-binary="+r.EngineBinary)
	}
	return args
}

// DevFunctionsYAML overlays the "Development" runtime onto a functions.yaml
// stream: for each Function whose metadata.name is in targets, it adds
//
//	annotations:
//	  render.crossplane.io/runtime: Development
//	  render.crossplane.io/runtime-development-target: <host:port>
//
// spec.package is preserved (drift-free — packages come from the repo file), but
// `crossplane render` ignores it in Development mode and dials the endpoint.
func DevFunctionsYAML(functionsFile []byte, targets map[string]string) ([]byte, error) {
	docs := splitYAMLDocs(functionsFile)
	var out [][]byte
	for _, doc := range docs {
		trimmed := bytes.TrimSpace(doc)
		if len(trimmed) == 0 {
			continue
		}
		var fn map[string]any
		if err := yaml.Unmarshal(trimmed, &fn); err != nil {
			return nil, fmt.Errorf("parse function doc: %w", err)
		}
		meta, _ := fn["metadata"].(map[string]any)
		if meta != nil {
			name, _ := meta["name"].(string)
			if target, ok := targets[name]; ok {
				ann, _ := meta["annotations"].(map[string]any)
				if ann == nil {
					ann = map[string]any{}
				}
				ann["render.crossplane.io/runtime"] = "Development"
				ann["render.crossplane.io/runtime-development-target"] = target
				meta["annotations"] = ann
				fn["metadata"] = meta
			}
		}
		b, err := yaml.Marshal(fn)
		if err != nil {
			return nil, fmt.Errorf("marshal function doc: %w", err)
		}
		out = append(out, b)
	}
	return bytes.Join(out, []byte("---\n")), nil
}

func (r *CrossplaneRenderer) Render(ctx context.Context, claimYAML []byte) ([]api.RenderedResource, error) {
	tmp, err := os.CreateTemp("", "app-wizard-claim-*.yaml")
	if err != nil {
		return nil, fmt.Errorf("create temp claim: %w", err)
	}
	defer func() { _ = os.Remove(tmp.Name()) }()
	if _, err := tmp.Write(claimYAML); err != nil {
		_ = tmp.Close()
		return nil, fmt.Errorf("write claim: %w", err)
	}
	if err := tmp.Close(); err != nil {
		return nil, fmt.Errorf("close temp claim: %w", err)
	}

	// Functions file: in dev-targets mode, overlay the Development runtime so
	// render dials the in-pod function sidecars instead of running Docker.
	functionsPath := r.FunctionsPath
	if len(r.DevTargets) > 0 {
		orig, err := os.ReadFile(r.FunctionsPath)
		if err != nil {
			return nil, fmt.Errorf("read functions file: %w", err)
		}
		devFns, err := DevFunctionsYAML(orig, r.DevTargets)
		if err != nil {
			return nil, err
		}
		ftmp, err := os.CreateTemp("", "app-wizard-functions-*.yaml")
		if err != nil {
			return nil, fmt.Errorf("create temp functions: %w", err)
		}
		defer func() { _ = os.Remove(ftmp.Name()) }()
		if _, err := ftmp.Write(devFns); err != nil {
			_ = ftmp.Close()
			return nil, fmt.Errorf("write functions: %w", err)
		}
		if err := ftmp.Close(); err != nil {
			return nil, fmt.Errorf("close temp functions: %w", err)
		}
		functionsPath = ftmp.Name()
	}

	args := r.renderArgs(tmp.Name(), functionsPath)

	var stdout, stderr bytes.Buffer
	cmd := exec.CommandContext(ctx, r.Binary, args...)
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		return nil, fmt.Errorf("crossplane render failed: %w: %s", err, strings.TrimSpace(stderr.String()))
	}

	return ParseRenderStream(stdout.Bytes())
}

// ParseRenderStream parses a multi-document YAML stream (as emitted by
// `crossplane render`) into RenderedResource entries.
func ParseRenderStream(stream []byte) ([]api.RenderedResource, error) {
	docs := splitYAMLDocs(stream)
	out := make([]api.RenderedResource, 0, len(docs))
	for _, doc := range docs {
		trimmed := bytes.TrimSpace(doc)
		if len(trimmed) == 0 {
			continue
		}
		var obj struct {
			Kind     string `json:"kind"`
			Metadata struct {
				Name string `json:"name"`
			} `json:"metadata"`
		}
		if err := yaml.Unmarshal(trimmed, &obj); err != nil {
			// Skip unparsable fragments rather than failing the whole preview.
			continue
		}
		if obj.Kind == "" {
			continue
		}
		out = append(out, api.RenderedResource{
			Kind: obj.Kind,
			Name: obj.Metadata.Name,
			Role: roleForKind(obj.Kind),
			YAML: string(trimmed) + "\n",
		})
	}
	return out, nil
}

// splitYAMLDocs splits a stream on `---` document separators.
func splitYAMLDocs(stream []byte) [][]byte {
	parts := bytes.Split(stream, []byte("\n---"))
	docs := make([][]byte, 0, len(parts))
	for _, p := range parts {
		docs = append(docs, bytes.TrimPrefix(p, []byte("---")))
	}
	return docs
}

// roleForKind maps a resource kind to a one-line human description.
func roleForKind(kind string) string {
	switch kind {
	case "Deployment":
		return "runs the workload pods"
	case "Service":
		return "cluster-internal network endpoint"
	case "HTTPRoute":
		return "external routing via Gateway API"
	case "Gateway":
		return "dedicated ingress gateway"
	case "PersistentVolumeClaim":
		return "persistent storage"
	case "HorizontalPodAutoscaler":
		return "autoscaling policy"
	case "PodDisruptionBudget":
		return "disruption safety budget"
	case "CiliumNetworkPolicy":
		return "network policy (zero-trust)"
	case "ExternalSecret":
		return "syncs secrets from AWS Secrets Manager"
	case "ServiceAccount":
		return "workload identity"
	case "SQLInstance":
		return "managed PostgreSQL database"
	case "Bucket", "ObjectStorage":
		return "S3 object storage"
	case "ConfigMap":
		return "configuration data"
	case "VMServiceScrape", "ServiceMonitor":
		return "metrics scrape target"
	case "VMRule":
		return "alerting rules"
	default:
		return ""
	}
}

var _ Renderer = (*CrossplaneRenderer)(nil)
