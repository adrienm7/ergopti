# Update and download windows

Audited source: `7b7e0eec1f` (`dev`). Date: November 21, 2026. Fifth campaign
in the order of the [2026-11-19 census](../2026-11-19-census/report.md), after
the [tray adapters](../2026-11-20-tray-adapters/report.md). The
[updater campaign](../2026-11-11-updater/report.md) and its
[follow-up](../2026-11-12-updater-followup/report.md) read the check, the
schedule, the channels and the asset binding; this one reads the windows the
user sees around them, and the install each window starts.

## Scope

The Updates window, the download window and the Versions window on the three
drivers, and the install path each one drives:

- Windows: `ui/update_check/init.ahk`, `ui/download_window/init.ahk` and
  `session.ahk`, `ui/changelog/init.ahk`, and the updater behind them
  (`modules/updater/self_update.ahk`, `changelog.ahk`, `core.ahk`,
  `asset_signature.ahk`, `release_install.ahk`, the staging and swap workers);
- macOS: `ui/update_check/init.lua`, `ui/download_window/*.lua`,
  `ui/changelog/init.lua`, `modules/updater/auto_check.lua` and
  `release_installer.lua`, the Sparkle prompts of the launcher
  (`CatalogUpdateUserDriver.swift`, `UpdatePromptPanel.swift`,
  `UpdatePromptTexts.swift`);
- Linux: `ui/update_check/bridge.lua`, `ui/download_window/bridge.lua`,
  `ui/changelog/bridge.lua`, `modules/updater/manager.lua` and
  `archive_transfer.lua`, the completion hook in `ergopti_hotstrings.lua`;
- shared: the pages `_shared/ui/update_check/`, `download_window/`,
  `release_notes/` and `changelog/`, `update_channels.js`, `version_order.js`,
  and the Lua session `_shared/updater/engine/check_session.lua` with
  `check_result.lua` and `release_install.lua`.

Read for each: the states (checking, available, downloading, verifying,
ready, error), progress and cancellation, the digest and signature checks,
the feed-only fallback, the localized errors (proxy, offline, disk full), the
keyboard and screen-reader access, the preferences read, the relaunch after
install and the teardown. Source reading, the shared page under a minimal DOM,
the AutoHotkey suites and the Linux suite under WSL; no update was downloaded
or installed, and no window was rendered.

Checked and kept:

- **States.** The three Updates windows show one shared page with the same
  five phases (`checking`, then `up_to_date`, `available`, `no_release` or
  `error`), from `UC_ANSWER_STATES` on Windows and `check_result.STATES` in Lua,
  which `test-update-check-dialog.cjs` keeps equal. None shows downloading or
  verifying: the window closes on Update and the install reports elsewhere
  (Windows: the tray row `menu.about.update_downloading` and a modal box at the
  end; macOS: the Sparkle panels; Linux: the download window, kind
  `app_update`). The Versions window carries the install phases on the three
  (`backing_up`, `downloading`, `installing`, `restarting`, `failed`).
- **Digest and signature.** Windows checks the SHA-256 in its staging worker,
  Linux in its archive transfer, the macOS Versions path in `release_stage.sh`
  (with the bundle version and the code signature); Sparkle checks its EdDSA
  key. `asset_signing.json` is `off` with no key, so a missing signature is a
  logged warning on Windows and Linux; a feed release needs one everywhere and
  is refused without a key. See UPD-10 for the words.
- **Feed-only fallback.** When the API gives no list, the three read the
  public feed. Windows and Linux mark the answer `check_only`: the page hides
  Update and says why (`update_check.check_only`). macOS never marks it, and
  rightly: its Update hands off to Sparkle, which installs from its appcast,
  not from the API (UPL-003 did not apply either).
- **Reading preferences.** The three seed `script.reading_font` and
  `script.reading_spacing` into the page (`window.__ergopti_reading`); the
  theme follows the system through CSS and `a11y_prefs.js`.
- **Relaunch.** Each install keeps the previous build and puts it back when
  the new one does not report ready: the Windows swap script (`.bak` and boot
  probation), the macOS swap (`ErgoptiPlus.app.previous`), the Linux restart
  watcher. A Linux system package is left to its package manager.
- **Teardown.** Each window binds its messages to one session and one epoch:
  `_UC_WindowEpoch` and the request id on Windows, the session generation in
  `check_session.lua` and the window identity on macOS and Linux. A late
  answer or a message of a closed window is inert. At exit, Windows kills its
  staging worker and drops its files; Linux cancels its transfer.

## Fixed

| Id     | OS      | Sequence                                                                       | Reference                                                                                                                                       | Before                                                                                                                                                                                                                                       | Regression                                                                                                     |
| ------ | ------- | ------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| UPD-01 | Windows | Updates window, Update, and the staged file fails its SHA-256 check            | The Windows Versions window and the Linux download window say `changelog_window.install_error_verify` (« The integrity check of {tag} failed ») | No Versions window follows an install started from the Updates window, so `_Updater_PublishManagedFailure` fell to the modal box `updater.install_error_download`: « Failed to download the update package. Check your internet connection » | `an unfollowed refused digest names the integrity check (upd-01)` (`test_release_install.ahk`)                 |
| UPD-02 | Linux   | Update, then Cancel in the download window                                     | Windows has no cancel; Sparkle names its own cancellation. Each kind's text belongs to that kind                                                | `cancel_from_presentation` wrote `ollama.download_cancelled` for every kind: a cancelled ErgoptiPlus update read « Ollama download cancelled »                                                                                               | `upd-02: a cancel leaves the line of the download's own kind` (`test_bridge_handlers_locale_routing_i18n.lua`) |
| UPD-03 | all     | Open the Updates window and press Escape                                       | The Windows native window (no WebView2) closes on Escape (`_UpdateCheck_BuildNative`)                                                           | On the three WebViews the page holds the focus: the Windows Gui `Escape` event never fires, and neither WebKit host reads the key. Escape did nothing                                                                                        | `Keyboard And Screen Reader (UPD)` (`test-update-check-dialog.cjs`)                                            |
| UPD-04 | all     | A screen reader at the Updates window while « checking » turns into the answer | The page's status line is already a polite live region                                                                                          | `line1` and `line2`, which carry « Checking… » and then the answer, were plain paragraphs: the answer was drawn, never announced, unless the user moved through the page                                                                     | `Keyboard And Screen Reader (UPD)` (`test-update-check-dialog.cjs`)                                            |

Notes:

- **UPD-01.** `_Updater_StagingFailureNotice` words the box of a staging
  failure nobody follows: a `verify` failure names the integrity check of the
  release, a transfer failure keeps `updater.install_error_download`. The
  release tag now reaches `_Updater_PublishManagedFailure` from
  `_Updater_PollDownloadAsync`.
- **UPD-02.** The Linux bridge's `KINDS` table now holds each kind's cancel
  key: `ollama.download_cancelled` for a model, the new
  `updater.download_cancelled` for an update (21 locales).
- **UPD-03 and UPD-04.** One fix in the shared page covers the three drivers:
  Escape posts `close`, which every host admits in any phase (`UC_PAGE_ACTIONS`,
  `check_session` `ACTIONS`), and an Escape another control already handled is
  left alone. The download window keeps no Escape: there it would cancel a
  download.

### Fixed in the follow-up

The follow-up of the same day closed UPD-05 to UPD-12. UPD-05 is a decision
the agent took with Windows as the reference while the maintainer was asleep;
it is recorded in [maintainer-decisions.md](../../../memory/maintainer-decisions.md)
for the maintainer to review.

| Id     | OS             | Sequence                                                         | Reference                                                                | Before                                                                                                                                                                                                      | Regression                                                                                                                                                                                                                                        |
| ------ | -------------- | ---------------------------------------------------------------- | ------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| UPD-05 | Linux, macOS   | Update, then close the download window while it downloads        | Windows installs whatever window is open; closing a window is not Cancel | Linux refused the verified archive (« native install refused ») because the closed window retired the document the install admission needed; macOS cancelled the update when its download panel closed      | `upd-05: an update whose download window was closed still installs` and `… never opened still installs` (`test_update_check_async_admission.lua`); `testClosingTheDownloadWindowKeepsTheUpdateGoing` (Swift, not run here)                        |
| UPD-06 | all            | A manual check behind a refusing proxy, offline, or rate limited | Windows names the managed-network cause of its receipt                   | macOS and Linux said « Could not reach GitHub » for every failure; no window named a rate limit; Windows replaced it with « diagnostics do not establish the cause » for an unknown cause                   | `failure_reasons` of `check_session_vectors.json`, replayed by `check_session_contract.lua` (macOS, Linux) and `test_updater_check_session_vectors.ahk`; `upd-06: names …` (`test_updater_check_only_fallback.lua`, `test_update_auto_check.lua`) |
| UPD-07 | Windows, Linux | Update, then watch the download                                  | Sparkle shows a fraction and a Cancel button                             | The Windows staging worker reported nothing before its last line and had no user cancel; the Linux window stayed at 0 % « Starting… » until the end                                                         | `Updater: the staging bytes reach the download window as a percentage (upd-07)` and three siblings (`test_updater_install_deadlines.ahk`); `upd-07: …` (`test_update_check_bridge.lua`, `test_archive_transfer_signature.lua`)                    |
| UPD-08 | Linux          | Update, then Cancel, or a failed download                        | The Versions path keeps the offer                                        | `download_update` returned to `idle`, so the menu dropped « Update now » until the next check                                                                                                               | `upd-08: a failed update download keeps the offer it failed on` (`test_production_dispatch_refusal.lua`)                                                                                                                                          |
| UPD-09 | Linux          | An installed update whose restart is refused                     | The Versions window keeps a pending restart and says so                  | « installed, restarting » was notified and shown before the restart was tried, whatever it answered                                                                                                         | `upd-09: the completion hook notifies only after the restart answered` (`test_updater_restart.lua`), `upd-09: the window reports the restart only once it is armed` (`test_update_check_bridge.lua`)                                              |
| UPD-10 | all            | A release whose signature is refused                             | A digest refusal is named as one                                         | Windows said « unexpected error » (API) or « Could not install the update » (feed); Sparkle's signature error fell to `updater.install_error`; Linux and the macOS Versions window said « integrity check » | `AssetSignature: a refused signature is named as one (upd-10)` (`test_asset_signature.ahk`); `upd-10: …` (Linux and macOS suites); `testErrorsNeverShowSparkleText` (Swift, not run here)                                                         |
| UPD-11 | macOS          | A Versions-window install whose download fails                   | The Linux and Windows Versions windows classify their receipts           | `done(nil, stage, detail)` passed no receipt, so a proxy or offline failure read « download failed »; the failed stage folder stayed beside the app                                                         | `upd-11: …` (`test_release_installer.lua`, the staging script under `/bin/sh` with fake tools)                                                                                                                                                    |
| UPD-12 | shared         | A locale without a download label; a page drawn while loading    | Every other page label hides when its key is missing                     | `update()` fell back to « 📁 Files: », « 📦 Size: », « ⚡ Speed: »; `lang` stayed `fr` until DOMContentLoaded                                                                                               | `upd-12` cases of `test-download-window-session.cjs` and `test-webview-i18n-cascade.cjs`                                                                                                                                                          |

Notes:

- **UPD-05.** The Linux install is admitted by the offer's own consent
  (`ui/update_check/bridge.lua` `admit_install`); `download_window/bridge.lua`
  no longer exports `install_admission_current`. The macOS close box hides
  the Sparkle download (`downloadHidden`) until its next step or the menu's
  update row; closing the checking panel still cancels the check. The new
  Windows download window (UPD-07) keeps the rule.
- **UPD-06.** One rule, `check_result.failure_key` and its AHK twin
  `UpdateCheck_FailureKey`: an exhausted rate limit
  (`update_check.error_rate_limited`, 21 locales), else a network cause the
  managed-network contract classified from the fetch's native receipt (an
  unknown cause proves nothing), else the reason's own key. `check_session`
  admits only those keys. Linux carries its curl receipt and the API page's
  rate limit; Windows records the rate limit on its request. macOS named the
  rate limit only: hs.http answers a transport failure with status -1 and a
  localized sentence, which the contract may not interpret (UPD-13, fixed
  below).
- **UPD-07.** Windows reads the bytes its staging worker wrote into the
  parent-owned capture (`ObserveBody`) at each monitor tick and shows them in
  the shared download window, kind `app_update`
  (`UpdateDownloadProgressWindow`, configured at boot); its Cancel ends the
  transaction. Linux tells the bytes its curl archive output received
  (`on_progress`) against the size GitHub declares for the asset
  (`release_parser.parse_asset_size`), never trusted for a check.
- **UPD-09.** A refused restart is notified and shown as
  `updater.installed_restart_refused` (21 locales) and logged; the old daemon
  keeps running.
- **UPD-10.** A refused signature has its own stage (Linux archive transfer,
  macOS `release_stage.sh` exit 27), its own shared reason
  (`release_install.download_reason`, `RELEASE_INSTALL_REASONS.signature`) and
  its own words: `updater.install_error_signature` and
  `changelog_window.install_error_signature` (21 locales).
- **UPD-11.** `release_stage.sh` prints one closed fact for a failed download
  (`FAILED curl:<exit>` or `FAILED native:<reason>`), which
  `release_installer.failure_receipt` maps to the managed-network fields it
  proves and no more; an EXIT trap removes the stage it created unless an app
  is READY.

### Fixed in the second follow-up

| Id     | OS    | Sequence                                                                                     | Reference                                                                         | Before                                                                                                                                        | Regression                                                                                                                                                                                                                  |
| ------ | ----- | -------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| UPD-13 | macOS | A manual check offline, behind a proxy asking for credentials, or with a refused certificate | Windows and Linux name the managed-network cause of their native receipt (UPD-06) | hs.http answered status -1 and a localized sentence, which the contract may not interpret: every such failure read « Could not reach GitHub » | `native_receipts` of `check_session_vectors.json`, replayed by `check_session_contract.lua` (macOS, Linux) and `upd-13: …` (`test_update_auto_check.lua`); `test_managed_http_protocol.lua`, `test_managed_http_worker.lua` |

Notes:

- **UPD-13.** The manual check's transport is now
  `core/network/adapters/managed_http_worker.lua`: it runs the launcher's
  existing `--managed-http-worker` role (ManagedHTTPWorker.swift, unchanged),
  which resolves the system proxy route and the certificate trust itself and
  ends a failed transfer with a closed reason derived from the NSURLSession and
  CFNetwork error codes. `core/network/engine/managed_http_protocol.lua` reads
  its frames (one head, the body, one terminal frame; anything else is refused
  whole) and owns the reason → receipt table that `release_installer` used to
  keep alone (UPD-11). `auto_check` classifies the API attempt's receipt
  through the shared contract and hands the report to
  `check_result.failure_key`, as Linux does: `offline`, `certificate` and
  `proxy` are named; `connect`, a deadline or an unavailable route prove no
  cause and keep « Could not reach GitHub ». No text is read for a cause.
- **Limits.** The worker reports `proxy` for a proxy that asks for credentials
  (407) or a proxy route it cannot build; a proxy that refuses the TCP
  connection is `connect` and stays unnamed, as on the Versions path. The
  worker follows no redirect, so a redirected API or feed URL reads as its 3xx
  answer and fails the check honestly. The background check stays on hs.http:
  its failure is only logged.

Native receiving, in `TODO-tests-windows.md`, `TODO-tests-macos.md` and
`TODO-tests-linux.md` (field point `update_windows` on macOS and Linux):
Escape and the screen reader at the Updates window on the three (UPD-03,
UPD-04), a digest refused through a local release mirror on Windows (UPD-01),
the Windows download window's bar, Cancel and close box (UPD-05, UPD-07), the
macOS download panel closed and a Versions install with the network down
(UPD-05, UPD-11), and a cancelled then a closed Linux update download (UPD-02,
UPD-05, UPD-07 to UPD-09).

## Proof

Commits `f93e67284e` (UPD-01), `5cf83571af` (UPD-02), `0da002fe4b` (UPD-03,
UPD-04).

- **Red on the old code.**
  - UPD-01: with `self_update.ahk` from `7b7e0eec1f`,
    `node tools/test/ahk-parallel.cjs --fresh --only="release install"`
    gives 15 of 16, the new case failing because `_Updater_StagingFailureNotice`
    does not exist.
  - UPD-02: with `download_window/bridge.lua` from `7b7e0eec1f`, the new Linux
    case fails on « app_update cancel reads: … done(false,"Téléchargement Ollama
    interrompu",null) ».
  - UPD-03 and UPD-04: with `update_check/index.html` and `script.js` from
    `7b7e0eec1f`, `test-update-check-dialog.cjs` fails four checks (Escape posts
    nothing and is not consumed; `#line1` and `#line2` are not live regions).
- **Green on the new code.** `ahk-parallel --only="release install"` 16 of 16;
  the Linux suite from an archive copy under WSL (`unset DISPLAY
WAYLAND_DISPLAY`, `luajit tests/run.lua --only=upd-02`): 1 passed, 0 failed;
  `test-update-check-dialog.cjs`: 1,420 checks.
- **Gates.** `test-ahk-encoding.cjs`, `test-app-windows-semantic-markup.cjs`,
  the locale gates (`test-locale-*`, `test-action-labels-have-locale-keys.cjs`),
  `test-shared-literal-inventory.cjs`, `test-linux-feature-parity.cjs`,
  `test-no-pinned-source-reads.cjs` (170 of 170), `-lua.cjs` and `-linux.cjs`,
  `test-error-messages-say-how-to-recover.cjs`,
  `tools/dev/field-todo-summary.py --check-doc` for Linux and macOS,
  `lint-conventions.js --fail-on-violations` and the formatter.
  `test-app-windows-accessibility-ratchet.cjs` was red before this campaign and
  is untouched by it (« physical_shortcuts loads a11y_prefs.js after a
  stylesheet »).
- **Not run here.** The macOS suites (no macOS Lua changed); the full Linux
  suite (only the new case ran); a real download, install or Sparkle session;
  `npm run test:js` and `verify-change` (they refuse this checkout's Node pin).

Follow-up commits (UPD-05 to UPD-12): `453047e0fb` (UPD-05), `433fd7b751`
and `90874ec994` (UPD-06), `fc6dcec533` (UPD-07), `677cb83b66` (UPD-08), `1005b168c7` (UPD-09),
`69dcd8eab2` (UPD-10), `7f3cbef3cf` (UPD-11), `0dada9f703` (UPD-12).

- **Red on the old code.** Each regression was run against the owner it
  pins restored from the commit before its fix: UPD-05 (2 cases), UPD-08 (2),
  UPD-09 (4) and UPD-10 (3) fail in the Linux suite; UPD-06 fails 3 Linux
  cases with the old `manager.lua`; UPD-11 fails 3 macOS cases with the old
  `release_installer.lua` and `release_stage.sh`; UPD-10 fails the AHK case
  with the old `self_update.ahk`; UPD-12 fails both page tests with the old
  `i18n.js` and `download_window/script.js`.
- **Green on the new code.** AHK through `ahk-parallel --fresh`: `Updater`
  434 of 434, `update check` 25 of 25, `AssetSignature` 11 of 11, `upd-07`
  5 of 5, `webview` 222 of 222, `boot` 547 of 547; `ErgoptiPlus.ahk` passes
  `/validate`. Linux under WSL from a `git archive` copy (`unset DISPLAY
WAYLAND_DISPLAY`): every `upd-` case green, and the full suite 24,211 passed
  and 178 failed, none in the updater, the update check, the download window,
  curl or the locales: root defeats the `eacces` and read-only fixtures, the
  archive copy lacks `tools/`, `ergopti/` and `TODO-tests-linux.md`, the
  pointer cases need a display, and the rest (`model-cancel-settlement`,
  `native-locale-catalog`) fail on the campaign's base commit too or pass alone
  (`route_message`, `api-selection-errors`). macOS Lua 5.4 under WSL:
  `--module=modules` and `--module=ui` with only such environment failures
  left, `--only=release-` 68 of 68 as an unprivileged user.
- **Gates.** `test-update-check-dialog.cjs`, `test-app-windows-semantic-markup.cjs`,
  the locale gates, `test-shared-literal-inventory.cjs`,
  `test-linux-feature-parity.cjs` (the `linux-control` behaviour owner
  re-pinned after review: its undo did not change), the three
  `test-no-pinned-source-reads*.cjs`, `test-config-key-literals.cjs`,
  `test-release-install-contract.cjs`, `test-ahk-encoding.cjs`,
  `field-todo-summary.py --check-doc`, the formatter and
  `lint-conventions.js --fail-on-violations`.
- **Not run here.** The Swift tests (`CatalogUpdateUserDriverTests`,
  `ReleaseArchiveStagingTests`: no macOS host);
  `test-macos-release-stage-native-receiving.cjs`, red before this follow-up
  too; a real download, install, restart or Sparkle session; `npm run test:js`
  and `verify-change` (they refuse this checkout's Node pin).

Second follow-up commit (UPD-13): `7a5ae7ce9c`.

- **Red on the old code.** With `auto_check.lua` and `release_installer.lua`
  from `2063644afd` (the test's contract port stubbed, since the old owner
  takes none), `test_update_auto_check.lua` fails 4 cases: the offline,
  certificate and proxy vectors read `updater.no_connection`, and the
  production session still checks through hs.http. The vectors that prove no
  cause pass there too, as they must. `test_managed_http_protocol.lua` and
  `test_managed_http_worker.lua` fail: their modules do not exist.
- **Green on the new code.** From a `git archive` copy under WSL
  (`unset DISPLAY WAYLAND_DISPLAY`, unprivileged user): the full macOS Lua 5.4
  suite, 29,179 passed and 3 failed, the same 3 that fail on `2063644afd`
  (`test_no_coauthor_in_commits`: the copy has no Git history;
  `test_native_python_bootstrap_interrupt`: a process-group signal under WSL;
  `prepare and title come from …`); the Linux suite's `upd-13` cases, 8 of 8
  under LuaJIT.
- **Gates.** `test-update-check-dialog.cjs` (1,494 checks), the locale gates,
  `test-shared-literal-inventory.cjs`, `test-linux-feature-parity.cjs`,
  `test-config-key-literals.cjs`, `test-macos-dev-qualification-deferral.cjs`,
  `field-todo-summary.py --os macos --check-doc`,
  the formatter and `lint-conventions.js --fail-on-violations`.
  `test-desktop-ci-evidence.cjs` passes its verdict checks, then stops on a
  Windows fixture (« the native directory identifies another device »), before
  any macOS part.
- **Only macOS proves.** The worker itself (Swift unchanged, so no XCTest
  suite was touched): that a real offline Mac, a proxy asking for credentials
  and a refused certificate end in `offline`, `proxy` and `certificate`, that
  GitHub answers the identity request with the list, its ETag and a 304, and
  that the dev and packaged launchers both resolve. The field point
  `update_windows` of `TODO-tests-macos.md` asks for it.
