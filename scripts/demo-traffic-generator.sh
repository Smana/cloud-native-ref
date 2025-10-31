#!/usr/bin/env bash

# =============================================================================
# Observability Demo Traffic Generator for image-gallery
# =============================================================================
#
# This script generates realistic HTTP traffic to demonstrate observability
# capabilities including metrics, traces, logs, and exemplars.
#
# Features:
# - Multiple traffic patterns (steady, burst, slow, mixed)
# - Error generation (404, 500 simulation via bad requests)
# - Trace correlation across multiple services (DB, S3, Cache)
# - Exemplar data points for metrics-to-traces linking
# - Log generation (info and error levels)
# - Colored terminal output for visibility
#
# Usage:
#   ./demo-traffic-generator.sh [OPTIONS]
#
# Options:
#   -u, --url URL           Base URL (default: http://image-gallery.apps.svc.cluster.local:8080)
#   -n, --requests NUM      Number of requests per pattern (default: 10)
#   -p, --pattern PATTERN   Traffic pattern: steady|burst|slow|errors|mixed|all (default: mixed)
#   -i, --infinite          Run continuously until interrupted
#   -d, --delay SECONDS     Delay between pattern cycles (default: 2)
#   -v, --verbose           Verbose output
#   -h, --help              Show this help message
#
# Examples:
#   # Run from within the cluster (recommended)
#   kubectl run -n apps traffic-generator --image=curlimages/curl:latest --rm -it --restart=Never \
#     -- sh -c "curl -s https://raw.githubusercontent.com/Smana/cloud-native-ref/feat_victoria_metrics/scripts/demo-traffic-generator.sh | sh -s -- --infinite"
#
#   # Run locally (requires Tailscale access)
#   ./demo-traffic-generator.sh --url https://image-gallery.priv.cloud.ogenki.io --pattern all -n 20
#
#   # Generate only errors for testing
#   ./demo-traffic-generator.sh --pattern errors -n 50
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

# Default values
BASE_URL="${BASE_URL:-http://localhost:8080}"
NUM_REQUESTS=10
TRAFFIC_PATTERN="mixed"
INFINITE_MODE=false
DELAY_BETWEEN_CYCLES=2
VERBOSE=false

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# -----------------------------------------------------------------------------
# Helper Functions
# -----------------------------------------------------------------------------

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*"
}

log_success() {
    echo -e "${GREEN}[✓]${NC} $*"
}

log_error() {
    echo -e "${RED}[✗]${NC} $*"
}

log_warning() {
    echo -e "${YELLOW}[⚠]${NC} $*"
}

log_trace() {
    echo -e "${MAGENTA}[TRACE]${NC} $*"
}

log_metric() {
    echo -e "${CYAN}[METRIC]${NC} $*"
}

print_header() {
    echo ""
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}═══════════════════════════════════════════════════════════════${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
    echo -e "${CYAN}  $*${NC}"
    echo -e "${CYAN}───────────────────────────────────────────────────────────────${NC}"
}

# Parse command line arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url)
                BASE_URL="$2"
                shift 2
                ;;
            -n|--requests)
                NUM_REQUESTS="$2"
                shift 2
                ;;
            -p|--pattern)
                TRAFFIC_PATTERN="$2"
                shift 2
                ;;
            -i|--infinite)
                INFINITE_MODE=true
                shift
                ;;
            -d|--delay)
                DELAY_BETWEEN_CYCLES="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                grep '^#' "$0" | sed 's/^# \?//'
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Make HTTP request and capture response
make_request() {
    local method="$1"
    local endpoint="$2"
    local expected_code="${3:-200}"
    local description="$4"

    local url="${BASE_URL}${endpoint}"
    local start_time=$(date +%s%N)

    # Make request and capture response
    local response
    local http_code

    if response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" 2>&1); then
        http_code=$(echo "$response" | tail -n 1)

        # Calculate duration in milliseconds
        local end_time=$(date +%s%N)
        local duration=$(( (end_time - start_time) / 1000000 ))

        # Log request details
        if [[ "$http_code" == "$expected_code" ]]; then
            log_success "${method} ${endpoint} → ${http_code} (${duration}ms) ${description}"
            if [[ "$VERBOSE" == "true" ]]; then
                echo -e "${GRAY}  Response: $(echo "$response" | head -n 1 | cut -c1-80)...${NC}"
            fi
        elif [[ "$http_code" =~ ^2[0-9]{2}$ ]]; then
            log_success "${method} ${endpoint} → ${http_code} (${duration}ms) ${description}"
        elif [[ "$http_code" =~ ^4[0-9]{2}$ ]]; then
            log_warning "${method} ${endpoint} → ${http_code} (${duration}ms) ${description}"
        else
            log_error "${method} ${endpoint} → ${http_code} (${duration}ms) ${description}"
        fi

        # Log trace info
        if [[ "$VERBOSE" == "true" ]]; then
            log_trace "Duration: ${duration}ms | Expected: ${expected_code} | Got: ${http_code}"
        fi

        return 0
    else
        log_error "${method} ${endpoint} → FAILED ${description}"
        return 1
    fi
}

# -----------------------------------------------------------------------------
# Traffic Pattern Functions
# -----------------------------------------------------------------------------

# Steady traffic pattern - Consistent request rate
generate_steady_traffic() {
    print_section "📊 Steady Traffic Pattern (${NUM_REQUESTS} requests)"
    log_info "Simulating consistent user traffic with ${NUM_REQUESTS} requests"

    for i in $(seq 1 "$NUM_REQUESTS"); do
        case $((i % 4)) in
            0) make_request GET "/healthz" 200 "[Health Check]" ;;
            1) make_request GET "/api/images" 200 "[List Images - will hit DB, S3, Cache]" ;;
            2) make_request GET "/gallery" 200 "[Gallery UI]" ;;
            3) make_request GET "/api/images" 200 "[List Images again - should hit Cache]" ;;
        esac

        sleep 0.5
    done

    log_metric "Generated ${NUM_REQUESTS} steady requests with cache hits"
}

# Burst traffic pattern - Sudden spike in traffic
generate_burst_traffic() {
    print_section "⚡ Burst Traffic Pattern (${NUM_REQUESTS} requests)"
    log_info "Simulating traffic spike (no delays between requests)"

    for i in $(seq 1 "$NUM_REQUESTS"); do
        make_request GET "/api/images" 200 "[Burst Request #${i}]" &
    done

    wait
    log_metric "Generated ${NUM_REQUESTS} concurrent burst requests"
}

# Slow traffic pattern - Requests with high latency
generate_slow_traffic() {
    print_section "🐌 Slow Traffic Pattern (${NUM_REQUESTS} requests)"
    log_info "Simulating slow requests (3 second delays)"

    for i in $(seq 1 "$NUM_REQUESTS"); do
        make_request GET "/api/images" 200 "[Slow Request #${i}]"
        sleep 3
    done

    log_metric "Generated ${NUM_REQUESTS} slow requests"
}

# Error generation pattern - Trigger various error responses
generate_error_traffic() {
    print_section "❌ Error Generation Pattern (${NUM_REQUESTS} requests)"
    log_info "Generating errors to test error handling and logging"

    local error_count=0

    for i in $(seq 1 "$NUM_REQUESTS"); do
        case $((i % 4)) in
            0)
                # 404: Request non-existent image
                make_request GET "/api/images/non-existent-image-$(date +%s).jpg" 404 "[404 Error - Image Not Found]"
                ((error_count++)) || true
                ;;
            1)
                # 404: Request non-existent endpoint
                make_request GET "/api/invalid-endpoint-$(date +%s)" 404 "[404 Error - Invalid Endpoint]"
                ((error_count++)) || true
                ;;
            2)
                # Request with invalid image ID
                make_request GET "/api/images/../etc/passwd" 404 "[404 Error - Path Traversal Attempt]"
                ((error_count++)) || true
                ;;
            3)
                # Malformed request
                make_request GET "/api/images/\$%^&*" 404 "[404 Error - Malformed Request]"
                ((error_count++)) || true
                ;;
        esac

        sleep 0.2
    done

    log_error "Generated ${error_count} error responses for testing"
    log_warning "Check VictoriaLogs for error logs and traces for failure spans"
}

# Mixed traffic pattern - Realistic combination of patterns
generate_mixed_traffic() {
    print_section "🎭 Mixed Traffic Pattern"
    log_info "Simulating realistic user behavior with mixed patterns"

    local total_requests=$((NUM_REQUESTS * 3))
    log_info "Executing ${total_requests} requests with varied patterns..."

    # Start with some health checks
    make_request GET "/healthz" 200 "[Health Check]"
    make_request GET "/readyz" 200 "[Readiness Check]"

    # Normal user flow
    print_section "Normal User Flow"
    make_request GET "/" 302 "[Home - Redirect to Gallery]"
    make_request GET "/gallery" 200 "[Gallery Page]"
    make_request GET "/api/images" 200 "[Load Images - First time]"

    # Some users viewing images
    log_info "Simulating image viewing..."
    for i in $(seq 1 "$((NUM_REQUESTS / 2))"); do
        make_request GET "/api/images" 200 "[Browse Images]"
        sleep 0.3
    done

    # Some errors from users
    log_info "Simulating user errors..."
    make_request GET "/api/images/typo-in-name.jpg" 404 "[User Typo]"
    make_request GET "/api/images/deleted-image.png" 404 "[Deleted Image]"

    # Burst of traffic
    log_info "Simulating traffic spike..."
    for i in $(seq 1 "$((NUM_REQUESTS / 3))"); do
        make_request GET "/api/images" 200 "[Spike Request]" &
    done
    wait

    # Cool down period
    log_info "Cool down period..."
    sleep 2
    make_request GET "/healthz" 200 "[Health Check]"

    log_metric "Completed mixed traffic pattern with ${total_requests} requests"
}

# Comprehensive pattern - All patterns combined
generate_all_traffic() {
    print_header "🚀 Running ALL Traffic Patterns"

    generate_steady_traffic
    sleep "$DELAY_BETWEEN_CYCLES"

    generate_burst_traffic
    sleep "$DELAY_BETWEEN_CYCLES"

    generate_error_traffic
    sleep "$DELAY_BETWEEN_CYCLES"

    generate_mixed_traffic

    log_success "Completed ALL traffic patterns"
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"

    print_header "🎯 Observability Demo Traffic Generator"

    log_info "Configuration:"
    echo -e "  ${GRAY}Base URL:${NC}          ${BASE_URL}"
    echo -e "  ${GRAY}Traffic Pattern:${NC}   ${TRAFFIC_PATTERN}"
    echo -e "  ${GRAY}Requests/Pattern:${NC}  ${NUM_REQUESTS}"
    echo -e "  ${GRAY}Infinite Mode:${NC}     ${INFINITE_MODE}"
    echo -e "  ${GRAY}Delay (cycles):${NC}    ${DELAY_BETWEEN_CYCLES}s"
    echo ""

    # Check connectivity
    log_info "Testing connectivity to ${BASE_URL}..."
    if make_request GET "/healthz" 200 "[Initial Health Check]"; then
        log_success "Successfully connected to image-gallery service"
    else
        log_error "Failed to connect to ${BASE_URL}"
        log_error "Please check:"
        echo "  1. Service is running: kubectl get pods -n apps"
        echo "  2. URL is correct (use http://xplane-image-gallery.apps:8080 from within cluster)"
        echo "  3. Network connectivity is available"
        exit 1
    fi

    # Main loop
    local cycle=1
    while true; do
        if [[ "$INFINITE_MODE" == "true" ]]; then
            print_header "🔄 Cycle ${cycle}"
        fi

        case "$TRAFFIC_PATTERN" in
            steady)
                generate_steady_traffic
                ;;
            burst)
                generate_burst_traffic
                ;;
            slow)
                generate_slow_traffic
                ;;
            errors)
                generate_error_traffic
                ;;
            mixed)
                generate_mixed_traffic
                ;;
            all)
                generate_all_traffic
                ;;
            *)
                log_error "Unknown traffic pattern: ${TRAFFIC_PATTERN}"
                log_info "Valid patterns: steady, burst, slow, errors, mixed, all"
                exit 1
                ;;
        esac

        if [[ "$INFINITE_MODE" == "false" ]]; then
            break
        fi

        log_info "Waiting ${DELAY_BETWEEN_CYCLES}s before next cycle..."
        sleep "$DELAY_BETWEEN_CYCLES"
        ((cycle++)) || true
    done

    print_header "✨ Traffic Generation Complete"
    log_info "Check your observability dashboards:"
    echo ""
    echo -e "  ${CYAN}📊 Metrics:${NC}  VictoriaMetrics - see request rates, error rates, latencies"
    echo -e "  ${MAGENTA}🔍 Traces:${NC}   VictoriaTraces - follow request flows through services"
    echo -e "  ${BLUE}📋 Logs:${NC}     VictoriaLogs - search for error logs and debug info"
    echo -e "  ${GREEN}💎 Exemplars:${NC} Click diamond dots on graphs to jump to traces"
    echo ""
    log_success "Happy observability exploration!"
}

# Run main function
main "$@"
