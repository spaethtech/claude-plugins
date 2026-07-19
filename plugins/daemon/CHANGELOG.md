# Changelog

All notable changes to the `daemon` plugin are documented here. This project
follows [Semantic Versioning](https://semver.org/).

## [2.8.0]

### Added

- **Stalled/hung background-process detection** (`reapProcesses.stalled`). Complements the existing
  reaping: orphan reaping handles processes whose owner is *gone*; this judges processes on a **live**
  session that appear hung. Because it acts on a still-owned process it's inherently heuristic, so it's
  **off by default** and requires the stalled condition to hold for `checks` **consecutive** sweeps
  before killing.

  ```json
  {
    "reapProcesses": {
      "stalled": {
        "enabled": false,
        "checks": 3,
        "minAgeSeconds": 600,
        "uninterruptible": true,
        "cpuIdle": false
      }
    }
  }
  ```

  A tagged process counts as stalled in a sweep only if it is older than `minAgeSeconds` **and** matches
  an enabled signal:
  - **`uninterruptible`** (default **on**): process in state **D** (uninterruptible sleep) — the
    textbook hung-on-I/O signal. Healthy idle processes sit in **S**, not **D**, so this is specific and
    low-false-positive.
  - **`cpuIdle`** (default **off**): the process's CPU time hasn't advanced since the previous sweep.
    Catches spin-free logical hangs/deadlocks, but also flags anything legitimately idle-but-waiting —
    an idle dev server, and even claude's own idle helper processes (they carry the session tag). Enable
    it only alongside a `protect[]` list for whatever is meant to sit idle.

  Kills go through the shared grace path (`graceSeconds`: SIGTERM → wait → SIGKILL) and honor
  `reapProcesses.protect[]`. Zombies (state **Z**) are skipped — they're already dead, so SIGKILL can't
  remove them (only their parent reaping them can). The live claude pane is always excluded, and every
  unreadable `/proc` read is skipped rather than guessed. The counter resets the moment a process looks
  healthy again (e.g. its CPU advances), so a process that merely paused is never killed.

### Changed

- Refactored the reaper's process-enumeration and grace-kill into shared `tagged_pids_for` /
  `kill_gracefully` helpers, now used by both orphan/age reaping and stalled detection.

## [2.7.0]

### Added

- **Daemon-managed Claude auto-updates.** A `claude` process never upgrades in place — an update lands
  on disk but the running process keeps its old version until it restarts. Long-lived daemon sessions
  would therefore stay stale indefinitely. The watcher now closes that gap, governed by an `autoUpdate`
  block in `daemon.json`:

  ```json
  {
    "autoUpdate": {
      "enabled": false,
      "intervalMinutes": 360,
      "restart": "when-idle",
      "idleMinutes": 5
    }
  }
  ```

  - **Keeps the binary current.** When any project opts in, the watcher runs `claude update` on the
    smallest configured interval (one global binary, so it runs once — not per project). This works for
    **all** install methods, not just native installs. The block is **purely additive** — it never
    disables Claude's own auto-updater; the two coexist without conflict. If you want the daemon to be
    the *sole* update driver you can optionally add `"env": { "DISABLE_AUTOUPDATER": "1" }` to the same
    `daemon.json` (don't use `DISABLE_UPDATES`, which blocks `claude update` itself).
  - **Adopts the new version by restarting.** Each session records the version it launched with; when
    the on-disk `claude --version` differs, the watcher restarts it (history-preserving via `--resume`,
    exactly like the `sessionName`/`remoteLabel` live-reload) per the `restart` policy:
    - `"when-idle"` (default) — restart only once the session's transcript has been quiet for
      `idleMinutes`, so an in-flight (or remote-controlled) task is never interrupted mid-turn.
    - `"immediate"` — restart as soon as a newer version is on disk.
    - `"never"` — keep the binary current but only log that an update is pending; you restart manually.
  - **Off by default** (`enabled: false`) — updating and restarting are disruptive, so this is opt-in
    per project. Unknown/unreadable reads fall back to safe defaults and never force a restart.

## [2.6.0]

### Added

- **`daemon.json` presence is now the per-project opt-in gate.** A project is daemonized only when
  `.claude/daemon.json` exists — so a normal, non-daemon `claude` session can be used in any project
  that doesn't have the file. Concretely:

  - **`setup.sh` (SessionStart)** exits early when the project has no `.claude/daemon.json`: it neither
    registers the project nor installs the watcher service. The systemd watcher is therefore installed
    the first time a session starts in a project that *has* a `daemon.json`, not merely because the
    plugin is enabled.
  - **The watcher** notices a `daemon.json` that has been **removed** and **gracefully stops** that
    project's tmux session — and does **not** bring it back until a `daemon.json` reappears (the next
    scan restarts it automatically). A brief disappearance (some editors truncate/unlink mid-save) is
    debounced: the file must be missing for 2 consecutive scans (~20s) before the session is stopped,
    so an atomic save can't bounce it.

  An empty `{}` `daemon.json` is enough to opt in.

- **Reaping of stuck/lingering background processes Claude started.** Background commands a daemon
  session spawns (dev servers, `run_in_background` jobs, `nohup … &`) become descendants of the pane's
  `claude` process. When that `claude` dies or restarts they reparent to PID 1 and leak. The watcher
  now cleans them up, governed by a `reapProcesses` block in `daemon.json`:

  ```json
  {
    "reapProcesses": {
      "enabled": true,
      "onRestart": true,
      "orphans": true,
      "graceSeconds": 5,
      "maxAgeSeconds": 0,
      "protect": ["vite", "node .* dev"]
    }
  }
  ```

  - **How ownership is tracked.** Each session is launched with a `DAEMON_SESSION_ID` env var (the
    path-derived session UUID). Because environment is inherited, it tags `claude` *and its entire
    descendant tree*, and it **survives reparenting to PID 1** — so a leaked process is still
    attributable to its origin session, and enumerating tagged PIDs enumerates the whole leak.
  - **Orphan reaping (on by default).** On a graceful stop/restart the old session's tagged processes
    are reaped immediately (synchronously, before any restart). A throttled sweep (~every 60s) also
    catches sessions that crashed or were OOM-killed without a clean stop — a session must be seen with
    no live tmux session for 2 consecutive sweeps before its orphans are reaped, so a transient tmux
    hiccup can't be mistaken for a dead session.
  - **Age-based reaping (off by default).** Set `maxAgeSeconds > 0` to also kill tagged processes on a
    *still-live* session once they exceed that age — aggressive, opt-in per project.
  - **`protect`** — a list of regexes matched against each candidate's `/proc/<pid>/cmdline`; a match
    spares the process.
  - **`graceSeconds`** — `SIGTERM`, wait, then `SIGKILL` survivors.
  - **Safety.** Mirrors the watcher's OOM-safe philosophy: every unreadable `/proc` read skips that
    process rather than guessing, and a live `claude` pane process is always excluded as
    defense-in-depth — reaping can never fratricide a session.

## [2.5.0]

### Added

- **Two independent name overrides in `daemon.json`: `sessionName` (tmux) and `remoteLabel` (Claude
  display label).** By default both derive from the project directory name; set either to override:

  ```json
  {
    "sessionName": "prod-worker",
    "remoteLabel": "Prod Worker — phone",
    "remoteControlAtStartup": true
  }
  ```

  - **`sessionName`** → the **tmux session name**, used **verbatim** (no `claude-` prefix — this
    changes the default from `claude-<dirname>` to `<dirname>`). So `tmux attach -t prod-worker` just
    works. Only tmux-hostile characters are adjusted: `.`, `:`, and whitespace become `-` (they would
    otherwise break tmux's `session:window.pane` targeting). Two projects choosing the same
    `sessionName` collide on the tmux name (the second won't start); their histories still stay
    separate since the session ID is path-derived.
  - **`remoteLabel`** → the **Claude display label** (the `-n` flag) shown in claude.ai, the mobile
    app, and Claude Desktop. Passed via a tmux session env var, so labels with spaces or quotes are
    handled safely.

  A missing/empty/`null` value — or an unreadable/invalid `daemon.json` — falls back to the
  directory name for each, independently.

  **Both handle a mid-session rename, with history preserved.** Editing either key is picked up by the
  existing mtime watcher (~10s) as a **stop + start** (not a live rename). The watcher tracks each
  session's actual tmux name, so a `sessionName` change kills the *old* session cleanly before starting
  the renamed one — no orphan, no duplicate. The restart relaunches with `--resume <session-id>`, and
  the session ID is derived from the project **path** (unchanged by either name), so the **same
  conversation** reopens — every turn preserved — under the new tmux name and/or label.

## [2.4.0]

### Changed

- **`settings.local.json` now overrides `settings.json` for the enabled/disabled
  decision.** Previously `is_plugin_enabled()` was an `OR` over both files: a
  `"daemon@spaethtech-plugins": false` in *either* project settings file disabled
  the plugin, and neither could bring the other back. That matched the daemon's
  narrow safety-first read but didn't match Anthropic's stated Claude Code
  precedence, where the local override file is meant to be the authoritative
  per-host tier on top of the checked-in team settings.

  The new precedence is:

  ```
  settings.local.json  >  settings.json  >  default (enabled)
  ```

  A file "wins" only when it sets the plugin key to an explicit `true` or `false`;
  a missing key or unrelated shape falls through to the next tier. Neither file
  defining an explicit bool → enabled (unchanged default).

  #### Behaviour matrix

  | `settings.json`     | `settings.local.json` | 2.3.x       | 2.4.0        |
  |---------------------|-----------------------|-------------|--------------|
  | absent / unset      | absent / unset        | enabled     | enabled      |
  | `true`              | absent / unset        | enabled     | enabled      |
  | `false`             | absent / unset        | **disabled**| **disabled** |
  | absent / unset      | `true`                | enabled     | enabled      |
  | absent / unset      | `false`               | **disabled**| **disabled** |
  | `true`              | `false`               | **disabled**| **disabled** |
  | `false`             | `true`                | **disabled**| **enabled**  ← flipped |

  The single flipped row is the intent of the two-file design: keep a project's
  default in `settings.json`, override per host in `settings.local.json`.

  #### Use case that motivated this

  A team-checked-in `settings.json` can now safely carry
  `"daemon@spaethtech-plugins": false` (the shared repo doesn't want to spawn a
  session on every clone), and the ONE host that hosts the project can flip it
  back to `true` in its local-only `settings.local.json` (typically gitignored).
  Previously that scenario couldn't be expressed — the checked-in `false` would
  win regardless of what the host set locally.

## [2.3.2]

### Fixed

- **Version-bump restart loop in the `SessionStart` hook.** `setup.sh` ran
  `install.sh` (which calls `systemctl --user restart`) *before* writing the
  cached `.version` marker. On an update the restart tears down the service
  cgroup the hook runs in and SIGTERMs `setup.sh` mid-script, so the marker
  never advanced past the old version. Every subsequent session then saw the
  same stale mismatch and re-triggered install → restart → kill, bouncing the
  watcher (and its tmux/Claude session) every ~2s.

  The marker is now written **before** `install.sh`, making the update
  idempotent: a restart that kills the hook still leaves `CURRENT == EXPECTED`,
  so the next session is a no-op.

## [2.3.1]

### Fixed

- **Watcher could delete its own systemd unit under memory pressure.** The
  "uninstalled from all projects" check in `service.sh` ran `grep` against each
  project's settings and treated *any* non-match as "plugin removed" — including a
  `grep` that failed because it was OOM-killed or the file was momentarily
  unreadable. A single failed read could therefore trip `teardown()`, which
  `rm`s `~/.config/systemd/user/claude-daemon.service` and exits, leaving nothing
  for systemd's `Restart=always` to bring back. The service simply vanished.

  `plugin_installed_in()` now returns three states — installed (0), confirmed
  absent (1), and inconclusive (2, a read/`grep` error) — and the main loop:
  - **never tears down on an inconclusive read** (transient errors defer the
    decision to the next scan), and
  - requires the plugin to be **confirmed absent for `TEARDOWN_THRESHOLD` (3)
    consecutive scans** (~30s) before removing the unit.

  Either guard alone defeats the OOM self-teardown; together they make accidental
  self-removal effectively impossible while preserving genuine uninstall cleanup.
