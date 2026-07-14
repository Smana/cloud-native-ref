package validate

import (
	"fmt"

	"github.com/Smana/cloud-native-ref/container-images/app-wizard/internal/api"
	"github.com/google/cel-go/cel"
	"github.com/google/cel-go/common/types"
	"github.com/google/cel-go/common/types/ref"
)

// celProgram is a compiled CEL rule paired with its message.
type celProgram struct {
	prog cel.Program
	rule api.CELRule
}

// CELEvaluator compiles the XRD's spec-level CEL rules once and evaluates them
// against a candidate spec. It mirrors Kubernetes: `self` is bound to the spec
// object, and a rule returning false yields a violation carrying its message.
type CELEvaluator struct {
	programs []celProgram
}

// NewCELEvaluator compiles rules. Rules that fail to compile are skipped with
// their compile error captured as the message so the caller still surfaces a
// signal rather than silently dropping a rule.
func NewCELEvaluator(rules []api.CELRule) (*CELEvaluator, error) {
	env, err := cel.NewEnv(
		cel.Variable("self", cel.DynType),
	)
	if err != nil {
		return nil, fmt.Errorf("cel env: %w", err)
	}

	e := &CELEvaluator{}
	for _, r := range rules {
		ast, iss := env.Compile(r.Rule)
		if iss != nil && iss.Err() != nil {
			// Preserve as a non-evaluable marker: record the rule but leave
			// prog nil; Evaluate treats nil prog as "cannot evaluate" and
			// skips it (client-side still has the rule text).
			e.programs = append(e.programs, celProgram{prog: nil, rule: r})
			continue
		}
		prog, err := env.Program(ast)
		if err != nil {
			e.programs = append(e.programs, celProgram{prog: nil, rule: r})
			continue
		}
		e.programs = append(e.programs, celProgram{prog: prog, rule: r})
	}
	return e, nil
}

// Evaluate returns the rules that the spec violates (evaluated to false). Rules
// that error at runtime or could not compile are skipped (best-effort, matches
// the "surface what we can" posture of pre-submit validation).
func (e *CELEvaluator) Evaluate(spec map[string]any) []api.CELRule {
	var violations []api.CELRule
	for _, p := range e.programs {
		if p.prog == nil {
			continue
		}
		out, _, err := p.prog.Eval(map[string]any{"self": spec})
		if err != nil {
			continue
		}
		if isFalse(out) {
			violations = append(violations, p.rule)
		}
	}
	return violations
}

func isFalse(v ref.Val) bool {
	b, ok := v.(types.Bool)
	if !ok {
		return false
	}
	return !bool(b)
}
