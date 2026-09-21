#!/usr/bin/env bash
# herdr Plugin Manager — popup TUI over the `herdr plugin` CLI.
#
# Keys: j/k or ↑/↓ move · u update · U update all · e enable/disable · x uninstall
#       o open repo in browser · c edit plugins.json · m marketplace
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

rows=()      # plugin rows (TSV from parse_list.py)
acts=()      # action rows: plugin_id \t action_id \t title \t command
flat=()      # display order: "p:<rows idx>" plus "a:<acts idx>" under expanded plugins
expanded=" " # " plugin_id plugin_id " — accordion state, survives reloads
sel=0        # index into flat
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
token_resolved=0    # github_token lookup has run

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
  # The watchdog must live in its OWN session: herdr kills the pane's whole
  # process group when the popup dies, and nohup doesn't stop that. macOS has
  # no setsid binary, so perl's POSIX::setsid detaches it instead.
  ( nohup perl -MPOSIX -e 'POSIX::setsid(); exec @ARGV' -- \
      bash "$root/bin/restore_watchdog.sh" "$$" "$tmpdir/prev-input" \
      "$root/bin/input_source.js" >/dev/null 2>&1 < /dev/null & ) 2>/dev/null
}

cleanup() { printf '\033[?25h'; rm -rf "$tmpdir" 2>/dev/null || true; }
trap cleanup EXIT

# Sets r_id r_name r_ver r_en r_kind r_spec r_commit r_slug r_ref r_full.
split_row() {
  local IFS=$'\t'
  read -r r_id r_name r_ver r_en r_kind r_spec r_commit r_slug r_ref r_full <<< "$1"
}

# Sets a_pid a_aid a_title a_cmd from one action row.
split_act() {
  local IFS=$'\t'
  read -r a_pid a_aid a_title a_cmd <<< "$1"
}

# Rebuilds the display order: every plugin row, with its action rows inlined
# beneath it while that plugin id is in $expanded.
build_flat() {
  flat=()
  local i j
  [ ${#rows[@]} -gt 0 ] || { sel=0; return 0; }
  for i in "${!rows[@]}"; do
    flat+=("p:$i")
    split_row "${rows[$i]}"
    case "$expanded" in
      *" $r_id "*)
        if [ ${#acts[@]} -gt 0 ]; then
          for j in "${!acts[@]}"; do
            case "${acts[$j]}" in "$r_id"$'\t'*) flat+=("a:$j") ;; esac
          done
        fi
        ;;
    esac
  done
  local last=$(( ${#flat[@]} - 1 ))
  [ "$sel" -gt "$last" ] && sel=$last
  [ "$sel" -lt 0 ] && sel=0
}

# Resolves the current selection to its plugin: sets r_* directly for a plugin
# row, or to the parent plugin for an action row.
select_plugin_row() {
  [ ${#flat[@]} -gt 0 ] || return 1
  local ent="${flat[$sel]}" line
  case "$ent" in
    p:*) split_row "${rows[${ent#p:}]}" ;;
    a:*)
      split_act "${acts[${ent#a:}]}"
      for line in "${rows[@]}"; do
        case "$line" in "$a_pid"$'\t'*) split_row "$line"; return 0 ;; esac
      done
      return 1
      ;;
  esac
}

action_count() {
  local n=0 a
  if [ ${#acts[@]} -gt 0 ]; then
    for a in "${acts[@]}"; do
      case "$a" in "$1"$'\t'*) n=$(( n + 1 )) ;; esac
    done
  fi
  printf '%s' "$n"
}

# Keybindings for plugin actions from herdr's config.toml ([[keys.command]]
# entries with type = "plugin_action"), as "full_action_id \t key" rows.
keymap=()
herdr_config="$(dirname "${HERDR_SOCKET_PATH:-$HOME/.config/herdr/herdr.sock}")/config.toml"

load_keymap() {
  local line
  keymap=()
  [ -f "$herdr_config" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] && keymap+=("$line")
  done < <(python3 "$root/bin/parse_keys.py" "$herdr_config" 2>/dev/null)
}

# Echoes the key(s) bound to a full action id ("prefix+p", comma-joined when
# bound more than once), or nothing when unbound.
action_key() {
  local k out=""
  if [ ${#keymap[@]} -gt 0 ]; then
    for k in "${keymap[@]}"; do
      case "$k" in "$1"$'\t'*) out="${out:+$out,}${k#*$'\t'}" ;; esac
    done
  fi
  printf '%s' "$out"
}

load_plugins() {
  local json line
  json="$("$herdr" plugin list --json 2>/dev/null)" || json=""
  rows=()
  acts=()
  if [ -n "$json" ]; then
    while IFS= read -r line; do
      [ -n "$line" ] || continue
      case "$line" in
        '#action'$'\t'*) acts+=("${line#\#action$'\t'}") ;;
        *) rows+=("$line") ;;
      esac
    done < <(printf '%s' "$json" | python3 "$root/bin/parse_list.py" 2>/dev/null)
  fi
  load_keymap
  build_flat
}

# ── update checking ─────────────────────────────────────────────────────────

# True when a requested ref is an exact commit pin: a hex string that is a
# prefix of the resolved commit can only be the commit itself.
#   $1 ref   $2 full resolved commit
is_sha_pin() {
  printf '%s\n' "$1" | grep -qE '^[0-9a-fA-F]{7,40}$' || return 1
  case "$2" in "$1"*) return 0 ;; *) return 1 ;; esac
}

# Compares one plugin's pinned sha against its remote ref, echoing the status
# word (current|update|error); when status is "update" and the remote's
# herdr-plugin.toml can be fetched, appends "\t<remote_version>". Standalone
# so it can be unit-tested.
#   $1 repo_slug (owner/repo)  $2 ref (or "-"/"")  $3 full pinned commit
#   $4 spec (owner/repo[/subdir], to locate herdr-plugin.toml; defaults to $1)
check_remote() {
  local slug="$1" ref="$2" commit="$3" spec="${4:-}" target remote_sha subdir manifest_url version
  [ -n "$spec" ] || spec="$slug"
  target="$ref"
  { [ -z "$target" ] || [ "$target" = "-" ]; } && target="HEAD"
  # An exact-sha pin can never drift, and ls-remote couldn't resolve a bare
  # sha anyway (it matches refs only) — report current without the network
  # round-trip.
  if is_sha_pin "$target" "$commit"; then
    printf 'current'
    return
  fi

  remote_sha="$(resolve_remote_sha "$slug" "$target")"
  if [ -z "$remote_sha" ]; then
    printf 'error'
    return
  fi

  if [ "$commit" = "$remote_sha" ]; then
    printf 'current'
    return
  fi
  printf 'update'

  # Best-effort: read the target version straight off the remote manifest at
  # the exact commit an update would pin to. raw.githubusercontent.com is a
  # plain file fetch (not the rate-limited GitHub Search/REST API), so this
  # doesn't compete with the marketplace's api.github.com budget.
  # For annotated tags, remote_sha is the peeled commit sha (tag object shas 404).
  command -v curl >/dev/null 2>&1 || return 0
  subdir=""
  [ "$spec" != "$slug" ] && subdir="${spec#"$slug"/}"
  manifest_url="https://raw.githubusercontent.com/$slug/$remote_sha"
  [ -n "$subdir" ] && manifest_url="$manifest_url/$subdir"
  manifest_url="$manifest_url/herdr-plugin.toml"
  version="$(curl -s --max-time 5 "$manifest_url" 2>/dev/null | \
    sed -nE 's/^version[[:space:]]*=[[:space:]]*"([^"]*)".*/\1/p' | head -1)"
  [ -n "$version" ] && printf '\t%s' "$version"
}

# First sha git ls-remote reports for a ref, or nothing on failure. Same
# guards as check_remote: no auth prompts, 8s hard cap on the whole call.
# Resolves peeled commit sha for annotated tags.
#   $1 repo_slug (owner/repo)  $2 ref
resolve_remote_sha() {
  local slug="$1" target="${2:-HEAD}"
  [ "$target" = "-" ] && target="HEAD"

  if printf '%s\n' "$target" | grep -Eq '^[0-9a-fA-F]{40}$'; then
    printf '%s\n' "$target"
    return 0
  fi

  local ref_name="$target"
  ref_name="${ref_name#refs/tags/}"
  ref_name="${ref_name#refs/heads/}"

  local ls_args=( "HEAD" "refs/tags/$ref_name" "refs/tags/$ref_name^{}" "refs/heads/$ref_name" )

  GIT_TERMINAL_PROMPT=0 GIT_HTTP_LOW_SPEED_LIMIT=1000 GIT_HTTP_LOW_SPEED_TIME=5 \
    perl -e 'alarm 8; exec @ARGV' -- \
    git ls-remote "https://github.com/$slug" "${ls_args[@]}" 2>/dev/null | \
    TARGET="$ref_name" awk '
      BEGIN { t = ENVIRON["TARGET"] }
      $2 == "refs/tags/" t "^{}" { peeled = $1 }
      $2 == "refs/tags/" t       { tag = $1 }
      $2 == "refs/heads/" t      { branch = $1 }
      $2 == "HEAD" && (t == "HEAD" || !t) { head = $1 }
      END {
        if (peeled) print peeled
        else if (tag) print tag
        else if (branch) print branch
        else if (head) print head
      }
    '
}

# Checks every github plugin in parallel, writing "<id>\t<status>[\t<version>]"
# lines. Blocks until all checks return (~0.5s, plus a manifest fetch for any
# plugin with an update); the popup's list is already painted by then.
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
      printf '%s\t%s\n' "$c_id" "$(check_remote "$c_slug" "$c_ref" "$c_full" "$c_spec")" >> "$statusfile"
    ) &
  done
  wait
  checked=1
}

plugin_status() {
  [ -s "$statusfile" ] || return 0
  awk -F'\t' -v id="$1" '$1==id{print $2; exit}' "$statusfile" 2>/dev/null
}

# The version an update would move a plugin to, or "" when status isn't
# "update" or the remote manifest couldn't be read.
plugin_update_version() {
  [ -s "$statusfile" ] || return 0
  awk -F'\t' -v id="$1" '$1==id{print $3; exit}' "$statusfile" 2>/dev/null
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
    if [ "${n:-0}" -gt 1 ]; then
      put '  %b↑ %s updates available — [u] this row · [U] all%b\n' "$yellow" "$n" "$reset"
    else
      put '  %b↑ 1 update available — press [u] to update%b\n' "$yellow" "$reset"
    fi
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

# Emits one already-colored row, right-padded to the terminal width so a
# scrollbar cell ($2) lands flush against the right edge. Relies on $cols and
# $show_scroll from the enclosing draw() (bash's dynamic scoping hands local
# vars down to called functions). Strips known color codes to measure the
# row's actual on-screen width before padding.
emit_row() {
  local line="$1" mark="$2" plain pad
  if [ "$show_scroll" -ne 1 ]; then
    put '%s\n' "$line"
    return 0
  fi
  plain="$line"
  plain="${plain//$bold/}"; plain="${plain//$dim/}"; plain="${plain//$red/}"
  plain="${plain//$green/}"; plain="${plain//$yellow/}"; plain="${plain//$cyan/}"
  plain="${plain//$reset/}"
  pad=$(( cols - ${#plain} - 3 ))
  [ "$pad" -lt 1 ] && pad=1
  put '%s%*s%b\n' "$line" "$pad" '' "$mark"
}

draw() {
  buf=""
  local cols
  cols="$(tput cols 2>/dev/null)"
  case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
  put '  %bherdr Plugin Manager%b' "$bold" "$reset"
  [ "$dry_run" = 1 ] && put '  %b[dry-run]%b' "$yellow" "$reset"
  if [ ${#rows[@]} -gt 0 ]; then
    if [ "$have_git" = 1 ] && [ "$checked" = 1 ]; then
      local n_outdated n_current
      n_outdated="$(awk -F'\t' '$2=="update"{c++} END{print c+0}' "$statusfile" 2>/dev/null)"
      n_current=$(( ${#rows[@]} - n_outdated ))
      put '  %b(%d installed · %d up to date · %d outdated)%b' \
        "$dim" "${#rows[@]}" "$n_current" "$n_outdated" "$reset"
    else
      put '  %b(%d installed)%b' "$dim" "${#rows[@]}" "$reset"
    fi
  fi
  put '\n\n'

  if [ ${#flat[@]} -eq 0 ]; then
    put '  %bno plugins installed — press [m] to browse the marketplace%b\n' "$dim" "$reset"
  else
    local max_vis=8 start=0 end i ent nacts marker
    [ "$sel" -ge "$max_vis" ] && start=$(( sel - max_vis + 1 ))
    end=$(( start + max_vis - 1 ))
    [ "$end" -ge ${#flat[@]} ] && end=$(( ${#flat[@]} - 1 ))

    local show_scroll=0 sb_thumb=1 sb_pos=0 sb_max_start=0
    if [ ${#flat[@]} -gt "$max_vis" ]; then
      show_scroll=1
      sb_thumb=$(( max_vis * max_vis / ${#flat[@]} ))
      [ "$sb_thumb" -lt 1 ] && sb_thumb=1
      [ "$sb_thumb" -gt "$max_vis" ] && sb_thumb=$max_vis
      sb_max_start=$(( ${#flat[@]} - max_vis ))
      [ "$sb_max_start" -gt 0 ] && sb_pos=$(( start * (max_vis - sb_thumb) / sb_max_start ))
    fi

    i=$start
    while [ "$i" -le "$end" ]; do
      ent="${flat[$i]}"
      local cursor="  " pre="" post="" sb=" "
      if [ "$i" -eq "$sel" ]; then
        cursor="${cyan}▸ ${reset}"
        pre="$bold" post="$reset"
      fi
      if [ "$show_scroll" -eq 1 ]; then
        local j=$(( i - start ))
        if [ "$j" -ge "$sb_pos" ] && [ "$j" -lt "$(( sb_pos + sb_thumb ))" ]; then
          sb="${cyan}┃${reset}"
        else
          sb="${dim}│${reset}"
        fi
      fi
      case "$ent" in
        p:*)
          split_row "${rows[${ent#p:}]}"
          local status dot state="" uver idx
          idx="${dim}$(printf '%2d' "$(( ${ent#p:} + 1 ))")${reset} "
          status="$(plugin_status "$r_id")"
          if [ "$r_en" = 0 ]; then
            dot="${dim}○${reset}"
            state="  ${dim}(disabled)${reset}"
          elif [ "$r_kind" = github ] && [ "$checked" != 1 ]; then
            dot="${green}○${reset}"
          elif [ "$status" = update ]; then
            dot="${yellow}●${reset}"
            uver="$(plugin_update_version "$r_id")"
            if [ -n "$uver" ]; then
              state="  ${yellow}↑ update → $uver${reset}"
            else
              state="  ${yellow}↑ update${reset}"
            fi
          else
            dot="${green}●${reset}"
          fi
          marker=" "
          nacts="$(action_count "$r_id")"
          if [ "$nacts" -gt 0 ]; then
            case "$expanded" in
              *" $r_id "*) marker="${dim}⌄${reset}" ;;
              *) marker="${dim}›${reset}" ;;
            esac
          fi
          local line
          printf -v line '%b  %b%b %b%-24.24s %-8.8s%b %b%b' \
            "$idx" "$cursor" "$dot" "$pre" "$r_name" "$r_ver" "$post" "$marker" "$state"
          emit_row "$line" "$sb"
          ;;
        a:*)
          split_act "${acts[${ent#a:}]}"
          local akey akey_disp="" line
          akey="$(action_key "$a_pid.$a_aid")"
          [ -n "$akey" ] && akey_disp="[$akey]"
          printf -v line '     %b   %b↳%b %b%-14.14s%b %b%-26.26s%b %b%s%b' \
            "$cursor" "$dim" "$reset" "$pre" "$a_aid" "$post" "$dim" "$a_title" "$reset" \
            "$yellow" "$akey_disp" "$reset"
          emit_row "$line" "$sb"
          ;;
      esac
      i=$(( i + 1 ))
    done
    put '\n'
    put '  %b──────────────────────────────────────────────────────────%b\n' "$dim" "$reset"
    ent="${flat[$sel]}"
    case "$ent" in
      a:*)
        split_act "${acts[${ent#a:}]}"
        local akey c1="${a_cmd:0:56}"
        akey="$(action_key "$a_pid.$a_aid")"
        [ ${#a_cmd} -gt 56 ] && c1="${a_cmd:0:55}…"
        put '  %baction%b  %s.%s\n' "$dim" "$reset" "$a_pid" "$a_aid"
        if [ -n "$akey" ]; then
          put '  %bkey%b     %b[%s]%b\n' "$dim" "$reset" "$yellow" "$akey" "$reset"
        else
          put '  %bkey%b     %b— not bound (add [[keys.command]] in config.toml)%b\n' \
            "$dim" "$reset" "$dim" "$reset"
        fi
        put '  %bcmd%b     %s\n' "$dim" "$reset" "$c1"
        ;;
      p:*)
        split_row "${rows[${ent#p:}]}"
        local src="$r_spec" uver
        [ "$r_ref" != "-" ] && src="$src ($r_ref)"
        [ "$r_kind" = local ] && src="local link"
        [ "$r_commit" != "-" ] && src="$src @$r_commit"
        put '  %bid%b      %s\n' "$dim" "$reset" "$r_id"
        put '  %bsource%b  %-60.60s\n' "$dim" "$reset" "$src"
        if [ "$(plugin_status "$r_id")" = update ]; then
          uver="$(plugin_update_version "$r_id")"
          if [ -n "$uver" ]; then
            put '  %b↑ %s available — press [u] to update%b\n' "$yellow" "$uver" "$reset"
          else
            put '  %b↑ newer commit available — press [u] to update%b\n' "$yellow" "$reset"
          fi
        fi
        ;;
    esac
  fi

  put '\n'
  put '  %b[j/k] move · [⏎] expand/run action · [u] update · [U] update all%b\n' "$dim" "$reset"
  put '  %b[o] repo in browser · [c] edit plugins.json · [x] uninstall%b\n' "$dim" "$reset"
  put '  %b[e] enable/disable · [m] marketplace · [r] refresh · [q] quit%b\n' "$dim" "$reset"
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
    line="$(printf '%s\n' "$out" | grep -m1 .)"
    case "$line" in
      '{'*)  # herdr CLI errors are JSON — surface just the message
        line="$(printf '%s' "$line" | python3 -c '
import json, sys
try:
    print(json.load(sys.stdin)["error"]["message"])
except Exception:
    pass' 2>/dev/null)" ;;
    esac
    line="$(printf '%.58s' "$line")"
    msg="${red}✗ failed${reset}${line:+ — $line}"
  fi
  load_plugins
}

# Enter on a plugin row — fold/unfold its action list.
toggle_expand() {
  select_plugin_row || return 0
  if [ "$(action_count "$r_id")" -eq 0 ]; then
    msg="${dim}'$r_name' declares no actions${reset}"
    return
  fi
  case "$expanded" in
    *" $r_id "*) expanded="${expanded/ $r_id / }" ;;
    *) expanded="${expanded}${r_id} " ;;
  esac
  build_flat
}

# Enter on an action row — close the popup, THEN run the action. Invoking from
# inside the popup fails for anything that opens UI (herdr answers ui_busy /
# popup already open while a popup is showing), so a detached helper waits for
# this process to die and fires the invoke against the normal workspace view.
invoke_action() {
  local ent="${flat[$sel]}"
  split_act "${acts[${ent#a:}]}"
  if [ "$dry_run" = 1 ]; then
    msg="${yellow}[dry-run]${reset} close popup → $herdr plugin action invoke $a_pid.$a_aid"
    return
  fi
  # Exiting right after the spawn closes the popup, and herdr tears down that
  # pane's process group. The child then has to finish POSIX::setsid() -- perl
  # startup included -- before the teardown reaches it, and it loses that race
  # often enough to drop roughly one action in three, silently: its stderr goes
  # to /dev/null and backgrounding returns 0 either way. So wait for the child
  # to signal that it has detached (capped, since a stuck child must never
  # leave the popup hanging).
  local flag="${TMPDIR:-/tmp}/herdr-pm-detached.$$"
  rm -f "$flag"
  ( HERDR_PM_FLAG="$flag" nohup perl -MPOSIX -e 'POSIX::setsid(); open(D, ">", $ENV{HERDR_PM_FLAG}) and close D; exec @ARGV' -- \
      bash "$root/bin/invoke_after_close.sh" "$$" "$herdr" "$a_pid.$a_aid" \
      >/dev/null 2>&1 < /dev/null & ) 2>/dev/null
  local waited=0
  while [ ! -e "$flag" ] && [ "$waited" -lt 40 ]; do
    sleep 0.025
    waited=$(( waited + 1 ))
  done
  rm -f "$flag"
  exit 0
}

# Runs (or dry-run prints) a long mutating command (install/update) attached
# directly to the terminal, then refreshes + checks. No --yes and no output
# pipe: herdr's own interactive trust preview (resolved commit, build
# commands, actions, hooks, panes) plus its [y/N] confirmation is the whole
# point — it needs the tty, and it only appears when stdin is interactive.
# One herdr invocation with the popup's cursor handling, printing the outcome
# line and returning herdr's exit status. Split out of run_mut so a batch can
# chain several installs without a reload and a keypress between each.
run_herdr() {
  local status=0
  printf '\n'
  if [ "$dry_run" = 1 ]; then
    printf '  %b[dry-run]%b %s' "$yellow" "$reset" "$herdr"
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  printf '\033[?25h'
  "$herdr" "$@"
  status=$?
  printf '\033[?25l'
  if [ "$status" -eq 0 ]; then
    printf '\n  %b✓ done%b\n' "$green" "$reset"
  else
    printf '\n  %b✗ cancelled or failed (exit %s)%b\n' "$red" "$status" "$reset"
  fi
  return "$status"
}

run_mut() {
  run_herdr "$@" || true
  pause_key
  load_plugins
  run_update_checks
}

# Reads a line with basic editing (backspace) and Esc-to-cancel, showing the
# cursor for the duration. Sets REPLY to the submitted text and
# PROMPT_CANCELLED to 1 if the user pressed Esc/Ctrl-C/EOF instead of Enter
# (callers should leave their state untouched in that case), else 0. A bare
# Esc is disambiguated from an escape sequence (arrow keys etc.) the same way
# read_key() does; sequence continuation bytes are swallowed as a no-op since
# this editor doesn't support cursor movement.
prompt_line() {
  local prompt="$1" buf="" k rest saved
  PROMPT_CANCELLED=0
  printf '\033[?25h%s' "$prompt"
  while true; do
    IFS= read -rsn1 k || { PROMPT_CANCELLED=1; break; }
    if [ -z "$k" ]; then
      break  # Enter
    elif [ "$k" = $'\e' ]; then
      rest=''
      if saved="$(stty -g 2>/dev/null)" && [ -n "$saved" ]; then
        stty -icanon -echo min 0 time 1 2>/dev/null
        rest="$(dd bs=6 count=1 2>/dev/null)"
        stty "$saved" 2>/dev/null
      else
        IFS= read -rsn1 -t 1 rest || true
      fi
      [ -z "$rest" ] && { PROMPT_CANCELLED=1; break; }
    elif [ "$k" = $'\x03' ]; then
      PROMPT_CANCELLED=1
      break
    elif [ "$k" = $'\x7f' ] || [ "$k" = $'\b' ]; then
      if [ -n "$buf" ]; then
        buf="${buf%?}"
        printf '\b \b'
      fi
    else
      buf+="$k"
      printf '%s' "$k"
    fi
  done
  printf '\033[?25l'
  REPLY="$buf"
}

do_update() {
  select_plugin_row || return 0
  if [ "$r_kind" != github ]; then
    msg="${yellow}'$r_name' is a $r_kind plugin — update it from its own checkout${reset}"
    return
  fi
  # No dedicated update command: re-running install moves the pin. Pass the
  # requested ref along so the installation's ref policy survives the update;
  # herdr's interactive preview (via run_mut) stays the final gate.
  local args=(plugin install "$r_spec")
  if [ "$r_ref" != "-" ] && is_sha_pin "$r_ref" "$r_full"; then
    # An exact-sha pin never moves implicitly: resolve where HEAD is, show
    # the move, and re-pin to that exact commit only on explicit consent.
    local head_sha
    head_sha="$(resolve_remote_sha "$r_slug" HEAD)"
    if [ -z "$head_sha" ]; then
      msg="${red}could not resolve $r_slug HEAD (needs git + network)${reset}"
      return
    fi
    if [ "$head_sha" = "$r_full" ]; then
      msg="${green}✓${reset} $r_name is pinned to the latest commit"
      return
    fi
    printf '\n  %b%s is pinned to %s — move the pin to %s (HEAD)? [y/N]%b ' \
      "$yellow" "$r_name" "${r_full:0:7}" "${head_sha:0:7}" "$reset"
    local k=""
    IFS= read -rsn1 k || true
    case "$k" in
      y|Y) args+=(--ref "$head_sha") ;;
      *) msg="${dim}update cancelled — pin kept at ${r_full:0:7}${reset}"; return ;;
    esac
  else
    if [ "$(plugin_status "$r_id")" = current ]; then
      msg="${green}✓${reset} $r_name is already up to date"
      return
    fi
    [ "$r_ref" != "-" ] && args+=(--ref "$r_ref")
  fi
  run_mut "${args[@]}"
}

# The plugins a bulk update would move, as "<id>\t<name>\t<spec>\t<ref>" rows:
# github kind only (a linked checkout updates from its own working copy), known
# to be behind, and not pinned to an exact sha.
outdated_rows() {
  local line o_id o_name o_ver o_en o_kind o_spec o_commit o_slug o_ref o_full
  for line in "${rows[@]}"; do
    IFS=$'\t' read -r o_id o_name o_ver o_en o_kind o_spec o_commit o_slug o_ref o_full <<< "$line"
    [ "$o_kind" = github ] || continue
    [ "$(plugin_status "$o_id")" = update ] || continue
    # Moving an exact-sha pin is a deliberate per-plugin decision, so a batch
    # passes over it silently; single-row [u] still offers the move.
    if [ "$o_ref" != "-" ] && is_sha_pin "$o_ref" "$o_full"; then continue; fi
    printf '%s\t%s\t%s\t%s\n' "$o_id" "$o_name" "$o_spec" "$o_ref"
  done
}

# Updates every outdated plugin in one pass. The set is snapshotted up front
# because each install reloads $rows, and the installs run from that array
# rather than a piped read: herdr's trust preview gates every install from the
# terminal, and a redirected stdin would swallow its prompt.
do_update_all() {
  if [ "$have_git" != 1 ]; then
    msg="${yellow}install git to check for updates${reset}"
    return
  fi
  if [ "$checked" != 1 ]; then
    msg="${dim}still checking for updates — try again in a moment${reset}"
    return
  fi

  local targets=() line
  while IFS= read -r line; do
    [ -n "$line" ] && targets+=("$line")
  done < <(outdated_rows)

  local n="${#targets[@]}"
  if [ "$n" -eq 0 ]; then
    msg="${green}✓${reset} nothing to update"
    return
  fi

  local t_id t_name t_spec t_ref t_ver
  printf '\n  %bupdating %s plugin(s):%b\n' "$bold" "$n" "$reset"
  for line in "${targets[@]}"; do
    IFS=$'\t' read -r t_id t_name t_spec t_ref <<< "$line"
    t_ver="$(plugin_update_version "$t_id")"
    if [ -n "$t_ver" ]; then
      printf '    %b↑%b %s %b→ %s%b\n' "$yellow" "$reset" "$t_name" "$dim" "$t_ver" "$reset"
    else
      printf '    %b↑%b %s\n' "$yellow" "$reset" "$t_name"
    fi
  done
  printf '\n  %bupdate %s plugin(s)? [y/N]%b ' "$yellow" "$n" "$reset"
  local k=""
  IFS= read -rsn1 k || true
  case "$k" in
    y|Y) ;;
    *) msg="${dim}bulk update cancelled${reset}"; return ;;
  esac

  local ok=0 failed=0 args
  for line in "${targets[@]}"; do
    IFS=$'\t' read -r t_id t_name t_spec t_ref <<< "$line"
    printf '\n  %b── %s%b\n' "$dim" "$t_name" "$reset"
    args=(plugin install "$t_spec")
    [ "$t_ref" != "-" ] && args+=(--ref "$t_ref")
    # Declining one preview is not a batch failure: the rest still run.
    if run_herdr "${args[@]}"; then
      ok=$(( ok + 1 ))
    else
      failed=$(( failed + 1 ))
    fi
  done

  pause_key
  load_plugins
  run_update_checks
  if [ "$failed" -gt 0 ]; then
    msg="${yellow}updated $ok of $n — $failed declined or failed${reset}"
  else
    msg="${green}✓${reset} updated $ok plugin(s)"
  fi
}

do_toggle() {
  select_plugin_row || return 0
  if [ "$r_en" = 1 ]; then
    run_quiet "disabled $r_name" plugin disable "$r_id"
  else
    run_quiet "enabled $r_name" plugin enable "$r_id"
  fi
}

do_uninstall() {
  select_plugin_row || return 0
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

# c — open the global plugins registry (~/.config/herdr/plugins.json) in the
# configured editor. HERDR_PM_EDITOR is an explicit override for servers whose
# environment does not inherit the caller's VISUAL/EDITOR settings.
do_plugins_json() {
  local editor="${HERDR_PM_EDITOR:-${VISUAL:-${EDITOR:-code}}}"
  if [ ! -f "$plugins_json" ]; then
    msg="${red}not found: $plugins_json${reset}"
    return
  fi
  if [ "$dry_run" = 1 ]; then
    msg="${yellow}[dry-run]${reset} $editor $plugins_json"
    return
  fi
  if ! command -v "$editor" >/dev/null 2>&1; then
    msg="${red}editor '$editor' not found — set HERDR_PM_EDITOR, VISUAL, or EDITOR${reset}"
    return
  fi
  if "$editor" "$plugins_json"; then
    msg="${green}opened${reset} $plugins_json"
  else
    msg="${red}failed to launch $editor${reset}"
  fi
}

# o — open the selected plugin's GitHub repo in the browser (subdir plugins open
# the subdir at the installed commit; local plugins have no remote).
do_open_repo() {
  select_plugin_row || return 0
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
# m_name feeds `run_mut plugin install "$m_name"` and a URL open below, so a
# malicious/crafted GitHub result must not reach either as anything but a
# plain owner/repo[/subdir] slug.
split_mrow() {
  local IFS=$'\t'
  read -r m_name m_stars m_desc <<< "$1"
  [[ "$m_name" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)?$ ]] || m_name=""
}

# Bearer token for api.github.com, resolved once. Anonymous search allows 10
# requests/minute per IP; authenticated allows 30. The marketplace itself stays
# well inside the anonymous budget (one request per visited page), but the
# token also makes calls attributable and gives headroom for repeat fetches.
# The herdr server's env usually lacks GH_TOKEN, so fall back to the gh CLI's
# stored credential when it is installed. Set HERDR_PM_NO_TOKEN=1 to force
# anonymous calls.
github_token=""
resolve_github_token() {
  github_token=""
  [ "${HERDR_PM_NO_TOKEN:-0}" = 1 ] && return 0
  github_token="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
  [ -n "$github_token" ] && return 0
  command -v gh >/dev/null 2>&1 || return 0
  github_token="$(gh auth token 2>/dev/null)" || github_token=""
}

# Curl config for the marketplace call, fed on stdin (-K -) rather than as a
# -H argument: argv is readable through `ps` by every other account on the box,
# and this is the user's own gh credential, not a scoped one. Empty output
# means an anonymous call, which curl accepts as a no-op config.
market_auth_config() {
  [ -n "$github_token" ] || return 0
  printf 'header = "Authorization: Bearer %s"\n' "$github_token"
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

# One-line reason for a failed marketplace fetch, using the real HTTP status and
# GitHub's own message when the body carries one (rate limits, auth, 5xx all
# arrive as readable JSON). Falls back to a status-labelled generic line.
#   $1 http status (000 when curl never connected)  $2 response body
#   $3 curl exit status (0 on success; 28 is the --max-time cap)
market_error() {
  local status="$1" body="$2" rc="${3:-0}" detail
  if [ "$status" = 000 ]; then
    printf 'marketplace fetch failed — no network connection'
    return
  fi
  if [ "$rc" = 28 ]; then
    printf 'marketplace fetch timed out (HTTP %s) — retry with [r]' "$status"
    return
  fi
  detail="$(printf '%s' "$body" | python3 -c \
    'import json,sys
try: d=json.load(sys.stdin)
except Exception: sys.exit()
print(d.get("message","") if isinstance(d,dict) else "")' 2>/dev/null)"
  case "$status" in
    403|429) printf 'marketplace rate limit (HTTP %s)%s' "$status" "${detail:+ — $detail}" ;;
    *)       printf 'marketplace fetch failed (HTTP %s)%s' "$status" "${detail:+ — $detail}" ;;
  esac
}

# Fetches one API page into its sparse slots (no-op when already stored).
# A page with zero rows is still a success as long as #total arrived — a narrow
# query can legitimately match nothing.
fetch_market_page() {
  local page="$1" json line base n=0 saw_total=0 status rc=0
  case "$m_pages_fetched" in *" $page "*) return 0 ;; esac
  [ "$token_resolved" = 1 ] || { resolve_github_token; token_resolved=1; }
  buf=""
  put '\n  %bfetching…%b\n' "$dim" "$reset"
  draw_flush
  # The 50-item page is ~330KB; 8s flaked mid-download on a slow link in
  # testing, so allow 20s. -o keeps a partial body out of $json, and rc
  # distinguishes a timeout from a real HTTP error for the message below
  # (rc is the pipeline's last stage, so it is still curl's).
  status="$(market_auth_config | curl -s --max-time 20 -o "$tmpdir/market.json" -w '%{http_code}' \
    -H 'Accept: application/vnd.github+json' -K - "$(market_url "$page")" 2>/dev/null)"
  rc=$?
  json="$(cat "$tmpdir/market.json" 2>/dev/null)" || json=""
  base=$(( (page - 1) * market_per_page ))
  if [ "$status" = 200 ] && [ "$rc" = 0 ] && [ -n "$json" ]; then
    while IFS= read -r line; do
      case "$line" in
        '') ;;
        '#total'*) m_total="${line##*$'\t'}"; saw_total=1 ;;
        *) mrows[$(( base + n ))]="$line"; n=$(( n + 1 )) ;;
      esac
    done < <(printf '%s' "$json" | python3 "$root/bin/parse_market.py" 2>/dev/null)
  fi
  if [ "$saw_total" = 0 ]; then
    msg="${red}$(market_error "$status" "$json" "$rc")${reset}"
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
  local total label sort_disp
  total="$(display_total)"
  label="topic:herdr-plugin"
  [ -n "$m_query" ] && label="\"$m_query\""
  if [ "$m_sort" = stars ]; then
    sort_disp="${cyan}[stars]${reset} ${dim}updated${reset}"
  else
    sort_disp="${dim}stars${reset} ${cyan}[updated]${reset}"
  fi
  put '  %bherdr marketplace%b  %b%s · sort: %b%b' \
    "$bold$cyan" "$reset" "$dim" "$label" "$reset" "$sort_disp"
  [ "$dry_run" = 1 ] && put '  %b[dry-run]%b' "$yellow" "$reset"
  put '\n\n'

  if [ "$total" -eq 0 ]; then
    if [ "$market_loaded" = 1 ]; then
      put '  %bno results — [/] to change the search, [q] to go back%b\n' "$dim" "$reset"
    else
      put '  %bnothing loaded — press [r] to retry%b\n' "$dim" "$reset"
    fi
  else
    local start=$(( mpg * MARKET_VIS )) end i
    end=$(( start + MARKET_VIS - 1 ))
    [ "$end" -ge "$total" ] && end=$(( total - 1 ))
    i=$start
    while [ "$i" -le "$end" ]; do
      local midx="${dim}$(printf '%4d' "$(( i + 1 ))")${reset} "
      if [ -z "${mrows[$i]:-}" ]; then
        put '%b      %b…%b\n' "$midx" "$dim" "$reset"
      else
        split_mrow "${mrows[$i]}"
        local cursor="  " pre="" post="" mark="  "
        market_installed "$m_name" && mark="${green}✓ ${reset}"
        if [ "$i" -eq "$msel" ]; then
          cursor="${cyan}▸ ${reset}"
          pre="$bold" post="$reset"
        fi
        put '%b  %b%b%b%-42.42s %b★ %-5s%b%b\n' \
          "$midx" "$cursor" "$mark" "$pre" "$m_name" "$yellow" "$m_stars" "$reset" "$post"
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
        put '  %b[⏎] installs github.com/%s%b\n' "$dim" "$m_name" "$reset"
      fi
    fi
    put_pagebar "$total"
  fi

  put '\n'
  put '  %b[j/k] move · [←/→] page · [⏎] install · [o] repo in browser%b\n' "$dim" "$reset"
  put '  %b[/] search · [s] sort · [r] refresh · [q] back%b\n' "$dim" "$reset"
  [ -n "$msg" ] && put '\n  %b\n' "$msg"
  draw_flush
}

# / — re-query the API with extra search terms (matches name/description/readme
# across the whole topic, not just the loaded rows). Empty input goes back to
# the unfiltered topic listing. Esc cancels without touching the current
# query/results.
m_search() {
  printf '\n'
  prompt_line "  search (empty = all, Esc = cancel): "
  if [ "$PROMPT_CANCELLED" = 1 ]; then
    msg="${dim}search cancelled${reset}"
    return
  fi
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
    msg="${green}$m_name is already installed${reset} — update it from the main list ([u])"
    return
  fi
  printf '\n  %binstall %b%s%b (★ %s)? [y/N]%b ' \
    "$bold" "$cyan" "$m_name" "$reset$bold" "$m_stars" "$reset"
  local k=""
  IFS= read -rsn1 k || true
  case "$k" in
    y|Y) run_mut plugin install "$m_name" ;;
    *) msg="${dim}install cancelled${reset}" ;;
  esac
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
      j|down) [ ${#flat[@]} -gt 0 ] && sel=$(( (sel + 1) % ${#flat[@]} )) ;;
      k|up)   [ ${#flat[@]} -gt 0 ] && sel=$(( (sel - 1 + ${#flat[@]}) % ${#flat[@]} )) ;;
      enter)
        [ ${#flat[@]} -gt 0 ] || continue
        case "${flat[$sel]}" in
          p:*) toggle_expand ;;
          a:*) invoke_action ;;
        esac
        ;;
      u) do_update ;;
      U) do_update_all ;;
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
