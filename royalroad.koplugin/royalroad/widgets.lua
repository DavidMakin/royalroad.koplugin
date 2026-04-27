local Blitbuffer     = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Font           = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom           = require("ui/geometry")
local GestureRange   = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local ImageWidget    = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local Size           = require("ui/size")
local TextBoxWidget  = require("ui/widget/textboxwidget")
local TextWidget     = require("ui/widget/textwidget")
local UIManager      = require("ui/uimanager")
local VerticalGroup  = require("ui/widget/verticalgroup")
local VerticalSpan   = require("ui/widget/verticalspan")
local T              = require("ffi/util").template
local _              = require("gettext")

local STORY_COVER_HEIGHT = 100
local STORY_COVER_WIDTH  = math.floor(STORY_COVER_HEIGHT * 2 / 3)
local STORY_ITEM_PAD     = 8

local GRID_COLS     = 3
local GRID_CELL_GAP = 6
local GRID_ROW_GAP  = 8

local function extractEpubCover(epub_path)
    local FileManagerBookInfo = require("apps/filemanager/filemanagerbookinfo")
    return FileManagerBookInfo:getCoverImage(nil, epub_path)
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

function StoryListItem:onHoldSelect()
    if self.menu and self.menu.onStoryHold then
        self.menu:onStoryHold(self.story)
    end
    return true
end

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
        HoldSelect = {
            GestureRange:new{ ges = "hold", range = self.dimen },
        },
    }

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
    GRID_COLS          = GRID_COLS,
    GRID_CELL_GAP      = GRID_CELL_GAP,
    GRID_ROW_GAP       = GRID_ROW_GAP,
}
