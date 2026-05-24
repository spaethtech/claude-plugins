#!/bin/bash -l
set -euo pipefail

PLUGIN_DIR="${DAEMON_PLUGIN_DIR:?DAEMON_PLUGIN_DIR not set}"
DATA_DIR="${DAEMON_DATA_DIR:?DAEMON_DATA_DIR not set}"
PROJECTS_FILE="$DATA_DIR/projects"
POLL_INTERVAL=10

declare -A MTIMES

session_id_for() {
  echo -n "$1" | sha256sum | \
    sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/'
}

start_session() {
  local project_dir="$1"
  local project_name="$(basename "$project_dir")"
  local session="claude-${project_name}"
  local daemon_json="$project_dir/.claude/daemon.json"
  local session_id="$(session_id_for "$project_dir")"

  local session_flag
  if find ~/.claude/projects -name "${session_id}.jsonl" 2>/dev/null | grep -q .; then
    session_flag="--resume $session_id"
  else
    session_flag="--session-id $session_id"
  fi

  # Use daemon.json for settings overrides if it exists
  local settings_flag=""
  if [[ -f "$daemon_json" ]]; then
    settings_flag="--settings $daemon_json"
    MTIMES["$project_dir"]="$(stat -c %Y "$daemon_json")"
  else
    MTIMES["$project_dir"]="none"
  fi

  tmux new-session -d -s "$session" -c "$project_dir" \
    "bash -lc 'exec claude $session_flag -n $project_name $settings_flag'"

  echo "Started session: $session ($project_dir)"
}

stop_session() {
  local project_dir="$1"
  local project_name="$(basename "$project_dir")"
  local session="claude-${project_name}"

  tmux kill-session -t "$session" 2>/dev/null || true
  unset "MTIMES[$project_dir]"
  echo "Stopped session: $session"
}

cleanup() {
  for project_dir in "${!MTIMES[@]}"; do
    stop_session "$project_dir"
  done
}
trap cleanup EXIT TERM INT

while true; do
  # Read registered projects
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  declare -A ACTIVE
  while IFS= read -r project_dir; do
    [[ -z "$project_dir" ]] && continue
    [[ ! -d "$project_dir" ]] && continue

    # Skip if plugin is disabled at project level
    settings="$project_dir/.claude/settings.json"
    if [[ -f "$settings" ]] && grep -q '"daemon@spaethtech-plugins"[[:space:]]*:[[:space:]]*false' "$settings"; then
      # Stop session if it was running
      if [[ -n "${MTIMES[$project_dir]:-}" ]]; then
        echo "Plugin disabled: $project_dir"
        stop_session "$project_dir"
      fi
      continue
    fi

    ACTIVE["$project_dir"]=1
    project_name="$(basename "$project_dir")"
    session="claude-${project_name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
      start_session "$project_dir"
    else
      # Check for daemon.json changes (added, modified, or removed)
      daemon_json="$project_dir/.claude/daemon.json"
      current_mtime="none"
      if [[ -f "$daemon_json" ]]; then
        current_mtime="$(stat -c %Y "$daemon_json")"
      fi
      if [[ "${MTIMES[$project_dir]:-}" != "$current_mtime" ]]; then
        echo "daemon.json changed: $project_dir"
        stop_session "$project_dir"
        start_session "$project_dir"
      fi
    fi
  done < "$PROJECTS_FILE"

  # Stop sessions for unregistered projects
  for project_dir in "${!MTIMES[@]}"; do
    if [[ -z "${ACTIVE[$project_dir]:-}" ]]; then
      echo "Project unregistered: $project_dir"
      stop_session "$project_dir"
    fi
  done

  unset ACTIVE
  sleep "$POLL_INTERVAL"
done
