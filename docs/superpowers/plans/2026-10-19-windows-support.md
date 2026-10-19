# Windows Support Implementation Plan

> Execute inline in this session; the user has authorized implementation, publishing, and issue follow-up.

**Goal:** Resolve #13 with a Windows Git Bash entrypoint while preserving existing Unix entrypoints.

**Architecture:** Add platform-scoped Windows pane/action IDs because herdr rejects duplicate IDs. A PowerShell launcher locates Git Bash explicitly. Shared Bash startup selects a working Python 3 interpreter and normalizes native Windows paths.

**Tech Stack:** Bash 3.2+, Python 3, Windows PowerShell, Git for Windows, GitHub Actions.

## Global Constraints

- Preserve macOS/Linux commands and bash 3.2 compatibility.
- Keep interactive install previews attached to stdin.
- Never choose the WSL bash launcher on Windows.
- Credit @jalezi; disclose any Windows verification limits.

### Task 1: Windows startup and shared runtime

- [x] Add `bin/windows.ps1`: find Git Bash from override, standard install paths, or Git location; launch manager or open the Windows popup.
- [x] Add `bin/runtime.sh`: detect MSYS, normalize paths, probe Python 3 (`python3`, `python`, `py -3`) and force UTF-8 output.
- [x] Scope existing manifest entries to macOS/Linux; add `manager-windows` and `open-windows`, version 0.6.0.
- [x] Use runtime startup in manager and add Windows URL opening with Python `os.startfile`.
- [x] Test Python fallback, missing interpreter, paths containing spaces, URL argument preservation, and unchanged Unix behavior with `bash tests/run.sh`.

### Task 2: Verification and publication

- [x] Add Windows Git Bash CI, including PowerShell launcher integration coverage.
- [x] Document Windows prerequisites, binding, overrides, and native config location in both README languages; credit the reporter in CHANGELOG.
- [x] Run syntax checks, full suites on bash 3.2 and modern bash, and `git diff --check`.
- [ ] Commit and publish, inspect CI, fix failures, merge once green, release 0.6.0.
- [ ] Post an English issue reply with release link, Windows setup, tested behavior and limitations; close #13 and verify state.
