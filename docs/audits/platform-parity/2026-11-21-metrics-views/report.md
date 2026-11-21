# Metrics views

Audited source: `2063644afd` (`dev`). Date: November 21, 2026. Seventh
campaign in the order of the [2026-11-19 census](../2026-11-19-census/report.md),
after the [update windows](../2026-11-21-update-windows/report.md); the sixth,
pickers and prompts, ran beside it and is not read here. The
[metrics campaign](../2026-11-11-metrics/report.md) read the producers and
the store, the [tooltips and WPM campaign](../2026-11-13-tooltips-wpm/report.md)
the widget's show and hide rules; this one reads what the user sees of them.

## Scope

The typing dashboard, the apps dashboard and the WPM widget with its tray or
menu bar readout, on the three drivers:

- Windows: `modules/keystats/keystats_webview.ahk` (the two dashboards' host,
  its warm hosts and pushes), `keystats_prefetch.ahk` and the reader behind it,
  `ui/wpm/*.ahk`, the AI output commit in `ai/engine/bridge.ahk`, and the
  diagnostics host's warm reuse (`diagnostics/ui/healthcheck/core.ahk`) for the
  same reuse rule;
- macOS: `ui/metrics_typing/init.lua`, `ui/metrics_apps/init.lua` with
  `projection.lua` and `snapshot.lua`, `ui/wpm/*.lua` and the live speed of
  `modules/keystats/init.lua`;
- Linux: `ui/metrics_typing/bridge.lua`, `ui/metrics_apps/bridge.lua`,
  `ui/metrics_flush_bridge.lua`, the payloads of `modules/keystats/keystats.lua`
  and `ui/wpm/*.lua`;
- shared: the pages `_shared/ui/metrics_typing/` and `_shared/ui/metrics_apps/`,
  `metrics_calendar.js`, `metrics_freshness.js`, `metrics_rebuild_banner.js`,
  `metrics_chart_values.js`, `metrics_manifest_keys.js`, the WPM canon
  `_shared/metrics/data/wpm_widget/constants.toml`, `wpm_widget_model.lua` and
  `wpm/live_wpm.lua`.

Read for each: the data sources and projections, the privacy filtering, the
periods and time zones, the empty and error states, the localization in 21
locales, the keyboard and screen-reader access, the reading preferences, the
refresh and the teardown. Source reading, the shared pages under a sandboxed
DOM, the AutoHotkey suites and the Linux suite under WSL; no dashboard or
widget was rendered on a desktop.

Checked and kept:

- **Periods and time zones.** The three use the local calendar day (Windows
  `FormatTime(A_Now)`, macOS `os.date`, Linux `calendar.lua`), and both ends of
  a range are inclusive (`keystats_reader_manifest.ahk`, the two
  `sqlite_reader.lua`). The page's default range runs from the first logged day
  to today. Rows carry `utc_offset_min` since KMD-1.
- **Privacy at read time.** No host filters when it reads, and none needs to:
  excluded apps, secure fields and private windows are refused at capture on the
  three (KMD-2), and the pseudo-apps `_sys`, `_system` and `Unknown` are handled
  alike. The live readouts were the exception (MET-02).
- **Projections.** The three count the still-open foreground interval in
  today's app time (macOS `with_live_active_app_duration`, Linux `project_day`,
  Windows `CapturedForeground`). App icons: Windows and Linux send `{}`, only
  macOS extracts them (known limit).
- **WPM speed.** Characters / 5 over the 15 s window with the 2 s floor, from
  the shared timings; backspace never counts; the colour hold, the idle hide,
  the burst keys, the neutral sources and the tray rule are equal; manual and
  hotstring text skip secure fields, private windows and excluded apps on the
  three; the only visible word, `menu.metrics.wpm_unit`, is in the 21 locales;
  geometry, colours and opacity come from the canon alone.
- **Dialogs and tabs.** The app filter and the drill-down have `role="dialog"`,
  `aria-modal`, an inert background, Escape and focus return; the tabs carry
  `role="tab"` and `aria-selected`; the freshness and rebuild banners are polite
  status regions.
- **Reading preferences.** Both pages load `a11y_prefs.js` and `theme.css`;
  macOS keys its HTML cache on the choice and Linux rebuilds the head (Windows:
  MET-03).
- **Teardown.** macOS `on_close` cancels its job, poller and timers; Linux
  revokes requests by window epoch and its poller stops on `pagehide`; Windows
  `KLWV_Hide` retires the range stage and subscriptions, and a page drops
  queued messages of an older window (`host_epoch`). A late reply is inert on
  the three.

## Fixed

| Id     | OS      | Sequence                                                                                  | Reference                                                                          | Before                                                                                                                                                                             | Regression                                                                                                                                      |
| ------ | ------- | ----------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- |
| MET-01 | Windows | Type a burst, stop, watch the tray readout                                                | macOS and Linux read 0 after timings `[keystats] wpm_idle_reset_ms` (5 s)          | `WPMWidget_Calc` used only the 15 s window: the readout kept a falling speed for up to 15 s                                                                                        | `WPM clock: idle-reset-after-burst` and `idle-reset-boundary` (`test_wpm_tick_rollover_owner.ahk`)                                              |
| MET-02 | Windows | Accept an AI suggestion in an excluded app, a private window or a secure field            | Typed and hotstring text, and Linux `record_synthetic_output`, count nothing there | The journal recorded nothing, yet one AI sample per character reached the pill and the tray readout, which sped up and turned the AI colour                                        | `AI output: a privacy-filtered acceptance feeds no WPM sample (met-02)` and two siblings (`test_ai_output_wpm_privacy.ahk`)                     |
| MET-03 | Windows | Close a dashboard or the diagnostics, change the reading font or spacing, reopen          | macOS keys its HTML on the choice; Linux rebuilds the head                         | The warm host's reuse key held the folder, locale and store, and its boot script (the seed) is added once: the window reopened in the old look                                     | `reading preferences: a retained window host follows a changed choice (met-03)` (`test_reading_preferences.ahk`)                                |
| MET-04 | Linux   | Apps dashboard: an incomplete read, then a complete one (or the other way round)          | Windows applies the read state of every push                                       | The poll applied `metrics_manifest_incomplete` and the unmeasured cards from the first answer only: the notice never cleared or never came                                         | `MET-04` block of `test-metrics-apps-linux-poll.cjs`                                                                                            |
| MET-05 | Linux   | Typing dashboard: change the dates while the range read fails                             | Windows sends `range_terminal`, macOS `receive_range_data(null)` at once           | The bridge answered `nil`, which sent nothing: the loader stayed for the 120 s watchdog                                                                                            | `(range-projection-unavailable, met-05)` (`test_metrics_flush_bridge.lua`)                                                                      |
| MET-06 | all     | Typing dashboard: change the dates; the read runs, fails or times out                     | The freshness banner names the state of the data                                   | The loader alone said a read was running, in fixed French on every locale; a failure put the previous table back silently under the new selection; nothing reached a screen reader | `… range read says so beside the previous table (met-06)`, failed and timeout on the three hosts (`test-typing-metrics-range-supersession.cjs`) |
| MET-07 | all     | Any dashboard in a locale other than French                                               | The dates follow `window._i18n_locale`                                             | Every number was French: thin-space thousands, decimal comma, « Md » (`format.js`), `Intl.NumberFormat('fr-FR')` in the apps tables, the OS locale in the chart text alternative   | `test-metrics-number-locale.cjs`                                                                                                                |
| MET-08 | Windows | Narrator on, the WPM widget switched from compact to graph (or rebuilt) at the same speed | Linux clears its name cache with the surface                                       | The name cache held the text alone, so the new window was never named and Narrator read « ErgoptiPlus WPM Graph »                                                                  | `a11y readers: every WPM surface is named at the same speed (met-08)` (`test_accessibility.ahk`)                                                |

Notes:

- **MET-01.** `WPMWidgetConst.IDLE_RESET_MS` is created from the shared timing
  by `WPMWidget_LoadSharedConst`, with no placeholder literal (the shared
  literal inventory counts one), and the calculator reads 0 once the newest
  character in the window is older than it. The three child fixtures pass the
  real timing.
- **MET-02.** The journal commit is bound to its transaction and records
  whether the privacy filter admitted rows (`MetricsRecorded`); the RAM commit
  feeds the readouts only then. A filtered or refused token, or a metrics
  collection that is off, counts nothing, as for typed text.
- **MET-03.** `KLWV_ReuseKey` and `_HC_ReuseKeyFor` carry
  `ReadingPrefs_SeedScript()`, so a changed choice retires the retained host
  (`KLWV_TakeWarmHost`, `_HC_CanReuse`).
- **MET-05.** `fail_range` calls the page's `complete_range_request(id,
"failed")` through `metrics_flush_bridge.call`, for a failed range read, a
  failed dashboard read and a keystats with no range reader, and logs the cause
  without the selection.
- **MET-06.** A polite status region, `#range_status`, stays in the tree and
  says `ui_typing.range_loading`, then `range_failed` or `range_timeout` (each
  with how to try again) beside the restored table, and clears once the data
  lands; the loader reads the same text. Three new keys in the 21 locales.
- **MET-07.** `format_number_parts` formats exactly below a million and in the
  compact notation from a million on, in the seeded interface language; the
  exact-value tooltip and the apps `format_int` use the same locale.

## Open

- **MET-09 (medium, Linux):** the typing heatmap always names the keys in
  QWERTY. Windows sends `keycode_layout` (`KLPF_KeycodeLayout`) and macOS
  `kc_layout` from `hs.keycodes.map`; Linux sends no layout in
  `get_dashboard_payload` nor in the range reply, so
  `build_keycode_layout_for_driver` keeps the static names. Follow-up: project
  the live XKB keymap the daemon already reads into the same `kc_layout` map.
- **MET-10 (medium, Linux):** the character, bigram and word tables and the
  heatmap do not follow the typing while the window keeps the focus. The 2 s
  poll's `refresh` answers the manifest only (`build_payload(state, false)`),
  and the page's manifest-only path draws no n-gram query; macOS re-requests the
  range at each live manifest, Windows pushes today's n-grams. Follow-up:
  request the range when a refresh's manifest changed, or carry today's n-grams
  in the refresh as Windows does, after measuring the SQLite read on a large
  store.
- **MET-11 (medium, macOS):** the empty and incomplete states differ. With no
  database the typing host publishes an empty manifest as complete and fresh,
  and keeps it as the next snapshot; the apps host publishes nothing on an
  incomplete read or with no database (« refresh refused »), so the page keeps
  the disk cache, or stays empty, without a notice. Windows and Linux send the
  partial counts flagged incomplete. Follow-up: publish the partial projection
  with `metrics_manifest_incomplete`, and an empty store as empty, not fresh.
- **MET-12 (medium, shared):** 61 explanatory tooltips are fixed French
  `title` attributes, 53 in `metrics_typing/index.html` and 8 in
  `metrics_apps/index.html`, plus the « % /SFBs touche » header of `table.js`
  and the « Précision : » and « Acceptées : » chart tooltips of `charts.js`;
  `i18n.js` translates only `data-i18n-title`. They are the definitions of the
  metrics, so every other locale reads them in French.
  `test-no-hardcoded-ui-strings.cjs` scans JS strings only and misses them.
  Follow-up: move each into a `data-i18n-title` key in the 21 locales and
  extend the gate to the pages' HTML.
- **MET-13 (low, shared):** a range or app selection with no data leaves each
  card's « Computing… » placeholder for good (`has_data` false keeps it), and a
  missing value reads « 0 ». Follow-up: `ui_typing.no_data` once the range read
  has landed, « — » for a missing value.
- **MET-14 (low, shared):** the apps page's render-error alert is never
  removed after a later good render and prints the stack. Follow-up: remove it
  at the end of a successful `renderDashboard`, show the message only.
- **MET-15 (low, shared):** the freshness and rebuild banners build their text
  once and do not listen for `i18n:applied`; a late locale (Windows injects it
  on `ready`) can leave their first wording or a raw key until the next state.
  Not reproduced.
- **MET-16 (low, shared):** the activity calendar's per-day counts live only in
  SVG `<title>` elements inside one `role="img"`, out of keyboard and
  screen-reader reach; the Chart.js text ignores the reading font
  (`Chart.defaults.font` is never set).
- **MET-17 (decision, macOS):** the live speed counts an expansion differently.
  macOS removes one stamp per deleted trigger character before adding the
  output (net text); Windows and Linux add the whole output and keep the typed
  trigger (gross). Windows is the reference, so macOS reads lower after each
  hotstring or AI rewrite; which one the readout should mean is the
  maintainer's choice.
- **MET-18 (low, Windows):** the pill needs two keystrokes after an idle: the
  draw also requires `wpm > 0 || a source`, and the calculator returns 0 below
  two events, where the shared `widget_visible` shows « 0 » at the first text
  key on macOS and Linux (TWD-2).
- **MET-19 (low, Windows and Linux):** a failed dashboard reset is silent on
  Windows (`keystats_webview.ahk` returns) and Linux's `cleared = false` is not
  read by the page; only macOS tells the page (`reset_id`). Also cosmetic on
  Linux: the range reply's `driver_meta` says `heatmap_id = "kc"` where the
  dashboard payload says `sc_kb`, and drops `unmeasured` (the page reads only
  `os`).

Native receiving, in `TODO-tests-windows.md`, `TODO-tests-macos.md` and
`TODO-tests-linux.md` (field point `metrics_views` on macOS and Linux): the
Windows tray readout after a burst (MET-01), an AI acceptance in an excluded
app and a private window (MET-02), a dashboard and the diagnostics reopened
after a reading change (MET-03), the range status and the numbers in English
with Narrator, VoiceOver and Orca (MET-06, MET-07), a Linux store made
unreadable during a date change (MET-05) and the apps notice clearing
(MET-04), and Narrator on the compact then graph widget (MET-08).

## Proof

Commits `d7a1b15eaf` and `b916901096` (MET-01), `54104194ce` (MET-02),
`3e130cbad3` (MET-03), `31490a51c7` (MET-04), `d7f08fffb8` (MET-05),
`5afab9de94` (MET-06), `965620df6b` (MET-07), `ff9ff23269` (MET-08).

- **Red on the old code.** Each regression was run against the owner it pins
  restored from `2063644afd`:
  - MET-01: `ahk-parallel --fresh --only=idle-reset` fails
    `idle-reset-after-burst` with « actual_wpm=6 expected_wpm=0 ».
  - MET-02: with the old `bridge.ahk`, the filtered case fails « expected: 0,
    actual: 3 » WPM pushes.
  - MET-03: with the reuse keys' old expressions inside the new seams, « a new
    font retires the dashboard host » fails (the old file has no seam to call).
  - MET-04: with the old `metrics_apps/index.html`, the later answers set the
    incomplete notice « [] ».
  - MET-05: with the old `bridge.lua`, both `met-05` cases fail « expected: 1,
    actual: 0 » terminals.
  - MET-06: with the old `data.js`, the six `met-06` cases fail « the read is
    announced ».
  - MET-07: with the old `format.js`, « met-07: en plain 1234 »; with the old
    `modal.js`, « met-07: apps en ».
  - MET-08: with the old `wpm_widget.ahk`, « the graph shown at the same speed is
    named too » fails.
- **Green on the new code.** AHK through `ahk-parallel --fresh`: `WPM` 125 of
  125, `met-02` 3 of 3, `LLM` green but `retired-live-menu`, which fails on
  `2063644afd` too, `reading` 31 of 31, `warm` and `healthcheck` 159 of 159,
  `a11y readers` 3 of 3; `test-ahk-encoding.cjs`. Linux under WSL from a
  `git archive` copy of `linux/` and `_shared/` (`unset DISPLAY
WAYLAND_DISPLAY`): `--only=met-05` 2 of 2. The pages:
  `test-metrics-apps-linux-poll.cjs`, `test-typing-metrics-range-supersession.cjs`
  (23), `test-typing-metrics-mailbox-ownership.cjs` (10),
  `test-typing-metrics-reset-transaction.cjs` (44),
  `test-metrics-filter-cache.cjs` (1,300),
  `test-metrics-manifest-contract.cjs`, `test-metrics-freshness-banner.cjs`,
  `test-metrics-rebuild-banner.cjs`, `test-metrics-apps-publication-order.cjs`
  (30), `test-metrics-number-locale.cjs` (27).
- **Gates.** `test-app-windows-semantic-markup.cjs`,
  `test-app-windows-accessibility-ratchet.cjs`, `test-metrics-cards-explained.cjs`,
  the locale gates (`test-locale-catalogue-complete.cjs` with 5,426 keys,
  `test-locale-hints-quote-live-labels.cjs`,
  `test-action-labels-have-locale-keys.cjs`),
  `test-error-messages-say-how-to-recover.cjs`, `test-no-hardcoded-ui-strings.cjs`,
  `test-shared-literal-inventory.cjs`, `test-linux-feature-parity.cjs`, the three
  `test-no-pinned-source-reads*.cjs`, `test-config-key-literals.cjs`,
  `field-todo-summary.py --check-doc` for macOS and Linux, the formatter and
  `lint-conventions.js --fail-on-violations`.
- **Not run here.** The macOS suites (no macOS Lua changed); the full Linux
  suite (it ran past its 15 min bound in the archive copy; the failures it had
  printed were the copy's missing `windows/`, `macos/` and `layouts/` trees); the
  browser accessibility scan (`app-windows-accessibility.playwright.cjs`, no
  browser here); a rendered dashboard or widget; `npm run test:js` and
  `verify-change` (they refuse this checkout's Node pin).
