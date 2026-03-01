You are operating in a Claude Code **remote-control session**. You MUST maintain session logs so the developer can review what happened while unattended.

There are TWO log files per session — a raw log and a summary:

```
.claude/remote/{session}/{date}/{time}.log  ← append-only raw log (crash-safe)
.claude/remote/{session}/{date}/{time}.md   ← generated on demand or at session end
```

## Session Initialization

At the **very start** of each remote session (before doing any work):

1. Determine the current date and time (use `date '+%Y-%m-%d'` and `date '+%H%M'`).
2. Determine the session name from the tmux session: `tmux display-message -p '#{session_name}' 2>/dev/null || echo "unknown"`.
3. Create the log directory: `mkdir -p .claude/remote/{session}/{date}/`
4. Create the raw log file: `.claude/remote/{session}/{date}/{time}.log`
5. Write the initial log header:

```
=== CLAUDE REMOTE SESSION ===
session: {session_name}
started: {date} {time}
project: {working directory}
===
```

6. Ensure `.claude/remote/` is listed in the project's `.gitignore` (append it if missing — do NOT overwrite the file).
7. Write a pointer file `.claude/remote/{session}/current` containing the path to the active log file.

## Raw Log Format (.log)

The raw log is an **append-only text file**. Write to it **immediately** — before and after every meaningful action. This is your crash-safe record. If the session dies mid-task, whatever was already written survives.

Use this format for each entry:

```
--- {HH:MM:SS} {EVENT_TYPE} ---
{details}
```

Event types and when to write them:

| Event | When |
|---|---|
| `TASK_START` | When you begin working on a task or request |
| `TASK_DONE` | When a task is completed |
| `CMD` | Before running a shell command (include the command) |
| `CMD_RESULT` | After a command completes (include exit code, key output) |
| `FILE_READ` | When reading a file (include path) |
| `FILE_WRITE` | When creating/modifying a file (include path, brief description) |
| `ERROR` | When an error occurs (include error message, context) |
| `DECISION` | When making a non-obvious choice (include rationale) |
| `COMMIT` | When creating a git commit (include hash, message) |
| `NOTE` | Any other relevant observation |

Example log entries:

```
--- 14:30:05 TASK_START ---
User requested: fix the login timeout bug in auth.ts

--- 14:30:12 FILE_READ ---
src/auth.ts

--- 14:30:18 DECISION ---
The timeout is hardcoded to 5000ms on line 42. Changing to configurable
via AUTH_TIMEOUT env var with 30000ms default.

--- 14:30:25 FILE_WRITE ---
src/auth.ts — replaced hardcoded timeout with process.env.AUTH_TIMEOUT

--- 14:30:30 CMD ---
npm test -- --grep "auth"

--- 14:30:45 CMD_RESULT ---
exit: 0 — 12 tests passed

--- 14:30:50 COMMIT ---
a1b2c3d — fix: make auth timeout configurable via AUTH_TIMEOUT env var

--- 14:30:51 TASK_DONE ---
Login timeout bug fixed. Timeout now reads from AUTH_TIMEOUT env var (default 30s).
```

## Summary File (.md)

The summary is **NOT written continuously**. It is generated:
- At session end (graceful shutdown)
- On demand when `/remote-summary` is invoked

When generating a summary, read the raw log and produce a structured markdown file:

```markdown
# Remote Session Summary

- **Session**: {session_name}
- **Started**: {date} {time}
- **Ended**: {date} {time}
- **Project**: {working directory}

## Tasks

- {task 1 description} — {outcome}
- {task 2 description} — {outcome}

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

## Important Rules

- **ALWAYS write to the .log file first, before doing the action.** For commands, log the CMD entry before running it. This ensures if the session crashes during execution, the intent is recorded.
- **NEVER skip logging.** Every remote session must have a log file.
- **Write frequently.** The raw log should be a near-real-time record. Don't batch entries.
- **Update the `current` pointer** at session start so tooling always knows where the active log is.
- The `.claude/remote/` directory is local-only (gitignored) so you can be candid about errors and decisions.
