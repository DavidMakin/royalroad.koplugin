# AGENTS.md

This file provides guidance to AI coding agents when working with code in this repository.

## Project Overview

KOReader plugin for downloading web fiction as EPUB files:
- **Royal Road** - Downloads stories from royalroad.com

## Project Structure

```
royalroad.koplugin/
├── _meta.lua          # Plugin metadata
├── main.lua           # Main implementation (loads modules below)
├── test_repair.lua    # Standalone unit tests: lua test_repair.lua
└── royalroad/
    ├── constants.lua      # URLs, timeouts, rate limits
    ├── http.lua           # fetchPage / fetchImage with retry + backoff
    ├── parser.lua         # HTML/JSON parsing (story, chapters, content)
    ├── urls.lua           # Chapter identity keying (fiction_id:chapter_id)
    ├── downloader.lua     # Download orchestration
    ├── epub.lua           # EPUB read/write (saveAsEPUB, extractChaptersFromEPUB)
    ├── repair.lua         # EPUB repair (dedupe + drop deleted chapters)
    ├── updater.lua        # Update detection + UI
    ├── story_detail.lua   # Story options dialog
    └── widgets.lua        # Shared widget helpers
```

## Git & Commits (MANDATORY)

**Commits to this repo are ALWAYS made by the user under the identity DavidMakin.**

- Never run `git commit` yourself. Stage files and hand over the exact commit command to the user.
- The user sometimes works from a work PC that switches git to a work admin identity — always verify the configured identity (`git config user.name` / `user.email`) before committing on their behalf, and never commit under the work identity.
- Always attribute the bug reporter when committing a fix for an issue: add a `Co-authored-by:` trailer with their GitHub identity.


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

### Chapter Identity & EPUB Repair

- Royal Road chapter URLs embed a stable site-wide id: `/fiction/{fiction_id}/{slug}/chapter/{chapter_id}/{chapter_slug}`. The `{slug}` changes when an author renames/reorganises their fiction; `chapter_id` never does.
- **Never compare full URLs for identity.** Use `urls.chapterKey()` (`royalroad/urls.lua`) which returns `fiction_id:chapter_id` and falls back to the raw URL for legacy formats. This is what prevents renamed chapters from being re-downloaded as "new" (duplicating the EPUB).
- Royal Road serves chapter lists in `window.chapters` JSON but **always truncated** (verified: a 261-chapter story serves ~184 entries). A single HTML fetch is never a complete chapter list. Anything that decides to *drop* chapters based on the live list must guard: treat the live list as authoritative only when `#current >= #deduped_stored`.
- `repairStoryDuplicates(fiction_id)` (in `repair.lua`) rebuilds a corrupted EPUB: pairs EPUB chapters with `story.chapter_urls` by index, dedupes by identity key (last occurrence wins), and — only when the live list is provably complete — drops chapters deleted from the site. Preserves cover and reading position.

### Story Exclusion (skip in "Update all")

- A story is excluded when its settings carry `story.excluded == true`; the field persists with all other story settings (any full-field settings save round-trip preserves it, no per-field copy needed).
- Excluded stories are **skipped by "Update all"** (`performUpdateCheck` in `updater.lua` filters them out of `targets`, counts them, and reports "Skipped N excluded stories" when the rest are up to date; exits early with an info message when every story is excluded). Individual updates (`checkSingleStoryForUpdates`, the per-story "Check for updates" button) are **not** filtered — exclusion only affects the batch path.
- Toggle points: story options dialog (`story_detail.lua`, button after the download actions) and the hold menu in the downloads list (`downloads_ui.lua`). Both clear `story.unread_new_count` on exclude so stale "+N new" badges don't persist.
- Visual indicators (plugin's own story list UI only — KOReader's library renders covers via `FileManagerBookInfo` and is untouched): a dark ⊘ badge overlaid on the cover's top-right corner (via `OverlapGroup` child with `overlap_align = "right"` in `widgets.lua`, both `StoryListItem` and `StoryCoverCell`), a grayed-out title, and a `[excluded]` suffix in the downloads list and batch-select list.
- KOReader `OverlapGroup` positions children via `overlap_align` (`"left"/"center"/"right"`), never via an `align` field; vertical offset is always top. Mirrored (RTL) UIs flip `"right"` to `"left"` automatically — do not compensate manually.

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

## Shell Scripts (MANDATORY)

All shell scripts (`.sh` files and inline shell in CI workflows) must pass `shellcheck` with no errors or warnings, including SC2250 (always use `${VAR}` braces around variable references). Run `shellcheck <file>` before committing any shell script.

## Known Limitations

- No official APIs - relies on HTML scraping
- HTML structure changes will break parsers
- Paywalled/restricted content not supported
- Royal Road's `window.chapters` JSON is truncated server-side, so downloads may miss late chapters if a story page changes mid-download
- EPUB repair (dedupe) is offline-safe; dropping site-deleted chapters requires a provably complete live chapter list, which the site rarely serves — when the list is incomplete the repair keeps all chapters
