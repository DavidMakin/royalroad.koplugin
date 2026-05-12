local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local ButtonDialog    = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
local Geom            = require("ui/geometry")
local InfoMessage     = require("ui/widget/infomessage")
local InputDialog     = require("ui/widget/inputdialog")
local ProgressWidget  = require("ui/widget/progresswidget")
local Size            = require("ui/size")
local TextWidget      = require("ui/widget/textwidget")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local lfs             = require("libs/libkoreader-lfs")
local logger          = require("logger")
local socket          = require("socket")
local T               = require("ffi/util").template
local util            = require("util")
local _               = require("gettext")
local NetworkMgr      = require("ui/network/manager")

local widgets        = require("royalroad/widgets")
local C              = require("royalroad/constants")
local extractEpubCover = widgets.extractEpubCover
local fitText          = widgets.fitText

local M = {}

local SCHEDULE_DELAY       = C.NETWORK.SCHEDULE_DELAY
local YIELD_DELAY          = C.NETWORK.YIELD_DELAY
local MAX_COVER_CACHE      = C.CACHE.MAX_COVERS

local function json_str(s)
    return (s or "")
        :gsub('\\', '\\\\')
        :gsub('"',  '\\"')
        :gsub('\n', '\\n')
        :gsub('\r', '\\r')
        :gsub('\t', '\\t')
end

function M:downloadStory()
    local function doDownload()
        local input = self.input_dialog:getInputText()
        UIManager:close(self.input_dialog)
        if input and input ~= "" then
            local fiction_id = input:match("/fiction/(%d+)") or input:match("^%s*(%d+)%s*$")
            if fiction_id then
                self:processFiction(fiction_id)
            else
                UIManager:show(InfoMessage:new{
                    text    = _("Invalid input. Enter a fiction ID or a Royal Road URL."),
                    timeout = 4,
                })
            end
        end
    end

    local btn_row = {
        {
            text = _("Cancel"),
            callback = function()
                UIManager:close(self.input_dialog)
            end,
        },
    }
    table.insert(btn_row, {
        text = _("Download"),
        is_enter_default = true,
        callback = doDownload,
    })

    self.input_dialog = InputDialog:new{
        title      = _("Enter Royal Road Fiction ID or URL"),
        input_hint = _("e.g., 73475 or royalroad.com/fiction/73475/..."),
        input_type = "string",
        text_height = Font:getFace("x_smallinfofont").size * 5,
        buttons = { btn_row },
    }
    UIManager:show(self.input_dialog)
    self.input_dialog:onShowKeyboard()
end

function M:_fetchStoryData(fiction_id, opts)
    local fiction_url = C.BASE_URL .. "/fiction/" .. fiction_id
    local story_html = self:fetchPageCached(fiction_url)
    if not story_html then
        if opts.show_progress then
            UIManager:show(InfoMessage:new{ text = _("Failed to fetch story page."), timeout = 5 })
        end
        return nil
    end

    local story_title  = self:extractTitle(story_html)
    local author       = self:extractAuthor(story_html)
    local chapter_urls = self:extractChapterURLs(story_html, fiction_id)
    local cover_url    = self:extractCoverURL(story_html)
    local description  = self:extractDescription(story_html)
    if description and description ~= "" then
        if not self._pending_descriptions then self._pending_descriptions = {} end
        self._pending_descriptions[fiction_id] = description
    end

    if opts.fetch_metadata then
        local rating           = self:extractRating(story_html)
        local status           = self:extractStatus(story_html)
        local word_count       = self:extractWordCount(story_html)
        local last_chapter_date = self:extractLastChapterDate(story_html)
        if rating or status or word_count or last_chapter_date then
            if not self._pending_metadata then self._pending_metadata = {} end
            self._pending_metadata[fiction_id] = {
                rating = rating, status = status,
                word_count = word_count, last_chapter_date = last_chapter_date,
            }
        end
    end

    if not story_title or #chapter_urls == 0 then
        if opts.show_progress then
            UIManager:show(InfoMessage:new{
                text = T(_("Failed to parse story.\nTitle: %1\nChapters: %2"),
                    story_title or "NONE", #chapter_urls),
                timeout = 10,
            })
        end
        return nil
    end

    local cover_image = nil
    if cover_url then
        if opts.show_progress then
            UIManager:show(InfoMessage:new{ text = _("Downloading cover image..."), timeout = 1 })
        end
        local image_data, mime_type, extension = self:fetchImage(cover_url)
        if image_data then
            cover_image = { data = image_data, mime_type = mime_type, extension = extension }
        end
    end

    return {
        story_title   = story_title,
        author        = author,
        chapter_urls  = chapter_urls,
        cover_url     = cover_url,
        cover_image   = cover_image,
    }
end

function M:processFiction(fiction_id)
    NetworkMgr:runWhenOnline(function()
        logger.info("Royal Road: Processing fiction ID:", fiction_id)

        if self.downloaded_stories[fiction_id] then
            local story = self.downloaded_stories[fiction_id]
            local already_dialog
            local buttons = {}

            if story.queued_chapter_urls and #story.queued_chapter_urls > #(story.chapter_urls or {}) then
                local remaining = #story.queued_chapter_urls - #(story.chapter_urls or {})
                table.insert(buttons, {{
                    text = T(_("Resume (%1 chapters left)"), remaining),
                    callback = function()
                        UIManager:close(already_dialog)
                        UIManager:scheduleIn(SCHEDULE_DELAY, function()
                            self:resumeDownload(fiction_id)
                        end)
                    end,
                }})
            end

            table.insert(buttons, {{
                text = _("Check for updates"),
                callback = function()
                    UIManager:close(already_dialog)
                    UIManager:scheduleIn(SCHEDULE_DELAY, function()
                        self:checkSingleStoryForUpdates(fiction_id)
                    end)
                end,
            }})
            table.insert(buttons, {{
                text = _("Re-download"),
                callback = function()
                    UIManager:close(already_dialog)
                    UIManager:scheduleIn(SCHEDULE_DELAY, function()
                        self:deleteAndRedownload(fiction_id)
                    end)
                end,
            }})
            table.insert(buttons, {{
                text = _("Cancel"),
                callback = function() UIManager:close(already_dialog) end,
            }})

            already_dialog = ButtonDialog:new{
                title   = T(_("%1\nalready downloaded."), story.title or fiction_id),
                buttons = buttons,
            }
            UIManager:show(already_dialog)
            return
        end

        UIManager:show(InfoMessage:new{ text = T(_("Fetching story %1..."), fiction_id), timeout = 2 })

        local data = self:_fetchStoryData(fiction_id, { show_progress = true, fetch_metadata = true })
        if not data then return end

        logger.info("Royal Road: Cover URL:", data.cover_url or "none found")

        local chapter_urls  = data.chapter_urls
        local total_available = #chapter_urls
        if self.debug_chapter_limit and total_available > self.debug_chapter_limit then
            local limited_urls = {}
            for i = 1, self.debug_chapter_limit do
                table.insert(limited_urls, chapter_urls[i])
            end
            chapter_urls = limited_urls
            logger.info("Royal Road: DEBUG - Limited from", total_available, "to", #chapter_urls, "chapters")
        end

        self:showChapterRangeDialog(fiction_id, data.story_title, data.author, chapter_urls, data.cover_image, data.cover_url, total_available)
    end)
end

function M:_resumeWithCandidateUrls(fiction_id, candidate_urls)
    local story = self.downloaded_stories[fiction_id]
    if not story then return end

    local fetched_set = {}
    for _, u in ipairs(story.chapter_urls or {}) do fetched_set[u] = true end

    local has_missing = false
    for _, u in ipairs(candidate_urls) do
        if not fetched_set[u] then has_missing = true; break end
    end

    if not has_missing then
        story.partial_of = nil
        story.queued_chapter_urls = nil
        self:saveSettings()
        UIManager:show(InfoMessage:new{
            text    = T(_("%1 is already complete."), story.title),
            timeout = 3,
        })
        return
    end

    logger.info("Royal Road: Resuming download for", fiction_id, "with", #candidate_urls, "candidate URLs")
    self:updateStory(fiction_id, candidate_urls)
end

function M:resumeDownload(fiction_id)
    local story = self.downloaded_stories[fiction_id]
    if not story or not story.queued_chapter_urls then return end
    self:_resumeWithCandidateUrls(fiction_id, story.queued_chapter_urls)
end

function M:processFictionAll(fiction_id)
    NetworkMgr:runWhenOnline(function()
        logger.info("Royal Road: Bulk processing fiction ID:", fiction_id)

        if self.downloaded_stories[fiction_id] then
            UIManager:scheduleIn(SCHEDULE_DELAY, function()
                self:checkSingleStoryForUpdates(fiction_id)
            end)
            return
        end

        UIManager:show(InfoMessage:new{ text = T(_("Fetching story %1..."), fiction_id), timeout = 2 })

        local data = self:_fetchStoryData(fiction_id, {})
        if not data then return end

        self:queueDownload(fiction_id, data.story_title, data.author, data.chapter_urls, data.cover_image, data.cover_url, nil)
    end)
end

function M:showChapterRangeDialog(fiction_id, story_title, author, chapter_urls, cover_image, cover_url, total_available)
    local function doDownload(from_ch, to_ch)
        local selected_urls = {}
        for i = from_ch, to_ch do
            table.insert(selected_urls, chapter_urls[i])
        end
        local partial_of = (to_ch < total_available) and total_available or nil

        UIManager:show(InfoMessage:new{
            text    = T(_("Found: %1\nBy: %2\nChapters: %3-%4 of %5\n\nDownloading..."),
                        story_title, author or "Unknown", from_ch, to_ch, total_available),
            timeout = 3,
        })

        UIManager:scheduleIn(SCHEDULE_DELAY, function()
            self:queueDownload(fiction_id, story_title, author, selected_urls, cover_image, cover_url, partial_of)
        end)
    end

    local range_dialog
    range_dialog = InputDialog:new{
        title       = _("Select chapters to download"),
        description = T(_("%1\nBy: %2\n%3 chapters available\n\nLeave as-is to download all.\nEnter a range like 1-%3 to download specific chapters.\nEnter a single number like 50 to download the last 50 chapters."),
                        story_title, author or _("Unknown"), total_available),
        input      = "1-" .. tostring(total_available),
        input_hint = T(_("all=1-%1  last 50=50  range=1-%1"), total_available),
        input_type = "string",
        buttons = {
            {
                {
                    text = _("Cancel"),
                    callback = function()
                        UIManager:close(range_dialog)
                    end,
                },
                {
                    text = _("Download"),
                    is_enter_default = true,
                    callback = function()
                        local raw = range_dialog:getInputText():gsub("%s", "")
                        UIManager:close(range_dialog)

                        local from_ch, to_ch
                        local range_from, range_to = raw:match("^(%d+)-(%d+)$")
                        if range_from and range_to then
                            from_ch = math.max(1, tonumber(range_from))
                            to_ch   = math.min(total_available, tonumber(range_to))
                        else
                            local n = tonumber(raw)
                            if n then
                                from_ch = math.max(1, total_available - n + 1)
                                to_ch   = total_available
                            else
                                from_ch = 1
                                to_ch   = total_available
                            end
                        end

                        if from_ch > to_ch then
                            UIManager:show(InfoMessage:new{
                                text    = _("Invalid range."),
                                timeout = 3,
                            })
                            return
                        end

                        doDownload(from_ch, to_ch)
                    end,
                },
            },
        },
    }
    UIManager:show(range_dialog)
    range_dialog:onShowKeyboard()
end

function M:queueDownload(fiction_id, story_title, author, chapter_urls, cover_image, cover_url, partial_of)
    if not self._download_queue then self._download_queue = {} end
    table.insert(self._download_queue, {
        fiction_id    = fiction_id,
        story_title   = story_title,
        author        = author,
        chapter_urls  = chapter_urls,
        cover_image   = cover_image,
        cover_url     = cover_url,
        partial_of    = partial_of,
    })
    if not self._download_active then
        self:_processDownloadQueue()
    else
        UIManager:show(InfoMessage:new{
            text = T(_("Queued: %1\n(%2 items in queue)"), story_title, #self._download_queue),
            timeout = 3,
        })
    end
end

function M:_processDownloadQueue()
    if not self._download_queue or #self._download_queue == 0 then
        self._download_active = false
        return
    end
    self._download_active = true
    local item = table.remove(self._download_queue, 1)
    self:downloadChapters(item.fiction_id, item.story_title, item.author,
        item.chapter_urls, item.cover_image, item.cover_url, item.partial_of)
end

function M:_onDownloadComplete()
    self._download_active = false
    self._page_cache = nil
    if self._download_queue and #self._download_queue > 0 then
        UIManager:scheduleIn(1, function() self:_processDownloadQueue() end)
    end
end

function M:cachedExtractCover(fiction_id, epub_path)
    if not self._cover_bb_cache then
        self._cover_bb_cache = {}
        self._cover_bb_order = {}
    end
    if self._cover_bb_cache[fiction_id] then
        return self._cover_bb_cache[fiction_id]
    end

    local function cacheBB(bb)
        local MAX_COVERS = MAX_COVER_CACHE
        if #self._cover_bb_order >= MAX_COVERS then
            local oldest = table.remove(self._cover_bb_order, 1)
            local old_bb = self._cover_bb_cache[oldest]
            if old_bb then old_bb:free() end
            self._cover_bb_cache[oldest] = nil
        end
        self._cover_bb_cache[fiction_id] = bb
        table.insert(self._cover_bb_order, fiction_id)
    end

    local disk_path = self.cover_cache_dir .. "/" .. fiction_id .. ".png"
    local f = io.open(disk_path, "rb")
    if f then
        f:close()
        local ok, RenderImage = pcall(require, "ui/renderimage")
        if ok then
            local bb = RenderImage:renderImageFile(disk_path, false)
            if bb then
                cacheBB(bb)
                return bb
            end
        end
    end

    local bb = extractEpubCover(epub_path)
    if bb then
        cacheBB(bb)
        local ok, err = util.makePath(self.cover_cache_dir)
        if ok or not err then
            pcall(function() bb:writePNG(disk_path, false) end)
        end
    end
    return bb
end

function M:_invalidateCoverCache(fiction_id)
    if self._cover_bb_cache and fiction_id then
        local bb = self._cover_bb_cache[fiction_id]
        if bb then bb:free() end
        self._cover_bb_cache[fiction_id] = nil
        if self._cover_bb_order then
            for i, id in ipairs(self._cover_bb_order) do
                if id == fiction_id then
                    table.remove(self._cover_bb_order, i)
                    break
                end
            end
        end
    end
    if self.cover_cache_dir and fiction_id then
        os.remove(self.cover_cache_dir .. "/" .. fiction_id .. ".png")
    end
end

function M:downloadChapters(fiction_id, story_title, author, chapter_urls, cover_image, cover_url, partial_of)
    local total_chapters = #chapter_urls
    local chapters_data = {}
    local start_time = socket.gettime()

    self:keepScreenAwake()

    local padding     = Size.padding.large
    local text_width  = math.floor(Device.screen:getWidth() * 0.8) - padding * 2
    local title_face  = Font:getFace("smalltfont")
    local body_face   = Font:getFace("smallffont")

    local queue_size = self._download_queue and #self._download_queue or 0
    local title_text = queue_size > 0
        and T(_("Downloading... (%1 more queued)"), queue_size)
        or _("Downloading...")
    local title_widget = TextWidget:new{
        text = fitText(title_text, title_face, text_width),
        face = title_face,
        bold = true,
    }

    local progress_text = TextWidget:new{
        text  = T(_("Chapter 0/%1"), total_chapters),
        face  = body_face,
        width = text_width,
    }

    local eta_text = TextWidget:new{
        text  = _("Calculating ETA..."),
        face  = body_face,
        width = text_width,
    }

    local progress_bar = ProgressWidget:new{
        width = text_width,
        height = Size.item.height_default / 3,
        percentage = 0,
        margin_h = 0,
        margin_v = Size.padding.small,
        radius = Size.radius.default,
        bgcolor = Blitbuffer.COLOR_LIGHT_GRAY,
        fillcolor = Blitbuffer.COLOR_DARK_GRAY,
    }

    local state = {
        fiction_id     = fiction_id,
        story_title    = story_title,
        author         = author,
        chapter_urls   = chapter_urls,
        cover_image    = cover_image,
        cover_url      = cover_url,
        total_chapters = total_chapters,
        chapters_data  = chapters_data,
        start_time     = start_time,
        cancelled      = false,
        failed_chapters = 0,
        failed_indices = {},
        failed_urls    = {},
        partial_of     = partial_of,
    }

    local cancel_button = Button:new{
        text = _("Cancel"),
        callback = function()
            state.cancelled = true
        end,
    }
    local cancel_centered = CenterContainer:new{
        dimen = Geom:new{ w = text_width, h = cancel_button:getSize().h },
        cancel_button,
    }

    local progress_group = VerticalGroup:new{
        align = "left",
        title_widget,
        progress_text,
        progress_bar,
        eta_text,
        cancel_centered,
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

    self:downloadNextChapter(state, 1)
end

function M:downloadNextChapter(state, i)
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
            local entry = self.downloaded_stories[state.fiction_id]
            if entry then
                entry.partial_of          = state.total_chapters
                entry.chapter_urls        = fetched_urls
                entry.queued_chapter_urls = state.chapter_urls
                self:saveSettings()
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
        self:_onDownloadComplete()
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
            local entry = self.downloaded_stories[state.fiction_id]
            if entry then
                if state.partial_of then
                    entry.partial_of = state.partial_of
                end
                if self._pending_descriptions and self._pending_descriptions[state.fiction_id] then
                    entry.description = self._pending_descriptions[state.fiction_id]
                    self._pending_descriptions[state.fiction_id] = nil
                end
                if self._pending_metadata and self._pending_metadata[state.fiction_id] then
                    local meta = self._pending_metadata[state.fiction_id]
                    if meta.rating then entry.rating = meta.rating end
                    if meta.status then entry.status = meta.status end
                    if meta.word_count then entry.word_count = meta.word_count end
                    if meta.last_chapter_date then entry.last_chapter_date = meta.last_chapter_date end
                    self._pending_metadata[state.fiction_id] = nil
                end
                self:saveSettings()
            end
            if #state.failed_indices > 0 then
                UIManager:scheduleIn(0.5, function()
                    local retry_dialog
                    retry_dialog = ButtonDialog:new{
                        title = T(_("Download complete. %1 chapters failed."), #state.failed_indices),
                        buttons = {
                            {{
                                text = _("Retry failed chapters"),
                                callback = function()
                                    UIManager:close(retry_dialog)
                                    self:_retryFailedChapters(state)
                                end,
                            }},
                            {{
                                text = _("Keep as-is"),
                                callback = function()
                                    UIManager:close(retry_dialog)
                                end,
                            }},
                        },
                    }
                    UIManager:show(retry_dialog)
                end)
            end
        else
            UIManager:show(InfoMessage:new{
                text = _("Failed to download chapters."),
            })
        end
        self:allowScreenSleep()
        self:_onDownloadComplete()
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

    UIManager:scheduleIn(YIELD_DELAY, function()
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
                state.failed_chapters = state.failed_chapters + 1
                table.insert(state.failed_indices, i)
                table.insert(state.failed_urls, chapter_url)
                table.insert(state.chapters_data, {
                    title = "Chapter " .. i,
                    content = "<p>[Chapter content could not be extracted.]</p>",
                })
            end
        else
            logger.warn("Royal Road: Failed to fetch chapter", i, "from", chapter_url)
            state.failed_chapters = state.failed_chapters + 1
            table.insert(state.failed_indices, i)
            table.insert(state.failed_urls, chapter_url)
            table.insert(state.chapters_data, {
                title = "Chapter " .. i,
                content = "<p>[Chapter failed to download.]</p>",
            })
        end

        UIManager:scheduleIn(self.rate_limit_delay, function()
            self:downloadNextChapter(state, i + 1)
        end)
    end)
end

function M:_retryFailedChapters(state)
    if not state.failed_urls or #state.failed_urls == 0 then return end
    UIManager:show(InfoMessage:new{
        text    = T(_("Retrying %1 failed chapters..."), #state.failed_urls),
        timeout = 2,
    })
    UIManager:scheduleIn(SCHEDULE_DELAY, function()
        self:_doRetryFailedChapters(state, 1)
    end)
end

function M:_doRetryFailedChapters(state, i)
    if i > #state.failed_urls then
        if self.use_epub then
            self:saveAsEPUB(state.fiction_id, state.story_title, state.author, state.chapters_data, state.cover_image, state.chapter_urls, state.cover_url)
        else
            self:saveAsHTML(state.fiction_id, state.story_title, state.author, state.chapters_data)
        end
        UIManager:show(InfoMessage:new{
            text = _("Retry complete. EPUB rebuilt with corrected chapters."),
        })
        return
    end
    local url = state.failed_urls[i]
    local chapter_idx = state.failed_indices[i]
    UIManager:scheduleIn(YIELD_DELAY, function()
        local chapter_html = self:fetchPage(url)
        if chapter_html then
            local chapter_title = self:extractChapterTitle(chapter_html)
            local chapter_content = self:extractChapterContent(chapter_html)
            if chapter_title and chapter_content then
                state.chapters_data[chapter_idx] = {
                    title = chapter_title,
                    content = chapter_content,
                }
            end
        end
        UIManager:scheduleIn(self.rate_limit_delay, function()
            self:_doRetryFailedChapters(state, i + 1)
        end)
    end)
end

function M:bulkImport()
    local dialog
    dialog = InputDialog:new{
        title = _("Bulk import fiction IDs or URLs"),
        input_hint = _("One URL or ID per line..."),
        input_type = "string",
        text_height = Font:getFace("x_smallinfofont").size * 8,
        buttons = {{
            {
                text = _("Cancel"),
                callback = function()
                    UIManager:close(dialog)
                end,
            },
            {
                text = _("Import"),
                is_enter_default = true,
                callback = function()
                    local text = dialog:getInputText()
                    UIManager:close(dialog)
                    if not text or text == "" then return end
                    local ids = {}
                    for line in (text .. "\n"):gmatch("([^\n]*)\n") do
                        local id = line:match("/fiction/(%d+)") or line:match("^%s*(%d+)%s*$")
                        if id then
                            table.insert(ids, id)
                        end
                    end
                    if #ids == 0 then return end
                    UIManager:show(InfoMessage:new{
                        text = T(_("Queuing %1 stories..."), #ids),
                        timeout = 2,
                    })
                    for i, id in ipairs(ids) do
                        UIManager:scheduleIn(0.2 * i, function()
                            self:processFictionAll(id)
                        end)
                    end
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function M:exportReadingList()
    local export_dialog
    export_dialog = ButtonDialog:new{
        title = _("Export reading list"),
        buttons = {
            {{
                text = _("Export as JSON"),
                callback = function()
                    UIManager:close(export_dialog)
                    local DocSettings = require("docsettings")
                    local entries = {}
                    for fiction_id, story in pairs(self.downloaded_stories) do
                        local progress = 0
                        if story.epub_path then
                            local ok, ds = pcall(function() return DocSettings:open(story.epub_path) end)
                            if ok and ds and ds.data then
                                progress = ds.data.percent_finished or 0
                            end
                        end
                        local entry = string.format(
                            '{"fiction_id":"%s","title":"%s","author":"%s","chapters":%d,"progress":%s,"epub_path":"%s"}',
                            json_str(fiction_id),
                            json_str(story.title),
                            json_str(story.author),
                            #(story.chapter_urls or {}),
                            tostring(progress),
                            json_str(story.epub_path)
                        )
                        table.insert(entries, entry)
                    end
                    local json = "[" .. table.concat(entries, ",") .. "]"
                    local path = self.download_dir .. "/royalroad_export.json"
                    local f = io.open(path, "w")
                    if f then
                        f:write(json)
                        f:close()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Exported to:\n%1"), path),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Failed to write export file."),
                            timeout = 3,
                        })
                    end
                end,
            }},
            {{
                text = _("Export as CSV"),
                callback = function()
                    UIManager:close(export_dialog)
                    local DocSettings = require("docsettings")
                    local rows = { '"fiction_id","title","author","chapters","progress","epub_path"' }
                    for fiction_id, story in pairs(self.downloaded_stories) do
                        local progress = 0
                        if story.epub_path then
                            local ok, ds = pcall(function() return DocSettings:open(story.epub_path) end)
                            if ok and ds and ds.data then
                                progress = ds.data.percent_finished or 0
                            end
                        end
                        local row = string.format('"%s","%s","%s",%d,%s,"%s"',
                            fiction_id,
                            (story.title or ""):gsub('"', '""'),
                            (story.author or ""):gsub('"', '""'),
                            #(story.chapter_urls or {}),
                            tostring(progress),
                            (story.epub_path or ""):gsub('"', '""')
                        )
                        table.insert(rows, row)
                    end
                    local path = self.download_dir .. "/royalroad_export.csv"
                    local f = io.open(path, "w")
                    if f then
                        f:write(table.concat(rows, "\n"))
                        f:close()
                        UIManager:show(InfoMessage:new{
                            text = T(_("Exported to:\n%1"), path),
                        })
                    else
                        UIManager:show(InfoMessage:new{
                            text = _("Failed to write export file."),
                            timeout = 3,
                        })
                    end
                end,
            }},
            {{
                text = _("Cancel"),
                callback = function() UIManager:close(export_dialog) end,
            }},
        },
    }
    UIManager:show(export_dialog)
end

return M
