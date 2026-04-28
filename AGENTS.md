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

## Developer Documentation

Full documentation: https://koreader.rocks/doc/

### Key Modules for Plugin Development

| Module | Purpose |
|--------|---------|
| `koplugin.*` | Plugin base classes and examples (HelloWorld, wallabag, exporter) |
| `ui.widget.*` | UI widgets (Button, Dialog, InputDialog, InfoMessage, TextWidget, etc.) |
| `ui.widget.container.*` | Layout containers (WidgetContainer, CenterContainer, VerticalGroup, etc.) |
| `ui.uimanager` | Widget display and event management |
| `luasettings` | Settings persistence |
| `datastorage` | Directory paths for data/settings |
| `ffi.archiver` | ZIP/epub creation |
| `ffi.util` | File operations |
| `gettext` | Internationalization |
| `ui.trapper` | Progress dialogs and UI interaction for background jobs |
| `logger` | Logging |
| `util` | General utilities |
| `dispatcher` | Event dispatching |
| `ui.data.css_tweaks` | CSS customization |
| `socketutil` | HTTP request utilities |

### Important Topics

- [Development Guide](topics/Development_guide.md.html) - Getting started with KOReader development
- [Events](topics/Events.md.html) - Event system for plugin communication
- [Unit Tests](topics/Unit_tests.md.html) - Testing patterns
- [DataStore](topics/DataStore.md.html) - Data persistence
- [Hacking](topics/Hacking.md.html) - Advanced customization

### Plugin Examples in KOReader

Reference implementations for plugin patterns:
- `koplugin.HelloWorld` - Minimal plugin skeleton
- `koplugin.QRClipboard` - Simple plugin with QR functionality
- `koplugin.wallabag` - Plugin that fetches web content
- `koplugin.exporter` - Plugin for exporting data (similar to EPUB export)

## Dependencies

All dependencies provided by KOReader:
- `socket.http`, `ltn12` - HTTP requests
- `archiver` - EPUB creation
- `ui/widget/*` - UI components
- `luasettings` - Settings persistence
- `datastorage`, `ffi/util` - File operations
- `gettext` - Internationalization

## Cross-Platform Compatibility (MANDATORY)

This plugin must work on **all devices KOReader supports**: Kindle, Kobo, Android, Linux, macOS, and any other platform KOReader runs on.

- **Never write device-specific code** unless the feature is genuinely unavailable on other platforms (e.g. Android wake lock APIs).
- When accessing KOReader widget internals (fields like `page_return_arrow`, `return_button`, `page_info`, etc.), always guard with `if self.field then` — these may be absent or named differently across KOReader versions and platforms.
- Test logic paths mentally for both e-ink devices (Kindle/Kobo) and general-purpose OSes (Android/Linux).
- If a platform-specific branch is truly required, wrap it with the appropriate `Device:isKindle()`, `Device:isAndroid()`, etc. check and leave a comment explaining why no cross-platform alternative exists.
- Any bug that only reproduces on one platform is a bug — fix it portably, not with a platform guard.

## Use KOReader Built-ins First (MANDATORY)

Before writing any new helper function, utility, or feature, check whether KOReader already provides it.

- Search the KOReader source (`util`, `ffi/util`, `ui/widget/*`, `luasettings`, `datastorage`, `socketutil`, etc.) before rolling your own.
- KOReader's utility modules cover: string manipulation, file operations, HTTP, table helpers, time formatting, screen dimensions, path handling, and more.
- If KOReader provides it, use it. Do not duplicate it.
- If unsure whether something exists, check the [KOReader API docs](https://koreader.rocks/doc/) or grep the KOReader source before writing new code.

## Known Limitations

- No official APIs - relies on HTML scraping
- HTML structure changes will break parsers
- Paywalled/restricted content not supported
- No resume for interrupted downloads
