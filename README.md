# Royal Road Downloader - KOReader Plugin

KOReader plugin for downloading web fiction from [Royal Road](https://www.royalroad.com/) as EPUB files for offline reading.

## Features

- Download complete stories as EPUB files
- Simple input: just enter the fiction ID
- Configurable download directory
- Rate limiting to respect server limits
- Real-time progress tracking with elapsed time and ETA
- Detailed logging for debugging
- Automatic EPUB generation with proper metadata

## Installation

1. Copy the `royalroad.koplugin` directory to your KOReader plugins folder:
   - **Kobo/Kindle**: `/mnt/onboard/.adds/koreader/plugins/`
   - **Android**: `/sdcard/koreader/plugins/`
   - **macOS**: `~/Library/Application Support/koreader/plugins/`
   - **Linux**: `~/.config/koreader/plugins/`

2. Restart KOReader

3. The plugin will appear in your tools menu

### Quick Install (macOS)

```bash
./install-plugin.sh
```

## Usage

1. Find a story on Royal Road (e.g., `https://www.royalroad.com/fiction/21220/mother-of-learning`)
2. Note the fiction ID from the URL (in this example: `21220`)
3. In KOReader: **Tools → Royal Road → Download story**
4. Enter the fiction ID and tap Download
5. The EPUB will be saved to `{KOReader}/royalroad/StoryTitle_ID.epub`

## Configuration

Access settings via **Menu → Tools → Royal Road → Settings**:

- **Download directory**: Where to save EPUB files
- **Rate limit delay**: Seconds between chapter downloads (default: 1.5s)

## Finding the Fiction ID

The ID is the number in the URL:

`https://www.royalroad.com/fiction/21220/mother-of-learning` → ID is `21220`

## Limitations

- No official API - uses HTML scraping (may break if the site changes)
- Cannot download paywalled/advanced chapters
- Large stories may take a while to download
- No resume functionality - interrupted downloads must restart

## Development

See `TESTING.md` for local testing instructions.

## License

This is an unofficial plugin and is not affiliated with Royal Road or KOReader.
Use responsibly and respect Royal Road's terms of service.
