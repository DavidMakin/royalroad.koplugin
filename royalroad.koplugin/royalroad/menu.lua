local ButtonDialog  = require("ui/widget/buttondialog")
local InfoMessage   = require("ui/widget/infomessage")
local InputDialog   = require("ui/widget/inputdialog")
local Menu          = require("ui/widget/menu")
local UIManager     = require("ui/uimanager")
local lfs           = require("libs/libkoreader-lfs")
local T             = require("ffi/util").template
local util          = require("util")
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
                keep_menu_open = true,
                callback = function() self:showSettings() end,
            },
        }
    self._royalroad_items = royalroad_items
    menu_items.royalroad = {
        text = _("Royal Road Downloader"),
        keep_menu_open = true,
        callback = function()
            self:manageDownloads()
        end,
    }
end

function M:showSettings()
    local settings_menu
    local function refresh()
        for _, item in ipairs(self._settings_items) do
            if item.text_func then item.text = item.text_func() end
        end
        if settings_menu then settings_menu:updateItems() end
    end

    local function showChoice(title, options, get, set, mark_dirty)
        local dialog
        local buttons = {}
        for _, opt in ipairs(options) do
            local value, label = opt[1], opt[2]
            table.insert(buttons, {{ text = (get() == value and "● " or "○ ") .. label, callback = function()
                set(value)
                self:saveSettings()
                UIManager:close(dialog)
                if mark_dirty then self._settings_view_dirty = true end
                refresh()
            end }})
        end
        table.insert(buttons, {{ text = _("Cancel"), callback = function() UIManager:close(dialog) end }})
        dialog = ButtonDialog:new{ title = title, buttons = buttons }
        UIManager:show(dialog)
    end

    self._settings_items = {
        {
            text_func = function()
                local dir = self.download_dir
                local short = dir:match("([^/]+/[^/]+)$") or dir
                return T(_("Download folder: .../%1"), short)
            end,
            keep_menu_open = true,
            callback = function() self:chooseDownloadFolder() end,
        },
        {
            text_func = function()
                return T(_("Download format: %1"), self.use_epub and _("EPUB") or _("HTML"))
            end,
            keep_menu_open = true,
            callback = function()
                showChoice(_("Download format"), {
                    { true,  _("EPUB") },
                    { false, _("HTML") },
                }, function() return self.use_epub end, function(v) self.use_epub = v end)
            end,
        },
        {
            text_func = function() return T(_("Rate limit: %1s"), self.rate_limit_delay) end,
            keep_menu_open = true,
            callback = function() self:setRateLimit() end,
        },
        {
            text_func = function()
                local label = self.manage_view_mode == "mosaic" and _("Cover mosaic") or _("List")
                return T(_("Manage view: %1"), label)
            end,
            keep_menu_open = true,
            callback = function()
                showChoice(_("Manage view"), {
                    { "list",   _("List") },
                    { "mosaic", _("Cover mosaic") },
                }, function() return self.manage_view_mode end, function(v) self.manage_view_mode = v end, true)
            end,
        },
        {
            text_func = function()
                return T(_("Mosaic titles: %1"), self.mosaic_hide_title and _("hidden") or _("shown"))
            end,
            keep_menu_open = true,
            callback = function()
                showChoice(_("Mosaic titles"), {
                    { false, _("Show") },
                    { true,  _("Hide") },
                }, function() return self.mosaic_hide_title end, function(v) self.mosaic_hide_title = v end, true)
            end,
        },
        {
            text_func = function()
                local labels = { title = _("Title"), date = _("Date"), chapters = _("Chapters"), lastread = _("Last read"), updated = _("Last updated") }
                return T(_("Sort by: %1"), labels[self.manage_sort_mode] or _("Title"))
            end,
            keep_menu_open = true,
            callback = function()
                showChoice(_("Sort by"), {
                    { "title",    _("Title") },
                    { "date",     _("Date downloaded") },
                    { "chapters", _("Chapter count") },
                    { "lastread", _("Last read") },
                    { "updated",  _("Last updated") },
                }, function() return self.manage_sort_mode end, function(v) self.manage_sort_mode = v end)
            end,
        },
        {
            text_func = function()
                return T(_("Auto-add to collection: %1"), self.auto_add_to_collection and _("On") or _("Off"))
            end,
            keep_menu_open = true,
            callback = function()
                showChoice(_("Auto-add downloaded stories to a collection"), {
                    { true,  _("On") },
                    { false, _("Off") },
                }, function() return self.auto_add_to_collection end, function(v)
                    self.auto_add_to_collection = v
                    if v then self:addAllStoriesToCollection() end
                end)
            end,
        },
        {
            text_func = function()
                return T(_("Collection name: %1"), self.collection_name)
            end,
            keep_menu_open = true,
            callback = function() self:setCollectionName() end,
        },
    }
    settings_menu = Menu:new{
        title             = _("Settings"),
        item_table        = self._settings_items,
        covers_fullscreen = true,
        is_borderless     = true,
        is_popout         = false,
    }
    -- Use onClose (fires only when THIS widget is truly removed from UIManager,
    -- not when sub-dialogs open on top) to avoid accessing UIManager._window_stack.
    local downloader = self
    local _parent_onClose = settings_menu.onClose
    settings_menu.onClose = function(s)
        downloader._settings_menu = nil
        settings_menu = nil
        if downloader._settings_view_dirty then
            downloader._settings_view_dirty = nil
            UIManager:scheduleIn(0, function()
                if downloader.manage_menu then UIManager:close(downloader.manage_menu) end
                downloader:manageDownloads()
            end)
        end
        if _parent_onClose then _parent_onClose(s) end
    end
    self._settings_menu = settings_menu
    UIManager:show(self._settings_menu)
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

function M:setCollectionName()
    local dialog
    dialog = InputDialog:new{
        title = _("Collection name"),
        input = self.collection_name,
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
                        local value = dialog:getInputText()
                        if value and value:match("%S") then
                            self.collection_name = value
                            self:saveSettings()
                            if self.auto_add_to_collection then
                                self:addAllStoriesToCollection()
                            end
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

function M:showAbout()
    local meta = require("royalroad/meta")
    UIManager:show(InfoMessage:new{
        text = T(_(
            "Royal Road Downloader\n\n" ..
            "Version: %1\n" ..
            "Min KOReader: %2\n\n" ..
            "%3"
        ), meta.version, meta.min_koreader_version, meta.description),
    })
end

function M:openDownloadsFolder()
    util.makePath(self.download_dir)

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
