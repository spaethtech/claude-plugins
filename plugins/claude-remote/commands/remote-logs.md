Show the raw session log for the most recent (or currently active) Claude Code remote session.

1. Check if `.claude/remote/current` exists — if so, read it to get the active log path.
2. Otherwise, find the most recent `.log` file under `.claude/remote/`:
   ```bash
   find .claude/remote/ -name '*.log' -type f 2>/dev/null | sort -r | head -1
   ```
3. If a log file is found, read it and display it to the user.
4. If no logs exist, tell the user that no remote session logs have been recorded yet and that logs are created automatically when sessions start via `claude-remote start`.

The raw log is an append-only text file with timestamped entries. Present it as-is — this is the unprocessed record. If the user wants a structured summary, suggest they use `/remote-summary` instead.
