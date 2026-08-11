-- Royal Road chapter URL identity helpers.
--
-- Royal Road chapter URLs embed a stable, site-wide unique chapter id:
--   /fiction/{fiction_id}/{slug}/chapter/{chapter_id}/{chapter_slug}
-- The {slug} segments are derived from the story/chapter titles and change
-- when an author renames or reorganises their fiction (e.g. deleting a
-- volume). Comparing full URLs then makes every chapter look "new", which
-- duplicates chapters during update detection and EPUB repair.
--
-- Chapters are therefore keyed by (fiction_id, chapter_id) only. URLs that do
-- not match the standard format fall back to the raw URL so legacy formats
-- keep their previous comparison behaviour.
local M = {}

local KEY_PATTERN = "/fiction/(%d+)/[^/]+/chapter/(%d+)"

-- Stable identity key for a chapter URL: "fiction_id:chapter_id".
-- Falls back to the raw URL when the URL does not match the standard format.
function M.chapterKey(url)
    local fiction_id, chapter_id = url:match(KEY_PATTERN)
    if fiction_id and chapter_id then
        return fiction_id .. ":" .. chapter_id
    end
    return url
end

-- Numeric chapter_id parsed from a chapterKey, or nil for non-standard keys.
-- Numeric keys sort correctly; non-standard keys sort after them.
function M.chapterId(key)
    local chapter_id = key:match(":(%d+)$")
    return chapter_id and tonumber(chapter_id) or nil
end

-- True when a URL list contains chapters with duplicate identity keys.
-- Used to flag EPUBs that were built before stable-key comparison existed.
function M.hasDuplicateKeys(urls)
    if not urls then return false end
    local seen = {}
    for _, u in ipairs(urls) do
        local key = M.chapterKey(u)
        if seen[key] then return true end
        seen[key] = true
    end
    return false
end

return M
