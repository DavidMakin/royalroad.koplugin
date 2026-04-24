local Blitbuffer      = require("ffi/blitbuffer")
local Button          = require("ui/widget/button")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device          = require("device")
local Font            = require("ui/font")
local FrameContainer  = require("ui/widget/container/framecontainer")
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
local http            = require("socket.http")
local ltn12           = require("ltn12")
local socketutil      = require("socketutil")
local T               = require("ffi/util").template
local _               = require("gettext")

local widgets        = require("royalroad/widgets")
local extractEpubCover = widgets.extractEpubCover

local M = {}

function M:downloadStory()
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

function M:processFiction(fiction_id)
    logger.info("Royal Road: Processing fiction ID:", fiction_id)

    if self.downloaded_stories[fiction_id] then
        UIManager:show(InfoMessage:new{
            text = _("Already downloaded — checking for new chapters..."),
            timeout = 2,
        })
        UIManager:scheduleIn(0.1, function()
            self:checkSingleStoryForUpdates(fiction_id)
        end)
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

    self:queueDownload(fiction_id, story_title, author, chapter_urls, cover_image, cover_url)
end

function M:queueDownload(fiction_id, story_title, author, chapter_urls, cover_image, cover_url)
    if not self._download_queue then self._download_queue = {} end
    table.insert(self._download_queue, {
        fiction_id    = fiction_id,
        story_title   = story_title,
        author        = author,
        chapter_urls  = chapter_urls,
        cover_image   = cover_image,
        cover_url     = cover_url,
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
        item.chapter_urls, item.cover_image, item.cover_url)
end

function M:_onDownloadComplete()
    self._download_active = false
    if self._download_queue and #self._download_queue > 0 then
        UIManager:scheduleIn(1, function() self:_processDownloadQueue() end)
    end
end

function M:cachedExtractCover(fiction_id, epub_path)
    return extractEpubCover(epub_path)
end

function M:fetchPage(page_url)
    local delays = { 2, 5 }
    for attempt = 0, #delays do
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
        local code, _, status = socket.skip(1, http.request(request))
        socketutil:reset_timeout()

        if code == 200 then
            return table.concat(response_body)
        end

        logger.warn("Royal Road: HTTP", code, status, "attempt", attempt + 1)
        if attempt < #delays then
            socket.sleep(delays[attempt + 1])
        end
    end
    return nil
end

function M:fetchImage(image_url)
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

function M:extractTitle(html)
    local title = html:match('<h1[^>]*property="name"[^>]*>%s*(.-)%s*</h1>')
        or html:match('<h1[^>]*>%s*(.-)%s*</h1>')
    if title then
        title = title:gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&#39;", "'")
        title = title:gsub("<[^>]+>", "")
    end
    return title
end

function M:extractAuthor(html)
    local author = html:match('property="author"[^>]*>%s*<span[^>]*>%s*(.-)%s*</span>')
        or html:match('<meta%s+property="books:author"%s+content="([^"]+)"')
    if author then
        author = author:gsub("&quot;", '"'):gsub("&amp;", "&")
    end
    return author or "Unknown"
end

function M:extractChapterURLs(html, fiction_id)
    local chapters = {}
    local seen = {}

    local story_slug = html:match('/fiction/' .. fiction_id .. '/([^/"]+)') or "story"

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

function M:extractCoverURL(html)
    local cover_url = html:match('window%.fictionCover%s*=%s*"([^"]+)"')
    if not cover_url then
        cover_url = html:match('<meta%s+property="og:image"%s+content="([^"]+)"')
            or html:match('<meta%s+content="([^"]+)"%s+property="og:image"')
    end
    if not cover_url then
        cover_url = html:match('class="[^"]*cover[^"]*"[^>]*>%s*<img[^>]*src="([^"]+)"')
            or html:match('<img[^>]*src="(https://www%.royalroadcdn%.com/public/covers[^"]+)"')
    end
    return cover_url
end

function M:downloadChapters(fiction_id, story_title, author, chapter_urls, cover_image, cover_url)
    local total_chapters = #chapter_urls
    local chapters_data = {}
    local start_time = socket.gettime()

    self:keepScreenAwake()

    local screen_width = Device.screen:getWidth()
    local dialog_width = math.floor(screen_width * 0.8)

    local queue_size = self._download_queue and #self._download_queue or 0
    local title_text = queue_size > 0
        and T(_("Downloading… (%1 more queued)"), queue_size)
        or _("Downloading…")
    local title_widget = TextWidget:new{
        text = title_text,
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
        failed_chapters = 0,
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
                entry.partial_of = state.total_chapters
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
            if state.failed_chapters > 0 then
                UIManager:scheduleIn(0.5, function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("Warning: %1 chapter(s) failed to download and contain placeholder text."), state.failed_chapters),
                    })
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
                state.failed_chapters = state.failed_chapters + 1
                table.insert(state.chapters_data, {
                    title = "Chapter " .. i,
                    content = "<p>[Chapter content could not be extracted.]</p>",
                })
            end
        else
            logger.warn("Royal Road: Failed to fetch chapter", i, "from", chapter_url)
            state.failed_chapters = state.failed_chapters + 1
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

function M:extractChapterTitle(html)
    local title = html:match('<h1[^>]*>%s*(.-)%s*</h1>')
        or html:match('<h2[^>]*>%s*(.-)%s*</h2>')
    if title then
        title = title:gsub("&quot;", '"'):gsub("&amp;", "&"):gsub("&#39;", "'")
        title = title:gsub("<[^>]+>", "")
    end
    return title or "Chapter"
end

function M:extractChapterContent(html)
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

return M
