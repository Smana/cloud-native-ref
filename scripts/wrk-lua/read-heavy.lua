-- read-heavy.lua
-- Simulates read-heavy workload across various GET endpoints
-- Generates traces for image listing, details, settings, and tags

local endpoints = {
    {method = "GET", path = "/api/images", weight = 40},
    {method = "GET", path = "/api/images?tags[]=landscape&tags[]=nature&match_all=true", weight = 15},
    {method = "GET", path = "/api/images?tags[]=test", weight = 10},
    {method = "GET", path = "/api/images?page=2&page_size=10", weight = 10},
    {method = "GET", path = "/api/settings", weight = 10},
    {method = "GET", path = "/api/tags/predefined", weight = 10},
    {method = "GET", path = "/healthz", weight = 5}
}

-- Calculate total weight
local total_weight = 0
for _, endpoint in ipairs(endpoints) do
    total_weight = total_weight + endpoint.weight
end

-- Select endpoint based on weighted distribution
function select_endpoint()
    local rand = math.random(1, total_weight)
    local cumulative = 0

    for _, endpoint in ipairs(endpoints) do
        cumulative = cumulative + endpoint.weight
        if rand <= cumulative then
            return endpoint
        end
    end

    return endpoints[1] -- fallback
end

request = function()
    local endpoint = select_endpoint()
    return wrk.format(endpoint.method, endpoint.path)
end

-- Track response statistics
done = function(summary, latency, requests)
    io.write("------------------------------\n")
    io.write("Read-Heavy Workload Summary\n")
    io.write("------------------------------\n")
    io.write(string.format("Total Requests: %d\n", summary.requests))
    io.write(string.format("Total Errors: %d\n", summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout))
    io.write(string.format("Throughput: %.2f req/sec\n", summary.requests / (summary.duration / 1000000)))
    io.write(string.format("Avg Latency: %.2fms\n", latency.mean / 1000))
    io.write(string.format("50th %%ile: %.2fms\n", latency:percentile(50) / 1000))
    io.write(string.format("95th %%ile: %.2fms\n", latency:percentile(95) / 1000))
    io.write(string.format("99th %%ile: %.2fms\n", latency:percentile(99) / 1000))
end
