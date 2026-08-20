local Blitbuffer     = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device         = require("device")
local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget    = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local OverlapGroup   = require("ui/widget/overlapgroup")
local ProgressWidget  = require("ui/widget/progresswidget")
local Size           = require("ui/size")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local TopContainer   = require("ui/widget/container/topcontainer")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local T              = require("ffi/util").template
local _              = require("gettext")

local screen = Device.screen

-- Absolute path to the plugin's icons/ directory, derived from this module's
-- own source file: KOReader resolves require() to absolute paths, so
-- "@<abs>/royalroad.koplugin/royalroad/widgets.lua" yields the royalroad/
-- dir and we step up one level to the plugin root (same idiom as
-- royalroad/epub.lua).
local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."
local EXCLUDED_RIBBON = _plugin_dir .. "/../icons/excluded_ribbon.svg"
local NEW_RIBBON      = _plugin_dir .. "/../icons/new_ribbon.svg"

local STORY_COVER_HEIGHT = screen and screen:scaleBySize(100) or 100
local STORY_COVER_WIDTH  = math.floor(STORY_COVER_HEIGHT * 2 / 3)
local STORY_ITEM_PAD     = screen and screen:scaleBySize(8) or 8

local GRID_CELL_GAP = screen and screen:scaleBySize(6) or 6
local GRID_ROW_GAP  = screen and screen:scaleBySize(8) or 8

local function extractEpubCover(epub_path)
    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
    return FileManagerBookInfo:getCoverImage(nil, epub_path)
end

-- Overlay an "excluded" ribbon on the top-right corner of a cover: a red
-- diagonal band with a white ⊘, shipped as an SVG
-- (icons/excluded_ribbon.svg). Only used inside this plugin's own story list
-- UI; the KOReader library renders covers via FileManagerBookInfo and is
-- never passed a badge.
-- SVG, not glyphs: KOReader's widget system cannot rotate text or glyphs, so
-- a diagonal ribbon is only possible as an SVG image. Verified against
-- KOReader source:
--  * RenderImage.RENDER_SVG_WITH_NANOSVG = true (MuPDF 1.13 is too old for
--    our SVGs), so the file must stick to NanoSVG features: primitives and
--    transform="rotate(...)" work, but <text> elements are never rendered —
--    the ⊘ is therefore drawn as a stroked circle + slash line inside the SVG.
--  * renderSVGImageFileWithNanoSVG keeps the image's aspect ratio and centers
--    it in the requested box, so the SVG is square and width == height.
--  * ImageWidget{file, width, height, alpha = true, is_icon = true} is the
--    pattern simpleui.koplugin uses for plugin-shipped SVG icons.
-- Placement: the badge ImageWidget is the OverlapGroup child directly —
-- wrapping it in a FrameContainer would paint FrameContainer's default black
-- border (bordersize = Size.border.window, color = COLOR_BLACK) around the
-- ribbon and its margin would float the badge off the cover edge. As a bare
-- child, the badge sits flush in the cover's corner. OverlapGroup
-- overlap_align = "right" pins it to the top-right corner and flips to the
-- top-left automatically in mirrored (RTL) UIs (verified in
-- frontend/ui/widget/overlapgroup.lua).
local function badgeSize(cover_h)
    -- Scale with the cover so the ribbon reads on both the small list covers
    -- (~scaleBySize(100) tall) and the full-screen grid covers, clamped so
    -- tiny covers don't shrink the symbol below legibility.
    return math.max(
        screen:scaleBySize(30),
        math.min(screen:scaleBySize(64), math.floor(cover_h * 0.35))
    )
end

local function makeRibbonBadge(file, side)
    return ImageWidget:new{
        file    = file,
        width   = side,
        height  = side,
        alpha   = true,
        is_icon = true,
    }
end

local function excludedBadge(cover_widget, cover_w, cover_h)
    if not (cover_w and cover_h and cover_w > 0 and cover_h > 0) then
        return cover_widget
    end
    local badge = makeRibbonBadge(EXCLUDED_RIBBON, badgeSize(cover_h))
    badge.overlap_align = "right"
    return OverlapGroup:new{
        dimen = Geom:new{ w = cover_w, h = cover_h },
        cover_widget,
        badge,
    }
end

-- "New chapters" ribbon on the bottom-right corner — the corner opposite the
-- exclusion ribbon, so a story can carry both badges at once. Shown whenever
-- unread_new_count > 0, which is set when new chapters are downloaded and
-- cleared by the next update check (individual or "Update all", see
-- updater.lua / story_detail.lua).
-- Positioned with overlap_offset {cover_w - side, cover_h - side} — OverlapGroup reads
-- numeric indices [1]/[2], NOT named x/y keys (overlapgroup.lua paintTo).
-- instead of overlap_align: OverlapGroup has no "bottom" alignment, but the
-- offset is RTL-safe because paintTo() mirrors only the x-offset
-- (offset[1] = size.w - w - offset[1]), which maps cover_w - side to 0 — so
-- the badge lands bottom-right in LTR and bottom-left in RTL, symmetric.
local function newBadge(cover_widget, cover_w, cover_h)
    if not (cover_w and cover_h and cover_w > 0 and cover_h > 0) then
        return cover_widget
    end
    local side  = badgeSize(cover_h)
    local badge = makeRibbonBadge(NEW_RIBBON, side)
    badge.overlap_offset = { cover_w - side, cover_h - side }
    return OverlapGroup:new{
        dimen = Geom:new{ w = cover_w, h = cover_h },
        cover_widget,
        badge,
    }
end

-- Apply whichever corner ribbons are active for a story to a cover widget.
-- Call this once at widget construction; rebuild the widget (via
-- refreshManageMenu) whenever story.excluded or story.unread_new_count changes.
local function applyBadges(cover_widget, cover_w, cover_h, story)
    if story.excluded then
        cover_widget = excludedBadge(cover_widget, cover_w, cover_h)
    end
    if (story.unread_new_count or 0) > 0 then
        cover_widget = newBadge(cover_widget, cover_w, cover_h)
    end
    return cover_widget
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
        HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        },
    }

    local inner_cover
    if self.story.cover_bb then
        inner_cover = ImageWidget:new{
            image            = self.story.cover_bb,
            image_disposable = false,
            width            = STORY_COVER_WIDTH,
            height           = STORY_COVER_HEIGHT,
            alpha            = true,
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
    cover_widget = applyBadges(cover_widget, STORY_COVER_WIDTH, STORY_COVER_HEIGHT, self.story)

    local text_width = self.width - STORY_COVER_WIDTH - STORY_ITEM_PAD * 3
    local story = self.story
    local info_group = VerticalGroup:new{ align = "left" }

    table.insert(info_group, TextWidget:new{
        text      = story.title or "",
        face      = Font:getFace("smalltfont", 16),
        max_width = text_width,
        bold      = true,
        fgcolor   = (story.missing or story.excluded) and Blitbuffer.COLOR_DARK_GRAY or nil,
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
        local chapters_text = T(_("%1 chapters"), n_chapters)
        if story.read_percent then
            chapters_text = T(_("%1/%2 chapters (%3%)"),
                story.chapters_read or 0, n_chapters, math.floor(story.read_percent * 100 + 0.5))
        end
        table.insert(info_group, VerticalSpan:new{ width = 2 })
        table.insert(info_group, TextWidget:new{
            text      = chapters_text,
            face      = Font:getFace("smallffont"),
            max_width = text_width,
            fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
        })
    end

    local bg = self.story.missing and Blitbuffer.gray(0.8) or Blitbuffer.COLOR_WHITE
    self[1] = FrameContainer:new{
        width      = self.width,
        height     = self.height,
        padding    = 0,
        margin     = 0,
        bordersize = 0,
        background = bg,
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
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
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

function StoryListItem:onHoldSelect()
    if self.menu and self.menu.onStoryHold then
        self.menu:onStoryHold(self.story)
    end
    return true
end

local StoryCoverCell = InputContainer:extend{
    story        = nil,
    cell_width   = nil,
    cell_height  = nil,
    cover_width  = nil,
    cover_height = nil,
    show_parent  = nil,
    menu         = nil,
    show_title   = true,
}

function StoryCoverCell:init()
    self.dimen = Geom:new{ w = self.cell_width, h = self.cell_height }
    self.ges_events = {
        TapSelect = {
            GestureRange:new{ ges = "tap", range = self.dimen },
        },
        HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        },
    }

    if self.story.is_hint then
        self[1] = FrameContainer:new{
            width      = self.cell_width,
            height     = self.cell_height,
            padding    = GRID_CELL_GAP,
            bordersize = 0,
            background = Blitbuffer.COLOR_WHITE,
            CenterContainer:new{
                dimen = Geom:new{
                    w = self.cell_width - 2 * GRID_CELL_GAP,
                    h = self.cell_height - 2 * GRID_CELL_GAP,
                },
                TextBoxWidget:new{
                    text      = self.story.title or "",
                    face      = Font:getFace("smallffont"),
                    width     = self.cell_width - 2 * GRID_CELL_GAP,
                    alignment = "center",
                    fgcolor   = Blitbuffer.COLOR_DARK_GRAY,
                },
            },
        }
        return
    end

    local inner_cover
    if self.story.cover_bb then
        inner_cover = ImageWidget:new{
            image            = self.story.cover_bb,
            image_disposable = false,
            width            = self.cover_width,
            height           = self.cover_height,
            alpha            = true,
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
    cover_widget = applyBadges(cover_widget, self.cover_width, self.cover_height, self.story)

    local title_height = math.ceil(14 * 1.3) * 2
    local progress_bar_h = self.story.read_percent and (2 + Size.line.medium) or 0
    local inner_h = self.cover_height + progress_bar_h + (self.show_title and (4 + title_height) or 0)

    local content = VerticalGroup:new{ align = "center", cover_widget }
    if self.story.read_percent then
        table.insert(content, VerticalSpan:new{ width = 2 })
        table.insert(content, ProgressWidget:new{
            width      = self.cover_width,
            height     = Size.line.medium,
            percentage = self.story.read_percent,
            margin_h   = 0,
            margin_v   = 0,
        })
    end
    if self.show_title then
        local title_widget = TextBoxWidget:new{
            text      = self.story.title or "",
            face      = Font:getFace("smallffont", 14),
            width     = self.cover_width,
            height    = title_height,
            alignment = "center",
            fgcolor   = (self.story.missing or self.story.excluded) and Blitbuffer.COLOR_DARK_GRAY or nil,
        }
        table.insert(content, VerticalSpan:new{ width = 4 })
        table.insert(content, title_widget)
    end

    self[1] = FrameContainer:new{
        width      = self.cell_width,
        height     = self.cell_height,
        padding    = GRID_CELL_GAP,
        bordersize = 0,
        background = self.story.missing and Blitbuffer.gray(0.8) or Blitbuffer.COLOR_WHITE,
        CenterContainer:new{
            dimen = Geom:new{ w = self.cell_width - 2 * GRID_CELL_GAP, h = inner_h },
            content,
        },
    }
end

function StoryCoverCell:update()
    if self[1] then
        self[1]:free()
        self[1] = nil
    end
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

function StoryCoverCell:onHoldSelect()
    if self.menu and self.menu.onStoryHold then
        self.menu:onStoryHold(self.story)
    end
    return true
end

return {
    StoryListItem    = StoryListItem,
    StoryCoverCell   = StoryCoverCell,
    extractEpubCover = extractEpubCover,
    STORY_COVER_HEIGHT = STORY_COVER_HEIGHT,
    STORY_COVER_WIDTH  = STORY_COVER_WIDTH,
    STORY_ITEM_PAD     = STORY_ITEM_PAD,
    GRID_CELL_GAP      = GRID_CELL_GAP,
    GRID_ROW_GAP       = GRID_ROW_GAP,
}
