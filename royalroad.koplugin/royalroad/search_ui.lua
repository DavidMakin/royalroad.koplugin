local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local Menu        = require("ui/widget/menu")
local UIManager   = require("ui/uimanager")
local logger      = require("logger")
local T           = require("ffi/util").template
local _           = require("gettext")

local M = {}

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
    UIManager:show(InfoMessage:new{
        text    = T(_("Searching for \"%1\"..."), query),
        timeout = 2,
    })

    UIManager:scheduleIn(0.1, function()
        local encoded = query:gsub(" ", "+"):gsub("[^%w%+%-_%.~]", function(c)
            return string.format("%%%02X", c:byte())
        end)
        local url = "https://www.royalroad.com/fictions/search?title=" .. encoded

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

        self:showSearchResults(query, results)
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
                title = title:gsub("<[^>]+>", ""):gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&#39;", "'")
                title = title:gsub("^%s+", ""):gsub("%s+$", "")
            end

            local author = block:match('property="author"[^>]*>%s*(.-)%s*</')
                or block:match('class="[^"]*author[^"]*"[^>]*>%s*(.-)%s*<')
            if author then
                author = author:gsub("<[^>]+>", ""):gsub("^%s+", ""):gsub("%s+$", "")
            end

            local chapters = block:match('<span[^>]*title="Chapters"[^>]*>%s*(%d+[^<]*)</span>')
                or block:match('(%d+)%s*[Cc]hapters?')

            local tags = {}
            for tag_text in block:gmatch('<a[^>]+class="[^"]*tag[^"]*"[^>]*>(.-)</a>') do
                local t = tag_text:gsub("<[^>]+>", ""):gsub("^%s+", ""):gsub("%s+$", "")
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
                })
            end
        end
        if #results >= 20 then break end
    end

    return results
end

function M:showSearchResults(query, results)
    local downloader = self
    local item_table = {}
    for _, r in ipairs(results) do
        local sub = r.author ~= "" and (r.author .. " - " .. r.chapters .. " ch") or (r.chapters .. " ch")
        if r.tags and #r.tags > 0 then
            sub = sub .. " · " .. table.concat(r.tags, ", ")
        end
        if #sub > 40 then sub = sub:sub(1, 38) .. "…" end
        table.insert(item_table, {
            text       = r.title,
            mandatory  = sub,
            fiction_id = r.fiction_id,
            title      = r.title,
            author     = r.author,
        })
    end

    local results_menu
    results_menu = Menu:new{
        covers_fullscreen  = true,
        is_borderless      = true,
        is_popout          = false,
        title              = T(_("Results: %1 (%2)"), query, #results),
        item_table         = item_table,
        title_bar_fm_style = true,
        onMenuSelect       = function(_menu, item)
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
