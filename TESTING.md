# Testing the Plugin Locally on macOS

## Option 1: Download Pre-built KOReader (Recommended)

1. **Download KOReader for macOS:**
   - Visit [KOReader Releases](https://github.com/koreader/koreader/releases/)
   - Click on the latest release tag
   - Find the workflow runs (green checkmark)
   - Click "macOS" → "Details"
   - Download the artifact for your architecture:
     - `arm64` for Apple Silicon (M1/M2/M3)
     - `x86_64` for Intel Macs

2. **Extract and install:**
   ```bash
   unzip koreader-macos-*.zip
   mv koreader.app /Applications/
   ```

3. **First run (bypass Gatekeeper):**
   - Right-click koreader.app → Open
   - macOS 15.7+: Go to System Settings → Privacy & Security → approve

4. **Install the plugin:**
   ```bash
   KOREADER_CONFIG="$HOME/Library/Application Support/koreader"
   cp -r royalroad.koplugin "$KOREADER_CONFIG/plugins/"
   ```

5. **Run KOReader** and the plugin will appear in the Tools menu

## Option 2: Build from Source

### Prerequisites

Install dependencies via Homebrew:
```bash
brew install autoconf automake bash binutils cmake coreutils findutils \
             gettext gnu-getopt libtool make meson nasm ninja pkg-config \
             sdl2 util-linux
```

Add Homebrew's GNU tools to PATH:
```bash
export PATH="$(brew --prefix)/opt/findutils/libexec/gnubin:$(brew --prefix)/opt/gnu-getopt/bin:$(brew --prefix)/opt/make/libexec/gnubin:$(brew --prefix)/opt/util-linux/bin:${PATH}"
```

### Build Steps

1. **Clone KOReader:**
   ```bash
   cd ~/Projects
   git clone https://github.com/koreader/koreader.git
   cd koreader
   ```

2. **Fetch dependencies:**
   ```bash
   ./kodev fetch-thirdparty
   ```

3. **Build the emulator:**
   ```bash
   ./kodev build
   ```
   (This takes a while - 20-30 minutes on first build)

4. **Copy plugin to development build:**
   ```bash
   cp -r royalroad.koplugin ./plugins/
   ```

5. **Run the emulator:**
   ```bash
   ./kodev run
   ```

## Testing the Plugin

1. **Launch KOReader**

2. **Open a test document** (any EPUB or PDF to get into the reader)

3. **Access the menu:**
   - Tap the top of the screen or press Esc

4. **Navigate to:** Tools → Royal Road

5. **Test with short works first:**

### Test IDs
- `36234` - Blue Core (~15 chapters, short)
- `21220` - Mother of Learning (109 chapters, complete)
- `99999999` - Invalid ID (for error testing)

## Debugging

### Check Logs

KOReader logs are typically at:
```bash
# Pre-built app
~/Library/Application Support/koreader/crash.log

# Built from source
./koreader/crash.log
```

View plugin logs in real-time:
```bash
./view-logs.sh

# Or manually
tail -f ~/Library/Application\ Support/koreader/crash.log | grep "Royal Road"
```

### Common Issues

**Plugin doesn't appear:**
- Verify directory name ends in `.koplugin`
- Check plugin files exist: `_meta.lua` and `main.lua`
- Restart KOReader completely

**Lua errors:**
- Check crash.log for stack traces
- Verify Lua syntax (no syntax checking until runtime)

**HTTP errors:**
- Test network connectivity
- Try a different ID
- Check if Royal Road's HTML structure changed

### Quick Syntax Check

Before testing, you can check for basic Lua syntax errors:
```bash
brew install lua
luac -p royalroad.koplugin/main.lua
```

## Testing Workflow

1. Make code changes to `main.lua`
2. Copy to KOReader plugins directory (if using pre-built)
3. Restart KOReader
4. Test the functionality
5. Check logs for errors
6. Repeat
