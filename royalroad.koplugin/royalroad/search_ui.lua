local ButtonDialog = require("ui/widget/buttondialog")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu        = require("ui/widget/menu")
local NetworkMgr  = require("ui/network/manager")
local UIManager   = require("ui/uimanager")
local logger      = require("logger")
local T           = require("ffi/util").template
local util        = require("util")
local _           = require("gettext")

local M = {}

local C = require("royalroad/constants")

local SORT_MODES = {
    { key = "default",   label = _("Default") },
    { key = "title",     label = _("Title A-Z") },
    { key = "rating",    label = _("Rating ↓") },
    { key = "wordcount", label = _("Words ↓") },
    { key = "chapters",  label = _("Chapters ↓") },
}

local function sortResults(results, mode)
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
function M:searchStories()
    local search_dialog
    search_dialog = InputDialog:new{
        title      = _("Search Royal Road"),
        input_hint = _("Story title..."),
        input_type = "string",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(search_dialog)
                    end,
                },
                {
                    text = _("Search"),
                    is_enter_default = true,
                    callback = function()
                        local query = search_dialog:getInputText()
                        UIManager:close(search_dialog)
                        if query and query ~= "" then
                            self:performSearch(query)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(search_dialog)
    search_dialog:onShowKeyboard()
end

function M:performSearch(query)
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{
            text    = T(_("Searching for \"%1\"..."), query),
            timeout = 2,
        })

        UIManager:scheduleIn(0.1, function()
            local encoded = util.urlEncode(query)
            local url = C.BASE_URL .. C.SEARCH.URL_PATH .. encoded

            local html = self:fetchPage(url)
            if not html then
                UIManager:show(InfoMessage:new{
                    text = _("Search failed. Check your connection."),
                })
                return
            end

            local results = self:parseSearchResults(html)
            if #results == 0 then
                UIManager:show(InfoMessage:new{
                    text = T(_("No results found for \"%1\"."), query),
                })
                return
            end

            self:showSearchResults(query, results, 1)
        end)
    end)
end

function M:_loadMoreResults(query, current_results, page, results_menu, sort_mode)
    NetworkMgr:runWhenOnline(function()
        UIManager:show(InfoMessage:new{
            text    = T(_("Loading page %1..."), page),
            timeout = 2,
        })
        UIManager:scheduleIn(0.1, function()
            local encoded = util.urlEncode(query)
            local url = C.BASE_URL .. C.SEARCH.URL_PATH .. encoded .. "&page=" .. page
            local html = self:fetchPage(url)
            local new_results = html and self:parseSearchResults(html) or {}

            if #new_results == 0 then
                UIManager:show(InfoMessage:new{
                    text    = _("No more results."),
                    timeout = 2,
                })
                return
            end

            for _, r in ipairs(new_results) do
                table.insert(current_results, r)
            end
            UIManager:close(results_menu)
            self:showSearchResults(query, current_results, page, sort_mode)
        end)
    end)
end

function M:showSearchResults(query, results, page, sort_mode)
    sort_mode = sort_mode or "default"
    local downloader = self
    local sorted = sortResults(results, sort_mode)

    local item_table = {}
    for _, r in ipairs(sorted) do
        local sub = r.status and ("[" .. r.status .. "] ") or ""
        sub = sub .. (r.author ~= "" and (r.author .. " - " .. r.chapters .. " ch") or (r.chapters .. " ch"))
        if r.tags and #r.tags > 0 then
            sub = sub .. " · " .. table.concat(r.tags, ", ")
        end
        if r.word_count then
            local wk = math.floor(tonumber(r.word_count) / 100 + 0.5) / 10
            sub = sub .. " · " .. tostring(wk) .. "k words"
        end
        if r.rating then
            sub = sub .. " ★" .. r.rating
        end
        if #sub > C.SEARCH.MAX_SUB_CHARS then sub = sub:sub(1, C.SEARCH.MAX_SUB_CHARS - 2) .. "…" end
        table.insert(item_table, {
            text       = r.title,
            mandatory  = sub,
            fiction_id = r.fiction_id,
            title      = r.title,
            author     = r.author,
        })
    end

    table.insert(item_table, {
        text      = _("▼ Load more results…"),
        mandatory = T(_("page %1"), page + 1),
        load_more = true,
    })

    local results_menu
    results_menu = Menu:new{
        covers_fullscreen   = true,
        is_borderless       = true,
        is_popout           = false,
        title               = T(_("Results: %1 (%2)"), query, #results),
        item_table          = item_table,
        title_bar_fm_style  = true,
        title_bar_left_icon = "appbar.menu",
        onLeftButtonTap     = function()
            local sort_dialog
            local buttons = {}
            for _, s in ipairs(SORT_MODES) do
                local mode_key = s.key
                table.insert(buttons, {{
                    text     = (sort_mode == mode_key and "● " or "○ ") .. s.label,
                    callback = function()
                        UIManager:close(sort_dialog)
                        UIManager:close(results_menu)
                        downloader:showSearchResults(query, results, page, mode_key)
                    end,
                }})
            end
            table.insert(buttons, {{
                text     = _("Cancel"),
                callback = function() UIManager:close(sort_dialog) end,
            }})
            sort_dialog = ButtonDialog:new{ buttons = buttons }
            UIManager:show(sort_dialog)
        end,
        onMenuSelect       = function(_menu, item)
            if item.load_more then
                self:_loadMoreResults(query, results, page + 1, results_menu, sort_mode)
                return
            end
            UIManager:close(results_menu)
            if downloader.downloaded_stories[item.fiction_id] then
                UIManager:show(InfoMessage:new{
                    text    = T(_("\"%1\" is already downloaded."), item.title),
                    timeout = 3,
                })
                UIManager:scheduleIn(0.1, function()
                    downloader:showStoryOptions(item.fiction_id)
                end)
                return
            end
            UIManager:show(InfoMessage:new{
                text    = T(_("Fetching chapter list for %1..."), item.title),
                timeout = 2,
            })
            UIManager:scheduleIn(0.1, function()
                downloader:processFiction(item.fiction_id)
            end)
        end,
        onReturn = function(this)
            UIManager:close(this)
        end,
    }
    UIManager:show(results_menu)
end

return M
