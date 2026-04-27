local ButtonDialog  = require("ui/widget/buttondialog")
local ConfirmBox    = require("ui/widget/confirmbox")
local InfoMessage   = require("ui/widget/infomessage")
local Menu          = require("ui/widget/menu")
local UIManager     = require("ui/uimanager")
local ffiUtil       = require("ffi/util")
local T             = require("ffi/util").template
local _             = require("gettext")

local M = {}

function M:showBatchActions()
    if self:countDownloadedStories() == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No downloaded stories."),
            timeout = 3,
        })
        return
    end

    local selected = {}
    local item_table = {}
    for fiction_id, story in pairs(self.downloaded_stories) do
        selected[fiction_id] = false
        table.insert(item_table, {
            fiction_id = fiction_id,
            text       = "○  " .. (story.title or fiction_id),
            title      = story.title or fiction_id,
        })
    end
    table.sort(item_table, function(a, b) return a.title < b.title end)

    local batch_menu
    local downloader = self

    local function refreshMenu()
        for i, item in ipairs(batch_menu.item_table) do
            local checked = selected[item.fiction_id]
            batch_menu.item_table[i].text = (checked and "●  " or "○  ") .. item.title
        end
        batch_menu:updateItems()
    end

    local function countSelected()
        local n = 0
        for _, v in pairs(selected) do if v then n = n + 1 end end
        return n
    end

    batch_menu = Menu:new{
        covers_fullscreen  = true,
        is_borderless      = true,
        is_popout          = false,
        title              = _("Select stories"),
        item_table         = item_table,
        title_bar_fm_style = true,
        onMenuSelect       = function(_, item)
            selected[item.fiction_id] = not selected[item.fiction_id]
            refreshMenu()
        end,
        onReturn           = function(this)
            UIManager:close(this)
        end,
        title_bar_left_icon = "check",
        onLeftButtonTap     = function()
            local n = countSelected()
            if n == 0 then
                UIManager:show(InfoMessage:new{
                    text    = _("No stories selected."),
                    timeout = 2,
                })
                return
            end
            local action_dialog
            action_dialog = ButtonDialog:new{
                title   = T(_("%1 stories selected"), n),
                buttons = {
                    {{
                        text     = _("Update selected"),
                        callback = function()
                            UIManager:close(action_dialog)
                            UIManager:close(batch_menu)
                            downloader:batchUpdate(selected)
                        end,
                    }},
                    {{
                        text     = _("Refresh covers"),
                        callback = function()
                            UIManager:close(action_dialog)
                            UIManager:close(batch_menu)
                            downloader:batchRefreshCovers(selected)
                        end,
                    }},
                    {{
                        text     = _("Delete EPUBs and tracking"),
                        callback = function()
                            UIManager:close(action_dialog)
                            UIManager:show(ConfirmBox:new{
                                text        = T(_("Delete %1 stories?\n\nThis will remove their EPUB files and tracking data."), n),
                                ok_text     = _("Delete"),
                                cancel_text = _("Cancel"),
                                ok_callback = function()
                                    UIManager:close(batch_menu)
                                    downloader:batchDelete(selected)
                                end,
                            })
                        end,
                    }},
                    {{
                        text     = _("Cancel"),
                        callback = function() UIManager:close(action_dialog) end,
                    }},
                },
            }
            UIManager:show(action_dialog)
        end,
    }
    UIManager:show(batch_menu)
end

function M:batchUpdate(selected)
    local targets = {}
    for fiction_id, is_selected in pairs(selected) do
        if is_selected then table.insert(targets, fiction_id) end
    end
    if #targets == 0 then return end

    local stories_with_updates = {}
    local errors = {}
    local total = #targets
    local current_msg

    local function process_next(idx)
        if current_msg then
            UIManager:close(current_msg)
            current_msg = nil
        end
        if idx > total then
            if #stories_with_updates == 0 then
                local msg = _("All selected stories are up to date!")
                if #errors > 0 then
                    msg = msg .. "\n\n" .. T(_("Failed to check: %1"), table.concat(errors, ", "))
                end
                UIManager:show(InfoMessage:new{ text = msg })
                return
            end
            self:showUpdateMenu(stories_with_updates)
            return
        end

        local fiction_id = targets[idx]
        local story = self.downloaded_stories[fiction_id]
        current_msg = InfoMessage:new{
            text = T(_("Checking %1 / %2\n%3"), idx, total, story and story.title or fiction_id),
        }
        UIManager:show(current_msg)

        UIManager:scheduleIn(0, function()
            if story then
                local story_html = self:fetchPage("https://www.royalroad.com/fiction/" .. fiction_id)
                if story_html then
                    local current_urls = self:extractChapterURLs(story_html, fiction_id)
                    local stored_count = #(story.chapter_urls or {})
                    if #current_urls > stored_count then
                        table.insert(stories_with_updates, {
                            fiction_id    = fiction_id,
                            title         = story.title,
                            stored_count  = stored_count,
                            current_count = #current_urls,
                            new_chapters  = #current_urls - stored_count,
                            current_urls  = current_urls,
                        })
                    end
                else
                    table.insert(errors, story.title or fiction_id)
                end
            end
            process_next(idx + 1)
        end)
    end

    process_next(1)
end

function M:batchDelete(selected)
    local count = 0
    for fiction_id, is_selected in pairs(selected) do
        if is_selected then
            local story = self.downloaded_stories[fiction_id]
            if story then
                if story.epub_path then
                    os.remove(story.epub_path)
                    local sdr_path = story.epub_path:gsub("%.epub$", ".sdr")
                    ffiUtil.purgeDir(sdr_path)
                end
                self.downloaded_stories[fiction_id] = nil
                self:_invalidateCoverCache(fiction_id)
                count = count + 1
            end
        end
    end
    self:_invalidateStoryCount()
    self:saveSettings()

    UIManager:show(InfoMessage:new{
        text    = T(_("Deleted %1 stories."), count),
        timeout = 3,
    })

    if self.manage_menu then
        UIManager:close(self.manage_menu)
        self:manageDownloads()
    end
end

function M:batchRefreshCovers(selected)
    local targets = {}
    for fiction_id, is_selected in pairs(selected) do
        if is_selected then table.insert(targets, fiction_id) end
    end
    if #targets == 0 then return end

    UIManager:show(InfoMessage:new{
        text    = T(_("Refreshing covers for %1 stories..."), #targets),
        timeout = 2,
    })

    UIManager:scheduleIn(0.1, function()
        local updated = 0
        local errors  = {}
        for _, fiction_id in ipairs(targets) do
            local story = self.downloaded_stories[fiction_id]
            if story and story.cover_url and story.cover_url ~= "" then
                local image_data, mime_type, extension = self:fetchImage(story.cover_url)
                if image_data then
                    story.cover_image_data = image_data
                    story.cover_mime       = mime_type
                    story.cover_ext        = extension
                    story.cover_bb         = nil
                    local existing_chapters = self:extractChaptersFromEPUB(story.epub_path)
                    if existing_chapters then
                        local cover_image = { data = image_data, mime_type = mime_type, extension = extension }
                        self:saveAsEPUB(story.fiction_id, story.title, story.author, existing_chapters, cover_image, story.chapter_urls, story.cover_url)
                    end
                    updated = updated + 1
                else
                    table.insert(errors, story.title or fiction_id)
                end
            end
        end
        self:saveSettings()

        local msg = T(_("Updated covers for %1 stories."), updated)
        if #errors > 0 then
            msg = msg .. "\n\n" .. T(_("Failed: %1"), table.concat(errors, ", "))
        end
        UIManager:show(InfoMessage:new{ text = msg })
    end)
end

return M
