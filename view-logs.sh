#!/bin/bash
# View KOReader logs in real-time

KOREADER_DIR="$HOME/Library/Application Support/koreader"
LOG_FILE="$KOREADER_DIR/crash.log"

if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not found: $LOG_FILE"
    echo "KOReader may not have been run yet."
    exit 1
fi

echo "Showing KOReader logs (Ctrl+C to exit):"
echo "=========================================="
echo ""

# Show last 50 lines and follow, filtering for plugin logs
tail -n 50 -f "$LOG_FILE" | grep --line-buffered -E "(Royal Road|AO3)"
