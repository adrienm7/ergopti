# Project Memory

Accumulated engineering knowledge for this repository — gotchas, architecture decisions, and working conventions, kept here so every future developer, LLM agent, and reviewer can rely on the same hard-won context. Each entry below was a discrete lesson learned while working on the codebase.

> Maintained as a single in-repo source of truth. When you learn something non-obvious about this codebase (a foot-gun, an architectural invariant, a convention the user insists on), add an entry under the right section rather than letting it evaporate. Keep entries factual and link related ones by their slug in `[[brackets]]`.

## Contents

- [feedback-ahk-source-encoding](#feedback-ahk-source-encoding) — AHK v2 source files must be UTF-8 BOM + LF; encoding drift causes silent mid-file parse aborts that masquerade as missing tests
- [feedback-ahk-suspend-prefix-latch](#feedback-ahk-suspend-prefix-latch) — AHK custom-combination prefix flags latch across Suspend; fix at the source, synthetic key events cannot clear them
- [feedback_ahk_ui_syntax_validation](#feedback_ahk_ui_syntax_validation) — Some AHK UI files are outside the headless test runner; how to syntax-check them locally on Windows
- [Coding style and conventions for this project](#coding-style-and-conventions-for-this-project) — Style rules, architecture decisions, and what to avoid when writing code for this project
- [project-lua-closure-before-local-nil-global](#project-lua-closure-before-local-nil-global) — A `local` declared textually AFTER a closure that uses it is not captured — the closure binds the nil global, and the hs.task/ShellRunner pcall swallows the resulting error silently
- [project-hs-sentinel-key-misfire](#project-hs-sentinel-key-misfire) — F13/F14/F15 are real physical keys macOS can emit; using them as Karabiner synthetic sentinels without gating on the right-AltGr state fires `script_suspend`/`script_reload`/`script_quit` on a bare key press
- [project-hs-purity-ratchet-counts-comments](#project-hs-purity-ratchet-counts-comments) — The `hs.*` purity ratchet counts the substring `hs.` everywhere — comments and string literals included — so a comment mentioning `hs.timer.new` increments the counter
- [feedback_commit_push](#feedback_commit_push) — Never push automatically — commit freely, push only after an explicit ask in the current conversation
- [feedback-proactive-memory](#feedback-proactive-memory) — Record non-obvious learnings in this file proactively at the end of every task, without being asked
- [feedback_fix_banners_tool](#feedback_fix_banners_tool) — npm run fix:banners auto-corrects all section banner alignment violations — run it before every commit instead of fixing manually
- [errors-only-log-sink](#errors-only-log-sink) — Dedicated daily ErgoptiPlus_errors_YYYY-MM-DD.log (WARNING + ERROR only); crash_reports/ strictly for uncaught fatal exceptions
- [feedback-loader-target-explicit](#feedback-loader-target-explicit) — AHK loader/writer modules that mutate a shared Map (Features etc.) must take the target Map as an explicit parameter, never reach for it via `global`
- [No co-author trailers (Copilot, Claude, bots)](#no-co-author-trailers-copilot-claude-bots) — Never add Co-Authored-By trailers — and never whitelist legacy ones to make a lint pass
- [feedback-regression-tests](#feedback-regression-tests) — Every user-requested bug fix must ship with a regression test that fails before / passes after the fix
- [feedback-local-gate-mirrors-ci](#feedback-local-gate-mirrors-ci) — Green locally must mean green in CI: the local gate is four commands, and it is only trustworthy once `node_modules` is installed on a Node satisfying the engine floor
- [feedback-test-before-merge](#feedback-test-before-merge) — Never merge a slice into dev before the user has tested it live. Stay on the branch and wait for explicit validation.
- [feedback-ui-must-be-i18n](#feedback-ui-must-be-i18n) — All user-facing UI text goes through the i18n system in 21 languages — never hardcode a UI string anywhere, WebView UIs included
- [project-ahk-menu-dispatcher-error-swallow](#project-ahk-menu-dispatcher-error-swallow) — The menu-dispatcher bypass must re-throw callback errors — a local try/catch only destroys reporting
- [project-audit-2026-07-21-open-items](#project-audit-2026-07-21-open-items) — Troisieme et quatrieme passes d'audit AHK : les pistes refutees a ne pas re-soulever, et deux decisions qui ne sont pas des correctifs
- [project-typing-latency-tooltip-coldstart](#project-typing-latency-tooltip-coldstart) — Latence de frappe : pourquoi la reutilisation de fenetre tooltip est rejetee, pourquoi le chunking de l'enregistrement differe a ete reverte, et pourquoi WebView2 a quitte le chemin de frappe
- [project-ahk-menu-dispatcher-drop](#project-ahk-menu-dispatcher-drop) — AHK 2.0 perd silencieusement ~30-50 % des clics du menu tray. Contourne par lib/menu_dispatcher.ahk — tout item actionnable doit passer par RegisterMenuItem, jamais par Menu.Add brut.
- [project-audit-2026-07-21-toml-onboarding](#project-audit-2026-07-21-toml-onboarding) — Regles durables sorties de l'audit de `lib/toml/` et `ui/onboarding/` : ou parse-t-on, comment signale-t-on un echec de lecture, et le piege de la sentinelle
- [project-ahk-unreadable-config-persists-defaults](#project-ahk-unreadable-config-persists-defaults) — A config reader that returns "" on a locked file makes the next save persist DEFAULTS over the user's real config — the TOML_ReadFailed rule exists but is unapplied at five readers
- [project-audit-ahk-2026-07-21-adversarial](#project-audit-ahk-2026-07-21-adversarial) — Fifth adversarial AHK pass: 52 confirmed / 10 refuted, full list in AUDIT_AHK_2026-07-21.md; two confident false-positives killed by measurement
- [project-webview2-bridge-gotchas](#project-webview2-bridge-gotchas) — Hosting a shared HTML/JS frontend in a WebView2 control (thqby `vendor/WebView2.ahk`) on Windows has FOUR distinct gotchas that each silently break the JS↔AHK bridge. The onboarding wizard (`ui/onboarding/webview.ahk`) hit all four in sequence; model_browser predates some of the fixes.
- [project-config-v2-refactor](#project-config-v2-refactor) — La migration v1 → v2 est terminee ; ne restent que les gotchas transversaux qu'elle a mis au jour
- [project_debug_menu_sync](#project_debug_menu_sync) — L'ordre du sous-menu Debug est defini une seule fois dans `_shared/modules/menu/menu_manifest.json` (cle `debug_menu`) ; les deux drivers le consomment
- [project-menu-manifest-macos-hotstrings-layout-gap](#project-menu-manifest-macos-hotstrings-layout-gap) — macOS never reads menu_manifest.json's hotstrings_menu/layout_menu keys (unlike gestures_menu/metrics_menu/shortcuts_menu, which ARE manifest-driven on both platforms) — a drift gate exists, the actual migration does not
- [project-gestures-reversal-detection](#project-gestures-reversal-detection) — Detection des inversions de direction dans le moteur de gestes (mode x1 vs incremental)
- [project-gestures-startup-design](#project-gestures-startup-design) — Choix de conception du demarrage des gestes macOS — le primer sert de signal de reveil, PAS des burst probes
- [project-hotstring-delay-architecture](#project-hotstring-delay-architecture) — Ou se configure le delai d'expansion des hotstrings, la precedence cross-driver, et les pieges
- [project-hotstring-engine-internals](#project-hotstring-engine-internals) — OnChar doit alimenter chaque caractere une seule fois ; la divergence de cadrage des frontieres de mot AHK vs Hammerspoon est intentionnelle
- [project-hs-perf-profilers-and-case-conform](#project-hs-perf-profilers-and-case-conform) — Profilers boot/hot-path macOS, chemin rapide case-conform, cache du menubar, snapshot TOML, et le piege Escape arme au premier affichage
- [project-tooltip-shared-style](#project-tooltip-shared-style) — Tooltip visual style is shared across drivers via _shared/modules/tooltip/constants.toml; the macOS stacked canvas rounds its colored rows via an hs.canvas clip; per-driver alphas are intentionally different
- [project-hs-script-quit-kills-karabiner](#project-hs-script-quit-kills-karabiner) — The quit shortcut os.exit()s and bypasses the shutdown callback, so it must kill Karabiner itself
- [project-hs-onboarding-config-schema](#project-hs-onboarding-config-schema) — The first-run wizard must write the canonical HS config schema, and the "ready" notification was removed
- [Keymap module architecture and refactor decisions](#keymap-module-architecture-and-refactor-decisions) — Ou vivent les defauts du module keymap, et pourquoi une seule place
- [project-hs-synthetic-injection-choke-point](#project-hs-synthetic-injection-choke-point) — The macOS driver tracks self-emitted synthetic keystrokes in TWO independent places; any injector that bypasses the expander choke point desyncs them and can corrupt typed output
- [project-locale-parity-test](#project-locale-parity-test) — en.json est le jeu de cles canonique ; le meta-test AHK test_locale_json_valid.ahk impose la parite en CI ; `tools/locale/check_locales.py --fix` est l'outil de backfill manuel
- [project-locale-fast-cache](#project-locale-fast-cache) — Le `.tsv` de locale du driver Windows est un cache gitignore auto-reparateur regenere depuis le `.json` canonique ; seul le `.json` est versionne
- [project_metrics_pipeline_17](#project_metrics_pipeline_17) — Architecture du pipeline metrics AHK — pourquoi AHK ne peut pas devenir pur-walker comme macOS
- [project-hotstring-live-rebuild](#project-hotstring-live-rebuild) — Hotstring section/category toggles apply in-process (no Reload) by re-running RegisterAllHotstrings; native-engine + layout-backed features under hotstrings.\* are the reload-only exceptions
- [project-hotstrings-self-healing-cache](#project-hotstrings-self-healing-cache) — Les hotstrings groupees ne sont plus de l'AHK genere et versionne : c'est un cache `.tsv` gitignore auto-reparateur reconstruit depuis les TOML au runtime, pour couper le parse au boot
- [project-prefix-index-rebuild-cost-is-cold-disk](#project-prefix-index-rebuild-cost-is-cold-disk) — The prefix-watcher index rebuild's cost is the cold-disk TOML read, NOT parse CPU — build the index from the in-memory `_HS_CACHE_ROWS`, the same way HSE registration does.
- [project-suspend-pause-invariant](#project-suspend-pause-invariant) — La pause doit TOUT taire (aucun tooltip/LLM/keylogger/widget). Le Suspend AHK ne desarme que les hotkeys — InputHooks, timers et OnMessage le contournent et exigent des gardes `A_IsSuspended` explicites.
- [project-macos-llm-runtime-enable-gate](#project-macos-llm-runtime-enable-gate) — macOS must not warm up or load an LLM model from profile/model restoration alone; only the live runtime enable gate may authorize warmup side-effects.
- [project-macos-eventtap-no-blocking](#project-macos-eventtap-no-blocking) — Never run blocking work (osascript / hs.execute subprocesses) synchronously inside an hs.eventtap callback — macOS disables the tap (kCGEventTapDisabledByTimeout) and the shortcut dies. Defer with hs.timer.doAfter(0, …).
- [project-macos-script-control-tap-lifecycle](#project-macos-script-control-tap-lifecycle) — The script-control eventtap (AltGr+Enter/Backspace/Escape) is keycode-based and must survive layout switches AND pause — never restart it via `shortcuts.stop()`/`shortcuts.start()`, and never let a pause-driven layout switch regenerate the Karabiner config.
- [project-touchdevice-dormancy-is-kernel](#project-touchdevice-dormancy-is-kernel) — Definitive answer that macOS touchdevice subsystem CANNOT be activated before first physical touch — it is a kernel-driver gate
- [project-ui-dynamic-buttons](#project-ui-dynamic-buttons) — AHK UIs must use Gui_HarmoniseButtonWidths instead of hardcoded w-values; HS auto-sizes via CSS padding
- [project-shifted-comma-case-variants](#project-shifted-comma-case-variants) — The "uppercase" form of a comma/apostrophe/period in case-variant generation MUST be nbsp/nnbsp + punctuation, NEVER a plain ASCII space — anchoring on nbsp is what keeps the ":D" emoji alive.
- [project-ahk-v2-semicolon-in-string](#project-ahk-v2-semicolon-in-string) — AHK v2 treats ` ;` (space-then-semicolon) as a comment start even INSIDE a double-quoted string literal — a literal `;` in an AHK string causes a "Missing `"`" parse error.
- [project-hs-timer-callback-errors-invisible](#project-hs-timer-callback-errors-invisible) — Hammerspoon swallows a throw inside an `hs.timer` callback — that silent-death class is now captured by `logger.install_runtime_error_capture()`, which must stay installed. The surviving trap is a test stub that defines a method production lacks.
- [project-profile-label-placeholder-convention](#project-profile-label-placeholder-convention) — LLM profile labels in `_shared/data/locales/*.json` use **brace** placeholders `{n}`/`{s}` (count + plural-s), NOT printf `%d`/`%s` — the menu substitutes braces, so a printf token leaks verbatim into the UI.
- [project-updater-nonblocking-http](#project-updater-nonblocking-http) — The updater background poll must never do synchronous WinHttp on the main thread (it freezes all keyboard remapping); WinHttp `SetTimeouts` treats 0 as infinite. Use the project's async WinHTTP + `WaitForResponse(0)` + `SetTimer`-poll pattern.
- [project-audit-tracking-artifacts-are-unreliable](#project-audit-tracking-artifacts-are-unreliable) — An audit's own tracking JSONs and roadmap `[x]` checkboxes contradict each other and the source — ground truth is the code, located by SYMBOL, never by the line numbers in a finding.
- [project-hs-adapter-contract-violations](#project-hs-adapter-contract-violations) — Four Hammerspoon API contract facts a plausible-looking call gets wrong — found dormant in the macOS adapters.
- [project-ahk-v2-static-unset-unreadable](#project-ahk-v2-static-unset-unreadable) — In AHK v2, `static _prop := unset` leaves the property unreadable — accessing it with `is` or any read raises PropertyError. Use `false` (or another concrete value) as the "not yet set" sentinel.
- [project-lua-nil-and-expr-is-nil](#project-lua-nil-and-expr-is-nil) — In Lua, `local x = cond and expr` yields **nil**, not false, when `cond` is nil — and `not nil` is `true`, so a "negative" gate silently inverts.
- [project-ahk-invariant-incomplete-application](#project-ahk-invariant-incomplete-application) — Every AHK-driver hardening invariant is applied per call-site; the recurring bug is the one missed sibling site, or a guarantee defeated one call level down by indirection — audit the whole class, not the documented site.
- [project-toml-cache-returns-real-booleans](#project-toml-cache-returns-real-booleans) — A TOML `true` reaches the cache as an AHK boolean, not the string "true" — compare through `TomlCacheBool`, never `StrLower(v) == "true"`
- [project-ahk-map-delete-raises-on-missing-key](#project-ahk-map-delete-raises-on-missing-key) — `Map.Delete(k)` throws when the key is absent, and `/validate` only syntax-checks when it PRECEDES the script path
- [project-ahk-probing-synthetic-input](#project-ahk-probing-synthetic-input) — Two ways a synthetic-input probe silently measures nothing and reports a confident false negative
- [project-ahk-keyword-as-variable-hangs-the-parser](#project-ahk-keyword-as-variable-hangs-the-parser) — Naming a local `Catch` (or any control-flow keyword) makes AHK v2 hang with ZERO output — no syntax error, no dialog, no partial log
- [project-ahk-numeric-string-equals-false](#project-ahk-numeric-string-equals-false) — In AHK v2, `"0" = false` is **TRUE** — comparing a `String|false` return value against `false` silently swallows any numeric-string success token
- [project-ahk-guard-tests-must-loop-the-class](#project-ahk-guard-tests-must-loop-the-class) — A regression test that pins the single site a bug was fixed at will not survive the next refactor — write guard tests as loops over a set enumerated from source.
- [project-audit-findings-are-hypotheses](#project-audit-findings-are-hypotheses) — Two findings from the 2026-07-20 second-pass audit were WRONG, and the existing test suite is what proved it — implement an audit finding as a hypothesis, not as an instruction
- [project-audit-evidence-must-be-reproducible](#project-audit-evidence-must-be-reproducible) — A refutation is a claim and needs the same standard of proof: the 2026-07-20 "the perf section was fabricated" debunking was ITSELF wrong — it looked in a directory that never existed
- [project-ahk-test-suite-critical-leak](#project-ahk-test-suite-critical-leak) — `Critical("On")` in a layout/hotkey callback is safe in production but LEAKS into the main thread when a test invokes that function directly, silently freezing every background timer for the rest of the suite.
- [[updater-download-suspend-guard] Garantie G5: background downloads bypass pause](#updater-download-suspend-guard-garantie-g5-background-downloads-bypass-pause)
- [[project-shared-tree-layout] _shared/ tree : SSOT-par-couche, et le piege du contournement](#project-shared-tree-layout-_shared-tree-ssot-par-couche-et-le-piege-du-contournement)
- [[project-macos-initlua-no-compile-coverage] Un fichier que le harness ne peut que *copier* a quand meme besoin d un controle de *parsing*](#project-macos-initlua-no-compile-coverage-un-fichier-que-le-harness-ne-peut-que-copier-a-quand-meme-besoin-d-un-controle-de-parsing)
- [[project-hs-fs-dir-drops-state] `hs.fs.dir` renvoie (iterator, state) — et un stub laxiste a masque l etat perdu](#project-hs-fs-dir-drops-state-hsfsdir-renvoie-iterator-state-et-un-stub-laxiste-a-masque-l-etat-perdu)
- [[project-healthcheck-stale-api] Une sonde gardee par `pcall`/`type` est INVISIBLE aux tests bases sur le crash](#project-healthcheck-stale-api-une-sonde-gardee-par-pcalltype-est-invisible-aux-tests-bases-sur-le-crash)
- [[project-macos-split-module-stub-reload] Splitting a stateful macOS module out of its caller requires adding it to `load_with_stubs`' reload list](#project-macos-split-module-stub-reload-splitting-a-stateful-macos-module-out-of-its-caller-requires-adding-it-to-load_with_stubs-reload-list)
- [[project-macos-reload-during-git-pull] Auto-reload watchers must defer the reload while a git operation is rewriting the working tree](#project-macos-reload-during-git-pull-auto-reload-watchers-must-defer-the-reload-while-a-git-operation-is-rewriting-the-working-tree) — a `git pull` against a live driver made an auto-reload pathwatcher fire hs.reload() mid-pull, booting init.lua against a half-updated tree that died with no config and no watchers; both file-driven watchers now gate on git_status
- [[project-md-gate-needs-eol-lf] A byte-compared generated `.md` doc needs `eol=lf`, or a Windows CRLF checkout fails the gate locally](#project-md-gate-needs-eol-lf-a-byte-compared-generated-md-doc-needs-eollf-or-a-windows-crlf-checkout-fails-the-gate-locally) — the architecture-diagram gate compares architecture.md byte-for-byte; core.autocrlf rewrote it to CRLF on Windows so the LF comparison failed locally though CI (Linux) was green
- [[project-init-json-decode-of-toml] `pcall(hs.json.decode, …)` imprime quand meme l erreur native LuaSkin](#project-init-json-decode-of-toml-pcallhsjsondecode-imprime-quand-meme-l-erreur-native-luaskin)
- [[project-macos-startup-winfilter-cost] Ne jamais creer un `hs.window.filter` sur un chemin de boot ou de premiere frappe](#project-macos-startup-winfilter-cost-ne-jamais-creer-un-hswindowfilter-sur-un-chemin-de-boot-ou-de-premiere-frappe)
- [[project-category-gating-ahk-only] Category enable/disable gating (CategoryEnabled["Hotstrings"]…) is intentionally AHK-only](#project-category-gating-ahk-only-category-enabledisable-gating-categoryenabledhotstrings-is-intentionally-ahk-only)
- [[project-macos-lib-namespace-shims] `lib.text_utils` est un shim de re-export load-bearing, pas de l indirection supprimable](#project-macos-lib-namespace-shims-libtext_utils-est-un-shim-de-re-export-load-bearing-pas-de-l-indirection-supprimable)
- [[project-hs-audit-open-labels-are-stale] Les labels <<Open>> des audits archives sont non verifies — relire la source](#project-hs-audit-open-labels-are-stale-les-labels-open-des-audits-archives-sont-non-verifies-relire-la-source)
- [[project-dc1-windows-vk-finger-map-gap] `KLW_VK_FINGER` est une 3e carte de doigts laissee expres, pas une regression](#project-dc1-windows-vk-finger-map-gap-klw_vk_finger-est-une-3e-carte-de-doigts-laissee-expres-pas-une-regression)
- [[project-ahk-suite-runnable-here-plus-os-purity-ratchet-nondeterminism] La suite AHK EST executable sur cette machine — lire le resultat dans %TEMP%](#project-ahk-suite-runnable-here-plus-os-purity-ratchet-nondeterminism-la-suite-ahk-est-executable-sur-cette-machine-lire-le-resultat-dans-temp)
- [[project-ahk-isset-requires-variable-load-crash] `IsSet(obj.prop)` is a LOAD-TIME crash in AHK v2 — and source-introspection tests can never catch it](#project-ahk-isset-requires-variable-load-crash-issetobjprop-is-a-load-time-crash-in-ahk-v2-and-source-introspection-tests-can-never-catch-it)
- [[project-metrics-ui-live-foreground-contract] Un tableau de bord de metriques doit projeter l intervalle de premier plan encore ouvert](#project-metrics-ui-live-foreground-contract-un-tableau-de-bord-de-metriques-doit-projeter-l-intervalle-de-premier-plan-encore-ouvert)
- [project-hs-partial-fixes-and-false-green-tests](#project-hs-partial-fixes-and-false-green-tests) — Three macOS "fixes" recorded as complete are partial, and each is protected by a test that asserts the wrong thing — the test locks in the mechanism, not the guarantee
- [project-hs-audit-2026-07-21](#project-hs-audit-2026-07-21)
- [project-hs-audit-round2-2026-07-21](#project-hs-audit-round2-2026-07-21) — Adjuger un backlog d'audit contre la source courante : un tiers etait faux ou perime
- [project-hs-audit-round4-2026-07-21](#project-hs-audit-round4-2026-07-21)
- [project-perf-2026-07-21-implementation](#project-perf-2026-07-21-implementation)
- [feedback-stash-drop-by-index-trap](#feedback-stash-drop-by-index-trap) — Never compute a `stash@{n}` index from grep line numbers (1-based vs 0-based) and never match entries via the pretty list — capture the stash commit SHA at push time, restore with `git stash store`
- [project-hs-suite-order-contamination](#project-hs-suite-order-contamination) — Green locally + red in CI on the same commit means test-file DISCOVERY ORDER (NTFS vs APFS): a leaked package.loaded stub or a warm-cache accident. The runner now cold-starts every file; never rely on a module being cached from an earlier test file

## Working conventions & feedback

### project-hs-suite-order-contamination

_Green locally + red in CI on the same commit means test-file DISCOVERY ORDER (NTFS vs APFS): a leaked package.loaded stub or a warm-cache accident. The runner now cold-starts every file; never rely on a module being cached from an earlier test file_

<sub>slug: `project_hs_suite_order_contamination`</sub>

Three CI-only failure waves (2026-07-22) came from one class: a test file installs a partial stub in `package.loaded` (shell_runner without `exec`, warmup_controller without `init`) or loads a module under a lucky environment, and whichever file the walker yields NEXT captures that state at require time. `tests/run.lua` walks the filesystem, and NTFS yields a different order than the CI runner's APFS — so the suite was green on Windows and red on macOS **for the same commit**, with a new victim surfacing after each targeted fix.

**Why:** `local Dep = require("x")` snapshots whatever `package.loaded["x"]` holds at that instant; nothing ever re-checks it. The warm cache also HID a real defect for months: the hs stub's `fs.attributes` returned constant nil, so `lib.paths` could never locate `_shared/` under a pristine stub — `lib.timings` only ever loaded because an earlier file had cached it under a real-fs override.

**How to apply:**

- Diagnostic reflex: local-green/CI-red on identical commits ⇒ suspect discovery order, not the runner OS. Reproduce by requiring the suspected polluter then the victim in one Lua process.
- The runner (`tests/run.lua`) now purges `modules.*`, `adapters.*`, `lib.*`, `ui.*` from `package.loaded` and installs a pristine hs stub between test FILES — never depend on a module surviving from a previous file, and never leave a deliberate stub installed past the end of your file (meta gate: `test_shell_runner_stub_restore`).
- The hs stub's `fs.attributes` probes the real filesystem (lfs, else `io.open` + `os.rename`) — tests that need a missing-path scenario must override it explicitly instead of relying on the old constant-nil behavior.
- The same accident class exists on the source-scan side: `read_driver_source("CONSTANT")` picks the FIRST file declaring the constant in walk order. If two files declare it (mlx vs ollama deps checkers), the test asserts a different file per OS — keep scanned constants unique, or fix every declaring site.

### feedback-stash-drop-by-index-trap

_Never compute a `stash@{n}` index from grep line numbers (1-based vs 0-based) and never match entries via the pretty list — capture the stash commit SHA at push time, restore with `git stash store`_

<sub>slug: `feedback_stash_drop_by_index_trap`</sub>

The shared-stash protocol (unique tag, apply by SHA, drop by re-found index) has two traps that combined into a near-miss on 2026-07-21: a `grep -n` line number is **1-based** while stash indices are **0-based**, so `git stash drop "stash@{$(… | grep -n tag | cut -d: -f1)}"` dropped the entry **below** the tagged one — another session's work. Worse, the local `git stash list` rendering (rtk proxy) strips the `WIP on <branch>:` prefix and shows `<base-sha> <base-subject>`, so what looks like "the SHA of the entry" in column one is the **base commit**, useless for `git stash store`.

**Why:** the stash stack is shared across all worktrees and several agent sessions push entries concurrently; dropping a neighbour's entry silently destroys their parked work.

**How to apply:**

- Immediately after `git stash push -u -m "<tag>"`, capture the entry's true commit: `git rev-parse stash@{0}` — that SHA is the only reliable handle.
- Drop by first printing `git stash list` and visually confirming which `stash@{n}` carries your tag; never derive `n` arithmetically from grep output.
- Recovery if a foreign entry was dropped: its stash commit stays dangling — find it via `git fsck --unreachable --no-reflogs`, identify the 2-parent commit whose subject is `WIP on <branch>: <base-sha> <subject>`, then `git stash store -m "<that subject>" <sha>` puts it back.
- `git log --stdin` does not work through the rtk git proxy — batch dangling-commit inspection with `xargs -n 150 git log --no-walk=unsorted` instead.
### feedback-ahk-source-encoding

_AHK v2 source files must be UTF-8 BOM + LF; encoding drift causes silent mid-file parse aborts that masquerade as missing tests_

<sub>slug: `feedback_ahk_source_encoding`</sub>

AHK v2's parser silently stops registering top-level statements partway through a file whose encoding is inconsistent (missing BOM, or CR bytes). The headless runner then plans `1..N` for only the first batch of `Test()` calls and reports green: the tests that ran are real, the missing ones are dropped with no error anywhere.

**Why:** discovered 2026-05-22 — a PowerShell rewrite left mojibake and a `cat >>` from bash appended LF lines into a BOM/CRLF file. The parser truncated instead of raising.

**How to apply:**

- Enforced by `npm run test:ahk-encoding` (`tools/test/test-ahk-encoding.cjs`: BOM required, CR bytes rejected). Run it before `git add`.
- Extend existing `.ahk` files via the Edit tool (it preserves encoding), NEVER via `cat >> file.ahk`.
- **Diagnostic:** a test file reporting fewer results than its `Test()` count is an encoding fault, not a logic fault — check the bytes before debugging the test.
- Non-ASCII is fine once the encoding is clean; `Chr(0xNNNN)` is the defensive alternative in files that must stay ASCII.

Related, same silent-abort signature: in AHK v2 the escape for a literal double quote is `` `" ``, not `""` (v1 syntax). See [[feedback_local_gate_mirrors_ci]].

### feedback-ahk-suspend-prefix-latch

_AHK custom-combination prefix flags latch across Suspend; fix at the source, synthetic key events cannot clear them_

<sub>slug: `feedback_ahk_suspend_prefix_latch`</sub>

AHK's custom-combination prefix-down flag is SEPARATE from `GetKeyState` and is cleared **only by a real physical key release processed by the live layer**. A synthetic `SendEvent("{SC138 Up}")` or a `{Down}{Up}` tap does NOT clear it (verified via logs), and re-registering the combos Off→On re-latches it. **You cannot clean it up on resume — only prevent it before the suspend flips.** Toggling `Suspend()` around the Kana `SC138` AltGr prefix produced two latch bugs, found live over ~5 iterations:

- **Menu/gesture pause → keyboard can't un-pause.** Toggling `Suspend` from a non-hook thread rebuilds the hook with the prefix un-armed, so the suspend-exempt script combos (AltGr+Enter/BackSpace/Delete/Escape) stop firing. **Fix:** also register the chords as plain **suffix** hotkeys gated on `HotIf((*) => A_IsSuspended and GetKeyState("SC138","P"))` — a suffix needs no prefix arming, never re-registers the prefix, and yields to the real combo when the prefix IS armed (no double-fire). Live in `lib/script_altgr_hotkeys.ahk`.
- **Keyboard pause → « AltGr bloqué ».** A keyboard pause holds the prefix down through `Suspend(1)`; its physical release lands while the layer is disarmed, so the flag stays latched and the layer later dispatches with `GetKeyState("SC138")==0`. **Fix:** drain every registered prefix key BEFORE suspending — `_SuspendPrefixesAreClear()` in `lib/lifecycle.ahk`, driven by `SUSPEND_CUSTOM_COMBO_PREFIX_KEYS` so a future suspend path cannot bypass the wait. `AltGrShiftDispatch` keeps a permanent WARNING guard-rail for any dispatch with the prefix not physically held.

**Never** reach for synthetic taps or Off→On re-registration. To syntax-check an edit, see [[feedback_ahk_ui_syntax_validation]] — and pass `/validate` BEFORE the script path, never after, or the script runs live ([[project_ahk_map_delete_raises_on_missing_key]]). Related: [[project_suspend_pause_invariant]].

### feedback_ahk_ui_syntax_validation

_Some AHK UI files are outside the headless test runner; how to syntax-check them locally on Windows_

<sub>slug: `feedback_ahk_ui_syntax_validation`</sub>

`run_all.ahk` includes most of `lib/`, `adapters/` and a growing subset of `modules/` + `ui/`, but it deliberately skips the files that register hotkeys or build menus at top level — notably `ui/tray_menu.ahk` and `ui/onboarding/*` (they would block a clean exit). A syntax error in those is caught **only** by CI's `Compile ErgoptiPlus.ahk` step (Ahk2Exe). Check what the runner actually includes before assuming a file is covered; the list drifts.

**How to syntax-check them locally** (two ways, both gotcha-laden):

1. **Ahk2Exe compile** (gold standard, == CI), at `C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe`. **Run it from PowerShell, never Git Bash** — MSYS path conversion rewrites `/in` `/out` `/base` into Windows paths (`/in` → `C:/Program Files/Git/in`) and the compile dies with "Unrecognised parameter". Ahk2Exe also **exits 0 on failure**, so verify the `.exe` was actually created.
2. **Parse-only harness**: a throwaway `.ahk` with `ExitApp(0)` as its first auto-execute statement, then `#Include` the UI file. AHK parses the whole merged script before running anything, so a syntax error aborts at load while `ExitApp(0)` exits before any included top-level code runs. Launch via `Start-Process -FilePath AutoHotkey64.exe -ArgumentList @("/ErrorStdOut",$script) -Wait -PassThru -RedirectStandardError $err` — a plain `& AutoHotkey64.exe` captures neither exit code nor stderr, because it is a GUI-subsystem app that detaches.

`/validate` is a real headless syntax check, but ONLY when it precedes the script path — in final position it becomes a script argument and the script runs live ([[project_ahk_map_delete_raises_on_missing_key]]). The headless runner writes its TAP report to `%TEMP%\ergopti_test_results.txt`, NOT stdout — read that file for pass/fail. See [[feedback_ahk_source_encoding]].

### Coding style and conventions for this project

_Style rules, architecture decisions, and what to avoid when writing code for this project_

<sub>slug: `feedback_coding_style`</sub>

The conventions are **not** restated here on purpose — `.github/copilot-instructions.md` is the single normative source, and `CLAUDE.md` @-includes it, so it is already in context. Re-read it before writing code; a copy in this file would be the second source of truth to drift.

It covers: tabs; banner spacing (5 blank lines / major, 3 / minor) with exact `=` alignment; the file-path header line; code English / UI French; docstring vs inline-comment punctuation; the 8 Logger variants and mandatory `start`/`success`, `trace`/`done` pairing; fail-fast via `require_state()`; single-source defaults; no magic numbers; setters log at DEBUG; and §5.9 regression tests.

**How to apply:** run `npm run fix:banners` rather than counting `=` by hand ([[feedback_fix_banners_tool]]). When refactoring, prioritise removing duplicated defaults and silent error swallowing — those are the two rules this codebase has actually broken.

### project-lua-closure-before-local-nil-global

_A `local` declared textually AFTER a closure that uses it is not captured — the closure binds the nil global, and the hs.task/ShellRunner pcall swallows the resulting error silently_

<sub>slug: `project_lua_closure_before_local_nil_global`</sub>

In Lua, `local function f() … uses x … end` captures `x` as an upvalue **only if `local x` appears lexically before the closure**. Declared below, the reference inside `f` resolves to the global `_G.x` (nil). The closure reads correctly; at call time the variable is nil.

**Why it is invisible:** found 2026-06-19 in `modules/llm/api_ollama.lua`. The streaming `on_done` closure called `os.remove(tmp_path)` as its first statement while the only `local tmp_path` sat below it — so `os.remove(nil)` threw and, because `ShellRunner`/`hs.task` invoke completion callbacks inside a `pcall`, the error was swallowed: the ENTIRE `on_done` body aborted on its first line on every stream completion. With `llm_streaming=true` by default, Ollama predictions silently never appeared. The pre-existing test only grepped that the literal `os.remove(tmp_path)` string was present inside `on_done` — green while the runtime value was nil. A textbook false-green.

**How to apply:**

- When a closure (`hs.task` / `ShellRunner` / `hs.timer` callback) references a `local`, verify the `local` is declared ABOVE it. Hoist temp-file and state creation above the callbacks that consume it.
- **The `hs.task` GC-pin shape is the recurring trap:** `local task = hs.task.new(… function() M._active_tasks[task] = nil end)` looks right and binds nil. The fix is always the 2-line split — `local task; task = hs.task.new(…)` plus `if task then … end` inside the callback. Nine sites were fixed this way in one 2026-06-20 pass (karabiner/onboarding, menu_apps, both models_manager_*), so assume any new one is wrong until checked.
- Regression tests must encode the ROOT CAUSE by comparing **source indices** (`src:find("local tmp_path") < src:find("local function on_done(", 1, true)`), never merely that the using line exists.

Related: [[feedback_regression_tests]], [[project_hs_timer_callback_errors_invisible]] (why the throw was invisible), [[feedback_coding_style]].

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

_The `hs.*` purity ratchet counts the substring `hs.` everywhere — comments and string literals included — so a comment mentioning `hs.timer.new` increments the counter_

<sub>slug: `project_hs_purity_ratchet_counts_comments`</sub>

`tests/meta/test_port_adapter_coverage.lua` counts occurrences of the literal substring `hs.` (and of `io.open`/`os.execute`) across `modules/` and `lib/`, excluding `adapters/`, `ui/` and root `init.lua`, then fails if the total rises above a baseline. It is a raw substring count, not an AST parse: **it counts comments and docstrings.** The test's own baseline comment says so and tracks a whole class of such false positives.

**Never quote the baseline numbers from memory — read `LUA_HS_BASELINE` / `LUA_IO_OS_BASELINE` in the test.** They move on almost every pass, and a stale number in prose sends people debugging a delta that does not exist.

**How to apply:**
- Prefer routing the OS call through an adapter and naming the *adapter* in the comment, not the raw `hs.` API.
- If a comment genuinely must name the `hs.` API (documenting a foot-gun), accept the increment and bump the baseline with a note saying it is a comment, not a call. Verify with `git diff -- modules lib` that no real call site was added.

**Corollary — `adapters/` is the OS-isolation layer, not "exactly the 20 ports".** A refactor making `macos/adapters/` mirror `windows/adapters/` at exactly the 20 contract ports, by moving the non-port helpers (`shell_runner`, `toml_cache`, `json_codec`) into `lib/`, is **rejected by this ratchet**: those helpers do shell-exec and file I/O, so relocating them spikes both counters outside `adapters/`. Do not weaken the baselines to permit it (§5.9). Cross-driver "adapter parity" means the 20 ports line up — not that the folders hold the same files.

Related: [[project_lua_closure_before_local_nil_global]] (the audit where this was discovered).

### feedback_commit_push

_Never push automatically — commit freely, push only after an explicit ask in the current conversation_

<sub>slug: `feedback_commit_push`</sub>

**`git push` is blocked unless the user says "push" / "pousse" / "merge" in that turn.** Commit freely after small autonomous changes, then stop. Never chain `&& git push`, never push in a follow-up step, and never infer approval from a green test run or from a prior "work autonomously" instruction.

**Why, two independent reasons:**

- The user was burned by auto-pushes mid-session while the code was in a broken/test state (hardcoded test HTML pushed to remote mid-debug).
- Every push to `dev` or `main` triggers CI **and cuts a release**. Pushing each small fix pollutes the releases and burns CI. Commits must stay local until explicitly approved.

**How to apply:**

- After any commit: stop. Wait for an explicit push instruction.
- Work on a feature/fix branch and commit locally as much as needed.
- Step-by-step mode ("étape par étape, tu valides chacune"): also wait for an explicit "ok"/"validé" before committing each step.
- If unsure: committing is fine, pushing never is.

Also codified in `CLAUDE.md` (Release branch safety), `.github/copilot-instructions.md` §6, and the `commit-and-push` skill. Related: [[feedback_test_before_merge]] (the merge-to-dev step, which this entry does not cover).

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

`npm run fix:banners` (wrapping `tools/lint/lint-conventions.js --fix-banners`) auto-corrects banner line lengths repo-wide across `.lua` and `.ahk`.

**Why:** banner misalignment blocks `git commit` via the husky pre-commit hook, and fixing it by hand (counting `=` characters) is slow and error-prone.

**How to apply:** after creating or editing any `.lua` or `.ahk` file, run it from the repo root before `git add`. Never align banners manually — the tool is definitive.

Related: [[feedback_coding_style]]

### errors-only-log-sink

_Dedicated daily ErgoptiPlus_errors_YYYY-MM-DD.log (WARNING + ERROR only); crash_reports/ strictly for uncaught fatal exceptions_

<sub>slug: `errors_only_log_sink`</sub>

Both drivers mirror every WARNING/ERROR line into a small daily `ErgoptiPlus_errors_YYYY-MM-DD.log` beside the unified log, same rotation and 14-day purge. The "Open error log" menu item and its gesture-assignable action are canonical in `_shared/modules/menu/menu_manifest.json` — no per-driver duplication.

**Why:** the unified daily log reaches thousands of lines, and triage almost always wants only the error lines. **Routing recoverable errors into `crash_reports/` was considered and rejected** — those rich per-incident JSON dumps (full ring buffer + sysinfo) stay exclusively for true uncaught fatals (`ergopti_report_crash` on HS, global `OnError` on AHK); mixing recoverable errors in would drown the signal and bloat them.

**How to apply:** use `LoggerError` / `Logger.error` for any noteworthy failure even when execution continues — and when the user reports "it did something weird", open the errors file first.

Related: [[feedback_coding_style]] (logging conventions).

### feedback-loader-target-explicit

_AHK loader/writer modules that mutate a shared Map (Features etc.) must take the target Map as an explicit parameter, never reach for it via `global`_

<sub>slug: `feedback_loader_target_explicit`</sub>

Any loader or writer that mutates a shared in-memory structure (the `Features` Map, the `TapHold` Map, any future global) MUST receive the target as an explicit function parameter — never a `global Features` declaration reaching into the global namespace.

**Why:** discovered 2026-05-22 during a sliced config migration, and the failure mode generalises to every such migration. A "successor" loader written against `global Features` is correct only once the migration is finished; **during** the slicing, the old global is still the live target while the new loader is meant to populate a separate one. Because section names coincide between the two schemas, the new loader silently walked the old entries and overwrote `{Enabled: True}` object literals with plain booleans — every downstream `.Enabled` access then crashed at tray-menu init, far from the cause.

**How to apply:**

- A function that mutates a Map passed by reference takes it as its first parameter. A function that returns a fresh Map needs no such parameter — no mutation, no aliasing risk.
- Read-only accessors may still use `global`: they locate data without changing it.
- Tests pass their own fixture, production passes the production global; both are then safe.
- If you find an existing module mutating a global, convert it to a parameter **before** adding a caller. Incremental migrations are exactly when the global-reference assumption breaks.

Related: [[feedback_ahk_source_encoding]] — same refactor, same signature: a silent or cryptic failure with nothing pointing at the root cause.

### No co-author trailers (Copilot, Claude, bots)

_Never add Co-Authored-By trailers — and never whitelist legacy ones to make a lint pass_

<sub>slug: `feedback_no_coauthor`</sub>

No `Co-Authored-By:` trailers, ever — Copilot, Claude, github-actions[bot], any tool. Normative in `.github/copilot-instructions.md` §6; produce a bare conventional commit with no trailers.

**The non-obvious part:** when a meta-test trips over legacy bot trailers already in the history, do **not** whitelist them. The user pushed back hard on that proposal: scope the check to NEW commits (`origin/dev..HEAD`) so history is not flagged but every future violation is. Softening a rule to make a check pass is the same anti-pattern as weakening a regression test ([[feedback_regression_tests]]).

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

_Green locally must mean green in CI: the local gate is four commands, and it is only trustworthy once `node_modules` is installed on a Node satisfying the engine floor_

<sub>slug: `feedback_local_gate_mirrors_ci`</sub>

The full pre-push gate — all four, from the repo root:

```bash
npm run test:js            # the umbrella suite (tools/test/run-js-suite.cjs)
npm run test:ahk-encoding  # every .ahk is UTF-8 BOM + LF
AutoHotkey64.exe static/ergopti_plus/windows/tests/run_all.ahk       # unit + meta
AutoHotkey64.exe static/ergopti_plus/windows/tests/e2e/run_e2e.ahk   # E2E
```

`test:js` is the one people skip and the one that matters most: it is the **umbrella** wrapping the checks CI gates on but the AHK runner knows nothing about — the pinned-source-read ratchets, `lint:conventions:strict`, port compliance, priority parity, the translations audit, `format_toml`. The AHK suite can be fully green while `test:js` is red.

**The prerequisite that silently voids the whole gate:** `test:js` needs `node_modules`. Without it, several checks die on `MODULE_NOT_FOUND` — which reads like "my environment can't run this" rather than "the gate did not run", so it gets waved through and real failures stay invisible. That is exactly how a ratchet violation reached CI on 2026-07-20 (run `29767112617`) after a fully green local AHK run.

Installing is itself a trap: `.npmrc` sets `engine-strict=true` and a transitive dep pins a recent Node minor. CI pins `node-version: '22'` (latest 22.x) and satisfies it; a local Node below that floor makes `npm ci` abort with `EBADENGINE`. `npm ci --engine-strict=false` unblocks the gate; upgrading local Node is the actual fix.

**Why:** the standing requirement is that green local predicts green CI ("assure toi de fix les tests locaux pour que dans le futur vert local=vert ci"). **A gate that cannot run is worse than one that fails** — a failure is visible, an un-runnable check is mistaken for a pass.

**How to apply:**

- Run all four before pushing. Any `MODULE_NOT_FOUND`, or a check count well below what the suite normally reports, means the gate did **not** run — fix the install, do not read it as a pass. (Do not memorise the exact count; it grows.)
- New AHK tests must read driver source through `_DriverFuncBody` / `_DriverSourceConcat` / `_DriverDirConcat`, never a hardcoded `modules/…` or `lib/….ahk` path. `tools/test/test-no-pinned-source-reads.cjs` fails the build past its `BASELINE`. **Never raise the baseline to make a change pass** — convert the test to a helper read ([[feedback_regression_tests]] applied to the ratchet itself).
- Two gotchas that cost several red runs: a **comment** containing a token a meta-test scans for shifts naive `InStr` position assertions — reword it or strip comments via `_StripFullLineComments`; and in AHK v2 an embedded quote is `` `" `` — a stray `\"` aborts the parse mid-file and the runner exits with no results at all, which looks like "tests vanished", not "tests failed" (same signature as [[feedback_ahk_source_encoding]]).

### feedback-test-before-merge

_Never merge a slice into dev before the user has tested it live. Stay on the branch and wait for explicit validation._

<sub>slug: `feedback_test_before_merge`</sub>

**Why:** during a sliced cut-over the user tested each slice in live AHK use before merging; on one slice I merged to dev right after a green test run and got pushed back — « ne pas merge dans dev avant d'avoir testé ! ». The suite exercises pure logic: it cannot catch tray-menu UI regressions, hotkey state mismatches, or boot-time failures that only surface in a real session. Merging early puts unvalidated code on dev and forces a rewind.

**How to apply:** when the user says « passe à la suite » or anything that merely sounds like "continue", default to **staying on the current branch** after committing. Say the slice is ready and ask them to test. Merge only on an explicit « ça marche » / « tu peux merger ». Same for deleting the branch — wait until after the merge.

Related: [[feedback_commit_push]], which covers the commit/push cadence but is silent on the merge step.

### feedback-ui-must-be-i18n

_All user-facing UI text goes through the i18n system in 21 languages — never hardcode a UI string anywhere, WebView UIs included_

<sub>slug: `feedback_ui_must_be_i18n`</sub>

Every user-facing string ships in **all 21 supported languages** (ar, cs, da, de, en, es, fr, he, hi, it, ja, ko, nl, no, pl, pt, ru, sv, tr, uk, zh). Locale files: `static/ergopti_plus/_shared/data/locales/<lang>.json`.

**Why — this overrides a naive reading of CLAUDE.md.** CLAUDE.md says "UI is French", but French was only the dev-time default: the project actually ships in 21 languages. Taking that line literally and hardcoding French breaks the multilingual contract for every other user.

**How to apply:**

- Any user-facing text (Svelte component, WebView HTML/JS, tray label, dialog) comes from the i18n system, never a string literal.
- WebView UIs: the JS loader is `_shared/ui/i18n.js`; markup uses `data-i18n` attributes, scripts use `t("menu.hotstrings.autocorrection")`.
- Windows driver: `t(key)` from `static/ergopti_plus/windows/lib/i18n.ahk`. macOS driver: `t(key)` from `static/ergopti_plus/macos/lib/i18n.lua` (+ `lib/locale.lua`).
- A new key goes into **all 21** files at once. Machine translation is an acceptable first pass; a missing key never is. The fallback chain (active→EN→FR) exists as a safety net, not a licence.
- Internal logs and developer comments stay English per CLAUDE.md — this rule covers user-visible text only.

Parity is enforced in CI against the canonical `en.json` — see [[project_locale_parity_test]].

### project-ahk-menu-dispatcher-error-swallow

_The menu-dispatcher bypass must re-throw callback errors — a local try/catch only destroys reporting_

<sub>slug: `project_ahk_menu_dispatcher_error_swallow`</sub>

In `lib/menu_dispatcher.ahk`, the `_DispatchIfMissed` bypass must let callback errors bubble to AHK's thread boundary (`throw Err` after logging), so a click dispatched by the bypass reports exactly like one dispatched natively.

**Why the defensive instinct is wrong here:** wrapping it looks prudent because the bypass runs on a `SetTimer` thread — but the global `ErgoptiGlobalErrorHandler` returns `true`, so a propagated error never kills the script; it just reaches the crash reporter and the user toast. Catching locally therefore buys no safety and silently deletes the only error report. Guarded by `tests/meta/test_menu_dispatch_error_propagation.ahk`.

Related: [[project_ahk_menu_dispatcher_drop]].

### project-audit-2026-07-21-open-items

_Troisieme et quatrieme passes d'audit AHK : les pistes refutees a ne pas re-soulever, et deux decisions qui ne sont pas des correctifs_

<sub>slug: `project_audit_2026_07_21_open_items`</sub>

53 findings confirmes sur 2026-07-21 (trois passes + une quatrieme sur
`lib/config_io.ahk`, `lib/webview_utils.ahk`, `adapters/text_sender.ahk`), tous
implementes avec un test de regression encodant leur cause racine. Le rapport
d'audit a ete supprime apres implementation ; seul ce qui n'est pas dans git
survit ici.

**Mesurer avant de theoriser.** Les logs a `<ConfigDir>/autohotkey/logs/` ont
donne les premiers vrais chiffres du driver : `Tooltip.ResolvePos` max 2560 ms —
c'est le `TransactionTimeout` UIA de 2000 ms par defaut, que le driver ne fixait
pas. Deux passes anterieures n'avaient jamais regarde ces logs, cf.
[[project_audit_evidence_must_be_reproducible]].

**Deux decisions, pas des correctifs :**

- **Le rollback `today_log_offset` est laisse en place, deliberement.** Il
  re-append un batch deja ecrit, mais chaque `events_*` est un `INSERT OR IGNORE`
  sur une PK `(device_id, id)` : le doublon est jete a l'import — du poids de
  fichier, pas de perte. Commiter l'etat avant `data.sql` echangerait ca contre
  une vraie fenetre de crash ou un batch est marque durable avant de l'etre.
  Invariant epingle par `test_sql_replay_is_idempotent.ahk`.
- **`require_state` est un RATCHET DE DERIVE a 27, pas un compte de defauts.**
  Les conventions 5.8 decrivent la forme des modules Lua/Hammerspoon (etat
  injecte par `M.init()`, chaque fonction publique gardee). Le driver AHK n'est
  pas bati ainsi : globals auto-execute, caches paresseux, checks de handle
  explicites. Les 27 entrees sont des caches (`_TimingsCache`), des flags
  auto-initialisants, des handles derriere leur propre garde, et une couture de
  test (`_HotstringRegistrar`). **Ne pas « corriger » ces entrees en y boulonnant
  des gardes** — une passe mecanique mettrait des early-returns vides dans
  `HotPath_Now()`, appele a chaque frappe. Le ratchet ne sert qu'a faire echouer
  un NOUVEAU module a etat injecte sans garde.

**Le foot-gun recurrent : un test peut occuper un nom sans rien asserter.** Six
tests ont ete trouves incapables d'echouer — un corps de fonction vide, un qui
assertait l'absence d'un helper deja supprime, un qui comparait une liste codee
en dur a sa propre longueur, un qui scannait un dossier vide, et un
(`test_webview_host_callback_epoch.ahk`) qui epinglait verbatim des callbacks
mal lies (`obj.Method` rend un Func NON lie dont le premier parametre est le
`this` implicite) sans jamais les appeler : la suite certifiait le defaut. Un
tel test est pire que pas de test. **Corriger ce code EXIGE de corriger
l'assertion dans le meme commit** — c'est reparer une assertion fausse, pas
affaiblir un test.

**Deux pieges de lecture confirmes empiriquement :**

- Quand deux chemins sur la meme donnee sont en desaccord sur les cles qui
  existent, l'un des deux derive — cherchez la paire avant de supposer qu'une
  restriction est voulue. (`ReadKeyboardShortcutsConfig` n'iterait que les 15
  defauts livres alors que le picker en offre ~600 ; `_GlobalClearAllBindings`,
  dans le meme fichier, parcourait deja la section persistee.)
- Le nettoyage de code mort qui supprime un module inutilise supprime aussi la
  preuve qu'il n'a jamais fonctionne.

#### Refute — NE PAS re-soulever

Chacun a ete instruit puis rejete avec preuve :

- **« Les sous-logs ne roulent pas a minuit et ne sont pas purges. »** Les
  sous-fichiers sont un SOUS-ENSEMBLE strict du log principal date (verifie au
  compte de lignes), donc en tronquer un ne detruit aucune donnee unique. Le
  residu est cosmetique.
- **« Le driver n'eleve jamais sa priorite de processus » / « `Slow
  HSE.FeedChar` impute mal des stalls de descheduling. »** Les deux sont
  contredits par `tests/meta/test_hotpath_priority_starvation.ahk`.
- **« Le mutex single-owner s'ouvre — 11 instances en 8 s. »** Le clustering
  correle avec les journees de dev intenses, pas avec un defaut de production.
- **« `KL_IngestOnce` n'a pas de garde de reentrance. »** Un timer AHK ne peut
  pas s'interrompre lui-meme ; les interleavings atteignables viennent de
  `OnExit`/rollover, deja couverts par le scratch atomique.
- **« Six autres freres du nom `.tmp` process-independant. »** Les autres
  writers atomiques n'ont pas de yield entre staging et rename : la fenetre de
  collision n'existe pas la.
- **« `CtrlAltDispatch` emet sans Critical. »** Un `Critical("On")` naif y ferait
  echouer `test_layout_tables.ahk` et le check de fuite Critical du framework.
- **« `_TooltipDequeueRebuild` n'a aucune discipline de generation. »**
  Structurellement vrai, mais aucun interleaving atteignable ne produit un
  resultat faux.
- Egalement refutes : l'overlay CapsLock contournant `LayerDispatch` ; le
  validateur tap-hold F-31 loguant par appui ; le retour falsy de
  `_SuspendPrefixesAreClear` ; `_DeferredGestureAutoConfigure` se re-armant a
  travers suspend ; la divergence de safety-flush F-32 dans le host changelog ;
  la couverture du garde d'ordre de chargement de `da0531f12` ; le passage de
  `TOOLTIP_POSITION_CACHE_MS` a 600 causant de la peremption (il vaut bien 600
  aujourd'hui, `ui/tooltip/core.ahk:56`).

Related: [[project_ahk_guard_tests_must_loop_the_class]],
[[project_ahk_invariant_incomplete_application]],
[[project_audit_findings_are_hypotheses]],
[[project_audit_evidence_must_be_reproducible]].

### project-typing-latency-tooltip-coldstart

_Latence de frappe : pourquoi la reutilisation de fenetre tooltip est rejetee, pourquoi le chunking de l'enregistrement differe a ete reverte, et pourquoi WebView2 a quitte le chemin de frappe_

<sub>slug: `project_typing_latency_tooltip_coldstart`</sub>

L'outil de mesure est `HotPath_LogIfSlow` (`lib/hotpath_profiler.ahk`, base QPC,
ne logue que les segments > 5 ms) : **lisez les lignes `Slow <segment>: <ms>` du
vrai `ErgoptiPlus_<date>.log` avant de theoriser.** Le cout recurrent est le
rendu du tooltip de previsualisation, parce qu'il **detruit et recree deux
fenetres top-level a chaque mise a jour** ; le debounce de 150 ms
(`_PREFIX_RENDER_DEBOUNCE_MS`, `lib/hotstrings/hotstring_inputhook.ahk:82`) est
un pansement sur ce cout, pas une solution.

Le scan alpha de bordure optimise vit dans `_TooltipFixBorderAlpha`
(`ui/tooltip/helpers.ahk:443`) ; son invariant — « reecrire exactement les pixels
que GDI a peints » — est verifie contre le rasteriseur reel, pas contre un
modele, par `tests/unit/test_tooltip_border_alpha.ahk`.

**Reverte — NE PAS re-tenter :**

- **Chunker l'enregistrement differe emoji/symboles** (`e7072a7c8`, reverte).
  L'idee : decouper la passe de ~3000 lignes en tranches via un `SetTimer(self,
  -1)` auto-reprogramme. **Resultat : +7969 ms au wall-clock (~12x le bloc
  monolithique)** sur un vrai boot a froid. `SetTimer(-1)` rend la main a la
  boucle de messages entre chaque tranche ; pendant que WebView2 demarrait a
  froid et saturait la file, chaque tranche attendait son drainage, etalant
  l'enregistrement sur toute la fenetre de warm-up et le faisant CHEVAUCHER le
  cold-start qu'il finissait avant. La premisse etait fausse aussi : les threads
  AHK sont interruptibles apres ~15 ms, donc le bloc synchrone n'a jamais gele
  la frappe. **Lecon : ne jamais `SetTimer`-yielder une boucle CPU dans une
  boucle de messages qu'un autre cold-start martele.**

**Rejete — ne pas re-tenter a la legere :**

- **Reutilisation de la fenetre tooltip** (garder le Gui de contenu + la bordure
  vivants, muter a la mise a jour). Le docstring du module PRETEND deja « single
  reused Gui… mutated on subsequent calls » : c'est aspirationnel, le code
  detruit et recree. Trois blocages : (1) **AHK v2 ne sait pas retirer un
  controle d'un Gui** — seulement `Gui.Destroy()` la fenetre entiere — donc la
  reutilisation du contenu impose une reecriture avec pool de controles a etat ;
  (2) les tests tooltip sont **logique/contrat uniquement** (arithmetique,
  formatters, greps de source) et n'exercent PAS le cycle de vie reel des
  fenetres, donc un tel refactor atterrirait sans filet dans le module au pire
  historique de bugs ; (3) la reutilisation de la seule bordure heurte un **piege
  de z-order** — une fenetre de contenu fraichement recreee passe au-dessus de la
  bordure topmost plus ancienne et masque l'anneau. Gain marginal (~2-4 ms/rendu)
  pour un vrai risque de regression.
- **De-contentionner le cold-start WebView2 par des astuces de timing**
  (idle-gating, delai fixe plus long, prechauffage). Le cold-start survit a une
  pause de frappe, un delai fixe devine, et prechauffer regonfle le boot. Corrige
  a la racine : le widget WPM a ete reecrit de WebView2 vers **GDI+ dans une
  fenetre layered a alpha par pixel** (`ui/wpm/wpm_widget.ahk`, via
  `GR_DrawBitmap` de `adapters/graphics_renderer.ahk`), supprimant le cold-start
  au lieu de l'ordonnancer. Il etait le seul consommateur WebView2 sur le chemin
  de frappe et utilisait un moteur de navigateur entier pour dessiner une
  sparkline ; une frappe y atteignait **476 ms**. Garde par
  `tests/meta/test_wpm_widget_native_render.ahk`.

**Deux foot-guns a retenir :**

- Le texte GDI+ sur une fenetre layered exige `GdipSetTextRenderingHint` =
  AntiAliasGridFit (4) pour porter l'alpha ; un `TextOut` GDI simple rend en
  alpha 0, donc invisible.
- **L'adapter TimerScheduler arme de VRAIS timers OS meme sous test.** Tout test
  qui arme un handle doit le declencher ou l'annuler, sinon le
  `_TS_ResetRegistry` suivant doit le drainer — un one-shot fuite plus un
  compteur d'ids remis a zero faisait qu'un handle mort evinçait le handle vivant
  du test suivant. Fixe cote test ; regression deterministe dans
  `_TSTest_StaleTimerCannotEvictLiveHandle`.

Related: [[feedback-ahk-source-encoding]], [[feedback-regression-tests]],
[[project-suspend-pause-invariant]].

### project-ahk-menu-dispatcher-drop

_AHK 2.0 perd silencieusement ~30-50 % des clics du menu tray. Contourne par lib/menu_dispatcher.ahk — tout item actionnable doit passer par RegisterMenuItem, jamais par Menu.Add brut._

<sub>slug: `project_ahk_menu_dispatcher_drop`</sub>

Symptome : « le menu se ferme, rien ne se passe » sur ~30-50 % des clics au
hasard. Cause racine : le dispatcher interne `WM_COMMAND → menu-callback` d'AHK
2.0 perd des evenements silencieusement (aucun log, aucune erreur). Windows
delivre `WM_COMMAND` de facon fiable — confirme en loguant `OnMessage(0x0111)` ;
c'est la distribution AHK qui perd le clic. Pre-existant, ce n'est **pas** une
regression du refactor v2.

**Correctifs qui ne marchent PAS** (ne pas re-tenter) : deferrer via
`SetTimer(-1)`, `A_MaxThreads := 32`, `Critical` a l'entree du callback.

Le contournement est `lib/menu_dispatcher.ahk` : une Map globale de callbacks
indexee par ItemId Win32 (decouvert post-`Menu.Add` via `Menu.Handle` +
`GetMenuItemID`) et un handler `OnMessage(0x0111)` qui re-distribue depuis un
thread `SetTimer` frais si le chemin natif n'a pas tire dans le delai de retry.

**La seule regle qui compte :**

- Tout item de menu portant un callback reellement actionnable DOIT etre ajoute
  via `RegisterMenuItem(MenuObj, Label, Callback)` (ou `RegisterMenuItemInsert`
  pour `.Insert`), **jamais** par `Menu.Add(Label, Callback)` brut.
- `Menu.Add` brut n'est correct QUE pour : les separateurs (`Menu.Add()`), les
  sous-menus conteneurs (`Menu.Add("Titre", SubMenuObj)`) et les en-tetes
  desactives purement decoratifs. Voir le bloc « WHEN TO USE WHICH » dans
  `menu_dispatcher.ahk`.
- Ca marche sur des menus popup detaches fraichement crees (`Menu()`) avant leur
  rattachement — `.Handle` cree le HMENU paresseusement.
- Plus le sous-menu est profond, pire c'est : un sous-menu a 3 niveaux perdait
  ~100 % de ses clics, bien au-dela de la moyenne de 30-50 %.
- **Pour auditer :** grepper les appels `.Add(` qui passent un callback non
  separateur / non sous-menu.

Related : [[feedback-loader-target-explicit]], [[project_config_v2_refactor]].

### project-audit-2026-07-21-toml-onboarding

_Regles durables sorties de l'audit de `lib/toml/` et `ui/onboarding/` : ou parse-t-on, comment signale-t-on un echec de lecture, et le piege de la sentinelle_

<sub>slug: `project_audit_2026_07_21_toml_onboarding`</sub>

**La conflation de sentinelle reecrit silencieusement les donnees
utilisateur.** Deux bugs de la meme forme : `ONBOARDING_DEFAULT_MAGIC_KEY`
servait de test « rien n'a ete choisi » alors que c'est aussi une reponse
valide, et un champ de dossier de config vide voulait dire « prends le defaut »
pour l'etape qui le stockait mais « ne fais rien » pour celle qui le validait.
**Tracez la provenance explicitement ; ne deduisez jamais « non renseigne »
d'une valeur legale.**

**Perdre le parse ne perd pas le fichier.** `TOML_RunStrictCanonicalization`
lance `SaveFullConfig` apres chaque ecriture reussie et re-emet tout l'arbre
`Features` depuis la memoire. La perte durable se limite a ce que `Features` ne
contient pas, et seulement quand la canonicalisation est sautee — c'est-a-dire
aux ecritures de la phase de boot.

**How to apply :**

- Les parseurs TOML partagent `TOML_StripInlineComment` (`lib/toml/toml_helpers.ahk`) ;
  ajoutez-y le nouveau parsing, pas dans une quatrieme copie.
- Un echec de lecture se signale par `TOML_ReadFailed(Path)`, **pas** par un
  resultat vide. Tout code qui REECRIT un fichier a partir d'un parse doit le
  verifier d'abord.
- `_Onboarding_ResetAnswers` possede le reset du wizard ; les renderers d'etape
  doivent rester de purs renderers, parce que la premiere page sert aussi de
  cible au bouton Retour.

### project-ahk-unreadable-config-persists-defaults

_A config reader that returns "" on a locked file — instead of signalling the read failure — makes the next save persist DEFAULTS over the user's real config. The `TOML_ReadFailed` rule exists but is unapplied at five readers._

<sub>slug: `project_ahk_unreadable_config_persists_defaults`</sub>

The rule in [[project_audit_2026_07_21_toml_onboarding]] — "a read failure signals via `TOML_ReadFailed(Path)`, never an empty result, and any code that REWRITES a file from a parse must check it first" — is real but was never applied class-wide. Five readers still collapse "unreadable" into "empty", and the writer downstream then persists the empty/default state over the user's on-disk config. Every one is triggered by a transient boot-time lock (OneDrive/Dropbox sync, an AV real-time scan, a backup/indexer holding the file for a few hundred ms); the `07-20` logs show this machine really does hit sharing-violation locks on the config dir.

Concrete sites and their data-loss path (audit 2026-07-21):

- **`ReadTomlFile` → `ApplyConfigToml` (the worst).** `ReadTomlFile` (`toml_loader.ahk:88`) catches the `FileRead` throw, logs one lone ERROR, and returns `""` with **no signal to writers**. `ApplyConfigToml` (`toml_config_loader.ahk:140`) sees `FileExist`=true, skips its missing-file guard, `loop parse ""` applies 0 overrides → `Features` stays at manifest DEFAULTS → the `-500 ms` boot timer's `SaveFullConfig` (`config_io.ahk:395`, `_CollectFeatureUpdates` walks the whole tree unconditionally) writes those defaults back once the lock has cleared. **The entire feature configuration is silently lost.** The existing `TOML_ReadFailed` guard only fires while the file is *still* unreadable at write time — a lock that clears between boot and the timer defeats it.
- **`_WS_Load`** (`wrap_symbols_config.ahk:292`) → empty maps → the next tray toggle's `_WS_Save` persists them → every disabled built-in re-enabled, custom pairs gone.
- **`CS_Read`** (`config_shortcuts.ahk:78`) → keeps the in-memory metrics DEFAULTS → the first `SaveFullConfig` overwrites the user's real metrics settings.
- **`ReadPersonalToml`** (`personal_toml_io.ahk:153`) and **`ReadPathsToml`** (`toml_helpers.ahk:735`): unguarded `FileRead` — the first swallows a locked `personal_hotstrings.toml` (personal hotstrings vanish, no log) and later crashes menu handlers; the second aborts the auto-execute boot mid-way with hotkeys already armed.

**Symptom the user reports:** "my settings reset after a restart", "the wrap symbols I disabled came back", "my hotstring categories re-enabled themselves" — with nothing in the visible logs, because the read failure is a single easily-lost ERROR and the destructive save logs nothing.

**How to apply:** give each reader the same read-failure sentinel `ParseTomlFile`/`TOML_ReadFailed` already has (a per-path failure flag), and make its writer (`SaveFullConfig`, `_WS_Save`, the metrics persist) FAIL CLOSED — refuse to serialize the affected section while the flag is set — so a transient lock can never be persisted as an empty/default config. One class fix closes all five; a regression test per reader writes a real file, forces the read to throw, mutates, and asserts the on-disk file is unchanged. This is the loop-the-class shape again: the rule was written but pinned at one layer only.

Related [[project_audit_2026_07_21_toml_onboarding]], [[feedback_loader_target_explicit]], [[project_ahk_invariant_incomplete_application]].

### project-audit-ahk-2026-07-21-adversarial

_Fifth adversarial pass on the AHK driver: 52 confirmed / 10 refuted / 3 hypotheses, full list in the committed `AUDIT_AHK_2026-07-21.md`. Two confident false-positives killed by measurement._

<sub>slug: `project_audit_ahk_2026_07_21_adversarial`</sub>

Loop-until-dry to three passes, each finding verified by two independent adversarial lenses with a tie-breaker on disagreement. The report is kept at the repo root (`AUDIT_AHK_2026-07-21.md`) as the open-items record — read it before the next pass instead of re-deriving. 52 confirmed (1 high, 17 medium, 34 low). Dominant classes: the unreadable-config data loss ([[project_ahk_unreadable_config_persists_defaults]]); the `3f9ab1a1e` dead-key ring-visibility gate missing three sibling emit paths (`SendNewResult`, `_DigitRowDown`, and the OneShotShift / Space-hold hooks that `_EmitReachedScreen` never checks); the crash-B "`#HotIf` reads an unset global" class extending BEYOND `Features` (the `_LLM_Tooltip_Visible` trio via `tab_accept.ahk`'s `#HotIf`, and `LOGGER_LOG_PATH` read bare in the pre-ready error net); and the `_PrefixBuffer`/`HSE_Buffer` G5 desyncs on nav-layer sends, physical Home/End/PgUp/PgDn, tooltip expiry and Win+L lock.

**Two confident false-positives were killed by measurement — recorded so they are not re-raised** ([[project_audit_findings_are_hypotheses]], [[project_audit_evidence_must_be_reproducible]]):

- **"Ollama warmup / remote-ready `WinHTTP Send()` blocks the keystroke thread on connect"** (proposed high+medium G4). Both Opus verifiers CONFIRMED it on code-reading alone; a standalone bench refuted it — the async `Send()` returns in 15 ms (see the measured note in [[project_updater_nonblocking_http]]).
- The `/validate`-executes-the-script confusion (wrong in both directions historically) is settled in [[project_ahk_map_delete_raises_on_missing_key]] — the flag validates when it PRECEDES the script path, runs the driver live when it trails it.

**Also refuted this pass, do not re-raise:** the three config bulk-toggle "unchecked gate write" claims (`config_io.ahk:153/:320` — the "the twin reports the write result" premise is false); keep-awake torn-down-but-not-restored-on-resume; reload-mid-hold synthetic-modifier leak; render-once streaming-TTLT freeze; `_LLM_Ollama_TrimAsyncRegistry`'s `ProcessClose`-under-`Critical` (dead code on the Ollama path).

**Coverage gaps left open (silence would read as covered):** ~9 adapters were cleared without being read; the `ui/` editor state machines were grepped only for the `2cc8a8b92` unbound-`this` pattern; `lib/tap_hold/tap_hold_writer.ahk` was never read; the runtime-only mutex-yield-vs-Reload race is unverifiable read-only; and G3 (races) is the thinnest-evidenced guarantee — exactly one confirmed race, every other race conclusion resting on "AHK is single-threaded + Reload is a full restart" with the LLM subsystem dormant across all 11 log days. Observability: the `07-19` boot crashes exist ONLY in `crash_reports/`, never reaching a daily log, because the file sink attaches after the config-read boot phase — read both when reconstructing a boot crash.

Related [[project_ahk_unreadable_config_persists_defaults]], [[project_updater_nonblocking_http]], [[project_ahk_invariant_incomplete_application]], [[project_audit_2026_07_21_open_items]], [[project_ahk_isset_requires_variable_load_crash]].

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

_La migration v1 → v2 est terminee ; ne restent que les gotchas transversaux qu'elle a mis au jour_

<sub>slug: `project_config_v2_refactor`</sub>

La config est unifiee sous `_shared/modules/features/manifest.toml` (snake_case, prefixes `ahk.`/`hs.`), lue par `lib/manifest_reader.ahk` / `macos/lib/manifest_reader.lua`. `ErgoptiPlus.ahk` construit `Features` via `ManifestBuildFeaturesMap()` ; les gates maitres vivent dans `lib/master_gates.ahk` (`CategoryEnabled`, separe des `.enabled` par feature, pour qu'un clic sur le maitre ne detruise pas les choix individuels). Le mapping historique v1→v2 est archive dans `_shared/modules/features/_migration_v1_to_v2.md`. Tous les helpers de miroir (`MirrorV1ToV2_*`, `lib/v1_v2_mirror.ahk`) ont ete supprimes au cut-over — ne pas les rechercher.

**GOTCHA — AHK v2 execute les initialiseurs `global`/`static` AVANT le corps auto-exec.** Ordre verifie par sonde : `global X := f()` → `class.static := g()` → 1re instruction auto-exec → appel de fonction explicite. Un consommateur ne peut donc PAS sourcer une valeur depuis un reader de TOML partage dans son propre initialiseur `global` — le reader n'a pas encore tourne. **Pattern impose : declarer la constante a une sentinelle (`0` / `""`), puis un loader de reassignation** (`TapHoldsLoadTimings`, `KeyloggerWalkerLoadTimings`, `HotstringsConfigLoadSharedDefaults`) appele dans le corps auto-exec. Corollaire `#Include` : `modules/tap_holds/constants.ahk` est inclus TOT dans `ErgoptiPlus.ahk` (l.264-273) car un `#Include` a sa place naturelle re-ecraserait avec les sentinelles les valeurs que `boot.ahk` vient de charger ; `#Include` dedoublonne par chemin, donc l'inclusion tardive est un no-op. Meme classe que le precedent `DYN_HOTSTRINGS_DEFAULT_DELAY`.

**GOTCHA — le garde de purete macOS compte `hs.` dans les COMMENTAIRES et les litteraux de chaine.** `tests/meta/test_port_adapter_coverage.lua` compte les lignes matchant `hs%.` dans `macos/{modules,lib}` contre `LUA_HS_BASELINE`. Un chemin de manifeste (`"hs.hotstrings.expansion_delay"`), une docstring qui cite `hs.timer.doAfter`, ou meme `Paths.shared(` (qui contient litteralement `hs.s`) comptent comme des appels OS. Le commentaire du baseline documente cette classe de faux positifs — **relire ce commentaire avant de re-ancrer** : la cible reelle est zero appel OS, pas zero occurrence. Corollaire : `macos/lib/timings.lua` doit rester pur de tout `hs.`, meme en commentaire.

**Divergences de timings DELIBEREES sur macOS — ne pas « corriger ».** MLX `DISCOVERY_MAX_WAIT_SEC` = 180 s (vs 60 s au registre — chargements 8B lents, `api_mlx_discovery.lua`) et le menu `INSTALLED_CACHE_TTL` = 30 s (vs 2 s, `menu_llm/models_manager_mlx.lua`).

**Gotchas LLM.** (1) Le clamp `min(0.60, temp+0.10)` de `api_mlx.lua` est une escalade de TEMPERATURE au retry, PAS un plafond de tokens — ne pas le « reparer » comme une divergence de tokens. (2) `_shared/tests/corpus/prompt_builder/vectors.json` epingle deja `max_tokens` ET la courbe de temperature de diversite pour les deux drivers : l'etendre plutot que d'ecrire un nouveau corpus.

**Gate de fraicheur du codegen.** `npm run build:domain` regenere en place les generateurs byte-fidele puis verifie la derive via `git diff` : une source modifiee sans re-run, ou l'edition a la main d'un fichier genere, fait echouer la CI. Pour ajouter un generateur au gate : pousser une etape + ses sorties sur le tableau `PIPELINE` de `tools/build/build-domain.cjs`.

**Schema de config.** `tools/test/test-config-schema.cjs` valide `config_template.toml` contre `_shared/core/config_schema/config.schema.json` (validateur JSON-Schema minimal maison, il n'y a pas d'ajv). Quand le manifeste gagne une cle de config, l'ajouter au schema ou ce test casse. Piege : un sous-schema strict dans un `allOf` avec `additionalProperties:false` rejette les proprietes freres — enumerer l'objet en entier.

**Les timings de telemetrie du keylogger AHK ne sont DELIBEREMENT pas balayes.** Ces sous-modules (`keylogger_watchers/_hook/_network/_av_state/_sensors/_mouse/_trigger_roi/_clipboard/_window_topology/_ergonomics`) sont AHK-only (aucune contrepartie macOS → zero valeur de mutualisation) ET absents de `run_all.ahk`, donc un cablage reassign-at-boot serait invalidable en CI avec un risque de sentinelle 0 ms → CPU-spin. Trois sont de vraies divergences code↔registre qui demandent un arbitrage du mainteneur : `CONTEXT_TTL_MS` 1000≠500, `PARK_CHECK_MS` 250≠100, `TOPO_TICK_MS` 1500≠500.

**Hors perimetre acquis** : pas de retrocompatibilite (etat propre — l'utilisateur supprime son ancien config.toml, le driver regenere depuis les templates au 1er boot). Voir [[feedback-loader-target-explicit]] pour la regle « un loader/writer prend son Map cible en parametre explicite, jamais via `global` », nee de ce refactor.

### project_debug_menu_sync

_L'ordre du sous-menu Debug est defini une seule fois dans `_shared/modules/menu/menu_manifest.json` (cle `debug_menu`) ; les deux drivers le consomment_

<sub>slug: `project_debug_menu_sync`</sub>

La cle `debug_menu` de `_shared/modules/menu/menu_manifest.json` est un tableau ordonne (comme `top_level`) et la SEULE source de verite pour l'ordre du sous-menu Debug. Les entrees specifiques a une plateforme portent `"platforms": ["ahk"]` ou `["hs"]` ; sans ce champ elles apparaissent sur les deux.

**Consommateurs :** AHK `MenuManifest_LoadDebugMenu()` (`windows/lib/menu_manifest.ahk`, itere dans `ui/menu/menu_init.ahk`) ; Lua `load_debug_menu()` (`macos/ui/menu/builder.lua`).

**Pourquoi :** le mainteneur exige que l'ordre des menus soit defini une seule fois dans `_shared/`, jamais duplique par plateforme. Ne pas recopier l'ordre ici ni ailleurs — lire le JSON.

**Comment appliquer :** pour reordonner ou ajouter une entree Debug, n'editer que `menu_manifest.json` ; les deux drivers la reprennent au prochain chargement.

Voir [[project_menu_manifest_macos_hotstrings_layout_gap]] — le meme manifeste pilote correctement `debug_menu` sur les deux plateformes, mais `hotstrings_menu`/`layout_menu` ne sont consommes que sous Windows.

### project-menu-manifest-macos-hotstrings-layout-gap

_macOS never reads menu_manifest.json's hotstrings_menu/layout_menu keys (unlike gestures_menu/metrics_menu/shortcuts_menu, which ARE manifest-driven on both platforms) — a drift gate exists, the actual migration does not_

<sub>slug: `project_menu_manifest_macos_hotstrings_layout_gap`</sub>

`_shared/modules/menu/menu_manifest.json` is the intended single source of truth for tray-menu structure across both drivers. On Windows, `hotstrings_menu` and `layout_menu` are consumed generically through `lib/manifest_menu.ahk`'s `MenuRenderer_Build`, exactly like `gestures_menu`/`metrics_menu`/`shortcuts_menu` — so reordering the manifest updates all four menus with no code change. On macOS, `gestures_menu`/`metrics_menu`/`shortcuts_menu` were correctly migrated to the equivalent `lib/manifest_menu.lua`'s `ManifestMenu.build`, but `ui/menu/menu_hotstrings.lua`, `ui/menu/builder.lua`, and `ui/menu/menu_keyboard_layout.lua` still hand-assemble the hotstrings and layout submenus imperatively — zero references to the manifest's `hotstrings_menu`/`layout_menu` arrays anywhere in that code. Reordering or editing those two manifest keys silently desyncs the two platforms' tray menus, with nothing catching it until a human notices the mismatch.

**Interim mitigation (2026-07-03):** `macos/tests/meta/test_menu_hotstrings_layout_drift_gate.lua` pins the current `hotstrings_menu`/`layout_menu` shape (hs-filtered signatures) against two hardcoded `CANONICAL_*` tables. This makes a manifest edit fail LOUDLY (the test breaks) instead of silently — a human is now forced to look at whether the macOS hand-built menu needs the same change — but it does not make macOS manifest-driven. The real fix is migrating `menu_hotstrings.lua`/`menu_keyboard_layout.lua`/`builder.lua` to read the manifest the way `gestures_menu` already does; that migration was assessed as a larger, riskier refactor than a bounded single-commit fix warrants (unfamiliar macOS Lua UI code, two menus' worth of imperative logic to replace) and was deliberately deferred rather than rushed.

**Why:** Found during the 2026-07-01 AHK driver audit's `project_debug_menu_sync` watch-list re-check — the same SSOT manifest that correctly drives `debug_menu` on both platforms also defines `hotstrings_menu`/`layout_menu`, but only Windows actually consumes them.

**How to apply:** Before editing `hotstrings_menu`/`layout_menu` in `menu_manifest.json`, run the macOS Lua suite (`cd static/ergopti_plus/macos && lua tests/run.lua`) — the drift gate will fail if the edit isn't also reflected in macOS's hand-built menu code. When picking up the deferred migration: mirror how `gestures_menu` was done (`lib/manifest_menu.lua`'s `ManifestMenu.build`, consumed from `builder.lua`), then delete the drift-gate test since it becomes structurally redundant once macOS is manifest-driven.

See also [[project_debug_menu_sync]].

### project-gestures-reversal-detection

_Detection des inversions de direction dans le moteur de gestes (mode x1 vs incremental)_

<sub>slug: `project_gestures_reversal_detection`</sub>

`static/ergopti_plus/macos/modules/gestures/engine.lua` gere deux modes de declenchement qui exigent une logique d'inversion DIFFERENTE. Ne pas les unifier.

**Pourquoi :** une regression avait fait un `return` inconditionnel dans `commitGesture` des qu'un tir live avait eu lieu. Consequence : un swipe 4 doigts gauche-puis-droite perdait l'inversion — l'utilisateur swipe a gauche (tire `space_prev`), inverse vite a droite, leve avant que le declencheur live ne franchisse `LIVE_AXIS_MIN`, et le commit refusait de tirer `space_next`.

**Mode x1** (swipes espace/expose 4 doigts, swipes 2 doigts, vertical 5 doigts) : le commit tire la nouvelle direction si `sign(sd) != gs.liveAxisSign`. Ne bloquer QUE les doubles-tirs dans la meme direction.

**Mode incremental** (mot 3 doigts, fenetre 5 doigts) : suit `gs.lastFirePos` a chaque tir. A chaque nouvelle frame, si le mouvement depuis `lastFirePos` atteint `LIVE_AXIS_MIN` dans la direction opposee a `liveAxisSign`, rebaser `startPos` sur la position courante immediatement. Bien plus reactif que l'ancien repli `diff < 0`, qui obligeait a revenir jusqu'a l'origine.

**Invariant :** les deux modes doivent initialiser `gs.lastFirePos = nil` dans `resetGS()` **ET** a l'ouverture d'un nouveau geste (branche `if not gs.active` de `process_frame`).

Voir [[project-gestures-startup-design]].

### project-gestures-startup-design

_Choix de conception du demarrage des gestes macOS — le primer sert de signal de reveil, PAS des burst probes_

<sub>slug: `project_gestures_startup_design`</sub>

Le module `static/ergopti_plus/macos/modules/gestures/` a longtemps souffert d'un bug de demarrage a froid : au lancement, l'abonnement `hs._asm.undocumented.touchdevice` etait attache mais ne recevait aucune frame tant que l'utilisateur n'avait pas touche le trackpad. Le premier geste etait perdu ; les gestes ne devenaient reactifs que ~10 s plus tard, au declenchement du timer de decouverte.

**Pourquoi :** le chemin de dispatch IOKit HID n'est pas initialise au lancement. Le watcher « tourne » techniquement, mais l'OS ne lui route aucune frame.

**La conception actuelle combine DEUX mecanismes — ne pas regresser vers les burst probes seuls :**

1. **Boucle de sonde adaptative** (`init.lua`) : recycle les watchers toutes les 500 ms jusqu'a la premiere frame, puis bascule sur un health-check a 20 s. Remplace l'ancien `STARTUP_BURST_DELAYS = {0.05, 0.15, …, 4.5}` fixe, qui s'epuisait trop tot.

2. **Primer comme signal de reveil** : l'eventtap `gesture_primer` (deja abonne a NSEventTypeGesture & co. pour garder le dispatch OS vivant) declenche AUSSI un recyclage d'urgence (`schedule_emergency_recycle`) s'il voit un evenement de classe geste avant toute frame touchdevice. Le premier geste physique de l'utilisateur debloque donc lui-meme le pipeline, et ce geste est capture en vol au lieu d'etre perdu. Un cooldown de 1 s (`EMERGENCY_RECYCLE_COOLDOWN`) evite plusieurs recyclages sur une rafale au premier contact.

Le primer gere aussi `tapDisabledByTimeout`/`tapDisabledByUserInput` en se reengageant, et s'abonne largement (`beginGesture`, `endGesture`, `swipe`, `magnify`, `rotate`, `directTouch`, `smartMagnify`) pour que l'arbre de dispatch s'initialise entierement.

Voir [[project-gestures-reversal-detection]].

### project-hotstring-delay-architecture

_Ou se configure le delai d'expansion des hotstrings, la precedence cross-driver, et les pieges_

<sub>slug: `project_hotstring_delay_architecture`</sub>

Voir [[project_hotstring_engine_internals]].

**Source de verite = le TOML partage par categorie**, `_shared/modules/hotstrings/<categorie>.toml` :

- `[_meta] delay = <s>` — delai du groupe/categorie.
- `[_meta.section_delays]` (lignes `<section> = <s>`) — surcharges par section, ex. `comma_j = 5`.
- **PAS** `features/manifest.toml`'s `time_activation_seconds` : il est bien lu par `toml_loader.ahk`, mais immediatement ecrase par la cascade `HotstringsResolve` — l'editer n'a aucun effet runtime.

**Precedence (les deux plateformes, du plus fort au plus faible) :** surcharge utilisateur → delai de section TOML → delai de groupe TOML → defaut global regle au menu → fallback dur.

**AHK :** `HotstringsResolve(cat, sec).Delay` resout la cascade ; la cle `_global` de `_HotstringsOverrides` est le defaut d'expansion regle au menu (Delais → « delai par defaut », persiste via `HotstringsSetOverride("_global","","delay",s)`). `ParseTomlGroupConfig` lit `[_meta.sections.<nom>]` ET `[_meta.section_delays]` dans `Sections[x].Delay`.

**macOS :** delai par GROUPE via `CoreState.DELAYS[group]`, par SECTION via `CoreState.SECTION_DELAYS[section]` (lu du TOML partage par `toml_codec/reader.lua`). `mapping_fires` applique la precedence (un delai de groupe different de son defaut = surcharge utilisateur, et gagne sur le delai de section). Les delais de section sont replies dans `WORD_TIMEOUT_SEC` (`recompute_word_timeout`) pour qu'une fenetre longue (5 s) ne soit pas coupee par l'effacement d'inactivite. macOS ne lit PAS le `[_meta] delay` de groupe (il utilise `DELAYS_DEFAULT`) ; seuls les delais de section viennent du TOML.

**Categories pseudo cote AHK.** `llm_prediction` et `dynamichotstrings` n'ont AUCUN TOML de categorie — `ParseTomlGroupConfig` renvoie silencieusement une config vide pour un fichier absent, donc ce sont des cles de surcharge pseudo-categorie : le defaut est une constante partagee, la surcharge est persistee via `HotstringsSetOverride("llm_prediction"|"dynamichotstrings", …)`. Cela evitait un plombage `_LLM_Tray` sur 6 fichiers et le risque d'enumeration lie a de faux TOML de categorie. Le timer du tooltip LLM resout la surcharge a chaud (effet immediat) ; les autres delais de categorie AHK ne s'appliquent qu'au redemarrage (le `TimeActivationSeconds` enregistre est lu au boot).

**Les trois fallbacks durs sont un fichier cross-driver.** `GLOBAL_DEFAULT_DELAY` (0.75 s), `GLOBAL_DEFAULT_COLOR` (#1e88e5), la baseline `personal` (#6e6e73) et `DYN_HOTSTRINGS_DEFAULT_DELAY` (2.0 s) vivent UNE SEULE FOIS dans `_shared/modules/hotstrings/defaults.toml` (`[colors]`, `[delays]`), lus au boot par les deux drivers avec un `require_key` fail-fast. Pieges d'implementation :

- **AHK utilise un loader EXPLICITE, jamais une lecture au top-level.** `HotstringsConfigLoadSharedDefaults()` est appele depuis le boot (avant `HotstringsConfigInit` et avant la construction du tray, qui lit `GLOBAL_DEFAULT_DELAY`). Il n'est PAS au top-level de `hotstrings_config.ahk` parce que `tests/test_hotstring_aggregation.ahk` fixe `_SharedDir` APRES son `#Include` — une lecture au top-level leverait a l'inclusion. Les globales partent a des sentinelles `""` / `Map()`. Meme classe de boot-order que le gotcha AHK v2 de [[project_config_v2_refactor]].
- **Fail-fast = THROW, pas `MsgBox`+`ExitApp`.** Une cle manquante leve une `Error` : en prod le boot non rattrape affiche le dialogue fatal et sort (voulu) ; en CI le `OnError` de `run_all.ahk` la transforme en `not ok 0`. Un `MsgBox` bloquerait le runner headless. Cote macOS c'est un `error()` au require.
- **`IniCacheGet`/`ParseTomlFile` renvoient les couleurs AVEC le `#` de tete** ; le loader strip puis re-ajoute pour normaliser. Ne pas doubler le prefixe.
- **Piege independant : le runner cible `tests/run_hotstrings_config.ahk` remonte ~14 echecs** (`_HSE_SourcePriority` « local variable has not been assigned a value ») parce qu'il n'inclut PAS `hotstring_engine_main.ahk`, qui definit ce symbole desormais appele dans la cascade de resolution. **Juger les changements hotstrings_config avec `run_all.ahk`, pas avec le runner cible.**
- Des tests tripwire single-source des deux cotes (`test_hotstrings_config.ahk` §SharedDefaults, `macos/.../unit/modules/test_hotstrings_defaults.lua`) assertent que les valeurs chargees egalent le fichier ET epinglent les litteraux canoniques.

### project-hotstring-engine-internals

_OnChar doit alimenter chaque caractere une seule fois ; la divergence de cadrage des frontieres de mot AHK vs Hammerspoon est intentionnelle_

<sub>slug: `project_hotstring_engine_internals`</sub>

Internes durement acquis du moteur de correspondance des hotstrings (Windows AHK + macOS Hammerspoon).

**Provenance de l'entree synthetique.** Le prefix watcher est cree `InputHook("V L0 I1")` (`lib/hotstrings/hotstring_inputhook.ahk`) : `I1` filtre l'entree synthetique de bas niveau (les rafales `SendInput`/`SendEvent` du driver partent au SendLevel 0 par defaut) tout en preservant chaque touche physique. C'est un filtrage par PROVENANCE, qui a remplace une ancienne fenetre temporelle de 60 ms — laquelle jetait aussi la vraie frappe juste apres une expansion. La machinerie `HSE_Suppressed` / `PrefixWatcherSuppress` subsiste en complement (`hotstring_builder.ahk`) ; ne pas la supprimer en supposant que `I1` suffit seul.

**OnChar doit alimenter chaque caractere EXACTEMENT une fois.** `_OnPrefixChar` alimente chaque caractere en tete de fonction (la ou les correspondances end-char/star tirent). Un bug historique re-alimentait les terminateurs de mot dans la branche frontiere : `;`/`:` atterrissaient DEUX fois dans `HSE_Buffer`, cassant silencieusement tout declencheur contenant un terminateur comme caractere NON final. Corrige en retirant le re-feed de la branche frontiere. macOS n'ajoute qu'une fois dans la boucle keyDown de `init.lua` et n'a jamais eu ce bug. **Si tu touches a la branche frontiere, ne re-alimente jamais.**

**Le jeu de terminateurs est configurable a chaud.** `HSE_WORD_TERMINATORS` est assigne au boot depuis `HotstringsGetWordDelimiters()` (`lib/boot.ahk`) — surcharge utilisateur ou `HOTSTRINGS_DEFAULT_WORD_DELIMITERS` — et `HotstringsSetWordDelimiters` le remplace en vol sans Reload. Le litteral dans `hotstring_engine_main.ahk` n'est que la constante de compilation, ecrasee au boot ; y epeler les apostrophes `Chr(0x27) . Chr(0x2019)` (une passe de typographie a deja silencieusement reecrit l'apostrophe ASCII en un second U+2019, faisant disparaitre U+0027). Le jeu de frontieres du prefix watcher est DERIVE de `HSE_WORD_TERMINATORS` et doit etre recalcule apres toute reassignation, sinon l'apercu et le matcher s'ancrent sur des jeux differents et les expansions previsualisees ne tirent jamais.

**La divergence de cadrage des frontieres de mot est VOULUE — ne pas l'aligner sans besoin utilisateur concret.** AHK utilise une ALLOWLIST de terminateurs (`_HSE_WordBoundaryAllows` : tirer seulement si le caractere precedant le declencheur est dans `HSE_WORD_TERMINATORS`, ou en debut de buffer). Hammerspoon utilise une DENYLIST de lettres (`word_boundary_blocks` → bloque si `text_utils.is_letter_char(prev)` ; le `%w` de Lua = lettres+chiffres, PAS l'underscore). Les deux sont d'accord sur toute entree francaise normale (espace/ponctuation/apostrophe → tire ; lettre/chiffre → bloque). Ils ne divergent QUE sur des caracteres precedents exotiques (trait d'union, `_`, `(`, `/`) : macOS tire, AHK bloque. Impact faible et le « mieux » est genuinement ambigu. Le declencheur `;` nu de comma→J est intra-mot des DEUX cotes (AHK `*?C` ; macOS via le saut de `;` initial dans `word_boundary_blocks`), donc le J majuscule est garanti dans tous les contextes — `:` nu n'est deliberement PAS un declencheur.

**`_HotstringRegistrar` vaut 0 en production.** Les hotstrings gerees par ErgoptiPlus s'enregistrent uniquement via HSE (`CreateHotstring` → `_RegisterHotstring` → `_MirrorRegistrationToHSE` → `HSE_Register`). Le `Hotstring()` natif d'AHK n'est atteint que si `_HotstringRegistrar` est non nul, et rien en production ne le fixe (`lib/hotstrings/hotstring_engine.ahk` : `global _HotstringRegistrar := 0`) — seul le harnais de test y injecte un recorder via `InstallHotstringHooks`. Les rares hotstrings vraiment natives (deadkey Ê, `…`) appellent `Hotstring()` directement. **Consequence exploitable : tout le cout d'enregistrement au boot est reproductible en headless, sans hook clavier.**

Voir [[project_hotstring_live_rebuild]], [[project_keymap_architecture]].

### project-hs-perf-profilers-and-case-conform

_Profilers boot/hot-path macOS, chemin rapide case-conform, cache du menubar, snapshot TOML, et le piege Escape arme au premier affichage_

<sub>slug: `project_hs_perf_profilers_and_case_conform`</sub>

**Profilers.** `lib/boot_profiler.lua` (`Boot.begin()` / `Boot.mark(phase)`) journalise `+delta ms (total ms)` par phase en INFO. `lib/hotpath_profiler.lua` (`HotPath.now()` / `HotPath.log_if_slow(label, t0, detail)`) n'emet un WARNING que si un segment depasse le seuil (5 ms par defaut) ; cable dans `keymap/init.lua` `onKeyDown` et `tooltip_llm.show_predictions`. **Les deux lisent l'horloge via `adapters.timer_scheduler` (`now()` / `now_ns()`), JAMAIS `hs.timer.*` directement** : le garde `tests/meta/test_port_adapter_coverage` compte les occurrences de `hs.` (y compris en commentaire) dans `modules/`+`lib/`. Les adapters sont exemptes ; tout nouveau code lib/modules doit router ses appels OS par eux.

**Chemin rapide case-conform** (`registry.lua` + `expander.lua` + `text_utils.conform_replacement`). Un declencheur auto, insensible a la casse, texte simple, sans caractere shift-symbole (`, ' .`) et non termine par la touche magique est enregistre comme UNE entree minuscule (`m.case_conform = true`) au lieu du trio minuscule/Titre/MAJUSCULE ; `try_auto_expand` conforme la casse du remplacement au declencheur tape (casse mixte → `conform_replacement` renvoie nil → pas de tir, comportement identique a l'ancien sans variante). Les buckets de caractere final sont passes de `:lower()` ASCII a `text_utils.trig_lower` Unicode (enregistrement ET `mappings_for_tail`/`rebuild_tail_indexes`) pour qu'un « Ê » final majuscule tombe dans le bucket « ê » — REQUIS pour que les entrees conform matchent des declencheurs accentues capitalises. **Realite du gain :** concentre sur `autocorrection` (~316 conform, ~630 entrees evitees) ; `magickey` n'en profite quasiment pas car ~1587/2119 de ses entrees sont deliberement `is_case_sensitive = true`. L'estimation d'agent « diviser le corpus par deux » etait fausse. Regression : `tests/unit/modules/keymap/test_case_conform.lua`.

**Cache du menubar** (`ui/menu/init.lua`). L'arbre genere est mis en cache ; le callback `setMenu` renvoie le cache sauf si `_menu_dirty` ou si l'etat de pause a bascule. **Toute NOUVELLE mutation d'etat qui doit rafraichir le menu DOIT poser `_menu_dirty = true`** (passer par `updateMenu`/`save_prefs`). Apres l'amorcage, `rebuild_menu_cache()` pousse un menu natif STATIQUE (`push_static_menu()`) pour qu'AppKit reutilise un NSMenu preconstruit ; les changements d'etat le re-poussent via un `schedule_menu_refresh()` coalesce. **Le comportement du menu statique n'est pas testable unitairement** (le stub `hs.menubar` est un no-op) — verifier la latence d'ouverture sur un vrai Mac.

**Cache snapshot TOML** (`adapters/toml_cache.lua` + hook dans `_shared/lua/toml_codec/reader.lua`). Le reader partage expose un hook PUR injecte — `M.set_cache_provider({load, store})` — et reste sans acces disque ; tout le travail filesystem/`hs` vit dans `adapters/` (repertoire EXEMPT des baselines du garde de purete). L'adapter serialise chaque table parsee en chunk Lua precompile charge par `loadfile` (~10× plus rapide que le parseur a la main). **L'invalidation est mtime ET taille ET une constante `CACHE_VERSION` : bumper `CACHE_VERSION` des que la forme de sortie de `reader.parse` change**, sinon un snapshot perime nourrit une structure incompatible. Toute incoherence/corruption est un miss silencieux qui retombe sur un parse normal, donc un fichier hotstrings edite n'est jamais servi perime. Cable dans `init.lua` AVANT tout `keymap.load_toml`. Regressions : `tests/unit/lib/test_toml_reader_cache_hook.lua` + `tests/unit/adapters/test_toml_cache.lua`.

**GOTCHA — le piege Escape du LLM est arme au PREMIER affichage du tooltip, exprès ; ne pas le deplacer dans init.** `llm_bridge.arm_escape_trap` est cable via `tooltip.set_on_show_callback`, pas via `M.init()`. C'est deliberé : l'eventtap doit etre insere en TETE *apres* que Raycast (ou toute autre app) ait enregistre le sien, pour que notre Escape ait la priorite pendant qu'un tooltip est visible. L'armer au boot risquerait de s'enregistrer avant ces apps et de perdre la priorite Escape. Le cout unique de `eventtap.new()` au premier affichage est le compromis accepte — ne pas l'« optimiser » vers init.

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

_Ou vivent les defauts du module keymap, et pourquoi une seule place_

<sub>slug: `project_keymap_architecture`</sub>

## Valeurs par defaut : source de verite unique

- **Tous les defauts keymap** vivent dans `modules/keymap/init.lua` → `M.DEFAULT_STATE` et `M.DELAYS_DEFAULT`.
- `ui/menu/menu_hotstrings.lua` lit `preview_star_enabled`, `preview_autocorrect_enabled`, `preview_ai_enabled`, `preview_colored_tooltips` depuis `keymap.DEFAULT_STATE` — ne les redeclare jamais.
- `llm_bridge.lua` amorce ses drapeaux d'apercu locaux depuis la table `keymap_defaults` passee a `M.init()`.

**Pourquoi :** le mainteneur exige que les valeurs par defaut soient definies a exactement UN endroit (le module keymap) et que le menu ne stocke que les surcharges utilisateur, jamais ses propres defauts pour un reglage possede par keymap.

## Repartition des responsabilites

- `modules/keymap/init.lua` — moteur principal, CoreState, boucle eventtap.
- `registry.lua` (+ `registry_groups.lua`, `registry_index.lua`) — base des hotstrings, chargement TOML/Lua, gestion groupes/sections, terminateurs.
- `utils.lua` — emission de texte (frappes vs collage presse-papier), parsing de tokens, solveur de recouvrement LLM, cache des fenetres ignorees.
- `expander.lua` — auto-expansion, expansion par terminateur, execution de la fonction repeat.
- `llm_bridge.lua` — apercu des hotstrings, acceptation de prediction, transmission de la config LLM.
- `lib/text_utils.lua` — simple re-export de `_shared/lua/text_utils` ; toute modification des utilitaires UTF-8 / diff / casse se fait dans `_shared/`, pas ici.

(Les conventions generales — `require_state`, aucun repli silencieux, paires `Logger.start`/`success` et `trace`/`done`, setters qui loggent — sont deja imposees par `.github/copilot-instructions.md` §4 et §5 ; ne pas les redupliquer ici.)

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

_en.json est le jeu de cles canonique ; le meta-test AHK test_locale_json_valid.ahk impose la parite en CI ; `tools/locale/check_locales.py --fix` est l'outil de backfill manuel_

<sub>slug: `project_locale_parity_test`</sub>

`static/ergopti_plus/_shared/data/locales/en.json` est la reference canonique. Tout autre fichier de locale doit refleter exactement son jeu de cles — aucune manquante, aucune en trop.

**Pourquoi :** les cles obsoletes (retirees d'EN mais restees dans les traductions) et les cles manquantes (ajoutees a EN mais pas encore traduites) partent toutes les deux en production comme des bugs.

La parite est imposee en CI par le meta-test AHK `windows/tests/meta/test_locale_json_valid.ahk` (execute par `run_all.ahk` dans le job `test-ahk`) : il construit l'union des cles de tous les locales et asserte que chaque fichier la contient integralement. Il verifie aussi que chaque fichier parse, que l'enveloppe `{…}` est intacte (un script d'insertion avait un jour retire le `{` ouvrant de tous les locales) et que `_meta.locale` / `_meta.flag` / `_meta.name` sont presents. `tools/locale/check_locales.py` est l'outil developpeur qui asserte la meme parite en local et, via `--fix`, la PRODUIT. Il n'y a pas de `.github/workflows/test_locales.yml` — ce workflow n'a jamais existe.

**Comment appliquer :**

- Ajouter une cle : l'inserer dans en.json, puis lancer `python tools/locale/check_locales.py --fix` pour la backfiller dans tous les autres locales avec la valeur anglaise en placeholder. Les traductions viennent ensuite.
- Retirer une cle : la supprimer d'en.json, puis `--fix` la retire de tous les autres.
- La colonne « Untranslated » de la sortie est purement informative : cognats et noms de marque partagent legitimement le texte anglais, elle ne fait donc PAS echouer la CI.

Memoire soeur : [[project-locale-fast-cache]] (le cache `.tsv` de parsing rapide, une preoccupation distincte) et [[project-ui-dynamic-buttons]].

### project-locale-fast-cache

_Le `.tsv` de locale du driver Windows est un cache gitignore auto-reparateur regenere depuis le `.json` canonique ; seul le `.json` est versionne_

<sub>slug: `project_locale_fast_cache`</sub>

Le `JsonParse` d'un locale complet coute ~180 ms sur le chemin critique du boot (le tray a besoin de `t()`) ; parser a la place le `.tsv` plat `cle<TAB>valeur` coute ~16 ms. Pour garder cette vitesse SANS versionner deux fois la meme donnee, les `.tsv` sous `_shared/data/locales/` sont un **cache gitignore auto-reparateur** possede de bout en bout par `lib/locale.ahk` (`_I18nLoadLocaleMap` / `_I18nTsvIsFresh` / `_I18nWriteTsvCache`) : au chargement il utilise le `.tsv` s'il existe ET est au moins aussi recent que le `.json` (comparaison `FileGetTime "M"`), sinon il parse le `.json`, construit la map et reecrit le `.tsv` pour le boot suivant. Le `.json` est la seule source de verite versionnee ; les consommateurs sont Windows uniquement.

**Pourquoi :** la regle dure du mainteneur est **aucune duplication versionnee**. Le design precedent commitait a la fois le `.json` et un `.tsv` genere par codegen (+ un test de parite node + un garde pre-commit) — la meme donnee deux fois dans git. Le cache paresseux supprime le `.tsv` versionne, supprime le codegen node et l'infra de parite, et fait du driver AHK le SEUL generateur : un format sur disque qui ne peut pas deriver de sa source (un `.tsv` perime est detecte par mtime et reconstruit). **Ne pas re-proposer un `.tsv` genere et versionne.**

**Comment appliquer :**

- N'editer que le `.json`. Le driver regenere le `.tsv` au prochain boot des qu'il manque OU est plus vieux que le `.json` (un boot lent, puis rapide a nouveau). Ne jamais commiter un `.tsv` — `.gitignore` le bloque.
- Le cache stocke les valeurs avec le placeholder `★` BRUT (independant de la MagicKey) ; le reader substitue la MagicKey configuree au parsing. Le writer echappe `\` → `\\`, CR → `\r`, LF → `\n` (**le backslash EN PREMIER**) ; le reader inverse en une seule passe de gauche a droite. Garder writer et reader en phase — `test_i18n.ahk` epingle l'aller-retour, la regeneration sur peremption, le `★` brut et le service par le chemin rapide sans `.json`.
- Un repertoire d'installation en lecture seule signifie juste que l'ecriture echoue silencieusement et que chaque boot passe par le `.json` (correct, plus lent) — le cache est strictement best-effort.

Memoire soeur : [[project-locale-parity-test]] est le garde de parite du jeu de cles d'en.json, une preoccupation distincte de ce cache.

### project_metrics_pipeline_17

_Architecture du pipeline metrics AHK — pourquoi AHK ne peut pas devenir pur-walker comme macOS_

<sub>slug: `project_metrics_pipeline_17`</sub>

**Architecture (verifiee).** Les donnees du dashboard viennent du prefetch (`keylogger_prefetch.ahk` → `keylogger_reader*.ahk` `KLR_BuildDatabase` → manifeste JSON dans A_Temp). KLR charge le `data.sql` de TOUS les appareils (`events_*` all-time) dans une base `:memory:` en cache, puis a chaque cycle Clear→Rebuild→Inject : `KLR_ClearAggregates` efface `agg_*`/`ngram_*`, `KLR_RebuildAggregates` recalcule en SQL les agregats derivables depuis `events_*`, `KLR_InjectKlwBatch` draine le batch KLW vivant (recent uniquement).

**Le point crucial : AHK ne persiste DELIBEREMENT pas les agregats** (anti-bloat, ~140 Mo/jour) — c'est precisement pour cela que le rebuild SQL existe. macOS (`macos/modules/keylogger/aggregator/`) est mono-source (le walk possede TOUTES les tables agg, persistees a chaque tick), et le JS du dashboard (`_shared/ui/metrics_typing/data.js`, `metrics_apps/script.js`) est ecrit contre la semantique macOS. **AHK ne peut pas passer pur-walker comme macOS sans reintroduire le bloat — ne pas « unifier » les deux dans ce sens.**

**Ligne de partage a respecter :** le rebuild SQL est la source unique de tout ce qui est calculable depuis `events_*` ; le walker est la source unique UNIQUEMENT des tables niveau caractere/ngram (ngrams, kc_hold, buckets, errors, ergo, chars_class, burst, session, layouts) et des colonnes d'enrichissement que SQL ne peut pas calculer. Une colonne ecrite des deux cotes = double comptage (c'etait la cause racine n°1 du bug #17).

**Pieges de diagnostic :** `compact_work.db` est un artefact de debug du lanceur, PAS la source du dashboard. Interroger la base avec `python` (pas `python3`).

**Lacunes connues, non bloquantes :** `app_time` affiche d'anciennes donnees parasites pour les lignes `events_app_switch` anterieures au correctif d'idle (historique seulement) ; `chars` inclut les frappes `[BS]` — conforme a la semantique macOS, intentionnel.

**Lint :** le hook husky pre-commit lance `lint-conventions.js --fail-on-violations` et BLOQUE en cas de violation. Toujours `npm run fix:all` avant de commiter.

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

_Les hotstrings groupees ne sont plus de l'AHK genere et versionne : c'est un cache `.tsv` gitignore auto-reparateur reconstruit depuis les TOML au runtime, pour couper le parse au boot_

<sub>slug: `project_hotstrings_self_healing_cache`</sub>

Le plus gros cout de boot etait invisible : **AHK tokenise chaque source `#Include`ee AVANT de creer l'icone du tray**, et le bundle `generated_*.ahk` versionne pesait ~1 Mo / ~2992 lignes — mesure a ~470 ms des ~470-660 ms de « temps jusqu'a l'icone ». **Compiler en `.exe` n'aiderait PAS** : les I/O disque pour les 259 fichiers du driver ne font que ~35 ms, le cout est la tokenisation CPU. `BootProfile_ProcessUptimeMs()` (FILETIME de creation via GetProcessTimes vs maintenant) expose cette phase anterieure au premier log.

Correctif (calque exactement sur le cache `.tsv` de locale, voir [[project-locale-fast-cache]]) : les 6 `generated_*.ahk`, le codegen node `build-hotstrings.cjs` ET le codegen python `compile_hotstrings.py` ont ete supprimes (+ le script npm `build:hotstrings` + l'etape CI de regeneration). `lib/hotstrings/hotstrings_cache.ahk` possede desormais le mecanisme : `HotstringsCacheEnsure()` lit `_shared/modules/hotstrings/generated_hotstrings.tsv` (gitignore) quand il est au moins aussi recent que chaque TOML groupe ; sinon il **reconstruit depuis les TOML une fois** (premier lancement ou apres edition) et le reecrit. Il se branche sur le MEME chemin rapide `_GENERATED_HOTSTRINGS` que `LoadHotstringsSection` consulte deja, donc les appelants sont inchanges. Lignes : `[flags, trigger, output, finalResult, isRepeat, isCaseSens]` ; le builder reutilise a l'identique le scan de lignes, `_HOTSTRING_ENTRY_PATTERN`, `UnescapeTomlString` et la logique de flags du repli TOML runtime, reproduisant donc l'ancien comportement genere 1:1.

**Deux comportements preserves VERBATIM — ce ne sont pas des bugs a corriger :** (1) `isRepeat` etait DEJA toujours faux dans l'ancienne sortie generee, parce que le generateur comparait la section au litteral `"repeatcorrections"` alors que la vraie section est `repeat_corrections` (underscore) ; (2) le chemin rapide genere ne posait jamais `Priority` dans les options (le repli TOML, lui, le fait) — le cache s'aligne sur le chemin genere. Corriger l'un ou l'autre changerait le comportement en production.

Le chemin d'enregistrement des hotstrings groupees n'avait AUCUNE couverture bout-en-bout ; `tests/unit/test_hotstrings_cache.ahk` est desormais ce filet (parite de construction, aller-retour `.tsv` sans perte, echappement de tab/CR/LF/backslash). Le premier lancement (ou celui qui suit une edition) paie un parse TOML unique ; chaque boot ulterieur est la lecture rapide du `.tsv`.

Rappel encodage pour tout nouveau `.ahk` : UTF-8 **BOM** + LF, sinon AHK avorte silencieusement en cours de fichier — voir [[feedback-ahk-source-encoding]].

### project-prefix-index-rebuild-cost-is-cold-disk

_The prefix-watcher index rebuild's cost is the cold-disk TOML read, NOT parse CPU — build the index from the in-memory `_HS_CACHE_ROWS`, the same way HSE registration does._

`HotstringPrefixWatcherRebuildIndex` used to rebuild its preview index by re-reading + regex-parsing every category TOML from disk (`_RegisterCategoryTriggers` per category). The smoking gun was in the boot log: the **same 3180-trigger index** measured **157 ms once the OS file cache was warm but 3031–6422 ms on the cold read right after a reload** (magickey.toml alone is ~2119 entries), under boot disk/CPU contention. That multi-second synchronous rebuild monopolised the single AHK thread, so the **tray menu could not open** during the deferred boot pass — the user-visible "menu takes seconds to appear". The parse work itself is cheap; the disk read is what blew up. Two rebuilds run at boot (the boot-tail warm-up `SetTimer(HotstringPrefixWatcherRebuildIndex, -HS_PREFIX_INDEX_WARM_DELAY_MS)` in `ErgoptiPlus.ahk`, and the one in `RegisterEmojisSymbolsDeferred`); both build the identical index, so they showed identical 3180 counts.

Fix: bundled categories now rebuild from the already-parsed in-memory `_HS_CACHE_ROWS` (`_RegisterCategoryTriggersFromCache`) — no `FileRead`, no per-line regex. It mirrors `_RegisterCategoryTriggers`' gating (master gate, V2 snake_case remap, per-section Features `enabled`) and feeds the SAME `_AddTriggerVariants` pipeline, so the index is **byte-identical** (pinned by `tests/test_prefix_index_cache_equiv.ahk`, which builds both ways over case-sensitive / strict / magic-key / priority-override entries and asserts entry-for-entry equality). Personal (never bundled — relocatable TOML) and any cache-miss still parse TOML. Map the cache row `[flags, trigger(★), output, finalResult, isRepeat, isCaseSens, priorityOverride]` to the watcher fields via: `IsCaseSensitive = Row[6]`, `IsStrict = InStr(Row[1],"C")>0`, `Individual = Row[7]`, and `StrReplace(★ → MagicKey)` on trigger+output.

Gotcha: the boot-tail warm-up has its OWN `SetTimer`, so it can race ahead of the cache load and fall back to the cold-disk path (`_PrefixWatcherCategoryIsCached` returns false while `_HS_CACHE_LOADED` is still false). The rebuild therefore calls the idempotent `HotstringsCacheEnsure()` first to guarantee the in-memory path. See [[project-hotstrings-self-healing-cache]].

<sub>slug: `project_prefix_index_rebuild_cost_is_cold_disk`</sub>

### project-suspend-pause-invariant

_La pause doit TOUT taire (aucun tooltip/LLM/keylogger/widget). Le Suspend AHK ne desarme que les hotkeys — InputHooks, timers et OnMessage le contournent et exigent des gardes `A_IsSuspended` explicites._

<sub>slug: `project_suspend_pause_invariant`</sub>

Quand le script est en pause, ABSOLUMENT rien ne doit s'activer — aucun tooltip, aucune prediction/HTTP LLM, aucun enregistrement keylogger, aucun widget WPM, aucune action de geste. Mots de l'utilisateur : « comme ahk éteint donc absolument aucun tooltip ou autre truc ahk ne doit s'activer ».

**Pourquoi c'est un piege :** le `Suspend()` natif d'AHK ne desarme QUE les **Hotkeys/Hotstrings**. Il ne touche NI les callbacks `InputHook`, NI ceux de `SetTimer`, NI les handlers `OnMessage`, NI `SetWinEventHook` — tous continuent de tirer pendant `A_IsSuspended`. Or tout le pipeline d'entree d'ErgoptiPlus est bati sur ceux-la : la pause faisait taire les remaps mais laissait tooltips, LLM et keylogger pleinement vivants.

**L'invariant (AHK) :** tout callback InputHook / timer / OnMessage produisant un effet de bord observable DOIT sortir tot sur `A_IsSuspended`. Les gardes existent aujourd'hui dans `lib/hook_dispatcher.ahk` (couvre le pont LLM et les watchers keylogger), les InputHooks propres du prefix watcher et du keylogger, les points d'entree de rendu des tooltips, le moteur de prediction LLM, le widget WPM, la couche `adapters/` et `lib/lifecycle.ahk`. **La regle prospective compte plus que cette liste : quand tu ajoutes un hook, un timer ou un chemin de tooltip, ajoute la garde, sinon il fuit pendant la pause.** Les timers keylogger de basse priorite (tick d'inactivite, park souris, demi-vie roi, OnMessage session/power) ne sont pas encore gardes — les garder aussi si le silence radio total est voulu.

**Reacteur central :** `ToggleSuspend` (`lib/lifecycle.ahk`) appelle `Ergopti_OnSuspendEnter()` (masquage force des deux tooltips + annulation du timer LLM) / `Ergopti_OnSuspendResume()` (reinitialisation du buffer de prefixe). Un watchdog de 500 ms `_SuspendStateWatchdog` (globale `_LastSuspendState`, arme dans `lib/boot.ahk`) rejoue le reacteur pour les transitions qui contournent `ToggleSuspend` (Pause natif, declencheur externe). Les combos script AltGr sont enregistres « S » (exemptes de suspend) pour que l'utilisateur puisse sortir de la pause.

**Parite macOS :** la pause est un multi-drapeau souple dans `modules/shortcuts/script_control.lua` (`_is_paused`, `is_paused()`) ; l'eventtap keymap sort tot sur `CoreState.processing_paused`, donc le chemin apercu/hotstring est deja bloque. Ecarts combles : `pause_all()` appelle `_keymap.reset_predictions()` + `ui.tooltip.hide_forced()` ; `triggerLiveAxisIfNeeded` des gestes a gagne `if not _state.enabled then return end` ; `prediction_engine.perform_check` lit `package.loaded["modules.shortcuts.script_control"].is_paused()`. Le warmup HTTP de fond et le keylogger verifiaient deja la pause.

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

_The script-control eventtap (AltGr+Enter/Backspace/Escape) is keycode-based and must survive layout switches AND pause — never restart it via `shortcuts.stop()`/`shortcuts.start()`, and never let a pause-driven layout switch regenerate the Karabiner config._

<sub>slug: `project_macos_script_control_tap_lifecycle`</sub>

AltGr (right_command / right_option) + Enter / Backspace / Escape → pause-toggle / reload / quit are served by one `hs.eventtap` in `modules/shortcuts/script_control.lua` (`handle_key`), keyed on **physical key codes** (Karabiner sentinels F13/F14/F15 + a right-cmd fallback). It is layout-independent and is the one thing that must work in EVERY state (paused, mid-layout-switch, KE-off).

**Trap 1 — `stop()`/`start()` is not a round-trip.** `shortcuts.stop()` stops all three sub-systems including ScriptControl; `shortcuts.start()` starts only Bindings + KeyboardShortcuts (ScriptControl has its own `start_script_control`). So a `stop(); start()` used as a "rebind" **kills the script-control eventtap and never revives it** — AltGr+Enter dies on the first layout switch and neither resume nor the menu button brings it back. **Rebind layout-dependent hotkeys with `pause_bindings()` / `resume_bindings()`** and leave the keycode-based eventtap untouched.

**Trap 2 — the pause-layout feature triggers the input-source watcher.** With `layout_pause_switch_enabled`, every pause switches the macOS layout, which fires Karabiner's `start_input_source_watcher`; that used to `regenerate()` the FULL Ergopti config and re-arm the binding hotkeys, silently undoing the pause (full remapping back, user shortcuts live mid-pause). The watcher callback now short-circuits on `script_control.is_paused()`, leaving the paused KE config (`Generator.build_paused_script_control_rules`, right_command + right_option × 3 slots) in place until the real resume regenerates it.

Note `GestActions.execute_single` deliberately has **no** pause guard, so reload/quit fire even while paused — that is intended (lifecycle controls).

See [[project-macos-eventtap-no-blocking]], [[project-suspend-pause-invariant]].

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


### project-shifted-comma-case-variants

_The "uppercase" form of a comma/apostrophe/period in case-variant generation MUST be nbsp/nnbsp + punctuation, NEVER a plain ASCII space — anchoring on nbsp is what keeps the ":D" emoji alive._

<sub>slug: `project_shifted_comma_case_variants`</sub>

On the Ergopti Shift layer, `,` / `'` / `.` do not shift to a letter — they shift to a no-break-space-prefixed punctuation, and French typography makes the space TYPE differ. Keep two concerns apart:

- **Emission** (AHK ONLY — macOS input goes through Karabiner, not in this repo): `:` → NBSP (U+00A0), `;` / `!` / `?` → NNBSP (U+202F). Lives in `SHIFT_SYMBOLS`, `modules/keymap/layout/layout_shift_caps.ahk`.
- **Matching** (both platforms): deliberately LENIENT — pair BOTH no-break spaces with BOTH `:` and `;`, so `DS` fires whichever one landed in the buffer. AHK: `_BuildUppercasedSymbols()` in `lib/hotstrings/hotstring_builder.ahk`. macOS: `M.UPPER_TRIGGERS` in `_shared/lua/text_utils/init.lua` (consumed by `trig_upper`/`trig_title`, which handle the symbol at ANY position).

**Why a plain ASCII space is wrong on two counts:** (1) the nbsp-prefixed form typed via the layout never matched the space-prefixed trigger, so caps never produced `DS`; and (2) a bare `<space>:D` — the emoji typed after a normal word — DID match and got swallowed into `DS`. The user types the emoji with a plain space and the shifted comma with a no-break space; anchoring on nbsp/nnbsp is the ONLY thing separating them.

**How to apply:** never put a plain space in these tables — use `Chr(0x202F)` / `Chr(0xA0)` (AHK) or `"\226\128\175"` / `"\194\160"` (Lua). Pinned by `test_layout_tables.ahk` (emission), `test_hotstring_engine_main.ahk` + `test_hotstrings_full.ahk` (AHK matching + plain-space emoji safety), `test_hotstring_registry_regressions.lua` (macOS).

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

_Hammerspoon swallows a throw inside an `hs.timer` callback — that silent-death class is now captured by `logger.install_runtime_error_capture()`, which must stay installed. The surviving trap is a test stub that defines a method production lacks._

<sub>slug: `project_hs_timer_callback_errors_invisible`</sub>

Hammerspoon runs timer callbacks under its own protected call and prints the traceback to its **Console**, not through `lib.logger` — so the collected file log used to just stop mid-path with no `[ERROR]`. This masked the « vert mais aucune prédiction » bug: `prediction_engine.perform_check` (fired by an `hs.timer.delayed`) called `StreamingHandler.ngram_predict`, a function the production `streaming_handler.lua` never implemented. Calling a `nil` field threw, the timer swallowed it, and the log showed `Request signature accepted` but never the dispatch `[START] LLM request`. **Worse, the unit test stubbed `ngram_predict`, so the suite stayed green while production crashed on every keystroke-driven request.**

**Mitigation now in place:** `lib/logger.lua` `M.install_runtime_error_capture()` wraps `hs.timer.{doAfter,new,delayed.new}` callbacks in `xpcall` (logging ERROR + traceback) and tees `print()` into the file log. Do not remove it — and do not assume it covers eventtaps.

**Still on you — keep test stubs faithful to the real module's exported surface.** A stub that provides a method production doesn't have turns a hard crash into a green test. When stubbing a singleton (`StreamingHandler`, `PromptBuilder`, `AppFilter`, `ApiCommon`), mirror only the functions the real module actually exports, and add a regression that drives the real call path. `test_prediction_engine.lua` §8 asserts StreamingHandler exposes no `ngram_predict` and that `perform_check` reaches `fetch_llm_prediction`.

See [[feedback-regression-tests]].

### project-profile-label-placeholder-convention

_LLM profile labels in `_shared/data/locales/*.json` use **brace** placeholders `{n}`/`{s}` (count + plural-s), NOT printf `%d`/`%s` — the menu substitutes braces, so a printf token leaks verbatim into the UI._

<sub>slug: `project_profile_label_placeholder_convention`</sub>

`llm.profile.batch_advanced.label` carries a dynamic prediction count. Every consumer substitutes the **brace** placeholders `{n}` (count) and `{s}` (plural marker), mirroring the prompt-template convention: macOS via `ui/menu/menu_llm/profile_label.lua` `M.format` (single source of truth, used by both `profiles_manager.lua` and `model_switcher.lua`), Windows via `LLM_Menu_GetProfileLabel` (`StrReplace` of `{n}`/`{s}`). Plain `i18n.get` / `t()` do **not** substitute — that is the caller's job.

**Why the divergence survived:** the label shipped with printf `%d prédiction%s` while the menu formatter only replaced `{n}`/`{s}`, so the user saw a literal `%d` in the "Batch Avancé" entry. A parallel path (`model_switcher.lua`) used `string.format(label, n, s)` and rendered it correctly — **two consumers, two conventions, one locale string that could only satisfy one of them**, which is exactly why nobody noticed.

**How to apply:**

- A locale value rendered as a menu label uses `{…}`; reserve printf `%d`/`%s` for strings passed straight to `string.format` / `Format()`. Never mix the two for the same string.
- Don't format a profile label inline — call `ProfileLabel.format` (macOS) so the count fallback (`DEFAULT_STATE.llm_num_predictions`) stays single-sourced.
- Guarded across all 21 locales by `macos/tests/unit/lib/test_locale_profile_labels.lua`, `macos/tests/unit/menu/test_profile_label.lua` and `windows/tests/unit/test_llm_menu_regressions.ahk`.

See [[project-locale-parity-test]], [[feedback-regression-tests]].

### project-updater-nonblocking-http

_The updater background poll must never do synchronous WinHttp on the main thread (it freezes all keyboard remapping); WinHttp `SetTimeouts` treats 0 as infinite. Use the project's async WinHTTP + `WaitForResponse(0)` + `SetTimer`-poll pattern._

<sub>slug: `project_updater_nonblocking_http`</sub>

Two distinct foot-guns, both surfaced by a user reporting a "freeze au démarrage" tied to the update check (AHK driver, `lib/updater.ahk`):

1. **`WinHttpRequest.SetTimeouts(resolve, connect, send, receive)` treats `0` as "infinite"**, not "default". The background poller called `SetTimeouts(0, 15000, 30000, 30000)` (commit `c135b2d30`) believing it bounded the call — but the **resolve (DNS) phase stayed unbounded**. On a network where DNS stalls (a connecting VPN, a captive portal, a dead resolver) the synchronous `Req.Send()` blocks forever. Every phase must be a finite, named constant (`UPDATER_HTTP_*_TIMEOUT_MS`). A regression test scans `updater.ahk` for any `SetTimeouts(0,` literal.

2. **A synchronous WinHttp call on the AHK main thread freezes ALL keyboard remapping** for its whole duration — hotkey subroutines and the `Send()` of remapped keys run on the main thread, so they cannot fire while `Req.Send()` blocks. The background poller fires its first check ~30 s after boot (`FirstMs := Min(30000, …)`), so on a bad network the user perceives a "startup freeze". Bounding the timeouts only caps the duration; the real fix is to **not block the main thread at all**.

**How to apply:**

- The unprompted background poll uses the async path: `_Updater_FetchLatestJsonAsync` opens the request in WinHTTP async mode (`Req.Open(url, true)`), `Send()` returns immediately, and `_Updater_PollAsync` harvests it via `WaitForResponse(0)` (0 = do not wait) re-armed by a `SetTimer`. The network I/O runs on WinHTTP's own worker threads — the main thread never blocks. This is the same **WinHTTP-async + `WaitForResponse(0)` + `SetTimer`-poll** pattern used in `modules/llm/api_ollama.ahk` + `api_remote.ahk` (mirroring `hs.http.asyncPost` on macOS). A `try`-wrapped `WaitForResponse(0)` that throws = the request errored (treated as failure); a max-polls cap derived from the timeout budget guarantees no orphaned poll timer.
- **The async `Open(url, true)` + `Send()` does NOT block on connect — measured, not assumed.** A standalone bench on 2026-07-21 (`WinHttp.WinHttpRequest.5.1`, `SetTimeouts(3000,…)`, no hooks) called `Send()` against a black-hole IP whose SYN is dropped: **`Send()` returned in 15 ms**. So a finding of the shape "the async `Send()` blocks the keystroke thread on DNS/connect" is FALSE, and must be refuted with this bench rather than argued from reading — the 2026-07-21 audit's two Opus verifiers BOTH confirmed exactly that false claim for `ollama_warmup.ahk` before the measurement overturned it (an adversarial verifier can be wrong in the confident direction). What genuinely blocks is a *synchronous* `Open(url, false)+Send()` and a `WaitForResponse` given a non-finite argument — so keep every network surface on the async path above, and never migrate a "connect blocks" finding into a fix.
- Status / ETag / array-unwrap interpretation is shared by the sync and async paths via `_Updater_InterpretResponse` (single source of truth — they must not drift).
- **User-initiated** paths (one-click "check now", changelog, download) keep the _synchronous_ fetch: the user is actively waiting on the click, and the timeouts are now bounded. Only the unprompted poll needs to be async.
- `Updater_StopBackgroundChecks` cancels in-flight async requests so a late response cannot pop a notification after the user picks "never".
- The `[ahk.updater] check_interval_seconds` persistence round-trip for the "never" (0) value is **correct** (verified empirically — write → parse → load yields `0` and the poller stays disarmed). The reason a "never" user can still see checks is that the default _when the key is absent_ is 86400 (opt-out), and the first check fires ~30 s after boot.
- Guarded by `windows/tests/test_updater.ahk`: timeouts all > 0, no `SetTimeouts(0,` literal, `Updater_DownloadAndInstall` sets timeouts before `Send()`, and `Updater_BackgroundTick` dispatches via `_Updater_FetchLatestJsonAsync` (never the blocking fetch).

See [[feedback-regression-tests]], [[project-ahk-menu-dispatcher-drop]].

### project-audit-tracking-artifacts-are-unreliable

_An audit's own tracking JSONs and roadmap `[x]` checkboxes contradict each other and the source — ground truth is the code, located by SYMBOL, never by the line numbers in a finding._

<sub>slug: `project_audit_reverify_2026_06_16`</sub>

Re-verifying the 170-finding 2026-06-14 AHK audit: `_audit_status.json` showed 6/170 checked while `_verify_results.json` marked all 170 `status:"done"` — and several "done" entries' own `evidence` field said the fix was absent. **Line numbers in a finding's `files` array drift; symbol names do not.** (Those reports and tracking files have since been deleted and their findings fixed; only `tools/dev/_known_titles.txt` and `_reverify_payload.json` remain.)

One durable structural fact worth keeping, against the recurring « triggerabcd → outpuabtcd » fear: the expansion core is sound. The main dispatch is one atomic `SendInput(Burst)` under `Critical` and suppression + synthetic-tag are depth counters, so a trigger cannot come out reordered. The Notepad clipboard path is the one acknowledged non-atomic exception, by design.

See [[project-audit-evidence-must-be-reproducible]], [[project-audit-findings-are-hypotheses]].

### project-hs-adapter-contract-violations

_Four Hammerspoon API contract facts a plausible-looking call gets wrong — found dormant in the macOS adapters._

<sub>slug: `project_audit_hs_fixes_2026_06_16`</sub>

- `hs.axuielement.focusedElement()` **does not exist** — use `applicationElementForPID(pid):attributeValue("AXFocusedUIElement")`.
- `#char` is a BYTE count and silently rejects multi-byte characters — use `utf8.len()` via `pcall`.
- `checkKeyboardModifiers()` only accepts canonical modifier names — normalise `LShift`/`RShift` → `shift` (`KEY_NORMALISATION` in `adapters/key_state.lua`) before querying.
- `hs.eventtap`'s `start()` leaks a disabled-but-allocated tap — unconditionally stop and nil any existing tap before creating a new one.

(The eight 2026-06-16 macOS audit fixes this entry used to narrate — paste-path `emit_text` return value, the 0.5 s stuck-counter reset, `doAfter(0)` injection, `synth_queue` idle drain, `prediction_engine.reset` chain timer, stale-success failure counter, and three tooltip lifecycle bugs — all shipped with regression tests, which are now the living memory.)

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

### project-lua-nil-and-expr-is-nil

_In Lua, `local x = cond and expr` yields **nil**, not false, when `cond` is nil — and `not nil` is `true`, so a "negative" gate silently inverts._

<sub>slug: `project_macos_audit_2026_06_17`</sub>

Found in `prediction_engine.is_noise_pred`: `local ends_sent = prev_char and prev_char:match(...)` returned **nil** whenever `prev_char` was nil (empty or whitespace-only buffer). `not nil` is `true`, so the uppercase-capital gate silently suppressed **every** prediction beginning with a capital at document start or after a whitespace-only buffer. Fix: `(prev_char == nil) or (prev_char:match(...))` — nil is now an implicit sentence boundary.

**How to apply:** whenever you write `local x = cond and expr`, decide explicitly what `cond == nil` must mean. If nil is possible, use `(cond ~= nil) and expr` or `cond == nil or (cond and expr)`. The `x:match(...)` shape is the usual carrier of this bug.

NRT: `tests/unit/modules/llm/test_noise_filter_regression.lua`. (Two sibling bugs found the same day — a framerate-dependent gesture peak confirmation using a frame count instead of `PEAK_FINGERS_CONFIRM_MS`, and a synthetic-event reset racing delayed OS delivery — are fixed and pinned by `test_peak_override_regression.lua` and `test_synthetic_reset_guard.lua`.)

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

### project-toml-cache-returns-real-booleans

_A TOML `true` reaches the cache as an AHK boolean, not the string "true" — compare through `TomlCacheBool`, never `StrLower(v) == "true"`_

<sub>slug: `project_toml_cache_returns_real_booleans`</sub>

`ParseTomlFile` runs every value through `TOML_CoerceValue`, which maps the
literals `true`/`false` to real AHK booleans. `IniCacheGet` then returns the
stored value VERBATIM — unlike its sibling `TOML_Read`, it coerces nothing. So:

```ahk
v := IniCacheGet(Cache, "ahk.layout", "ergopti_base")  ; Integer 1, not "true"
StrLower(v) == "true"    ; "1" vs "true" -> ALWAYS FALSE, never throws
TomlCacheBool(Cache, "ahk.layout", "ergopti_base")     ; correct
```

The onboarding wizard carried this for as long as the native host existed:
every saved `true` pre-filled as No, and Finish then wrote that `false` back
over the user’s config, disabling the whole Ergopti emulation on a re-run.

**Why it survived so long:** the bug is one-directional. TOML `false` coerces
to `0`, which also compares false — so it was right by accident and never
showed up as a spurious enable. And `tests/unit/test_config.ahk` builds its
cache from string literals (`Map("S", Map("n", "42"))`), so it never observes
what the real parser produces.

**How to apply:**

- Read TOML booleans out of a cache with `TomlCacheBool` (`lib/toml/toml_helpers.ahk`).
- When testing a parser, feed it a real file — a hand-built Map tests your
  assumption about the parser, not the parser.
- Guarded by `tests/meta/test_onboarding_toml_bool_reads.ahk`, written for the
  class: it fails if ANY host reimplements the string comparison.

---

### project-ahk-map-delete-raises-on-missing-key

_`Map.Delete(k)` throws when the key is absent, and `/validate` only syntax-checks when it PRECEDES the script path_

<sub>slug: `project_ahk_map_delete_raises_on_missing_key`</sub>

Two costs paid during the 2026-07-21 lib/toml + ui/onboarding pass.

**`Map.Delete` is not `.Has`-tolerant.** Clearing a per-path flag with a bare
`_TomlReadFailures.Delete(Path)` produced `FATAL STARTUP ERROR: Item has no
value.` — the whole suite refused to load. Reads have a forgiving form
(`.Get(k, default)`) and deletes do not, which makes the asymmetry easy to miss:

```ahk
if Cache.Has(Key)      ; required
    Cache.Delete(Key)
```

**`/validate` works in v2.0 — but ONLY before the script path.** This entry has
been wrong twice, in both directions, so it is now stated from an empirical
re-derivation on v2.0.26 using an execution marker:

```bash
AutoHotkey64.exe /ErrorStdOut /validate <file>   # validates, does NOT run
AutoHotkey64.exe /ErrorStdOut <file> /validate   # RUNS THE SCRIPT
```

Flag **before** the path is a real headless syntax check: a valid script exits 0
silently, a broken one exits 2 and prints `<file> (2) : ==> Missing "` on stdout.
Flag **after** the path is consumed as an ordinary script argument (`A_Args`),
because AHK already took the path as the script — so the script starts live. That
is what launched a second driver from a worktree for two minutes; the flag was
never the problem, its position was.

The earlier claim that the flag "does not exist in v2.0 and is ignored" was a
wrong correction of a wrong original. **A refutation needs the same standard of
proof as the claim it refutes** — four commands settled this one. See
[[project_audit_findings_are_hypotheses]].

The test suite remains the check that matters for anything `run_all.ahk`
includes, because it catches load errors *and* behaviour.

**Corollary — GUI modules are not covered by that.** `ui/onboarding/*` is not
included by `run_all.ahk`, so a real parse error there passes every
source-introspection test. When editing those files, prefer constructs whose
validity is not in doubt (hoist `global` declarations to the top of a function
rather than relying on a mid-body declaration being legal).

**How to apply:**

- Guard every `Map.Delete` with `.Has()`.
- Pass `/validate` **before** the script path, never after; and never point
  either form at `ErgoptiPlus.ahk` from a worktree — that starts a real driver
  alongside the user's.
- Scratch `.ahk` probes outside `tests/` proved unrunnable in this environment
  (they hang with no output); write the probe as a suite test instead.

---

### project-ahk-probing-synthetic-input

_Two ways a synthetic-input probe silently measures nothing and reports a confident false negative_

<sub>slug: `project_ahk_probing_synthetic_input`</sub>

Cost two wrong verdicts while settling audit finding F5 (does a remap hotkey
fire during `DeadKey`'s `InputHook.Wait()`?). The probe twice reported
`hotkey_fired=NO`, which would have REFUTED a real bug.

**1. InputLevel vs SendLevel.** The driver registers its remap hotkeys with
`Hotkey(sc, cb, "I2")` — `I2` is InputLevel 2. A hotkey at InputLevel N ignores
synthetic input whose SendLevel is ≤ N. So a probe that copies the real
registration must send at `SendLevel 3` or above, or its own key is invisible
to its own hotkey.

**2. `SendLevel` is per-thread.** Setting it in the auto-execute section does
NOT carry into a `SetTimer` callback — that runs on a new thread. It has to be
set inside the callback doing the send.

Both failures look identical to the real negative result, which is what makes
them dangerous: the probe runs, exits cleanly, and prints a confident verdict.

**How to apply:**

- Have the probe RECORD its own preconditions next to the verdict (`A_SendLevel`
  at the moment of the send). A verdict without them is unreadable later.
- Treat a negative result from a fresh probe as "probe unproven" until at least
  one positive control has fired through the same path.
- Related: AHK built-in function names are not usable as variables —
  `Report := ""` is fine, `Log := ""` dies at load with "This Func cannot be
  used as an output variable" (`Log()` is the natural-logarithm built-in), the
  same family as [[project_ahk_keyword_as_variable_hangs_the_parser]].

---

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

_A regression test that pins the single site a bug was fixed at will not survive the next refactor — write guard tests as loops over a set enumerated from source._

<sub>slug: `project_ahk_guard_tests_must_loop_the_class`</sub>

This is the concrete, repeated failure mode behind [[project_ahk_invariant_incomplete_application]]. A fix is applied where the bug bit; the test is written to describe *that fix*. Both are locally correct. The invariant, however, is a property of a **class of call sites**, and nothing re-checks the class when a new sibling appears.

**Still open in the suite today:**

- `test_live_rebuild_no_critical_io.ahk` asserts `InStr(Body, "Critical(") = 0` on **`RebuildHotstringsLive`'s body only**. Any caller that wraps the *call* in `Critical("On")` from outside restores the 1-2 s keyboard freeze the fix removed, and the test stays green.
- `test_webview_bridge_suspend_guard.ahk` names 3 `*_OnWebMessage` handlers; there are 9. The other 7 can mutate config — or run an elevated UAC driver install — while the driver is paused.
- `test_webview_low_ram_native_fallback.ahk` names 5 hosts; there are 12.
- `test_taphold_timings_load_order.ahk` pins the include-order invariant for 1 of 5 shared-constant loaders.

**The pattern to copy:** `SUSPEND_CUSTOM_COMBO_PREFIX_KEYS` (`lib/lifecycle.ahk`) is a hand-maintained list, so `test_suspend_prefix_drain_covers_all_combos.ahk` **derives the real prefix set from driver source** and fails when a newly introduced combination is missing.

**How to apply:**

- Derive the set from source where possible (scan for `X & Y::` combination prefixes; enumerate `*_OnWebMessage` handlers) so a newly added sibling *joins the test automatically*.
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

_`Critical("On")` in a layout/hotkey callback is safe in production but LEAKS into the main thread when a test invokes that function directly, silently freezing every background timer for the rest of the suite._

<sub>slug: `project_ahk_test_suite_critical_leak`</sub>

- **In production (hotkeys/timers):** AHK gives the callback its own pseudo-thread, so on return the previous thread's `Critical` setting is restored automatically. Safe.
- **In tests (direct invocation):** `test_framework.ahk` runs every test sequentially on the **main auto-execute thread**. A test that calls e.g. `AltGrShiftDispatch` or `LayerDispatch` directly inherits its `Critical("On")` permanently.

**The consequence:** a permanently-`Critical` main thread **blocks all background timers** from firing for the remainder of the suite — even during `Sleep`. Every test that relies on `SetTimer` (hotstring engine suppression release, etc.) then silently hangs or fails, far from the real culprit.

**How to apply:** always acquire `Critical` with an explicit restore:

```autohotkey
_AtCrit := Critical("On")
try {
	; … critical code …
} finally {
	Critical(_AtCrit)
}
```

`test_framework.ahk` now throws `Test LEAKED Critical: <TestName>` and resets the state to `0` when a test forgets, so a new occurrence surfaces immediately instead of cascading.

Related: [[project_ahk_invariant_incomplete_application]]

### [updater-download-suspend-guard] Garantie G5: background downloads bypass pause
* **Symptom**: A background update download could finish and trigger a script restart while the driver was supposedly suspended.
* **Cause**: the download poller runs from a SetTimer callback, which bypasses A_IsSuspended.
* **Fix**: the poller checks A_IsSuspended and terminates the download if caught mid-flight.
* **ARCHITECTURE CHANGED — this entry used to describe the opposite of the current code, and was corrected on 2026-07-21.** Staging now runs in a PowerShell CHILD PROCESS (`_Updater_BuildStagingWorkerScript`); AHK only polls it via `_Updater_MonitorStagingWorker` and receives a READY token. `Req.WaitForResponse`, `Req.Abort` and `Stream.SaveToFile` no longer exist in the driver, and no disk write happens on the AHK thread.
* **Do NOT add `Critical` to the monitor.** The old entry claimed the fix wrapped the disk-write block in `Critical "On"`; that is now exactly backwards. Cancellation must stay interruptible, or Suspend cannot terminate a staging worker that is already running — the very failure this guarantee exists to prevent.
* **Regression Guard**: `meta/test_g5_updater_download.ahk` asserts the A_IsSuspended check, asserts `.terminate()`, and asserts that `Critical(` is **absent**. A doc that told you to add it (`docs/STATE_TRANSITION_MATRIX.md`) was corrected at the same time — it would have made a reader break a live test.

### [project-shared-tree-layout] _shared/ tree : SSOT-par-couche, et le piege du contournement
* **Layout** (`static/ergopti_plus/_shared/`) : `modules/` (par sous-systeme) · `core/` (`domain/ ports/ config_schema/`) · `data/` (`locales/ db/ keycodes/`) · `lua/` · `tests/` · `ui/` · `tap_hold/`.
* **SSOT par couche** — la racine `_shared` est resolue en EXACTEMENT UN endroit par consommateur, donc un *renommage du tree* est une edition d un seul token a chacun de ces endroits : runtime macOS `macos/lib/paths.lua` (`Paths.shared`), runtime AHK `_SharedDir` (`ErgoptiPlus.ahk`, fallback relatif dans logger.ahk), tests macOS `macos/tests/helpers/init.lua` (`SHARED_REL`), JS `tools/lib/paths.cjs`, Python `tools/lib/paths.py`, `linux/install.sh`, `tools/build/build_static_bundle.py`, `tools/build/build_macos_app.sh`.
* **Un deplacement *interne* (ex. `llm/` → `modules/llm/`) n est PAS couvert par le SSOT** — chaque site qui passe un sous-chemin relatif a `_shared` doit changer. Sweep ancre sur `_shared/`, `shared("`, `sharedRel("`, `.shared("`, `_SharedDir . "\`, en preservant BOM UTF-8 + LF sur `.ahk`.
* **Piege — les sites qu un sweep ancre ne peut pas voir :** du code `_shared/lua` qui navigue depuis sa propre position (`lua/llm/profile_selector.lua` → `dir .. "/../../modules/llm/profiles.json"`) ; des loaders AHK qui aliasent `_SharedDir` dans un local (`lib/timings/timings_config.ahk`) ; des fixtures de test qui construisent les chemins a la main ; des modules UI avec leur propre wrapper de chemin passant une chaine relative litterale (`ui/wpm/wpm_widget.lua` : `resolve_shared_constants_path("modules/wpm_widget/constants.toml")` — celui-la a shippe en ERROR au boot).
* **Apres tout deplacement, lancer TOUTES les suites** (AHK `tests/run_all.ahk`, macOS `lua tests/run.lua`, Linux `luajit tests/run.lua`) : un audit de sweep vert est necessaire mais PAS suffisant. **MAIS une suite n attrape une rupture de chemin que si le test assert que le fichier a resolu** : la casse wpm_widget est passee parce que son test n assertait que `WpmWidget ~= nil`, et le module degrade proprement sur fichier manquant. Un test de resolution de chemin DOIT asserter que le resolveur a trouve un vrai fichier (ou qu aucune ERROR <<file not found>> n a ete loggee au load), jamais seulement que le module consommateur s est charge.
* **Configs hors sweep :** `.gitignore` racine (chemins de cache `_shared` auto-regeneres), `stryker.config.mjs`, `package.json` — un sweep scope a `static/tools/src/docs` les rate ; une regle d ignore perimee rend silencieusement les caches suivis.

### [project-macos-initlua-no-compile-coverage] Un fichier que le harness ne peut que *copier* a quand meme besoin d un controle de *parsing*
* macOS `init.lua` a shippe une erreur de syntaxe Lua dure (un `end` perdu) restee latente avec CI vert : la suite Lua charge les modules individuels via des stubs `hs` et **ne charge jamais `init.lua`** (l executer demande le runtime Hammerspoon vivant), et `build_macos_app.sh` ne fait que copier — donc rien n avait jamais *parse* le fichier de tete. L entree AHK n a pas ce trou (Ahk2Exe la compile en CI).
* **Garde** : `macos/tests/meta/test_lua_sources_compile.lua` — `loadfile()` parse sans executer (pas de `hs`, pas de FS, pas d OS), la facon zero-dependance de verifier la syntaxe d un code que le harness ne peut pas lancer. init.lua exige sa **propre assertion nommee** : il est a la racine du driver, donc hors du scan groupe sur `lib/ modules/ ui/ adapters/` + `_shared/lua/`.
* **Lecon** : un diff mecanique qui ajoute un niveau d imbrication est la facon classique de perdre le `end` fermant d un bloc — relancer un parseur, ne pas verifier l equilibrage a l oeil.

### [project-hs-fs-dir-drops-state] `hs.fs.dir` renvoie (iterator, state) — et un stub laxiste a masque l etat perdu
* `hs.fs.dir(path)` renvoie **DEUX** valeurs : un iterateur ET un objet d **etat** de repertoire que l iterateur EXIGE comme premier argument (le vrai HS verifie une metatable userdata <<directory>>, sinon *"directory metatable expected, got nil"* des le premier pas). `local ok, it = pcall(hs.fs.dir, dir)` puis `for x in it do` ne capture que l iterateur et perd silencieusement l etat → crash au boot. Il LEVE aussi sur un repertoire absent/refuse, donc il faut un pcall en plus.
* **La seule forme benie** : l expression iterateur directement dans un generic-for, a l interieur d une closure pcall'ee — `pcall(function() for name in hs.fs.dir(dir) do … end end)`. Centraliser en un helper `safe_dir_entries(dir)` par fichier.
* **Pourquoi la CI l a rate (deux trous cumules, tous deux generalisables)** : (1) le stub `hs` renvoyait un iterateur unique et sans etat, donc le motif buggy <<marchait>> — **un stub doit modeler l arite de retour et l exigence d etat de la vraie API**, sinon il rend la CI verte par-dessus un crash garanti en production ; (2) un meta-test anterieur *imposait activement la forme buggy* (assertait `pcall(hs.fs.dir, …)` present et le generic-for nu absent) — **un garde-source qui impose une *orthographe* de code peut cimenter un bug ; asserter l invariant, pas la formulation**.
* **Garde** : `macos/tests/meta/test_fs_dir_iterator_contract.lua` — par fichier assert `count(hs.fs.dir) == count("in hs.fs.dir(")`, assert le pcall de protection contre le throw, et epingle le stub a la forme fidele `(iterator, state)`. Le runtime d init.lua n est jamais execute par la suite, donc sa logique de boot n est atteignable QUE par des tests de contrat statiques sur la source.

### [project-healthcheck-stale-api] Une sonde gardee par `pcall`/`type` est INVISIBLE aux tests bases sur le crash
* La fenetre de diagnostic macOS (`ui/healthcheck/` — collecteurs dans `helpers.lua`) appelait une dizaine de fonctions renommees ou jamais implementees (`llm.get_state`, `log_manager.get_paths`, `layout.is_ergopti_base`, …). Chacune etait enveloppee dans un garde `type(x) ~= "function"` qui logge un WARNING et retombe sur un fallback — donc rien ne crashait, un test <<le module se charge-t-il ?>> restait vert, et tous les champs affichaient `unknown`/`n/a` pendant des mois.
* **Lecon** : tester le RESULTAT (la vraie valeur resolue / aucun warning de degradation), pas seulement <<ca n a pas crashe>>. Un module qui lit l API d un *autre* module exige un test de contrat explicite, car rien d autre n exerce ces appels precis. La ou aucun accesseur n existe, rapporter `n/a` SANS sonder une fonction inexistante.
* **Garde** : `macos/tests/meta/test_healthcheck_api_contract.lua` — (1) une table CONTRACT declarative de chaque (module, symbole) touche par les collecteurs, assertee contre le VRAI module ; (2) execute `healthcheck.run()` et assert qu aucun collecteur n a logge un warning `is not a function`/`unavailable` (hors `hs.*`, que le stub headless n a legitimement pas).

### [project-macos-split-module-stub-reload] Splitting a stateful macOS module out of its caller requires adding it to `load_with_stubs`' reload list
* **Symptom**: after the F4 split extracted the async active-layout probe from `ui/menu/menu_keyboard_layout.lua` into `modules/keymap/input_sources.lua`, `test_menu_keyboard_layout_latency.lua` failed with "cache must hold the two probed layouts: expected 2, got 1" — the `hs.task` stub the test injected via `load_with_stubs("ui.menu.menu_keyboard_layout", {task=...})` never reached the relocated `refresh_active_layouts_async`.
* **Cause**: `tests/helpers/init.lua` `load_with_stubs(module_name, …)` clears `package.loaded[module_name]` plus a *curated list* of always-reload modules (text_utils, toml_codec, i18n, paths, llm.init), then sets the fresh `hs` stub. A required module that is NOT in that list and is already cached returns its old instance — and Lua modules capture `local hs = hs` at *require time*, so the cached instance is bound to a previous test's `hs`, ignoring the new stub.
* **The invariant**: when you split a stateful module (session caches, or anything that captures `hs`/`Logger` at load) out of a module that tests drive through `load_with_stubs`, add the new module(s) to the force-reload block in `tests/helpers/init.lua`. F4 added `modules.keymap.layout_install` + `modules.keymap.input_sources` there. Symptom of forgetting: a stub injected for the parent silently fails to reach the child, and a behavioural assertion sees stale/empty cache state.
* **Related**: the `test_port_adapter_coverage.lua` `LUA_HS_BASELINE`/`LUA_IO_OS_BASELINE` ratchets scan only `macos/modules/` + `macos/lib/` — moving OS-calling code from `ui/` into `modules/` raises the count without adding any new OS call. Re-baseline with a "relocation, not new OS calls" comment (precedent: the init.lua → lib/personal_hotstrings bumps).

### [project-macos-reload-during-git-pull] Auto-reload watchers must defer the reload while a git operation is rewriting the working tree
* **Symptom**: running `git pull` on the driver repo while Hammerspoon is live left it open but completely unresponsive — every remap/shortcut dead — until force-killed and relaunched. The "must force-kill" (not just "config broken, still clickable") points at a **reload storm**: repeated `hs.reload()` firing faster than boot completes, so the keymap eventtap never stabilises. This driver already fixed one such storm once (`fe57ce045`, "debounce pathwatcher to prevent keyboard freeze on rapid file changes", citing exactly "a git commit touching several .lua files").
* **Cause**: the driver arms TWO auto-reload pathwatchers on `base_dir` — `lib/file_watchers.lua` (project `*.lua` + hotstrings/personal `*.toml`) and `ui/menu/menu_watchers.lua` (`*.lua`/`*.toml`) — each firing `hs.reload()` on any source change. `git pull` rewrites `init.lua` and dozens of required modules. The 0.5 s debounce only collapses a single *burst*; it does not stop a reload from firing while git is STILL writing (→ boot against a half-updated tree), and it does not stop the **post-reload FSEvents replay**: macOS buffers the pull's change events across `hs.reload()` and re-delivers them to the freshly-armed watcher, which reloads again, and again — the storm.
* **Fix (two parts)**: (1) `lib/git_status.lua` `operation_in_progress(base_dir)` walks up to the `.git` dir and probes `index.lock` (held for the ENTIRE working-tree update of a checkout / ff-pull / merge / reset / commit), `MERGE_HEAD` / `CHERRY_PICK_HEAD` / `REVERT_HEAD`, and the `rebase-*/head-name` markers; both watchers hold the reload while it returns true, so the pull collapses to a single post-pull reload. All probing routes through `adapters.file_system`, so the lib adds ZERO to the `hs.*`/io/os purity ratchet. (2) `lib/file_watchers.lua` gained the `BOOT_SUPPRESS_SEC = 5` window that `menu_watchers` already had, so the post-reload FSEvents replay is dropped instead of re-firing. The stale-lock cap (`GIT_SETTLE_MAX_DEFERRALS = 120`, 60 s) resets to 0 on any real file event, so a long pull that keeps writing NEVER trips it — only a lock held with no further activity (a crashed git) does.
* **Whole-class lesson**: this was the recurring **missed sibling** ([[project-ahk-invariant-incomplete-application]]) twice over — the git guard had to go on BOTH watchers (guarding one lets the other reload mid-pull), and the boot-suppress lived on `menu_watchers` but not `file_watchers`. The third pathwatcher, `modules/keylogger/kc_bridge.lua`, watches only `<config_dir>/metrics/karabiner_kc.log` (a runtime log git never writes) and never reloads. Every other `hs.reload()` site is user/event-driven (gesture, locale menu, path editor, reset-defaults, about/update, onboarding) and cannot fire from an external file write.
* **Cross-driver**: the debounce stays the bare literal `0.5` in `hs.timer.doAfter(0.5, …)` — a single-source gate (`tools/test/test-file-watchers-constants-single-source.cjs`) pins it to Linux's `_debounce_sec`, so do NOT replace it with a named constant. Linux's own `lib/file_watchers.lua` may carry the same latent bug; not addressed here.
* **Guards**: `macos/tests/unit/lib/test_git_status.lua` (predicate), `test_file_watchers_git_defer.lua` + `tests/unit/ui/menu/test_menu_watchers_git_defer.lua` (reload HELD while git in progress, fires once it settles), and `test_file_watchers_boot_suppress.lua` (a change inside the boot window is dropped, one after it reloads). Related: [[project-lua-closure-before-local-nil-global]] (the `fire_reload` forward-declaration), [[project-macos-eventtap-no-blocking]] (why the probe is filesystem-only, never a `git` subprocess).

### [project-md-gate-needs-eol-lf] A byte-compared generated `.md` doc needs `eol=lf`, or a Windows CRLF checkout fails the gate locally
* **Symptom**: `npm run test:js` reported the architecture-diagram check stale on Windows ("architecture.md is stale — run: npm run gen:diagram") even with a clean tree; `npm run gen:diagram` then produced only a one-line date diff, and CI (Linux) was green.
* **Cause**: `tools/test/test-architecture-diagram.cjs` compares the committed `static/ergopti_plus/docs/architecture.md` to the freshly built Mermaid body with `committed.includes(mermaid)`. `.gitattributes` forced `eol=lf` for source files (`*.lua`/`*.py`/`*.ahk`/`*.sh`) but NOT `*.md`, so with `core.autocrlf=true` a Windows checkout rewrote the LF blob to CRLF; the LF `.includes()` then failed on the CRLF copy. The blob in git is LF, so Linux/macOS never saw it.
* **Fix**: added `*.md text eol=lf` to `.gitattributes`, then re-checked out the file (`git checkout -- <path>`) to normalise the working tree to LF — no committed-content change. **Do not** "fix" it by committing the regenerated file: that only bumps the embedded `Generated on <date>` line (a real but spurious diff) and re-breaks the next day.
* **Lesson**: any CI gate that byte-compares a committed text artifact will silently fail on a Windows checkout unless that file's extension is pinned to `eol=lf`. Related: [[feedback-ahk-source-encoding]] (the AHK LF+BOM gate), [[feedback-local-gate-mirrors-ci]].

### [project-init-json-decode-of-toml] `pcall(hs.json.decode, …)` imprime quand meme l erreur native LuaSkin
* `hs.json.decode` est **natif** : lui donner du non-JSON logge `LuaSkin: Error deserialising JSON: …` dans la console HS (que le tee console remonte en `[CONSOLE] ERROR`) **meme a l interieur d un `pcall`** — pcall attrape l echec cote Lua, la ligne console part quand meme. init.lua JSON-decodait `config.toml` a chaque boot ainsi ; le pcall masquait que tout le bloc etait MORT, donc il a ete supprime plutot que repare.
* **Lecon** : apres une migration de format de config, grepper les lecteurs restes sur l ANCIEN format mais pointes sur le nouveau fichier. Garde : `macos/tests/meta/test_config_not_json_decoded.lua`.

### [project-macos-startup-winfilter-cost] Ne jamais creer un `hs.window.filter` sur un chemin de boot ou de premiere frappe
* La PREMIERE instanciation de `hs.window.filter` fait enumerer a Hammerspoon toutes les fenetres de toutes les apps — plusieurs secondes sur une machine chargee ou avec un VPN (Cisco Secure Client ne s enregistre jamais et spamme `wfilter: <app> is STILL not registered`). Le keylogger construisait son filtre navigateur (mode prive) avidement au demarrage du moteur, qui mettait donc des secondes a etre pret ; le cache keymap `is_ignored_window` cree `hs.window.filter.default` a la premiere frappe.
* **Motif de correction** : le creer PARESSEUSEMENT au premier moment ou il sert, scope aux apps concernees (`ensure_browser_window_filter`, garde par `BROWSER_APP_SET[app_name]` dans l app-watcher), et logger sa duree pour rendre la lenteur attribuable. Verifier d abord si la fonctionnalite dependante peut lire `hs.window.focusedWindow()` directement : la detection prive/incognito au changement d app n a jamais eu besoin du filtre.
* Garde : `macos/tests/meta/test_startup_optimizations.lua`.

### [project-category-gating-ahk-only] Category enable/disable gating (CategoryEnabled["Hotstrings"]…) is intentionally AHK-only
* The Windows driver gates whole feature categories (Hotstrings, Shortcuts, …) through PascalCase keys in the `CategoryEnabled` map, seeded from `manifest.toml`'s `[ahk.category_enabled]` section (`IsCategoryGated`/`_MasterCategoryFor`). The macOS driver has **no category-gating layer at all** — features toggle individually. So the PascalCase ids are NOT a leftover v2-migration debt and NOT a cross-driver parity gap: there is nothing on the macOS side to mirror.
* **Why kept** (audit 2026-06-26, re-examined a past "should we migrate?" idea): converting the ~27 PascalCase gating sites across ~10 AHK files to v2 snake_case is pure-cosmetic, AHK-only churn that touches every category toggle (real regression risk) for zero cross-driver benefit. Confirmed **KEEP**.
* **How to apply**: treat `CategoryEnabled` / `IsCategoryGated` / `_MasterCategoryFor` PascalCase ids as a deliberate Windows-internal implementation detail, not drift. Do not "fix" them for parity. Related: [[feedback_loader_target_explicit]].

Related: [[project-hs-fs-dir-drops-state]], [[project-touchdevice-dormancy-is-kernel]], [[feedback_regression_tests]]

### [project-macos-lib-namespace-shims] `lib.text_utils` est un shim de re-export load-bearing, pas de l indirection supprimable
* `macos/lib/text_utils.lua` est un re-export identite d une ligne (`return require("text_utils")`) de `_shared/lua/text_utils`, sans aucune extension HS. Il ressemble a de l indirection purement supprimable (un audit a propose de le supprimer).
* **Pourquoi il est garde** : la suite de tests macOS est indexee sur le chemin de module `lib.*`. ~30 modules de production font `require("lib.text_utils")` et ~12 fichiers de test installent `package.loaded["lib.text_utils"] = <stub>` ou `helpers.load_with_stubs("lib.text_utils")` pour controler ce que voit le code teste. De-shimmer vers le nom nu `text_utils` ferait cesser de matcher chaque cle de stub — contournant silencieusement l interception — pour un fichier d une ligne. Net negatif.
* **Comment appliquer** : traiter `lib.text_utils` comme le namespace macOS-local canonique de cet utilitaire partage, meme role load-bearing que les shims `lib/toml/{codec,reader,writer}.lua`. Ne pas les <<de-shimmer>>. (Le jumeau `lib/color_utils.lua` n avait lui aucun require de production et A ete supprime — commit `f56e0a048` ; il n existe plus aucun module `color_utils` aujourd hui.)

### [project-hs-audit-open-labels-are-stale] Les labels <<Open>> des audits archives sont non verifies — relire la source
* Les constats de `docs/archive/audits/AUDIT_HAMMERSPOON_*.md` sont des instantanes a un instant t : une re-verification a trouve la grande majorite des constats macOS marques <<Open>> deja corriges dans le code. Il n existe pas de registre consolide des constats macOS clos (le <<Track B done>> du REFACTOR_GUIDE concerne un audit AHK distinct), donc le statut n est connaissable qu en lisant la source. En re-auditant, traiter chaque label <<Open>> archive comme **non verifie** — y compris ce paragraphe.
* **La forme de bug vivante recurrente** : les vrais problemes ouverts sont presque toujours le **frere oublie** d un invariant corrige a son site documente (cf. [[project-ahk-invariant-incomplete-application]], qui s applique a macOS mot pour mot) — le correctif du cycle de vie du tap a rate `menu_state.sync_state_to_modules` ; le garde d appui simple a rate `Ctrl`+F13/F14/F15 ; le teardown MLX a rate le chemin Quit de la menubar ; le garde de warmup LLM a rate `WarmupCtrl`/`models_selector`. **Chasser toute la *classe* de l invariant, pas l unique site documente.**
* Pour tout bug invisible au runtime (throw async avale, closure-nil-global, flag de config mort, tache jamais `.start()`ee), le test de regression DOIT encoder la cause racine de facon comportementale — un grep du type <<la chaine d appel existe>> est un faux-vert (il a garde deux regressions vertes).
* **Classe encore invisible** : `lib/logger.install_runtime_error_capture()` n enveloppe que les constructeurs `hs.timer` et tee `print()`. `adapters/shell_runner.lua` a depuis ete corrige (xpcall + crash report), mais `adapters/http_client.lua` invoque toujours ses callbacks de completion sous un `pcall` nu sans `Logger.error` — les throws y sont silencieux. Corriger cet adaptateur rendrait auto-signalante toute la famille de bugs <<callback async>>.

### [project-dc1-windows-vk-finger-map-gap] `KLW_VK_FINGER` est une 3e carte de doigts laissee expres, pas une regression
* `_shared/data/keycodes/azerty.json` est la carte doigt/main canonique. La copie JS (`_shared/ui/metrics_typing/state.js`) est desormais generee au build (verrouillee par `tools/test/test-keycode-data-js-parity.cjs`) et la copie macOS (`macos/modules/keylogger/aggregator/core.lua`) se derive au runtime depuis le JSON — aucune des deux ne peut plus deriver.
* **La 3e copie reste volontairement** : `KLW_VK_FINGER` (`windows/modules/keylogger/keylogger_walker_core.ahk`) mappe des **codes de touche virtuels Windows** — un espace d identifiants totalement different — vers les memes identifiants de doigt, pour la detection AHK des series meme-doigt/meme-main. azerty.json n a aucun champ VK, et deriver a la main la correspondance `kc` macOS ↔ VK Windows risque de corrompre silencieusement les stats WPM/SFB : trop risque a faire par inspection sans clavier physique.
* **Comment appliquer** : pour une vraie parite 3 drivers, ajouter D ABORD le champ VK a azerty.json et le verifier exhaustivement contre un log de frappes reelles capture touche par touche (pas par inspection), PUIS porter `KLW_VK_FINGER` pour qu il en derive. D ici la, c est un doublon connu et intentionnel.

### [project-ahk-suite-runnable-here-plus-os-purity-ratchet-nondeterminism] La suite AHK EST executable sur cette machine — lire le resultat dans %TEMP%
* **Capacite (non evidente)** : AutoHotkey v2 est installe a `C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe`. La suite Windows complete tourne headless via `AutoHotkey64.exe run_all.ahk` depuis `static/ergopti_plus/windows/tests`. Ce binaire est de **sous-systeme GUI**, donc son `FileAppend(text, "*")` n atteint jamais un pipe Git-Bash — lire le rapport TAP dans le fichier qu il ecrit aussi : `%TEMP%\ergopti_test_results.txt` (`TEST_RESULTS_CANONICAL`, `tests/test_framework.ahk`) ; la derniere ligne est `# N passed, M failed.`. ~4 min, watchdog a 240 s. Les changements cote Windows SONT verifiables ici — pas seulement <<ecrire et esperer>>.
* **Piege — le ratchet de purete OS est non deterministe.** `windows/tests/meta/test_ahk_os_purity_ratchet.ahk` compte les lignes DllCall/COM/FileIO dans `windows/{modules,lib}` (`adapters/` exclu) avec un `try Src := FileRead(...)` par fichier qui **avale les echecs de lecture** (`Src=""` → 0 token pour ce fichier). Un flake intermittent sous-compte silencieusement, donc le total varie d une execution a l autre sur une source identique. Lancer la suite deux fois ; un ecart isole sur le ratchet ou le total avec des editions neutres en tokens est ce non-determinisme connu, pas ta regression.
* **Comment appliquer** : avant de croire un run rouge, repliquer le compte de facon deterministe (parcours node des memes dossiers, lignes `;` ignorees, une ligne au plus une fois par categorie). Si le depassement de `_AOPR_BASELINE` est reel, corriger selon la regle du ratchet lui-meme : router un appel OS dans `windows/adapters/` (tirer le compte vers zero) OU relever le baseline **avec une note explicite** (le fichier l autorise pour les appels vraiment inadaptes a un adaptateur). Jamais de bump silencieux.

### [project-ahk-isset-requires-variable-load-crash] `IsSet(obj.prop)` is a LOAD-TIME crash in AHK v2 — and source-introspection tests can never catch it

* **Bug (2026-07-08)**: `lib/webview_utils.ahk` probed `IsSet(WebViewHost._ManifestCache)` (and `IsSet(this.WebView)` / `IsSet(this.Controller)` across the `WebViewHost` lifecycle). AHK v2 `IsSet` accepts **only a plain variable**, never a property or index expression, so `IsSet(obj.prop)` / `IsSet(arr[i])` raises `Error: IsSet requires a variable.` at **parse time** — the file fails to load and the whole app aborts the instant it is `#Include`d ("erreur dès le démarrage"). AHK reports only the *first* load error and exits, so all six broken calls presented as one crash at the earliest line; fixing only that line just moves the crash to the next one.
* **Correct probe for "is this property/field set"**: `obj.HasOwnProp("name")` — empirically (this AHK build) returns false for a property declared `:= unset`, true after assignment, false again after re-assigning `unset` (exact `IsSet` semantics). Verified round-trip: `init:0 → afterset:1 → afterunset:0`. Use `HasOwnProp` for optional fields that are only *accessed behind the guard*. For a holder that is **read unconditionally** (e.g. via `is Map`) use a concrete sentinel (`""`/`false`/`0`), never `unset` — reading an `unset` property throws (see [[project-ahk-v2-static-unset-unreadable]]). The manifest cache took the concrete-`""` route for exactly this reason.
* **Why the "plein de tests unitaires" missed it (the real lesson)**: every `webview_utils` test (`test_webview2_temp_leak`, `test_webview_low_ram_native_fallback`, `test_webview_shared_env_reentrancy_guard`) is **pure source-introspection** — `FileRead` + `InStr`/`RegExMatch` on the text. None of them ever *parses the file through the AHK interpreter*, so a load-time/parse error is invisible to them. This is a **systemic blind spot**: the whole meta-test family (`_DriverSourceConcat` / `_DriverFuncBody`) reads source as strings; it can assert *what the code says* but never *that the code loads*. AHK `/ErrorStdOut` and `/validate` are unreliable here (both spuriously exit 2 / pop a modal dialog under Git-Bash launch), so a headless "does it parse" gate isn't trivial to add.
* **Regression**: `tests/meta/test_isset_no_property_arg.ahk` scans the **entire** driver source (`_DriverSourceNoComments()`) for `(?<!\w)IsSet\(\s*[A-Za-z_]\w*\s*[.\[]` and asserts zero hits — guards the whole class across every present/future file, not just the site that bit us. Regex verified: matches all three original bad lines, ignores valid `IsSet(var)` and `MyIsSet(a.b)`. `_DriverFuncBody(Name)` only anchors on **free functions** (`^[ \t]*Name\(`), so it can't extract a `static`/instance **class method** body — scan `_DriverSourceNoComments()` directly for class-method invariants.

Related: [[project-ahk-v2-static-unset-unreadable]], [[project-ahk-suite-runnable-here-plus-os-purity-ratchet-nondeterminism]]

### [project-metrics-ui-live-foreground-contract] Un tableau de bord de metriques doit projeter l intervalle de premier plan encore ouvert
* **Invariant** : l agregation par changement d app ne compte que les intervalles DEJA termines, donc ouvrir le tableau de bord avant le prochain changement omet forcement le temps de l app courante. L intervalle ouvert doit etre ajoute **uniquement au moment de la lecture/du rendu** — jamais persiste ni mis en cache, sinon il est compte deux fois. Amorcer l app de premier plan au demarrage d un cycle de vie, car son premier callback est declenche sur front.
* **Un micro-idle reste du temps de premier plan.** Windows reinitialisait `app_entered_at` a chaque micro-idle de 30 s, ce qui mesure la densite de frappe et non le temps d ecran attentif. Seuls un vrai timeout de session, un verrouillage ou une mise en veille terminent l intervalle.
* **Les trois drivers doivent emettre la meme enveloppe** (`{metrics_manifest, app_icons}`). Garder les correctifs UI cross-driver bases sur le contrat : une UI qui se *charge* mais recoit une forme de payload differente est toujours cassee. Couverture : `tools/test/test-shared-ui-js-syntax.cjs` parse les scripts navigateur partages (un template literal malforme a une fois tue silencieusement `process_manifest` sur macOS) ; Windows `test_metrics_app_time_accuracy.ahk` couvre le micro-idle et le manifest live ; Linux couvre le contrat du pont, l amorcage du cycle de vie et la projection par app.

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

_Premiere passe adverse sur le driver Hammerspoon. Le markdown d'audit a ete supprime par
design : cette entree EST l'archive._

<sub>slug: `project_hs_audit_2026_07_21`</sub>

13 defauts corriges. **Les 78 findings laisses OPEN par cette passe sont tous clos** — voir
`[[project_hs_audit_round4_2026_07_21]]`. Ne rien re-implementer depuis une liste perimee
(`[[project-hs-audit-open-labels-are-stale]]`).

**Formes de defauts a savoir reconnaitre** (toutes corrigees, chacune avec sa regression) :
des PII atteignant le log 14 jours par le puits *preview* apres que le contrat de retenue
ait ete applique aux deux puits d'*expansion* seulement — la sortie provider est desormais
retenue **inconditionnellement**, parce que l'API d'enregistrement ne porte aucune
metadonnee de confidentialite et que la retenue-par-defaut est la seule forme sous laquelle
un futur provider ne peut pas fuiter par omission. `is_secure_field` ecrit depuis deux sites
qui divergeaient, si bien que tout changement de focus dans un gestionnaire de mots de passe
reactivait la capture. `_sql_num(nil)` -> `NULL` dans des colonnes `NOT NULL`, avale par
`INSERT OR IGNORE`. L'argument par defaut de `keyStroke` bloquant la run loop 200 ms par
appel sur 49 sites. `karabiner.pause/resume` deployant 100 kB de config a l'interieur de
l'eventtap script-control — le tap qui porte precisement la touche necessaire pour depauser.

**REFUTE — ne pas relever :**

- **Bug de rotation par date du logger.** *Faux pour macOS* : `_ensure_log_file()` repointe
  les DEUX `UNIFIED_LOG_FILE` et `ERRORS_LOG_FILE` au rollover, asserte par
  `test_logger_date_rollover.lua`. **Defaut propre a AHK — ne pas porter le fix.**
- **Appels AppleScript de `gestures/actions.lua` non differes.** *Faux* — le grep pointait
  les lignes internes de closures deja enveloppees dans `hs.timer.doAfter(0, …)`. Un hit de
  grep n'est pas un site d'appel : ouvrir le fichier.
- **Le widget WPM tourne sous pause.** *Faux* — la suppression est indirecte mais reelle,
  via `on_pause_change` -> `updateMenu()` -> le builder metrics.
- **`[[project_lua_closure_before_local_nil_global]]` present sur macOS.** *Faux* — un scan
  mecanique de tout `.lua` non-test n'a trouve que des faux positifs. Relancer le scanner
  plutot que relire a l'oeil.
- **Mauvais usage d'`utf8`.** *Blanchi* — chaque boucle `utf8.codes` est gardee par un
  `pcall(utf8.len, …)` reussi.

**Comment l'appliquer :**

- **Ecrire le test de garde a l'echelle de la CLASSE des le depart.** Chaque finding de
  severite haute etait le frere d'un invariant que la base affirmait et testait deja
  ailleurs. Le scan NOT NULL a trouve 4 colonnes de plus, le scan gsub a trouve `search_web`.
- **Suspecter le test livre autant que le code livre.** Le stub de `shell_runner` renvoyait
  `nil` la ou `hs.task:start()` renvoie l'objet task — le stub *cimentait* le defaut que son
  propre test pretendait verrouiller ; le stub `hs` perdait le 3e argument de `keyStroke`,
  donc aucun test ne pouvait le voir. Reparer un stub infidele **renforce** un test : ce
  n'est pas l'affaiblir.
- **Quand une garde est deliberee, corriger l'autre cote.** La position de la garde de pause
  est epinglee volontairement ; l'obsolescence du contexte a donc ete corrigee par une
  re-synchro au resume, laissant « pause = tout eteint » aussi strict.
- **G4 (latence) reste non mesuree sur ce driver** — il n'a jamais tourne sur le poste de
  dev Windows et `<config_dir>/hammerspoon/` n'a pas de `logs/`. Les vrais logs sous
  `<config_dir>/autohotkey/logs/` appartiennent a l'AUTRE driver. Ne jamais citer une
  milliseconde non observee (`[[project_audit_evidence_must_be_reproducible]]`).
- **loop-until-dry n'a PAS ete atteint.** `lib/toml`, `lib/i18n`, les adapters d'entree,
  `ui/menu_llm`, `ui/download_window`, `ui/healthcheck`, `ui/metrics_*` et **l'ordre de boot
  / le callback de shutdown d'`init.lua`** n'ont jamais ete balayes. Le silence d'un rapport
  d'audit n'est pas de la couverture.
- **Les subagents ecriront dans votre worktree sauf interdiction explicite.** « lecture
  seule » doit nommer le depot entier, pas seulement « les sources du driver ».

Related: [[project_hs_audit_round4_2026_07_21]], [[project_ahk_guard_tests_must_loop_the_class]],
[[project_audit_findings_are_hypotheses]], [[project_audit_evidence_must_be_reproducible]],
[[project_macos_eventtap_no_blocking]], [[project_suspend_pause_invariant]],
[[feedback_regression_tests]].

### project-hs-audit-round2-2026-07-21

_Adjuger un backlog d'audit contre la source courante : un tiers etait faux ou perime_

<sub>slug: `project_hs_audit_round2_2026_07_21`</sub>

Les rondes 2-3 ont traite les 78 findings ouverts de `[[project_hs_audit_2026_07_21]]` ;
la ronde 4 a clos le reste. **La liste « STILL OPEN » que portait cette entree est
entierement implementee — rien ici n'est du travail en attente.**

**Methode a reutiliser.** Chaque finding ouvert a ete adjuge contre la source COURANTE, un
agent par fichier, rendant CONFIRMED (preuve citee + fix minimal exact + plan de test),
REFUTED (avec le code qui infirme) ou ALREADY_FIXED. Sur 75 adjuges : **53 confirmes,
16 refutes, 6 deja corriges** — pres d'un tiers du backlog etait faux ou perime, ce qui est
precisement pourquoi implementer une liste d'audit au pied de la lettre est une mauvaise
idee (`[[project_audit_findings_are_hypotheses]]`).

**Refute avec preuve — ne pas relever :** le retour de `start()` dans `karabiner/watchers.lua`
(verifie par le proprietaire du verrou), le fallback closeAll de `shortcuts/actions/system.lua`
(IL est atteignable), le chemin `is_ignored` de `keymap/init.lua` (atteignable), la boucle de
retry de `log_manager.lua` (elle termine), le ledger de `kc_bridge.lua` (borne ailleurs),
`poll_until` dans `karabiner/onboarding.lua` (deja async), plus sept findings sur la qualite
des tests dont les gardes se sont averees adequates.

**Elargir une garde rapporte plus que poursuivre le site signale — ca a paye quatre fois :**
la garde d'epinglage GC de `hs.task` etait une ALLOWLIST de 8 fichiers ; la convertir en scan
de tout l'arbre a trouve 5 fichiers non epingles que personne n'avait signales. La garde
d'echappement gsub en a trouve 7 de plus, puis son propre motif s'est revele trop etroit
(identifiants nus seulement, ratant `tostring(err)`) et l'elargir en a trouve 7 encore. La
garde de quoting shell a trouve **41 sites dans 15 fichiers** ou `%q` — qui echappe pour un
litteral Lua et laisse `$`, backticks et `!` vivants pour /bin/sh — quotait un chemin
configurable par l'utilisateur. La garde NOT NULL a trouve 4 colonnes de plus. Les quatre
sont aujourd'hui des meta-tests permanents (`tests/meta/test_gsub_replacement_escaping.lua`,
`test_shell_quoting_not_lua_q.lua`, `test_shell_runner_gc_protection.lua`,
`tests/unit/modules/keylogger/test_build_inserts_never_nulls_not_null.lua`).

**Bugs auto-infliges rattrapes par la discipline :**

- Une reecriture par regex a transforme le corps de `postKeyStroke` en recursion infinie, et
  une autre a CORROMPU trois chaines de format multi-`%q` en fusionnant deux arguments en un
  appel. **Relire le diff de toute reecriture scriptee avant de commiter.**
- **Lancer `lua tests/run.lua` AVANT chaque commit, pas apres** — le hook pre-commit lint
  mais ne lance PAS la suite. Un commit est parti rouge.
- **`lib/logger.lua` ne doit acquerir aucune dependance.** Ajouter `require("lib.text_utils")`
  a casse **19 tests** par ordre de boot ; le logger quote inline a la place (la raison est
  desormais un commentaire au site d'appel).
- Un test comportemental de gestures incapable de discriminer corrige de casse (en mode x1,
  « a arrete de tirer » est indiscernable d'une completion normale) a ete remplace par une
  garde structurelle, en disant pourquoi dans le fichier.
- Dire aux subagents que « lecture seule » signifie le **depot entier**. A qui on avait dit
  seulement « ne modifie pas les sources du driver », l'un a ecrit un test sonde dans
  `tests/` et pollue une execution en cours.

Related: [[project_hs_audit_2026_07_21]], [[project_hs_audit_round4_2026_07_21]],
[[project_ahk_guard_tests_must_loop_the_class]], [[project_audit_findings_are_hypotheses]],
[[feedback_regression_tests]].

### project-hs-audit-round4-2026-07-21

_Deux implementations independantes de « est-ce que ce mapping va se declencher ? » avaient
diverge de quatre facons — le fix a ete d'en supprimer une_

<sub>slug: `project_hs_audit_round4_2026_07_21`</sub>

La ronde 4 a clos le backlog d'audit Hammerspoon : les 78 findings traites (53 corriges,
16 refutes, 6 deja corriges). Suite 3241 -> 3356 verte.

**La divergence tooltip/moteur fut la vraie trouvaille de la ronde.** Un rapport
utilisateur — « le tooltip montre une expansion, j'appuie sur ★, et j'obtiens la derniere
lettre doublee » — s'est revele etre deux implementations independantes de « est-ce que ce
mapping va se declencher ? ». `llm_bridge.ends_with_trigger` et
`expander.word_boundary_blocks` divergeaient de QUATRE facons, dans les **deux** sens : en
debut de buffer le preview autorisait toute correspondance la ou le moteur consulte
`start_is_word_boundary` et refuse (le tooltip promettait, le moteur declinait) ; les
declencheurs prefixes d'un separateur (`;e` -> `Je`) sont exemptes de la regle de frontiere
dans le moteur mais pas dans le preview (le moteur emettait du texte que le tooltip n'avait
jamais montre) ; la resolution `case_conform` existait dans le seau autocorrect du preview
mais pas dans son seau star ; et les gardes de no-op comparaient des operandes differents.

Corrige en extrayant **`expander.would_fire(m, buffer)` comme source unique de verite**,
derivee de `try_auto_expand` (qui lui delegue desormais, pour que la semantique du moteur
reste faisant autorite). Le preview appelle la meme fonction, et pour un declencheur ★
interroge `buf .. magic_key` — le buffer que le moteur verra reellement. **Le matcher prive
du preview a ete supprime, pas conserve comme helper.**

**Deux axes, pas un.** Unifier le MATCHING a laisse une seconde divergence : une ligne
pouvait etre inatteignable a cause du MOMENT ou elle avait ete tapee. `update_preview` ne
tourne que si aucune expansion n'a tire ; donc un declencheur `auto` complet en fin de
buffer signifie que le moteur l'a deja decline et que rien ne peut reessayer. Ces lignes
annoncaient des expansions qu'aucune frappe ne pouvait produire ; desormais conditionnees
par `not mapping.auto`.

**★ est une validation explicite.** La branche terminateur contournait deja le delai de
vitesse de frappe pour la touche magique ; la branche auto — qui POSSEDE les declencheurs
`has_magic`, puisque leur codepoint de queue EST ★ — n'avait jamais recu ce contournement,
donc un declencheur ★ tape apres une pause retombait sur le fallback repeat-key. Hisse en un
seul local `star_validated` partage.

**Lecons qui ont coute quelque chose :**

- **Ne jamais supprimer la sortie de `git stash pop`.** `pop stash@{0} >/dev/null 2>&1` a
  masque un conflit ; 15 fichiers ont ete commites en portant des marqueurs `<<<<<<<`,
  rattrapes seulement parce que la commande suivante n'a pas su parser `lib/logger.lua`. La
  pile de stash est partagee entre worktrees — preferer copier les fichiers vers le
  scratchpad et `git checkout HEAD -- <path>` pour les preuves rouge/vert.
- **Encoder la CLASSE, pas le site.** Un scan de tout l'arbre pour les cibles `require()`
  non resolubles a trouve 6 references mortes la ou le finding en signalait 4, et un scan au
  niveau methode en a trouve 4 de plus vers des methodes inexistantes.
- **Borner une fenetre de scan de source au rebind suivant de la variable.** Une fenetre de
  largeur fixe a impute a `lib/ui_restore.lua` une garde appartenant a l'entree de liste
  suivante (toutes nomment leur module `m`). Livrer ca aurait « corrige » du code correct.
- **Les mentions en prose d'un symbole precedent son appel.** Une garde ancree sur
  `try_repeat_feature` matchait le commentaire documentant l'ordre des branches — ancrer sur
  la forme d'appel (`Expander.try_repeat_feature`).
- **Un test qui passe seul peut echouer en suite.** De nouveaux cas gestures appelaient
  `Actions.init()`, qui warn et sort au deuxieme appel : en execution complete ils operaient
  sur l'etat d'un fichier precedent. Charger un module frais par cas.

Related: [[project_hs_audit_2026_07_21]], [[project_macos_eventtap_no_blocking]],
[[project_ahk_guard_tests_must_loop_the_class]], [[feedback_regression_tests]].

### project-perf-2026-07-21-implementation

_Pourquoi l'I/O par item est le premier suspect de perf, pourquoi une refutation est aussi
une hypothese, et pourquoi le cap de queue end-char a ete refuse_

<sub>slug: `project_perf_2026_07_21_implementation`</sub>

Huit des neuf candidats de l'audit perf AHK du 2026-07-21 ont ete livres, un commit chacun,
chacun verifie rouge-avant / vert-apres. Les cinq lecons durables :

**Quand le cout d'une phase croit avec le nombre d'items, suspecter l'I/O par item avant de
suspecter les items.** `_MG_LoadHotstringSubCategories` relisait et redecodait les 12,5 ko de
`menu_manifest.json` a chaque item de menu (~100x par construction). Le parser du driver
lui-meme benche a **44,3 ms par decodage**, dont 43,9 ms de `JsonParse` — `lib/json.ahk` est
un parser recursif-descendant en AHK a ~4 µs/octet — tandis que `FileRead` coute 0,096 ms
parce que le fichier est en page-cache. Soit ~4 s par boot ET par reconstruction a chaud, et
le tout **neutre en comportement** : le manifest ne declare aucune cle `master_gates`, donc
le helper renvoyait toujours ses defauts codes en dur. Il lit desormais la racine partagee
deja en cache via `_MR_GetManifestRoot()`, verrouille par
`tests/meta/test_menu_master_category_cache.ahk`.

**Un verificateur adverse peut se tromper dans le sens confiant.** La passe de verification
de l'audit a ecarte le chiffre de parsing comme « invraisemblablement eleve, le realiste est
2-5 ms » et exige un re-bench avant d'assigner une priorite. Le re-bench a donne raison au
chiffre initial, et l'a meme montre legerement conservateur. Une refutation est une
hypothese elle aussi — la re-deriver avant d'agir dessus.

**Le runner AHK et le gate JS couvrent des terrains DISJOINTS.** Ajouter un seul nom a une
contract map `ADAPTER_*` a laisse la suite AHK integralement verte alors que le contrat de
port cross-driver etait casse : la conformite de port n'est verifiee que par `test:js`. Cette
map declare le port que CHAQUE driver doit satisfaire, donc un helper propre a Windows
(`CB_IsBusy`) a sa place dans le fichier adapter mais PAS dans la map. `.claude/skills/verify-change/`
et `tools/test/verify-change.cjs` derivent maintenant les gates requis des fichiers modifies,
pour que ce choix ne soit jamais fait de memoire.

**Deux classes d'echec silencieux sont desormais verifiees mecaniquement**, parce que toutes
deux produisent une suite QUI PASSE : un fichier de test que `run_all.ahk` n'`#Include` pas
ne tourne jamais (`tests/meta/test_run_all_include_integrity.ahk`) ; et `_DriverFuncBody("Nom")`
renvoie `""` pour un nom introuvable, donc toute assertion d'absence dessus passe a vide.
AHK v2 aggrave la seconde : **appeler une fonction qui n'existe pas n'est pas une erreur au
chargement** — le nom se resout comme une variable — et les sites d'appel en production sont
generalement enveloppes dans `try`, donc un renommage a moitie fini donne un test vert, zero
erreur et zero ligne de log.

**OPT-9b (cap par queue sur la boucle end-char) a ete refuse, deliberement.** Il exige cinq
sites synchronises ; en rater un donne une borne trop courte, c'est-a-dire **un hotstring qui
cesse silencieusement de tirer**. Le gain est sub-µs contre un seuil de profiler a 5 ms, et
le meme mecanisme sur la boucle STAR, plus chaude, avait deja ete refute pour gain non
mesurable. Ne pas le relever : risque de correction pour zero gain mesurable.

**Quand une branche de repli emet, elle doit rapporter le succes.** La branche
`_SEND_INSTANT_CLIP_BUSY` de `SendInstant` injectait le texte puis renvoyait nu (falsy),
tandis que `WrapTextIfSelected` lit falsy comme « rien emis » et re-envoyait le symbole nu
par-dessus. Le commentaire au site d'appel affirmait meme le contraire.

Related: [[project_audit_2026_07_21_open_items]],
[[project_typing_latency_tooltip_coldstart]],
[[project_ahk_guard_tests_must_loop_the_class]], [[feedback_regression_tests]].

