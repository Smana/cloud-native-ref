package assist

import (
	"context"
	"encoding/json"
	"fmt"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/config"
	"github.com/anthropics/anthropic-sdk-go"
	"github.com/anthropics/anthropic-sdk-go/option"
)

// maxTokens bounds each assist response. The tasks are small structured
// extractions, so 4000 is generous.
const maxTokens = 4000

const prefillSystemPrompt = `You map a plain-language app description to a partial Crossplane App spec. Only set fields you are confident about. Output via the tool.`

// policiesSystemPrompt encodes the Cilium authoring traps from
// .claude/rules/cilium-network-policies.md. These are the rules the model MUST
// follow when suggesting egress rules; violating them produces policies that
// silently drop traffic at runtime.
const policiesSystemPrompt = `You map a plain-language description of an app's dependencies to candidate CiliumNetworkPolicy ingress and egress rules. Output via the tool. Default-deny is already enforced by the composition; you only emit the explicit allow rules.

Follow these Cilium authoring rules exactly — violating them produces policies that silently drop traffic at runtime:

1. Every toFQDNs egress rule REQUIRES a companion kube-dns egress rule that inspects DNS at L7: an egress rule selecting the kube-dns pods with toPorts on UDP 53 AND TCP 53 whose toPorts.rules.dns.matchPattern is "*". Without this L7 DNS rule, Cilium proxies the DNS query but never sees the response IPs, so the toFQDNs allowlist has no IPs to match and every downstream TCP connection is silently dropped (DNS keeps working, the connection fails).

2. Always include that kube-dns egress rule (UDP+TCP port 53, with the L7 dns matchPattern "*") whenever the app makes ANY external or in-cluster connection by DNS name.

3. matchPattern is a single-segment glob: it does NOT span dots. "*.example.com" matches "cdn.example.com" but NOT "a.b.example.com". Prefer matchName for exact hosts, or list each concrete subdomain explicitly, rather than relying on a wildcard that will miss deeper subdomains.

4. For host-network or link-local dependencies — most importantly AWS access via the EKS Pod Identity Agent at 169.254.170.23:80 — do NOT use toCIDR. That endpoint runs on the node's host network, so Cilium classifies it as the "host" entity and a toCIDR rule silently fails. Use toEntities ["host"] scoped to toPorts TCP 80 instead.

Emit only the rules the description justifies. When in doubt, prefer fewer, tighter rules over broad ones.`

const (
	prefillToolName  = "app_spec"
	policiesToolName = "network_policies"
)

// messagesClient is the minimal subset of the Anthropic Messages API the assist
// uses. Injected so tests can supply a fake without a real API key or network.
type messagesClient interface {
	New(ctx context.Context, params anthropic.MessageNewParams, opts ...option.RequestOption) (*anthropic.Message, error)
}

// AnthropicAssist is the Assist backed by the Anthropic Messages API. It uses a
// single schema-constrained tool (input_schema = the XRD-derived schema, forced
// via tool_choice) to obtain structured output that cannot drift from the XRD.
type AnthropicAssist struct {
	client    messagesClient
	model     anthropic.Model
	available bool
}

// NewAnthropicAssist builds an AnthropicAssist from config. The API key and base
// URL come from config; neither is logged here. When cfg.LLMModel is empty the
// SDK default Opus 4.8 constant is used.
func NewAnthropicAssist(cfg *config.Config) *AnthropicAssist {
	opts := []option.RequestOption{}
	if cfg.LLMAPIKey != "" {
		opts = append(opts, option.WithAPIKey(cfg.LLMAPIKey))
	}
	if cfg.LLMBaseURL != "" {
		opts = append(opts, option.WithBaseURL(cfg.LLMBaseURL))
	}
	client := anthropic.NewClient(opts...)

	model := anthropic.ModelClaudeOpus4_8
	if cfg.LLMModel != "" {
		model = anthropic.Model(cfg.LLMModel)
	}

	return &AnthropicAssist{
		client:    &client.Messages,
		model:     model,
		available: cfg.AssistsAvailable(),
	}
}

// Available reports whether the backend is configured.
func (a *AnthropicAssist) Available() bool { return a.available }

// Prefill maps a description to a partial App .spec, constrained by appSchema.
func (a *AnthropicAssist) Prefill(ctx context.Context, description string, appSchema map[string]any) (map[string]any, error) {
	raw, err := a.callTool(ctx, prefillSystemPrompt, description, prefillToolName,
		"A partial Crossplane App .spec. Only include fields you are confident about.", appSchema)
	if err != nil {
		return nil, err
	}
	var spec map[string]any
	if err := json.Unmarshal(raw, &spec); err != nil {
		return nil, fmt.Errorf("assist: parse prefill tool output: %w", err)
	}
	return spec, nil
}

// SuggestPolicies maps a dependency description to candidate ingress/egress
// rules. cnpSchema is the networkPolicies subschema; its "ingress" and "egress"
// array schemas are wrapped into the tool input_schema.
func (a *AnthropicAssist) SuggestPolicies(ctx context.Context, description string, cnpSchema map[string]any) ([]any, []any, error) {
	toolSchema, err := policiesToolSchema(cnpSchema)
	if err != nil {
		return nil, nil, err
	}
	raw, err := a.callTool(ctx, policiesSystemPrompt, description, policiesToolName,
		"Candidate CiliumNetworkPolicy ingress and egress rules.", toolSchema)
	if err != nil {
		return nil, nil, err
	}
	var out struct {
		Ingress []any `json:"ingress"`
		Egress  []any `json:"egress"`
	}
	if err := json.Unmarshal(raw, &out); err != nil {
		return nil, nil, fmt.Errorf("assist: parse policies tool output: %w", err)
	}
	return out.Ingress, out.Egress, nil
}

// callTool runs a single Messages request with one tool whose input_schema is
// the provided schema, forces that tool via tool_choice, and returns the raw
// JSON of the tool-use input. This is the standard schema-constrained
// structured-extraction pattern.
func (a *AnthropicAssist) callTool(ctx context.Context, systemPrompt, description, toolName, toolDescription string, schema map[string]any) (json.RawMessage, error) {
	if !a.available {
		return nil, ErrNotConfigured
	}
	if a.client == nil {
		return nil, ErrNotConfigured
	}

	tool := anthropic.ToolParam{
		Name:        toolName,
		Description: anthropic.String(toolDescription),
		InputSchema: toolInputSchema(schema),
	}

	resp, err := a.client.New(ctx, anthropic.MessageNewParams{
		Model:     a.model,
		MaxTokens: maxTokens,
		System: []anthropic.TextBlockParam{
			{Text: systemPrompt},
		},
		Tools: []anthropic.ToolUnionParam{{OfTool: &tool}},
		ToolChoice: anthropic.ToolChoiceUnionParam{
			OfTool: &anthropic.ToolChoiceToolParam{Name: toolName},
		},
		Messages: []anthropic.MessageParam{
			anthropic.NewUserMessage(anthropic.NewTextBlock(description)),
		},
	})
	if err != nil {
		return nil, fmt.Errorf("assist: LLM request failed: %w", err)
	}

	for _, block := range resp.Content {
		if tu, ok := block.AsAny().(anthropic.ToolUseBlock); ok && tu.Name == toolName {
			return json.RawMessage(tu.JSON.Input.Raw()), nil
		}
	}
	return nil, fmt.Errorf("assist: model returned no tool use for %q", toolName)
}

// toolInputSchema converts a JSON Schema document (map) into the SDK's tool
// input_schema shape. The SDK only requires "type" and "properties" as typed
// fields; the rest of the schema (required, enums, patterns, nested objects,
// $schema, additionalProperties, …) is carried through ExtraFields verbatim so
// the constraint stays faithful to the XRD-derived schema.
func toolInputSchema(schema map[string]any) anthropic.ToolInputSchemaParam {
	in := anthropic.ToolInputSchemaParam{}
	if props, ok := schema["properties"].(map[string]any); ok {
		in.Properties = props
	}
	extra := map[string]any{}
	for k, v := range schema {
		switch k {
		case "type", "properties":
			// carried as typed fields
		default:
			extra[k] = v
		}
	}
	if len(extra) > 0 {
		in.ExtraFields = extra
	}
	return in
}

// policiesToolSchema builds the tool input_schema for SuggestPolicies from the
// networkPolicies subschema: an object with "ingress" and "egress" array
// schemas pulled from the composition's schema (so it stays drift-free).
func policiesToolSchema(cnpSchema map[string]any) (map[string]any, error) {
	props, ok := cnpSchema["properties"].(map[string]any)
	if !ok {
		return nil, fmt.Errorf("assist: networkPolicies schema has no properties")
	}
	ingress, iok := props["ingress"]
	egress, eok := props["egress"]
	if !iok || !eok {
		return nil, fmt.Errorf("assist: networkPolicies schema missing ingress/egress")
	}
	return map[string]any{
		"type": "object",
		"properties": map[string]any{
			"ingress": ingress,
			"egress":  egress,
		},
	}, nil
}
