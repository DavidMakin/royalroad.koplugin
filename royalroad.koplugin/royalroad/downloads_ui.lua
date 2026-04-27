local Blitbuffer      = require("ffi/blitbuffer")
local Device          = require("device")
local DocSettings     = require("docsettings")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local Menu            = require("ui/widget/menu")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local T               = require("ffi/util").template
local _               = require("gettext")

local widgets = require("royalroad/widgets")
local StoryListItem    = widgets.StoryListItem
local StoryCoverCell   = widgets.StoryCoverCell
local STORY_COVER_HEIGHT = widgets.STORY_COVER_HEIGHT
local STORY_COVER_WIDTH  = widgets.STORY_COVER_WIDTH
local STORY_ITEM_PAD     = widgets.STORY_ITEM_PAD
local GRID_COLS          = widgets.GRID_COLS
local GRID_CELL_GAP      = widgets.GRID_CELL_GAP
local GRID_ROW_GAP       = widgets.GRID_ROW_GAP

local M = {}

function M:manageDownloads()
    if self:countDownloadedStories() == 0 then
        UIManager:show(InfoMessage:new{
            text    = _("No downloaded stories."),
            timeout = 3,
        })
        return
    end

    local filter_text = self._manage_filter or ""

    local item_table = {}
    for fiction_id, story in pairs(self.downloaded_stories) do
        story.fiction_id = fiction_id
        local display_title = story.title or "Unknown"
        if story.partial_of then
            display_title = display_title .. T(_(" [%1/%2 ch]"), #(story.chapter_urls or {}), story.partial_of)
        end
        if story.unread_new_count and story.unread_new_count > 0 then
            display_title = display_title .. T(_(" [+%1 new]"), story.unread_new_count)
        end
        story.text = display_title
        if filter_text == "" or (story.title or ""):lower():find(filter_text:lower(), 1, true) then
            table.insert(item_table, story)
        end
    end
    local sort_mode = self.manage_sort_mode or "title"
    if sort_mode == "date" then
        table.sort(item_table, function(a, b)
            return (a.download_date or 0) > (b.download_date or 0)
        end)
    elseif sort_mode == "chapters" then
        table.sort(item_table, function(a, b)
            return #(a.chapter_urls or {}) > #(b.chapter_urls or {})
        end)
    elseif sort_mode == "lastread" then
        local function last_read_time(story)
            if story.epub_path then
                local ok, ds = pcall(DocSettings.open, DocSettings, story.epub_path)
                if ok and ds and ds.data then
                    return ds.data.last_read_time or (ds.data.last_xpointer and 1 or 0)
                end
            end
            return 0
        end
        local cache = {}
        table.sort(item_table, function(a, b)
            if cache[a.fiction_id] == nil then cache[a.fiction_id] = last_read_time(a) end
            if cache[b.fiction_id] == nil then cache[b.fiction_id] = last_read_time(b) end
            return cache[a.fiction_id] > cache[b.fiction_id]
        end)
    elseif sort_mode == "updated" then
        table.sort(item_table, function(a, b)
            return (a.last_update or a.download_date or 0) > (b.last_update or b.download_date or 0)
        end)
    else
        table.sort(item_table, function(a, b)
            return (a.title or "") < (b.title or "")
        end)
    end

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
            local top_h = (self.title_bar and not self.no_title) and self.title_bar:getHeight() or 0
            local bot_h = 0
            if self.page_return_arrow and self.page_info_text then
                bot_h = math.max(self.page_return_arrow:getSize().h, self.page_info_text:getSize().h)
                        + Size.padding.button
            end
            local available_h = (self.inner_dimen and self.inner_dimen.h or Device.screen:getHeight()) - top_h - bot_h
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

        function StoryMosaicMenu:updatePageInfo(select_number)
            Menu.updatePageInfo(self, select_number)
            if self.onReturn then
                self.page_return_arrow:show()
                self.page_return_arrow:enable()
            end
        end

        function StoryMosaicMenu:_loadCovers()
            for _, pending in ipairs(self._items_pending) do
                local entry  = pending.entry
                local widget = pending.widget
                if not entry.cover_bb then
                    local bb = downloader:cachedExtractCover(entry.fiction_id, entry.epub_path)
                    if bb then
                        entry.cover_bb = bb
                        widget:update()
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

        local function openSearch(current_menu)
            local search_dialog
            search_dialog = InputDialog:new{
                title       = _("Filter stories"),
                input       = downloader._manage_filter or "",
                input_hint  = _("Type to filter..."),
                buttons = {
                    {
                        {
                            text = _("Clear"),
                            callback = function()
                                UIManager:close(search_dialog)
                                downloader._manage_filter = ""
                                UIManager:close(current_menu)
                                downloader:manageDownloads()
                            end,
                        },
                        {
                            text = _("Filter"),
                            is_enter_default = true,
                            callback = function()
                                local q = search_dialog:getInputText()
                                UIManager:close(search_dialog)
                                downloader._manage_filter = q
                                UIManager:close(current_menu)
                                downloader:manageDownloads()
                            end,
                        },
                    },
                },
            }
            UIManager:show(search_dialog)
            search_dialog:onShowKeyboard()
        end

        local filter_suffix = (filter_text ~= "") and T(_(" [filter: %1]"), filter_text) or ""
        local menu = StoryMosaicMenu:new{
            covers_fullscreen       = true,
            is_borderless           = true,
            is_popout               = false,
            title                   = T(_("Downloads (%1)"), #item_table) .. filter_suffix,
            item_table              = item_table,
            title_bar_fm_style      = true,
            title_bar_right_icon    = "appbar.search",
            onRightButtonTap        = function(this) openSearch(this) end,
            onReturn                = function(this)
                UIManager:close(this)
                UIManager:scheduleIn(0.3, function() downloader:showPluginMenu() end)
            end,
        }
        downloader.manage_menu = menu
        UIManager:show(menu)
        return
    end

    local StoryListMenu = Menu:extend{
        _items_pending = {},
    }

    function StoryListMenu:_recalculateDimen()
        local top_h = (self.title_bar and not self.no_title) and self.title_bar:getHeight() or 0
        local bot_h = 0
        if self.page_return_arrow and self.page_info_text then
            bot_h = math.max(self.page_return_arrow:getSize().h, self.page_info_text:getSize().h)
                    + Size.padding.button
        end
        local available_h = (self.inner_dimen and self.inner_dimen.h or Device.screen:getHeight()) - top_h - bot_h
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

    function StoryListMenu:updatePageInfo(select_number)
        Menu.updatePageInfo(self, select_number)
        if self.onReturn then
            self.page_return_arrow:show()
            self.page_return_arrow:enable()
        end
    end

    function StoryListMenu:_loadCovers()
        for _, pending in ipairs(self._items_pending) do
            local entry  = pending.entry
            local widget = pending.widget
            if not entry.cover_bb then
                local bb = downloader:cachedExtractCover(entry.fiction_id, entry.epub_path)
                if bb then
                    entry.cover_bb = bb
                    widget:update()
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

    local function openSearch(current_menu)
        local search_dialog
        search_dialog = InputDialog:new{
            title       = _("Filter stories"),
            input       = downloader._manage_filter or "",
            input_hint  = _("Type to filter..."),
            buttons = {
                {
                    {
                        text = _("Clear"),
                        callback = function()
                            UIManager:close(search_dialog)
                            downloader._manage_filter = ""
                            UIManager:close(current_menu)
                            downloader:manageDownloads()
                        end,
                    },
                    {
                        text = _("Filter"),
                        is_enter_default = true,
                        callback = function()
                            local q = search_dialog:getInputText()
                            UIManager:close(search_dialog)
                            downloader._manage_filter = q
                            UIManager:close(current_menu)
                            downloader:manageDownloads()
                        end,
                    },
                },
            },
        }
        UIManager:show(search_dialog)
        search_dialog:onShowKeyboard()
    end

    local filter_suffix = (filter_text ~= "") and T(_(" [filter: %1]"), filter_text) or ""
    local menu_title    = T(_("Downloads (%1)"), #item_table) .. filter_suffix

    local menu = StoryListMenu:new{
        covers_fullscreen       = true,
        is_borderless           = true,
        is_popout               = false,
        title                   = menu_title,
        item_table              = item_table,
        title_bar_fm_style      = true,
        title_bar_right_icon    = "appbar.search",
        onRightButtonTap        = function(this) openSearch(this) end,
        onReturn                = function(this)
            UIManager:close(this)
            UIManager:scheduleIn(0.3, function() downloader:showPluginMenu() end)
        end,
    }
    downloader.manage_menu = menu
    UIManager:show(menu)
end

return M
