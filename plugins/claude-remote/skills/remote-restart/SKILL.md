---
name: remote-restart
description: Restart the Claude Code remote-control tmux session for the current project
disable-model-invocation: true
allowed-tools: Bash
---

Restart the Claude Code remote-control tmux session for the current project. This resumes the previous conversation context.

Run the following bash command:
```bash
${CLAUDE_PLUGIN_ROOT}/scripts/claude-remote restart
```

Report the output to the user.
