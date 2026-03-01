Show the raw session log for the most recent (or currently active) Claude Code remote session.

1. Determine the session name: `tmux display-message -p '#{session_name}' 2>/dev/null` or fall back to finding the most recent session directory under `.claude/remote/`.
2. Check if `.claude/remote/{session}/current` exists — if so, read it to get the active log path.
3. Otherwise, find the most recent `.log` file for this session:
   ```bash
   find .claude/remote/{session}/ -name '*.log' -type f 2>/dev/null | sort -r | head -1
   ```
4. If a log file is found, read it and display it to the user.
5. If no logs exist, tell the user that no remote session logs have been recorded yet and that logs are created automatically when sessions start via `claude-remote start`.

The raw log is an append-only text file with timestamped entries. Present it as-is — this is the unprocessed record. If the user wants a structured summary, suggest they use `/remote-summary` instead.
