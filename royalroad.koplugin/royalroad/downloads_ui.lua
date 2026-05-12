local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local DocSettings     = require("docsettings")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
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

function M:_buildManageItemTable()
    self._last_read_cache = nil
    local filter_text = self._manage_filter or ""

    local item_table = {}
    for fiction_id, story in pairs(self.downloaded_stories) do
        story.fiction_id = fiction_id
        local display_title = story.title or "Unknown"
        if story.missing then
            display_title = display_title .. _(" [missing]")
        elseif story.partial_of then
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
                local ok, ds = pcall(function() return DocSettings:open(story.epub_path) end)
                if ok and ds and ds.data then
                    return ds.data.last_read_time or (ds.data.last_xpointer and 1 or 0)
                end
            end
            return 0
        end
        self._last_read_cache = self._last_read_cache or {}
        local cache = self._last_read_cache
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

    if #item_table == 0 then
        local hint_text = _("No stories yet — tap ☰ to download your first story")
        table.insert(item_table, {
            is_hint    = true,
            title      = hint_text,
            text       = hint_text,
            fiction_id = nil,
        })
    end

    return item_table
end

function M:refreshManageMenu()
    if not self.manage_menu then
        self:manageDownloads()
        return
    end
    local item_table = self:_buildManageItemTable()
    self.manage_menu.item_table = item_table
    self.manage_menu:updateItems()
end

function M:manageDownloads()
    local item_table = self:_buildManageItemTable()

    local item_height = STORY_COVER_HEIGHT + STORY_ITEM_PAD * 2
    local downloader  = self

    local function closeAndRefresh(dialog1, dialog2)
        if dialog1 then UIManager:close(dialog1) end
        if dialog2 then UIManager:close(dialog2) end
        downloader:saveSettings()
        downloader:manageDownloads()
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
                            downloader:refreshManageMenu()
                        end,
                    },
                    {
                        text = _("Filter"),
                        is_enter_default = true,
                        callback = function()
                            local q = search_dialog:getInputText()
                            UIManager:close(search_dialog)
                            downloader._manage_filter = q
                            downloader:refreshManageMenu()
                        end,
                    },
                },
            },
        }
        UIManager:show(search_dialog)
        search_dialog:onShowKeyboard()
    end

    local ButtonDialog = require("ui/widget/buttondialog")

    local function open_sort(anchor, menu)
        local cur = downloader.manage_sort_mode or "title"
        local function lbl(mode, label)
            return (cur == mode and "✓ " or "    ") .. label
        end
        local d
        d = ButtonDialog:new{
            shrink_unneeded_width = true,
            anchor = anchor,
            buttons = {
                {{ text = lbl("title",    _("Title")),        align = "left", callback = function() downloader.manage_sort_mode = "title"    UIManager:close(d) downloader:refreshManageMenu() end }},
                {{ text = lbl("date",     _("Date added")),   align = "left", callback = function() downloader.manage_sort_mode = "date"     UIManager:close(d) downloader:refreshManageMenu() end }},
                {{ text = lbl("updated",  _("Last updated")), align = "left", callback = function() downloader.manage_sort_mode = "updated"  UIManager:close(d) downloader:refreshManageMenu() end }},
                {{ text = lbl("lastread", _("Last read")),    align = "left", callback = function() downloader.manage_sort_mode = "lastread" UIManager:close(d) downloader:refreshManageMenu() end }},
                {{ text = lbl("chapters", _("Chapters")),     align = "left", callback = function() downloader.manage_sort_mode = "chapters" UIManager:close(d) downloader:refreshManageMenu() end }},
            },
        }
        UIManager:show(d)
    end

    local StoryMenuBase = Menu:extend{
        _items_pending = {},
    }

    function StoryMenuBase:updatePageInfo(select_number)
        Menu.updatePageInfo(self, select_number)
        if self.onReturn and self.page_return_arrow then
            self.page_return_arrow:show()
            self.page_return_arrow:enable()
        end
    end

    function StoryMenuBase:_loadCovers()
        local pending = self._items_pending
        self._items_pending = {}
        local function load_next(idx)
            if idx > #pending then return end
            local item   = pending[idx]
            local entry  = item.entry
            local widget = item.widget
            if not entry.cover_bb then
                local bb = downloader:cachedExtractCover(entry.fiction_id, entry.epub_path)
                if bb then
                    entry.cover_bb = bb
                    widget:update()
                    UIManager:setDirty(self.show_parent, "ui")
                end
            end
            UIManager:scheduleIn(0, function() load_next(idx + 1) end)
        end
        load_next(1)
    end

    function StoryMenuBase:onStorySelect(story)
        if story.is_hint then
            downloader:downloadStory()
            return
        end
        downloader:showStoryOptions(story.fiction_id)
    end

    function StoryMenuBase:onStoryHold(story)
        if story.is_hint then return end
        local TitleBar        = require("ui/widget/titlebar")
        local ButtonTable     = require("ui/widget/buttontable")
        local FrameContainer  = require("ui/widget/container/framecontainer")
        local VerticalGroup   = require("ui/widget/verticalgroup")

        local dialog
        local width = math.floor(Device.screen:getWidth() * 0.8)
        local function close() UIManager:close(dialog) end

        local title_bar = TitleBar:new{
            width          = width,
            title          = story.title,
            close_callback = close,
        }
        local button_table = ButtonTable:new{
            width   = width,
            buttons = {
                {{ text = _("Open"), callback = function()
                    close() downloader:showStoryOptions(story.fiction_id)
                end }},
                {{ text = _("Check for updates"), callback = function()
                    close() downloader:checkSingleStoryForUpdates(story.fiction_id)
                end }},
                {{ text = _("Delete"), callback = function()
                    close() downloader:deleteStoryCompletely(story.fiction_id)
                end }},
            },
        }
        dialog = CenterContainer:new{
            dimen = Device.screen:getSize(),
            FrameContainer:new{
                background = Blitbuffer.COLOR_WHITE,
                bordersize = Size.border.window,
                padding    = 0,
                VerticalGroup:new{
                    title_bar,
                    button_table,
                },
            },
        }
        UIManager:show(dialog)
    end

    function StoryMenuBase:onCloseWidget()
        for _, entry in ipairs(self.item_table) do
            entry.cover_bb = nil
        end
        Menu.onCloseWidget(self)
    end

    if self.manage_view_mode == "mosaic" then
        local cols      = downloader.mosaic_cols or 3
        local rows      = downloader.mosaic_rows or 2
        local hide_title = downloader.mosaic_hide_title or false
        local screen_w  = Device.screen:getWidth()
        local title_h   = hide_title and 0 or (math.ceil(14 * 1.3) * 2)

        local StoryMosaicMenu = StoryMenuBase:extend{}

        function StoryMosaicMenu:_recalculateDimen()
            local top_h = (self.title_bar and not self.no_title) and self.title_bar:getHeight() or 0
            local bot_h = 0
            if self.page_return_arrow and self.page_info_text then
                bot_h = math.max(self.page_return_arrow:getSize().h, self.page_info_text:getSize().h)
                        + Size.padding.button
            end
            local full_w       = self.inner_dimen and self.inner_dimen.w or screen_w
            local avail_h      = (self.inner_dimen and self.inner_dimen.h or Device.screen:getHeight()) - top_h - bot_h
            local side_pad     = Size.padding.large
            local inner_w      = full_w - 2 * side_pad
            local cell_w       = math.floor((inner_w - GRID_CELL_GAP * (cols - 1)) / cols)
            local cell_h       = math.floor((avail_h - GRID_ROW_GAP  * (rows + 1)) / rows)
            local cover_w_max  = math.max(0, cell_w - GRID_CELL_GAP * 2)
            local cover_h_max  = math.max(0, cell_h - title_h - (hide_title and 0 or 4) - GRID_CELL_GAP * 2)
            local cover_h      = math.min(cover_h_max, math.floor(cover_w_max * 3 / 2))
            local cover_w      = math.floor(cover_h * 2 / 3)
            self._cell_w    = cell_w
            self._cell_h    = cell_h
            self._cover_w   = cover_w
            self._cover_h   = cover_h
            self._side_pad  = side_pad
            self.perpage    = rows * cols
            self.page_num   = math.ceil(#self.item_table / self.perpage)
            if self.page_num > 0 and self.page > self.page_num then
                self.page = self.page_num
            end
            self.item_width  = full_w
            self.item_height = cell_h
            self.item_dimen  = Geom:new{ x = 0, y = 0, w = full_w, h = cell_h }
        end

        function StoryMosaicMenu:updateItems(select_number)
            self.layout = {}
            self.item_group:clear()
            local old_dimen = self.dimen and self.dimen:copy()
            self:_recalculateDimen()
            self._items_pending = {}

            local cell_w  = self._cell_w
            local cell_h  = self._cell_h
            local cover_w = self._cover_w
            local cover_h = self._cover_h
            local side_pad = self._side_pad or Size.padding.large

            local idx_offset = (self.page - 1) * self.perpage

            for row_i = 1, rows do
                local row = HorizontalGroup:new{ align = "top" }
                local row_layout = {}
                table.insert(row, HorizontalSpan:new{ width = side_pad })
                for col = 1, cols do
                    local entry = self.item_table[idx_offset + (row_i - 1) * cols + col]
                    if entry then
                        local cell = StoryCoverCell:new{
                            story        = entry,
                            cell_width   = cell_w,
                            cell_height  = cell_h,
                            cover_width  = cover_w,
                            cover_height = cover_h,
                            show_title   = not hide_title,
                            show_parent  = self.show_parent,
                            menu         = self,
                        }
                        table.insert(row, cell)
                        table.insert(row_layout, cell)
                        if col < cols then
                            table.insert(row, HorizontalSpan:new{ width = GRID_CELL_GAP })
                        end
                        if not entry.cover_bb and entry.epub_path and lfs.attributes(entry.epub_path, "mode") then
                            table.insert(self._items_pending, { entry = entry, widget = cell })
                        end
                    end
                end
                table.insert(row, HorizontalSpan:new{ width = side_pad })
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

        local filter_suffix = (filter_text ~= "") and T(_(" [filter: %1]"), filter_text) or ""
        local menu
        menu = StoryMosaicMenu:new{
            covers_fullscreen       = true,
            is_borderless           = true,
            is_popout               = false,
            title                   = T(_("Royal Road Downloader (%1)"), #item_table) .. filter_suffix,
            item_table              = item_table,
            title_bar_fm_style      = true,
            title_bar_left_icon     = "appbar.menu",
            onLeftButtonTap         = function()
                local function anchor() return menu.title_bar.left_button.image.dimen end

                local function open_grid()
                    local DoubleSpinWidget = require("ui/widget/doublespinwidget")
                    local orig_cols = downloader.mosaic_cols or 3
                    local orig_rows = downloader.mosaic_rows or 2
                    local widget = DoubleSpinWidget:new{
                        title_text       = _("Mosaic grid size"),
                        width_factor     = 0.6,
                        left_text        = _("Columns"),
                        left_value       = orig_cols,
                        left_min         = 2,
                        left_max         = 8,
                        left_default     = 3,
                        left_precision   = "%01d",
                        right_text       = _("Rows"),
                        right_value      = orig_rows,
                        right_min        = 1,
                        right_max        = 8,
                        right_default    = 2,
                        right_precision  = "%01d",
                        callback = function(left_value, right_value)
                            downloader.mosaic_cols = left_value
                            downloader.mosaic_rows = right_value
                            downloader:saveSettings()
                            UIManager:close(menu)
                            downloader:manageDownloads()
                        end,
                    }
                    UIManager:show(widget)
                end

                local view_dialog
                view_dialog = ButtonDialog:new{
                    shrink_unneeded_width = true,
                    anchor = anchor,
                    buttons = {
                        {{ text = "\u{2261} " .. _("Switch to list view"),     align = "left", callback = function() downloader.manage_view_mode = "list" closeAndRefresh(view_dialog, menu) end }},
                        {{ text = "\u{2195} " .. _("Sort by…"),                align = "left", callback = function() UIManager:close(view_dialog) open_sort(anchor, menu) end }},
                        {{ text = "\u{229E} " .. _("Grid size…"),              align = "left", callback = function() UIManager:close(view_dialog) open_grid() end }},
                        {{ text = (downloader.mosaic_hide_title and "✓ " or "○ ") .. _("Hide titles"),  align = "left", callback = function()
                            downloader.mosaic_hide_title = not downloader.mosaic_hide_title
                            closeAndRefresh(view_dialog, menu)
                        end }},
                        {},
                        {{ text = "\u{2193} " .. _("Download story"),          align = "left", callback = function() UIManager:close(view_dialog) downloader:downloadStory() end }},
                        {{ text = "\u{2315} " .. _("Search Royal Road"),       align = "left", callback = function() UIManager:close(view_dialog) downloader:searchStories() end }},
                        {{ text = "\u{21BB} " .. _("Check for updates"),       align = "left", callback = function() UIManager:close(view_dialog) downloader:checkForUpdates() end }},
                        {{ text = "\u{2B07} " .. _("Bulk import"),             align = "left", callback = function() UIManager:close(view_dialog) downloader:bulkImport() end }},
                        {{ text = "\u{2B06} " .. _("Export reading list"),     align = "left", callback = function() UIManager:close(view_dialog) downloader:exportReadingList() end }},
                        {{ text = "\u{2399} " .. _("Open downloads folder"),   align = "left", callback = function() UIManager:close(view_dialog) downloader:openDownloadsFolder() end }},
                        {{ text = "\u{2699} " .. _("Settings"),                align = "left", callback = function() UIManager:close(view_dialog) downloader:showSettings() end }},
                        {},
                        {{ text = "\u{2139} " .. _("About"),                   align = "left", callback = function() UIManager:close(view_dialog) downloader:showAbout() end }},
                    },
                }
                UIManager:show(view_dialog)
            end,
            title_bar_right_icon    = "appbar.search",
            onRightButtonTap        = function(this) openSearch(this) end,
        }
        downloader.manage_menu = menu
        UIManager:show(menu)
        return
    end

    local StoryListMenu = StoryMenuBase:extend{}

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
        if self.page_info then self.page_info:resetLayout() end
        if self.return_button then self.return_button:resetLayout() end
    end

    function StoryListMenu:updateItems(select_number)
        self.layout = {}
        self.item_group:clear()
        local old_dimen = self.dimen and self.dimen:copy()
        self:_recalculateDimen()
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

    local filter_suffix = (filter_text ~= "") and T(_(" [filter: %1]"), filter_text) or ""
    local menu_title    = T(_("Royal Road Downloader (%1)"), #item_table) .. filter_suffix

    local menu
    menu = StoryListMenu:new{
        covers_fullscreen       = true,
        is_borderless           = true,
        is_popout               = false,
        title                   = menu_title,
        item_table              = item_table,
        title_bar_fm_style      = true,
        title_bar_left_icon     = "appbar.menu",
        onLeftButtonTap         = function()
                local function anchor() return menu.title_bar.left_button.image.dimen end

                local view_dialog
            view_dialog = ButtonDialog:new{
                shrink_unneeded_width = true,
                anchor = anchor,
                buttons = {
                    {{ text = "\u{25A6} " .. _("Switch to mosaic view"),   align = "left", callback = function() downloader.manage_view_mode = "mosaic" closeAndRefresh(view_dialog, menu) end }},
                    {{ text = "\u{2195} " .. _("Sort by…"),                align = "left", callback = function() UIManager:close(view_dialog) open_sort(anchor, menu) end }},
                    {},
                    {{ text = "\u{2193} " .. _("Download story"),          align = "left", callback = function() UIManager:close(view_dialog) downloader:downloadStory() end }},
                    {{ text = "\u{2315} " .. _("Search Royal Road"),       align = "left", callback = function() UIManager:close(view_dialog) downloader:searchStories() end }},
                    {{ text = "\u{21BB} " .. _("Check for updates"),       align = "left", callback = function() UIManager:close(view_dialog) downloader:checkForUpdates() end }},
                    {{ text = "\u{2B07} " .. _("Bulk import"),             align = "left", callback = function() UIManager:close(view_dialog) downloader:bulkImport() end }},
                    {{ text = "\u{2B06} " .. _("Export reading list"),     align = "left", callback = function() UIManager:close(view_dialog) downloader:exportReadingList() end }},
                    {{ text = "\u{2399} " .. _("Open downloads folder"),   align = "left", callback = function() UIManager:close(view_dialog) downloader:openDownloadsFolder() end }},
                    {{ text = "\u{2699} " .. _("Settings"),                align = "left", callback = function() UIManager:close(view_dialog) downloader:showSettings() end }},
                    {},
                    {{ text = "\u{2139} " .. _("About"),                   align = "left", callback = function() UIManager:close(view_dialog) downloader:showAbout() end }},
                },
            }
            UIManager:show(view_dialog)
        end,
        title_bar_right_icon    = "appbar.search",
        onRightButtonTap        = function(this) openSearch(this) end,
    }
    downloader.manage_menu = menu
    UIManager:show(menu)
end

return M
