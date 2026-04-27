local DataStorage    = require("datastorage")
local Device         = require("device")
local Dispatcher     = require("dispatcher")
local LuaSettings    = require("luasettings")
local UIManager      = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs            = require("libs/libkoreader-lfs")
local logger         = require("logger")
local _              = require("gettext")

local RoyalRoadDownloader = WidgetContainer:extend{
    name = "royalroad",
}

local module_names = {
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
    self:showPluginMenu()
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
    self:scheduleAutoUpdateCheck()
end

function RoyalRoadDownloader:scheduleAutoUpdateCheck()
    if not self.auto_check_updates then return end
    if self:countDownloadedStories() == 0 then return end
    local interval_secs = (self.auto_check_interval_hours or 24) * 3600
    local due = os.time() - (self.last_auto_check or 0) >= interval_secs
    if not due then return end
    UIManager:scheduleIn(10, function()
        logger.info("Royal Road: Running automatic update check")
        self.last_auto_check = os.time()
        self:saveSettings()
        local ok, err = pcall(function() self:performUpdateCheck() end)
        if not ok then
            logger.err("Royal Road: Auto update check failed:", err)
        end
    end)
end

function RoyalRoadDownloader:loadSettings()
    self.settings = LuaSettings:open(DataStorage:getSettingsDir().."/royalroad.lua")
    self.downloaded_stories = self.settings:readSetting("downloaded_stories", {})
    self.download_dir = self.settings:readSetting("download_dir", self.default_download_dir)
    self.use_epub = self.settings:readSetting("use_epub", true)
    self.rate_limit_delay = self.settings:readSetting("rate_limit_delay", 1.5)
    self.manage_view_mode = self.settings:readSetting("manage_view_mode", "list")
    self.manage_sort_mode = self.settings:readSetting("manage_sort_mode", "title")
    self.auto_check_updates = self.settings:readSetting("auto_check_updates", false)
    self.auto_check_interval_hours = self.settings:readSetting("auto_check_interval_hours", 24)
    self.last_auto_check = self.settings:readSetting("last_auto_check", 0)
    self._story_count = nil
    local dirty = false
    for fiction_id, story in pairs(self.downloaded_stories) do
        if story.epub_path and not lfs.attributes(story.epub_path, "mode") then
            logger.info("Royal Road: EPUB missing, removing from tracking:", story.title)
            self.downloaded_stories[fiction_id] = nil
            dirty = true
        end
    end
    if dirty then self:saveSettings() end
end

function RoyalRoadDownloader:saveSettings()
    self.settings:saveSetting("downloaded_stories", self.downloaded_stories)
    self.settings:saveSetting("download_dir", self.download_dir)
    self.settings:saveSetting("use_epub", self.use_epub)
    self.settings:saveSetting("rate_limit_delay", self.rate_limit_delay)
    self.settings:saveSetting("manage_view_mode", self.manage_view_mode)
    self.settings:saveSetting("manage_sort_mode", self.manage_sort_mode)
    self.settings:saveSetting("auto_check_updates", self.auto_check_updates)
    self.settings:saveSetting("auto_check_interval_hours", self.auto_check_interval_hours)
    self.settings:saveSetting("last_auto_check", self.last_auto_check)
    self.settings:flush()
end

function RoyalRoadDownloader:countDownloadedStories()
    if self._story_count == nil then
        local count = 0
        for _ in pairs(self.downloaded_stories) do count = count + 1 end
        self._story_count = count
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
