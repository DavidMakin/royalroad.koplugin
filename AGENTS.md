# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

KOReader plugin for downloading web fiction as EPUB files:
- **Royal Road** - Downloads stories from royalroad.com

## Project Structure

```
royalroad.koplugin/
├── _meta.lua          # Plugin metadata
└── main.lua           # Main implementation
```

## Development Commands

These are Lua-based KOReader plugins. No build commands - plugins run directly in KOReader.

### Testing

1. Copy plugin directories to KOReader's plugin directory:
   - On Kobo/Kindle: `/mnt/onboard/.adds/koreader/plugins/`
   - On Android: `/sdcard/koreader/plugins/`
   - On macOS: `~/Library/Application Support/koreader/plugins/`

2. Restart KOReader

3. Access via: Menu → Tools → [Plugin Name]

See `TESTING.md` for detailed testing instructions.

## Architecture

### Plugin System

KOReader plugins follow a specific structure:
- Directory name must end in `.koplugin`
- `_meta.lua` defines plugin metadata
- `main.lua` contains the main implementation extending `WidgetContainer`

### Key Components

- Extends `WidgetContainer` base class
- Integrates with KOReader's menu system via `addToMainMenu()`
- Uses KOReader UI components: `InputDialog`, `InfoMessage`
- Handles settings persistence via `LuaSettings`

### HTTP Fetching
- Uses Lua's `socket.http` library
- Rate limiting: 1.5s between requests

### HTML Parsing
- Uses Lua pattern matching to extract content
- Site-specific selectors for title, author, chapters, content

### EPUB Generation
- Uses KOReader's `Archiver` module
- Combines chapters into single EPUB with metadata

## HTML Structure

### Royal Road
- Title: `<h1>` with `property="name"`
- Author: `span[property="author"]`
- Chapter content: `div.chapter-content`
- Chapter URLs: `/fiction/{ID}/chapter/{CHAPTER_ID}`

## File Locations

- Downloaded EPUBs: `{KOReader data dir}/royalroad/`
- Settings: `{KOReader settings dir}/royalroad.lua`
- Logs: KOReader's standard log output (crash.log)

## Dependencies

All dependencies provided by KOReader:
- `socket.http`, `ltn12` - HTTP requests
- `archiver` - EPUB creation
- `ui/widget/*` - UI components
- `luasettings` - Settings persistence
- `datastorage`, `ffi/util` - File operations
- `gettext` - Internationalization

## Known Limitations

- No official APIs - relies on HTML scraping
- HTML structure changes will break parsers
- Paywalled/restricted content not supported
- No resume for interrupted downloads
