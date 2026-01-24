#!/bin/bash
#
# validate-spec.sh - Validate specification files before implementation
#
# Usage: ./scripts/validate-spec.sh [spec-file]
#
# If no file specified, validates the most recently modified spec in docs/specs/
# (excluding done/ and templates/)
#

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
ERRORS=0
WARNINGS=0

# Print functions
print_header() {
    echo -e "\n${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BLUE}  $1${NC}"
    echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
}

print_success() {
    echo -e "   ${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "   ${RED}❌ $1${NC}"
    ((ERRORS++))
}

print_warning() {
    echo -e "   ${YELLOW}⚠️  $1${NC}"
    ((WARNINGS++))
}

# shellcheck disable=SC2329
print_info() {
    echo -e "   ${BLUE}ℹ️  $1${NC}"
}

# Find spec file
if [ $# -ge 1 ]; then
    SPEC_FILE="$1"
    if [ ! -f "$SPEC_FILE" ]; then
        echo -e "${RED}ERROR: Spec file not found: $SPEC_FILE${NC}"
        exit 1
    fi
else
    # Find most recently modified spec, excluding done/ and templates/
    SPEC_FILE=$(find docs/specs -name "spec.md" \
        -not -path "*/done/*" \
        -not -path "*/templates/*" \
        -type f -print0 2>/dev/null | \
        xargs -0 ls -t 2>/dev/null | head -1)
    if [ -z "$SPEC_FILE" ]; then
        echo -e "${RED}ERROR: No active spec files found in docs/specs/${NC}"
        exit 1
    fi
fi

echo -e "\n╔════════════════════════════════════════════════════════════════╗"
echo -e "║  ${BLUE}Spec Validation${NC}                                               ║"
echo -e "╚════════════════════════════════════════════════════════════════╝"
echo -e "\n📄 Validating: ${BLUE}$SPEC_FILE${NC}"

# CHECK 1: Required Sections (matching actual template)
print_header "1. Required Sections"

for section in "## Summary" "## Problem" "## User Stories" "## Requirements" "## Success Criteria" "## Design" "## Tasks"; do
    if grep -q "^$section" "$SPEC_FILE"; then
        print_success "Found: $section"
    else
        print_error "Missing: $section"
    fi
done

# CHECK 2: Unresolved Clarifications
print_header "2. Clarification Markers"

UNRESOLVED=$(grep -c '\[NEEDS CLARIFICATION:' "$SPEC_FILE" 2>/dev/null || echo "0")
UNRESOLVED=${UNRESOLVED:-0}
if [ "$UNRESOLVED" -gt 0 ] 2>/dev/null; then
    print_error "Found $UNRESOLVED unresolved [NEEDS CLARIFICATION] marker(s)"
    # Show the clarifications that need resolving
    grep -n '\[NEEDS CLARIFICATION:' "$SPEC_FILE" 2>/dev/null | while read -r line; do
        echo -e "      ${YELLOW}→ $line${NC}"
    done
else
    print_success "No unresolved clarification markers"
fi

# CHECK 3: GitHub Issue Link
print_header "3. GitHub Issue Link"

if grep -qP 'Issue.*#\d+' "$SPEC_FILE"; then
    ISSUE_NUM=$(grep -oP 'Issue.*#\K\d+' "$SPEC_FILE" | head -1)
    print_success "GitHub Issue linked: #$ISSUE_NUM"
else
    print_error "No GitHub Issue link found"
fi

# CHECK 4: Constitution Reference
print_header "4. Constitution Compliance"

if grep -q 'constitution.md' "$SPEC_FILE"; then
    print_success "Constitution reference found"
else
    print_warning "No constitution reference in spec"
fi

# CHECK 5: Placeholder Detection
print_header "5. Placeholder Detection"

PLACEHOLDER_FOUND=0
for placeholder in '\[Name\]' '\[Title\]' 'YYYY-MM-DD' 'SPEC-XXX' '\[role\]' '\[capability\]' '\[benefit\]'; do
    if grep -qP "$placeholder" "$SPEC_FILE"; then
        print_warning "Found placeholder: $placeholder"
        ((PLACEHOLDER_FOUND++))
    fi
done

if [ "$PLACEHOLDER_FOUND" -eq 0 ]; then
    print_success "No unfilled placeholders found"
fi

# CHECK 6: Review Checklist Completion
print_header "6. Review Checklist"

# Extract Review Checklist section and count checkboxes
CHECKLIST_START=$(grep -n "^## Review Checklist" "$SPEC_FILE" | cut -d: -f1 || echo "0")
if [ "$CHECKLIST_START" -gt 0 ]; then
    # Get content from Review Checklist to next section or end
    NEXT_SECTION=$(tail -n +"$((CHECKLIST_START + 1))" "$SPEC_FILE" | grep -n "^## " | head -1 | cut -d: -f1 || echo "")
    if [ -n "$NEXT_SECTION" ]; then
        END_LINE=$((CHECKLIST_START + NEXT_SECTION - 1))
        CHECKLIST_CONTENT=$(sed -n "${CHECKLIST_START},${END_LINE}p" "$SPEC_FILE")
    else
        CHECKLIST_CONTENT=$(tail -n +"$CHECKLIST_START" "$SPEC_FILE")
    fi

    CHECKED=$(echo "$CHECKLIST_CONTENT" | grep -c '\[x\]' 2>/dev/null || echo "0")
    UNCHECKED=$(echo "$CHECKLIST_CONTENT" | grep -c '\[ \]' 2>/dev/null || echo "0")
    TOTAL=$((CHECKED + UNCHECKED))

    if [ "$TOTAL" -gt 0 ]; then
        PERCENT=$((100 * CHECKED / TOTAL))
        if [ "$PERCENT" -eq 100 ]; then
            print_success "Review checklist: $CHECKED/$TOTAL items complete (100%)"
        elif [ "$PERCENT" -ge 75 ]; then
            print_warning "Review checklist: $CHECKED/$TOTAL items complete ($PERCENT%)"
        else
            print_error "Review checklist: $CHECKED/$TOTAL items complete ($PERCENT%) - review before implementing"
        fi
    else
        print_warning "No checklist items found in Review Checklist section"
    fi
else
    print_error "Missing: ## Review Checklist section"
fi

# CHECK 7: Requirements & Success Criteria Count
print_header "7. Requirements & Success Criteria"

FR_COUNT=$(grep -cP 'FR-\d{3}' "$SPEC_FILE" 2>/dev/null || echo "0")
SC_COUNT=$(grep -cP 'SC-\d{3}' "$SPEC_FILE" 2>/dev/null || echo "0")

if [ "$FR_COUNT" -ge 2 ]; then
    print_success "Found $FR_COUNT functional requirements (FR-XXX)"
else
    print_warning "Only $FR_COUNT functional requirements found (recommend at least 2)"
fi

if [ "$SC_COUNT" -ge 2 ]; then
    print_success "Found $SC_COUNT success criteria (SC-XXX)"
else
    print_warning "Only $SC_COUNT success criteria found (recommend at least 2)"
fi

# CHECK 8: Tasks Defined
print_header "8. Task Tracking"

TASK_COUNT=$(grep -cP '^\s*-\s*\[[ x]\]\s*T\d{3}:' "$SPEC_FILE" 2>/dev/null || echo "0")
COMPLETED_TASKS=$(grep -cP '^\s*-\s*\[x\]\s*T\d{3}:' "$SPEC_FILE" 2>/dev/null || echo "0")

if [ "$TASK_COUNT" -gt 0 ]; then
    print_success "Found $TASK_COUNT tasks ($COMPLETED_TASKS completed)"
else
    print_warning "No structured tasks (T001:, T002:...) found"
fi

# SUMMARY
print_header "Summary"

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "\n   ${GREEN}✅ All checks passed! Spec is ready for implementation.${NC}"
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "\n   ${YELLOW}⚠️  $WARNINGS warning(s), 0 errors - Review warnings before proceeding${NC}"
    exit 0
else
    echo -e "\n   ${RED}❌ $ERRORS error(s), $WARNINGS warning(s) - Fix errors before implementation${NC}"
    exit 1
fi
