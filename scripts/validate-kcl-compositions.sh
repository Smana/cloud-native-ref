#!/usr/bin/env bash
# Comprehensive validation for KCL Crossplane compositions
# Run this script from the repository root
#
# For each composition, this script validates:
# 1. KCL formatting with `kcl fmt`
# 2. KCL syntax and logic with `kcl run` using settings-example.yaml
# 3. Full rendering with `crossplane render` using example files
#
# Usage: ./scripts/validate-kcl-compositions.sh

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

CONFIG_BASE="infrastructure/base/crossplane/configuration"
KCL_BASE_PATH="$CONFIG_BASE/kcl"
TOTAL_ERRORS=0
TOTAL_WARNINGS=0

# Check if Docker is running (needed for crossplane render)
check_docker() {
    if ! docker info > /dev/null 2>&1; then
        echo -e "${YELLOW}⚠️  Warning: Docker is not running. Crossplane render validation will be skipped.${NC}"
        echo "   Start Docker to enable full validation."
        return 1
    fi
    return 0
}

DOCKER_AVAILABLE=0
check_docker && DOCKER_AVAILABLE=1

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  KCL Crossplane Composition Validation                        ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# Check if we're in the repo root
if [[ ! -d "$KCL_BASE_PATH" ]]; then
    echo -e "${RED}❌ Error: Must run from repository root${NC}"
    echo "   Current directory: $(pwd)"
    echo "   Expected to find: $KCL_BASE_PATH"
    exit 1
fi

# Define compositions to validate
# Format: "module_name:composition_file:example1,example2,..."
declare -a COMPOSITIONS=(
    "app:app-composition.yaml:app-basic.yaml,app-complete.yaml"
    "cloudnativepg:sql-instance-composition.yaml:sqlinstance-basic.yaml,sqlinstance-complete.yaml"
    "eks-pod-identity:epi-composition.yaml:epi.yaml"
    "queueinstance:queueinstance-composition.yaml:queueinstance-kafka-basic.yaml,queueinstance-sqs-basic.yaml,queueinstance-complete.yaml"
)

# Validate a single composition
validate_composition() {
    local module_name=$1
    local composition_file=$2
    local examples=$3

    local module_path="$KCL_BASE_PATH/$module_name"
    local settings_file="$module_path/settings-example.yaml"
    local composition_path="$CONFIG_BASE/$composition_file"
    local functions_path="$CONFIG_BASE/functions.yaml"
    local env_config="$CONFIG_BASE/examples/environmentconfig.yaml"

    local errors=0
    local warnings=0

    echo ""
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}${BLUE}  Validating: $module_name${NC}"
    echo -e "${BOLD}${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    # Check if module exists
    if [[ ! -d "$module_path" ]]; then
        echo -e "${RED}❌ Module directory not found: $module_path${NC}"
        return 1
    fi

    # ========================================================================
    # Step 1: KCL Format Check
    # ========================================================================
    echo ""
    echo -e "${YELLOW}📝 [1/3] Checking KCL formatting...${NC}"

    cd "$module_path"
    kcl fmt . > /dev/null 2>&1

    if ! git diff --quiet .; then
        echo -e "${RED}   ❌ Code was reformatted${NC}"
        git diff --stat .
        errors=$((errors + 1))
    else
        echo -e "${GREEN}   ✅ Formatting is correct${NC}"
    fi
    cd - > /dev/null

    # ========================================================================
    # Step 2: KCL Syntax and Logic Check
    # ========================================================================
    echo ""
    echo -e "${YELLOW}🧪 [2/3] Validating KCL syntax and logic...${NC}"

    if [[ ! -f "$settings_file" ]]; then
        echo -e "${YELLOW}   ⚠️  Settings file not found: $settings_file${NC}"
        warnings=$((warnings + 1))
    else
        cd "$module_path"
        if kcl run . -Y settings-example.yaml > /dev/null 2>&1; then
            echo -e "${GREEN}   ✅ KCL syntax valid${NC}"
        else
            echo -e "${RED}   ❌ KCL syntax error${NC}"
            echo ""
            echo "   Running with output to show error:"
            kcl run . -Y settings-example.yaml || true
            errors=$((errors + 1))
        fi
        cd - > /dev/null
    fi

    # ========================================================================
    # Step 3: Crossplane Render Validation
    # ========================================================================
    echo ""
    echo -e "${YELLOW}🎨 [3/3] Testing crossplane render...${NC}"

    if [[ $DOCKER_AVAILABLE -eq 0 ]]; then
        echo -e "${YELLOW}   ⚠️  Skipped (Docker not running)${NC}"
        warnings=$((warnings + 1))
    else
        # Check if composition file exists
        if [[ ! -f "$composition_path" ]]; then
            echo -e "${RED}   ❌ Composition file not found: $composition_path${NC}"
            errors=$((errors + 1))
        elif [[ ! -f "$functions_path" ]]; then
            echo -e "${RED}   ❌ Functions file not found: $functions_path${NC}"
            errors=$((errors + 1))
        elif [[ ! -f "$env_config" ]]; then
            echo -e "${RED}   ❌ EnvironmentConfig not found: $env_config${NC}"
            errors=$((errors + 1))
        else
            # Test each example file
            IFS=',' read -ra EXAMPLE_ARRAY <<< "$examples"
            for example in "${EXAMPLE_ARRAY[@]}"; do
                local example_path="$CONFIG_BASE/examples/$example"

                if [[ ! -f "$example_path" ]]; then
                    echo -e "${YELLOW}   ⚠️  Example not found: $example${NC}"
                    warnings=$((warnings + 1))
                    continue
                fi

                echo -e "   Testing: ${example}"

                cd "$CONFIG_BASE"
                if crossplane render \
                    "examples/$example" \
                    "$composition_file" \
                    functions.yaml \
                    --extra-resources examples/environmentconfig.yaml \
                    > /dev/null 2>&1; then
                    echo -e "${GREEN}   ✅ ${example} renders successfully${NC}"
                else
                    echo -e "${RED}   ❌ ${example} failed to render${NC}"
                    echo ""
                    echo "   Running with output to show error:"
                    crossplane render \
                        "examples/$example" \
                        "$composition_file" \
                        functions.yaml \
                        --extra-resources examples/environmentconfig.yaml || true
                    errors=$((errors + 1))
                fi
                cd - > /dev/null
            done
        fi
    fi

    # Summary for this composition
    echo ""
    if [[ $errors -eq 0 && $warnings -eq 0 ]]; then
        echo -e "${GREEN}✅ All checks passed for $module_name${NC}"
    elif [[ $errors -eq 0 ]]; then
        echo -e "${YELLOW}⚠️  Completed with $warnings warning(s) for $module_name${NC}"
    else
        echo -e "${RED}❌ Failed with $errors error(s) and $warnings warning(s) for $module_name${NC}"
    fi

    TOTAL_ERRORS=$((TOTAL_ERRORS + errors))
    TOTAL_WARNINGS=$((TOTAL_WARNINGS + warnings))

    return $errors
}

# Main validation loop
echo "Starting validation for ${#COMPOSITIONS[@]} compositions..."

for composition_spec in "${COMPOSITIONS[@]}"; do
    IFS=':' read -r module composition examples <<< "$composition_spec"
    validate_composition "$module" "$composition" "$examples"
done

# Final summary
echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  Validation Summary                                            ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

if [[ $TOTAL_ERRORS -eq 0 && $TOTAL_WARNINGS -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}✅ SUCCESS${NC}${GREEN} - All compositions validated successfully!${NC}"
    echo ""
    exit 0
elif [[ $TOTAL_ERRORS -eq 0 ]]; then
    echo -e "${YELLOW}${BOLD}⚠️  WARNINGS${NC}${YELLOW} - Completed with $TOTAL_WARNINGS warning(s)${NC}"
    echo ""
    echo "Review warnings above. Some validations were skipped."
    exit 0
else
    echo -e "${RED}${BOLD}❌ FAILED${NC}${RED} - Found $TOTAL_ERRORS error(s) and $TOTAL_WARNINGS warning(s)${NC}"
    echo ""
    echo "Fix the errors shown above before committing."
    echo ""
    echo "Common fixes:"
    echo "  - Formatting: Review git diff and commit the changes"
    echo "  - Syntax errors: Check the KCL code in the failing module"
    echo "  - Render errors: Verify example files match the composition schema"
    exit 1
fi
