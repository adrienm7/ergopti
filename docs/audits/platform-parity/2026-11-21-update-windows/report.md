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

## Open

- **UPD-05 (high, Linux):** closing the download window during an update
  throws the download away. Closing it retires its document
  (`webview_manager.lua` `retire_document_entry`), and the install admission
  (`download_window/bridge.lua` `install_admission_current`, then
  `owner_current` and `document_current`) needs that document, so once the
  verified archive is there the native install is refused (« native install
  refused ») and the user is told the install failed. The download itself goes
  on (`on_window_closed`: « background download ownership and explicit
  cancellation remain independent »), and nothing reopens the window. When the
  window cannot open at all, `download_offered` logs « the update downloads
  without it » and the install is always refused (`session_id == nil`). Windows
  installs whatever window is open; macOS treats closing the Sparkle panel as a
  cancel. Follow-up, a maintainer choice: close cancels (macOS), or the update
  installs without its window (Windows and the comment), with a test that
  closes the window before the archive is verified.
- **UPD-06 (medium, macOS and Linux):** a failed check names no network
  cause. Windows turns the transport's receipt into the shared
  `managed_network.json` cause (`network.failure.proxy`, `offline`,
  `certificate`, `host_blocked`) and adds its actions
  (`update_check/init.ahk`, `_UpdateCheck_ShowManagedFailure`). The Lua session
  knows four reasons only (`check_result.REASONS`): a proxy, TLS or offline
  failure is « Could not reach GitHub » (`manager.lua` `publish_failure`,
  `auto_check.lua` `fail`), though both Lua Versions windows already classify
  receipts with `core.network.engine.failure`. A rate limit is named in no
  Updates window (only in the Versions window, `error_rate_limited`).
  Follow-up: carry the fetch receipt into `CheckResult.failure` and let
  `check_session` admit a canonical message key, as Windows does.
- **UPD-07 (medium, Windows and Linux):** an update download shows no
  progress. The Windows staging worker reports nothing before its last line
  (`$ProgressPreference = "SilentlyContinue"`), and only the tray row says it
  downloads; there is no user cancel (only a pause, the deadline or exit). The
  Linux download window stays at 0 % « Starting… » until the end: nothing calls
  `DownloadWindow.update` for `app_update`. Sparkle shows a fraction and a
  Cancel button.
- **UPD-08 (medium, Linux):** a failed or cancelled update download drops the
  offer. `download_update` returns the updater to `idle`
  (`start_download(..., "idle")`), and the menu offers « Update now » only in
  `available` (`menu_about.lua`); the next check brings it back. The Versions
  path keeps it (`download_release`: « a failure keeps the menu's update
  row »). Existing tests pin `idle` after a refused dispatch
  (`test_production_dispatch_refusal.lua`), so the fix re-pins them.
- **UPD-09 (low, Linux):** « installed, restarting » is said before the
  restart is tried. `on_update_finished` notifies
  `updater.installed_restarting` and ignores what
  `restart_on_installed_release` returns, so a refused restart leaves the user
  on the old daemon with a notice that says otherwise; only the Versions window
  keeps a pending restart row.
- **UPD-10 (low, the three):** no driver names a refused signature. Windows
  says `changelog_window.install_error_unexpected` for an API release
  (`self_update.ahk`), Sparkle's error falls to `updater.install_error`
  (`UpdatePromptTexts.swift`), Linux reports it as `install_error_verify` like
  a digest. Enforcement is off, so only a feed release meets it today.
- **UPD-11 (low, macOS):** the Versions install loses its failure receipt.
  `release_installer.lua` calls `done(nil, stage, detail)` with three
  arguments, so `release_install.lua` classifies `{}`: a full disk or a proxy
  refusal (`release_stage.sh` exit 10) reads as `install_error_download`; and
  a failed stage leaves its `.ergopti-release-install-` folder beside the app.
- **UPD-12 (low, shared):** the download page hard-codes some text. `update()`
  falls back to English (« 📁 Files: %s », « 📦 Size: », « ⚡ Speed: ») when a
  key is missing, and `index.html` says `lang="fr"` (the Updates page says
  `lang="en"`) until i18n applies. The keys exist in the 21 locales, so only a
  broken locale shows it.

Native receiving, in `TODO-tests-windows.md`, `TODO-tests-macos.md` and
`TODO-tests-linux.md` (field point `update_windows` on macOS and Linux):
Escape and the screen reader at the Updates window on the three (UPD-03,
UPD-04), a digest refused through a local release mirror on Windows (UPD-01),
a proxy that refuses the API on macOS (UPD-06), and a cancelled then a closed
Linux update download (UPD-02, UPD-05, UPD-07, UPD-08).

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
