#!/bin/bash
#
# validate-spec.sh — Validate SDD spec directory (3-artifact structure).
#
# Usage:
#   ./scripts/validate-spec.sh                        # most-recent active spec
#   ./scripts/validate-spec.sh <spec-dir>             # explicit directory
#   ./scripts/validate-spec.sh <path/to/spec.md>      # also accepts spec.md path
#
# Validates:
#   spec.md            — WHAT: required sections, issue link, SC-XXX / FR-XXX counts, falsifiable SCs
#   plan.md            — HOW: Design + Tasks (T001+) + Review Checklist ≥ 75%
#   clarifications.md  — append-only log (no forbidden CLARIFIED-inline pattern in spec.md)
#
# Cross-artifact checks:
#   - FR-XXX should appear in plan.md tasks (coverage gap detection)
#   - clarifications.md CL-N entries should be referenced from spec/plan
#
# Exit:
#   0 = pass (maybe with warnings)
#   1 = errors present (do not implement)
#

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

ERRORS=0
WARNINGS=0

print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}
print_success() { echo -e "   ${GREEN}✅ $1${NC}"; }
print_error()   { echo -e "   ${RED}❌ $1${NC}"; ERRORS=$((ERRORS+1)); }
print_warning() { echo -e "   ${YELLOW}⚠️  $1${NC}"; WARNINGS=$((WARNINGS+1)); }

# ---------- locate spec directory ----------
if [ $# -ge 1 ]; then
    arg="$1"
    if [ -d "$arg" ]; then
        SPEC_DIR="$arg"
    elif [ -f "$arg" ]; then
        SPEC_DIR="$(dirname "$arg")"
    else
        echo -e "${RED}ERROR: path not found: $arg${NC}" >&2
        exit 1
    fi
else
    # Most-recently-modified active spec directory (contains a spec.md)
    SPEC_DIR=$(find docs/specs -name "spec.md" \
        -not -path "*/done/*" \
        -not -path "*/templates/*" \
        -type f -print0 2>/dev/null | \
        xargs -0 ls -t 2>/dev/null | head -1 | xargs -I{} dirname {})
    if [ -z "${SPEC_DIR:-}" ]; then
        echo -e "${RED}ERROR: no active spec directory found under docs/specs/${NC}" >&2
        exit 1
    fi
fi

SPEC_FILE="$SPEC_DIR/spec.md"
PLAN_FILE="$SPEC_DIR/plan.md"
CLARIFS_FILE="$SPEC_DIR/clarifications.md"

echo -e "\n╔════════════════════════════════════════════════════════════════╗"
echo -e "║  ${BLUE}SDD Spec Validation${NC}                                          ║"
echo -e "╚════════════════════════════════════════════════════════════════╝"
echo -e "\n📂 Directory: ${BLUE}$SPEC_DIR${NC}"

# ---------- artifact presence ----------
print_header "0. Artifact presence"
for f in spec.md plan.md clarifications.md; do
    if [ -f "$SPEC_DIR/$f" ]; then
        print_success "$f exists"
    else
        print_error "$f missing — run create-spec.sh to scaffold, or copy from docs/specs/templates/"
    fi
done
# If spec.md is missing, everything else is moot
[ -f "$SPEC_FILE" ] || { echo -e "\n${RED}Cannot continue without spec.md${NC}"; exit 1; }

# ---------- spec.md: required sections ----------
print_header "1. spec.md — required sections"
for section in "## Summary" "## Problem" "## User Stories" "## Requirements" "## Success Criteria"; do
    if grep -q "^$section" "$SPEC_FILE"; then
        print_success "Found: $section"
    else
        print_error "Missing in spec.md: $section"
    fi
done

# ---------- spec.md: issue link ----------
print_header "2. spec.md — GitHub issue link"
if grep -qP 'Issue.*#\d+' "$SPEC_FILE"; then
    ISSUE_NUM=$(grep -oP 'Issue.*#\K\d+' "$SPEC_FILE" | head -1)
    print_success "GitHub issue linked: #$ISSUE_NUM"
elif grep -qP '^\s*\*\*Issue\*\*:\s*N/A' "$SPEC_FILE"; then
    print_warning "Issue marked N/A (acceptable for foundational/legacy specs)"
else
    print_error "No GitHub issue link (expected '**Issue**: #XXX' or 'N/A' in metadata header)"
fi

# ---------- spec.md: unresolved markers ----------
print_header "3. spec.md — clarification markers"
UNRESOLVED=$(grep -cP '^\s*-\s*\[[ x]\]\s*\[NEEDS CLARIFICATION:' "$SPEC_FILE" 2>/dev/null || echo "0")
UNRESOLVED=${UNRESOLVED:-0}
if [ "$UNRESOLVED" -gt 0 ] 2>/dev/null; then
    print_warning "$UNRESOLVED unresolved [NEEDS CLARIFICATION] marker(s) — run /clarify"
    grep -nP '\[NEEDS CLARIFICATION:' "$SPEC_FILE" | while read -r line; do
        echo -e "      ${YELLOW}→ $line${NC}"
    done
else
    print_success "No unresolved clarification markers"
fi

# Forbid the legacy in-place CLARIFIED pattern — decisions must live in clarifications.md
INLINE_CLARIFIED=$(grep -cP '\[CLARIFIED:' "$SPEC_FILE" 2>/dev/null || echo "0")
INLINE_CLARIFIED=${INLINE_CLARIFIED:-0}
if [ "$INLINE_CLARIFIED" -gt 0 ] 2>/dev/null; then
    print_warning "Found $INLINE_CLARIFIED inline [CLARIFIED: ...] marker(s) in spec.md"
    echo -e "      ${YELLOW}→ Decisions must live in clarifications.md as CL-N entries; spec.md references them by ID${NC}"
fi

# ---------- spec.md: counts ----------
print_header "4. spec.md — FR / SC counts"
FR_COUNT=$(grep -cP 'FR-\d{3}' "$SPEC_FILE" 2>/dev/null || echo "0")
SC_COUNT=$(grep -cP 'SC-\d{3}' "$SPEC_FILE" 2>/dev/null || echo "0")
FR_COUNT=${FR_COUNT:-0}; SC_COUNT=${SC_COUNT:-0}
[ "$FR_COUNT" -ge 2 ] && print_success "Found $FR_COUNT FR-XXX requirements" \
    || print_warning "Only $FR_COUNT FR-XXX (recommend ≥ 2)"
[ "$SC_COUNT" -ge 2 ] && print_success "Found $SC_COUNT SC-XXX success criteria" \
    || print_warning "Only $SC_COUNT SC-XXX (recommend ≥ 2)"

# ---------- spec.md: falsifiability heuristic ----------
print_header "5. spec.md — falsifiable success criteria"
AMBIGUOUS=$(grep -EniP '\*\*SC-\d{3}\*\*.*\b(fast|scalable|secure|robust|flexible|user-friendly|simple|efficient|reliable)\b' "$SPEC_FILE" 2>/dev/null || true)
if [ -n "$AMBIGUOUS" ]; then
    print_warning "SC entries contain vague adjectives (no measurable threshold). Add a metric:"
    echo "$AMBIGUOUS" | while read -r line; do echo -e "      ${YELLOW}→ $line${NC}"; done
else
    print_success "No vague adjectives detected in SC-XXX"
fi

# ---------- plan.md: design + tasks + review checklist ----------
if [ -f "$PLAN_FILE" ]; then
    print_header "6. plan.md — design, tasks, review checklist"
    for section in "## Design" "## Tasks" "## Review Checklist"; do
        if grep -q "^$section" "$PLAN_FILE"; then
            print_success "Found in plan.md: $section"
        else
            print_error "Missing in plan.md: $section"
        fi
    done

    CHECKLIST_START=$(grep -n "^## Review Checklist" "$PLAN_FILE" | cut -d: -f1 | head -1 || echo "0")
    if [ "${CHECKLIST_START:-0}" -gt 0 ]; then
        NEXT_HEADING=$(tail -n +"$((CHECKLIST_START + 1))" "$PLAN_FILE" | grep -n "^## " | head -1 | cut -d: -f1 || echo "")
        if [ -n "$NEXT_HEADING" ]; then
            END_LINE=$((CHECKLIST_START + NEXT_HEADING - 1))
        else
            END_LINE=$(wc -l < "$PLAN_FILE")
        fi
        CHECKED=$(awk "NR>=${CHECKLIST_START} && NR<=${END_LINE}" "$PLAN_FILE" | grep -c '\[x\]' || true)
        UNCHECKED=$(awk "NR>=${CHECKLIST_START} && NR<=${END_LINE}" "$PLAN_FILE" | grep -c '\[ \]' || true)
        : "${CHECKED:=0}"; : "${UNCHECKED:=0}"
        TOTAL=$((CHECKED + UNCHECKED))
        if [ "$TOTAL" -gt 0 ]; then
            PERCENT=$((100 * CHECKED / TOTAL))
            if [ "$PERCENT" -ge 100 ]; then
                print_success "Review checklist: $CHECKED/$TOTAL (100%)"
            elif [ "$PERCENT" -ge 75 ]; then
                print_warning "Review checklist: $CHECKED/$TOTAL ($PERCENT%)"
            else
                print_error "Review checklist: $CHECKED/$TOTAL ($PERCENT%) — complete ≥ 75% before implementing"
            fi
        else
            print_warning "plan.md Review Checklist has no checkboxes"
        fi
    fi

    # Tasks — count T001+ entries inside plan.md (Tasks section moved here from tasks.md).
    TASK_COUNT=$(grep -cP '^\s*-\s*\[[ x]\]\s*\*\*T\d{3}\*\*' "$PLAN_FILE" 2>/dev/null || echo "0")
    TASK_DONE=$(grep -cP '^\s*-\s*\[x\]\s*\*\*T\d{3}\*\*' "$PLAN_FILE" 2>/dev/null || echo "0")
    : "${TASK_COUNT:=0}"; : "${TASK_DONE:=0}"
    if [ "$TASK_COUNT" -gt 0 ]; then
        print_success "plan.md tasks: $TASK_COUNT ($TASK_DONE complete)"
    else
        print_warning "plan.md has no T001-style task IDs in Tasks section"
    fi
fi

# ---------- clarifications.md: append-only format ----------
if [ -f "$CLARIFS_FILE" ]; then
    print_header "8. clarifications.md — append-only format"
    CL_ENTRIES=$(grep -cP '^## CL-\d+' "$CLARIFS_FILE" 2>/dev/null || echo "0")
    : "${CL_ENTRIES:=0}"
    if [ "$CL_ENTRIES" -gt 0 ]; then
        print_success "clarifications.md: $CL_ENTRIES CL-N entries"
        # Check for duplicate IDs
        DUP=$(grep -oP '^## CL-\K\d+' "$CLARIFS_FILE" | sort | uniq -d)
        if [ -n "$DUP" ]; then
            print_error "Duplicate CL IDs: $(echo "$DUP" | tr '\n' ' ')"
        fi
    else
        print_warning "clarifications.md has no CL-N entries yet (OK for fresh specs)"
    fi
fi

# ---------- cross-artifact: FR coverage ----------
if [ -f "$PLAN_FILE" ]; then
    print_header "9. Cross-artifact — FR-XXX → task coverage"
    UNCOVERED=""
    while IFS= read -r FR; do
        FR_ID=$(echo "$FR" | grep -oP 'FR-\d{3}')
        # Skip if FR ID is referenced in plan.md (case-insensitive task description)
        if ! grep -qP "$FR_ID" "$PLAN_FILE" 2>/dev/null; then
            UNCOVERED+="$FR_ID "
        fi
    done < <(grep -oP '\*\*FR-\d{3}\*\*' "$SPEC_FILE" 2>/dev/null | sort -u)
    if [ -n "$UNCOVERED" ]; then
        print_warning "FRs not referenced in plan.md (coverage gap): $UNCOVERED"
        echo -e "      ${YELLOW}→ Mention each FR-XXX in a task or design note in plan.md${NC}"
    else
        print_success "All FR-XXX referenced in plan.md"
    fi
fi

# ---------- cross-artifact: stale CL-N references ----------
if [ -f "$CLARIFS_FILE" ]; then
    print_header "10. Cross-artifact — CL-N references"
    DEFINED_CL=$(grep -oP '^## CL-\K\d+' "$CLARIFS_FILE" 2>/dev/null | sort -u | tr '\n' ' ')
    REFERENCED_CL=$(grep -ohP 'CL-\K\d+' "$SPEC_FILE" "$PLAN_FILE" 2>/dev/null | sort -u | tr '\n' ' ')
    STALE=""
    for n in $REFERENCED_CL; do
        case " $DEFINED_CL " in *" $n "*) ;; *) STALE+="CL-$n " ;; esac
    done
    if [ -n "$STALE" ]; then
        print_warning "Stale CL-N references (mentioned but not defined): $STALE"
    else
        [ -n "$REFERENCED_CL" ] && print_success "All CL-N references resolve to clarifications.md entries" \
            || print_success "No CL-N cross-references yet"
    fi
fi

# ---------- ambiguity: vague adjectives in plan too ----------
if [ -f "$PLAN_FILE" ]; then
    print_header "11. plan.md — vague adjectives in design"
    VAGUE_PLAN=$(grep -EniP '\b(fast|scalable|secure|robust|flexible|simple|efficient|reliable)\b' "$PLAN_FILE" 2>/dev/null | grep -vP '(<!--|^\s*//)' | head -5 || true)
    if [ -n "$VAGUE_PLAN" ]; then
        print_warning "plan.md uses vague terms — quantify or remove:"
        echo "$VAGUE_PLAN" | while read -r line; do echo -e "      ${YELLOW}→ $line${NC}"; done
    else
        print_success "No vague adjectives in plan.md"
    fi
fi

# ---------- placeholders across all files ----------
print_header "12. Placeholder detection (all artifacts)"
PLACEHOLDER_FOUND=0
for f in "$SPEC_FILE" "$PLAN_FILE" "$CLARIFS_FILE"; do
    [ -f "$f" ] || continue
    for placeholder in '\[Title\]' 'YYYY-MM-DD' 'SPEC-XXX' 'pull/YYY'; do
        if grep -qP "$placeholder" "$f"; then
            print_warning "Placeholder '$placeholder' in $(basename "$f")"
            PLACEHOLDER_FOUND=$((PLACEHOLDER_FOUND+1))
        fi
    done
done
[ "$PLACEHOLDER_FOUND" -eq 0 ] && print_success "No unfilled placeholders"

# ---------- constitution reference ----------
print_header "13. Constitution reference"
if grep -q 'constitution.md' "$SPEC_FILE" || grep -q 'constitution.md' "$PLAN_FILE" 2>/dev/null; then
    print_success "Constitution reference present in spec or plan"
else
    print_warning "No constitution reference — add link to docs/specs/constitution.md"
fi

# ---------- summary ----------
print_header "Summary"
if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "\n   ${GREEN}✅ All checks passed. Spec ready for implementation.${NC}"
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "\n   ${YELLOW}⚠️  $WARNINGS warning(s), 0 errors — review before proceeding.${NC}"
    exit 0
else
    echo -e "\n   ${RED}❌ $ERRORS error(s), $WARNINGS warning(s) — fix errors before implementation.${NC}"
    exit 1
fi
