local ButtonDialog  = require("ui/widget/buttondialog")
local InfoMessage   = require("ui/widget/infomessage")
local InputDialog   = require("ui/widget/inputdialog")
local Menu          = require("ui/widget/menu")
local UIManager     = require("ui/uimanager")
local lfs           = require("libs/libkoreader-lfs")
local T             = require("ffi/util").template
local _             = require("gettext")

local M = {}

function M:addToMainMenu(menu_items)
    local royalroad_items = {
            {
                text_func = function()
                    local q = self._download_queue and #self._download_queue or 0
                    local active = self._download_active and 1 or 0
                    local total = q + active
                    if total > 0 then
                        return T(_("Download story (%1 active)"), total)
                    end
                    return _("Download story")
                end,
                keep_menu_open = true,
                callback = function()
                    self:downloadStory()
                end,
            },
            {
                text = _("Search Royal Road"),
                keep_menu_open = true,
                callback = function()
                    self:searchStories()
                end,
            },
            {
                text_func = function()
                    local count = self:countDownloadedStories()
                    if count > 0 then
                        return T(_("Check for updates (%1 stories)"), count)
                    else
                        return _("Check for updates")
                    end
                end,
                keep_menu_open = true,
                callback = function()
                    self:checkForUpdates()
                end,
            },
            {
                text_func = function()
                    local count = self:countDownloadedStories()
                    if count > 0 then
                        return T(_("Manage downloads (%1 stories)"), count)
                    else
                        return _("Manage downloads")
                    end
                end,
                keep_menu_open = true,
                callback = function()
                    self:manageDownloads()
                end,
            },
            {
                text = _("Batch actions"),
                keep_menu_open = true,
                callback = function()
                    self:showBatchActions()
                end,
            },
            {
                text = _("Bulk import"),
                keep_menu_open = true,
                callback = function()
                    self:bulkImport()
                end,
            },
            {
                text = _("Export reading list"),
                keep_menu_open = true,
                callback = function()
                    self:exportReadingList()
                end,
            },
            {
                text = _("Open downloads folder"),
                callback = function()
                    self:openDownloadsFolder()
                end,
            },
            {
                text = _("Settings"),
                sub_item_table = {
                    {
                        text_func = function()
                            local dir = self.download_dir
                            local short = dir:match("([^/]+/[^/]+)$") or dir
                            return T(_("Download folder: .../%1"), short)
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:chooseDownloadFolder()
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Download format: %1"), self.use_epub and _("EPUB") or _("HTML"))
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local dialog
                            dialog = ButtonDialog:new{
                                title = _("Download format"),
                                buttons = {
                                    {{
                                        text     = (self.use_epub and "● " or "○ ") .. _("EPUB"),
                                        callback = function()
                                            self.use_epub = true
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{
                                        text     = (not self.use_epub and "● " or "○ ") .. _("HTML"),
                                        callback = function()
                                            self.use_epub = false
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
                                },
                            }
                            UIManager:show(dialog)
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Rate limit: %1s"), self.rate_limit_delay)
                        end,
                        keep_menu_open = true,
                        callback = function()
                            self:setRateLimit()
                        end,
                    },
                    {
                        text_func = function()
                            local label = self.manage_view_mode == "mosaic" and _("Cover mosaic") or _("List")
                            return T(_("Manage view: %1"), label)
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local dialog
                            dialog = ButtonDialog:new{
                                title = _("Manage view"),
                                buttons = {
                                    {{
                                        text     = (self.manage_view_mode == "list" and "● " or "○ ") .. _("List"),
                                        callback = function()
                                            self.manage_view_mode = "list"
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{
                                        text     = (self.manage_view_mode == "mosaic" and "● " or "○ ") .. _("Cover mosaic"),
                                        callback = function()
                                            self.manage_view_mode = "mosaic"
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
                                },
                            }
                            UIManager:show(dialog)
                        end,
                    },
                    {
                        text_func = function()
                            local labels = { title = _("Title"), date = _("Date"), chapters = _("Chapters"), lastread = _("Last read"), updated = _("Last updated") }
                            return T(_("Sort by: %1"), labels[self.manage_sort_mode] or _("Title"))
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local dialog
                            dialog = ButtonDialog:new{
                                title = _("Sort by"),
                                buttons = {
                                    {{
                                        text     = (self.manage_sort_mode == "title" and "● " or "○ ") .. _("Title"),
                                        callback = function()
                                            self.manage_sort_mode = "title"
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{
                                        text     = (self.manage_sort_mode == "date" and "● " or "○ ") .. _("Date downloaded"),
                                        callback = function()
                                            self.manage_sort_mode = "date"
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{
                                        text     = (self.manage_sort_mode == "chapters" and "● " or "○ ") .. _("Chapter count"),
                                        callback = function()
                                            self.manage_sort_mode = "chapters"
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{
                                        text     = (self.manage_sort_mode == "lastread" and "● " or "○ ") .. _("Last read"),
                                        callback = function()
                                            self.manage_sort_mode = "lastread"
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{
                                        text     = (self.manage_sort_mode == "updated" and "● " or "○ ") .. _("Last updated"),
                                        callback = function()
                                            self.manage_sort_mode = "updated"
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
                                 },
                            }
                            UIManager:show(dialog)
                        end,
                    },
                    {
                        text_func = function()
                            local state = self.auto_check_updates and _("On") or _("Off")
                            return T(_("Auto-check updates: %1"), state)
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local dialog
                            dialog = ButtonDialog:new{
                                title = _("Auto-check updates on open"),
                                buttons = {
                                    {{
                                        text     = (self.auto_check_updates and "● " or "○ ") .. _("On"),
                                        callback = function()
                                            self.auto_check_updates = true
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{
                                        text     = (not self.auto_check_updates and "● " or "○ ") .. _("Off"),
                                        callback = function()
                                            self.auto_check_updates = false
                                            self:saveSettings()
                                            UIManager:close(dialog)
                                            if self._plugin_menu then self._plugin_menu:updateItems() end
                                        end,
                                    }},
                                    {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }},
                                },
                            }
                            UIManager:show(dialog)
                        end,
                    },
                    {
                        text_func = function()
                            return T(_("Check interval: %1h"), self.auto_check_interval_hours)
                        end,
                        keep_menu_open = true,
                        callback = function()
                            local dialog
                            dialog = InputDialog:new{
                                title = _("Auto-check interval (hours)"),
                                input = tostring(self.auto_check_interval_hours),
                                input_type = "number",
                                buttons = {{
                                    { text = _("Cancel"), callback = function() UIManager:close(dialog) end },
                                    { text = _("Save"), callback = function()
                                        local v = tonumber(dialog:getInputText())
                                        if v and v >= 1 then
                                            self.auto_check_interval_hours = v
                                            self:saveSettings()
                                        end
                                        UIManager:close(dialog)
                                        if self._plugin_menu then self._plugin_menu:updateItems() end
                                    end},
                                }},
                            }
                            UIManager:show(dialog)
                            dialog:onShowKeyboard()
                        end,
                    },
                },
            },
        }
    self._royalroad_items = royalroad_items
    menu_items.royalroad = {
        text = _("Royal Road Downloader"),
        keep_menu_open = true,
        callback = function()
            self:showPluginMenu()
        end,
    }
end

function M:showPluginMenu()
    if not self._royalroad_items then
        self:addToMainMenu({})
    end
    local downloader = self
    local plugin_menu = Menu:new{
        title           = _("Royal Road Downloader"),
        item_table      = self._royalroad_items,
        covers_fullscreen = true,
        is_borderless   = true,
        is_popout       = false,
    }
    function plugin_menu:updatePageInfo(select_number)
        Menu.updatePageInfo(self, select_number)
        if self.onReturn then
            self.page_return_arrow:show()
            self.page_return_arrow:enable()
        end
    end
    function plugin_menu:onReturn()
        UIManager:close(self)
        UIManager:scheduleIn(0.3, function() downloader:showPluginMenu() end)
    end
    self._plugin_menu = plugin_menu
    UIManager:show(plugin_menu)
end

function M:setRateLimit()
    local dialog
    dialog = InputDialog:new{
        title = _("Rate limit (seconds between chapters)"),
        input = tostring(self.rate_limit_delay),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(dialog)
                    end,
                },
                {
                    text = _("Save"),
                    callback = function()
                        local value = tonumber(dialog:getInputText())
                        if value and value >= 0 then
                            self.rate_limit_delay = value
                            self:saveSettings()
                        end
                        UIManager:close(dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M:chooseDownloadFolder()
    local PathChooser = require("ui/widget/pathchooser")
    local path_chooser = PathChooser:new{
        select_directory = true,
        select_file = false,
        show_files = false,
        path = self.download_dir,
        onConfirm = function(dir)
            self.download_dir = dir
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = T(_("Download folder set to:\n%1"), dir),
                timeout = 3,
            })
        end,
    }
    UIManager:show(path_chooser)
end

function M:openDownloadsFolder()
    if not lfs.attributes(self.download_dir, "mode") then
        lfs.mkdir(self.download_dir)
    end

    local FileManager = require("apps/filemanager/filemanager")
    if self.ui.document then
        self.ui:onClose()
    end
    if FileManager.instance then
        FileManager.instance:reinit(self.download_dir)
    else
        FileManager:showFiles(self.download_dir)
    end
end

return M
