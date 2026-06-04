# Project Memory

Accumulated engineering knowledge for this repository — gotchas, architecture decisions, and working conventions, kept here so every future developer, LLM agent, and reviewer can rely on the same hard-won context. Each entry below was a discrete lesson learned while working on the codebase.

> Maintained as a single in-repo source of truth. When you learn something non-obvious about this codebase (a foot-gun, an architectural invariant, a convention the user insists on), add an entry under the right section rather than letting it evaporate. Keep entries factual and link related ones by their slug in `[[brackets]]`.

## Contents

- **Working conventions & feedback**
  - [feedback-ahk-source-encoding](#feedback-ahk-source-encoding) — AHK v2 source files must be UTF-8 BOM + CRLF; encoding drift causes silent mid-file parse aborts that masquerade as missing tests
  - [feedback-ahk-suspend-prefix-latch](#feedback-ahk-suspend-prefix-latch) — AHK Kana custom-combination prefix latches across Suspend; fix at the source, synthetic key events can't clear it
  - [feedback_ahk_ui_syntax_validation](#feedback-ahk-ui-syntax-validation) — AHK UI files aren't in the headless test runner; how to syntax-check them locally on Windows
  - [Coding style and conventions for this project](#coding-style-and-conventions-for-this-project) — Style rules, architecture decisions, and what to avoid when writing code for this project
  - [feedback_commit_push](#feedback-commit-push) — Never push automatically — commit only after explicit ask, push only after explicit validation
  - [feedback_fix_banners_tool](#feedback-fix-banners-tool) — npm run fix:banners auto-corrects all section banner alignment violations — run it before every commit instead of fixing manually
  - [feedback-loader-target-explicit](#feedback-loader-target-explicit) — AHK loader/writer modules that mutate a shared Map (Features etc.) must take the target Map as an explicit parameter, never reach for it via `global`
  - [No co-author trailers (Copilot, Claude, bots)](#no-co-author-trailers-copilot-claude-bots) — Never add Co-Authored-By trailers to commits — including Copilot, Claude, github-actions[bot], or any LLM/tool credit
  - [feedback-no-push-dev](#feedback-no-push-dev) — Ne jamais pusher sur dev sans validation explicite — chaque commit sur dev déclenche la CI et crée une release
  - [feedback-regression-tests](#feedback-regression-tests) — Every user-requested bug fix must ship with a regression test that fails before / passes after the fix
  - [feedback-test-before-merge](#feedback-test-before-merge) — Never merge a cut-over slice into dev before the user has tested it live. Stay on the slice branch and wait for explicit validation.
  - [feedback-ui-must-be-i18n](#feedback-ui-must-be-i18n) — All user-facing UI text must go through the i18n system in 21 supported languages — never hardcode any UI string anywhere, including WebView UIs (metrics, download window, etc.).
- **Project architecture & decisions**
  - [project-ahk-menu-dispatcher-drop](#project-ahk-menu-dispatcher-drop) — AHK 2.0 silently drops ~30-50% of tray-menu clicks. FIXED via lib/menu_dispatcher.ahk — every actionable item must use RegisterMenuItem, never raw Menu.Add.
  - [project-config-v2-refactor](#project-config-v2-refactor) — State of the v2 config schema refactor (Scope C) — branch refactor/config-schema-v2 with 5 dormant commits. Cut-over to actually migrate the AHK driver runtime is the open piece.
  - [project_debug_menu_sync](#project-debug-menu-sync) — Debug menu order is defined in shared/menu_manifest.json debug_menu — both AHK and Lua drivers consume it
  - [project-gestures-reversal-detection](#project-gestures-reversal-detection) — How direction reversals are detected in the gestures engine (x1 vs incremental)
  - [project-gestures-startup-design](#project-gestures-startup-design) — Design choices for the macOS gestures startup path — primer-as-wakeup-signal vs burst probes
  - [project-hotstring-delay-architecture](#project-hotstring-delay-architecture) — Where hotstring expansion delays are configured, the cross-platform precedence, and the key gotchas
  - [project-hotstring-engine-internals](#project-hotstring-engine-internals) — AHK prefix-watcher InputHook captures synthetic input; OnChar must feed each char once; AHK vs Hammerspoon word-boundary framing divergence is intentional
  - [Keymap module architecture and refactor decisions](#keymap-module-architecture-and-refactor-decisions) — Structure of the keymap module, where defaults live, which files do what
  - [project-locale-parity-test](#project-locale-parity-test) — en.json is the canonical key set; tools/check_locales.py enforces parity in CI
  - [project_metrics_pipeline_17](#project-metrics-pipeline-17) — AHK metrics pipeline — bug #17 CLOSED, follow-up bugs fixed
  - [project-suspend-pause-invariant](#project-suspend-pause-invariant) — Pause must fully silence ALL features (no tooltip/LLM/keylogger/widget). AHK Suspend only disarms hotkeys — InputHooks/timers/OnMessage bypass it and need explicit A_IsSuspended guards.
  - [project-touchdevice-dormancy-is-kernel](#project-touchdevice-dormancy-is-kernel) — Definitive answer that macOS touchdevice subsystem CANNOT be activated before first physical touch — it is a kernel-driver gate
  - [project-ui-dynamic-buttons](#project-ui-dynamic-buttons) — AHK UIs must use Gui_HarmoniseButtonWidths instead of hardcoded w-values; HS auto-sizes via CSS padding


---

## Working conventions & feedback

### feedback-ahk-source-encoding

*AHK v2 source files must be UTF-8 BOM + CRLF; encoding drift causes silent mid-file parse aborts that masquerade as missing tests*

<sub>slug: `feedback_ahk_source_encoding`</sub>

AHK v2's parser silently stops registering top-level statements partway through a source file when the file's encoding is inconsistent (LF appended into a CRLF/BOM file, missing BOM, mixed line endings). The headless test runner then plans `1..N` for only the first batch of `Test()` calls and reports green — passing tests are real, missing ones are silently dropped, and there is no error message anywhere.

**Why:** discovered 2026-05-22 during the v2 config-refactor test suite development. Initial drafting of `test_features_manifest_v2.ahk` showed only 5-7 of 33 tests registering despite all `Test()` calls being syntactically valid. Root cause: PowerShell file rewrites left mojibake (double-encoded UTF-8) and `cat >>` from bash appended LF lines into a CRLF/BOM file. The AHK v2 parser handled this by quietly truncating the file, not by raising an error.

**How to apply:**
- New `.ahk` files: the Write tool on Windows defaults to UTF-8 **without** BOM and LF-only, both wrong. After every Write of a new `.ahk` file, run a PowerShell conversion step before adding it to git: `$c = [IO.File]::ReadAllText($p); $c = $c -replace "\r\n","\n" -replace "\n","\r\n"; [IO.File]::WriteAllText($p, $c, (New-Object Text.UTF8Encoding $true))`. Then verify with the BOM + CRLF byte check.
- Existing `.ahk` files: extend via the Edit tool (preserves encoding), NEVER via `cat >> file.ahk` from bash (it appends LF and corrupts the file).
- Non-ASCII in comments/strings is fine when encoding is clean. The v2 test suite (`test_features_manifest_v2.ahk`) stays ASCII-only as a defensive convention and accesses non-ASCII glyphs via `Chr(0xNNNN)` (e.g. `Chr(0x2605)` for the magic key star) so future encoding regressions cannot reintroduce the silent abort.
- Diagnostic when a test file shows fewer test-results than its `Test()` count: run `file <path>` first, before debugging the test logic.

Also documented in:
- `.github/copilot-instructions.md` — AHK language section (primary developer rule).
- `static/drivers/autohotkey/tests/test_framework.ahk` — module header (visible to every test author).
- `static/drivers/autohotkey/lib/manifest_reader.ahk` — module header (codegen output must match).

Related rule (same context, AHK v2 string parsing): inside a double-quoted string, the escape for a literal double quote is `` `" `` (backtick + quote), NOT `""` (doubled quote — that was AHK v1 syntax). The IDE flags `""` as `Did you mean to use '\`"'?` but the silent-abort can mask this if it falls in a region the parser has already given up on.

### feedback-ahk-suspend-prefix-latch

*AHK Kana custom-combination prefix latches across Suspend; fix at the source, synthetic key events can't clear it*

<sub>slug: `feedback_ahk_suspend_prefix_latch`</sub>

Toggling AHK `Suspend()` around the ergopti_plus Kana `SC138` AltGr custom-combination prefix produces two distinct latch bugs. The working fixes are non-obvious — found live over ~5 iterations on branch fix/hs (commit 89c15093f, ErgoptiPlus.ahk + lib/layout/layout_altgr.ahk).

- **Menu/gesture pause → keyboard can't un-pause.** Toggling `Suspend` from a non-hook thread rebuilds the keyboard hook with the `SC138 & X` prefix un-armed, so the suspend-exempt script combos (AltGr+Enter/BackSpace/Delete/Escape) stop firing. **Fix:** also register the chords as plain **suffix** hotkeys (`Hotkey("SC01C", …, "I2 S")`) gated on `HotIf(A_IsSuspended and GetKeyState("SC138","P"))`. A suffix needs no prefix arming, never re-registers the prefix (so it can't latch the Kana key), and yields to the real combo when the prefix IS armed (no double-fire).
- **Keyboard pause → menu/gesture resume → « AltGr bloqué ».** A keyboard pause holds SC138 down through `Suspend(1)`; its physical release lands while the AltGr layer is disarmed, so AHK's internal prefix-down flag stays latched. On resume the layer dispatches with `GetKeyState("SC138")==0`.

**Why:** AHK's custom-combination prefix-down flag is SEPARATE from `GetKeyState` and is cleared **only by a real physical key release processed by the live layer**. A synthetic `SendEvent("{SC138 Up}")` or `{Down}{Up}` tap does NOT clear it (verified via logs), and re-registering the combos Off→On re-latches it. So you cannot clean it up on resume.

**How to apply:** prevent at the source — in `ToggleSuspend`, before `Suspend(1)`, `KeyWait("SC138","T1")` when SC138 is physically held (keyboard pause). Never reach for synthetic taps or Off→On re-registration. A permanent WARNING guard-rail in `AltGrShiftDispatch` logs any dispatch with SC138 not physically held to catch regressions in ErgoptiPlus_layout.log. Use `AutoHotkey64.exe /ErrorStdOut /validate <script>` (exit 0 = clean) to syntax-check edits headlessly. Related: [[project_suspend_pause_invariant]].

### feedback_ahk_ui_syntax_validation

*AHK UI files aren't in the headless test runner; how to syntax-check them locally on Windows*

<sub>slug: `feedback_ahk_ui_syntax_validation`</sub>

The AHK UI files `windows/ui/tray_menu.ahk` and `windows/lib/hotstrings/hotstrings_config_window.ahk` are NOT `#Include`d by the headless test runner `windows/tests/run_all.ahk` (it pulls in `lib/` + `adapters/` + `test_*` only). So a syntax error in those UI files is caught **only** by CI's `Compile ErgoptiPlus.ahk` step (Ahk2Exe), never by the AHK test suite or the CI dry-run warning check.

**Why:** run_all deliberately avoids `modules/` and UI files that register hotkeys / build menus at top level (they'd block a clean exit).

**How to syntax-check them locally** (two ways, both gotcha-laden):
1. **Ahk2Exe compile** (gold standard, == CI): `Ahk2Exe.exe` lives at `C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe`. **Run it from PowerShell, never Git Bash** — Git Bash's MSYS path conversion rewrites `/in` `/out` `/base` into Windows paths (`/in` → `C:/Program Files/Git/in`), so the compile fails with "Unrecognised parameter". `& $ahk2exe /in $in /out $out /base $base /silent`; Ahk2Exe exits 0 even on failure, so verify the `.exe` was actually created.
2. **Parse-only harness**: a throwaway `.ahk` with `ExitApp(0)` as the first auto-execute statement, then `#Include` the UI file(s). AHK parses the whole merged script before running anything, so a syntax error aborts at load; the `ExitApp(0)` exits before any included top-level code runs (won't start the driver). Launch via `Start-Process -FilePath AutoHotkey64.exe -ArgumentList @("/ErrorStdOut",$script) -Wait -PassThru -RedirectStandardError $err` — plain `& AutoHotkey64.exe` does NOT capture the exit code or stderr because it's a GUI-subsystem app that detaches.

The headless test runner writes its TAP report to `%TEMP%\ergopti_test_results.txt` (NOT stdout) — read that file for pass/fail, not the AHK process stdout. See [[feedback_ahk_source_encoding]].

### Coding style and conventions for this project

*Style rules, architecture decisions, and what to avoid when writing code for this project*

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

### feedback_commit_push

*Never push automatically — commit only after explicit ask, push only after explicit validation*

<sub>slug: `feedback_commit_push`</sub>

**NEVER push without explicit user instruction.** `git push` is always blocked unless the user says "push" or equivalent in that turn.

Commit freely after small autonomous changes, but stop there. Do NOT chain `&& git push` or run `git push` in a follow-up step.

**Why:** User was burned by auto-pushes mid-session while code was in a broken/test state (hardcoded test HTML pushed to remote mid-debug).

**How to apply:**
- After any commit: stop. Do not push. Wait for the user to say "push" or "pousse".
- Step-by-step plan mode (user said "étape par étape, tu valides chacune"): also wait for explicit "ok"/"validé" before committing each step.
- If unsure: commit is OK, push is never OK without explicit instruction.

### feedback_fix_banners_tool

*npm run fix:banners auto-corrects all section banner alignment violations — run it before every commit instead of fixing manually*

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

### feedback-loader-target-explicit

*AHK loader/writer modules that mutate a shared Map (Features etc.) must take the target Map as an explicit parameter, never reach for it via `global`*

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

*Never add Co-Authored-By trailers to commits — including Copilot, Claude, github-actions[bot], or any LLM/tool credit*

<sub>slug: `feedback_no_coauthor`</sub>

Never add `Co-Authored-By:` trailers to commit messages. This includes Copilot, Claude, github-actions[bot], and any other LLM/tool credit.

**Why:** Project convention in `.github/copilot-instructions.md` §6 explicitly forbids it ("No co-author credits: Never add Co-Authored-By trailers. Do not credit any LLM or tool in commit messages."). The user reaffirmed this strongly when I proposed to whitelist legacy Copilot trailers in a meta-test — they want NEW commits to remain clean and don't want me to soften the rule.

**How to apply:** When writing commit messages (Bash heredoc, `git commit -m`, etc.), produce a bare conventional commit with no trailers. Do not whitelist bot trailers in lint/meta tests either — make the test scope only NEW commits (e.g., `origin/dev..HEAD`) so legacy history isn't flagged but future violations are caught.

### feedback-no-push-dev

*Ne jamais pusher sur dev sans validation explicite — chaque commit sur dev déclenche la CI et crée une release*

<sub>slug: `feedback_no_push_dev`</sub>

Ne pas pusher sur `dev` (ni `main`) sans que l'utilisateur ait explicitement demandé un push.

**Why:** Chaque commit pushé sur `dev` déclenche la CI qui crée une release. Pousser à chaque petit fix pollue les releases et consomme inutilement la CI.

**How to apply:** Travailler sur une branche feature/fix, committer localement autant que nécessaire, et ne pusher sur `dev` QUE quand l'utilisateur dit "push" ou "merge". Ne jamais enchaîner commit + push automatiquement sur `dev`.

### feedback-regression-tests

*Every user-requested bug fix must ship with a regression test that fails before / passes after the fix*

<sub>slug: `feedback_regression_tests`</sub>

For every bug the user asks me to fix, I MUST add a unit/regression test that encodes the root cause — failing before the fix, passing after — so the test suite grows strictly more robust over time and that bug can never silently return.

**Why:** the user explicitly wants accumulating coverage ("plus le temps passe et plus nos tests sont robustes"). Every bug hit once should be caught forever; time makes the suite stronger, never weaker.

**How to apply:**
- Fix the bug, then add the test in the suite covering the affected layer: AHK `static/ergopti_plus/windows/tests/`, macOS `static/ergopti_plus/macos/tests/`, or cross-platform `tools/test/`. Run it green before considering the fix done.
- Encode the ROOT CAUSE, not just the symptom — and exploit the harness so a regression actually fails. Example: the `DYN_HOTSTRINGS_DEFAULT_DELAY` startup crash (a menu-build global defined in late-loaded `modules/hotstrings.ahk` instead of the early `hotstrings_config.ahk`) is guarded by a test in `test_hotstrings_config.ahk` asserting the constant is defined — the AHK suite loads `hotstrings_config.ahk` but NOT `modules/hotstrings.ahk`, so moving it back to the module makes it undefined and fails the test.
- Never delete or weaken a regression test to make a change pass; fix the change.

Codified in `.github/copilot-instructions.md` §5.9 (the project rules doc that `CLAUDE.md` @-includes — so it covers project + Claude + Copilot). See [[project_hotstring_delay_architecture]].

### feedback-test-before-merge

*Never merge a cut-over slice into dev before the user has tested it live. Stay on the slice branch and wait for explicit validation.*

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

*All user-facing UI text must go through the i18n system in 21 supported languages — never hardcode any UI string anywhere, including WebView UIs (metrics, download window, etc.).*

<sub>slug: `feedback_ui_must_be_i18n`</sub>

All user-facing text in the ergopti project must be served via the i18n system, in **all 21 supported languages** (ar, cs, da, de, en, es, fr, he, hi, it, ja, ko, nl, no, pl, pt, ru, sv, tr, uk, zh). Locale files live in [[reference-locales-files]] at `static/locales/<lang>.json`.

**Why:** CLAUDE.md already mandates "UI is French, code is English" but in practice the project ships in 21 languages — French was just the dev-time default. Hardcoded French strings in `_shared/ui/metrics_typing/*.js`, `_shared/ui/download_window/*.js`, etc. break the multilingual contract and shame anyone who tries to use the app in another language.

**How to apply:**
- When adding or editing any user-facing UI code (Svelte component, WebView HTML/JS, tray menu label, dialog), the displayed text MUST come from the i18n system, not a string literal.
- For WebView UIs: the JS i18n loader is at `_shared/ui/i18n.js`. Reference keys like `t("menu.hotstrings.autocorrection")`.
- For AHK driver: use `t(key)` from [[lib-i18n-ahk]] (`static/drivers/autohotkey/lib/i18n.ahk`).
- For Hammerspoon driver: use `t(key)` from [[lib-i18n-lua]] (`static/drivers/hammerspoon/lib/i18n.lua` + `lib/locale.lua`).
- When adding a new key, add it to ALL 21 locale JSON files at the same time (machine-translation is acceptable as a first pass, but never leave a key missing from a locale — fallback chain is active→EN→FR but missing keys should still be filled).
- Internal logs and developer-facing comments stay English per CLAUDE.md — this rule applies only to user-visible text.

**Backlog item:** [`_shared/ui/metrics_typing/data.js`, `table.js`, `charts.js`] and [`_shared/ui/download_window/*`] contain extensive hardcoded French. Needs extraction to i18n keys + translation to all 21 languages. Logged in the todo list as "[BACKLOG] i18n WebView extraction".


---

## Project architecture & decisions

### project-ahk-menu-dispatcher-drop

*AHK 2.0 silently drops ~30-50% of tray-menu clicks. FIXED via lib/menu_dispatcher.ahk — every actionable item must use RegisterMenuItem, never raw Menu.Add.*

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

### project-config-v2-refactor

*State of the v2 config schema refactor (Scope C) — branch refactor/config-schema-v2 with 5 dormant commits. Cut-over to actually migrate the AHK driver runtime is the open piece.*

<sub>slug: `project_config_v2_refactor`</sub>

The user is mid-flight on the Scope C refactor — a clean-state rewrite of the Ergopti+ user configuration system, unifying it under a snake_case schema, a single shared features manifest, and a codegen pipeline.

**Why:** the v1 config had drifted into a messy state (AHK using PascalCase mixed with snake_case in the same `config.toml`, HS using snake_case-only, separate `features_config.ahk` hardcoded Map, hand-written TOML loaders that don't support nested sections). The refactor centralises every default in `_shared/features/manifest.toml` and codegen-emits per-driver artifacts.

**How to apply:** when resuming work on this refactor, read in this order:
1. `static/drivers/_shared/config_schema/SCHEMA.md` — design conventions (snake_case, modélisation α for hotstrings, `ahk.`/`hs.` prefixes).
2. `static/drivers/_shared/features/manifest.toml` — single source of truth, 302 features.
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

**Mapping reference** is now committed at `static/drivers/_shared/features/_migration_v1_to_v2.md` (commit 98c34833, 567 lines) — exhaustive v1 → v2 table covering every TOML section, Features path, access pattern, IniCacheGet call site, and a stepped cut-over checklist. Read this top-down before launching the cut-over agent.

**Next decision** — approach for the cut-over: (a) 3 mini-cut-over commits with a temporary compat shim (driver bootable at each step, adds throwaway code), or (b) Big Bang Agent run with the migration document as reference (single sweep across all files, no intermediate boot, cleaner diff but riskier). User has not yet chosen.

**Out-of-scope reminders**: no backward compatibility (clean state — users delete their old config.toml and the driver regenerates from templates at first boot), [[feedback-ui-must-be-i18n]] still applies to all new UI work.

### project_debug_menu_sync

*Debug menu order is defined in shared/menu_manifest.json debug_menu — both AHK and Lua drivers consume it*

<sub>slug: `project_debug_menu_sync`</sub>

The debug submenu order is the single source of truth in `shared/menu_manifest.json` under the `debug_menu` key (an ordered array like `top_level`). Platform-specific items carry a `"platforms": ["ahk"]` or `"platforms": ["hs"]` field; entries without `platforms` appear on both.

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

**Why:** User requires that menu order be defined once in shared/ — never duplicated per-platform.

**How to apply:** To reorder or add debug menu items, only edit `menu_manifest.json`. Both drivers pick it up automatically at next load.

### project-gestures-reversal-detection

*How direction reversals are detected in the gestures engine (x1 vs incremental)*

<sub>slug: `project_gestures_reversal_detection`</sub>

The gestures engine in [engine.lua](../../../../d:/Documents/GitHub/ergopti/static/drivers/hammerspoon/modules/gestures/engine.lua) handles two trigger modes that need different reversal logic.

**Why:** A regression in commit `b1f1e5a2` and earlier designs blanket-returned in `commitGesture` whenever any live fire had happened. That caused 4-finger left-then-right swipes to lose the reversal: user swiped left (fires "space_prev"), reversed quickly to right, lifted before live trigger crossed `LIVE_AXIS_MIN`, and commit refused to fire "space_next".

**How to apply:**

**x1 mode** (4-finger space/expose swipes, 2-finger swipes, 5-finger vertical): commit fires the new direction if `sign(sd) != gs.liveAxisSign`. Block only same-direction double-fires.

**Incremental mode** (3-finger word, 5-finger window): tracks `gs.lastFirePos` on every fire. On each new frame, if movement from `lastFirePos` is >= `LIVE_AXIS_MIN` units in the opposite direction of `liveAxisSign`, rebase `startPos` to current pos immediately. This is much more responsive than the old `diff < 0` fallback which required the user to come all the way back through the original origin.

Both modes must initialise `gs.lastFirePos = nil` in `resetGS()` AND at the start of a new gesture (in the `if not gs.active` branch of `process_frame`).

See also [[project-gestures-startup-design]].

### project-gestures-startup-design

*Design choices for the macOS gestures startup path — primer-as-wakeup-signal vs burst probes*

<sub>slug: `project_gestures_startup_design`</sub>

The Hammerspoon gestures module (`static/drivers/hammerspoon/modules/gestures/`) historically struggled with a cold-start bug: at HS launch, the `hs._asm.undocumented.touchdevice` subscription was attached but received no frames until the user physically touched the trackpad. The user's first gesture was lost; gestures only became responsive ~10s later when the 20s discovery timer fired.

**Why:** IOKit HID dispatch path isn't initialised at HS launch time. The watcher is technically "running" but the OS doesn't route frames to it.

**How to apply:** The current design (cc7abf51, May 2026) combines two mechanisms — do NOT regress to burst probes alone:

1. **Adaptive probe loop** in [init.lua](../../../../d:/Documents/GitHub/ergopti/static/drivers/hammerspoon/modules/gestures/init.lua): recycles watchers every 500ms until first frame, then switches to 20s health-check. Replaces the old fixed `STARTUP_BURST_DELAYS = {0.05, 0.15, ..., 4.5}` which exhausted too early.

2. **Primer-as-wakeup-signal**: the `gesture_primer` eventtap (already subscribed to NSEventTypeGesture and friends to keep the OS gesture dispatch alive) now ALSO triggers an emergency recycle when it sees a gesture-class event before any touchdevice frame has been received. This means the user's first physical gesture *itself* unblocks the pipeline, so the gesture is captured in flight rather than lost.

A 1s cooldown debounces the emergency recycle so a fast burst of gesture events at first contact doesn't trigger several recycles.

The primer also handles `tapDisabledByTimeout`/`tapDisabledByUserInput` by re-engaging itself, and subscribes to more types (`beginGesture`, `endGesture`, `swipe`, `magnify`, `rotate`, `directTouch`, `smartMagnify`) so the dispatch tree initialises fully.

See also [[project-gestures-reversal-detection]].

### project-hotstring-delay-architecture

*Where hotstring expansion delays are configured, the cross-platform precedence, and the key gotchas*

<sub>slug: `project_hotstring_delay_architecture`</sub>

How the hotstring expansion-delay (TimeActivationSeconds / typing-speed gate) is configured across both drivers. Mapped 2026-06-04 building the per-section delay feature (comma_j → 5s). See [[project_hotstring_engine_internals]].

**Source of truth = the shared per-category TOML**, `static/ergopti_plus/shared/hotstrings/<category>.toml`:
- `[_meta] delay = <s>` — the group/category delay.
- `[_meta.section_delays]` block (`<section> = <s>` lines) — per-section overrides, e.g. `comma_j = 5`.
- NOT `features/manifest.toml`'s `time_activation_seconds` — that field is **test-only metadata** (only `test-manifest-equivalence.cjs` reads it); it does NOT drive the runtime delay. Don't edit it expecting an effect.

**Precedence (both platforms, highest first):** user override → TOML section delay → TOML group delay → menu-set global default → hardcoded fallback.

**AHK:** `HotstringsResolve(cat, sec).Delay` resolves it: `UserSec → UserCat → TomlSec → TomlCat → _HotstringsOverrides["_global"].Delay → GLOBAL_DEFAULT_DELAY (0.75)`. The `_global` key is the **menu-set default expansion delay** (tray: Delays submenu → "default delay" item; persisted via `HotstringsSetOverride("_global","","delay",s)`). The AHK loader (`toml_loader.ahk` `ParseTomlGroupConfig`) reads `[_meta.sections.<name>]` AND `[_meta.section_delays]` into `Sections[x].Delay`. The AHK `Terminators` class in `_generated/terminators.ahk` is dormant (unused) — unrelated to this.

**macOS (Hammerspoon):** per-GROUP `CoreState.DELAYS[group]` (seeded from hardcoded `DELAYS_DEFAULT` + user prefs) + per-section `CoreState.SECTION_DELAYS[section]` (loaded from the shared TOML's `[_meta.section_delays]` via the shared `toml_codec/reader.lua`, which handles `[_meta]`, `[_meta.sections]` inline lang-maps, `[_meta.sections.<name>]`, and `[_meta.section_delays]`). `mapping_fires` applies the precedence (a group delay differing from its default = a user override and wins over the section delay). Each mapping (incl. generated `;`/nbsp/nnbsp aliases) is tagged with `entry.section`. Section delays are folded into `WORD_TIMEOUT_SEC` (`recompute_word_timeout`) so a long window (5s) is not cut short by the inactivity wipe. macOS does NOT read the TOML group `[_meta] delay` (uses the hardcoded `DELAYS_DEFAULT`); only section delays come from the TOML.

**Cross-platform Delays-submenu parity (added 2026-06-04, branch `feat/comma-j-expansion`).** Both drivers' hotstrings "Delays" submenu now surfaces the same set of quick delay items: default expansion delay, ★ magic-key, autocorrection, AI-prediction timeout, and dynamic-hotstrings (HS also keeps it; AHK gained all of them). Key implementation facts:
- **★ + autocorrection** are real TOML-backed categories (`magickey.toml` `[_meta] delay = 2.0`, `autocorrection.toml` = 1.0). On macOS the quick item must read via `hotstrings_config.resolve(cat,nil).delay` and write via `set_override` + `set_delay` (NOT the `make_delay_item`/`state.delays` path, which is in-memory-only and would desync from the config window). AHK uses `HotstringsResolve`/`HotstringsSetOverride` — `_HS_CategoryDelayLabel`/`_HS_PromptCategoryDelay(cat, i18nKey, DefaultSec:="")` in `tray_menu.ahk`.
- **AHK llm_prediction + dynamichotstrings have NO category TOML** — `ParseTomlGroupConfig` silently returns an empty cached config for a missing file (no log noise), so they're used as **pseudo-category override keys**: default is a code constant (`UI_LLM_TIMEOUT_SEC`=20s in `shared/tooltip/constants.toml`; `DYN_HOTSTRINGS_DEFAULT_DELAY`=2.0 in `modules/hotstrings.ahk`), override persisted via `HotstringsSetOverride("llm_prediction"/"dynamichotstrings",...)`. This avoided a 6-file `_LLM_Tray` plumbing route and the `build-hotstrings.cjs` enumeration risk of adding fake category TOMLs. The LLM tooltip timer (`lib/tooltip.ahk` ~1209) resolves the override live (applies without restart); AHK category-delay changes otherwise apply on restart (registered `TimeActivationSeconds` is read at startup).
- **AHK dynamic phone/SSN/IBAN prefix hotstrings were rewritten from native `Hotstring()` to HSE `CreateHotstring`** so they honour `TimeActivationSeconds` (they had none). `_HotstringDispatch` calls a callable `Replacement`, so `(*) => SendFinalResult(V)` became `(*) => V` + `FinalResult:True`; `OnlyText:True` also fixed a latent `+33…` SendInput modifier-interpretation bug. The `@np` personal-info expansions were already HSE and left firing instantly (out of scope). `IsTimeActivationExpired` treats `<=0` as "no gate".
- **i18n**: two NEW keys `menu.hotstrings.delay_magic_key` / `delay_autocorrection` added to all 21 locales (the existing `tooltip_magic`/`tooltip_autocorrect` are PREVIEW labels, not delay labels). Reused `tooltip_ai_acceptance` / `tooltip_autocompletion` for the AI/dynamic items. Locale files are UTF-8 **BOM + CRLF + tab + NOT globally sorted** — insert keys via targeted text insertion at the alphabetical position, never full reserialize (would rewrite all 2144 keys). `tools/locale/check_locales.py` points at a stale `tools/static/locales` path but the parity rule (every locale mirrors `en.json`) still holds.
- **Test fixes (committed)**: `lib/locale.lua` Windows path-separator bug (forward-slash-only dirname regex dropped the `lib` segment when `package.searchpath` injected a backslash); two stale purity baselines re-anchored (852→862, 61→63) in `tests/meta/test_port_adapter_coverage.lua`.

All AI-timeout + dynamic-delay behaviour is AHK-side and **UI/runtime — NOT covered by the headless suite; needs live-testing on Windows**. Suites: macOS 1215/0, AHK 1052/0.

All of the above lives on branch `feat/comma-j-expansion` (not yet merged to dev as of 2026-06-04).

### project-hotstring-engine-internals

*AHK prefix-watcher InputHook captures synthetic input; OnChar must feed each char once; AHK vs Hammerspoon word-boundary framing divergence is intentional*

<sub>slug: `project_hotstring_engine_internals`</sub>

Hard-won internals of the ErgoptiPlus hotstring matching engine (Windows AHK + macOS Hammerspoon). Discovered 2026-06-04 while fixing the comma-layer/nnbsp + vowel → capital-J expansion.

**AHK prefix watcher InputHook captures synthetic output.** The watcher's InputHook is created `InputHook("V L0")` — no `I0` flag — so it observes input injected by `SendEvent`/`SendInput` too (the comment says injected keystrokes must reach the watcher). Therefore `SendNewResult(...)` output flows back through `_OnPrefixChar` → `HSE_FeedChar` into `HSE_Buffer`. The whole `HSE_Suppressed` / `PrefixWatcherSuppress` machinery exists only to filter the engine's OWN expansion bursts so they don't re-feed. Do NOT assume `SendEvent` bypasses the watcher — it does not.

**OnChar must feed each char exactly once.** `_OnPrefixChar` feeds every char at the top (where end-char/star matches fire). A historical bug also re-fed word-terminators in the boundary branch, so `;`/`:` landed in `HSE_Buffer` twice (`nnbsp::e`), silently breaking any trigger that contains a terminator as a NON-final char (the J triggers). Fixed by removing the boundary-branch re-feed. macOS appends once in the init.lua keyDown loop and never had this bug. If you touch the boundary branch, never re-feed.

**`HSE_WORD_TERMINATORS`** (hotstring_engine_main.ahk) is the engine's base separator set; it is hand-maintained (NOT the codegen `_generated/terminators.*`, which is the user-configurable catalogue). Spell apostrophes as `Chr(0x27) . Chr(0x2019)` — a typography pass once silently rewrote the ASCII apostrophe to a second U+2019, dropping U+0027.

**Cross-platform word-boundary framing differs by design.** AHK uses a terminator-ALLOWLIST (`_HSE_WordBoundaryAllows`: fire only if the char before the trigger is in `HSE_WORD_TERMINATORS` or start-of-buffer). Hammerspoon uses a letter-DENYLIST (`word_boundary_blocks` → blocks if `text_utils.is_letter_char(prev)`; Lua `%w` = letters+digits, NOT underscore). They AGREE for all normal French input (space/punct/apostrophe → fire; letter/digit → block). They diverge ONLY for exotic preceding chars (hyphen, `_`, `(`, `/`): macOS fires, AHK blocks. This is low-impact and "best" is genuinely ambiguous — left intentionally unaligned. Don't "fix" it without a concrete user need. The comma→J bare `;` trigger is in-word on BOTH (AHK `*?C`; macOS via the leading-`;` skip in `word_boundary_blocks`) so the capital J is guaranteed in every context — bare `:` is deliberately NOT a trigger. See [[project_keymap_architecture]].

### Keymap module architecture and refactor decisions

*Structure of the keymap module, where defaults live, which files do what*

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

### project-locale-parity-test

*en.json is the canonical key set; tools/check_locales.py enforces parity in CI*

<sub>slug: `project_locale_parity_test`</sub>

`static/locales/en.json` is the canonical reference. Every other locale
file must mirror its key set exactly — no missing, no extra.

**Why:** Stale keys (removed from EN but lingering in translations) and
missing keys (added to EN but not yet translated) both ship as bugs.
The CI workflow `.github/workflows/test_locales.yml` runs
`tools/check_locales.py` on every push touching `static/locales/` and
fails on any drift.

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

### project_metrics_pipeline_17

*AHK metrics pipeline — bug #17 CLOSED, follow-up bugs fixed*

<sub>slug: `project_metrics_pipeline_17`</sub>

Bug #17 "metrics population" on Windows/AHK. Verified 2026-06-02 via a 5-agent mapping workflow + live DB inspection (`D:\Documents\GitHub\config\ergopti_plus\metrics\by_device\6b399146-3e75-fe4a-aab3-c1d0c68a2b19\compact_work.db`, query with `python` not python3).

**Architecture (verified):** Dashboard data = prefetch (`keylogger_prefetch.ahk` KLPF_BuildAndWrite → `keylogger_reader.ahk` KLR_BuildDatabase → manifest JSON in A_Temp). KLR loads ALL devices' data.sql (all-time `events_*`) into a cached `:memory:` db, then every cycle Clear→Rebuild→Inject: KLR_ClearAggregates wipes agg_*/ngram_*; KLR_RebuildAggregates recomputes SQL-derivable aggregates from events_* (all-time); KLR_InjectKlwBatch drains the live KLW.batch (recent-only). AHK deliberately does NOT persist aggregates (anti-bloat, ~140MB/day) — that's why the SQL rebuild exists. `compact_work.db` is a separate launcher debug artifact, NOT the dashboard source. macOS (`macos/.../aggregator.lua`) is single-source (the walk owns ALL agg tables, persisted per tick) — the dashboard JS (`shared/ui/metrics_typing/data.js`, `metrics_apps/script.js`) is written against macOS semantics.

**Convergent target:** SQL rebuild = single source for everything computable from events_*; walker = single source ONLY for char-level/ngram tables (ngrams, kc_hold, buckets, errors, ergo, chars_class, burst, session, layouts) + enrichment columns SQL can't compute. AHK can't go pure-walker like macOS without reintroducing the bloat.

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
6. hs_suggested missing → added INSERT COUNT(*) WHERE kind='suggested' + manifest projection.
7. Reset button no-op on Windows → fixed: JS postMessage + AHK clear_cache handler purges all 3 cache layers (KLPF_MANIFEST_CACHE, KLRCache, KLPF_LAST_JSON) + disk file.
8. Empty dashboard on first run / after metrics folder delete → fixed: KLR_BuildDatabase early-return when by_device/ absent now runs KLR_RebuildAggregates+KLR_InjectKlwBatch before returning.

**Known remaining gaps (non-blocking):**
- app_time shows old garbage for pre-idle-fix events_app_switch rows (historical only, new data clean).
- chars includes [BS] keystrokes — matches macOS semantics, intentional.
- LLM path unused so llm_chars=0 and esrc llm attribution unverifiable until LLM is used.

**Lint:** pre-commit husky hook runs `lint-conventions.js --fail-on-violations` and NOW BLOCKS on violations. Always `npm run fix:all` before committing.

### project-suspend-pause-invariant

*Pause must fully silence ALL features (no tooltip/LLM/keylogger/widget). AHK Suspend only disarms hotkeys — InputHooks/timers/OnMessage bypass it and need explicit A_IsSuspended guards.*

<sub>slug: `project_suspend_pause_invariant`</sub>

When the script is paused, ABSOLUTELY nothing may activate — no tooltip, no LLM prediction/HTTP, no keylogger recording, no WPM widget, no gesture action. User words: « comme ahk éteint donc absolument aucun tooltip ou autre truc ahk ne doit s'activer ». Fixed 2026-06-02.

**Why it's a trap:** native AHK `Suspend()` only disarms **Hotkeys/Hotstrings**. It does NOT touch `InputHook` callbacks, `SetTimer` callbacks, `OnMessage` handlers, or `SetWinEventHook` — all keep firing while `A_IsSuspended`. The whole ErgoptiPlus input pipeline is built on those, so pausing silenced remaps but left tooltips/LLM/keylogger fully live.

**The invariant (AHK):** every InputHook/timer/OnMessage callback that produces an observable side effect MUST early-return on `A_IsSuspended`. Guards live at: `HookDispatcher.Dispatch` (hook_dispatcher.ahk — covers LLM bridge + keylogger watchers), `_OnPrefixChar`/`_OnPrefixKeyDown` (hotstring_prefix_watcher.ahk — its OWN InputHook, NOT via HookDispatcher), `KL_Hook_OnChar`/`KL_Hook_OnKeyDown` (keylogger_hook.ahk — own InputHook), `LLM_Engine_FirePrediction`, `TooltipShow`+`LLM_TooltipShow` (lib/tooltip.ahk render entries), `WPMWidget_Tick`, `GestureSimulateActivity`. **When you add any new hook/timer/tooltip path, add the guard or it leaks while paused.** Lower-priority keylogger timers (idle tick, mouse-park, roi half-life, session/power OnMessage) are NOT yet guarded — guard them too if total radio-silence is wanted.

**Central reactor:** `ToggleSuspend` (ErgoptiPlus.ahk) calls `Ergopti_OnSuspendEnter()` (force-hide both tooltips + `LLM_Engine_CancelTimer`) / `Ergopti_OnSuspendResume()` (`_ResetPrefixBuffer`). A 500 ms `_SuspendStateWatchdog` (global `_LastSuspendState`) replays the reactor for suspend transitions that bypass ToggleSuspend (native Pause, external trigger). The AltGr script combos are registered "S" suspend-exempt so the user can un-pause — see [[project-ahk-menu-dispatcher-drop]] neighbourhood and the Kana fixup [[feedback-ahk-source-encoding]] is unrelated.

**macOS parity:** pause is a soft multi-flag in `modules/shortcuts/script_control.lua` (`_is_paused`, `is_paused()`); the keymap eventtap early-returns on `CoreState.processing_paused` so the preview/hotstring path is already gated. Gaps closed for parity: `pause_all()` now calls `_keymap.reset_predictions()` + `ui.tooltip.hide_forced()`; gestures `triggerLiveAxisIfNeeded` gained `if not _state.enabled then return end`; `prediction_engine.perform_check` reads `package.loaded["modules.shortcuts.script_control"].is_paused()`. Background warmup HTTP + keylogger already check pause.

### project-touchdevice-dormancy-is-kernel

*Definitive answer that macOS touchdevice subsystem CANNOT be activated before first physical touch — it is a kernel-driver gate*

<sub>slug: `project_touchdevice_dormancy_is_kernel`</sub>

The macOS `hs._asm.undocumented.touchdevice` watcher reports `running=true` immediately after `:start()` but delivers no frame callbacks until the user physically touches the trackpad. **This is impossible to bypass from userspace and should not be re-investigated.**

**Why:** The streaming gate is in the kernel-side `AppleMultitouchDriver` / `AppleHSSPIHIDDriver`. `MTDeviceStart` arms the callback path but does not prime the sensor. The driver only pushes frames upstream when the HID sensor reports non-zero contact — there is no "send empty frame" path in the kernel-side driver, so no userspace symbol can synthesize one.

Every approach has been verified to fail on built-in Apple Silicon trackpads:
- All MT* symbols in MultitouchSupport.framework audited (asmagill's reverse-engineered header is the most complete public source) — none wake/prime the device.
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

*AHK UIs must use Gui_HarmoniseButtonWidths instead of hardcoded w-values; HS auto-sizes via CSS padding*

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

