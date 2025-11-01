-- upload.lua
-- Simulates image upload requests with multipart/form-data
-- Generates extensive traces with file processing spans

local boundary = "----WebKitFormBoundary7MA4YWxkTrZu0gW"  -- pragma: allowlist secret

-- Simple image data (1x1 PNG, base64 decoded)
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

local tags = {"landscape", "nature", "test", "demo", "benchmark"}

-- Generate random filename
function random_filename()
    local timestamp = os.time()
    local random = math.random(1000, 9999)
    return string.format("bench-image-%d-%d.png", timestamp, random)
end

-- Build multipart body with 1-3 files
function build_multipart_body()
    local num_files = math.random(1, 3)
    local body = ""

    -- Add files
    for i = 1, num_files do
        local filename = random_filename()
        body = body .. "--" .. boundary .. "\r\n"
        body = body .. 'Content-Disposition: form-data; name="files"; filename="' .. filename .. '"\r\n'
        body = body .. "Content-Type: image/png\r\n"
        body = body .. "\r\n"
        body = body .. png_data .. "\r\n"
    end

    -- Add tags (randomly select 1-3 tags)
    local num_tags = math.random(1, 3)
    local selected_tags = {}
    for i = 1, num_tags do
        table.insert(selected_tags, tags[math.random(#tags)])
    end

    body = body .. "--" .. boundary .. "\r\n"
    body = body .. 'Content-Disposition: form-data; name="tags"\r\n'
    body = body .. "\r\n"
    body = body .. table.concat(selected_tags, ",") .. "\r\n"
    body = body .. "--" .. boundary .. "--\r\n"

    return body
end

request = function()
    local body = build_multipart_body()
    local headers = {}
    headers["Content-Type"] = "multipart/form-data; boundary=" .. boundary

    return wrk.format("POST", "/api/images", headers, body)
end
