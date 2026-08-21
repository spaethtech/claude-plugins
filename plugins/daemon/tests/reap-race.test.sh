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
