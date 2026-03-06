#!/usr/bin/env bash
# cSpell:ignore pcomm

# Kill duplicate Claude CLI/tmux sessions, but spare the VS Code extension.
# Called by settings.json SessionStart hook.

for pid in $(pgrep -f 'claude.*--output-format stream-json'); do
    # Skip self and parent
    [ "$pid" = "$$" ] || [ "$pid" = "$PPID" ] && continue

    # Skip VS Code extension processes
    ppid_of_pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    pcomm=$(ps -o comm= -p "$ppid_of_pid" 2>/dev/null)
    case "$pcomm" in
        node|code|electron|code-*) continue ;;
    esac

    kill "$pid" 2>/dev/null
done

true
