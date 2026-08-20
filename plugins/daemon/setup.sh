#!/bin/bash
set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$PLUGIN_DIR/.data}"
PROJECT_DIR="${CLAUDE_PROJECT_DIR:-$(pwd)}"

# daemon.json presence is the opt-in gate. Without it, this is a normal (non-daemon) Claude
# session: don't install the watcher service and don't register the project. This runs on EVERY
# SessionStart, so a project only ever gets daemonized once it has a .claude/daemon.json — and the
# watcher service itself is only installed the first time a session starts in such a project.
if [[ ! -f "$PROJECT_DIR/.claude/daemon.json" ]]; then
  exit 0
fi

mkdir -p "$DATA_DIR"

# Install or update the watcher service when plugin version changes
EXPECTED=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_DIR/.claude-plugin/plugin.json" | sed 's/.*"\([^"]*\)"$/\1/')
CURRENT=$(cat "$DATA_DIR/.version" 2>/dev/null || true)

if [[ "$CURRENT" != "$EXPECTED" ]]; then
  # install.sh writes $DATA_DIR/.version itself — but only AFTER prereqs pass and the unit is enabled,
  # right before its `systemctl --user restart` (which tears down this hook's cgroup and SIGTERMs us).
  # So a genuine prereq failure exits install.sh *before* the marker advances → we retry next session;
  # a success writes the marker *before* the restart can kill us → no update loop. This distinguishes
  # "install failed" from "killed by our own restart" without latching failures (the old write-first did
  # not, so a single prereq failure silently disabled the daemon forever).
  install_rc=0
  bash "$PLUGIN_DIR/install.sh" --quiet || install_rc=$?
  # 143 (SIGTERM) / 130 (SIGINT): killed by our own restart AFTER a successful install (marker already
  # written) — not a failure. Anything else genuinely failed: leave a breadcrumb, since hook stderr is
  # easily swallowed and CURRENT stays un-advanced so it'll retry.
  if (( install_rc == 0 || install_rc == 143 || install_rc == 130 )); then
    rm -f "$DATA_DIR/.install-error" 2>/dev/null || true
  else
    echo "claude-daemon install failed (exit $install_rc) on $(date). See what's wrong with: bash \"$PLUGIN_DIR/install.sh\"" \
      > "$DATA_DIR/.install-error" 2>/dev/null || true
  fi
fi

# Register this project with the watcher
PROJECTS_FILE="$DATA_DIR/projects"
touch "$PROJECTS_FILE"
if ! grep -qxF "$PROJECT_DIR" "$PROJECTS_FILE"; then
  echo "$PROJECT_DIR" >> "$PROJECTS_FILE"
fi
