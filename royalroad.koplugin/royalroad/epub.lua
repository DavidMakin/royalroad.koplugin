local InfoMessage = require("ui/widget/infomessage")
local UIManager   = require("ui/uimanager")
local lfs         = require("libs/libkoreader-lfs")
local logger      = require("logger")
local T           = require("ffi/util").template
local util        = require("util")
local _           = require("gettext")

local M = {}

local _plugin_dir = debug.getinfo(1, "S").source:match("^@(.+)/[^/]+$") or "."

local CSS_BEFORE  = util.readFromFile(_plugin_dir .. "/ReadiumCSS-before.css")  or ""
local CSS_DEFAULT = util.readFromFile(_plugin_dir .. "/ReadiumCSS-default.css") or ""
local CSS_AFTER   = util.readFromFile(_plugin_dir .. "/ReadiumCSS-after.css")   or ""

function M:ensureDownloadDir()
    local ok, err = util.makePath(self.download_dir)
    if not ok and err then
        logger.warn("Royal Road: Could not create download dir:", err)
    end
end

function M:saveAsHTML(fiction_id, story_title, author, chapters)
    self:ensureDownloadDir()

    local html_parts = {
        '<!DOCTYPE html>',
        '<html>',
        '<head>',
        '<meta charset="utf-8"/>',
        '<title>' .. self:escapeXML(story_title) .. '</title>',
        '</head>',
        '<body>',
        '<h1>' .. self:escapeXML(story_title) .. '</h1>',
        '<p><em>By ' .. self:escapeXML(author) .. '</em></p>',
        '<hr/>',
    }

    for _, chapter in ipairs(chapters) do
        table.insert(html_parts, '<div>')
        table.insert(html_parts, '<h2>' .. self:escapeXML(chapter.title) .. '</h2>')
        table.insert(html_parts, chapter.content)
        table.insert(html_parts, '</div><hr/>')
    end

    table.insert(html_parts, '</body></html>')

    local full_html = table.concat(html_parts, "\n")
    local safe_title = util.getSafeFilename(story_title)
    local filename = string.format("%s/%s_%s.html", self.download_dir, safe_title, fiction_id)

    local file = io.open(filename, "w")
    if file then
        file:write(full_html)
        file:close()
        UIManager:show(InfoMessage:new{
            text = T(_("Saved HTML:\n%1\n\n%2 chapters"), filename, #chapters),
            timeout = 10,
        })
        logger.info("Royal Road: Saved", filename)
    else
        logger.err("Royal Road: Failed to write HTML file:", filename)
        UIManager:show(InfoMessage:new{
            text = T(_("Failed to write file:\n%1"), filename),
        })
    end
end

function M:getImageDimensions(data, mime_type)
    if not data or #data < 24 then return nil, nil end
    if mime_type == "image/png" then
        -- PNG: width at bytes 17-20, height at 21-24 (1-indexed), big-endian uint32
        local w = data:byte(17) * 16777216 + data:byte(18) * 65536 + data:byte(19) * 256 + data:byte(20)
        local h = data:byte(21) * 16777216 + data:byte(22) * 65536 + data:byte(23) * 256 + data:byte(24)
        return w, h
    elseif mime_type == "image/jpeg" then
        -- JPEG: scan for SOF markers (0xFF 0xC0/0xC1/0xC2)
        local i = 1
        while i <= #data - 8 do
            if data:byte(i) == 0xFF then
                local marker = data:byte(i + 1)
                if marker == 0xC0 or marker == 0xC1 or marker == 0xC2 then
                    local h = data:byte(i + 5) * 256 + data:byte(i + 6)
                    local w = data:byte(i + 7) * 256 + data:byte(i + 8)
                    return w, h
                elseif marker ~= 0xFF then
                    local seg_len = data:byte(i + 2) * 256 + data:byte(i + 3)
                    i = i + 2 + seg_len
                else
                    i = i + 1
                end
            else
                i = i + 1
            end
        end
    end
    return nil, nil
end

function M:escapeXML(text)
    if not text then return "" end
    return util.htmlEscape(text)
end

function M:extractChaptersFromEPUB(epub_path)
    local Archiver = require("ffi/archiver")

    local arc = Archiver.Reader:new()
    if not arc:open(epub_path) then
        logger.warn("Royal Road: Failed to open EPUB for reading:", epub_path)
        return nil, "Failed to open EPUB"
    end

    local chapter_files = {}
    local file_contents = {}

    logger.info("Royal Road: Reading EPUB contents...")
    for entry in arc:iterate() do
        if entry.mode == "file" then
            local path = entry.path
            logger.dbg("Royal Road: EPUB entry:", path)
            if path:match("content%.opf$") then
                file_contents["content.opf"] = arc:extractToMemory(path)
                logger.info("Royal Road: Found content.opf")
            elseif path:match("chapter_%d+%.xhtml$") then
                file_contents[path] = arc:extractToMemory(path)
                logger.info("Royal Road: Found chapter file:", path)
            end
        end
    end
    arc:close()

    local opf_content = file_contents["content.opf"]
    if not opf_content then
        logger.warn("Royal Road: No content.opf found in EPUB")
        return nil, "No content.opf found"
    end

    local id_to_href = {}
    for id, href in opf_content:gmatch('<item[^>]+id="([^"]+)"[^>]+href="([^"]+)"') do
        id_to_href[id] = href
    end
    for href, id in opf_content:gmatch('<item[^>]+href="([^"]+)"[^>]+id="([^"]+)"') do
        id_to_href[id] = href
    end

    for idref in opf_content:gmatch('<itemref[^>]+idref="([^"]+)"') do
        local href = id_to_href[idref]
        if href and href:match("chapter_") then
            local full_path = href
            table.insert(chapter_files, full_path)
            logger.dbg("Royal Road: Spine chapter:", idref, "->", full_path)
        end
    end

    logger.info("Royal Road: Found", #chapter_files, "chapters in spine, have", #file_contents, "files loaded")

    local chapters = {}
    for i, filepath in ipairs(chapter_files) do
        local content = file_contents[filepath]
        if content then
            local title = content:match("<title>([^<]+)</title>")
                       or content:match("<h2>([^<]+)</h2>")
                       or "Untitled Chapter"

            local chapter_content = content:match('<div class="chapter">.-</h2>(.+)</div>%s*</body>')
            if not chapter_content then
                chapter_content = content:match("<body>(.+)</body>")
            end
            if not chapter_content then
                logger.warn("Royal Road: Could not extract content from chapter file:", filepath)
            end

            table.insert(chapters, {
                title = title,
                content = chapter_content or "",
            })
        else
            logger.warn("Royal Road: Missing chapter file:", filepath)
        end
    end

    logger.info("Royal Road: Extracted", #chapters, "chapters from EPUB")
    return chapters
end

-- Builds manifest/spine/nav structures for OPF, NCX and nav.xhtml.
-- Returns: manifest_items, spine_items, nav_points, nav_entries, nav_landmarks, first_chapter_file
function M:_buildTocStructures(fiction_id, escaped_title, chapters, cover_image)
    local manifest_items = {}
    local spine_items    = {}
    local nav_points     = {}
    local nav_entries    = {}
    local nav_landmarks  = {}
    local play_order     = 1

    local has_cover = cover_image and cover_image.data
    if has_cover then
        local cover_filename = "cover." .. cover_image.extension
        table.insert(manifest_items, string.format(
            '    <item id="cover" href="%s" media-type="%s" properties="cover-image"/>',
            cover_filename, cover_image.mime_type))
        table.insert(manifest_items,
            '    <item id="titlepage" href="cover.xhtml" media-type="application/xhtml+xml"/>')
        table.insert(spine_items, '    <itemref idref="titlepage"/>')
        table.insert(nav_points, string.format([[    <navPoint id="navpoint-%d" playOrder="%d">
      <navLabel><text>Cover</text></navLabel>
      <content src="cover.xhtml"/>
    </navPoint>]], play_order, play_order))
        table.insert(nav_entries,   '      <li><a href="cover.xhtml">Cover</a></li>')
        table.insert(nav_landmarks, '      <li><a epub:type="cover" href="cover.xhtml">Cover</a></li>')
        play_order = play_order + 1
    end

    table.insert(manifest_items,
        '    <item id="title-page" href="title.xhtml" media-type="application/xhtml+xml"/>')
    table.insert(spine_items, '    <itemref idref="title-page"/>')
    table.insert(nav_points, string.format([[    <navPoint id="navpoint-%d" playOrder="%d">
      <navLabel><text>Title Page</text></navLabel>
      <content src="title.xhtml"/>
    </navPoint>]], play_order, play_order))
    table.insert(nav_entries,   '      <li><a href="title.xhtml">Title Page</a></li>')
    table.insert(nav_landmarks, '      <li><a epub:type="frontmatter" href="title.xhtml">Title Page</a></li>')
    play_order = play_order + 1

    local first_chapter_file = nil
    for i, chapter in ipairs(chapters) do
        local chapter_id   = string.format("chapter-%03d", i)
        local chapter_file = string.format("chapter_%03d.xhtml", i)
        table.insert(manifest_items, string.format(
            '    <item id="%s" href="%s" media-type="application/xhtml+xml"/>',
            chapter_id, chapter_file))
        table.insert(spine_items, string.format('    <itemref idref="%s"/>', chapter_id))

        local esc_ch = self:escapeXML(chapter.title)
        table.insert(nav_points, string.format([[    <navPoint id="navpoint-%d" playOrder="%d">
      <navLabel><text>%s</text></navLabel>
      <content src="%s"/>
    </navPoint>]], play_order, play_order, esc_ch, chapter_file))
        table.insert(nav_entries, string.format(
            '      <li><a href="%s">%s</a></li>', chapter_file, esc_ch))
        if i == 1 then first_chapter_file = chapter_file end
        play_order = play_order + 1
    end

    if first_chapter_file then
        table.insert(nav_landmarks, string.format(
            '      <li><a epub:type="bodymatter" href="%s">Begin Reading</a></li>',
            first_chapter_file))
    end

    table.insert(manifest_items, '    <item id="ncx" href="toc.ncx" media-type="application/x-dtbncx+xml"/>')
    table.insert(manifest_items, '    <item id="nav" href="nav.xhtml" media-type="application/xhtml+xml" properties="nav"/>')
    table.insert(manifest_items, '    <item id="css-before" href="ReadiumCSS-before.css" media-type="text/css"/>')
    table.insert(manifest_items, '    <item id="css-default" href="ReadiumCSS-default.css" media-type="text/css"/>')
    table.insert(manifest_items, '    <item id="css-after" href="ReadiumCSS-after.css" media-type="text/css"/>')

    return manifest_items, spine_items, nav_points, nav_entries, nav_landmarks
end

function M:_buildOPF(fiction_id, book_id, escaped_title, escaped_author, cover_image,
                     manifest_items, spine_items)
    local has_cover    = cover_image and cover_image.data
    local cover_meta   = has_cover and '    <meta name="cover" content="cover"/>\n' or ""
    local cover_guide  = has_cover
        and '\n  <guide>\n    <reference href="title.xhtml" title="Cover" type="cover"/>\n  </guide>'
        or ""
    local modified_date = os.date("!%Y-%m-%dT%H:%M:%SZ")

    return string.format([[<?xml version="1.0" encoding="UTF-8"?>
<package xmlns="http://www.idpf.org/2007/opf" unique-identifier="bookid" version="3.0">
  <metadata xmlns:dc="http://purl.org/dc/elements/1.1/">
    <dc:title>%s</dc:title>
    <dc:creator id="creator">%s</dc:creator>
    <meta refines="#creator" property="role" scheme="marc:relators">aut</meta>
    <dc:identifier id="bookid">%s</dc:identifier>
    <dc:language>en</dc:language>
    <dc:source>https://www.royalroad.com/fiction/%s</dc:source>
    <meta property="dcterms:modified">%s</meta>
%s  </metadata>
  <manifest>
%s
  </manifest>
  <spine toc="ncx">
%s
  </spine>%s
</package>]],
        escaped_title, escaped_author, book_id, fiction_id, modified_date, cover_meta,
        table.concat(manifest_items, "\n"), table.concat(spine_items, "\n"), cover_guide)
end

function M:_buildNCX(book_id, escaped_title, escaped_author, nav_points)
    return string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE ncx PUBLIC "-//NISO//DTD ncx 2005-1//EN" "http://www.daisy.org/z3986/2005/ncx-2005-1.dtd">
<ncx xmlns="http://www.daisy.org/z3986/2005/ncx/" version="2005-1">
  <head>
    <meta name="dtb:uid" content="%s"/>
    <meta name="dtb:depth" content="1"/>
    <meta name="dtb:totalPageCount" content="0"/>
    <meta name="dtb:maxPageNumber" content="0"/>
  </head>
  <docTitle><text>%s</text></docTitle>
  <docAuthor><text>%s</text></docAuthor>
  <navMap>
%s
  </navMap>
</ncx>]], book_id, escaped_title, escaped_author, table.concat(nav_points, "\n"))
end

function M:_buildNav(escaped_title, nav_entries, nav_landmarks)
    return string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops"
      xml:lang="en" lang="en">
<head>
  <title>%s</title>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-before.css"/>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-default.css"/>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-after.css"/>
</head>
<body>
  <nav epub:type="toc" id="toc">
    <h1>Contents</h1>
    <ol>
%s
    </ol>
  </nav>
  <nav epub:type="landmarks" id="landmarks" hidden="">
    <ol>
%s
    </ol>
  </nav>
</body>
</html>]], escaped_title, table.concat(nav_entries, "\n"), table.concat(nav_landmarks, "\n"))
end

function M:_addChapters(epub, chapters)
    for i, chapter in ipairs(chapters) do
        local esc_ch        = self:escapeXML(chapter.title)
        local chapter_content = (chapter.content or ""):gsub("<br>", "<br/>")
        local chapter_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en">
<head>
  <title>%s</title>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-before.css"/>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-default.css"/>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-after.css"/>
</head>
<body>
  <div class="chapter">
    <h2>%s</h2>
    %s
  </div>
</body>
</html>]], esc_ch, esc_ch, chapter_content)
        epub:addFileFromMemory(string.format("chapter_%03d.xhtml", i), chapter_xhtml)
    end
end

function M:saveAsEPUB(fiction_id, story_title, author, chapters, cover_image, chapter_urls, cover_url)
    self:ensureDownloadDir()

    local safe_title = util.getSafeFilename(story_title)
    local filename = string.format("%s/%s_%s.epub", self.download_dir, safe_title, fiction_id)

    local ok, result = pcall(function()
        local Archiver = require("ffi/archiver")
        local epub = Archiver.Writer:new{}
        if not epub:open(filename, "epub") then
            error("Failed to create EPUB file")
        end

        local book_id        = "royalroad-" .. fiction_id
        local escaped_title  = self:escapeXML(story_title)
        local escaped_author = self:escapeXML(author)
        local has_cover      = cover_image and cover_image.data

        epub:addFileFromMemory("mimetype", "application/epub+zip")

        local container_xml = [[<?xml version="1.0" encoding="UTF-8"?>
<container version="1.0" xmlns="urn:oasis:names:tc:opendocument:xmlns:container">
  <rootfiles>
    <rootfile full-path="content.opf" media-type="application/oebps-package+xml"/>
  </rootfiles>
</container>]]
        epub:addFileFromMemory("META-INF/container.xml", container_xml)

        local manifest_items, spine_items, nav_points, nav_entries, nav_landmarks =
            self:_buildTocStructures(fiction_id, escaped_title, chapters, cover_image)

        epub:addFileFromMemory("content.opf",
            self:_buildOPF(fiction_id, book_id, escaped_title, escaped_author,
                           cover_image, manifest_items, spine_items))
        epub:addFileFromMemory("toc.ncx",
            self:_buildNCX(book_id, escaped_title, escaped_author, nav_points))
        epub:addFileFromMemory("nav.xhtml",
            self:_buildNav(escaped_title, nav_entries, nav_landmarks))

        epub:addFileFromMemory("ReadiumCSS-before.css", CSS_BEFORE)
        epub:addFileFromMemory("ReadiumCSS-default.css", CSS_DEFAULT)
        epub:addFileFromMemory("ReadiumCSS-after.css", CSS_AFTER)

        if has_cover then
            local img_w, img_h = self:getImageDimensions(cover_image.data, cover_image.mime_type)
            img_w = img_w or 400
            img_h = img_h or 600
            local cover_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8" standalone="no" ?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
  <title>Cover</title>
</head>
<body>
  <div style="height: 100vh; text-align: center; padding: 0pt; margin: 0pt;">
    <svg xmlns="http://www.w3.org/2000/svg" height="100%%" preserveAspectRatio="xMidYMid meet" version="1.1" viewBox="0 0 %d %d" width="100%%" xmlns:xlink="http://www.w3.org/1999/xlink">
      <image width="%d" height="%d" xlink:href="cover.%s"/>
    </svg>
  </div>
</body>
</html>]], img_w, img_h, img_w, img_h, cover_image.extension)
            epub:addFileFromMemory("cover.xhtml", cover_xhtml)
            epub:addFileFromMemory("cover." .. cover_image.extension, cover_image.data)
        end

        local title_xhtml = string.format([[<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE html>
<html xmlns="http://www.w3.org/1999/xhtml" xml:lang="en" lang="en" xmlns:epub="http://www.idpf.org/2007/ops">
<head>
  <title>%s</title>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-before.css"/>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-default.css"/>
  <link rel="stylesheet" type="text/css" href="ReadiumCSS-after.css"/>
</head>
<body>
    <div id="title-page" class="element" epub:type="titlepage">
        <div class="title-page-title-subtitle-block">
        <h1 class="title-page-title">%s</h1>
        </div>
    </div>
  <p><em>By %s</em></p>
  <p></p>
  <p></p>
  <p><small>Downloaded from Royal Road</small></p>
  <p><small><a href="https://www.royalroad.com/fiction/%s">https://www.royalroad.com/fiction/%s</a></small></p>
</body>
</html>]], escaped_title, escaped_title, escaped_author, fiction_id, fiction_id)
        epub:addFileFromMemory("title.xhtml", title_xhtml)

        self:_addChapters(epub, chapters)

        epub:close()
        return true
    end)

    if ok and result then
        self.downloaded_stories[fiction_id] = {
            fiction_id = fiction_id,
            title = story_title,
            author = author,
            chapter_urls = chapter_urls or {},
            epub_path = filename,
            cover_url = cover_url,
            download_date = os.time(),
            last_update = os.time(),
        }
        self:_invalidateStoryCount()
        self:saveSettings()
        logger.info("Royal Road: Saved metadata for story", fiction_id, "with", #(chapter_urls or {}), "chapters")

        UIManager:show(InfoMessage:new{
            text = T(_("Saved EPUB:\n%1\n\n%2 chapters"), filename, #chapters),
            timeout = 10,
        })
        logger.info("Royal Road: Saved EPUB", filename)
    else
        local error_msg = tostring(result)
        logger.warn("Royal Road: EPUB creation failed, falling back to HTML:", error_msg)
        UIManager:show(InfoMessage:new{
            text = T(_("EPUB creation failed:\n%1\n\nSaving as HTML instead..."), error_msg),
            timeout = 5,
        })
        self:saveAsHTML(fiction_id, story_title, author, chapters)
    end
end

return M
