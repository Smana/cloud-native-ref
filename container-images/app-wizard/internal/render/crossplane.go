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
	// CompositionPath / FunctionsPath / EnvConfigPath are absolute paths to the
	// composition, functions, and environmentconfig files.
	CompositionPath string
	FunctionsPath   string
	EnvConfigPath   string
}

// NewCrossplaneRenderer builds a renderer. repoRoot anchors the relative
// composition paths.
func NewCrossplaneRenderer(repoRoot, compositionPath, functionsPath, envConfigPath string) *CrossplaneRenderer {
	abs := func(p string) string {
		if filepath.IsAbs(p) {
			return p
		}
		return filepath.Join(repoRoot, p)
	}
	return &CrossplaneRenderer{
		Binary:          "crossplane",
		CompositionPath: abs(compositionPath),
		FunctionsPath:   abs(functionsPath),
		EnvConfigPath:   abs(envConfigPath),
	}
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

	args := []string{"render", tmp.Name(), r.CompositionPath, r.FunctionsPath}
	if r.EnvConfigPath != "" {
		args = append(args, "--extra-resources", r.EnvConfigPath)
	}

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
