#!/bin/bash
# Install the launchd scheduler for daily podcast generation at 6:00 AM.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
PLIST_SRC="$PROJECT_DIR/com.podcastagent.plist"
PLIST_DEST="$HOME/Library/LaunchAgents/com.podcastagent.plist"

echo "Installing podcast scheduler..."
echo "  Project: $PROJECT_DIR"
echo "  Plist:   $PLIST_DEST"
echo "  Schedule: daily at 6:00 AM"
echo

# Unload existing if present
if launchctl list | grep -q com.podcastagent; then
  echo "Unloading existing scheduler..."
  launchctl unload "$PLIST_DEST" 2>/dev/null || true
fi

# Copy plist and replace placeholder with actual project path
sed "s|PODGEN_DIR|$PROJECT_DIR|g" "$PLIST_SRC" > "$PLIST_DEST"

# Load the scheduler
launchctl load "$PLIST_DEST"

echo "Scheduler installed and loaded."
echo "Verify with: launchctl list | grep podcastagent"
echo
echo "To uninstall:"
echo "  launchctl unload $PLIST_DEST"
echo "  rm $PLIST_DEST"
