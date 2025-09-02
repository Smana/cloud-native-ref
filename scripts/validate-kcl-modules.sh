#!/bin/bash
set -euo pipefail

# Script to validate KCL modules locally before pushing
# Usage: ./validate-kcl-modules.sh [MODULE_NAME]

MODULE_NAME="${1:-}"
KCL_MODULES_PATH="infrastructure/base/crossplane/configuration/kcl"

if [[ -n "$MODULE_NAME" ]]; then
    MODULES=("$MODULE_NAME")
else
    # Find all KCL modules
    mapfile -t MODULES < <(find "$KCL_MODULES_PATH" -name "kcl.mod" -exec dirname {} \; -print0 | xargs -0 -I {} basename {})
fi

echo "🔍 Validating KCL modules: ${MODULES[*]}"
echo

# Check if KCL is installed
if ! command -v kcl &> /dev/null; then
    echo "❌ KCL CLI is not installed. Please install it first:"
    echo "   curl -fsSL https://kcl-lang.io/script/install-kcl.sh | /bin/bash"
    exit 1
fi

# Function to validate a single module
validate_module() {
    local module=$1
    local module_path="$KCL_MODULES_PATH/$module"

    if [[ ! -d "$module_path" ]]; then
        echo "❌ Module directory not found: $module_path"
        return 1
    fi

    if [[ ! -f "$module_path/kcl.mod" ]]; then
        echo "❌ kcl.mod not found in: $module_path"
        return 1
    fi

    echo "📦 Validating module: $module"
    cd "$module_path"

    # Extract module info
    local version
    local name
    version=$(grep "^version" kcl.mod | sed 's/version = "\(.*\)"/\1/' | tr -d '"')
    name=$(grep "^name" kcl.mod | sed 's/name = "\(.*\)"/\1/' | tr -d '"')

    echo "   Name: $name"
    echo "   Version: $version"

    # Check format (simplified - just ensure kcl fmt runs without error)
    echo -n "   Format check: "
    if kcl fmt . > /dev/null 2>&1; then
        echo "✅"
    else
        echo "❌ Code formatting failed"
        return 1
    fi

    # Check linting
    echo -n "   Lint check: "
    if kcl lint . > /dev/null 2>&1; then
        echo "✅"
    else
        echo "⚠️ Lint warnings found:"
        kcl lint . || true
    fi

    # Run tests if they exist
    echo -n "   Test execution: "
    if find . -name "*_test.k" | grep -q .; then
        if kcl test . > /dev/null 2>&1; then
            echo "✅"
        else
            echo "❌ Tests failed"
            kcl test . || true
            return 1
        fi
    else
        echo "ℹ️ No test files found"
    fi

    # Validate configuration (skip for Crossplane function modules that need parameters)
    echo -n "   Configuration validation: "
    if grep -q "option(\"params\")" ./*.k 2>/dev/null; then
        echo "⏭️ Skipped (Crossplane function module - requires runtime parameters)"
    else
        local temp_output="/tmp/kcl-validation-$module.yaml"
        if kcl run . --output "$temp_output" > /dev/null 2>&1; then
            echo "✅"
            rm -f "$temp_output"
        else
            echo "❌ Configuration validation failed"
            kcl run . --output "$temp_output" || true
            return 1
        fi
    fi

    cd - > /dev/null
    echo "✅ Module $module validation complete"
    echo
}

# Validate all modules
failed_modules=()
for module in "${MODULES[@]}"; do
    if ! validate_module "$module"; then
        failed_modules+=("$module")
    fi
done

# Summary
echo "📊 Validation Summary"
echo "=================="
echo "Total modules: ${#MODULES[@]}"
echo "Passed: $((${#MODULES[@]} - ${#failed_modules[@]}))"
echo "Failed: ${#failed_modules[@]}"

if [[ ${#failed_modules[@]} -gt 0 ]]; then
    echo
    echo "❌ Failed modules: ${failed_modules[*]}"
    exit 1
else
    echo
    echo "✅ All modules passed validation!"
fi
