# Changelog

Notable changes per release. Versions are the `version` field in
`herdr-plugin.toml`, which is what `u` compares against when it decides a
plugin is behind.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Fixed

- Marketplace calls now authenticate when a token is available, resolving
  `GH_TOKEN`, then `GITHUB_TOKEN`, then `gh auth token`. Anonymous search
  allows 10 requests/minute per IP and authenticated allows 30, so this keeps
  the marketplace well inside budget and makes its requests attributable. Set
  `HERDR_PM_NO_TOKEN=1` to force anonymous calls.
- The marketplace page timeout is 20s instead of 8s. A 50-item page is roughly
  330KB and the old cap flaked mid-download on a slow link.
- A failed marketplace fetch reports the real reason (HTTP status and GitHub's
  own message, or a timeout or connection failure) instead of one generic
  "offline or rate limit" line.

## [0.4.1] — 2026-09-18

### Fixed

- The `c` key now honors `HERDR_PM_EDITOR`, then `VISUAL`, then `EDITOR`,
  falling back to `code`, instead of always invoking `code`. The selected
  editor runs in the popup's foreground terminal, so terminal editors such
  as `nvim` work correctly.

## [0.4.0] — 2026-09-17

### Added

- The header shows how many plugins are installed, and once the update check
  finishes, how many are up to date vs outdated.
- A scrollbar on the right edge of the installed list, shown once it has more
  rows than fit in the 8-row visible window.
- A github plugin shows a hollow green dot while its update check is still
  running, instead of a filled dot that looks like a confirmed "up to date"
  before the check has actually returned.

## [0.3.0] — 2026-09-16

### Added

- `U` updates every outdated plugin in one pass, after a confirm that lists
  what is about to move. Same ref semantics as `u`, and herdr's trust preview
  still gates each install, so declining one leaves the rest of the batch
  running. Exact-sha pins are passed over silently and locally linked plugins
  are excluded, as in the update check. ([#8])
- An offline test suite: `bash tests/run.sh`. `git`, `curl` and the herdr CLI
  are stubbed, so a run needs no network, no herdr install and none of your own
  plugins. Runs on bash 3.2.

### Changed

- `U` was an alias of `u`; it now runs the batch.
- The update footer points at `U` once more than one plugin is behind.

## [0.2.2] — 2026-09-16

### Fixed

- Plugins pinned to an annotated tag were permanently reported as having an
  update: the installed commit sha was compared against the tag object sha,
  which can never match. The peeled commit sha is now resolved, which also
  fixes the 404 when reading the target version from the remote manifest.
  Thanks [@e-kotov]. ([#5])
- Invoking an action silently did nothing about one press in three. The popup
  exited as soon as the detached helper was spawned, and herdr's teardown of
  the pane's process group could reach the helper before `setsid()` returned.
  The popup now waits for the helper to signal that it has detached.
  Thanks [@lamngockhuong]. ([#6], [#7])

## [0.2.1] — 2026-09-04

### Fixed

- Marketplace repo names are validated before an install or a browser open.
  ([#4])

### Added

- MIT license.

## [0.2.0] — 2026-08-19

### Fixed

- Updates preserve the ref an install requested: branch and tag installs follow
  their own ref, and an exact-sha pin only moves after an explicit confirm.
- Installs and updates route through herdr's interactive trust preview.

## [0.1.3] — 2026-08-12

### Added

- Marketplace sort indicator, row index numbers, cancelable search, larger
  popup.

## [0.1.2] — 2026-08-12

### Added

- Update rows show the version an update would move to, read from the remote
  manifest.

## [0.1.1] — 2026-08-12

### Added

- Action accordion in the installed list, showing each action's configured
  keybinding.
- Marketplace pagination, search and sort.
- Automatic ASCII input source while the popup is open (macOS).

### Fixed

- The popup closes before an invoked action runs.
- Sub-second Esc quit, and a hard timeout on update checks.
- Toggle and uninstall report a one-line status instead of the CLI's raw JSON.

## [0.1.0] — 2026-07-21

Initial release: a popup TUI over the `herdr plugin` CLI — list, install,
update, enable/disable, uninstall, and a marketplace browser.

[Unreleased]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.2.2...v0.3.0
[0.2.2]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.2.1...v0.2.2
[0.2.1]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.2.0...v0.2.1
[0.2.0]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.1.3...v0.2.0
[0.1.3]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.1.2...v0.1.3
[0.1.2]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.1.1...v0.1.2
[0.1.1]: https://github.com/speardragon/herdr-plugin-manager/compare/v0.1.0...v0.1.1
[0.1.0]: https://github.com/speardragon/herdr-plugin-manager/releases/tag/v0.1.0
[#4]: https://github.com/speardragon/herdr-plugin-manager/pull/4
[#5]: https://github.com/speardragon/herdr-plugin-manager/pull/5
[#6]: https://github.com/speardragon/herdr-plugin-manager/issues/6
[#7]: https://github.com/speardragon/herdr-plugin-manager/pull/7
[#8]: https://github.com/speardragon/herdr-plugin-manager/issues/8
[@e-kotov]: https://github.com/e-kotov
[@lamngockhuong]: https://github.com/lamngockhuong
