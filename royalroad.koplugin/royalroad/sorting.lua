local _ = require("gettext")

local M = {}

M.SEARCH_SORT_MODES = {
    { key = "default",   label = _("Default") },
    { key = "title",     label = _("Title A-Z") },
    { key = "rating",    label = _("Rating ↓") },
    { key = "wordcount", label = _("Words ↓") },
    { key = "chapters",  label = _("Chapters ↓") },
}

function M.sortSearchResults(results, mode)
    local sorted = {}
    for _, r in ipairs(results) do table.insert(sorted, r) end
    if mode == "title" then
        table.sort(sorted, function(a, b) return (a.title or "") < (b.title or "") end)
    elseif mode == "rating" then
        table.sort(sorted, function(a, b) return (tonumber(a.rating) or 0) > (tonumber(b.rating) or 0) end)
    elseif mode == "wordcount" then
        table.sort(sorted, function(a, b) return (tonumber(a.word_count) or 0) > (tonumber(b.word_count) or 0) end)
    elseif mode == "chapters" then
        table.sort(sorted, function(a, b) return (tonumber(a.chapters) or 0) > (tonumber(b.chapters) or 0) end)
    end
    return sorted
end

-- Sort downloaded stories by mode. Mutates item_table in place.
-- last_read_fn(story) -> number: called lazily when mode == "lastread".
function M.sortDownloads(item_table, mode, last_read_fn)
    if mode == "date" then
        table.sort(item_table, function(a, b)
            return (a.download_date or 0) > (b.download_date or 0)
        end)
    elseif mode == "chapters" then
        table.sort(item_table, function(a, b)
            return #(a.chapter_urls or {}) > #(b.chapter_urls or {})
        end)
    elseif mode == "lastread" then
        local cache = {}
        table.sort(item_table, function(a, b)
            if cache[a.fiction_id] == nil then cache[a.fiction_id] = last_read_fn(a) end
            if cache[b.fiction_id] == nil then cache[b.fiction_id] = last_read_fn(b) end
            return cache[a.fiction_id] > cache[b.fiction_id]
        end)
    elseif mode == "updated" then
        table.sort(item_table, function(a, b)
            return (a.last_update or a.download_date or 0) > (b.last_update or b.download_date or 0)
        end)
    else -- "title" (default)
        table.sort(item_table, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    end
end

return M
