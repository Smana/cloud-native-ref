#!/usr/bin/env bash

# =============================================================================
# Image Gallery v1.6.0 - wrk-based Observability Benchmark Suite
# =============================================================================
#
# Professional benchmarking suite using wrk to generate high-volume traffic
# for observability demonstrations (traces, metrics, logs, exemplars).
#
# Features:
# - High-throughput load testing with realistic concurrency
# - Multiple workload scenarios (read-heavy, write-heavy, mixed, errors, tracing)
# - Lua scripts for complex request patterns (uploads, dynamic data)
# - Comprehensive latency statistics and percentiles
# - Optimized for VictoriaMetrics, VictoriaTraces, and VictoriaLogs
#
# Usage:
#   ./benchmark-image-gallery.sh [OPTIONS]
#
# Options:
#   -u, --url URL           Base URL (default: http://xplane-image-gallery.apps:8080)
#   -s, --scenario NAME     Scenario: quick|standard|trace|stress|custom|all (default: standard)
#   -i, --intensity LEVEL   Intensity: minimal|light|moderate|aggressive|extreme (default: moderate)
#   -c, --connections NUM   Concurrent connections (overrides intensity default)
#   -d, --duration TIME     Duration (e.g., 30s, 2m, 1h) (overrides intensity default)
#   -t, --threads NUM       Worker threads (overrides intensity default)
#   -w, --workload TYPE     Workload: read|write|mixed|upload|error|db-trace (for custom scenario)
#   -v, --verbose           Show wrk command details
#   -h, --help              Show this help message
#
# Intensity Levels:
#   minimal     - Ultra-light: 2 connections, 1 thread, shortest durations (for OOM-prone scenarios)
#   light       - Demo-friendly: 5 connections, 2 threads, shorter durations
#   moderate    - Standard testing: 20 connections, 4 threads (default)
#   aggressive  - Stress testing: 50 connections, 8 threads, longer durations
#   extreme     - Load testing: 100 connections, 12 threads, extended durations
#
# Scenarios:
#   quick      - 30s mixed workload, 20 connections (quick demo)
#   standard   - 2min comprehensive test, 50 connections (default)
#   trace      - 90s trace-focused (uploads + db-tracing), 30 connections
#   stress     - 5min sustained load, 100 connections
#   custom     - Use --workload, --connections, --duration to customize
#   all        - Run all predefined scenarios sequentially
#
# Workloads (for custom scenario):
#   read       - Read-heavy (70% reads across various endpoints)
#   write      - Write-heavy (70% uploads, 30% settings updates)
#   mixed      - Realistic mix (70% reads, 20% writes, 10% errors)
#   upload     - Pure upload testing with multipart/form-data
#   error      - Error generation (404s, 500s, validation errors)
#   db-trace   - Database tracing scenarios (normal, error, slow)
#
# Examples:
#   # Quick demo from within cluster
#   kubectl run -n apps benchmark --image=williamyeh/wrk --rm -it --command -- \
#     sh -c "curl -sL https://raw.githubusercontent.com/.../benchmark-image-gallery.sh | sh -s -- --scenario quick"
#
#   # Standard observability benchmark (default)
#   ./benchmark-image-gallery.sh
#
#   # Trace-focused for demo
#   ./benchmark-image-gallery.sh --scenario trace
#
#   # Custom 5-minute read-heavy test with 80 connections
#   ./benchmark-image-gallery.sh --scenario custom --workload read -c 80 -d 5m
#
#   # Via Tailscale
#   ./benchmark-image-gallery.sh --url https://image-gallery.priv.cloud.ogenki.io
#
# =============================================================================

set -euo pipefail

# -----------------------------------------------------------------------------
# Configuration
# -----------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LUA_DIR="${SCRIPT_DIR}/wrk-lua"

# Defaults
BASE_URL="${BASE_URL:-http://xplane-image-gallery.apps:8080}"
SCENARIO="standard"
INTENSITY="moderate"
CONNECTIONS=""
DURATION=""
THREADS=""
WORKLOAD=""
VERBOSE=false

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

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

print_header() {
    echo ""
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  $*${NC}"
    echo -e "${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
}

print_section() {
    echo ""
    echo -e "${CYAN}┌────────────────────────────────────────────────────────────────┐${NC}"
    echo -e "${CYAN}│${NC} $*"
    echo -e "${CYAN}└────────────────────────────────────────────────────────────────┘${NC}"
}

show_help() {
    grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# \?//'
    exit 0
}

# Parse arguments
parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            -u|--url)
                BASE_URL="$2"
                shift 2
                ;;
            -s|--scenario)
                SCENARIO="$2"
                shift 2
                ;;
            -i|--intensity)
                INTENSITY="$2"
                shift 2
                ;;
            -c|--connections)
                CONNECTIONS="$2"
                shift 2
                ;;
            -d|--duration)
                DURATION="$2"
                shift 2
                ;;
            -t|--threads)
                THREADS="$2"
                shift 2
                ;;
            -w|--workload)
                WORKLOAD="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                show_help
                ;;
            *)
                log_error "Unknown option: $1"
                echo "Use -h or --help for usage information"
                exit 1
                ;;
        esac
    done
}

# Configure intensity levels
configure_intensity() {
    case "$INTENSITY" in
        minimal)
            INTENSITY_CONNECTIONS=2
            INTENSITY_THREADS=1
            INTENSITY_DURATION_MULTIPLIER=0.3
            ;;
        light)
            INTENSITY_CONNECTIONS=5
            INTENSITY_THREADS=2
            INTENSITY_DURATION_MULTIPLIER=0.5
            ;;
        moderate)
            INTENSITY_CONNECTIONS=20
            INTENSITY_THREADS=4
            INTENSITY_DURATION_MULTIPLIER=1.0
            ;;
        aggressive)
            INTENSITY_CONNECTIONS=50
            INTENSITY_THREADS=8
            INTENSITY_DURATION_MULTIPLIER=1.5
            ;;
        extreme)
            INTENSITY_CONNECTIONS=100
            INTENSITY_THREADS=12
            INTENSITY_DURATION_MULTIPLIER=2.0
            ;;
        *)
            log_error "Unknown intensity level: ${INTENSITY}"
            echo "Valid intensity levels: minimal, light, moderate, aggressive, extreme"
            exit 1
            ;;
    esac

    # Apply intensity defaults if not explicitly set
    if [[ -z "$CONNECTIONS" ]]; then
        CONNECTIONS=$INTENSITY_CONNECTIONS
    fi
    if [[ -z "$THREADS" ]]; then
        THREADS=$INTENSITY_THREADS
    fi
}

# Check prerequisites
check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check wrk
    if ! command -v wrk &> /dev/null; then
        log_error "wrk is not installed!"
        echo ""
        echo "Please install wrk:"
        echo "  • Arch Linux:   yay -S wrk  or  sudo pacman -S wrk"
        echo "  • Ubuntu/Debian: sudo apt-get install wrk"
        echo "  • macOS:        brew install wrk"
        echo "  • From source:  git clone https://github.com/wg/wrk && cd wrk && make"
        echo ""
        exit 1
    fi
    log_success "wrk $(wrk --version 2>&1 | head -1 | awk '{print $2}') found"

    # Check Lua scripts
    if [[ ! -d "$LUA_DIR" ]]; then
        log_error "Lua scripts directory not found: $LUA_DIR"
        exit 1
    fi

    local required_scripts=("read-heavy.lua" "write-heavy.lua" "mixed-workload.lua" "upload.lua" "error-generator.lua" "db-tracing.lua")
    for script in "${required_scripts[@]}"; do
        if [[ ! -f "$LUA_DIR/$script" ]]; then
            log_error "Missing Lua script: $LUA_DIR/$script"
            exit 1
        fi
    done
    log_success "All Lua scripts found"

    # Test connectivity
    log_info "Testing connectivity to ${BASE_URL}..."
    if curl -sf --max-time 5 "${BASE_URL}/healthz" > /dev/null 2>&1; then
        log_success "Successfully connected to image-gallery service"
    else
        log_error "Failed to connect to ${BASE_URL}"
        log_warning "Please check:"
        echo "  1. Service is running: kubectl get pods -n apps | grep image-gallery"
        echo "  2. URL is correct (cluster: http://xplane-image-gallery.apps:8080)"
        echo "  3. Port forwarding if local: kubectl port-forward -n apps svc/xplane-image-gallery 8080:8080"
        echo "  4. Tailscale connectivity if using private domain"
        exit 1
    fi
}

# Run wrk benchmark
run_wrk() {
    local workload_name="$1"
    local lua_script="$2"
    local connections="$3"
    local duration="$4"
    local threads="$5"
    local description="$6"

    print_section "${workload_name}"
    log_info "${description}"
    echo ""

    local cmd="wrk -c ${connections} -t ${threads} -d ${duration} --latency"

    if [[ -n "$lua_script" ]]; then
        cmd="${cmd} -s ${LUA_DIR}/${lua_script}"
    fi

    cmd="${cmd} ${BASE_URL}"

    if [[ "$VERBOSE" == "true" ]]; then
        log_info "Command: ${cmd}"
        echo ""
    fi

    log_info "Running benchmark..."
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    eval "$cmd"

    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    log_success "Benchmark completed"

    # Cool down between benchmarks
    if [[ "$SCENARIO" == "all" ]]; then
        log_info "Cooling down for 5 seconds..."
        sleep 5
    fi
}

# -----------------------------------------------------------------------------
# Scenario Definitions
# -----------------------------------------------------------------------------

run_quick_scenario() {
    print_header "Quick Demo Scenario (30s)"
    log_info "Perfect for quick observability demonstrations"
    run_wrk "Mixed Workload" "mixed-workload.lua" $CONNECTIONS 30s $THREADS "70% reads, 20% writes, 10% errors"
}

run_standard_scenario() {
    print_header "Standard Observability Scenario (2 minutes)"
    log_info "Comprehensive test covering all major endpoints"

    local phase1_conn=$((CONNECTIONS * 2))
    local phase2_conn=$((CONNECTIONS * 2))
    local phase3_conn=$CONNECTIONS

    run_wrk "Read-Heavy Phase" "read-heavy.lua" $phase1_conn 40s $THREADS "Focused on GET endpoints and queries"
    run_wrk "Mixed Workload Phase" "mixed-workload.lua" $phase2_conn 60s $THREADS "Realistic user behavior mix"
    run_wrk "Database Tracing Phase" "db-tracing.lua" $phase3_conn 20s $THREADS "Full-stack trace demonstration"
}

run_trace_scenario() {
    print_header "Trace-Focused Scenario (90s)"
    log_info "Optimized for generating rich trace data"

    # Scale connection increments based on intensity to avoid OOMKills
    # minimal: keep connections flat (2/2/2) to prevent memory spikes
    # light+: add incremental load per phase
    local db_conn_increment=10
    local mixed_conn_increment=5

    if [[ "$INTENSITY" == "minimal" ]]; then
        db_conn_increment=0
        mixed_conn_increment=0
        log_info "Minimal intensity: using flat $CONNECTIONS connections across all phases to prevent OOMKills"
    fi

    run_wrk "Upload Tracing" "upload.lua" $CONNECTIONS 30s $THREADS "Multi-span traces with file processing"
    run_wrk "Database Tracing" "db-tracing.lua" $((CONNECTIONS + db_conn_increment)) 40s $THREADS "DB spans with error and slow scenarios"
    run_wrk "Mixed Tracing" "mixed-workload.lua" $((CONNECTIONS + mixed_conn_increment)) 20s $THREADS "End-to-end request traces"
}

run_stress_scenario() {
    print_header "Stress Test Scenario (5 minutes)"
    log_info "High-load sustained test for performance validation"

    local warmup_conn=$((CONNECTIONS * 2))
    local sustained_conn=$((CONNECTIONS * 4))
    local cooldown_conn=$CONNECTIONS

    run_wrk "Warm-up Phase" "read-heavy.lua" $warmup_conn 30s $THREADS "Warming up caches and connections"
    run_wrk "Sustained Load Phase" "mixed-workload.lua" $sustained_conn 4m $((THREADS * 2)) "High-concurrency realistic workload"
    run_wrk "Cool-down Phase" "read-heavy.lua" $cooldown_conn 30s $THREADS "Monitoring recovery behavior"
}

run_custom_scenario() {
    if [[ -z "$WORKLOAD" ]]; then
        log_error "Custom scenario requires --workload option"
        echo "Available workloads: read, write, mixed, upload, error, db-trace"
        exit 1
    fi

    local connections="${CONNECTIONS:-50}"
    local duration="${DURATION:-60s}"

    print_header "Custom Scenario: ${WORKLOAD}"

    case "$WORKLOAD" in
        read)
            run_wrk "Read-Heavy Workload" "read-heavy.lua" "$connections" "$duration" "$THREADS" \
                "Custom read-heavy test with ${connections} connections for ${duration}"
            ;;
        write)
            run_wrk "Write-Heavy Workload" "write-heavy.lua" "$connections" "$duration" "$THREADS" \
                "Custom write-heavy test with ${connections} connections for ${duration}"
            ;;
        mixed)
            run_wrk "Mixed Workload" "mixed-workload.lua" "$connections" "$duration" "$THREADS" \
                "Custom mixed workload with ${connections} connections for ${duration}"
            ;;
        upload)
            run_wrk "Upload Workload" "upload.lua" "$connections" "$duration" "$THREADS" \
                "Custom upload test with ${connections} connections for ${duration}"
            ;;
        error)
            run_wrk "Error Generation" "error-generator.lua" "$connections" "$duration" "$THREADS" \
                "Custom error generation with ${connections} connections for ${duration}"
            ;;
        db-trace)
            run_wrk "Database Tracing" "db-tracing.lua" "$connections" "$duration" "$THREADS" \
                "Custom DB tracing with ${connections} connections for ${duration}"
            ;;
        *)
            log_error "Unknown workload: ${WORKLOAD}"
            echo "Available workloads: read, write, mixed, upload, error, db-trace"
            exit 1
            ;;
    esac
}

run_all_scenarios() {
    print_header "Running ALL Scenarios"
    log_warning "This will take approximately 10 minutes"
    echo ""

    run_quick_scenario
    run_standard_scenario
    run_trace_scenario

    log_warning "Skipping stress test in 'all' mode (add --scenario stress to run separately)"
}

# Print observability tips
print_observability_tips() {
    print_header "Observability Dashboard Links"

    echo -e "${CYAN}📊 VictoriaMetrics${NC}"
    echo "   • HTTP Metrics Dashboard"
    echo "   • Request rates, error rates, latency percentiles"
    echo "   • Click 💎 exemplar dots to jump to traces"
    echo ""

    echo -e "${MAGENTA}🔍 VictoriaTraces${NC}"
    echo "   • Search for high-latency traces"
    echo "   • Filter by endpoint: /api/images, /api/test-db"
    echo "   • Examine error spans and failure propagation"
    echo "   • Compare normal vs slow DB query spans"
    echo ""

    echo -e "${BLUE}📋 VictoriaLogs${NC}"
    echo "   • Error logs with trace correlation:"
    echo '     {kubernetes.container_name="xplane-image-gallery"} | unpack_json | log.level:error'
    echo "   • Logs with trace IDs:"
    echo '     {kubernetes.container_name="xplane-image-gallery"} | unpack_json | log.trace_id:*'
    echo ""

    echo -e "${GREEN}💡 Tips${NC}"
    echo "   • Exemplars link metrics to traces - click the diamond dots!"
    echo "   • Look for trace_id in logs to correlate with traces"
    echo "   • Check upload spans for multi-file processing"
    echo "   • DB tracing shows full stack: HTTP → App → PostgreSQL"
    echo ""
}

# -----------------------------------------------------------------------------
# Main Execution
# -----------------------------------------------------------------------------

main() {
    parse_args "$@"
    configure_intensity

    print_header "🚀 Image Gallery v1.6.0 - wrk Benchmark Suite"

    log_info "Configuration:"
    echo -e "  ${BOLD}Base URL:${NC}        ${BASE_URL}"
    echo -e "  ${BOLD}Scenario:${NC}        ${SCENARIO}"
    echo -e "  ${BOLD}Intensity:${NC}       ${INTENSITY}"
    if [[ "$SCENARIO" == "custom" ]]; then
        echo -e "  ${BOLD}Workload:${NC}        ${WORKLOAD}"
    fi
    echo -e "  ${BOLD}Connections:${NC}     ${CONNECTIONS}"
    echo -e "  ${BOLD}Threads:${NC}         ${THREADS}"
    echo -e "  ${BOLD}Lua Scripts:${NC}     ${LUA_DIR}"
    echo ""

    check_prerequisites

    local start_time
    start_time=$(date +%s)

    case "$SCENARIO" in
        quick)
            run_quick_scenario
            ;;
        standard)
            run_standard_scenario
            ;;
        trace)
            run_trace_scenario
            ;;
        stress)
            run_stress_scenario
            ;;
        custom)
            run_custom_scenario
            ;;
        all)
            run_all_scenarios
            ;;
        *)
            log_error "Unknown scenario: ${SCENARIO}"
            echo "Valid scenarios: quick, standard, trace, stress, custom, all"
            exit 1
            ;;
    esac

    local end_time
    end_time=$(date +%s)
    local total_duration=$((end_time - start_time))

    print_header "✨ Benchmark Suite Complete"
    log_success "Total execution time: ${total_duration}s"
    echo ""

    print_observability_tips
}

main "$@"
