local DataStorage    = require("datastorage")
local Device         = require("device")
local Dispatcher     = require("dispatcher")
local LuaSettings    = require("luasettings")
local UIManager      = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs            = require("libs/libkoreader-lfs")
local logger         = require("logger")
local util           = require("util")
local _              = require("gettext")
local C              = require("royalroad/constants")

local RoyalRoadDownloader = WidgetContainer:extend{
    name = "royalroad",
}

local module_names = {
    "royalroad/http",
    "royalroad/parser",
    "royalroad/menu",
    "royalroad/downloads_ui",
    "royalroad/batch_ui",
    "royalroad/search_ui",
    "royalroad/downloader",
    "royalroad/epub",
    "royalroad/updater",
    "royalroad/story_detail",
}
for _, mod_name in ipairs(module_names) do
    local mod = require(mod_name)
    for k, v in pairs(mod) do
        RoyalRoadDownloader[k] = v
    end
end

function RoyalRoadDownloader:onDispatcherRegisterActions()
    Dispatcher:registerAction("royalroad_show_menu", {
        category = "none",
        event    = "ShowRoyalRoadMenu",
        title    = _("Royal Road Downloader"),
        filemanager = true,
    })
    Dispatcher:registerAction("royalroad_check_updates", {
        category = "none",
        event    = "RoyalRoadCheckForUpdates",
        title    = _("Royal Road - Check for updates"),
        filemanager = true,
    })
end

function RoyalRoadDownloader:onShowRoyalRoadMenu()
    self:manageDownloads()
end

function RoyalRoadDownloader:onRoyalRoadCheckForUpdates()
    self:checkForUpdates()
end

function RoyalRoadDownloader:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
    local home_dir = G_reader_settings:readSetting("home_dir") or DataStorage:getFullDataDir()
    self.default_download_dir = ("%s/%s"):format(home_dir, "royalroad")
    self.cover_cache_dir = DataStorage:getDataDir() .. "/cache/royalroad"
    self.debug_chapter_limit = nil
    self:loadSettings()
    logger.info("Royal Road: Plugin initialized. Download dir:", self.download_dir)
    logger.info("Royal Road: Tracking", self:countDownloadedStories(), "downloaded stories")
    if self.debug_chapter_limit then
        logger.info("Royal Road: DEBUG MODE - Limiting downloads to", self.debug_chapter_limit, "chapters")
    end
end

function RoyalRoadDownloader:loadSettings()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir().."/royalroad.lua")
    self.downloaded_stories = self.settings:readSetting("downloaded_stories", {})
    self.download_dir = self.settings:readSetting("download_dir", self.default_download_dir)
    self.use_epub = self.settings:readSetting("use_epub", true)
    self.rate_limit_delay = self.settings:readSetting("rate_limit_delay", C.NETWORK.DEFAULT_RATE_LIMIT)
    self.manage_view_mode = self.settings:readSetting("manage_view_mode", C.DEFAULTS.VIEW_MODE)
    self.manage_sort_mode = self.settings:readSetting("manage_sort_mode", C.DEFAULTS.SORT_MODE)
    self.mosaic_cols        = self.settings:readSetting("mosaic_cols", C.DEFAULTS.MOSAIC_COLS)
    self.mosaic_rows        = self.settings:readSetting("mosaic_rows", C.DEFAULTS.MOSAIC_ROWS)
    self.mosaic_hide_title  = self.settings:readSetting("mosaic_hide_title", false)
    self._story_count = nil
    local dirty = false
    for fiction_id, story in pairs(self.downloaded_stories) do
        local file_missing = story.epub_path and not lfs.attributes(story.epub_path, "mode")
        if file_missing and not story.missing then
            logger.warn("Royal Road: EPUB missing, marking as missing:", story.title, story.epub_path)
            story.missing = true
            dirty = true
        elseif not file_missing and story.missing then
            story.missing = nil
            dirty = true
        end
    end
    if dirty then self:saveSettings() end
end

function RoyalRoadDownloader:saveSettings()
    local stories_to_save = {}
    for fiction_id, story in pairs(self.downloaded_stories) do
        local s = {}
        for k, v in pairs(story) do
            if k ~= "cover_bb" then
                s[k] = v
            end
        end
        stories_to_save[fiction_id] = s
    end
    self.settings:saveSetting("downloaded_stories", stories_to_save)
    self.settings:saveSetting("download_dir", self.download_dir)
    self.settings:saveSetting("use_epub", self.use_epub)
    self.settings:saveSetting("rate_limit_delay", self.rate_limit_delay)
    self.settings:saveSetting("manage_view_mode", self.manage_view_mode)
    self.settings:saveSetting("manage_sort_mode", self.manage_sort_mode)
    self.settings:saveSetting("mosaic_cols",       self.mosaic_cols)
    self.settings:saveSetting("mosaic_rows",       self.mosaic_rows)
    self.settings:saveSetting("mosaic_hide_title", self.mosaic_hide_title)
    self.settings:flush()
    self._save_pending = false
end

function RoyalRoadDownloader:saveSettingsDebounced()
    if self._save_pending then return end
    self._save_pending = true
    UIManager:scheduleIn(0.4, function()
        if self._save_pending then
            self:saveSettings()
        end
    end)
end

function RoyalRoadDownloader:countDownloadedStories()
    if self._story_count == nil then
        self._story_count = util.tableSize(self.downloaded_stories)
    end
    return self._story_count
end

function RoyalRoadDownloader:_invalidateStoryCount()
    self._story_count = nil
end

function RoyalRoadDownloader:keepScreenAwake()
    logger.info("Royal Road: Enabling screen wake lock")
    UIManager:preventStandby()
    if Device:isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android and android.timeout then
            if android.timeout.get then
                self._prev_screen_timeout = android.timeout.get()
            end
            if android.timeout.set then
                android.timeout.set(-1)
                logger.info("Royal Road: Android screen timeout set to -1 (keep on)")
            end
        else
            logger.warn("Royal Road: Could not load android module")
        end
    end
end

function RoyalRoadDownloader:allowScreenSleep()
    logger.info("Royal Road: Releasing screen wake lock")
    UIManager:allowStandby()
    if Device:isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android and android.timeout and android.timeout.set then
            local restore_value = self._prev_screen_timeout or 0
            android.timeout.set(restore_value)
            logger.info("Royal Road: Android screen timeout restored to", restore_value)
        end
        self._prev_screen_timeout = nil
    end
end

return RoyalRoadDownloader
