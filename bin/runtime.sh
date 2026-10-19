# Shared startup for the popup. Sourced by manager.sh, also exercised offline.
is_windows() {
  case "${OSTYPE:-}" in msys*|cygwin*) return 0 ;; *) return 1 ;; esac
}

native_path() {
  if is_windows; then cygpath -u "$1"; else printf '%s\n' "$1"; fi
}

init_python() {
  # Probing executes Python: the Windows Store python3 alias exists on PATH
  # but cannot run scripts. PYTHONIOENCODING also prevents cp1252 output from
  # corrupting the UTF-8 TSV exchanged with the TUI.
  export PYTHONIOENCODING=utf-8
  local candidate
  for candidate in python3 python py; do
    if [ "$candidate" = py ]; then
      if py -3 -c 'import sys; sys.exit(sys.version_info.major != 3)' >/dev/null 2>&1; then
        pm_python=(py -3)
        return 0
      fi
    elif command "$candidate" -c 'import sys; sys.exit(sys.version_info.major != 3)' >/dev/null 2>&1; then
      pm_python=("$candidate")
      return 0
    fi
  done
  printf 'Plugin Manager requires Python 3 (python3, python, or py -3 on PATH).\n' >&2
  return 127
}

python3() {
  # Native Windows Python writes CRLF even to a pipe; TSV consumers require LF.
  command "${pm_python[@]}" "$@" | tr -d '\r'
}
