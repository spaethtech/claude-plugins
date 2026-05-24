#!/bin/bash
set -euo pipefail

PLUGIN_DIR="${CLAUDE_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
SERVICE_NAME="claude-daemon"
SYSTEMD_USER_DIR="$HOME/.config/systemd/user"
SERVICE_FILE="$SYSTEMD_USER_DIR/${SERVICE_NAME}.service"

# Already installed and running — nothing to do
if [[ -f "$SERVICE_FILE" ]] && systemctl --user is-active "$SERVICE_NAME" &>/dev/null; then
  echo "Service $SERVICE_NAME is already installed and running."
  exit 0
fi

# Prerequisites
if ! command -v tmux &>/dev/null; then
  echo "ERROR: tmux is required but not installed."
  exit 1
fi
if ! command -v claude &>/dev/null; then
  echo "ERROR: claude is not on PATH."
  exit 1
fi

echo "=== Claude Daemon - Install ==="
echo "  Plugin: $PLUGIN_DIR"
echo "  Service: $SERVICE_NAME"
echo ""

chmod +x "$PLUGIN_DIR/service.sh"
mkdir -p "$SYSTEMD_USER_DIR"

cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=Claude Code Daemon Watcher
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment=DAEMON_PLUGIN_DIR=${PLUGIN_DIR}
ExecStart=${PLUGIN_DIR}/service.sh
Restart=always
RestartSec=10
TimeoutStopSec=30

[Install]
WantedBy=default.target
EOF
echo "Generated ${SERVICE_NAME}.service"

# Enable lingering (skip if already enabled or sudo unavailable)
if ! loginctl show-user "$USER" 2>/dev/null | grep -q "Linger=yes"; then
  if sudo -n loginctl enable-linger "$USER" 2>/dev/null; then
    echo "Enabled linger for $USER."
  else
    echo "WARNING: Could not enable linger (sudo required). Service won't survive logout."
    echo "  Run manually: sudo loginctl enable-linger $USER"
  fi
fi

systemctl --user daemon-reload
systemctl --user enable "$SERVICE_NAME"
systemctl --user start "$SERVICE_NAME"
echo "Service started."

echo ""
echo "=== Usage ==="
echo "  To add a project:    echo '{}' > /path/to/project/.claude/daemon.json"
echo "  To remove a project: rm /path/to/project/.claude/daemon.json"
echo ""
echo "  Status:   systemctl --user status $SERVICE_NAME"
echo "  Logs:     journalctl --user -u $SERVICE_NAME -f"
echo "  Stop:     systemctl --user stop $SERVICE_NAME"
