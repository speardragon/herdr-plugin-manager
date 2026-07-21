#!/usr/bin/env bash
# Restores the macOS input source once the popup process dies — by ANY path:
# q/Esc, herdr killing the pane, Ctrl-C, even SIGKILL. An EXIT/TERM trap in the
# popup can't cover all of those (bash defers trapped signals while blocked in
# a command-substitution read, and nothing survives SIGKILL), so a detached
# watchdog owns the restore instead.
#   $1 popup pid   $2 file the previous source id gets written to   $3 helper js
pid="$1"
prevfile="$2"
helper="$3"
prev=""
while kill -0 "$pid" 2>/dev/null; do
  [ -z "$prev" ] && prev="$(cat "$prevfile" 2>/dev/null)"
  sleep 0.3
done
[ -n "$prev" ] && exec osascript -l JavaScript "$helper" select "$prev"
exit 0
