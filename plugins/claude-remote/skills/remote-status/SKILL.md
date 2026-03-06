---
name: remote-status
description: Check if a Claude Code remote-control tmux session is running for the current project
disable-model-invocation: true
allowed-tools: Bash
---

Check if a Claude Code remote-control tmux session is running for the current project.

Run the following bash command:
```bash
${CLAUDE_PLUGIN_ROOT}/scripts/claude-remote status
```

Report the output to the user.
