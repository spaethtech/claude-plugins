#!/bin/bash
set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
DATA_DIR="${CLAUDE_PLUGIN_DATA:-$PLUGIN_DIR/.data}"
SERVICE_NAME="claude-daemon"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/${SERVICE_NAME}.service"

QUIET=false
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=true ;;
  esac
done

log() { $QUIET || echo "$@"; }
# Errors ALWAYS surface, even under --quiet. --quiet suppresses progress chatter, not diagnostics —
# otherwise a prereq failure during the SessionStart hook is completely silent (see the header note in
# setup.sh about the version-marker latch this pairs with).
err() { echo "$@" >&2; }

# Ensure a required command exists, installing it via the system package manager if missing. Package
# name is assumed to equal the command name (true for tmux and jq). Returns non-zero (caller exits) if
# it can't be made available — with a visible reason, since `sudo -n` may need a password.
ensure_cmd() {
  local cmd="$1" rc=0
  command -v "$cmd" &>/dev/null && return 0
  log "Installing $cmd..."
  if   command -v apt-get &>/dev/null; then sudo -n apt-get install -y -qq "$cmd" 2>/dev/null || rc=$?
  elif command -v dnf     &>/dev/null; then sudo -n dnf install -y -q "$cmd"     2>/dev/null || rc=$?
  elif command -v yum     &>/dev/null; then sudo -n yum install -y -q "$cmd"     2>/dev/null || rc=$?
  elif command -v pacman  &>/dev/null; then sudo -n pacman -S --noconfirm "$cmd" 2>/dev/null || rc=$?
  elif command -v brew    &>/dev/null; then brew install "$cmd"                  2>/dev/null || rc=$?
  else err "ERROR: $cmd is required but no supported package manager was found. Install it manually."; return 1
  fi
  if (( rc != 0 )) || ! command -v "$cmd" &>/dev/null; then
    err "ERROR: Failed to install $cmd (sudo -n may require a password). Install it manually, e.g.: sudo apt-get install $cmd"
    return 1
  fi
}

# The version this run marks complete once it succeeds. Written to $DATA_DIR/.version immediately before
# the restart at the end (which SIGTERMs this hook) — so a genuine failure, which exits earlier, never
# advances the marker and the next SessionStart retries. See setup.sh.
EXPECTED_VERSION=$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_DIR/.claude-plugin/plugin.json" | sed 's/.*"\([^"]*\)"$/\1/')

# Prerequisites. tmux hosts the sessions; jq parses every daemon.json in the watcher (service.sh) —
# without it the watcher silently ignores all per-project config and falls back to defaults.
ensure_cmd tmux || exit 1
ensure_cmd jq   || exit 1
if ! command -v claude &>/dev/null; then
  err "ERROR: claude is not on PATH (as seen by this installer). Note the systemd user service needs claude"
  err "       resolvable from the systemd user manager's PATH — a shell alias or a ~/.bashrc PATH export"
  err "       does not qualify; install claude to a real directory on PATH (e.g. the native ~/.local/bin)."
  exit 1
fi
# Capture claude's directory now, so it can be baked into the unit's PATH below. The systemd *user
# manager* PATH may not include ~/.local/bin (where a native install lands) on older systemd (< v256),
# so the service's bare `claude` calls would otherwise fail invisibly. Regenerated on every update.
CLAUDE_DIR="$(dirname "$(command -v claude)")"

mkdir -p "$SYSTEMD_USER_DIR" "$DATA_DIR"
chmod +x "$PLUGIN_DIR/service.sh"
[[ -f "$PLUGIN_DIR/shim/docker" ]] && chmod +x "$PLUGIN_DIR/shim/docker"

# Regenerate the service file (always, to pick up new paths on update)
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Claude Code Daemon Watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# The service manager's PATH may lack ~/.local/bin (native claude), so prepend claude's dir. Standard
# dirs cover the watcher's other tools (jq, tmux, systemctl, docker, sudo, loginctl).
Environment=PATH=${CLAUDE_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
Environment=DAEMON_PLUGIN_DIR=${PLUGIN_DIR}
Environment=DAEMON_DATA_DIR=${DATA_DIR}
ExecStart=${PLUGIN_DIR}/service.sh
Restart=always
RestartSec=10
TimeoutStopSec=30
# A normal `systemctl restart` SIGTERMs the watcher (exit 143); treat that as success so routine
# restarts don't plant a spurious 'Failed with result exit-code' red herring in the journal.
SuccessExitStatus=143

[Install]
WantedBy=default.target
EOF
log "Generated ${SERVICE_NAME}.service"

# Enable lingering (skip if already enabled or sudo unavailable)
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
  if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
    log "Enabled linger for $USER."
  else
    log "WARNING: Could not enable linger (sudo required). Service won't survive logout."
    log "  Run manually: sudo loginctl enable-linger $USER"
  fi
fi

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"

# Mark this version installed BEFORE the restart. Everything that can legitimately fail (prereqs, unit
# generation, daemon-reload, enable) has already run; the restart below tears down the cgroup this
# script and its SessionStart-hook parent run in and SIGTERMs us mid-line. Writing the marker here makes
# that self-kill idempotent (no update→restart→kill loop), while a genuine earlier failure never reaches
# this point — so the marker distinguishes "succeeded / killed by our own restart" from "install failed".
echo "$EXPECTED_VERSION" > "$DATA_DIR/.version"

systemctl --user restart "$SERVICE_NAME"
log "Service started."
