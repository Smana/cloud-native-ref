#!/bin/bash
#
# validate-spec.sh - Validate specification files before implementation
#
# Usage: ./scripts/validate-spec.sh [spec-file]
#
# If no file specified, validates the most recently modified spec in docs/specs/active/
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

print_info() {
    echo -e "   ${BLUE}ℹ️  $1${NC}"
}

# Find spec file
if [ $# -ge 1 ]; then
    SPEC_FILE="$1"
    if [ ! -f "$SPEC_FILE" ]; then
        if [ -f "docs/specs/active/$SPEC_FILE" ]; then
            SPEC_FILE="docs/specs/active/$SPEC_FILE"
        else
            echo -e "${RED}ERROR: Spec file not found: $SPEC_FILE${NC}"
            exit 1
        fi
    fi
else
    SPEC_FILE=$(ls -t docs/specs/active/*.md 2>/dev/null | head -1)
    if [ -z "$SPEC_FILE" ]; then
        echo -e "${RED}ERROR: No spec files found in docs/specs/active/${NC}"
        exit 1
    fi
fi

echo -e "\n╔════════════════════════════════════════════════════════════════╗"
echo -e "║  ${BLUE}Spec Validation${NC}                                               ║"
echo -e "╚════════════════════════════════════════════════════════════════╝"
echo -e "\n📄 Validating: ${BLUE}$SPEC_FILE${NC}"

# CHECK 1: Required Sections
print_header "1. Required Sections"

for section in "## Summary" "## Motivation" "## Design"; do
    if grep -q "^$section" "$SPEC_FILE"; then
        print_success "Found: $section"
    else
        print_error "Missing: $section"
    fi
done

# CHECK 2: Unresolved Clarifications
print_header "2. Clarification Markers"

UNRESOLVED=$(grep -c '\[NEEDS CLARIFICATION:' "$SPEC_FILE" 2>/dev/null | head -1 || echo "0")
UNRESOLVED=${UNRESOLVED:-0}
if [ "$UNRESOLVED" -gt 0 ] 2>/dev/null; then
    print_error "Found $UNRESOLVED unresolved [NEEDS CLARIFICATION] marker(s)"
else
    print_success "No unresolved clarification markers"
fi

# CHECK 3: GitHub Issue Link
print_header "3. GitHub Issue Link"

if grep -qP 'GitHub Issue.*#\d+' "$SPEC_FILE"; then
    print_success "GitHub Issue linked"
else
    print_error "No GitHub Issue link found"
fi

# CHECK 4: Constitution Reference
print_header "4. Constitution Compliance"

if grep -q 'constitution.md' "$SPEC_FILE"; then
    print_success "Constitution reference found"
else
    print_warning "No constitution reference in spec header"
fi

# CHECK 5: Placeholder Detection
print_header "5. Placeholder Detection"

PLACEHOLDER_FOUND=0
for placeholder in '\[Name\]' '\[Title\]' 'YYYY-MM-DD' 'SPEC-XXXX'; do
    if grep -qP "$placeholder" "$SPEC_FILE"; then
        print_warning "Found placeholder: $placeholder"
        ((PLACEHOLDER_FOUND++))
    fi
done

if [ "$PLACEHOLDER_FOUND" -eq 0 ]; then
    print_success "No unfilled placeholders found"
fi

# SUMMARY
print_header "Summary"

if [ "$ERRORS" -eq 0 ] && [ "$WARNINGS" -eq 0 ]; then
    echo -e "\n   ${GREEN}✅ All checks passed!${NC}"
    exit 0
elif [ "$ERRORS" -eq 0 ]; then
    echo -e "\n   ${YELLOW}⚠️  $WARNINGS warning(s), 0 errors${NC}"
    exit 0
else
    echo -e "\n   ${RED}❌ $ERRORS error(s), $WARNINGS warning(s)${NC}"
    exit 1
fi
