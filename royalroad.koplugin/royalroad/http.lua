local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local logger      = require("logger")
local socket      = require("socket")
local http        = require("socket.http")
local socket_url  = require("socket.url")
local ltn12       = require("ltn12")
local socketutil  = require("socketutil")
local _           = require("gettext")

local C      = require("royalroad/constants")
local anubis = require("royalroad/anubis")

local HTTP_CONNECT_TIMEOUT    = C.HTTP.CONNECT_TIMEOUT
local HTTP_TOTAL_TIMEOUT      = C.HTTP.TOTAL_TIMEOUT
local BLOCK_NOTICE_INTERVAL   = 60

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

-- GET a royalroad.com URL, sending any Anubis clearance cookies we hold.
-- Returns code, headers, status, body.
function M:_get(page_url, follow_redirects)
    local response_body = {}
    local request = {
        url      = page_url,
        method   = "GET",
        redirect = follow_redirects,
        sink     = ltn12.sink.table(response_body),
        headers  = {
            ["User-Agent"] = C.USER_AGENT,
            ["Accept"]     = "text/html",
        },
    }
    -- Clearance is for royalroad.com only; never leak it to other hosts.
    local host = socket_url.parse(page_url).host
    host = host and host:lower()
    local cookie = (host == "royalroad.com" or host == "www.royalroad.com")
        and anubis.cookieHeader(self._anubis_cookies)
    if cookie then request.headers["Cookie"] = cookie end

    socketutil:set_timeout(HTTP_CONNECT_TIMEOUT, HTTP_TOTAL_TIMEOUT)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()
    return code, headers, status, table.concat(response_body)
end

-- Solves the Anubis challenge in `html` and stores the clearance cookie in
-- self._anubis_cookies (in memory only; the cookie lasts days, but a new
-- session just solves again, which takes seconds). Returns true when cleared.
function M:_clearAnubis(page_url, html, headers)
    local challenge = anubis.parseChallenge(html)
    if not challenge or not anubis.isSupported(challenge) then
        logger.warn("Royal Road: unsupported Anubis challenge",
            challenge and challenge.algorithm, challenge and challenge.difficulty)
        return false
    end

    self._anubis_cookies = anubis.mergeCookies(self._anubis_cookies, headers)
    -- Solving blocks the UI thread, so paint the message before starting.
    local notice = InfoMessage:new{ text = _("Solving Royal Road security check...") }
    UIManager:show(notice)
    UIManager:forceRePaint()
    local nonce, hash, elapsed = anubis.solve(challenge)
    UIManager:close(notice)
    if not nonce then return false end

    local pass_url = anubis.passUrl(C.BASE_URL, challenge, nonce, hash, elapsed, page_url)
    local code, pass_headers = self:_get(pass_url, false)
    self._anubis_cookies = anubis.mergeCookies(self._anubis_cookies, pass_headers)
    if not anubis.hasClearance(self._anubis_cookies) then
        logger.warn("Royal Road: Anubis rejected the solution, HTTP", code)
        return false
    end
    logger.info("Royal Road: Anubis challenge solved in", elapsed, "ms, nonce", nonce)
    return true
end

-- Callers treat a failed fetch as "nothing found", so say why. Throttled
-- because one update run can hit this for every story.
function M:_notifyBlocked()
    local now = os.time()
    if self._blocked_notice_time and now - self._blocked_notice_time < BLOCK_NOTICE_INTERVAL then
        return
    end
    self._blocked_notice_time = now
    UIManager:show(InfoMessage:new{
        text = _("Royal Road is blocking automated access right now. Try again later."),
        timeout = 6,
    })
end

function M:fetchPage(page_url)
    local delays = { 2, 5 }
    local skip_delay = false
    local solved_challenge = false
    for attempt = 0, #delays do
        if attempt > 0 and not skip_delay then
            socket.sleep(delays[attempt])
        end
        skip_delay = false

        local code, headers, status, body = self:_get(page_url, true)

        if code == 200 and anubis.isChallenge(body) then
            -- One solve per fetch: a second challenge right after a pass means
            -- the site rejected us, so retrying would only burn CPU.
            if solved_challenge or not self:_clearAnubis(page_url, body, headers) then
                logger.warn("Royal Road: blocked by bot protection, url", page_url)
                self:_notifyBlocked()
                return nil, 0
            end
            solved_challenge = true
            -- Retry right away, outside the attempt count: solving on the last
            -- attempt must not end the fetch with no try at the real page.
            code, headers, status, body = self:_get(page_url, true)
            if code == 200 and not anubis.isChallenge(body) then return body, nil end
            if code == 200 then
                logger.warn("Royal Road: blocked by bot protection, url", page_url)
                self:_notifyBlocked()
                return nil, 0
            end
            skip_delay = true
        elseif code == 200 then
            return body, nil
        elseif code == 429 then
            local backoff = C.NETWORK.RATE_LIMIT_BACKOFF * (attempt + 1)
            logger.warn("Royal Road: HTTP 429 rate-limited, backing off", backoff, "s (attempt", attempt + 1, ")")
            socket.sleep(backoff)
            skip_delay = true
        else
            logger.warn("Royal Road: HTTP", code, status, "attempt", attempt + 1, "url", page_url)
        end
    end
    return nil, 0
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
