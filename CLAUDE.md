# Claude Code Plugins Marketplace

This repository is a Claude Code plugin marketplace. Users can add it with:

```
/plugin marketplace add spaethtech/claude-plugins
```

## Structure

- `.claude-plugin/marketplace.json` — The marketplace registry listing all available plugins
- `plugins/<plugin-name>/` — Individual plugin directories, each with its own `plugin.json`

## Adding a Plugin

1. Create a directory under `plugins/` with a kebab-case name
2. Add a `.claude-plugin/plugin.json` manifest inside it
3. Add the plugin entry to `.claude-plugin/marketplace.json`

## Plugin Directory Structure

Each plugin can contain any combination of:

```
plugins/my-plugin/
├── .claude-plugin/
│   └── plugin.json        # Plugin manifest (required)
├── commands/              # Slash commands (markdown files)
├── agents/                # Subagents (markdown files)
├── skills/                # Skills
├── hooks/
│   └── hooks.json         # Event handlers
├── .mcp.json              # MCP server configs
└── .lsp.json              # Language server configs
```

## Validation

Run `/plugin validate .` from this repo to check marketplace.json syntax.
