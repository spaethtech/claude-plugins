# Changelog

All notable changes to the `daemon` plugin are documented here. This project
follows [Semantic Versioning](https://semver.org/).

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
