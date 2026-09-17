#!/usr/bin/env bash
set -euo pipefail

# Vector VRL Configuration Validator
# Tests Vector VRL transformations locally before deployment
# Usage: ./scripts/validate-vector-vrl.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VRL_DIR="${SCRIPT_DIR}/vector-vrl-tests"
DOCKER_IMAGE="timberio/vector:latest-alpine"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
TOTAL_TESTS=0
PASSED_TESTS=0
FAILED_TESTS=0

echo -e "${BLUE}╔════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Vector VRL Configuration Validation                          ║${NC}"
echo -e "${BLUE}╚════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if Docker is available
if ! command -v docker &> /dev/null; then
    echo -e "${RED}✗ Docker is not installed or not in PATH${NC}"
    echo -e "${YELLOW}  Install Docker to run VRL validation locally${NC}"
    exit 1
fi

# Check if VRL files exist
if [ ! -f "${VRL_DIR}/cnpg-auto-explain.vrl" ]; then
    echo -e "${RED}✗ VRL file not found: ${VRL_DIR}/cnpg-auto-explain.vrl${NC}"
    exit 1
fi

if [ ! -f "${VRL_DIR}/test-samples.json" ]; then
    echo -e "${RED}✗ Test samples not found: ${VRL_DIR}/test-samples.json${NC}"
    exit 1
fi

echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Testing: CNPG auto_explain VRL transformation${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""

# Test 1: VRL Syntax Validation
echo -e "${YELLOW}[1/3] Validating VRL syntax...${NC}"
if echo '{"message": "test"}' | docker run --rm -i -v "${VRL_DIR}:/vrl" "${DOCKER_IMAGE}" \
    vrl --program /vrl/cnpg-auto-explain.vrl &> /tmp/vrl-syntax-check.log; then
    echo -e "${GREEN}   ✅ VRL syntax is valid${NC}"
else
    echo -e "${RED}   ✗ VRL syntax validation failed${NC}"
    cat /tmp/vrl-syntax-check.log
    exit 1
fi
echo ""

# Test 2: Run test cases
echo -e "${YELLOW}[2/3] Running test cases...${NC}"

# Extract test cases from JSON
TEST_COUNT=$(jq '.test_cases | length' "${VRL_DIR}/test-samples.json")
TOTAL_TESTS=$TEST_COUNT

for i in $(seq 0 $((TEST_COUNT - 1))); do
    TEST_NAME=$(jq -r ".test_cases[$i].name" "${VRL_DIR}/test-samples.json")
    TEST_DESC=$(jq -r ".test_cases[$i].description" "${VRL_DIR}/test-samples.json")

    echo -e "   ${BLUE}Testing:${NC} $TEST_NAME - $TEST_DESC"

    # Extract input and expected output
    INPUT=$(jq -c ".test_cases[$i].input" "${VRL_DIR}/test-samples.json")

    # Run VRL transformation
    OUTPUT=$(echo "$INPUT" | docker run --rm -i -v "${VRL_DIR}:/vrl" "${DOCKER_IMAGE}" \
        vrl --program /vrl/cnpg-auto-explain.vrl --print-object 2>&1 || true)

    # Extract JSON output (skip log lines)
    JSON_OUTPUT=$(echo "$OUTPUT" | grep -E '^\{' | head -1)

    # Check if transformation succeeded
    if echo "$JSON_OUTPUT" | grep -q '"query_id"'; then
        # Validate expected fields
        EXPECTED_QUERY_ID=$(jq -r ".test_cases[$i].expected.query_id" "${VRL_DIR}/test-samples.json")
        ACTUAL_QUERY_ID=$(echo "$JSON_OUTPUT" | jq -r '.query_id' 2>/dev/null || echo "")

        if [ "$EXPECTED_QUERY_ID" = "$ACTUAL_QUERY_ID" ]; then
            echo -e "   ${GREEN}✅ $TEST_NAME passed${NC}"
            PASSED_TESTS=$((PASSED_TESTS + 1))
        else
            echo -e "   ${RED}✗ $TEST_NAME failed - query_id mismatch${NC}"
            echo -e "      Expected: $EXPECTED_QUERY_ID"
            echo -e "      Got: $ACTUAL_QUERY_ID"
            FAILED_TESTS=$((FAILED_TESTS + 1))
        fi
    else
        echo -e "   ${RED}✗ $TEST_NAME failed - transformation error${NC}"
        echo "$OUTPUT" | grep -A 5 "error"
        FAILED_TESTS=$((FAILED_TESTS + 1))
    fi
done
echo ""

# Test 3: Validate output schema
echo -e "${YELLOW}[3/3] Validating output schema...${NC}"

REQUIRED_FIELDS=("query_id" "cluster_name" "namespace" "pod_name" "plan" "query_text")
SAMPLE_OUTPUT=$(jq -c '.test_cases[0].input' "${VRL_DIR}/test-samples.json" | \
    docker run --rm -i -v "${VRL_DIR}:/vrl" "${DOCKER_IMAGE}" \
    vrl --program /vrl/cnpg-auto-explain.vrl --print-object 2>&1 | grep -E '^\{' | head -1)

ALL_FIELDS_PRESENT=true
for field in "${REQUIRED_FIELDS[@]}"; do
    if echo "$SAMPLE_OUTPUT" | jq -e ".$field" &>/dev/null; then
        echo -e "   ${GREEN}✓${NC} Field '$field' present"
    else
        echo -e "   ${RED}✗${NC} Field '$field' missing"
        ALL_FIELDS_PRESENT=false
    fi
done

if [ "$ALL_FIELDS_PRESENT" = true ]; then
    echo -e "${GREEN}   ✅ Output schema is valid${NC}"
else
    echo -e "${RED}   ✗ Output schema validation failed${NC}"
    exit 1
fi
echo ""

# Summary
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  Test Summary${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "  Total tests: $TOTAL_TESTS"
echo -e "  ${GREEN}Passed: $PASSED_TESTS${NC}"
if [ $FAILED_TESTS -gt 0 ]; then
    echo -e "  ${RED}Failed: $FAILED_TESTS${NC}"
fi
echo ""

if [ $FAILED_TESTS -eq 0 ]; then
    echo -e "${GREEN}✅ All VRL validations passed!${NC}"
    echo ""
    echo -e "${BLUE}Next steps:${NC}"
    echo -e "  1. VRL configuration is validated and ready for deployment"
    echo -e "  2. Commit changes to trigger GitOps deployment"
    echo -e "  3. Monitor Vector pods after reconciliation"
    exit 0
else
    echo -e "${RED}✗ VRL validation failed${NC}"
    echo -e "${YELLOW}Fix the errors above before committing${NC}"
    exit 1
fi
