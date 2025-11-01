-- error-generator.lua
-- Generates various HTTP errors for testing error handling and logging
-- Useful for validating error traces, error metrics, and log aggregation

local error_scenarios = {
    -- 404 errors - Non-existent resources (60% - safer than before)
    {path = "/api/images/nonexistent-image.jpg", weight = 25, expected = 404},
    {path = "/api/images/deleted-file.png", weight = 15, expected = 404},
    {path = "/api/invalid-endpoint", weight = 10, expected = 404},
    {path = "/api/images/../../../etc/passwd", weight = 5, expected = 404}, -- Path traversal attempt
    {path = "/api/images/$%^&*()_+", weight = 5, expected = 404}, -- Malformed characters

    -- Database errors (10% - reduced from 15%)
    {path = "/api/test-db?scenario=error", weight = 10, expected = 500},

    -- Slow requests (10% - same but still limited)
    {path = "/api/test-db?scenario=slow", weight = 10, expected = 200},

    -- Invalid query parameters (15%)
    {path = "/api/images?page=-1", weight = 5, expected = 400},
    {path = "/api/images?page_size=999", weight = 5, expected = 400},
    {path = "/api/images?tags[]=", weight = 5, expected = 200}, -- Empty tag
}

-- Calculate total weight
local total_weight = 0
for _, scenario in ipairs(error_scenarios) do
    total_weight = total_weight + scenario.weight
end

-- Track error statistics
local error_counts = {
    ["404"] = 0,
    ["500"] = 0,
    ["400"] = 0,
    ["200"] = 0,
    ["other"] = 0
}

function select_scenario()
    local rand = math.random(1, total_weight)
    local cumulative = 0

    for _, scenario in ipairs(error_scenarios) do
        cumulative = cumulative + scenario.weight
        if rand <= cumulative then
            return scenario
        end
    end

    return error_scenarios[1]
end

request = function()
    local scenario = select_scenario()

    -- Add dynamic timestamp to avoid caching
    local separator = string.find(scenario.path, "?") and "&" or "?"
    local path = scenario.path .. separator .. "ts=" .. os.time() .. math.random(1000, 9999)

    return wrk.format("GET", path)
end

response = function(status, headers, body)
    -- Track response codes
    local code_str = tostring(status)
    if error_counts[code_str] then
        error_counts[code_str] = error_counts[code_str] + 1
    else
        error_counts["other"] = error_counts["other"] + 1
    end
end

done = function(summary, latency, requests)
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Error Generation Summary\n")
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write(string.format("Total Requests:  %d\n", summary.requests))
    io.write(string.format("Duration:        %.2fs\n", summary.duration / 1000000))
    io.write(string.format("Throughput:      %.2f req/sec\n", summary.requests / (summary.duration / 1000000)))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Response Code Distribution:\n")
    io.write(string.format("  200 OK:          %d\n", error_counts["200"]))
    io.write(string.format("  400 Bad Request: %d\n", error_counts["400"]))
    io.write(string.format("  404 Not Found:   %d\n", error_counts["404"]))
    io.write(string.format("  500 Server Err:  %d\n", error_counts["500"]))
    if error_counts["other"] > 0 then
        io.write(string.format("  Other:           %d\n", error_counts["other"]))
    end
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Connection Errors:\n")
    io.write(string.format("  Connect:  %d\n", summary.errors.connect))
    io.write(string.format("  Read:     %d\n", summary.errors.read))
    io.write(string.format("  Write:    %d\n", summary.errors.write))
    io.write(string.format("  Timeout:  %d\n", summary.errors.timeout))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Latency Distribution:\n")
    io.write(string.format("  Avg:      %.2fms\n", latency.mean / 1000))
    io.write(string.format("  95th %%:   %.2fms\n", latency:percentile(95) / 1000))
    io.write(string.format("  99th %%:   %.2fms\n", latency:percentile(99) / 1000))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("\nCheck VictoriaLogs for error logs with:\n")
    io.write('  {kubernetes.container_name="xplane-image-gallery"} | unpack_json | log.level:error\n')
    io.write("\nCheck VictoriaTraces for error spans and failed operations.\n")
end
