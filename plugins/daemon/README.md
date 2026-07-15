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
                 └─ tmux "<dirname>"
                      └─ claude --resume <derived-uuid> -n <dirname>
```

| Derived value | Source |
|---------------|--------|
| tmux session name | `sessionName` in `.claude/daemon.json` (verbatim), else the directory name |
| Claude display label (`-n`) | `remoteLabel` in `.claude/daemon.json`, else the directory name |
| Session ID | Deterministic UUID from project path (sha256) |
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

#### Naming the session

By default both the tmux session and the Claude display label are the project directory name. Two
independent keys override them:

```json
{
  "sessionName": "prod-worker",
  "remoteLabel": "Prod Worker — phone"
}
```

- **`sessionName`** — the **tmux** session name, used verbatim (no `claude-` prefix), so
  `tmux attach -t prod-worker` works. Characters tmux treats specially in targeting — `.`, `:`, and
  whitespace — are replaced with `-`. Two projects sharing a `sessionName` collide on the tmux name
  (the second won't start), though their histories stay separate (the session ID is path-derived).
- **`remoteLabel`** — the **Claude display label** (the `-n` flag) shown in claude.ai, the mobile app,
  and Claude Desktop.

Each falls back to the directory name independently when missing or empty.

**Renaming keeps your history.** Editing either key is picked up by the live-reload watcher, which
**stops and restarts** the session (not a live rename) — and it tracks the running tmux name, so a
`sessionName` change kills the old session cleanly before starting the renamed one. The restart
relaunches with `--resume`, and the session ID is derived from the project path — not the name — so it
reopens the **same conversation** under the new name/label. You lose nothing but a brief restart.

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
- **Crash-safe teardown**: The watcher only removes its own systemd unit after confirming the plugin is absent from every registered project across several consecutive scans (~30s). A settings file that can't be read (e.g. a `grep` killed under memory pressure) is treated as *inconclusive* and never triggers removal — so transient OOM can't make the daemon delete itself.

## Known Limitations

See [TODO.md](TODO.md) for improvements pending plugin lifecycle hooks ([anthropics/claude-code#48986](https://github.com/anthropics/claude-code/issues/48986)).
