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

A `SessionStart` hook registers each project with a global watcher service — **but only if the
project has a `.claude/daemon.json`**. That file is the opt-in signal: without it, `claude` runs as a
normal (non-daemon) session and nothing is installed or registered. The watcher manages persistent
Claude sessions for all registered projects.

```
Project has .claude/daemon.json
  └─ SessionStart hook fires
       └─ setup.sh registers project in ${CLAUDE_PLUGIN_DATA}/projects
            └─ claude-daemon.service (watcher)
                 └─ tmux "<dirname>"
                      └─ claude --resume <derived-uuid> -n <dirname>
```

Remove the `daemon.json` and the watcher gracefully stops that project's session on the next scan and
won't restart it until the file reappears — so you can toggle a project between daemon and plain
`claude` just by adding or removing the file.

| Derived value | Source |
|---------------|--------|
| tmux session name | `sessionName` in `.claude/daemon.json` (verbatim), else the directory name |
| Claude display label (`-n`) | `remoteLabel` in `.claude/daemon.json`, else the directory name |
| Session ID | Deterministic UUID from project path (sha256) |
| Settings | `.claude/daemon.json` merged on top of `.claude/settings.json` (if present) |

## Usage

Add a `.claude/daemon.json` to the project (even an empty `{}`), start one Claude session to trigger
the hook, and the daemon runs automatically. No other setup needed. Delete the file to turn the daemon
off for that project.

### Opt-in: `.claude/daemon.json`

`daemon.json` is **required** — its presence is what opts a project into the daemon. An empty object is
enough:

```json
{}
```

Its keys are also merged on top of the project's `.claude/settings.json` for the daemon session only
(manual CLI sessions are unaffected), so it doubles as a settings-override file:

```json
{
  "remoteControlAtStartup": true,
  "tui": "fullscreen"
}
```

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

### Reaping stuck background processes

Background commands a daemon session starts — dev servers, `run_in_background` jobs, `nohup … &` —
run as children of the session's `claude` process. If that `claude` dies or restarts, they reparent to
PID 1 and leak. The watcher reaps them, governed by a `reapProcesses` block in `daemon.json`:

```json
{
  "reapProcesses": {
    "enabled": true,
    "onRestart": true,
    "orphans": true,
    "graceSeconds": 5,
    "maxAgeSeconds": 3600,
    "protect": ["vite", "node .* dev"]
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `true` | Master switch for this project's reaping |
| `orphans` / `onRestart` | `true` | Kill the session's leaked processes on a stop/restart and via a periodic sweep — the safe default (nothing live owns them) |
| `maxAgeSeconds` | `3600` (1h) | Age-based reaping on a **live** session — kill tagged processes older than this. Sensible ceiling that catches leaked children (dev servers, headless browsers, unattended `run_in_background` jobs) without touching short-lived work. Set to `0` to disable age-based reaping entirely; add long-lived processes to `protect` (e.g. persistent MCP daemons) so they survive. |
| `graceSeconds` | `5` | `SIGTERM`, wait, then `SIGKILL` survivors |
| `protect` | — | Regexes matched against `/proc/<pid>/cmdline`; a match spares the process |

**How it knows which processes are Claude's.** Each session is launched with a `DAEMON_SESSION_ID` env
var. Environment is inherited, so it tags `claude` and every process it spawns, and it survives
reparenting to PID 1 — so a leaked process stays attributable to its origin session even after its
`claude` is gone. Reaping only ever targets a session with no live `claude`; a live session's
background work is left alone (that's `claude`'s to manage). Every unreadable `/proc` read is skipped
rather than guessed, and live `claude` processes are always excluded — reaping can't kill a session.

#### Stalled / hung processes

Orphan reaping only fires once a session's owner is *gone*. To also kill processes that hang while the
session is still **live**, add a `stalled` sub-block. This judges a still-owned process, so it's
heuristic — **off by default**, and it must look stalled for `checks` **consecutive** sweeps (~1min
each) before anything is killed:

```json
{
  "reapProcesses": {
    "protect": ["vite", "node .* dev"],
    "stalled": {
      "enabled": true,
      "checks": 3,
      "minAgeSeconds": 600,
      "uninterruptible": true,
      "cpuIdle": false
    }
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Turn stalled/hung detection on for this project |
| `checks` | `3` | Consecutive sweeps the process must look stalled before it's killed (~1 min/sweep) |
| `minAgeSeconds` | `600` | Ignore processes younger than this |
| `uninterruptible` | `true` | Flag a process stuck in state **D** (uninterruptible sleep) — the specific, low-false-positive "hung on I/O" signal |
| `cpuIdle` | `false` | Also flag a process whose CPU time isn't advancing. **Aggressive:** this also matches anything legitimately idle-but-waiting — an idle dev server, even claude's own idle helpers — so enable it only with a `protect[]` list |

Kills use the same `graceSeconds` path and honor `protect[]`. Zombies (state **Z**) are skipped —
they're already dead, so `SIGKILL` can't remove them (only their parent reaping them can). The counter
resets the instant a process looks healthy again (e.g. its CPU advances), so a process that merely
paused is never killed. Note this is **not** true hang-proof detection — a genuinely idle-but-healthy
process is indistinguishable from a hung one by these signals, which is why `cpuIdle` leans on
`protect[]` and why the whole feature is opt-in.

#### Docker containers

A container started with `docker run` is **not** a child of the `claude` process — dockerd runs it
under `containerd-shim` with a fresh environment, so it never inherits the `DAEMON_SESSION_ID` tag and
is invisible to the process reaper above. A hung one therefore survives even after its launching bash
process is reaped (this bit us hard once — a wedged `docker run` grep burned CPU for ~2.5h and took the
host down). Enable `reapProcesses.docker` to clean these up too:

```json
{
  "reapProcesses": {
    "docker": {
      "enabled": true,
      "maxAgeSeconds": 3600,
      "protect": ["postgres", "my-dev-db"]
    }
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Opt in. When on, the session gets a `docker` shim on its PATH that stamps an ownership label on `docker run` / `docker compose run`; the reaper removes containers by that label |
| `maxAgeSeconds` | inherits `reapProcesses.maxAgeSeconds` (else `3600`) | On a live session, remove labeled containers older than this |
| `protect` | — | Regexes matched against container **name or image**; a match spares it (e.g. an intentional dev database) |

**How ownership works — and why it's safe.** The shim injects `--label claude.daemon.session=<sid>`
only into `docker run`/`compose run`, only inside a daemon session, and the reaper filters on exactly
that label. It's the same firewall as the process reaper: **it can only ever remove containers this
daemon labeled.** Compose-managed containers (`com.docker.compose.*`) and anything you start yourself
have no such label and are never touched. Labeled containers are removed on session stop/restart, and —
on a live session — once they exceed `maxAgeSeconds` (which is what actually catches a hung container
whose bash launcher was already reaped). Every `docker` call is timeout-wrapped so a wedged dockerd
can't hang the watcher.

**Recommended pattern.** Run anything you want to stay up as a **`docker compose up` service** — those
carry compose labels, not ours, so they're never reap candidates no matter how long they run. That
leaves the agent's one-shot `docker run` / `docker compose run` commands as the only things age-reaping
touches, which is exactly right: a one-shot is meant to exit, so one still running past `maxAgeSeconds`
is a hang (the incident) rather than a service. Keep process age-reaping on too — with long-lived work
living in containers, a *host* process outliving `maxAgeSeconds` is almost always leaked ephemera. The
one edge to know: a genuine long (>`maxAgeSeconds`) one-shot run via `docker run` (a big build/test
rather than compose) would be reaped — raise `docker.maxAgeSeconds` or `protect` it if that comes up.

**Limitations.** Only `docker …` invocations are shimmed — a call by absolute path (`/usr/bin/docker`),
with global flags before the subcommand (`docker --context x run`), or `docker compose -f f.yml run`
(flags before `run`) bypasses the label and won't be auto-reaped (fail-open by design). `docker-compose`
v1 (hyphenated) isn't shimmed. Linux-only.

### Auto-updating Claude

A running `claude` process never upgrades in place — an update lands on disk but the running process
keeps its old version until it exits. A daemon session that runs for days would stay stale forever. The
watcher fixes this via an `autoUpdate` block in `daemon.json` (**off by default** — opt in per project):

```json
{
  "autoUpdate": {
    "enabled": true,
    "intervalMinutes": 360,
    "restart": "when-idle",
    "idleMinutes": 5
  }
}
```

| Key | Default | Meaning |
|-----|---------|---------|
| `enabled` | `false` | Opt this project into daemon-managed updates |
| `intervalMinutes` | `360` | How often the watcher runs `claude update`. It's one global binary, so the watcher updates once per the smallest interval across opted-in projects — not per project |
| `restart` | `"when-idle"` | How to adopt a newer on-disk version: `when-idle` (restart once the session's transcript has been quiet for `idleMinutes`), `immediate` (restart as soon as it's available), or `never` (log only; restart manually) |
| `idleMinutes` | `5` | Quiet threshold for `when-idle` |

The watcher runs `claude update` (works for **all** install methods, not just native), then restarts
each session whose launched version differs from what's now on disk. Restart is history-preserving
(`--resume`, path-derived session ID), so you lose nothing but a brief blip. `when-idle` avoids
interrupting an in-flight or remote-controlled task mid-turn.

This block is **purely additive** — it never disables Claude's own auto-updater. It just adds the two
pieces a long-running session otherwise lacks: proactively pulling updates (which matters because a
running process never self-updates in place) and restarting to adopt them. If you'd rather the daemon
be the *sole* update driver, you can *optionally* add `"env": { "DISABLE_AUTOUPDATER": "1" }` to make it
the single source of update timing — but leaving Claude's auto-updater on is fine and they coexist
without conflict. (Don't use `DISABLE_UPDATES`, which blocks `claude update` itself.)

### Remote control & periodic re-login (known limitation)

Remote control **requires** an OAuth `/login` (the long-lived-token alternatives — `claude setup-token`,
`ANTHROPIC_API_KEY` — don't support it). Claude Code's OAuth refresh tokens are single-use / rotating
with a **fixed absolute lifetime that refreshing does not extend**, and multiple long-lived daemon
sessions under one login **share a single credential file** and can rotate each other's tokens out,
forcing a periodic `/login`. This is [documented Claude Code
behaviour](https://code.claude.com/docs/en/troubleshoot-install.md), not something the daemon can work
around — Claude Code 2.1.211+ added coordination that makes parallel sessions share their refresh more
gracefully, so keep current.

> **Removed in 2.12.0:** earlier versions shipped a `keepAlive` option that fired a periodic `claude -p`
> to "hold the login open." It didn't work — it can't extend the fixed expiry, and its extra refresher
> was a *third* token-rotator that made the multi-session collision **worse**. It's gone; drop any
> `keepAlive` block from your `daemon.json`.

If you still hit frequent re-logins with several concurrent sessions, the reliable manual workaround is
to isolate each session's credentials: launch each with its own `CLAUDE_CONFIG_DIR` and do a one-time
`/login` in each, so no two sessions share (and rotate) one token.

## Session Persistence

The session ID is a deterministic UUID derived from the project's absolute path. Restarts always resume the same conversation — no state files needed. First run creates the session, subsequent runs resume it.

## Plugin Lifecycle

A `SessionStart` hook runs `setup.sh` on every Claude session. It:

1. Compares the plugin version against a cached value in `${CLAUDE_PLUGIN_DATA}` — on first install or after an update, runs `install.sh` to create or update the systemd watcher service
2. Registers the current project in `${CLAUDE_PLUGIN_DATA}/projects`

Subsequent sessions are a no-op for step 1; step 2 is a dedup check.

With auto-update enabled, marketplace updates are pulled automatically. The watcher service is updated on the next Claude session start.

## Prerequisites

- `tmux` (3.x+) — hosts the sessions
- `jq` — the watcher parses every `daemon.json` with it; without it the daemon runs but silently ignores
  all per-project config and uses defaults
- `tmux` and `jq` are **auto-installed if missing** via the system package manager (apt / dnf / yum /
  pacman / brew), provided passwordless `sudo -n` works; otherwise the installer errors (on stderr) with
  the manual command to run
- `claude` CLI installed as a real binary on a directory in `PATH` — **not** merely a shell alias or a
  `~/.bashrc` PATH export. The installer captures `claude`'s directory and bakes it into the systemd
  unit's `PATH`, so a native `~/.local/bin/claude` works even where the systemd *user manager*'s own
  PATH omits `~/.local/bin` (older systemd, before ~v256). But if `claude` only exists as an alias, the
  installer can't resolve it and will exit with an error (visible on stderr).
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

- **Opt-in via `daemon.json`**: A project is daemonized only if it has `.claude/daemon.json` (empty `{}` is enough); remove the file to turn the daemon off and fall back to plain `claude`
- **Auto-restart**: If Claude exits, the watcher restarts its session on the next scan
- **Leak cleanup**: Background processes a dead/restarted session left behind are reaped (see [Reaping stuck background processes](#reaping-stuck-background-processes))
- **Linger**: Service runs even when logged out
- **Remote control**: Add `"remoteControlAtStartup": true` to daemon.json, connect from claude.ai/code
- **Multiple projects**: Each gets its own tmux session and Claude session — no conflicts
- **Crash-safe teardown**: The watcher only removes its own systemd unit after confirming the plugin is absent from every registered project across several consecutive scans (~30s). A settings file that can't be read (e.g. a `grep` killed under memory pressure) is treated as *inconclusive* and never triggers removal — so transient OOM can't make the daemon delete itself.

## Known Limitations

See [TODO.md](TODO.md) for improvements pending plugin lifecycle hooks ([anthropics/claude-code#48986](https://github.com/anthropics/claude-code/issues/48986)).
