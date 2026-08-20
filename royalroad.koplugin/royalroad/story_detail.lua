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
local TitleBar        = require("ui/widget/titlebar")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local ffiUtil         = require("ffi/util")
local T               = ffiUtil.template
local _               = require("gettext")
local C               = require("royalroad/constants")
local urls            = require("royalroad/urls")

local M = {}

function M:showStoryOptions(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    -- Note: unread_new_count is deliberately NOT cleared here. The "new
    -- chapters" ribbon (widgets.lua newBadge) is meant to persist until the
    -- next update check for this story (checkSingleStoryForUpdates) or an
    -- "Update all" pass; opening the options dialog does not acknowledge
    -- the new chapters.

    local epub_exists = story.epub_path and lfs.attributes(story.epub_path, "mode") ~= nil
    local has_dupes = urls.hasDuplicateKeys(story.chapter_urls or {})
    local is_excluded = story.excluded == true
    if epub_exists and story.missing then
        story.missing = nil
        self:saveSettings()
    elseif not epub_exists and not story.missing then
        story.missing = true
        self:saveSettings()
    end

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
    if story.author and story.author ~= "" then
        table.insert(meta_group, TextBoxWidget:new{
            text    = story.author,
            face    = Font:getFace("smallffont"),
            width   = info_w,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    local function addMeta(text)
        table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
        table.insert(meta_group, TextWidget:new{
            text    = text,
            face    = Font:getFace("smallffont"),
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    if story.status and story.status ~= "" then
        addMeta(story.status)
    end
    addMeta(T(_("%1 chapters"), chapter_count))
    if story.word_count and story.word_count ~= "" then
        local wk = math.floor(tonumber(story.word_count) / 100 + 0.5) / 10
        local wc_str = wk and (wk .. "k") or tostring(story.word_count)
        addMeta(T(_("%1 words"), wc_str))
    end
    if story.rating and story.rating ~= "" then
        addMeta(T(_("Rating: %1★"), story.rating))
    end
    addMeta(T(_("Downloaded: %1"), download_date))
    addMeta(T(_("Last checked: %1"), last_check))
    if story.last_chapter_date and story.last_chapter_date ~= "" then
        local lcd = story.last_chapter_date:match("^(%d+%-%d+%-%d+)") or story.last_chapter_date
        addMeta(T(_("Last chapter: %1"), lcd))
    end
    if read_percent and read_percent > 0 then
        local progress_text
        if chapter_count > 0 then
            local chapters_read = math.min(chapter_count, math.max(0, math.floor(read_percent * chapter_count + 0.5)))
            progress_text = T(_("Progress: %1% (%2/%3 chapters)"),
                math.floor(read_percent * 100 + 0.5), chapters_read, chapter_count)
        else
            progress_text = T(_("Progress: %1%"), math.floor(read_percent * 100 + 0.5))
        end
        addMeta(progress_text)
    end

    local header = HorizontalGroup:new{ align = "top" }
    table.insert(header, cover_frame)
    table.insert(header, HorizontalSpan:new{ width = Size.padding.large })
    table.insert(header, meta_group)

    local ButtonTable = require("ui/widget/buttontable")
    local buttons = {}

    if epub_exists then
        table.insert(buttons, {{
            text = _("\u{25B7} Open book"),
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
            text = _("\u{21BB} Check for updates"),
            callback = function()
                self:checkSingleStoryForUpdates(fiction_id)
            end,
        }})

        if has_dupes then
            table.insert(buttons, {{
                text = _("Repair duplicate chapters"),
                callback = function()
                    UIManager:close(self.story_detail_dialog)
                    UIManager:setDirty(nil, "ui")
                    self:repairStoryDuplicates(fiction_id)
                end,
            }})
        end

    else
        table.insert(buttons, {{
            text = _("\u{2193} EPUB missing - Redownload"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                self:deleteAndRedownload(fiction_id)
            end,
        }})
    end

    table.insert(buttons, {{
        text = is_excluded and _("\u{25C9} Include in updates") or _("\u{2298} Exclude from updates"),
        callback = function()
            -- The toggle never touches unread_new_count: the badge only goes
            -- away when a check is selected (updater.lua) — excluding a story
            -- doesn't make its unread chapters read.
            story.excluded = not is_excluded
            self:saveSettings()
            UIManager:close(self.story_detail_dialog)
            UIManager:setDirty(nil, "ui")
            if self.manage_menu then self:refreshManageMenu() end
        end,
    }})

    if story.partial_of then
        table.insert(buttons, {{
            text = T(_("\u{25B6} Resume download (%1/%2 ch)"), #(story.chapter_urls or {}), story.partial_of),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                self:resumePartialDownload(fiction_id)
            end,
        }})
    end


    if story.cover_url and story.cover_url ~= "" then
        table.insert(buttons, {{
            text = _("\u{21BA} Refresh cover"),
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
                            self:saveAsEPUB(fiction_id, story.title, story.author, existing_chapters, cover_image, story.chapter_urls, story.cover_url, story.epub_path)
                        end
                        UIManager:show(InfoMessage:new{ text = _("Cover updated!"), timeout = 2 })
                    else
                        UIManager:show(InfoMessage:new{ text = _("Failed to fetch cover."), timeout = 3 })
                    end
                end)
            end,
        }})
    end
    if Device:canOpenLink() then
        local story_url = C.BASE_URL .. "/fiction/" .. fiction_id
        table.insert(buttons, {{
            text = _("\u{1F310} Open in browser"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                Device:openLink(story_url)
            end,
        }})
    end
    table.insert(buttons, {{
            text = _("\u{2296} Remove from tracking"),
        callback = function()
            UIManager:close(self.story_detail_dialog)
            UIManager:setDirty(nil, "ui")
            self:removeFromTracking(fiction_id)
        end,
    }})
    if epub_exists then
        table.insert(buttons, {{
            text = _("\u{2297} Delete EPUB and tracking"),
            callback = function()
                UIManager:close(self.story_detail_dialog)
                UIManager:setDirty(nil, "ui")
                self:deleteStoryCompletely(fiction_id)
            end,
        }})
    table.insert(buttons, {{
            text = _("\u{2B07} Delete and redownload"),
        callback = function()
            UIManager:close(self.story_detail_dialog)
            UIManager:setDirty(nil, "ui")
            self:deleteAndRedownload(fiction_id)
        end,
    }})
    end

    local btn_table = ButtonTable:new{
        width    = dialog_w - Size.padding.large * 2,
        buttons  = buttons,
        zero_sep = true,
    }

    local main_vgroup = VerticalGroup:new{ align = "left" }
    table.insert(main_vgroup, header)
    if has_dupes then
        table.insert(main_vgroup, VerticalSpan:new{ width = Size.padding.small })
        table.insert(main_vgroup, TextBoxWidget:new{
            text = _("Duplicate chapters detected — use \"Repair duplicate chapters\" to fix this EPUB."),
            face = Font:getFace("smallffont"),
            width = dialog_w - Size.padding.large * 2,
            fgcolor = Blitbuffer.COLOR_RED,
        })
    end
    if is_excluded then
        table.insert(main_vgroup, VerticalSpan:new{ width = Size.padding.small })
        table.insert(main_vgroup, TextBoxWidget:new{
            text = _("Excluded from automatic updates — tap \"Include in updates\" to re-enable."),
            face = Font:getFace("smallffont"),
            width = dialog_w - Size.padding.large * 2,
            fgcolor = Blitbuffer.COLOR_DARK_GRAY,
        })
    end
    table.insert(main_vgroup, VerticalSpan:new{ width = Size.padding.large })
    table.insert(main_vgroup, btn_table)

    local title_bar = TitleBar:new{
        width          = dialog_w,
        title          = story.title,
        with_bottom_line = true,
        close_callback = function()
            UIManager:close(self.story_detail_dialog)
            UIManager:setDirty(nil, "ui")
        end,
    }

    self.story_detail_dialog = CenterContainer:new{
        dimen = Device.screen:getSize(),
        FrameContainer:new{
            padding    = 0,
            bordersize = Size.border.window,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                title_bar,
                FrameContainer:new{
                    padding    = Size.padding.large,
                    bordersize = 0,
                    background = Blitbuffer.COLOR_WHITE,
                    main_vgroup,
                },
            },
        },
    }
    UIManager:show(self.story_detail_dialog)
end

function M:checkSingleStoryForUpdates(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    -- Selecting the check acknowledges the new-chapter state immediately:
    -- clear the flag that drives the "new" ribbon (widgets.lua newBadge) as
    -- soon as the check starts, regardless of whether the fetch succeeds.
    -- If the check finds updates and the user downloads them, the download
    -- path re-sets unread_new_count to the number of new chapters.
    if story.unread_new_count then
        story.unread_new_count = nil
        self:saveSettings()
    end

    local checking_msg = InfoMessage:new{
        text = T(_("Checking %1 for updates..."), story.title),
    }
    UIManager:show(checking_msg)

    UIManager:scheduleIn(0.1, function()
        local update, fetch_failed = self:_computeStoryUpdate(fiction_id, story)

        UIManager:close(checking_msg)
        UIManager:close(self.story_detail_dialog)
        UIManager:setDirty(nil, "ui")

        if fetch_failed then
            UIManager:show(InfoMessage:new{
                text = _("Failed to fetch story page."),
            })
            return
        end

        if update then
            self:showUpdateMenu({ update })
        else
            local msg = T(_("%1 is up to date!\n\n%2 chapters"), story.title, #(story.chapter_urls or {}))
            if urls.hasDuplicateKeys(story.chapter_urls or {}) then
                msg = msg .. "\n\n" .. _("Duplicate chapters detected — open story options and use \"Repair duplicate chapters\".")
            end
            UIManager:show(InfoMessage:new{
                text = msg,
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
                ffiUtil.purgeDir(sdr_path)
            end

            self.downloaded_stories[fiction_id] = nil
            self:_invalidateCoverCache(fiction_id)
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
                ffiUtil.purgeDir(sdr_path)
            end

            self:_invalidateCoverCache(fiction_id)
            self.downloaded_stories[fiction_id] = nil
            self:_invalidateStoryCount()
            self:saveSettings()

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
        local story_html = self:fetchPageCached(C.BASE_URL .. "/fiction/" .. fiction_id)
        if not story_html then
            UIManager:show(InfoMessage:new{ text = _("Failed to fetch story page.") })
            return
        end

        local current_urls = self:extractChapterURLs(story_html, fiction_id)
        if #current_urls == 0 then
            UIManager:show(InfoMessage:new{ text = _("Could not find chapters on story page.") })
            return
        end

        self:_resumeWithCandidateUrls(fiction_id, current_urls)
    end)
end

return M
