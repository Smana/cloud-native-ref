-- write-heavy.lua
-- Simulates write-heavy workload with settings updates and uploads
-- Generates traces for PUT/POST operations

local boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"  -- pragma: allowlist secret

-- Simple PNG data
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

local settings_configs = {
    {grid_columns = 3, background_opacity = 0.2, text_theme = "light"},
    {grid_columns = 4, background_opacity = 0.3, text_theme = "dark"},
    {grid_columns = 5, background_opacity = 0.5, text_theme = "light"},
    {grid_columns = 6, background_opacity = 0.7, text_theme = "dark"},
}

local font_families = {"system-ui", "Arial", "Roboto", "Open Sans", "Lato", "Montserrat"}

function random_filename()
    local timestamp = os.time()
    local random = math.random(1000, 9999)
    return string.format("write-bench-%d-%d.png", timestamp, random)
end

function build_upload_request()
    local body = ""
    body = body .. "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="files"; filename="' .. random_filename() .. '"\r\n'
    body = body .. "Content-Type: image/png\r\n"
    body = body .. "\r\n"
    body = body .. png_data .. "\r\n"
    body = body .. "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="tags"\r\n'
    body = body .. "\r\n"
    body = body .. "write-test,benchmark\r\n"
    body = body .. "--" .. boundary .. "--\r\n"

    local headers = {}
    headers["Content-Type"] = "multipart/form-data; boundary=" .. boundary

    return wrk.format("POST", "/api/images", headers, body)
end

function build_settings_update()
    local config = settings_configs[math.random(#settings_configs)]
    local font = font_families[math.random(#font_families)]

    local body = string.format([[{
        "user_id": "bench-user",
        "grid_columns": %d,
        "background_opacity": %.1f,
        "text_theme": "%s",
        "font_family": "%s",
        "show_tags": true,
        "show_dimensions": true
    }]], config.grid_columns, config.background_opacity, config.text_theme, font)

    local headers = {}
    headers["Content-Type"] = "application/json"

    return wrk.format("PUT", "/api/settings", headers, body)
end

-- 70% uploads, 30% settings updates
request = function()
    local rand = math.random(1, 100)
    if rand <= 70 then
        return build_upload_request()
    else
        return build_settings_update()
    end
end

done = function(summary, latency, requests)
    io.write("------------------------------\n")
    io.write("Write-Heavy Workload Summary\n")
    io.write("------------------------------\n")
    io.write(string.format("Total Requests: %d\n", summary.requests))
    io.write(string.format("Total Errors: %d\n", summary.errors.connect + summary.errors.read + summary.errors.write + summary.errors.status + summary.errors.timeout))
    io.write(string.format("Throughput: %.2f req/sec\n", summary.requests / (summary.duration / 1000000)))
    io.write(string.format("Avg Latency: %.2fms\n", latency.mean / 1000))
    io.write(string.format("95th %%ile: %.2fms\n", latency:percentile(95) / 1000))
    io.write(string.format("99th %%ile: %.2fms\n", latency:percentile(99) / 1000))
end
