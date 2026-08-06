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
- [project-gate-scripts-must-be-wired](#project-gate-scripts-must-be-wired) — A `tools/test/` script is only a gate once `run-js-suite.cjs` invokes it; four exist that nothing runs, one of them documented as a "CI gate"
- [project-generated-trees-are-not-reducible](#project-generated-trees-are-not-reducible) — The `_generated/` trees were audited 2026-08-03: 21 artefacts, 200.3 KB, zero orphans — do not re-open the question
- [project-plan-entries-go-stale-faster-than-code](#project-plan-entries-go-stale-faster-than-code) — Eighteen TODO measurements were wrong across two sessions; re-measure before starting and write the correction back
- [project-a-second-vocabulary-fails-silently](#project-a-second-vocabulary-fails-silently) — Two modules naming the same data differently never raises: the receiver reads nil and takes its default, so every failure mode is plausible output
- [project-instrumentation-absence-is-invisible](#project-instrumentation-absence-is-invisible) — A missing profiler segment produces a clean-looking profile, so the 20 segments and 5 boot stamps are inventoried
- [project-a-green-probe-can-mean-redundant-guards](#project-a-green-probe-can-mean-redundant-guards) — A falsifiability probe that stays green can mean the hazard is guarded twice, not that the assertion is vacuous
- [project-the-macos-logger-ring-is-per-process](#project-the-macos-logger-ring-is-per-process) — The shared Lua core is required under a bare name, so the test runner never evicts it and its state spans every test file
- [project-adopting-a-singleton-core-has-three-costs](#project-adopting-a-singleton-core-has-three-costs) — Moving a driver onto a shared process-singleton core costs single-slot hooks, cross-file state carry-over, and newly-visible log lines
- [project-audit-ahk-2026-07-30-pass](#project-audit-ahk-2026-07-30-pass) — Sixth adversarial AHK pass: 14 findings all fixed; the refuted list, the coverage gaps, and the two measurements worth keeping
- [feedback-ahk-suite-needs-temp-space](#feedback-ahk-suite-needs-temp-space) — A near-full `%TEMP%` volume makes the AHK runner report assertion failures that do not reproduce; check free space before believing a red run
- [feedback-test-before-merge](#feedback-test-before-merge) — Never merge a slice into dev before the user has tested it live. Stay on the branch and wait for explicit validation.
- [feedback-ui-must-be-i18n](#feedback-ui-must-be-i18n) — All user-facing UI text goes through the i18n system in 21 languages — never hardcode a UI string anywhere, WebView UIs included
- [project-heredoc-normalises-trailing-newlines](#project-heredoc-normalises-trailing-newlines) — A shell heredoc always appends a newline, so `with_stdin` silently alters DATA payloads; use `with_exact_stdin`
- [project-windows-at-rest-store-is-data-sql](#project-windows-at-rest-store-is-data-sql) — Windows never opens db.sqlite: data.sql is the data at rest, and the cache is rebuilt from it
- [project-ahk-menu-dispatcher-error-swallow](#project-ahk-menu-dispatcher-error-swallow) — The menu-dispatcher bypass must re-throw callback errors — a local try/catch only destroys reporting
- [project-ahk-loop-capture-copy-freezes-nothing](#project-ahk-loop-capture-copy-freezes-nothing) — Copying a loop variable into another outer local does not freeze it for a closure; use .Bind()
- [project-source-scan-loops-need-a-floor](#project-source-scan-loops-need-a-floor) — A scan loop that finds nothing looks exactly like a scan loop that finds only good results; assert the match count
- [project-ahk-settimer-reenters-during-file-io](#project-ahk-settimer-reenters-during-file-io) — AHK pumps messages during blocking file I/O, so a routine that schedules its own next tick can be re-entered mid-flight
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
- [project-typing-order-and-atomicity](#project-typing-order-and-atomicity) — Qui possede le terminateur (macOS le consomme, Windows/Linux non), pourquoi une expansion doit etre une rafale atomique, et pourquoi une fenetre temporelle ne remplace jamais un filtre par provenance
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
- [project-ahk-map-delete-raises-on-missing-key](#project-ahk-map-delete-raises-on-missing-key) — `Map.Delete(k)` throws when the key is absent; the `/validate` half of this entry is superseded — the flag never validates
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
- [[project-macos-reload-during-git-pull] Auto-reload watchers must hold the reload while ANY bulk write (git pull, cloud sync, rsync) rewrites the tree](#project-macos-reload-during-git-pull-auto-reload-watchers-must-hold-the-reload-while-any-bulk-write-git-pull-cloud-sync-rsync-rewrites-the-tree) — reloading mid-bulk-write (git pull OR OneDrive/Dropbox/rsync) froze the driver; both macOS and Linux now hold the reload via the shared `reload_gate` (adaptive quiescence + a precise git index.lock guard)
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
- [project-pages-deploy-branch-vs-workflow](#project-pages-deploy-branch-vs-workflow) — GitHub Pages set to "GitHub Actions" ignores the gh-pages branch entirely: pushes "succeed" while the live site stays frozen. This repo deploys from the BRANCH, and the deploy step must run its git ops in a worktree, never `git checkout gh-pages` inside the build dir
- [project-site-i18n-gettext-french-key](#project-site-i18n-gettext-french-key) — The ergopti-plus page translates with t('French source'): the French text IS the key, so edited copy falls back to the new French instead of showing a stale translation; adding a language is one dictionary file + one list entry
- [project-svelte-script-comment-closing-tag](#project-svelte-script-comment-closing-tag) — A literal closing script tag ANYWHERE inside a Svelte component script — even in a // comment — terminates the block and breaks the parse; assemble such strings from split halves
- [project-hs-audit-2026-07-29](#project-hs-audit-2026-07-29) — Every cross-cutting hygiene ratchet in this repo was written for the Windows driver and never extended to macOS; that one gap shipped a red CI job, sixteen mojibake sequences and nineteen unparseable locales
- [project-hs-audit-2026-07-30-implementation](#project-hs-audit-2026-07-30-implementation) — Ce qui casse quand on implemente les findings : un garde qui cherche le helper « quelque part dans l'appel » est un faux vert, et `doAfter(0, …)` deplace le gel sans le supprimer
- [project-source-scanning-guards-must-strip-comments](#project-source-scanning-guards-must-strip-comments) — Tout garde qui cherche du texte dans du code source doit retirer les commentaires d'abord : commenter la ligne gardee laisse le texte cherche intact, et le garde reste vert. Piege rencontre deux fois en une session, sur des tests neufs
- [project-simplification-branch-2026-07-30](#project-simplification-branch-2026-07-30) — Etat de la branche `simplification` : ce qui est livre, ce qui reste, et les trois affirmations d'audit qui se sont revelees fausses a la verification

- [project-linux-grab-is-a-contract-not-a-flag](#project-linux-grab-is-a-contract-not-a-flag) — EVIOCGRAB on Linux is only survivable with an open uinput channel, in that order; the kernel releases the grab on process death, so the danger is not the crash but the fork-per-key fallback
- [project-git-stash-in-this-checkout-pops-a-stranger](#project-git-stash-in-this-checkout-pops-a-stranger) — `git stash push` can fail with "could not write index" and the reflex `git stash pop` then merges someone else's parked stash into your tree; never reach for stash here to get a clean tree
- [project-drift-guard-needs-a-clean-tree](#project-drift-guard-needs-a-clean-tree) — `test-drift-guard-covers-every-output.cjs` fails whenever a generated file is modified-but-uncommitted, by design, and takes over two minutes

- [project-linux-a-field-must-be-named-at-every-boundary](#project-linux-a-field-must-be-named-at-every-boundary) — On the Linux driver the same defect recurred nine times in one session: a value is computed correctly and lost at a boundary that DROPS what it does not name — an allow-list, a projection, a code-to-table map, a JSON envelope. Nothing errors, and the symptom is always a panel of zeroes
- [project-python-slice-replace-can-shred-a-file](#project-python-slice-replace-can-shred-a-file) — A `str.replace` whose needle came from two `index()` calls silently becomes `replace("", …)` when the bounds invert, inserting the payload between every character; the original is recoverable because it is interleaved, not lost
- [project-a-driver-that-types-also-types-into-its-own-keylogger](#project-a-driver-that-types-also-types-into-its-own-keylogger) — Whether the driver's own keylogger sees an expansion depends on WHICH sender emitted it: SendEvent is observed, SendInput is not, and no comment in the tree says so
- [project-an-enumeration-is-not-a-feature](#project-an-enumeration-is-not-a-feature) — Every hand-written list in this repo has been found short; the fix is to derive the list, and where derivation would explode, to resolve at use time instead
- [project-the-preview-index-is-file-driven-only](#project-the-preview-index-is-file-driven-only) — The Windows preview tooltip reads _PrefixIndex, whose single writer has three FILE-driven callers; a trigger registered imperatively by CreateHotstring can never be previewed, and inserting it into the index is erased by the next rebuild




### project-linux-a-field-must-be-named-at-every-boundary

**What kept happening.** Nine separate defects in one session on the Linux
driver had one shape. A value is computed correctly, and then lost at a
boundary that silently drops whatever it does not name by hand:

- `sqlite_writer.upsert_app_day` has an `allowed` set. A field absent from it is
  dropped without a word. The three LLM counters, then `hs_suggested` and
  `llm_suggested`, each spent their existence incremented in memory and
  forgotten at every restart.
- `keylogger.get_app_stats()` is a projection the flush reads. A field the
  accumulator increments and this does not copy is lost between the two. Same
  two counters, same session, second boundary — fixing the first was not enough
  and the symptom did not change.
- `sqlite_reader` built an n-gram envelope with thirteen codes and filled one,
  because its query named a single table.
- `hotstring_engine.load_mappings` has a bucket whitelist; `is_private` and
  `field` were absent, so the privacy flag never reached the preview.
- The dashboard bridges answered actions no page sends and none of the two it
  does.
- The healthcheck bridge answered a shape of its own invention; the page reads
  sixteen named fields and found none.

**Why it is hard to see.** Every one of these is a green test away from being
caught and none of them errors. The failing surface is a panel of zeroes or a
blank window, which reads as "this feature is unused" or "this driver has
nothing to report" — the two most plausible wrong conclusions available.

**What to do.** When adding a value that must reach the database or a page,
grep the whole path for a place that ENUMERATES fields, and add it to every one.
Then test the join, not the units: the walk and the writer were each correct in
isolation while the flush called neither. See
[[project-linux-writing-a-table-nobody-reads]].



### project-linux-writing-a-table-nobody-reads

A table that is written and never read fails identically to a table that is
never written: a blank panel. Both halves have to land in the same change, or
the second half looks like the first half not working.

The Linux driver wrote 8 of the schema's 25 tables. Adding the walk that fills
the other n-gram families changed nothing visible until the reader was taught to
query them — and the delay columns were written as literal zeroes by the writer
AND dropped by the reader's merge, so "which sequences cost you the most" ranked
a column of zeroes while looking entirely functional.

The same rule applies to adapters. `adapters/notifier.lua` was DELETED under
ADR-008 for having no callers: the file made the port matrix answer "does Linux
notify?" affirmatively by inspection while the practical answer was no. When it
was reinstated, the caller landed in the same commit and got its own assertion,
because the port matrix gate only checks presence.


### project-the-preview-index-is-file-driven-only

_A trigger created by CreateHotstring can never appear in the Windows preview bubble — the index has one writer and all three of its callers read files_

<sub>slug: `project_the_preview_index_is_file_driven_only`</sub>

On Windows the hotstring preview resolves its candidates from `_PrefixIndex` and
from nothing else. That Map has exactly one writer, `_AddTriggerToIndex`,
reachable from three callers — the bundled category TOML scan, its in-memory
cache equivalent, and the extension-pack scan. **All three are file-driven**, and
the six-name list they iterate (`_PREFIX_WATCHER_CATEGORIES`) has no entry for
anything registered in code.

So every trigger created imperatively at boot by `CreateHotstring` is invisible
to the preview while expanding perfectly. The whole `@` family — the
personal-information tags and letter combos, and the three dates — fired and
showed no tooltip at all, with nothing logged beyond a DEBUG line reading
`no prefix match for '@n'`. The symptom looks like a filter or a toggle and is
neither: it is a **missing candidate source**.

**Do not fix it by inserting into the index at registration time.**
`HotstringPrefixWatcherRebuildIndex` builds a fresh `Map()` and swaps it in, so
any such entry is erased by the first live section toggle, personal save or
boot-tail warm-up — the bug then returns intermittently and reads as a race. Do
not add them to `_TriggerSet` either: it feeds `_CheckNearMiss`, which forwards
`Entry.Output` to the analytics log, so that route writes raw IBAN / SSN / card
values into the 14-day keylogger.

The route that works is a **preview provider** —
`HotstringPrefixWatcherRegisterPreviewProvider(Fn)`, consulted by
`_PrefixCollectFromProviders` after the index probe. macOS has had the same
concept (`register_preview_provider`) since the personal-info work; Linux still
has the gap. Two rules the collector enforces rather than each provider: a
provider row whose trigger the index already answered for is DROPPED (the index
row carries the real category, section and priority of the mapping that will
fire), and every provider row is stamped `IsPrivate` unconditionally so the
preview telemetry withholds it — a provider exists to resolve values the driver
holds precisely because they are the user's own.

One more thing the provider must ask, and it is not obvious: **the engine decides
what a tag IS, not the tag itself.** `@dt` spells two valid personal-info letter
aliases and is also the short-date trigger; only the engine's Spec knows which
one will fire. Resolving the tag by its letters would have previewed a name and a
phone number for a trigger that types today's date.

Related: [[feedback-regression-tests]].




### project-a-driver-that-types-also-types-into-its-own-keylogger

_Whether the driver's own keylogger sees an expansion depends on WHICH sender
emitted it — and the answer was measured, not read_

<sub>slug: `project_a_driver_that_types_also_types_into_its_own_keylogger`</sub>

**Measure this before reasoning about it.** Windows expands a hotstring by
SENDING characters, and its keylogger observes keystrokes with a pass-through
`InputHook`. Everyone — three independent reviewers and the author of this entry
— concluded from that pairing that the hook sees every expansion. It does not.
Arming an `InputHook` exactly as `HookDispatcher` arms the driver's own (`"V L0"`,
`KeyOpt("{All}", "N")`) and injecting four characters by each route gives:

| sender | observed |
| --- | --- |
| `SendInput` (plain or `{Text}`) | **0 / 4** |
| `SendEvent` | **4 / 4**, with key codes |

`hotstring_send.ahk` says so itself, in a comment nobody had connected to the
privacy question: `SendInput` is chosen there *because* the hook "processes
SendEvent characters as physical input". Which sender runs is decided by
`hotstring_builder.ahk` from the Spec's `FinalResult` flag — set, and the send
goes through `SendFinalResult` → `SendInput` → unobserved.

The whole `@` personal-info family registers `FinalResult: True`, so **its
expansions never reach the typing row.** Two rounds of fixing were aimed there
before anyone measured. The trigger-log sites, which are direct writes and depend
on no hook at all, were real the whole time.

The general rule: a comment describing a mechanism is not evidence about which
branch of it your code takes. Probing cost one 46-line script and five minutes.

The two-sink structure below is still worth knowing, because `SendNewResult`
(`SendEvent`) is a live path for other categories:

1. the `hotstring` row written by `KL_LogHotstring`, and
2. the `typing` row, whose `text` and `events` columns are
   `Keylogger.buffer_text` / `Keylogger.buffer_events`, filled character by
   character by `KL_Hook_OnChar`.

`KL_LogHotstring` calls `KL_FlushBuffer` **before** writing its own row, so one
call published the plaintext and then the redaction of the same value. A fix
applied only at sink 1 changes nothing an attacker with the log would see.

The trap that makes this survive review: the synthetic branch in
`KL_Hook_OnChar` *looks* like a guard. It sets `meta["s"] := 1` and
`meta["st"]`, and the two lines that persist the CONTENT sit outside it. A tag
answering **where** a character came from was read as an answer to **whether it
may be persisted**. The same shape recurs anywhere a "source" marker sits next
to a persistence call.

Rules that fall out of it, all three drivers:

- Any privacy flag a feature holds must reach the **synthetic-input recorder**,
  not just the feature's own log row — `KL_MarkSynthetic(source, is_private)`,
  Linux `append_synthetic_events(…, is_private)`, macOS `notify_synthetic`.
- The substitution is **length-preserving** (`PersonalInfoRedactForLog`, one
  `PI_MASK_FALLBACK_CHAR` per UTF-16 unit). Every consumer downstream counts
  characters — `net_saved_chars`, one WPM push per character, one event per
  keystroke — so dropping the text would trade a privacy bug for a metrics bug.
- Bracket markers (`[BS]`, `[ENTER]`, the whole `KLHOOK_SPECIAL` set) are
  **exempt**: they carry no content and rewriting them desynchronises the
  walker's deletion accounting. Linux states the same exemption for `[BS]`.
- The privacy latch is released with the **last** held level, never the first —
  `synth_active` is a depth counter precisely because fires overlap, and a public
  fire finishing first must not un-redact an inner private one still typing.

Two sibling sinks the same review turned up, both reachable without the user
doing anything: `HotPath_LogIfSlow` logs at **WARNING**, which is above the
default INFO level, so any profiler detail built from a trigger or a buffer
reaches `<ConfigDir>/autohotkey/logs/` with 14-day retention and no opt-in —
unlike the DEBUG sites, which at least need the level switched on. And after a
star fire the preview watcher takes the engine's buffer verbatim
(`_PrefixBuffer := HSE_Buffer`), so the "buffer" a diagnostic prints is the
resolved value, not the six characters the user typed.

**Severity is not a safeguard until you check the default.** On Windows the
ranking is real — `LoggerError` and `HotPath_LogIfSlow` sit above the default
INFO, so those lines are written with no opt-in, while a `LoggerDebug` needs the
level switched on. On the Lua side there is no such distinction: the shared
logger's default minimum is **10, debug included**. Two lines were printing a
resolved `@`-tag value in full on that assumption — `_shared/lua/dynamic_hotstrings`
`match_buffer` at DEBUG (code BOTH Lua drivers run) and the Linux
`manager.lua` "Dynamic expansion" line at INFO. For `@i★` that is the user's
IBAN, written on every expansion, with nothing enabled. macOS had no equivalent
line; Windows already redacted its own. Linux was strictly worse than a bug
already fixed twice elsewhere — the same shape this file records for the typing
row.

Finally, a redacted value is **not an identifier**. `KL_Roi_OnHotstring` stores
its trigger as a key of `trigger_last_use` and `KL_Roi_HalflifeTick` writes that
key back out, so keying on the redaction merged `@cb★`, `@cc★` and `@ss★` onto
one entry of four bullets. Where a redaction would become a key, skip the keying
and keep the counter.

Related: [[project-the-preview-index-is-file-driven-only]],
[[project-an-enumeration-is-not-a-feature]], [[feedback-regression-tests]].




### project-an-enumeration-is-not-a-feature

_Every hand-written list in this repo has been found short. Derive the list; where
deriving would explode, resolve at use time instead_

<sub>slug: `project_an_enumeration_is_not_a_feature`</sub>

The same defect keeps surfacing under different names, and it is always a list a
human wrote and no one re-checked:

- the Linux packagers copied an enumerated set of directories, and `_generated/`
  was not in it — so every `.deb` and `.rpm` shipped a driver that fell back to a
  two-locale table;
- `install.sh` derived the shared tree by counting `..` steps, which is a fixed
  list of one layout, and could not install its own release tarball;
- `test-linux-shared-path-resolver.cjs` matched one spelling of the bug it
  guarded and reported green over the other;
- the Windows `@`-combos came from thirty-one `CreateHotstringComboAuto` calls
  out of a space of 28 561 at length four. `@npdt` and `@nt` were simply not
  among them: the letters resolved, the values existed, the key did nothing, and
  nothing logged;
- a privacy scan written for this repo used a fixed three-line window after each
  sink and hid four persisted rows whose `"trigger"` key sat on line four.

Two remedies, in order of preference:

1. **Derive the list and record only the judgement.**
   `test-personal-info-log-sinks-are-judged.cjs` walks the driver for every
   logging/persistence call that mentions a trigger, and each site must either
   redact in place or carry a written verdict. A new sink fails the gate the day
   it is added; a verdict that matches no site fails too, so the ledger cannot
   outlive the code. The list is machine-made, the reasoning is human.
2. **Where enumerating would explode, resolve at use time.**
   `HSE_TryPersonalInfoCombo` expands `@<letters>★` by walking the letters when
   the key is pressed, so all 28 561 combinations work at flat memory cost —
   which is also what macOS already did (`resolve_combo`, `personal_info.lua`).
   Pre-registration bought an O(1) lookup and paid for it with a list that could
   only ever be a sample.

The tell that you are looking at one of these: the code path fails **silently and
partially**. Everything about the mechanism works; one member is missing; nothing
reports it. When a user says "X works but Y doesn't" and X and Y differ only in
degree, look for the list before looking for the logic.

**Where the same feature exists three times, ask each driver the same question.**
Chasing the Windows `@`-combo list found three more defects nobody had reported,
each in a different driver, all in the same family:

- Linux had **no** multi-letter combos at all — `if #letter == 1` in its
  registration loop. Not a short list: no list. The two drivers that worked did
  so by resolving at fire time, and Linux was the one still registering.
- Linux never passed `is_private` to `keylogger.record_hotstring`, though its
  static-hotstring path a hundred lines away always had. Every `@`-tag expansion
  wrote its resolved value into the per-character synthetic record.
- macOS's `resolve_combo` **skipped** letters it could not resolve, so `@npz`
  expanded as `@np` and every value landed one form field short. Linux and
  Windows both decline the whole combo; macOS now does too.

The last one is the instructive shape: it changes what gets **typed**, not what
is displayed, so no amount of shared preview corpus could have caught it. A
cross-driver corpus proves the three agree about OUTPUT it can observe; behaviour
it cannot observe still needs the same question asked three times, by hand.

**A `git checkout <file>` to undo a scratch edit discards the whole file's
working-tree state.** Doing that mid-session cost every uncommitted change to
`manager.lua`. Back the file up and `cp` it back; the tests are what proved the
reconstruction was complete, which is a second reason to write them first.

**Migrating a menu row to `_shared`: the recipe.** The count that matters is
`test-menu-rows-outside-renderer.cjs`, and only two things ever lower it —
a `list` provider, and (since 2026-08-06) the declarative `check` / `command`
types. Routing a menu through `ManifestMenu.build` moves nothing, because
`dynamic` hands the id straight back to a driver function that builds the row.

For ONE row with a label, a tick and a behaviour:

1. `_shared/modules/features/manifest.toml` → `type = "check"` (or `"command"`
   for no tick), plus `i18n`, and keep `checked_when` / `disabled_when`.
2. `npm run build:menu`.
3. Each driver deletes its row-builder and registers the behaviour by name:
   Lua as `ctx.commands["id"]` plus `ctx.state_getters`, AutoHotkey as the
   `Commands` / `StateGetters` arguments of `MenuRenderer_Build`.

For a REPEATED row (a catalogue, a slot list, a submenu of N entries): make it
`type = "list"` and have each driver return `{label, action, checked, items,
disabled, separator}` data. Both renderers accept that exact shape.

Two things that will bite:

- **Quote the keys.** `["open_config"] = …`, not `open_config = …`. Every gate
  in this repo resolves "does this driver handle it" by grepping for the quoted
  id, so a bare key reports a working row as unhandled.
- **A migration touches all three drivers or it breaks two of them.** The
  manifest is shared: change a type and the renderer stops looking for the old
  handler everywhere at once. The `check` types were added to
  `_shared/lua/menu/renderer.lua` and `windows/infra/manifest_menu.ahk` in the
  same change for exactly this reason.

Expect tests that pin the OLD shape to fail — a canonical-order list, a
"handler X must exist" guard. Retarget them at the invariant (the row is built
by the shared resolver, from either side) rather than deleting them; the
migration otherwise reads as a regression while the code is in fact more shared.

**`menu_manifest.json` is GENERATED. Never hand-edit it.** Its source is
`_shared/modules/features/manifest.toml`, and `npm run gen` — which `npm run
test:js` also triggers — rebuilds it. A hand-edit therefore survives until the
next suite run and then vanishes, which is worse than failing: the drivers had
already been changed to match the edited JSON, so three menus were left with
declarations that no longer existed and rows that nothing built. The tests
caught it (an empty Debug submenu), but only after a full round of work went to
the wrong file.

Related: `build-domain.cjs` compares every generated output against **HEAD**, so
a legitimate change to a generator SOURCE leaves `npm run gen` red until the
regenerated file is committed. That red is not a defect — check the diff, and
expect it to clear on commit.

**Check the DATA before you check the driver.** The shared action catalogue
declared 79 actions for Linux and the driver answered 40. Of the first eleven
closed, ten needed no code at all: the row carried `emit_ahk_*` and `emit_hs_*`
and simply had no `emit_linux` column, so the generator emitted nothing and the
chord fell through to `Logger.debug("Unknown action")`. Filling one column in
`_shared/modules/actions/actions.toml` wired all ten. A gap that looks like
"this driver is behind" is worth looking for in the shared table first — that is
what a single source is for, and it is also where the cheapest fix lives.

Two things that make this class of gap invisible while it exists:

- **The picker offers whatever is DECLARED.** So the user binds the action, the
  assignment is stored, the chord fires, and nothing happens — no error at bind
  time and none at fire time. `test-action-registry-bijection.cjs` is the gate;
  it now also fails when the count falls BELOW its baseline, because a ratchet
  that only catches a rise lets a closed gap re-open silently.
- **A cascade of `elseif` has no length.** The `open_*` and screenshot handlers
  are tables keyed by action id precisely so a gate can compare their key set
  against the catalogue. Quote the keys (`["open_config"] = …`): every gate in
  this repo resolves "does this driver handle it" by grepping for the quoted id.

On Linux specifically: no single binary takes a screenshot on every desktop, so
each capture action is a cascade — and the **Wayland candidates must come
first**, because under Wayland the X11 tools talk to nothing and exit ZERO. A
cascade ordered the other way reports success and captures nothing, on exactly
the desktops this driver targets.

Related: [[project-a-driver-that-types-also-types-into-its-own-keylogger]],
[[feedback-regression-tests]].


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

**Never** reach for synthetic taps or Off→On re-registration. To syntax-check an edit, see [[feedback_ahk_ui_syntax_validation]] — and never use `/validate`, in any shell or position: it does not validate, it RUNS the script. Related: [[project_suspend_pause_invariant]].

### feedback_ahk_ui_syntax_validation

_Some AHK UI files are outside the headless test runner; how to syntax-check them locally on Windows_

<sub>slug: `feedback_ahk_ui_syntax_validation`</sub>

`run_all.ahk` includes most of `lib/`, `adapters/` and a growing subset of `modules/` + `ui/`, but it deliberately skips the files that register hotkeys or build menus at top level — notably `ui/tray_menu.ahk` and `ui/onboarding/*` (they would block a clean exit). A syntax error in those is caught **only** by CI's `Compile ErgoptiPlus.ahk` step (Ahk2Exe). Check what the runner actually includes before assuming a file is covered; the list drifts.

**How to syntax-check them locally** (two ways, both gotcha-laden):

1. **Ahk2Exe compile** (gold standard, == CI), at `C:\Program Files\AutoHotkey\Compiler\Ahk2Exe.exe`. **Run it from PowerShell, never Git Bash** — MSYS path conversion rewrites `/in` `/out` `/base` into Windows paths (`/in` → `C:/Program Files/Git/in`) and the compile dies with "Unrecognised parameter".
2. **Parse-only harness**: a throwaway `.ahk` with `ExitApp(0)` as its first auto-execute statement, then `#Include` the UI file. AHK parses the whole merged script before running anything, so a syntax error aborts at load while `ExitApp(0)` exits before any included top-level code runs. Launch via `Start-Process -FilePath AutoHotkey64.exe -ArgumentList @("/ErrorStdOut",$script) -Wait -PassThru -RedirectStandardError $err` — a plain `& AutoHotkey64.exe` captures neither exit code nor stderr, because it is a GUI-subsystem app that detaches.

**CORRECTED 2026-07-29 — two claims in this entry were measured FALSE on AutoHotkey 2.0.26.** Both
were re-derived directly; if a future version behaves differently, re-measure before trusting either.

- **`/validate` does NOT validate here, even when it precedes the script path.** The flag is
  silently ignored: the script is parsed, and *if it parses it RUNS*. Measured on the real driver:
  with the parse break present the command returned `exit 2` immediately (looking exactly like a
  working validator); with the break fixed the same command **hung for two minutes and left an
  orphaned `AutoHotkey64.exe` holding the keyboard hook** after the shell wrapper was killed. Never
  point it at the driver.
- **Ahk2Exe does NOT exit 0 on failure.** Measured: syntax error → **exit 17** with
  `<file> (<line>) : ==> <message>` on stdout and no `.exe`; success → exit 0 plus the `.exe`.
  Checking the exit code is sufficient, and checking that the `.exe` appeared is a fine belt-and-braces.

**Never read an exit code through a pipe.** `cmd … | head` makes `$?` report *head's* status. An
audit refuted the real "driver does not start" defect on a `EXIT=0` read this way. Capture first —
`out=$(cmd 2>&1); rc=$?` — then filter.

**CONFIRMED THE HARD WAY 2026-07-29 (second time in one day), plus one new variant.** An audit pass
ran `/ErrorStdOut /validate` over the 58 `ui/` files, twice, and both attempts **launched the driver's
UI files as live scripts** — 58 `AutoHotkey64.exe` processes spawned one after another, killed
manually. Two distinct mechanisms, so guarding against one is not enough:

- **Under Git Bash the flags never reach AHK.** MSYS argument conversion rewrites any `/flag` into a
  Windows path. Observed directly in `Win32_Process.CommandLine`:
  `AutoHotkey64.exe "C:/Program Files/Git/ErrorStdOut" "C:/Program Files/Git/validate" <script>` —
  AHK sees two bogus script arguments and runs `<script>`. Same class as the `Ahk2Exe /in /out` trap
  above; it applies to **every** `/flag` passed to a Windows exe from Git Bash.
- **Under PowerShell the flags arrive correctly and it still runs**, because `/validate` is ignored
  (measured above).

**Cleanup discipline when this happens:** kill by matching the command line, and **exclude your own
PID** — a `Where-Object { $_.CommandLine -match 'my_pattern' }` matches the very command containing
that pattern, so the sweep kills its own shell (observed: three consecutive `exit 255`). Kill the
spawning loop's process first or it keeps launching new children faster than they are reaped, then
assert the only surviving `AutoHotkey64.exe` is the driver.

**The concrete defect this gap shipped (2026-07-29):** `ui/menu/menu_rebuild.ahk` used an unbraced
one-line `try` as an `if` body followed by `else`. **AHK v2's `Try` carries its own optional `Else`
clause**, so the `else` binds to the `try` and the `if`'s `else` is orphaned — `Unexpected "Else"`,
a load-time abort of the whole driver. The 3 499-test suite stayed fully green because `ui/` is not
reachable from `run_all.ahk`. Braces on both bodies are the fix; the class is now gated statically
by `tools/test/test-ahk-v2-syntax-antipatterns.cjs` (runs on every platform, so it does not depend
on AutoHotkey being installed).

**SUPERSEDED 2026-07-30 — there is now a gate, `npm run test:ahk-parse`.** Nobody should hand-roll
this again. `tools/test/test-ahk-parse-coverage.cjs` compiles `ErgoptiPlus.ahk` with Ahk2Exe through
Node's `spawnSync` (no shell, so the Git Bash `/flag` rewrite cannot apply) and reports the failing
file and line. Measured: a deliberate break in `ui/tray_menu.ahk` → `exit 17` naming
`ui\tray_menu.ahk (130) : ==> Missing "}"`. Wired into `verify-change` as the `ahk-parse` gate for
every non-test `.ahk` edit, and into `npm run test:js`.

Two things that cost an hour before that landed, both worth keeping:

- **The `ExitApp` parse-only harness described above is NOT safe on the real driver.** `ExitApp`
  fires the entry point's `OnExit` handlers, so driver teardown code runs against uninitialised
  state; the probe hung and left an orphaned process. It is fine for a single `ui/` file, which is
  what it was written for — never for `ErgoptiPlus.ahk`. Ahk2Exe writes an `.exe` and executes
  nothing, which is the only reason it is the right tool here.
- **I re-fell into the "never read an exit code through a pipe" trap two paragraphs above**, with
  `Ahk2Exe … | head -5`, and concluded from `exit=0` that Ahk2Exe could not tell a valid script from
  a broken one. It can. Reading that rule is not the same as applying it: capture first, filter after.

The gate self-validates before trusting its own verdict — it compiles a known-good and a known-bad
fixture and reports SKIPPED, never OK, unless the compiler separates them. That is not defensive
padding: invoked a different way on this same machine, Ahk2Exe returned `exit 52` on *every* input.
A gate wired straight to that is a permanent false red, and one that read 52 as "no syntax error"
would be a permanent false green.

The headless runner writes its TAP report to `%TEMP%\ergopti_test_results.txt`, NOT stdout — read
that file for pass/fail. See [[feedback_ahk_source_encoding]],
[[project_audit_evidence_must_be_reproducible]].

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

**2026-07-29 — the sink's purpose was defeated, and the mechanism generalises.** Measured composition
of `ErgoptiPlus_errors_2026-07-29.log` (790 KB, 8 775 lines): **85.5 % one background timer's normal
cost, 9.6 % a probe loop warning about itself, 4.6 % other hot-path lines — 0.3 % (25 lines) actual
signal.** A genuine G2 defect (one tray-menu row rendering its raw id) sat in that file for a full day
looking like 1 line among 282 identical ones. Two independent causes, one rule each:

- **A hot-path profiler threshold is calibrated per population, not globally.**
  `_HOTPATH_SLOW_MS := 5.0` is right for per-keystroke work, where 5 ms is alarming. Applied to a
  2 Hz cross-process COM round trip whose *normal* cost is ~14 ms, it fires on ~80 % of ticks and the
  tripwire stops meaning anything. When instrumenting a **background repeating** segment, give it its
  own threshold set above its measured normal cost, and record that measurement in a comment.
- **An accessor that warns must not be reused as a speculative probe.** `t()` warns on a total miss
  because a miss on the display path *is* a defect. `manifest_descriptions.ahk`'s candidate cascade
  calls the same `t()` for candidates it fully expects to miss, so each label emits several warnings
  asserting "the raw key is being displayed to the user" when it is not. Split the accessor: a silent
  lookup for probes, the warning one for terminal display.

Diagnostic reflex: before reading this file's contents, measure its **composition**
(`awk` by message class). A sink that is >90 % one message is telling you about the instrument, not
the driver.

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

Related, and the failure mode this entry's own "a gate that cannot run is worse than one that fails"
predicts: [[project_gate_scripts_must_be_wired]].

### project-audit-ahk-2026-07-30-pass

_Sixth adversarial AHK pass: 14 findings, all fixed and committed with regression tests. The refuted list, the coverage gaps, and the two measurements worth keeping._

<sub>slug: `project_audit_ahk_2026_07_30_pass`</sub>

Seven adversarial lenses plus an independent manual pass, each finding
refuted-by-default before being reported, then every survivor fixed one commit at
a time. The report itself was deleted once the fixes landed — a finding list that
outlives its fixes reads as a backlog and gets re-worked. What is worth keeping:

**The dominant class, again: an invariant applied per site.** Four of the fourteen
were siblings of an already-fixed defect, and in each case the shipped guard test
was scoped to the directory of the original fix and structurally blind to the rest:

- the pause-preserving reload existed only in `ui/menu/`, and 19 other reachable
  `Reload` sites — including the tray's own « Recharger » item — dropped the pause;
- the ext-pack preview was unified with the engine on the FILE SET but not on the
  GRAMMAR (single-bracket headers and bare `key = "value"` entries expanded and
  could never be previewed) nor on the PRIORITY (previewed at COMMON, fired at
  PACKAGE, so a colliding pack previewed as the loser and fired as the winner);
- the hotstrings-config "reset all" existed twice and only the native twin
  flushed the debounced write and republished;
- a 3-key sample gate for menu labels missed its sibling, leaving one tray row
  rendering `i_e_acute` in all 21 languages.

Reflex: when a fix lands, ask what the guarantee's SCOPE is, then make the test
enumerate that scope. `test_menu_reload_preserves_suspend` and
`test-manifest-menu-labels-resolve` are the shapes to copy.

**REFUTED — do not re-raise** (in addition to the older lists):

- **The preview wiping its buffer on a word-boundary character** is DELIBERATE and
  documented in `_PrefixAppendTypedChar`: `HSE_Buffer` keeps the terminator
  because a trigger may contain one as a non-final character, while the preview
  scopes to the current word and the post-fire resync (`_PrefixBuffer := HSE_Buffer`)
  covers the `l'` + `ia` case. Needs a concrete failing trigger before touching.
- **`_HSE_SourcePriority`'s `ext.` branch is unreachable from the loader** —
  `LoadExtTomlFile` sets the package priority directly and never consults the
  cascade. The branch stays because `test-priority-parity` pins it to
  `priority.json` and the macOS registry. Not dead code to delete unilaterally.
- **A per-pack delay/priority/colour override is honoured by NEITHER side.** The
  config window writes it under `ext.<extId>`; the engine ignores the cascade for
  packs entirely. Exposed by the priority fix, deliberately left open — it is a
  missing feature, not a fidelity bug, and the tooltip now matches the engine.
- **`MENU/InitSub: flat hotstring submenus` is not a code regression.** It swung
  47 ms → 406 ms with ZERO commits touching the driver in between, and spans
  31–1672 ms across boots sharing a commit. That is an I/O or scheduling
  signature. Per-category `BootProfile_Mark`s were added so the next boot log can
  attribute it; do not optimise it from the aggregate number.

**Two measurements worth keeping** (re-derive before relying on them):

- `OnChar`'s own cost is **mean 1.0 ms, max 4.7 ms exclusive**. The historical
  701 ms figures were re-entrant work billed to the host segment by the raw wall
  clock. Never quote a raw `OnChar` number as its cost again — read the
  `[excl … , nested …]` breakdown the profiler now emits.
- The `UIA.SelectionPoll` probe reached **301.0 ms**, past Windows'
  ~300 ms `LowLevelHooksTimeout`, where the keystroke is delivered WITHOUT the
  hook's verdict. Per-call timeout clamps cannot bound a five-hop COM sequence;
  that is why the segment now has its own deadline.

**Coverage gaps left open — silence here would read as covered:**
`modules/keylogger/*` (24 files, the largest unaudited subsystem) was not
examined; 19 of 22 `adapters/` were not read; the `ui/` editor state machines were
only sampled; `lib/tap_hold/tap_hold_writer.ahk` remains unread for a second pass
running; and `tests/e2e/` + `tests/startup/` were never searched when looking for
contradicting tests. Loop-until-dry was NOT reached — one discovery wave ran.

Related: [[project_ahk_invariant_incomplete_application]],
[[project_gate_scripts_must_be_wired]], [[feedback_ahk_ui_syntax_validation]],
[[errors_only_log_sink]], [[project_audit_ahk_2026_07_21_adversarial]].

### project-plan-entries-go-stale-faster-than-code

_Eighteen TODO measurements were wrong across two sessions — re-measure before starting, and write the correction back_

<sub>slug: `project_plan_entries_go_stale_faster_than_code`</sub>

`TODO.md` warned that "roughly one entry in six turns out to be stale". Measured
over one long session on 2026-08-03, it was closer to **one in two**, and the
errors were not small — they inverted the work.

**What was wrong, and how:**

| Entry said | Actually |
| --- | --- |
| §2 perf: "mostly unmeasured", gated behind sub-segmenting `_TooltipPresentStack` | That prerequisite was **done**, with five marks. So were the render counter, the resolve-exit counters, `RemapEmit`, `UIA.SelectionPoll`, and the five pre-logger boot stamps |
| Lot 8.5: "wire the 1 483 lines of shared JS as an oracle" | Six modules, five already runtime-mirrored **and** oracles. One (`draw_calls.js`) was neither |
| Lot 8.4: tap-hold vocabularies pair by NAME; `right_ctrl` has no macOS counterpart | They pair by **physical position**. `right_ctrl` ↔ `right_option` exists, and its "drift" was one action under two spellings. Of five divergences, exactly one is real |
| Lot 6(4): 18 of 73 remap actions have locale keys | True, and **zero** have a key without a registry row — the sets line up exactly, which the entry did not say |
| Lot 6(2), 6(6) | Named things that do not exist, or conflated two subjects |
| Lot 9 port row: "one JS gate saves ~1 000 lines" | Would have swapped a runtime check for a textual one. Only the cross-tree half was a gain |
| Lot 7(2): adoption blocked on writing a corpus | Also blocked on something unrecorded: **the shared core had no dedup at all**, so adopting it would have silently removed flood suppression from a driver that had it |

**A second session, 2026-08-04, and the rate did not improve.** Seven more, and
this time the pattern is sharper: **every one of them was the plan describing the
code rather than the code.**

| Entry said | Actually |
| --- | --- |
| §2: macOS cannot adopt the shared matcher without either converting its buffer per keystroke or giving the core a second representation | Neither. Both predicates consume exactly the trigger-length tail and the one codepoint in front of it — **the buffer was never an input to the decision**, only where those two strings came from. The slice stays with the driver, the decision is shared |
| Four canonical features are "absent from every driver — the work is extraction, not a README" | **Two of the four were the list mis-describing the drivers.** `metrics` is `modules/keylogger`, shared by all three; `download` is `ui/download_window`, shipped by two, filed under `modules/` against the file's own tree rule |
| Lower the menu-row ratchet by migrating the three biggest blocks | Would have moved it by **zero**. Routing a menu through the renderer does not move the number — a `dynamic` handler appends its rows in the driver file. Three menus already do it and are still counted |
| The three biggest blocks are 36 / 32 / 26 | A **three-way tie at 26**. The third was chosen and then presented as if the data had chosen it |
| One shared reason on the 34 hs-only gesture entries: 138 → 105 for 21 strings | `platforms = ["hs"]` excludes **Linux** too, and Linux ships the gestures module, its menu and its defaults. That half of the reason would read "not coded yet" — the one thing the model reason forbids — in twenty-one languages |
| `platform/remap` is the shared home `layout` was missing | It is the remap **engine** — tap-holds on Windows, Karabiner on macOS, the kanata daemon on Linux. A different capability that happens to sit next to this one on one driver |
| The macOS renderer's lines 93-559 move to `_shared` verbatim | Line 237 is `if not is_for_hs(item)`. Followed literally, Linux would render the **hs** projection and drop the exact three rows the parity gate exists to expose |

**How to apply:**

- **Re-measure every entry before starting it.** Half the value of this session
  was measurements that turned an "N-day refactor" into "already done" or into "a
  product decision, not a refactor".
- **Write the correction back into the entry**, with the number. A stale entry
  costs the next person the same investigation; a corrected one costs nothing.
- **An entry's cost estimate is the least reliable part of it.** Lot 6(4)'s
  "55 rows" is 55 rows *plus 55 handlers*, because the bijection gate requires a
  handler on every platform a row is declared for — which changes it from a data
  edit into a product decision about whether a swipe may trigger `layer` hold.
- **Before treating an absence as work, open the three drivers and find where
  the capability lives.** It has been somewhere every single time — six entries
  across two sessions, and the correction was always a rename in the list rather
  than a move in the code.
- **Before treating a metric as work, ask what mechanically moves it.** Two of
  the seven above were plans to change a lot of code for a number that would not
  have moved. The answer belongs in the gate's header, next to the number, where
  the next person reads it — not in the plan, which they will not.

Related: [[project-gate-scripts-must-be-wired]],
[[project-generated-trees-are-not-reducible]],
[[project-a-second-vocabulary-fails-silently]].




### project-a-second-vocabulary-fails-silently

_When two modules name the same data differently, nothing raises — the receiver just sees absent fields_

<sub>slug: `project_a_second_vocabulary_fails_silently`</sub>

The Linux tray menu rendered top-level rows only. Every submenu was discarded,
every disabled row rendered clickable, every separator rendered as an ordinary
item labelled "-". Nothing raised, nothing logged, and two tests covering the
exact path passed throughout — because they asserted `setMenu` "does not crash",
and it did not.

The cause was three vocabularies for one tree:

| | submenu | unavailable | separator |
| --- | --- | --- | --- |
| the menu builders (both Lua drivers) | `menu` | `disabled = true` | a row titled `"-"` |
| `_shared/lua/tray/protocol.lua` | `items` | `enabled = false` | `separator = true` |
| `_shared/core/ports/TrayMenu.spec.js` | `children` | `enabled = false` | `separator = true` |

Not one key matched between the producer and the serialiser. **Nothing in any
driver had ever written the serialiser's spelling** — it shared that vocabulary
with its own tests and nobody else.

**Why it stayed invisible for so long.** A vocabulary mismatch does not throw:
the receiver reads a field, finds `nil`, and takes the default branch. `enabled`
defaulted to true, so a disabled row rendered enabled. `items` was absent, so a
parent rendered as a leaf. Every failure mode is *plausible output*, which is
exactly what a "does not crash" assertion cannot distinguish from correct output.

There was a second consequence nobody would have predicted: the callback walk
recursed on `menu` and the serialiser on `items`, both numbering children
`id * 1000 + i`. So a submenu's callbacks were registered under ids the rendered
menu never contained.

**How to apply:**

- **Delete the second spelling; do not write a translator.** Both were available
  here. The translator leaves two shapes to keep in step and a third place for
  them to drift; deleting the unused one leaves nothing to maintain. Choose the
  vocabulary the *callers* already produce, not the one the receiver invented.
- **A port spec marked "informative — not validated at runtime" is the document a
  new driver is written from.** That is where a wrong shape costs most, not
  least. This one carried a third spelling that no implementation had ever used.
- **"Does not crash" is not a test of a serialiser.** Assert the output: that a
  child label reaches the XML, that a disabled row says `enabled="false"`, that a
  separator is a separator node. Then pin the abandoned spellings as dead, so a
  half-revert that reintroduces one fails instead of going quiet again.
- **Suspect this whenever two modules exchange records and only one of them
  raises.** The tell is a receiver full of defaults: `x ~= false`, `or {}`,
  `type(y) == "table" and … or nil`. Each of those turns a name mismatch into a
  reasonable-looking value.

Related: [[project-plan-entries-go-stale-faster-than-code]],
[[feedback-regression-tests]].




### project-instrumentation-absence-is-invisible

_A missing test fails; a missing profiler segment produces a clean-looking profile — so the segments are inventoried, not trusted_

<sub>slug: `project_instrumentation_absence_is_invisible`</sub>

Instrumentation is the one kind of code whose absence produces no symptom. A
deleted assertion turns a suite red. A deleted `HotPath_LogIfSlow` turns a hot
path silent, and silence reads as "fast".

`tools/test/test-hotpath-segments-declared.cjs` inventories all of it: **20
HotPath segments and 5 pre-logger boot stamps**, each with a line saying what hot
path it covers. A deleted segment fails with the reason it was added.

**What each covers**, keystroke path first: `Hook.KeyDown` / `Hook.KeyUp` (the
first stage of every keystroke — two tap-hold trackers plus the whole
`EVT_KB_DOWN` fan-out, inside the hook callback), `RemapEmit`, `OnChar`,
`HSE.FeedChar`, `HSE.Dispatch`, `LLM.OnChar`, `KL.Ingest`; then render:
`Tooltip.Build`, `Tooltip.ResolvePos`, `Tooltip.Present` (sub-attributed by
`HotPath_BreakdownMark` into clamp / prepare / corners / border / reveal),
`Tooltip.DequeuePresent`, `Tooltip.LlmPresent`, `Tooltip.BorderPixelLoop`; then
the user-triggered and COM paths: `Gesture.Invoke` (the single choke point all
three dispatchers share, so one segment covers every action a gesture, a shortcut
slot or a tap-hold can fire — and it times the throwing exit too, because an
action that takes a second to fail costs exactly what one that takes a second to
succeed does), `Config.TomlWrite` (a full read-modify-write run from a menu
callback, so a slow save shows up as a frozen tray menu), `Updater.Poll`
(`WaitForResponse(0)` on a COM object every tick — and BOTH exits are timed,
since the re-arming one runs on every tick but the last), `Webview.Eval`
(`ExecuteScriptAsync` is async in name only; the COM marshalling is not); then
idle: `UIA.SelectionPoll`, `Metrics.FocusRefresh`.

**How to read the profile:** every segment logs only above the 5 ms floor, so an
ordinary keystroke prints nothing. `Tooltip.Present` was the dominant offender
(~12.9 ms mean) and its five sub-steps all sit BELOW the floor individually —
which is why the breakdown exists: the parent's number never said which moved.
`Metrics.FocusRefresh` is the one to suspect for idle cost: `WinGetTitle` sends a
message to the foreground window and a Not Responding window makes it wait out
the timeout, up to 20×/s.

**How to apply:**

- Adding a hot path means adding its segment AND its inventory line.
- Never delete a segment to "clean up" — it is the only evidence that path is
  fast.




### project-generated-trees-are-not-reducible

_The `_generated/` trees were audited on 2026-08-03: 21 artefacts, 200.3 KB, zero orphans. Do not re-open the question_

<sub>slug: `project_generated_trees_are_not_reducible`</sub>

"Are the `_generated/` folders still earning their committed size?" is a natural
question and it has now been answered with a full scan, so the next person does
not have to redo it.

**Measured:** all 21 committed artefacts across `windows/`, `macos/` and
`linux/_generated/` total **200.3 KB**. Every single one has at least one runtime
reader outside `_generated/`, at least one generator under `tools/`, and
drift-guard coverage (`build-domain.cjs` compares the working tree against the
index). **There are no orphans and nothing to delete.**

**67 % of the mass is three files** — `macos/_generated/features_manifest.lua`
(54.9 KB), `windows/_generated/features_manifest.ahk` (54.8 KB),
`linux/_generated/features_manifest.lua` (24 KB).

**How to apply:**

- Do not propose replacing the feature manifests with a runtime TOML read. It
  puts a ~130 KB parse back on every driver's boot path to save 134 KB of
  committed text, which is exactly the trade ADR-002 decided against. Net
  negative, and it has now been re-proposed and re-rejected twice.
- If you add a `_generated/` artefact, it needs the same three things as the
  others: a runtime reader, a generator in the registry, and drift-guard
  coverage. Two out of three is a file that rots silently.
- To re-run the scan: for each file under a driver's `_generated/`, search that
  driver's tree and `tools/` for its basename. A file whose only hits are inside
  `_generated/` is an orphan.

Related: [[project-gate-scripts-must-be-wired]].




### project-gate-scripts-must-be-wired

_A `tools/test/` gate script is only a gate once `run-js-suite.cjs` invokes it; four exist that nothing runs, one of them documented as a "CI gate"_

<sub>slug: `project_gate_scripts_must_be_wired`</sub>

`tools/test/` holds 73 `test-*.{js,cjs}` scripts. `run-js-suite.cjs` — the umbrella CI runs via
`npm run test:js` — references **64**. Of the nine unreferenced, five are covered another way (their
own CI step, or an equivalent inline check). **Four are invoked by nothing at all:**
`test-feature-read-sites.js`, `test-config-schema.cjs`, `test-metrics-heatmap-translation.cjs`,
`test-mutation-targets.cjs` (`test:mutation` runs `stryker run`, not this script). The last two have no
npm script either.

**Why it matters:** `test-feature-read-sites.js` exists to kill the `UnsetItemError` crash class — a
`Features["x"]["y"]` read at a path the manifest does not back. It validates 261 literal read sites,
five of them inside `#HotIf` expressions where the throw lands *in the hotkey evaluator on the
keystroke path*. And `_shared/modules/features/README.md` documents it as "CI gate asserting every
`Features[…]` call resolves against the manifest" — the doc asserts a guarantee that does not hold.
All four pass when run by hand, so a maintainer spot-checking them sees green; nothing anywhere
reports that CI skipped them. This is the purest false green in the repo: not a test that cannot
fail, a test that never runs.

**How to apply:**

- Adding a gate script is two steps, never one: write it **and** add it to `run-js-suite.cjs`'s check
  list. An npm alias is for local repro, not for coverage.
- Do not trust a README or `docs/TESTING.md` claim that something "is a CI gate" — grep
  `run-js-suite.cjs` and `.github/workflows/*.yml` for the script name. Documentation drifts; the
  invocation list is the truth.

**Update 2026-08-03 — it recurred, and it is an assertion now.** The advice above
was right and was not enough: an instruction nobody can check is a habit, and
habits lapse. Running the mise-en-commun audit found **three more** dark gates —
`test-port-compliance.cjs`, `test-priority-parity.cjs`, `test-manifest-parity.cjs`
— each appearing exactly once outside its own file, on its `package.json` line.
Port compliance is the freshness gate for the whole port layer: it re-projects
`contracts.json` from the 21 spec files and checks every AutoHotkey `ADAPTER_*`
map against it. All three passed, which is precisely why nobody noticed.

`tools/test/test-npm-aliases-match-the-suite.cjs` now asserts the direction that
matters: **no npm alias may name a gate the suite does not run.** The reverse was
measured and deliberately left as a ratchet — 78 of the 136 suite gates have no
alias, so requiring one would mean 78 lines of `package.json` mirroring the
suite. Adding a gate with an alias is free; adding one without makes the number
worse on purpose.

The rule to apply is unchanged and now enforced: **write the gate, add it to
`run-js-suite.cjs`, and give it an npm alias.** If you only do two of the three,
the gate tells you which one you skipped.
- The durable guard is a meta-check that enumerates `tools/test/test-*` and asserts each is either in
  `run-js-suite.cjs` or in an explicit allow-list whose entries name the CI step that runs them —
  and that check must be wired into `run-js-suite.cjs` itself so it cannot become its own victim.

Related: [[feedback_local_gate_mirrors_ci]], [[feedback_regression_tests]],
[[project_ahk_invariant_incomplete_application]].

### feedback-ahk-suite-needs-temp-space

_A near-full `%TEMP%` volume makes the AHK runner report assertion failures that do not reproduce; check free space before believing a red run_

<sub>slug: `feedback_ahk_suite_needs_temp_space`</sub>

The runner writes its TAP output and its intermediates under `%TEMP%`. On 2026-07-29 the suite was run with the `%TEMP%` volume at **0 bytes free** and reported **4 failures**. Re-running the same tree with `%TEMP%` pointed at a volume with space reported **2**, and those two were genuine — a test and its fix disagreeing. The other two never reproduced.

What makes this expensive is the shape of the false failures: they arrive as ordinary named assertion failures, not as an I/O error, a write exception, or a runner abort. There is nothing in the output that says "the disk is full". So they read as real defects and get debugged as real defects.

**Why:** a red run is normally trustworthy, so the instinct is to go straight to the named test. Here the failing test names were unrelated to any recent change, which is the only tell — and it is a weak one, because an audit pass touching many modules makes unrelated failures look plausible.

**How to apply:**

- Before debugging a red AHK run, check free space on the `%TEMP%` volume. A run that reports failures in tests nothing recent touched is the signature.
- To run the suite without consuming a nearly-full system drive, point `%TEMP%`/`%TMP%` at another volume for that process only:

```powershell
$env:TEMP = "D:\ergopti_build_tmp"; $env:TMP = $env:TEMP
AutoHotkey64.exe static/ergopti_plus/windows/tests/run_all.ahk
```

- Confirm a fix against a run with space available. Two of the four failures above would otherwise have been "fixed" by changing code that was never broken.
- Same family as [[feedback_local_gate_mirrors_ci]]: a gate that cannot run properly is worse than one that fails, because its output still looks like a verdict.

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
- Windows driver: `t(key)` from `static/ergopti_plus/windows/infra/i18n.ahk`. macOS driver: `t(key)` from `static/ergopti_plus/macos/infra/i18n.lua` (+ `lib/locale.lua`).
- A new key goes into **all 21** files at once. Machine translation is an acceptable first pass; a missing key never is. The fallback chain (active→EN→FR) exists as a safety net, not a licence.
- Internal logs and developer comments stay English per CLAUDE.md — this rule covers user-visible text only.

Parity is enforced in CI against the canonical `en.json` — see [[project_locale_parity_test]].

### project-ahk-loop-capture-copy-freezes-nothing

_Copying a loop variable into another outer local does NOT freeze it for a closure — every closure shares that one variable and sees the last iteration's value. Use `.Bind()`_

<sub>slug: `project_ahk_loop_capture_copy_freezes_nothing`</sub>

The trap is well known for lambdas; the trap in the *attempted fix* is not.
`for Vec in Vectors { VidCopy := VecId; _T() { … VidCopy … }; Test(name, _T) }`
looks like it snapshots per iteration. It does not: `VidCopy` is one variable in
the enclosing function, every registered closure closes over the same slot, and
they all run **after** the loop has finished — so they all read the final value.

**Why it survives review, and how it presents:** the suite is green. Found
2026-07-31 in `tests/meta/test_corpus_security_keylogger.ahk`, where six
per-vector tests had shared one binding for however long: all six asserted the
same expected value, so reading the last vector's data gave the right answer
every time. It surfaced only when a seventh vector with a *different* expected
shape joined them — `Item has no value`, because SEC-008's payload was being
read through SEC-007's test.

**How to apply:**

- Register the callback with `.Bind(args…)`: `Test(name, _Check.Bind(VecId, Vec["expected"]))`.
  Bind evaluates its arguments at registration and stores them per callable —
  that is the only per-iteration snapshot AHK v2 gives you.
- Take everything the assertion needs as **parameters** of a top-level named
  function. A closure that reads any enclosing local is suspect by construction.
- Suspect any per-item test loop whose items all assert the SAME value: it
  cannot tell a correct binding from a broken one. Give one item a different
  expectation and re-run.

Related: [[feedback_regression_tests]], [[project_false_green_tests]].

### project-ahk-settimer-reenters-during-file-io

_AHK pumps messages during blocking file I/O, so a one-shot SetTimer a routine schedules can dispatch INSIDE that routine — any function that both does file I/O and schedules its own next tick needs a re-entrancy flag_

<sub>slug: `project_ahk_settimer_reenters_during_file_io`</sub>

Found 2026-07-31 in `KL_Mig_Slice` (the keylogger at-rest migration). The slice
reads and writes the ledger, and schedules `KL_Mig_Tick` as a one-shot. AHK's
message pump runs during that I/O, so the tick can dispatch **while a slice is
still on the stack**. The inner slice reached the end of the pass, called
`_KL_Mig_Release` — which sets `writeFh` back to `""` — and returned into the
outer slice, whose very next statement was `KLMigration.writeFh.Write(...)`.

**How it presents:** an intermittent red that passes on every re-run. Here it was
`This value of type "String" has no method named "Write"`, twice in one session,
green on the immediately following run each time. **A test that fails once and
passes on retry is a concurrency bug until proven otherwise** — do not write it
off as a stale handle or a temp-dir clash without reading the scheduling.

**How to apply:**

- Any function that does blocking I/O **and** arms a timer that re-enters it
  needs a guard flag, not just a state check: `active` was still true, so the
  usual `if (!active) return` did nothing.
- Split the body out so the `try/finally` around the flag covers **every** exit
  path — these routines are full of early returns for end-of-pass and abort.
- The re-entrant call must **yield** (return "still alive"), not abort the pass:
  the slice already in flight schedules the next tick, so returning false would
  stall the migration.
- Drive the re-entry **deterministically** in the test — raise the flag by hand
  and call in — rather than waiting for the scheduler to reproduce it.

Related: [[project_hs_timer_callback_errors_invisible]] (the macOS twin, where
the swallowed error is the symptom rather than the corrupted state).

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
- The `/validate`-executes-the-script confusion is settled in [[feedback_ahk_ui_syntax_validation]] — the flag NEVER validates, in any position or shell, and the script runs. (An earlier note here claimed position mattered; it was measured against an already-broken file, which exits 2 and looks exactly like a working validator.)

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

La config est unifiee sous `_shared/modules/features/manifest.toml` (snake_case), lue par `windows/infra/manifest_reader.ahk` / `macos/infra/manifest_reader.lua`. `ErgoptiPlus.ahk` construit `Features` via `ManifestBuildFeaturesMap()` ; les gates maitres vivent dans `infra/master_gates.ahk` (`CategoryEnabled`, separe des `.enabled` par feature, pour qu'un clic sur le maitre ne detruise pas les choix individuels). Le mapping historique v1→v2 est archive dans `_shared/modules/features/_migration_v1_to_v2.md`. Tous les helpers de miroir (`MirrorV1ToV2_*`, `lib/v1_v2_mirror.ahk`) ont ete supprimes au cut-over — ne pas les rechercher.

**Les silos `ahk.` / `hs.` ont ete dissous le 2026-08-02** (Lot 4). Une feature vit a son chemin semantique (`layout.ergopti_base`, jamais `ahk.layout.ergopti_base`) ; quels drivers l'implementent est le champ `platforms`, une valeur par defaut divergente est `default_per_platform`. Toute la machinerie de traduction a disparu avec eux : le strip de prefixe du loader TOML, le saut silencieux des sections `[hs.*]`, `ManifestResolveFeatureSection`, la paire WalkParts/Offset du locator. **Ne pas les reintroduire** — deux orthographes pour une section, c'est un `config.toml` qui applique les deux dans l'ordre du fichier et ou la derniere ecrase la premiere sans rien dire. `test-feature-namespace-ratchet.cjs` l'assere a zero.

**GOTCHA — AHK v2 execute les initialiseurs `global`/`static` AVANT le corps auto-exec.** Ordre verifie par sonde : `global X := f()` → `class.static := g()` → 1re instruction auto-exec → appel de fonction explicite. Un consommateur ne peut donc PAS sourcer une valeur depuis un reader de TOML partage dans son propre initialiseur `global` — le reader n'a pas encore tourne. **Pattern impose : declarer la constante a une sentinelle (`0` / `""`), puis un loader de reassignation** (`TapHoldsLoadTimings`, `KeyloggerWalkerLoadTimings`, `HotstringsConfigLoadSharedDefaults`) appele dans le corps auto-exec. Corollaire `#Include` : `platform/remap/constants.ahk` est inclus TOT dans `ErgoptiPlus.ahk` (l.264-273) car un `#Include` a sa place naturelle re-ecraserait avec les sentinelles les valeurs que `boot.ahk` vient de charger ; `#Include` dedoublonne par chemin, donc l'inclusion tardive est un no-op. Meme classe que le precedent `DYN_HOTSTRINGS_DEFAULT_DELAY`.

**GOTCHA — le garde de purete macOS compte `hs.` dans les COMMENTAIRES et les litteraux de chaine.** `tests/meta/test_port_adapter_coverage.lua` compte les lignes matchant `hs%.` dans `macos/{modules,lib}` contre `LUA_HS_BASELINE`. Une docstring qui cite `hs.timer.doAfter`, ou meme `Paths.shared(` (qui contient litteralement `hs.s`) comptent comme des appels OS. Le commentaire du baseline documente cette classe de faux positifs — **relire ce commentaire avant de re-ancrer** : la cible reelle est zero appel OS, pas zero occurrence. Corollaire : `macos/infra/timings.lua` doit rester pur de tout `hs.`, meme en commentaire.

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

**Consommateurs :** AHK `MenuManifest_LoadDebugMenu()` (`windows/infra/menu_manifest.ahk`, itere dans `ui/menu/menu_init.ahk`) ; Lua `load_debug_menu()` (`macos/ui/menu/builder.lua`).

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

### project-typing-order-and-atomicity

_Qui possede le terminateur, et pourquoi une expansion doit etre atomique — les trois defauts de frappe de juillet 2026 et leur portee par driver_

<sub>slug: `project_typing_order_and_atomicity`</sub>

Trois symptomes signales par l'utilisateur (« Entree part avant l'autocorrection », « pex★ donne pexar exemple », « des touches sont avalees ») remontent a **deux** proprietes que seul le driver Windows possedait deja.

**1. Ordre : le terminateur ne doit partir qu'apres le remplacement.** Sur macOS le tap consomme la touche terminatrice (pour effacer declencheur + terminateur ensemble) puis la re-emet. Elle etait re-emise *en ligne*, juste apres le texte, en supposant qu'un evenement clavier brut poste apres une injection de texte est delivre apres ce texte. **C'est faux** : le remplacement voyage par le pipeline d'entree texte (evenement unicode, ou une lecture du presse-papier que la cible planifie elle-meme) tandis que Entree et Tab voyagent comme evenements bruts que beaucoup d'hotes traitent a l'arrivee. Rien n'ordonnait les deux. Correctif : `modules/keymap/terminator_replay.lua` **retient** le terminateur jusqu'a ce que le remplacement ait provablement atterri — les compteurs `expected_synthetic_*` que le driver tient deja pour ignorer son propre echo sont la preuve — avec un chien de garde borne, car **tard est rattrapable, perdu ne l'est pas**.

**Corollaire non evident : `emit_text`/`emit_tokens` doivent annoncer une barriere meme pour un collage EN LIGNE.** L'ancien code ne posait la barriere que pour un collage *differe*, au motif que « Cmd+V est deja poste et l'ordre de post est preserve ». Il l'est — mais **le texte colle n'est pas un de nos evenements** : c'est la cible qui le produit, plus tard, quand elle lit le presse-papier. Toute frappe postee juste derriere le Cmd+V arrive donc *devant* le texte qu'elle est censee suivre.

**2. Atomicite : rien ne doit pouvoir s'intercaler dans une expansion.** Windows emet **une seule** rafale `SendInput` (`Burst := BackSpaceSeq . ReplacementPart . EndCharPart`, `hotstring_dispatch.ahk`) sous `Critical`. C'est ce qui rend impossible qu'une touche physique se glisse au milieu (« outpubct », « Cha[lettre]tGPT ») ou qu'un backspace se perde. L'ancien code y envoyait BackSpace, Replacement et EndChar en trois `SendInput` separes — et ces intervalles etaient precisement la source de corruption. **Ne jamais rescinder cette rafale.** Garde : `windows/tests/meta/test_expansion_burst_atomic.ahk`.

**3. Provenance, jamais une fenetre temporelle.** macOS classait comme « notre propre echo » toute frappe arrivee moins de 20 ms apres la precedente (`elseif dt < 0.02`). La vitesse de frappe n'est pas une preuve de provenance : le caractere restait a l'ecran mais n'entrait plus dans le buffer, donc l'expansion suivante dimensionnait ses backspaces sur un buffer plus court que la ligne et **effacait le texte de l'utilisateur**. Windows avait deja fait exactement cette migration (fenetre de 60 ms → filtre `I1` par provenance, cf. [[project_hotstring_engine_internals]]) ; macOS utilise desormais le test de PID source qu'il avait deja sous la main deux branches plus haut.

**4. Un tap mort est une panne totale et silencieuse.** macOS desactive un event tap dont le callback depasse le budget systeme. Rien dans le driver ne peut s'en apercevoir : **un tap mort ne delivre aucun evenement avec quoi s'en apercevoir**, donc le seul detecteur est un chien de garde par sondage — et **son intervalle EST la duree de la panne**. Il etait a 5 s. Pire, le reveil restaurait la plomberie sans la verite : `CoreState.buffer` decrivait encore la ligne d'avant la panne, et l'expansion suivante effacait par-dessus le texte reellement tape (symptome maison : « hs★ » → « hsammerspoon »). Toute reprise de tap doit donc **invalider le contexte observe** (`invalidate_observed_context`), et les **deux** chemins de reprise le doivent — le gestionnaire d'erreur re-arme le tap si vite que le chien de garde ne le voit jamais tombe.

**Portee reelle par driver — a ne pas surestimer.** Le point 1 n'est reglable que par le driver qui *consomme* la touche. macOS le fait (event tap). **Windows et Linux ne la consomment pas** : le prefix watcher est `InputHook("V …")` (mode Visible : « every keystroke also reaches its normal destination ») et le hook Linux tourne en mode *observe* (pas d'`EVIOCGRAB`). Le terminateur physique atteint donc l'application AVANT l'expansion, et le driver compense en effacant un caractere de plus puis en le re-injectant — ce qui est correct pour un espace ou une virgule, mais **n'annule pas un Entree qui a deja envoye le message**. Les deux drivers gardent donc l'exposition « Entree avant expansion » ; la fermer exige de passer en interception plus un re-emission sans perte de *tous* les evenements physiques, ce qui doit etre valide sur materiel reel (cf. `keyboard_hook.get_mode()`). Ne pas porter le rejeu macOS sur Linux sans ce changement : le terminateur serait **double**. Garde : `linux/tests/unit/meta/test_injector_terminator_contract.lua`.

Voir [[project_hotstring_engine_internals]], [[project_keymap_architecture]].

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

The `script_quit` action (`modules/gestures/actions.lua`, bound by default to **rcmd+Escape** via `script_control.lua`'s `escape` slot) quits Hammerspoon with `os.exit(0)`. `os.exit` terminates the Lua VM abruptly and **does NOT trigger `hs.shutdownCallback`** (`init.lua`) — where the normal Karabiner-Elements teardown lives (step 3, `KILL_FAST_CMD`). So on the quit-shortcut path, KE kept running with the Ergopti complex-modification rules and the **physical keyboard stayed remapped after HS was gone** (2026-06-16 user report, "ultra important"). Fix: `script_quit` now calls `karabiner.kill()` itself, synchronously, before scheduling the exit. `karabiner.kill()` (`platform/remap/init.lua`) runs the robust `KILL_CMD` (`ke_lifecycle.lua`) which does a `launchctl bootout` of every user-level karabiner/pqrs agent — NOT just `KILL_FAST_CMD`'s `pkill`, because a bare pkill of `karabiner_console_user_server` lets launchd respawn it and re-grab the keyboard. `kill()` also respects a user-managed KE (leaves it untouched when HS did not own the bridge via `is_hs_owned_bridge()`). It is synchronous (blocking `hs.execute`), so KE is provably down before `os.exit`. Same reasoning applies to ANY future "quit HS" code path that uses `os.exit`: it must tear KE down explicitly. Regression: `tests/unit/modules/gestures/test_script_quit_kills_karabiner.lua`.

**The shutdown KE teardown must NOT run on a RELOAD — only on a genuine quit (2026-06-16).** `hs.shutdownCallback` fires for BOTH `hs.reload()` and a real quit, with no built-in flag to tell them apart. Its step 3 ran `KILL_FAST_CMD` unconditionally, so EVERY reload killed the user-level KE bridge (`karabiner_console_user_server` + `session_monitor`). `KILL_FAST_CMD` never names `karabiner_grabber`, but on the user's KE version killing the bridge **cascades the root grabber daemon down** — so the next boot's health check found no grabber and popped the **native "install Karabiner" prompt** (user report: "dès le reload … c'est karabiner_grabber … UI native qui me propose de télécharger karabiner", no logs because it's a UI path). This contradicts the deliberate design (`karabiner/init.lua` comments: "KE reloads via FSEvents — daemons stay alive across reloads, no Space switch"). Fix: a reload-vs-quit guard. `lib/reload_guard.lua` drops a short-lived timestamp sentinel in the Storage adapter; `init.lua` **wraps `hs.reload` once at boot** to call `reload_guard.mark_reload()` before delegating (captures every reload path — file-watcher auto-reload, locale/paths change, menu "reload", the `script_reload` shortcut — since they all read the global `hs.reload` at call time), and `reload_guard.clear()` runs once at boot so the sentinel can only be true because a reload was initiated in the live session. The shutdown handler now skips the KE kill when `reload_guard.is_reloading()` (60 s TTL guards against a stale sentinel from a crash mid-reload). The quit-shortcut path is unaffected (it `os.exit`s, bypassing the callback, and kills KE itself — see above); a genuine Cmd+Q still tears KE down (no sentinel → kill runs). `reload_guard` routes persistence through `adapters.storage` and time through `os.time` so it adds ZERO `hs.*` to the lib baseline — **but the gate counts `hs.` even in comments**, so its docstrings deliberately say "a Hammerspoon reload"/"the Hammerspoon shutdown callback" instead of the literal API token. Regression: `tests/unit/lib/test_reload_guard.lua` (marked → reloading; cleared/fresh → quit; stale/non-numeric sentinel → quit). Real-Mac check still needed to confirm the grabber survives a reload end-to-end.

### project-hs-onboarding-config-schema

_The first-run wizard must write the canonical HS config schema, and the "ready" notification was removed_

<sub>slug: `project_hs_onboarding_config_schema`</sub>

The macOS onboarding wizard (`ui/onboarding/init.lua`) writes the user's first-run answers to `<config_dir>/hammerspoon/config.toml`, which is then read back by `infra/preferences.lua` (the `KEY_MAP` table) after the wizard's reload. **The two MUST agree on section + key names.** A 2026-06-16 bug: `commit()` wrote AHK-flavored keys — `[Metrics] metrics_enabled`, `[Gestures] Enabled`, `[Hotstrings] MagicKey`, `[Layout] Ergopti*`, `[Script] Locale` — but the macOS loader reads `[metrics] enabled`, `[gestures] enabled`, `[hotstrings] enabled` / `[hotstrings] trigger_char` (lowercase sections, clean `enabled` flags). So enabling metrics + gestures in the wizard had ZERO effect after the reload (the keys were never read → defaults won). Fixed by building the updates via the pure `onboarding.M._build_config_updates(answers)` using the canonical schema; regression `tests/unit/ui/test_onboarding_config_schema.lua` asserts the exact sections/keys and forbids the AHK-style ones. **Locale is special: it persists via `hs.settings` (`i18n_locale`), NOT config.toml** — `set_locale_no_reload()` only touches memory (wiped by the wizard's reload), so the wizard now also calls `i18n.persist_locale(code)` (a non-reloading settings write added for exactly this). When adding a new wizard question, add its key to BOTH the wizard updates and `preferences.KEY_MAP`, or it silently won't stick. Layout/`use_ergopti` on macOS maps to `[hotstrings].enabled` (the hotstring engine); the physical layout is Karabiner-deployed independently, so there is no `[layout] Ergopti*` config key.

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

**`/validate` DOES NOT WORK. Never use it, in any shell, in any position.**
Superseded 2026-07-29 by [[feedback_ahk_ui_syntax_validation]], which carries the
measurements and the two safe alternatives — read that entry, not this paragraph.

This entry has now been wrong three times, in every direction, which is the
lesson worth keeping. The version that stood here claimed the flag validates when
it PRECEDES the script path and runs the script only when it trails it. That is
false: on v2.0.26 the flag is ignored wherever it sits, so the file is parsed and,
if it parses, EXECUTED. The earlier "validates when it precedes" reading came from
testing against a file that had a syntax error — which exits 2 immediately and is
indistinguishable from a working validator. Testing a validator only against
INVALID input cannot tell validation from execution; that is the methodological
mistake, not the flag.

Two independent mechanisms, so guarding against one is not enough: under Git Bash
MSYS rewrites `/validate` into a Windows path so it never reaches AHK at all, and
under PowerShell it arrives correctly and is ignored. Both end with the script
running. Full detail, including the cleanup discipline for the processes this
spawns, lives in [[feedback_ahk_ui_syntax_validation]].

**A refutation needs the same standard of proof as the claim it refutes**, and
"the same standard" includes testing the NEGATIVE case. See
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
* **SSOT par couche** — la racine `_shared` est resolue en EXACTEMENT UN endroit par consommateur, donc un *renommage du tree* est une edition d un seul token a chacun de ces endroits : runtime macOS `macos/infra/paths.lua` (`Paths.shared`), runtime AHK `_SharedDir` (`ErgoptiPlus.ahk`, fallback relatif dans logger.ahk), tests macOS `macos/tests/helpers/init.lua` (`SHARED_REL`), JS `tools/lib/paths.cjs`, Python `tools/lib/paths.py`, `linux/install.sh`, `tools/build/build_static_bundle.py`, `tools/build/build_macos_app.sh`.
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
* **Related**: the `test_port_adapter_coverage.lua` `LUA_HS_BASELINE`/`LUA_IO_OS_BASELINE` ratchets scan only `macos/modules/` + `macos/infra/` — moving OS-calling code from `ui/` into `modules/` raises the count without adding any new OS call. Re-baseline with a "relocation, not new OS calls" comment (precedent: the init.lua → lib/personal_hotstrings bumps).

### [project-macos-reload-during-git-pull] Auto-reload watchers must hold the reload while ANY bulk write (git pull, cloud sync, rsync) rewrites the tree
* **Symptom**: running `git pull` on the driver repo while Hammerspoon is live left it open but completely unresponsive — every remap/shortcut dead — until force-killed and relaunched. The "must force-kill" (not just "config broken, still clickable") points at a **reload storm**: repeated `hs.reload()` firing faster than boot completes, so the keymap eventtap never stabilises. This driver already fixed one such storm once (`fe57ce045`, "debounce pathwatcher to prevent keyboard freeze on rapid file changes", citing exactly "a git commit touching several .lua files").
* **Cause**: the driver arms TWO auto-reload pathwatchers on `base_dir` — `lib/file_watchers.lua` (project `*.lua` + hotstrings/personal `*.toml`) and `ui/menu/menu_watchers.lua` (`*.lua`/`*.toml`) — each firing `hs.reload()` on any source change. `git pull` rewrites `init.lua` and dozens of required modules. The 0.5 s debounce only collapses a single *burst*; it does not stop a reload from firing while git is STILL writing (→ boot against a half-updated tree), and it does not stop the **post-reload FSEvents replay**: macOS buffers the pull's change events across `hs.reload()` and re-delivers them to the freshly-armed watcher, which reloads again, and again — the storm.
* **Fix (source-agnostic, three parts)** — git is only one bulk-write source; OneDrive / Dropbox / rsync / a mass save cause the identical freeze and leave no lock, so the core defence must not be git-specific. The decision policy lives in `_shared/lua/reload_gate.lua` (pure Lua, injected filesystem) so the macOS and Linux drivers share ONE implementation. (1) **Quiescence** — a bulk write shows up as MANY distinct files in a burst; the reload is held until file activity has been quiet for `BULK_SETTLE_SEC` (3 s), long enough to bridge the gaps a cloud sync leaves between files, while a lone edit still reloads after `EDIT_SETTLE_SEC` (0.5 s). `reload_gate.is_settled(elapsed, distinct_count)` decides; each watcher tracks the burst's distinct paths. (2) **Git precision** — `reload_gate.git_operation_in_progress(fs, base_dir)` walks up to `.git` and probes `index.lock` (held for the ENTIRE working-tree update of a checkout / ff-pull / merge / reset / commit), `MERGE_HEAD` / `CHERRY_PICK_HEAD` / `REVERT_HEAD`, and the `rebase-*/head-name` markers, so a git op is deferred exactly even if its events pause. On macOS the fs is `adapters.file_system` (zero `hs.*`/io/os purity cost, via the thin `lib/git_status.lua` binding); on Linux it is the Linux `adapters.file_system`. (3) **Storm break (macOS only)** — `lib/file_watchers.lua` gained the `BOOT_SUPPRESS_SEC = 5` window `menu_watchers` already had, dropping the post-reload FSEvents replay. The stuck-state cap (`GIT_SETTLE_MAX_DEFERRALS = 120`, 60 s) resets to 0 on any real file event, so no bulk write however long trips it — only a quiet-but-stuck state (a crashed git's stale lock) does.
* **Whole-class lesson**: this was the recurring **missed sibling** ([[project-ahk-invariant-incomplete-application]]) twice over — the git guard had to go on BOTH watchers (guarding one lets the other reload mid-pull), and the boot-suppress lived on `menu_watchers` but not `file_watchers`. The third pathwatcher, `modules/keylogger/kc_bridge.lua`, watches only `<config_dir>/metrics/karabiner_kc.log` (a runtime log git never writes) and never reloads. Every other `hs.reload()` site is user/event-driven (gesture, locale menu, path editor, reset-defaults, about/update, onboarding) and cannot fire from an external file write.
* **Cross-driver**: the debounce stays the bare literal `0.5` in `hs.timer.doAfter(0.5, …)` — a single-source gate (`tools/test/test-file-watchers-constants-single-source.cjs`) pins it to Linux's `_debounce_sec`, so do NOT replace it with a named constant. Linux's own `lib/file_watchers.lua` is fixed the same way — its `_check_deadline` consults `reload_gate` before firing; the Linux freeze is milder (`on_reload` is an in-process TOML re-scan, no re-exec and no watcher storm), so the risk there is re-scanning a half-written TOML rather than a dead config.
* **Guards**: `macos/tests/unit/lib/test_reload_gate.lua` (the shared policy: adaptive settle + git detection), `test_git_status.lua` (the macOS binding), `test_file_watchers_adaptive_settle.lua` (a many-file burst is held past the edit window, reloads at the bulk window — the OneDrive/rsync case), `test_file_watchers_git_defer.lua` + `tests/unit/ui/menu/test_menu_watchers_git_defer.lua` (reload HELD while git in progress), `test_file_watchers_boot_suppress.lua` (the boot-window replay is dropped), and Linux `tests/unit/meta/test_file_watchers.lua` "holds a many-file bulk burst" (gated on `CAN_STAT`, runs on Linux CI). Related: [[project-lua-closure-before-local-nil-global]] (the `fire_reload` forward-declaration), [[project-macos-eventtap-no-blocking]] (why the probe is filesystem-only, never a `git` subprocess).

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
* `macos/infra/text_utils.lua` est un re-export identite d une ligne (`return require("text_utils")`) de `_shared/lua/text_utils`, sans aucune extension HS. Il ressemble a de l indirection purement supprimable (un audit a propose de le supprimer).
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

### project-pages-deploy-branch-vs-workflow

_GitHub Pages set to "GitHub Actions" ignores the gh-pages branch entirely — pushes "succeed" while the live site stays frozen. This repo deploys from the BRANCH, and the deploy step must run its git ops in an isolated worktree_

<sub>slug: `project_pages_deploy_branch_vs_workflow`</sub>

Diagnosed 2026-07-22: ergopti.fr had been frozen at a 26 May artifact deploy and ergopti.fr/dev/ returned 404, while `deploy-site.yml` green-pushed a perfectly good `/dev/` tree to `gh-pages` on every dev push. Cause: the repo's Pages config had `build_type: "workflow"`, so GitHub served the last `actions/deploy-pages` artifact (from a long-deleted workflow) and **ignored the branch completely**. Nothing in the deploy job fails — the site just silently never updates.

**Why this setup:** "Deploy from a branch" (`gh-pages`, `/root`) natively serves two builds on one site — `main` at `/`, `dev` at `/dev/` — and each push rebuilds only the pushed branch's subdirectory. The "GitHub Actions" mode deploys ONE artifact per deploy, so keeping `/` and `/dev/` side by side would require rebuilding both branches every time or a fragile cross-branch cache.

**A second failure hid underneath:** the old deploy step ran `git checkout gh-pages` **inside the build checkout**, so `node_modules/`, `build/` and `.svelte-kit/` survived as untracked files and `git add -A` swept them into the published branch — the root lost its `index.html` and the branch ballooned. The step now attaches `gh-pages` in an isolated `git worktree` under `$RUNNER_TEMP` and copies `build/` output in; the worktree only ever contains the branch's own tracked files.

**How to apply:**

- Prod stopped updating (or `/dev/` 404s) while deploys are green ⇒ check `gh api repos/{owner}/{repo}/pages` — `build_type` must be `legacy` (branch mode), source `gh-pages` `/`.
- Never `git checkout gh-pages` in a dir that contains build output; always a separate worktree.
- `gh-pages` is protected by a ruleset (deletion + non_fast_forward, admin bypass): the CI pushes plain fast-forward commits — never force-push it, never commit to it by hand.
- After changing the Pages config, a build can be forced with `POST /repos/{owner}/{repo}/pages/builds`.

Related: [[feedback_commit_push]].

### project-site-i18n-gettext-french-key

_The ergopti-plus marketing page translates with gettext-style `t('French source')` — the French text IS the dictionary key, so edited copy falls back to the new French instead of ever showing a stale translation_

<sub>slug: `project_site_i18n_gettext_french_key`</sub>

`src/routes/ergopti-plus/i18n.svelte.js` + `locales/en.js` + `LangToggle.svelte`. French is implicit (`t()` returns the key verbatim); other languages are per-language dictionaries mapping the French source → translation. A missing key falls back to French, so **changing the French wording automatically retires the old translation** — re-translate at leisure by adding the new key. Language is auto-detected from `navigator.language`, persisted under `ergoptiplus.lang`, defaulting to French; the page prerenders in French (SSR-safe).

**How to apply:**

- Adding a language = create `locales/xx.js` + one entry in `AVAILABLE_LANGS`. No call site changes; the toggle renders one button per entry.
- Dictionary keys must stay **byte-identical** to the component source, typographic apostrophes (’) included.
- Arrays of translated strings inside components must be `$derived` (not `const`) or they will not re-render on language change.
- This is the marketing-page system only — the drivers' 21-language locale JSONs are a separate pipeline ([[feedback-ui-must-be-i18n]], [[project-locale-parity-test]]).

### project-svelte-script-comment-closing-tag

_A literal closing `</script>` tag ANYWHERE inside a Svelte component's script block — even in a `//` comment — terminates the block and breaks the parse with a misleading template error_

<sub>slug: `project_svelte_script_comment_closing_tag`</sub>

Svelte scans the raw text of a component's `<script>` block for the closing tag without lexing JS first, so a comment (or string) containing the literal sequence ends the script early; everything after is parsed as template markup and dies with something like "Expected a valid element or component name" pointing at innocent JS. Hit 2026-07-22 in `+page.svelte`'s JSON-LD emitter, whose explanatory comment mentioned the closing tag it was working around.

**How to apply:** build script-tag strings from split halves (`'<scr' + 'ipt …'` / `'</scr' + 'ipt>'`) and never write the closing sequence in comments inside `.svelte` files — describe it in words instead.



### project-hs-audit-2026-07-29

_Chaque ratchet d'hygiene transverse du depot a ete ecrit pour le driver Windows et jamais
etendu a macOS — un seul trou de politique, trois defauts livres_

<sub>slug: `project_hs_audit_2026_07_29`</sub>

Passe adverse sur le driver Hammerspoon : 111 findings adjuges (92 confirmes, 17 refutes,
2 hypotheses), 128 agents. Le rapport a ete retire ; les 60 findings non livres sont dans
`TODO.md` avec leur cause, leur correctif et leur test proposes.

**La trouvaille structurante n'est aucun des bugs, c'est leur cause commune.** Trois ratchets
existaient — `verify-change.cjs`, `test-ahk-encoding.cjs`, `test-no-pinned-source-reads.cjs` —
et les trois etaient scopes au driver Windows. Le troisieme l'admettait dans son propre
commentaire (« this is an .ahk-only ratchet »). Chaque trou a coute :

- pas de regle `hs-e2e` → une regression keymap a rougi la CI pendant que la suite unitaire
  affichait 3548/3548. **Le gate local et le gate CI couvraient des terrains disjoints.**
  En elargissant la garde a la CLASSE, le driver **Linux** s'est revele avoir le meme trou :
  personne ne l'avait signale.
- garde d'encodage limite aux `.ahk` → 16 sequences UTF-8 double-encodees dans 3 sources Lua
  (dont une qui s'echappe dans le `paths.toml` genere au premier lancement) et **19 locales
  sur 21 rendues illisibles par un double BOM**, introduit par le commit
  *« chore: standardize repository line endings to lf »* — la passe qui durcissait le garde
  `.ahk` est celle qui a casse les `.json`. Un cinquieme fichier corrompu
  (`_shared/modules/actions/actions.toml`) n'a ete trouve que par le nouveau garde.

**Comment l'appliquer :** quand tu ecris un ratchet, scanne l'arbre entier des le depart. Un
garde scope a un driver est une politique a moitie appliquee, et la moitie non couverte est
exactement celle ou personne ne regarde.

**Autres lecons durables de cette passe :**

- **Un correctif peut contenir l'erreur qu'il documente.** `terminator_replay` retenait le
  terminateur jusqu'a preuve d'atterrissage du remplacement, et son message de commit explique
  que « le texte colle n'est pas un de nos evenements ». Sa predicate acceptait pourtant l'echo
  de notre propre Cmd+V comme preuve, relachant ~79 ms trop tot sur le chemin de collage.
- **Un point de passage unique peut retrecir un contrat.** Faire passer les injecteurs dynamiques
  par `keymap.inject_dynamic` a ferme la desynchronisation des deux trackers — et perdu
  `is_private`, donc SSN/IBAN/carte/telephone etaient persistes en clair 14 jours. Quand tu
  centralises, compare les ARITES, pas seulement les comportements.
- **Un stub plus etroit que le vrai module cache le defaut qu'il pretend verrouiller.** Le stub
  keymap de `test_personal_hotstrings` n'exposait pas la constante que le loader lit ; reparer
  le stub renforce le test.
- **Une garde qui epingle l'orthographe transforme un durcissement en regression.**
  `test_gestures_ghost_timer_guard` matchait le texte exact du garde ; l'elargir a l'invariant
  etait la correction, pas l'affaiblissement.
- **Verifier avant d'agir sur un finding.** `is_hs_owned_bridge()` renvoie `false` quand le
  marqueur est simplement absent, donc le garde « evident » sur le marquage de propriete KE
  aurait casse le tout premier amorcage. Ce finding est reste ouvert exprès.
- **G4 reste non mesurable ici** : `<config_dir>/hammerspoon/` n'a pas de `logs/`. Les seuls
  chiffres citables viennent d'artefacts executes (suite, e2e, banc), jamais du raisonnement.

Related: [[project_hs_audit_round4_2026_07_21]], [[project_ahk_invariant_incomplete_application]],
[[project_audit_findings_are_hypotheses]], [[feedback_regression_tests]].


### project-hs-audit-2026-07-30-implementation

**Type:** project — **Sujet:** les pieges rencontres en IMPLEMENTANT les findings de l'audit
Hammerspoon, distincts de ceux rencontres en le menant.

- **`hs.timer.doAfter(0, …)` protege l'echeance du tap, pas la boucle.** Huit sites du calque
  d'actions interactives differaient leur `hs.execute` avec ce motif et leurs commentaires
  affirmaient que le probleme etait regle. Le corps du timer tourne sur la MEME boucle unique :
  le gel est deplace d'un tick, pas supprime. Seul un sous-processus asynchrone l'elimine. Tout
  garde ecrit pour cette classe doit donc refuser la deferral comme preuve.
- **Un garde qui cherche le helper « quelque part dans l'appel » est un faux vert.**
  `menu_paths` echappait son chemin et interpolait son prompt BRUT, dans un seul
  `string.format`. Ma premiere version du garde cherchait `applescript_escape` dans le texte de
  l'appel : elle est restee VERTE quand j'ai retabli le prompt brut. Aucune verification de
  FORME ne voit un argument manquant dans une liste d'arguments. La correction est structurelle —
  `applescript_format` echappe chaque argument chaine par construction, et le garde demande
  desormais QUEL formateur a ete utilise (un seul token, au point d'appel).
- **Enoncer l'invariant, jamais l'appel.** La regle « doit appeler le helper » aurait signale
  trois lignes CORRECTES du driver qui echappent un guillemet en ligne pour JavaScript — elles
  sont justes precisement parce qu'elles doublent l'antislash d'abord. La regle publiee est donc
  l'ORDRE (antislash avant guillemet), avec un controle positif qui inclut le cas « passe
  antislash placee APRES » — pire qu'absente, puisqu'elle redouble les antislashs que la passe
  guillemet vient d'introduire.
- **Ne pas balayer `^adapters%.` dans `load_with_stubs`.** Les adaptateurs capturent tous
  `local hs = hs` au require, donc un balayage global semble etre la bonne correction de classe.
  Il casse 18 tests : plusieurs installent leurs propres doubles d'adaptateur dans
  `package.loaded` AVANT d'appeler `load_with_stubs`, et le balayage les efface. Vider
  l'adaptateur precis dans la fabrique du test qui en a besoin.
- **`test_shell_runner_on_done_visible` interdit `pcall(on_done,` dans tout le fichier.** Toute
  nouvelle fonction de `shell_runner` qui invoque un callback fourni par l'appelant doit passer
  par `xpcall` + `Logger.error`. Ce test a attrape ma premiere version le jour meme.
- **Un test qui epingle le MECANISME bloque une meilleure correction.** Trois cas de capture
  d'ecran exigeaient un `doAfter` de delai 0 et grepaient la chaine de commande shell. Leur
  invariant — le travail ne doit pas tourner en ligne sur le thread du tap — est satisfait plus
  fortement par un sous-processus. Ré-encoder a son nouveau lieu, en plus fort : chemin absolu du
  binaire, `start()` reellement appele, ORDRE mkdir/capture (que le bloc dos-a-dos precedent ne
  pouvait pas exprimer), et un id de fenetre nil ne lancant RIEN plutot que deux sous-chaines
  dans le bon ordre dans le fichier.
- **Un stub muet rend une absence vacueuse.** Le premier cas du test de propriete KE passait
  parce que le `sysctl -n kern.boottime` stubbe renvoyait une sortie vide : `get_boot_timestamp`
  valait nil et les DEUX ecritures de marqueur etaient silencieusement supprimees. L'assertion
  aurait tenu face a un driver qui revendique la propriete bruyamment. C'est le cas apparie —
  « et il enregistre toujours que le remappage est applique » — qui l'a revele.
- **Ecrire du Lua riche en antislashs via un heredoc bash le corrompt.** Une paire
  d'antislashs est reduite a un seul, et la sequence antislash-n devient un vrai saut de
  ligne qui casse le parse. Utiliser les outils d'edition, ou construire avec
  `chr(92)`. Ce piege s'est represente trois fois dans cette session.

Related: [[project_hs_audit_2026_07_29]], [[project_audit_findings_are_hypotheses]],
[[project_ahk_invariant_incomplete_application]], [[feedback_regression_tests]].




### project-source-scanning-guards-must-strip-comments

_Tout garde qui cherche du texte dans du code source doit retirer les commentaires d'abord : commenter la ligne gardee laisse le texte cherche intact, et le garde reste vert. Piege rencontre deux fois en une session, sur des tests neufs_

<sub>slug: `project_source_scanning_guards_must_strip_comments`</sub>

Un meta-test qui asserte `assert_contains(source, "Foo.install(")` **ne peut pas
echouer** quand on desactive l'appel en le commentant : la chaine cherchee est
toujours presente, dans le commentaire. Verifie deux fois le 2026-07-30, sur deux
gardes ecrits le jour meme :

1. `linux/tests/unit/meta/test_logger_sink.lua` — commenter
   `LoggerSink.install(Logger)` laissait les trois assertions vertes. Le garde ne
   prouvait donc rien sur le bug qu'il etait cense encoder.
2. `tools/test/test-extensions-path-resolves.cjs` — le cliquet interdisant
   l'ancien prefixe `static/extensions` signalait **les commentaires qui
   expliquent le bug**, y compris les siens et ceux du correctif.

C'est la meme famille que le cliquet de purete `hs.*`, qui compte la sous-chaine
`hs.` dans les commentaires et les litteraux : la difference est que la, le
faux positif est bruyant, alors qu'ici le faux **negatif** est silencieux.

**Comment appliquer.**

- Retirer les lignes entierement commentees avant toute recherche de code. Une
  bande passante suffisante : `^%s*%-%-` (Lua), `^\s*;` (AHK), `^\s*(//|#)`.
  C'est ainsi que du code se desactive en pratique, et ca ne peut pas se
  declencher a tort sur un `--` dans un litteral de chaine.
- Pour un cliquet qui doit aussi ignorer les commentaires de fin de ligne,
  couper la ligne au premier marqueur de commentaire de ce langage.
- **Ajouter un auto-test du strippeur** dans le meme fichier
  (`strip("-- Foo.install()")` ne doit plus contenir `Foo`). Sans lui, la
  regression du garde est invisible.
- Et surtout : **verifier le rouge**. Desactiver le correctif, lancer, constater
  l'echec, retablir. Les deux pieges ci-dessus n'ont ete trouves que comme ca.
- Un garde qui scanne son propre fichier doit s'exclure : les deux le
  mentionnaient dans leur docstring.

Memoires soeurs : [[feedback_regression_tests]] (tout correctif part avec son
test), [[project_ahk_guard_tests_must_loop_the_class]] (enumerer la classe, pas
le site), [[project_hs_purity_ratchet_counts_comments]] (le meme comptage, cote
faux positif).




### project-simplification-branch-2026-07-30

_Etat de la branche `simplification` : ce qui est livre, ce qui reste, et les trois affirmations d'audit qui se sont revelees fausses a la verification_

<sub>slug: `project_simplification_branch_2026_07_30`</sub>

Branche `simplification`, derivee de `dev`, worktree sous
`.claude/worktrees/simplification`. Non fusionnee : le mainteneur decide quand.
Le programme complet est dans `TODO.md` §0, la documentation du
fonctionnement dans `docs/ERGOPTI_PLUS.md`.

**Livre** : lot 0 (la verite : README, specs partagees, angles morts de lint) et
6 des 12 blocages — B1 (aucun log sur Linux), B2 (tray absent de toute unite
packagee), B7 (`resolve_disabled_when` AHK echouait ouvert), B8 (chemins des
packs d'extensions), B11 (le LLM Windows journalisait le texte tape), B12 (le
bloc `<think>` etait tape dans le document sur Linux). Restants : B3, B4, B5, B6,
B9, B10 — listes avec leurs pieges dans `TODO.md`.

**Trois affirmations d'audit fausses, corrigees a la verification.** A citer
comme rappel que l'etape de verification n'est pas optionnelle :

1. « `.husky/` n'existe pas, il n'y a aucun hook git. » **Faux** :
   `.husky/{pre-commit,commit-msg}` sont suivis par git. Le test qui a produit
   cette conclusion avait tourne depuis `static/ergopti_plus/` apres une derive
   du repertoire courant. En revanche l'agent avait raison sur le fond : le hook
   annoncait « BOM + CRLF » alors que le fixer qu'il appelle normalise en LF.
2. « Supprimer `tools/build/PKGBUILD`, reference nulle part. » **Faux** : c'est la
   recette de packaging Arch/AUR elle-meme, consommee par `makepkg`, pas par un
   script du depot. La supprimer aurait retire le support Arch. Elle contenait en
   revanche un vrai bug : six sites de packaging pointaient vers
   `github.com/nizos/ergopti`, et `PKGBUILD` clonait ce mauvais depot.
3. « Brancher `linux/adapters/secure_field_detector.lua`, il n'a aucun
   consommateur. » **Faux comme correctif** : le non-usage est delibere et
   documente (`modules/keylogger/keylogger.lua:90-98`) — l'adaptateur matche le
   `WM_CLASS` exactement sur une liste plus courte, donc deleguer *reduirait* la
   couverture et laisserait fuir `gpg`/`ssh-agent`/`polkit`/`sudo`. Un garde de
   test verrouille « la couverture ne doit jamais se reduire ». Le correctif de
   B4 doit etre **additif**.

**Deux mesures a garder.** Le ratio d'identite d'arborescence est de **18,9 %**
(10 des 53 sous-repertoires de profondeur <= 2 presents dans les trois drivers) —
c'est la metrique de progression de l'invariant I1. Et `_shared/lua/` n'est
partage qu'a **37,7 %** (3 195 des 8 473 lignes requises en production par les
deux drivers Lua) : verifier les consommateurs reels avant de supposer qu'une
modification y atteint macOS *et* Linux.

Memoires soeurs : [[project_source_scanning_guards_must_strip_comments]],
[[project_audit_findings_are_hypotheses]],
[[project_audit_evidence_must_be_reproducible]].

### project-heredoc-normalises-trailing-newlines

_A shell heredoc always delivers its body plus one newline, so `Heredoc.with_stdin` cannot carry DATA — only `with_exact_stdin` does_

<sub>slug: `project_heredoc_normalises_trailing_newlines`</sub>

`_shared/lua/shell/heredoc.lua` frames a payload as `cmd <<'TOKEN'\n<body>\nTOKEN\n`.
There is no shell syntax for a heredoc whose body ends without a newline, so
`with_stdin()` strips the payload's own trailing newlines before writing the
body and the shell then appends exactly one. The command therefore reads
`strip_trailing_newlines(payload) .. "\n"`, never `payload`.

That is harmless for a **script** (a SQL script does not care how many newlines
it ends with) and silent corruption for **data**. It shipped that way in the
at-rest cipher: `encrypt("abc")` stored the ciphertext of `"abc\n"`, `"abc\n\n"`
collapsed onto the same value, and the round trip was not the identity. Nothing
read the encrypted columns yet, so it surfaced only when a migration started
rewriting stored rows in place.

`with_exact_stdin()` pipes the heredoc through `head -c <byte length>`, which
removes the framing newline without removing any of the payload's own. Verified
against real openssl: `"abc"` and `"abc\n\n"` both round-trip byte for byte.

**How to apply:**
- Payload is a script the command parses → `with_stdin` is fine.
- Payload is a VALUE that must come back unchanged (a plaintext, a ciphertext, a
  key input, anything hashed) → `with_exact_stdin`, always.
- The same trap applies to any framing that appends a terminator: check what the
  reader actually receives, not what you passed.

Related: [[project_windows_at_rest_store_is_data_sql]].

### project-windows-at-rest-store-is-data-sql

_The Windows driver never opens `db.sqlite` — `data.sql` is the data at rest, and `db.sqlite` is a disposable cache rebuilt from it_

<sub>slug: `project_windows_at_rest_store_is_data_sql`</sub>

On macOS and Linux the keylogger writes into a SQLite database. On Windows it
does not: `KL_BuildInserts` emits INSERT statements that `KL_IngestOnce` appends
to `<config>/metrics/by_device/<device>/data.sql`, an append-only ledger, and
`KL_GetSqlitePath()` points into **tmpdir**, where `keylogger_prefetch.ahk`
rebuilds an in-memory database from schema.sql + data.sql for each dashboard
open.

The consequence for anything that must change what is stored: **converting the
database on Windows protects nothing**, because the next rebuild restores the old
content straight out of the ledger. The ledger is what has to change. That is why
`modules/keylogger/keylogger_text_migration.ahk` rewrites a file where the two
Lua drivers run `UPDATE` statements.

Two traps when rewriting that ledger:
- **It is not line-oriented.** `KL_SqlStr` escapes quotes and nothing else, so
  typed text puts raw newlines, semicolons, commas and `--` inside a statement.
  Splitting on any of them cuts a statement in half. Track quoting.
- **The ingest tick keeps appending.** A rewrite that snapshots the file and then
  replaces it loses everything appended in between. Raise `KLMigration.active`,
  which `KL_IngestOnce` checks and defers on, and publish with a single
  `FSMove(..., overwrite)` so the original is intact until the last instant.

Related: [[project_heredoc_normalises_trailing_newlines]].




### project-source-scan-loops-need-a-floor

_A source-scanning test whose assertions live INSIDE the match loop passes for free when the pattern matches nothing. Assert that the loop ran._

<sub>slug: `project_source_scan_loops_need_a_floor`</sub>

The shape is everywhere in the meta suites:

```ahk
while (Pos := RegExMatch(Content, Pattern, &M, Pos)) {
    if InStr(M[], "forbidden")
        AssertFalse(true, "…")
    Pos += StrLen(M[])
}
AssertTrue(true)   ; ← "no forbidden condition found"
```

Zero matches and only-good matches are indistinguishable from outside the loop.
The trailing `AssertTrue(true)` cannot tell them apart, so a pattern that stops
matching — because the code it targets was renamed, reformatted, or moved out of
the scanned tree — silently converts the guard into a permanent pass.

**The specific regex trap that causes it here:** `[^)]*` inside a pattern meant
to span a call. AHK conditions routinely contain a nested `)`:

```ahk
HotIf((*) => Features["layout"]["ergopti_alt_gr"] and IsRealAltGrPress())
```

`HotIf\([^)]*ergopti_alt_gr[^)]*\)` matches this **zero** times, because
`[^)]` stops at the `)` of `(*)`. This has now happened twice in this repo: the
AltGr number-row guard (found 2026-07-31, scanning nothing since it was written)
and the first version of `test-ahk-loop-capture.cjs`, whose own regex found no
occurrences of the pattern it was written to count.

**How to apply:**

- Count the matches and assert the count. `Seen > 0` with a message naming what
  should have been found turns a broken pattern into a failure instead of a pass.
- Prefer a line-anchored pattern (`m)^.*Token.*$`) over `[^)]*` whenever the
  target can contain a bracket. Conditions are written on one line.
- Verify a repaired guard by INJECTING the regression it exists for, not by
  running it green. Green proves the pattern compiles, not that it looks anywhere.

Related: [[project_ahk_loop_capture_copy_freezes_nothing]].




### project-locale-placeholder-parity-is-not-a-defect

A "every translation must carry the same format placeholders as English" rule
was measured against the 21 catalogues on 2026-08-01 and **deliberately not
built**. It fires on correct work in both directions:

- **Dropped specifiers are often right.** `en` has
  `Disabled in %d application%s`, where `%s` exists only to pluralise an English
  noun. Czech renders it `Zakázáno v %d aplikaci/aplikacích` — no `%s`, because
  Czech does not pluralise that way. Danish, Hebrew and Norwegian likewise write
  `shortcuts.color_picker_result` without the trailing `{2}`, ending the sentence
  at "copied to the clipboard" instead of appending the value. That is a
  translator's call, not a bug. **Lua's `string.format` ignores surplus
  arguments**, so a dropped specifier does not raise; the reverse (more
  specifiers than arguments) is the only shape that errors.
- **The "added specifier" hits were all prose.** 21 keys looked like a
  translation introducing `% d` / `% s` / `% i` / `% f`. Every one is a literal
  percent sign followed by a space and an ordinary word: `{pct}% du focus`,
  `{pct}% del focus`. A C-format regex reads `% d` as "space flag + d" and spans
  straight into "du". These strings are `ui_apps.*` — the metrics WebView, which
  substitutes `{pct}` by name and never calls a `%`-formatter at all.

**Why:** a gate that fires on correct translations is worse than no gate,
because the change it demands damages the product. Twenty-five "findings" here
were 25 pieces of good localisation.

**How to apply:**

- Before writing a parity gate over human-translated text, print the actual
  strings on both sides. Types and counts cannot distinguish a bug from a
  language.
- `%` in a translated string is usually a percent sign. Scope any `%`-format
  scan to keys that provably reach a formatter, not to the whole catalogue.
- What *is* worth gating there — and now is, via
  `test-locale-catalogue-complete.cjs` — is key parity, empty values, and each
  catalogue's `_meta.locale` matching its filename. Those are objective.

Related: [[feedback-ui-must-be-i18n]].




### project-menu-manifest-json-is-generated

`_shared/modules/menu/menu_manifest.json` is **generated** from
`_shared/modules/features/manifest.toml` `[menu.*]` by
`tools/build/build-menu-manifest.js`. Editing the JSON by hand works right up
until anything regenerates it, at which point the edit vanishes with no error —
the drift check then reports the file as differing from HEAD, which reads like an
unrelated failure if you do not know the file is an output.

The generated file says so in its own `_comment` key, which is easy to miss when
you arrive via grep rather than by opening the top of the file.

**Why:** measured on 2026-08-01, after a hand edit to the JSON survived a full
AHK suite run and then disappeared. The three-line change had to be redone in the
TOML and regenerated.

**How to apply:**

- Before editing any JSON under `_shared/`, check `tools/build/generators.cjs` —
  it lists every generated output. `menu_manifest.json`,
  `terminators_catalogue.lua`, the three `config_template.toml`, the
  `features_manifest.*` and `keycode_data.js` are all outputs.
- Edit the source, run the generator (`node tools/build/build-menu-manifest.js`
  or `npm run gen`), and commit source **and** output together — the drift check
  compares generated files against HEAD, so a regenerated-but-uncommitted output
  fails it.

Related: [[project-gate-scripts-must-be-wired]].




### project-crlf-in-worktree-is-not-a-repo-defect

`core.autocrlf` is **true** on the Windows dev box and `.gitattributes` pins
`*.lua`, `*.toml`, `*.json`, `*.ahk`, `*.js` and more to `eol=lf`. A file can
therefore show CRLF when read byte-for-byte from the working copy while being
**LF in the repository** — `git status` shows no diff, and "converting" it
produces an empty commit.

Measured on 2026-08-01: `models.json` (3 864 lines) and the LLM
process-prediction corpus both read as CRLF on disk and were both already LF in
git. Reporting them as a defect would have been wrong.

The genuinely committed CRLF defect that day was different in kind: a **tool**
wrote the file. `tools/format_toml.py` used Python's default newline handling,
which translates every line feed to CRLF on Windows, so its output entered the
repo as CRLF rather than being normalised on the way in.

**Why:** the two look identical from a byte scan, and only one is a bug.

**How to apply:**

- Before reporting CRLF as a defect, run `git diff --stat HEAD -- <file>`. Empty
  means the repository copy is already LF and there is nothing to fix.
- Any Python that writes a tracked file needs `newline="\n"` explicitly —
  `write_text(..., newline="\n")` or `open(..., newline="\n")`. The default is
  platform-dependent and Windows is the platform this repo is developed on.
- `test-shared-sources-are-lf.cjs` guards `.lua`/`.toml`/`.json`; the `.ahk` half
  (plus the BOM AHK v2 requires) is `test-ahk-encoding.cjs`. Both are stable on a
  fresh clone because `.gitattributes` pins those extensions.

Related: [[feedback-ahk-source-encoding]].




### project-corpus-harness-must-model-the-matching-rule

Adding a corpus vector that exercises a **new branch** of the hotstring matcher
broke a consistency assumption in the driver harnesses twice on 2026-08-01, in
the same shape both times:

- **The buffer cap.** Windows asserted "a non-matched buffer must not end with
  its trigger". At the 256-codepoint cap the buffer *does* end with the trigger
  and the engine cannot see it, because the window is shorter than the trigger.
- **Case folding.** All **three** harnesses asserted that a matched vector's
  buffer ends with its trigger *exactly*. In the default (case-insensitive)
  mode, `"BTW"` ending a buffer for trigger `"btw"` is the fold working.

Both assumptions were true of every vector that existed when they were written,
and both were statements about the corpus rather than about the matcher.

**Why:** a harness that checks corpus consistency has to model the matching
rule. Assuming the strictest form passes for years and then rejects the first
vector that exercises a legitimate branch — and the natural reaction is to
"fix" the new vector, which deletes the coverage that just proved the harness
wrong.

**How to apply:**

- When a new vector fails a *consistency* check rather than the replay, ask
  first whether the check models the rule. Both times here the vector was right.
- Compare the way the vector declares itself: exact for `is_case_sensitive`,
  folded otherwise; skip length checks when the trigger cannot fit the window.
- Read the exemptions already present. Both harnesses already skipped
  `is_word` vectors for exactly this reason — the enumeration was incomplete,
  not wrong in principle.
- Measure the branch against the real engine before writing the vector, so a
  failure is known to be the harness rather than a guessed expectation.

Related: [[feedback-regression-tests]].




### project-drift-guard-precondition-not-a-flake

`test-drift-guard-covers-every-output.cjs` fails with *"Fix that first — this
test cannot distinguish its own signal from pre-existing drift"* whenever a
**generated file differs from HEAD at the moment the suite runs**. It shells out
to the real drift check, which compares generated outputs against HEAD, so an
uncommitted regenerated output makes that check red before the test has
perturbed anything — and it refuses to interpret a signal it cannot attribute.

Observed four times on 2026-08-01, every one immediately after editing a
generator **source** (`manifest.toml`) and regenerating, before committing. It
passes standalone and after the commit. I first wrote this off as a flake or a
staging race; it is neither, and the message says so.

**Why:** the natural reaction to an intermittent failure that clears on re-run is
to treat the suite as unreliable, which is how a real signal starts getting
ignored.

**How to apply:**

- Editing a generator source? Regenerate **and commit both** before running
  `npm run test:js`. Source and output belong in the same commit anyway — the
  drift check compares against HEAD, not the index.
- The outputs are listed in `tools/build/generators.cjs`. See
  [[project-menu-manifest-json-is-generated]] for the same trap from the other
  direction — hand-editing an output.
- A failure here is never about the file you are editing; it is about the tree
  state. Read the message before re-running.



### project-fixed-field-lists-drop-flags

**What:** four separate layers of the hotstring pipeline built a table by naming
its fields one at a time instead of iterating the schema's flag list, and every
one of them silently dropped a flag that mattered.

- `_shared/lua/toml_codec/reader.lua` returned a fixed entry table without
  `is_case_sensitive_strict`, so **neither Lua driver ever saw the flag as
  anything but false** — for all 1 302 shared entries that declare it. The
  loaders forwarded it and the engines read it; the value they moved around was
  the default.
- The macOS registry loader, the Linux corpus replay, the Linux e2e harness and
  the macOS e2e harness each named their own subset. The Linux e2e dropped
  `auto_expand`, which meant every "match expected" scenario in it had been
  failing since `auto_expand` landed, unnoticed.

**Why:** a dropped flag does not error. It reads as its default, which is a
legal value, so three layers above it keep looking correct. Nothing in a suite
distinguishes "the driver ignores this flag" from "this entry does not set it".

**How to apply:**

- Build the table from a **named list** (`for _, flag in ipairs(SCHEMA_FLAGS)`),
  never field by field. In a test harness this is not style — it is the
  difference between replaying the vector you wrote and replaying a different
  one.
- When adding a schema field, grep for the places that enumerate the existing
  ones. There is no compiler error to lean on.
- The regression test belongs on the LIST, not on the flag you just fixed. See
  `linux/tests/unit/meta/test_linux_loader_delegates_toml_codec.lua`.



### project-hotstring-case-flags-are-orthogonal

**What:** the hotstring schema has two case flags and they mean different
things. `is_case_sensitive` selects the **registration shape** — register the
trigger literally, do not generate the lower/Title/UPPER family.
`is_case_sensitive_strict` selects the **comparison** — no case folding. Only
the AutoHotkey loader had this right (`HSE_RegisterFromTomlFlags` maps the first
to a registrar, the second to AHK's `C` flag).

The name of the first flag is the opposite of what it does, which is exactly how
both Lua drivers came to read it as "compare exactly". Consequence: the 592
shared acronym autocorrections (`"adn" = { output = "ADN", is_case_sensitive =
true }`) fired on nothing but their exact lower-case spelling. The literal
registration exists so the family cannot produce `"Adn" -> "Adn"`; the fold is
what lets a capitalised `"Adn"` correct at all.

Note also that the domain spec `_shared/core/domain/HotstringMatcher.spec.js`
uses the name `is_case_sensitive` for the COMPARISON — i.e. for the TOML's
`is_case_sensitive_strict`. Two different things with one name, one layer apart.

**Why:** every reading of the flag is defensible from its name, and the shipped
corpus sets both flags together on the 1 302 entries where it matters, so the
difference only shows on the 592 where it is set alone.

**How to apply:**

- Resolve both flags into an internal mode at load time and never let the
  ambiguous name reach the matcher. The shared engine calls them `exact`,
  `fold` and `conform`.
- `conform` means the replacement takes the casing that was TYPED. Windows
  lowercases the replacement for the lower variant, so an entry with an
  upper-case output must declare `is_case_sensitive` or its casing is discarded.
- See [[project-fixed-field-lists-drop-flags]] for why this stayed invisible.



### project-corpus-harness-must-not-decide-the-answer

**What:** the three drivers' hotstring corpus harnesses each computed the
expected outcome themselves and compared it to the vector, instead of asking the
driver. macOS compared the buffer tail to the trigger inside the test; the AHK
replay mapped `is_case_sensitive` straight onto the `C` flag rather than routing
through the real registrar; both then asserted the vector against their own
model. They agreed with the bug they existed to catch.

**Why:** a harness that reimplements the rule validates its own reading. It
passes whatever the driver does, and it fails when the CORPUS changes — which
reads as "the corpus is wrong" and gets the corpus reverted.

**How to apply:**

- Drive the real entry point. macOS has `Expander.would_fire(m, buffer)` — a
  pure predicate the engine and the tooltip both call. AutoHotkey has
  `HSE_RegisterFromTomlFlags` + `HSE_FeedChar`, and the conform verdict lives in
  `_HSE_ConformReplacement`, not in the match — a replay that stops at the match
  reports a fire that never happens.
- Assert the output TEXT, not only whether something matched. Case bugs are
  invisible to a boolean.
- When a vector's outcome genuinely depends on a per-driver constant, mark it
  `driver_specific` in the corpus and have the other drivers skip it BY NAME and
  count the skips. A silent skip is indistinguishable from coverage.



### project-decided-do-not-re-raise

**What:** ten changes that were proposed, examined and deliberately NOT made.
Each is a live-looking optimisation or fix whose reasoning has already been done
once. Carried out of TODO.md, which is for work that remains — a decision is not
a task.

**Why:** every one of these reads as an obvious improvement to a fresh pair of
eyes, which is exactly why they keep being re-raised. Two of them have already
been implemented, reverted, and re-proposed at least once.

**How to apply:** read the reasoning before touching any of these areas. If new
evidence overturns one, say what the evidence is — do not simply re-do it.

Evidence in `docs/PROJECT_MEMORY.md`.

- **Moving the KE ownership mark into `launch_headless_once()`** (the last leg of
  `ke-prime-force-claims-and-kills-unowned-bridge`): everything else in that finding
  shipped — the read-only status probe no longer claims the bridge, the poll timeout
  no longer disowns one we launched, and the settle path's pkill is ownership-gated
  like every other kill in the driver.
  What is left is moving `mark_hs_owned_bridge()` from the top of
  `prime_ke_for_session` into the branch where a headless launch actually ran, plus
  the two force-path re-marks. It stays undone deliberately. Ownership is what
  authorises the quit-time bootout, so narrowing it narrows teardown too: a force
  prime that finds a live, responsive bridge would stop claiming it and would
  therefore stop tearing it down at quit — which may be right, or may reopen the
  post-quit-remapping class recorded in PROJECT_MEMORY. The two readings cannot be
  separated by a unit test, and a previous attempt in this exact area was reverted
  for precisely that kind of unverifiable side effect. It needs one session on a real
  machine: force-prime with a foreign bridge alive, quit, and check whether the
  keyboard is still remapped.
- **Moving the clipboard transaction off the keystroke tap** (raised as
  `perform-paste-clipboard-io-inside-eventtap`): the deferral was tried and reverted
  because it breaks the paste-ordering contract pinned by
  `tests/unit/modules/keymap/test_emit_tokens_multi_paste.lua`. The two remaining
  candidates turn out to be already done, which closes the item.
  One round trip per EXPANSION rather than per token: already the case. The
  expensive `hs.pasteboard.readAllData()` runs only on the branch where no restore
  is pending (`keymap/utils.lua` `perform_paste`); every later paste in the same
  expansion cancels the pending restore and KEEPS the captured original, precisely
  so it does not re-read and capture its own payload.
  Moving the RESTORE off the hot path: also already the case — it runs from the
  `CLIPBOARD_RESTORE_SEC` timer, and its throw-path restore landed in 21c4a0208.
  What is left inside the tap is one `setContents` plus the Cmd+V, which IS the
  paste, and one `readAllData` per expansion. Neither can move without breaking the
  ordering the pinned test exists to protect.
- **Re-seeding the delay baseline at every remaining flush site** (raised as
  `shortcut-and-mouse-flush-skip-baseline-reseed`): the three keystroke-path sites
  were real and 17286ec2e fixed them. Widening it to the rest of the tree is
  refuted on its stated consequence AND on the semantics.
  The claim was that a zeroed baseline makes the next keystroke record a
  zero-millisecond gap and be "recognised as synthetic". It is not: synthetic is
  carried by the explicit `meta.s` flag (`aggregator/events.lua:101`), never
  inferred from a delay. The real effect is the one the code's own comment states —
  the inter-word gap vanishes from the timing data — which is why only the
  keystroke-path sites needed it.
  And `last_time == 0` is a deliberate sentinel: `init.lua:631` reads
  `last_time > 0 and (now - last_time) or 0`, i.e. "no previous keystroke in this
  buffer". Every remaining flush site is a boundary where that is the correct
  answer — session end after an idle timeout, the midnight day rollover, native
  autocorrect, and the stop/teardown paths. Re-seeding there would invent a typing
  interval across a gap that was not typing.
- **A resolve memo bypassed on the dynamic-hotstring preview path** (raised as
  `resolve-not-memoised-on-preview-path`): refuted by reading the file.
  `_shared/lua/dynamic_hotstrings/init.lua` holds exactly one state table,
  `local _rules = {}` — there is no cache anywhere in it. `match_buffer` calls
  `pcall(rule.resolver)` unconditionally on every suffix hit and `M.preview` is a
  three-line delegation to that same function, so there is no memo for the preview
  to bypass. The defect shape needs two divergent resolution paths and there is
  one: `rules_engine.lua`'s interceptor and its preview provider both call the
  identical `SharedEngine.match_buffer`.
- **Per-tail cap on the end-char match loop**: five synchronised sites where
  missing one silently shortens the bound — a hotstring that stops firing — for a
  sub-microsecond gain four orders of magnitude below the profiler threshold.
  The same mechanism on the hotter STAR loop was already refuted.
- **Tooltip window reuse**, **chunking the emoji registration**, **timing tricks
  around the WebView2 cold start**: tried, reverted, or rejected with blockers.
- **Reconciling the three word-boundary predicates**: the AHK/Hammerspoon
  divergence is deliberate — do not fix without a concrete user need.
- **Descending-index iteration in `HookDispatcher`**: rejected in the code
  itself; it underflows and skips a subscriber that unsubscribes itself.
- **Idle-gating the keylogger network ticks** and the AV WMI scan: cost accepted
  explicitly — in-process, and they only emit on a state change.
- **Removing the 75 ms tooltip render debounce** as "pure added latency on every
  preview" (raised as `G4B-02`): refuted by the fix to `G4B-01`. The preview must
  land after `TOOLTIP_UIA_IDLE_REQUIRED_MS` of physical idle for stage 2 of the
  position cascade to be reachable, and `_PREFIX_RENDER_DEBOUNCE_MS` (150) plus
  `TOOLTIP_RENDER_DEBOUNCE_MS` (75) is exactly what clears the 200 ms gate, with
  25 ms of margin. Dropping the 75 ms puts the render back under the gate and
  silently disables the position cache. The relationship is pinned by
  `tests/meta/test_tooltip_debounce_is_load_bearing.ahk`.




### project-a-green-probe-can-mean-redundant-guards

_A falsifiability probe that stays green does not always mean the assertion is vacuous — it can mean the hazard is guarded twice_

<sub>slug: `project_a_green_probe_can_mean_redundant_guards`</sub>

Every new gate in this repo is perturbed one fact at a time to prove it can fail.
The usual reading of a probe that stays GREEN is "the assertion is vacuous —
rewrite it". That reading is wrong often enough to be worth naming.

**Measured 2026-08-03 on the macOS logger.** The assertion was "the Logger's own
console line appears exactly once in the file — the print() tee must not
re-capture what the file sink already wrote". The probe deleted the `_emitting`
guard from the tee. It stayed green.

The assertion was fine. The hazard is guarded **twice**:

1. `_console_out()` calls `_orig_print` — the function captured *before* the tee
   was installed — so the tee is never entered for a Logger line at all.
2. The tee separately early-returns on `_emitting`.

Either guard alone is sufficient, so no single-fact mutation can produce a double
write. Removing **both** does, and that two-fact probe is what proves the
assertion real.

**How to apply:**

- When a probe comes back green, ask "is there a SECOND thing preventing this?"
  before rewriting the assertion. Deleting a good assertion because a probe could
  not falsify it is how coverage is lost while the sweep reports success.
- Then run the two-fact probe. An assertion nothing can falsify is worthless; an
  assertion only a two-fact perturbation falsifies is guarding something real and
  should say so in a comment, so the next reader does not "simplify" one of the
  two guards away.
- The corollary: `_emitting` is dead in the single-instance production path and
  alive only when two module instances each install a tee, which is a *test*
  arrangement. It stays because losing it costs nothing and the cross-instance
  case is real in the suite — but it is documented as redundant, not as load
  bearing.
- **A probe that goes red on the wrong case is also a result.** In the same
  sweep, a mutation that corrupted a log line's suppression count to `0` failed
  to turn the assertion checking that count red. The assertion searched a log
  line for the bare digit `"3"` — and the line carries a timestamp, so the date
  `2026-08-03` supplied one. **Never assert a numeric value as a bare substring
  of a line that carries a timestamp**; match it in context (`"3 identical"`).
  An assertion a calendar can satisfy will pass for eleven days a year and hide
  a defect for the other three hundred and fifty.

Related: [[project-instrumentation-absence-is-invisible]],
[[project-gate-scripts-must-be-wired]],
[[project-source-scan-loops-need-a-floor]].




### project-the-macos-logger-ring-is-per-process

_The shared Lua core is required under a BARE name, so the test runner's namespace purge never evicts it_

<sub>slug: `project_the_macos_logger_ring_is_per_process`</sub>

`macos/tests/run.lua` cold-starts every test FILE by evicting driver modules from
`package.loaded` between files. The eviction list is a prefix match:

```lua
local PURGE_PREFIXES = { "^modules%.", "^adapters%.", "^infra%.", "^ui%." }
```

The shared Lua core is reached as `require("logger")` — `_shared/lua` is spliced
onto `package.path` in `init.lua`, so the module name is **bare**. It matches no
prefix and is therefore never evicted.

**The consequence, which is not a choice:** any state the shared core holds —
the 200-entry ring, the dedup streak, the minimum level — is **per process**, and
survives every test file. A suite that got a fresh ring for free from
`load_with_stubs` wiping `package.loaded["infra.logger"]` stops getting one the
moment that state moves into the core. This is exactly the shape of the three
"expected 0 entries, saw 200" failures the first adoption attempt produced.

**How to apply:**

- A test that needs a clean ring must call `Logger.ring_buffer_clear()` — and one
  that needs a clean dedup streak `Logger.reset_dedup()` — in its own setup.
  Relying on module reload is relying on a loader side effect, and it is invisible
  at the point where it matters.
- The same applies to any future `_shared/lua` module holding state. Adding
  `"^logger$"` to `PURGE_PREFIXES` would "fix" it and would be wrong: it would
  make the tests pass by giving them an isolation the running driver never has.

Related: [[project-plan-entries-go-stale-faster-than-code]].




### project-adopting-a-singleton-core-has-three-costs

_Moving a driver onto a shared process-singleton core costs three things nobody predicts: single-slot hooks, cross-file state carry-over, and newly-visible log lines_

<sub>slug: `project_adopting_a_singleton_core_has_three_costs`</sub>

The macOS driver moved onto `_shared/lua/logger` on 2026-08-03 (1054 → 877 lines,
four duplicated algorithms deleted: line format, eight variants, 200-entry ring,
five-second dedup window). The rewiring itself was small. Everything that went
wrong came from one fact — **the core is a process singleton and the driver
wrapper is not** — and it went wrong in three distinct ways.

**1. Single-slot hooks, multiple wrapper instances.** The core holds ONE sink,
ONE clock and ONE timestamp provider. `infra.logger` can be instantiated more
than once inside a single test file: the file takes its own handle through
`load_with_stubs`, and the module under test pulls another when it loads.
Whichever ran last owns all three slots — so a test would install a sink on one
instance and watch every line be delivered through the other, reaching the file
and the console exactly as it should and reaching the assertion never. Symptom:
*"expected 3 lines, got 0"*, on a driver that is logging perfectly.

Fix: `M.claim_core_hooks()`, called at load AND from `M.set_sink()`. Installing a
sink is a caller saying "drive the logger through me", so it is the right moment
to take ownership. It is exposed on `M` rather than kept `local` because
`M.set_sink` is defined earlier in the file, and a table field resolves at CALL
time where a `local` declared further down is not captured at all — see
[[project-lua-closure-before-local-nil-global]].

Claim the clock as a **closure over `M`**, never by value: `Core.clock_fn =
function() return M.clock_fn() end`. Assigning `Core.clock_fn = M.clock_fn`
captures it once at load, and every later replacement is ignored — which silently
disables the only way a five-second window can be exercised by a suite running in
milliseconds.

**2. Shared state makes the suite order-dependent.** The dedup streak is per
process, so the last line of one test file can suppress the identical first line
of the next, and the result then depends on the walk order — which differs
between NTFS and APFS. `tests/run.lua`'s `purge_driver_modules()` now clears the
core's streak and ring between FILES. It deliberately does NOT add `^logger$` to
`PURGE_PREFIXES`: evicting the module would hand every test an isolation the
running driver never has, which is how a suite comes to be green about behaviour
that does not exist.

**3. Previously-invisible log lines become visible, and old counts encode the
blindness.** `test_expander_no_duplicate_init` asserted "first init emits no
WARN". After adoption it saw one — a real
`[keymap.terminator_replay] M.init() called more than once`, emitted through a
DIFFERENT logger instance and therefore invisible to the sink before. The count
had not regressed; it had stopped lying. The fix is to scope the assertion to the
module under test's own tag, which is what it always meant.

**How to apply:**

- Before adopting a shared core, ask what it holds ONE of. Every such slot is a
  place where two wrapper instances fight, and the loser fails silently.
- A test count that changes after adoption is evidence about the OLD test, not
  automatically about the new code. Read the line before assuming a regression.
- Pin the driver half as BEHAVIOUR first. Source-scanning guards all go red on a
  move that changes nothing, and the only available reading of a red test is "you
  broke it". See [[project-source-scanning-guards-must-strip-comments]].
- When a constant moves out of a driver, a single-source gate will report that it
  "silently stopped guarding it". Do not delete the check — **invert** it, into
  "this file must not declare it again". That is the stronger assertion: not
  "these numbers agree" but "there is only one number".

Related: [[project-the-macos-logger-ring-is-per-process]],
[[project-a-green-probe-can-mean-redundant-guards]].





### project-linux-grab-is-a-contract-not-a-flag

_EVIOCGRAB is only survivable with an open uinput channel, opened first; the kernel releases the grab on process death, so the hazard is not the crash — it is the fallback that made grabbing unaffordable_

<sub>slug: `project_linux_grab_is_a_contract_not_a_flag`</sub>

Under `EVIOCGRAB` the daemon is the ONLY remaining path to the application: every physical event it consumes has to be put back, in arrival order, or the keyboard is dead. Three properties follow, and each one was violated at some point by code that looked correct:

- **Order.** The uinput channel opens BEFORE the grab and closes AFTER the ungrab. Opening after the grab leaves a window in which the daemon owns the keyboard and can only give keys back one `fork` at a time; closing before the ungrab destroys the device while there may still be keys to put through it.
- **No fallback.** `emit_key` had a `ydotool key` fallback, which is a subprocess per physical keystroke on the input path — the measured reason the grab was impossible in the first place. Degrading into it on the machines where uinput is unavailable reintroduces the defect exactly where it hurts. It refuses and says so, and the daemon exits at boot with a French message naming the fix.
- **Autorepeat is a character.** The application sees exactly what is re-emitted, repeats included. A buffer that ignores evdev value 2 believes the user typed `a` while the screen says `aaaa`, and then erases the wrong number of characters on the next expansion. It is NOT a physical press: the keystroke metrics count keys pressed, and a held key is one press.

**Why:** the grab was enabled by default on the strength of a comment stating that re-emission no longer forked. `open_fast_channel()` had no caller outside its own test, so the justification was true of the code that existed and false of the code that ran.

**How to apply:**

- There is no ungrab-on-panic handler and there must not be one. `EVIOCGRAB` is bound to the open descriptor and the kernel drops it when the process dies, however it dies. A handler would only pretend to add safety.
- Never write the `struct input_event` layout down. `infra/input_event.lua` owns it in both directions and derives the offsets from `ffi.sizeof`. The old constants (24 bytes, type at offset 17) are the 64-bit shape and only that: a 32-bit userspace has an 8-byte timeval, so every field lands elsewhere and the driver reads plausible garbage rather than failing.
- The two daemons are coordinated by NAME. `linux/infra/device_names.lua` is the single source; the remap config excludes our uinput device by exact string, and `device_finder` asks for the remap output device before it ranks anything else. `is_likely_keyboard` matched our own `Ergopti Virtual Keyboard` into the PREFERRED tier, so the daemon read its own injections back.

Related: [[project-a-second-vocabulary-fails-silently]], [[feedback-regression-tests]].




### project-git-stash-in-this-checkout-pops-a-stranger

_`git stash push` can fail with "could not write index", and the reflex `git stash pop` then merges another session's parked stash into your working tree_

<sub>slug: `project_git_stash_in_this_checkout_pops_a_stranger`</sub>

Observed 2026-08-04. `git stash push -u -m "wip"` failed with `error: could not write index`; the paired `git stash pop` in the same command chain then ran anyway and applied **`stash@{0}`, which belonged to an earlier session**, producing 17 `UU` conflicts across a driver tree the current work had never touched. Nothing was lost — a conflicted `pop` does not drop the stash — but the working tree looked as if the current change had exploded.

**Why:** this checkout carries long-lived stashes from other sessions (see [[feedback-stash-drop-by-index-trap]]), and `pop` with no argument takes the top of a shared stack that is not yours.

**How to apply:**

- Do not use `git stash` here to obtain a clean tree for a gate. Commit the work first — commits are free and local, and the release-branch rule already forbids pushing.
- If a `stash push` ever reports a failure, **stop**. Do not run `pop`. Check `git stash list` first and confirm what is on top.
- Recovery from an accidental pop is per-path, not global: `git reset -q -- <path>` then `git checkout -- <path>` restores the tracked files, and any file the stash ADDED remains untracked and must be removed by hand after confirming with `git show stash@{0}:<path>` that the stash still holds it.




### project-drift-guard-needs-a-clean-tree

_`test-drift-guard-covers-every-output.cjs` fails whenever a generated file is modified-but-uncommitted — by design — and takes over two minutes_

<sub>slug: `project_drift_guard_needs_a_clean_tree`</sub>

The gate's own contract is "detects a change to every generator output **and never eats an uncommitted edit**". To prove the second half it must refuse to run over a dirty generated file, so an uncommitted `static/ergopti_plus/docs/architecture.md` — which is exactly what `npm run gen:diagram` produces — makes `npm run test:js` report a failure that has nothing to do with the change under test.

**Why:** adding any adapter or port changes `architecture.md`, so this fires on most structural work, and the failure message reads like a real drift.

**How to apply:**

- Run `npm run gen` after any change to adapters, ports, the features manifest or the menu manifest, and **commit the regenerated outputs in the same commit**.
- Re-run the drift guard only on a clean tree. It takes >120 s, so it will be moved to the background by the harness; start it deliberately rather than inside a chain.

Related: [[project-gate-scripts-must-be-wired]], [[feedback-local-gate-mirrors-ci]].





### project-python-slice-replace-can-shred-a-file

_A `str.replace(old, new)` whose `old` was sliced between two `index()` results becomes `replace("", new)` when the bounds invert — the payload lands between every character of the file_

<sub>slug: `project_python_slice_replace_can_shred_a_file`</sub>

Hit on 2026-08-04 while editing `linux/modules/hotstrings/loader.lua`. The script did:

```python
old = s[s.index('--- Scans a directory tree'):s.index('return M')]
s = s.replace(old, new)
```

`s.index('return M')` matched **`return M.load_catalogue(...)`**, hundreds of lines EARLIER than the start marker, so the slice was the empty string. Python's `replace("", new)` inserts `new` at every position: the 176-line file became 406 320 lines, and `loadfile` failed at line 15 on a fragment of the payload.

**Why it matters here:** the file also held uncommitted work, so `git checkout` was not a recovery option.

**How to apply:**

- Never build a replacement needle from two `index()` calls without asserting the slice is non-empty and the bounds are ordered. `assert start < end and old.strip()` before the replace.
- Prefer the Edit tool for structured edits. It fails loudly on a non-unique or absent match, which is exactly the failure this pattern converts into silent destruction.
- **Recovery, if it happens:** the original characters are still there, interleaved. The file is `new + c0 + new + c1 + … + new`, so the repeated unit can be derived from the distance between the first two occurrences of its own first line — `unit = s[i1 : i2 - 1]` — and `s.replace(unit, "")` restores the file exactly. Verify with `loadfile` and the suite, not by eye.
- Escaping a Lua pattern through a Python heredoc is its own trap: a Lua `"([^/\]+)"` is four backslashes in a non-raw Python literal and two in a raw one. When a `replace` reports zero occurrences, print `repr()` of the real line before guessing again.

Related: [[project-git-stash-in-this-checkout-pops-a-stranger]].




### project-a-path-resolver-must-know-every-layout-that-ships

_The Linux driver resolved `_shared` as a sibling only, which is the checkout and the tarball — and wrong for every system package we build_

<sub>slug: `project_a_path_resolver_must_know_every_layout_that_ships`</sub>

`infra/paths.lua` probed exactly one candidate, `<driver root>/../_shared`. That is correct for the checkout (`static/ergopti_plus/{linux,_shared}`) and for the release tarball, which unpacks the two side by side — so every developer, every test and every CI run agreed it worked. The `.deb`, the `.rpm` and the `PKGBUILD` stage the driver flat into `/usr/lib/ergopti` and nest the shared tree **inside** it, because a sibling would land at `/usr/lib/_shared`, which no package may own. On an installed package the probe therefore addressed `/usr/lib/_shared/data/locales/en.json` and `shared_root()` returned nil.

**Why it survived so long:** the generated wrapper exports `LUA_PATH` over the shared Lua tree, so `require` kept working. The daemon started, logged normally, and only the **data** reads failed — locales, keycode tables, hotstring packs, tooltip config, defaults. A `--help` smoke test passes in that state, which is why one had never caught it.

**How to apply:**

- When a resolver takes a layout as given, enumerate the layouts that actually ship before trusting it. Here there were two, and only one was in the code.
- `require` working proves nothing about data reads. A wrapper's `LUA_PATH` covers the first and not the second, so a package can boot and be functionally empty.
- Test a path resolver by placing the resolver **file** where the layout puts it and loading it from there — that is what an install does. Stubbing `io.open` tests the branch, not the layout.
- A package smoke test must open a data file, not only exit 0 from `--help`.

Related: [[project-fixed-field-lists-drop-flags]], [[project-a-green-probe-can-mean-redundant-guards]].




### project-release-notes-are-not-joined-to-the-assets

_The Linux release table linked `kanata.kbd` for months; no job ever uploaded it, and the site's Linux button resolved through that same name_

<sub>slug: `project_release_notes_are_not_joined_to_the_assets`</sub>

The release body is a literal heredoc in `finalize-release`; the attached files come from whatever `find release-assets -type f` returns. Nothing compared the two, so a row could name a file no job produced. `kanata.kbd` did, and every published release carried a 404.

It was worse than a dead row. `Platforms.svelte`, `Hero.svelte` and `StickyCta.svelte` each resolve the Linux call-to-action through `ui.release?.url('kanata.kbd')`, and `getGitHubRelease.js` looks assets up by exact name — so the button rendered as `href="#"` on three pages. The drift ran in the other direction too: `ergopti-plus-linux.tar.gz`, the only asset containing the driver, was uploaded and mentioned nowhere in the notes.

**How to apply:**

- Two hand-maintained lists that must agree need a gate joining them, derived from the source on both sides. A hardcoded expected list rots exactly like the thing it guards.
- The join key here is the **basename**: upload entries are build-tree paths, note links are release-asset names, and the release attaches by filename.
- Deleting the offending row is not always the fix. The site asked for that asset by name, so removing the row would have left the button dead — the fix was to attach the file.

Related: [[project-gate-scripts-must-be-wired]], [[feedback-local-gate-mirrors-ci]].




### project-the-drift-guard-crashes-on-this-windows-box

_`test-drift-guard-covers-every-output.cjs` intermittently dies with `errno -4094` on a `config_template.toml` and leaves that file dirty — an environment fault, not drift_

<sub>slug: `project_the_drift_guard_crashes_on_this_windows_box`</sub>

The guard proves it can detect drift by perturbing each generated output in turn and restoring it. On this machine the `open` intermittently fails with `UNKNOWN` / `errno: -4094` — Windows file locking, most likely a scanner watching files that are rewritten in a tight loop. When it dies mid-perturbation it leaves one `_generated/config_template.toml` modified, so the **next** run opens by reporting real-looking drift in a different driver each time.

Seen twice on 2026-08-06: first reported as `features manifest no-drift` inside `npm run verify`, which passed when run alone; then three consecutive runs of the drift guard each blaming a different driver's `config_template.toml`.

**How to apply:**

- Before believing a drift report, run `npm run gen` and check `git status --porcelain | grep _generated`. If regenerating from a clean tree produces no diff, there is no drift — the guard damaged the file itself.
- `npm run gen` restores whatever the crash left behind; it is the recovery step, not just the fix.
- Do not chase this as a code defect. CI runs on Linux and exercises the guard properly; this is a local-environment fault only.

Related: [[project-drift-guard-needs-a-clean-tree]], [[project-drift-guard-precondition-not-a-flake]].




### project-a-test-must-own-every-module-its-subject-asks

_The injector tests stubbed the layout and the channel but not the hook the injector asks what the user is holding — so an earlier file's leftovers wrapped every injection in a spurious Shift release_

<sub>slug: `project_a_test_must_own_every_module_its_subject_asks`</sub>

`modules/hotstrings/injector.lua` releases every modifier the user is physically holding before typing, and restores them after — under a grab the application has already seen the Shift press, so an injected `e` would arrive as `E`. It learns what is held by lazily requiring `adapters.keyboard_hook`.

`test_injector_commands.lua` controlled the layout (`_set_table_for_test`) and the uinput channel (`_set_uinput`) but never the hook, so it inherited whatever was left in `package.loaded`. When the run order put a hook-touching file first, every case got `42:0` (KEY_LEFTSHIFT up) prepended and `42:1` appended: a case expecting six events saw eight, a case expecting none saw two, and the whole file went red at once.

**Why it looked like something else:** it reproduced only on some runs, so it read as a LuaJIT bug or a rolling-distro problem. The proof it was neither: commit `dcf2b5b79` produced a green `Linux · unit tests` job **and** a red one. Test discovery shells out to `find` (no `lfs` in CI), and `find` order depends on the filesystem of a fresh VM — so the module order, and therefore the pollution, varied run to run.

**How to apply:**

- List what the SUBJECT requires, not what the test happens to think about. Any module the subject asks a question of must be stubbed, or the test is measuring ambient state.
- A whole file failing at once is a setup fault, not N behaviour changes. Read it that way before reading the assertions.
- Reproduce order-dependence by poisoning `package.loaded` directly rather than by shuffling files: `package.loaded["adapters.keyboard_hook"] = { held_text_modifiers = function() return { "shift" } end }` reproduced all ten failures on the first try.
- A behaviour nobody tests is a behaviour that will surface as somebody else's failure. The release/restore wrap had no test at all, which is exactly why it appeared as nine unrelated ones.

Related: [[project-fixed-field-lists-drop-flags]], [[project-a-green-probe-can-mean-redundant-guards]].




### project-a-boolean-return-that-means-two-things-hides-a-stale-test

_`set_override` returns `save_overrides()`, so `false` means "field refused" OR "write failed" — a test asserting `false` passed for years on machines where the write failed_

<sub>slug: `project_a_boolean_return_that_means_two_things_hides_a_stale_test`</sub>

`hotstrings_config.set_override(cat, sec, field, value)` validates the field name, writes the override, then `return save_overrides()`. Two unrelated outcomes collapse into one `false`.

A test asserted `set_override("rolls", nil, "priority", 5) == false`, with the reasoning that priority is resolved by the loader from a different cascade. That contract changed deliberately on 2026-08-05 — the settings window has a priority field per category and per section, the bridge forwards it, and the guard had been refusing it silently. The test should have gone red that day. It did not, because on a machine with no writable config directory `save_overrides()` fails and returns `false` for a completely unrelated reason. On CI, where the write succeeds, it failed at random.

**How to apply:**

- Assert the EFFECT, not a return value that conflates outcomes. Reading the override back through `get_user_override` cannot be satisfied by a failed save.
- Ask the accessor that owns the field. `resolve()` answers the delay/colour/tooltip cascade and never carried `priority`; asserting against it would have failed a genuinely overridable field for being absent where it was never meant to appear.
- When a guard changes a public contract, grep for tests asserting the OLD one in the same commit. A test that should have gone red and did not is a test that was passing for the wrong reason all along.

Related: [[project-a-green-probe-can-mean-redundant-guards]], [[project-fixed-field-lists-drop-flags]].
