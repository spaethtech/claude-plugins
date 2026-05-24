#!/bin/bash
set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"
DAEMON_HOME="$HOME/.local/share/claude-daemon"

mkdir -p "$DAEMON_HOME"

# Install or update the watcher service when plugin version changes
EXPECTED=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_DIR/.claude-plugin/plugin.json" | sed 's/.*"\([^"]*\)"$/\1/')
CURRENT=$(cat "$DAEMON_HOME/.version" 2>/dev/null || true)

if [[ "$CURRENT" != "$EXPECTED" ]]; then
  bash "$PLUGIN_DIR/install.sh" --quiet
  echo "$EXPECTED" > "$DAEMON_HOME/.version"
fi

# Register this project with the watcher
PROJECTS_FILE="$DAEMON_HOME/projects"
touch "$PROJECTS_FILE"
if ! grep -qxF "$PROJECT_DIR" "$PROJECTS_FILE"; then
  echo "$PROJECT_DIR" >> "$PROJECTS_FILE"
fi
