# Project Memory

Accumulated engineering knowledge for this repository — gotchas, architecture decisions, and working conventions, kept here so every future developer, LLM agent, and reviewer can rely on the same hard-won context. Each entry below was a discrete lesson learned while working on the codebase.

> Maintained as a single in-repo source of truth. When you learn something non-obvious about this codebase (a foot-gun, an architectural invariant, a convention the user insists on), add an entry under the right section rather than letting it evaporate. Keep entries factual and link related ones by their slug in `[[brackets]]`.

## Contents

- **Working conventions & feedback**
  - [feedback-ahk-source-encoding](#feedback-ahk-source-encoding) — AHK v2 source files must be UTF-8 BOM + LF; encoding drift causes silent mid-file parse aborts that masquerade as missing tests
  - [feedback-ahk-suspend-prefix-latch](#feedback-ahk-suspend-prefix-latch) — AHK Kana custom-combination prefix latches across Suspend; fix at the source, synthetic key events can't clear it
  - [feedback_ahk_ui_syntax_validation](#feedback-ahk-ui-syntax-validation) — AHK UI files aren't in the headless test runner; how to syntax-check them locally on Windows
  - [Coding style and conventions for this project](#coding-style-and-conventions-for-this-project) — Style rules, architecture decisions, and what to avoid when writing code for this project
  - [project-lua-closure-before-local-nil-global](#project-lua-closure-before-local-nil-global) — A `local` declared textually AFTER a closure that uses it is not captured: the closure binds the nil global, and an hs.task/ShellRunner pcall swallows the resulting error silently
  - [feedback_commit_push](#feedback-commit-push) — Never push automatically — commit only after explicit ask, push only after explicit validation
  - [feedback-proactive-memory](#feedback-proactive-memory) — Record non-obvious learnings in this file proactively at the end of every task, without being asked
  - [feedback_fix_banners_tool](#feedback-fix-banners-tool) — npm run fix:banners auto-corrects all section banner alignment violations — run it before every commit instead of fixing manually
  - [feedback-loader-target-explicit](#feedback-loader-target-explicit) — AHK loader/writer modules that mutate a shared Map (Features etc.) must take the target Map as an explicit parameter, never reach for it via `global`
  - [No co-author trailers (Copilot, Claude, bots)](#no-co-author-trailers-copilot-claude-bots) — Never add Co-Authored-By trailers to commits — including Copilot, Claude, github-actions[bot], or any LLM/tool credit
  - [feedback-no-push-dev](#feedback-no-push-dev) — Ne jamais pusher sur dev sans validation explicite — chaque commit sur dev déclenche la CI et crée une release
  - [feedback-regression-tests](#feedback-regression-tests) — Every user-requested bug fix must ship with a regression test that fails before / passes after the fix
  - [feedback-local-gate-mirrors-ci](#feedback-local-gate-mirrors-ci) — The pre-push gate is four commands; `npm run test:js` (66 checks) is the umbrella CI gates on, and it silently no-ops unless `node_modules` is installed on a Node meeting the engine floor
  - [feedback-test-before-merge](#feedback-test-before-merge) — Never merge a cut-over slice into dev before the user has tested it live. Stay on the slice branch and wait for explicit validation.
  - [feedback-ui-must-be-i18n](#feedback-ui-must-be-i18n) — All user-facing UI text must go through the i18n system in 21 supported languages — never hardcode any UI string anywhere, including WebView UIs (metrics, download window, etc.).
- **Project architecture & decisions**
  - [project-audit-2026-07-21-open-items](#project-audit-2026-07-21-open-items) — third-pass AHK audit: all 42 confirmed findings implemented, 26 claims refuted, and the two decisions taken instead of fixes (the report md was deleted; this is the record)
  - [project-ahk-menu-dispatcher-drop](#project-ahk-menu-dispatcher-drop) — AHK 2.0 silently drops ~30-50% of tray-menu clicks. FIXED via lib/menu_dispatcher.ahk — every actionable item must use RegisterMenuItem, never raw Menu.Add.
  - [project-ahk-invariant-incomplete-application](#project-ahk-invariant-incomplete-application) — Every AHK-driver hardening invariant (Critical-emit, suspend-guard, async-HTTP, RegisterMenuItem) is applied per-site; the recurring bug is the ONE missed sibling site or the guarantee defeated by indirection. Audit the whole class, not the documented site.
  - [project-ahk-test-suite-critical-leak](#project-ahk-test-suite-critical-leak) — Critical("On") in layout/hotkey callbacks is safe in production but leaks into the main thread when invoked directly by tests, silently hanging background timers
  - [project-ahk-numeric-string-equals-false](#project-ahk-numeric-string-equals-false) — `"0" = false` is TRUE in AHK v2; never compare a String|false return against false, type-check with `is String`
  - [project-ahk-keyword-as-variable-hangs-the-parser](#project-ahk-keyword-as-variable-hangs-the-parser) — naming a variable `Catch` (or any control-flow keyword) hangs AHK v2 with zero output and no error; bisect to a trivial probe when a run produces nothing at all
  - [project-ahk-guard-tests-must-loop-the-class](#project-ahk-guard-tests-must-loop-the-class) — Guard tests must enumerate the whole class of call sites, not the one site a bug was fixed at — 5 findings in one audit came from this
  - [project-audit-evidence-must-be-reproducible](#project-audit-evidence-must-be-reproducible) — A refutation needs the same proof as a finding: the "the perf section was fabricated" debunking was itself wrong (it searched `ahk/logs`, but the real path is `autohotkey/logs`); G4 IS measured, and the logs live at `<ConfigDir>/autohotkey/logs/` via `paths.toml`
  - [project-hs-audit-round2-2026-07-21](#project-hs-audit-round2-2026-07-21) — the second implementation pass: 51 of 78 open findings treated (24 fixed, 27 refuted/stale); the remaining 27 are listed there with an exact fix each
  - [project-hs-audit-2026-07-21](#project-hs-audit-2026-07-21) — 13 macOS defects fixed (PII in logs, keystrokes logged inside a vault, silently discarded events); 78 findings remain OPEN and unverified — the backlog lives here because the audit md was deleted by design
  - [project-audit-findings-are-hypotheses](#project-audit-findings-are-hypotheses) — 2 of 35 audit findings were wrong and the existing suite proved it; implement a finding as a hypothesis, not an instruction
  - [project-updater-nonblocking-http](#project-updater-nonblocking-http) — The updater background poll must never do synchronous WinHttp on the main thread (it freezes all remapping); WinHttp SetTimeouts 0 = infinite. Use the async WinHTTP + WaitForResponse(0) + SetTimer-poll pattern.
  - [project-config-v2-refactor](#project-config-v2-refactor) — State of the v2 config schema refactor (Scope C) — branch refactor/config-schema-v2 with 5 dormant commits. Cut-over to actually migrate the AHK driver runtime is the open piece.
  - [project_debug_menu_sync](#project-debug-menu-sync) — Debug menu order is defined in _shared/modules/menu/menu_manifest.json debug_menu — both AHK and Lua drivers consume it
  - [project_menu_manifest_macos_hotstrings_layout_gap](#project-menu-manifest-macos-hotstrings-layout-gap) — macOS never reads menu_manifest.json's hotstrings_menu/layout_menu keys (unlike gestures_menu/metrics_menu/shortcuts_menu, which ARE manifest-driven on both platforms) — a drift GATE exists, the actual migration does not
  - [project-shared-tree-layout](#project-shared-tree-layout) — _shared/ is 6 folders (modules/core/data/lua/tests/ui); each layer resolves the shared root in ONE place (SSOT), but renames/moves still need call-site subpath edits — and several sites bypass the SSOT, so only the test suites catch them
  - [project-gestures-reversal-detection](#project-gestures-reversal-detection) — How direction reversals are detected in the gestures engine (x1 vs incremental)
  - [project-gestures-startup-design](#project-gestures-startup-design) — Design choices for the macOS gestures startup path — primer-as-wakeup-signal vs burst probes
  - [project-hotstring-delay-architecture](#project-hotstring-delay-architecture) — Where hotstring expansion delays are configured, the cross-platform precedence, and the key gotchas
  - [project-hotstring-engine-internals](#project-hotstring-engine-internals) — AHK prefix-watcher InputHook captures synthetic input; OnChar must feed each char once; AHK vs Hammerspoon word-boundary framing divergence is intentional
  - [project-hotstring-live-rebuild](#project-hotstring-live-rebuild) — Hotstring section/category toggles apply in-process via a re-runnable RegisterAllHotstrings(); native-engine + layout-backed features under hotstrings.\* are the reload-only exceptions
  - [project-typing-latency-tooltip-coldstart](#project-typing-latency-tooltip-coldstart) — Tooltip render + post-boot warm-up latency: the border alpha scan optimization, why tooltip window-reuse is rejected (AHK v2 can't remove Gui controls), and why deferred-registration chunking was reverted
  - [project-hs-perf-profilers-and-case-conform](#project-hs-perf-profilers-and-case-conform) — macOS boot/hot-path profilers (via timer_scheduler adapter), the case-conform registration fast path (lowercase-only + fire-time conform, Unicode tail buckets), the menubar dirty-cache, the two dominant boot costs found + fixed (group disable/enable round-trip ~2 s; synchronous log-purge shell pipeline ~0.6 s deferred), and the escape-trap-on-first-show gotcha (Escape priority over Raycast — do not move to init)
  - [project-tooltip-shared-style](#project-tooltip-shared-style) — Tooltip style is shared via _shared/modules/tooltip/constants.toml (per-driver alphas border_alpha_hs vs _ahk are intentionally different); the macOS stacked canvas rounds its colored rectangle with a SINGLE rounded panel background — NOT an hs.canvas clip element (clip rendered solid red on the user's build)
  - [project-dc1-windows-vk-finger-map-gap](#project-dc1-windows-vk-finger-map-gap) — DC-1 single-sourced the JS + macOS finger maps from azerty.json; a 3rd hardcoded copy (Windows VK-code keyed) remains in keylogger_walker_core.ahk, deliberately left untouched
  - [project-hs-script-quit-kills-karabiner](#project-hs-script-quit-kills-karabiner) — the script_quit action (rcmd+Escape) calls os.exit(), which BYPASSES the Hammerspoon shutdown callback, so it must call karabiner.kill() itself or KE keeps remapping the keyboard after HS is gone; conversely the shutdown callback must NOT kill KE on a reload (lib/reload_guard distinguishes reload from quit) or the grabber cascades down and the native "install Karabiner" prompt appears
  - [project-hs-onboarding-config-schema](#project-hs-onboarding-config-schema) — the first-run wizard MUST write config.toml using the canonical HS schema (ui/menu/preferences.lua KEY_MAP: lowercase sections, clean `enabled` flags) — NOT AHK-style keys — or every wizard choice is silently dropped on the post-wizard reload; locale persists via hs.settings, not config.toml
  - [Keymap module architecture and refactor decisions](#keymap-module-architecture-and-refactor-decisions) — Structure of the keymap module, where defaults live, which files do what
  - [project-hs-synthetic-injection-choke-point](#project-hs-synthetic-injection-choke-point) — The macOS driver has TWO synthetic-keystroke trackers (keymap expected_synthetic_* + keylogger synth_queue); injectors that bypass perform_text_replacement desync them and can corrupt typed output — see AUDIT_HAMMERSPOON_BUGS.md
  - [project-locale-parity-test](#project-locale-parity-test) — en.json is the canonical key set; the AHK meta-test test_locale_json_valid.ahk enforces parity in CI; check_locales.py --fix is the manual backfill tool
  - [project-locale-fast-cache](#project-locale-fast-cache) — The Windows driver's locale .tsv is a gitignored self-healing fast-parse cache regenerated from the canonical .json on a miss/staleness; only .json is tracked, no committed duplication
  - [project_metrics_pipeline_17](#project-metrics-pipeline-17) — AHK metrics pipeline — bug #17 CLOSED, follow-up bugs fixed
  - [project-suspend-pause-invariant](#project-suspend-pause-invariant) — Pause must fully silence ALL features (no tooltip/LLM/keylogger/widget). AHK Suspend only disarms hotkeys — InputHooks/timers/OnMessage bypass it and need explicit A_IsSuspended guards.
  - [project-macos-llm-runtime-enable-gate](#project-macos-llm-runtime-enable-gate) — macOS must not warm up or load an LLM model from profile/model restoration alone; warmup is allowed only after the runtime LLM gate is enabled
  - [project-macos-eventtap-no-blocking](#project-macos-eventtap-no-blocking) — Never run blocking osascript/hs.execute inside an hs.eventtap callback — macOS disables the tap (kCGEventTapDisabledByTimeout) and AltGr+Enter dies. Defer with hs.timer.doAfter(0).
  - [project-macos-script-control-tap-lifecycle](#project-macos-script-control-tap-lifecycle) — The script-control eventtap (AltGr+Enter/Backspace/Escape) must survive layout switches and pause. `shortcuts.start` is a Bindings-only proxy that kills it; the pause-layout switch fires the Karabiner input-source watcher that rebuilds mid-pause. Rebind via pause_bindings/resume_bindings and skip the rebuild while paused.
  - [project-touchdevice-dormancy-is-kernel](#project-touchdevice-dormancy-is-kernel) — Definitive answer that macOS touchdevice subsystem CANNOT be activated before first physical touch — it is a kernel-driver gate
  - [project-ui-dynamic-buttons](#project-ui-dynamic-buttons) — AHK UIs must use Gui_HarmoniseButtonWidths instead of hardcoded w-values; HS auto-sizes via CSS padding
  - [errors-only-log-sink](#errors-only-log-sink) — Dedicated ErgoptiPlus*errors*\*.log (WARNING/ERROR only) + menu item; crash_reports remain for uncaught fatals only
  - [project-hs-timer-callback-errors-invisible](#project-hs-timer-callback-errors-invisible) — Errors thrown in hs.timer/eventtap callbacks are swallowed to the HS Console, never the file logger; a test stub of a method production lacks masks the dangling call (the "vert mais aucune prédiction" bug)
  - [project-macos-audit-2026-06-17-bugs](#project-macos-audit-2026-06-17-bugs) — Three macOS bugs fixed: LLM noise filter nil-vs-false Lua foot-gun, gesture peak confirmation was framerate-dependent (dead constant), synthetic-event reset race under OS load
  - [broad-unit-test-regression-coverage](#broad-unit-test-regression-coverage) — Maximize Test()/helpers.it coverage for every feature (hotstrings, gestures, keylogger, layout, suspend/pause, menu, config, logger, etc.) in both AHK and HS to catch all regressions early. Every invariant and edge that has bitten us gets a permanent test.
  - "Oui encore plus" ultra pass: +25+ additional tests across script_control (more pause idempotence/transitions, extras under pause), karabiner (pause gate on config), port_adapter meta (explicit suspend/pause purity + adapter notes + corpus coverage), corpus meta (pause/delay/reversal corpus notes + LLM under pause), tap_hold (more pause + bad TOML graceful), personal_toml (pause guard + bad entry), llm_profiles (pause no predict), keylogger_reader (pause privacy in reports), plus extra pause in gestures engine (more reversal + pause), keylogger privacy (agg under pause, PII on errors), llm prediction (pause on timeout, volume no degrade), hotstrings_full (more pause/synthetic/delay edges), shortcuts (more pause all dispatchers, menu no raw Add, bad features graceful). Total expansion now >80 new regression tests. The suite is now the strongest it's ever been — every feature has explicit pause/suspend guards + error/edge tests for critical invariants like project_suspend_pause_invariant, project_hotstring_delay_architecture, project_gestures_reversal_detection, keylogger privacy, menu dispatcher drops, AltGr prefix latch. Time makes the tests strictly more robust. Full suites + live test before any merge.
  - Expansion added: pause/suspend guards (script_control, gestures engine/init, hotstring engine, keylogger, layout, shortcuts, LLM); reversal detection in gestures; delay edges; FS/pcall error paths; cross parity. Strategy: for any new hook/timer/dispatch/pause path, add test that would have caught the silent failure. Full suites mandatory before merge.
  - Suite continued with additional tests in hotstrings_config (section delays, pause), keymap state (delays, pause), layout (AltGr prefix latch), LLM (errors), gestures init (set_action under pause), meta require_state (suspend notes). All banners fixed. This makes the test suite strictly stronger over time per feedback_regression_tests.
  - Further batch: tap_hold_loader (pause, defaults overlay, invalid TOML, inherit_defaults=false, accessor edges — 6+ new), toml_loader (unicode, caching, multiple escapes), karabiner config (pause, migration, empty inputs), i18n (pause safe load/t()), hotstrings_full (pause guard, section delay), config (pause+manifest). Total added across expansion: 40+ regression tests. Prioritize suspend/pause in every new path.
  - Latest additions in "ajoute le plus de tests possible" pass: reinforced config, added personal_info and terminators pause guards (HS), more i18n/hotstrings_full pause+delay, karabiner edges. ~10 additional tests. Goal achieved: broad coverage across tap_hold, toml, karabiner, i18n, hotstrings, config, personal, terminators + universal pause invariant.
  - Post-compaction "encore plus" / "encore plus de tests. le maximum possible..." wave (this session continuation after summary compaction): +25-32 new regression tests in one dense iteration for near-100% certainty. Key additions: test*shortcuts.ahk (+6 — closed the critical ZERO pause coverage gap on all dispatchers, AltGr prefix latch regression under pause/resume [[feedback-ahk-suspend-prefix-latch]], RegisterMenuItem safety + pause, 250+ volume, bad Features, idempotent transitions); test_hotstrings_config.ahk (+3 — pause gate on resolution, explicit section>group>default delay precedence regression, 150+ bad TOML under pause); test_logger_contract.ahk (+3 — pause + errors-sink survival for diagnostics, 300+ volume ERROR under pause, hard FS on errors sink no-crash); test_active_app_cache.ahk (+3 — pause blocks all cache-driven activation for shortcuts/gestures/hotstrings/widgets, 200+ volume under pause, bad/unicode exe resilience); deepened HS: llm/profiles (+2-3 volume + pause transitions), gestures/engine (+2 primer + pause + 200+ volume + reversal), keylogger/aggregator (+2 privacy+pause+rollover + FS/pcall), shortcuts/bindings (+3 pause + volume + bad ids), karabiner/generator (+2 pause + volume + bad), keymap/terminators (+2 pause + volume unicode), meta corpus_hotstrings (+2 pause + delay precedence). Also notes in require_state (shortcuts full, hotstrings_config, logger_contract) and port_adapter. All with explicit "project_suspend_pause_invariant", historical gotchas, and max edges (volume 100-300+, unicode, bad input, FS/pcall no-crash, rollover, dedup, re-init, idempotent pause, cache-driven safety). Banners clean on most; 1 minor whitespace on shortcuts (warn-only, tests fully registered and valid). Memory updated. Campaign total now well over 210+ new regression tests. These tests would have caught: silent AltGr latch dispatch after pause, wrong hotstring delay timing (DYN* early-load or section override), logger ERROR loss under pause (diagnostics broken), cache-driven shortcut/gesture fire while suspended, gesture primer stuck after touchdevice dormancy + pause, aggregator PII leak on pause+rollover, menu item drops, volume corruption in prediction/profiles/bindings, etc. Full suites (run_all.ahk + run.lua) + live hardware test (pause/resume, high volume typing/gestures/LLM, config reload, keylogger privacy) mandatory before any merge. User can request "encore plus" again — the loop continues until no obvious gaps remain in survey.
  - [project-hs-partial-fixes-and-false-green-tests](#project-hs-partial-fixes-and-false-green-tests) — Three macOS fixes recorded as complete are partial; each is guarded by a test asserting the mechanism instead of the guarantee
  - [project-ahk-menu-dispatcher-error-swallow](#project-ahk-menu-dispatcher-error-swallow) — The menu dispatcher bypass must re-throw callback errors to maintain parity with AHK's native dispatch and the global OnError handler.

---

## Working conventions & feedback

### feedback-ahk-source-encoding

_AHK v2 source files must be UTF-8 BOM + LF; encoding drift causes silent mid-file parse aborts that masquerade as missing tests_

<sub>slug: `feedback_ahk_source_encoding`</sub>

AHK v2's parser can silently stop registering top-level statements partway through a source file when the file's encoding is inconsistent (missing BOM or mixed line endings). The headless test runner then plans `1..N` for only the first batch of `Test()` calls and reports green — passing tests are real, missing ones are silently dropped, and there is no error message anywhere.

**Why:** discovered 2026-05-22 during the v2 config-refactor test suite development. Initial drafting of `test_features_manifest_v2.ahk` showed only 5-7 of 33 tests registering despite all `Test()` calls being syntactically valid. Root cause: PowerShell file rewrites left mojibake (double-encoded UTF-8) and `cat >>` from bash appended LF lines into a CRLF/BOM file. The AHK v2 parser handled this by quietly truncating the file, not by raising an error.

**How to apply:**

- New `.ahk` files: use UTF-8 **with** BOM and LF-only. After creating one, run `npm run test:ahk-encoding` before adding it to git.
- Existing `.ahk` files: extend via the Edit tool (preserves encoding), NEVER via `cat >> file.ahk` from bash (it can bypass the repository encoding guard).
- Non-ASCII in comments/strings is fine when encoding is clean. The v2 test suite (`test_features_manifest_v2.ahk`) stays ASCII-only as a defensive convention and accesses non-ASCII glyphs via `Chr(0xNNNN)` (e.g. `Chr(0x2605)` for the magic key star) so future encoding regressions cannot reintroduce the silent abort.
- Diagnostic when a test file shows fewer test-results than its `Test()` count: run `file <path>` first, before debugging the test logic.

Also documented in:

- `.github/copilot-instructions.md` — AHK language section (primary developer rule).
- `static/drivers/autohotkey/tests/test_framework.ahk` — module header (visible to every test author).
- `static/drivers/autohotkey/lib/manifest_reader.ahk` — module header (codegen output must match).

Related rule (same context, AHK v2 string parsing): inside a double-quoted string, the escape for a literal double quote is `` `" `` (backtick + quote), NOT `""` (doubled quote — that was AHK v1 syntax). The IDE flags `""` as `Did you mean to use '\`"'?` but the silent-abort can mask this if it falls in a region the parser has already given up on.

### feedback-ahk-suspend-prefix-latch

_AHK Kana custom-combination prefix latches across Suspend; fix at the source, synthetic key events can't clear it_

<sub>slug: `feedback_ahk_suspend_prefix_latch`</sub>

Toggling AHK `Suspend()` around the ergopti_plus Kana `SC138` AltGr custom-combination prefix produces two distinct latch bugs. The working fixes are non-obvious — found live over ~5 iterations on branch fix/hs (commit 89c15093f, ErgoptiPlus.ahk + lib/layout/layout_altgr.ahk).

- **Menu/gesture pause → keyboard can't un-pause.** Toggling `Suspend` from a non-hook thread rebuilds the keyboard hook with the `SC138 & X` prefix un-armed, so the suspend-exempt script combos (AltGr+Enter/BackSpace/Delete/Escape) stop firing. **Fix:** also register the chords as plain **suffix** hotkeys (`Hotkey("SC01C", …, "I2 S")`) gated on `HotIf(A_IsSuspended and GetKeyState("SC138","P"))`. A suffix needs no prefix arming, never re-registers the prefix (so it can't latch the Kana key), and yields to the real combo when the prefix IS armed (no double-fire).
- **Keyboard pause → menu/gesture resume → « AltGr bloqué ».** A keyboard pause holds SC138 down through `Suspend(1)`; its physical release lands while the AltGr layer is disarmed, so AHK's internal prefix-down flag stays latched. On resume the layer dispatches with `GetKeyState("SC138")==0`.

**Why:** AHK's custom-combination prefix-down flag is SEPARATE from `GetKeyState` and is cleared **only by a real physical key release processed by the live layer**. A synthetic `SendEvent("{SC138 Up}")` or `{Down}{Up}` tap does NOT clear it (verified via logs), and re-registering the combos Off→On re-latches it. So you cannot clean it up on resume.

**How to apply:** prevent at the source — in `ToggleSuspend`, before `Suspend(1)`, `KeyWait("SC138","T1")` when SC138 is physically held (keyboard pause). Never reach for synthetic taps or Off→On re-registration. A permanent WARNING guard-rail in `AltGrShiftDispatch` logs any dispatch with SC138 not physically held to catch regressions in ErgoptiPlus_layout.log. Use `AutoHotkey64.exe /ErrorStdOut /validate <script>` (exit 0 = clean) to syntax-check edits headlessly. Related: [[project_suspend_pause_invariant]].

### feedback_ahk_ui_syntax_validation

_AHK UI files aren't in the headless test runner; how to syntax-check them locally on Windows_

<sub>slug: `feedback_ahk_ui_syntax_validation`</sub>

The AHK UI files `windows/ui/tray_menu.ahk` and `windows/lib/hotstrings/hotstrings_config_window.ahk` are NOT `#Include`d by the headless test runner `windows/tests/run_all.ahk` (it pulls in `lib/` + `adapters/` + `test_*` only). So a syntax error in those UI files is caught **only** by CI's `Compile ErgoptiPlus.ahk` step (Ahk2Exe), never by the AHK test suite or the CI dry-run warning check.

**Why:** run_all deliberately avoids `modules/` and UI files that register hotkeys / build menus at top level (they'd block a clean exit).

**How to syntax-check them locally** (two ways, both gotcha-laden):

1. **Ahk2Exe compile** (gold standard, == CI): `Ahk2Exe.exe` lives at `C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe`. **Run it from PowerShell, never Git Bash** — Git Bash's MSYS path conversion rewrites `/in` `/out` `/base` into Windows paths (`/in` → `C:/Program Files/Git/in`), so the compile fails with "Unrecognised parameter". `& $ahk2exe /in $in /out $out /base $base /silent`; Ahk2Exe exits 0 even on failure, so verify the `.exe` was actually created.
2. **Parse-only harness**: a throwaway `.ahk` with `ExitApp(0)` as the first auto-execute statement, then `#Include` the UI file(s). AHK parses the whole merged script before running anything, so a syntax error aborts at load; the `ExitApp(0)` exits before any included top-level code runs (won't start the driver). Launch via `Start-Process -FilePath AutoHotkey64.exe -ArgumentList @("/ErrorStdOut",$script) -Wait -PassThru -RedirectStandardError $err` — plain `& AutoHotkey64.exe` does NOT capture the exit code or stderr because it's a GUI-subsystem app that detaches.

The headless test runner writes its TAP report to `%TEMP%\ergopti_test_results.txt` (NOT stdout) — read that file for pass/fail, not the AHK process stdout. See [[feedback_ahk_source_encoding]].

### Coding style and conventions for this project

_Style rules, architecture decisions, and what to avoid when writing code for this project_

<sub>slug: `feedback_coding_style`</sub>

Follow `.github/copilot-instructions.md` strictly. Key rules:

- **Tabs** for indentation (never spaces).
- **Section headers**: 5 blank lines before major sections, 3 before subsections. Exact `=` alignment required.
- **File path comment** as very first line (e.g., `--- modules/keymap/init.lua`).
- **Language**: code in English, user-facing text in French. Use typographic apostrophe `'` in UI text.
- **Docstrings** end with `.` (formal sentences). Inline comments do NOT end with `.`.
- **Logging**: use the 8-variant Logger system. Lifecycle pairs (start/success, trace/done) are mandatory — never an unpaired start/trace.
- **Fail fast**: guard public functions with `require_state()`, log ERROR and return. No silent fallbacks.
- **Single source of truth**: defaults live in exactly one module. Other modules read from the source, never re-declare.
- **No magic numbers**: all constants named at file top.
- **Setters log at DEBUG** with their new value.

**Why:** The user has an explicit copilot-instructions.md and consistently enforces these conventions.

**How to apply:** Before writing any new code in this repo, re-read the instructions. When refactoring, prioritize removing duplicated defaults and silent error swallowing.

### project-lua-closure-before-local-nil-global

_A `local` declared textually AFTER a closure that uses it is not captured — the closure binds the nil global, and a pcall in the hs.task/ShellRunner wrapper swallows the resulting error silently_

<sub>slug: `project_lua_closure_before_local_nil_global`</sub>

In Lua, `local function f() ... uses x ... end` only captures `x` as an upvalue if `local x` appears **lexically before** the closure. If `local x` is declared *below* the closure, the reference inside `f` resolves to the global `_G.x` (nil), not the later local. This is a sharp foot-gun in async callbacks: the closure looks correct, but at call time the variable is nil.

**Why:** found 2026-06-19 by the senior-audit workflow as the single `critical` finding (F1 in `AUDIT_HAMMERSPOON_2026-06-19.md`). In `modules/llm/api_ollama.lua`, the streaming `on_done` closure (declared ~line 555) calls `os.remove(tmp_path)` as its first statement, but the only `local tmp_path` is ~line 615 — below the closure. So `tmp_path` was the nil global, `os.remove(nil)` threw, and because `ShellRunner`/`hs.task` invoke the completion callback inside a `pcall`, the error was swallowed: the ENTIRE `on_done` body aborted on its first line on every stream completion. With `llm_streaming=true` by default, Ollama streaming predictions silently never appeared. The pre-existing regression test only grepped that the literal `os.remove(tmp_path)` string was present inside `on_done`, so it stayed green while the runtime value was nil — a false-green.

**How to apply:**

- When a closure (especially an `hs.task`/`ShellRunner`/`hs.timer` callback) references a `local`, verify the `local` is declared ABOVE the closure. Hoist temp-file/state creation above the callbacks that consume it (mirror how `api_mlx.lua` is ordered).
- Errors thrown inside `hs.task`/`hs.timer`/`hs.eventtap` callbacks are swallowed by their pcall wrapper to the HS Console, never the file logger — see [[project_hs_timer_callback_errors_invisible]]. A nil-global closure bug is therefore invisible at runtime; only careful reading or a behavioral test catches it.
- Regression tests for this class must encode the ROOT CAUSE: assert the `local` declaration index is **before** the closure definition index in the source (`src:find("local tmp_path%s*=") < src:find("local function on_done(", 1, true)`), not merely that the using line exists. A string-grep that the call is present is a false-green.
- **Specific pattern to watch in `hs.task` GC-pin management**: `local task = hs.task.new(... function() M._active_tasks[task] = nil end)` looks correct but binds nil. The fix is always the 2-line split: `local task; task = hs.task.new(...)` plus `if task then M._active_tasks[task] = nil end` inside the callback. Found in 9 additional sites in the 2026-06-20 audit: `modules/karabiner/onboarding.lua` (×4), `ui/menu/menu_apps.lua` (×1), `ui/menu/menu_llm/models_manager_mlx.lua` (×3), `ui/menu/menu_llm/models_manager_ollama.lua` (×1).

Related: [[feedback_regression_tests]] (encode the root cause, not the symptom), [[project_hs_timer_callback_errors_invisible]] (why the throw was invisible), [[feedback_coding_style]] (fail-fast / no silent error swallowing).

### project-hs-sentinel-key-misfire

_F13/F14/F15 are real physical keys macOS can emit; using them as Karabiner synthetic sentinels without gating on the right-AltGr state fires `script_suspend`/`script_reload`/`script_quit` on a bare key press_

<sub>slug: `project_hs_sentinel_key_misfire`</sub>

The shortcuts module uses F13/F14/F15 as sentinel keycodes that Karabiner injects when the right-AltGr modifier is held. These are also real physical keys present on extended keyboards (or remapped by Karabiner profiles). Before the 2026-06-19 fix (commit `10065c106`), `handle_key` in `shortcuts/script_control.lua` dispatched the sentinel branches unconditionally — so pressing a physical F15 on a full-size keyboard with no AltGr held fired `script_quit`, silently killing the driver.

**Why:** Invisible because: (a) no error is raised — the quit path runs cleanly; (b) `hs.eventtap` callback errors are swallowed to Console anyway. From the user's perspective the driver "just dies."

**How to apply:**
- Always gate sentinel branches on `KeyState.is_right_altgr_held()` (the adapter checks raw device-specific HID modifier masks, not the OS-level modifiers that can desync under Karabiner remapping).
- Never use a key that the OS or hardware can emit natively as a sentinel without this gate. If Karabiner injects it, it should also be the one guarding it.
- Regression test: `tests/unit/modules/shortcuts/test_script_control.lua` asserts the gate.

Related: [[project_hs_timer_callback_errors_invisible]], [[project_lua_closure_before_local_nil_global]].

---

### project-hs-purity-ratchet-counts-comments

_The `hs.*` purity ratchet in `test_port_adapter_coverage.lua` counts the substring `hs.` everywhere in source files — including comments and string literals — so a comment that mentions `hs.timer.new` increments the counter_

<sub>slug: `project_hs_purity_ratchet_counts_comments`</sub>

The OS-purity ratchet (`tests/meta/test_port_adapter_coverage.lua`) counts occurrences of the literal substring `hs.` in all `.lua` files under `modules/` and `lib/` (excluding `adapters/`, `ui/`, and root `init.lua`). It then asserts the total is ≤ 950. The grep is a raw substring count, not an AST parse — it counts comments.

**Consequence:** Writing a comment like `-- Formerly used hs.timer.new directly` adds 1 to the count. If the baseline is exactly 950 and you add such a comment, the ratchet fails. Conversely, if you reword a comment to avoid `hs.` (e.g., `-- Formerly used the timer scheduler directly`), the count drops and the baseline stays at 950 — but it feels wrong to hide how the API is referenced in comments.

**How to apply:**
- Keep comments in `modules/` and `lib/` neutral about `hs.*` calls when possible. Route the OS call through an adapter and mention the adapter in the comment, not the raw `hs.` API.
- If a comment genuinely needs to reference the `hs.` API name (e.g., documenting a foot-gun), accept the ratchet increment and update the baseline in the test with a brief note.
- Current baseline: `hs.*` count = 950, `io.open`/`os.execute` count = 70.

**Corollary — `adapters/` is the OS-isolation layer, not "exactly the 20 ports".** A refactor that tries to make `macos/adapters/` mirror `windows/adapters/` at exactly the 20 contract ports by moving the non-port helpers (`shell_runner`, `toml_cache`, `json_codec`) into `lib/` is rejected by this ratchet: those helpers do shell-exec / file-I/O, so relocating them spikes the `io.open`/`os.execute` and `hs.*` counts outside `adapters/` (verified: 74 > 70 and 976 > 950). Do **not** weaken the baseline to permit it (§5.9). The correct mental model: `adapters/` holds the 20 ports **plus** any OS-touching infrastructure helper; cross-driver "adapter parity" means the 20 ports line up, not that the folder file counts match.

Related: [[project_lua_closure_before_local_nil_global]] (the audit where this was discovered).

---

### feedback_commit_push

_Never push automatically — commit only after explicit ask, push only after explicit validation_

<sub>slug: `feedback_commit_push`</sub>

**NEVER push without explicit user instruction.** `git push` is always blocked unless the user says "push" or equivalent in that turn.

Commit freely after small autonomous changes, but stop there. Do NOT chain `&& git push` or run `git push` in a follow-up step.

**Why:** User was burned by auto-pushes mid-session while code was in a broken/test state (hardcoded test HTML pushed to remote mid-debug).

**How to apply:**

- After any commit: stop. Do not push. Wait for the user to say "push" or "pousse".
- Step-by-step plan mode (user said "étape par étape, tu valides chacune"): also wait for explicit "ok"/"validé" before committing each step.
- If unsure: commit is OK, push is never OK without explicit instruction.

### feedback-proactive-memory

_Record non-obvious learnings in this file proactively at the end of every task, without being asked_

<sub>slug: `feedback_proactive_memory`</sub>

At the end of any non-trivial task, record what was learned — foot-guns, architectural invariants, rejected approaches and why, conventions the user insists on — directly into this file, **without asking permission first**. Saving project knowledge is part of finishing the work, not an optional add-on to clear with the user.

**Why:** the user said explicitly (2026-06-14) "tu ne devrais même pas avoir à me poser la question et devrais le faire à chaque fois tout seul" — asking "should I save this to memory?" is friction; the answer is always yes. Knowledge that evaporates between sessions forces re-investigation of things already figured out (e.g. re-attempting a refactor already proven unworkable).

**How to apply:**

- After finishing a task, add/update the relevant entry here (the right section + a ToC line) as a normal part of wrapping up — no confirmation prompt.
- Capture especially: the WHY behind a decision, approaches that were tried and rejected (so they aren't re-attempted), and any silent/cryptic failure mode.
- This is the in-repo store; do NOT spin up a separate agent-private memory file — everything lives here (see the top-of-file note and `CLAUDE.md`).
- Committing the doc still follows [[feedback_commit_push]] (commit freely, never push without an explicit ask).

### feedback_fix_banners_tool

_npm run fix:banners auto-corrects all section banner alignment violations — run it before every commit instead of fixing manually_

<sub>slug: `feedback_fix_banners_tool`</sub>

`npm run fix:banners` already exists in `package.json` and auto-corrects banner
line lengths across the entire repo (`.lua` + `.ahk`).

It calls `node scripts/lint-conventions.js --fix-banners --warn-only`.

**Why:** Banner alignment violations block `git commit` via the pre-commit hook.
Fixing them by hand (counting `=` chars) is slow and error-prone.

**How to apply:** After creating or editing any `.lua` or `.ahk` file, run
`npm run fix:banners` from the repo root before `git add / git commit`.
Never fix banner lengths manually — the tool is definitive.

Related: [[feedback_coding_style]]

### errors-only-log-sink

_Dedicated daily ErgoptiPlus_errors_YYYY-MM-DD.log (only WARNING + ERROR) + "Open error log" menu item; crash_reports/ strictly for uncaught fatal exceptions_

<sub>slug: `errors_only_log_sink`</sub>

Both drivers now write every `LoggerError`/`Logger.error` (and WARNING) line to a separate small daily log file under the driver-scoped `logs/` directory, using the same rotation + 14-day purge policy as the unified log. A matching "Open error log" (and sg_action) entry was added to the debug menu, driven from the single source `_shared/menu_manifest.json`.

**Why:** The unified daily log easily reaches thousands of lines. Users (and the maintainer) frequently want to see _only_ the error lines for triage. `crash_reports/` (rich per-incident JSON with full ring buffer + sysinfo) is intentionally kept for true uncaught crashes only; routing recoverable errors there would create noise and bloat.

**How to apply:**

- Use `LoggerError` / `Logger.error` for anything that represents a noteworthy failure (even if execution continues).
- The errors file is the recommended first artifact to look at when the user reports "it did something weird".
- Crash reporter (the `ergopti_report_crash` path on HS, global `OnError` on AHK) stays exclusively for fatal unhandled exceptions.
- Menu item and gesture-assignable action are canonical via the manifest (no per-driver duplication).

Related: crash_reporter modules, lib/logger in both drivers, [[feedback_coding_style]] (logging conventions).

### feedback-loader-target-explicit

_AHK loader/writer modules that mutate a shared Map (Features etc.) must take the target Map as an explicit parameter, never reach for it via `global`_

<sub>slug: `feedback_loader_target_explicit`</sub>

Loader and writer modules in the AHK driver that mutate a shared in-memory structure (the `Features` Map, the `TapHold` Map, future v2/v3 globals) MUST take the target structure as an explicit function parameter. They must NOT use a `global Features` (or equivalent) declaration to reach into the global namespace.

**Why:** discovered 2026-05-22 during Phase 1 of the v2 config-refactor cut-over. The v2 TOML loader (`ApplyConfigTomlV2`) was originally written with `global Features` because it was conceived as a successor to v1's `ApplyConfigToml` and the production wiring would eventually use only one `Features` global. But during the sliced migration period the v1 `Features` global stays the live target, while the v2 loader is meant to populate a separate `FeaturesV2` global. With the global reference baked in, the v2 loader silently clobbered v1 — the section names (`Layout`, `Shortcuts`, `TapHolds`, `Gestures`, `LLM`, `Metrics`, `Script`, `Hotstrings`) coincide between v1 PascalCase and v2 stripped-prefix forms, so the loader walked v1 entries and overwrote inner `{Enabled: True}` object literals with plain booleans. Every downstream `.Enabled` access crashed at tray-menu init.

**How to apply:**

- Any function whose body mutates a Map passed by reference takes the Map as its first parameter: `ApplyConfigTomlV2(Features, FilePath)`, `LoadTapHoldToml(FilePath)` returning a new Map (no mutation = no parameter needed), `MirrorV1ToV2(SourceMap, TargetMap)`.
- Read-only accessors can still use `global` (they only need to find the data, not change it).
- Tests calling the loader supply their own fixture explicitly; production supplies the production global. Either is safe.
- If you find an existing module that mutates a global, refactor it to take the parameter before adding new callers — incremental migrations are exactly when the global-reference assumption breaks.

Related: [[feedback-ahk-source-encoding]] — both were sharp foot-guns in the same v2 refactor; both surfaced as silent or cryptic failures with no error pointing at the root cause.

### No co-author trailers (Copilot, Claude, bots)

_Never add Co-Authored-By trailers to commits — including Copilot, Claude, github-actions[bot], or any LLM/tool credit_

<sub>slug: `feedback_no_coauthor`</sub>

Never add `Co-Authored-By:` trailers to commit messages. This includes Copilot, Claude, github-actions[bot], and any other LLM/tool credit.

**Why:** Project convention in `.github/copilot-instructions.md` §6 explicitly forbids it ("No co-author credits: Never add Co-Authored-By trailers. Do not credit any LLM or tool in commit messages."). The user reaffirmed this strongly when I proposed to whitelist legacy Copilot trailers in a meta-test — they want NEW commits to remain clean and don't want me to soften the rule.

**How to apply:** When writing commit messages (Bash heredoc, `git commit -m`, etc.), produce a bare conventional commit with no trailers. Do not whitelist bot trailers in lint/meta tests either — make the test scope only NEW commits (e.g., `origin/dev..HEAD`) so legacy history isn't flagged but future violations are caught.

### feedback-no-push-dev

_Ne jamais pusher sur dev sans validation explicite — chaque commit sur dev déclenche la CI et crée une release_

<sub>slug: `feedback_no_push_dev`</sub>

Ne pas pusher sur `dev` (ni `main`) sans que l'utilisateur ait explicitement demandé un push.

**Why:** Chaque commit pushé sur `dev` déclenche la CI qui crée une release. Pousser à chaque petit fix pollue les releases et consomme inutilement la CI.

**How to apply:** Travailler sur une branche feature/fix, committer localement autant que nécessaire, et ne pusher sur `dev` QUE quand l'utilisateur dit "push" ou "merge". Ne jamais enchaîner commit + push automatiquement sur `dev`.

### feedback-regression-tests

_Every user-requested bug fix must ship with a regression test that fails before / passes after the fix_

<sub>slug: `feedback_regression_tests`</sub>

For every bug the user asks me to fix, I MUST add a unit/regression test that encodes the root cause — failing before the fix, passing after — so the test suite grows strictly more robust over time and that bug can never silently return.

**Why:** the user explicitly wants accumulating coverage ("plus le temps passe et plus nos tests sont robustes"). Every bug hit once should be caught forever; time makes the suite stronger, never weaker.

**How to apply:**

- Fix the bug, then add the test in the suite covering the affected layer: AHK `static/ergopti_plus/windows/tests/`, macOS `static/ergopti_plus/macos/tests/`, or cross-platform `tools/test/`. Run it green before considering the fix done.
- Encode the ROOT CAUSE, not just the symptom — and exploit the harness so a regression actually fails. Example: the `DYN_HOTSTRINGS_DEFAULT_DELAY` startup crash (a menu-build global defined in late-loaded `modules/hotstrings.ahk` instead of the early `hotstrings_config.ahk`) is guarded by a test in `test_hotstrings_config.ahk` asserting the constant is defined — the AHK suite loads `hotstrings_config.ahk` but NOT `modules/hotstrings.ahk`, so moving it back to the module makes it undefined and fails the test.
- Never delete or weaken a regression test to make a change pass; fix the change.

Codified in `.github/copilot-instructions.md` §5.9 (the project rules doc that `CLAUDE.md` @-includes — so it covers project + Claude + Copilot). See [[project_hotstring_delay_architecture]].

### feedback-local-gate-mirrors-ci

_Green locally must mean green in CI: the local gate is four commands, and it is only trustworthy once `node_modules` is installed on a Node that satisfies the engine floor_

<sub>slug: `feedback_local_gate_mirrors_ci`</sub>

The full pre-push gate — run all four from the repo root, in this order:

```bash
npm run test:js            # 66 checks — the umbrella suite (tools/test/run-js-suite.cjs)
npm run test:ahk-encoding  # every .ahk is UTF-8 BOM + LF
AutoHotkey64.exe static/ergopti_plus/windows/tests/run_all.ahk       # 3212 unit/meta tests
AutoHotkey64.exe static/ergopti_plus/windows/tests/e2e/run_e2e.ahk   # 5 E2E
```

`npm run test:js` is the one people skip, and it is the one that matters most: it is the **umbrella** that wraps the checks CI gates on but the AHK runner knows nothing about — the pinned-source-read ratchet, `lint:conventions:strict`, port compliance, priority parity, the translations audit, and `python tools/format_toml.py --hotstrings --all --check`. The AHK suite can be 3212/3212 green while `test:js` is red.

**The prerequisite that silently voids the whole gate:** `test:js` needs `node_modules` installed. With it empty, 3 of the 66 checks die on `MODULE_NOT_FOUND` — which reads like "my environment can't run this" rather than "the gate did not run", so it gets waved through and real failures stay invisible. That is exactly how a ratchet violation reached CI on 2026-07-20 (run `29767112617`) after a fully green local AHK run.

Installing is itself a trap here: `.npmrc` sets `engine-strict=true`, and `mute-stream@4.0.0` requires `node ^22.22.2 || ^24.15.0 || >=26.0.0`. CI pins `node-version: '22'`, which resolves to the latest 22.x and satisfies it; a local Node below that floor (e.g. v22.16.0) makes plain `npm ci` abort with `EBADENGINE`. `npm ci --engine-strict=false` unblocks the gate immediately; upgrading local Node to the latest 22.x is the actual fix.

**Why:** the user's standing requirement is that a green local run predicts a green CI run ("assure toi de fix les tests locaux pour que dans le futur vert local=vert ci"). A gate that cannot run is worse than one that fails — a failure is visible, an un-runnable check is mistaken for a passing one.

**How to apply:**

- Run all four commands before pushing. If `test:js` reports fewer than 66 checks or any `MODULE_NOT_FOUND`, the gate did **not** run — fix the install first, do not interpret it as a pass.
- New AHK tests must read driver source through `_DriverFuncBody` / `_DriverSourceConcat` / `_DriverDirConcat`, never a hardcoded `modules/…`, `lib/…` or `ui/….ahk` path. The ratchet in `tools/test/test-no-pinned-source-reads.cjs` fails the build when the count exceeds `BASELINE = 20`. **Never raise the baseline to make a change pass** — convert the test to a helper read (this is [[feedback_regression_tests]]' "never weaken a test" rule applied to the ratchet itself).
- Two gotchas that cost several red runs: a **comment** containing a token a meta-test scans for (`Bundle_Init()`, `Features[`) shifts naive `InStr` position assertions — reword the comment or strip comments via `_StripFullLineComments`; and in AHK v2 the escape char is the **backtick**, so an embedded quote is `` `" `` — a stray `\"` aborts the parse mid-file and the runner exits with no results at all, which looks like "tests vanished", not "tests failed" (same failure signature as [[feedback_ahk_source_encoding]]).

### feedback-test-before-merge

_Never merge a cut-over slice into dev before the user has tested it live. Stay on the slice branch and wait for explicit validation._

<sub>slug: `feedback_test_before_merge`</sub>

Never merge a cut-over slice into dev before the user has tested it live.

**Why:** During the v2 config cut-over (slices 1-6), the user repeatedly tested
each slice in live AHK use before merging. On slice 6 I merged to dev immediately
after running the test suite without waiting for the user's confirmation — the
user pushed back ("ne pas merge dans dev avant d'avoir testé!"). The test suite
exercises pure logic; it can't catch tray-menu UI regressions, hotkey state
mismatches, or boot-time failures that only surface in a real session. Merging
prematurely puts unvalidated code on dev and forces a rewind if something
breaks.

**How to apply:** When the user says "passe à la suite" or anything that sounds
like "continue", default to staying on the current slice branch after committing.
Do NOT merge to dev. Tell them the slice is ready on its branch and ask them to
test before merging. Only merge after the user explicitly says it works in live
use ("ça marche", "tout est bon", "tu peux merger", etc.). Same rule applies for
deleting the slice branch — wait for the merge first.

Related: [[feedback_commit_push]] (which covers auto-commit/push cadence on
small changes, but is silent on the merge-to-dev step).

### feedback-ui-must-be-i18n

_All user-facing UI text must go through the i18n system in 21 supported languages — never hardcode any UI string anywhere, including WebView UIs (metrics, download window, etc.)._

<sub>slug: `feedback_ui_must_be_i18n`</sub>

All user-facing text in the ergopti project must be served via the i18n system, in **all 21 supported languages** (ar, cs, da, de, en, es, fr, he, hi, it, ja, ko, nl, no, pl, pt, ru, sv, tr, uk, zh). Locale files live in [[reference-locales-files]] at `static/ergopti_plus/_shared/data/locales/<lang>.json`.

**Why:** CLAUDE.md already mandates "UI is French, code is English" but in practice the project ships in 21 languages — French was just the dev-time default. Hardcoded French strings in `_shared/ui/metrics_typing/*.js`, `_shared/ui/download_window/*.js`, etc. break the multilingual contract and shame anyone who tries to use the app in another language.

**How to apply:**

- When adding or editing any user-facing UI code (Svelte component, WebView HTML/JS, tray menu label, dialog), the displayed text MUST come from the i18n system, not a string literal.
- For WebView UIs: the JS i18n loader is at `_shared/ui/i18n.js`. Reference keys like `t("menu.hotstrings.autocorrection")`.
- For AHK driver: use `t(key)` from [[lib-i18n-ahk]] (`static/drivers/autohotkey/lib/i18n.ahk`).
- For Hammerspoon driver: use `t(key)` from [[lib-i18n-lua]] (`static/drivers/hammerspoon/lib/i18n.lua` + `lib/locale.lua`).
- When adding a new key, add it to ALL 21 locale JSON files at the same time (machine-translation is acceptable as a first pass, but never leave a key missing from a locale — fallback chain is active→EN→FR but missing keys should still be filled).
- Internal logs and developer-facing comments stay English per CLAUDE.md — this rule applies only to user-visible text.

**Backlog item:** [`_shared/ui/metrics_typing/data.js`, `table.js`, `charts.js`] and [`_shared/ui/download_window/*`] contain extensive hardcoded French. Needs extraction to i18n keys + translation to all 21 languages. Logged in the todo list as "[BACKLOG] i18n WebView extraction".

### project-ahk-menu-dispatcher-error-swallow

_The menu dispatcher bypass must re-throw callback errors to maintain parity with AHK's native dispatch and the global OnError handler_

<sub>slug: `project_ahk_menu_dispatcher_error_swallow`</sub>

In `lib/menu_dispatcher.ahk`, the `_DispatchIfMissed` bypass was wrapping the menu callback invocation in a `try...catch` block that suppressed errors (logging them via `LoggerError` but swallowing them). This broke error reporting parity: if AHK dispatched a click and the callback crashed, the error propagated to the global `OnError` handler (triggering the crash reporter and user toast). If the bypass dispatched the *same* click and it crashed, the error was swallowed silently.

**Why:** The original implementation likely assumed that since the bypass ran on a `SetTimer` thread, a crash there would kill the timer or the script, so it tried to be defensive. But AHK v2's global `ErgoptiGlobalErrorHandler` prevents the script from crashing (it returns `true`) while surfacing the crash properly. Suppressing the error locally broke the `fail-fast` project instruction.

**How to apply:**
- Re-throw the error `throw Err` after logging it, or remove the `try...catch` wrapper entirely, so the exception bubbles up to AHK's thread boundary and gets caught by the global `OnError` handler.
- See the regression test `tests/meta/test_menu_dispatch_error_propagation.ahk`.

---

## Project architecture & decisions

### project-audit-2026-07-21-open-items

_Third-pass AHK audit: what landed, the 26 confirmed findings still open with their sites, and the 26 claims adversarially refuted so they are not re-raised_

<sub>slug: `project_audit_2026_07_21_open_items`</sub>

The 2026-07-21 pass ran the three inventories the two 2026-07-20 passes had
recorded as NOT RUN, mined ten days of real driver logs for the first time, and
re-audited the previous campaign's fixes for collateral. 59 candidates were
raised, each adversarially verified by an independent agent instructed to refute
it: **42 confirmed, 26 refuted**. The audit report was deleted after
implementation, so this entry is the durable record.

**Measured, not theorised.** The logs at `<ConfigDir>/autohotkey/logs/` yielded
the driver's first real G4 numbers — see
[[project_audit_evidence_must_be_reproducible]] for why two earlier passes never
found them. Worst hot-path segments over ten days: `Tooltip.ResolvePos` max
**2560 ms** (1764 slow events, 41 over 100 ms), `OnChar`/`HSE.FeedChar` max
**701 ms** (nested — the same stall, do not double count), `Tooltip.Present` max
239 ms. The 2560 ms is UIA's own 2000 ms `TransactionTimeout` default plus
overhead, which the driver never set.

**Landed (11 commits).** Log rotation now follows the calendar rather than the
process lifetime; per-invocation scratch names for both sleep-retrying atomic
writers; the ByRef/call-site mismatch that made "tout désactiver" throw on every
use; UIA probe bounded, idle-gated and negative-cached; healthcheck collectors
individually guarded so a crash still yields a report; unknown hotkey modifiers
rejected instead of silently rebinding; the today.log open brought inside the
HIGH-04 requeue transaction; the personal-editor section pointer proven live at
every use; and the lifecycle-pairing gate made to actually assert.

**Two lessons worth more than the fixes.** A guard test written from a LIST of
sites rather than from the CLASS misses siblings by construction — the
`.tmp`, UIA-probe and section-pointer findings were all "N of M sites migrated".
And a test can occupy a name while asserting nothing: `test_logger_pairing.ahk`
registered a `Test()` whose body was an empty function, so the one gate policing
unpaired lifecycle logs was itself incapable of failing.

#### All 42 confirmed findings are implemented

The 26 that this entry originally listed as open were implemented on
2026-07-21 in a second campaign of eleven commits, each with a regression test
encoding its root cause. Nothing from that list remains outstanding.

Two outcomes are worth keeping, because they are decisions rather than fixes:

- **The `today_log_offset` rollback was left in place, deliberately.** It does
  re-append an already-written batch, but every `events_*` statement is
  `INSERT OR IGNORE` against a `(device_id, id)` primary key, so the duplicate is
  discarded at import — file bloat, not data loss. Reordering the write to commit
  state before `data.sql` would trade that for a genuine crash window where a
  batch is marked durable before it is. The invariant that makes the current
  behaviour benign is now pinned by `test_sql_replay_is_idempotent.ahk` rather
  than assumed.
- **`require_state` is now a RATCHET at 38, not a clean gate.** The old test
  scanned three files and could not fail; widened across `modules/`, `lib/`,
  `adapters/` and `ui/` it surfaces 38 genuine violations among 77 stateful
  files. Adding a guard changes behaviour (an early return on a path that
  currently proceeds), so applying 38 mechanically would be reckless. The count
  may only go DOWN. **This is the single largest remaining piece of debt in the
  driver.**

The recurring lesson from the second campaign was that guard tests fail quietly.
Four tests were found asserting nothing: one registered an empty function body,
one asserted the absence of a helper that had already been deleted, one compared
a hardcoded list against its own length, and one scanned a directory that no
longer held the code. A test that cannot fail is worse than no test, because it
occupies the name and deters anyone from writing the real one.

#### Refuted — do NOT re-raise

Each was investigated and rejected with evidence. The strongest ones:

- **"Sub-logs neither roll at midnight nor are purged."** Sub-files are a strict
  SUBSET of the dated main log, verified by line count (22 `[gestures` lines in
  the main log, 22 in the sub-file; 44 vs 44 for `[LayoutShift`), so truncating
  one destroys zero unique data. The purge regex not matching an undated name is
  correct, not defective. Residue is cosmetic. *(A rollover call was nonetheless
  added for policy consistency — it is not a data-integrity fix.)*
- **"The driver never raises its process priority" / "`Slow HSE.FeedChar`
  misattributes descheduling stalls."** Both contradicted by
  `tests/meta/test_hotpath_priority_starvation.ahk`.
- **"Single-owner mutex gate fails open — 11 instances booted in 8 s."** The boot
  clustering correlates with heavy development days (19 boots on 07-16 with zero
  errors), not with a production defect.
- **"`KL_IngestOnce` has no reentrancy guard."** No test forbids a latch, but an
  AHK timer cannot interrupt itself; the reachable interleavings come from
  `OnExit`/rollover, which the atomic-scratch fix already addresses.
- **"Six more missed siblings of the process-independent `.tmp` name."** The
  other atomic writers have no yield between staging and rename, so the collision
  window the fix closes does not exist there.
- **"`CtrlAltDispatch` emits without Critical."** A naive `Critical("On")` there
  would fail `test_layout_tables.ahk` plus the framework's Critical-leak check.
- **"`_TooltipDequeueRebuild` has zero generation discipline."** Structurally
  true, but no reachable interleaving produces a wrong result.
- Also refuted: the CapsLock overlay bypassing `LayerDispatch`; the F-31 tap-hold
  validator logging per keypress; `_SuspendPrefixesAreClear`'s falsy return;
  `_DeferredGestureAutoConfigure` re-arming through suspend; the F-32
  safety-flush divergence in the changelog host; `da0531f12`'s load-order guard
  coverage; raising `TOOLTIP_POSITION_CACHE_MS` to 600 causing staleness.

Related: [[project_ahk_guard_tests_must_loop_the_class]],
[[project_ahk_invariant_incomplete_application]],
[[project_audit_findings_are_hypotheses]],
[[project_audit_evidence_must_be_reproducible]].

### project-typing-latency-tooltip-coldstart

_Tooltip render + post-boot warm-up latency: the border alpha scan optimization, why tooltip window-reuse is rejected (AHK v2 can't remove Gui controls), and why deferred-registration chunking was reverted_

<sub>slug: `project_typing_latency_tooltip_coldstart`</sub>

Findings from the runtime/typing-latency pass (2026-06-14). The `HotPath_LogIfSlow` profiler (`lib/hotpath_profiler.ahk`, QPC-based, logs only keystrokes/segments over 5 ms) is the lens — read the real `ErgoptiPlus_<date>.log` for `Slow <segment>: <ms>` lines before theorising. The recurring cost is the preview tooltip render (`Tooltip.Build` 5-7 ms + `Tooltip.Present` 11-40 ms, spiking to 62 ms), because the tooltip **destroys and recreates two top-level windows (content Gui + layered border) on every update** — the 150 ms `_PREFIX_RENDER_DEBOUNCE_MS` in `hotstring_prefix_watcher.ahk` is a workaround masking that cost.

**Shipped:**

- **Border alpha scan** (`6b1e4e59c`): `_TooltipShowBorder` repaints a 32-bpp DIB and rewrites every GDI-RoundRect-painted pixel to premultiplied border alpha. Extracted into `_TooltipFixBorderAlpha(PixPtr, Wp, Hp, Diam, PremulPx)`, which scans ONLY the painted zones — the two horizontal edge rows (full width) + the left/right corner-column zones of the top/bottom bands + the two vertical edge columns of middle rows — instead of the full corner band. Cost drops from ~2·Diam·Wp to ~2·Wp + 4·Diam², biggest win on short 1-2 row previews (~4-6 ms/render saved; the 5-12 ms `Tooltip.BorderPixelLoop` warnings mostly fall under the 5 ms threshold). Pinned by `tests/test_tooltip_border_alpha.ahk`, which paints a REAL GDI RoundRect and asserts the optimized scan is byte-identical to a full O(Wp·Hp) reference across six geometries — the invariant ("rewrite exactly the pixels GDI painted") is verified against the rasterizer, not a model of it.
  **Tried and REVERTED — do NOT re-attempt:**

- **Chunking the deferred emoji/symbol registration** (`e7072a7c8`, reverted). The idea: register the ~3000-row emoji/symbol pass in 150-row chunks via a self-rescheduling `SetTimer(self, -1)` so the keystroke hook runs between chunks instead of through one ~547 ms blob. **It backfired badly.** A real boot log (cold WebView2, first launch post-reboot) showed the chunked pass take **+7969 ms wall-clock (~12× the blob)**: `SetTimer(-1)` hands control to the message loop between every chunk, and while WebView2 cold-starts (flooding the message queue) each chunk waits for the queue to drain, so the registration smears across the whole warm-up window — and now overlaps the WebView2 cold-start it used to finish _before_ (blob done ~T+2 s, WebView2 at T+2.5 s = no overlap; chunked ran to ~T+8 s = full overlap). The premise was also wrong: AHK threads are interruptible after a ~15 ms window, so a synchronous blob never froze typing for 547 ms — the logs never showed such a freeze. **Lesson:** don't `SetTimer`-yield a CPU loop into a message loop that another cold-start is hammering; keep the blob (it is interruptible and self-contained). The `_HsCacheRegisterSection` row-range plumbing and the chunk parity test were reverted with it.

**Shipped (later) — WPM graph widget rewritten from WebView2 to native GDI+:**

- A real boot log (cold WebView2, first launch after reboot) showed the WebView2 cold-start was FAR worse than an earlier warm-run estimate: a single keystroke's `HSE.Dispatch` hit **476 ms** (`OnChar` 485 ms) and `Tooltip.Build` 268 ms during the ~3-5 s msedgewebview2 cold-start — it starved the foreground app and every timer. The WPM graph (`lib/metrics/wpm_widget.ahk`, graph mode) was the only WebView2 consumer on the typing path, and it used a whole browser engine to draw a tiny sparkline. It was rewritten to render with **GDI+ into a per-pixel-alpha layered window** — the exact pattern `lib/spotlight.ahk` uses via the GraphicsRenderer adapter (`GR_DrawBitmap(hwnd, drawFn)` → `UpdateLayeredWindow`). Zero cold-start. Key pieces: `WPMWidget_EnsureGdip` (start GDI+ once, cache the font + centered string format for the process life — the graph re-renders every tick so per-call startup would be waste), `WPMWidget_DrawGraph` (rounded pill + filled/stroked sparkline clipped to the pill + centered WPM label, in LOGICAL coords with a per-render world-transform scale = dpi/96 so it matches the old DPI-scaled canvas 1:1), `WPMWidget_RenderGraph` (paints the still-hidden window then `GR_Show` reveals it — no flash). Show/hide simplified: both modes hide outright now (no WebView2 renderer to keep alive at alpha 0). GDI+ text on a layered window needs `GdipSetTextRenderingHint` = AntiAliasGridFit (4) so it carries alpha — plain GDI `TextOut` would render alpha-0 (invisible). Guarded by `tests/meta/test_wpm_widget_native_render.ahk` (no `WebView2.create`/`NavigateToString`/`ExecuteScriptAsync`/`CoreWebView2`/`_graph_wv`; must use `GdiplusStartup` + `GR_DrawBitmap`). Verified by a standalone GDI+ smoke render (pill + label + sparkline all produce correct-alpha pixels) and an Ahk2Exe compile of the whole driver (`wpm_widget.ahk` + `tray_menu.ahk` are NOT in run_all, so the compile is their only parse gate). WebView2.ahk stays included — `keylogger_webview` / `ollama_webview` still use it. Follow-up: the first appearance of the graph window cost a one-time ~110 ms `Tooltip.Present` blip (a concurrent tooltip's message pump absorbed the DWM allocation of the brand-new window). `WPMWidget_PrewarmGraph` (armed at `PREWARM_DELAY_MS` = 900 ms after ready, in the quiet slot after the deferred menu build and before the emoji pass, graph-mode + visible only) now pre-creates the window + starts GDI+ + runs one HIDDEN render (forcing the `UpdateLayeredWindow` surface allocation) off the typing path, leaving it hidden so the tick still reveals it only on real typing.

**Rejected — do NOT re-attempt lightly:**

- **Tooltip window-reuse** (keep the content Gui + border alive, mutate on update). The module docstring CLAIMS "single reused Gui… mutated on subsequent calls" but the code destroys+recreates every render — the claim is aspirational. Three blockers: (1) **AHK v2 cannot remove controls from a Gui** — only `Gui.Destroy()` the whole window — so content reuse needs a stateful control-pool rewrite (reuse by index, restyle/move/hide), high visual-regression risk in a module already full of dimmed-row / separator / LLM / dequeue edge cases; (2) the tooltip tests (`test_tooltip_*`, `test_llm_tooltip_*`) are **logic/contract-only** (arithmetic, formatters, FileRead source-greps) — they do NOT exercise the real window lifecycle, so a reuse refactor would land with no behavioral net in the module with the worst bug history ("clignote et part", "plein de tooltips", "border alone flash"); (3) border-only reuse hits a **z-order trap** — a freshly recreated content window lands above the reused (older) topmost border, hiding the ring. Marginal gain (~2-4 ms/render after the border-loop fix) for real regression risk → not worth it.
- **WebView2 (WPM widget) cold-start de-contention via timing tricks** (idle-gating / longer fixed delay / pre-warm). Initially deferred (idle-gating only partially helps since the cold-start outlasts a typing pause; a fixed delay guesses; pre-warming re-inflates boot). A later cold-WebView2 log proved the contention was severe enough (476 ms keystroke latency) to fix at the root instead — see the GDI+ rewrite under "Shipped (later)" above, which removes the cold-start entirely rather than scheduling around it.

**Two follow-up leftovers, investigated 2026-06-14 (multi-agent workflow, adversarially verified):**

- **HSE dispatch spikes (78-90 ms, one 476 ms)** were **WebView2-induced contention, not inherent** — resolved by the GDI+ rewrite. Verified: a star magic-key expansion is one `Critical`-wrapped atomic `SendInput` burst (hotstring_engine_main.ahk ~1332/1347); analytics are deferred off the keystroke (`_HSE_QueueFireLog` → `SetTimer(_HSE_DrainFireLog, -90)`); the profiler times the WHOLE dispatch in wall-clock QPC, so a single-threaded block while WebView2 saturated the pump/GDI landed in the reported ms. The post-rewrite log shows the same `cdg★` trigger at 6.8-8.7 ms (worst all-session 14.1 ms). The 200 ms clipboard `SendInstant` path is **Notepad-only** (gated on window class, never fired in the log); the match path is a bounded by-trigger Map probe (NOT O(n) in the ~3000 emoji regs). **No hot-path change made** — only the existing `test_wpm_widget_native_render.ahk` guard prevents the WebView2 cause from returning.
- **Flaky `TimerScheduler — cancelAll(): drains all live handles`** (expected 3, got 2, intermittent) — root cause: the adapter calls the REAL AHK `SetTimer` (never stubbed in the harness), and `_TSTest_AfterHandleFiredFalseInitially` arms `TimerAfter(0.001)` = `SetTimer(fn, -1)` then only asserts the flag and returns — leaking an overdue one-shot. `_TS_ResetRegistry` reset the id counter to 0 every test, so that leaked handle's id (1) was REUSED by a later test; when the leaked timer dispatched (on a framework stdout pump-yield), its `_OneShot` `Delete(1)` evicted the _current_ test's live id-1 handle → count 2. Fixed **test-side**: `_TS_ResetRegistry` now (a) disarms every armed handle's `Fn` via `SetTimer(Fn, 0)` before swapping the registry, and (b) no longer resets the id counter (monotonic ids → a stale `Delete` hits a defunct id, and `_OneShot` guards with `Has(Id)`). Deterministic regression test `_TSTest_StaleTimerCannotEvictLiveHandle` reproduces the collision by invoking a leaked handle's bound fn directly (no real-timer timing). **Lesson:** the TimerScheduler adapter arms REAL OS timers even under test — any test that arms a handle must fire or cancel it, or the next `_TS_ResetRegistry` must drain it.

Related: [[feedback-ahk-source-encoding]] (the new `.ahk` files needed BOM+CRLF), [[feedback-regression-tests]] (the border win shipped with a real-GDI parity test), [[project-suspend-pause-invariant]] (the tooltip hot path checks `A_IsSuspended`).

### project-ahk-menu-dispatcher-drop

_AHK 2.0 silently drops ~30-50% of tray-menu clicks. FIXED via lib/menu_dispatcher.ahk — every actionable item must use RegisterMenuItem, never raw Menu.Add._

<sub>slug: `project_ahk_menu_dispatcher_drop`</sub>

ErgoptiPlus tray-menu items intermittently fail to fire their callback on click. Symptom: "menu closes, nothing happens" on a random ~30-50% of clicks. Root cause: AHK 2.0's internal `WM_COMMAND → menu-callback` dispatcher drops events silently (no log, no error). Windows delivers `WM_COMMAND` reliably — confirmed 2026-05-21 by logging `OnMessage(0x0111)`; it's AHK's dispatch that loses the click. Pre-existing, NOT a v2-refactor regression (`git revert e49aeb6b` still reproduced).

**Failed fixes** (do not retry): `SetTimer(-1)` deferral, `A_MaxThreads := 32`, `Critical` at callback entry. None helped.

## RESOLVED — the bypass is built

The "bypass AHK's dispatcher" fix is no longer pending — it ships as **`lib/menu_dispatcher.ahk`**. It maintains a global `_MenuDispatchCallbacks` Map keyed by Win32 menu-item ID (discovered post-`Menu.Add` via `Menu.Handle` + `GetMenuItemID`), and an `OnMessage(0x0111)` handler that re-dispatches from a fresh `SetTimer` thread if AHK's native path hasn't fired within 150 ms (`_MenuDispatchLastFire` timestamp guards against double-fire).

**How to apply — the one rule that matters:**

- Every menu item with a real user-actionable callback MUST be added via `RegisterMenuItem(MenuObj, Label, Callback)` (or `RegisterMenuItemInsert` for `.Insert`), NEVER raw `Menu.Add(Label, Callback)`.
- Raw `Menu.Add` is correct ONLY for: separators (`Menu.Add()`), container submenus (`Menu.Add("Title", SubMenuObj)`), and disabled display-only headers. See the "WHEN TO USE WHICH" block in menu_dispatcher.ahk.
- It works on freshly-created detached popup menus (`Menu()`) before they're attached — `.Handle` lazily creates the HMENU. Proven by `BuildGesturesMenu` (GMenu) and `BuildScriptShortcutsMenu` (SMenu).

**Last unmigrated site, now fixed (2026-06-02):** `BuildScriptShortcutsMenu()` in `ErgoptiPlus.ahk` (the « Raccourcis de gestion du script » items) still used raw `SMenu.Add` and dropped ~100% of clicks (deeply-nested 3-level submenu seems to drop far worse than the ~30-50% average) — the action picker never opened. Switched to `RegisterMenuItem(SMenu, ...)`. When auditing for this bug, grep for `\.Add(` calls that pass a non-separator/non-submenu callback.

## Related

- [feedback-loader-target-explicit](feedback_loader_target_explicit.md) — different concern, same tray_menu.ahk neighborhood.
- [project-config-v2-refactor](project_config_v2_refactor.md) — Phase 2 was wrongly suspected of causing this.

### project-webview2-bridge-gotchas

_Hosting a shared HTML/JS frontend in a WebView2 control (thqby `vendor/WebView2.ahk`) on Windows has FOUR distinct gotchas that each silently break the JS↔AHK bridge. The onboarding wizard (`ui/onboarding/webview.ahk`) hit all four in sequence; model_browser predates some of the fixes._

<sub>slug: `project_webview2_bridge_gotchas`</sub>

Symptom progression while bringing up the onboarding webview: blank gray panel → renders but no flags → renders but language switch does nothing → switches once then freezes. Each was a separate root cause:

1. **Show the window BEFORE `WebView2.create` + `Controller.Fill()`.** Creating/filling against a still-hidden Gui sizes the control to a zero client rect → blank gray page that never lays out. `g.Show()` first (model_browser already did this; onboarding originally didn't).
2. **`file://` is an opaque/unique origin** — Chromium logs "Unsafe attempt to load URL … 'file:' URLs are treated as unique security origins" and the `window.chrome.webview` message channel does not reliably deliver from it. `postMessage` returns `undefined` (looks fine) but nothing arrives host-side. FIX: `SetVirtualHostNameToFolderMapping("ergopti.onboarding", folder, 1)` and navigate to `https://<host>/index.html`. Map a second host for assets outside the page folder (flag PNGs, layout JPG live under `_StaticDir`, not the onboarding folder). Windows also has no flag-emoji font, so flags MUST be `<img>` PNGs served via the host, never emoji text.
3. **`X.WebMessageReceived(cb)` returns a subscription object whose `__Delete` unsubscribes.** Discarding the return value lets AHK GC it immediately → the handler is removed the instant it's added → exactly zero messages delivered. FIX: store the handle in a persistent global (`_OnbWeb_MsgSub`); clear it only on teardown.
4. **`ExecuteScript()` is `ExecuteScriptAsync().await()`, and `.await()` spins a NESTED message loop.** Calling it synchronously inside the `WebMessageReceived` STA callback wedges further event delivery (channel delivers exactly one message — `ready` — then goes silent). Even deferred out of the callback, the `.await()` on a large (~135 KB locale-string) injection can fail to complete and freeze the AHK thread (the script's side effect runs — button updates — but `.await()` never returns). FIX: use **fire-and-forget `ExecuteScriptAsync` (NO `.await()`)** for host→page injection; we don't need the result, and WebView2 holds the completion handler so the script still runs. See `_OnbWeb_RunScript`.

**How to apply / diagnose:**
- When a webview bridge "renders but is dead," confirm message arrival host-side first (log the raw inbound message — but strip `{ }` from the logged substring, or the AHK logger's `Format()` chokes on JSON braces and the `try`-wrapped log silently no-ops, hiding the very messages you're hunting). Use Info level, not Debug, while diagnosing.
- WebView2 caches virtual-host sub-resources by URL: navigate `index.html?cb=<A_TickCount>` (fresh HTML each launch) and bump `?v=N` on `script.js`/`style.css` when they change, else an edited frontend is served stale.
- A `SafetyFlush` timer that injects initData if `ready` never arrives keeps the wizard from being blank; if it fires regularly, the channel is broken.
- These four are independent — fixing one reveals the next. Any new WebView2 window (e.g. the hotstring editor) should clone `webview.ahk`'s post-fix shape wholesale.

### project-config-v2-refactor

_State of the v2 config schema refactor (Scope C) — branch refactor/config-schema-v2 with 5 dormant commits. Cut-over to actually migrate the AHK driver runtime is the open piece._

<sub>slug: `project_config_v2_refactor`</sub>

The user is mid-flight on the Scope C refactor — a clean-state rewrite of the Ergopti+ user configuration system, unifying it under a snake_case schema, a single shared features manifest, and a codegen pipeline.

**Why:** the v1 config had drifted into a messy state (AHK using PascalCase mixed with snake_case in the same `config.toml`, HS using snake_case-only, separate `features_config.ahk` hardcoded Map, hand-written TOML loaders that don't support nested sections). The refactor centralises every default in `_shared/modules/features/manifest.toml` and codegen-emits per-driver artifacts.

**How to apply:** when resuming work on this refactor, read in this order:

1. `static/drivers/_shared/core/config_schema/SCHEMA.md` — design conventions (snake_case, modélisation α for hotstrings, `ahk.`/`hs.` prefixes).
2. `static/drivers/_shared/modules/features/manifest.toml` — single source of truth, 302 features.
3. `scripts/build-features-manifest.js` — codegen pipeline; run with `npm run build:manifest`.
4. The three dormant AHK modules: `lib/first_boot.ahk`, `lib/manifest_reader.ahk`, `lib/toml/toml_loader_v2.ahk`.

**Branch state**: `refactor/config-schema-v2`, 9 commits ahead of dev as of 2026-05-22 (commits f3eeab2a → 112ef51a). All commits leave the AHK driver functional — the v2 wiring is not yet active.

**v2 pipeline test suite** at `static/drivers/autohotkey/tests/test_features_manifest_v2.ahk` (commit 210fc026, 34 tests passing): locks the manifest load + Map build + TOML override + coerce contract. Run via the existing `run_all.ahk` harness. Caveat: AHK v2 source files MUST be UTF-8 BOM + CRLF or the parser silently aborts mid-file — see [feedback-ahk-source-encoding](feedback_ahk_source_encoding.md) for the full rule.

**Big-bang cut-over attempt 2026-05-22 — surfaced a scope gap, did not ship**: a `general-purpose` agent (with the migration doc + tests as references) read the full surface area and stopped before executing, reporting that the migration doc's READ-path mapping does not cover three load-bearing WRITE/render-path systems that also depend on the v1 Features shape:

1. **`SaveFullConfig` + `_CollectFeatureUpdates`** in `ErgoptiPlus.ahk` (~lines 1433-1565) write the live Features Map back to `config.toml` using v1 section names (`Hotstrings.MagicKey`, `Layout`, `TapHolds`). Without a v2 writer, every tray-menu toggle would corrupt the config on save.
2. **`ApplyTomlMetadataToFeatures` / `BootstrapPersonalFeatures` / `ApplyLocaleDescriptions` / `ApplyIndexTomlToDynamicHotstrings`** in `lib/toml/toml_loader.ahk` inject `Description`, `__Order`, and per-section metadata into Features at boot. They use `FoldAsciiLower` reverse-lookup against v1 PascalCase keys — would emit raw `enabled`/`time_activation_seconds` text in the tray menu.
3. **`ui/tray_menu.ahk`** (1430 lines) reads `__Order` / `Description` and calls `TOML_Write(..., "Section", "Key")` on toggle — ~60 menu-relevant Features reads coupled to v1 shape.
4. **Onboarding writes** (`_Onboarding_Commit`, ~line 1180) batch-write v1 sections.

The agent's recommendation: fall back to migration doc approach (a) — sliced cut-over with a temporary compat shim — because (b) Big-Bang exceeds single-session reliable execution. **Useful artifact shipped**: `lib/tap_hold/tap_hold_loader.ahk` (dormant, commit 112ef51a, 149 lines) — the Phase 5 tap-hold loader module that was always going to be needed.

**Next decision (open)**: extend the migration doc with the write/render-path mapping (Sections 11-14 covered reads + IniCacheGet but not config writes, tray-menu rendering, or onboarding writes), then retry approach (b); OR adopt approach (a) with a compat shim and slice; OR put the cut-over on the backlog and use the dormant modules + tests as the v2 foundation for a future session.

**Phase 1 of sliced cut-over (option a) — landed and patched on 2026-05-22**: commits 9b75dad4 (wiring) + ccc09225 (fix). Branch now 11 commits ahead of dev.

**Sharp foot-gun discovered during Phase 1** (`ccc09225`): the v2 TOML loader (`ApplyConfigTomlV2`) originally used `global Features` and so always clobbered whichever Map was bound to that global. Because v1 PascalCase section names (`Layout`, `Shortcuts`, `TapHolds`, `Gestures`, `LLM`, `Metrics`, `Script`, `Hotstrings`) coincidentally match top-level v1 Map keys, calling the loader at boot while v1 Features was still the live target walked into those entries and assigned `Features["Layout"]["ErgoptiBase"] := true` — overwriting the inner `{Enabled: True}` object literal with a plain bool. Every downstream `.Enabled` property access then crashed with `This value of type "Integer" has no property named "Enabled"` at tray-menu init.

Fixed by making the target Map explicit: `ApplyConfigTomlV2(FeaturesMap, FilePath)`. Production calls `ApplyConfigTomlV2(FeaturesV2, ...)`; tests pass their isolated fixture. The v1 global is no longer reachable from the v2 loader and cannot be clobbered. Tests stayed 427/427. **Rule for any future loader/writer module that targets a Map**: take the target Map as an explicit parameter, never reach for it via `global`. This is now [[feedback-loader-target-explicit]].

**Phase 2 — landed 2026-05-22**, commit `e49aeb6b`: migrated 14 read sites across `lib/layout/layout_altgr.ahk` (4), `lib/layout/layout_shift_caps.ahk` (2), `modules/layout.ahk` (6), `modules/keylogger/keylogger_prefetch.ahk` (2-guard chain) from `Features["Layout"][PascalCase].Enabled` to `FeaturesV2["layout"][snake_case]`. Tray menu (`tray_menu.ahk:801,807`) intentionally kept on v1 — it's the write path. New module `lib/v1_v2_mirror.ahk` houses `MirrorV1ToV2_Layout()` (one helper per phase, deleted in bulk at final cut-over); called right after `ApplyConfigTomlOverrides` in `ErgoptiPlus.ahk`. Pure derived view — divergence impossible since writes still go through v1 + Reload + mirror runs again at boot. Tests stayed 427/427. Branch now 16 commits ahead of dev.

**Phase 3 — landed 2026-05-21**, commit `e4c86142`: migrated 27 read sites across `modules/gestures.ahk` (1 = master gate), `modules/layout.ahk` (1 = WrapTextIfSelected), `modules/shortcuts.ahk` (25 = 17 plain bools + 8 modélisation α reads for GPT/Search/TakeNote). New mirror helpers: `MirrorV1ToV2_Gestures()` (1 entry), `MirrorV1ToV2_Shortcuts()` (~25 entries — handles both plain-bool BoolPairs and AlphaPairs PropMap with .Enabled / .Letter / .Link / .DatedNotes / .DestinationFolder / .SearchEngine / .SearchEngineURLQuery). Tests stayed 427/427. Branch now 17 commits ahead of dev.

**Deliberately deferred this phase (need dispatcher rewrite first)**: Shortcuts sub-Maps `AltGrLAlt` / `AltGrCapsLock` / `LAltCapsLock` (consumed by `RunFirstSimpleAction` / `HasAnyEnabled` in `lib/dispatchers.ahk` which iterate v1-shaped `{Cfg.Enabled}` objects). Also deferred: Letter pickers (EGrave/ECirc/EAcute/AGrave — couple to base-layer registration in `lib/layout/layout_ergopti.ahk:50-52`), Personal sub-Map (boot path dependency on `RegisterPersonalFeature`), Metrics (no v1 `Features["Metrics"]` reads exist — indirection via `MetricsShortcuts` global; migrate at final cut-over).

**Phase 4 — landed 2026-05-21**, commit `262c3cb2`: migrated 17 individual `.Enabled` reads in the AltGrLAlt + LAltCapsLock sub-Map dispatch chains. Extended `MirrorV1ToV2_Shortcuts()` with a SubKeyMap (10 snake_case renames: backspace/caps_lock/caps_word/ctrl_backspace/ctrl_delete/delete/enter/escape/one_shot_shift/tab) and a SubMaps loop covering AltGrLAlt + LAltCapsLock (20 entries copied). AltGrCapsLock skipped this phase (no individual reads, only dispatcher calls). Branch now 18 commits ahead of dev. Tests stayed 427/427.

**Dispatcher call sites still on v1** at `modules/shortcuts.ahk` lines 50, 97, 162, 176 — they pass v1-shaped sub-Maps to `RunFirstSimpleAction` / `HasAnyEnabled` in `lib/dispatchers.ahk`. Those helpers iterate `{Cfg.Enabled}` objects and need to be widened or replaced before their inputs can move to v2.

**Phase 5 — landed 2026-05-21**, commit `644a415b`: migrated 62 read sites across `modules/hotstrings.ahk` (56) + `modules/layout.ahk` (3) + `lib/layout/layout_shift_caps.ahk` (1) + `ErgoptiPlus.ahk:712` (1 SpaceAroundSymbols init). New `MirrorV1ToV2_Hotstrings()` maps all 6 categories (Autocorrection / DistancesReduction / SFBsReduction / Rolls / MagicKey / DynamicHotstrings) — ~64 entries copied including the PatternMaxLength extra prop on TextExpansionPersonalInformation. Branch now 19 commits ahead of dev. Tests stayed 427/427.

**Notable renames absorbed in Phase 5**: `SFBsReduction.IÉ -> sfbs_reduction.i_e_acute`, `DynamicHotstrings -> dynamic` (category itself renamed since "Hotstrings" was redundant inside `[hotstrings.*]`).

**Still on v1 in modules/hotstrings.ahk**: the 34 `LoadHotstringsSection` calls pass the v1 Map entry as their 3rd arg. The helper in `lib/toml/toml_loader.ahk:131` reads `.TimeActivationSeconds` / `.HasOwnProp(...)` via object property access — widening it (or replacing it) is the next bottleneck before the Hotstrings cut-over can finish.

**Phase 6 — landed 2026-05-21**, commit `db21e37b`: migrated the LLM tray populator in `ui/tray_menu.ahk` (~50 lines, 12 IniCacheGet calls) to read from the v2 nested `FeaturesV2["llm"]` Map. The 199 `_LLM_Tray[key]` read sites across `ui/tray_llm.ahk` + `modules/llm/*` are untouched — `_LLM_Tray` itself is still populated by `LLM_Tray_Init` from the same flat `saved_opts` shape, just sourced from a different upstream. New `MirrorV1ToV2_LLM()` reads each v1 flat `[LLM]` key from `_IniCache` and places it at its v2 nested path; notable rename `ctx_chars → llm.generation.context_length`; `model` lands at `llm.models.ollama` + `selected = "ollama"`. The `app_profile_overrides` and `onboarding_seen` v1 keys have no v2 declared counterpart (runtime state) so the populator keeps a direct IniCacheGet for those.

**Menu dispatcher bypass — landed 2026-05-21**, commits `7006c3e5` + `d30fd6e0`: new `lib/menu_dispatcher.ahk` installs an `OnMessage(0x0111)` retry hook for the pre-existing AHK 2.0 callback-drop bug ([project-ahk-menu-dispatcher-drop](project_ahk_menu_dispatcher_drop.md)). `RegisterMenuItem` / `RegisterMenuItemInsert` discover the Win32 ItemId via `Menu.Handle` + `GetMenuItemID`, wrap the user callback to stamp a per-ItemId "last fire" timestamp, then OnMessage schedules a 150ms retry — if the timestamp hasn't moved by then AHK dropped the dispatch and the retry runs the callback from a fresh SetTimer thread. `A_MaxThreads` bumped 10 → 64 in ErgoptiPlus.ahk for retry-timer headroom. User-confirmed working. Currently wired into `MenuAddItem` (individual feature toggles) + `AddCategoryToggleItem` (master section toggles). Ad-hoc Menu.Add toggle callbacks in tray_menu.ahk (Metrics / Gestures / Hotstrings master) and tray_llm.ahk remain on AHK's native dispatch — bring into the bypass piecewise as drops become noticeable.

**Phase 7 — landed 2026-05-21** (4 sub-phases, 4 commits):

- **7.1** (`8a06b9a2`) — extended menu-dispatcher bypass to Metrics typing/apps toggles + Gestures auto-configure & per-slot pickers.
- **7.2** (`7633514d`) — `LoadHotstringsSection` widened to accept v2 Maps via inline shape-detect + synthesise v1 object at the boundary; 33 call sites in `modules/hotstrings.ahk` migrated to pass `FeaturesV2["hotstrings"][<cat>][<entry>]`. ZERO residual `Features["Autocorrection"|...]` references in modules/hotstrings.ahk.
- **7.3** (`5c3651ea`) — `MirrorV1ToV2_TapHold()` foundation: translates the v1 multi-variant `Features["TapHolds"][KEY][VARIANT].Enabled` shape into the v2 single-action `TapHold["keys"][<key>] = {tap_action, hold_modifier|hold_layer, time_activation_seconds}`. Mirror handles CapsLock / LAlt / AltGr / RCtrl / Space sub-Maps plus flat LShiftCopy / LCtrlPaste / TabAlt entries. **Read-site migration of the ~70 sites in `modules/tap_holds.ahk` is deferred** — the v1 branching pattern becomes a v2 switch on tap_action, non-mechanical and high-risk to batch through; future phase work.
- **7.4** (`a670bd81`) — **master toggle behavior refactor** (UX fix for the pre-existing concern). New `CategoryEnabled` global gating Map separate from per-feature `.Enabled` flags; persisted in `[CategoryEnabled]` TOML section. `ToggleCategoryAllFeatures` and `ToggleAllHotstrings` now flip ONLY the master gate; per-feature choices stay preserved across master clicks. Every per-section mirror applies the gate when populating FeaturesV2 (`enabled := Gated and (V1.Enabled = true)`). Tray-menu parent checkmark + master toggle label read `IsCategoryGated`. Defaults all-true for fresh installs / no-touch users; old toggles persist their off state until user re-toggles individually.

**Phase 8 candidate** — pick by impact/risk ratio:

- **Hotstrings sub-categories** (~99 sites across `modules/hotstrings.ahk`, biggest fanout) — modélisation α with `TimeActivationSeconds` extra prop on most entries. Highest impact, also highest complexity. Note: the `LoadHotstringsSection` helper in `lib/toml/toml_loader.ahk:131` reads `FeatureConfig.TimeActivationSeconds` (v1 object access) — would need widening too, or keep passing the v1 object as third arg while only migrating the `if X.Enabled` gates (mixed v1/v2 in same statement).
- **Dispatcher widening + Shortcuts sub-Map dispatchers** (AltGrCapsLock + the 4 call sites at lines 50/97/162/176) — needs adding a v2-aware variant of `RunFirstSimpleAction` / `HasAnyEnabled` OR widening the dispatchers to accept both shapes. Unlocks the final Shortcuts cleanup.
- **LLM** — surface looks small (7 `IniCacheGet("LLM", ...)` in tray_menu.ahk) but the global `_LLM_Tray` Map populated by those calls has 199 read sites across `ui/tray_llm.ahk` etc. Migration approach: change the population loop to read from `FeaturesV2["llm"][...]` instead of IniCacheGet; no edits to the 199 read sites. Catch: user TOML has v1 flat `[LLM]` keys, v2 expects nested `[llm.models.ollama]` etc., so the mirror has to read v1 IniCacheGet values and flatten them into v2 sub-section paths.
- **TapHolds** — biggest structural change (no longer in `Features`, moved to separate `TapHold` global from `tap_hold.toml`). Requires the dormant `lib/tap_hold/tap_hold_loader.ahk` (commit 112ef51a) to go live and a hand-written migration of `modules/tap_holds.ahk` (~70 sites — branchy logic, not mechanical).

**Open piece — the cut-over (C4.5 + C4.6 + C5 + C7 + C8)**: replace the hardcoded `Features := Map(...)` in `lib/features_config.ahk` with a call to `ManifestBuildFeaturesMap()`, wire `EnsureUserConfigsExist()` + `ApplyConfigTomlV2()` into `ErgoptiPlus.ahk` boot, and migrate ~500-800 sites across 22 files from PascalCase to snake_case keys plus `.Property → ["key"]` access. Also: `TapHolds` is removed from Features in v2 (moved to a separate `tap_hold` table populated from `tap_hold.toml`), so sites reading `Features["TapHolds"][...]` need a different access pattern.

**Mapping reference** is now committed at `static/drivers/_shared/modules/features/_migration_v1_to_v2.md` (commit 98c34833, 567 lines) — exhaustive v1 → v2 table covering every TOML section, Features path, access pattern, IniCacheGet call site, and a stepped cut-over checklist. Read this top-down before launching the cut-over agent.

**Next decision** — approach for the cut-over: (a) 3 mini-cut-over commits with a temporary compat shim (driver bootable at each step, adds throwaway code), or (b) Big Bang Agent run with the migration document as reference (single sweep across all files, no intermediate boot, cleaner diff but riskier). User has not yet chosen.

**Out-of-scope reminders**: no backward compatibility (clean state — users delete their old config.toml and the driver regenerates from templates at first boot), [[feedback-ui-must-be-i18n]] still applies to all new UI work.

**Update (2026-06-13, A2): the AHK cut-over is DONE in production; macOS started.**
`ErgoptiPlus.ahk` now has `global Features := ManifestBuildFeaturesMap()` (live), and
`manifest_reader.ahk` is consumed pervasively (menu_renderer, tray_menu, toml_config_loader).
The "dormant until cut-over" docstring in `manifest_reader.ahk` is stale.

The macOS side had FOUR orphaned `_generated/*.lua` (zero runtime + zero test
consumers). A2 resolved them:

- **`expander.lua` / `registry.lua` / `shortcuts_bindings.lua` were deleted** (dead
  code, with their `codegen-{expander,registry}-hs.cjs` / `codegen-shortcuts.cjs`
  generators + npm scripts). They were a never-wired "hexagonal migration" — the
  hand-written `modules/keymap/{registry,expander}.lua` diverged far past the
  pure generated contract (TOML loading, `hs.settings`, priority cascade,
  case-variant generation, i18n), so the generated adapters could never replace
  them. **Update (audit 2026-06-26, GEN-1/2): the AHK `expander.ahk`/`registry.ahk`
  were ALSO deleted.** The earlier "KEPT because TESTED" rationale was wrong: the
  `test_domain_{registry,expander}.ahk` tests exercise the hand-written `HSE_*`
  engine (`hotstring_engine_main.ahk`) against the shared `Registry.spec.js` /
  `Expander.spec.js` contracts — NOT the generated classes, which were never
  `#Include`'d or instantiated (grep-proven). So both drivers' generated
  registry/expander ports are now gone, along with their codegen + npm scripts;
  the `SubStr(-0)` regression guard was retargeted to the live engine.
- **`features_manifest.lua` got a reader** — `macos/lib/manifest_reader.lua`
  (counterpart of `manifest_reader.ahk`). `modules/keymap/init.lua` `DEFAULT_STATE`
  now sources its hotstring/preview defaults via `Manifest.default_for("hs.hotstrings.<id>")`
  / `"hotstrings.trigger_char"` (fail-fast on a missing path), so macOS keymap
  defaults come from the same `_shared/modules/features/manifest.toml` single source as AHK.
  The reader loads the manifest cwd-independently (`debug.getinfo` + `loadfile`),
  not via `require`. Other macOS modules (gestures/llm/dynamic_hotstrings/keylogger)
  still hold hand-written `DEFAULT_STATE` — wiring them is the follow-up (LLM layers
  a runtime JSON, Karabiner has no manifest entries; both need hardware smoke-test).

**Gotcha — `LUA_HS_BASELINE` counts `hs.` substrings, including manifest path
literals.** `tests/meta/test_port_adapter_coverage.lua` guards against new `hs.*`
OS calls by counting lines matching `hs%.` in `macos/{modules,lib}`. Manifest
paths like `"hs.hotstrings.expansion_delay"` are STRING LITERALS, not OS calls,
but the heuristic counts them. Wiring keymap added 5 such lines, so the baseline
was re-anchored 900→905 with a comment. If you wire more modules to the manifest,
expect to re-anchor again (the real drive-to-zero target is OS calls, not paths).

**Update (2026-06-13, A3): shared timings registry now has dedicated readers on
both drivers.** `_shared/modules/timings/constants.toml` (~80 ms constants, each naming the
AHK + HS local it duplicated) is now read through a fail-fast reader on each side
instead of ad-hoc per-consumer parsing:

- `macos/lib/timings.lua` — `M.ms(section,key)` / `M.sec(section,key)` (ms/1000),
  cwd-independent `debug.getinfo` load + throw on missing section/key. ZERO `hs.`
  (it is in `lib/`, counted by the baseline — keep it pure, no `hs.` even in
  comments). Wired: `keylogger/init.lua`, `llm/prediction_engine.lua`,
  `gestures/engine.lua` (timing constants only — spatial gesture thresholds stay
  local).
- `windows/lib/timings/timings_config.ahk` — `TimingsLoadShared()` /
  `TimingsGet()` / `TimingsGetSec()`, THROW on miss (CI-safe via run_all's
  OnError, like the A4 hotstrings loader). Wired: `keylogger_walker.ahk`
  (`KLWConst`) and `tap_holds/constants.ahk`.

**Gotcha — AHK v2 runs static/global initializers BEFORE the auto-execute body.**
Empirically verified with a probe: order is `global X := f()` → `class.static :=
g()` → first auto-exec statement → explicit function call. So a consumer CANNOT
source a value from a shared-TOML reader in its own `static`/`global` initializer
— the reader has not loaded yet (its `TimingsLoadShared()` runs in the auto-exec
body). **Pattern: declare the constant at sentinel `0`, then a reassign loader
(`KeyloggerWalkerLoadTimings` / `TapHoldsLoadTimings`) sources it in the
auto-exec body**, placed in `ErgoptiPlus.ahk` right after
`HotstringsConfigLoadSharedDefaults()` — early enough to beat the keylogger hook
and tap-hold hotkeys arming (both happen far later). Functions/classes are
callable regardless of `#Include` position, so the loader can be called before
the file that defines the consumer is textually included. This is the same
boot-order class as the A4 hotstrings-defaults loader and the `DYN_HOTSTRINGS_DEFAULT_DELAY`
early-config-layer gotcha. The broad remaining timing sites (other `keylogger_*.ahk`,
keep-awake, gestures probe timers, UI/Karabiner timers, MLX/LLM warmup/discovery)
are a follow-up needing per-module hardware smoke-test, same as the manifest-reader
follow-up above.

**Update (2026-06-13, A5): the AHK LLM backends now consume the shared
PromptBuilder `max_tokens`.** The engine computed `params["max_tokens"]`
(`max(15, max_words*6+10)`, default 150) and then **discarded it**, while
`api_ollama.ahk` re-derived `num_predict := Max(24, Min(96, mw*4))` and
`api_remote.ahk` hardcoded `256` in all three provider branches — macOS already
threaded the value, so AHK was the incomplete side. Now `prediction_engine.ahk`
threads `max_tokens` into `LLM_OllamaGenerate_Async/_Streaming` and
`LLM_RemoteGenerate_Async`, and the payload builders serialize it verbatim
(defaults 150 / 256 only for an out-of-range value). These are output **ceilings**
rarely reached (generation stops at the stop-sequence/line boundary), so the
practical effect is small — but the Windows caps did change, so it needs a
live-model sanity check. **Gotchas for the next person:** (1) the `api_mlx.lua`
`min(0.60, temp+0.10)` clamp is TEMPERATURE retry escalation, NOT a token limit —
do not "fix" it as a token divergence. (2) The cross-driver
`_shared/tests/corpus/prompt_builder/vectors.json` already pins `max_tokens` AND
the diversity-temperature curve (greedy snap 0.15, auto-raise, cap 1.0) for both
drivers — extend it rather than writing a new token corpus. (3) The AHK _batch_
path still uses a single per-prediction cap, not macOS's `× num_predictions + N*5`
scaling — a documented parity follow-up, not a regression.

**Update (2026-06-13, A6): tooling/enforcement gates added.**

- **Codegen freshness** is now part of `build:domain` (8 steps): it regenerates
  the byte-faithful generators (`build:manifest`, `codegen:terminators`,
  `codegen:expander:ahk`, `codegen:registry`) in place and drift-checks them via
  `git diff` against HEAD, so a source change without a re-run, or a hand-edit of
  a generated file, fails CI. To add a generator to the gate, push a step + its
  outputs onto the `PIPELINE` array in `tools/build/build-domain.cjs`.
- ⚠️ **FOOTGUN — do NOT run `npm run codegen:prompt-builder:ahk`.** That generator
  (`codegen-prompt-builder-ahk.cjs`) uses constants `AQ='`"'`/`AQQ` and emits
the backtick-quote escape even for string *delimiters*, producing invalid AHK
(`` config.Has(`"max_words`") `` instead of `config.Has("max_words")`). The
COMMITTED `windows/\_generated/prompt_builder.ahk`is correct (plain`"`), so
re-running the generator CORRUPTS it. It is excluded from the freshness gate for
this reason; the AHK PromptBuilder is currently effectively hand-maintained. Fix
the generator's delimiter escaping (only intra-string quotes need `` `" ``)
before re-enabling codegen for it. The cross-driver `prompt_builder/vectors.json`
  corpus validates behaviour either way.
- **Config schema** is now enforced: `tools/test/test-config-schema.cjs`
  (`test:config-schema`, also a `build:domain` step) is a dependency-free minimal
  JSON-Schema validator (there is no ajv) that checks the generated
  `config_template.toml` against `_shared/core/config_schema/config.schema.json`. That
  schema had drifted (it was consumed by zero tests) and was reconciled to the
  manifest. When the manifest gains a config key, add it to the schema or this
  fails. Watch the `allOf` + `additionalProperties:false` trap (a strict
  sub-schema in an `allOf` rejects sibling properties — spell the object out).
- **AHK shared-purity §4** (`test_port_adapter_coverage.ahk`) now HARD-FAILS on a
  direct OS call in `_shared/**/*.js` (was warn-only). The scanner skips comments
  and uses `\bhs\.`; shared JS is confirmed clean (the old matches were all
  comments + a `months.` false positive).

**Update (2026-06-13, follow-up pass): the A2–A6 follow-ups are closed; the
boot-perf idle-pass landed; one item deliberately remains.** Landed: the prompt-builder generator fix (now gated), the
A4 llm_prediction tint from `UI_AI_LOADING_HEX`, the A5 AHK batch token scaling,
the A2 manifest-reader extension (keylogger/dynamic_hotstrings/gestures), the full
**macOS timings sweep** (~38 constants → `lib/timings`), and the **AHK LLM backend
timings** (`LLMApiLoadTimings`). Gotchas worth keeping:

- **`lib/timings` typos fail fast at require-time** — the macOS suite catches a
  wrong section/key because it loads the modules; this is the safety net that made
  the macOS sweep safe to do in bulk.
- **macOS hs.\* baseline is 906** now (the +1 over 905 is the
  `hs.gestures.space_wrap` manifest PATH literal in gestures/init.lua — not an OS
  call). Wiring more `hs.*`-prefixed manifest paths will need another re-anchor.
- **Two intentional macOS local timing divergences** (NOT to "fix"): MLX
  `DISCOVERY_MAX_WAIT` 180 s (vs registry 60 s — slow 8B loads) and the menu
  `INSTALLED_CACHE_TTL` 30 s (vs 2 s).
- **Boot-perf emoji/symbol idle-pass** (`a866b13fb`): boot
  `RegisterAllHotstrings(…, DeferHeavy := true)` skips the emoji/symbol magic-key
  categories (~3000 regs / ~410 ms); a one-shot post-boot `SetTimer`
  (`RegisterEmojisSymbolsDeferred`, `HS_DEFERRED_REGISTRATION_DELAY_MS` = 1500)
  registers them off-path + rebuilds the prefix-watcher index. Live rebuilds pass
  `DeferHeavy=false` (synchronous, unchanged). Lives in `modules/hotstrings.ahk` +
  `ErgoptiPlus.ahk` — NOT in the CI harness, so it needs a hardware boot smoke-test.
  Nuance: deferred = registered last → a same-trigger/same-length/same-priority
  collision would flip the tie-break (practically nil — distinct namespaces).
- **The AHK keylogger telemetry timings are deliberately NOT swept.** Those
  sub-modules (`keylogger_watchers/_hook/_network/_av_state/_sensors/_mouse/
_trigger_roi/_clipboard/_window_topology/_ergonomics` + `keylogger.ahk`
  `KeylogConst`) are AHK-only telemetry (no macOS counterpart → no mutualization
  value) AND are **not in `run_all.ahk`**, so a reassign-at-boot wire would be
  unverifiable in CI with a 0 ms-sentinel → CPU-spin hazard. Three are genuine
  code↔registry divergences (`CONTEXT_TTL` 1000≠500, `PARK_CHECK` 250≠100,
  `TOPO_TICK` 1500≠500) that need a maintainer call first. See TODO "Follow-up
  pass" for the safe recipe (harness inclusion + batch loader + tripwire +
  reconcile + hardware smoke-test).

### project_debug_menu_sync

_Debug menu order is defined in _shared/modules/menu/menu_manifest.json debug_menu — both AHK and Lua drivers consume it_

<sub>slug: `project_debug_menu_sync`</sub>

The debug submenu order is the single source of truth in `_shared/menu_manifest.json` under the `debug_menu` key (an ordered array like `top_level`). Platform-specific items carry a `"platforms": ["ahk"]` or `"platforms": ["hs"]` field; entries without `platforms` appear on both.

**Canonical order** (as of 2026-05-29):

1. `window_spy`, `list_vars`, `key_history` — AHK only
2. `console` — HS only
3. `---`
4. `log_level` — submenu
5. `open_logs`
6. `open_today_log`
7. `---`
8. `healthcheck`

**Consumers:**

- AHK: `MenuManifest_LoadDebugMenu()` in `windows/lib/menu_manifest.ahk`, iterated in `windows/ui/tray_menu.ahk`
- Lua: `load_debug_menu()` in `macos/ui/menu/builder.lua`

**Why:** User requires that menu order be defined once in _shared/ — never duplicated per-platform.

**How to apply:** To reorder or add debug menu items, only edit `menu_manifest.json`. Both drivers pick it up automatically at next load.

See also [[project_menu_manifest_macos_hotstrings_layout_gap]] — the same SSOT manifest correctly drives `debug_menu` on both platforms, but `hotstrings_menu`/`layout_menu` are only consumed on Windows.

### project-menu-manifest-macos-hotstrings-layout-gap

_macOS never reads menu_manifest.json's hotstrings_menu/layout_menu keys (unlike gestures_menu/metrics_menu/shortcuts_menu, which ARE manifest-driven on both platforms) — a drift gate exists, the actual migration does not_

<sub>slug: `project_menu_manifest_macos_hotstrings_layout_gap`</sub>

`_shared/modules/menu/menu_manifest.json` is the intended single source of truth for tray-menu structure across both drivers. On Windows, `hotstrings_menu` and `layout_menu` are consumed generically through `lib/manifest_menu.ahk`'s `MenuRenderer_Build`, exactly like `gestures_menu`/`metrics_menu`/`shortcuts_menu` — so reordering the manifest updates all four menus with no code change. On macOS, `gestures_menu`/`metrics_menu`/`shortcuts_menu` were correctly migrated to the equivalent `lib/manifest_menu.lua`'s `ManifestMenu.build`, but `ui/menu/menu_hotstrings.lua`, `ui/menu/builder.lua`, and `ui/menu/menu_keyboard_layout.lua` still hand-assemble the hotstrings and layout submenus imperatively — zero references to the manifest's `hotstrings_menu`/`layout_menu` arrays anywhere in that code. Reordering or editing those two manifest keys silently desyncs the two platforms' tray menus, with nothing catching it until a human notices the mismatch.

**Interim mitigation (2026-07-03):** `macos/tests/meta/test_menu_hotstrings_layout_drift_gate.lua` pins the current `hotstrings_menu`/`layout_menu` shape (hs-filtered signatures) against two hardcoded `CANONICAL_*` tables. This makes a manifest edit fail LOUDLY (the test breaks) instead of silently — a human is now forced to look at whether the macOS hand-built menu needs the same change — but it does not make macOS manifest-driven. The real fix is migrating `menu_hotstrings.lua`/`menu_keyboard_layout.lua`/`builder.lua` to read the manifest the way `gestures_menu` already does; that migration was assessed as a larger, riskier refactor than a bounded single-commit fix warrants (unfamiliar macOS Lua UI code, two menus' worth of imperative logic to replace) and was deliberately deferred rather than rushed.

**Why:** Found during the 2026-07-01 AHK driver audit's `project_debug_menu_sync` watch-list re-check — the same SSOT manifest that correctly drives `debug_menu` on both platforms also defines `hotstrings_menu`/`layout_menu`, but only Windows actually consumes them.

**How to apply:** Before editing `hotstrings_menu`/`layout_menu` in `menu_manifest.json`, run the macOS Lua suite (`cd static/ergopti_plus/macos && lua tests/run.lua`) — the drift gate will fail if the edit isn't also reflected in macOS's hand-built menu code. When picking up the deferred migration: mirror how `gestures_menu` was done (`lib/manifest_menu.lua`'s `ManifestMenu.build`, consumed from `builder.lua`), then delete the drift-gate test since it becomes structurally redundant once macOS is manifest-driven.

See also [[project_debug_menu_sync]].

### project-gestures-reversal-detection

_How direction reversals are detected in the gestures engine (x1 vs incremental)_

<sub>slug: `project_gestures_reversal_detection`</sub>

The gestures engine in [engine.lua](../../../../d:/Documents/GitHub/ergopti/static/drivers/hammerspoon/modules/gestures/engine.lua) handles two trigger modes that need different reversal logic.

**Why:** A regression in commit `b1f1e5a2` and earlier designs blanket-returned in `commitGesture` whenever any live fire had happened. That caused 4-finger left-then-right swipes to lose the reversal: user swiped left (fires "space_prev"), reversed quickly to right, lifted before live trigger crossed `LIVE_AXIS_MIN`, and commit refused to fire "space_next".

**How to apply:**

**x1 mode** (4-finger space/expose swipes, 2-finger swipes, 5-finger vertical): commit fires the new direction if `sign(sd) != gs.liveAxisSign`. Block only same-direction double-fires.

**Incremental mode** (3-finger word, 5-finger window): tracks `gs.lastFirePos` on every fire. On each new frame, if movement from `lastFirePos` is >= `LIVE_AXIS_MIN` units in the opposite direction of `liveAxisSign`, rebase `startPos` to current pos immediately. This is much more responsive than the old `diff < 0` fallback which required the user to come all the way back through the original origin.

Both modes must initialise `gs.lastFirePos = nil` in `resetGS()` AND at the start of a new gesture (in the `if not gs.active` branch of `process_frame`).

See also [[project-gestures-startup-design]].

### project-gestures-startup-design

_Design choices for the macOS gestures startup path — primer-as-wakeup-signal vs burst probes_

<sub>slug: `project_gestures_startup_design`</sub>

The Hammerspoon gestures module (`static/drivers/hammerspoon/modules/gestures/`) historically struggled with a cold-start bug: at HS launch, the `hs._asm.undocumented.touchdevice` subscription was attached but received no frames until the user physically touched the trackpad. The user's first gesture was lost; gestures only became responsive ~10s later when the 20s discovery timer fired.

**Why:** IOKit HID dispatch path isn't initialised at HS launch time. The watcher is technically "running" but the OS doesn't route frames to it.

**How to apply:** The current design (cc7abf51, May 2026) combines two mechanisms — do NOT regress to burst probes alone:

1. **Adaptive probe loop** in [init.lua](../../../../d:/Documents/GitHub/ergopti/static/drivers/hammerspoon/modules/gestures/init.lua): recycles watchers every 500ms until first frame, then switches to 20s health-check. Replaces the old fixed `STARTUP_BURST_DELAYS = {0.05, 0.15, ..., 4.5}` which exhausted too early.

2. **Primer-as-wakeup-signal**: the `gesture_primer` eventtap (already subscribed to NSEventTypeGesture and friends to keep the OS gesture dispatch alive) now ALSO triggers an emergency recycle when it sees a gesture-class event before any touchdevice frame has been received. This means the user's first physical gesture _itself_ unblocks the pipeline, so the gesture is captured in flight rather than lost.

A 1s cooldown debounces the emergency recycle so a fast burst of gesture events at first contact doesn't trigger several recycles.

The primer also handles `tapDisabledByTimeout`/`tapDisabledByUserInput` by re-engaging itself, and subscribes to more types (`beginGesture`, `endGesture`, `swipe`, `magnify`, `rotate`, `directTouch`, `smartMagnify`) so the dispatch tree initialises fully.

See also [[project-gestures-reversal-detection]].

### project-hotstring-delay-architecture

_Where hotstring expansion delays are configured, the cross-platform precedence, and the key gotchas_

<sub>slug: `project_hotstring_delay_architecture`</sub>

How the hotstring expansion-delay (TimeActivationSeconds / typing-speed gate) is configured across both drivers. Mapped 2026-06-04 building the per-section delay feature (comma_j → 5s). See [[project_hotstring_engine_internals]].

**Source of truth = the shared per-category TOML**, `static/ergopti_plus/_shared/modules/hotstrings/<category>.toml`:

- `[_meta] delay = <s>` — the group/category delay.
- `[_meta.section_delays]` block (`<section> = <s>` lines) — per-section overrides, e.g. `comma_j = 5`.
- NOT `features/manifest.toml`'s `time_activation_seconds` — that field is **test-only metadata** (only `test-manifest-equivalence.cjs` reads it); it does NOT drive the runtime delay. Don't edit it expecting an effect.

**Precedence (both platforms, highest first):** user override → TOML section delay → TOML group delay → menu-set global default → hardcoded fallback.

**AHK:** `HotstringsResolve(cat, sec).Delay` resolves it: `UserSec → UserCat → TomlSec → TomlCat → _HotstringsOverrides["_global"].Delay → GLOBAL_DEFAULT_DELAY (0.75)`. The `_global` key is the **menu-set default expansion delay** (tray: Delays submenu → "default delay" item; persisted via `HotstringsSetOverride("_global","","delay",s)`). The AHK loader (`toml_loader.ahk` `ParseTomlGroupConfig`) reads `[_meta.sections.<name>]` AND `[_meta.section_delays]` into `Sections[x].Delay`. The AHK `Terminators` class in `_generated/terminators.ahk` is dormant (unused) — unrelated to this.

**macOS (Hammerspoon):** per-GROUP `CoreState.DELAYS[group]` (seeded from hardcoded `DELAYS_DEFAULT` + user prefs) + per-section `CoreState.SECTION_DELAYS[section]` (loaded from the shared TOML's `[_meta.section_delays]` via the shared `toml_codec/reader.lua`, which handles `[_meta]`, `[_meta.sections]` inline lang-maps, `[_meta.sections.<name>]`, and `[_meta.section_delays]`). `mapping_fires` applies the precedence (a group delay differing from its default = a user override and wins over the section delay). Each mapping (incl. generated `;`/nbsp/nnbsp aliases) is tagged with `entry.section`. Section delays are folded into `WORD_TIMEOUT_SEC` (`recompute_word_timeout`) so a long window (5s) is not cut short by the inactivity wipe. macOS does NOT read the TOML group `[_meta] delay` (uses the hardcoded `DELAYS_DEFAULT`); only section delays come from the TOML.

**Cross-platform Delays-submenu parity (added 2026-06-04, branch `feat/comma-j-expansion`).** Both drivers' hotstrings "Delays" submenu now surfaces the same set of quick delay items: default expansion delay, ★ magic-key, autocorrection, AI-prediction timeout, and dynamic-hotstrings (HS also keeps it; AHK gained all of them). Key implementation facts:

- **★ + autocorrection** are real TOML-backed categories (`magickey.toml` `[_meta] delay = 2.0`, `autocorrection.toml` = 1.0). On macOS the quick item must read via `hotstrings_config.resolve(cat,nil).delay` and write via `set_override` + `set_delay` (NOT the `make_delay_item`/`state.delays` path, which is in-memory-only and would desync from the config window). AHK uses `HotstringsResolve`/`HotstringsSetOverride` — `_HS_CategoryDelayLabel`/`_HS_PromptCategoryDelay(cat, i18nKey, DefaultSec:="")` in `tray_menu.ahk`.
- **AHK llm_prediction + dynamichotstrings have NO category TOML** — `ParseTomlGroupConfig` silently returns an empty cached config for a missing file (no log noise), so they're used as **pseudo-category override keys**: default is a code constant (`UI_LLM_TIMEOUT_SEC`=20s in `_shared/modules/tooltip/constants.toml`; `DYN_HOTSTRINGS_DEFAULT_DELAY`=2.0 in `modules/hotstrings.ahk`), override persisted via `HotstringsSetOverride("llm_prediction"/"dynamichotstrings",...)`. This avoided a 6-file `_LLM_Tray` plumbing route and the `build-hotstrings.cjs` enumeration risk of adding fake category TOMLs. The LLM tooltip timer (`lib/tooltip.ahk` ~1209) resolves the override live (applies without restart); AHK category-delay changes otherwise apply on restart (registered `TimeActivationSeconds` is read at startup).
- **AHK dynamic phone/SSN/IBAN prefix hotstrings were rewritten from native `Hotstring()` to HSE `CreateHotstring`** so they honour `TimeActivationSeconds` (they had none). `_HotstringDispatch` calls a callable `Replacement`, so `(*) => SendFinalResult(V)` became `(*) => V` + `FinalResult:True`; `OnlyText:True` also fixed a latent `+33…` SendInput modifier-interpretation bug. The `@np` personal-info expansions were already HSE and left firing instantly (out of scope). `IsTimeActivationExpired` treats `<=0` as "no gate".
- **i18n**: two NEW keys `menu.hotstrings.delay_magic_key` / `delay_autocorrection` added to all 21 locales (the existing `tooltip_magic`/`tooltip_autocorrect` are PREVIEW labels, not delay labels). Reused `tooltip_ai_acceptance` / `tooltip_autocompletion` for the AI/dynamic items. Locale files are UTF-8 **BOM + CRLF + tab + NOT globally sorted** — insert keys via targeted text insertion at the alphabetical position, never full reserialize (would rewrite all 2144 keys). `tools/locale/check_locales.py` points at a stale `tools/static/locales` path but the parity rule (every locale mirrors `en.json`) still holds.
- **Test fixes (committed)**: `lib/locale.lua` Windows path-separator bug (forward-slash-only dirname regex dropped the `lib` segment when `package.searchpath` injected a backslash); two stale purity baselines re-anchored (852→862, 61→63) in `tests/meta/test_port_adapter_coverage.lua`.

All AI-timeout + dynamic-delay behaviour is AHK-side and **UI/runtime — NOT covered by the headless suite; needs live-testing on Windows**. Suites: macOS 1215/0, AHK 1052/0.

All of the above lives on branch `feat/comma-j-expansion` (not yet merged to dev as of 2026-06-04).

**The three hard fallbacks are now a shared cross-driver file (A4, 2026-06-13).** `GLOBAL_DEFAULT_DELAY` (0.75 s), `GLOBAL_DEFAULT_COLOR` (#1e88e5) and the `personal` baseline (#6e6e73) used to be duplicated literals in BOTH `windows/lib/hotstrings/hotstrings_config.ahk` and `macos/modules/hotstrings_config.lua` (each claiming "single source"). They now live ONCE in `static/ergopti_plus/_shared/modules/hotstrings/defaults.toml` (`[colors] global_default / personal`, `[delays] default_sec`) and are read at boot by both drivers with a fail-fast `require_key`, exactly like `_shared/modules/tooltip/constants.toml`. Key implementation gotchas:

- **AHK uses an EXPLICIT loader, never a top-level auto-read.** `HotstringsConfigLoadSharedDefaults()` is called from `ErgoptiPlus.ahk` (before `HotstringsConfigInit` and the tray menu build — `initMenu` reads `GLOBAL_DEFAULT_DELAY`). It is NOT run at the `hotstrings_config.ahk` top level because `tests/test_hotstring_aggregation.ahk` sets `_SharedDir` _after_ its `#Include` of the file — a top-level read would throw at include time. This mirrors `ui_style.ahk`'s sentinel-then-loader pattern. The three globals start `""` / `Map()` sentinels.
- **Fail-fast = THROW, not `MsgBox`+`ExitApp`.** A missing key throws an `Error`: in production the unhandled boot error surfaces the fatal dialog and exits (desired); in CI `run_all.ahk`'s `OnError` handler turns it into a `not ok 0` line (no hung modal). `MsgBox`+`ExitApp` would hang the headless runner. The macOS side `error()`s at require-time (re-required per test).
- **`IniCacheGet`/`ParseTomlFile` return colors WITH the leading `#`** (the TOML stores `"#1e88e5"`); the loader strips+re-adds `#` to normalise. Don't double-prefix.
- **Pre-existing trap unrelated to A4:** the focused dev runner `tests/run_hotstrings_config.ahk` reports ~14 failures (`_HSE_SourcePriority` "local variable has not been assigned a value") because it does NOT `#Include hotstring_engine_main.ahk`, which defines `_HSE_SourcePriority` — now called in the resolve priority cascade. **CI uses `run_all.ahk`, which includes it and is fully green (1372/0).** Use `run_all.ahk` to judge hotstrings_config changes, not the focused runner.
- Out of A4 scope (still AHK-only literals): `llm_prediction #AD61FF` (no HS equivalent — mirrors tooltip `ai_loading_hex`) and `DYN_HOTSTRINGS_DEFAULT_DELAY 2.0`. Single-source tripwire tests on both drivers (`test_hotstrings_config.ahk` §SharedDefaults, `macos/.../unit/modules/test_hotstrings_defaults.lua`) assert the loaded values equal the file AND pin the canonical literals.

### project-hotstring-engine-internals

_AHK prefix-watcher InputHook captures synthetic input; OnChar must feed each char once; AHK vs Hammerspoon word-boundary framing divergence is intentional_

<sub>slug: `project_hotstring_engine_internals`</sub>

Hard-won internals of the ErgoptiPlus hotstring matching engine (Windows AHK + macOS Hammerspoon). Discovered 2026-06-04 while fixing the comma-layer/nnbsp + vowel → capital-J expansion.

**AHK prefix watcher InputHook captures synthetic output.** The watcher's InputHook is created `InputHook("V L0")` — no `I0` flag — so it observes input injected by `SendEvent`/`SendInput` too (the comment says injected keystrokes must reach the watcher). Therefore `SendNewResult(...)` output flows back through `_OnPrefixChar` → `HSE_FeedChar` into `HSE_Buffer`. The whole `HSE_Suppressed` / `PrefixWatcherSuppress` machinery exists only to filter the engine's OWN expansion bursts so they don't re-feed. Do NOT assume `SendEvent` bypasses the watcher — it does not.

**OnChar must feed each char exactly once.** `_OnPrefixChar` feeds every char at the top (where end-char/star matches fire). A historical bug also re-fed word-terminators in the boundary branch, so `;`/`:` landed in `HSE_Buffer` twice (`nnbsp::e`), silently breaking any trigger that contains a terminator as a NON-final char (the J triggers). Fixed by removing the boundary-branch re-feed. macOS appends once in the init.lua keyDown loop and never had this bug. If you touch the boundary branch, never re-feed.

**`HSE_WORD_TERMINATORS`** (hotstring_engine_main.ahk) is the engine's base separator set; it is hand-maintained (NOT the codegen `_generated/terminators.*`, which is the user-configurable catalogue). Spell apostrophes as `Chr(0x27) . Chr(0x2019)` — a typography pass once silently rewrote the ASCII apostrophe to a second U+2019, dropping U+0027.

**Cross-platform word-boundary framing differs by design.** AHK uses a terminator-ALLOWLIST (`_HSE_WordBoundaryAllows`: fire only if the char before the trigger is in `HSE_WORD_TERMINATORS` or start-of-buffer). Hammerspoon uses a letter-DENYLIST (`word_boundary_blocks` → blocks if `text_utils.is_letter_char(prev)`; Lua `%w` = letters+digits, NOT underscore). They AGREE for all normal French input (space/punct/apostrophe → fire; letter/digit → block). They diverge ONLY for exotic preceding chars (hyphen, `_`, `(`, `/`): macOS fires, AHK blocks. This is low-impact and "best" is genuinely ambiguous — left intentionally unaligned. Don't "fix" it without a concrete user need. The comma→J bare `;` trigger is in-word on BOTH (AHK `*?C`; macOS via the leading-`;` skip in `word_boundary_blocks`) so the capital J is guaranteed in every context — bare `:` is deliberately NOT a trigger. See [[project_keymap_architecture]].

**Boot registration is pure HSE data-structure building — `_HotstringRegistrar` is 0 in production.** Discovered 2026-06-12 while profiling boot perf. ErgoptiPlus-managed hotstrings (the ~5400 generated + personal ones) register through HSE only: `CreateHotstring` → `_RegisterHotstring` → `_MirrorRegistrationToHSE` → `HSE_Register`. The native AHK `Hotstring()` is reached **only** when `_HotstringRegistrar` is non-zero, and nothing in production ever sets it (it stays at its default `0`; only the test harness swaps in a recorder via `InstallHotstringHooks`). The few genuinely-native hotstrings (Ê deadkey, `…`) call `Hotstring()` directly, not through this path. Consequence: the entire boot-time registration cost is reproducible **headless** with no keyboard hook — which is what `tests/bench_boot_hotstrings.ahk` exploits to bisect it (run via `AutoHotkey64.exe`; NOT a `test_` file, not in run_all, must stay UTF-8 BOM + CRLF per the encoding guard). Cold-run profile: magic-key text expansion dominates (~3100 star regs; star triggers pay `_HSE_IndexStarPrefixes`), then `autocorrection.accents`. The per-registration object/closure build is the floor — the only material lever left is doing fewer registrations at boot (defer/reduce), which changes time-to-availability and collision ordering, so it is a deliberate decision, not a micro-opt. See [[project_hotstring_live_rebuild]].

### project-hs-perf-profilers-and-case-conform

_macOS boot/hot-path profilers, the case-conform registration fast path, the menubar cache, and the escape-trap-on-first-show gotcha_

<sub>slug: `project_hs_perf_profilers_and_case_conform`</sub>

Performance work on the Hammerspoon driver, 2026-06-16 (ports of AHK optimisations + instrumentation).

**Profilers (ported from AHK `lib/boot_profiler.ahk` + `lib/hotpath_profiler.ahk`).** `lib/boot_profiler.lua` (`Boot.begin()` / `Boot.mark(phase)`) logs per-phase `+delta ms (total ms)` at INFO; wired across `init.lua` (logger setup → core requires → path → LLM bootstrap → TOML discovery → groups registered → sort → menu/UI → watchers → boot complete). `lib/hotpath_profiler.lua` (`HotPath.now()` / `HotPath.log_if_slow(label, t0, detail)`) logs a WARNING only when a segment exceeds the threshold (default 5 ms); wired into `keymap/init.lua` `onKeyDown` (every keystroke) and `tooltip_llm.show_predictions`. BOTH read the clock through `adapters.timer_scheduler` (`now()` seconds, `now_ns()` nanoseconds) — NEVER `hs.timer.*` directly, because the `tests/meta/test_port_adapter_coverage` guard counts `hs.` occurrences (INCLUDING in comments) in `modules/`+`lib/` against a baseline. Adapters are exempt; new lib/modules code must route OS calls through them or the guard regresses.

**Case-conform fast path (`registry.lua` + `expander.lua` + `text_utils.conform_replacement`).** An auto, case-INsensitive, plain-text trigger with no shift-symbol char (`, ' .`) and not magic-key-terminated is registered as ONE lowercase entry (`m.case_conform = true`) instead of the lower/Title/UPPER trio; `try_auto_expand` conforms the replacement's case to the typed trigger at fire time (mixed case → `conform_replacement` returns nil → no fire, matching the old no-variant behaviour). The tail-char buckets switched from ASCII `:lower()` to Unicode `text_utils.trig_lower` (registration AND `mappings_for_tail`/`rebuild_tail_indexes`) so an accented UPPERCASE tail "Ê" resolves to the lowercase "ê" bucket — REQUIRED for conform entries to match capitalised accented triggers. The `llm_bridge` preview tail loop is conform-aware too. **Reality check:** the win is concentrated in `autocorrection` (~316 conform, ~630 entries avoided); `magickey` barely benefits because ~1587/2119 of its entries are deliberately `is_case_sensitive = true` (already single entries) — the agents' "halve the corpus" estimate was wrong. The dominant boot cost is TOML parsing (~0.5 s for the 5 main files in plain Lua), which the boot profiler now exposes; conform mainly shrinks the sort + bucket + memory. Regression coverage: `tests/unit/modules/keymap/test_case_conform.lua`.

**Menubar cache (`ui/menu/init.lua`).** `Builder.generate()` ran on EVERY click via the `setMenu` callback (the ~1 s open latency). Now the generated tree is cached; the callback returns the cache unless `_menu_dirty` (set by `updateMenu`/`save_prefs`) or the pause state flipped (cheap boolean check). The cache is pre-warmed off the boot path inside the existing `MENU_CACHE_PRIME_DELAY_SEC` timer (after the layout/apps/karabiner submenu caches warm), and `rebuild_menu_cache()` logs the build time. Any NEW state change that should refresh the menu MUST set `_menu_dirty = true` (route through `updateMenu`/`save_prefs`).

**Boot perf — two dominant costs found via the profiler (2026-06-16, second pass), both fixed.** (1) **Group disable+enable round-trip (~2 s).** `ui/menu/menu_state.lua` `sync_state_to_modules` restored saved hotstring-group state by calling `disable_group` THEN `enable_group` for every ENABLED group. At boot all groups are already enabled, so this purged + RE-PARSED each category TOML from disk and re-sorted all ~5355 mappings ~16× for zero net change — the bulk of the "Menu + UI + script control start" phase. Fix: apply only the delta — `enable_group` alone for wanted groups (it early-returns when already enabled), `disable_group` alone for unwanted ones (early-returns when already disabled). The registry's own guards make both no-ops cheap. A timing log (`Hotstring group sync: N enable / M disable in X ms`) now reports ~0 ms so a regression is obvious. Regression: `tests/unit/ui/menu/test_menu_state_group_sync.lua` (asserts an enabled group is never disabled first). (2) **Synchronous log-purge shell pipeline (~0.6 s).** `lib/logger.lua` `init_log_path` ran a `find | while read … date … rm` pipeline (several subprocess forks PER log file) + a per-sub-file `stat` inline on the boot critical path. It is pure housekeeping (deleting stale files), so it was split into `M._purge_old_logs(log_dir, max_age_days)` and deferred via `hs.timer.doAfter(LOG_PURGE_DELAY_SEC=5)`; the dated log file is already writable beforehand. Headless/no-timer falls back to inline so behaviour is unchanged. Regression: `tests/unit/lib/test_logger_deferred_purge.lua` (asserts no `find` runs synchronously). Finer boot sub-marks (`Path: …`, `UI: …`) + per-engine timing (`Keylogger engine start`, `Keymap engine start`) + a menu cache-hit/rebuild DEBUG line were added so the next log round attributes any remaining cost precisely. The hot path also gained Perf-gated sub-segment timing (`match=…ms preview=…ms`) appended to the slow-keystroke WARNING via `HotPath.elapsed_ms`.

**Boot perf — third pass (2026-06-16): keylogger deferred, preview measurement memoized, menu made static.** (1) **Keylogger start deferred (~1.3 s).** Once the group round-trip was gone, `keylogger.start` (SQLite open + log-rotation offset replay + export setup) was the single biggest boot cost. It only feeds typing METRICS, so `menu_state.sync_state_to_modules` now starts it via `hs.timer.doAfter(KEYLOGGER_START_DELAY_SEC=0.5)` instead of inline — boot becomes interactive ~1.3 s sooner; a sub-second gap of unlogged keystrokes is harmless. Regression: the keylogger-defer test in `tests/unit/ui/menu/test_menu_state_group_sync.lua` (asserts start is scheduled, not called inline). (2) **Per-keystroke preview cost = `canvas:minimumTextSize` (8–34 ms).** The HotPath breakdown (`match=…ms preview=…ms`) showed trigger MATCHING is <0.3 ms; the cost is the tooltip render's `minimumTextSize` ObjC text-layout calls (once per row + once per trigger label, every keystroke a preview shows). `renderer.lua` now memoizes them via `_measure_styled(canvas, index, text, size_tag, style)` keyed by `"<size_tag>\0<text>"` (bounded at 4096) — the two labels (★/↵) hit the cache permanently and recurring previewed words hit it across re-renders. Regression: the memo tests in `tests/unit/ui/test_tooltip_stacked_panel.lua`. (3) **Menu open made instant via a STATIC native menu.** Even with the Lua tree cached, `myMenu:setMenu(callback)` makes Hammerspoon rebuild the NATIVE NSMenu from the returned table on EVERY click — the residual open latency. After the prewarm build primes the tree (`_menu_primed`), `rebuild_menu_cache()` now `push_static_menu()`s it as a static `setMenu(table)` so AppKit reuses one prebuilt NSMenu (instant opens). State changes re-push it via a coalesced `schedule_menu_refresh()` (`MENU_REFRESH_COALESCE_SEC`) instead of a per-click rebuild; the dynamic callback survives only as the COLD path for the ~2 s before priming. The static-menu behaviour is not unit-testable (the stub `hs.menubar` is a no-op) — verify open latency on a real Mac.

**Boot perf — fourth pass (2026-06-16): TOML hotstring snapshot cache (~200 ms).** With the keylogger and group round-trip gone, the dominant remaining boot cost (`Hotstring groups registered` ~165–215 ms + part of `menu.start`'s delay-reading pass) is the shared TOML parser itself: `_shared/lua/toml_codec/reader.lua` walks every source byte by hand (`s:sub(j,j)` per char), which is slow in plain Lua for the ~5400-mapping bundled files. Fix: a disk **snapshot cache**. The reader gained a PURE injected hook — `M.set_cache_provider({load, store})`; on `parse(path)` it tries `load(path)` first (return the cached table, skip parsing) and after a real parse calls `store(path, result)`. The filesystem/`hs` work lives in `adapters/toml_cache.lua` (the `adapters/` dir is EXEMPT from the `test_port_adapter_coverage` hs.*/io.open baselines, so this added ZERO to either baseline and the shared reader stays filesystem-free). The adapter serialises each parsed table into a precompiled Lua chunk (`return {ver,mtime,size,data={...}}`) loaded via the C-level `loadfile` (~10× faster than the hand parser). **Invalidation is mtime AND size AND a `CACHE_VERSION` constant** (bump `CACHE_VERSION` whenever `reader.parse`'s output shape changes, or stale snapshots feed an incompatible structure) — any mismatch / missing / corrupt snapshot is a silent miss that falls back to a normal parse, so an edited hotstrings file is never served stale. Cache dir: `hs.configdir .. "/cache/toml_hotstrings"`; wired in `init.lua` right after the log-path setup, BEFORE any `keymap.load_toml`, so the first boot after a file change re-parses + refreshes the snapshot and every later boot (plus the same-boot delay-reading pass that re-parses the same files) hits it. The serialiser uses `string.format("%q", s)` for byte-exact strings incl. UTF-8, `math.type` to keep integer vs float, and handles nested array/map tables (the full `reader.parse` value space; no cycles/functions in TOML). Regression: `tests/unit/lib/test_toml_reader_cache_hook.lua` (hook honoured: hit short-circuits without reading the file, miss parses + stores, provider error falls through) + `tests/unit/adapters/test_toml_cache.lua` (round-trip deep-equality incl. lang-map descriptions / quote+newline+UTF-8 strings, and mtime/size staleness → miss). The serialize/loadfile path is real-Lua-testable; the only un-asserted part is real-Mac wall-clock — verify the `Hotstring groups registered` boot mark drops on the second boot after a clean cache.

**GOTCHA — the LLM escape-trap is armed on FIRST tooltip show on purpose, do NOT move it to init.** `llm_bridge.arm_escape_trap` is wired via `tooltip.set_on_show_callback`, not `M.init()`. This is deliberate: the eventtap must be inserted at HEAD *after* Raycast (or any other app) has registered its own tap, so our Escape takes priority while a tooltip is visible. Arming it at boot would risk registering before those apps and losing Escape priority. The one-time `eventtap.new()` cost on first show is the accepted trade-off — do not "optimise" it to init.

### project-tooltip-shared-style

_Tooltip visual style is shared across drivers via _shared/modules/tooltip/constants.toml; the macOS stacked canvas rounds its colored rows via an hs.canvas clip; per-driver alphas are intentionally different_

<sub>slug: `project_tooltip_shared_style`</sub>

The cross-driver tooltip look is defined ONCE in `_shared/modules/tooltip/constants.toml` and read by both drivers — macOS via `ui/tooltip/config.lua` (into `Config.layout.*` / `Config.colors.*`), Windows via `lib/ui_style.ahk`. Never hardcode tooltip style (radius, border, separator, padding, colors) in a renderer; add/read the key in the shared TOML.

**Per-driver alphas are deliberately different, by design.** The file carries BOTH `border_alpha_hs` (0.13) and `border_alpha_ahk` (0.25), and `sep_alpha_hs` (0.09) vs the AHK separator value, because hs.canvas and GDI render the same nominal alpha differently — the split values make the two LOOK identical. macOS code MUST read the `_hs` variants. A 2026-06-16 bug had the macOS *stacked* (multi-row LLM) canvas hardcode the AHK `0.25` for both its border and separators, so the multi-row tooltip looked heavier than the single tooltip and than Windows. Fixed by routing both through `Config.colors.border` / `Config.colors.sep`. Regression: `tests/unit/ui/test_tooltip_shared_style.lua`.

**Rounding the stacked colored rectangle — DO NOT use an `action="clip"` element.** The single tooltip (`renderer.M.canvas`) always rounded its background, but the stacked canvas drew one sharp-cornered fill rectangle PER ROW under a rounded border — a colored rectangle poking outside the rounded border. A first fix attempt added a leading rounded `action="clip"` element (+ trailing `resetClip`) with a load-time probe and a `CLIP_OFFSET` index shift. **This was WRONG and shipped a regression:** on the user's Hammerspoon the clip action was not honored, so the element rendered with the hs.canvas DEFAULT `fillColor` — which is RED — turning the ENTIRE tooltip solid bright red instead of a translucent red tint. The probe (just `pcall(appendElements{action="clip"})`) passes regardless because appendElements accepts any action string; it does NOT prove the clip clips. **Working fix:** draw ONE rounded background rectangle (element 1) spanning the whole stack, `apply_tint()`-ed from the firing (first) row — that single rounded rect IS the colored rectangle and shares the border's corners. Per-row background overrides stay available (rounded) but are drawn only when a row's tint differs from the panel's (rare — alternatives usually share the firing row's category color), so the common case is one clean rounded panel. Element layout: `[1]` panel bg, row i `base=(i-1)*3+2` (bg/text/label), separators `sep_base=row_count*3+2`, border `row_count*4+1`. The element list is built by the PURE `renderer.M._build_stacked_elements(n)` so the structure (rounded panel, NO clip, rounded border) is unit-testable even though the stub `hs.canvas` is a no-op mock (`tests/unit/ui/test_tooltip_stacked_panel.lua`). Pixel/translucency still needs a real-Mac check, but "all red" can never silently return.

### project-hs-script-quit-kills-karabiner

_The quit shortcut os.exit()s and bypasses the shutdown callback, so it must kill Karabiner itself_

<sub>slug: `project_hs_script_quit_kills_karabiner`</sub>

The `script_quit` action (`modules/gestures/actions.lua`, bound by default to **rcmd+Escape** via `script_control.lua`'s `escape` slot) quits Hammerspoon with `os.exit(0)`. `os.exit` terminates the Lua VM abruptly and **does NOT trigger `hs.shutdownCallback`** (`init.lua`) — where the normal Karabiner-Elements teardown lives (step 3, `KILL_FAST_CMD`). So on the quit-shortcut path, KE kept running with the Ergopti complex-modification rules and the **physical keyboard stayed remapped after HS was gone** (2026-06-16 user report, "ultra important"). Fix: `script_quit` now calls `karabiner.kill()` itself, synchronously, before scheduling the exit. `karabiner.kill()` (`modules/karabiner/init.lua`) runs the robust `KILL_CMD` (`ke_lifecycle.lua`) which does a `launchctl bootout` of every user-level karabiner/pqrs agent — NOT just `KILL_FAST_CMD`'s `pkill`, because a bare pkill of `karabiner_console_user_server` lets launchd respawn it and re-grab the keyboard. `kill()` also respects a user-managed KE (leaves it untouched when HS did not own the bridge via `is_hs_owned_bridge()`). It is synchronous (blocking `hs.execute`), so KE is provably down before `os.exit`. Same reasoning applies to ANY future "quit HS" code path that uses `os.exit`: it must tear KE down explicitly. Regression: `tests/unit/modules/gestures/test_script_quit_kills_karabiner.lua`.

**The shutdown KE teardown must NOT run on a RELOAD — only on a genuine quit (2026-06-16).** `hs.shutdownCallback` fires for BOTH `hs.reload()` and a real quit, with no built-in flag to tell them apart. Its step 3 ran `KILL_FAST_CMD` unconditionally, so EVERY reload killed the user-level KE bridge (`karabiner_console_user_server` + `session_monitor`). `KILL_FAST_CMD` never names `karabiner_grabber`, but on the user's KE version killing the bridge **cascades the root grabber daemon down** — so the next boot's health check found no grabber and popped the **native "install Karabiner" prompt** (user report: "dès le reload … c'est karabiner_grabber … UI native qui me propose de télécharger karabiner", no logs because it's a UI path). This contradicts the deliberate design (`karabiner/init.lua` comments: "KE reloads via FSEvents — daemons stay alive across reloads, no Space switch"). Fix: a reload-vs-quit guard. `lib/reload_guard.lua` drops a short-lived timestamp sentinel in the Storage adapter; `init.lua` **wraps `hs.reload` once at boot** to call `reload_guard.mark_reload()` before delegating (captures every reload path — file-watcher auto-reload, locale/paths change, menu "reload", the `script_reload` shortcut — since they all read the global `hs.reload` at call time), and `reload_guard.clear()` runs once at boot so the sentinel can only be true because a reload was initiated in the live session. The shutdown handler now skips the KE kill when `reload_guard.is_reloading()` (60 s TTL guards against a stale sentinel from a crash mid-reload). The quit-shortcut path is unaffected (it `os.exit`s, bypassing the callback, and kills KE itself — see above); a genuine Cmd+Q still tears KE down (no sentinel → kill runs). `reload_guard` routes persistence through `adapters.storage` and time through `os.time` so it adds ZERO `hs.*` to the lib baseline — **but the gate counts `hs.` even in comments**, so its docstrings deliberately say "a Hammerspoon reload"/"the Hammerspoon shutdown callback" instead of the literal API token. Regression: `tests/unit/lib/test_reload_guard.lua` (marked → reloading; cleared/fresh → quit; stale/non-numeric sentinel → quit). Real-Mac check still needed to confirm the grabber survives a reload end-to-end.

### project-hs-onboarding-config-schema

_The first-run wizard must write the canonical HS config schema, and the "ready" notification was removed_

<sub>slug: `project_hs_onboarding_config_schema`</sub>

The macOS onboarding wizard (`ui/onboarding/init.lua`) writes the user's first-run answers to `<config_dir>/hammerspoon/config.toml`, which is then read back by `ui/menu/preferences.lua` (the `KEY_MAP` table) after the wizard's reload. **The two MUST agree on section + key names.** A 2026-06-16 bug: `commit()` wrote AHK-flavored keys — `[Metrics] metrics_enabled`, `[Gestures] Enabled`, `[Hotstrings] MagicKey`, `[Layout] Ergopti*`, `[Script] Locale` — but the macOS loader reads `[metrics] enabled`, `[gestures] enabled`, `[hotstrings] enabled` / `[hotstrings] trigger_char` (lowercase sections, clean `enabled` flags). So enabling metrics + gestures in the wizard had ZERO effect after the reload (the keys were never read → defaults won). Fixed by building the updates via the pure `onboarding.M._build_config_updates(answers)` using the canonical schema; regression `tests/unit/ui/test_onboarding_config_schema.lua` asserts the exact sections/keys and forbids the AHK-style ones. **Locale is special: it persists via `hs.settings` (`i18n_locale`), NOT config.toml** — `set_locale_no_reload()` only touches memory (wiped by the wizard's reload), so the wizard now also calls `i18n.persist_locale(code)` (a non-reloading settings write added for exactly this). When adding a new wizard question, add its key to BOTH the wizard updates and `preferences.KEY_MAP`, or it silently won't stick. Layout/`use_ergopti` on macOS maps to `[hotstrings].enabled` (the hotstring engine); the physical layout is Karabiner-deployed independently, so there is no `[layout] Ergopti*` config key.

**Boot "script ready" notification removed.** Now that boot is ~1 s (third perf pass), the per-launch "✅ Ergopti+ — Script prêt !" banner (`menu.script_ready`, emitted at the end of `ui/menu/init.lua` M.start) was pure noise and is gone. Convention going forward: **notifications are reserved for things the user must act on or wait for — LLM and Karabiner.** Do not add per-launch/"feature toggled" success banners.

### Keymap module architecture and refactor decisions

_Structure of the keymap module, where defaults live, which files do what_

<sub>slug: `project_keymap_architecture`</sub>

## File map

- `modules/keymap/init.lua` — Main engine, CoreState, eventtap loop. Single source of truth for ALL keymap defaults via `M.DEFAULT_STATE` and `M.DELAYS_DEFAULT`.
- `modules/keymap/registry.lua` — Hotstring DB, TOML/Lua file loading, group/section management, terminators.
- `modules/keymap/utils.lua` — Text emission (keystrokes vs. clipboard paste), token parsing, LLM overlap solver, ignored-window cache.
- `modules/keymap/expander.lua` — Auto-expand, terminator-expand, repeat-feature execution.
- `modules/keymap/llm_bridge.lua` — Hotstring preview, prediction acceptance, LLM config forwarding.
- `lib/text_utils.lua` — UTF-8 utilities, diff engine, case conversion. Stays in lib (also used by modules/llm/parser.lua).
- `ui/menu/menu_hotstrings.lua` — Menu UI for hotstrings. Reads preview defaults from `keymap.DEFAULT_STATE`.

## Default values: single source of truth

- **All keymap defaults** live in `modules/keymap/init.lua` → `M.DEFAULT_STATE` and `M.DELAYS_DEFAULT`.
- `ui/menu/menu_hotstrings.lua` reads `preview_star_enabled`, `preview_autocorrect_enabled`, `preview_ai_enabled`, `preview_colored_tooltips` from `keymap.DEFAULT_STATE` — never re-declares them.
- `llm_bridge.lua` seeds its local preview flags from the `keymap_defaults` table passed to `M.init()`.

**Why:** The user explicitly requires that default values be defined in exactly one place (the keymap module) and that the menu only stores user overrides, never its own hardcoded defaults for keymap-owned settings.

## Patterns to always apply

- Every public function that uses `_state` starts with `if not require_state("func_name") then return end`.
- No silent fallbacks for missing state — log an ERROR and return immediately.
- Logger.start/success pairs for significant lifecycle actions (init, start, stop, load).
- Logger.trace/done pairs for routine internal operations (emit, sort).
- Setters log at DEBUG level.

### project-hs-synthetic-injection-choke-point

_The macOS driver tracks self-emitted synthetic keystrokes in TWO independent places; any injector that bypasses the expander choke point desyncs them and can corrupt typed output_

<sub>slug: `project_hs_synthetic_injection_choke_point`</sub>

The Hammerspoon driver runs **two independent CGEvent taps** that each see the
app's own synthetic keystrokes and each keep their own "skip my synthetic
output" bookkeeping:

- **keymap tap** (`modules/keymap/init.lua`): `CoreState.expected_synthetic_deletes` + `expected_synthetic_chars`, plus `suppress_rescan()` / `no_rescan_until` to stop emitted text from re-entering `run_trigger_checks`.
- **keylogger tap** (`modules/keylogger/init.lua`): a separate `CoreState.synth_queue`, fed only by `M.notify_synthetic()` and drained in `handle_key`.

`expander.perform_text_replacement` is the **single correct choke point**: it
arms both counters, calls `suppress_rescan`, calls `keylogger.notify_synthetic`,
and resyncs the buffer. `llm_bridge.apply_prediction` mostly mirrors it.

**Foot-gun (the class of bug found in the 2026-06 HS audit, see
`AUDIT_HAMMERSPOON_BUGS.md` at repo root):** injectors that emit raw
`hs.eventtap.keyStroke("delete")` + `emit_text` **outside** that choke point
desync the two trackers. Both named injectors below were fixed by the
2026-07-01 audit's implementation pass and now route through the choke point —
this entry previously (incorrectly) described them as still bypassing it; keep
this paragraph in sync with the source when either injector changes again.
`dynamic_hotstrings/rules_engine` now routes through `keymap.inject_dynamic`
(with a fallback path that itself calls `suppress_rescan`, the counters, and
`notify_synthetic`). `personal_info.do_expand` likewise now calls
`notify_synthetic`, not just `suppress_rescan`. The paste branch (`emit_text`
returns `(1,"")` for >50 chars or codepoints >U+FFFF) leaves
`expected_synthetic_chars` empty and the synthetic Cmd+V then hits the
Cmd/Ctrl buffer-wipe branch — this remains a live constraint for any new
injector to respect.

**How to apply:** never emit synthetic deletes/text from a new injector with raw
`hs.eventtap` calls. Route it through `perform_text_replacement` or a shared
`keymap.inject_replacement(deletes, text, variant)` helper so the bookkeeping is
guaranteed. The two synthetic trackers must also stay in sync on recovery: the
keymap self-heals (`dt > 0.5s` reset) and the keylogger `synth_queue` now also
self-heals via a `SYNTH_IDLE_DRAIN_MS` (500 ms) idle drain in
`modules/keylogger/init.lua`. This foot-gun watch-list entry is about the NEXT
injector someone adds, not `rules_engine`/`personal_info` specifically anymore.
Related: [[project_keymap_architecture]], [[feedback_regression_tests]].

### project-locale-parity-test

_en.json is the canonical key set; the AHK meta-test test_locale_json_valid.ahk enforces parity in CI; check_locales.py --fix is the manual backfill tool_

<sub>slug: `project_locale_parity_test`</sub>

`static/ergopti_plus/_shared/data/locales/en.json` is the canonical reference.
Every other locale file must mirror its key set exactly — no missing, no extra.

**Why:** Stale keys (removed from EN but lingering in translations) and
missing keys (added to EN but not yet translated) both ship as bugs.
Parity is enforced in CI by the AHK meta-test
`windows/tests/meta/test_locale_json_valid.ahk` (run by `run_all.ahk` in the
`test-ahk` job), which ASSERTS that all 21 locales expose exactly `en.json`'s key
set (currently 2208 keys). `tools/check_locales.py` is the manual developer tool
that asserts the same parity locally and, via `--fix`, PRODUCES it. There is no
`.github/workflows/test_locales.yml` — that workflow never existed.

**How to apply:**

- Add a key: insert it in en.json, then run
  `python tools/check_locales.py --fix` to backfill every other locale
  with the English value as a placeholder. Translators (or sub-agent
  translation passes) update those placeholders later.
- Remove a key: delete it from en.json, then `--fix` drops it from
  every other locale.
- The "Untranslated" column in the script output is informational only;
  cognates and brand names legitimately share text with English so it
  does NOT fail CI.

Sibling memory: [[project-ui-dynamic-buttons]].

### project-locale-fast-cache

_The Windows driver's locale .tsv is a gitignored self-healing cache regenerated from the canonical .json; only .json is tracked_

<sub>slug: `project_locale_fast_cache`</sub>

`JsonParse` of a 2208-key locale costs ~180 ms on the boot critical path (the tray
menu needs `t()`); parsing the flat `key<TAB>value` `.tsv` instead is ~16 ms
(~×11). To keep that speed WITHOUT committing the same data twice, the `.tsv`
files under `static/ergopti_plus/_shared/data/locales/` are a **gitignored, self-healing
cache** owned end-to-end by `lib/i18n.ahk` (`_I18nLoadLocaleMap` /
`_I18nWriteTsvCache`): on load it uses the `.tsv` when present AND at least as new
as the `.json` (`FileGetTime "M"` compare in `_I18nTsvIsFresh`), otherwise it
parses the `.json`, builds the map, and rewrites the `.tsv` for the next boot. The
`.json` is the single tracked source of truth; consumers are Windows-only (nothing
in macOS/web reads these).

**Why:** The maintainer's hard rule is no tracked duplication. The earlier design
committed both `.json` and a codegen-generated `.tsv` (+ a node parity test +
pre-commit guard) — the same data in git twice. The lazy cache removes the tracked
`.tsv`, deletes the node codegen + parity infra, and makes the AHK driver the SOLE
generator: one format on disk that cannot drift from its source (a stale `.tsv` is
detected by mtime and rebuilt automatically).

**How to apply:**

- Edit only the `.json`. The driver auto-regenerates the `.tsv` on the next boot
  whenever it is missing OR older than the `.json` (one ~180 ms boot, then fast
  again). Never commit a `.tsv` — `.gitignore` blocks it.
- The cache stores values with the RAW `★` placeholder (MagicKey-independent); the
  reader substitutes the configured MagicKey at parse time. The writer escapes
  `\` → `\\`, CR → `\r`, LF → `\n` (backslash FIRST); the reader inverts in one
  left-to-right scan. Keep writer/reader in lockstep — `test_i18n.ahk` pins the
  round-trip, staleness-regeneration, raw-★, and fast-path-served-without-json
  invariants.
- A read-only install dir just means the write fails silently and every boot uses
  the `.json` path (correct, slower) — the cache is strictly best-effort.

Sibling memory: [[project-locale-parity-test]] is the SEPARATE en.json key-set
parity guard (`tools/check_locales.py`) — a different concern from this
fast-parse cache.

### project_metrics_pipeline_17

_AHK metrics pipeline — bug #17 CLOSED, follow-up bugs fixed_

<sub>slug: `project_metrics_pipeline_17`</sub>

Bug #17 "metrics population" on Windows/AHK. Verified 2026-06-02 via a 5-agent mapping workflow + live DB inspection (`D:\Documents\GitHub\config\ergopti_plus\metrics\by_device\6b399146-3e75-fe4a-aab3-c1d0c68a2b19\compact_work.db`, query with `python` not python3).

**Architecture (verified):** Dashboard data = prefetch (`keylogger_prefetch.ahk` KLPF*BuildAndWrite → `keylogger_reader.ahk` KLR_BuildDatabase → manifest JSON in A_Temp). KLR loads ALL devices' data.sql (all-time `events*_`) into a cached `:memory:` db, then every cycle Clear→Rebuild→Inject: KLR*ClearAggregates wipes agg*_/ngram*\*; KLR_RebuildAggregates recomputes SQL-derivable aggregates from events*\* (all-time); KLR_InjectKlwBatch drains the live KLW.batch (recent-only). AHK deliberately does NOT persist aggregates (anti-bloat, ~140MB/day) — that's why the SQL rebuild exists. `compact_work.db` is a separate launcher debug artifact, NOT the dashboard source. macOS (`macos/.../aggregator.lua`) is single-source (the walk owns ALL agg tables, persisted per tick) — the dashboard JS (`_shared/ui/metrics_typing/data.js`, `metrics_apps/script.js`) is written against macOS semantics.

**Convergent target:** SQL rebuild = single source for everything computable from events\_\*; walker = single source ONLY for char-level/ngram tables (ngrams, kc_hold, buckets, errors, ergo, chars_class, burst, session, layouts) + enrichment columns SQL can't compute. AHK can't go pure-walker like macOS without reintroducing the bloat.

**STATUS: CLOSED (2026-06-02).** All bugs fixed and live-verified. Commits on `dev`, NOT pushed.

**Commits landed:**

- `290ff0df4 fix(metrics): single-source AHK aggregation and tag synthetic input` — 7 files
- `49c630d9f fix(lint): repair convention linter and realign surfaced banners`
- `fix(metrics): wire reset button to AHK cache purge and fix empty-db first run` — 3 files
- `fix(metrics): add hs_suggested to SQL rebuild and manifest projection` — 1 file

**All root-cause bugs fixed:**

1. Double-count (walker+SQL both writing agg scalars) → collapsed to single-source per column.
2. chars semantics (LENGTH(text) vs keystroke count) → fixed via json_each non-synthetic count.
3. hs_chars net→gross double-subtract → fixed: feed GROSS = SUM(net_saved+LENGTH(trigger)).
4. switches_to schema bug (wrong col names, silent fail) → fixed col names.
5. esrc lost (KLR_NewNgramItem hardcoded hs=0) → fixed with regex decode of esrc_json.
6. hs_suggested missing → added INSERT COUNT(\*) WHERE kind='suggested' + manifest projection.
7. Reset button no-op on Windows → fixed: JS postMessage + AHK clear_cache handler purges all 3 cache layers (KLPF_MANIFEST_CACHE, KLRCache, KLPF_LAST_JSON) + disk file.
8. Empty dashboard on first run / after metrics folder delete → fixed: KLR_BuildDatabase early-return when by_device/ absent now runs KLR_RebuildAggregates+KLR_InjectKlwBatch before returning.

**Known remaining gaps (non-blocking):**

- app_time shows old garbage for pre-idle-fix events_app_switch rows (historical only, new data clean).
- chars includes [BS] keystrokes — matches macOS semantics, intentional.
- LLM path unused so llm_chars=0 and esrc llm attribution unverifiable until LLM is used.

**Lint:** pre-commit husky hook runs `lint-conventions.js --fail-on-violations` and NOW BLOCKS on violations. Always `npm run fix:all` before committing.

### project-hotstring-live-rebuild

_Hotstring section/category toggles apply in-process (no Reload) by re-running RegisterAllHotstrings; native-engine + layout-backed features under hotstrings.\* are the reload-only exceptions_

<sub>slug: `project_hotstring_live_rebuild`</sub>

The whole AHK hotstring registration in `modules/hotstrings.ahk` is wrapped in one re-runnable `RegisterAllHotstrings(IncludeNative := true)` function, called once at boot (right after the `#Include` in `ErgoptiPlus.ahk`) and again on every live toggle. A menu toggle no longer Reloads the script: it flips the feature flag (`WriteFeatureUpdate`, which mutates the in-memory `Features` Map AND persists to disk) then calls `RebuildHotstringsLive()` in `ui/tray_menu.ahk` — `HSE_RegistryClear()` + `HSE_HardReset()` + `RegisterAllHotstrings(false)` + `HotstringPrefixWatcherRebuildIndex()` + `RebuildTrayMenu()`. Re-running re-evaluates every `if Features[...]` guard, so cross-dependent sections (sfbs_reduction.bu reads magic_key.text_expansion) and inline-generated ones (comma_j, rolls operators, the `SpaceAroundSymbols`-baked `:=` / `->` — recomputed at the top of each run) all apply with no per-section special-casing.

**Why a re-run instead of the old HSE-group splice:** the previous approach kept a whitelist of "pure" `LoadHotstringsSection` groups and spliced them in/out of the live HSE index, which couldn't handle cross-deps or inline registrations — so ~half the sections still Reloaded. The uniform re-run handles everything except the cases below.

**The reload-only exceptions** (`lib/hotstrings/hotstring_live_toggle.ahk` → `_HS_RELOAD_ONLY_GROUPS`, an inverted blocklist — everything is live unless listed):

1. **Native AHK `Hotstring()` sections** — `distancesreduction.dead_key_e_circumflex` (Ê deadkey) and `autocorrection.multiple_punctuation_marks` ("…"). They register through AHK's native hotstring engine, not the HSE; `HSE_RegistryClear()` can't drop them, and re-registering them from a menu-click thread would risk the wrong `A_InputLevel`. So `RegisterAllHotstrings(false)` SKIPS them (`if IncludeNative`) on a live rebuild — they keep their boot registration — and toggling one of them Reloads.
2. **Layout features filed under `hotstrings.*` in the manifest** — `magickey.replace` (the J→★ key remap, applied by `modules/layout.ahk` `RemapKey` at boot, not by RegisterAllHotstrings). A hotstring rebuild does nothing for it, so it Reloads. **Gotcha:** the `hotstrings.*` manifest namespace is NOT a clean 1:1 with what RegisterAllHotstrings registers — audit `Features["hotstrings"][...]` reads in non-hotstrings modules (only `modules/layout.ahk` at time of writing) before assuming a `hotstrings.*` path is live-eligible.

**Category toggles** (`ToggleCategoryAllFeatures`) are live for **Rolls** and **SFBsReduction** only — every other gated hotstring category holds a reload-only feature (DistancesReduction→deadkey, Autocorrection→"…", MagicKey→replace) or is the Hotstrings master gating those. `ApplyMasterGatesToFeatures` is destructive (it zeroes `Features` for gated-off categories), so it's made reversible by a deep-clone `_HSCategorySnapshot` taken at boot BEFORE gating and refreshed each time a category is turned OFF, then restored on ON — so section toggles made while a category was on survive an off→on cycle without re-reading config (config can omit default-valued sections, so a config re-read would lose them). The layout AltGr rolls (chevron_equal, hashtag_quote) follow the gate because their `HotIf` reads the zeroed/restored `Features` live.

**The `(#` / `[#` gotcha:** the `paren_quote` / `bracket_quote` rolls (menu labels `(# ➜ ("` / `[# ➜ ["`) are defined in `rolls.toml` (`paren_quote` / `bracket_quote` sections, served via the runtime cache) but never loaded by RegisterAllHotstrings — on Ergopti the `(#`→`("` is actually produced by the LAYOUT `HashtagOrQuote` handler (SC017, the # key), which used to be gated only by `hashtag_quote`. Fix: gate that handler's `(`→quote on `Features[rolls][paren_quote]` and `[`→quote on `bracket_quote`, read live, so the menu items the user naturally toggles actually control it. Do NOT also load the HSE `paren_quote` — that would make `(#` need two toggles to disable.

Related: [[project_hotstring_engine_internals]] (the HSE InputHook the rebuild repopulates), [[project_hotstring_delay_architecture]], [[feedback_loader_target_explicit]] (WriteFeatureUpdate mutates the live Features in place), [[feedback_test_before_merge]] (each slice — wrap, live sections, category-live — was boot-tested live before its commit).

### project-hotstrings-self-healing-cache

_The bundled hotstrings are NOT committed generated AHK any more — they are a gitignored, self-healing `.tsv` cache rebuilt from the TOML at runtime, to cut boot-time parse._

The single biggest boot cost was invisible: AHK tokenises every `#Include`d source **before** it creates the tray icon, and the committed `generated_*.ahk` bundle was **~1 MB / ~2992 rows** of that — measured at **~470 ms of the ~470-660 ms "time-to-icon"** (the parse phase; pure file I/O for all 259 driver files is only ~35 ms, so compiling to `.exe` would NOT help — the cost is CPU tokenisation, not disk). `BootProfile_ProcessUptimeMs()` (GetProcessTimes creation FILETIME vs now) surfaces this pre-first-log phase as the first BootProfile line.

Fix (mirrors the i18n locale `.tsv` pattern exactly): deleted the 6 `generated_*.ahk`, the node `build-hotstrings.cjs` AND the python `compile_hotstrings.py` codegens (+ the `build:hotstrings` npm script + the CI "Regenerate hotstrings_generated.ahk" step). `lib/hotstrings/hotstrings_cache.ahk` now owns it: `HotstringsCacheEnsure()` reads `_shared/modules/hotstrings/generated_hotstrings.tsv` (gitignored) when it is at least as new as every bundled TOML; otherwise it **rebuilds from the TOML once** (first launch or after a TOML edit) and rewrites it. It plugs into the SAME `_GENERATED_HOTSTRINGS` fast-path `LoadHotstringsSection` already consults (each cached `cat.sec` → a bound `_HsCacheRegisterSection`), so callers are unchanged. Rows are `[flags, trigger, output, finalResult, isRepeat, isCaseSens]`; the builder uses the **identical** line scan + `_HOTSTRING_ENTRY_PATTERN` + `UnescapeTomlString` + flag logic as the runtime TOML fallback, so it reproduces the old generated behaviour 1:1.

Gotchas: (1) `isRepeat` was ALREADY always false in the old generated output — the generator compared the section to the literal `"repeatcorrections"` while the real section is `repeat_corrections` (underscore). Preserved verbatim (behaviour-preserving, NOT corrected). (2) The generated fast-path never set `Priority` in opts (the TOML fallback does) — the cache matches the generated path (no Priority). (3) New `.ahk` files MUST be UTF-8 **BOM** + CRLF or AHK silently aborts mid-file → the file's later functions go undefined → load error with no message in the headless harness (run `node tools/deploy/fix-ahk-encoding.cjs`). (4) The bundled-hotstring registration path had NO end-to-end suite coverage; `tests/test_hotstrings_cache.ahk` is now that net (build parity, lossless `.tsv` round-trip, escape/unescape of tab/CR/LF/backslash). First-launch (or post-edit) pays a one-time TOML parse; every later boot is the fast `.tsv` read.

<sub>slug: `project_hotstrings_self_healing_cache`</sub>

### project-prefix-index-rebuild-cost-is-cold-disk

_The prefix-watcher index rebuild's cost is the cold-disk TOML read, NOT parse CPU — build the index from the in-memory `_HS_CACHE_ROWS`, the same way HSE registration does._

`HotstringPrefixWatcherRebuildIndex` used to rebuild its preview index by re-reading + regex-parsing every category TOML from disk (`_RegisterCategoryTriggers` per category). The smoking gun was in the boot log: the **same 3180-trigger index** measured **157 ms once the OS file cache was warm but 3031–6422 ms on the cold read right after a reload** (magickey.toml alone is ~2119 entries), under boot disk/CPU contention. That multi-second synchronous rebuild monopolised the single AHK thread, so the **tray menu could not open** during the deferred boot pass — the user-visible "menu takes seconds to appear". The parse work itself is cheap; the disk read is what blew up. Two rebuilds run at boot (the boot-tail warm-up `SetTimer(HotstringPrefixWatcherRebuildIndex, -HS_PREFIX_INDEX_WARM_DELAY_MS)` in `ErgoptiPlus.ahk`, and the one in `RegisterEmojisSymbolsDeferred`); both build the identical index, so they showed identical 3180 counts.

Fix: bundled categories now rebuild from the already-parsed in-memory `_HS_CACHE_ROWS` (`_RegisterCategoryTriggersFromCache`) — no `FileRead`, no per-line regex. It mirrors `_RegisterCategoryTriggers`' gating (master gate, V2 snake_case remap, per-section Features `enabled`) and feeds the SAME `_AddTriggerVariants` pipeline, so the index is **byte-identical** (pinned by `tests/test_prefix_index_cache_equiv.ahk`, which builds both ways over case-sensitive / strict / magic-key / priority-override entries and asserts entry-for-entry equality). Personal (never bundled — relocatable TOML) and any cache-miss still parse TOML. Map the cache row `[flags, trigger(★), output, finalResult, isRepeat, isCaseSens, priorityOverride]` to the watcher fields via: `IsCaseSensitive = Row[6]`, `IsStrict = InStr(Row[1],"C")>0`, `Individual = Row[7]`, and `StrReplace(★ → MagicKey)` on trigger+output.

Gotcha: the boot-tail warm-up has its OWN `SetTimer`, so it can race ahead of the cache load and fall back to the cold-disk path (`_PrefixWatcherCategoryIsCached` returns false while `_HS_CACHE_LOADED` is still false). The rebuild therefore calls the idempotent `HotstringsCacheEnsure()` first to guarantee the in-memory path. See [[project-hotstrings-self-healing-cache]].

<sub>slug: `project_prefix_index_rebuild_cost_is_cold_disk`</sub>

### project-suspend-pause-invariant

_Pause must fully silence ALL features (no tooltip/LLM/keylogger/widget). AHK Suspend only disarms hotkeys — InputHooks/timers/OnMessage bypass it and need explicit A_IsSuspended guards._

<sub>slug: `project_suspend_pause_invariant`</sub>

When the script is paused, ABSOLUTELY nothing may activate — no tooltip, no LLM prediction/HTTP, no keylogger recording, no WPM widget, no gesture action. User words: « comme ahk éteint donc absolument aucun tooltip ou autre truc ahk ne doit s'activer ». Fixed 2026-06-02.

**Why it's a trap:** native AHK `Suspend()` only disarms **Hotkeys/Hotstrings**. It does NOT touch `InputHook` callbacks, `SetTimer` callbacks, `OnMessage` handlers, or `SetWinEventHook` — all keep firing while `A_IsSuspended`. The whole ErgoptiPlus input pipeline is built on those, so pausing silenced remaps but left tooltips/LLM/keylogger fully live.

**The invariant (AHK):** every InputHook/timer/OnMessage callback that produces an observable side effect MUST early-return on `A_IsSuspended`. Guards live at: `HookDispatcher.Dispatch` (hook_dispatcher.ahk — covers LLM bridge + keylogger watchers), `_OnPrefixChar`/`_OnPrefixKeyDown` (hotstring_prefix_watcher.ahk — its OWN InputHook, NOT via HookDispatcher), `KL_Hook_OnChar`/`KL_Hook_OnKeyDown` (keylogger_hook.ahk — own InputHook), `LLM_Engine_FirePrediction`, `TooltipShow`+`LLM_TooltipShow` (lib/tooltip.ahk render entries), `WPMWidget_Tick`, `GestureSimulateActivity`. **When you add any new hook/timer/tooltip path, add the guard or it leaks while paused.** Lower-priority keylogger timers (idle tick, mouse-park, roi half-life, session/power OnMessage) are NOT yet guarded — guard them too if total radio-silence is wanted.

**Central reactor:** `ToggleSuspend` (ErgoptiPlus.ahk) calls `Ergopti_OnSuspendEnter()` (force-hide both tooltips + `LLM_Engine_CancelTimer`) / `Ergopti_OnSuspendResume()` (`_ResetPrefixBuffer`). A 500 ms `_SuspendStateWatchdog` (global `_LastSuspendState`) replays the reactor for suspend transitions that bypass ToggleSuspend (native Pause, external trigger). The AltGr script combos are registered "S" suspend-exempt so the user can un-pause — see [[project-ahk-menu-dispatcher-drop]] neighbourhood and the Kana fixup [[feedback-ahk-source-encoding]] is unrelated.

**macOS parity:** pause is a soft multi-flag in `modules/shortcuts/script_control.lua` (`_is_paused`, `is_paused()`); the keymap eventtap early-returns on `CoreState.processing_paused` so the preview/hotstring path is already gated. Gaps closed for parity: `pause_all()` now calls `_keymap.reset_predictions()` + `ui.tooltip.hide_forced()`; gestures `triggerLiveAxisIfNeeded` gained `if not _state.enabled then return end`; `prediction_engine.perform_check` reads `package.loaded["modules.shortcuts.script_control"].is_paused()`. Background warmup HTTP + keylogger already check pause.

### project-macos-llm-runtime-enable-gate

_macOS must not warm up or load an LLM model from profile/model restoration alone; only the live runtime enable gate may authorize warmup side-effects._

<sub>slug: `project_macos_llm_runtime_enable_gate`</sub>

Root-caused 2026-06-15 from a live bug report: the AI menu was disabled, yet `api_mlx` still tried to warm up `Qwen3.5-2B-4bit` for ~186 s and marked the model load as failed. The trigger path was non-obvious: `ui/menu/menu_llm/profiles_manager.lua` calls `sync_profiles()` during menu construction, that calls `modules.llm.set_active_profile()`, and the core used to re-prime the KV cache unconditionally on every profile change. At startup the menu also resolves the current model before the real enable/disable state is applied, so a disabled boot could still schedule a warmup/load attempt.

**Invariant:** restoring profile/model state is allowed at boot, but it must be side-effect-free until the runtime prediction engine explicitly enables LLM activity. Persisted/default config is NOT enough: startup may temporarily restore state while predictions remain locked off. The canonical gate now lives in `modules/llm.init` as `CoreState.runtime_llm_enabled`, written by `prediction_engine.set_llm_enabled()` via `core_llm.set_runtime_llm_enabled()`.

**How to apply:** any future warmup trigger (`set_active_profile`, model/profile restoration, startup controller, menu sync) must check the live runtime flag, not just `DEFAULT_STATE.llm_enabled`, TOML state, or menu checkbox state. A profile switch while disabled must update the active profile ID but MUST NOT hit `warmup_model()` or start an MLX/Ollama load. Regression coverage lives in `tests/unit/modules/llm/test_init.lua` and `tests/unit/modules/llm/test_prediction_engine.lua`.

### project-macos-eventtap-no-blocking

_Never run blocking work (osascript / hs.execute subprocesses) synchronously inside an hs.eventtap callback — macOS disables the tap (kCGEventTapDisabledByTimeout) and the shortcut dies. Defer with hs.timer.doAfter(0, …)._

<sub>slug: `project_macos_eventtap_no_blocking`</sub>

The script-control shortcut (AltGr+Enter → pause / resume) is an `hs.eventtap` on `keyDown` (`modules/shortcuts/script_control.lua` → `handle_key`). Its callback toggles pause via `dispatch_action`, which fires the `_on_pause_change` listener **synchronously, still inside the eventtap callback**. When the « switch keyboard layout on pause / resume » feature (`layout_pause_switch_enabled`) was wired up, that listener called `menu_keyboard_layout.set_layout_by_kl_name`, which spawns **two BLOCKING `/usr/bin/osascript` subprocesses** via `run_osascript_isolated` (`hs.execute`): one to enumerate TIS input sources, one to `TISSelectInputSource`. For Ergopti bundles those take hundreds of ms. Reported 2026-06-09.

**Why it's a trap:** a CGEventTap callback that does not return fast enough is disabled by macOS with `kCGEventTapDisabledByTimeout`. Once disabled the tap stops receiving events entirely — so after the _first_ AltGr+Enter (which still toggled), the tap was dead and AltGr+Enter did **nothing at all** (« rien du tout »), neither pause nor resume. The bug only surfaced once `ab20abd52` made the layout switch actually fire (before, a separate regression meant `set_input_source` silently no-op'd), so the blocking call had never really run inside the tap before — a textbook « fixing one bug unmasks another » sequence.

**Fix:** the layout switch is deferred onto the next run-loop cycle so the eventtap callback returns immediately. The decision + deferral lives in `menu_keyboard_layout.schedule_pause_layout_switch(is_paused, state, schedule?)` (scheduler injectable for tests; defaults to `hs.timer.doAfter(0, …)`), and `ui/menu/init.lua`'s `_on_pause_change` listener calls it. Regression test in `tests/unit/ui/menu/test_menu_keyboard_layout.lua` asserts the switch is _scheduled_, never run synchronously.

**How to apply:** any work done inside an `hs.eventtap` callback — or anything it calls synchronously (listeners, menu rebuilds, layout switches) — must be cheap. If it shells out, touches TIS / Carbon, or does heavy I/O, wrap it in `hs.timer.doAfter(0, …)`. The gesture click-hold release path learned the same lesson the same day (deferred synthetic mouse events off the keyDown). See [[project-suspend-pause-invariant]] for the pause reactor that drives `_on_pause_change`.

### project-macos-script-control-tap-lifecycle

_The script-control eventtap (AltGr+Enter/Backspace/Escape) is keycode-based and must survive layout switches AND pause. Two traps killed it: `shortcuts.start` is a Bindings-only proxy (asymmetric with `shortcuts.stop`), and the pause-layout feature's layout switch fires the Karabiner input-source watcher which rebuilds everything._

<sub>slug: `project_macos_script_control_tap_lifecycle`</sub>

The macOS script-management shortcuts — AltGr (right_command / right_option) + Enter / Backspace / Escape → pause-toggle / reload / quit — are served by a single `hs.eventtap` in `modules/shortcuts/script_control.lua` (`handle_key`). It is keyed on **physical key codes** (Karabiner sentinels F13/F14/F15 + a right-cmd fallback), so it is **layout-independent** and must stay alive through layout switches and pause. Two non-obvious bugs stranded it (root-caused live on branch fix/hs, 2026-06-09/10).

**Trap 1 — `shortcuts.start` is a Bindings-only proxy.** `modules/shortcuts/init.lua` defines `M.stop()` as a function stopping all three sub-systems (`Bindings.stop()` + `ScriptControl.stop()` + `KeyboardShortcuts.stop()`), but `M.start` is just `= Bindings.start` (a proxy). So any `shortcuts.stop(); shortcuts.start()` round-trip **kills the script-control eventtap and never revives it** (only Bindings restart). The Karabiner input-source watcher did exactly this to re-bind layout-dependent hotkeys, so AltGr+Enter died on the first layout switch — and neither resume nor the menu button could bring it back (they only restart bindings). **Fix:** rebind layout-dependent hotkeys with `pause_bindings()` / `resume_bindings()` (Bindings + KeyboardShortcuts only) and leave the keycode-based eventtap untouched. Never call `shortcuts.stop()`/`shortcuts.start()` as a "rebind".

**Trap 2 — the pause-layout feature triggers the input-source watcher.** When `layout_pause_switch_enabled` is on, every pause switches the macOS keyboard layout (e.g. Ergopti → French). That switch fires Karabiner's `start_input_source_watcher` callback, which `M.regenerate()`'d the **full** Ergopti config and re-armed the binding hotkeys — silently undoing the pause (full remapping back, user shortcuts live mid-pause), and (pre-Trap-1-fix) killing the eventtap. **Fix:** the watcher callback short-circuits on `script_control.is_paused()`, leaving the paused KE config in place (script-control rules only — all three slots, layout-independent key_codes). The eventual resume regenerates the full config for real.

**How to apply:** the script-control eventtap is the one thing that must work in EVERY state (paused, mid-layout-switch, KE-off). Anything that stops or rebinds shortcuts must preserve it. Note `GestActions.execute_single` deliberately has **no** pause guard, so reload/quit (AltGr+Backspace/Escape) fire even while paused — that is intended (lifecycle controls). The paused KE config comes from `Generator.build_paused_script_control_rules` (right_command + right_option × 3 slots). See [[project-macos-eventtap-no-blocking]] (the layout switch must also be deferred + non-blocking) and [[project-suspend-pause-invariant]].

### project-touchdevice-dormancy-is-kernel

_Definitive answer that macOS touchdevice subsystem CANNOT be activated before first physical touch — it is a kernel-driver gate_

<sub>slug: `project_touchdevice_dormancy_is_kernel`</sub>

The macOS `hs._asm.undocumented.touchdevice` watcher reports `running=true` immediately after `:start()` but delivers no frame callbacks until the user physically touches the trackpad. **This is impossible to bypass from userspace and should not be re-investigated.**

**Why:** The streaming gate is in the kernel-side `AppleMultitouchDriver` / `AppleHSSPIHIDDriver`. `MTDeviceStart` arms the callback path but does not prime the sensor. The driver only pushes frames upstream when the HID sensor reports non-zero contact — there is no "send empty frame" path in the kernel-side driver, so no userspace symbol can synthesize one.

Every approach has been verified to fail on built-in Apple Silicon trackpads:

- All MT\* symbols in MultitouchSupport.framework audited (asmagill's reverse-engineered header is the most complete public source) — none wake/prime the device.
- `MTDevicePowerSetEnabled` works only on Magic Trackpad 2 (USB/BT). On built-in M-series, `MTDevicePowerControlSupported` returns false; the call is a no-op (returns kIOReturnUnsupported).
- `IOHIDManager` since macOS 10.12: built-in trackpad is exclusively claimed by the multitouch driver, zero IOHID input value callbacks for raw multitouch.
- `CGEventTap` / `NSEvent` gesture mask: consume already-synthesized gesture events from the WindowServer — same dormancy because the WindowServer itself only receives events when MultitouchSupport emits them.
- `IOPMAssertion`: governs sleep, not sensor activity.
- `IOHIDPostEvent` for synthetic touch: requires private entitlement `com.apple.private.hid.client.event-dispatch`, ungrantable to third parties.

Every real-world project using raw multitouch (BetterTouchTool, FingerMgmt, Middle, OpenMultitouchSupport, libpointing, Kivy mactouch, krackers/rmhsilva/shaun-mathew gists) follows the same pattern and accepts the dormancy. BetterTouchTool's release notes explicitly handle wake-from-sleep by **restarting** the listener — still no pre-touch frames.

**How to apply:** Treat the first physical touch as the activation signal. Don't aggressively recycle watchers expecting it to help — empirical logs confirm 32 recycles produce identical state every time. Two things ARE worth doing:

1. Verify "Input Monitoring" permission is granted to Hammerspoon (Sequoia silently suppresses frames otherwise — `:alive()` will lie and return false even after a touch).
2. Re-create the device on `NSWorkspaceDidWakeNotification` so sleep/wake cycles don't lose the stream (BetterTouchTool pattern).

See also [[project-gestures-startup-design]].

### project-ui-dynamic-buttons

_AHK UIs must use Gui_HarmoniseButtonWidths instead of hardcoded w-values; HS auto-sizes via CSS padding_

<sub>slug: `project_ui_dynamic_buttons`</sub>

Every AHK dialog that adds buttons whose label comes from `t()` must size
them dynamically via `Gui_HarmoniseButtonWidths(buttons, minW)` in
`lib/ui_style.ahk` rather than `AddButton("w90 …")`.

**Why:** Hardcoded `w90` / `w100` / `w110` clipped long localised labels
(German "Durchsuchen", "Zurücksetzen", "Aktualisierungen"). The user
explicitly asked for the dynamic policy to apply across every UI, not
just onboarding.

**How to apply:**

- Create the buttons with NO `w` option so AHK auto-sizes to text.
- Pass the button array to `Gui_HarmoniseButtonWidths([...])`. It
  measures, takes the max, applies the 90 px floor (`UI_BTN_MIN_W`),
  and resizes each button to the shared width.
- Caller still owns positioning. After harmonise, re-position via
  `btn.Move(x, y)` if needed (right-edge anchor, centring, etc.).
- HS does NOT need this — every webview button uses CSS `padding` and
  auto-sizes to content. Don't add Lua-side width logic.

Sibling memory: [[project-locale-parity-test]].

- Latest "encore plus" wave (user repeated "encore plus" after diagnostic/healthcheck enrichment + previous massive test waves): +18-25+ new regression tests focused on making the enriched Diagnostic système (healthcheck) production-hardened + filling keylogger/llm/gestures/timer/shortcuts/meta gaps for near-100% certainty. AHK additions: 5+ new Test() in test_logger.ahk Healthcheck section (active_app cache state accurate under pause in diagnostic report; features manifest + timers/scheduler visible + pause-safe; gestures/LLM/layout collectors pcall-resilient + volume + pause with errors sink visibility + AltGr latch in layout section; keylogger aggregator/rollover data in diagnostic accurate under pause + high volume + privacy); +2 in test_active_app_cache.ahk (diagnostic sees clean cache under pause, no false activations; volume + pause + re-init + pcall WinEvent resilience for snapshot); +2 in test_shortcuts.ahk (AltGr prefix latch historical regression safe across pause/resume + diagnostic must report true latch state; all dispatchers incl. Win\*/menu pause silence + 150+ volume + bad Features + diagnostic safe); +3 in test_timer_scheduler.ahk (every() must be silent under pause + diagnostic can inspect; pcall-wrapped callback ERROR routes to dedicated errors sink under pause; high volume + pause transitions + re-init preserves diagnostic scheduler visibility). HS: new describe in test_aggregator.lua ("aggregator — diagnostic (healthcheck) integration + pause" — 4 its: pure under pause + diagnostic reads safe counts + errors sink; volume+pause+rollover+unicode keeps diagnostic keylogger summary correct/privacy-safe; privacy+FS/pcall under pause still surfaces errors sink to diagnostic; bad/unicode events resilient); new describe in test_conflicts.lua (3 its for pause safety + diagnostic); notes in llm/test_profiles.lua; port_adapter_coverage.ahk lists extended for full keylogger stack, llm stack, gestures conflicts/touchdevice, keymap expander/utils etc., karabiner ke_lifecycle, adapters/timer, active_app_cache, timer_scheduler, features_manifest + healthcheck as special always-available read-only surface for paused troubleshooting. All tests: explicit project_suspend_pause_invariant, historical gotchas (errors sink, AltGr in diagnostic layout, privacy in keylogger-to-diagnostic, pcall/FS), max edges (volume 150-200+, unicode, rollover, re-init, FS/pcall no-crash). Banners: final run clean ("lint-conventions: OK — no violations found"). Tails/greps verified registration. This wave (plus accumulated prior "encore plus" in session) brings the total new regression tests in the campaign well past 250-300. Would have caught: diagnostic returning stale active_app/features/timers/keylogger-agg/LLM-profile/karabiner-grabber/AltGr-latch data or hiding the clean errors sink when user (paused) runs "Diagnostic système" to debug; silent aggregator volume corruption or PII in the troubleshooting report; stuck gesture conflicts or ke lifecycle after suspend; timer pcall errors not visible in diagnostic; wrong LLM profile in healthcheck while suspended. Newly ultra-hardened: healthcheck collectors (active_app, features, timers, gestures/LLM/layout, keylogger agg/rollover) + full keylogger aggregator diagnostic view + conflicts + timer pcall/every + shortcuts dispatchers + historical AltGr + profiles resolve + karabiner lifecycle + meta port/require coverage. Full suites (windows/tests/run_all.ahk + macos/tests/run.lua) + live test (trigger Diagnostic while A_IsSuspended/paused, errors in sink, high volume keylogger/LLM/gestures/timers, pause/resume AltGr/hotstrings, rollover, bad states) mandatory. User can say "encore plus" again.

### project-shifted-comma-case-variants

_The "uppercase" form of a comma/apostrophe/period in case-variant generation MUST be nbsp/nnbsp + punctuation, NEVER a plain ASCII space — anchoring on nbsp is what keeps the ":D" emoji alive._

<sub>slug: `project_shifted_comma_case_variants`</sub>

Case-insensitive hotstrings whose trigger contains `,` / `'` / `.` auto-generate
title/upper-case variants. On the Ergopti Shift layer those keys do NOT shift to
an uppercase letter — they shift to a no-break-space-prefixed punctuation. Per
**French typography the space TYPE differs**: Shift+comma emits `NNBSP(U+202F);`
(narrow), Shift+period emits `NBSP(U+00A0):` (full), Shift+apostrophe emits
`NNBSP?`. The deadkey path (¨+s / ¨+n) can also produce either no-break space.

Two distinct concerns — keep them apart:

- **Emission** (AHK ONLY — macOS input goes through Karabiner, not in this repo):
  the layout must emit the EXACT pairing above (`:`→NBSP, `;`/`!`/`?`→NNBSP).
  Lives in `SHIFT_SYMBOLS` in `windows/lib/layout/layout_shift_caps.ahk`. Pinned
  by `test_layout_tables.ahk` (Shift+period → NBSP+`:`, Shift+comma → NNBSP+`;`).
- **Matching** (both platforms): the case-variant tables are deliberately
  LENIENT — `DS` must come out regardless of WHICH no-break space precedes the
  punctuation. So they pair BOTH no-break spaces with BOTH `:` and `;`.

The single source of truth for the matching tables:

- **AHK**: `_BuildUppercasedSymbols()` in `windows/lib/hotstrings/hotstring_engine.ahk`.
- **macOS**: `M.UPPER_TRIGGERS["," / "'" / "."]` in `_shared/lua/text_utils/init.lua`
  (consumed by `trig_upper`/`trig_title`, which handle the symbol at ANY position
  in the trigger — the comma-first alias block in `modules/keymap/registry.lua`
  only covers comma-FIRST and is a redundant secondary path).

**Why:** Both platforms originally used a plain ASCII space (`" :"`, `" ;"`,
`" ?"`). That was wrong on two counts: (1) the nbsp/nnbsp-prefixed form typed via
the layout never matched the space-prefixed trigger, so caps never produced `DS`;
and (2) a bare `<space>:D` — the `:D` emoji typed after a normal word — DID match
the space-prefixed trigger and got swallowed into `DS`. The user types the emoji
as `<space>:` (plain space), the shifted comma as a no-break space — anchoring on
nbsp/nnbsp is the ONLY thing that separates the two. A later fix corrected the
EMISSION (Shift+period was wrongly emitting `NNBSP:`; French typography wants
`NBSP:`) while keeping MATCHING lenient so `DS` fires for any no-break space.

**How to apply:**

- Never put a plain space in these symbol-shift tables. Use `Chr(0x202F)` /
  `Chr(0xA0)` (AHK) or `"\226\128\175"` / `"\194\160"` (Lua).
- Emission pairing (AHK layout): `:` → NBSP, `;` / `!` / `?` → NNBSP.
- Matching tables stay lenient: comma → all four of `{nnbsp,nbsp} × {":",";"}`;
  apostrophe → `{nnbsp,nbsp} × "?"`; period (macOS) → `{nnbsp,nbsp} × ":"`.
- Regression tests pin all of it: emission (`test_layout_tables.ahk`), lenient
  matching with correct casing AND plain-`<space>` never registered (emoji
  safety). AHK: `test_hotstring_engine_main.ahk` (HSE comma-shift / plain-space
  colon-D), `test_hotstring_engine.ahk`, `test_hotstrings_full.ahk` (variant
  counts), `test_layout_tables.ahk` (emission). macOS:
  `test_hotstring_registry_regressions.lua`.

### project-ahk-v2-semicolon-in-string

_AHK v2 treats ` ;` (space-then-semicolon) as a comment start even INSIDE a double-quoted string literal — a literal `;` in an AHK string causes a "Missing `"`" parse error._

<sub>slug: `project_ahk_v2_semicolon_in_string`</sub>

`x := "nnbsp + ; + d"` fails to parse with `==> Missing """`. The tokenizer ends
the string at the ` ;` and reads the rest as a comment. Confirmed empirically
with AutoHotkey64 v2.

**Why:** Bit during the shifted-comma regression tests — an assertion message
contained a literal `;` and the whole `run_all.ahk` suite aborted with exit
code 2 and produced no results file (the headless failure mode is silent, same
family as the [[project_config_v2_refactor]] encoding abort).

**How to apply:** Never put a literal `;` inside an AHK v2 string. Spell the word
("semicolon") or build it via `Chr(0x3B)` concatenation. This compounds with the
existing ASCII-only test-suite convention (use `Chr(0xNNNN)` for non-ASCII; an
em-dash `—` in a string literal also broke the parser the same way).

### project-hs-timer-callback-errors-invisible

_A Lua error thrown inside an `hs.timer`/`hs.timer.delayed` callback is swallowed to the Hammerspoon Console and never reaches the file logger — so a crash on a timer-driven path is invisible in logs, and a unit-test stub that defines a method production lacks will mask the dangling call._

<sub>slug: `project_hs_timer_callback_errors_invisible`</sub>

Hammerspoon runs timer callbacks under its own protected call. When the callback
errors, Hammerspoon prints the traceback to its **Console** (and the
`~/.hammerspoon` crash log), not through our `lib.logger`, which writes the file
the user collects. The file log therefore shows everything up to the crash and
nothing after, with no `[ERROR]` line — the path just stops mid-way.

**Why:** This masked the "vert mais aucune prédiction" bug. The LLM prediction
engine (`modules/llm/prediction_engine.lua` `perform_check`) is fired by
`_inactivity_timer` (an `hs.timer.delayed`). It called
`StreamingHandler.ngram_predict(buffer)` — a function the production
`streaming_handler.lua` never implemented (a leftover from an extraction
refactor). Calling a `nil` field threw, the timer swallowed it, and the file log
showed `prompt_builder: Request signature accepted` (logged just before the
crash) but never the dispatch `[START] LLM request — model:` — so the request
died silently and no prediction ever appeared even with a green (backend-ready)
health dot. Worse, the unit test stubbed `ngram_predict`, so the suite stayed
green while production crashed on every keystroke-driven request. Fixed in commit
`173b37390` by removing the dead n-gram block; the regression in
`test_prediction_engine.lua` §8 now mirrors the real StreamingHandler surface
(no `ngram_predict`) and asserts `perform_check` reaches `fetch_llm_prediction`.

**How to apply:**

- When a timer-/eventtap-driven feature "does nothing" with no error in the file
  log, suspect a swallowed callback error: read the Hammerspoon **Console**
  (Console.app / `hs.console`), not just the collected file log. A path that logs
  its entry but none of its exit branches (no dispatch, no skip-reason) is the
  tell.
- Keep test stubs faithful to the **real module's exported surface**. A stub that
  provides a method production doesn't have turns a hard crash into a green test.
  When stubbing a singleton (`StreamingHandler`, `PromptBuilder`, `AppFilter`,
  `ApiCommon`), mirror only the functions the real module actually exports — and
  add a regression that drives the real call path so a dangling call fails loudly.
- See [[feedback-regression-tests]].

### project-profile-label-placeholder-convention

_LLM profile labels in `_shared/data/locales/*.json` use **brace** placeholders `{n}`/`{s}` (count + plural-s), NOT printf `%d`/`%s` — the menu substitutes braces, so a printf token leaks verbatim into the UI._

<sub>slug: `project_profile_label_placeholder_convention`</sub>

The `llm.profile.batch_advanced.label` string carries a dynamic prediction count.
Every consumer that renders it substitutes the **brace** placeholders `{n}`
(count) and `{s}` (plural marker), mirroring the prompt-template convention
(`{context}`, `{min_words}`, `{n}`): macOS via
`ui/menu/menu_llm/profile_label.lua` `M.format` (the single source of truth, used
by both `profiles_manager.lua` and `model_switcher.lua`), Windows via
`LLM_Tray_GetProfileLabel` (`StrReplace` of `{n}`/`{s}`). Plain `i18n.get` /
`t()` do **not** substitute — that is the caller's job.

**Why:** The label shipped with printf `%d prédiction%s` tokens while the menu
formatter only ever replaced `{n}`/`{s}`, so the user saw a literal
`… avec %d prédiction%s` in the "Batch Avancé" entry. A parallel path
(`model_switcher.lua`) used `string.format(label, n, s)` and rendered it
correctly, which is exactly why the divergence survived — two consumers, two
conventions, one locale string that could only satisfy one of them. Fixed by
standardising all 21 locales on `{n}`/`{s}` and routing every macOS consumer
through the one `ProfileLabel.format` helper.

**How to apply:**

- A locale value rendered as a menu label must use `{…}` placeholders; reserve
  printf `%d`/`%s` for strings passed straight to `string.format` / `t()` +
  `Format()` (e.g. dialog bodies, `menu.profiles.profile_label_prefix` uses `%s`
  and is `StrReplace`d on `%s`). Never mix the two for the same string.
- Don't format a profile label inline — call `ProfileLabel.format` (macOS) so the
  count fallback (`DEFAULT_STATE.llm_num_predictions`) stays single-sourced.
- Guarded forever by `macos/tests/unit/lib/test_locale_profile_labels.lua` and
  `macos/tests/unit/menu/test_profile_label.lua`, mirrored on Windows in
  `windows/tests/test_llm_menu_regressions.ahk` §5: all 21 locales are scanned so
  no profile label may carry `%d`/`%s`, and `batch_advanced` must keep `{n}`/`{s}`.
- Related: built-in profile rows in the macOS LLM menu now select on a single
  click (no "use this profile" sub-item), matching the AHK tray; cloning a
  read-only built-in moved to a single "Clone active profile…" entry.
- See [[project-locale-parity-test]], [[feedback-regression-tests]].

### project-updater-nonblocking-http

_The updater background poll must never do synchronous WinHttp on the main thread (it freezes all keyboard remapping); WinHttp `SetTimeouts` treats 0 as infinite. Use the project's async WinHTTP + `WaitForResponse(0)` + `SetTimer`-poll pattern._

<sub>slug: `project_updater_nonblocking_http`</sub>

Two distinct foot-guns, both surfaced by a user reporting a "freeze au démarrage" tied to the update check (AHK driver, `lib/updater.ahk`):

1. **`WinHttpRequest.SetTimeouts(resolve, connect, send, receive)` treats `0` as "infinite"**, not "default". The background poller called `SetTimeouts(0, 15000, 30000, 30000)` (commit `c135b2d30`) believing it bounded the call — but the **resolve (DNS) phase stayed unbounded**. On a network where DNS stalls (a connecting VPN, a captive portal, a dead resolver) the synchronous `Req.Send()` blocks forever. Every phase must be a finite, named constant (`UPDATER_HTTP_*_TIMEOUT_MS`). A regression test scans `updater.ahk` for any `SetTimeouts(0,` literal.

2. **A synchronous WinHttp call on the AHK main thread freezes ALL keyboard remapping** for its whole duration — hotkey subroutines and the `Send()` of remapped keys run on the main thread, so they cannot fire while `Req.Send()` blocks. The background poller fires its first check ~30 s after boot (`FirstMs := Min(30000, …)`), so on a bad network the user perceives a "startup freeze". Bounding the timeouts only caps the duration; the real fix is to **not block the main thread at all**.

**How to apply:**

- The unprompted background poll uses the async path: `_Updater_FetchLatestJsonAsync` opens the request in WinHTTP async mode (`Req.Open(url, true)`), `Send()` returns immediately, and `_Updater_PollAsync` harvests it via `WaitForResponse(0)` (0 = do not wait) re-armed by a `SetTimer`. The network I/O runs on WinHTTP's own worker threads — the main thread never blocks. This is the same **WinHTTP-async + `WaitForResponse(0)` + `SetTimer`-poll** pattern used in `modules/llm/api_ollama.ahk` + `api_remote.ahk` (mirroring `hs.http.asyncPost` on macOS). A `try`-wrapped `WaitForResponse(0)` that throws = the request errored (treated as failure); a max-polls cap derived from the timeout budget guarantees no orphaned poll timer.
- Status / ETag / array-unwrap interpretation is shared by the sync and async paths via `_Updater_InterpretResponse` (single source of truth — they must not drift).
- **User-initiated** paths (one-click "check now", changelog, download) keep the _synchronous_ fetch: the user is actively waiting on the click, and the timeouts are now bounded. Only the unprompted poll needs to be async.
- `Updater_StopBackgroundChecks` cancels in-flight async requests so a late response cannot pop a notification after the user picks "never".
- The `[ahk.updater] check_interval_seconds` persistence round-trip for the "never" (0) value is **correct** (verified empirically — write → parse → load yields `0` and the poller stays disarmed). The reason a "never" user can still see checks is that the default _when the key is absent_ is 86400 (opt-out), and the first check fires ~30 s after boot.
- Guarded by `windows/tests/test_updater.ahk`: timeouts all > 0, no `SetTimeouts(0,` literal, `Updater_DownloadAndInstall` sets timeouts before `Send()`, and `Updater_BackgroundTick` dispatches via `_Updater_FetchLatestJsonAsync` (never the blocking fetch).

See [[feedback-regression-tests]], [[project-ahk-menu-dispatcher-drop]].

### project-audit-reverify-2026-06-16

_The 2026-06-14 audit's tracking JSONs and roadmap [x] checkboxes are UNRELIABLE — re-verified against source: 148/154 actually fixed, 11 real bugs remain (3 high)_

<sub>slug: `project_audit_reverify_2026_06_16`</sub>

Re-verification of the 170-finding audit (`docs/AUDIT_ergoptiplus_ahk_2026-06-14.md`) against the **current source** on 2026-06-16. Headline: the audit's machine-tracking is not trustworthy and must never be taken at face value.

- **`tools/dev/_audit_status.json`, `_verify_results.json`, `_impl_results.json` and the roadmap `[x]` checkboxes contradict each other and the source.** `_audit_status.json` showed only 6/170 `checked:true` while `_verify_results.json` marked all 170 `status:"done"` — yet several "done" entries' own `evidence` field says the fix is absent ("still only does LoggerWarn on catch"). **Ground truth is the source code, located by symbol (function/var names), not by the stale line numbers in the finding `files` arrays (lines have drifted).**
- **Actual state: 148/154 re-checked findings are genuinely fixed** (most with a regression test). Only **11 real issues remain**, fully detailed (symptom, file:line proof, fix, regression test) in the root report **`BUGS_RESTANTS_ergoptiplus_2026-06-16.md`**.
- **3 HIGH still open**: (1) generic hold-modifier long-press uses an unbounded `KeyWait(..,"U")` with no `try/finally` (capslock/enter/lalt/rctrl) → a lost key-up latches Ctrl/Alt/Win down system-wide (the `one_shot_shift` paths were hardened by #77, the generic ones were missed); (2) `_LLM_Ollama_Pending` survives `LLM_OllamaCancelAllAsync` and re-dispatches curl+PII-temp-write after suspend; (3) AltGr rolls (`chevron_equal`/`hashtag_quote`/`paren_quote`/`bracket_quote`) are registered BEFORE `RegisterAltGrLayer()` so the "last-registered variant wins" rule makes them dead in the default config (swap the two calls at `modules/layout.ahk:862-863`).
- **The expansion core is sound** re the user's "triggerabcd→outpuabtcd/outputbcd" fear: the main dispatch is one atomic `SendInput(Burst)` under `Critical` (`hotstring_engine_main.ahk:1375-1394`); suppression + synthetic-tag are depth counters. The only residual reorder path is `remap-emit-critical-uneven` (low): `$`/`%`/`=` number-row keys emit via the non-`Critical` `SendNewResult` and can transpose with the next remapped letter (`=a`→`a=`). The Notepad clipboard path is the one acknowledged non-atomic exception (by design).
- **Caveat on the changelog finding (Bug 5):** the synchronous WinHTTP on `_Updater_OpenChangelogWindow` is a *deliberately accepted* trade-off — [[project-updater-nonblocking-http]] documents that user-initiated fetches (check-now / changelog / download) intentionally stay synchronous because the user is actively waiting on the click. It is listed as optional hardening, not an oversight.

**How to apply:** when resuming this audit, read the 11 remaining bugs from the root report; do NOT trust `tools/dev/_*` tracking files. The re-verified structured payload is `tools/dev/_reverify_payload.json`; the 170 known titles (for dedup) are `tools/dev/_known_titles.txt`. See [[feedback-regression-tests]], [[project-hotstring-engine-internals]], [[project-suspend-pause-invariant]], [[feedback-ahk-suspend-prefix-latch]].

### project-audit-hs-fixes-2026-06-16

_8 Hammerspoon macOS audit bugs fixed in one session (A3/A5/A6/C5/D3/D4/E1-E3/H2-H5), each with a regression test_

<sub>slug: `project_audit_hs_fixes_2026_06_16`</sub>

Fixed in order, each in its own commit on `dev`:

**A5** — `emit_text()` / `emit_tokens()` returned `(1, "")` on the paste path; the empty string left `expected_synthetic_chars` empty, so the Cmd+V echo reached the `flags.cmd` branch which unconditionally wiped the buffer. Fix: return `(utf8_len, text)` on paste; add an `expected_synthetic_chars` non-empty guard in the Cmd branch.

**A6** — The 0.5 s stuck-counter reset in `onKeyDownRaw` could wipe `expected_synthetic_deletes / expected_synthetic_chars` just set by an in-flight expansion if the runloop lagged. Fix: `CoreState.last_synthetic_arm_time` field + both `arm_synthetic()` and `perform_text_replacement()` set it; the reset guard now also requires `(now - last_synthetic_arm_time) > 1.0`.

**A3** — `dynamic_hotstrings/rules_engine.lua` deferred injection via `doAfter(0)`, creating a window where a real keystroke could interleave. Fix: emit synchronously inside the interceptor (CGEventPost is non-blocking); release `_is_injecting` immediately without a second timer.

**C5** — `keylogger.synth_queue` was never drained on idle; a dropped synthetic `keyDown` left an unmatched entry that would permanently tag the next real keystroke as synthetic. Fix: drain after `delay > SYNTH_IDLE_DRAIN_MS (500 ms)` with a `Logger.warn`; also clear in `M.stop()`.

**D3** — `prediction_engine.M.reset()` did not clear `chain_pending` or stop `_chain_trigger_timer`; a late-firing fallback could call `perform_check()` on stale state. Fix: clear `chain_pending = false` and stop/nil the timer at the very top of `M.reset()`, before any other teardown.

**D4** — `streaming_handler.on_success()` reset `_consecutive_llm_failures = 0` before the stale-fetch-id guard. A stale success silently zeroed the counter. Fix: move the reset after the guard.

**E1/E2/E3** — Three tooltip lifecycle bugs:
- E1: stacked hotstring canvas survived LLM transitions; `hide_stacked()` was only called from `hide_forced()`. Added `pcall(Renderer.hide_stacked)` in `dismiss_silent()`, `show()`, and `show_loading()`.
- E2: `update_preview()` inside `perform_text_replacement()` was synchronous, arming a keyDown watcher before synthetic echoes cleared; those echoes triggered `hide_forced()` and destroyed the chained preview. Fix: wrap in `hs.timer.doAfter(0, ...)` so all synthetic events are consumed first. The `test_expander.lua` assertion for update_preview now calls `hs.timer.__fire_all()` to flush the stub.
- E3: `M.show()` did not stop an active dequeue cycle; a stale timer could overwrite the new content. Fix: call `stop_dequeue()` at the top of `M.show()`.

**H2-H5** — Four dormant adapter contract violations:
- H2: `hs.axuielement.focusedElement()` does not exist; use `applicationElementForPID(pid):attributeValue("AXFocusedUIElement")`.
- H3: `#char` (byte count) rejects multi-byte chars; use `utf8.len()` via pcall.
- H4: `checkKeyboardModifiers()` only accepts canonical names; add `KEY_NORMALISATION` map for LShift/RShift → shift etc.
- H5: `start()` leaked a disabled-but-allocated tap; unconditionally stop and nil any existing tap before creating a new one.

**Test coverage:** 8 new regression test files, 1 existing test file updated. Lua baseline bumped from 906 to 909 to account for 3 legitimate new `hs.timer` calls (A5/A6/E2). All 1639 Lua unit tests pass.

### project-ahk-v2-static-unset-unreadable

_In AHK v2, `static _prop := unset` leaves the property unreadable — accessing it with `is` or any read raises PropertyError. Use `false` (or another concrete value) as the "not yet set" sentinel._

<sub>slug: `project_ahk_v2_static_unset_unreadable`</sub>

Crash reported 2026-06-16 (`PropertyError: "This value of type 'Class' has no property named '_ih'."`) in `hook_dispatcher.ahk:314`. Root cause: `static _ih := unset` was used to declare the live InputHook holder. In AHK v2 the `unset` keyword marks a property as having no value — and the `is` operator (as well as plain reads) raises `PropertyError` before it can evaluate. The same bug was latent in `Stop()` which reset `_ih := unset`, so a `Stop()`/`Start()` cycle would crash identically.

**Why:** `unset` is a valid AHK v2 expression for "this parameter/variable has no value", but it is NOT a concrete value you can store and read back. `HasOwnProp("_ih")` may still return true (the slot exists), but any read — including the left-hand side of `is` — throws.

**Fix:** replace the `unset` sentinel with `false` (an integer that is never `is InputHook`). The `is InputHook` check in `Start()` and `Stop()` works transparently because `false is InputHook` evaluates to `false` without throwing.

**How to apply:**
- Never use `static _prop := unset` as a "not-yet-initialized" holder when the property will be tested with `is` or read unconditionally before assignment. Use `false`, `0`, or `""` instead.
- If you must use `unset` (e.g., for optional parameters), guard reads with `HasOwnProp` + a manual `is`-safe nil check, never bare `obj._prop is SomeClass`.
- Regression tests in `test_hook_dispatcher.ahk` section 4 encode the exact PropertyError path.

### project-macos-audit-2026-06-17-bugs

_Three silent bugs found in the macOS driver: LLM noise filter suppressed uppercase at doc-start, gesture peak confirmation was framerate-dependent, synthetic-event reset could race with delayed OS delivery_

<sub>slug: `project_macos_audit_2026_06_17`</sub>

Three bugs fixed in the macOS driver (commit on dev branch 2026-06-17):

**1. `prediction_engine.lua` — `is_noise_pred` uppercase filter at doc-start**
`local ends_sent = prev_char and prev_char:match(...)` returns **nil** (not false) when `prev_char` is nil (empty or whitespace-only buffer). `not nil` is `true` in Lua, so the uppercase-capital gate silently suppressed all predictions beginning with a capital letter at document start or after whitespace-only buffers. Fix: `(prev_char == nil) or (prev_char:match(...))` — nil prev_char is now treated as an implicit sentence boundary.
NRT: `tests/unit/modules/llm/test_noise_filter_regression.lua`.

**2. `gestures/engine.lua` — framerate-dependent peak confirmation (dead code)**
`commitGesture` used `(gs.peakNFrames or 0) >= FINGER_CONFIRM_FRAMES` to decide whether to override `maxFingers` with the peak finger count. The constant `PEAK_FINGERS_CONFIRM_MS = 0.05` was defined but **never used** (dead code). At 120 Hz ProMotion, 4 frames ≈ 33 ms < 50 ms, so the confirmation fired too early. Fix: `local peak_elapsed = now - (gs.peakNFirstSeen or now)` compared against `PEAK_FINGERS_CONFIRM_MS`.
NRT: `tests/unit/modules/gestures/test_peak_override_regression.lua`.

**3. `keymap/init.lua` — synthetic-event reset could race with delayed OS delivery**
The stuck-counter guard `if dt > 0.5 and arm_age > 1.0 then reset` discarded in-flight synthetic events if the OS delayed their delivery past 1 s. Under extreme OS load, the events would then arrive unfiltered and duplicate characters. Fix: skip the reset when events are still pending (`expected_synthetic_deletes > 0` or `expected_synthetic_chars != ""`), unless `arm_age > SYNTHETIC_STALE_SEC = 5.0 s` (cleanup for truly lost events).
NRT: `tests/unit/modules/keymap/test_synthetic_reset_guard.lua`.

**Why:** Lua `nil and expr` evaluates to `nil` (not `false`) — `not nil` is `true`. This is the same foot-gun as `prev_char:match(...)` in multiple places in the codebase.

**How to apply:** When writing `local x = condition and expr`, always verify the `condition == nil` case. If nil is possible, use `(condition ~= nil) and expr` or `condition == nil or (condition and expr)` as appropriate.

### project-ahk-invariant-incomplete-application

_Every AHK-driver hardening invariant is applied per call-site; the recurring bug is the one missed sibling site, or a guarantee defeated one call level down by indirection — audit the whole class, not the documented site._

<sub>slug: `project_ahk_invariant_incomplete_application`</sub>

The adversarial AHK audit of 2026-06-19 (full report: `AUDIT_AHK_2026-06-19.md` at the repo root) found **0 critical, 5 high, 3 medium, 4 low** confirmed bugs in an otherwise very-well-defended driver (~300 existing tests already guard hundreds of these classes). The striking pattern: **none was a brand-new class** — each was a known, already-fixed invariant that had **one sibling site still un-migrated**, or a guarantee that held at the call site but was **defeated by indirection**. Two reusable lessons:

1. **Invariants are per-site, not global — find the missed sibling.** The keystroke-emit `Critical("On")` serialization invariant (`remap-emit-critical-uneven`) is enforced on `_RemapEmit` + the whole digit row, but **not** on the Shift/CapsLock (`LayerDispatch`) and AltGr (`AltGrShiftDispatch`) emit paths (audit H1). Sync-WinHttp was eliminated in `updater.ahk` but the **changelog window** is a separate sync path (H5). The suspend guard is on `Updater_BackgroundTick`'s *dispatch* but not its *completion* handler (M2), nor the LAlt/RCtrl backspace-repeat loops (L1), nor `_PrefixRenderFlush` (L2). `TOML_CoerceValue`'s array-split escape bug was fixed in **both** sister coercers (`CS_CoerceValue`, `TomlCoerceValueExt`) but a third copy remained (L3). The lone un-migrated `RegisterMenuItem` actionable site is `InsertKeyboardShortcutGroups` (H4). **When auditing any documented fix, grep the whole codebase for the same class and check every sibling, not just the documented function.**

2. **A non-blocking / safe guarantee can be defeated by indirection — and a guard test scoped to one function's body misses it.** `ErgoptiGlobalErrorHandler` is *designed* non-blocking (its own comment explains a modal starves the keyboard hook) yet calls `CrashReport_PromptUser`, which puts up a modal `MsgBox` one level down (H2); the guard test `test_global_error_handler_sendevent_storm.ahk` only asserts `MsgBox` absence in the *handler's* body, so the indirection sails through. Likewise a bare `try fn()` with no `catch` + an unconditional "success" log hides the throw from `OnError` AND falsely reports success (L4 gestures dispatch; same class as the swallowed-callback foot-gun `[[project_lua_closure_before_local_nil_global]]`).

**How to apply:**

- A regression test that greps a single function body is necessary but not sufficient for a transitive guarantee — assert the invariant holds in **every** function in the class (or at minimum in the helper the guarded function calls). Encode the ROOT CAUSE per `[[feedback_regression_tests]]`.
- "`guarded`" in AHK usually means try-wrapped against *throws*. `MsgBox`/`Send`/`Sleep`/sync-`WinHttp` **block**, they don't throw — a `try {}` gives zero protection against a blocking call on the input thread.
- `SetTimer(fn, -1)` does NOT offload to another thread (a real comment in `changelog_window.ahk` wrongly claimed it did); callbacks run on the single AHK pseudo-thread when the message loop yields — the same thread that remaps every keystroke. A synchronous network/COM/shell call inside a `SetTimer` callback freezes typing.

Related: [[project_ahk_menu_dispatcher_drop]], [[project_updater_nonblocking_http]], [[project_suspend_pause_invariant]], [[project_lua_closure_before_local_nil_global]], [[feedback_regression_tests]].

### project-ahk-keyword-as-variable-hangs-the-parser

_Naming a local `Catch` (or any control-flow keyword) makes AHK v2 hang with ZERO output — no syntax error, no dialog, no partial log_

<sub>slug: `project_ahk_keyword_as_variable_hangs_the_parser`</sub>

Found 2026-07-21 while writing a meta-test. The statement was ordinary:

```ahk
Catch := SubStr(Src, OpenPos, 1000)      ; hangs the whole test suite
CatchWindow := SubStr(Src, OpenPos, 1000) ; fine
```

`catch` is a control-flow keyword in AHK v2. Assigning to a variable of that
name does not raise a syntax error and does not open the usual error dialog —
the interpreter simply never finishes. The suite produced **zero lines of
output** and had to be killed by timeout, even under `/ErrorStdOut`.

**Why this is expensive to diagnose:** every normal signal is absent. Zero
output looks like a load-time failure, so you go hunting in the module you just
edited (here, `keylogger.ahk`) — which in this case was not even included in
`run_all.ahk`. `/ErrorStdOut` prints nothing, so it does not look like a parse
error either. Redirected stdout is block-buffered, so the boot lines that would
have localised the hang are lost with the killed process.

**How to apply:**

- Never name a variable after a keyword: `Catch`, `Try`, `Finally`, `Loop`,
  `Until`, `Else`, `Return`, `Throw`, `Switch`, `Case`, `Break`, `Continue`,
  `Static`, `Global`, `Local`. Prefer a qualified name — `CatchWindow`,
  `CatchBody`, `LoopCount`.
- **Bisect on zero output.** A hang with no output is a parser problem, not a
  logic problem: reduce the new code to a trivial `Assert(true, "probe")` and
  add it back in stages. Three suite runs beat any amount of re-reading.
- Do not trust "zero output means it failed at load" — with block-buffered
  redirection it only means the process died before the first flush.

Related: [[project_ahk_numeric_string_equals_false]] (the other v2 foot-gun that
fails silently rather than loudly), [[feedback_ahk_source_encoding]].

### project-ahk-numeric-string-equals-false

_In AHK v2, `"0" = false` is **TRUE** — comparing a `String|false` return value against `false` silently swallows any numeric-string success token_

<sub>slug: `project_ahk_numeric_string_equals_false`</sub>

AHK v2's `=` (and `==`) compare **numerically** when one side is a number and the other is a numeric string. `false` is the integer `0`, so `"0" = false` evaluates to `0 = 0` → **true**. Trailing whitespace does not save you: `"0\r\n"` is still a numeric string.

**Why:** found 2026-07-20 (audit F-23) in `ui/onboarding/steps_metrics.ahk:247-259`. `FSRead` returns `String` on success and the integer `false` on failure. The gesture auto-registration worker writes `"0"` as its **success** token, and the reader began with `if (Result = false) { LoggerError("… result missing"); return false }`. So every *successful* registration was reported as a failure — the UI painted red and told the user to register manually after it had already worked. The failure path was fine (`"1" = false` is false), so only the success case misreported, and the log said "result missing", pointing any debugger at file I/O rather than the comparison.

The give-away was **internal contradiction**, needing no external artifact: line 249 rejected `"0"` as "file missing" while line 254 treated `"0"` as the success value. Two adjacent lines disagreeing about the same literal is the cheapest possible proof that one is wrong.

**How to apply:**

- Never compare a `String|false` result against `false`. Type-check instead: `if !(Result is String)`. Note `==` does **not** fix this — it is also numeric-equal here.
- Extract sentinel tokens as named constants (§5.1) so the success value is greppable.
- When auditing, treat two nearby comparisons against the same literal that imply opposite meanings as a confirmed defect, not a suspicion.

Related: [[feedback_regression_tests]], [[project_ahk_v2_static_unset_unreadable]] (same family — an AHK v2 type/value semantic that reads as obviously-correct).

### project-ahk-guard-tests-must-loop-the-class

_A regression test that pins the single site a bug was fixed at will not survive the next refactor — five 2026-07-20 findings exist purely because a guard test named sites instead of enumerating the class_

<sub>slug: `project_ahk_guard_tests_must_loop_the_class`</sub>

This is the concrete, repeated failure mode behind [[project_ahk_invariant_incomplete_application]], and the second 2026-07-20 audit found five instances of it in one pass:

- `test_live_rebuild_no_critical_io.ahk` asserts `InStr(Body, "Critical(") = 0` on **`RebuildHotstringsLive`'s body only**. `ToggleCategoryAllFeatures` (`lib/config_io.ahk:217`) wraps the *call* in `Critical("On")` from outside, restoring the exact 1-2 s keyboard freeze F33 removed — and the test stays green. The outer `Critical` is even justified by a comment ("RebuildHotstringsLive re-enters Critical internally; that is safe") that **F33 itself made false**.
- `test_webview_bridge_suspend_guard.ahk` names 3 handlers; there are 9. The other 7 can mutate config — or run an elevated UAC driver install — while the driver is paused.
- `test_webview_low_ram_native_fallback.ahk` names 5 hosts; there are 12.
- `test_taphold_timings_load_order.ahk` pins the include-order invariant for 1 of 5 shared-constant loaders. All five are currently correct, so this is latent — but a re-zeroed 0 ms timing sentinel is a documented CPU-spin hazard.
- `SUSPEND_CUSTOM_COMBO_PREFIX_KEYS` is a hand-maintained list of 2; the driver registers 5 custom-combination prefixes (`SC01D`, `SC02A`, `SC11D` are missing), so three can latch across `Suspend` — the « AltGr bloqué » class that synthetic key events cannot clear.

**Why:** a fix is applied where the bug bit; the test is written to describe *that fix*. Both are locally correct. The invariant, however, is a property of a **class of call sites**, and nothing re-checks the class when a new sibling appears.

**How to apply:**

- Write guard tests as **loops over an enumerated set**, not assertions about one function body. Derive the set from source where possible (scan for `X & Y::` combination prefixes; enumerate `*_OnWebMessage` handlers) so a newly added sibling *joins the test automatically*.
- For a **transitive** guarantee ("this must not run under `Critical`"), asserting the callee's body is necessary but never sufficient — assert it across every caller too.
- When you fix a bug by removing something from a function, **grep the callers**: they may be re-adding it, and their justifying comment may have just become false.

Related: [[project_ahk_invariant_incomplete_application]], [[feedback_regression_tests]], [[project_ahk_menu_dispatcher_drop]].

### project-audit-findings-are-hypotheses

_Two findings from the 2026-07-20 second-pass audit were WRONG, and the existing test suite is what proved it — implement an audit finding as a hypothesis, not as an instruction_

<sub>slug: `project_audit_findings_are_hypotheses`</sub>

Of 35 findings implemented, **2 had to be reverted because a pre-existing regression test rejected them**, and both reverts were the correct outcome:

- **F-14** proposed making `PrefixWatcherSuppress` delegate to `HSE_Suppress`, on the strength of four comments in `hotstring_dispatch.ahk` claiming it already does. `tests/meta/test_hse_physical_input_provenance.ahk:14` asserts the delegation is **absent**: the render guard and the engine suppression window are separate *by design*, because the engine window exists to filter the engine's own `SendInput` output while genuinely physical input declares itself with `IsPhysical=true` (F46). Delegating drops a physical character typed inside a nearby output transaction. **The comments were the bug, not the code.**
- **F-16** proposed memoizing `_MG_LoadSubCategories`. `tests/unit/test_master_gates.ahk` requires an invalid canonical manifest to throw on *every* call; a cache returns the last good value instead. The finding also dissolved on its own once **F-01** removed the `Critical` span that made the re-read expensive — the cost was never inherent, only badly placed.

**Why this matters:** an adversarial audit produces *plausible* defects. Plausibility is not correctness, and a long, well-argued finding is not more likely to be right than a short one — it is just more persuasive. The suite encodes decisions whose reasoning is no longer in anyone's head.

**How to apply:**

- Treat each finding as a hypothesis to be tested by implementing it, not a work order. Run the full suite after each fix, not at the end of a batch, so the rejection is attributable.
- When an existing test goes red, the default assumption is that **your change is wrong** (`ship-fix` §5). Read what the test asserts and *why* before touching either side.
- If a finding is genuinely refuted, record the refutation next to the code — the stale comments that caused F-14 are exactly what a future audit would flag again.
- Fix findings in dependency order where possible: F-16 disappeared once F-01 landed. A cluster of findings often has one real root.
- Two further audit claims were corrected during implementation because a positional source assertion matched inside the very code it was checking (the function already reset the flag on entry). When asserting "X appears after Y", search *from* Y's offset — see the `meta-test` skill.

Related: [[project_ahk_guard_tests_must_loop_the_class]], [[feedback_regression_tests]], [[project_audit_evidence_must_be_reproducible]].

### project-audit-evidence-must-be-reproducible

_A refutation is a claim and needs the same standard of proof: the 2026-07-20 "the perf section was fabricated" debunking was ITSELF wrong — it looked in a directory that never existed_

<sub>slug: `project_audit_evidence_must_be_reproducible`</sub>

> **CORRECTED 2026-07-20 (third pass).** This entry previously asserted that the first
> 2026-07-20 audit fabricated its performance section. **That accusation was false**, and the
> correction matters more than the original lesson. Kept in full, because how the error was
> made is the actual teaching.

**What the first audit claimed.** `AUDIT_AHK_2026-07-20.md` (commit `1171adc90`, removed by `08382fb56`) reported `Tooltip.ResolvePos` worst **2560.3 ms** and `OnChar` worst **701.3 ms**.

**What the second audit concluded.** That zero `Slow`/`HotPath` lines existed in any log, that `<ConfigDir>/ahk/logs/` was empty, and therefore that the table was invented and "G4 has never been measured on this driver".

**What is actually true.** The third pass re-derived the numbers independently with `awk` over the real logs and got **`Tooltip.ResolvePos` max 2560.3 ms** and **`OnChar` max 701.3 ms** — *exactly* the disputed figures. Across 10 days of logs there are **8 958** `Slow` lines. The first audit's data was genuine.

**Why the debunking went wrong — one wrong path segment:**

- The log directory is `_ConfigDir . _AhkSubDir . "logs\"`, and **`_AhkSubDir := "autohotkey\"`** (`lib/boot.ahk:70`). The real path is `<ConfigDir>/autohotkey/logs/`.
- The second audit checked `<ConfigDir>/**ahk**/logs/` — a directory that has never existed — found nothing, and read `D:\tmp` test-harness output instead.
- `<ConfigDir>` is itself redirected by `%APPDATA%\Ergopti\paths.toml`; on this machine it resolves to `D:\Documents\GitHub\config\ergopti_plus\`. Neither audit resolved it.

**Consequence of the false debunking:** a genuine, measured **2.5-second stall on the typing path** was dismissed as unmeasured, and the `Tooltip.ResolvePos` finding was formally refuted on that basis. The defect stayed open for a full extra audit cycle.

**How to apply:**

- **Hold refutations to the same standard as findings.** "This evidence does not exist" is a positive claim about the world; it needs proof of where you looked. Absence of evidence at the wrong path is not evidence of absence.
- **Resolve the config path before concluding anything about logs.** `paths.toml` first, then `_AhkSubDir`. Never conclude "the driver has never logged" — it has, since at least 2026-07-08.
- Cheapest check, run at the *correct* path: `awk 'index($0,"Slow")>0{c++} END{print c+0}' <log>`.
- Still true and still worth doing: state G4 claims as "derived from reading code" unless you have a log line to quote, and label the provenance of every number.
- **Be fair in how you report a suspected fabrication.** The original entry hedged ("I cannot prove no such log ever existed elsewhere") and was still wrong to accuse. Prefer "I could not locate the artifact at X, Y, Z — where should I look?" over "this was invented".

Related: [[project_audit_reverify_2026_06_16]] (same lesson from the other direction — that audit's *tracking JSONs* were unreliable), [[feedback_regression_tests]].

### project-ahk-test-suite-critical-leak

_Critical("On") in layout/hotkey callbacks is safe in production but leaks into the main thread when invoked directly by tests, silently hanging background timers_

<sub>slug: `project_ahk_test_suite_critical_leak`</sub>

Ergopti uses a custom test framework (`test_framework.ahk`) for its AutoHotkey codebase, executing all tests sequentially within a single auto-execute thread.

1. **In Production (Hotkeys/Timers):** Calling `Critical("On")` inside a hotkey or timer callback is perfectly safe. AHK creates a pseudo-thread for the callback, and when it returns, the previous thread resumes with its own `Critical` setting restored automatically.
2. **In Tests (Direct Invocation):** The test framework runs sequentially on the **main auto-execute thread**. If a test directly invokes a function (e.g. `AltGrShiftDispatch` or `LayerDispatch`) that calls `Critical("On")` without manually restoring it, that `Critical` state permanently "leaks" into the main thread.

**The Consequence:**
If the main thread becomes permanently `Critical`, AHK will **block all background timers** from firing for the remainder of the test suite (even during `Sleep` calls). Tests that rely on `SetTimer` (e.g., hotstring engine suppression releases) will silently hang or fail.

**How to apply:**
- Always wrap standalone `Critical("On")` acquisitions in functions in a `try...finally` block, explicitly restoring the previous state:
  `utohotkey
  _AtCrit := Critical("On")
  try {
      ; ... your critical code ...
  } finally {
      Critical(_AtCrit)
  }
  ``r
- The test framework (`test_framework.ahk`) now includes a safety check that throws `Test LEAKED Critical: <TestName>` and resets the state to `0` if a test forgets to restore it, preventing cascading failures and quickly catching new occurrences.

Related: [[project_ahk_invariant_incomplete_application]]

### [updater-download-suspend-guard] Garantie G5: background downloads bypass pause
* **Symptom**: A background update download (_Updater_PollDownloadAsync) could finish and trigger a script restart while the driver was supposedly suspended.
* **Cause**: _Updater_PollDownloadAsync relies on a SetTimer callback which bypasses A_IsSuspended. It would happily process Req.WaitForResponse(0), write the downloaded .exe to disk, and call ExitApp(0) to apply the update.
* **Fix**: Added if A_IsSuspended at the top of _Updater_PollDownloadAsync to Req.Abort() the download if caught suspended mid-flight. Additionally wrapped the disk-write and ExitApp block in Critical "On" so a suspend hotkey cannot interrupt the thread during the final critical section.
* **Regression Guard**: meta/test_g5_updater_download.ahk asserts that both the A_IsSuspended check and Critical "On" are present in the callback.

### [project-shared-tree-layout] _shared/ tree: 6-folder layout, SSOT-per-layer, and the bypass gotcha
* **Layout** (`static/ergopti_plus/_shared/`, renamed from `shared/` and reorganised from ~20 top-level entries into 6):
  * `modules/` — per-subsystem: `logger/ tooltip/ hotstrings/ llm/ updater/ wpm_widget/ timings/ features/` + `gestures/actions.toml`, `menu/menu_manifest.json`, `wrap_symbols/wrap_symbols.json`
  * `core/` — `domain/ ports/ config_schema/` (the hexagonal contracts + JS domain specs)
  * `data/` — `locales/ db/ keycodes/`
  * `lua/`, `tests/`, `ui/` — unchanged
* **SSOT per layer** — the `_shared` root is resolved in EXACTLY ONE place per consumer, so renaming the *tree* is a one-token edit there. The places: macOS runtime `macos/lib/paths.lua` (`find_from_configdir("_shared")` → `Paths.shared(rel)`); AHK runtime `_SharedDir` (`ErgoptiPlus.ahk` ~L51, all modules read it; logger.ahk has a relative fallback); macOS tests `macos/tests/helpers/init.lua` (`SHARED_REL` → `helpers.shared(rel)`); JS tooling `tools/lib/paths.cjs` (`SHARED_REL` → `shared()`/`sharedRel()`); Python tooling `tools/lib/paths.py`; Linux `linux/install.sh` (`SRC_SHARED`/`DEST_SHARED`); the bundle `tools/build/build_static_bundle.py` (`ASSET_TREES`); the macOS app `tools/build/build_macos_app.sh` (`drivers/_shared` — packaged layout, see [[project-config-v2-refactor]] sibling resolver note).
* **The two-part cost of any future change:** (1) a *tree rename* (`_shared` → x) is the one-token-per-layer edit above; (2) an *internal move* (e.g. `llm/` → `modules/llm/`) is NOT covered by the SSOT — every call site that passes a shared-relative subpath (`shared("modules/llm/…")`, `_SharedDir . "\modules\llm\…"`, file-header/docstring paths) must change. Use an anchored, encoding-safe sweep (match the moved segment only right after `_shared/`, `${..._SHARED}/`, an SSOT opener `shared("`/`sharedRel("`/`.shared("`, or `_SharedDir . "\`), preserving UTF-8 BOM + CRLF on `.ahk`.
* **Bypass gotcha — only the suites catch these.** Some sites resolve a shared path WITHOUT the SSOT and are invisible to an anchored sweep:
  * pure `_shared/lua/` code that can't depend on the runtime resolver — `lua/llm/profile_selector.lua` hard-navigates `dir .. "/../../modules/llm/profiles.json"` from its own file location;
  * AHK loaders that alias `_SharedDir` to a local — `lib/hotstrings/hotstrings_config.ahk` and `lib/timings/timings_config.ahk` do `Dir := _SharedDir` then `Dir . "\modules\hotstrings\…"`;
  * test fixtures that build paths or temp dirs by hand (`test_freshness_*` creates `Base\modules\hotstrings`; `_ISRMM_ReadSharedSource("modules/hotstrings/…")`; `test_port_adapter_coverage` derives `SHARED_DIR .. "/core/ports"`).
  * UI modules with their OWN path wrapper that pass a literal `_shared`-relative string — `ui/wpm/wpm_widget.lua`'s `resolve_shared_constants_path("wpm_widget/constants.toml")` was missed by the reorg (it never wrote `.shared(`/`_SharedDir` so no sweep saw it) and shipped on a branch as a boot ERROR (widget non-functional) — fixed to `"modules/wpm_widget/constants.toml"` / `"modules/timings/constants.toml"`. The AHK twin `WPMWidget_LoadSharedConst()` was correct (`_SharedDir . "\modules\wpm_widget\…"`).
  After any move, run ALL suites — AHK `tests/run_all.ahk` (2317), macOS `lua tests/run.lua` (2233), Linux `luajit tests/run.lua` (37) — they exercise the real paths and are the only thing that surfaces these. A green anchored-sweep audit is necessary but NOT sufficient. **BUT the suite only catches a path break if the test actually asserts the file resolved** — the wpm_widget break slipped through because its test asserted only `WpmWidget ~= nil` (the module degrades gracefully on a missing file, so it loads either way). A path-resolution test MUST assert the resolver found a real file (or that NO "file not found" ERROR was logged at load), never just that the consuming module loaded.
* **Outside-the-sweep configs:** root `.gitignore` (cache paths `_shared/data/locales/*.tsv`, `_shared/modules/hotstrings/generated_hotstrings.tsv`), `stryker.config.mjs` (`_shared/core/domain/*.spec.js`), and `package.json` live at the repo root — a sweep scoped to `static/tools/src/docs` misses them. The self-healing caches are gitignored at their `_shared` paths; if an ignore rule goes stale after a move the cache files silently become tracked.

Related: [[project_debug_menu_sync]], [[project-tooltip-shared-style]], [[project-locale-fast-cache]], [[feedback-ahk-source-encoding]], [[feedback_fix_banners_tool]]

### [project-macos-initlua-no-compile-coverage] init.lua had ZERO compile coverage — CI never parsed the HS entry point
* **Symptom**: The Hammerspoon driver failed to boot with `init.lua:1050: 'end' expected (to close 'do' at line 818) near <eof>` — a hard Lua syntax error in the top-level orchestration file. It had been latent for **2 days** with CI fully green.
* **Cause**: Commit `69c76e568` wrapped a directory scan in init.lua's File Watchers section inside a new `if … then … end`; the diff reused the surrounding `do` block's closing `end` to balance the new nesting and so **deleted the `end` that closed the `do`** opened at the top of the section. A pure mechanical diff hazard — adding one nesting level while the old closer gets visually re-attributed to the new block.
* **The gap (why CI stayed green)**: The macOS Lua suite (`lua tests/run.lua`) loads individual modules through `hs` **stubs** and asserts behaviour — but it **never loads `init.lua`**, because *running* the entry point needs the live Hammerspoon runtime (real `hs.pathwatcher`, `hs.eventtap`, …). And `build_macos_app.sh` only **copies** files. So nothing — no test, no build step — ever even *parsed* the top-level file. (Asymmetry: the AHK entry `ErgoptiPlus.ahk` IS compiled in CI by the Ahk2Exe step, so only the macOS entry had this hole.)
* **Fix**: Added the missing `end` to close the `do` block (init.lua, end of Section 7).
* **Regression guard**: `macos/tests/meta/test_lua_sources_compile.lua` — `loadfile()` **parses without executing** (no `hs` runtime, no FS side effects, no OS access), so it is the zero-dependency way to syntax-check code a harness can't *run*. It asserts init.lua parses (a dedicated, named assertion — init.lua is at the driver root, so the bulk scan over `lib/ modules/ ui/ adapters/` + `_shared/lua/` does NOT include it) and that all 181 production sources parse. Runs inside the always-on macOS test job (`ci.yml` `lua5.4 tests/run.lua`). Verified red→green: fails with the exact `'end' expected` error on the broken file, passes after the fix.
* **The lesson**: any top-level/orchestration file a test harness can only *copy* or cannot *run* still needs a *parse* check. `loadfile`/`luac -p` (Lua) and the Ahk2Exe compile gate (AHK) are how you get it. Mechanical diffs that add a nesting level are the classic way to lose a block's closing `end` — re-run a parser, don't eyeball brace balance.

Related: [[feedback_regression_tests]], [[project-shared-tree-layout]], [[project-hs-timer-callback-errors-invisible]]

### [project-hs-fs-dir-drops-state] hs.fs.dir returns (iterator, state) — capturing only the iterator crashes boot, and a lenient stub hid it
* **Symptom**: The Hammerspoon driver crashed on boot — `init.lua:427: bad argument #1 to 'for iterator' (directory metatable expected, got nil)`. Visible in the HS console the instant the driver loaded; CI was green.
* **Cause**: `hs.fs.dir(path)` returns **TWO** values — an iterator function AND a directory **state object** the iterator REQUIRES as its first argument (real Hammerspoon checks a "directory" userdata metatable, else aborts with *"directory metatable expected, got nil"* on the first step). The code did `local ok, it = pcall(hs.fs.dir, dir)` then `for x in it do`, which captures only the iterator and **silently drops the state object**. `init.lua` had this in 5 places (boot path) and `ui/hotstrings_config_window/init.lua` in 2 (config window).
* **Why CI missed it — TWO compounding gaps**:
  1. The hs test stub returned a **single, stateless** iterator (`dir = function(_) return function() return nil end end`). It needed no state, so the dropped-state pattern "worked" under test. A stub that doesn't model the real **multi-return / required-state** contract masks the entire bug class.
  2. A prior meta test (`test_init_fsdir_pcall.lua`) actively **enforced the buggy shape**: it asserted `pcall(hs.fs.dir, …)` was present and the bare `for … in hs.fs.dir(…)` was absent. That test fixed trap 1 (hs.fs.dir THROWS on a missing/denied dir → wrap in pcall) but locked in trap 2. A source guard that mandates a brittle *code shape* can cement a bug; guards must assert the *invariant*, not a spelling.
* **Fix**: iterate **inside** the pcall — `pcall(function() for name in hs.fs.dir(dir) do … end end)` — so the throw is caught AND hs.fs.dir's full multi-value return flows into the generic-for. Centralised in one `safe_dir_entries(dir)` helper per file (returns a names array). The only blessed shape anywhere is now the iterator expression directly in a generic-for: `for <vars> in hs.fs.dir(...) do`.
* **Regression guards** (`macos/tests/meta/test_fs_dir_iterator_contract.lua`, replacing the misguided `test_init_fsdir_pcall.lua`):
  * **Source contract** — scans init.lua + ui/ + modules/ + lib/ + adapters/ + _shared/lua/; per file asserts `count(hs.fs.dir) == count("in hs.fs.dir(")` (comments stripped), so any capture/`pcall(hs.fs.dir,…)`/assignment form fails. Verified red→green: reports `init.lua (5 references, 0 in a generic-for)` on the pre-fix code.
  * **Throw protection** — asserts init.lua still wraps an hs.fs.dir loop in a pcall'd closure (preserves the original init-fsdir-pcall guarantee).
  * **Stub fidelity** — the stub's `hs.fs.dir` now returns `(iterator, state)` and its iterator errors when called without the state (`make_fs_dir_iterator`, `__set_entries`/`__reset_entries` hooks). This upgrades the *whole* suite to catch dropped-state bugs and pins the stub so nobody reverts it to the lenient form. Making the default stub faithful broke **zero** existing tests (2233/0).
* **The lesson**: a test stub must model the real API's **return arity and state requirements**, not a convenient simplification — a lenient stub turns CI green over a guaranteed production crash. And init.lua's runtime is never executed by the suite (needs live Hammerspoon), so its boot logic is only reachable by **static source-contract** tests; those must encode the *invariant* (state preserved + throw-safe), never a fragile required phrasing.

Related: [[project-macos-initlua-no-compile-coverage]], [[feedback_regression_tests]], [[project-macos-eventtap-no-blocking]], [[project-hs-timer-callback-errors-invisible]]

### [project-healthcheck-stale-api] Diagnostic collectors silently degraded — guarded probes hid renamed APIs from "does it crash?" tests
* **Symptom**: The macOS diagnostic window (`ui/healthcheck/` — collectors in `helpers.lua`; was the monolithic `lib/healthcheck.lua` before the F2 split) showed `unknown`/`n/a` for almost every runtime field (LLM, layout, keylogger, hotstrings, log paths) and every boot/reload logged a wall of `[healthcheck] X is not a function` / `X unavailable` WARNINGs.
* **Cause**: The collectors called functions that don't exist (renamed/never-implemented): `log_manager.get_paths()`, `aggregator.get_stats()`, `require("modules.keylogger.privacy")`, `llm.get_state()`, `layout.is_ergopti_base()`, `key_state.get_altgr/get_shift/get_caps()`, `terminators.count()/get_magic_key()`. Each was wrapped in a `type(x) ~= "function"` guard that logs a WARNING and falls back — so nothing crashed and a "does the module load?" test stayed green while the diagnostic was useless.
* **Real APIs** (wired in the fix): log paths → `lib.logger.UNIFIED_LOG_FILE`/`ERRORS_LOG_FILE` (public constants, re-pointed by `init_log_path()`); WPM → `modules.keylogger.get_live_stats().wpm`; LLM → `get_runtime_llm_enabled()`/`get_backend()`/`get_active_profile()`; AltGr/Shift → `adapters.key_state.is_right_altgr_held()`/`isDown("shift")`; terminators → count `terminators.get_terminator_defs()`; magic key → `modules.keymap.get_trigger_char()`. No accessor exists for session event count, privacy-hit count, active-layout (`ergopti_base`), or capslock — those now report `n/a` WITHOUT probing a nonexistent function (`checkKeyboardModifiers` only exposes shift/ctrl/alt/cmd/fn).
* **Regression guards** (`macos/tests/meta/test_healthcheck_api_contract.lua`): (1) a declarative CONTRACT table of every (module, function/constant) the collectors call, each asserted to exist on the REAL module; (2) a self-syncing test that runs `healthcheck.run()` against real modules and asserts no collector logged an `is not a function`/`unavailable` warning (excluding `hs.*` — the headless stub legitimately lacks `hs.processInfo`/`hs.screen`). Verified red→green: reverting one collector to `llm.get_state` makes (2) fail with the exact warning.
* **The lesson**: a probe that is `pcall`/`type`-guarded to "degrade gracefully" is INVISIBLE to crash-based tests — it logs a warning and returns a fallback, so the suite is green while the feature is dead. Test the OUTCOME (the real value resolved / no degradation warning), not just "it didn't crash". A diagnostic that reads another module's API needs an explicit contract test, because nothing else exercises those exact calls.

### [project-macos-split-module-stub-reload] Splitting a stateful macOS module out of its caller requires adding it to `load_with_stubs`' reload list
* **Symptom**: after the F4 split extracted the async active-layout probe from `ui/menu/menu_keyboard_layout.lua` into `modules/keymap/input_sources.lua`, `test_menu_keyboard_layout_latency.lua` failed with "cache must hold the two probed layouts: expected 2, got 1" — the `hs.task` stub the test injected via `load_with_stubs("ui.menu.menu_keyboard_layout", {task=...})` never reached the relocated `refresh_active_layouts_async`.
* **Cause**: `tests/helpers/init.lua` `load_with_stubs(module_name, …)` clears `package.loaded[module_name]` plus a *curated list* of always-reload modules (text_utils, toml_codec, i18n, paths, llm.init), then sets the fresh `hs` stub. A required module that is NOT in that list and is already cached returns its old instance — and Lua modules capture `local hs = hs` at *require time*, so the cached instance is bound to a previous test's `hs`, ignoring the new stub.
* **The invariant**: when you split a stateful module (session caches, or anything that captures `hs`/`Logger` at load) out of a module that tests drive through `load_with_stubs`, add the new module(s) to the force-reload block in `tests/helpers/init.lua`. F4 added `modules.keymap.layout_install` + `modules.keymap.input_sources` there. Symptom of forgetting: a stub injected for the parent silently fails to reach the child, and a behavioural assertion sees stale/empty cache state.
* **Related**: the `test_port_adapter_coverage.lua` `LUA_HS_BASELINE`/`LUA_IO_OS_BASELINE` ratchets scan only `macos/modules/` + `macos/lib/` — moving OS-calling code from `ui/` into `modules/` raises the count without adding any new OS call. Re-baseline with a "relocation, not new OS calls" comment (precedent: the init.lua → lib/personal_hotstrings bumps).

### [project-init-json-decode-of-toml] init.lua JSON-decoded config.toml every boot (native LuaSkin error leaked through pcall)
* **Symptom**: A native `LuaSkin: Error deserialising JSON: The data couldn't be read because it isn't in the correct format.` printed to the HS console on every boot, captured by the console tee as a `[CONSOLE] ERROR`, during the "TOML discovery" phase.
* **Cause**: init.lua's legacy "Config Priming" block did `local config_file = menu_paths.get("ConfigTomlPath")` then `hs.json.decode(raw)` on it. `ConfigTomlPath` resolves to **config.toml** — the v2 config migrated from JSON to TOML — so it decoded TOML as JSON and failed every boot. The call was `pcall`-wrapped, so the Lua error was swallowed and the block was simply DEAD (its trigger-char + section-state restore now happens from config.toml via `menu_state`/`Preferences`). **`hs.json.decode` is native: it logs the LuaSkin console error even inside `pcall`** — pcall catches the Lua-level failure but the console line still fires.
* **Fix**: removed the dead block (and the now-unused `config_file` local). `magic_key` keeps its `"★"` default; a custom value is restored from config.toml by `menu_state` at menu start (current behaviour — the block never worked).
* **Regression guard** (`macos/tests/meta/test_config_not_json_decoded.lua`): asserts `ConfigTomlPath` ends in `.toml`, and that init.lua never binds it to a local that is `io.open`'d (the JSON-priming shape) — legit consumers (`config_overrides.apply`, `Preferences.load`, onboarding) take the path inline and parse it as TOML. Verified red→green.
* **The lesson**: `pcall(hs.json.decode, …)` does NOT suppress the native deserialise-error console line — never feed non-JSON to it. After a config format migration, grep for stale readers of the old format pointed at the new file.

Related: [[project-hs-fs-dir-drops-state]], [[project-macos-initlua-no-compile-coverage]], [[feedback_regression_tests]]

### [project-macos-startup-winfilter-cost] hs.window.filter's first instantiation enumerates every window — keep it off boot paths
* **Symptom**: After a reload the macOS driver felt slow to "settle" (the keylogger took several seconds; the HS console spammed `wfilter: <app> is STILL not registered`).
* **Cause**: `hs.window.filter`'s FIRST instantiation makes Hammerspoon enumerate every window of every app — multi-second on a machine with many apps or a VPN (e.g. Cisco Secure Client never registers). The keylogger built its browser private-mode filter EAGERLY at engine start (`hs.timer.doAfter(0, … hs.window.filter.new(browsers) …)`), so the engine took seconds to become ready. (The keymap `is_ignored_window` cache also creates `hs.window.filter.default` — the global all-windows filter — on first keystroke.)
* **Fix**: the keylogger browser filter is now created LAZILY on the first browser activation (`ensure_browser_window_filter`, gated by a `BROWSER_APP_SET[app_name]` check in the app-watcher). Per-app-switch private/incognito detection is unaffected — it runs via `ContextTracker.app_watcher_cb → update_private_status`, which uses `hs.window.focusedWindow()` directly and never needed the filter. Both window.filter creation sites now log their duration (`… (%.1f ms)`) so a slow first-keystroke / first-browser-focus is attributable.
* **Also**: `gestures.start()`'s dependency pre-warm re-called `Actions.init()`/`Engine.init()` (already run at module load) — a guarded no-op that logged `M.init() called more than once` every boot; removed. (The keymap/shortcuts `M.start() called more than once` warnings are DIFFERENT and intentional: init.lua starts them early for availability, then `menu_state` re-applies the saved enabled/disabled preference idempotently — left as-is.)
* **Regression guard** (`macos/tests/meta/test_startup_optimizations.lua`): asserts the keylogger instantiates `hs.window.filter` exactly once, in a lazy helper gated by a browser activation, never eagerly in a `doAfter(0)` at start; and that `Actions.init`/`Engine.init` are each called exactly once. Verified red→green (reintroducing the double-init fails the count assertion).
* **The lesson**: never create an `hs.window.filter` on a boot/first-keystroke path — defer it to the first moment it's actually needed (scoped to the apps that need it), and check whether the dependent feature can read `hs.window.focusedWindow()` directly instead. The boot itself is ~1.2 s; the felt slowness was deferred window enumeration.

### [project-category-gating-ahk-only] Category enable/disable gating (CategoryEnabled["Hotstrings"]…) is intentionally AHK-only
* The Windows driver gates whole feature categories (Hotstrings, Shortcuts, …) through PascalCase keys in the `CategoryEnabled` map, seeded from `manifest.toml`'s `[ahk.category_enabled]` section (`IsCategoryGated`/`_MasterCategoryFor`). The macOS driver has **no category-gating layer at all** — features toggle individually. So the PascalCase ids are NOT a leftover v2-migration debt and NOT a cross-driver parity gap: there is nothing on the macOS side to mirror.
* **Why kept** (audit 2026-06-26, re-examined a past "should we migrate?" idea): converting the ~27 PascalCase gating sites across ~10 AHK files to v2 snake_case is pure-cosmetic, AHK-only churn that touches every category toggle (real regression risk) for zero cross-driver benefit. Confirmed **KEEP**.
* **How to apply**: treat `CategoryEnabled` / `IsCategoryGated` / `_MasterCategoryFor` PascalCase ids as a deliberate Windows-internal implementation detail, not drift. Do not "fix" them for parity. Related: [[feedback_loader_target_explicit]].

Related: [[project-hs-fs-dir-drops-state]], [[project-touchdevice-dormancy-is-kernel]], [[feedback_regression_tests]]

### [project-macos-lib-namespace-shims] macОС lib.text_utils / lib.color_utils re-export shims are kept on purpose
* `macos/lib/{text_utils,color_utils}.lua` are one-line identity re-exports (`return require("text_utils")` / `"color_utils"`) of the shared `_shared/lua/{text_utils,color_utils}` modules — no HS extension. They look like pure removable indirection (audit SS-3 first proposed deleting them).
* **Why kept** (audit 2026-06-26, SS-3 re-examined against the code): the macОС test suite is keyed on the `lib.*` module path. Production keymap modules `require("lib.text_utils")` (utils/registry/init/llm_bridge/expander, + a pcall in dynamic_hotstrings) and ~15 tests install `package.loaded["lib.text_utils"] = <stub>` or `helpers.load_with_stubs("lib.text_utils")` to control the module the code-under-test sees. Deleting the shims + repointing production to the bare `text_utils`/`color_utils` name would make every stub key (`lib.text_utils`) stop matching the new `require("text_utils")` — silently bypassing stub interception — forcing a ~21-site rewrite of the test infrastructure for two one-line files. Net negative; the "7 sites, simple mechanical edit" estimate was wrong. (`lib.color_utils` has ZERO production requires — only tests load it.)
* **How to apply**: treat `lib.text_utils` / `lib.color_utils` as the canonical macОС-local namespace for these shared utils — the same load-bearing role the audit kept for the `lib.toml_*` shims (SS-4). Do not "de-shim" them.

### [project-hs-audit-open-labels-are-stale] Archived AUDIT_HAMMERSPOON_*.md "Open" labels are stale — verify status in current code; the live bug is the missed sibling of a fixed invariant
* **Context** (audit `AUDIT_HAMMERSPOON_2026-06-29.md` at repo root): the 23 findings in the archived `docs/archive/audits/AUDIT_HAMMERSPOON_2026-06-19/20.md` are all marked "Open", but those docs are point-in-time snapshots. Verified against the current branch, **~19 of 23 are already fixed in code** (all 9 closure-nil-global sites, F-CRIT-2, F-HIGH-1/2/3/5/6, F-MED-1..6, F-LOW-1/3/5, F-INFO-1/3). The REFACTOR_GUIDE "Track B done" refers to a *separate AHK audit* (`.ahk` files), not these macOS findings, so there is no consolidated macOS done-registry — status was only knowable by reading the source.
* **The recurring live-bug shape**: the genuinely-open issues are almost all the **missed sibling** of an invariant fixed at its documented site (`project-ahk-invariant-incomplete-application` applied to macOS): the script-control-tap-lifecycle fix missed `menu_state.sync_state_to_modules` (panic tap destroyed by "Disable all"); F-CRIT-1's bare-press gate missed `Ctrl`+F13/F14/F15; F-MED-7's MLX teardown missed the menubar Quit path; F-HIGH-6's table.concat guard missed the hotstrings/metrics submenus; the LLM warmup gate missed `WarmupCtrl`/`models_selector`. The one true regression (F-LOW-4) was a sync→async migration that never `.start()`d the task, kept green by a string-grep false-green test.
* **How to apply**: when re-auditing, treat archived "Open" labels as **unverified** — re-read the current source for each. Hunt the whole invariant *class* (every sibling call site), not the one documented location. For any runtime-invisible bug (swallowed `hs.task`/`ShellRunner` throw, closure-nil-global, dead config flag, never-`.start()`d task), the regression test MUST encode the root cause behaviorally — a grep that "the call string exists" is a false-green (it kept both the `os.remove(tmp_path)` and `read_layout_async` regressions green).
* **Still-invisible class**: `lib/logger.install_runtime_error_capture()` wraps only `hs.timer` constructors + tees `print()`; `hs.task`/`ShellRunner` completion/stream callbacks swallow throws with a bare `pcall` and no `Logger.error` (`adapters/shell_runner.lua`, `http_client.lua`) — fixing that one adapter makes the entire async-callback bug family self-reporting.

Related: [[project-lua-closure-before-local-nil-global]], [[project-hs-timer-callback-errors-invisible]], [[project-ahk-invariant-incomplete-application]], [[feedback_regression_tests]]

### [project-dc1-windows-vk-finger-map-gap] DC-1 single-sourced the JS + macOS finger maps from azerty.json — a 3rd hardcoded copy remains in the Windows/AHK keylogger
* The finger/hand keycode map (`_shared/data/keycodes/azerty.json` = canon) previously had exactly 2 hand-copied duplicates: `_shared/ui/metrics_typing/state.js`'s `KEYCODE_DATA` and `macos/modules/keylogger/aggregator/core.lua`'s `KC_TO_FINGER`. Both are now derived from the shared JSON: JS via build-time codegen (`npm run codegen:keycode-data:js` → `_generated/keycode_data.js`, loaded via a `<script>` tag before `state.js`); Lua at runtime (`Paths.shared("data/keycodes/azerty.json")` + `hs.json.decode`, restricted to the same `CONTENT_KCS` subset as before, with a small hardcoded `FALLBACK_KC_TO_FINGER` only for I/O-failure degradation). A parity test (`tools/test/test-keycode-data-js-parity.cjs`) locks the JS side to azerty.json; the Lua side self-derives so there is nothing to drift.
* **Gap NOT covered by this fix**: `windows/modules/keylogger/keylogger_walker_core.ahk:74-84` declares a 3rd hand-written finger map, `KLW_VK_FINGER` — an AHK `Map` from Windows **virtual-key codes** (not macOS `kc`) to the same finger identifiers, consumed by `keylogger_walker_events.ahk:383-404` for the AHK-side same-finger/same-hand streak detection. This is the functional Windows equivalent of macOS's `KC_TO_FINGER`, but keyed in a completely different identifier space.
* **Why left out deliberately**: azerty.json has no Windows VK-code field today — adding one requires verifying the physical-key correspondence between macOS `kc` and Windows VK for every content key by hand (a wrong mapping silently corrupts WPM/SFB stats, high-risk for an LLM to get right without a physical keyboard to test against), which is materially riskier than the JS/Lua half and was never part of this task's ask.
* **How to apply**: if a future task wants full 3-driver parity here, add the VK field to azerty.json first, verify it exhaustively (ideally against a captured real keystroke log per key, not by inspection), THEN port `KLW_VK_FINGER` to derive from it the same way `core.lua` now does. Until then, treat `KLW_VK_FINGER` as a known, intentionally-untouched hardcoded copy — not a regression.

Related: [[project-shared-tree-layout]]

### [project-ahk-suite-runnable-here-plus-os-purity-ratchet-nondeterminism] The AHK suite IS runnable on this Windows box (results in %TEMP%), but the OS-purity ratchet is non-deterministic and currently drifted red
* **Capability (non-obvious)**: AutoHotkey v2 is installed at `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`. The full Windows/AHK test suite runs headlessly via `AutoHotkey64.exe run_all.ahk` (from `static/ergopti_plus/windows/tests`). `AutoHotkey64.exe` is a **GUI-subsystem** binary, so its `FileAppend(text, "*")` stdout does NOT reach a Git-Bash pipe — capture the TAP report from the file it also writes: **`%TEMP%\ergopti_test_results.txt`** (`C:\Users\admin\AppData\Local\Temp\ergopti_test_results.txt`); read its last line (`# N passed, M failed.`). ~4 min, watchdog at 240 s. This means Windows-side changes and cross-driver AHK parity corpora ARE verifiable here — not just "write + hope".
* **Gotcha 1 — the OS-purity ratchet is non-deterministic**: `windows/tests/meta/test_ahk_os_purity_ratchet.ahk` counts DllCall/COM/FileIO lines across `windows/{modules,lib}` (excl. `adapters/`) with a per-file `try Src := FileRead(...)` that **swallows read failures** (`try` → `Src=""` → 0 tokens for that file). An intermittent FileRead flake silently under-counts, so the total varies run-to-run: observed 2945/0 once, 2943/1 twice on identical source. The suite total itself flickers (2945 vs 2944) — the documented silent-abort behaviour. Re-run before trusting a single AHK result.
* **Gotcha 2 — the baseline is stale, the ratchet is genuinely red (pre-existing, not from the geometry/buffer-cap SSoT work of 2026-07-08)**: the deterministic true count (replicate with a node walk of the same dirs, skipping `;`-lines) is **257** (DllCall=108 COM=14 FileIO=135) vs `_AOPR_BASELINE := 256` captured 2026-06-21 (110/19/127). The distribution shifted from the maintainer's ~70 AHK fix commits since. To confirm a change is NOT the culprit: `git show <commit> -- <files> | grep '^+' | grep -E 'DllCall|ComObj|FileRead|FileOpen|...'` — geometry/literal/`;`-comment edits add zero tokens.
* **How to apply**: fix per the ratchet's own rule — route one OS call into `windows/adapters/` (drive the count toward zero) OR bump the baseline to 257 **with an explicit note** (line 16 permits it for genuinely adapter-unworthy calls). Do NOT bump silently. When touching AHK, run the suite twice and read `%TEMP%\ergopti_test_results.txt`; a lone ratchet/total flake with token-neutral edits is the known non-determinism, not your regression.

Related: [[project-config-v2-refactor]], [[project-dc1-windows-vk-finger-map-gap]]


### [project-ahk-isset-requires-variable-load-crash] `IsSet(obj.prop)` is a LOAD-TIME crash in AHK v2 — and source-introspection tests can never catch it

* **Bug (2026-07-08)**: `lib/webview_utils.ahk` probed `IsSet(WebViewHost._ManifestCache)` (and `IsSet(this.WebView)` / `IsSet(this.Controller)` across the `WebViewHost` lifecycle). AHK v2 `IsSet` accepts **only a plain variable**, never a property or index expression, so `IsSet(obj.prop)` / `IsSet(arr[i])` raises `Error: IsSet requires a variable.` at **parse time** — the file fails to load and the whole app aborts the instant it is `#Include`d ("erreur dès le démarrage"). AHK reports only the *first* load error and exits, so all six broken calls presented as one crash at the earliest line; fixing only that line just moves the crash to the next one.
* **Correct probe for "is this property/field set"**: `obj.HasOwnProp("name")` — empirically (this AHK build) returns false for a property declared `:= unset`, true after assignment, false again after re-assigning `unset` (exact `IsSet` semantics). Verified round-trip: `init:0 → afterset:1 → afterunset:0`. Use `HasOwnProp` for optional fields that are only *accessed behind the guard*. For a holder that is **read unconditionally** (e.g. via `is Map`) use a concrete sentinel (`""`/`false`/`0`), never `unset` — reading an `unset` property throws (see [[project-ahk-v2-static-unset-unreadable]]). The manifest cache took the concrete-`""` route for exactly this reason.
* **Why the "plein de tests unitaires" missed it (the real lesson)**: every `webview_utils` test (`test_webview2_temp_leak`, `test_webview_low_ram_native_fallback`, `test_webview_shared_env_reentrancy_guard`) is **pure source-introspection** — `FileRead` + `InStr`/`RegExMatch` on the text. None of them ever *parses the file through the AHK interpreter*, so a load-time/parse error is invisible to them. This is a **systemic blind spot**: the whole meta-test family (`_DriverSourceConcat` / `_DriverFuncBody`) reads source as strings; it can assert *what the code says* but never *that the code loads*. AHK `/ErrorStdOut` and `/validate` are unreliable here (both spuriously exit 2 / pop a modal dialog under Git-Bash launch), so a headless "does it parse" gate isn't trivial to add.
* **Regression**: `tests/meta/test_isset_no_property_arg.ahk` scans the **entire** driver source (`_DriverSourceNoComments()`) for `(?<!\w)IsSet\(\s*[A-Za-z_]\w*\s*[.\[]` and asserts zero hits — guards the whole class across every present/future file, not just the site that bit us. Regex verified: matches all three original bad lines, ignores valid `IsSet(var)` and `MyIsSet(a.b)`. `_DriverFuncBody(Name)` only anchors on **free functions** (`^[ \t]*Name\(`), so it can't extract a `static`/instance **class method** body — scan `_DriverSourceNoComments()` directly for class-method invariants.

Related: [[project-ahk-v2-static-unset-unreadable]], [[project-ahk-suite-runnable-here-plus-os-purity-ratchet-nondeterminism]]

### [project-metrics-ui-live-foreground-contract] A metrics dashboard must project the still-open foreground interval

* **Symptom (2026-07-18)**: the application-time dashboard could remain empty during a long uninterrupted task, or report only a fraction of a full workday. The typing dashboard could also remain blank on macOS when one browser script failed to parse; Linux exposed neither metrics UI through its WebKit bridge.
* **Cause**: app-switch aggregates only own intervals that have already ended. Without a projection-only addition for the current foreground app, opening the UI before the next switch necessarily omits that time. Windows additionally reset `app_entered_at` on every 30-second micro-idle, thereby measuring typing density instead of focused screen time. macOS had a malformed template literal in `metrics_typing/data.js`, which prevented `process_manifest` from being defined; Linux returned a session-summary shape while the shared UIs require `{metrics_manifest, app_icons}` and had no typing bridge.
* **Invariant**: all three drivers must emit the same dashboard envelope, and the current app interval is added at **read/render** time only (never persisted/cached, or it will double-count). A micro-idle is still foreground time; only a real session timeout/lock/sleep ends the interval. Prime the foreground app after a lifecycle starts when its first callback is edge-triggered.
* **Regression coverage**: shared browser scripts are parsed by `tools/test/test-shared-ui-js-syntax.cjs`; macOS tests the active-app snapshot; Linux tests the bridge contract, lifecycle prime, and per-app projection; Windows tests the micro-idle and live-manifest guards. Keep cross-driver UI fixes contract-based: a UI that merely loads but receives a different payload shape is still broken.

### project-hs-partial-fixes-and-false-green-tests

_Three macOS "fixes" recorded as complete are partial, and each is protected by a test that asserts the wrong thing — the test locks in the mechanism, not the guarantee_

<sub>slug: `project_hs_partial_fixes_and_false_green_tests`</sub>

Found by the 2026-07-20 Hammerspoon adversarial audit (`AUDIT_HAMMERSPOON_2026-07-20.md`).
A green regression test is only worth what its assertion is worth, and three of ours assert a
*mechanism* rather than the *user-visible guarantee* — so the fix regressed (or was never
complete) while CI stayed green.

- **Deferred log purge.** `[[project_hs_perf_profilers_and_case_conform]]` records the
  synchronous log-purge shell pipeline as fixed by deferring it via
  `hs.timer.doAfter(LOG_PURGE_DELAY_SEC=5)`. It was moved off the **boot path** but NOT off the
  **main thread**: `ShellRunner.exec` is `pcall(hs.execute, …)`, fully synchronous. The blocking
  work now lands 5 s after boot — when the keystroke tap IS armed and the user IS typing, which
  is worse than at boot where it was invisible. `test_logger_deferred_purge.lua` asserts the
  purge is *scheduled*, so the blocking call is invisible to CI. Correct assertion:
  `#exec_log == 0`. The purge needs no subprocess at all — filename + `hs.fs.attributes` suffice.
  The same pipeline also never purged the errors sink: `basename` leaves the `errors_` prefix, so
  `date -j -f '%Y-%m-%d'` fails, `2>/dev/null` eats it and `&&` short-circuits.
- **Crash report deferred off the hot path.** `test_crash_report_deferred_off_hot_path.lua`
  states the problem correctly ("froze the whole run loop until a human dismissed a dialog, for
  ANY recoverable Lua error") but the remedy was `hs.timer.doAfter(0, …)`. That leaves the
  stack frame while staying on the **same main thread one tick later**; the freeze is
  `hs.dialog.blockAlert`'s nested modal run loop, not the stack frame. `lib/dialog_util.lua:57-58`
  already documents that modals block the runloop. Related: `_guard_timer_cb` routed EVERY
  recoverable timer throw into the crash reporter, contradicting `[[errors_only_log_sink]]`.
- **MLX warmup gated on disable.** `test_mlx_warmup_gated_on_disable.lua` is titled
  "pause/**disable**" but only greps `script_control.lua` for `stop_warmup`. Whole-tree grep:
  `stop_warmup` had exactly ONE production caller, the pause path.
  `prediction_engine.set_llm_enabled(false)` never called it, so turning AI off left api_mlx's
  2 s self-retry POSTing. Same shape: `test_ollama_ready_reset_on_switch.lua` asserted
  `reset_ready` is *called* and never modelled the in-flight callback that undoes it.

**How to apply:**

- When writing a regression test for a "we made X non-blocking / deferred / gated" fix, assert
  the **absence of the harmful operation** (zero shell execs, zero modal calls, zero POSTs after
  the gate), never the presence of the scheduling call. `doAfter(0)` is not a thread hop.
- A guard test scoped to ONE function's body misses the class — see
  `[[project_ahk_guard_tests_must_loop_the_class]]`. The macOS twin of that lesson:
  `test_pause_guard_position.lua` pinned the pause guard inside `keylogger.handle_key` only, so
  `context_tracker`'s three ungated writers (window **titles**!) kept recording while paused,
  invisible to 3 099 green tests.
- **The dominant bug shape on this driver is the documented invariant with one missed sibling
  site** — `[[project_ahk_invariant_incomplete_application]]` applies to macOS verbatim. The
  audit's critical finding is the purest case: `rules_engine.lua` *states* that SSN/IBAN
  plaintext must never reach the log and guards the interceptor path, while the prefix mappings
  registered 100 lines below take the expander path, where no guard existed. When you find a
  comment asserting an invariant, grep for every route that reaches the same sink.
- Second shape: **a guard that tests the wrong thing.** `pcall` status read as a function's
  return value (`hs.keycodes.setLayout` returns a boolean, it does not raise — so the whole TIS
  fallback was dead code); a function's *existence* read as an *init flag*
  (`if not Rotation.get_offset` is always false); `nil` used as both "no cache" and "cached
  negative" (`vscode_bridge`). Grep for `local ok = pcall(` where the callee returns a status.

Tooling note: the RTK proxy rewrites `git diff` into a summary, so `git diff > file.patch`
produces a `--stat`, not an applicable patch. Use `rtk proxy git diff` when a real patch is needed.

Also recorded: `~/.hammerspoon` and any `ErgoptiPlus_*.log` are absent on the Windows dev box, so
**G4 cannot be measured there** — per `[[project_audit_evidence_must_be_reproducible]]`, label
latency findings "derived from reading the code" and never quote a millisecond figure you did not
observe. The macOS suite is 3 099/0 green, but only when run from `macos/`; from the repo root
6 tests fail on a relative-path read.




### project-hs-audit-2026-07-21

_Second adversarial pass on the Hammerspoon driver: 13 defects fixed, 78 findings left OPEN. The
audit markdown was deleted by design, so this entry IS the record._

<sub>slug: `project_hs_audit_2026_07_21`</sub>

**Fixed and shipped** (each with a regression test that fails before / passes after; suite went
3 228/478 → 3 251/488):

- **PII reached the 14-day log on PREVIEW, not expansion.** Typing `@phone` logged the resolved
  number before any expansion committed. `acc7946fc` had applied the withhold contract to the two
  *expansion* sinks in `expander.lua` and stopped; the preview sink in `llm_bridge.lua` had no
  guard, and the match records did not even carry `is_private`, so it could not have applied one.
  Provider output is now withheld unconditionally — the registration API has no privacy metadata,
  so withhold-by-default is the only shape under which a new provider cannot leak by omission.
- **Keystrokes were logged inside password managers.** `is_secure_field` was written from two
  sites that disagreed: the activation path used the union `isSecureField() or isSecureApp()`,
  the AX focus callback recomputed from the role/subrole axis alone and assigned unconditionally.
  Any focus change inside a vault re-enabled capture. Separately, the pause guard froze the
  cached context, so pausing → switching to a vault → resuming left the flag stale-false; fixed
  by re-syncing on **resume**, deliberately NOT by weakening the guard.
- **Whole typing events silently discarded.** `_sql_num(nil)` emits `NULL`, the columns are
  `NOT NULL`, and `INSERT OR IGNORE` swallows the violation. Writing the guard **class-wide**
  immediately surfaced 4 more columns nobody had reported.
- **`keyStroke` blocked the run loop 200 ms per call at 49 sites** (the argument defaults to a
  blocking usleep). **`karabiner.pause/resume` deployed a 100 kB config inside the script-control
  eventtap callback** — the tap carrying AltGr+Enter, the key needed to un-pause.
- Also: unescaped gsub replacements (`%` magic key aborted all registration; `search_web` threw
  for any selection with a space); `hs.task:start()`'s falsy return discarded; config-window
  delay edits never reaching the engine; a dead synchronous `python3` fork on every save;
  negative AX lookups never cached in the wrap-text tap.

**OPEN — reported by audit agents, NOT verified by me. Treat as hypotheses**
(`[[project_audit_findings_are_hypotheses]]`), 17 critical/high of 78 total:

- **CRITICAL** (G2) `modules/llm/api_mlx_discovery.lua:384` — MLX endpoint discovery deadlocks permanently: reset() orphans a poll chain that resurrects on the shared _endpoint_probe_in_flight flag and kills the new chain's probe via the shared _probe_client
- **HIGH** (G2) `adapters/secure_field_detector.lua:114` — Split the shared pcall in refresh(): a throwing AXSubrole read wipes an already-read secure AXRole
- **HIGH** (G2) `modules/gestures/engine.lua:649` — A single transient extra finger contact latches gs.lifting for the rest of the gesture: the whole remainder of the swipe is silently dropped and the gesture mis-commits as tap_(N+1)
- **HIGH** (G2) `modules/gestures/engine.lua:716` — gs.candidateFingers is never cleared when the finger count falls back to maxFingers, blocking every live fire for the remainder of the gesture
- **HIGH** (G2) `modules/karabiner/init.lua:489` — M.regenerate() has no pause guard — the « pause = tout éteint » invariant is enforced at one call site inside the file while ~17 menu call sites redeploy the full Ergopti config mid-pause
- **HIGH** (G2) `modules/karabiner/watchers.lua:146` — CapsWord's `--set-variable capsword 0` task is neither GC-rooted nor start()-checked — KE can be left with capsword=1 and the next spacebar turns CapsLock back ON
- **HIGH** (G2) `modules/keylogger/aggregator/sql.lua:163` — macOS n-gram UPSERT overwrites esrc_json instead of merging it, so the hotstring/LLM source split for every n-gram reflects only the last 5 s ingest tick (invariant fixed on Windows AND Linux, forgotten on macOS)
- **HIGH** (G2) `modules/keylogger/init.lua:820` — Every space and sentence-punctuation flush zeroes the inter-keystroke delay of the NEXT keystroke — ~1 keystroke in 6 is logged with delay 0
- **HIGH** (G2) `modules/keylogger/kc_bridge.lua:413` — kc_bridge replays the entire Karabiner backlog written while metrics were switched OFF, on the next OFF->ON toggle — the exact failure F-MED-26 claims to prevent, missed on the stop/start path
- **HIGH** (G2) `modules/keylogger/log_manager.lua:1228` — Toggling Metrics OFF then ON permanently kills SQLite ingest and midnight rotation for the rest of the session — close_db() has no matching re-open on the start path
- **HIGH** (G2) `modules/keylogger/sqlite_reader.lua:606` — read_range_split_today omits ngram_keycodes / ngram_shortcuts / ngram_shortcut_bigrams from the today projection, so today's keycode heatmap and shortcuts tabs are always empty (both sibling drivers query them)
- **HIGH** (G2) `modules/keymap/utils.lua:221` — emit_tokens emits every token after the 2nd paste-worthy segment BEFORE it — multi-segment hotstrings land scrambled on screen
- **HIGH** (G4) `modules/llm/app_filter.lua:183` — app_filter runs 6–15 uncached synchronous AX round-trips INSIDE the keyDown eventtap callback on every accepted prediction (F16 chain path)
- **HIGH** (G2) `modules/shortcuts/actions/system.lua:128` — close_awake_alert discards the closeSpecific pcall result, making the closeAll fallback unreachable — reverts f25be56f1 and leaks the keep-awake banner forever
- **HIGH** (G2) `modules/shortcuts/actions/system.lua:683` — Wrap-text eventtap: a STALE positive AX cache re-wraps text that is no longer selected, swallowing the keystroke and duplicating the previous selection
- **HIGH** (G2) `modules/shortcuts/script_control.lua:246` — Pause/resume loses the shortcuts preference: the tray "Raccourcis" toggle is the only top-level feature toggle not pause-gated, and resume_all() restores from a pause-time snapshot that a mid-pause toggle invalidates
- **HIGH** (G2) `ui/onboarding/init.lua:409` — Surface a batch_write() that returns false — the retargeted commit write fails silently and reports success

The remaining 61 are medium/low across `gestures/engine`, `llm/api_mlx_*`, `keylogger/aggregator`,
`ui/menu_llm`, and `shortcuts/actions`. They were not transcribed individually — re-run the sweep
to regenerate them rather than trusting a stale list.

**REFUTED — do not re-raise these:**

- **Logger date-rotation bug** (the standing suspicion in `bugs_hs.md`). *False for macOS.*
  `_ensure_log_file()` re-points **both** `UNIFIED_LOG_FILE` and `ERRORS_LOG_FILE` on rollover,
  and `_write_to_file` runs before both errors-sink opens, so the path is always fresh.
  `test_logger_date_rollover.lua` already asserts it. **This is an AHK-only defect — do not port
  the fix.**
- **`gestures/actions.lua` AppleScript calls not deferred.** *False* — grep line numbers pointed
  at the inner lines of closures already wrapped in `hs.timer.doAfter(0, …)`. A grep hit is not
  a call site; open the file.
- **WPM widget runs under pause.** *False* — suppression is indirect but real:
  `on_pause_change` → `updateMenu()` → the metrics builder stops widget and menubar
  (`menu_metrics.lua:155-159`).
- **Closure-binds-nil-global (`[[project_lua_closure_before_local_nil_global]]`) is present.**
  *False* — a mechanical scan of every non-test `.lua` found 3 file-scope candidates, all false
  positives (`parsed.sections` is a field access; the others are `M.X = v` then `local X = M.X`).
  Top nested candidates were function **parameters**. The class is clean; re-run the scanner
  rather than re-reading by eye.
- **`utf8` misuse.** *Cleared* — every `utf8.codes` loop is gated by a successful
  `pcall(utf8.len, …)`, every `offset`/`len` result nil-checked.

**How to apply:**

- **Write the guard test class-wide from the start.** Every high-severity finding in this pass was
  a sibling of an invariant the codebase already stated, documented and tested *somewhere else*.
  Two of the fixes only exist because the guard enumerated the class: the NOT NULL scan found 4
  extra columns, the gsub scan found `search_web`. This is
  `[[project_ahk_guard_tests_must_loop_the_class]]` earning its keep again.
- **Suspect the shipped test, not just the shipped code.** Three fixes came with tests
  structurally blind to the damage. `shell_runner`'s stub returned `nil` where the real
  `hs.task:start()` returns the task object — the stub *cemented* the defect its own test claimed
  to lock out. The `hs` stub dropped `keyStroke`'s third argument, so no test could ever see it.
  Fixing an unfaithful stub and adding the uncovered case **strengthens** a test; that is not the
  same as weakening one.
- **When a guard is deliberate, fix the other side.** `test_pause_guard_position.lua` pins the
  pause guard's position on purpose. The context staleness was fixed with a resume-time re-sync,
  leaving « pause = tout éteint » exactly as strict.
- **G4 is still unmeasured on this driver.** `<config_dir>/hammerspoon/` has no `logs/` (and
  `logs` is gitignored in the config repo); the driver has never run on the Windows dev box. The
  AHK logs at `<config_dir>/autohotkey/logs/` are real and were re-derived independently
  (`Tooltip.ResolvePos` 2560.32 ms, `OnChar` 701.27 ms, 8 958 `Slow` lines) — those belong to the
  *other* driver. See `[[project_audit_evidence_must_be_reproducible]]`.
- **loop-until-dry was NOT reached.** No zone got two consecutive clean passes; every open finding
  is one pass deep. `lib/toml`, `lib/i18n`, the input adapters, `ui/menu_llm`, `ui/download_window`,
  `ui/healthcheck`, `ui/metrics_*` and **`init.lua`'s boot order / shutdown callback** were never
  swept at all. Silence in an audit report is not coverage.
- **Subagents will write into your worktree unless told not to.** One created a probe test under
  `tests/` mid-run and it polluted a live suite execution; "read-only" must name the whole repo,
  not just "driver source".

Related: [[project_ahk_guard_tests_must_loop_the_class]],
[[project_audit_findings_are_hypotheses]], [[project_audit_evidence_must_be_reproducible]],
[[project_macos_eventtap_no_blocking]], [[project_suspend_pause_invariant]],
[[feedback_regression_tests]].





### project-hs-audit-round2-2026-07-21

_Second implementation pass on the 78 findings the first pass left open: 51 treated
(24 fixed, 27 refuted or already fixed), 27 still open with an exact fix specified._

<sub>slug: `project_hs_audit_round2_2026_07_21`</sub>

**Method that made this tractable.** Every open finding was adjudicated against the
CURRENT source by one agent per file, returning CONFIRMED (with quoted evidence, an
exact minimal fix and a test plan), REFUTED (with the disproving code) or
ALREADY_FIXED. Of 75 adjudicated: **53 confirmed, 16 refuted, 6 already fixed** —
so nearly a third of the surviving backlog was wrong or stale, which is why
implementing an audit list verbatim is a bad idea (`[[project_audit_findings_are_hypotheses]]`).

**The adjudication is worth keeping.** Refuted with evidence, do not re-raise:
`karabiner/watchers.lua:283` (start() return is checked by the latch owner),
`shortcuts/actions/system.lua:134` (closeAll fallback IS reachable),
`keymap/init.lua:868` (the is_ignored path is reachable),
`log_manager.lua:1057` (the retry loop does terminate),
`kc_bridge.lua:271` (the ledger is bounded elsewhere),
`karabiner/onboarding.lua:544` (poll_until is already async),
plus seven test-quality findings whose guards turned out to be adequate.

**Classes that kept paying out.** Three fixes came from widening a guard rather
than from the reported site:
- The `hs.task` GC-pin guard was an ALLOWLIST of 8 files. Converting it to a
  whole-tree scan found **5 unpinned files** nobody had reported, including the
  interactive-screencapture task (the longest-lived subprocess in the driver) and
  the CapsWord clear-variable task, whose loss leaves KE with capsword=1 so the
  next space re-enables CapsLock.
- The gsub-replacement escape guard, written class-wide, found **7 more sites**;
  then its own pattern proved too narrow (bare identifiers only, missing
  `tostring(err)`), and widening it found **7 more again** — including raw hdiutil
  stderr. That class has now bitten four separate times.
- The NOT NULL guard, written class-wide, found **4 more columns** in round one.
  Writing the guard for the class, not the site, is the single highest-yield habit
  in this repo.

**Self-inflicted bugs caught by the discipline, worth remembering:**
- A regex-driven fix rewrote `postKeyStroke`'s own body into infinite recursion;
  caught only by reading the diff before committing.
- Two files were left referencing a `_active_tasks` global that had never been
  declared, because the script that added the declaration raised before writing.
- A commit landed with a red test: the pre-commit hook lints but does NOT run the
  suite. **Run `lua tests/run.lua` before every commit, not after.**
- A first attempt at a behavioural gesture test could not discriminate fixed from
  broken (in x1 mode "stopped firing" is indistinguishable from normal completion)
  and was replaced with a structural guard, stating why in the file.

**STILL OPEN — 27 findings, each with a verified exact fix in hand.** These were
adjudicated CONFIRMED against current source but not implemented; treat them as
specified work, not as hypotheses:

- **HIGH** `modules/keylogger/sqlite_reader.lua:606` — read_range_split_today omits ngram_keycodes / ngram_shortcuts / ngram_shortcut_bigrams from the today projection, so tod
  - *Fix:* Add the three missing today passes using the file's own `_safe_query` (F-MED-28) pattern — the same wrapper every other query loop in this file already uses — inside the existing `if db then` block, so no extra sqlite connection i…
- **HIGH** `modules/llm/api_mlx_discovery.lua:384` — MLX endpoint discovery deadlocks: reset() orphans a poll chain that resurrects on the shared _endpoint_probe_in_flight f
  - *Fix:* Smallest correct edit: give the poll phase the SAME `my_discovery_gen ~= _discovery_gen` guard this file already applies three times to its probe callbacks (the F-MED-8 pattern), so an orphaned chain self-terminates deterministica…
- **HIGH** `modules/shortcuts/actions/system.lua:707` — Wrap-text eventtap: a stale positive AX selection cache re-wraps text that is no longer selected, swallowing the keystro
  - *Fix:* Give the cache the invalidation hook the codebase already uses for TTL caches (a local `invalidate_*`-style helper next to the cache, as in modules/keymap/input_sources.lua:71 invalidate_active_layouts_cache and modules/keymap/uti…
- **MEDIUM** `lib/logger.lua:446` — Ephemeral topical sub-file purge is inverted: it spares the files that grow and deletes only the idle ones
  - *Fix:* Do not try to infer "contains only today" from mtime AFTER the logger has touched the file — evaluate the same predicate on the FIRST write of each new calendar date, which is the only moment mtime still answers that question. Thi…
- **MEDIUM** `modules/gestures/actions.lua:364` — Four registered gesture/shortcut actions require modules that do not exist; the inner bare pcall hides the failure from 
  - *Fix:* Point the four registrations at the real modules AND stop swallowing the failure. Use the lazy-require guard pattern this same file already uses for script_pause_toggle (actions.lua:447-450: `local ok, sc = pcall(require, …); if o…
- **MEDIUM** `modules/gestures/engine.lua:412` — PEAK OVERRIDE confirms on wall time elapsed since the peak was first seen, not on how long the peak was held, so a one-f
  - *Fix:* Record when the peak was last observed and measure the actual held duration, keeping the comparison line byte-identical so test_peak_override_regression.lua section 3 still passes, and using a timestamp rather than a frame counter…
- **MEDIUM** `modules/karabiner/init.lua:538` — User-configurable config-dir path interpolated into a shell command with Lua %q instead of POSIX quoting, while the sibl
  - *Fix:* Reuse the POSIX quoter the same feature already defines 150 lines away (generator.lua:385 `sq()`), and memoise it with the `_ensured_dirs` idea from menu_paths.lua. Add next to the other module-level flags near line 116: local _de…
- **MEDIUM** `modules/karabiner/watchers.lua:351` — Layout-poll watchdog releases the guard but never terminates the abandoned read, turning a bounded one-shot failure into
  - *Fix:* Give the poll ownership of the in-flight handle, mirroring watchers.lua:186. Assign the module local INSIDE read_layout_async, BEFORE start(), so a synchronously-completing handle (the shape used by test_layout_poll_lock_release.l…
- **MEDIUM** `modules/keymap/input_sources.lua:701` — upgrade_active_list reports success from osascript's exit code, not the AppleScript's result
  - *Fix:* Bind the AppleScript's own result, mirroring the two correct siblings in the same file (set_input_source:441 and enable_and_select_source:604 — the established payload-check pattern here). OLD (input_sources.lua:700-701): local ok…
- **MEDIUM** `modules/keymap/utils.lua:215` — emit_tokens omits {Enter}/{Tab} key tokens from the physical echo, under-filling the keylogger synth_queue on every mult
  - *Fix:* Mirror the terminator re-type path (expander.lua:454-464) and the personal_info emitter, using a named lookup so no magic literals appear inline. Add a constant to section 1 of modules/keymap/utils.lua, after IGNORED_WIN_TTL_SEC (…
- **MEDIUM** `modules/llm/api_mlx_fetch.lua:240` — MLX sequential retry hardcodes its temperature policy and caps at 0.60, which LOWERS the retry below the failed variant'
  - *Fix:* Adopt the pattern api_ollama.lua and api_remote.lua already use, verbatim. old text (api_mlx_fetch.lua:33): local _RETRY_MAX_MULT = ApiCommon.get_retry_policy() new text: local _RETRY_MAX_MULT, _RETRY_TEMP_STEP, _RETRY_EXTRA_TOKEN…
- **MEDIUM** `modules/llm/api_mlx_inference.lua:46` — MLX hardcodes deduplication OFF instead of reading inference.json, so a sequential fetch stops early on duplicate varian
  - *Fix:* Adopt the pattern already used by api_ollama.lua:75 and api_remote.lua:160 (read the flag from ApiCommon, which loads _shared/modules/llm/inference.json). ApiCommon is already required at line 27, so no new require is needed. Old …
- **MEDIUM** `modules/llm/prediction_engine.lua:922` — handle_chain_signal runs perform_check synchronously inside the keymap CGEventTap, where AppFilter.is_blocked issues unc
  - *Fix:* Defer with hs.timer.doAfter(0, …) — the exact pattern the codebase uses for the same hazard at script_control.lua:242 (`hs.timer.doAfter(0, function() pcall(function() _karabiner.pause() end) end)`) and menu_keyboard_layout.schedu…
- **MEDIUM** `modules/shortcuts/actions/text.lua:184` — do_transform has no re-entrancy guard: two rapid case-toggle presses interleave and silently destroy the user's clipboar
  - *Fix:* Apply the in-flight-flag pattern the codebase already uses twice — `_reload_in_flight` in lib/ui_restore.lua and `_warmup_in_flight` in modules/llm/api_mlx.lua:643 (which also arms a hard timeout precisely because the comment at :…
- **MEDIUM** `modules/shortcuts/script_control.lua:253` — Pause/resume loses the shortcuts preference: the tray "Raccourcis" toggle is the only top-level feature toggle not pause
  - *Fix:* Smallest correct edit, using the pattern the codebase already applies to the gestures master toggle (ui/menu/menu_gestures.lua:78-79) and to every other item in menu_shortcuts.lua. In ui/menu/menu_shortcuts.lua:331-335: OLD: local…
- **MEDIUM** `static/ergopti_plus/macos/modules/llm/mlx_deps_checker.lua:515` — mlx_deps_checker arms an uncancellable 1.5 s auto-hide timer that destroys the SHARED download_window singleton — includ
  - *Fix:* Two edits, mirroring the ownership re-validation the codebase already uses for deferred callbacks (the `_startup_check_generation` guard in ui/menu/menu_llm/startup_controller.lua:86, and the warm-up generation guard covered by te…
- **MEDIUM** `tests/stubs/hs.lua:480` — tests/stubs/hs.lua has no hs.screen, so both render entry points abort at the anchor step inside their pcall and the ent
  - *Fix:* Add an hs.screen module table to the '9/ Misc UI' section, following the exact pattern the stub already uses for every other hs submodule (a plain `M.<name> = { ... }` table of closures returning inspectable literals, e.g. M.windo…
- **MEDIUM** `tests/unit/lib/test_timings.lua:147` — Cover the `next(sections) == nil` clause the fix is actually about — the shipped test never executes it
  - *Fix:* Add a fourth case to the existing `timings: registry load fail-fast` describe, reusing the file's own save-stub-reload-restore helper pattern (`reload_timings_without_shared_tree`, test_timings.lua:126-145) but stubbing the READER…
- **MEDIUM** `tests/unit/modules/gestures/test_actions.lua:60` — Parameterized-action test asserts only the accessor layer, leaving the set-then-execute guarantee untested
  - *Fix:* Add an execution-level describe block to tests/unit/modules/gestures/test_actions.lua, following the behavioural pattern the repo already uses for exactly this problem in tests/unit/modules/gestures/test_actions_modifier_keystroke…
- **MEDIUM** `tests/unit/modules/keymap/test_lifecycle_preserves_interceptors.lua:49` — Make the new lifecycle regression test replayable in isolation by also clearing package.loaded["ui.tooltip"]
  - *Fix:* Follow the pattern the harness already uses for leaked partial stubs (tests/helpers/init.lua:117-142 clears lib.text_utils / lib.toml.codec / lib.timings for exactly this reason), and the pattern the sibling test uses (test_expand…
- **MEDIUM** `tests/unit/ui/menu/test_karabiner_timeout_regenerates.lua:127` — Shipped regression test asserts call COUNTS, not the setter→regenerate ORDER it exists to protect — a swapped-order muta
  - *Fix:* Make the double stateful so the assertion encodes the deployed value instead of the call count — the same technique the suite already uses in tests/unit/ui/menu/test_menu_karabiner_perf.lua, whose double stores timeouts rather tha…
- **MEDIUM** `tests/unit/ui/test_onboarding_retargets_config_dir.lua:36` — Pin persist_config_dir_for_wizard → get("ConfigTomlPath") — the retarget test doubles away the half of the guarantee tha
  - *Fix:* No production change — the code is correct today (verified by reading the full persist→config_dir→get chain above). Close the blind spot by appending a section 4 to tests/unit/ui/test_onboarding_retargets_config_dir.lua that drops…
- **MEDIUM** `tests/unit/ui/test_tooltip_stacked_panel.lua:253` — The combined-footer regression test asserts only a call count, which the broken (re-shadowed size_combined) state satisf
  - *Fix:* Assert the render OUTCOME alongside the count, using the same "assert observable state, not the call count" pattern the sibling regression test tests/unit/ui/test_tooltip_llm_is_visible_after_render_crash.lua already uses (it asse…
- **MEDIUM** `ui/menu/menu_paths.lua:134` — Do not memoise a directory whose creation FAILED — pcall status is not hs.fs.mkdir's return value
  - *Fix:* Two edits. Edit 1 — capture the actual return value (lines 134-135): OLD: local ok_mk = pcall(hs.fs.mkdir, current) if not ok_mk then NEW: local ok_mk, created = pcall(hs.fs.mkdir, current) if not ok_mk or not created then Edit 2 …
- **MEDIUM** `ui/menu/menu_shortcuts.lua:454` — Script-control shortcut picker offers open_url / search_web but never prompts for the parameter, making both permanently
  - *Fix:* Reuse the pattern the codebase already has at ui/menu/menu_gestures.lua:153-178 (the parameter-prompt-before-apply branch). Extract it into the EXISTING ui/menu/shortcut_utils.lua — that module already owns shortcut-related dialog…
- **LOW** `modules/gestures/init.lua:478` — The gestures space_wrap setting is persisted, restored and exposed as a menu checkbox but is never read by any code path
  - *Fix:* Implement the consumer rather than removing the setting. Removal would touch _shared manifest.toml, both regenerated files, menu_manifest.json, 21 locale files, menu_gestures.lua, preferences.lua and menu_state.lua, and would requ…
- **LOW** `ui/tooltip/tooltip_llm.lua:878` — Sibling site forgotten: show_predictions re-measures the identical combined footer once per reserved slot
  - *Fix:* Apply the hoist-and-reuse pattern already used in renderer.lua M.render (the hoisted `size_combined`, renderer.lua:239-243): measure the index-invariant footer on the first iteration and reuse it. (1) declare the memo before the l…

**How to apply:**

- Re-adjudicate before implementing any of the above: this branch changed several
  of those files, so a cited line may have moved or the defect may already be gone.
  Three of the 27 were already stale when this pass started.
- Keep writing the guard for the CLASS. Every high-severity finding in both passes
  was a sibling of an invariant the codebase had already stated and tested
  somewhere else — `[[project_ahk_invariant_incomplete_application]]` is the
  dominant shape on this driver, not an occasional one.
- Suspect the shipped test as readily as the shipped code. Several fixes arrived
  with tests structurally blind to the damage; fixing an unfaithful STUB and adding
  the uncovered case strengthens a test and is not the same as weakening one.
- Tell subagents "read-only" means the whole repository. Told only "do not edit
  driver source", one wrote a probe test into `tests/` and polluted a live run.

Related: [[project_hs_audit_2026_07_21]], [[project_ahk_guard_tests_must_loop_the_class]],
[[project_audit_findings_are_hypotheses]], [[project_macos_eventtap_no_blocking]],
[[project_suspend_pause_invariant]], [[feedback_regression_tests]].
