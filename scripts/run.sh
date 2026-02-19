#!/bin/bash
# Wrapper script for launchd — resolves paths dynamically and runs the orchestrator.
# Usage: scripts/run.sh <podcast_name>

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

cd "$PROJECT_DIR" || exit 1

# Load rbenv/asdf/chruby if available
if [ -f "$HOME/.bash_profile" ]; then
  source "$HOME/.bash_profile"
elif [ -f "$HOME/.zshrc" ]; then
  source "$HOME/.zshrc"
fi

exec bundle exec ruby bin/podgen generate --quiet "$@"
