# herdr-plugin-manager

![herdr 0.7.4+](https://img.shields.io/badge/herdr-0.7.4%2B-8a2be2)
![platform: macOS / Linux](https://img.shields.io/badge/platform-macOS%20%7C%20Linux-informational)
![zero JS dependencies](https://img.shields.io/badge/deps-zero-brightgreen)

![herdr Plugin Manager popup showing installed plugins with update indicators](assets/updates.png)

🇺🇸 English | [🇰🇷 한국어](#한국어)

**Manage [herdr](https://herdr.dev) plugins from a single popup.** When every pane is running an AI agent, you shouldn't have to open a new tab and remember `herdr plugin ...` incantations just to install something — one keypress opens a popup where you install, update, remove, toggle, and browse the marketplace.

Under the hood it's a thin TUI over the `herdr plugin` CLI (bash + python3, zero external dependencies).

> **Also from the same author — [Command Center](https://github.com/speardragon/herdr-command-center).** One keybinding, every command: a popup that lists the commands you registered and runs them by slot key. It makes other plugins' actions easier to reach without remembering which prefix key they sit under, and gives the jobs you keep retyping a permanent slot.
>
> <img src="https://raw.githubusercontent.com/speardragon/herdr-command-center/main/docs/popup-list.png" width="520" alt="The Command Center popup listing commands in a grid, each with its own slot key">

## Quick start

```bash
herdr plugin install speardragon/herdr-plugin-manager
```

Add a keybinding to `~/.config/herdr/config.toml` — the **recommended key is `prefix+p`** (**p**lugin):

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "ray.plugin-manager.open"
description = "open plugin manager"
```

Run `herdr server reload-config`, then press `prefix+p` in any pane.

## Keys

![main view — installed plugin list](assets/main.png)

| Key | Action |
|-----|--------|
| `j` / `k` / `↑` / `↓` | Move selection (details of the selected item shown below the list). Each plugin row shows its 1-based position at the far left |
| `Enter` | On a **plugin row**: fold/unfold its declared actions (accordion, `›`/`⌄`) · on an **action row**: run that action immediately via `herdr plugin action invoke`. Action rows show the key bound to them in your herdr config (e.g. `prefix+p`), and the detail pane shows the binding plus the command the action runs |
| `u` | Update the selected plugin — herdr has no update command, so this re-runs `install` **preserving the requested ref**: branch/tag installs update along their own ref, and an exact-sha pin is only moved after an explicit `old → new` confirm. herdr's interactive trust preview (commit, build commands, actions, hooks) is the final gate; already-up-to-date plugins are skipped |
| `U` | Update **every** outdated plugin in one pass, after a `y/N` confirm listing what is about to move. Same ref semantics as `u`, and herdr's trust preview still gates each install — declining one leaves the rest of the batch running. Exact-sha pins are passed over silently (moving a pin stays a per-plugin decision), as are locally linked plugins |
| `e` | Toggle enable ↔ disable |
| `x` | Uninstall after a `y/N` confirm (locally linked plugins are unlinked instead) |
| `o` | Open the plugin's GitHub repo in your browser (subdir plugins open the subdir at the installed commit) |
| `c` | Open the global plugin registry `~/.config/herdr/plugins.json` with `HERDR_PM_EDITOR`, then `VISUAL`, then `EDITOR`; `code` is the compatibility fallback |
| `m` | **Marketplace** — browse community plugins (below) |
| `r` | Refresh the list (re-checks updates) |
| `q` / `Esc` | Close |

**Indicators:** 🟢 `●` enabled & up to date · 🟡 `●` `↑ update → 0.2.0` — a newer commit exists on the GitHub source (press `u`, or `U` to update them all); the target version is read from the remote `herdr-plugin.toml` when that fetch succeeds, otherwise it just shows `↑ update` · ⚪ `○` disabled. The list paints instantly; update status settles ~0.5s later by comparing each plugin's pinned sha against its requested ref (default-branch HEAD when none; exact-sha pins are always current) via `git ls-remote`, then (only for plugins with an update) fetching the remote manifest from `raw.githubusercontent.com` for the version string. Locally linked plugins are excluded from update checks.

**Auto ASCII input (macOS):** like herdr's `switch_ascii_input_source_in_prefix`, opening the popup on a non-ASCII input source (e.g. a Korean IME) switches to your last-used ASCII layout so the single-key TUI works immediately, and the original source is restored when the popup closes — by a detached watchdog, so it works even if the pane is force-closed. Uses the Text Input Source API via osascript (JXA), no extra installs. Disable with `HERDR_PM_ASCII_INPUT=0`.

## Marketplace (`m`)

![marketplace view — community plugins sorted by stars](assets/market.png)

The same index as [herdr.dev/plugins](https://herdr.dev/plugins/) — public GitHub repos tagged with the `herdr-plugin` topic, queried straight from the GitHub Search API. Results are browsed in pages of 10 with a `‹ 1 … 4 [5] 6 … 29 ›` page bar at the bottom; the API is fetched 50 at a time, only for the pages you actually visit (up to the search API's 1000-result cap).

Requests authenticate when a token is available, resolving `GH_TOKEN`, then `GITHUB_TOKEN`, then `gh auth token`. Anonymous search allows 10 requests per minute per IP and authenticated allows 30, and the herdr server's environment usually has no `GH_TOKEN` even when your shell does — so the `gh` fallback is what normally keeps the marketplace browsing smoothly. Set `HERDR_PM_NO_TOKEN=1` to force anonymous calls. A failed fetch reports the real reason (HTTP status and GitHub's own message, a timeout, or no connection) instead of one generic line.

`j`/`k` move (crossing a page boundary flips automatically; each row shows its 1-based position in the full result set at the far left) · `←`/`→` (or `h`/`l`) flip pages, wrapping at the ends · `/` **searches** by re-querying the API (`topic:herdr-plugin + your terms` — matches name/description/readme across the whole topic, not just loaded rows; empty input + Enter returns to the full listing, Esc cancels without changing anything) · `s` toggles the sort between most-starred and most-recently-updated · **Enter installs the selection** after a `y/N` confirm — the install itself then runs through herdr's interactive trust preview (resolved commit, build commands, actions, hooks, panes), so nothing executes until you approve exactly what it's about to run; already-installed repos show a `✓` · `o` opens the repo in your browser · `r` re-fetches with the current query/sort · `q` goes back. The active query and sort are shown in the header; a failed fetch keeps the cursor and loaded list intact.

## Dry-run mode

```bash
herdr plugin pane open --plugin ray.plugin-manager --entrypoint manager \
  --placement popup --focus --env HERDR_PM_DRY_RUN=1
```

Every mutating action prints the exact command instead of running it; read-only actions still work.

## Requirements

herdr 0.7.4+ · `python3` (JSON parsing) · `git` (optional, update indicators) · `curl` (marketplace and update-target versions) · `gh` (optional, marketplace authentication when no token is in the environment) · `open`/`xdg-open` (the `o` key) · an editor command on `PATH` (the `c` key; `code` is only the fallback).

The `c` key resolves its editor in this order: `HERDR_PM_EDITOR`, `VISUAL`,
`EDITOR`, then `code`. The selected command is run in the popup's foreground
terminal, so terminal editors such as `nvim` work normally. `HERDR_PM_EDITOR`
is useful when the Herdr server was started without the caller's shell
environment; set it to one executable or a wrapper script.

## Development

```bash
herdr plugin link /path/to/herdr-plugin-manager
herdr plugin action invoke ray.plugin-manager.open
HERDR_PM_DRY_RUN=1 bash bin/manager.sh   # test the TUI in any terminal, no popup needed
bash tests/run.sh                        # run the tests
bash tests/run.sh bulk_loop              # ...or just the cases matching a name
```

The tests stub out `git`, `curl` and the herdr CLI, so they need no network, no
herdr install and no plugins of your own — `tests/cases/e2e_bulk_update.sh`
drives the real popup against a fixture list of six plugins. Needs `python3`
and `perl`, and runs on bash 3.2.

---

## 한국어

**[herdr](https://herdr.dev) 플러그인을 popup 하나로 관리하는 플러그인.** 모든 pane에 에이전트를 띄워두고 일할 때, 플러그인 하나 설치하자고 새 탭을 열고 `herdr plugin ...` 명령어를 기억해낼 필요가 없다 — 키 한 번이면 popup이 뜨고, 거기서 설치·업데이트·삭제·enable/disable·마켓플레이스 탐색까지 전부 끝난다.

> **같은 제작자의 다른 플러그인 — [Command Center](https://github.com/speardragon/herdr-command-center).** 키 하나에 모든 명령. 등록해둔 명령을 popup에 나열하고 슬롯 키로 바로 실행한다. 다른 플러그인의 액션을 어떤 prefix 키에 넣어뒀는지 기억하지 않고도 꺼내 쓸 수 있고, 매번 다시 타이핑하던 반복 작업에 고정 자리를 줄 수 있다.
>
> <img src="https://raw.githubusercontent.com/speardragon/herdr-command-center/main/docs/popup-list.png" width="520" alt="Command Center popup — 등록된 명령이 슬롯 키와 함께 그리드로 나열된 화면">

내부적으로는 전부 `herdr plugin` CLI를 그대로 호출하는 얇은 TUI다 (bash + python3, 외부 의존성 없음).

### 빠른 시작

```bash
herdr plugin install speardragon/herdr-plugin-manager
```

herdr 설정(`~/.config/herdr/config.toml`)에 키바인딩 추가 — **추천 키는 `prefix+p`** (**p**lugin):

```toml
[[keys.command]]
key = "prefix+p"
type = "plugin_action"
command = "ray.plugin-manager.open"
description = "open plugin manager"
```

`herdr server reload-config` 실행 후 아무 pane에서나 `prefix+p`를 누르면 popup이 뜬다.

### 키

![main view — installed plugin list](assets/main.png)

| 키 | 동작 |
|----|------|
| `j` / `k` / `↑` / `↓` | 이동 (선택된 항목의 상세가 하단에 표시). 플러그인 행 맨 왼쪽에 1부터 시작하는 순번이 표시된다 |
| `Enter` | **플러그인 행**: 액션 목록 펼치기/접기 (아코디언, `›`/`⌄` 표시) · **액션 행**: 그 액션 즉시 실행 |
| `u` | 업데이트 — herdr에 update 명령이 없어 `install` 재실행 방식이되, **요청 ref를 그대로 유지**한다: 브랜치/태그 설치는 그 ref를 따라 갱신되고, 특정 커밋에 고정(exact-sha pin)된 설치는 `이전 → 새 커밋` 확인을 명시적으로 통과해야만 핀이 이동한다. 최종 승인은 herdr의 인터랙티브 설치 프리뷰(커밋, build 커맨드, 액션, 훅)에서 이뤄지며, 이미 최신이면 건너뛴다 |
| `U` | **전체 업데이트** — 업데이트가 있는 플러그인을 한 번에 갱신한다. 대상 목록을 먼저 보여주고 `y/N` 확인을 받으며, ref 시맨틱은 `u`와 동일하다. herdr 트러스트 프리뷰가 설치마다 그대로 게이트 역할을 하므로 하나를 거절해도 나머지는 계속 진행된다. exact-sha 핀과 로컬 링크 플러그인은 조용히 건너뛴다 (핀 이동은 플러그인별로 판단할 일이기 때문) |
| `e` | enable ↔ disable 토글 |
| `x` | 삭제 — `y/N` 확인 후 uninstall (로컬 링크 플러그인이면 unlink) |
| `o` | 선택한 플러그인의 GitHub repo를 브라우저로 열기 (subdir 플러그인은 설치된 커밋의 해당 subdir로 이동) |
| `c` | 전역 플러그인 레지스트리 `~/.config/herdr/plugins.json`을 `HERDR_PM_EDITOR` → `VISUAL` → `EDITOR` 순서로 열기 (`code`는 호환용 fallback) |
| `m` | **마켓플레이스** — 커뮤니티 플러그인 탐색 (아래 참조) |
| `r` | 목록 새로고침 (업데이트 재확인 포함) |
| `q` / `Esc` | 닫기 |

#### 액션 아코디언 (`Enter`)

액션을 선언한 플러그인은 행 끝에 `›` 표시가 붙는다. `Enter`로 펼치면 액션들이 `↳ id — 제목` 형태로 아래에 나열되고, 액션 행에서 다시 `Enter`를 누르면 **popup이 닫히면서 그 액션이 실행**된다 (`herdr plugin action invoke` — 키바인딩으로 호출하는 것과 동일한 경로). popup을 먼저 닫는 이유: pane/popup을 여는 액션은 popup이 떠 있는 동안 herdr가 거부하기 때문에, 분리된 헬퍼가 popup 종료를 기다렸다가 실행한다.

액션 행에는 herdr 설정(`config.toml`의 `[[keys.command]]`)에 **바인딩된 단축키**(`prefix+p` 등)가 함께 표시되고, 하단 상세에는 바인딩 여부와 그 액션이 실행하는 커맨드까지 보인다:

```
  ▸ ● Plugin Manager           0.1.0    ⌄
       ↳ open           Open plugin manager        prefix+p
    ● Space Stats              0.1.0    ›
  ──────────────────────────────────────────
  action  ray.plugin-manager.open
  key     prefix+p
  cmd     bash -c exec "${HERDR_BIN_PATH:-herdr}" plugin pane ope…
```

바인딩이 없는 액션은 `key — not bound`로 표시된다 — 자주 쓰는 액션이면 config.toml에 키를 달라는 신호다.

#### 표시등 (● / ○)

| 표시 | 의미 |
|------|------|
| 🟢 `●` | enabled · 최신 상태 |
| 🟡 `●` `↑ update → 0.2.0` | enabled · GitHub 원본에 더 새 커밋이 있음 → `u`로 업데이트 (`U`는 전부 한 번에) (원격 `herdr-plugin.toml`에서 버전을 읽어올 수 있으면 화살표 뒤에 표시, 못 읽어오면 버전 없이 `↑ update`만 표시) |
| ⚪ `○` `(disabled)` | disabled |

popup을 열면 목록이 즉시 그려지고, 곧이어(≈0.5초) 각 GitHub 플러그인의 설치 커밋 sha를 `git ls-remote`로 요청 ref(없으면 기본 브랜치 HEAD, 특정 커밋 고정 설치는 항상 최신 취급)의 최신 커밋과 비교해 표시등을 초록/노랑으로 확정한다. 업데이트가 있으면 그 커밋 시점의 `herdr-plugin.toml`을 `raw.githubusercontent.com`에서 읽어와 버전 문자열도 함께 보여준다 (실패해도 상태 확인 자체에는 영향 없음). 로컬 링크(`herdr plugin link`) 플러그인은 업데이트 확인과 `u` 대상에서 제외된다 — 로컬 checkout에서 직접 갱신하면 된다.

#### 자동 영문 전환 (macOS)

herdr의 `switch_ascii_input_source_in_prefix` 옵션처럼, **popup이 열릴 때 입력소스가 한글 등 비-ASCII IME면 자동으로 영문 자판으로 전환**해 단일 키 조작이 바로 먹게 하고, **popup이 닫히면 원래 입력소스로 복원**한다. macOS의 Text Input Source API를 osascript(JXA)로 호출하므로 별도 설치가 필요 없다. 복원은 popup 프로세스를 감시하는 분리된 watchdog이 수행해서 `q`/`Esc`는 물론 pane이 강제로 닫혀도 동작한다. 끄려면 `HERDR_PM_ASCII_INPUT=0`을 popup 환경변수로 넘기면 된다.

### 마켓플레이스 (`m`)

![marketplace view — community plugins sorted by stars](assets/market.png)

[herdr.dev/plugins](https://herdr.dev/plugins/)와 같은 인덱스 — GitHub에서 `herdr-plugin` topic이 붙은 공개 저장소를 보여준다 (herdr.dev 페이지 자체가 이 topic의 자동 인덱스라서, 원본인 GitHub Search API를 직접 조회한다). 10개씩 페이지로 나뉘고 하단에 `‹ 1 … 4 [5] 6 … 29 ›` 페이지 바가 표시된다. 데이터는 API에서 50개 단위로 필요한 페이지만 가져온다 (검색 API 상한 1000개).

요청은 토큰이 있으면 인증한다 — `GH_TOKEN` → `GITHUB_TOKEN` → `gh auth token` 순서. 비인증 검색은 IP당 분당 10회, 인증은 30회이며, herdr 서버 환경에는 셸에 토큰이 있어도 `GH_TOKEN`이 없는 경우가 대부분이라 `gh` fallback이 보통 마켓플레이스를 매끄럽게 유지해 준다. `HERDR_PM_NO_TOKEN=1`이면 비인증으로 강제한다. 실패 시에는 원인(HTTP 상태와 GitHub 메시지, 타임아웃, 연결 실패)을 그대로 보여준다.

| 키 | 동작 |
|----|------|
| `j` / `k` / `↑` / `↓` | 항목 이동 (페이지 경계를 넘으면 자동으로 다음/이전 페이지). 각 행 맨 왼쪽에 전체 결과 기준 1부터 시작하는 순번이 표시된다 |
| `←` / `→` (또는 `h` / `l`) | **페이지 넘기기** (끝에서 wrap) |
| `/` | **검색** — 입력한 단어로 GitHub API에 재질의 (`topic:herdr-plugin + 검색어`). 로드된 목록만 거르는 게 아니라 topic 전체의 이름·설명·README를 검색한다. 빈 입력 + Enter = 전체 목록으로 복귀, Esc = 아무것도 바꾸지 않고 취소 |
| `s` | **정렬 토글** — 별점순(stars) ↔ 최근 업데이트순(updated) |
| `Enter` | **선택한 플러그인 설치** — `y/N` 확인 후 herdr의 인터랙티브 설치 프리뷰(대상 커밋, build 커맨드, 액션, 훅, pane)를 보여주며, 거기서 최종 승인해야 실제로 실행된다. 이미 설치된 항목(`✓`)은 안내만 표시 |
| `o` | 해당 repo를 브라우저로 열기 |
| `r` | 현재 검색·정렬 기준으로 처음부터 다시 가져오기 |
| `q` / `Esc` / `m` | 설치된 플러그인 목록으로 돌아가기 |

현재 검색어와 정렬 기준은 헤더에 표시된다 (예: `"viewer" · sort: stars [updated]` — 대괄호가 현재 활성화된 기준). 네트워크가 없거나 GitHub API rate limit(비인증 검색 분당 10회)에 걸리면 실패 안내가 뜨고, 커서와 로드된 목록은 그대로 유지된다. 일부 저장소는 플러그인이 subdir에 있어 루트 설치가 실패할 수 있는데, 그 경우 `o`로 repo를 열어 README의 설치 경로를 확인한 뒤 `herdr plugin install owner/repo/subdir`를 직접 실행하면 된다 (popup에는 설치 기능이 없다 — 설치는 마켓플레이스의 `Enter`를 통해서만 한다).

### Dry-run 모드

실제 명령을 실행하지 않고 어떤 명령이 실행될지만 보여주는 모드. 검증·데모용.

```bash
herdr plugin pane open --plugin ray.plugin-manager --entrypoint manager \
  --placement popup --focus --env HERDR_PM_DRY_RUN=1
```

install / update / uninstall / enable / disable / repo 열기 / plugins.json 열기가 전부 `[dry-run] ...` 출력으로 대체된다. 목록 조회·업데이트 확인 같은 읽기 동작은 그대로 실행된다.

### 요구 사항

- herdr 0.7.4+
- `python3` (macOS 기본 포함 — JSON 파싱에만 사용)
- `git` (선택 — 업데이트 표시등용. 없으면 표시등만 생략)
- `curl` (macOS 기본 포함 — 마켓플레이스 조회 및 업데이트 대상 버전 조회용)
- `gh` (선택 — 환경에 토큰이 없을 때 마켓플레이스 인증용)
- 브라우저 오프너 (`o` 키용 — macOS `open` / Linux `xdg-open`)
- `c` 키용 편집기 명령 (선택 — `HERDR_PM_EDITOR`, `VISUAL`, `EDITOR` 중 하나; 없으면 `code`를 fallback으로 사용)

`c` 키는 `HERDR_PM_EDITOR` → `VISUAL` → `EDITOR` → `code` 순서로 편집기를
찾는다. 선택된 명령은 팝업의 foreground 터미널에서 그대로 실행되므로 `nvim`
같은 터미널 편집기도 정상 동작한다. `HERDR_PM_EDITOR`는 herdr 서버가 사용자
셸 환경(`VISUAL`/`EDITOR`)을 물려받지 못하는 상태로 떠 있을 때 유용하며,
실행 파일 하나 또는 래퍼 스크립트로 지정한다.

### 개발

```bash
herdr plugin link /path/to/herdr-plugin-manager   # 로컬 개발용 링크
herdr plugin action invoke ray.plugin-manager.open
```

TUI 로직은 herdr popup 없이도 PTY에서 직접 테스트할 수 있다:

```bash
HERDR_PM_DRY_RUN=1 bash bin/manager.sh
```

테스트는 `git` · `curl` · herdr CLI를 전부 스텍으로 대체하므로 네트워크도, herdr 설치도, 본인 플러그인도 필요 없다. `tests/cases/e2e_bulk_update.sh`는 플러그인 6개짜리 픽스처 목록을 두고 실제 popup을 구동한다. `python3`·`perl` 필요, bash 3.2에서 동작한다.

```bash
bash tests/run.sh              # 전체
bash tests/run.sh bulk_loop    # 이름이 맞는 케이스만
```

#### 구조

- `herdr-plugin.toml` — popup pane(`manager`) + workspace action(`open`) 선언
- `bin/manager.sh` — TUI 본체 (bash 3.2 호환 · 설치 목록/마켓플레이스 2개 뷰 · 버퍼 단일 출력 방식의 flicker-free 렌더링)
- `bin/parse_list.py` — `herdr plugin list --json` → 탭 구분 행 변환
- `bin/parse_market.py` — GitHub Search API 응답 → 탭 구분 행 변환
- `tests/` — 오프라인 테스트 (`cases/` 케이스 · `lib/stubs/` git·curl·herdr 스텁 · `fixtures/` 플러그인 목록)
