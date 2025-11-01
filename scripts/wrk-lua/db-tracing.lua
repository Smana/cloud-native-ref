-- db-tracing.lua
-- Focuses on database tracing scenarios
-- Perfect for demonstrating full-stack trace propagation

local scenarios = {
    -- Normal database queries (85%) - Increased for safer benchmarking
    {path = "/api/test-db?scenario=normal", weight = 85, description = "Normal DB query"},

    -- Error scenarios (10%) - Reduced from 20% to avoid overwhelming the app
    {path = "/api/test-db?scenario=error", weight = 10, description = "DB error simulation"},

    -- Slow queries (5%) - Reduced from 10% to minimize resource exhaustion
    {path = "/api/test-db?scenario=slow", weight = 5, description = "Slow DB query"},
}

local total_weight = 85 + 10 + 5

-- Statistics tracking
local stats = {
    normal = 0,
    error = 0,
    slow = 0,
    total = 0
}

function select_scenario()
    local rand = math.random(1, total_weight)

    if rand <= 85 then
        stats.normal = stats.normal + 1
        return scenarios[1]
    elseif rand <= 95 then
        stats.error = stats.error + 1
        return scenarios[2]
    else
        stats.slow = stats.slow + 1
        return scenarios[3]
    end
end

request = function()
    stats.total = stats.total + 1
    local scenario = select_scenario()
    return wrk.format("GET", scenario.path)
end

done = function(summary, latency, requests)
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Database Tracing Benchmark Summary\n")
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write(string.format("Total Requests:     %d\n", summary.requests))
    io.write(string.format("Duration:           %.2fs\n", summary.duration / 1000000))
    io.write(string.format("Throughput:         %.2f req/sec\n", summary.requests / (summary.duration / 1000000)))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Scenario Distribution:\n")
    io.write(string.format("  Normal Queries:   %d (%.1f%%)\n", stats.normal, stats.normal * 100 / summary.requests))
    io.write(string.format("  Error Queries:    %d (%.1f%%)\n", stats.error, stats.error * 100 / summary.requests))
    io.write(string.format("  Slow Queries:     %d (%.1f%%)\n", stats.slow, stats.slow * 100 / summary.requests))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Response Statistics:\n")
    local total_errors = summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout
    io.write(string.format("  Successful:       %d\n", summary.requests - total_errors))
    io.write(string.format("  Errors:           %d\n", total_errors))
    if total_errors > 0 then
        io.write(string.format("    Connect:        %d\n", summary.errors.connect))
        io.write(string.format("    Read:           %d\n", summary.errors.read))
        io.write(string.format("    Write:          %d\n", summary.errors.write))
        io.write(string.format("    Status:         %d\n", summary.errors.status))
        io.write(string.format("    Timeout:        %d\n", summary.errors.timeout))
    end
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Latency Distribution:\n")
    io.write(string.format("  Min:              %.2fms\n", latency.min / 1000))
    io.write(string.format("  Avg:              %.2fms\n", latency.mean / 1000))
    io.write(string.format("  Median (50th):    %.2fms\n", latency:percentile(50) / 1000))
    io.write(string.format("  90th percentile:  %.2fms\n", latency:percentile(90) / 1000))
    io.write(string.format("  95th percentile:  %.2fms\n", latency:percentile(95) / 1000))
    io.write(string.format("  99th percentile:  %.2fms\n", latency:percentile(99) / 1000))
    io.write(string.format("  Max:              %.2fms\n", latency.max / 1000))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("\n📊 Observability Tips:\n")
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("🔍 VictoriaTraces:\n")
    io.write("   • Search for traces with 'test-db' endpoint\n")
    io.write("   • Compare normal vs slow query spans\n")
    io.write("   • Examine error traces for failure propagation\n")
    io.write("   • Look for database span attributes\n")
    io.write("\n📋 VictoriaLogs:\n")
    io.write('   • Error logs: {kubernetes.container_name="xplane-image-gallery"}\n')
    io.write('     | unpack_json | log.level:error\n')
    io.write('   • With trace context: add | log.trace_id:*\n')
    io.write("\n📈 VictoriaMetrics:\n")
    io.write("   • http.server.request.count - Request rates by endpoint\n")
    io.write("   • http.server.request.duration - Latency histograms\n")
    io.write("   • Click exemplar dots to jump to traces!\n")
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
end
