#!/bin/bash
set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$PLUGIN_DIR/.data}"

EXPECTED=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_DIR/.claude-plugin/plugin.json" | sed 's/.*"\([^"]*\)"$/\1/')
CURRENT=$(cat "$DATA_DIR/.version" 2>/dev/null || true)

if [[ "$CURRENT" == "$EXPECTED" ]]; then
  exit 0
fi

bash "$PLUGIN_DIR/install.sh" --quiet

mkdir -p "$DATA_DIR"
echo "$EXPECTED" > "$DATA_DIR/.version"
