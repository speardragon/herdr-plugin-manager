#!/usr/bin/env bash
# Exercise the real detached-helper handshake and delivery after popup exit.
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
export PM_TEST_ROOT="$root" PM_TEST_WORK="$work"
mkdir -p "$work/path with spaces"
cat > "$work/path with spaces/herdr" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$PM_TEST_WORK/invoked"
EOF
chmod +x "$work/path with spaces/herdr"
cat > "$work/popup.sh" <<'EOF'
source "$PM_TEST_ROOT/tests/lib/harness.sh"
load_fns split_act invoke_action
flat=(a:0)
acts=($'example.plugin\topen\tOpen\tcommand')
sel=0
dry_run=0
herdr="$PM_TEST_WORK/path with spaces/herdr"
invoke_action
EOF
bash "$work/popup.sh"
check 'popup exits after helper detaches' 0 "$?"
waited=0
while [ ! -s "$work/invoked" ] && [ "$waited" -lt 50 ]; do
  sleep 0.1
  waited=$(( waited + 1 ))
done
check 'detached helper delivers the selected action' \
  'plugin action invoke example.plugin.open' "$(cat "$work/invoked" 2>/dev/null)"
report
