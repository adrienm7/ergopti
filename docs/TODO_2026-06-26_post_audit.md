# Post-Audit TODO — 2026-06-26

Final backlog produced after executing the `refactor/audit-2026-06-26` branch
and running a fresh four-axis re-audit (cross-driver duplication, god-files /
complexity, dead code / tooling, Linux + shared-frontend convergence). Every
item below is evidence-backed with `file:line` pointers and tagged with
`behavior_change` / `reload_only` so the maintainer can sequence by risk.

`reload_only = true` means the change is only verifiable by reloading the live
driver (AHK GUI on Windows, Hammerspoon boot on macOS, daemon restart on Linux)
— automated gates cannot prove it.

---

## 0. What already landed on this branch (done + green)

F1 keylogger split · F2 healthcheck split · F3 WPM split · F4 keymap layout
split · DD-1 Ollama port single-source (AHK) · SS-2 shared `toml_codec` purity ·
MS-2 macOS LLM menu i18n · **MS-3a section-decoration single-source** · TT-3/TT-4
CI cadence + dormant-guard revival · **click-lock / hammerspoon-integrity guards
repointed after folderisation**. All verified by `test:hs`, `test:js`, the AHK
suite, and `lint:conventions:strict`.

---

## 1. Tier 1 — Quick wins (high value, low risk, NOT reload-only)

These are fully verifiable by the existing gates and safe to land immediately.

- [ ] **T1-A — Fix the broken `install-ahk-watcher.js` dev tool.** `tools/dev/install-ahk-watcher.js:23` points at `scripts/watch-ahk.js` (the `scripts/` dir is gone — watcher is `tools/dev/watch-ahk.js`); `PROJECT_DIR` (`:15`) resolves to `tools/`, not the repo root; `:26` references the dead `static/drivers/hotstrings/.local_ahk_path` (canonical: `static/ergopti_plus/windows/.local_ahk_path`). The `test-dev-tool-paths.cjs` guard does not scan this file, so it slipped. **Fix the 3 paths + add the file to the guard's `SCRIPTS` array.** `behavior_change: true (broken→fixed)` · `reload_only: false`.
- [ ] **T1-B — Delete `tools/dev/update-ahk-date.js`.** `test-dev-tool-paths.cjs:11,44` already document it as "the removed update-ahk-date.js" and fail if anything references it, yet the 2.6K file still exists with zero invocations. `reload_only: false`.
- [ ] **T1-C — Remove the orphan `lint:banners` npm alias** (`package.json:18`): zero callers in CI / husky / `run-js-suite.cjs`; banner alignment is enforced by `lint:conventions:strict`. Keep the underlying `audit-banner-alignment.js` for manual `--fix`. `reload_only: false`.
- [ ] **T1-D — Decide the fate of the `uninstall-ahk-watcher.js` + `install-ahk-watcher.js` pair** (no `install:*` npm entry, referenced nowhere): wire both as `watch:ahk:install`/`:uninstall`, or delete the pair. `reload_only: false`.
- [ ] **T1-E — Fix stale self-path headers** (CLAUDE.md rule 3): `tools/codegen/new-driver.js:1` and `tools/lint/audit-banner-alignment.js:2` still claim `// scripts/...` pre-reorg paths. Doc-only.

---

## 2. Tier 2 — Cross-driver single-source (medium, mostly behavior-neutral)

- [ ] **D-1 — Semver comparison reimplemented 3× with NO parity gate, and already drifted. ⚠ highest-value correctness item.** Three independent implementations of the same non-trivial semver-precedence algorithm: JS "canonical" `_shared/modules/updater/version.js:19-111`, AHK `windows/lib/updater/core.ahk:264-344`, Lua `macos/lib/updater.lua:62-140`. The `version.js` header *mandates* they agree, but there is no gate, and the **non-semver fallback has already diverged**: macOS fails-closed (`updater.lua:120-128`, regression fix lib-update-03) while AHK (`core.ahk:327-328`) and JS (`version.js:96`) still use lexicographic `StrCompare`. **Action:** pick one fallback semantics (recommend fail-closed everywhere), reconcile all three, and add a cross-driver parity gate feeding one shared vector table to all three suites (the proven `tooltip/tint.js` + `test_tooltip_tint_contract.{ahk,lua}` pattern). `behavior_change: true` (aligning the fallback) · `reload_only: false`. **Needs a maintainer decision on which fallback to standardise on.**
- [ ] **D-3 — LLM stop-token vocabulary duplicated ×3.** `windows/modules/llm/api_ollama.ahk:111-112`, `macos/modules/llm/api_ollama.lua:280-281`, `macos/modules/llm/api_mlx_inference.lua:104-105` (the MLX copy has already dropped `TAIL:`/`SUITE` forms — live drift). Move into a `stop_sequences` block in the already-shared, fail-fast-loaded `_shared/modules/llm/inference.json`. `behavior_change: false` · `reload_only: false`.
- [ ] **D-2 — Updater presets + GitHub owner/repo: the shared single-source is dead.** `_shared/modules/updater/constants.toml` defines the 12 interval presets + `adrienm7/ergopti` and claims both drivers read it — but nothing does; AHK hardcodes them (`windows/lib/updater/core.ahk:19-20,71-84`) and Lua hardcodes them (`macos/lib/updater.lua:14-15,38-51`). Either wire both to read the TOML at boot (same machinery as `timings/constants.toml`) or delete the dead TOML + fix its false header (§5.6). `behavior_change: false` · `reload_only: true` if wired.
- [ ] **D-4 — Hotstrings override-file parser grammar duplicated ×2.** `windows/lib/hotstrings/hotstrings_config.ahk:373-467` (`_ParseOverrides`) and `macos/modules/hotstrings/hotstrings_config.lua:98-215` (`parse_overrides`) hand-parse the identical bespoke TOML-subset grammar. A single runtime parser is blocked by AHK↔Lua (same constraint as SS-2); realistic action = define the grammar once as a shared corpus (like `_shared/tests/corpus/toml/`) and gate both parsers against it. `behavior_change: false`.
- [ ] **D-5 — French day/month name tables defined twice (intra-Lua).** `_shared/lua/dynamic_hotstrings/init.lua` (`datelongfr` resolver) and `macos/modules/dynamic_hotstrings/rules_engine.lua` re-emit the same ordered FR weekday/month lists. Expose once from the shared module. Low. `behavior_change: false`.

---

## 3. Tier 3 — God-file splits & complexity (behavior-neutral, reload_only)

Each mirrors a split the *other* driver already did, so the boundary is proven.

- [ ] **F5 — Split `windows/modules/gestures/init.ahk` (~1196 L).** Section "1/ Constants" actually spans 44–1089 and contains the `GESTURE_ACTIONS` catalog + ~20 action *implementations* (screenshot, color-pick, web-search, mouse-teleport, paste-plain, …) mixed with the dispatch engine. Extract the catalog + action functions into `windows/modules/gestures/actions.ahk` to mirror `macos/modules/gestures/actions.lua` (846 L) vs `init.lua` (740 L). High value. `reload_only: true`.
- [ ] **F6 — Split `windows/ui/personal_toml_editor.ahk` (~987 L).** Lines 32–503 are a self-contained TOML read/write/normalise codec (`ReadPersonalToml`/`WritePersonalToml`/`NormaliseOutput`) also consumed by the hotstring loader, trapped inside a GUI file. Extract to `windows/lib/hotstrings/personal_toml_io.ahk` (mirrors the macOS lib/ui separation) — makes the pure transforms unit-testable without Gui v2. High value. `reload_only: true`.
- [ ] **F7 — Split `macos/modules/shortcuts/actions/system.lua` (~923 L)** into 4 cohesive files its own docstring already delineates: keep-awake (161–420), pixel-color (420–522), eventtap binding factories (522–765), mouse/display utils (765–923). Thin aggregator re-exports `M`. Med-high. `reload_only: true`.
- [ ] **F8 — Extract the index/lookup machinery from `macos/modules/keymap/registry.lua` (~1094 L).** The "2/ Database Management" section (195–698, ~500 L) bundles O(1) tail-bucket indexing (`rebuild_lookup`, `rebuild_tail_indexes`, deferred-sort) with file-loading + casing. Pull the indexing into `keymap/registry_index.lua`. **Judgment call — borderline cohesive; medium risk (hot path).** `reload_only: true`.
- [ ] **F9 — Optional: retire pure `lib/*` re-export shims** (`macos/lib/{toml_codec,toml_reader,toml_writer,text_utils,color_utils}.lua`) and collapse the `_shared/lua/toml_codec/init.lua`→`codec.lua` hop, *once the `_shared/` migration is considered settled*. Low value; keep `modules/llm/parser.lua` (real logic). `reload_only: true`.

---

## 4. Tier 4 — Shared frontend & Linux convergence

- [ ] **UI-A — 12 webview apps each redefine the native host-bridge, with an inconsistent payload contract. ⚠ latent bug.** Per-app bridge blocks (e.g. `action_picker/script.js:25-36`, `changelog/script.js:45-56`, `hotstring_editor/script.js:162-178`, `prompt_editor/script.js:560-568`, … 12 total) differ only by handler-name string, but disagree on what they send to WKWebView: some `JSON.stringify` both channels, others (`paths_editor:91/99`, `personal_info_editor:59/67`, `onboarding:431/438`, `hotstring_editor:166/168`) send a JSON string to WebView2 but a raw object to WKWebView. Add `_shared/ui/host_bridge.js` → `makeHostBridge(handlerName)` normalising both hosts identically. **Verify the chosen shape against both hosts before landing.** `behavior_change: possibly` · `reload_only: true (both platforms)`.
- [ ] **UI-B — `escape_html` duplicated 3+ times with divergent escaping** (`model_browser/script.js:141-147`, `metrics_apps/script.js:262-270` [escapes `'`], `metrics_typing/format.js:56-59` [does not]). One `escapeHtml` in a new `_shared/ui/dom_utils.js`, superset escaping. Med. `reload_only: true`.
- [ ] **UI-C — DOM-ready boilerplate repeated in ~7 apps** (`changelog:109-112`, `download_window:41-47`, `model_browser:72-75`, `onboarding:642-645`, …). Add `onDomReady(fn)` to `dom_utils.js`. Low. `reload_only: true`.
- [ ] **UI-D — Split the `metrics_apps/script.js` 3 526-line monolith** to mirror the already-decomposed sibling `metrics_typing/` (11 files). Do after UI-A/UI-B exist so the split consumes them. L effort. `reload_only: true`.
- [ ] **LIN-1 — Migrate the Linux TOML loader off its hand-rolled fork.** `linux/modules/hotstrings/loader.lua:79-208` reimplements a TOML parser only because the shared reader used to hard-require macOS `lib.logger` — that impurity is fixed (SS-2). Delegate to `_shared/lua/toml_codec.reader`, keeping `M.load` as the thin flag-normalisation shell. **Gate strictly behind CI `test:linux` (luajit) + a new equivalence regression test — reload-only on Linux hardware the maintainer rarely exercises.** Med. `reload_only: true (Linux)`.
- [ ] **LIN-2 — (defer) Linux `http_client` async + shared timeout constant.** Only the `DEFAULT_TIMEOUT_MS = 30000` magic number is shareable today; revisit when Linux gains libuv async.

---

## 5. Tier 5 — Large deferred chantiers (from the prior audit)

- [ ] **UI-1 / P4.17 — Make the healthcheck report a shared frontend** (`_shared/ui/healthcheck/{index.html,script.js,style.css}` + WebView2/WKWebView hosts cloning the changelog host). −~300 LOC of byte-identical HTML. L; reload-both-platforms; ship a §5.9 guard on the snapshot JSON keys. Best paired with UI-A (the shared host-bridge).
- [ ] **I18N-4 / P4.18 — Extract ~410 hardcoded FR string literals from `_shared/ui/**/*.js`** (20 files; worst: `metrics_typing/data.js` 177, `metrics_apps/script.js` 131) into i18n keys + `check_locales.py --fix` backfill + a new ratchet. XL; do file-by-file.
- [ ] **MS-3b — macOS shortcut-label parity.** macOS `menu_shortcuts.lua:56-78` (`pretty_key`) derives "Ctrl + A"-style labels algorithmically; AHK reads them from the manifest i18n key. Resolve macOS labels from the manifest key (like AHK) with `pretty_key` as fallback only for ids absent from the manifest. `behavior_change: true` (may change displayed strings) · `reload_only: true`. Needs the `pretty_key`-ids-vs-manifest-keys enumeration first.

---

## 6. Dead code removals (careful, batched, reload-affecting)

The dead-code agent verified each below appears exactly once (its own definition)
in the production corpus and 0× in tests/manifests. AHK class-method and pure
dynamic-string dispatch were out of scope, so treat as a *lower bound* and delete
in **small batched commits, each with the full AHK/HS suite green**.

- [ ] **DC-shims (rule 5.6)** — delete `prediction_engine.lua:226` `set_llm_show_model_name` alias (repoint `init.lua:317` + `llm_bridge.lua:295` to `set_llm_display_model_name`); `windows/ui/healthcheck/core.ahk:455` `HealthCheck_Format` (pure delegate); `windows/modules/llm/api_ollama.ahk:215` `LLM_OllamaGenerate` (confirm no test depends first). Fix the *wording* of the false "backward compatibility" comment on the **live** `registry.lua:338` `has_exact_trigger` (do NOT delete it).
- [ ] **DC-dead-modules** — delete `macos/ui/menu/menu_script_control.lua` (126 L, zero non-test refs; superseded by `menu_shortcuts.lua` — remove its lone test too), `macos/lib/color_utils.lua` (pure dead shim), `_shared/lua/keycodes/qwerty_names.lua` (1 ref = itself).
- [ ] **DC-dead-AHK-functions** — ~43 zero-caller free functions, biggest clusters in `windows/modules/keylogger/{keylogger,keylogger_ui,keylogger_reader}.ahk` and `windows/modules/llm/*`. Full list in the audit transcript. Batch carefully; `npm run build:domain` + AHK suite green per commit.

---

## 7. Negative findings — verified clean, do NOT touch

- **LLM catalogues** (models / providers / pricing / inference / profiles / defaults incl. Ollama port) are fully shared and fail-fast loaded on both drivers; HTTP payload *shapes* differ only by language (legitimate).
- **Tooltip tint HSL** is reimplemented per-driver but **already** guarded by a cross-driver parity gate (`test_tooltip_tint_contract.{ahk,lua}` vs `_shared/modules/tooltip/tint.js`) — this is the model D-1/D-3 should copy.
- **Terminators, keycodes, keymap utils, wrap_symbols, priority.json (parity-gated), gestures actions.toml, hotstrings defaults.toml** — all single-sourced.
- **Linux core is well-converged**: `hotstring_engine`, `keymap/terminators`, `keylogger/metrics`, `logger/shim` are genuinely shared; `crypto`/`storage`/`notifier`/`text_sender`/`injector`/`keyboard_hook`/`input_reader` are legitimately OS-specific.
- **~15 macOS port adapters** look unused (runtime calls `hs.*` directly) but are deliberate port-contract scaffolding validated by the adapter-compliance suite — removing them breaks the contract tests.
- **All 10 committed `_generated/` artifacts** are drift-gated by `build:domain` (`git diff --exit-code`) in CI — correct regenerate-and-diff pattern, leave as-is.
- **`metrics_typing/` (11-file app)**, **`_shared/ui/i18n.js`**, **keylogger walkers** (deliberate AHK↔Lua 1:1 line-up), **`registry.lua`/`api_remote`/`api_ollama` "legacy" branches** (describe live runtime behavior) — legitimately as-is.
