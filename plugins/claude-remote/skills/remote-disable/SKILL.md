---
name: remote-disable
description: Disable auto-start on boot for the current project by removing the @reboot cron entry
disable-model-invocation: true
allowed-tools: Bash
---

Disable auto-start on boot for the current project by removing the @reboot cron entry.

Run the following bash command:
```bash
${CLAUDE_PLUGIN_ROOT}/scripts/claude-remote disable
```

Report the output to the user.
