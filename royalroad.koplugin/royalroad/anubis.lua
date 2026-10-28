-- Anubis proof-of-work support. Royal Road serves an Anubis challenge page
-- (HTTP 200) instead of content. Only the SHA-256 "fast" algorithm is
-- solved; "slow" is rejected on purpose until it has been seen live. Anything
-- else is reported as unsupported rather than parsed as HTML.
local logger    = require("logger")
local rapidjson = require("rapidjson")
local sha2      = require("ffi/sha2")
local socket    = require("socket")
local url       = require("socket.url")

local M = {}

M.PASS_PATH = "/.within.website/x/cmd/anubis/api/pass-challenge"

local AUTH_PREFIX      = "techaro.lol-anubis-auth"
local COOKIE_PREFIX    = "techaro.lol-anubis"
local MAX_SOLVE_SECONDS = 30 -- unmeasured on real e-ink hardware; revisit after a device test
local CLOCK_CHECK_EVERY = 4096

function M.isChallenge(html)
    return html:find('id="anubis_challenge"', 1, true) ~= nil
end

-- Returns { id, random, algorithm, difficulty, extensions } or nil.
function M.parseChallenge(html)
    local json = html:match('<script id="anubis_challenge"[^>]*>(.-)</script>')
    if not json then return nil end
    local ok, data = pcall(rapidjson.decode, json)
    if not ok or type(data) ~= "table" then return nil end
    local rules, challenge = data.rules, data.challenge
    if type(rules) ~= "table" or type(challenge) ~= "table" then return nil end
    if type(challenge.id) ~= "string" or type(challenge.randomData) ~= "string" then return nil end
    if type(rules.algorithm) ~= "string" or type(rules.difficulty) ~= "number" then return nil end
    return {
        id         = challenge.id,
        random     = challenge.randomData,
        algorithm  = rules.algorithm,
        difficulty = rules.difficulty,
        extensions = type(rules.extensions) == "table" and rules.extensions or {},
    }
end

function M.isSupported(challenge)
    return challenge.algorithm == "fast"
        and #challenge.extensions == 0
        and challenge.difficulty >= 0 and challenge.difficulty <= 8
end

-- Finds a nonce whose SHA-256 of (randomData .. nonce) starts with `difficulty`
-- hex zeros. Returns nonce, hash, elapsed_ms, or nil when over the time cap.
function M.solve(challenge)
    local prefix = ("0"):rep(challenge.difficulty)
    local started = socket.gettime()
    local nonce = 0
    while true do
        local hash = sha2.sha256(challenge.random .. nonce)
        if hash:sub(1, #prefix) == prefix then
            return nonce, hash, math.floor((socket.gettime() - started) * 1000)
        end
        nonce = nonce + 1
        if nonce % CLOCK_CHECK_EVERY == 0 and socket.gettime() - started > MAX_SOLVE_SECONDS then
            logger.warn("Royal Road: Anubis proof of work exceeded", MAX_SOLVE_SECONDS, "s")
            return nil
        end
    end
end

function M.passUrl(base_url, challenge, nonce, hash, elapsed_ms, redir)
    return base_url .. M.PASS_PATH
        .. "?id=" .. url.escape(challenge.id)
        .. "&response=" .. hash
        .. "&nonce=" .. nonce
        .. "&redir=" .. url.escape(redir)
        .. "&elapsedTime=" .. elapsed_ms
end

-- luasocket joins repeated Set-Cookie headers with ", ", and Expires dates
-- contain commas too, so match the Anubis cookie names rather than splitting.
function M.mergeCookies(jar, headers)
    jar = jar or {}
    local set_cookie = headers and headers["set-cookie"]
    if set_cookie then
        for name, value in set_cookie:gmatch("(" .. COOKIE_PREFIX:gsub("%p", "%%%0") .. "[%w%-%._]*)=([^;,%s]+)") do
            jar[name] = value
        end
    end
    return jar
end

function M.cookieHeader(jar)
    if not jar then return nil end
    local parts = {}
    for name, value in pairs(jar) do
        parts[#parts + 1] = name .. "=" .. value
    end
    if #parts == 0 then return nil end
    table.sort(parts)
    return table.concat(parts, "; ")
end

function M.hasClearance(jar)
    if not jar then return false end
    for name in pairs(jar) do
        if name:sub(1, #AUTH_PREFIX) == AUTH_PREFIX then return true end
    end
    return false
end

return M
