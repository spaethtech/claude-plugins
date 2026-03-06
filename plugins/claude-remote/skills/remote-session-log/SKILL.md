---
name: remote-session-log
description: Summary format reference for Claude Code remote session logs. Used by /remote-summary to generate structured summaries from raw terminal capture.
user-invocable: false
---

Remote session terminal output is automatically captured to `.log` files via `tmux pipe-pane`. The `.log` is raw terminal I/O — not structured.

## Log Layout

```
.claude/remote/{session}/{timestamp}.log  <- automatic terminal capture
.claude/remote/{session}/{timestamp}.md   <- generated on demand or at session end
```

The `{timestamp}` is `YYYYMMDD-HHMMSS` (e.g. `20260301-143005`). Sorting filenames lexically gives chronological order — the most recent log is always last.

## Summary Format (.md)

When generating a summary (via `/remote-summary`), read the raw `.log` and produce:

```markdown
# Remote Session Summary

- **Session**: {session name}
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

- {error description} — {resolution}

## Decisions

- {decision} — {rationale}
```

If no errors occurred, omit the Errors section. Same for Decisions if none were noteworthy.

The `.claude/remote/` directory is local-only (gitignored).
