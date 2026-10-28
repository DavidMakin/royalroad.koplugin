-- Standalone tests, run with KOReader's LuaJIT from the KOReader directory:
--   cd /usr/lib/koreader && ./luajit /path/to/royalroad.koplugin/test_anubis.lua
local koreader = os.getenv("KOREADER_DIR") or "."
package.path  = koreader .. "/?.lua;" .. koreader .. "/frontend/?.lua;" .. koreader .. "/common/?.lua;" .. arg[0]:gsub("[^/]*$", "") .. "?.lua;" .. package.path
package.cpath = koreader .. "/common/?.so;" .. koreader .. "/libs/?.so;" .. package.cpath

local sha2   = require("ffi/sha2")
local anubis = require("royalroad/anubis")

local function eq(got, want, msg)
    assert(got == want, string.format("%s: got %s, want %s", msg, tostring(got), tostring(want)))
end

local random = "63d82dca89be482a91ed595696e3d8a028908c8dacb15a462a942ce34cc785f6a6f967b74a110358fddb926bf106290df0dcc17b1e5bcdc13d82482d710969db"
local html = '<script id="anubis_version" type="application/json">"v1"</script>'
    .. '<script id="anubis_challenge" type="application/json">{"rules":{"algorithm":"fast","difficulty":4},'
    .. '"challenge":{"id":"01a181d6-ce03-75f7-be22-e4884a53de0f","method":"fast","randomData":"' .. random
    .. '","difficulty":4,"spent":false,"extensions":null}}</script>'

assert(anubis.isChallenge(html), "challenge detected")
assert(not anubis.isChallenge("<html><body>chapter</body></html>"), "plain page is not a challenge")

local c = anubis.parseChallenge(html)
eq(c.algorithm, "fast", "algorithm")
eq(c.difficulty, 4, "difficulty")
eq(c.id, "01a181d6-ce03-75f7-be22-e4884a53de0f", "id")
assert(anubis.isSupported(c), "fast/4 supported")

local nonce, hash = anubis.solve(c)
assert(nonce, "solved")
eq(hash:sub(1, 4), "0000", "hash has 4 leading hex zeros")
eq(sha2.sha256(random .. nonce), hash, "hash matches randomData .. nonce")

c.algorithm = "argon2id"
assert(not anubis.isSupported(c), "argon2id unsupported")
c.algorithm = "slow"
assert(not anubis.isSupported(c), "slow unsupported until seen live")
c.algorithm = "fast"
c.extensions = { "css-load" }
assert(not anubis.isSupported(c), "extensions unsupported")

-- Repeated Set-Cookie headers are comma-joined by luasocket; Expires has a comma.
local jar = anubis.mergeCookies(nil, { ["set-cookie"] =
    "ARRAffinity=abc|def; Path=/; Secure; HttpOnly, "
    .. "techaro.lol-anubis-cookie-verification-d82da6a5=uuid-1; Path=/; Expires=Wed, 28 Oct 2026 09:58:20 GMT; Secure" })
eq(jar["techaro.lol-anubis-cookie-verification-d82da6a5"], "uuid-1", "verification cookie kept")
assert(not anubis.hasClearance(jar), "verification cookie is not clearance")
jar = anubis.mergeCookies(jar, { ["set-cookie"] = "techaro.lol-anubis-auth=jwt.token.value; Path=/; Max-Age=604800" })
assert(anubis.hasClearance(jar), "auth cookie is clearance")
eq(anubis.cookieHeader(jar),
    "techaro.lol-anubis-auth=jwt.token.value; techaro.lol-anubis-cookie-verification-d82da6a5=uuid-1", "cookie header")

local u = anubis.passUrl("https://www.royalroad.com", c, 42, "00ab", 7, "https://www.royalroad.com/fiction/1?a=b")
local url = require("socket.url")
local query = u:match("%?(.*)$")
local fields = {}
for k, v in query:gmatch("([^&=]+)=([^&]*)") do fields[k] = url.unescape(v) end
assert(u:find("^https://www%.royalroad%.com/%.within%.website/x/cmd/anubis/api/pass%-challenge%?"), "pass url path")
eq(fields.id, "01a181d6-ce03-75f7-be22-e4884a53de0f", "pass url id")
eq(fields.response, "00ab", "pass url response")
eq(fields.nonce, "42", "pass url nonce")
eq(fields.redir, "https://www.royalroad.com/fiction/1?a=b", "pass url redir")
eq(fields.elapsedTime, "7", "pass url elapsedTime")

print("test_anubis: all passed")
