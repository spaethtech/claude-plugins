---
name: remote-summary
description: Generate or show a structured summary for a Claude Code remote session
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Glob
---

Generate (or show) a structured summary for a Claude Code remote session.

1. Determine the session name: `tmux display-message -p '#{session_name}' 2>/dev/null` or fall back to finding the most recent session directory under `.claude/remote/`.
2. Find the most recent `.log` file (filenames are timestamps, so sorting gives chronological order):
   ```bash
   ls -1 .claude/remote/{session}/*.log 2>/dev/null | sort -r | head -1
   ```
3. Determine the corresponding summary path by replacing `.log` with `.md`.
4. **If a `.md` already exists** for this log, read and display it.
5. **If no summary exists yet**, read the raw `.log` (terminal capture with ANSI codes — parse through them) and generate a summary in this format:

```markdown
# Remote Session Summary

- **Session**: {session name from log header}
- **Started**: {timestamp}
- **Ended**: {timestamp} (or "still running" if active)
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

6. Write the generated summary to the `.md` path.
7. Display the summary to the user.

If no log files exist at all, tell the user no remote sessions have been recorded yet.
