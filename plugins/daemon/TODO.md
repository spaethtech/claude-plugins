# TODO

## Pending plugin lifecycle hooks

Tracked in [anthropics/claude-code#48986](https://github.com/anthropics/claude-code/issues/48986).

Once plugin lifecycle hooks ship, the following improvements become possible:

### PostInstall / PostUpdate

Replace the `SessionStart` version-check workaround in `setup.sh` with a proper `PluginInstall` / `PluginUpdate` hook. Currently the systemd watcher service isn't installed until the user starts their next Claude session — a lifecycle hook would run it at the right moment.

### PostDisable / PostUninstall

Stop and remove the systemd service when the plugin is disabled or uninstalled from a project. Currently the watcher keeps running because there's no hook to trigger cleanup — projects must be manually removed from the `projects` file or the service stopped by hand.

### Project deregistration

The `projects` file in `${CLAUDE_PLUGIN_DATA}` grows but never shrinks. A `PluginDisable` hook could remove the project entry automatically. Until then, stale entries for deleted directories are skipped silently but entries for existing-but-no-longer-enabled projects are not pruned.
