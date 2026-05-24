#!/bin/bash
set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SERVICE_NAME="claude-daemon"
DAEMON_HOME="$HOME/.local/share/claude-daemon"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/${SERVICE_NAME}.service"

QUIET=false
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=true ;;
  esac
done

log() { $QUIET || echo "$@"; }

# Prerequisites
if ! command -v tmux &>/dev/null; then
  log "ERROR: tmux is required but not installed."
  exit 1
fi
if ! command -v claude &>/dev/null; then
  log "ERROR: claude is not on PATH."
  exit 1
fi

mkdir -p "$SYSTEMD_USER_DIR" "$DAEMON_HOME"

# Copy service.sh to durable location (survives cache + data dir cleanup)
cp "$PLUGIN_DIR/service.sh" "$DAEMON_HOME/service.sh"
chmod +x "$DAEMON_HOME/service.sh"

# Store the cache path so the watcher can detect plugin removal/updates
echo "$PLUGIN_DIR" > "$DAEMON_HOME/.plugin-dir"

# Regenerate the service file (always, to pick up new paths on update)
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Claude Code Daemon Watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DAEMON_HOME=${DAEMON_HOME}
ExecStart=${DAEMON_HOME}/service.sh
Restart=always
RestartSec=10
TimeoutStopSec=30

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
systemctl --user restart "$SERVICE_NAME"
log "Service started."
