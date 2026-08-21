# SpaethTech Claude Code Plugins

A Claude Code plugin marketplace.

## Install the Marketplace

```bash
claude plugin marketplace add spaethtech/claude-plugins --scope user
```

This makes every plugin available across all your projects. Install and configure individual plugins
using the links in the table below — or the interactive `/plugin` UI inside Claude Code.

Manage the marketplace:

```bash
claude plugin marketplace update spaethtech-plugins   # pull the latest
claude plugin list                                    # list installed plugins
```

## Plugins

| Plugin | What it does |
|--------|--------------|
| **[daemon](plugins/daemon/README.md)** | Run Claude Code as a persistent systemd/tmux service — auto-restart on crash, survive logout, remote-control from claude.ai, clean up leaked background processes & Docker containers, and self-update. **[Install &amp; `daemon.json` reference →](plugins/daemon/README.md)** |
