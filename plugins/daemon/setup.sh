#!/bin/bash
set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$PLUGIN_DIR/.data}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

mkdir -p "$DATA_DIR"

# Install or update the watcher service when plugin version changes
EXPECTED=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_DIR/.claude-plugin/plugin.json" | sed 's/.*"\([^"]*\)"$/\1/')
CURRENT=$(cat "$DATA_DIR/.version" 2>/dev/null || true)

if [[ "$CURRENT" != "$EXPECTED" ]]; then
  # Write the marker BEFORE install.sh. On an update, install.sh runs
  # `systemctl --user restart`, which tears down the service cgroup this hook is
  # running in and SIGTERMs us mid-script. If the marker were written afterward it
  # would never advance, so every subsequent session would re-trigger the update →
  # restart → kill loop. Marking first makes the update idempotent: a restart that
  # kills us still leaves CURRENT == EXPECTED, so the next session is a no-op.
  echo "$EXPECTED" > "$DATA_DIR/.version"
  bash "$PLUGIN_DIR/install.sh" --quiet
fi

# Register this project with the watcher
PROJECTS_FILE="$DATA_DIR/projects"
touch "$PROJECTS_FILE"
if ! grep -qxF "$PROJECT_DIR" "$PROJECTS_FILE"; then
  echo "$PROJECT_DIR" >> "$PROJECTS_FILE"
fi
