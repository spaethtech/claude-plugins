#!/bin/bash
# Regression guard for the periodic-reaper sweep scanner.
#
# Bug fixed in 2.11.1: under `set -euo pipefail`, a bare `grep` in the sid scanner exited 1 on the first
# tag-less /proc entry and errexit aborted the whole enumeration inside its subshell — silently feeding
# the sweep an empty list, so periodic process reaping (aged / orphan / stalled) NEVER ran. This test
# asserts tagged_sids_present() still enumerates a live tagged session under the exact shell options
# service.sh runs with.
set -uo pipefail
SVC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/service.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

fn="$(awk '/^tagged_sids_present\(\) \{/{f=1} f{print} f&&/^\}/{exit}' "$SVC")"
[[ -n "$fn" ]] || fail "could not extract tagged_sids_present from $SVC"

sid="regress-$$-$(date +%s)"
DAEMON_SESSION_ID="$sid" sleep 30 &
bg=$!
trap 'kill "$bg" 2>/dev/null' EXIT
sleep 0.3

# Run the extracted scanner under the daemon's real options; it must NOT abort and MUST find the sid.
out="$(bash -c "set -euo pipefail; $fn; tagged_sids_present")"
grep -qxF "$sid" <<<"$out" || fail "scanner did not emit the live tagged sid '$sid'. Got: [${out//$'\n'/ }]"
echo "PASS: tagged_sids_present enumerates tagged sessions under set -euo pipefail"
