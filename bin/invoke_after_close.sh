#!/usr/bin/env bash
# Fires a plugin action once the popup is gone. Invoking from inside the popup
# fails for anything that opens UI (ui_busy / popup already open), so the TUI
# spawns this detached (own session, like restore_watchdog.sh), exits to close
# the popup, and the invoke happens right after — with retries, because herdr
# takes a beat to return to the normal workspace view.
#   $1 popup pid   $2 herdr binary   $3 full action id (plugin.action)
pid="$1"
herdr="$2"
action="$3"
while kill -0 "$pid" 2>/dev/null; do sleep 0.1; done
for _ in 1 2 3 4 5 6 7 8 9 10; do
  out="$("$herdr" plugin action invoke "$action" 2>&1)" && exit 0
  case "$out" in
    *ui_busy*|*"popup already open"*) sleep 0.2 ;;
    *) exit 1 ;;
  esac
done
exit 1
