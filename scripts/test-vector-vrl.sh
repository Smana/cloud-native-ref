#!/bin/bash
set -euo pipefail

# ============================================================================
# Vector VRL Configuration Test Script
# ============================================================================
# Purpose: Test Vector VRL configuration locally without deploying to cluster
# Usage:
#   ./scripts/test-vector-vrl.sh                    # Run all tests
#   ./scripts/test-vector-vrl.sh --validate-only    # Only validate syntax
#   ./scripts/test-vector-vrl.sh --test-only        # Only run unit tests
# ============================================================================

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m' # No Color

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
CONFIG_FILE="${PROJECT_ROOT}/observability/base/victoria-logs/helmrelease-vlsingle.yaml"
TEMP_DIR=$(mktemp -d)
VECTOR_CONFIG="${TEMP_DIR}/vector-config.yaml"

# Cleanup function
cleanup() {
    rm -rf "${TEMP_DIR}"
}
trap cleanup EXIT

# ============================================================================
# Functions
# ============================================================================

print_header() {
    echo -e "${BLUE}============================================================================${NC}"
    echo -e "${BLUE}$1${NC}"
    echo -e "${BLUE}============================================================================${NC}"
}

print_success() {
    echo -e "${GREEN}✅ $1${NC}"
}

print_error() {
    echo -e "${RED}❌ $1${NC}"
}

print_info() {
    echo -e "${YELLOW}ℹ️  $1${NC}"
}

check_dependencies() {
    print_header "Checking Dependencies"

    if ! command -v yq &> /dev/null; then
        print_error "yq is not installed. Please install: https://github.com/mikefarah/yq"
        exit 1
    fi
    print_success "yq is installed"

    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker to run Vector tests"
        exit 1
    fi
    print_success "Docker is installed"

    echo
}

extract_vector_config() {
    print_header "Extracting Vector Configuration"

    # Extract Vector customConfig from HelmRelease using yq
    cat > "${TEMP_DIR}/extract-script.yq" << 'EXTRACT_SCRIPT'
{
  "sources": .spec.values.vector.customConfig.sources,
  "transforms": .spec.values.vector.customConfig.transforms,
  "sinks": .spec.values.vector.customConfig.sinks,
  "tests": .spec.values.vector.customConfig.tests
}
EXTRACT_SCRIPT

    yq eval-all \
        --from-file "${TEMP_DIR}/extract-script.yq" \
        "${CONFIG_FILE}" \
        > "${VECTOR_CONFIG}"

    if [ ! -s "${VECTOR_CONFIG}" ]; then
        print_error "Failed to extract Vector configuration"
        exit 1
    fi

    print_success "Vector configuration extracted to ${VECTOR_CONFIG}"

    # Show summary
    echo
    print_info "Configuration Summary:"
    echo "  Sources:    $(yq eval '.sources | keys | join(", ")' "${VECTOR_CONFIG}")"
    echo "  Transforms: $(yq eval '.transforms | keys | join(", ")' "${VECTOR_CONFIG}")"
    echo "  Sinks:      $(yq eval '.sinks | keys | join(", ")' "${VECTOR_CONFIG}")"
    echo "  Tests:      $(yq eval '.tests | length' "${VECTOR_CONFIG}") test cases"
    echo
}

validate_config() {
    print_header "Validating Vector Configuration Syntax"

    if docker run --rm \
        -v "${VECTOR_CONFIG}:/etc/vector/vector.yaml:ro" \
        timberio/vector:latest-alpine \
        validate /etc/vector/vector.yaml --no-environment; then
        print_success "Configuration syntax is valid"
        return 0
    else
        print_error "Configuration validation failed"
        return 1
    fi
}

run_tests() {
    print_header "Running Vector Unit Tests"

    if docker run --rm \
        -v "${VECTOR_CONFIG}:/etc/vector/vector.yaml:ro" \
        timberio/vector:latest-alpine \
        test /etc/vector/vector.yaml; then
        print_success "All unit tests passed"
        return 0
    else
        print_error "Unit tests failed"
        return 1
    fi
}

show_test_details() {
    print_header "Test Coverage Details"

    echo "Test cases defined in configuration:"
    echo

    yq eval '.tests[] | "  • " + .name' "${VECTOR_CONFIG}"

    echo
    print_info "Each test validates:"
    echo "  - Input log format and structure"
    echo "  - VRL transformation logic"
    echo "  - Output field presence and values"
    echo "  - Error handling and routing"
    echo
}

create_sample_logs() {
    print_header "Creating Sample PostgreSQL Logs"

    # Create sample valid log
    cat > "${TEMP_DIR}/sample-valid.json" << 'EOF'
{
  "kubernetes": {
    "container_name": "postgres",
    "pod_labels": {
      "cnpg.io/cluster": "test-cluster"
    },
    "namespace_name": "databases",
    "pod_name": "test-cluster-1"
  },
  "message": "{\"timestamp\":\"2025-01-14 10:30:45.123 UTC\",\"record\":{\"query_id\":\"12345\",\"database_name\":\"mydb\",\"user_name\":\"appuser\",\"message\":\"duration: 150.5 ms  plan: {\\\"Query Text\\\":\\\"SELECT * FROM users WHERE id = 1\\\",\\\"Plan\\\":{\\\"Node Type\\\":\\\"Index Scan\\\",\\\"Relation Name\\\":\\\"users\\\",\\\"Index Name\\\":\\\"users_pkey\\\"},\\\"Planning Time\\\":1.234,\\\"Execution Time\\\":149.266}\"}}"
}
EOF

    # Create sample invalid log
    cat > "${TEMP_DIR}/sample-invalid.json" << 'EOF'
{
  "kubernetes": {
    "container_name": "postgres",
    "pod_labels": {
      "cnpg.io/cluster": "test-cluster"
    },
    "namespace_name": "databases",
    "pod_name": "test-cluster-1"
  },
  "message": "{\"timestamp\":\"2025-01-14 10:30:45.123 UTC\",\"record\":{\"query_id\":\"11111\",\"database_name\":\"mydb\",\"user_name\":\"appuser\",\"message\":\"duration: 100.0 ms  plan: {INVALID JSON}\"}}"
}
EOF

    print_success "Sample logs created in ${TEMP_DIR}"
    echo "  - sample-valid.json: Valid PostgreSQL auto_explain log"
    echo "  - sample-invalid.json: Invalid JSON (should be routed to failures)"
    echo
}

# ============================================================================
# Main
# ============================================================================

MODE="${1:-all}"

case "${MODE}" in
    --validate-only)
        check_dependencies
        extract_vector_config
        validate_config
        ;;

    --test-only)
        check_dependencies
        extract_vector_config
        run_tests
        ;;

    --show-tests)
        check_dependencies
        extract_vector_config
        show_test_details
        ;;

    --create-samples)
        create_sample_logs
        print_info "Use these samples for manual testing in VRL playground:"
        echo "  https://playground.vrl.dev/"
        ;;

    *)
        # Run all checks
        check_dependencies
        extract_vector_config

        VALIDATION_OK=false
        TESTS_OK=false

        if validate_config; then
            VALIDATION_OK=true
        fi

        echo

        if run_tests; then
            TESTS_OK=true
        fi

        echo
        show_test_details

        # Final summary
        print_header "Summary"
        if ${VALIDATION_OK}; then
            print_success "Syntax validation: PASSED"
        else
            print_error "Syntax validation: FAILED"
        fi

        if ${TESTS_OK}; then
            print_success "Unit tests: PASSED"
        else
            print_error "Unit tests: FAILED"
        fi

        echo

        if ${VALIDATION_OK} && ${TESTS_OK}; then
            print_success "All checks passed! Vector configuration is ready."
            exit 0
        else
            print_error "Some checks failed. Please review the errors above."
            exit 1
        fi
        ;;
esac
