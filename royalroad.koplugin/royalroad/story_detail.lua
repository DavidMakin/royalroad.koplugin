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
local Size            = require("ui/size")
local TextBoxWidget   = require("ui/widget/textboxwidget")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local logger          = require("logger")
local T               = require("ffi/util").template
local _               = require("gettext")

local M = {}

function M:showStoryOptions(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

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
    table.insert(meta_group, VerticalSpan:new{ width = Size.padding.small })
    table.insert(meta_group, TextWidget:new{
        text    = T(_("%1 chapters"), chapter_count),
        face    = Font:getFace("smallffont"),
        fgcolor = Blitbuffer.COLOR_DARK_GRAY,
    })
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

    local header = HorizontalGroup:new{ align = "top" }
    table.insert(header, cover_frame)
    table.insert(header, HorizontalSpan:new{ width = Size.padding.large })
    table.insert(header, meta_group)

    local ButtonTable = require("ui/widget/buttontable")
    local btn_table = ButtonTable:new{
        width = dialog_w - Size.padding.large * 2,
        buttons = {
            {{
                text = _("Check for updates"),
                callback = function()
                    UIManager:close(self.story_detail_dialog)
                    UIManager:setDirty(nil, "ui")
                    if self.manage_menu then UIManager:close(self.manage_menu) end
                    self:checkSingleStoryForUpdates(fiction_id)
                end,
            }},
            {{
                text = _("Remove from tracking"),
                callback = function()
                    UIManager:close(self.story_detail_dialog)
                    UIManager:setDirty(nil, "ui")
                    self:removeFromTracking(fiction_id)
                end,
            }},
            {{
                text = _("Delete EPUB and tracking"),
                callback = function()
                    UIManager:close(self.story_detail_dialog)
                    UIManager:setDirty(nil, "ui")
                    self:deleteStoryCompletely(fiction_id)
                end,
            }},
            {{
                text = _("Close"),
                callback = function()
                    UIManager:close(self.story_detail_dialog)
                    UIManager:setDirty(nil, "ui")
                end,
            }},
        },
        zero_sep = true,
    }

    local content = FrameContainer:new{
        padding    = Size.padding.large,
        bordersize = Size.border.window,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            header,
            VerticalSpan:new{ width = Size.padding.large },
            btn_table,
        },
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

function M:removeFromTracking(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    self.downloaded_stories[fiction_id] = nil
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

return M
