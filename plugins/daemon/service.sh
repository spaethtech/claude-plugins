#!/bin/bash -l
set -euo pipefail

PLUGIN_DIR="${DAEMON_PLUGIN_DIR:?DAEMON_PLUGIN_DIR not set}"
DATA_DIR="${DAEMON_DATA_DIR:?DAEMON_DATA_DIR not set}"
PROJECTS_FILE="$DATA_DIR/projects"
SERVICE_NAME="claude-daemon"
PLUGIN_KEY="daemon@spaethtech-plugins"
POLL_INTERVAL=10
# Consecutive "uninstalled from all projects" scans required before a destructive
# teardown. At POLL_INTERVAL=10s this is a ~30s sustained signal, so a one-off failed
# settings read (e.g. an OOM-killed grep) can never trigger self-removal.
TEARDOWN_THRESHOLD=3

declare -A MTIMES
# project_dir → the tmux session name it was actually started with. Lets a mid-session `sessionName`
# change kill the OLD session (by its real name) before starting the renamed one, instead of orphaning
# it. Rebuilt by adoption on watcher restart (see the reload loop).
declare -A SESSION_NAMES
uninstall_streak=0

session_id_for() {
  echo -n "$1" | sha256sum | \
    sed 's/^\(.\{8\}\)\(.\{4\}\)\(.\{4\}\)\(.\{4\}\)\(.\{12\}\).*/\1-\2-\3-\4-\5/'
}

# tmux session NAME for a project — the `sessionName` from daemon.json used verbatim (NO `claude-`
# prefix), else the project directory's basename. tmux target syntax treats '.' and ':' specially
# (window / pane separators) and whitespace is awkward, so ONLY those characters are replaced with '-';
# everything else is kept as-is. A missing/empty/null value, or an unreadable/invalid daemon.json,
# falls back to the directory basename.
# NOTE: two projects that pick the same `sessionName` collide on the tmux name; their conversations
# still stay separate (the session ID is path-derived), but the second tmux session won't start.
tmux_session_for() {
  local project_dir="$1"
  local daemon_json="$project_dir/.claude/daemon.json"
  local name=""
  if [[ -f "$daemon_json" ]]; then
    name="$(jq -r '.sessionName // empty' "$daemon_json" 2>/dev/null || true)"
  fi
  if [[ -z "$name" ]]; then
    name="$(basename "$project_dir")"
  fi
  # Neutralize only the tmux-hostile characters; keep the rest verbatim.
  printf '%s' "$name" | sed 's/[.:[:space:]]/-/g'
}

# Claude DISPLAY label (the `-n` flag — what shows in claude.ai, the mobile app, and Desktop). A
# `remoteLabel` string in daemon.json wins; otherwise the project directory's basename. Same fallback
# on a missing/empty/null value or an unreadable/invalid daemon.json.
remote_label_for() {
  local project_dir="$1"
  local daemon_json="$project_dir/.claude/daemon.json"
  local name=""
  if [[ -f "$daemon_json" ]]; then
    name="$(jq -r '.remoteLabel // empty' "$daemon_json" 2>/dev/null || true)"
  fi
  if [[ -n "$name" ]]; then
    printf '%s' "$name"
  else
    basename "$project_dir"
  fi
}

start_session() {
  local project_dir="$1"
  local session
  session="$(tmux_session_for "$project_dir")"
  local remote_label
  remote_label="$(remote_label_for "$project_dir")"
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

  # Remember the real tmux name so a later `sessionName` change can kill THIS session (not a freshly
  # recomputed name) before starting the renamed one — see the reload loop.
  SESSION_NAMES["$project_dir"]="$session"

  # The display label is passed through a tmux session env var (`-e`) and expanded at the innermost
  # shell, so a label with spaces or quotes needs no nested-quote gymnastics in the command below.
  tmux new-session -d -s "$session" -c "$project_dir" \
    -e "DAEMON_SESSION_NAME=$remote_label" \
    "bash -lc 'exec claude $session_flag -n \"\$DAEMON_SESSION_NAME\" $settings_flag'"

  echo "Started session: $session ($project_dir) [label: $remote_label]"
}

stop_session() {
  local project_dir="$1"
  # Kill the session under the name it was actually STARTED with (tracked), so a mid-session
  # `sessionName` change still targets the running session. Fall back to recomputing the name when the
  # tracking map is empty (e.g. the first scan after a watcher restart, before adoption).
  local session="${SESSION_NAMES[$project_dir]:-}"
  if [[ -z "$session" ]]; then
    session="$(tmux_session_for "$project_dir")"
  fi

  tmux kill-session -t "$session" 2>/dev/null || true
  unset "MTIMES[$project_dir]"
  unset "SESSION_NAMES[$project_dir]"
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

# Check if plugin key exists (not value, just presence) in any settings file for a project.
# Returns: 0 = installed (key found), 1 = confirmed absent (all files readable, no key),
#          2 = inconclusive (a settings file exists but could not be read/grepped).
#
# The 2-state distinction is critical: a grep that fails because it was OOM-killed or
# because the file was momentarily unreadable must NOT be mistaken for "the user removed
# the plugin". Conflating those two is what lets transient memory pressure trick the
# watcher into tearing down its own systemd unit. grep exits 0=match, 1=no-match, >1=error.
plugin_installed_in() {
  local project_dir="$1"
  local unknown=0 rc f
  for f in "$project_dir/.claude/settings.json" \
           "$project_dir/.claude/settings.local.json" \
           "$HOME/.claude/settings.json"; do
    [[ -f "$f" ]] || continue
    if grep -q "\"$PLUGIN_KEY\"" "$f" 2>/dev/null; then
      return 0
    else
      rc=$?
      [[ $rc -gt 1 ]] && unknown=1
    fi
  done
  [[ $unknown -eq 1 ]] && return 2
  return 1
}

# Read an explicit true|false value for the plugin key from a settings file.
# Echoes "true" or "false" on success (rc=0). Returns rc=1 if the file is
# absent or the key is missing / not an explicit bool. Returns rc=2 if the
# file exists but grep failed (transient read error).
plugin_value_in() {
  local f="$1" match rc
  [[ -f "$f" ]] || return 1
  match=$(grep -oE "\"$PLUGIN_KEY\"[[:space:]]*:[[:space:]]*(true|false)" "$f" 2>/dev/null)
  rc=$?
  [[ $rc -gt 1 ]] && return 2
  [[ -z "$match" ]] && return 1
  if [[ "$match" =~ :[[:space:]]*true ]]; then
    echo "true"
  else
    echo "false"
  fi
  return 0
}

# Precedence follows Claude Code's own settings layering:
#   settings.local.json  >  settings.json  >  default (enabled).
# The local override is where an operator says "on THIS host I want a
# different state" — a design choice by Anthropic that svelte-ui's
# `settings.local.json` matches. Whichever file explicitly sets the plugin
# to true/false wins; unrelated fields (or a missing key) fall through to
# the next tier. Neither file explicitly defining a bool → enabled by
# default (matches the pre-2.4.0 behaviour of "no `: false` seen").
#
# Read errors on a specific file fall through to the next tier rather than
# tipping the session state — the per-project loop is non-destructive (one
# bad poll = one wrong session start/stop that self-corrects on the next
# scan), so defensive defer isn't worth the complexity here.
is_plugin_enabled() {
  local project_dir="$1"
  local val

  if val=$(plugin_value_in "$project_dir/.claude/settings.local.json"); then
    [[ "$val" == "true" ]]
    return
  fi

  if val=$(plugin_value_in "$project_dir/.claude/settings.json"); then
    [[ "$val" == "true" ]]
    return
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

  # Check if plugin was uninstalled from ALL projects (entry removed entirely).
  # teardown() is destructive and irreversible (it rm's this unit and exits), so we
  # guard it two ways: (1) an inconclusive read of any project's settings aborts the
  # decision entirely, and (2) "absent everywhere" must hold for TEARDOWN_THRESHOLD
  # consecutive scans before we act. Either guard alone defeats the OOM self-teardown.
  any_installed=false
  any_unknown=false
  while IFS= read -r project_dir; do
    [[ -z "$project_dir" ]] && continue
    [[ ! -d "$project_dir" ]] && continue
    plugin_installed_in "$project_dir" && rc=0 || rc=$?
    case $rc in
      0) any_installed=true; break ;;
      2) any_unknown=true ;;
    esac
  done < "$PROJECTS_FILE"

  if $any_installed; then
    uninstall_streak=0
  elif $any_unknown; then
    # Could not read some settings (transient error / memory pressure). Inconclusive —
    # never tear down on a read we don't trust. Reset the streak and re-check next scan.
    echo "Install check inconclusive (unreadable settings); deferring teardown"
    uninstall_streak=0
  else
    uninstall_streak=$((uninstall_streak + 1))
    if (( uninstall_streak >= TEARDOWN_THRESHOLD )); then
      echo "Plugin uninstalled from all projects (confirmed ${uninstall_streak}x)"
      teardown false
    else
      echo "Plugin appears uninstalled (${uninstall_streak}/${TEARDOWN_THRESHOLD}); deferring teardown"
    fi
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

    known_session="${SESSION_NAMES[$project_dir]:-}"
    if [[ -n "$known_session" ]] && tmux has-session -t "$known_session" 2>/dev/null; then
      # Running and tracked. Any daemon.json edit (sessionName OR remoteLabel) → restart to apply it.
      # stop_session targets the KNOWN old name, so a sessionName change kills the running session
      # cleanly before the renamed one starts; the restart resumes the same conversation (the session
      # ID is path-derived), so history is preserved under the new name.
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
    else
      # Not tracked as running. After a watcher restart the tmux session may already exist under its
      # derived name — adopt it (seed the tracking + mtime maps) instead of starting a duplicate.
      # Otherwise start it. (If sessionName changed while the watcher was down, the derived name won't
      # match the old running session and a new one starts, leaving the old orphaned — a rare edge.)
      expected_session="$(tmux_session_for "$project_dir")"
      if tmux has-session -t "$expected_session" 2>/dev/null; then
        SESSION_NAMES["$project_dir"]="$expected_session"
        daemon_json="$project_dir/.claude/daemon.json"
        if [[ -f "$daemon_json" ]]; then
          MTIMES["$project_dir"]="$(stat -c %Y "$daemon_json")"
        else
          MTIMES["$project_dir"]="none"
        fi
      else
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
