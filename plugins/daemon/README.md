# Claude Daemon

A Claude Code plugin that runs persistent Claude sessions as a systemd service. Install the plugin in any project, and the watcher automatically starts a daemon session for it.

## Install

Install from the `spaethtech-plugins` marketplace via `/plugin` in Claude Code. The watcher service is set up automatically on the next session start.

To prompt collaborators to install, add this to your project's `.claude/settings.json`:

```json
{
  "extraKnownMarketplaces": {
    "spaethtech-plugins": {
      "source": {
        "source": "github",
        "repo": "spaethtech/claude-plugins"
      }
    }
  }
}
```

## How It Works

A `SessionStart` hook registers each project with a global watcher service. The watcher manages persistent Claude sessions for all registered projects.

```
Plugin installed in project
  └─ SessionStart hook fires
       └─ setup.sh registers project in ${CLAUDE_PLUGIN_DATA}/projects
            └─ claude-daemon.service (watcher)
                 └─ tmux "claude-<dirname>"
                      └─ claude --resume <derived-uuid> -n <dirname>
```

| Derived value | Source |
|---------------|--------|
| Claude session name | Directory name |
| Session ID | Deterministic UUID from project path (sha256) |
| tmux session | `claude-<dirname>` |
| Settings | `.claude/daemon.json` merged on top of `.claude/settings.json` (if present) |

## Usage

Once the plugin is installed in a project and you've started one Claude session (to trigger the hook), the daemon runs automatically. No other setup needed.

### Optional: Settings overrides

Create `.claude/daemon.json` to override settings for the daemon session only — manual CLI sessions are unaffected:

```json
{
  "remoteControlAtStartup": true,
  "tui": "fullscreen"
}
```

This file is optional. Without it, the daemon uses the project's standard `.claude/settings.json`.

### Live Reload

The watcher checks `daemon.json` modification times every 10 seconds. Edit the file and the session restarts automatically.

## Session Persistence

The session ID is a deterministic UUID derived from the project's absolute path. Restarts always resume the same conversation — no state files needed. First run creates the session, subsequent runs resume it.

## Plugin Lifecycle

A `SessionStart` hook runs `setup.sh` on every Claude session. It:

1. Compares the plugin version against a cached value in `${CLAUDE_PLUGIN_DATA}` — on first install or after an update, runs `install.sh` to create or update the systemd watcher service
2. Registers the current project in `${CLAUDE_PLUGIN_DATA}/projects`

Subsequent sessions are a no-op for step 1; step 2 is a dedup check.

With auto-update enabled, marketplace updates are pulled automatically. The watcher service is updated on the next Claude session start.

## Prerequisites

- `tmux` (3.x+)
- `claude` CLI on PATH
- systemd with user service support (Linux)

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

- **Auto-discovery**: Install the plugin in a project, start a session — daemon runs
- **Auto-restart**: If Claude exits, the watcher restarts its session on the next scan
- **Linger**: Service runs even when logged out
- **Remote control**: Add `"remoteControlAtStartup": true` to daemon.json, connect from claude.ai/code
- **Multiple projects**: Each gets its own tmux session and Claude session — no conflicts
- **Settings optional**: `daemon.json` is only needed for overrides, not for opt-in

## Known Limitations

See [TODO.md](TODO.md) for improvements pending plugin lifecycle hooks ([anthropics/claude-code#48986](https://github.com/anthropics/claude-code/issues/48986)).
