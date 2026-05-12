local logger     = require("logger")
local socket     = require("socket")
local http       = require("socket.http")
local ltn12      = require("ltn12")
local socketutil = require("socketutil")

local C = require("royalroad/constants")

local HTTP_CONNECT_TIMEOUT = C.HTTP.CONNECT_TIMEOUT
local HTTP_TOTAL_TIMEOUT   = C.HTTP.TOTAL_TIMEOUT

local M = {}

function M:fetchPageCached(url)
    if not self._page_cache then self._page_cache = {} end
    local entry = self._page_cache[url]
    if entry and os.time() - entry.time < C.NETWORK.PAGE_CACHE_TTL then
        return entry.html
    end
    local html = self:fetchPage(url)
    if html then
        self._page_cache[url] = { html = html, time = os.time() }
    end
    return html
end

function M:fetchPage(page_url)
    local delays = { 2, 5 }
    for attempt = 0, #delays do
        if attempt > 0 then
            socket.sleep(delays[attempt])
        end

        local response_body = {}
        local request = {
            url    = page_url,
            method = "GET",
            sink   = ltn12.sink.table(response_body),
            headers = {
                ["User-Agent"] = C.USER_AGENT,
                ["Accept"]     = "text/html",
            },
        }

        socketutil:set_timeout(HTTP_CONNECT_TIMEOUT, HTTP_TOTAL_TIMEOUT)
        local code, _, status = socket.skip(1, http.request(request))
        socketutil:reset_timeout()

        if code == 200 then
            return table.concat(response_body)
        end

        if code == 429 then
            local backoff = C.NETWORK.RATE_LIMIT_BACKOFF * (attempt + 1)
            logger.warn("Royal Road: HTTP 429 rate-limited, backing off", backoff, "s (attempt", attempt + 1, ")")
            socket.sleep(backoff)
        else
            logger.warn("Royal Road: HTTP", code, status, "attempt", attempt + 1, "url", page_url)
        end
    end
    return nil
end

function M:fetchImage(image_url)
    if not image_url then return nil, nil end

    local response_body = {}
    local request = {
        url    = image_url,
        method = "GET",
        sink   = ltn12.sink.table(response_body),
        headers = {
            ["User-Agent"] = C.USER_AGENT,
            ["Accept"]     = "image/*",
        },
    }

    socketutil:set_timeout(HTTP_CONNECT_TIMEOUT, HTTP_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.warn("Royal Road: Failed to download cover image, HTTP", code)
        return nil, nil
    end

    local image_data = table.concat(response_body)
    if #image_data == 0 then
        logger.warn("Royal Road: Cover image is empty")
        return nil, nil
    end

    local mime_type, extension
    local b1, b2, b3, b4 = image_data:byte(1, 4)
    if b1 == 0xFF and b2 == 0xD8 and b3 == 0xFF then
        mime_type, extension = "image/jpeg", "jpg"
    elseif b1 == 0x89 and b2 == 0x50 and b3 == 0x4E and b4 == 0x47 then
        mime_type, extension = "image/png", "png"
    elseif b1 == 0x47 and b2 == 0x49 and b3 == 0x46 then
        mime_type, extension = "image/gif", "gif"
    elseif #image_data >= 12 and image_data:sub(9, 12) == "WEBP" then
        mime_type, extension = "image/webp", "webp"
    else
        mime_type, extension = "image/jpeg", "jpg"
    end

    logger.info("Royal Road: Downloaded cover image,", #image_data, "bytes")
    return image_data, mime_type, extension
end

return M
