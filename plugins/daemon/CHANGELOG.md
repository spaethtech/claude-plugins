# Changelog

All notable changes to the `daemon` plugin are documented here. This project
follows [Semantic Versioning](https://semver.org/).

## [2.11.2]

### Fixed

Install-reliability fixes from a host where the daemon silently never installed (Debian 12, systemd
252): `sudo -n` needed a password and `claude` wasn't on the service PATH — two ordinary environmental
problems that combined into an unfalsifiable, permanent, zero-output failure.

- **A failed install no longer latches the version marker (primary).** `setup.sh` used to write
  `$DATA_DIR/.version` *before* running `install.sh`, so if `install.sh` exited non-zero at a prereq
  check, the marker was already advanced — `CURRENT == EXPECTED` on every later session and the install
  was **never retried**, even after the user fixed the underlying problem. The marker write now lives in
  `install.sh`, after prereqs pass and the unit is enabled, immediately **before** the `systemctl
  restart` that SIGTERMs the hook. So a genuine failure exits before the marker advances (and retries
  next session), while a success writes it before the self-kill (no update→restart→kill loop). The
  anti-loop property the old write-first ordering protected is preserved.
- **Prereq errors are no longer swallowed by `--quiet`.** `setup.sh` calls `install.sh --quiet`, which
  routed every `ERROR:` through the same `log()` that `--quiet` silenced — a host could fail to install
  forever with zero diagnostics. Errors now go to stderr unconditionally via a separate `err()`, and
  `setup.sh` drops a `$DATA_DIR/.install-error` breadcrumb (with the exit code and the command to
  re-run) on any genuine failure, cleared on success.
- **The systemd unit now bakes `claude`'s directory into `PATH`.** The service ran bare `claude`
  (`--version`, `exec claude`, `claude update`) but the unit set no `PATH`, inheriting the systemd user
  manager's — which on older systemd (before ~v256) omits `~/.local/bin`, where a native install lands,
  making `claude` invisible to the service with no error. `install.sh` captures `claude`'s dir at
  install time (it already requires `claude` to resolve) and writes `Environment=PATH=<dir>:…` into the
  unit. Regenerated on every update.
- **Routine restarts no longer log a spurious failure.** A normal `systemctl restart` SIGTERMs the
  watcher (exit 143), which systemd logged as `Failed with result 'exit-code'` — a red herring for
  anyone later debugging the service. Added `SuccessExitStatus=143` to the unit.

Regression coverage in `tests/install-marker.test.sh`: a hermetic (fully stubbed) run asserts a
successful install advances the marker and a failed one does not, that errors reach stderr under
`--quiet`, that the unit carries the baked PATH + `SuccessExitStatus`, and that the marker write
precedes the restart in source (so a SIGTERM mid-restart still leaves it advanced).

## [2.11.1]

### Fixed

- **The periodic process reaper never ran — under `set -euo pipefail` the sweep silently reaped
  nothing.** The sweep's session-id scanner used a bare `grep` inside a `for` loop; `grep` exits 1 on
  the first tag-less `/proc` entry (kernel threads / pid 1 sort first), and `errexit` aborted the whole
  enumeration subshell *before it reached any tagged process*. The scanner returned an empty list, so
  `reap_procs` (aged **and** orphan modes) and `detect_stalled_for_session` were **never invoked from
  the periodic sweep**. A daemon up for days logged zero sweep reaps while over-age / orphaned / stalled
  leaks piled up untouched. **If you relied on age/orphan/stalled reaping, you have effectively had
  none.** On-stop reaping (`stop_session`) and Docker container reaping were unaffected — they call the
  reaper directly, bypassing this scanner.

  Fixed by neutralising grep's no-match exit with `|| true`, factored into a `tagged_sids_present()`
  helper (sibling of `tagged_pids_for`), with a regression test in `tests/reaper-sweep.test.sh` that
  asserts the scanner enumerates a live tagged session under `set -euo pipefail`. Note for anyone
  tempted to "clean it up": a `grep … | tr` form does **not** fix this — `pipefail` makes the no-match
  pipeline exit 1 and `errexit` still aborts. The `|| true` (or a `grep && …` guard) is required.

- Corrected a stale `reap_procs` header comment that still said `maxAgeSeconds` defaults to `0`
  (age-based off); the default has been `3600` (1h, on) since 2.9.0 — the drift went unnoticed because
  the age path never actually executed (above).

## [2.11.0]

### Added

- **Docker container reaping** (`reapProcesses.docker`) — cleans up containers a daemon session
  launched but leaked. **Motivated by an incident on 2026-08-04:** a `docker run --rm … grep …` was
  auto-backgrounded by the Bash tool after the 2-minute timeout; the grep wedged (piping to `head`
  inside a large file, stuck in write). Our existing reaper killed the bash process, but the
  **container kept running** — `docker run` hands the workload to dockerd, so the container process is
  a child of `containerd-shim` with a *fresh environment* and never carries our `DAEMON_SESSION_ID`
  `/proc` tag, making it structurally invisible to the process reaper. `--rm` didn't fire (it cleans up
  on container *exit*, not on client disconnect). The zombie container burned CPU for ~2h27m, starved
  dbus/systemd-logind, and wedged the VM — a hard reboot was required.

  **How it works — label at launch, reap by label:**
  - When enabled, a daemon session gets a small `docker` shim prepended to its PATH (`shim/docker`).
    The shim injects `--label claude.daemon.session=<session-id>` into `docker run` and
    `docker compose run`, then execs the real docker. It's a transparent passthrough for every other
    invocation and **fails open** — any parsing uncertainty runs the original command unmodified.
  - The reaper then removes containers filtered strictly on that label — the exact same ownership
    firewall as the process reaper. **Compose containers** (labelled `com.docker.compose.*`) and
    **user-started containers** lack our label and are *never* matched.
  - **Triggers:** on session stop/restart/teardown, all of the session's labeled containers are
    removed; on the periodic sweep, a **live** session's labeled containers older than `maxAgeSeconds`
    are removed (this is what would have caught the incident — that session stayed alive while the
    container leaked), and a **crashed** session's containers are removed even when no tagged process
    remains in `/proc`.

  ```json
  {
    "reapProcesses": {
      "docker": {
        "enabled": false,
        "maxAgeSeconds": 3600,
        "protect": ["postgres", "my-dev-db"]
      }
    }
  }
  ```

  - **`enabled`** (default `false`) — opt-in; when off, no shim is placed on PATH and nothing changes.
  - **`maxAgeSeconds`** (default: inherits `reapProcesses.maxAgeSeconds`, else `3600`) — age threshold
    for live-session container reaping.
  - **`protect`** — regexes matched against container **name or image**; a match spares the container
    (for an intentional long-lived container the session started, e.g. a dev database).
  - **Safety.** Every `docker` call is `timeout`-wrapped so a wedged dockerd (the incident's failure
    mode) can't hang the watcher; a failed/unreadable docker read skips that container rather than
    guessing. Removal is `docker rm -f` (force stop + remove), scoped to our label only.
  - **Limitations.** Only `docker run` / `docker compose run` invoked as `docker …` are labeled; a call
    via an absolute path (`/usr/bin/docker`), or with global flags before the subcommand
    (`docker --context x run`), or `docker compose -f f.yml run` (compose flags before `run`), bypasses
    the shim and goes unlabeled (so it won't be auto-reaped) — fail-open by design. `docker-compose`
    (v1, hyphenated) is not shimmed. Linux-only, like the rest of the reaper.

## [2.10.0]

### Added

- **OAuth keep-alive** (`keepAlive`) — keeps remote control alive across long idle periods without a
  forced `/login`. A Claude Pro/Max OAuth login refreshes its token only when the process makes a
  request near/after access-token expiry; an idle daemon never does, so once the refresh token's idle
  window lapses (a few days) you must re-authenticate — which breaks remote control. The watcher now
  fires a trivial `claude -p` once the access token has expired, triggering the reactive refresh and
  rotating the shared refresh token, keeping every session authenticated.

  ```json
  {
    "keepAlive": {
      "enabled": true,
      "checkEveryMinutes": 30
    }
  }
  ```

  - **`enabled`** (default `false`) — opt-in per project. Credentials live in one per-user file shared
    by every session, so a single keep-alive covers all daemon sessions at once; if multiple projects
    opt in, the **smallest** `checkEveryMinutes` wins.
  - **`checkEveryMinutes`** (default `30`) — how often the watcher checks `expiresAt`. It only actually
    refreshes once the access token is within ~5 min of expiry (firing earlier is a no-op — a request
    won't rotate the token until it's near/past expiry), so at most ~3 trivial requests a day while idle.
  - **Self-verifying via journald.** Each attempt logs the outcome (prefix `keep-alive:`): token rotated
    (success), request ok but token didn't advance (possible refresh bug — watch for re-login), request
    failed (refresh token likely dead — manual `/login` needed), or timed out. Watch with
    `journalctl --user -u claude-daemon -f | grep keep-alive`.
  - **Scope.** Only meaningful for a `claudeAiOauth` login on Linux (the credential file); API-key auth
    has no expiry (skipped), and macOS stores credentials in Keychain rather than a file.

### Changed

- Refactored process enumeration/grace-kill helpers are now joined by `keepalive_field` for reading the
  new block, mirroring `autoupdate_field`.

## [2.9.0]

### Changed

- **`reapProcesses.maxAgeSeconds` default is now `3600` (was `0` / off).** Age-based reaping
  on a live session now fires by default for tagged processes older than 1h — the ceiling
  that catches everything you actually want reaped (leaked headless browsers, forgotten
  `run_in_background` dev servers, unattended pytest suites) without touching short-lived
  work. Prior default silently left leaked processes running indefinitely; the reaping
  code was in place but the age threshold made it a no-op unless the user opted in via
  `daemon.json`, and few projects did — including the ones that most needed it.

  **Migration.** Projects that rely on tagged processes lasting more than 1h on a live
  session need to either:
  - raise `reapProcesses.maxAgeSeconds` explicitly (e.g. `86400` for 24h), or
  - add the process's cmdline pattern to `reapProcesses.protect` (e.g. persistent MCP
    daemons that the session intentionally keeps alive across long spans), or
  - set `reapProcesses.maxAgeSeconds: 0` to opt out of age-based reaping entirely
    (orphan reaping on session stop/restart still applies).

  If your current `daemon.json` doesn't set `maxAgeSeconds`, you now get 1h reaping
  automatically. Verify your project's long-lived processes appear in `protect` before
  the first live-session sweep after upgrading.

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
