#!/bin/bash
# Helper script to install/update the plugin in KOReader (macOS)

KOREADER_DIR="$HOME/Library/Application Support/koreader"
PLUGIN_DIR="$KOREADER_DIR/plugins"

echo "Installing Royal Road plugin to KOReader..."

# Create plugins directory if it doesn't exist
mkdir -p "$PLUGIN_DIR"

# Copy plugin
cp -rv royalroad.koplugin "$PLUGIN_DIR/"

echo ""
echo "Plugin installed successfully!"
echo ""
echo "Location: $PLUGIN_DIR/"
echo ""
echo "To view logs in real-time:"
echo "  tail -f \"$KOREADER_DIR/crash.log\""
echo ""
echo "Restart KOReader to load the updated plugin."
