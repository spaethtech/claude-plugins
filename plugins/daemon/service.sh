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
# Consecutive scans a project's daemon.json must be MISSING before its session is stopped. At
# POLL_INTERVAL=10s this is a ~20s grace so an editor's truncate/unlink during an atomic save can't
# bounce the session. daemon.json presence is the per-project opt-in gate (see setup.sh).
DAEMON_JSON_ABSENCE_THRESHOLD=2
# Run the leaked-process sweep every Nth poll (6 * 10s ≈ 60s) — reading /proc every scan is wasteful.
SWEEP_EVERY=6
# Consecutive sweeps a session id must be seen with NO live tmux session before its orphaned
# background processes are reaped. Guards against a transient tmux hiccup fratricide-ing a live
# session's children; on-restart reaping (via stop_session) is immediate because the kill is definite.
ORPHAN_SWEEP_THRESHOLD=2

declare -A MTIMES
# project_dir → the tmux session name it was actually started with. Lets a mid-session `sessionName`
# change kill the OLD session (by its real name) before starting the renamed one, instead of orphaning
# it. Rebuilt by adoption on watcher restart (see the reload loop).
declare -A SESSION_NAMES
# project_dir → consecutive scans daemon.json has been missing (debounce; see the reload loop).
declare -A ABSENT_STREAK
# session_id → consecutive sweeps observed with no live tmux session (orphan-reap confirmation).
declare -A DEAD_SWEEPS
# project_dir → the `claude --version` a session was STARTED with. When the on-disk version differs, the
# session is stale and (per policy) restarted to adopt the update — a running process never picks up an
# update in place. Set at start_session; used by the auto-update adoption check in the loop.
declare -A SESSION_VERSIONS
# pid → last observed CPU time (clock ticks) and consecutive sweeps the process has looked stalled.
# Used by stalled/hung detection (detect_stalled_for_session) to require sustained no-progress before
# killing. Pruned each sweep as pids vanish. Keyed by raw pid — pid reuse across a ~minutes window is
# negligible, and a reused pid simply re-baselines (its counter resets the first sweep it looks healthy).
declare -A PROC_CPU
declare -A PROC_STALL
uninstall_streak=0
sweep_counter=0
# Epoch of the last `claude update` run. Initialised in-loop to defer the first update by one interval
# (so a watcher restart doesn't trigger an immediate update every time).
last_update_epoch=0

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

# The installed claude version, normalised to bare X.Y.Z (drops the " (Claude Code)" suffix). Empty if
# claude can't be run — callers treat empty as "unknown" and never restart on it.
claude_version() {
  claude --version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
}

# Read a field from a project's autoUpdate block, echoing $3 when the file/key is missing or unreadable.
autoupdate_field() {
  local dj="$1/.claude/daemon.json" field="$2" default="$3"
  [[ -f "$dj" ]] || { echo "$default"; return; }
  jq -r "(.autoUpdate.$field) // \"$default\"" "$dj" 2>/dev/null || echo "$default"
}

# True when a session is quiet — its transcript hasn't been written for >= idle_min minutes. Used to
# avoid restarting a session mid-task to adopt an update. A missing transcript counts as idle (nothing
# in flight); an unreadable one counts as NOT idle (defer the restart — never guess it's safe).
session_idle() {
  local project_dir="$1" idle_min="$2"
  [[ "$idle_min" =~ ^[0-9]+$ ]] || idle_min=5
  local sid transcript mtime now
  sid="$(session_id_for "$project_dir")"
  transcript="$(find "$HOME/.claude/projects" -name "${sid}.jsonl" 2>/dev/null | head -1)"
  [[ -z "$transcript" ]] && return 0
  mtime="$(stat -c %Y "$transcript" 2>/dev/null)" || return 1
  now="$(date +%s)"
  (( now - mtime >= idle_min * 60 ))
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
  # DAEMON_SESSION_ID tags claude AND every process it spawns (env is inherited). Because it survives
  # reparenting to PID 1, a background process leaked by a dead/restarted claude is still attributable
  # to this session — and since the tag propagates to the whole descendant tree, enumerating tagged
  # PIDs enumerates the entire leak. The reaper (reap_procs) keys off exactly this.
  tmux new-session -d -s "$session" -c "$project_dir" \
    -e "DAEMON_SESSION_NAME=$remote_label" \
    -e "DAEMON_SESSION_ID=$session_id" \
    "bash -lc 'exec claude $session_flag -n \"\$DAEMON_SESSION_NAME\" $settings_flag'"

  # Record the version this session launched with, so the loop can later detect it's stale and (per
  # the autoUpdate policy) restart it to adopt a newer on-disk claude.
  SESSION_VERSIONS["$project_dir"]="$(claude_version)"

  echo "Started session: $session ($project_dir) [label: $remote_label]"
}

# Echo the pids whose environment carries this DAEMON_SESSION_ID tag — i.e. a session's whole
# descendant tree, even after reparenting to PID 1. An unreadable environ (other user / race) is
# silently skipped: grep opens the file itself so its permission error goes to /dev/null.
tagged_pids_for() {
  local sid="$1" environ pid
  for environ in /proc/[0-9]*/environ; do
    pid="${environ#/proc/}"; pid="${pid%/environ}"
    grep -qz "^DAEMON_SESSION_ID=${sid}\$" "$environ" 2>/dev/null && echo "$pid"
  done
}

# SIGTERM a list of pids, wait $1 seconds, then SIGKILL any survivors. No-op on an empty list, so the
# grace sleep is only ever paid when there's actually something to kill.
kill_gracefully() {
  local grace="$1"; shift
  local -a pids=("$@")
  ((${#pids[@]})) || return 0
  kill -TERM "${pids[@]}" 2>/dev/null || true
  sleep "$grace"
  local -a survivors=() p
  for p in "${pids[@]}"; do kill -0 "$p" 2>/dev/null && survivors+=("$p"); done
  if ((${#survivors[@]})); then
    echo "SIGKILL ${#survivors[@]} survivor(s)"
    kill -KILL "${survivors[@]}" 2>/dev/null || true
  fi
}

# Reap the background processes a daemon session leaked. Anchored on the DAEMON_SESSION_ID env tag
# (see start_session), so it finds the whole descendant tree even after reparenting to PID 1.
#   $1 project_dir  — for per-project policy; may no longer exist (daemon.json removed) → safe defaults
#   $2 session_id   — the tag to match
#   $3 mode         — "all"  : owner is dead/stopping → kill every tagged process (age ignored)
#                     "aged" : owner is LIVE          → kill only tagged procs older than maxAgeSeconds
#
# Policy comes from daemon.json's reapProcesses block. Defaults: reaping ON (orphan + on-restart),
# grace 5s, maxAgeSeconds 0 (age-based OFF), no protect list. Every /proc read that fails
# (permission/race/unreadable age) SKIPS that process — we never signal on an inconclusive read,
# mirroring the watcher's OOM-safe philosophy. A live claude pane pid is always excluded as
# defense-in-depth so we can never fratricide a session.
reap_procs() {
  local project_dir="$1" sid="$2" mode="$3"
  local daemon_json="$project_dir/.claude/daemon.json"

  local enabled=true grace=5 max_age=0
  local -a protect=()
  if [[ -f "$daemon_json" ]]; then
    enabled=$(jq -r '(.reapProcesses.enabled)     // true' "$daemon_json" 2>/dev/null || echo true)
    grace=$(  jq -r '(.reapProcesses.graceSeconds) // 5'   "$daemon_json" 2>/dev/null || echo 5)
    max_age=$(jq -r '(.reapProcesses.maxAgeSeconds)// 0'   "$daemon_json" 2>/dev/null || echo 0)
    mapfile -t protect < <(jq -r '.reapProcesses.protect[]? // empty' "$daemon_json" 2>/dev/null || true)
  fi
  [[ "$enabled" == "true" ]] || return 0
  [[ "$grace"   =~ ^[0-9]+$ ]] || grace=5
  if [[ "$mode" == "aged" ]]; then
    # Age-based reaping is strictly opt-in: a missing/zero/non-numeric maxAgeSeconds disables it.
    [[ "$max_age" =~ ^[0-9]+$ ]] && (( max_age > 0 )) || return 0
  fi

  # Live claude pane pids (across all sessions) — never a reap target. If tmux is unreachable this is
  # empty; acceptable, because a dead session has no panes and a stopping one is being killed anyway.
  local live_panes
  live_panes=" $(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ') "

  local -a targets=()
  local pid cmdline p skip age
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ "$live_panes" == *" $pid "* ]] && continue
    if [[ "$mode" == "aged" ]]; then
      age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
      [[ "$age" =~ ^[0-9]+$ ]] || continue          # unreadable age → inconclusive → skip
      (( age >= max_age )) || continue
    fi
    if ((${#protect[@]})); then
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      skip=false
      for p in "${protect[@]}"; do
        [[ -n "$p" && "$cmdline" =~ $p ]] && { skip=true; break; }
      done
      $skip && continue
    fi
    targets+=("$pid")
  done < <(tagged_pids_for "$sid")

  ((${#targets[@]})) || return 0
  echo "Reaping ${#targets[@]} leaked proc(s) [$mode] for session ${sid:0:8}"
  kill_gracefully "$grace" "${targets[@]}"
}

# Detect and kill STALLED/HUNG background processes on a LIVE session. Unlike orphan reaping (owner
# dead → definitely safe) this judges a still-owned process, so it's inherently heuristic and strictly
# opt-in via reapProcesses.stalled. Runs once per sweep and requires the stalled condition to hold for
# `checks` CONSECUTIVE sweeps (state carried in PROC_STALL/PROC_CPU) before killing — a momentary D or a
# single flat-CPU reading never fires.
#
# A process counts as stalled this sweep only if it is old enough (minAgeSeconds) AND either:
#   • uninterruptible (default ON):  in state D (uninterruptible sleep) — the textbook hung-on-I/O
#     signal; healthy idle processes sit in S, not D, so this is specific and low-false-positive.
#   • cpuIdle (default OFF):  its CPU time hasn't advanced since last sweep. Catches spin-free logical
#     hangs, but ALSO flags anything legitimately idle-but-waiting (an idle dev server, and even
#     claude's own idle helper processes, which carry the tag) — so it's off by default; when you
#     enable it, protect[] the things meant to sit idle.
#
# Zombies (state Z) are skipped: they're already dead, so SIGKILL can't remove them — only their parent
# reaping them can. The live claude pane is always excluded, and every unreadable /proc read is skipped.
detect_stalled_for_session() {
  local project_dir="$1" sid="$2"
  local dj="$project_dir/.claude/daemon.json"
  [[ -f "$dj" ]] || return 0
  [[ "$(jq -r '(.reapProcesses.stalled.enabled) // false' "$dj" 2>/dev/null || echo false)" == "true" ]] || return 0

  local checks min_age cpu_idle uninterruptible grace
  checks=$(         jq -r '(.reapProcesses.stalled.checks)          // 3'     "$dj" 2>/dev/null || echo 3)
  min_age=$(        jq -r '(.reapProcesses.stalled.minAgeSeconds)   // 600'   "$dj" 2>/dev/null || echo 600)
  cpu_idle=$(       jq -r '(.reapProcesses.stalled.cpuIdle)         // false' "$dj" 2>/dev/null || echo false)
  uninterruptible=$(jq -r '(.reapProcesses.stalled.uninterruptible) // true'  "$dj" 2>/dev/null || echo true)
  grace=$(          jq -r '(.reapProcesses.graceSeconds)            // 5'     "$dj" 2>/dev/null || echo 5)
  [[ "$checks"   =~ ^[0-9]+$ ]] || checks=3
  [[ "$min_age"  =~ ^[0-9]+$ ]] || min_age=600
  [[ "$grace"    =~ ^[0-9]+$ ]] || grace=5
  local -a protect=()
  mapfile -t protect < <(jq -r '.reapProcesses.protect[]? // empty' "$dj" 2>/dev/null || true)

  local live_panes
  live_panes=" $(tmux list-panes -a -F '#{pane_pid}' 2>/dev/null | tr '\n' ' ') "

  local -a kill_list=()
  local pid stat_line rest state cpu age prev stalled_now cmdline p skip
  local -a F
  while IFS= read -r pid; do
    [[ -z "$pid" ]] && continue
    [[ "$live_panes" == *" $pid "* ]] && continue
    stat_line=$(cat "/proc/$pid/stat" 2>/dev/null) || continue   # gone / unreadable → skip
    rest=${stat_line##*") "}                                      # drop "<pid> (<comm>) "; rest starts at state
    read -ra F <<< "$rest"
    state=${F[0]}
    [[ "$state" == "Z" ]] && { PROC_STALL["$pid"]=0; continue; }  # zombie: unkillable, don't count it
    cpu=$(( ${F[11]:-0} + ${F[12]:-0} ))                          # utime + stime, in clock ticks
    age=$(ps -o etimes= -p "$pid" 2>/dev/null | tr -d ' ')
    if ! [[ "$age" =~ ^[0-9]+$ ]]; then PROC_STALL["$pid"]=0; PROC_CPU["$pid"]=$cpu; continue; fi

    prev="${PROC_CPU[$pid]:-}"
    stalled_now=false
    if (( age >= min_age )); then
      if [[ "$uninterruptible" == "true" && "$state" == "D" ]]; then stalled_now=true; fi
      if [[ "$cpu_idle" == "true" && -n "$prev" ]] && (( cpu == prev )); then stalled_now=true; fi
    fi
    PROC_CPU["$pid"]=$cpu

    if ! $stalled_now; then PROC_STALL["$pid"]=0; continue; fi
    PROC_STALL["$pid"]=$(( ${PROC_STALL[$pid]:-0} + 1 ))
    (( ${PROC_STALL[$pid]} >= checks )) || continue

    if ((${#protect[@]})); then
      cmdline=$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)
      skip=false
      for p in "${protect[@]}"; do
        [[ -n "$p" && "$cmdline" =~ $p ]] && { skip=true; break; }
      done
      $skip && continue
    fi
    kill_list+=("$pid")
  done < <(tagged_pids_for "$sid")

  ((${#kill_list[@]})) || return 0
  echo "Stalled: killing ${#kill_list[@]} hung proc(s) [checks=$checks] for session ${sid:0:8}"
  kill_gracefully "$grace" "${kill_list[@]}"
  local dead
  for dead in "${kill_list[@]}"; do unset "PROC_STALL[$dead]" "PROC_CPU[$dead]"; done
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

  # The claude we just killed reparents its background procs to PID 1 (they keep the DAEMON_SESSION_ID
  # tag). Reap them now — synchronously and BEFORE any restart — so a daemon.json-change restart, a
  # manual stop, or a daemon.json removal all clean up the old session's leaks. reap_procs returns
  # immediately when there's nothing tagged, so a normal restart with no background work pays no cost.
  reap_procs "$project_dir" "$(session_id_for "$project_dir")" all

  unset "MTIMES[$project_dir]"
  unset "SESSION_NAMES[$project_dir]"
  unset "ABSENT_STREAK[$project_dir]"
  unset "SESSION_VERSIONS[$project_dir]"
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

# Defer the first `claude update` by one interval so a watcher restart doesn't force an update on boot.
last_update_epoch="$(date +%s)"

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

  # ── Auto-update: keep the claude binary current (global) ────────────────────────────────────────
  # `claude update` is a single global operation (one binary), so we run it at most once per the
  # SMALLEST interval among projects that opted in — not once per project. Adopting the new version
  # (restarting sessions) is handled per project further down, since a running process never upgrades
  # in place. Nothing to do unless at least one project set autoUpdate.enabled=true.
  min_update_interval=0
  while IFS= read -r project_dir; do
    [[ -z "$project_dir" || ! -d "$project_dir" ]] && continue
    [[ "$(autoupdate_field "$project_dir" enabled false)" == "true" ]] || continue
    iv="$(autoupdate_field "$project_dir" intervalMinutes 360)"
    [[ "$iv" =~ ^[0-9]+$ ]] || iv=360
    if (( min_update_interval == 0 || iv < min_update_interval )); then min_update_interval=$iv; fi
  done < "$PROJECTS_FILE"

  now="$(date +%s)"
  if (( min_update_interval > 0 )) && (( now - last_update_epoch >= min_update_interval * 60 )); then
    last_update_epoch=$now
    echo "Running claude update (interval ${min_update_interval}m)..."
    claude update >/dev/null 2>&1 || echo "claude update failed (will retry next interval)"
  fi

  # The on-disk version, read once per scan and reused by every project's adoption check below.
  disk_version="$(claude_version)"

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

    # daemon.json presence is the per-project opt-in gate. If it's gone, stop the session and do NOT
    # bring it back — until a daemon.json reappears, at which point the next scan starts it again. A
    # brief disappearance (some editors truncate/unlink mid-save) is debounced so it can't bounce the
    # session: it must stay missing for DAEMON_JSON_ABSENCE_THRESHOLD consecutive scans before we stop.
    if [[ ! -f "$project_dir/.claude/daemon.json" ]]; then
      absent_streak=$(( ${ABSENT_STREAK[$project_dir]:-0} + 1 ))
      ABSENT_STREAK["$project_dir"]=$absent_streak
      if (( absent_streak < DAEMON_JSON_ABSENCE_THRESHOLD )); then
        # Grace window — keep a running session alive (mark ACTIVE so the unregistered-sweep below
        # leaves it be); just don't start or restart it this scan.
        [[ -n "${MTIMES[$project_dir]:-}" ]] && ACTIVE["$project_dir"]=1
        echo "daemon.json missing: $project_dir (${absent_streak}/${DAEMON_JSON_ABSENCE_THRESHOLD}); deferring stop"
      elif [[ -n "${MTIMES[$project_dir]:-}" ]]; then
        echo "daemon.json removed: $project_dir (confirmed ${absent_streak}x) — stopping session"
        stop_session "$project_dir"
      fi
      continue
    fi
    ABSENT_STREAK["$project_dir"]=0

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

      # Adopt a newer claude version. A running process never upgrades in place, so when the on-disk
      # version differs from what this session launched with, restart it (history-preserving via
      # --resume) per the autoUpdate.restart policy. Skipped if the mtime restart above already
      # relaunched it (SESSION_VERSIONS is now disk_version) or the version is unknown (empty).
      if [[ "$(autoupdate_field "$project_dir" enabled false)" == "true" ]]; then
        restart_policy="$(autoupdate_field "$project_dir" restart when-idle)"
        sess_version="${SESSION_VERSIONS[$project_dir]:-}"
        if [[ "$restart_policy" != "never" && -n "$disk_version" && -n "$sess_version" \
              && "$disk_version" != "$sess_version" ]]; then
          if [[ "$restart_policy" == "immediate" ]] \
             || session_idle "$project_dir" "$(autoupdate_field "$project_dir" idleMinutes 5)"; then
            echo "Adopting claude $sess_version → $disk_version: $project_dir"
            stop_session "$project_dir"
            start_session "$project_dir"
          else
            echo "claude update pending ($sess_version → $disk_version), session busy: $project_dir"
          fi
        fi
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

  # ── Periodic leaked-process sweep (every ~SWEEP_EVERY polls ≈ 60s) ──────────────────────────────
  # stop_session already reaps on graceful stops/restarts. This catches the cases that never reach it:
  # a claude that crashed or was OOM-killed leaves tagged orphans behind. It also drives, on still-live
  # sessions, opt-in age-based reaping (reap_procs aged) and stalled/hung detection
  # (detect_stalled_for_session). Orphan reaping waits ORPHAN_SWEEP_THRESHOLD consecutive dead sweeps so
  # a transient tmux failure can't be mistaken for "the session died".
  sweep_counter=$(( sweep_counter + 1 ))
  if (( sweep_counter % SWEEP_EVERY == 0 )); then
    declare -A SID_TO_PROJECT LIVE_SIDS
    while IFS= read -r project_dir; do
      [[ -z "$project_dir" || ! -d "$project_dir" ]] && continue
      sid="$(session_id_for "$project_dir")"
      SID_TO_PROJECT["$sid"]="$project_dir"
      known="${SESSION_NAMES[$project_dir]:-}"
      [[ -z "$known" ]] && known="$(tmux_session_for "$project_dir")"
      tmux has-session -t "$known" 2>/dev/null && LIVE_SIDS["$sid"]=1
    done < "$PROJECTS_FILE"

    # Distinct DAEMON_SESSION_IDs present in any process environment right now. Other users' environ is
    # unreadable, so only our own tagged procs appear — an unreadable file simply drops out.
    while IFS= read -r sid; do
      [[ -z "$sid" ]] && continue
      proj="${SID_TO_PROJECT[$sid]:-}"
      if [[ -n "${LIVE_SIDS[$sid]:-}" ]]; then
        DEAD_SWEEPS["$sid"]=0
        reap_procs "$proj" "$sid" aged          # live owner → only over-age procs (opt-in)
        detect_stalled_for_session "$proj" "$sid"   # live owner → stalled/hung procs (opt-in)
      else
        DEAD_SWEEPS["$sid"]=$(( ${DEAD_SWEEPS[$sid]:-0} + 1 ))
        if (( ${DEAD_SWEEPS[$sid]} >= ORPHAN_SWEEP_THRESHOLD )); then
          reap_procs "$proj" "$sid" all         # no live owner → orphans, kill every tagged proc
        fi
      fi
    done < <(
      # grep opens each file itself (its own stderr → /dev/null), so an unreadable /proc entry is
      # silent. Piping `< "$e"` here instead would leak the shell's redirection error past 2>/dev/null
      # to journald for every foreign process — hundreds of lines a minute.
      for e in /proc/[0-9]*/environ; do
        grep -az '^DAEMON_SESSION_ID=' "$e" 2>/dev/null
      done | tr '\0' '\n' | sort -u | sed 's/^DAEMON_SESSION_ID=//'
    )
    unset SID_TO_PROJECT LIVE_SIDS

    # Prune stalled-tracking state for pids that no longer exist, so the maps don't grow unbounded.
    for gone in "${!PROC_STALL[@]}"; do
      [[ -d "/proc/$gone" ]] || unset "PROC_STALL[$gone]" "PROC_CPU[$gone]"
    done
  fi

  sleep "$POLL_INTERVAL"
done
