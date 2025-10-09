#!/usr/bin/env bash
# Format and validate KCL compositions before committing
# Run this script from the repository root
#
# Usage: ./scripts/validate-kcl-compositions.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

KCL_BASE_PATH="infrastructure/base/crossplane/configuration/kcl"
ERRORS=0

echo "🔍 Validating KCL compositions..."

# Check if we're in the repo root
if [[ ! -d "$KCL_BASE_PATH" ]]; then
    echo -e "${RED}❌ Error: Must run from repository root${NC}"
    exit 1
fi

# Format all KCL modules
for module in "$KCL_BASE_PATH"/*; do
    if [[ -d "$module" && -f "$module/main.k" ]]; then
        module_name=$(basename "$module")
        echo ""
        echo -e "${YELLOW}📝 Formatting module: ${module_name}${NC}"

        cd "$module"
        kcl fmt .

        # Check if formatting made changes
        if ! git diff --quiet .; then
            echo -e "${RED}❌ Code was reformatted. Review and stage changes:${NC}"
            git diff --stat .
            echo ""
            echo "Run: git add . && git commit --amend --no-edit"
            ERRORS=$((ERRORS + 1))
        else
            echo -e "${GREEN}✅ Formatting is correct${NC}"
        fi

        cd - > /dev/null
    fi
done

echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo -e "${GREEN}✅ All KCL modules are properly formatted${NC}"
    exit 0
else
    echo -e "${RED}❌ Found $ERRORS module(s) with formatting issues.${NC}"
    echo "The files have been automatically formatted. Review and commit the changes."
    exit 1
fi
