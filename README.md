# SpaethTech Claude Code Plugins

A Claude Code plugin marketplace.

## Install the Marketplace

```bash
claude plugin marketplace add spaethtech/claude-plugins --scope user
```

This makes all plugins available across every project. Then install individual plugins via `/plugin` in Claude Code.

## Plugins

### daemon

Persistent Claude Code sessions managed by a systemd watcher service. Install the plugin in any project, start one Claude session to trigger setup, and the watcher runs your daemon sessions automatically.

- **Enable a project**: Install the plugin, start a session — done
- **Settings overrides**: Optional `.claude/daemon.json` for daemon-only settings
- **Disable/re-enable**: Reactive — watcher stops/starts sessions within 10 seconds
- **Uninstall**: Watcher tears itself down automatically

See [plugins/daemon/README.md](plugins/daemon/README.md) for full documentation.

## Usage

```bash
# Add the marketplace (one time)
claude plugin marketplace add spaethtech/claude-plugins --scope user

# Install a plugin (user level — available in all projects)
claude plugin install daemon@spaethtech-plugins --scope user

# Update marketplace to latest
claude plugin marketplace update spaethtech-plugins

# List installed plugins
claude plugin list
```

Or use the interactive `/plugin` UI inside Claude Code.
