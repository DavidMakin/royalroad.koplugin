local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local DocSettings     = require("docsettings")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local InfoMessage     = require("ui/widget/infomessage")
local ProgressWidget  = require("ui/widget/progresswidget")
local RenderText      = require("ui/rendertext")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local logger          = require("logger")
local socket          = require("socket")
local NetworkMgr      = require("ui/network/manager")
local T               = require("ffi/util").template
local _               = require("gettext")

local M = {}

local SCHEDULE_DELAY = 0.1

local function fitText(text, face, max_width)
    local w = RenderText:sizeUtf8Text(0, max_width, face, text, true, false).x
    if w <= max_width then return text end
    local ellipsis = "…"
    local lo, hi = 1, #text
    while lo < hi do
        local mid = math.floor((lo + hi + 1) / 2)
        local candidate = text:sub(1, mid) .. ellipsis
        if RenderText:sizeUtf8Text(0, max_width, face, candidate, true, false).x <= max_width then
            lo = mid
        else
            hi = mid - 1
        end
    end
    return text:sub(1, lo) .. ellipsis
end

function M:checkForUpdates()
    if self:countDownloadedStories() == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No downloaded stories to check.\n\nDownload a story first, then you can check for updates."),
        })
        return
    end

    UIManager:show(InfoMessage:new{
        text = _("Checking for updates..."),
        timeout = 2,
    })

    UIManager:scheduleIn(SCHEDULE_DELAY, function()
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

function M:performUpdateCheck()
    NetworkMgr:runWhenOnline(function()
        local stories_with_updates = {}
        local errors = {}

        for fiction_id, story in pairs(self.downloaded_stories) do
            logger.info("Royal Road: Checking updates for", story.title, "(", fiction_id, ")")

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
            socket.sleep(self.rate_limit_delay)
        end

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

        self:showUpdateMenu(stories_with_updates)
    end)
end

function M:showUpdateMenu(stories_with_updates)
    local count = #stories_with_updates

    if count == 1 then
        local story = stories_with_updates[1]
        local ButtonDialog = require("ui/widget/buttondialog")
        self.update_dialog = ButtonDialog:new{
            title = T(_("%1 has %2 new chapters"), story.title, story.new_chapters),
            buttons = {
                {{
                    text = _("Update"),
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
                }},
                {{
                    text = _("Cancel"),
                    callback = function() UIManager:close(self.update_dialog) end,
                }},
            },
        }
        UIManager:show(self.update_dialog)
        return
    end

    local total_new = 0
    for _, s in ipairs(stories_with_updates) do
        total_new = total_new + s.new_chapters
    end

    local ButtonDialog = require("ui/widget/buttondialog")
    self.update_dialog = ButtonDialog:new{
        title = T(_("%1 stories have updates (%2 new chapters total)"), count, total_new),
        buttons = {
            {{
                text = T(_("Update All (%1 stories)"), count),
                callback = function()
                    UIManager:close(self.update_dialog)
                    self:updateAllStories(stories_with_updates)
                end,
            }},
            {{
                text = _("Choose…"),
                callback = function()
                    UIManager:close(self.update_dialog)
                    self:showUpdatePicker(stories_with_updates)
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(self.update_dialog) end,
            }},
        },
    }
    UIManager:show(self.update_dialog)
end

function M:showUpdatePicker(stories_with_updates)
    local Menu      = require("ui/widget/menu")

    local selected = {}
    local item_table = {}
    for _i, story in ipairs(stories_with_updates) do
        selected[_i] = false
        table.insert(item_table, {
            text  = "○  " .. T(_("%1  (+%2)"), story.title, story.new_chapters),
            title = T(_("%1  (+%2)"), story.title, story.new_chapters),
            story = story,
            idx   = _i,
        })
    end

    local picker

    local function selectedCount()
        local n = 0
        for _, v in pairs(selected) do if v then n = n + 1 end end
        return n
    end

    local function updateTitle()
        local n = selectedCount()
        local title = n == 0 and _("Tap to select stories") or T(_("Update selected (%1)"), n)
        if picker and picker.title_bar then
            picker.title_bar:setTitle(title)
        end
    end

    local function runUpdate()
        local n = selectedCount()
        if n == 0 then
            UIManager:show(InfoMessage:new{
                text    = _("No stories selected."),
                timeout = 2,
            })
            return
        end
        UIManager:close(picker)
        local chosen = {}
        for _i, story in ipairs(stories_with_updates) do
            if selected[_i] then table.insert(chosen, story) end
        end
        if n == 1 then
            local ok, err = pcall(function()
                self:updateStory(chosen[1].fiction_id, chosen[1].current_urls)
            end)
            if not ok then
                logger.err("Royal Road: Update failed:", err)
                UIManager:show(InfoMessage:new{
                    text = T(_("Update failed:\n%1"), tostring(err)),
                })
            end
        else
            self:updateAllStories(chosen)
        end
    end

    local function refreshItems()
        for _, item in ipairs(item_table) do
            item.text = (selected[item.idx] and "●  " or "○  ") .. item.title
        end
        picker:updateItems()
        updateTitle()
    end

    picker = Menu:new{
        title              = _("Tap to select stories"),
        item_table         = item_table,
        items_per_page     = (G_reader_settings:readSetting("items_per_page") or 14) - 1,
        covers_fullscreen  = true,
        is_borderless      = true,
        is_popout          = false,
        title_bar_fm_style = true,
        title_bar_left_icon = "check",
        onLeftButtonTap    = runUpdate,
        onMenuSelect       = function(_, item)
            selected[item.idx] = not selected[item.idx]
            refreshItems()
        end,
        close_callback     = function() UIManager:close(picker) end,
    }

    UIManager:show(picker)
end

function M:updateAllStories(stories_with_updates)
    local total = #stories_with_updates
    local cancelled = false

    local padding     = Device.screen:scaleBySize(10)
    local frame_width = math.floor(Device.screen:getWidth() * 0.8)
    local text_width  = frame_width - padding * 2
    local label_face  = Font:getFace("smallinfofont")

    local story_label = TextWidget:new{
        text  = "",
        face  = label_face,
        width = text_width,
    }
    local chapter_text = TextWidget:new{
        text  = "",
        face  = label_face,
        width = text_width,
    }
    local progress_bar = ProgressWidget:new{
        width      = text_width,
        height     = Device.screen:scaleBySize(10),
        percentage = 0,
    }
    local cancel_button = Button:new{
        text     = _("Cancel"),
        callback = function() cancelled = true end,
    }
    local cancel_centered = CenterContainer:new{
        dimen = Geom:new{ w = text_width, h = cancel_button:getSize().h },
        cancel_button,
    }
    local progress_frame = FrameContainer:new{
        padding    = padding,
        background = Blitbuffer.COLOR_WHITE,
        VerticalGroup:new{
            align = "left",
            story_label,
            chapter_text,
            progress_bar,
            cancel_centered,
        },
    }
    local progress_dialog = CenterContainer:new{
        dimen = Device.screen:getSize(),
        progress_frame,
    }
    UIManager:show(progress_dialog)
    self:keepScreenAwake()

    local batch = {
        cancelled       = function() return cancelled end,
        story_label     = story_label,
        chapter_text    = chapter_text,
        progress_bar    = progress_bar,
        progress_dialog = progress_dialog,
        text_width      = text_width,
        label_face      = label_face,
    }

    local function updateNext(index)
        if cancelled then
            UIManager:close(progress_dialog)
            self:allowScreenSleep()
            UIManager:show(InfoMessage:new{
                text    = _("Update cancelled."),
                timeout = 3,
            })
            return
        end
        if index > total then
            UIManager:close(progress_dialog)
            self:allowScreenSleep()
            UIManager:show(InfoMessage:new{
                text = T(_("Updated %1 stories!"), total),
            })
            return
        end

        local story = stories_with_updates[index]
        local prefix = T(_("Story %1/%2: "), index, total)
        local title_space = text_width - RenderText:sizeUtf8Text(0, text_width, label_face, prefix, true, false).x
        local label_text = prefix .. fitText(story.title, label_face, title_space)
        story_label:setText(label_text)
        UIManager:setDirty(progress_dialog, "ui")
        UIManager:scheduleIn(SCHEDULE_DELAY, function()
            self:updateStory(story.fiction_id, story.current_urls, function()
                updateNext(index + 1)
            end, batch)
        end)
    end

    updateNext(1)
end

function M:updateStory(fiction_id, current_urls, on_complete, batch)
    local story = self.downloaded_stories[fiction_id]
    if not story then
        logger.warn("Royal Road: Story not found in downloaded list:", fiction_id)
        if on_complete then on_complete() end
        return
    end

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

    local stored_set = {}
    for _, url in ipairs(story.chapter_urls or {}) do
        stored_set[url] = true
    end

    local new_urls = {}
    for _, url in ipairs(current_urls) do
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

    local existing_chapters, err = self:extractChaptersFromEPUB(epub_path)
    if not existing_chapters then
        logger.err("Royal Road: Failed to extract chapters from EPUB:", epub_path, err)
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to read existing EPUB:\n%1"), err or "Unknown error"),
        })
        if on_complete then on_complete() end
        return
    end

    logger.info("Royal Road: Extracted", #existing_chapters, "existing chapters")

    self:downloadNewChapters(fiction_id, story, existing_chapters, new_urls, current_urls, old_position, on_complete, batch)
end

function M:downloadNewChapters(fiction_id, story, existing_chapters, new_urls, all_urls, old_position, on_complete, batch)
    local new_chapters = {}
    local total_new = #new_urls
    local start_time = socket.gettime()

    local progress_text, progress_bar, progress_dialog

    if batch then
        progress_text    = batch.chapter_text
        progress_bar     = batch.progress_bar
        progress_dialog  = batch.progress_dialog
    else
        local padding    = Device.screen:scaleBySize(10)
        local text_width = math.floor(Device.screen:getWidth() * 0.8) - padding * 2
        local face       = Font:getFace("smallinfofont")
        local prefix     = T(_("Updating: "))
        local title_space = text_width - RenderText:sizeUtf8Text(0, text_width, face, prefix, true, false).x

        progress_text = TextWidget:new{
            text  = T(_("Downloading new chapter 1/%1"), total_new),
            face  = face,
            width = text_width,
        }
        progress_bar = ProgressWidget:new{
            width      = text_width,
            height     = Device.screen:scaleBySize(10),
            percentage = 0,
        }

        local cancel_button = Button:new{
            text     = _("Cancel"),
            callback = function() state.cancelled = true end,
        }
        local cancel_centered = CenterContainer:new{
            dimen = Geom:new{ w = text_width, h = cancel_button:getSize().h },
            cancel_button,
        }

        local progress_frame = FrameContainer:new{
            padding    = padding,
            background = Blitbuffer.COLOR_WHITE,
            VerticalGroup:new{
                align = "left",
                TextWidget:new{
                    text  = prefix .. fitText(story.title, face, title_space),
                    face  = face,
                    width = text_width,
                },
                progress_text,
                progress_bar,
                cancel_centered,
            },
        }

        progress_dialog = CenterContainer:new{
            dimen = Device.screen:getSize(),
            progress_frame,
        }

        UIManager:show(progress_dialog)
        self:keepScreenAwake()
    end

    local state = {
        new_urls          = new_urls,
        new_chapters      = new_chapters,
        total_new         = total_new,
        start_time        = start_time,
        progress_text     = progress_text,
        progress_bar      = progress_bar,
        fiction_id        = fiction_id,
        story             = story,
        existing_chapters = existing_chapters,
        all_urls          = all_urls,
        old_position      = old_position,
        on_complete       = on_complete,
        cancelled         = false,
        batch             = batch,
        progress_dialog   = progress_dialog,
    }

    self:downloadNextNewChapter(state, 1)
end

function M:downloadNextNewChapter(state, i)
    local is_cancelled = state.cancelled or (state.batch and state.batch.cancelled())
    if is_cancelled then
        if not state.batch then
            UIManager:close(state.progress_dialog)
            self:allowScreenSleep()
            UIManager:show(InfoMessage:new{
                text    = _("Update cancelled."),
                timeout = 3,
            })
        end
        if state.on_complete then state.on_complete() end
        return
    end

    if i > state.total_new then
        if not state.batch then
            self:allowScreenSleep()
            UIManager:close(state.progress_dialog)
        end
        self:rebuildEPUBWithNewChapters(state)
        return
    end

    local chapter_str = T(_("Downloading new chapter %1/%2"), i, state.total_new)
    if state.batch then
        chapter_str = fitText(chapter_str, state.batch.label_face, state.batch.text_width)
    end
    state.progress_text:setText(chapter_str)
    state.progress_bar:setPercentage(i / state.total_new)
    UIManager:setDirty(state.progress_dialog, "ui")

    local full_url = state.new_urls[i]

    UIManager:scheduleIn(SCHEDULE_DELAY, function()
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

        UIManager:scheduleIn(self.rate_limit_delay, function()
            self:downloadNextNewChapter(state, i + 1)
        end)
    end)
end

function M:rebuildEPUBWithNewChapters(state)
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
        if not self._cover_cache then self._cover_cache = {} end
        if self._cover_cache[cover_url] then
            cover_image = {
                data      = self._cover_cache[cover_url].data,
                mime_type = self._cover_cache[cover_url].mime_type,
                extension = self._cover_cache[cover_url].extension,
            }
            logger.info("Royal Road: Using cached cover image for update")
        else
            local image_data, mime_type, extension = self:fetchImage(cover_url)
            if image_data then
                cover_image = {
                    data = image_data,
                    mime_type = mime_type,
                    extension = extension,
                }
                self._cover_cache[cover_url] = { data = image_data, mime_type = mime_type, extension = extension }
                logger.info("Royal Road: Fetched cover image for update")
            end
        end
    end

    self:saveAsEPUB(
        state.fiction_id,
        state.story.title,
        state.story.author,
        all_chapters,
        cover_image,
        state.all_urls,
        cover_url,
        state.story.epub_path,
        state.on_complete ~= nil
    )
    self._cover_cache = nil

    local entry = self.downloaded_stories[state.fiction_id]
    if entry then
        entry.partial_of = nil
        entry.unread_new_count = (entry.unread_new_count or 0) + #state.new_chapters
        self:saveSettings()
    end

    if state.old_position.last_xpointer then
        UIManager:scheduleIn(0.5, function()
            local ok, doc_settings = pcall(function()
                local entry = self.downloaded_stories[state.fiction_id]
                return DocSettings:open(entry and entry.epub_path or state.story.epub_path)
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

    if state.on_complete then
        state.on_complete()
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Updated %1!\n\n+%2 new chapters\nTotal: %3 chapters\n\nReading position preserved."),
                state.story.title, #state.new_chapters, #all_chapters),
        })
    end
end

return M
