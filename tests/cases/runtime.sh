#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/../lib/harness.sh"
source "$root/bin/runtime.sh"
load_fns open_url

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
real_python="$(type -P python3 || type -P python)"
mkdir -p "$work/tools with spaces"
printf '#!/bin/sh\nexit 1\n' > "$work/tools with spaces/python3"
printf '#!/bin/sh\nexec "%s" "$@"\n' "$real_python" > "$work/tools with spaces/python"
chmod +x "$work/tools with spaces/"*
original_path="$PATH"
PATH="$work/tools with spaces:$PATH"
init_python
check 'broken python3 falls back to python' python "${pm_python[*]}"
check 'selected interpreter runs UTF-8 scripts' '플러그인 ✓' "$(python3 -c 'print("플러그인 ✓")')"
check 'Python output encoding is UTF-8' utf-8 "$PYTHONIOENCODING"
check 'CRLF output is normalized for TSV readers' row "$(python3 -c 'import sys; sys.stdout.write("row\r\n")')"

printf '#!/bin/sh\nexit 1\n' > "$work/tools with spaces/python"
printf '#!/bin/sh\n[ "$1" = -3 ] || exit 1\nshift\nexec "%s" "$@"\n' "$real_python" > "$work/tools with spaces/py"
chmod +x "$work/tools with spaces/py"
init_python
check 'Windows launcher fallback includes -3' 'py -3' "${pm_python[*]}"
check 'launcher runs scripts' 3 "$(python3 -c 'print(3)')"
printf '#!/bin/sh\nexit 1\n' > "$work/tools with spaces/py"
init_python 2> "$work/error"
check 'no working interpreter fails startup' 127 "$?"
error="$(cat "$work/error")"
explained=no
case "$error" in *'requires Python 3'*) explained=yes ;; esac
check 'missing Python explains the prerequisite' yes "$explained"
PATH="$original_path"

OSTYPE=msys
opened=''
python3() { opened="$3"; }
open() { opened=macos; }
xdg-open() { opened=linux; }
url='https://github.com/owner/repo/tree/main/subdir?a=1&b=2'
open_url "$url"
check 'Windows opener preserves the complete URL' "$url" "$opened"
OSTYPE=darwin
open_url "$url"
check 'Unix opener still uses open' macos "$opened"
check 'Unix paths retain spaces' '/tmp/plugin manager' "$(native_path '/tmp/plugin manager')"
report
