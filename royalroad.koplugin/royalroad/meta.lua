-- Version info derived from _meta.lua to stay in sync.
-- This module is used by the About dialog; the canonical
-- version lives in _meta.lua (updated by the release workflow).
--
-- NOTE: require("_meta") is NOT safe here. "_meta" is a generic module
-- name used by nearly every KOReader plugin, and Lua's require() cache
-- (package.loaded) is shared across all plugins. Whichever plugin's
-- _meta.lua loads first "wins" that cache slot, so require("_meta")
-- can silently return a DIFFERENT plugin's metadata table. Load our
-- own _meta.lua by absolute file path instead.
local script_dir = debug.getinfo(1, "S").source:match("^@(.*)/")
local _meta = dofile(script_dir .. "/../_meta.lua")
return {
    version              = _meta.version,
    min_koreader_version = _meta.min_koreader_version,
    description          = _meta.description,
}
