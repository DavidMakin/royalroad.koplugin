local util   = require("util")
local logger = require("logger")

local C = require("royalroad/constants")

local M = {}

local function trim(s)
    return s:gsub("^%s+", ""):gsub("%s+$", "")
end

function M:extractTitle(html)
    local title = html:match('<h1[^>]*property="name"[^>]*>%s*(.-)%s*</h1>')
        or html:match('<h1[^>]*>%s*(.-)%s*</h1>')
    if title then
        title = util.htmlEntitiesToUtf8(title)
        title = title:gsub("<[^>]+>", "")
    end
    return title
end

function M:extractAuthor(html)
    local author = html:match('property="author"[^>]*>%s*<span[^>]*>%s*(.-)%s*</span>')
        or html:match('<meta%s+property="books:author"%s+content="([^"]+)"')
    if author then
        author = util.htmlEntitiesToUtf8(author)
    end
    return author or "Unknown"
end

function M:extractChapterURLs(html, fiction_id)
    local chapters = {}
    local seen = {}

    if html:find('window%.chapters%s*=') then
        -- Read each entry's own "url" field: field order and "volumeId":null
        -- (chapters outside any volume) must not decide what we pick up.
        for chapter_path in html:gmatch('"url":"(/fiction/' .. fiction_id .. '/[^"]+/chapter/%d+/[^"]+)"') do
            local full_url = C.BASE_URL .. chapter_path
            if not seen[full_url] then
                seen[full_url] = true
                table.insert(chapters, full_url)
            end
        end
    end

    if #chapters == 0 then
        for chapter_path in html:gmatch('href="(/fiction/' .. fiction_id .. '/[^/]+/chapter/%d+/[^"]+)"') do
            local full_url = C.BASE_URL .. chapter_path
            if not seen[full_url] then
                seen[full_url] = true
                table.insert(chapters, full_url)
            end
        end
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

function M:extractDescription(html)
    local desc = html:match('<div[^>]+class="[^"]*description[^"]*"[^>]*>(.-)</div>')
    if not desc then
        desc = html:match('<meta[^>]+property="description"[^>]+content="([^"]+)"')
            or html:match('<meta[^>]+content="([^"]+)"[^>]+property="description"')
    end
    if desc then
        desc = desc:gsub("<[^>]+>", "")
        desc = util.htmlEntitiesToUtf8(desc)
        desc = desc:gsub("^%s+", ""):gsub("%s+$", "")
        desc = desc:gsub("%s+", " ")
    end
    return desc
end

function M:extractRating(html)
    return html:match('"ratingValue"%s*:%s*"([%d%.]+)"')
        or html:match('property="v:rating"[^>]+content="([^"]+)"')
        or html:match('<span[^>]*class="[^"]*number[^"]*"[^>]*>([%d%.]+)</span>')
end

function M:extractStatus(html)
    for _, status in ipairs({ "Ongoing", "Completed", "Hiatus", "Stub" }) do
        if html:match('<span[^>]*class="[^"]*label[^"]*"[^>]*>%s*' .. status .. '%s*</span>') then
            return status
        end
    end
end

function M:extractWordCount(html)
    local wc = html:match('"wordCount"%s*:%s*(%d+)')
        or html:match('<span[^>]*title="Words"[^>]*>%s*([%d,]+)%s*</span>')
    if wc then
        wc = wc:gsub(",", "")
    end
    return wc
end

function M:extractLastChapterDate(html)
    local date
    for d in html:gmatch('<time[^>]+datetime="([^"]+)"') do
        date = d
    end
    return date
end

function M:extractChapterTitle(html)
    local title = html:match('<h1[^>]*>%s*(.-)%s*</h1>')
        or html:match('<h2[^>]*>%s*(.-)%s*</h2>')
    if title then
        title = util.htmlEntitiesToUtf8(title)
        title = title:gsub("<[^>]+>", "")
    end
    return title or "Chapter"
end

local function escapeLuaPattern(s)
    return (s:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1"))
end

-- Royal Road injects decoy paragraphs/spans into chapter content and hides
-- them with a per-page generated CSS class (e.g. ".a1b2c3{display:none;speak:never;}")
-- so that copy-pasted or scraped text carries an invisible watermark. Find
-- those generated class names by scanning <style> blocks for the display:none +
-- speak:never/none signature.
local function findHiddenClasses(html)
    local hidden = {}
    for style_body in html:gmatch("<style[^>]*>(.-)</style>") do
        local clean = style_body:gsub("%s+", "")
        for cls, body in clean:gmatch("%.([%w%-_]+)%{([^}]*)%}") do
            if body:find("display:none", 1, true)
                and (body:find("speak:never", 1, true) or body:find("speak:none", 1, true)) then
                hidden[cls] = true
            end
        end
    end
    return hidden
end

-- Removes elements matching the given hidden class names (whole-word match
-- within the class attribute) from a fragment of HTML, plus anything
-- explicitly hidden via an inline display:none style as a defensive extra.
local function stripHiddenElements(content, hidden_classes)
    if hidden_classes then
        for cls in pairs(hidden_classes) do
            local esc = escapeLuaPattern(cls)
            local pattern = '<(%a[%w]*)[^>]-%sclass%s*=%s*"[^"]-%f[%w]' .. esc .. '%f[%W][^"]*"[^>]*>.-</%1%s*>'
            content = content:gsub(pattern, "")
        end
    end
    content = content:gsub('<(%a[%w]*)[^>]-%sstyle%s*=%s*"[^"]-display%s*:%s*none[^"]*"[^>]*>.-</%1%s*>', "")
    return content
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
        local open_pos  = html:find('<div', pos, true)
        local close_pos = html:find('</div>', pos, true)
        if not close_pos then break end

        if open_pos and open_pos < close_pos then
            depth = depth + 1
            pos   = open_pos + 4
        else
            depth = depth - 1
            if depth == 0 then
                local content = html:sub(content_start, close_pos - 1)
                return stripHiddenElements(content, findHiddenClasses(html))
            end
            pos = close_pos + 6
        end
    end

    return nil
end

function M:parseSearchResults(html)
    local results = {}
    local seen = {}

    for block in html:gmatch('<div[^>]+class="[^"]*fiction%-list%-item[^"]*"[^>]*>(.-)</div>%s*</div>%s*</div>') do
        local fiction_id = block:match('/fiction/(%d+)/')
        if fiction_id and not seen[fiction_id] then
            seen[fiction_id] = true

            local title = block:match('<h2[^>]*>%s*(.-)%s*</h2>')
                or block:match('class="[^"]*fiction%-title[^"]*"[^>]*>%s*(.-)%s*<')
            if title then
                title = trim(title:gsub("<[^>]+>", ""))
                title = util.htmlEntitiesToUtf8(title)
            end

            local author = block:match('property="author"[^>]*>%s*(.-)%s*</')
                or block:match('class="[^"]*author[^"]*"[^>]*>%s*(.-)%s*<')
            if author then
                author = trim(author:gsub("<[^>]+>", ""))
            end

            local chapters_str = block:match('<span[^>]*title="Chapters"[^>]*>%s*(%d+[^<]*)</span>')
local chapters = chapters_str and tonumber(chapters_str:match("%d+"))
                or block:match('(%d+)%s*[Cc]hapters?')

            local rating = block:match('"ratingValue"%s*:%s*"([%d%.]+)"')
                or block:match('<span[^>]*class="[^"]*number[^"]*"[^>]*>([%d%.]+)</span>')

            local status = self:extractStatus(block)

            local wc_raw = block:match('"wordCount"%s*:%s*(%d+)')
                or block:match('<span[^>]*title="Words"[^>]*>%s*([%d,]+)%s*</span>')
            local word_count = wc_raw and wc_raw:gsub(",", "") or nil

            local tags = {}
            for tag_text in block:gmatch('<a[^>]+class="[^"]*tag[^"]*"[^>]*>(.-)</a>') do
                local t = trim(tag_text:gsub("<[^>]+>", ""))
                if t ~= "" then
                    table.insert(tags, t)
                    if #tags >= 3 then break end
                end
            end

            if title and title ~= "" then
                table.insert(results, {
                    fiction_id = fiction_id,
                    title      = title,
                    author     = author or "",
                    chapters   = chapters,
                    tags       = tags,
                    rating     = rating,
                    status     = status,
                    word_count = word_count,
                })
            end
        end
        if #results >= C.SEARCH.MAX_RESULTS then break end
    end

    if #results == 0 and #html > 1000 then
        logger.warn("Royal Road: parseSearchResults returned 0 results from non-empty HTML (site structure may have changed)")
    end
    return results
end

return M
