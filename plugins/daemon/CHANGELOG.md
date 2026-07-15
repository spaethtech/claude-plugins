# Changelog

All notable changes to the `daemon` plugin are documented here. This project
follows [Semantic Versioning](https://semver.org/).

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
