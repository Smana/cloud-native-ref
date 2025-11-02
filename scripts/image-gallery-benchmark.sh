#!/bin/bash
# Comprehensive Image Gallery Benchmark Script
# Replaces wrk with pure bash + curl approach for controllable, safe benchmarking
# Supports all 14 API endpoints with configurable workload patterns and error injection

set -euo pipefail

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Configuration Defaults
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

URL="${URL:-https://image-gallery.priv.cloud.ogenki.io}"
DURATION="${DURATION:-60}"
CONCURRENCY="${CONCURRENCY:-2}"  # Safe default: 2 workers
PATTERN="${PATTERN:-mixed}"
DELAY="${DELAY:-1}"  # Safe default: 1s between requests = ~2 req/s total
ERROR_4XX_RATE="${ERROR_4XX_RATE:-5}"
ERROR_5XX_RATE="${ERROR_5XX_RATE:-5}"
VERBOSE="${VERBOSE:-false}"
NAMESPACE="${NAMESPACE:-apps}"
APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=xplane-image-gallery}"

# Results directory
RESULTS_DIR="/tmp/image-gallery-bench-$$"
mkdir -p "$RESULTS_DIR"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Utility Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') | $*"
}

log_verbose() {
    if [ "$VERBOSE" = "true" ]; then
        echo "$(date '+%H:%M:%S') | $*"
    fi
}

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Comprehensive benchmark for image-gallery API with all endpoints and error injection.

OPTIONS:
    --url URL               Base URL (default: https://image-gallery.priv.cloud.ogenki.io)
    -d, --duration TIME     Test duration in seconds (default: 60)
    -c, --concurrency N     Number of parallel clients (default: 2)
    -p, --pattern PATTERN   Workload pattern (default: mixed)
                            Options: read-heavy, write-heavy, mixed, error-focus, trace-focus
    --delay SECONDS         Delay between requests per worker (default: 1)
    --error-4xx PERCENT     4xx error injection rate (default: 5)
    --error-5xx PERCENT     5xx error injection rate (default: 5)
    -v, --verbose           Show detailed request logs
    -h, --help              Show this help message

WORKLOAD PATTERNS:
    read-heavy      90% reads, 10% writes (of non-error requests)
    write-heavy     22% reads, 78% writes (of non-error requests)
    mixed           67% reads, 33% writes (of non-error requests)
    error-focus     50% reads, 50% writes (of non-error requests)
    trace-focus     44% reads, 56% writes (favors complex writes)

    Note: Error rates are controlled separately via --error-4xx and --error-5xx flags.
          These rates apply uniformly across all patterns.

IMPORTANT - OOMKILL PREVENTION:
    The image-gallery app (without OTEL span queue fix) is sensitive to request rate.
    Default settings (2 workers, 1s delay = ~2 req/s) are intentionally conservative.

    To increase load safely:
    - Start with defaults and monitor pod health
    - Gradually increase concurrency OR decrease delay
    - Watch for pod restarts (script auto-stops on OOMKills)
    - If OOMKills occur, reduce rate until OTEL fix is deployed

EXAMPLES:
    # Safe minimal test with defaults (2 workers, 1s delay = ~2 req/s)
    $0 -d 60

    # Read-heavy workload with no errors
    $0 -d 300 -c 3 --delay 2 -p read-heavy --error-4xx 0 --error-5xx 0

    # Mixed workload with higher concurrency (monitor for OOMKills!)
    $0 -d 120 -c 5 --delay 1 -p mixed --verbose

    # Error-focused pattern for observability testing
    $0 -d 120 -c 2 --delay 1 -p error-focus --error-4xx 15 --error-5xx 15

    # Trace demonstration (safe rate)
    $0 -d 180 -c 3 --delay 1 -p trace-focus

EOF
    exit 0
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Endpoint Definitions (All 14 Endpoints)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Endpoint categories:
# - READ: GET endpoints that don't modify state
# - WRITE: POST/PUT/DELETE endpoints that modify state
# - ERROR: Endpoints that can generate specific errors

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Request Generation Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Create a tiny 1x1 PNG (67 bytes) - same as wrk uses
create_test_png() {
    local file="$1"
    printf '\x89\x50\x4E\x47\x0D\x0A\x1A\x0A\x00\x00\x00\x0D\x49\x48\x44\x52\x00\x00\x00\x01\x00\x00\x00\x01\x08\x06\x00\x00\x00\x1F\x15\xC4\x89\x00\x00\x00\x0A\x49\x44\x41\x54\x78\x9C\x63\x00\x01\x00\x00\x05\x00\x01\x0D\x0A\x2D\xB4\x00\x00\x00\x00\x49\x45\x4E\x44\xAE\x42\x60\x82' > "$file"
}

# Generate random image ID for operations
# Usage: random_image_id [force_fake]
#   force_fake: if "true", always returns fake ID (for 4xx error injection)
random_image_id() {
    local force_fake="${1:-false}"

    if [ "$force_fake" = "true" ]; then
        # Generate fake ID for 404 errors
        echo "00000000-0000-0000-0000-$(printf '%012d' $RANDOM)"
    else
        # Try to use real ID from uploaded images
        if [ -f "$RESULTS_DIR/uploaded_ids.txt" ] && [ -s "$RESULTS_DIR/uploaded_ids.txt" ]; then
            shuf -n 1 "$RESULTS_DIR/uploaded_ids.txt" 2>/dev/null || echo "placeholder-id"
        else
            echo "placeholder-id"
        fi
    fi
}

# Execute HTTP request and record metrics
execute_request() {
    local method="$1"
    local endpoint="$2"
    local extra_args="${3:-}"
    local worker_id="${4:-0}"

    local start_time=$(date +%s%3N)
    local http_code
    local response_file="$RESULTS_DIR/worker_${worker_id}_response.txt"

    # Execute curl with timeout
    http_code=$(curl -s -o "$response_file" -w "%{http_code}" \
        -X "$method" \
        "$URL$endpoint" \
        --max-time 10 \
        $extra_args \
        2>/dev/null || echo "000")

    local end_time=$(date +%s%3N)
    local latency=$((end_time - start_time))

    # Record result
    echo "$http_code|$latency" >> "$RESULTS_DIR/worker_${worker_id}_results.txt"

    log_verbose "Worker $worker_id: $method $endpoint → HTTP $http_code (${latency}ms)"

    # Extract uploaded image ID if this was a successful upload
    if [ "$http_code" = "201" ] && [ "$endpoint" = "/api/images" ]; then
        # Try to extract ID from response JSON
        local image_id=$(grep -oP '"id"\s*:\s*"\K[^"]+' "$response_file" 2>/dev/null | head -1 || true)
        if [ -n "$image_id" ]; then
            echo "$image_id" >> "$RESULTS_DIR/uploaded_ids.txt"
        fi
    fi

    echo "$http_code"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Endpoint Request Functions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

request_healthz() {
    local worker_id="$1"
    execute_request "GET" "/healthz" "" "$worker_id"
}

request_readyz() {
    local worker_id="$1"
    execute_request "GET" "/readyz" "" "$worker_id"
}

request_list_images() {
    local worker_id="$1"
    local page=$((RANDOM % 3 + 1))
    local limit=$((RANDOM % 20 + 10))
    execute_request "GET" "/api/images?page=$page&limit=$limit" "" "$worker_id"
}

request_list_images_filtered() {
    local worker_id="$1"
    local tags="test,benchmark"
    execute_request "GET" "/api/images?tags=$tags&limit=20" "" "$worker_id"
}

request_get_image() {
    local worker_id="$1"
    local force_error="${2:-false}"
    local image_id=$(random_image_id "$force_error")
    execute_request "GET" "/api/images/$image_id" "" "$worker_id"
}

request_view_image() {
    local worker_id="$1"
    local force_error="${2:-false}"
    local image_id=$(random_image_id "$force_error")
    execute_request "GET" "/api/images/$image_id/view" "" "$worker_id"
}

request_get_settings() {
    local worker_id="$1"
    execute_request "GET" "/api/settings" "" "$worker_id"
}

request_get_predefined_tags() {
    local worker_id="$1"
    execute_request "GET" "/api/tags/predefined" "" "$worker_id"
}

request_test_db_normal() {
    local worker_id="$1"
    execute_request "GET" "/api/test-db?scenario=normal" "" "$worker_id"
}

request_test_db_error() {
    local worker_id="$1"
    execute_request "GET" "/api/test-db?scenario=error" "" "$worker_id"
}

request_test_db_slow() {
    local worker_id="$1"
    execute_request "GET" "/api/test-db?scenario=slow" "" "$worker_id"
}

request_upload_images() {
    local worker_id="$1"
    local num_files=$((RANDOM % 3 + 1))
    local test_file="$RESULTS_DIR/worker_${worker_id}_upload.png"

    create_test_png "$test_file"

    local curl_args="-F tags=test,benchmark,worker-$worker_id"
    for i in $(seq 1 $num_files); do
        curl_args="$curl_args -F files=@$test_file"
    done

    execute_request "POST" "/api/images" "$curl_args" "$worker_id"
}

request_update_settings() {
    local worker_id="$1"
    local json='{"traceSamplingRate":0.5,"imageSizeLimit":52428800}'
    execute_request "PUT" "/api/settings" "-H \"Content-Type: application/json\" -d '$json'" "$worker_id"
}

request_reset_settings() {
    local worker_id="$1"
    execute_request "POST" "/api/settings/reset" "" "$worker_id"
}

request_delete_image() {
    local worker_id="$1"
    local force_error="${2:-false}"
    local image_id=$(random_image_id "$force_error")
    execute_request "DELETE" "/api/images/$image_id" "" "$worker_id"
}

request_home_page() {
    local worker_id="$1"
    execute_request "GET" "/" "" "$worker_id"
}

request_gallery_page() {
    local worker_id="$1"
    execute_request "GET" "/gallery" "" "$worker_id"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Workload Pattern Definitions
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

# Select read endpoint (for non-error requests)
select_read_endpoint() {
    local rand=$((RANDOM % 100))

    if [ $rand -lt 25 ]; then
        echo "request_list_images"
    elif [ $rand -lt 45 ]; then
        echo "request_get_image"
    elif [ $rand -lt 60 ]; then
        echo "request_view_image"
    elif [ $rand -lt 75 ]; then
        echo "request_get_settings"
    elif [ $rand -lt 85 ]; then
        echo "request_list_images_filtered"
    elif [ $rand -lt 92 ]; then
        echo "request_test_db_normal"
    else
        echo "request_gallery_page"
    fi
}

# Select write endpoint (for non-error requests)
select_write_endpoint() {
    local pattern="$1"
    local rand=$((RANDOM % 100))

    case "$pattern" in
        trace-focus)
            # Favor uploads for rich traces
            if [ $rand -lt 70 ]; then
                echo "request_upload_images"
            elif [ $rand -lt 90 ]; then
                echo "request_update_settings"
            else
                echo "request_delete_image"
            fi
            ;;
        *)
            # Standard write distribution
            if [ $rand -lt 60 ]; then
                echo "request_upload_images"
            elif [ $rand -lt 85 ]; then
                echo "request_update_settings"
            else
                echo "request_delete_image"
            fi
            ;;
    esac
}

# Select error-generating endpoint (for injected errors)
# Returns endpoint name with ERROR: prefix for 4xx errors (so worker knows to pass force_error=true)
select_error_endpoint() {
    local error_type="$1"  # 4xx or 5xx
    local rand=$((RANDOM % 100))

    if [ "$error_type" = "4xx" ]; then
        # Generate 4xx errors (404 Not Found)
        # Prefix with ERROR: so worker knows to pass force_error=true
        if [ $rand -lt 50 ]; then
            echo "ERROR:request_get_image"  # 404
        elif [ $rand -lt 80 ]; then
            echo "ERROR:request_delete_image"  # 404
        else
            echo "ERROR:request_view_image"  # 404
        fi
    else
        # Generate 5xx errors (no prefix needed, these don't use random_image_id)
        if [ $rand -lt 70 ]; then
            echo "request_test_db_error"  # 500
        else
            echo "request_test_db_slow"  # May timeout or cause slowness
        fi
    fi
}

select_endpoint_for_pattern() {
    local pattern="$1"
    local rand=$((RANDOM % 100))

    # Calculate total error rate
    local total_error_rate=$((ERROR_4XX_RATE + ERROR_5XX_RATE))

    # First decide: error injection or normal request?
    if [ $rand -lt "$total_error_rate" ] && [ "$total_error_rate" -gt 0 ]; then
        # Inject error - decide which type based on ratio
        # Use 100-based range for better distribution
        local error_rand=$((RANDOM % 100))
        local threshold_4xx=$((ERROR_4XX_RATE * 100 / total_error_rate))

        if [ $error_rand -lt "$threshold_4xx" ]; then
            select_error_endpoint "4xx"
        else
            select_error_endpoint "5xx"
        fi
    else
        # Normal request - select based on pattern's read/write ratio
        # Adjust rand to 0-99 range for remaining percentage
        local adjusted_max=$((100 - total_error_rate))
        local adjusted_rand=$((RANDOM % adjusted_max))

        case "$pattern" in
            read-heavy)
                # 90% reads, 10% writes (of non-error requests)
                if [ $adjusted_rand -lt 90 ]; then
                    select_read_endpoint
                else
                    select_write_endpoint "$pattern"
                fi
                ;;

            write-heavy)
                # 22% reads, 78% writes (of non-error requests)
                if [ $adjusted_rand -lt 22 ]; then
                    select_read_endpoint
                else
                    select_write_endpoint "$pattern"
                fi
                ;;

            mixed)
                # 67% reads, 33% writes (of non-error requests)
                if [ $adjusted_rand -lt 67 ]; then
                    select_read_endpoint
                else
                    select_write_endpoint "$pattern"
                fi
                ;;

            error-focus)
                # 50% reads, 50% writes (of non-error requests)
                # Note: With default 40% error rate, actual distribution is:
                # 30% reads, 30% writes, 40% errors
                if [ $adjusted_rand -lt 50 ]; then
                    select_read_endpoint
                else
                    select_write_endpoint "$pattern"
                fi
                ;;

            trace-focus)
                # 44% reads, 56% writes (of non-error requests)
                # Favors complex writes for rich trace generation
                if [ $adjusted_rand -lt 44 ]; then
                    select_read_endpoint
                else
                    select_write_endpoint "$pattern"
                fi
                ;;

            *)
                # Default: balanced
                if [ $adjusted_rand -lt 60 ]; then
                    select_read_endpoint
                else
                    select_write_endpoint "$pattern"
                fi
                ;;
        esac
    fi
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Worker Client
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

worker_client() {
    local worker_id="$1"
    local end_time="$2"

    log "Worker $worker_id started"

    while [ $(date +%s) -lt "$end_time" ]; do
        # Select endpoint based on pattern
        local endpoint_spec=$(select_endpoint_for_pattern "$PATTERN")

        # Check if this is an error-injected request (prefixed with ERROR:)
        if [[ "$endpoint_spec" == ERROR:* ]]; then
            # Strip ERROR: prefix and call with force_error=true
            local endpoint_func="${endpoint_spec#ERROR:}"
            $endpoint_func "$worker_id" "true"
        else
            # Normal request - use endpoint_spec directly
            $endpoint_spec "$worker_id"
        fi

        # Delay between requests
        sleep "$DELAY"
    done

    log "Worker $worker_id completed"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Pod Health Monitoring
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

monitor_pod_health() {
    local check_interval=10
    local last_restart_count=0

    while true; do
        sleep "$check_interval"

        # Get current restart count
        local current_restart_count=$(kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" \
            -o jsonpath='{.items[*].status.containerStatuses[0].restartCount}' 2>/dev/null | \
            awk '{sum=0; for(i=1; i<=NF; i++) sum+=$i; print sum}')

        if [ -z "$current_restart_count" ]; then
            current_restart_count=0
        fi

        # Check if restarts increased
        if [ "$current_restart_count" -gt "$last_restart_count" ]; then
            log "⚠️  POD RESTART DETECTED! Restart count: $last_restart_count → $current_restart_count"

            # Record restart event
            echo "restart|$(date +%s)" >> "$RESULTS_DIR/pod_events.txt"

            # Get pod status
            kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" >> "$RESULTS_DIR/pod_status.txt" 2>&1

            # Check for OOMKills
            local oom_kills=$(kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL" \
                -o jsonpath='{.items[*].status.containerStatuses[*].lastState.terminated.reason}' 2>/dev/null | \
                grep -c "OOMKilled" || true)

            if [ "$oom_kills" -gt 0 ]; then
                log "🔴 OOMKILL DETECTED! Benchmark will auto-stop."
                echo "oomkill|$(date +%s)" >> "$RESULTS_DIR/pod_events.txt"

                # Signal workers to stop
                touch "$RESULTS_DIR/stop_signal"
                break
            fi

            last_restart_count="$current_restart_count"
        fi
    done
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Statistics Calculation
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

calculate_statistics() {
    log "Calculating statistics..."

    # Combine all worker results
    cat "$RESULTS_DIR"/worker_*_results.txt > "$RESULTS_DIR/all_results.txt" 2>/dev/null || true

    local total_requests=$(wc -l < "$RESULTS_DIR/all_results.txt")

    if [ "$total_requests" -eq 0 ]; then
        log "No requests completed"
        return
    fi

    # Count by status code
    local success_2xx=$(grep -c "^2" "$RESULTS_DIR/all_results.txt" || true)
    local error_4xx=$(grep -c "^4" "$RESULTS_DIR/all_results.txt" || true)
    local error_5xx=$(grep -c "^5" "$RESULTS_DIR/all_results.txt" || true)
    local error_000=$(grep -c "^000" "$RESULTS_DIR/all_results.txt" || true)

    # Extract latencies and sort
    awk -F'|' '{print $2}' "$RESULTS_DIR/all_results.txt" | sort -n > "$RESULTS_DIR/latencies.txt"

    local min_latency=$(head -1 "$RESULTS_DIR/latencies.txt")
    local max_latency=$(tail -1 "$RESULTS_DIR/latencies.txt")

    # Calculate percentiles
    local p50_line=$(awk "BEGIN {print int($total_requests * 0.50)}")
    local p90_line=$(awk "BEGIN {print int($total_requests * 0.90)}")
    local p95_line=$(awk "BEGIN {print int($total_requests * 0.95)}")
    local p99_line=$(awk "BEGIN {print int($total_requests * 0.99)}")

    local p50=$(sed -n "${p50_line}p" "$RESULTS_DIR/latencies.txt")
    local p90=$(sed -n "${p90_line}p" "$RESULTS_DIR/latencies.txt")
    local p95=$(sed -n "${p95_line}p" "$RESULTS_DIR/latencies.txt")
    local p99=$(sed -n "${p99_line}p" "$RESULTS_DIR/latencies.txt")

    # Calculate average latency
    local avg_latency=$(awk '{sum+=$1; count++} END {if(count>0) print int(sum/count); else print 0}' "$RESULTS_DIR/latencies.txt")

    # Calculate throughput
    local elapsed_time=$(($(date +%s) - START_TIME))
    local req_per_sec=$(awk "BEGIN {printf \"%.2f\", $total_requests / $elapsed_time}")

    # Check for pod events
    local restart_count=0
    local oomkill_count=0
    if [ -f "$RESULTS_DIR/pod_events.txt" ]; then
        restart_count=$(grep -c "^restart" "$RESULTS_DIR/pod_events.txt" || true)
        oomkill_count=$(grep -c "^oomkill" "$RESULTS_DIR/pod_events.txt" || true)
    fi

    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
    # Print Summary Report
    # ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Benchmark Results Summary"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Configuration:"
    echo "  URL:              $URL"
    echo "  Pattern:          $PATTERN"
    echo "  Duration:         ${DURATION}s (actual: ${elapsed_time}s)"
    echo "  Concurrency:      $CONCURRENCY workers"
    echo "  Request Delay:    ${DELAY}s"
    echo "  Error Injection:  4xx=${ERROR_4XX_RATE}%, 5xx=${ERROR_5XX_RATE}%"
    echo ""
    echo "Request Statistics:"
    echo "  Total Requests:   $total_requests"
    echo "  Throughput:       $req_per_sec req/s"
    echo "  Success (2xx):    $success_2xx ($(awk "BEGIN {printf \"%.1f\", $success_2xx*100/$total_requests}")%)"
    echo "  Client Error (4xx): $error_4xx ($(awk "BEGIN {printf \"%.1f\", $error_4xx*100/$total_requests}")%)"
    echo "  Server Error (5xx): $error_5xx ($(awk "BEGIN {printf \"%.1f\", $error_5xx*100/$total_requests}")%)"
    echo "  Timeout (000):    $error_000 ($(awk "BEGIN {printf \"%.1f\", $error_000*100/$total_requests}")%)"
    echo ""
    echo "Latency Distribution (milliseconds):"
    echo "  Min:      ${min_latency}ms"
    echo "  Average:  ${avg_latency}ms"
    echo "  p50:      ${p50}ms"
    echo "  p90:      ${p90}ms"
    echo "  p95:      ${p95}ms"
    echo "  p99:      ${p99}ms"
    echo "  Max:      ${max_latency}ms"
    echo ""

    if [ "$restart_count" -gt 0 ] || [ "$oomkill_count" -gt 0 ]; then
        echo "⚠️  Pod Health Issues:"
        echo "  Pod Restarts:     $restart_count"
        echo "  OOMKills:         $oomkill_count"
        echo ""
        if [ "$oomkill_count" -gt 0 ]; then
            echo "🔴 CRITICAL: OOMKills detected during benchmark!"
            echo "   This indicates memory pressure. Consider:"
            echo "   - Increasing pod memory limits"
            echo "   - Reducing concurrency (-c)"
            echo "   - Increasing delay (--delay)"
            echo "   - Checking OTEL span queue configuration"
            echo ""
        fi
    else
        echo "✅ Pod Health: No restarts or OOMKills detected"
        echo ""
    fi

    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "Results saved to: $RESULTS_DIR"
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# Main Execution
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case $1 in
            --url)
                URL="$2"
                shift 2
                ;;
            -d|--duration)
                DURATION="$2"
                shift 2
                ;;
            -c|--concurrency)
                CONCURRENCY="$2"
                shift 2
                ;;
            -p|--pattern)
                PATTERN="$2"
                shift 2
                ;;
            --delay)
                DELAY="$2"
                shift 2
                ;;
            --error-4xx)
                ERROR_4XX_RATE="$2"
                shift 2
                ;;
            --error-5xx)
                ERROR_5XX_RATE="$2"
                shift 2
                ;;
            -v|--verbose)
                VERBOSE="true"
                shift
                ;;
            -h|--help)
                usage
                ;;
            *)
                echo "Unknown option: $1"
                usage
                ;;
        esac
    done

    # Validate pattern
    case "$PATTERN" in
        read-heavy|write-heavy|mixed|error-focus|trace-focus)
            ;;
        *)
            echo "Invalid pattern: $PATTERN"
            echo "Valid patterns: read-heavy, write-heavy, mixed, error-focus, trace-focus"
            exit 1
            ;;
    esac

    # Print banner
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "  Image Gallery Comprehensive Benchmark"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    log "Starting benchmark with configuration:"
    log "  URL: $URL"
    log "  Pattern: $PATTERN"
    log "  Duration: ${DURATION}s"
    log "  Concurrency: $CONCURRENCY"
    log "  Delay: ${DELAY}s between requests"
    log "  Error Rates: 4xx=${ERROR_4XX_RATE}%, 5xx=${ERROR_5XX_RATE}%"
    echo ""

    # Record start time
    START_TIME=$(date +%s)
    END_TIME=$((START_TIME + DURATION))

    # Start pod health monitoring in background
    monitor_pod_health &
    MONITOR_PID=$!

    # Start worker clients
    log "Starting $CONCURRENCY worker clients..."
    declare -a WORKER_PIDS

    for i in $(seq 1 "$CONCURRENCY"); do
        worker_client "$i" "$END_TIME" &
        WORKER_PIDS+=($!)
    done

    # Wait for all workers to complete
    for pid in "${WORKER_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    log "All workers completed"

    # Stop monitoring
    kill "$MONITOR_PID" 2>/dev/null || true

    # Calculate and display statistics
    calculate_statistics

    # Final pod status
    echo "Final Pod Status:"
    kubectl get pods -n "$NAMESPACE" -l "$APP_LABEL"
    echo ""

    log "Benchmark complete!"
}

# Trap cleanup
cleanup() {
    log "Cleaning up..."
    kill $(jobs -p) 2>/dev/null || true

    # Keep results directory for analysis
    log "Results preserved in: $RESULTS_DIR"
}

trap cleanup EXIT

# Run main
main "$@"
