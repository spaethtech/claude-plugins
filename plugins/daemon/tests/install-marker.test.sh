#!/bin/bash
# Regression guard for the version-marker latch (bug fixed in 2.11.2).
#
# Old behaviour: setup.sh wrote $DATA_DIR/.version BEFORE running install.sh, so a failed install
# (e.g. missing prereq) latched the marker and the SessionStart hook never retried — the daemon was
# silently, permanently un-installed. Fix: install.sh writes the marker itself, only after prereqs pass
# and the unit is enabled, right before the self-killing restart.
#
# Asserts:
#   1. a SUCCESSFUL (fully stubbed) install writes .version = plugin version
#   2. a FAILED install (missing claude prereq) leaves .version UN-written  ← the latch regression
#   3. the marker write precedes `systemctl --user restart` in source  ← SIGTERM-during-restart stays advanced
set -uo pipefail
PLUGIN_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
pass=0; fail=0
ok()  { echo "PASS: $*"; pass=$((pass+1)); }
bad() { echo "FAIL: $*" >&2; fail=$((fail+1)); }

VER="$(grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' "$PLUGIN_DIR/.claude-plugin/plugin.json" | sed 's/.*"\([^"]*\)"$/\1/')"

# Hermetic sandbox: stub every external the installer touches so it runs to completion without a real
# systemd/sudo/package-manager, and without mutating the real user environment.
make_sandbox() {  # $1 = "with-claude" | "no-claude"
  local root; root="$(mktemp -d)"
  local bin="$root/bin"; mkdir -p "$bin" "$root/home" "$root/data"
  for t in systemctl tmux sudo apt-get; do printf '#!/bin/bash\nexit 0\n' > "$bin/$t"; chmod +x "$bin/$t"; done
  # loginctl must report linger already on, so the installer skips the sudo enable-linger path.
  printf '#!/bin/bash\necho "Linger=yes"\n' > "$bin/loginctl"; chmod +x "$bin/loginctl"
  [[ "$1" == "with-claude" ]] && { printf '#!/bin/bash\nexit 0\n' > "$bin/claude"; chmod +x "$bin/claude"; }
  echo "$root"
}

# --- Test 1: successful install advances the marker ---
root="$(make_sandbox with-claude)"
env -i PATH="$root/bin:/usr/bin:/bin" HOME="$root/home" USER="${USER:-tester}" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$root/data" \
    bash "$PLUGIN_DIR/install.sh" --quiet >/dev/null 2>&1
got="$(cat "$root/data/.version" 2>/dev/null || echo '<absent>')"
[[ "$got" == "$VER" ]] && ok "successful install wrote .version=$VER" || bad "expected .version=$VER, got [$got]"
# and it baked claude's dir into the unit PATH (bug 3)
grep -q "Environment=PATH=$root/bin:" "$root/home/.config/systemd/user/claude-daemon.service" 2>/dev/null \
  && ok "unit PATH includes claude's dir" || bad "unit PATH missing claude's dir"
grep -q '^SuccessExitStatus=143' "$root/home/.config/systemd/user/claude-daemon.service" 2>/dev/null \
  && ok "unit has SuccessExitStatus=143 (bug 4)" || bad "unit missing SuccessExitStatus=143"
rm -rf "$root"

# --- Test 2: failed install (no claude) must NOT advance the marker ---
root="$(make_sandbox no-claude)"
env -i PATH="$root/bin:/usr/bin:/bin" HOME="$root/home" USER="${USER:-tester}" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$root/data" \
    bash "$PLUGIN_DIR/install.sh" --quiet >/dev/null 2>&1
rc=$?
[[ $rc -ne 0 ]] && ok "install failed (rc=$rc) with claude missing" || bad "install should have failed with claude missing"
[[ ! -f "$root/data/.version" ]] && ok "failed install left .version un-written (no latch)" \
  || bad "LATCH REGRESSION: .version was written on a failed install ([$(cat "$root/data/.version")])"
# errors must reach stderr even under --quiet (bug 2)
err="$(env -i PATH="$root/bin:/usr/bin:/bin" HOME="$root/home" USER="${USER:-tester}" \
    CLAUDE_PLUGIN_ROOT="$PLUGIN_DIR" CLAUDE_PLUGIN_DATA="$root/data" \
    bash "$PLUGIN_DIR/install.sh" --quiet 2>&1 >/dev/null)"
grep -qi 'claude is not on PATH' <<<"$err" && ok "prereq error reached stderr under --quiet (bug 2)" \
  || bad "prereq error was swallowed under --quiet"
rm -rf "$root"

# --- Test 3: marker write precedes the restart in source (SIGTERM-during-restart stays advanced) ---
awk 'index($0,".version\"")>0 && /echo "\$EXPECTED_VERSION"/ {m=NR} /systemctl --user restart/ {r=NR} END{exit !(m>0 && r>0 && m<r)}' \
  "$PLUGIN_DIR/install.sh" && ok "marker write precedes systemctl restart" \
  || bad "marker write is not before the restart (SIGTERM could leave it un-advanced)"

echo "---"
echo "$pass passed, $fail failed"
[[ $fail -eq 0 ]]
