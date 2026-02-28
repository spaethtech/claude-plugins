Show recent Claude Code remote session logs for the current project.

1. List the contents of `.claude/remote/` to find session log directories (sorted by date, most recent first).
2. If there are logs, read the most recent day's log files and present a summary to the user.
3. If no logs exist yet, tell the user that no remote session logs have been recorded and that logs are created automatically when sessions start via `claude-remote start`.

Use bash commands like:
```bash
ls -1t .claude/remote/ 2>/dev/null
```

Then read the latest logs and summarize them concisely.
