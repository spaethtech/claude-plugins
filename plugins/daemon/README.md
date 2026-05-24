# Claude Daemon

A global watcher that runs Claude Code as persistent sessions for any project that has a `.claude/daemon.json` file.

## How It Works

One systemd service (`claude-daemon`) scans `~/` for projects containing `.claude/daemon.json`. For each one found, it starts a Claude Code session inside a tmux window. Remove the file, the session stops. Edit the file, the session restarts.

```
systemd (claude-daemon.service)
  └─ service.sh (watcher loop)
       ├─ scans ~/ for .claude/daemon.json every 10s
       ├─ starts tmux "claude-<dirname>" for each found
       ├─ stops sessions when daemon.json is removed
       └─ restarts sessions when daemon.json is modified
```

| Derived value | Source |
|---------------|--------|
| Claude session name | Directory name |
| Session ID | Deterministic UUID from project path (sha256) |
| tmux session | `claude-<dirname>` |
| Settings | `.claude/daemon.json` merged on top of `.claude/settings.json` |

## Quick Start

**Install the watcher (one time):**

```bash
./install.sh
```

**Add a project:**

```bash
echo '{}' > ~/my-project/.claude/daemon.json
# Session starts within 10 seconds
```

**Add a project with settings overrides:**

```bash
cat > ~/my-project/.claude/daemon.json <<'EOF'
{
  "remoteControlAtStartup": true,
  "tui": "fullscreen"
}
EOF
```

**Remove a project:**

```bash
rm ~/my-project/.claude/daemon.json
# Session stops within 10 seconds
```

## Session Persistence

The session ID is a deterministic UUID derived from the project's absolute path. Restarts always resume the same conversation — no state files needed. First run creates the session, subsequent runs resume it.

## Settings

`.claude/daemon.json` is passed via `--settings` and merges on top of the project's `.claude/settings.json`. Only the daemon session gets these overrides — manual CLI sessions are unaffected.

An empty `{}` file is valid — it starts a daemon with the project's standard settings.

### Live Reload

The watcher checks `daemon.json` modification times every 10 seconds. Edit the file and the session restarts automatically.

## Prerequisites

- `tmux` (3.x+)
- `claude` CLI on PATH
- systemd with user service support

## Install

```bash
CLAUDE_PLUGIN_ROOT=/path/to/this/plugin ./install.sh
```

When installed as a Claude Code plugin, `CLAUDE_PLUGIN_ROOT` is set automatically.

This will:
- Generate `claude-daemon.service` into `~/.config/systemd/user/`
- Enable lingering (so the service survives logout)
- Enable and start the watcher

## Commands

```bash
systemctl --user status  claude-daemon     # watcher status
systemctl --user restart claude-daemon     # restart watcher
journalctl --user -u     claude-daemon -f  # watcher logs

tmux attach -t claude-<project>            # interactive access
# Ctrl+B, D                                # detach back to shell
```

## Uninstall

```bash
systemctl --user stop claude-daemon
systemctl --user disable claude-daemon
rm ~/.config/systemd/user/claude-daemon.service
systemctl --user daemon-reload
```

## Notes

- **Zero config**: Drop a `daemon.json`, get a session. Remove it, session stops.
- **Auto-restart**: If Claude exits, the watcher restarts its session on the next scan
- **Linger**: Service runs even when logged out
- **Remote control**: Add `"remoteControlAtStartup": true` to daemon.json, connect from claude.ai/code
- **Multiple projects**: Each gets its own tmux session and Claude session — no conflicts
- **Scan scope**: `~/` with max depth 4, excluding `node_modules` and `.git`
