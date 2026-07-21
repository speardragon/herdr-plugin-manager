#!/usr/bin/env bash
# herdr Plugin Manager — popup TUI over the `herdr plugin` CLI.
#
# Keys: j/k or ↑/↓ move · i install · u update · e enable/disable · x uninstall
#       o open repo in browser · c edit plugins.json in VS Code · m marketplace
#       r refresh · q/Esc quit
# Marketplace view (m): browses GitHub repos tagged `herdr-plugin` (the same
# index behind https://herdr.dev/plugins/); Enter installs the selection.
#
# A ● dot is green when the plugin is up to date, yellow when a newer commit is
# available on its GitHub source. The update check runs once when the popup
# opens (list paints first, dots settle ~0.5s later) and again after any change.
#
# HERDR_PM_DRY_RUN=1 prints mutating commands instead of running them.
#
# Targets bash 3.2 (macOS default). The herdr popup's stdin returns EOF from a
# timed read (`read -t`) when idle instead of blocking, so the main input read
# MUST be blocking; only the short escape-sequence continuation uses `-t`, where
# that same immediate-return behavior is exactly what distinguishes a bare Esc
# from an arrow key.
set -uo pipefail

herdr="${HERDR_BIN_PATH:-herdr}"
root="${HERDR_PLUGIN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
dry_run="${HERDR_PM_DRY_RUN:-0}"
plugins_json="$(dirname "${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}")/plugins.json"

rows=()
sel=0
msg=""
checked=0

# Marketplace state (m key). Same index that powers https://herdr.dev/plugins/.
# The result set is browsed in display pages of MARKET_VIS items (←/→), backed
# by sparse API pages of market_per_page fetched on demand. `/` re-queries the
# GitHub Search API with extra terms; `s` toggles the sort. per_page is
# overridable for tests.
MARKET_VIS=10
market_per_page="${HERDR_PM_MARKET_PER_PAGE:-50}"
view="main"
mrows=()           # sparse: mrows[global_index]
msel=0             # selected global index into the result set
mpg=0              # current display page, 0-based
market_loaded=0
m_total=0          # API total_count for the current query
m_query=""         # extra search terms ('' = whole topic)
m_sort="stars"     # stars | updated
m_pages_fetched=" "  # " 1 2 " — API pages already stored

have_git=0
command -v git >/dev/null 2>&1 && have_git=1
tmpdir="$(mktemp -d "${TMPDIR:-/tmp}/herdr-pm.XXXXXX")"
statusfile="$tmpdir/status"
: > "$statusfile"

bold="$(tput bold 2>/dev/null || true)"
dim="$(tput dim 2>/dev/null || true)"
red="$(tput setaf 1 2>/dev/null || true)"
green="$(tput setaf 2 2>/dev/null || true)"
yellow="$(tput setaf 3 2>/dev/null || true)"
cyan="$(tput setaf 6 2>/dev/null || true)"
reset="$(tput sgr0 2>/dev/null || true)"

# Like herdr's switch_ascii_input_source_in_prefix: when the popup opens on a
# non-ASCII input source (e.g. Korean IME), hop to the last-used ASCII layout so
# the single-key TUI works immediately, and restore the original source when the
# popup closes. macOS only; disable with HERDR_PM_ASCII_INPUT=0.
#
# Both helpers run detached (nohup, stdio off the pty) — the switch so it never
# delays the first paint, and the restore as a watchdog on this process's pid,
# because no trap fires reliably for every way a popup can die (bash holds
# trapped signals while blocked in the command-substitution read, and SIGKILL
# reaches nothing at all).
start_ascii_input() {
  [ "${HERDR_PM_ASCII_INPUT:-1}" = 1 ] || return 0
  [ "$(uname)" = Darwin ] && command -v osascript >/dev/null 2>&1 || return 0
  ( nohup osascript -l JavaScript "$root/bin/input_source.js" switch-ascii \
      > "$tmpdir/prev-input" 2>/dev/null < /dev/null & ) 2>/dev/null
  ( nohup bash "$root/bin/restore_watchdog.sh" "$$" "$tmpdir/prev-input" \
      "$root/bin/input_source.js" >/dev/null 2>&1 < /dev/null & ) 2>/dev/null
}

cleanup() { printf '\033[?25h'; rm -rf "$tmpdir" 2>/dev/null || true; }
trap cleanup EXIT

# Sets r_id r_name r_ver r_en r_kind r_spec r_commit r_slug r_ref r_full.
split_row() {
  local IFS=$'\t'
  read -r r_id r_name r_ver r_en r_kind r_spec r_commit r_slug r_ref r_full <<< "$1"
}

load_plugins() {
  local json line
  json="$("$herdr" plugin list --json 2>/dev/null)" || json=""
  rows=()
  if [ -n "$json" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] && rows+=("$line")
    done < <(printf '%s' "$json" | python3 "$root/bin/parse_list.py" 2>/dev/null)
  fi
  local last=$(( ${#rows[@]} - 1 ))
  [ "$sel" -gt "$last" ] && sel=$last
  [ "$sel" -lt 0 ] && sel=0
}

# ── update checking ─────────────────────────────────────────────────────────

# Compares one plugin's pinned sha against its remote ref, echoing the status
# word (current|update|error). Standalone so it can be unit-tested.
#   $1 repo_slug (owner/repo)  $2 ref (or "-"/"")  $3 full pinned commit
check_remote() {
  local slug="$1" ref="$2" commit="$3" target shas
  target="$ref"
  { [ -z "$target" ] || [ "$target" = "-" ]; } && target="HEAD"
  # perl's alarm hard-caps the whole ls-remote at 8s — git's LOW_SPEED vars only
  # cover the transfer phase, so a stalled connect could otherwise freeze the
  # popup for minutes while the startup check blocks the input loop.
  shas="$(GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=5 \
    perl -e 'alarm 8; exec @ARGV' -- \
    git ls-remote "https://github.com/$slug" "$target" 2>/dev/null | cut -f1)"
  if [ -z "$shas" ]; then
    printf 'error'
  elif printf '%s\n' "$shas" | grep -qx "$commit"; then
    printf 'current'
  else
    printf 'update'
  fi
}

# Checks every github plugin in parallel, writing "<id>\t<status>" lines. Blocks
# until all checks return (~0.5s); the popup's list is already painted by then.
run_update_checks() {
  checked=0
  : > "$statusfile"
  if [ "$have_git" != 1 ]; then
    checked=1
    return
  fi
  local line c_id c_name c_ver c_en c_kind c_spec c_commit c_slug c_ref c_full
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r c_id c_name c_ver c_en c_kind c_spec c_commit c_slug c_ref c_full <<< "$line"
    [ "$c_kind" = github ] || continue
    (
      trap - EXIT INT TERM  # don't let a worker subshell run the parent cleanup
      printf '%s\t%s\n' "$c_id" "$(check_remote "$c_slug" "$c_ref" "$c_full")" >> "$statusfile"
    ) &
  done
  wait
  checked=1
}

plugin_status() {
  [ -s "$statusfile" ] || return 0
  awk -F'\t' -v id="$1" '$1==id{print $2; exit}' "$statusfile" 2>/dev/null
}

check_footer() {
  [ "${#rows[@]}" -gt 0 ] || return 0
  if [ "$have_git" != 1 ]; then
    put '  %binstall git to check for updates%b\n' "$dim" "$reset"
    return 0
  fi
  if [ "$checked" != 1 ]; then
    put '  %bchecking for updates…%b\n' "$dim" "$reset"
    return 0
  fi
  local n
  n="$(awk -F'\t' '$2=="update"{c++} END{print c+0}' "$statusfile" 2>/dev/null)"
  if [ "${n:-0}" -gt 0 ]; then
    put '  %b↑ %s update(s) available — press u to update%b\n' "$yellow" "$n" "$reset"
  else
    put '  %ball plugins up to date%b\n' "$dim" "$reset"
  fi
}

# ── rendering ────────────────────────────────────────────────────────────────

# Flicker-free frames: compose into a buffer, then emit in ONE write that homes
# the cursor and overwrites in place — each line erases its own tail (\033[K)
# and the frame erases below itself (\033[J). Never a full-screen clear
# (\033[2J), which blanks the terminal for a frame and causes flicker.
buf=""
put() { local s; printf -v s "$@"; buf+="$s"; }
draw_flush() {
  buf="${buf//$'\n'/$'\033[K\n'}"
  printf '\033[H\033[?25l%s\033[K\033[J' "$buf"
  buf=""
}

draw() {
  buf=""
  put '  %bherdr Plugin Manager%b' "$bold" "$reset"
  [ "$dry_run" = 1 ] && put '  %b[dry-run]%b' "$yellow" "$reset"
  put '\n\n'

  if [ ${#rows[@]} -eq 0 ]; then
    put '  %bno plugins installed — press i to install one%b\n' "$dim" "$reset"
  else
    local max_vis=10 start=0 end i
    [ "$sel" -ge "$max_vis" ] && start=$(( sel - max_vis + 1 ))
    end=$(( start + max_vis - 1 ))
    [ "$end" -ge ${#rows[@]} ] && end=$(( ${#rows[@]} - 1 ))
    i=$start
    while [ "$i" -le "$end" ]; do
      split_row "${rows[$i]}"
      local status dot state="" cursor="  " pre="" post=""
      status="$(plugin_status "$r_id")"
      if [ "$r_en" = 0 ]; then
        dot="${dim}○${reset}"
        state="  ${dim}(disabled)${reset}"
      elif [ "$status" = update ]; then
        dot="${yellow}●${reset}"
        state="  ${yellow}↑ update${reset}"
      else
        dot="${green}●${reset}"
      fi
      if [ "$i" -eq "$sel" ]; then
        cursor="${cyan}▸ ${reset}"
        pre="$bold" post="$reset"
      fi
      put '  %b%b %b%-26.26s %-8.8s%b%b\n' \
        "$cursor" "$dot" "$pre" "$r_name" "$r_ver" "$post" "$state"
      i=$(( i + 1 ))
    done
    put '\n'
    split_row "${rows[$sel]}"
    local src="$r_spec"
    [ "$r_ref" != "-" ] && src="$src ($r_ref)"
    [ "$r_kind" = local ] && src="local link"
    [ "$r_commit" != "-" ] && src="$src @$r_commit"
    put '  %b──────────────────────────────────────────────────────────%b\n' "$dim" "$reset"
    put '  %bid%b      %s\n' "$dim" "$reset" "$r_id"
    put '  %bsource%b  %-60.60s\n' "$dim" "$reset" "$src"
    [ "$(plugin_status "$r_id")" = update ] && \
      put '  %b↑ newer commit available — press u to install it%b\n' "$yellow" "$reset"
  fi

  put '\n'
  put '  %bj/k or ↑/↓ move · i install · u update · e enable/disable%b\n' "$dim" "$reset"
  put '  %bo repo in browser · c edit plugins.json · x uninstall%b\n' "$dim" "$reset"
  put '  %bm marketplace · r refresh · q quit%b\n' "$dim" "$reset"
  check_footer
  [ -n "$msg" ] && put '\n  %b\n' "$msg"
  draw_flush
}

# ── input ────────────────────────────────────────────────────────────────────

# Echoes a token: a literal key char, "up"/"down", "enter", "noop" (ignored
# escape sequence), or "q" (bare Esc / EOF). The first byte is read blocking.
# After an ESC, arrow continuation bytes are already buffered and come back
# instantly; only a bare Esc has to wait out the disambiguation timer. bash 3.2
# caps `read -t` at whole seconds (a full 1s pause before an Esc quit closed
# the popup), so the timer is VMIN=0/VTIME=1 at the tty layer instead — the dd
# returns within ~0.1s when no bytes follow.
read_key() {
  local k rest='' saved=''
  IFS= read -rsn1 k || { printf 'q'; return; }
  [ -z "$k" ] && { printf 'enter'; return; }
  if [ "$k" = $'\e' ]; then
    if saved="$(stty -g 2>/dev/null)" && [ -n "$saved" ]; then
      stty -icanon -echo min 0 time 1 2>/dev/null
      rest="$(dd bs=2 count=1 2>/dev/null)"
      stty "$saved" 2>/dev/null
    else
      IFS= read -rsn2 -t 1 rest || true
    fi
    case "$rest" in
      '[A'|'OA') printf 'up' ;;
      '[B'|'OB') printf 'down' ;;
      '[C'|'OC') printf 'right' ;;
      '[D'|'OD') printf 'left' ;;
      '') printf 'q' ;;
      *) printf 'noop' ;;
    esac
  else
    printf '%s' "$k"
  fi
}

pause_key() {
  printf '\n  %bpress any key%b' "$dim" "$reset"
  IFS= read -rsn1 || true
}

# Runs a quick mutating command (toggle/uninstall) silently — the herdr CLI
# replies with a JSON blob that is pure noise in a popup, so success becomes a
# one-line msg and the refreshed list (●/○) is the real feedback. No pause.
#   $1 = success message, rest = herdr args
run_quiet() {
  local ok_msg="$1" out line
  shift
  if [ "$dry_run" = 1 ]; then
    local shown=""
    printf -v shown ' %q' "$@"
    msg="${yellow}[dry-run]${reset} $herdr$shown"
    return
  fi
  out="$("$herdr" "$@" 2>&1)"
  if [ $? -eq 0 ]; then
    msg="${green}✓${reset} $ok_msg"
  else
    line="$(printf '%s\n' "$out" | grep -m1 . | cut -c1-58)"
    msg="${red}✗ failed${reset}${line:+ — $line}"
  fi
  load_plugins
}

# Runs (or dry-run prints) a long mutating command (install/update) with output
# streamed — clone/build progress is worth watching — then refreshes + checks.
run_mut() {
  local status=0
  printf '\n'
  if [ "$dry_run" = 1 ]; then
    printf '  %b[dry-run]%b %s' "$yellow" "$reset" "$herdr"
    printf ' %q' "$@"
    printf '\n'
  else
    "$herdr" "$@" 2>&1 | sed 's/^/  /'
    status=${PIPESTATUS[0]}
    if [ "$status" -eq 0 ]; then
      printf '\n  %b✓ done%b\n' "$green" "$reset"
    else
      printf '\n  %b✗ failed (exit %s)%b\n' "$red" "$status" "$reset"
    fi
  fi
  pause_key
  load_plugins
  run_update_checks
}

prompt_line() {
  printf '\033[?25h'
  IFS= read -e -r -p "$1" REPLY || REPLY=""
  printf '\033[?25l'
}

do_install() {
  printf '\n'
  prompt_line "  install owner/repo[/subdir]: "
  local spec="$REPLY"
  if [ -z "$spec" ]; then
    msg="${dim}install cancelled${reset}"
    return
  fi
  prompt_line "  git ref (Enter = default branch): "
  local ref="$REPLY"
  local args=(plugin install "$spec")
  [ -n "$ref" ] && args+=(--ref "$ref")
  args+=(--yes)
  run_mut "${args[@]}"
}

do_update() {
  [ ${#rows[@]} -eq 0 ] && return
  split_row "${rows[$sel]}"
  if [ "$r_kind" != github ]; then
    msg="${yellow}'$r_name' is a $r_kind plugin — update it from its own checkout${reset}"
    return
  fi
  # No dedicated update command: re-installing moves the sha pin to latest.
  run_mut plugin install "$r_spec" --yes
}

do_toggle() {
  [ ${#rows[@]} -eq 0 ] && return
  split_row "${rows[$sel]}"
  if [ "$r_en" = 1 ]; then
    run_quiet "disabled $r_name" plugin disable "$r_id"
  else
    run_quiet "enabled $r_name" plugin enable "$r_id"
  fi
}

do_uninstall() {
  [ ${#rows[@]} -eq 0 ] && return
  split_row "${rows[$sel]}"
  local verb=uninstall
  [ "$r_kind" = local ] && verb=unlink
  printf '\n  %b%s %s (%s)? [y/N]%b ' "$red" "$verb" "$r_name" "$r_id" "$reset"
  local k=""
  IFS= read -rsn1 k || true
  case "$k" in
    y|Y) run_quiet "${verb}ed $r_name" plugin "$verb" "$r_id" ;;
    *) msg="${dim}$verb cancelled${reset}" ;;
  esac
}

# Opens a URL in the default browser. macOS `open`, else Linux `xdg-open`.
open_url() {
  if command -v open >/dev/null 2>&1; then
    open "$1" >/dev/null 2>&1
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$1" >/dev/null 2>&1
  else
    return 127
  fi
}

# c — open the global plugins registry (~/.config/herdr/plugins.json) in VS Code.
do_plugins_json() {
  if [ ! -f "$plugins_json" ]; then
    msg="${red}not found: $plugins_json${reset}"
    return
  fi
  if [ "$dry_run" = 1 ]; then
    msg="${yellow}[dry-run]${reset} code $plugins_json"
    return
  fi
  if ! command -v code >/dev/null 2>&1; then
    msg="${red}'code' CLI not found — run 'Install code command' in VS Code${reset}"
    return
  fi
  if code "$plugins_json" >/dev/null 2>&1; then
    msg="${green}opened${reset} $plugins_json"
  else
    msg="${red}failed to launch VS Code${reset}"
  fi
}

# o — open the selected plugin's GitHub repo in the browser (subdir plugins open
# the subdir at the installed commit; local plugins have no remote).
do_open_repo() {
  [ ${#rows[@]} -eq 0 ] && return
  split_row "${rows[$sel]}"
  if [ "$r_kind" != github ] || [ "$r_slug" = "-" ]; then
    msg="${yellow}'$r_name' has no GitHub repo (source: $r_kind)${reset}"
    return
  fi
  local url="https://github.com/$r_slug" subdir rev
  if [ "$r_spec" != "$r_slug" ]; then
    subdir="${r_spec#"$r_slug"/}"
    rev="$r_full"
    [ "$rev" = "-" ] && rev="$r_ref"
    [ "$rev" = "-" ] && rev="HEAD"
    url="https://github.com/$r_slug/tree/$rev/$subdir"
  fi
  if [ "$dry_run" = 1 ]; then
    msg="${yellow}[dry-run]${reset} open $url"
    return
  fi
  if open_url "$url"; then
    msg="${green}opened${reset} $url"
  else
    msg="${red}no browser opener (open/xdg-open) found${reset}"
  fi
}

# ── marketplace view ─────────────────────────────────────────────────────────

# Sets m_name m_stars m_desc from one marketplace TSV row.
split_mrow() {
  local IFS=$'\t'
  read -r m_name m_stars m_desc <<< "$1"
}

market_url() {
  local q="topic:herdr-plugin" enc
  if [ -n "$m_query" ]; then
    enc="$(python3 -c 'import sys, urllib.parse as u; print(u.quote_plus(sys.argv[1]))' "$m_query" 2>/dev/null)" || enc=""
    [ -n "$enc" ] && q="${q}+${enc}"
  fi
  printf 'https://api.github.com/search/repositories?q=%s&sort=%s&order=desc&per_page=%s&page=%s' \
    "$q" "$m_sort" "$market_per_page" "$1"
}

# Drops all fetched results (query/sort unchanged) so the next fetch starts over.
market_reset() {
  mrows=()
  m_pages_fetched=" "
  m_total=0
  msel=0
  mpg=0
  market_loaded=0
}

# GitHub search serves at most 1000 results; browse within that.
display_total() {
  local t="${m_total:-0}"
  [ "$t" -gt 1000 ] && t=1000
  printf '%s' "$t"
}

# Fetches one API page into its sparse slots (no-op when already stored).
# A page with zero rows is still a success as long as #total arrived — a narrow
# query can legitimately match nothing.
fetch_market_page() {
  local page="$1" json line base n=0 saw_total=0
  case "$m_pages_fetched" in *" $page "*) return 0 ;; esac
  buf=""
  put '\n  %bfetching…%b\n' "$dim" "$reset"
  draw_flush
  json="$(curl -s --max-time 8 -H 'Accept: application/vnd.github+json' "$(market_url "$page")" 2>/dev/null)" || json=""
  base=$(( (page - 1) * market_per_page ))
  if [ -n "$json" ]; then
    while IFS= read -r line; do
      case "$line" in
        '') ;;
        '#total'*) m_total="${line##*$'\t'}"; saw_total=1 ;;
        *) mrows[$(( base + n ))]="$line"; n=$(( n + 1 )) ;;
      esac
    done < <(printf '%s' "$json" | python3 "$root/bin/parse_market.py" 2>/dev/null)
  fi
  if [ "$saw_total" = 0 ]; then
    msg="${red}marketplace fetch failed — offline or GitHub rate limit, try again later${reset}"
    return 1
  fi
  m_pages_fetched="${m_pages_fetched}${page} "
  market_loaded=1
  return 0
}

# Makes sure every API page covering global indexes lo..hi is stored.
ensure_range() {
  local lo="$1" hi="$2" p last
  p=$(( lo / market_per_page + 1 ))
  last=$(( hi / market_per_page + 1 ))
  while [ "$p" -le "$last" ]; do
    fetch_market_page "$p" || return 1
    p=$(( p + 1 ))
  done
}

# Moves the cursor to a global index (wrapping at either end), fetching the
# backing API page first so a failed fetch leaves the cursor where it was.
goto_idx() {
  local idx="$1" total
  total="$(display_total)"
  [ "$total" -eq 0 ] && return 1
  [ "$idx" -lt 0 ] && idx=$(( total - 1 ))
  [ "$idx" -ge "$total" ] && idx=0
  ensure_range "$idx" "$idx" || return 1
  [ -n "${mrows[$idx]:-}" ] || return 1
  msel="$idx"
  mpg=$(( msel / MARKET_VIS ))
}

# Flips to a display page (wrapping), landing the cursor on its first item.
goto_page() {
  local p="$1" total pages
  total="$(display_total)"
  [ "$total" -eq 0 ] && return 1
  pages=$(( (total + MARKET_VIS - 1) / MARKET_VIS ))
  [ "$p" -lt 0 ] && p=$(( pages - 1 ))
  [ "$p" -ge "$pages" ] && p=0
  goto_idx $(( p * MARKET_VIS ))
}

# True when owner/repo matches the source slug of an installed plugin.
market_installed() {
  local line c_id c_name c_ver c_en c_kind c_spec c_commit c_slug c_ref c_full
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r c_id c_name c_ver c_en c_kind c_spec c_commit c_slug c_ref c_full <<< "$line"
    [ "$c_slug" = "$1" ] && return 0
  done
  return 1
}

# "‹ 1 … 4 [5] 6 … 29 ›" — the current display page among all of them.
put_pagebar() {
  local total="$1" pages cur i lo hi
  pages=$(( (total + MARKET_VIS - 1) / MARKET_VIS ))
  [ "$pages" -le 1 ] && return 0
  cur=$(( mpg + 1 ))
  lo=$(( cur - 2 )); hi=$(( cur + 2 ))
  [ "$lo" -lt 1 ] && lo=1
  [ "$hi" -gt "$pages" ] && hi="$pages"
  put '  %b‹%b ' "$dim" "$reset"
  if [ "$lo" -gt 1 ]; then
    put '%b1%b ' "$dim" "$reset"
    [ "$lo" -gt 2 ] && put '%b…%b ' "$dim" "$reset"
  fi
  i=$lo
  while [ "$i" -le "$hi" ]; do
    if [ "$i" -eq "$cur" ]; then
      put '%b[%d]%b ' "$cyan" "$i" "$reset"
    else
      put '%b%d%b ' "$dim" "$i" "$reset"
    fi
    i=$(( i + 1 ))
  done
  if [ "$hi" -lt "$pages" ]; then
    [ "$hi" -lt $(( pages - 1 )) ] && put '%b…%b ' "$dim" "$reset"
    put '%b%d%b ' "$dim" "$pages" "$reset"
  fi
  put '%b›%b\n' "$dim" "$reset"
}

draw_market() {
  buf=""
  local total label
  total="$(display_total)"
  label="topic:herdr-plugin"
  [ -n "$m_query" ] && label="\"$m_query\""
  put '  %bherdr marketplace%b  %b%s · by %s%b' \
    "$bold" "$reset" "$dim" "$label" "$m_sort" "$reset"
  [ "$dry_run" = 1 ] && put '  %b[dry-run]%b' "$yellow" "$reset"
  put '\n\n'

  if [ "$total" -eq 0 ]; then
    if [ "$market_loaded" = 1 ]; then
      put '  %bno results — / to change the search, q to go back%b\n' "$dim" "$reset"
    else
      put '  %bnothing loaded — press r to retry%b\n' "$dim" "$reset"
    fi
  else
    local start=$(( mpg * MARKET_VIS )) end i
    end=$(( start + MARKET_VIS - 1 ))
    [ "$end" -ge "$total" ] && end=$(( total - 1 ))
    i=$start
    while [ "$i" -le "$end" ]; do
      if [ -z "${mrows[$i]:-}" ]; then
        put '      %b…%b\n' "$dim" "$reset"
      else
        split_mrow "${mrows[$i]}"
        local cursor="  " pre="" post="" mark="  "
        market_installed "$m_name" && mark="${green}✓ ${reset}"
        if [ "$i" -eq "$msel" ]; then
          cursor="${cyan}▸ ${reset}"
          pre="$bold" post="$reset"
        fi
        put '  %b%b%b%-42.42s %b★ %-5s%b%b\n' \
          "$cursor" "$mark" "$pre" "$m_name" "$yellow" "$m_stars" "$reset" "$post"
      fi
      i=$(( i + 1 ))
    done
    put '\n'
    if [ -n "${mrows[$msel]:-}" ]; then
      split_mrow "${mrows[$msel]}"
      put '  %b──────────────────────────────────────────────────────────%b\n' "$dim" "$reset"
      put '  %b%d/%d%b  %-56.56s\n' "$dim" "$(( msel + 1 ))" "$total" "$reset" "$m_desc"
      if market_installed "$m_name"; then
        put '  %b✓ already installed%b\n' "$green" "$reset"
      else
        put '  %bEnter installs github.com/%s%b\n' "$dim" "$m_name" "$reset"
      fi
    fi
    put_pagebar "$total"
  fi

  put '\n'
  put '  %bj/k move · ←/→ page · Enter install · o repo in browser%b\n' "$dim" "$reset"
  put '  %b/ search · s sort · r refresh · q back%b\n' "$dim" "$reset"
  [ -n "$msg" ] && put '\n  %b\n' "$msg"
  draw_flush
}

# / — re-query the API with extra search terms (matches name/description/readme
# across the whole topic, not just the loaded rows). Empty input goes back to
# the unfiltered topic listing.
m_search() {
  printf '\n'
  prompt_line "  search (empty = all): "
  m_query="$REPLY"
  market_reset
  fetch_market_page 1 || true
}

# s — flip the API sort between most-starred and most-recently-updated.
m_sort_toggle() {
  if [ "$m_sort" = stars ]; then m_sort="updated"; else m_sort="stars"; fi
  market_reset
  fetch_market_page 1 || true
}

m_install() {
  [ -n "${mrows[$msel]:-}" ] || return 0
  split_mrow "${mrows[$msel]}"
  if market_installed "$m_name"; then
    msg="${green}$m_name is already installed${reset} — update it from the main list (u)"
    return
  fi
  run_mut plugin install "$m_name" --yes
}

m_open_repo() {
  [ -n "${mrows[$msel]:-}" ] || return 0
  split_mrow "${mrows[$msel]}"
  local url="https://github.com/$m_name"
  if [ "$dry_run" = 1 ]; then
    msg="${yellow}[dry-run]${reset} open $url"
    return
  fi
  if open_url "$url"; then
    msg="${green}opened${reset} $url"
  else
    msg="${red}no browser opener (open/xdg-open) found${reset}"
  fi
}

# ── main loop ────────────────────────────────────────────────────────────────

# Test hook: `manager.sh --self-test <slug> <ref> <commit>` prints the update
# status for one plugin and exits — checks the comparison logic without a popup.
if [ "${1:-}" = "--self-test" ]; then
  check_remote "${2:-}" "${3:--}" "${4:-}"
  echo
  exit 0
fi

start_ascii_input
load_plugins
draw                 # paint the list immediately …
run_update_checks    # … then block ~0.5s resolving update status …
draw                 # … and repaint with the green/yellow dots.
while true; do
  key="$(read_key)"
  [ "$key" = noop ] && continue
  msg=""
  if [ "$view" = market ]; then
    case "$key" in
      j|down) goto_idx $(( msel + 1 )) || true ;;
      k|up)   goto_idx $(( msel - 1 )) || true ;;
      right|l|L) goto_page $(( mpg + 1 )) || true ;;
      left|h|H)  goto_page $(( mpg - 1 )) || true ;;
      enter|i|I) m_install ;;
      o|O) m_open_repo ;;
      /) m_search ;;
      s|S) m_sort_toggle ;;
      r|R) market_reset; fetch_market_page 1 || true ;;
      m|M|q|Q) view=main ;;
      *) continue ;;
    esac
  else
    case "$key" in
      j|down) [ ${#rows[@]} -gt 0 ] && sel=$(( (sel + 1) % ${#rows[@]} )) ;;
      k|up)   [ ${#rows[@]} -gt 0 ] && sel=$(( (sel - 1 + ${#rows[@]}) % ${#rows[@]} )) ;;
      i|I) do_install ;;
      u|U) do_update ;;
      e|E) do_toggle ;;
      x|X) do_uninstall ;;
      o|O) do_open_repo ;;
      c|C) do_plugins_json ;;
      m|M) view=market; [ "$market_loaded" != 1 ] && { market_reset; fetch_market_page 1 || true; } ;;
      r|R) load_plugins; run_update_checks; msg="${dim}refreshed${reset}" ;;
      q|Q) exit 0 ;;
      *) continue ;;
    esac
  fi
  if [ "$view" = market ]; then draw_market; else draw; fi
done
