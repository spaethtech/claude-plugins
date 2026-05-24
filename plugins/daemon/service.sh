#!/bin/bash -l
set -euo pipefail

DAEMON_HOME="${DAEMON_HOME:?DAEMON_HOME not set}"
PROJECTS_FILE="$DAEMON_HOME/projects"
PLUGIN_DIR_FILE="$DAEMON_HOME/.plugin-dir"
SERVICE_NAME="claude-daemon"
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

stop_all() {
  for project_dir in "${!MTIMES[@]}"; do
    stop_session "$project_dir"
  done
}

teardown() {
  echo "Tearing down daemon service..."
  stop_all
  systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service"
  systemctl --user daemon-reload 2>/dev/null || true
  rm -rf "$DAEMON_HOME"
  echo "Daemon service removed."
  exit 0
}

trap stop_all EXIT TERM INT

is_plugin_enabled() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local settings_local="$project_dir/.claude/settings.local.json"

  if [[ -f "$settings" ]] && grep -q '"daemon@spaethtech-plugins"[[:space:]]*:[[:space:]]*false' "$settings"; then
    return 1
  fi
  if [[ -f "$settings_local" ]] && grep -q '"daemon@spaethtech-plugins"[[:space:]]*:[[:space:]]*false' "$settings_local"; then
    return 1
  fi

  return 0
}

while true; do
  # Check if plugin was globally removed (cache directory gone)
  if [[ -f "$PLUGIN_DIR_FILE" ]]; then
    plugin_dir="$(cat "$PLUGIN_DIR_FILE")"
    if [[ ! -d "$plugin_dir" ]]; then
      echo "Plugin removed from cache: $plugin_dir"
      teardown
    fi

    # Check for plugin update (newer version in cache)
    cache_parent="$(dirname "$plugin_dir")"
    if [[ -d "$cache_parent" ]]; then
      latest="$(ls -1 "$cache_parent" | sort -V | tail -1)"
      current="$(basename "$plugin_dir")"
      if [[ "$latest" != "$current" ]]; then
        echo "Plugin updated: $current → $latest"
        new_plugin_dir="$cache_parent/$latest"
        stop_all
        # Run the new version's install.sh (regenerates service file + copies scripts)
        CLAUDE_PLUGIN_ROOT="$new_plugin_dir" bash "$new_plugin_dir/install.sh" --quiet
        echo "Watcher updated and restarted."
        exit 0
      fi
    fi
  fi

  # Read registered projects
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  declare -A ACTIVE
  active_count=0

  while IFS= read -r project_dir; do
    [[ -z "$project_dir" ]] && continue
    [[ ! -d "$project_dir" ]] && continue

    if ! is_plugin_enabled "$project_dir"; then
      if [[ -n "${MTIMES[$project_dir]:-}" ]]; then
        echo "Plugin disabled: $project_dir"
        stop_session "$project_dir"
      fi
      continue
    fi

    ACTIVE["$project_dir"]=1
    active_count=$((active_count + 1))
    project_name="$(basename "$project_dir")"
    session="claude-${project_name}"

    if ! tmux has-session -t "$session" 2>/dev/null; then
      start_session "$project_dir"
    else
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
