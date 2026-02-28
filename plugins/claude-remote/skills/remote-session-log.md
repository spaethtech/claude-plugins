You are operating in a Claude Code **remote-control session**. You MUST maintain a session log so the developer can review what happened while unattended.

## Session Log Requirements

At the **very start** of each remote session (before doing any work), do the following:

1. Determine the current date and time (use `date '+%Y-%m-%d'` and `date '+%H%M'`).
2. Determine the session name from the tmux session: `tmux display-message -p '#{session_name}' 2>/dev/null || echo "unknown"`.
3. Create the log directory if it doesn't exist: `.claude/remote/{date}/` (e.g. `.claude/remote/2026-02-28/`).
4. Create a new log file: `.claude/remote/{date}/{time}-{session}.md` (e.g. `.claude/remote/2026-02-28/1430-claude-myproject.md`).
5. Write an initial header to the log:

```markdown
# Remote Session Log

- **Session**: {session_name}
- **Started**: {date} {time}
- **Project**: {working directory}

## Activity

```

6. Ensure `.claude/remote/` is listed in the project's `.gitignore` (append it if missing — do NOT overwrite the file).

## Ongoing Logging

As you work through the session, **append** to the log file after each meaningful action:

- Task descriptions (what was requested or what you decided to do)
- Files modified (paths and brief description of changes)
- Commands run and their outcomes
- Errors encountered and how they were resolved
- Commits created (hash and message)
- Decisions made and rationale

Use this format for each entry:

```markdown
### {HH:MM} — {brief title}

{description of what was done}

- Modified: `path/to/file` — {what changed}
- Ran: `command` — {outcome}
```

## On Session End

When the session ends (or when you receive a stop/exit signal), append a summary:

```markdown
## Summary

- **Ended**: {date} {time}
- **Tasks completed**: {count}
- **Files modified**: {list}
- **Commits**: {list of hashes}
```

## Important

- NEVER skip logging. Every remote session must have a log file.
- Keep log entries concise but informative — another developer should understand what happened by reading the log alone.
- The `.claude/remote/` directory is local-only (gitignored) so you can be candid about errors and decisions.
