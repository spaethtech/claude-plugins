#!/bin/bash -l
set -euo pipefail

PLUGIN_DIR="${DAEMON_PLUGIN_DIR:?DAEMON_PLUGIN_DIR not set}"
SCAN_ROOT="$HOME"
SCAN_DEPTH=4
SCAN_INTERVAL=10

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

  local settings_flag="--settings $daemon_json"

  tmux new-session -d -s "$session" -c "$project_dir" \
    "bash -lc 'exec claude $session_flag -n $project_name $settings_flag'"

  MTIMES["$project_dir"]="$(stat -c %Y "$daemon_json")"
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
  # Find all projects with daemon.json
  mapfile -t FOUND < <(find "$SCAN_ROOT" -maxdepth "$SCAN_DEPTH" \
    -name daemon.json -path '*/.claude/daemon.json' \
    -not -path '*/node_modules/*' -not -path '*/.git/*' 2>/dev/null)

  # Build set of active project dirs
  declare -A ACTIVE
  for daemon_json in "${FOUND[@]}"; do
    [[ -z "$daemon_json" ]] && continue
    project_dir="$(cd "$(dirname "$daemon_json")/.." && pwd)"
    ACTIVE["$project_dir"]=1
    project_name="$(basename "$project_dir")"
    session="claude-${project_name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
      # New project or crashed session — start it
      start_session "$project_dir"
    else
      # Check for daemon.json changes
      current_mtime="$(stat -c %Y "$daemon_json" 2>/dev/null || echo 0)"
      if [[ "${MTIMES[$project_dir]:-}" != "$current_mtime" ]]; then
        echo "daemon.json changed: $project_dir"
        stop_session "$project_dir"
        start_session "$project_dir"
      fi
    fi
  done

  # Stop sessions for removed daemon.json files
  for project_dir in "${!MTIMES[@]}"; do
    if [[ -z "${ACTIVE[$project_dir]:-}" ]]; then
      echo "daemon.json removed: $project_dir"
      stop_session "$project_dir"
    fi
  done

  unset ACTIVE
  sleep "$SCAN_INTERVAL"
done
