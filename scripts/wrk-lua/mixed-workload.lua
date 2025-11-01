-- mixed-workload.lua
-- Realistic mixed workload: 70% reads, 20% writes, 10% errors
-- Simulates real-world user behavior with database tracing

local boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"  -- pragma: allowlist secret

local png_data = string.char(
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
    0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
    0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4,
    0x89, 0x00, 0x00, 0x00, 0x0A, 0x49, 0x44, 0x41,
    0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
    0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00,
    0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE,
    0x42, 0x60, 0x82
)

-- Read endpoints (70% of traffic)
local read_endpoints = {
    {path = "/api/images", weight = 30},
    {path = "/api/images?tags[]=landscape", weight = 15},
    {path = "/api/images?page=2&page_size=15", weight = 10},
    {path = "/api/test-db?scenario=normal", weight = 8},
    {path = "/api/settings", weight = 5},
    {path = "/api/tags/predefined", weight = 2}
}

-- Calculate weights
local read_total = 0
for _, e in ipairs(read_endpoints) do
    read_total = read_total + e.weight
end

function select_read_endpoint()
    local rand = math.random(1, read_total)
    local cumulative = 0
    for _, e in ipairs(read_endpoints) do
        cumulative = cumulative + e.weight
        if rand <= cumulative then
            return e.path
        end
    end
    return read_endpoints[1].path
end

function random_filename()
    return string.format("mixed-%d-%d.png", os.time(), math.random(1000, 9999))
end

function build_upload()
    local body = "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="files"; filename="' .. random_filename() .. '"\r\n'
    body = body .. "Content-Type: image/png\r\n\r\n"
    body = body .. png_data .. "\r\n"
    body = body .. "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="tags"\r\n\r\n'
    body = body .. "mixed,benchmark\r\n"
    body = body .. "--" .. boundary .. "--\r\n"

    local headers = {}
    headers["Content-Type"] = "multipart/form-data; boundary=" .. boundary
    return wrk.format("POST", "/api/images", headers, body)
end

function build_settings_update()
    local body = string.format([[{"user_id":"mixed-bench","grid_columns":%d,"background_opacity":%.1f}]],
        math.random(3, 6), math.random(2, 8) / 10)
    local headers = {}
    headers["Content-Type"] = "application/json"
    return wrk.format("PUT", "/api/settings", headers, body)
end

-- Error-generating requests
local error_paths = {
    "/api/images/nonexistent-" .. os.time() .. ".jpg",
    "/api/images/../../../etc/passwd",
    "/api/invalid-endpoint-" .. math.random(1000, 9999),
    "/api/test-db?scenario=error"
}

function build_error_request()
    local path = error_paths[math.random(#error_paths)]
    return wrk.format("GET", path)
end

request = function()
    local rand = math.random(1, 100)

    if rand <= 70 then
        -- 70% reads
        local path = select_read_endpoint()
        return wrk.format("GET", path)
    elseif rand <= 85 then
        -- 15% uploads
        return build_upload()
    elseif rand <= 90 then
        -- 5% settings updates
        return build_settings_update()
    else
        -- 10% errors
        return build_error_request()
    end
end

done = function(summary, latency, requests)
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Mixed Workload Summary\n")
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write(string.format("Requests:    %d total\n", summary.requests))
    io.write(string.format("Duration:    %.2fs\n", summary.duration / 1000000))
    io.write(string.format("Throughput:  %.2f req/sec\n", summary.requests / (summary.duration / 1000000)))
    io.write(string.format("Errors:      %d (%.1f%%)\n",
        summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout,
        (summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout) * 100 / summary.requests))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
    io.write("Latency Distribution:\n")
    io.write(string.format("  Avg:     %.2fms\n", latency.mean / 1000))
    io.write(string.format("  Median:  %.2fms\n", latency:percentile(50) / 1000))
    io.write(string.format("  95th %%:  %.2fms\n", latency:percentile(95) / 1000))
    io.write(string.format("  99th %%:  %.2fms\n", latency:percentile(99) / 1000))
    io.write(string.format("  Max:     %.2fms\n", latency.max / 1000))
    io.write("━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n")
end
