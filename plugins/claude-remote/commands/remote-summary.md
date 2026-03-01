Generate (or show) a structured summary for a Claude Code remote session.

1. Check if `.claude/remote/current` exists to find the active log path. Otherwise, find the most recent `.log.txt`:
   ```bash
   find .claude/remote/ -name '*.log.txt' -type f 2>/dev/null | sort -r | head -1
   ```
2. Determine the corresponding summary path by replacing `.log.txt` with `.summary.md`.
3. **If a `.summary.md` already exists** for this session, read and display it.
4. **If no summary exists yet**, read the raw `.log.txt` and generate a summary in this format:

```markdown
# Remote Session Summary

- **Session**: {session name from log header}
- **Started**: {date} {time}
- **Ended**: {date} {time} (or "still running" if current)
- **Project**: {working directory}

## Tasks

- {task description} — {outcome}

## Changes

| File | Action | Description |
|------|--------|-------------|
| `path/to/file` | modified | {what changed} |

## Commits

- `{hash}` — {message}

## Errors

- {error} — {resolution}

## Decisions

- {decision} — {rationale}
```

Omit the Errors section if there were none. Same for Decisions.

5. Write the generated summary to the `.summary.md` path.
6. Display the summary to the user.

If no log files exist at all, tell the user no remote sessions have been recorded yet.
