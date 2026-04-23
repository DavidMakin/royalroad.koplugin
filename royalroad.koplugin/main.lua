local DataStorage = require("datastorage")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local ProgressWidget = require("ui/widget/progresswidget")
local Button = require("ui/widget/button")
local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local FrameContainer = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Menu = require("ui/widget/menu")
local TextBoxWidget = require("ui/widget/textboxwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local TextWidget = require("ui/widget/textwidget")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local Font = require("ui/font")
local Size = require("ui/size")
local logger = require("logger")
local _ = require("gettext")
local T = require("ffi/util").template
local socketutil = require("socketutil")
local lfs = require("libs/libkoreader-lfs")

local socket = require("socket")
local http = require("socket.http")
local ltn12 = require("ltn12")
local Device = require("device")

local STORY_COVER_HEIGHT = 100
local STORY_COVER_WIDTH  = math.floor(STORY_COVER_HEIGHT * 2 / 3)
local STORY_ITEM_PAD     = 8

local function extractEpubCover(epub_path)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok then return nil end
    local arc = Archiver.Reader:new()
    if not arc:open(epub_path) then return nil end
    local data
    for entry in arc:iterate() do
        if entry.mode == "file" and entry.path:match("^cover%.[a-z]+$") then
            data = arc:extractToMemory(entry.path)
            break
        end
    end
    arc:close()
    return data
end

local StoryListItem = InputContainer:extend{
    story       = nil,
    width       = nil,
    height      = nil,
    menu        = nil,
    show_parent = nil,
}

function StoryListItem:init()
    self.dimen = Geom:new{ w = self.width, h = self.height }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }

    local inner_cover
    if self.story.cover_bb then
        inner_cover = ImageWidget:new{
            image  = self.story.cover_bb,
            width  = STORY_COVER_WIDTH,
            height = STORY_COVER_HEIGHT,
            alpha  = true,
        }
    else
        local initials = (self.story.title or "?"):sub(1, 2):upper()
        inner_cover = CenterContainer:new{
            dimen = Geom:new{ w = STORY_COVER_WIDTH, h = STORY_COVER_HEIGHT },
            TextWidget:new{
                text    = initials,
                face    = Font:getFace("smalltfont"),
                bold    = true,
                fgcolor = Blitbuffer.COLOR_WHITE,
            },
        }
    end

    local cover_widget = FrameContainer:new{
        width      = STORY_COVER_WIDTH,
        height     = STORY_COVER_HEIGHT,
        padding    = 0,
        bordersize = 1,
        background = self.story.cover_bb and Blitbuffer.COLOR_WHITE or Blitbuffer.gray(0.6),
        inner_cover,
    }

    local text_width = self.width - STORY_COVER_WIDTH - STORY_ITEM_PAD * 3
    local story = self.story
    local info_group = VerticalGroup:new{ align = "left" }

    table.insert(info_group, TextBoxWidget:new{
        text  = story.title or "",
        face  = Font:getFace("smalltfont"),
        width = text_width,
        bold  = true,
    })
    if story.author and story.author ~= "" then
        table.insert(info_group, VerticalSpan:new{ width = 2 })
        table.insert(info_group, TextWidget:new{
            text      = story.author,
            face      = Font:getFace("smallffont"),
            max_width = text_width,
            fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    local n_chapters = story.chapter_urls and #story.chapter_urls or 0
    if n_chapters > 0 then
        table.insert(info_group, VerticalSpan:new{ width = 2 })
        table.insert(info_group, TextWidget:new{
            text      = T(_("%1 chapters"), n_chapters),
            face      = Font:getFace("smallffont"),
            max_width = text_width,
            fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    local TopContainer = require("ui/widget/container/topcontainer")
    self[1] = FrameContainer:new{
        width      = self.width,
        height     = self.height,
        padding    = 0,
        margin     = 0,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            VerticalSpan:new{ width = STORY_ITEM_PAD },
            HorizontalGroup:new{
                align = "top",
                HorizontalSpan:new{ width = STORY_ITEM_PAD },
                cover_widget,
                HorizontalSpan:new{ width = STORY_ITEM_PAD },
                TopContainer:new{
                    dimen = Geom:new{ w = text_width, h = STORY_COVER_HEIGHT },
                    info_group,
                },
            },
            VerticalSpan:new{ width = STORY_ITEM_PAD },
        },
    }
end

function StoryListItem:update()
    self:init()
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

function StoryListItem:onTapSelect()
    if self.menu then
        self.menu:onStorySelect(self.story)
    end
    return true
end

local GRID_COLS     = 3
local GRID_CELL_GAP = 6
local GRID_ROW_GAP  = 8

local StoryCoverCell = InputContainer:extend{
    story       = nil,
    cell_width  = nil,
    cell_height = nil,
    cover_width = nil,
    cover_height = nil,
    show_parent = nil,
    menu        = nil,
}

function StoryCoverCell:init()
    self.dimen = Geom:new{ w = self.cell_width, h = self.cell_height }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
    }

    local inner_cover
    if self.story.cover_bb then
        inner_cover = ImageWidget:new{
            image  = self.story.cover_bb,
            width  = self.cover_width,
            height = self.cover_height,
            alpha  = true,
        }
    else
        local initials = (self.story.title or "?"):sub(1, 2):upper()
        inner_cover = CenterContainer:new{
            dimen = Geom:new{ w = self.cover_width, h = self.cover_height },
            TextWidget:new{
                text    = initials,
                face    = Font:getFace("smalltfont"),
                bold    = true,
                fgcolor = Blitbuffer.COLOR_WHITE,
            },
        }
    end

    local cover_widget = FrameContainer:new{
        width      = self.cover_width,
        height     = self.cover_height,
        padding    = 0,
        bordersize = 1,
        background = self.story.cover_bb and Blitbuffer.COLOR_WHITE or Blitbuffer.gray(0.6),
        inner_cover,
    }

    local title_height = math.ceil(14 * 1.3) * 2
    local title_widget = TextBoxWidget:new{
        text      = self.story.title or "",
        face      = Font:getFace("smallffont", 14),
        width     = self.cover_width,
        height    = title_height,
        alignment = "center",
    }

    self[1] = FrameContainer:new{
        width      = self.cell_width,
        height     = self.cell_height,
        padding    = GRID_CELL_GAP,
        bordersize = 0,
        background = Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.cover_width, h = self.cover_height + 4 + title_height },
            VerticalGroup:new{
                align = "center",
                cover_widget,
                VerticalSpan:new{ width = 4 },
                title_widget,
            },
        },
    }
end

function StoryCoverCell:update()
    self:init()
    UIManager:setDirty(self.show_parent, function()
        return "ui", self.dimen
    end)
end

function StoryCoverCell:onTapSelect()
    if self.menu then
        self.menu:onStorySelect(self.story)
    end
    return true
end

local RoyalRoadDownloader = WidgetContainer:extend{
    name = "royalroad",
}

function RoyalRoadDownloader:init()
    self.ui.menu:registerToMainMenu(self)
    self.default_download_dir = ("%s/%s"):format(DataStorage:getFullDataDir(), "royalroad")
    self.debug_chapter_limit = nil  -- Set to a number to limit chapters for testing
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
    self.rate_limit_delay = self.settings:readSetting("rate_limit_delay", 1.5)
    self.manage_view_mode = self.settings:readSetting("manage_view_mode", "list")
end

function RoyalRoadDownloader:saveSettings()
    self.settings:saveSetting("downloaded_stories", self.downloaded_stories)
    self.settings:saveSetting("download_dir", self.download_dir)
    self.settings:saveSetting("use_epub", self.use_epub)
    self.settings:saveSetting("rate_limit_delay", self.rate_limit_delay)
    self.settings:saveSetting("manage_view_mode", self.manage_view_mode)
    self.settings:flush()
end

function RoyalRoadDownloader:countDownloadedStories()
    local count = 0
    for _ in pairs(self.downloaded_stories) do
        count = count + 1
    end
    return count
end

-- Keep screen awake during long downloads (device-aware)
function RoyalRoadDownloader:keepScreenAwake()
    logger.info("Royal Road: Enabling screen wake lock")
    UIManager:preventStandby()
    -- On Android, also use the Android-specific screen timeout API
    if Device:isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android and android.timeout then
            -- Store previous timeout to restore later
            if android.timeout.get then
                self._prev_screen_timeout = android.timeout.get()
            end
            -- Keep screen on: -1 = AKEEP_SCREEN_ON_ENABLED
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
    -- On Android, restore previous timeout
    if Device:isAndroid() then
        local ok, android = pcall(require, "android")
        if ok and android and android.timeout and android.timeout.set then
            -- Restore previous timeout or use default (0 = AKEEP_SCREEN_ON_DISABLED = system default)
            local restore_value = self._prev_screen_timeout or 0
            android.timeout.set(restore_value)
            logger.info("Royal Road: Android screen timeout restored to", restore_value)
        end
        self._prev_screen_timeout = nil
    end
end

function RoyalRoadDownloader:addToMainMenu(menu_items)
    menu_items.royalroad = {
        text = _("Royal Road"),
        sub_item_table = {
            {
                text = _("Download story"),
                keep_menu_open = true,
                callback = function()
                    self:downloadStory()
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
                        return T(_("Manage downloads (%1)"), count)
                    else
                        return _("Manage downloads")
                    end
                end,
                callback = function()
                    self:manageDownloads()
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
                            return T(_("Download folder: …/%1"), short)
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
                        sub_item_table = {
                            {
                                text = _("EPUB"),
                                checked_func = function() return self.use_epub end,
                                callback = function()
                                    self.use_epub = true
                                    self:saveSettings()
                                end,
                            },
                            {
                                text = _("HTML"),
                                checked_func = function() return not self.use_epub end,
                                callback = function()
                                    self.use_epub = false
                                    self:saveSettings()
                                end,
                            },
                        },
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
                        sub_item_table = {
                            {
                                text = _("List"),
                                checked_func = function() return self.manage_view_mode == "list" end,
                                callback = function()
                                    self.manage_view_mode = "list"
                                    self:saveSettings()
                                end,
                            },
                            {
                                text = _("Cover mosaic"),
                                checked_func = function() return self.manage_view_mode == "mosaic" end,
                                callback = function()
                                    self.manage_view_mode = "mosaic"
                                    self:saveSettings()
                                end,
                            },
                        },
                    },
                },
            },
        },
    }
end

function RoyalRoadDownloader:setRateLimit()
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

function RoyalRoadDownloader:chooseDownloadFolder()
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

function RoyalRoadDownloader:openDownloadsFolder()
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

function RoyalRoadDownloader:manageDownloads()
    if self:countDownloadedStories() == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No downloaded stories."),
            timeout = 3,
        })
        return
    end

    local item_table = {}
    for fiction_id, story in pairs(self.downloaded_stories) do
        table.insert(item_table, {
            fiction_id   = fiction_id,
            title        = story.title or "Unknown",
            author       = story.author,
            chapter_urls = story.chapter_urls,
            epub_path    = story.epub_path,
            text         = story.title or "Unknown",
        })
    end
    table.sort(item_table, function(a, b)
        return (a.title or "") < (b.title or "")
    end)

    local item_height = STORY_COVER_HEIGHT + STORY_ITEM_PAD * 2
    local downloader  = self

    if self.manage_view_mode == "mosaic" then
        local screen_w   = Device.screen:getWidth()
        local cell_gap   = GRID_CELL_GAP
        local cell_w     = math.floor((screen_w - cell_gap * (GRID_COLS - 1)) / GRID_COLS)
        local cover_w    = cell_w - GRID_CELL_GAP * 2
        local cover_h    = math.floor(cover_w * 3 / 2)
        local title_h    = math.ceil(14 * 1.3) * 2
        local cell_h     = cover_h + 4 + title_h + GRID_CELL_GAP * 2

        local StoryMosaicMenu = Menu:extend{
            _items_pending = {},
        }

        function StoryMosaicMenu:_recalculateDimen()
            local available_h = self.inner_dimen and self.inner_dimen.h or (Device.screen:getHeight() - 100)
            local rows_per_page = math.max(1, math.floor(available_h / (cell_h + GRID_ROW_GAP)))
            self.perpage   = rows_per_page * GRID_COLS
            self.page_num  = math.ceil(#self.item_table / self.perpage)
            if self.page_num > 0 and self.page > self.page_num then
                self.page = self.page_num
            end
            self.item_width  = self.inner_dimen and self.inner_dimen.w or screen_w
            self.item_height = cell_h
            self.item_dimen  = Geom:new{ x = 0, y = 0, w = self.item_width, h = self.item_height }
        end

        function StoryMosaicMenu:updateItems(select_number)
            self.layout = {}
            self.item_group:clear()
            local old_dimen = self.dimen and self.dimen:copy()
            self:_recalculateDimen()
            self.page_info:resetLayout()
            self.return_button:resetLayout()
            self._items_pending = {}

            local idx_offset = (self.page - 1) * self.perpage
            local rows_per_page = self.perpage / GRID_COLS

            for row_i = 1, rows_per_page do
                local row = HorizontalGroup:new{ align = "top" }
                local row_layout = {}
                for col = 1, GRID_COLS do
                    local entry = self.item_table[idx_offset + (row_i - 1) * GRID_COLS + col]
                    if entry then
                        local cell = StoryCoverCell:new{
                            story        = entry,
                            cell_width   = cell_w,
                            cell_height  = cell_h,
                            cover_width  = cover_w,
                            cover_height = cover_h,
                            show_parent  = self.show_parent,
                            menu         = self,
                        }
                        table.insert(row, cell)
                        table.insert(row_layout, cell)
                        if col < GRID_COLS then
                            table.insert(row, HorizontalSpan:new{ width = cell_gap })
                        end
                        if not entry.cover_bb and entry.epub_path and lfs.attributes(entry.epub_path, "mode") then
                            table.insert(self._items_pending, { entry = entry, widget = cell })
                        end
                    end
                end
                table.insert(self.item_group, row)
                table.insert(self.layout, row_layout)
                table.insert(self.item_group, VerticalSpan:new{ width = GRID_ROW_GAP })
            end

            self:updatePageInfo(select_number)
            UIManager:setDirty(self.show_parent, function()
                local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
                return "ui", refresh_dimen
            end)

            if #self._items_pending > 0 then
                UIManager:scheduleIn(0.1, function() self:_loadCovers() end)
            end
        end

        function StoryMosaicMenu:_loadCovers()
            local RenderImage = require("ui/renderimage")
            for _, pending in ipairs(self._items_pending) do
                local entry  = pending.entry
                local widget = pending.widget
                if not entry.cover_bb then
                    local cover_data = extractEpubCover(entry.epub_path)
                    if cover_data then
                        local ok, bb = pcall(function()
                            return RenderImage:renderImageData(
                                cover_data, #cover_data, false, cover_w, cover_h)
                        end)
                        if ok and bb then
                            entry.cover_bb = bb
                            widget:update()
                        end
                    end
                end
            end
            self._items_pending = {}
        end

        function StoryMosaicMenu:onStorySelect(story)
            downloader:showStoryOptions(story.fiction_id)
        end

        function StoryMosaicMenu:onCloseWidget()
            for _, entry in ipairs(self.item_table) do
                if entry.cover_bb then
                    entry.cover_bb:free()
                    entry.cover_bb = nil
                end
            end
            Menu.onCloseWidget(self)
        end

        local menu = StoryMosaicMenu:new{
            covers_fullscreen  = true,
            is_borderless      = true,
            is_popout          = false,
            title              = T(_("Downloads (%1)"), #item_table),
            item_table         = item_table,
            title_bar_fm_style = true,
        }
        downloader.manage_menu = menu
        UIManager:show(menu)
        return
    end

    local StoryListMenu = Menu:extend{
        _items_pending = {},
    }

    function StoryListMenu:_recalculateDimen()
        local available_h = self.inner_dimen and self.inner_dimen.h or (Device.screen:getHeight() - 100)
        self.perpage     = math.max(1, math.floor(available_h / item_height))
        self.page_num    = math.ceil(#self.item_table / self.perpage)
        if self.page_num > 0 and self.page > self.page_num then
            self.page = self.page_num
        end
        self.item_width  = self.inner_dimen and self.inner_dimen.w or Device.screen:getWidth()
        self.item_height = item_height
        self.item_dimen  = Geom:new{ x = 0, y = 0, w = self.item_width, h = self.item_height }
    end

    function StoryListMenu:updateItems(select_number)
        self.layout = {}
        self.item_group:clear()
        local old_dimen = self.dimen and self.dimen:copy()
        self:_recalculateDimen()
        self.page_info:resetLayout()
        self.return_button:resetLayout()
        self._items_pending = {}

        local idx_offset = (self.page - 1) * self.perpage
        for i = 1, self.perpage do
            local entry = self.item_table[idx_offset + i]
            if not entry then break end

            local w      = self.item_width or Device.screen:getWidth()
            local widget = StoryListItem:new{
                story       = entry,
                width       = w,
                height      = item_height,
                show_parent = self.show_parent,
                menu        = self,
            }
            table.insert(self.item_group, widget)

            if i < self.perpage and (idx_offset + i) < #self.item_table then
                local LineWidget = require("ui/widget/linewidget")
                table.insert(self.item_group, LineWidget:new{
                    dimen      = Geom:new{ w = w, h = Size.line.thin },
                    background = Blitbuffer.COLOR_LIGHT_GRAY,
                })
            end

            table.insert(self.layout, { widget })

            if not entry.cover_bb and entry.epub_path and lfs.attributes(entry.epub_path, "mode") then
                table.insert(self._items_pending, { entry = entry, widget = widget })
            end
        end

        self:updatePageInfo(select_number)
        UIManager:setDirty(self.show_parent, function()
            local refresh_dimen = old_dimen and old_dimen:combine(self.dimen) or self.dimen
            return "ui", refresh_dimen
        end)

        if #self._items_pending > 0 then
            UIManager:scheduleIn(0.1, function()
                self:_loadCovers()
            end)
        end
    end

    function StoryListMenu:_loadCovers()
        local RenderImage = require("ui/renderimage")
        for _, pending in ipairs(self._items_pending) do
            local entry  = pending.entry
            local widget = pending.widget
            if not entry.cover_bb then
                local cover_data = extractEpubCover(entry.epub_path)
                if cover_data then
                    local ok, bb = pcall(function()
                        return RenderImage:renderImageData(
                            cover_data, #cover_data, false,
                            STORY_COVER_WIDTH, STORY_COVER_HEIGHT)
                    end)
                    if ok and bb then
                        entry.cover_bb = bb
                        widget:update()
                    end
                end
            end
        end
        self._items_pending = {}
    end

    function StoryListMenu:onStorySelect(story)
        downloader:showStoryOptions(story.fiction_id)
    end

    function StoryListMenu:onCloseWidget()
        for _, entry in ipairs(self.item_table) do
            if entry.cover_bb then
                entry.cover_bb:free()
                entry.cover_bb = nil
            end
        end
        Menu.onCloseWidget(self)
    end

    local menu = StoryListMenu:new{
        covers_fullscreen  = true,
        is_borderless      = true,
        is_popout          = false,
        title              = T(_("Downloads (%1)"), #item_table),
        item_table         = item_table,
        title_bar_fm_style = true,
    }
    downloader.manage_menu = menu
    UIManager:show(menu)
end

function RoyalRoadDownloader:downloadStory()
    self.input_dialog = InputDialog:new{
        title = _("Enter Royal Road Fiction ID"),
        input_hint = _("e.g., 73475"),
        input_type = "number",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self.input_dialog)
                    end,
                },
                {
                    text = _("Download"),
                    is_enter_default = true,
                    callback = function()
                        local fiction_id = self.input_dialog:getInputText()
                        UIManager:close(self.input_dialog)
                        if fiction_id and fiction_id ~= "" then
                            self:processFiction(fiction_id)
                        end
                    end,
                },
            },
        },
    }
    UIManager:show(self.input_dialog)
    self.input_dialog:onShowKeyboard()
end

function RoyalRoadDownloader:processFiction(fiction_id)
    logger.info("Royal Road: Processing fiction ID:", fiction_id)

    if self.downloaded_stories[fiction_id] then
        self:checkSingleStoryForUpdates(fiction_id)
        return
    end

    UIManager:show(InfoMessage:new{
        text = T(_("Fetching story %1..."), fiction_id),
        timeout = 2,
    })

    local fiction_url = "https://www.royalroad.com/fiction/" .. fiction_id
    local story_html = self:fetchPage(fiction_url)

    if not story_html then
        UIManager:show(InfoMessage:new{
            text = _("Failed to fetch story page."),
            timeout = 5,
        })
        return
    end

    local story_title = self:extractTitle(story_html)
    local author = self:extractAuthor(story_html)
    local chapter_urls = self:extractChapterURLs(story_html, fiction_id)
    local cover_url = self:extractCoverURL(story_html)

    if not story_title or #chapter_urls == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to parse story.\nTitle: %1\nChapters: %2"),
                story_title or "NONE", #chapter_urls),
            timeout = 10,
        })
        return
    end

    logger.info("Royal Road: Cover URL:", cover_url or "none found")

    -- Download cover image
    local cover_image = nil
    if cover_url then
        UIManager:show(InfoMessage:new{
            text = _("Downloading cover image..."),
            timeout = 1,
        })
        local image_data, mime_type, extension = self:fetchImage(cover_url)
        if image_data then
            cover_image = {
                data = image_data,
                mime_type = mime_type,
                extension = extension,
            }
        end
    end

    -- Apply debug chapter limit if set
    local total_available = #chapter_urls
    if self.debug_chapter_limit and #chapter_urls > self.debug_chapter_limit then
        local limited_urls = {}
        for i = 1, self.debug_chapter_limit do
            table.insert(limited_urls, chapter_urls[i])
        end
        chapter_urls = limited_urls
        logger.info("Royal Road: DEBUG - Limited from", total_available, "to", #chapter_urls, "chapters")
    end

    local download_msg = T(_("Found: %1\nBy: %2\nChapters: %3\n\nDownloading..."),
                 story_title, author or "Unknown", #chapter_urls)
    if self.debug_chapter_limit and total_available > #chapter_urls then
        download_msg = T(_("Found: %1\nBy: %2\nChapters: %3 (of %4 - DEBUG LIMIT)\n\nDownloading..."),
                 story_title, author or "Unknown", #chapter_urls, total_available)
    end

    UIManager:show(InfoMessage:new{
        text = download_msg,
        timeout = 3,
    })

    self:downloadChapters(fiction_id, story_title, author, chapter_urls, cover_image, cover_url)
end

function RoyalRoadDownloader:fetchPage(page_url)
    local response_body = {}
    local request = {
        url = page_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader/1.0)",
            ["Accept"] = "text/html",
        },
    }

    socketutil:set_timeout(10, 60)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.warn("Royal Road: HTTP", code, status)
        return nil
    end

    return table.concat(response_body)
end

function RoyalRoadDownloader:fetchImage(image_url)
    if not image_url then return nil, nil end

    local response_body = {}
    local request = {
        url = image_url,
        method = "GET",
        sink = ltn12.sink.table(response_body),
        headers = {
            ["User-Agent"] = "Mozilla/5.0 (compatible; KOReader/1.0)",
            ["Accept"] = "image/*",
        },
    }

    socketutil:set_timeout(10, 60)
    local code, headers, status = socket.skip(1, http.request(request))
    socketutil:reset_timeout()

    if code ~= 200 then
        logger.warn("Royal Road: Failed to download cover image, HTTP", code)
        return nil, nil
    end

    local image_data = table.concat(response_body)
    if #image_data == 0 then
        logger.warn("Royal Road: Cover image is empty")
        return nil, nil
    end

    -- Determine image type from URL
    local mime_type = "image/jpeg"
    local extension = "jpg"
    if image_url:match("%.png") then
        mime_type = "image/png"
        extension = "png"
    elseif image_url:match("%.gif") then
        mime_type = "image/gif"
        extension = "gif"
    elseif image_url:match("%.webp") then
        mime_type = "image/webp"
        extension = "webp"
    end

    logger.info("Royal Road: Downloaded cover image,", #image_data, "bytes")
    return image_data, mime_type, extension
end

function RoyalRoadDownloader:extractTitle(html)
    local title = html:match('<h1[^>]*property="name"[^>]*>%s*(.-)%s*</h1>')
        or html:match('<h1[^>]*>%s*(.-)%s*</h1>')
    if title then
        title = title:gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&#39;", "'")
        title = title:gsub("<[^>]+>", "")
    end
    return title
end

function RoyalRoadDownloader:extractAuthor(html)
    local author = html:match('property="author"[^>]*>%s*<span[^>]*>%s*(.-)%s*</span>')
        or html:match('<meta%s+property="books:author"%s+content="([^"]+)"')
    if author then
        author = author:gsub("&quot;", '"'):gsub("&amp;", "&")
    end
    return author or "Unknown"
end

function RoyalRoadDownloader:extractChapterURLs(html, fiction_id)
    local chapters = {}
    local seen = {}  -- Deduplicate

    -- Get story slug from URL in the page
    local story_slug = html:match('/fiction/' .. fiction_id .. '/([^/"]+)') or "story"

    -- Method 1: Parse window.chapters JavaScript array (newer RR pages)
    -- Look for pattern: "id":1234,..."slug":"chapter-slug" in the chapters array
    -- Search entire HTML since the array can be very large
    if html:find('window%.chapters%s*=') then
        for chapter_id, slug in html:gmatch('"id":(%d+),"volumeId":%d+,"title":"[^"]*","slug":"([^"]+)"') do
            local full_url = string.format("https://www.royalroad.com/fiction/%s/%s/chapter/%s/%s",
                fiction_id, story_slug, chapter_id, slug)
            if not seen[full_url] then
                seen[full_url] = true
                table.insert(chapters, full_url)
            end
        end
        if #chapters > 0 then
            logger.info("Royal Road: Extracted", #chapters, "chapters from window.chapters")
        end
    end

    -- Method 2: Fallback to href parsing (older RR pages or if method 1 failed)
    if #chapters == 0 then
        for chapter_path in html:gmatch('href="(/fiction/' .. fiction_id .. '/[^/]+/chapter/%d+/[^"]+)"') do
            local full_url = "https://www.royalroad.com" .. chapter_path
            if not seen[full_url] then
                seen[full_url] = true
                table.insert(chapters, full_url)
            end
        end
        logger.info("Royal Road: Extracted", #chapters, "chapters from href links")
    end

    return chapters
end

function RoyalRoadDownloader:extractCoverURL(html)
    -- Try window.fictionCover JavaScript variable first
    local cover_url = html:match('window%.fictionCover%s*=%s*"([^"]+)"')
    -- Try og:image meta tag
    if not cover_url then
        cover_url = html:match('<meta%s+property="og:image"%s+content="([^"]+)"')
            or html:match('<meta%s+content="([^"]+)"%s+property="og:image"')
    end
    -- Try cover image in the page
    if not cover_url then
        cover_url = html:match('class="[^"]*cover[^"]*"[^>]*>%s*<img[^>]*src="([^"]+)"')
            or html:match('<img[^>]*src="(https://www%.royalroadcdn%.com/public/covers[^"]+)"')
    end
    return cover_url
end

function RoyalRoadDownloader:downloadChapters(fiction_id, story_title, author, chapter_urls, cover_image, cover_url)
    local total_chapters = #chapter_urls
    local chapters_data = {}
    local start_time = socket.gettime()

    -- Prevent device from sleeping during download
    self:keepScreenAwake()

    local screen_width = Device.screen:getWidth()
    local dialog_width = math.floor(screen_width * 0.8)

    local title_widget = TextWidget:new{
        text = _("Downloading..."),
        face = Font:getFace("smalltfont"),
        bold = true,
    }

    local progress_text = TextWidget:new{
        text = T(_("Chapter 0/%1"), total_chapters),
        face = Font:getFace("smallffont"),
    }

    local eta_text = TextWidget:new{
        text = _("Calculating ETA..."),
        face = Font:getFace("smallffont"),
    }

    local progress_bar = ProgressWidget:new{
        width = dialog_width - Size.padding.large * 2,
        height = Size.item.height_default / 3,
        percentage = 0,
        margin_h = 0,
        margin_v = Size.padding.small,
        radius = Size.radius.default,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        fillcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    -- State table declared early so the cancel button closure can reference it
    local state = {
        fiction_id = fiction_id,
        story_title = story_title,
        author = author,
        chapter_urls = chapter_urls,
        cover_image = cover_image,
        cover_url = cover_url,
        total_chapters = total_chapters,
        chapters_data = chapters_data,
        start_time = start_time,
        cancelled = false,
    }

    local cancel_button = Button:new{
        text = _("Cancel"),
        callback = function()
            state.cancelled = true
        end,
    }

    local progress_group = VerticalGroup:new{
        align = "center",
        title_widget,
        progress_text,
        progress_bar,
        eta_text,
        cancel_button,
    }

    local progress_frame = FrameContainer:new{
        padding = Size.padding.large,
        margin = Size.margin.default,
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.window,
        progress_group,
    }

    local progress_dialog = CenterContainer:new{
        dimen = Device.screen:getSize(),
        progress_frame,
    }

    UIManager:show(progress_dialog)

    state.progress_dialog = progress_dialog
    state.progress_text = progress_text
    state.eta_text = eta_text
    state.progress_bar = progress_bar

    -- Start async download loop
    self:downloadNextChapter(state, 1)
end

function RoyalRoadDownloader:downloadNextChapter(state, i)
    if state.cancelled then
        UIManager:close(state.progress_dialog)
        self:allowScreenSleep()
        if #state.chapters_data > 0 then
            local fetched_urls = {}
            for j = 1, #state.chapters_data do
                fetched_urls[j] = state.chapter_urls[j]
            end
            if self.use_epub then
                self:saveAsEPUB(state.fiction_id, state.story_title, state.author, state.chapters_data, state.cover_image, fetched_urls, state.cover_url)
            else
                self:saveAsHTML(state.fiction_id, state.story_title, state.author, state.chapters_data)
            end
            UIManager:show(InfoMessage:new{
                text = T(_("Download cancelled.\nSaved %1 of %2 chapters.\nDownload again to get the rest."),
                    #state.chapters_data, state.total_chapters),
                timeout = 5,
            })
        else
            UIManager:show(InfoMessage:new{
                text = _("Download cancelled."),
                timeout = 3,
            })
        end
        return
    end

    if i > state.total_chapters then
        UIManager:close(state.progress_dialog)

        if #state.chapters_data > 0 then
            if self.use_epub then
                self:saveAsEPUB(state.fiction_id, state.story_title, state.author, state.chapters_data, state.cover_image, state.chapter_urls, state.cover_url)
            else
                self:saveAsHTML(state.fiction_id, state.story_title, state.author, state.chapters_data)
            end
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to download chapters."),
            })
        end
        self:allowScreenSleep()
        return
    end

    state.progress_text:setText(T(_("Chapter %1/%2"), i, state.total_chapters))
    state.progress_bar:setPercentage(i / state.total_chapters)
    if i > 1 then
        local elapsed = socket.gettime() - state.start_time
        local avg_time = elapsed / (i - 1)
        local eta_seconds = avg_time * (state.total_chapters - i + 1)
        local eta_min = math.floor(eta_seconds / 60)
        local eta_sec = math.floor(eta_seconds % 60)
        state.eta_text:setText(T(_("ETA: %1m %2s"), eta_min, eta_sec))
    end
    UIManager:setDirty(state.progress_dialog, "ui")

    -- Schedule the actual download after a brief delay to let UI update
    UIManager:scheduleIn(0.01, function()
        local chapter_url = state.chapter_urls[i]
        local chapter_html = self:fetchPage(chapter_url)

        if chapter_html then
            local chapter_title = self:extractChapterTitle(chapter_html)
            local chapter_content = self:extractChapterContent(chapter_html)

            if chapter_title and chapter_content then
                table.insert(state.chapters_data, {
                    title = chapter_title,
                    content = chapter_content,
                })
            else
                logger.warn("Royal Road: Failed to extract chapter", i, "from", chapter_url)
                table.insert(state.chapters_data, {
                    title = "Chapter " .. i,
                    content = "<p>[Chapter content could not be extracted.]</p>",
                })
            end
        else
            logger.warn("Royal Road: Failed to fetch chapter", i, "from", chapter_url)
            table.insert(state.chapters_data, {
                title = "Chapter " .. i,
                content = "<p>[Chapter failed to download.]</p>",
            })
        end

        -- Schedule next chapter after rate limit delay
        UIManager:scheduleIn(self.rate_limit_delay, function()
            self:downloadNextChapter(state, i + 1)
        end)
    end)
end

function RoyalRoadDownloader:extractChapterTitle(html)
    local title = html:match('<h1[^>]*>%s*(.-)%s*</h1>')
        or html:match('<h2[^>]*>%s*(.-)%s*</h2>')
    if title then
        title = title:gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&#39;", "'")
        title = title:gsub("<[^>]+>", "")
    end
    return title or "Chapter"
end

function RoyalRoadDownloader:extractChapterContent(html)
    local div_open = html:find('<div[^>]-class="[^"]-chapter%-content[^"]-"', 1)
    if not div_open then return nil end

    local tag_end = html:find('>', div_open)
    if not tag_end then return nil end

    local pos = tag_end + 1
    local content_start = pos
    local depth = 1

    while depth > 0 do
        local open_pos = html:find('<div', pos, true)
        local close_pos = html:find('</div>', pos, true)
        if not close_pos then break end

        if open_pos and open_pos < close_pos then
            depth = depth + 1
            pos = open_pos + 4
        else
            depth = depth - 1
            if depth == 0 then
                local content = html:sub(content_start, close_pos - 1)
                content = content:gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&#39;", "'"):gsub("&nbsp;", " ")
                return content
            end
            pos = close_pos + 6
        end
    end

    return nil
end

function RoyalRoadDownloader:ensureDownloadDir()
    if not lfs.attributes(self.download_dir, "mode") then
        logger.info("Royal Road: Creating directory:", self.download_dir)
        lfs.mkdir(self.download_dir)
    end
end

function RoyalRoadDownloader:saveAsHTML(fiction_id, story_title, author, chapters)
    self:ensureDownloadDir()

    local html_parts = {
        '<!DOCTYPE html>',
        '<html>',
        '<head>',
        '<meta charset="utf-8"/>',
        '<title>' .. story_title .. '</title>',
        '</head>',
        '<body>',
        '<h1>' .. story_title .. '</h1>',
        '<p><em>By ' .. author .. '</em></p>',
        '<hr/>',
    }

    for i, chapter in ipairs(chapters) do
        table.insert(html_parts, '<div>')
        table.insert(html_parts, '<h2>' .. chapter.title .. '</h2>')
        table.insert(html_parts, chapter.content)
        table.insert(html_parts, '</div><hr/>')
    end

    table.insert(html_parts, '</body></html>')

    local full_html = table.concat(html_parts, "\n")
    local safe_title = story_title:gsub("[^%w%s%-]", ""):gsub("%s+", "_")
    local filename = string.format("%s/%s_%s.html", self.download_dir, safe_title, fiction_id)

    local file = io.open(filename, "w")
    if file then
        file:write(full_html)
        file:close()
        UIManager:show(InfoMessage:new{
            text = T(_("Saved HTML:\n%1\n\n%2 chapters"), filename, #chapters),
            timeout = 10,
        })
        logger.info("Royal Road: Saved", filename)
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to write file:\n%1"), filename),
        })
    end
end

function RoyalRoadDownloader:escapeXML(text)
    if not text then return "" end
    return text:gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
end

-- Extract chapters from an existing EPUB file
-- Returns array of {title, content} tables, or nil on error
function RoyalRoadDownloader:extractChaptersFromEPUB(epub_path)
    local Archiver = require("ffi/archiver")

    local arc = Archiver.Reader:new()
    if not arc:open(epub_path) then
        logger.warn("Royal Road: Failed to open EPUB for reading:", epub_path)
        return nil, "Failed to open EPUB"
    end

    -- First pass: find all chapter files and their order from content.opf
    local chapter_files = {}  -- Array of chapter filenames in order
    local file_contents = {}  -- Map of path -> content

    -- Read all files we need
    logger.info("Royal Road: Reading EPUB contents...")
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local path = entry.path
            logger.dbg("Royal Road: EPUB entry:", path)
            -- Store content.opf to parse chapter order
            if path:match("content%.opf$") then
                file_contents["content.opf"] = arc:extractToMemory(path)
                logger.info("Royal Road: Found content.opf")
            -- Store all chapter files
            elseif path:match("chapter_%d+%.xhtml$") then
                file_contents[path] = arc:extractToMemory(path)
                logger.info("Royal Road: Found chapter file:", path)
            end
        end
    end
    arc:close()

    -- Parse content.opf to get chapter order
    local opf_content = file_contents["content.opf"]
    if not opf_content then
        logger.warn("Royal Road: No content.opf found in EPUB")
        return nil, "No content.opf found"
    end

    -- Extract chapter file names from spine (which defines reading order)
    -- Pattern: <itemref idref="chapter-001"/> and <item id="chapter-001" href="chapter_001.xhtml".../>
    local id_to_href = {}
    for id, href in opf_content:gmatch('<item[^>]+id="([^"]+)"[^>]+href="([^"]+)"') do
        id_to_href[id] = href
    end
    -- Also try alternate attribute order
    for href, id in opf_content:gmatch('<item[^>]+href="([^"]+)"[^>]+id="([^"]+)"') do
        id_to_href[id] = href
    end

    -- Get spine order
    for idref in opf_content:gmatch('<itemref[^>]+idref="([^"]+)"') do
        local href = id_to_href[idref]
        if href and href:match("chapter_") then
            local full_path = "OEBPS/" .. href
            table.insert(chapter_files, full_path)
            logger.dbg("Royal Road: Spine chapter:", idref, "->", full_path)
        end
    end

    logger.info("Royal Road: Found", #chapter_files, "chapters in spine, have", #file_contents, "files loaded")

    -- Extract chapter content
    local chapters = {}
    for i, filepath in ipairs(chapter_files) do
        local content = file_contents[filepath]
        if content then
            -- Parse title from <title> tag or <h2> tag
            local title = content:match("<title>([^<]+)</title>")
                       or content:match("<h2>([^<]+)</h2>")
                       or "Untitled Chapter"

            -- Parse chapter content from body
            -- The format is: <div class="chapter"><h2>Title</h2>CONTENT</div>
            local chapter_content = content:match('<div class="chapter">.-</h2>(.+)</div>%s*</body>')
            if not chapter_content then
                -- Fallback: get everything in body
                chapter_content = content:match("<body>(.+)</body>")
            end

            table.insert(chapters, {
                title = title,
                content = chapter_content or "",
            })
        else
            logger.warn("Royal Road: Missing chapter file:", filepath)
        end
    end

    logger.info("Royal Road: Extracted", #chapters, "chapters from EPUB")
    return chapters
end

function RoyalRoadDownloader:saveAsEPUB(fiction_id, story_title, author, chapters, cover_image, chapter_urls, cover_url)
    self:ensureDownloadDir()

    local safe_title = story_title:gsub("[^%w%s%-]", ""):gsub("%s+", "_")
    local filename = string.format("%s/%s_%s.epub", self.download_dir, safe_title, fiction_id)

    -- Try to use Archiver for EPUB creation
    local ok, result = pcall(function()
        local Archiver = require("ffi/archiver")
        local epub = Archiver.Writer:new{}
        if not epub:open(filename, "epub") then
            error("Failed to create EPUB file")
        end

        local book_id = "royalroad-" .. fiction_id
        local escaped_title = self:escapeXML(story_title)
        local escaped_author = self:escapeXML(author)

        -- 1. mimetype (must be first and uncompressed)
        epub:addFileFromMemory("mimetype", "application/epub+zip")

        -- 2. META-INF/container.xml
        local container_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="OEBPS/content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
        epub:addFileFromMemory("META-INF/container.xml", container_xml)

        -- 3. Build manifest and spine entries
        local manifest_items = {}
        local spine_items = {}
        local nav_points = {}
        local play_order = 1

        -- Add cover if available
        local has_cover = cover_image and cover_image.data
        if has_cover then
            -- Use path relative to OPF (which is in OEBPS/), so ../cover.jpg points to root
            local cover_filename = "../cover." .. cover_image.extension
            -- Note: properties="cover-image" is EPUB3 only, using EPUB2 meta instead
            table.insert(manifest_items, string.format(
                '    <item id="cover-image" href="%s" media-type="%s"/>',
                cover_filename, cover_image.mime_type))
            table.insert(manifest_items,
                '    <item id="cover" href="cover.xhtml" media-type="application/xhtml+xml"/>')
            table.insert(spine_items, '    <itemref idref="cover"/>')

            -- Cover page nav point
            table.insert(nav_points, string.format([[    <navPoint id="navpoint-%d" playOrder="%d">
      <navLabel><text>Cover</text></navLabel>
      <content src="cover.xhtml"/>
    </navPoint>]], play_order, play_order))
            play_order = play_order + 1
        end

        -- Add title page
        table.insert(manifest_items,
            '    <item id="title-page" href="title.xhtml" media-type="application/xhtml+xml"/>')
        table.insert(spine_items, '    <itemref idref="title-page"/>')
        table.insert(nav_points, string.format([[    <navPoint id="navpoint-%d" playOrder="%d">
      <navLabel><text>Title Page</text></navLabel>
      <content src="title.xhtml"/>
    </navPoint>]], play_order, play_order))
        play_order = play_order + 1

        -- Add chapters
        for i, chapter in ipairs(chapters) do
            local chapter_id = string.format("chapter-%03d", i)
            local chapter_file = string.format("chapter_%03d.xhtml", i)
            table.insert(manifest_items, string.format(
                '    <item id="%s" href="%s" media-type="application/xhtml+xml"/>',
                chapter_id, chapter_file))
            table.insert(spine_items, string.format('    <itemref idref="%s"/>', chapter_id))

            local escaped_chapter_title = self:escapeXML(chapter.title)
            table.insert(nav_points, string.format([[    <navPoint id="navpoint-%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s"/>
    </navPoint>]], play_order, play_order, escaped_chapter_title, chapter_file))
            play_order = play_order + 1
        end

        -- Add NCX and CSS to manifest
        table.insert(manifest_items, '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
        table.insert(manifest_items, '    <item id="css" href="style.css" media-type="text/css"/>')

        -- 4. content.opf
        local cover_meta = ""
        local guide_section = ""
        if has_cover then
            cover_meta = '\n    <meta name="cover" content="cover-image"/>'
            guide_section = [[
  <guide>
    <reference type="cover" title="Cover" href="cover.xhtml"/>
  </guide>]]
        end

        local content_opf = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="2.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:opf="http://www.idpf.org/2007/opf">
    <dc:title>%s</dc:title>
    <dc:creator opf:role="aut">%s</dc:creator>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:language>en</dc:language>
    <dc:source>https://www.royalroad.com/fiction/%s</dc:source>%s
  </metadata>
  <manifest>
%s
  </manifest>
  <spine toc="ncx">
%s
  </spine>%s
</package>]],
            escaped_title, escaped_author, book_id, fiction_id, cover_meta,
            table.concat(manifest_items, "\n"), table.concat(spine_items, "\n"), guide_section)
        epub:addFileFromMemory("OEBPS/content.opf", content_opf)

        -- 5. toc.ncx
        local toc_ncx = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <docAuthor><text>%s</text></docAuthor>
  <navMap>
%s
  </navMap>
</ncx>]], book_id, escaped_title, escaped_author, table.concat(nav_points, "\n"))
        epub:addFileFromMemory("OEBPS/toc.ncx", toc_ncx)

        -- 6. CSS
        local style_css = [[body {
  font-family: serif;
  margin: 1em;
  line-height: 1.6;
}
h1, h2 { margin-top: 1em; }
.cover { text-align: center; }
.cover img { max-width: 100%; max-height: 100%; }
.chapter { margin-top: 2em; }
p { text-indent: 1.5em; margin: 0.5em 0; }
]]
        epub:addFileFromMemory("OEBPS/style.css", style_css)

        -- 7. Cover page (if cover exists)
        if has_cover then
            local cover_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>Cover</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <div class="cover">
    <img src="../cover.%s" alt="Cover"/>
  </div>
</body>
</html>]], cover_image.extension)
            epub:addFileFromMemory("OEBPS/cover.xhtml", cover_xhtml)

            -- Add actual cover image at EPUB root level
            epub:addFileFromMemory("cover." .. cover_image.extension, cover_image.data)
        end

        -- 8. Title page
        local title_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>%s</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <h1>%s</h1>
  <p><em>By %s</em></p>
  <p><small>Downloaded from Royal Road</small></p>
</body>
</html>]], escaped_title, escaped_title, escaped_author)
        epub:addFileFromMemory("OEBPS/title.xhtml", title_xhtml)

        -- 9. Chapter files
        for i, chapter in ipairs(chapters) do
            local escaped_chapter_title = self:escapeXML(chapter.title)
            local chapter_content = chapter.content or ""

            local chapter_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.1//EN" "http://www.w3.org/TR/xhtml11/DTD/xhtml11.dtd">
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
  <title>%s</title>
  <link rel="stylesheet" type="text/css" href="style.css"/>
</head>
<body>
  <div class="chapter">
    <h2>%s</h2>
    %s
  </div>
</body>
</html>]], escaped_chapter_title, escaped_chapter_title, chapter_content)

            local chapter_file = string.format("OEBPS/chapter_%03d.xhtml", i)
            epub:addFileFromMemory(chapter_file, chapter_xhtml)
        end

        epub:close()
        return true
    end)

    if ok and result then
        -- Save story metadata for update tracking
        self.downloaded_stories[fiction_id] = {
            fiction_id = fiction_id,
            title = story_title,
            author = author,
            chapter_urls = chapter_urls or {},
            epub_path = filename,
            cover_url = cover_url,
            download_date = os.time(),
            last_update = os.time(),
        }
        self:saveSettings()
        logger.info("Royal Road: Saved metadata for story", fiction_id, "with", #(chapter_urls or {}), "chapters")

        UIManager:show(InfoMessage:new{
            text = T(_("Saved EPUB:\n%1\n\n%2 chapters"), filename, #chapters),
            timeout = 10,
        })
        logger.info("Royal Road: Saved EPUB", filename)
    else
        -- Fall back to HTML if EPUB fails
        local error_msg = tostring(result)
        logger.warn("Royal Road: EPUB creation failed, falling back to HTML:", error_msg)
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB creation failed:\n%1\n\nSaving as HTML instead..."), error_msg),
            timeout = 5,
        })
        self:saveAsHTML(fiction_id, story_title, author, chapters)
    end
end

-- Check for updates across all tracked stories
function RoyalRoadDownloader:checkForUpdates()
    if self:countDownloadedStories() == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No downloaded stories to check.\n\nDownload a story first, then you can check for updates."),
        })
        return
    end

    -- Show checking progress
    UIManager:show(InfoMessage:new{
        text = _("Checking for updates..."),
        timeout = 2,
    })

    -- Schedule the actual check after UI updates
    UIManager:scheduleIn(0.1, function()
        local ok, err = pcall(function()
            self:performUpdateCheck()
        end)
        if not ok then
            logger.err("Royal Road: Update check failed:", err)
            UIManager:show(InfoMessage:new{
                text = T(_("Update check failed:\n%1"), tostring(err)),
            })
        end
    end)
end

function RoyalRoadDownloader:performUpdateCheck()
    local stories_with_updates = {}
    local errors = {}

    for fiction_id, story in pairs(self.downloaded_stories) do
        logger.info("Royal Road: Checking updates for", story.title, "(", fiction_id, ")")

        -- Fetch current story page
        local story_url = "https://www.royalroad.com/fiction/" .. fiction_id
        local story_html = self:fetchPage(story_url)

        if story_html then
            local current_urls = self:extractChapterURLs(story_html, fiction_id)
            local stored_count = #(story.chapter_urls or {})
            local current_count = #current_urls

            logger.info("Royal Road: Story", fiction_id, "has", stored_count, "stored,", current_count, "current chapters")

            if current_count > stored_count then
                local new_chapters = current_count - stored_count
                table.insert(stories_with_updates, {
                    fiction_id = fiction_id,
                    title = story.title,
                    stored_count = stored_count,
                    current_count = current_count,
                    new_chapters = new_chapters,
                    current_urls = current_urls,
                })
            end
        else
            table.insert(errors, story.title)
            logger.warn("Royal Road: Failed to fetch story page for", fiction_id)
        end
    end

    -- Show results
    if #stories_with_updates == 0 then
        local msg = _("All stories are up to date!")
        if #errors > 0 then
            msg = msg .. "\n\n" .. T(_("Failed to check: %1"), table.concat(errors, ", "))
        end
        UIManager:show(InfoMessage:new{
            text = msg,
        })
        return
    end

    -- Build menu of stories with updates
    self:showUpdateMenu(stories_with_updates)
end

function RoyalRoadDownloader:showUpdateMenu(stories_with_updates)
    local ButtonDialog = require("ui/widget/buttondialog")

    local buttons = {}
    for idx, story in ipairs(stories_with_updates) do
        table.insert(buttons, {
            {
                text = T(_("%1 (+%2 chapters)"), story.title, story.new_chapters),
                callback = function()
                    UIManager:close(self.update_dialog)
                    local ok, err = pcall(function()
                        self:updateStory(story.fiction_id, story.current_urls)
                    end)
                    if not ok then
                        logger.err("Royal Road: Update failed:", err)
                        UIManager:show(InfoMessage:new{
                            text = T(_("Update failed:\n%1"), tostring(err)),
                        })
                    end
                end,
            },
        })
    end

    -- Add "Update All" button if multiple stories
    if #stories_with_updates > 1 then
        table.insert(buttons, {
            {
                text = T(_("Update All (%1 stories)"), #stories_with_updates),
                callback = function()
                    UIManager:close(self.update_dialog)
                    self:updateAllStories(stories_with_updates)
                end,
            },
        })
    end

    -- Add cancel button
    table.insert(buttons, {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.update_dialog)
            end,
        },
    })

    self.update_dialog = ButtonDialog:new{
        title = T(_("%1 stories have updates"), #stories_with_updates),
        buttons = buttons,
    }
    UIManager:show(self.update_dialog)
end

function RoyalRoadDownloader:updateAllStories(stories_with_updates)
    -- Update stories one by one
    local function updateNext(index)
        if index > #stories_with_updates then
            UIManager:show(InfoMessage:new{
                text = T(_("Updated %1 stories!"), #stories_with_updates),
            })
            return
        end

        local story = stories_with_updates[index]
        UIManager:show(InfoMessage:new{
            text = T(_("Updating %1 (%2/%3)..."), story.title, index, #stories_with_updates),
            timeout = 2,
        })

        UIManager:scheduleIn(0.1, function()
            self:updateStory(story.fiction_id, story.current_urls, function()
                updateNext(index + 1)
            end)
        end)
    end

    updateNext(1)
end

-- Update a single story with new chapters
function RoyalRoadDownloader:updateStory(fiction_id, current_urls, on_complete)
    local story = self.downloaded_stories[fiction_id]
    if not story then
        logger.warn("Royal Road: Story not found in downloaded list:", fiction_id)
        if on_complete then on_complete() end
        return
    end

    -- Check if EPUB file exists
    local epub_path = story.epub_path
    local file = io.open(epub_path, "r")
    if not file then
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB file not found:\n%1\n\nPlease re-download the story."), epub_path),
        })
        if on_complete then on_complete() end
        return
    end
    file:close()

    logger.info("Royal Road: Starting update for", story.title)

    -- 1. Read existing reading position from sidecar (if exists)
    local old_position = {}
    local ok, doc_settings = pcall(function()
        return DocSettings:open(epub_path)
    end)
    if ok and doc_settings and doc_settings.data then
        old_position = {
            last_xpointer = doc_settings.data.last_xpointer,
            bookmarks = doc_settings.data.bookmarks,
            highlights = doc_settings.data.highlight,
        }
        logger.info("Royal Road: Saved reading position for restoration")
    end

    -- 2. Find NEW chapter URLs (not in stored list)
    local stored_set = {}
    for i, url in ipairs(story.chapter_urls or {}) do
        stored_set[url] = true
    end

    local new_urls = {}
    for i, url in ipairs(current_urls) do
        if not stored_set[url] then
            table.insert(new_urls, url)
        end
    end

    if #new_urls == 0 then
        UIManager:show(InfoMessage:new{
            text = T(_("%1 is already up to date."), story.title),
        })
        if on_complete then on_complete() end
        return
    end

    logger.info("Royal Road: Found", #new_urls, "new chapters to download")

    -- 3. Extract existing chapters from EPUB
    local existing_chapters, err = self:extractChaptersFromEPUB(epub_path)
    if not existing_chapters then
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to read existing EPUB:\n%1"), err or "Unknown error"),
        })
        if on_complete then on_complete() end
        return
    end

    logger.info("Royal Road: Extracted", #existing_chapters, "existing chapters")

    -- 4. Download new chapters with progress display
    self:downloadNewChapters(fiction_id, story, existing_chapters, new_urls, current_urls, old_position, on_complete)
end

function RoyalRoadDownloader:downloadNewChapters(fiction_id, story, existing_chapters, new_urls, all_urls, old_position, on_complete)
    local new_chapters = {}
    local total_new = #new_urls
    local start_time = socket.gettime()

    local progress_text = TextWidget:new{
        text = T(_("Downloading new chapter 1/%1"), total_new),
        face = Font:getFace("smallinfofont"),
    }
    local progress_bar = ProgressWidget:new{
        width = Device.screen:scaleBySize(200),
        height = Device.screen:scaleBySize(10),
        percentage = 0,
    }

    local state = {
        new_urls = new_urls,
        new_chapters = new_chapters,
        total_new = total_new,
        start_time = start_time,
        progress_text = progress_text,
        progress_bar = progress_bar,
        fiction_id = fiction_id,
        story = story,
        existing_chapters = existing_chapters,
        all_urls = all_urls,
        old_position = old_position,
        on_complete = on_complete,
        cancelled = false,
    }

    local cancel_button = Button:new{
        text = _("Cancel"),
        callback = function()
            state.cancelled = true
        end,
    }

    local progress_frame = FrameContainer:new{
        padding = Device.screen:scaleBySize(10),
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "center",
            TextWidget:new{
                text = T(_("Updating: %1"), story.title),
                face = Font:getFace("smallinfofont"),
            },
            progress_text,
            progress_bar,
            cancel_button,
        },
    }

    local progress_dialog = CenterContainer:new{
        dimen = Device.screen:getSize(),
        progress_frame,
    }

    UIManager:show(progress_dialog)
    state.progress_dialog = progress_dialog

    self:keepScreenAwake()
    self:downloadNextNewChapter(state, 1)
end

function RoyalRoadDownloader:downloadNextNewChapter(state, i)
    if state.cancelled then
        UIManager:close(state.progress_dialog)
        self:allowScreenSleep()
        UIManager:show(InfoMessage:new{
            text = _("Update cancelled."),
            timeout = 3,
        })
        if state.on_complete then state.on_complete() end
        return
    end

    if i > state.total_new then
        -- All new chapters downloaded, rebuild EPUB
        self:allowScreenSleep()
        UIManager:close(state.progress_dialog)
        self:rebuildEPUBWithNewChapters(state)
        return
    end

    -- Update progress
    state.progress_text:setText(T(_("Downloading new chapter %1/%2"), i, state.total_new))
    state.progress_bar:setPercentage(i / state.total_new)
    UIManager:setDirty(state.progress_dialog, "ui")

    -- Download chapter (URLs are already full URLs)
    local full_url = state.new_urls[i]

    UIManager:scheduleIn(0.1, function()
        local chapter_html = self:fetchPage(full_url)
        if chapter_html then
            local title = self:extractChapterTitle(chapter_html)
            local content = self:extractChapterContent(chapter_html)
            if title and content then
                table.insert(state.new_chapters, {
                    title = title,
                    content = content,
                })
                logger.info("Royal Road: Downloaded new chapter:", title)
            else
                logger.warn("Royal Road: Failed to extract new chapter", i, "from", full_url)
                table.insert(state.new_chapters, {
                    title = "Chapter " .. (#state.existing_chapters + i),
                    content = "<p>[Chapter content could not be extracted.]</p>",
                })
            end
        else
            logger.warn("Royal Road: Failed to download chapter:", full_url)
            table.insert(state.new_chapters, {
                title = "Chapter " .. (#state.existing_chapters + i),
                content = "<p>[Chapter failed to download.]</p>",
            })
        end

        -- Rate limit delay before next chapter
        UIManager:scheduleIn(self.rate_limit_delay, function()
            self:downloadNextNewChapter(state, i + 1)
        end)
    end)
end

function RoyalRoadDownloader:rebuildEPUBWithNewChapters(state)
    -- Combine existing + new chapters
    logger.info("Royal Road: Existing chapters:", #state.existing_chapters)
    logger.info("Royal Road: New chapters downloaded:", #state.new_chapters)

    local all_chapters = {}
    for i, chapter in ipairs(state.existing_chapters) do
        table.insert(all_chapters, chapter)
    end
    for i, chapter in ipairs(state.new_chapters) do
        table.insert(all_chapters, chapter)
    end

    logger.info("Royal Road: Rebuilding EPUB with", #all_chapters, "total chapters (", #state.existing_chapters, "existing +", #state.new_chapters, "new)")

    local cover_image = nil
    local cover_url = state.story.cover_url
    if not cover_url then
        local story_html = self:fetchPage("https://www.royalroad.com/fiction/" .. state.fiction_id)
        if story_html then
            cover_url = self:extractCoverURL(story_html)
        end
    end
    if cover_url then
        local image_data, mime_type, extension = self:fetchImage(cover_url)
        if image_data then
            cover_image = {
                data = image_data,
                mime_type = mime_type,
                extension = extension,
            }
            logger.info("Royal Road: Fetched cover image for update")
        end
    end

    -- Rebuild EPUB
    self:saveAsEPUB(
        state.fiction_id,
        state.story.title,
        state.story.author,
        all_chapters,
        cover_image,
        state.all_urls,
        cover_url
    )

    -- Restore reading position
    if state.old_position.last_xpointer then
        UIManager:scheduleIn(0.5, function()
            local ok, doc_settings = pcall(function()
                return DocSettings:open(state.story.epub_path)
            end)
            if ok and doc_settings then
                doc_settings.data.last_xpointer = state.old_position.last_xpointer
                if state.old_position.bookmarks then
                    doc_settings.data.bookmarks = state.old_position.bookmarks
                end
                if state.old_position.highlights then
                    doc_settings.data.highlight = state.old_position.highlights
                end
                doc_settings:flush()
                logger.info("Royal Road: Restored reading position")
            end
        end)
    end

    -- Show completion message
    UIManager:show(InfoMessage:new{
        text = T(_("Updated %1!\n\n+%2 new chapters\nTotal: %3 chapters\n\nReading position preserved."),
            state.story.title, #state.new_chapters, #all_chapters),
    })

    if state.on_complete then
        state.on_complete()
    end
end

function RoyalRoadDownloader:showStoryOptions(fiction_id)
    local ButtonDialog = require("ui/widget/buttondialog")

    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    local chapter_count = #(story.chapter_urls or {})

    self.story_options_dialog = ButtonDialog:new{
        title = T(_("%1\n%2 chapters"), story.title, chapter_count),
        buttons = {
            {
                {
                    text = _("Check for updates"),
                    callback = function()
                        UIManager:close(self.story_options_dialog)
                        if self.manage_menu then
                            UIManager:close(self.manage_menu)
                        end
                        self:checkSingleStoryForUpdates(fiction_id)
                    end,
                },
            },
            {
                {
                    text = _("Remove from tracking"),
                    callback = function()
                        UIManager:close(self.story_options_dialog)
                        self:removeFromTracking(fiction_id)
                    end,
                },
            },
            {
                {
                    text = _("Delete EPUB and tracking"),
                    callback = function()
                        UIManager:close(self.story_options_dialog)
                        self:deleteStoryCompletely(fiction_id)
                    end,
                },
            },
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(self.story_options_dialog)
                    end,
                },
            },
        },
    }
    UIManager:show(self.story_options_dialog)
end

function RoyalRoadDownloader:checkSingleStoryForUpdates(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    UIManager:show(InfoMessage:new{
        text = T(_("Checking %1 for updates..."), story.title),
        timeout = 2,
    })

    UIManager:scheduleIn(0.1, function()
        local story_url = "https://www.royalroad.com/fiction/" .. fiction_id
        local story_html = self:fetchPage(story_url)

        if not story_html then
            UIManager:show(InfoMessage:new{
                text = _("Failed to fetch story page."),
            })
            return
        end

        local current_urls = self:extractChapterURLs(story_html, fiction_id)
        local stored_count = #(story.chapter_urls or {})
        local current_count = #current_urls

        if current_count > stored_count then
            local new_chapters = current_count - stored_count
            local stories_with_updates = {{
                fiction_id = fiction_id,
                title = story.title,
                stored_count = stored_count,
                current_count = current_count,
                new_chapters = new_chapters,
                current_urls = current_urls,
            }}
            self:showUpdateMenu(stories_with_updates)
        else
            UIManager:show(InfoMessage:new{
                text = T(_("%1 is up to date!\n\n%2 chapters"), story.title, stored_count),
            })
        end
    end)
end

function RoyalRoadDownloader:removeFromTracking(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    self.downloaded_stories[fiction_id] = nil
    self:saveSettings()

    UIManager:show(InfoMessage:new{
        text = T(_("Removed %1 from tracking.\n\nThe EPUB file was not deleted."), story.title),
    })

    -- Refresh manage menu if open
    if self.manage_menu then
        UIManager:close(self.manage_menu)
        self:manageDownloads()
    end
end

function RoyalRoadDownloader:deleteStoryCompletely(fiction_id)
    local ConfirmBox = require("ui/widget/confirmbox")

    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1?\n\nThis will delete the EPUB file and remove tracking."), story.title),
        ok_text = _("Delete"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            -- Delete the EPUB file
            if story.epub_path then
                os.remove(story.epub_path)
                -- Also try to remove sidecar directory
                local sdr_path = story.epub_path:gsub("%.epub$", ".sdr")
                os.execute('rm -rf "' .. sdr_path .. '"')
            end

            -- Remove from tracking
            self.downloaded_stories[fiction_id] = nil
            self:saveSettings()

            UIManager:show(InfoMessage:new{
                text = T(_("Deleted %1."), story.title),
            })

            -- Refresh manage menu if open
            if self.manage_menu then
                UIManager:close(self.manage_menu)
                self:manageDownloads()
            end
        end,
    })
end

return RoyalRoadDownloader
