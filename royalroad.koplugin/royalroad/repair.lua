-- Repair path for EPUBs that were built with full-URL chapter comparison
-- (before stable identity keying existed). Those EPUBs can contain the same
-- chapters twice — once under an old slug and once under the new one — plus
-- chapters that no longer exist on Royal Road at all (deleted volumes).
--
-- Strategy:
--   1. Pair every EPUB chapter with the stored URL it was downloaded under
--      (the plugin keeps story.chapter_urls index-aligned with the EPUB
--      spine, so position i of one corresponds to position i of the other).
--   2. Deduplicate by stable identity key (fiction_id:chapter_id).
--   3. Order the result by the live chapter list when that list is provably
--      complete — in that case chapters missing from it were deleted from the
--      site and are dropped. When the live list is truncated or unavailable,
--      keep every unique chapter, ordered by numeric chapter id.
--   4. Rewrite the EPUB in place and restore the reading position.
local InfoMessage = require("ui/widget/infomessage")
local NetworkMgr  = require("ui/network/manager")
local UIManager   = require("ui/uimanager")
local logger      = require("logger")
local ffiUtil     = require("ffi/util")
local T           = ffiUtil.template
local _           = require("gettext")
local C           = require("royalroad/constants")
local urls        = require("royalroad/urls")

local M = {}

-- Pure planning logic, kept free of KOReader UI dependencies so it can be
-- unit-tested standalone (see test_repair.lua).
--
--   stored_urls:  story.chapter_urls from settings. Must be index-aligned
--                 with `chapters` (this is guaranteed by the download/update
--                 flow, which appends both together).
--   chapters:     chapters extracted from the EPUB spine.
--   current_urls: live chapter list from the story page, or nil when
--                 unavailable. Only treated as authoritative when it contains
--                 AT LEAST as many entries as the deduplicated stored set —
--                 a shorter list means Royal Road truncated the server-side
--                 chapter data (large stories), and dropping anything in that
--                 case would lose chapters.
--
-- Returns: plan table, or nil + a reason code:
--   "count_mismatch" -- stored and EPUB chapter counts differ; refuse to
--                      guess pairings (suggests a re-download).
--   "no_duplicates"  -- nothing to repair.
function M._planRepair(stored_urls, chapters, current_urls)
    stored_urls = stored_urls or {}
    if #chapters ~= #stored_urls then
        return nil, "count_mismatch"
    end

    local n = #chapters
    local seen = {}
    local unique_keys = {}
    local last_index = {}
    local last_url = {}
    for i = 1, n do
        local key = urls.chapterKey(stored_urls[i])
        if not seen[key] then
            seen[key] = true
            table.insert(unique_keys, key)
        end
        -- Last occurrence wins: its content is the most recent download
        -- (current text and correct slug).
        last_index[key] = i
        last_url[key] = stored_urls[i]
    end

    local unique_count = #unique_keys
    if unique_count == n then
        return nil, "no_duplicates"
    end

    local live_authoritative = current_urls ~= nil and #current_urls >= unique_count
    local ordered_keys
    local dropped_count = 0

    if live_authoritative then
        -- Follow the site's own ordering and drop stored chapters the site
        -- no longer lists.
        local key_used = {}
        ordered_keys = {}
        for _, u in ipairs(current_urls) do
            local key = urls.chapterKey(u)
            if seen[key] and not key_used[key] then
                key_used[key] = true
                table.insert(ordered_keys, key)
            end
        end
        for _, key in ipairs(unique_keys) do
            if not key_used[key] then
                dropped_count = dropped_count + 1
            end
        end
    else
        -- Keep every unique chapter, ordered by numeric chapter_id (the
        -- stable identity). Non-numeric legacy keys sort last, keeping their
        -- original relative order. table.sort is not stable, so tie-break on
        -- the original index.
        local decorated = {}
        for i, key in ipairs(unique_keys) do
            table.insert(decorated, { key = key, num = urls.chapterId(key), idx = i })
        end
        table.sort(decorated, function(a, b)
            if a.num and b.num then
                if a.num ~= b.num then return a.num < b.num end
                return a.idx < b.idx
            end
            if a.num then return true end
            if b.num then return false end
            return a.idx < b.idx
        end)
        ordered_keys = {}
        for i, d in ipairs(decorated) do
            ordered_keys[i] = d.key
        end
    end

    local new_chapters = {}
    local new_urls = {}
    for _, key in ipairs(ordered_keys) do
        table.insert(new_chapters, chapters[last_index[key]])
        table.insert(new_urls, last_url[key])
    end

    return {
        new_chapters  = new_chapters,
        new_urls      = new_urls,
        old_count     = n,
        unique_count  = unique_count,
        dup_count     = n - unique_count,
        dropped_count = dropped_count,
        authoritative = live_authoritative,
    }
end

-- Extracts the cover image embedded in an existing EPUB (offline-capable).
-- Returns { data, mime_type, extension } or nil when the EPUB has no cover.
function M:_extractCoverFromEPUB(epub_path)
    local Archiver = require("ffi/archiver")
    local arc = Archiver.Reader:new()
    if not arc:open(epub_path) then return nil end

    local mime_types = {
        jpg  = "image/jpeg",
        jpeg = "image/jpeg",
        png  = "image/png",
        gif  = "image/gif",
        webp = "image/webp",
        svg  = "image/svg+xml",
    }

    local cover
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local basename = (entry.path:match("([^/]+)$")) or entry.path
            local ext = basename:match("^cover%.([a-zA-Z0-9]+)$")
            if ext then
                local data = arc:extractToMemory(entry.path)
                if data and #data > 0 then
                    ext = ext:lower()
                    cover = {
                        data      = data,
                        mime_type = mime_types[ext] or "image/jpeg",
                        extension = ext,
                    }
                    break
                end
            end
        end
    end
    arc:close()
    return cover
end

-- Rebuilds a corrupted EPUB: deduplicates chapters by stable identity and,
-- when the live chapter list is provably complete, drops chapters deleted
-- from Royal Road. Preserves the cover and the reading position.
function M:repairStoryDuplicates(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    if story.partial_of or (story.queued_chapter_urls and #story.queued_chapter_urls > 0) then
        UIManager:show(InfoMessage:new{
            text = _("A download is still in progress for this story.\n\nFinish the download first, then repair."),
        })
        return
    end

    local epub_path = story.epub_path
    local file = io.open(epub_path, "r")
    if not file then
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB file not found:\n%1\n\nPlease re-download the story."), epub_path),
        })
        return
    end
    file:close()

    local chapters, err = self:extractChaptersFromEPUB(epub_path)
    if not chapters then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to read existing EPUB:\n%1"), err or _("Unknown error")),
        })
        return
    end

    -- Optional live chapter list, used only when provably complete (see
    -- _planRepair). Skipped entirely when the device is offline so a repair
    -- never blocks on network timeouts.
    local current_urls
    local ok_online, online = pcall(function()
        return NetworkMgr:isOnline()
    end)
    if ok_online and online then
        local story_html = self:fetchPageCached(C.BASE_URL .. "/fiction/" .. fiction_id)
        if story_html then
            current_urls = self:extractChapterURLs(story_html, fiction_id)
            logger.info("Royal Road: Repair got", #current_urls, "live chapter URLs")
        end
    end

    local plan, reason = M._planRepair(story.chapter_urls or {}, chapters, current_urls)
    if not plan then
        if reason == "no_duplicates" then
            UIManager:show(InfoMessage:new{
                text = _("No duplicate chapters found — nothing to repair."),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Repair impossible: stored chapter count (%1) does not match the EPUB (%2).\n\nPlease re-download the story."),
                    #(story.chapter_urls or {}), #chapters),
            })
        end
        return
    end

    -- Cover: prefer the one already embedded in the EPUB (works offline),
    -- fall back to re-fetching the stored cover URL.
    local cover_image = self:_extractCoverFromEPUB(epub_path)
    local cover_url = story.cover_url
    if not cover_image and cover_url and cover_url ~= "" then
        local image_data, mime_type, extension = self:fetchImage(cover_url)
        if image_data then
            cover_image = { data = image_data, mime_type = mime_type, extension = extension }
        end
    end

    -- Preserve the reading position across the rebuild (same pattern as the
    -- update flow in updater.lua).
    local DocSettings = require("docsettings")
    local old_position = {}
    local ok, doc_settings = pcall(function()
        return DocSettings:open(epub_path)
    end)
    if ok and doc_settings and doc_settings.data then
        old_position = {
            last_xpointer = doc_settings.data.last_xpointer,
            bookmarks     = doc_settings.data.bookmarks,
            highlights    = doc_settings.data.highlight,
        }
    end

    self:saveAsEPUB(
        fiction_id,
        story.title,
        story.author,
        plan.new_chapters,
        cover_image,
        plan.new_urls,
        cover_url,
        epub_path,
        true -- silent: report with the summary below
    )

    if old_position.last_xpointer then
        local repaired = self.downloaded_stories[fiction_id] and self.downloaded_stories[fiction_id].epub_path
        if repaired then
            local ok2, ds2 = pcall(function()
                return DocSettings:open(repaired)
            end)
            if ok2 and ds2 then
                ds2.data.last_xpointer = old_position.last_xpointer
                if old_position.bookmarks then ds2.data.bookmarks = old_position.bookmarks end
                if old_position.highlights then ds2.data.highlight = old_position.highlights end
                ds2:flush()
                logger.info("Royal Road: Restored reading position after repair")
            end
        end
    end

    self:_invalidateCoverCache(fiction_id)

    local msg = T(_("Repaired %1!\n\nRemoved %2 duplicate chapters"), story.title, plan.dup_count)
    if plan.dropped_count > 0 then
        msg = msg .. T(_("\nDropped %1 chapters no longer on Royal Road"), plan.dropped_count)
    end
    msg = msg .. T(_("\nTotal: %1 chapters"), #plan.new_chapters)
    UIManager:show(InfoMessage:new{ text = msg, timeout = 10 })
end

return M
