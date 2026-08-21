#!/bin/bash
# Regression guard for the reap_procs / detect_stalled_for_session set -e crash (fixed 2.12.0).
#
# Bug: `age=$(ps -o etimes= -p "$pid" ... | tr ...)` had no guard. When a tagged process exits between
# tagged_pids_for enumerating it and this ps, ps exits 1, pipefail propagates it, and set -e aborted the
# ENTIRE watcher (whose EXIT trap then killed every session). Fired constantly on busy sessions because
# Claude's own short-lived Bash-tool procs are tagged. Fix: `... | tr ... ) || continue`.
#
# This drives the REAL reap_procs (extracted from service.sh) in aged mode against a pid that is already
# dead — the exact race — under set -Eeuo pipefail, and asserts it does not abort.
set -uo pipefail
SVC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/service.sh"
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }
extract() { awk "/^$1\\(\\) \\{/{f=1} f{print} f&&/^\\}/{exit}" "$SVC"; }

# A pid that was real and is now definitely dead (reaped) → ps -p <pid> exits 1, like the race.
sh -c 'exit 0' & dead=$!; wait "$dead" 2>/dev/null || true

proj="$(mktemp -d)"; mkdir -p "$proj/.claude"
echo '{ "reapProcesses": { "maxAgeSeconds": 1 } }' > "$proj/.claude/daemon.json"   # aged reaping active

# --- Functional: reap_procs aged must survive a dead pid mid-sweep ---
harness="$(mktemp)"
{
  echo 'set -Eeuo pipefail'
  extract kill_gracefully
  extract reap_procs
  echo "tagged_pids_for() { echo $dead; }"       # stub: emit the already-dead pid
  echo "reap_procs '$proj' testsid aged"
} > "$harness"
if bash "$harness"; then
  ok "reap_procs aged survives a pid that exited mid-sweep (no set -e abort)"
else
  bad "reap_procs aborted on a dead pid (rc=$?) — the crash is back"
fi
rm -f "$harness"; rm -rf "$proj"

# --- Functional: reap_procs must survive with NO tmux server (the live_panes crash) ---
# stop_session kills the last session → tmux server exits → `tmux list-panes -a` returns non-zero →
# without `|| true` set -e aborts the watcher on the very next daemon.json edit.
proj="$(mktemp -d)"; mkdir -p "$proj/.claude"; echo '{}' > "$proj/.claude/daemon.json"
harness="$(mktemp)"
{
  echo 'set -Eeuo pipefail'
  echo 'tmux() { return 1; }'                        # simulate: no tmux server (list-panes fails)
  extract kill_gracefully
  extract reap_procs
  echo 'tagged_pids_for() { :; }'                    # no tagged pids; we only exercise the live_panes line
  echo "reap_procs '$proj' testsid all"
} > "$harness"
if bash "$harness"; then
  ok "reap_procs survives with no tmux server (live_panes guarded)"
else
  bad "reap_procs aborted with no tmux server (rc=$?) — live_panes crash is back"
fi
rm -f "$harness"; rm -rf "$proj"

# --- Structural: every tmux list-panes site is guarded with || true ---
lp_unguarded="$(grep -n 'tmux list-panes' "$SVC" | grep -v '|| true' || true)"
[[ -z "$lp_unguarded" ]] && ok "all tmux list-panes sites are guarded with || true" \
  || bad "unguarded tmux list-panes site(s):"$'\n'"$lp_unguarded"

# --- Structural: jq preflight present ---
grep -q 'FATAL.*jq not found' "$SVC" && ok "jq runtime preflight present" || bad "missing jq preflight"

# --- Structural: tmux new-session is guarded (collision must not abort the watcher) ---
grep -q 'if ! tmux new-session' "$SVC" && ok "tmux new-session is guarded (if !)" \
  || bad "tmux new-session is unguarded (a sessionName collision would crash the watcher)"

# --- Structural: no bare stat on daemon.json (race during edits must not abort) ---
bare_stat="$(grep -n 'stat -c %Y "\$daemon_json"' "$SVC" | grep -vE '2>/dev/null|return 1' || true)"
[[ -z "$bare_stat" ]] && ok "all stat on daemon.json are guarded" \
  || bad "unguarded stat on daemon.json:"$'\n'"$bare_stat"

# --- Behavioral: tagged_pids_for's return status must not trip the ERR trap (2.12.4) ---
# It communicates via stdout; its last loop iteration's grep exits 1 (no match) or 2 (unreadable
# environ — another uid's process), which would leak out through `done < <(tagged_pids_for)` and fire
# the errtrace ERR trap every sweep. Assert it returns 0 and trips no trap.
sentinel="$(mktemp -u)"; h="$(mktemp)"
{
  echo 'set -Eeuo pipefail'
  echo "trap 'touch \"$sentinel\"' ERR"
  extract tagged_pids_for
  echo 'while IFS= read -r _; do :; done < <(tagged_pids_for no-such-sid-xyz)'
  echo 'tagged_pids_for no-such-sid-xyz >/dev/null; echo rc=$?'
} > "$h"
out="$(bash "$h" 2>/dev/null)"; rm -f "$h"
[[ "$out" == "rc=0" ]] && ok "tagged_pids_for returns 0 on no-match / unreadable environ" \
  || bad "tagged_pids_for returned non-zero: [$out]"
[[ ! -e "$sentinel" ]] && ok "tagged_pids_for via <() does not trip the ERR trap" \
  || bad "tagged_pids_for tripped the ERR trap (return-status leak)"
rm -f "$sentinel"

# --- Structural: stdout-emitting helpers pin their status with an explicit return 0 ---
for fn in tagged_pids_for tagged_sids_present session_id_for tmux_session_for remote_label_for; do
  awk "/^$fn\\(\\) \\{/{f=1} f{print} f&&/^\\}/{exit}" "$SVC" | grep -q 'return 0' \
    && ok "$fn pins 'return 0'" || bad "$fn is missing an explicit 'return 0'"
done

# --- Structural: every ps -o etimes call site is guarded with || continue ---
unguarded="$(grep -n 'ps -o etimes' "$SVC" | grep -v '|| continue' || true)"
if [[ -z "$unguarded" ]]; then
  ok "all ps -o etimes sites are guarded with || continue"
else
  bad "unguarded ps -o etimes site(s):"$'\n'"$unguarded"
fi

# --- Structural: the watcher installs an ERR breadcrumb trap under errtrace ---
grep -q 'set -Eeuo pipefail' "$SVC" && grep -q "trap .*ERR" "$SVC" \
  && ok "errtrace + ERR breadcrumb trap present" || bad "missing errtrace/ERR trap hardening"

echo "---"; echo "$pass passed, $fail failed"; [[ $fail -eq 0 ]]
