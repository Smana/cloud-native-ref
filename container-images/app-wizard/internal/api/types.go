// Package api defines the wire contract shared between the app-wizard backend
// and its React SPA. This file is the single source of truth for that contract;
// the TypeScript mirror lives at ui/src/api/types.ts and MUST be kept in sync.
//
// SPEC-008 Phase 1. See docs/specs/008-app-wizard-self-service-ui/.
package api

// SchemaPayload is returned by GET /api/schema. It is everything the form
// renderer needs to draw the App form: the JSON Schema derived from the App
// XRD (FR-001), the CEL rules for live validation (FR-002), the presentation
// overlay (FR-003), and the selectable stacks (FR-006).
type SchemaPayload struct {
	// JSONSchema is the App XRD's spec openAPIV3Schema converted to a standard
	// JSON Schema document (draft 2020-12). Raw JSON so the frontend consumes
	// it directly without a Go-side type per field.
	JSONSchema map[string]any `json:"jsonSchema"`
	// CELRules are the spec-level x-kubernetes-validations, surfaced so the form
	// can evaluate them client-side and show the same message the API server would.
	CELRules []CELRule `json:"celRules"`
	// Hints is the presentation overlay (tiers, groups, order, labels, examples).
	Hints UIHints `json:"hints"`
	// Stacks are the deployable targets from apps/stacks.yaml.
	Stacks []Stack `json:"stacks"`
	// SchemaVersion identifies the XRD revision the payload was built from
	// (repo commit SHA), so the frontend can cache-bust on schema change.
	SchemaVersion string `json:"schemaVersion"`
}

// CELRule is one x-kubernetes-validations entry from the XRD.
type CELRule struct {
	Rule    string `json:"rule"`
	Message string `json:"message"`
}

// UIHints is the hand-maintained presentation overlay (ui-hints.yaml). It never
// contains field knowledge (types/enums/defaults come from the schema) — only
// how to present fields. A field absent from Hints defaults to the "advanced"
// tier and is never hidden.
type UIHints struct {
	// Fields maps a JSON-path-ish field key (e.g. "image.repository",
	// "sqlInstance") to its presentation hint.
	Fields map[string]FieldHint `json:"fields"`
	// Groups defines ordered, labeled collapsible sections referenced by
	// FieldHint.Group.
	Groups []GroupHint `json:"groups"`
}

// Tier controls initial visibility: basic = first screen, advanced = behind an
// expander, expert = behind an "expert" toggle.
type FieldHint struct {
	Tier    string `json:"tier"`              // basic | advanced | expert
	Group   string `json:"group,omitempty"`   // GroupHint.ID this field belongs to
	Label   string `json:"label,omitempty"`   // friendly label overriding the field name
	Help    string `json:"help,omitempty"`    // overrides/augments the schema description
	Example string `json:"example,omitempty"` // placeholder/example value
	Order   int    `json:"order,omitempty"`   // sort within its group/tier
}

type GroupHint struct {
	ID    string `json:"id"`
	Label string `json:"label"`
	Tier  string `json:"tier"`  // basic | advanced | expert
	Order int    `json:"order"`
}

// Stack is one entry from apps/stacks.yaml (FR-006, CL-6).
type Stack struct {
	Name        string `json:"name"`
	Description string `json:"description"`
	Namespace   string `json:"namespace"`
	OwnerTeam   string `json:"ownerTeam"`
}

// ValidateRequest carries a candidate claim spec for pre-submit validation.
type ValidateRequest struct {
	// Spec is the App claim's .spec object as entered in the form.
	Spec map[string]any `json:"spec"`
}

// ValidateResponse reports schema + CEL validation outcomes (FR-002, FR-007).
type ValidateResponse struct {
	Valid          bool             `json:"valid"`
	SchemaErrors   []FieldError     `json:"schemaErrors"`
	CELViolations  []CELRule        `json:"celViolations"` // rules that failed, with their messages
	SecretFindings []SecretFinding  `json:"secretFindings"` // FR-010: candidate secrets in the spec
}

type FieldError struct {
	Path    string `json:"path"`
	Message string `json:"message"`
}

// SecretFinding flags a value that looks like a secret (FR-010, SC-006).
type SecretFinding struct {
	Path   string `json:"path"`
	Reason string `json:"reason"` // e.g. "matches AWS access key pattern", "high entropy"
}

// RenderPreviewRequest asks the backend to run `crossplane render` on a claim.
type RenderPreviewRequest struct {
	Spec map[string]any `json:"spec"`
	Name string         `json:"name"`
	// Stack determines the target namespace (from the stack registry).
	Stack string `json:"stack"`
}

// RenderPreviewResponse lists the resources the claim would create (FR-008, SC-004).
type RenderPreviewResponse struct {
	OK        bool             `json:"ok"`
	Resources []RenderedResource `json:"resources"`
	Error     string           `json:"error,omitempty"`
}

type RenderedResource struct {
	Kind string `json:"kind"`
	Name string `json:"name"`
	Role string `json:"role,omitempty"` // one-line human description
}

// PRRequest is the payload to create the app and open a pull request (FR-005).
type PRRequest struct {
	Stack       string         `json:"stack"`
	AppName     string         `json:"appName"`
	Spec        map[string]any `json:"spec"`
	Description string         `json:"description"` // feeds the PR body
}

// PRResponse is returned once the PR is opened (FR-005).
type PRResponse struct {
	URL    string `json:"url"`
	Number int    `json:"number"`
	Branch string `json:"branch"`
}

// User is the authenticated GitHub identity (FR-004).
type User struct {
	Login     string `json:"login"`
	AvatarURL string `json:"avatarUrl"`
	Name      string `json:"name"`
}

// ErrorResponse is the uniform error envelope for all endpoints.
type ErrorResponse struct {
	Error string `json:"error"`
}
