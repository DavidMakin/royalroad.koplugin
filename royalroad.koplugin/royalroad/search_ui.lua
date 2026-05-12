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

local function trim(s)
    return s:gsub("^%s+", ""):gsub("%s+$", "")
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

function M:_loadMoreResults(query, current_results, page, results_menu)
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
            self:showSearchResults(query, current_results, page)
        end)
    end)
end

function M:parseSearchResults(html)
    local results = {}
    local seen = {}

    for block in html:gmatch('<div[^>]+class="[^"]*fiction%-list%-item[^"]*"[^>]*>(.-)</div>%s*</div>%s*</div>') do
        local fiction_id = block:match('/fiction/(%d+)/')
        if fiction_id and not seen[fiction_id] then
            seen[fiction_id] = true

            local title = block:match('<h2[^>]*>%s*(.-)%s*</h2>')
                or block:match('class="[^"]*fiction%-title[^"]*"[^>]*>%s*(.-)%s*<')
            if title then
                title = trim(title:gsub("<[^>]+>", ""))
                title = util.htmlEntitiesToUtf8(title)
            end

            local author = block:match('property="author"[^>]*>%s*(.-)%s*</')
                or block:match('class="[^"]*author[^"]*"[^>]*>%s*(.-)%s*<')
            if author then
                author = trim(author:gsub("<[^>]+>", ""))
            end

            local chapters = block:match('<span[^>]*title="Chapters"[^>]*>%s*(%d+[^<]*)</span>')
                or block:match('(%d+)%s*[Cc]hapters?')

            local rating = block:match('"ratingValue"%s*:%s*"([%d%.]+)"')
                or block:match('<span[^>]*class="[^"]*number[^"]*"[^>]*>([%d%.]+)</span>')

            local status = self:extractStatus(block)

            local wc_raw = block:match('"wordCount"%s*:%s*(%d+)')
                or block:match('<span[^>]*title="Words"[^>]*>%s*([%d,]+)%s*</span>')
            local word_count = wc_raw and wc_raw:gsub(",", "") or nil

            local tags = {}
            for tag_text in block:gmatch('<a[^>]+class="[^"]*tag[^"]*"[^>]*>(.-)</a>') do
                local t = trim(tag_text:gsub("<[^>]+>", ""))
                if t ~= "" then
                    table.insert(tags, t)
                    if #tags >= 3 then break end
                end
            end

            if title and title ~= "" then
                table.insert(results, {
                    fiction_id = fiction_id,
                    title      = title,
                    author     = author or "",
                    chapters   = chapters or "?",
                    tags       = tags,
                    rating     = rating,
                    status     = status,
                    word_count = word_count,
                })
            end
        end
            if #results >= C.SEARCH.MAX_RESULTS then break end
    end

    return results
end

function M:showSearchResults(query, results, page)
    local downloader = self
    local item_table = {}
    for _, r in ipairs(results) do
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
        covers_fullscreen  = true,
        is_borderless      = true,
        is_popout          = false,
        title              = T(_("Results: %1 (%2)"), query, #results),
        item_table         = item_table,
        title_bar_fm_style = true,
        onMenuSelect       = function(_menu, item)
            if item.load_more then
                self:_loadMoreResults(query, results, page + 1, results_menu)
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
