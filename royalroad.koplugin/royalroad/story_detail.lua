local Blitbuffer      = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local ImageWidget     = require("ui/widget/imagewidget")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local T               = require("ffi/util").template
local _               = require("gettext")

local M = {}

function M:showStoryOptions(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    if story.unread_new_count then
        story.unread_new_count = nil
        self:saveSettings()
    end

    local epub_exists = story.epub_path and lfs.attributes(story.epub_path, "mode") ~= nil

    local screen_w = Device.screen:getWidth()
    local dialog_w = math.floor(screen_w * 0.85)
    local cover_h  = math.floor(dialog_w * 0.25)
    local cover_w  = math.floor(cover_h * 2 / 3)

    local inner_cover
    if story.cover_bb then
        inner_cover = ImageWidget:new{
            image            = story.cover_bb,
            image_disposable = false,
            width            = cover_w,
            height           = cover_h,
            alpha            = true,
        }
    else
        local initials = (story.title or "?"):sub(1, 2):upper()
        inner_cover = CenterContainer:new{
            dimen = Geom:new{ w = cover_w, h = cover_h },
            TextWidget:new{
                text    = initials,
                face    = Font:getFace("smalltfont"),
                bold    = true,
                fgcolor = Blitbuffer.COLOR_WHITE,
            },
        }
    end

    local cover_frame = FrameContainer:new{
        width      = cover_w,
        height     = cover_h,
        padding    = 0,
        bordersize = 1,
        background = story.cover_bb and Blitbuffer.COLOR_WHITE or Blitbuffer.gray(0.5),
        inner_cover,
    }

    local chapter_count = #(story.chapter_urls or {})
    local download_date = story.download_date
        and os.date("%Y-%m-%d", story.download_date) or _("Unknown")
    local last_check = story.last_update
        and os.date("%Y-%m-%d", story.last_update) or _("Never")

    local read_percent = nil
    if epub_exists then
        local ok, doc_settings = pcall(function()
            local DocSettings = require("docsettings")
            return DocSettings:open(story.epub_path)
        end)
        if ok and doc_settings and doc_settings.data then
            read_percent = doc_settings.data.percent_finished
        end
    end

    local info_w = dialog_w - cover_w - Size.padding.large * 3
    local meta_group = VerticalGroup:new{ align = "left" }
    table.insert(meta_group, TextBoxWidget:new{
        text  = story.title or "",
        face  = Font:getFace("smalltfont"),
        width = info_w,
        bold  = true,
    })
    if story.author and story.author ~= "" then
        table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(meta_group, TextBoxWidget:new{
            text  = story.author,
            face  = Font:getFace("smallffont"),
            width = info_w,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    if story.status and story.status ~= "" then
        table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(meta_group, TextWidget:new{
            text    = story.status,
            face    = Font:getFace("smallffont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(meta_group, TextWidget:new{
        text    = T(_("%1 chapters"), chapter_count),
        face    = Font:getFace("smallffont"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    if story.word_count and story.word_count ~= "" then
        table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(meta_group, TextWidget:new{
            text    = T(_("%1 words"), story.word_count),
            face    = Font:getFace("smallffont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    if story.rating and story.rating ~= "" then
        table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(meta_group, TextWidget:new{
            text    = T(_("Rating: %1★"), story.rating),
            face    = Font:getFace("smallffont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(meta_group, TextWidget:new{
        text    = T(_("Downloaded: %1"), download_date),
        face    = Font:getFace("smallffont"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(meta_group, TextWidget:new{
        text    = T(_("Last checked: %1"), last_check),
        face    = Font:getFace("smallffont"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
    if story.last_chapter_date and story.last_chapter_date ~= "" then
        table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(meta_group, TextWidget:new{
            text    = T(_("Last chapter: %1"), story.last_chapter_date),
            face    = Font:getFace("smallffont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    if read_percent and read_percent > 0 then
        table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(meta_group, TextWidget:new{
            text    = T(_("Progress: %1%"), math.floor(read_percent * 100)),
            face    = Font:getFace("smallffont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    local header = HorizontalGroup:new{ align = "top" }
    table.insert(header, cover_frame)
    table.insert(header, HorizontalSpan:new{ width = Size.padding.large })
    table.insert(header, meta_group)

    local ButtonTable = require("ui/widget/buttontable")
    local buttons = {}

    if epub_exists then
        table.insert(buttons, {{
            text = _("Open book"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                if self.manage_menu then UIManager:close(self.manage_menu) end
                if self._last_read_cache then self._last_read_cache[fiction_id] = nil end
                local ReaderUI = require("apps/reader/readerui")
                UIManager:scheduleIn(0.1, function()
                    ReaderUI:showReader(story.epub_path)
                end)
            end,
        }})
        table.insert(buttons, {{
            text = _("Check for updates"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                if self.manage_menu then UIManager:close(self.manage_menu) end
                self:checkSingleStoryForUpdates(fiction_id)
            end,
        }})

    else
        table.insert(buttons, {{
            text = _("EPUB missing - Redownload"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                self:deleteAndRedownload(fiction_id)
            end,
        }})
    end

    if story.partial_of then
        table.insert(buttons, {{
            text = T(_("Resume download (%1/%2 ch)"), #(story.chapter_urls or {}), story.partial_of),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                self:resumePartialDownload(fiction_id)
            end,
        }})
    end


    if story.cover_url and story.cover_url ~= "" then
        table.insert(buttons, {{
            text = _("Refresh cover"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:show(InfoMessage:new{ text = _("Fetching cover..."), timeout = 2 })
                UIManager:scheduleIn(0.1, function()
                    local image_data, mime_type, extension = self:fetchImage(story.cover_url)
                    if image_data then
                        story.cover_image_data = image_data
                        story.cover_mime = mime_type
                        story.cover_ext = extension
                        story.cover_bb = nil
                        self:saveSettings()
                        local existing_chapters, ch_err = self:extractChaptersFromEPUB(story.epub_path)
                        if existing_chapters then
                            local cover_image = { data = image_data, mime_type = mime_type, extension = extension }
                            self:saveAsEPUB(story.fiction_id, story.title, story.author, existing_chapters, cover_image, story.chapter_urls, story.cover_url)
                        end
                        UIManager:show(InfoMessage:new{ text = _("Cover updated!"), timeout = 2 })
                    else
                        UIManager:show(InfoMessage:new{ text = _("Failed to fetch cover."), timeout = 3 })
                    end
                end)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Remove from tracking"),
        callback = function()
            UIManager:close(self.story_detail_dialog)
            UIManager:setDirty(nil, "ui")
            self:removeFromTracking(fiction_id)
        end,
    }})
    if epub_exists then
        table.insert(buttons, {{
            text = _("Delete EPUB and tracking"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                self:deleteStoryCompletely(fiction_id)
            end,
        }})
        table.insert(buttons, {{
            text = _("Delete and redownload"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                self:deleteAndRedownload(fiction_id)
            end,
        }})
    end
    table.insert(buttons, {{
        text = _("Close"),
        callback = function()
            UIManager:close(self.story_detail_dialog)
            UIManager:setDirty(nil, "ui")
        end,
    }})

    local btn_table = ButtonTable:new{
        width    = dialog_w - Size.padding.large * 2,
        buttons  = buttons,
        zero_sep = true,
    }

    local main_vgroup = VerticalGroup:new{ align = "left" }
    table.insert(main_vgroup, header)
    table.insert(main_vgroup, VerticalSpan:new{ width = Size.padding.large })
    table.insert(main_vgroup, btn_table)

    local content = FrameContainer:new{
        padding    = Size.padding.large,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        main_vgroup,
    }

    self.story_detail_dialog = CenterContainer:new{
        dimen = Device.screen:getSize(),
        content,
    }
    UIManager:show(self.story_detail_dialog)
end

function M:checkSingleStoryForUpdates(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    UIManager:show(InfoMessage:new{
        text = T(_("Checking %1 for updates..."), story.title),
        timeout = 2,
    })

    UIManager:scheduleIn(0.1, function()
        local story_url = "https://www.royalroad.com/fiction/" .. fiction_id
        local story_html = self:fetchPageCached(story_url)

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

function M:removeFromTracking(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

            self.downloaded_stories[fiction_id] = nil
            self:_invalidateCoverCache(fiction_id)
            self:_invalidateStoryCount()
    self:saveSettings()

    UIManager:show(InfoMessage:new{
        text = T(_("Removed %1 from tracking.\n\nThe EPUB file was not deleted."), story.title),
    })

    if self.manage_menu then
        UIManager:close(self.manage_menu)
        self:manageDownloads()
    end
end

function M:deleteStoryCompletely(fiction_id)
    local ConfirmBox = require("ui/widget/confirmbox")

    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete %1?\n\nThis will delete the EPUB file and remove tracking."), story.title),
        ok_text = _("Delete"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            if story.epub_path then
                os.remove(story.epub_path)
                local sdr_path = story.epub_path:gsub("%.epub$", ".sdr")
                os.execute('rm -rf "' .. sdr_path .. '"')
            end

            self.downloaded_stories[fiction_id] = nil
            self:_invalidateStoryCount()
            self:saveSettings()

            UIManager:show(InfoMessage:new{
                text = T(_("Deleted %1."), story.title),
            })

            if self.manage_menu then
                UIManager:close(self.manage_menu)
                self:manageDownloads()
            end
        end,
    })
end

function M:deleteAndRedownload(fiction_id)
    local ConfirmBox = require("ui/widget/confirmbox")

    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    UIManager:show(ConfirmBox:new{
        text = T(_("Delete and redownload %1?\n\nThe EPUB will be deleted and a fresh download will start."), story.title),
        ok_text = _("Delete and redownload"),
        cancel_text = _("Cancel"),
        ok_callback = function()
            if story.epub_path then
                os.remove(story.epub_path)
                local sdr_path = story.epub_path:gsub("%.epub$", ".sdr")
                os.execute('rm -rf "' .. sdr_path .. '"')
            end

            self.downloaded_stories[fiction_id] = nil
            self:_invalidateStoryCount()
            self:saveSettings()

            if self.manage_menu then
                UIManager:close(self.manage_menu)
            end

            UIManager:scheduleIn(0.1, function()
                self:processFiction(fiction_id)
            end)
        end,
    })
end

function M:resumePartialDownload(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story or not story.partial_of then return end

    UIManager:show(InfoMessage:new{
        text    = T(_("Fetching chapter list for %1..."), story.title),
        timeout = 2,
    })

    UIManager:scheduleIn(0.1, function()
        local story_html = self:fetchPageCached("https://www.royalroad.com/fiction/" .. fiction_id)

        if not story_html then
            UIManager:show(InfoMessage:new{
                text = _("Failed to fetch story page."),
            })
            return
        end

        local current_urls = self:extractChapterURLs(story_html, fiction_id)
        if #current_urls == 0 then
            UIManager:show(InfoMessage:new{
                text = _("Could not find chapters on story page."),
            })
            return
        end

        local stored_set = {}
        for _, url in ipairs(story.chapter_urls or {}) do
            stored_set[url] = true
        end

        local has_missing = false
        for _, url in ipairs(current_urls) do
            if not stored_set[url] then
                has_missing = true
                break
            end
        end

        if not has_missing then
            story.partial_of = nil
            self:saveSettings()
            UIManager:show(InfoMessage:new{
                text = T(_("%1 is already complete."), story.title),
            })
            return
        end

        self:updateStory(fiction_id, current_urls)
    end)
end

return M
