#!/bin/bash -l
set -euo pipefail

PLUGIN_DIR="${DAEMON_PLUGIN_DIR:?DAEMON_PLUGIN_DIR not set}"
DATA_DIR="${DAEMON_DATA_DIR:?DAEMON_DATA_DIR not set}"
PROJECTS_FILE="$DATA_DIR/projects"
SERVICE_NAME="claude-daemon"
PLUGIN_KEY="daemon@spaethtech-plugins"
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

# Full teardown: stop sessions, remove systemd service
# If clean=true, also remove cache
teardown() {
  local clean="${1:-false}"
  echo "Tearing down daemon service..."
  stop_all
  systemctl --user disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "$HOME/.config/systemd/user/${SERVICE_NAME}.service"
  systemctl --user daemon-reload 2>/dev/null || true
  if [[ "$clean" == "true" ]]; then
    cache_parent="$(dirname "$PLUGIN_DIR")"
    if [[ -d "$cache_parent" ]]; then
      rm -rf "$cache_parent"
      echo "Cache removed: $cache_parent"
    fi
  fi
  echo "Daemon service removed."
  exit 0
}

trap stop_all EXIT TERM INT

# Check if plugin key exists (not value, just presence) in any settings file for a project
plugin_installed_in() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local settings_local="$project_dir/.claude/settings.local.json"

  if [[ -f "$settings" ]] && grep -q "\"$PLUGIN_KEY\"" "$settings"; then
    return 0
  fi
  if [[ -f "$settings_local" ]] && grep -q "\"$PLUGIN_KEY\"" "$settings_local"; then
    return 0
  fi
  # User-level settings
  if [[ -f "$HOME/.claude/settings.json" ]] && grep -q "\"$PLUGIN_KEY\"" "$HOME/.claude/settings.json"; then
    return 0
  fi

  return 1
}

# Check if plugin is explicitly disabled (value is false)
is_plugin_enabled() {
  local project_dir="$1"
  local settings="$project_dir/.claude/settings.json"
  local settings_local="$project_dir/.claude/settings.local.json"

  if [[ -f "$settings" ]] && grep -q "\"$PLUGIN_KEY\"[[:space:]]*:[[:space:]]*false" "$settings"; then
    return 1
  fi
  if [[ -f "$settings_local" ]] && grep -q "\"$PLUGIN_KEY\"[[:space:]]*:[[:space:]]*false" "$settings_local"; then
    return 1
  fi

  return 0
}

while true; do
  # Data dir deleted → user chose full removal → clean teardown
  if [[ ! -d "$DATA_DIR" ]]; then
    teardown true
  fi

  # Cache gone (7-day cleanup) → teardown (nothing to clean)
  if [[ ! -d "$PLUGIN_DIR" ]]; then
    teardown false
  fi

  # Check for plugin update (newer version in cache)
  cache_parent="$(dirname "$PLUGIN_DIR")"
  if [[ -d "$cache_parent" ]]; then
    latest="$(ls -1 "$cache_parent" | sort -V | tail -1)"
    current="$(basename "$PLUGIN_DIR")"
    if [[ "$latest" != "$current" ]]; then
      echo "Plugin updated: $current → $latest"
      new_plugin_dir="$cache_parent/$latest"
      stop_all
      CLAUDE_PLUGIN_ROOT="$new_plugin_dir" CLAUDE_PLUGIN_DATA="$DATA_DIR" \
        bash "$new_plugin_dir/install.sh" --quiet
      echo "Watcher updated and restarted."
      exit 0
    fi
  fi

  # No projects file yet — wait
  if [[ ! -f "$PROJECTS_FILE" ]]; then
    sleep "$POLL_INTERVAL"
    continue
  fi

  # Check if plugin was uninstalled from ALL projects (entry removed entirely)
  all_uninstalled=true
  while IFS= read -r project_dir; do
    [[ -z "$project_dir" ]] && continue
    [[ ! -d "$project_dir" ]] && continue
    if plugin_installed_in "$project_dir"; then
      all_uninstalled=false
      break
    fi
  done < "$PROJECTS_FILE"

  if $all_uninstalled; then
    echo "Plugin uninstalled from all projects"
    teardown false
  fi

  # Process each registered project
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
