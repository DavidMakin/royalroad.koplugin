-- Standalone fetchPage flow test with a fake Royal Road, no network:
--   cd /usr/lib/koreader && ./luajit /path/to/royalroad.koplugin/test_http.lua
local koreader = os.getenv("KOREADER_DIR") or "."
package.path  = koreader .. "/?.lua;" .. koreader .. "/frontend/?.lua;" .. koreader .. "/common/?.lua;" .. arg[0]:gsub("[^/]*$", "") .. "?.lua;" .. package.path
package.cpath = koreader .. "/common/?.so;" .. koreader .. "/libs/?.so;" .. package.cpath

local shown = {}
package.preload["socketutil"] = function() return { set_timeout = function() end, reset_timeout = function() end } end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["ui/widget/infomessage"] = function() return { new = function(_, o) return o end } end
package.preload["ui/uimanager"] = function()
    return {
        show = function(_, w) shown[#shown + 1] = w.text end,
        close = function() end,
        forceRePaint = function() end,
    }
end

local sha2 = require("ffi/sha2")
local RANDOM = ("ab12"):rep(16)
local CHALLENGE = '<script id="anubis_challenge" type="application/json">{"rules":{"algorithm":"fast","difficulty":2},'
    .. '"challenge":{"id":"id-1","randomData":"' .. RANDOM .. '","extensions":null}}</script>'

require("socket").sleep = function() end  -- skip retry backoff
local mode, requests, flaky_hits = "ok", {}, 0
package.loaded["socket.http"] = {
    request = function(req)
        requests[#requests + 1] = req
        local cookie = req.headers["Cookie"] or ""
        if req.url:find("pass%-challenge") then
            local response, nonce = req.url:match("response=(%x+)&nonce=(%d+)")
            if mode ~= "reject" and response == sha2.sha256(RANDOM .. nonce) and response:sub(1, 2) == "00" then
                return 1, 302, { ["set-cookie"] = "techaro.lol-anubis-auth=jwt; Path=/" }, "HTTP/1.1 302"
            end
            return 1, 403, {}, "HTTP/1.1 403"
        end
        if mode == "flaky" and not cookie:find("anubis-auth", 1, true) then
            flaky_hits = flaky_hits + 1
            if flaky_hits <= 2 then return 1, 500, {}, "HTTP/1.1 500" end
        end
        if cookie:find("techaro.lol-anubis-auth=jwt", 1, true) then
            req.sink("<html>real page</html>")
            return 1, 200, {}, "HTTP/1.1 200"
        end
        req.sink("<html>" .. CHALLENGE .. "</html>")
        return 1, 200, { ["set-cookie"] = "techaro.lol-anubis-cookie-verification-x=v1; Path=/" }, "HTTP/1.1 200"
    end,
}

local function fresh() return setmetatable({}, { __index = require("royalroad/http") }) end

-- Cleared flow: challenge, solve, pass, retry with the auth cookie.
local f = fresh()
local html, err = f:fetchPage("https://www.royalroad.com/fiction/1")
assert(html == "<html>real page</html>", "got real page, not challenge: " .. tostring(html))
assert(err == nil, "no error")
assert(#requests == 3, "page, pass-challenge, retry: " .. #requests)
assert(requests[2].redirect == false, "pass-challenge must not follow redirects")
assert(requests[2].headers["Cookie"]:find("cookie-verification-x=v1", 1, true), "verification cookie sent to pass-challenge")
assert(shown[1] == "Solving Royal Road security check...", "solving notice shown")

-- Second fetch on the same instance reuses clearance: one request, no solve.
requests, shown = {}, {}
assert(f:fetchPage("https://www.royalroad.com/fiction/2") == "<html>real page</html>", "second page")
assert(#requests == 1 and #shown == 0, "clearance reused without solving")

-- Rejected solution: nil, one blocked notice, throttled on the next failure.
mode, requests, shown = "reject", {}, {}
local g = fresh()
assert(g:fetchPage("https://www.royalroad.com/fiction/3") == nil, "blocked returns nil")
local blocked = 0
for _, text in ipairs(shown) do if text:find("blocking automated access", 1, true) then blocked = blocked + 1 end end
assert(blocked == 1, "one blocked notice: " .. blocked)
shown = {}
assert(g:fetchPage("https://www.royalroad.com/fiction/4") == nil, "still blocked")
for _, text in ipairs(shown) do assert(not text:find("blocking automated access", 1, true), "notice throttled") end

-- Challenge arriving on the last attempt (two 500s first) is still retried.
mode, requests, shown = "flaky", {}, {}
local h = fresh()
assert(h:fetchPage("https://www.royalroad.com/fiction/5") == "<html>real page</html>", "real page after late challenge")

-- Clearance cookie is never sent to a non-royalroad host.
mode, requests = "ok", {}
local j = fresh()
j._anubis_cookies = { ["techaro.lol-anubis-auth"] = "jwt" }
j:_get("https://royalroad.com.evil.example/x", true)
j:_get("https://www.royalroad.com/x", true)
assert(requests[1].headers["Cookie"] == nil, "no cookie to other host")
assert(requests[2].headers["Cookie"], "cookie sent to royalroad.com")

print("test_http: all passed")
