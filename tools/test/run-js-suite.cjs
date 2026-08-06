// tools/test/run-js-suite.cjs

/**
 * ==============================================================================
 * MODULE: JS Validation Suite Runner
 * DESCRIPTION:
 * Single local entry point for the JavaScript/Node validation layer of CI. It
 * runs the same checks the GitHub "Validate ·" jobs run, in one command, and
 * prints a legible pass/fail summary so a contributor can reproduce and read a
 * CI failure without scrolling a multi-megabyte log or guessing which of a dozen
 * npm scripts maps to the red check.
 *
 * FEATURES & RATIONALE:
 * 1. One command: "npm run test:js" == the CI JS validation, so local and CI
 *    outcomes match. Pass --full to also run the slow property + mutation tests.
 * 2. Legible failures: each failing check prints the exact command to re-run it
 *    in isolation plus the tail of its output, at the top of the summary.
 * 3. Fail-fast aggregate: exits non-zero if any check fails, with a one-line
 *    summary CI annotators can surface.
 * ==============================================================================
 */

'use strict';

const { spawnSync } = require('child_process');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const FULL = process.argv.includes('--full');

// Each check mirrors a CI "Validate ·" step. command/args are run from ROOT.
const CHECKS = [
	{ name: 'domain pipeline (manifest, parity, ports, schema, read-sites, drift)', cmd: 'npm', args: ['run', '--silent', 'build:domain'], repro: 'npm run build:domain' },
	{ name: 'hotstring priority parity (shared JSON ↔ AHK + Lua)', cmd: 'npm', args: ['run', '--silent', 'test:priority-parity'], repro: 'npm run test:priority-parity' },
	{ name: 'translation key consistency audit', cmd: 'node', args: ['tools/lint/audit-translations.cjs'], repro: 'node tools/lint/audit-translations.cjs' },
	{ name: 'convention lint (banners, spacing, section headers — strict)', cmd: 'npm', args: ['run', '--silent', 'lint:conventions:strict'], repro: 'npm run lint:conventions:strict' },
	{ name: 'lint banner-marker safety (no hardcoded-prefix corruption of "--"-marker Lua banners)', cmd: 'node', args: ['tools/test/test-lint-banner-marker-safety.cjs'], repro: 'node tools/test/test-lint-banner-marker-safety.cjs' },
	{ name: 'LLM legacy_ids + BASIC_PROMPT single source', cmd: 'node', args: ['tools/test/test-llm-legacy-basic-prompt-single-source.cjs'], repro: 'node tools/test/test-llm-legacy-basic-prompt-single-source.cjs' },
	{ name: 'locale display order single source (locale_order.json ↔ macOS + Windows + Linux + site)', cmd: 'node', args: ['tools/test/test-locale-order-single-source.cjs'], repro: 'node tools/test/test-locale-order-single-source.cjs' },
	{ name: 'no generator stamps the current date into its output (drift must mean drift)', cmd: 'node', args: ['tools/test/test-generated-output-is-time-independent.cjs'], repro: 'node tools/test/test-generated-output-is-time-independent.cjs' },
	{ name: 'architecture diagram (ports resolve + architecture.md in sync)', cmd: 'node', args: ['tools/test/test-architecture-diagram.cjs'], repro: 'node tools/test/test-architecture-diagram.cjs' },
	{ name: 'dev-tool paths (private-AHK workflow points at live paths)', cmd: 'node', args: ['tools/test/test-dev-tool-paths.cjs'], repro: 'node tools/test/test-dev-tool-paths.cjs' },
	{ name: 'fast repeating timers are inventoried (no silent poller)', cmd: 'node', args: ['tools/test/test-fast-timer-inventory.cjs'], repro: 'node tools/test/test-fast-timer-inventory.cjs' },
	{ name: 'metrics categories are id-keyed (colours survive a language switch)', cmd: 'node', args: ['tools/test/test-metrics-category-ids.cjs'], repro: 'node tools/test/test-metrics-category-ids.cjs' },
	{ name: 'action platform declarations match the macOS registry', cmd: 'node', args: ['tools/test/test-action-platform-truth.cjs'], repro: 'node tools/test/test-action-platform-truth.cjs' },
	{ name: 'every menu-manifest field and section has a driver that reads it (no decorative declarations)', cmd: 'node', args: ['tools/test/test-menu-manifest-keys-have-readers.cjs'], repro: 'node tools/test/test-menu-manifest-keys-have-readers.cjs' },
	{ name: 'no new menu row built outside the renderer (I3 ratchet — windows 220, macos 301, linux 3)', cmd: 'node', args: ['tools/test/test-menu-rows-outside-renderer.cjs'], repro: 'node tools/test/test-menu-rows-outside-renderer.cjs' },
	{ name: 'every declared menu row has a handler in its driver (I3 ratchet — ahk 0, hs 5, linux 0)', cmd: 'node', args: ['tools/test/test-menu-action-handler-bijection.cjs'], repro: 'node tools/test/test-menu-action-handler-bijection.cjs' },
	{ name: 'top-level menu shape agrees across the three drivers (I3 — the manifest finally has a Linux dimension)', cmd: 'node', args: ['tools/test/test-menu-top-level-parity.cjs'], repro: 'node tools/test/test-menu-top-level-parity.cjs' },
	{ name: 'the whole menu tree agrees across the three drivers, submenus included (I3 — no empty submenu, no orphaned header, no unread getter)', cmd: 'node', args: ['tools/test/test-menu-parity.cjs'], repro: 'node tools/test/test-menu-parity.cjs' },
	{ name: 'the hotstrings windows are one shared UI, and every driver bridge answers every action it sends', cmd: 'node', args: ['tools/test/test-hotstrings-bridge-parity.cjs'], repro: 'node tools/test/test-hotstrings-bridge-parity.cjs' },
	{ name: 'no Lua 5.2+ constructs where LuaJIT has to load them (the interpreter CI and the daemon actually run)', cmd: 'node', args: ['tools/test/test-luajit-52-isms.cjs'], repro: 'node tools/test/test-luajit-52-isms.cjs' },
	{ name: 'every skipped conformance case names a ledger row (skips are data, not prose)', cmd: 'node', args: ['tools/test/test-conformance-skips-declared.cjs'], repro: 'node tools/test/test-conformance-skips-declared.cjs' },
	{ name: 'every script a git hook invokes exists (a moved script breaks the next commit that trips it)', cmd: 'node', args: ['tools/test/test-hook-scripts-exist.cjs'], repro: 'node tools/test/test-hook-scripts-exist.cjs' },
	{ name: 'shared .lua/.toml/.json use LF (the AHK half is covered by test:ahk-encoding)', cmd: 'node', args: ['tools/test/test-shared-sources-are-lf.cjs'], repro: 'node tools/test/test-shared-sources-are-lf.cjs' },
	{ name: 'no driver-namespaced manifest table (I2 — a feature lives at its semantic path, never under a driver)', cmd: 'node', args: ['tools/test/test-feature-namespace-ratchet.cjs'], repro: 'node tools/test/test-feature-namespace-ratchet.cjs' },
	{ name: 'single-driver features reach only their own driver (platforms inherit from the section — pin them)', cmd: 'node', args: ['tools/test/test-driver-scoped-features-stay-scoped.cjs'], repro: 'node tools/test/test-driver-scoped-features-stay-scoped.cjs' },
	{ name: 'platform-restriction reasons reach a reader (absences shipped, translated, consumed)', cmd: 'node', args: ['tools/test/test-reason-keys-are-readable.cjs'], repro: 'node tools/test/test-reason-keys-are-readable.cjs' },
	{ name: 'no new unexplained platform restriction (I2 ratchet — 138 today; run with --report for the inventory)', cmd: 'node', args: ['tools/test/test-platform-restrictions-explained.cjs'], repro: 'node tools/test/test-platform-restrictions-explained.cjs --report' },
	{ name: 'every declared action chord is well formed (I4 — an unknown modifier fires the wrong shortcut silently)', cmd: 'node', args: ['tools/test/test-action-chord-notation.cjs'], repro: 'node tools/test/test-action-chord-notation.cjs' },
	{ name: 'every declared action has a handler in its driver (I4 bijection — ahk 0, hs 0, linux 39)', cmd: 'node', args: ['tools/test/test-action-registry-bijection.cjs'], repro: 'node tools/test/test-action-registry-bijection.cjs' },
	{ name: 'the Karabiner and gesture action namespaces are one (54 tappable reachable, 19 hold-only out, no doubled keystroke)', cmd: 'node', args: ['tools/test/test-karabiner-namespace-is-merged.cjs'], repro: 'node tools/test/test-karabiner-namespace-is-merged.cjs' },
	{ name: 'Karabiner binary paths declared once (a v16-style rename must not reach 3 of 4 copies)', cmd: 'node', args: ['tools/test/test-karabiner-binary-paths-single-source.cjs'], repro: 'node tools/test/test-karabiner-binary-paths-single-source.cjs' },
	{ name: 'WPM divisor single source (Lua drivers use the shared constant; WebView copies frozen at 5)', cmd: 'node', args: ['tools/test/test-wpm-chars-per-word-single-source.cjs'], repro: 'node tools/test/test-wpm-chars-per-word-single-source.cjs' },
	{ name: 'prompt-builder constants agree across Lua, JS and the generated AHK (all 10)', cmd: 'node', args: ['tools/test/test-prompt-builder-constants-parity.cjs'], repro: 'node tools/test/test-prompt-builder-constants-parity.cjs' },
	{ name: 'every corpus field is read by a replay or documented as descriptive', cmd: 'node', args: ['tools/test/test-corpus-fields-are-read.cjs'], repro: 'node tools/test/test-corpus-fields-are-read.cjs' },
	{ name: 'every source path a packaging script copies exists (no suite runs a build)', cmd: 'node', args: ['tools/test/test-packaging-paths-exist.cjs'], repro: 'node tools/test/test-packaging-paths-exist.cjs' },
	{ name: 'every asset the release notes link to is uploaded by a build job (no dead download button)', cmd: 'node', args: ['tools/test/test-release-notes-assets-are-uploaded.cjs'], repro: 'node tools/test/test-release-notes-assets-are-uploaded.cjs' },
	{ name: 'every registered action resolves a label in all 21 locales', cmd: 'node', args: ['tools/test/test-action-labels-have-locale-keys.cjs'], repro: 'node tools/test/test-action-labels-have-locale-keys.cjs' },
	{ name: 'Linux modules resolve _shared through infra/paths.lua', cmd: 'node', args: ['tools/test/test-linux-shared-path-resolver.cjs'], repro: 'node tools/test/test-linux-shared-path-resolver.cjs' },
	{ name: 'every _shared resolver executes and lands on a real file (Linux + macOS, and the unset-HOME fallback)', cmd: 'node', args: ['tools/test/test-shared-root-resolvers.cjs'], repro: 'node tools/test/test-shared-root-resolvers.cjs' },
	{ name: 'driver-doc paths (no stale static/drivers in docs)', cmd: 'node', args: ['tools/test/test-doc-paths.cjs'], repro: 'node tools/test/test-doc-paths.cjs' },
	{ name: 'no new location-pinned source reads in AHK tests (ratchet)', cmd: 'node', args: ['tools/test/test-no-pinned-source-reads.cjs'], repro: 'node tools/test/test-no-pinned-source-reads.cjs' },
	{ name: 'no new location-pinned source reads in macOS tests (ratchet)', cmd: 'node', args: ['tools/test/test-no-pinned-source-reads-lua.cjs'], repro: 'node tools/test/test-no-pinned-source-reads-lua.cjs' },
	{ name: 'AHK test coverage (every test_*.ahk reachable from run_all)', cmd: 'node', args: ['tools/test/test-ahk-test-coverage.cjs'], repro: 'node tools/test/test-ahk-test-coverage.cjs' },
	{ name: 'e2e gate symmetry (every driver e2e runner is selected by verify-change)', cmd: 'node', args: ['tools/test/test-e2e-gate-symmetry.cjs'], repro: 'node tools/test/test-e2e-gate-symmetry.cjs' },
	{ name: 'shared-contract gate coverage (_shared/core + _shared/tests select all three driver suites)', cmd: 'node', args: ['tools/test/test-shared-contract-gate-coverage.cjs'], repro: 'node tools/test/test-shared-contract-gate-coverage.cjs' },
	{ name: 'AHK parse coverage (Ahk2Exe compiles the whole #Include graph — Windows only, self-validating)', cmd: 'node', args: ['tools/test/test-ahk-parse-coverage.cjs'], repro: 'node tools/test/test-ahk-parse-coverage.cjs' },
	{ name: 'AHK runners are invoked (no run_*/bench_* file referenced by nothing)', cmd: 'node', args: ['tools/test/test-ahk-runners-are-invoked.cjs'], repro: 'node tools/test/test-ahk-runners-are-invoked.cjs' },
	{ name: 'AHK loop capture (no inline closure over a loop variable in a Test registration)', cmd: 'node', args: ['tools/test/test-ahk-loop-capture.cjs'], repro: 'node tools/test/test-ahk-loop-capture.cjs' },
	{ name: 'Lua closure-binds-nil-global (ratchet against the fourth recurrence of the hs.task GC-pin trap)', cmd: 'node', args: ['tools/test/test-lua-closure-before-local.cjs'], repro: 'node tools/test/test-lua-closure-before-local.cjs' },
	{ name: 'glossaries match the code (port count + names derived from _shared/core/ports, no retired driver dirs)', cmd: 'node', args: ['tools/test/test-glossary-matches-code.cjs'], repro: 'node tools/test/test-glossary-matches-code.cjs' },
	{ name: 'Linux menu i18n keys exist (every i18n_safe key is defined in en.json)', cmd: 'node', args: ['tools/test/test-linux-menu-keys-exist.cjs'], repro: 'node tools/test/test-linux-menu-keys-exist.cjs' },
	{ name: 'source encoding (no double-encoded UTF-8, no repeated BOM, valid UTF-8 — every driver)', cmd: 'node', args: ['tools/test/test-source-encoding.cjs'], repro: 'node tools/test/test-source-encoding.cjs' },
	{ name: 'AHK v2.0 parse-breakers (v1 quotes / block-body arrows that abort the whole suite)', cmd: 'node', args: ['tools/test/test-ahk-v2-syntax-antipatterns.cjs'], repro: 'node tools/test/test-ahk-v2-syntax-antipatterns.cjs' },
	{ name: 'unified reporter parses TAP + Lua output (report.cjs)', cmd: 'node', args: ['tools/test/test-report.cjs'], repro: 'node tools/test/test-report.cjs' },
	{ name: 'max_tokens single source (no literal default in backend adapters)', cmd: 'node', args: ['tools/test/test-max-tokens-single-source.cjs'], repro: 'node tools/test/test-max-tokens-single-source.cjs' },
	{ name: 'temperature single source (no literal 0.1 default in macOS adapters)', cmd: 'node', args: ['tools/test/test-temperature-single-source.cjs'], repro: 'node tools/test/test-temperature-single-source.cjs' },
	{ name: 'ollama port single source (no hardcoded port literal in AHK LLM files)', cmd: 'node', args: ['tools/test/test-ollama-port-single-source.cjs'], repro: 'node tools/test/test-ollama-port-single-source.cjs' },
	{ name: 'Linux LLM defaults single source (temp/port/context/keep_alive from _shared canonicals)', cmd: 'node', args: ['tools/test/test-linux-llm-defaults-single-source.cjs'], repro: 'node tools/test/test-linux-llm-defaults-single-source.cjs' },
	{ name: 'locale resolution single source (macOS+Linux wrappers delegate to shared locale.core)', cmd: 'node', args: ['tools/test/test-locale-resolution-single-source.cjs'], repro: 'node tools/test/test-locale-resolution-single-source.cjs' },
	{ name: 'webview i18n browser-fallback path (bridge-less locale fetch resolves)', cmd: 'node', args: ['tools/test/test-i18n-fallback-path.cjs'], repro: 'node tools/test/test-i18n-fallback-path.cjs' },
	{ name: 'webview i18n fallback cascade (a failed locale fetch must not blank the page)', cmd: 'node', args: ['tools/test/test-webview-i18n-cascade.cjs'], repro: 'node tools/test/test-webview-i18n-cascade.cjs' },
	{ name: 'menu labels single source (shared labels.lua consumed by macOS)', cmd: 'node', args: ['tools/test/test-menu-labels-single-source.cjs'], repro: 'node tools/test/test-menu-labels-single-source.cjs' },
	{ name: 'Linux version single source (one BUNDLE_VERSION-style source, no re-typed 3.0.0; P0-E)', cmd: 'node', args: ['tools/test/test-linux-version-single-source.cjs'], repro: 'node tools/test/test-linux-version-single-source.cjs' },
	{ name: 'hotstring buffer-cap parity (shared BUFFER_MAX_CHARS == both Windows mirrors; P0-F)', cmd: 'node', args: ['tools/test/test-hotstring-buffer-cap-parity.cjs'], repro: 'node tools/test/test-hotstring-buffer-cap-parity.cjs' },
	{ name: 'LLM model + GPT link single source (no re-typed default literals in AHK)', cmd: 'node', args: ['tools/test/test-llm-model-single-source.cjs'], repro: 'node tools/test/test-llm-model-single-source.cjs' },
	{ name: 'version compare parity (JS over shared vectors; AHK+macOS suites read the same table)', cmd: 'node', args: ['tools/test/test-version-compare-contract.cjs'], repro: 'node tools/test/test-version-compare-contract.cjs' },
	{ name: 'LLM stop-sequences single source (no re-inlined literals in backends)', cmd: 'node', args: ['tools/test/test-llm-stop-sequences-single-source.cjs'], repro: 'node tools/test/test-llm-stop-sequences-single-source.cjs' },
	{ name: 'shared TOML codec purity (no hard driver requires — loads on every Lua runtime)', cmd: 'node', args: ['tools/test/test-shared-toml-codec-purity.cjs'], repro: 'node tools/test/test-shared-toml-codec-purity.cjs' },
	{ name: 'no fallback literals (LLM defaults read from JSON, never a deleted mirror)', cmd: 'node', args: ['tools/test/test-no-fallback-literals.cjs'], repro: 'node tools/test/test-no-fallback-literals.cjs' },
	{ name: 'cross-driver manifest equivalence (resolved values identical across drivers)', cmd: 'node', args: ['tools/test/test-manifest-equivalence.cjs'], repro: 'node tools/test/test-manifest-equivalence.cjs' },
	{ name: 'webview geometry single source (macOS defers to manifest; Windows literals match; P0-A)', cmd: 'node', args: ['tools/test/test-webview-geometry-single-source.cjs'], repro: 'node tools/test/test-webview-geometry-single-source.cjs' },
	{ name: 'diagnostic UI integrity (macOS + Windows healthcheck render path)', cmd: 'node', args: ['tools/test/test-diagnostic-ui-integrity.cjs'], repro: 'node tools/test/test-diagnostic-ui-integrity.cjs' },
	{ name: 'UI focus-fix regression (force-focus + no raw blockAlert)', cmd: 'node', args: ['tools/test/test-ui-focus-fix.cjs'], repro: 'node tools/test/test-ui-focus-fix.cjs' },
	{ name: 'click-lock fix (non-consuming watcher + keystroke release, both drivers)', cmd: 'node', args: ['tools/test/test-click-lock-fix.cjs'], repro: 'node tools/test/test-click-lock-fix.cjs' },
	{ name: 'Hammerspoon integrity (no global leaks, M.stop present, shutdown wired)', cmd: 'node', args: ['tools/test/test-hammerspoon-integrity.cjs'], repro: 'node tools/test/test-hammerspoon-integrity.cjs' },
	{ name: 'section-title decoration parity (single "— … —" source per driver, no re-inlining)', cmd: 'node', args: ['tools/test/test-section-decoration-parity.cjs'], repro: 'node tools/test/test-section-decoration-parity.cjs' },
	{ name: 'macOS bundle layout (build script + launcher mirror the repo)', cmd: 'node', args: ['tools/test/test-macos-bundle-layout.cjs'], repro: 'node tools/test/test-macos-bundle-layout.cjs' },
	{ name: 'Linux package layout (.deb/.rpm install into /usr/lib/ergopti; wrapper boots the same bundle entry)', cmd: 'node', args: ['tools/test/test-linux-package-layout.cjs'], repro: 'node tools/test/test-linux-package-layout.cjs' },
	{ name: 'Linux launcher starts where install.sh leaves a machine (no hard dep the installer skips; every exported shared path exists)', cmd: 'node', args: ['tools/test/test-linux-launcher-deps.cjs'], repro: 'node tools/test/test-linux-launcher-deps.cjs' },
	{ name: 'extension-pack paths resolve (every read site lands on a real pack; pre-reorg prefix ratcheted out)', cmd: 'node', args: ['tools/test/test-extensions-path-resolves.cjs'], repro: 'node tools/test/test-extensions-path-resolves.cjs' },
	{ name: 'LLM logs carry no typed text (context length only, never a slice of the buffer)', cmd: 'node', args: ['tools/test/test-llm-no-prompt-content-in-logs.cjs'], repro: 'node tools/test/test-llm-no-prompt-content-in-logs.cjs' },
	{ name: 'LLM privacy defaults single-sourced (secure fields blocked, URL bars allowed, all three drivers)', cmd: 'node', args: ['tools/test/test-llm-privacy-defaults-cross-driver.cjs'], repro: 'node tools/test/test-llm-privacy-defaults-cross-driver.cjs' },
	{ name: 'at-rest encryption envelope parity (marker/cipher/PBKDF2 identical across the three drivers)', cmd: 'node', args: ['tools/test/test-text-crypto-envelope-parity.cjs'], repro: 'node tools/test/test-text-crypto-envelope-parity.cjs' },
	{ name: 'metrics privacy defaults single-sourced (one id per filter; no driver keeps a hardcoded copy)', cmd: 'node', args: ['tools/test/test-metrics-privacy-single-source.cjs'], repro: 'node tools/test/test-metrics-privacy-single-source.cjs' },
	{ name: 'launcher single-instance guard (LSMultipleInstancesProhibited in Info.plist)', cmd: 'node', args: ['tools/test/test-launcher-single-instance.cjs'], repro: 'node tools/test/test-launcher-single-instance.cjs' },
	{ name: 'menu manifest drift (feature paths + i18n keys resolve against manifest.toml)', cmd: 'node', args: ['tools/test/test-menu-manifest.cjs'], repro: 'node tools/test/test-menu-manifest.cjs' },
	{ name: 'features manifest no-drift (every committed _generated/ file matches the live generator)', cmd: 'node', args: ['tools/test/test-features-manifest-no-drift.cjs'], repro: 'node tools/test/test-features-manifest-no-drift.cjs' },
	{ name: 'drift guard covers every generator output (and never eats an uncommitted edit)', cmd: 'node', args: ['tools/test/test-drift-guard-covers-every-output.cjs'], repro: 'node tools/test/test-drift-guard-covers-every-output.cjs' },
	{ name: 'hotstring corpus backspace_count is a logical count, not emitted keystrokes', cmd: 'node', args: ['tools/test/test-corpus-backspace-count-semantics.cjs'], repro: 'node tools/test/test-corpus-backspace-count-semantics.cjs' },
	{ name: 'one menu_manifest.json reader per driver (macOS parsed it three times, two of them caches of the same file)', cmd: 'node', args: ['tools/test/test-menu-manifest-single-reader.cjs'], repro: 'node tools/test/test-menu-manifest-single-reader.cjs' },
	{ name: 'is_word means the same thing on all three drivers (no trigger asks for a boundary it carries)', cmd: 'node', args: ['tools/test/test-is-word-flag-is-honoured-identically.cjs'], repro: 'node tools/test/test-is-word-flag-is-honoured-identically.cjs' },
	{ name: 'logger scalars single-source (retention/ring/dedup/flush vs the timing registry)', cmd: 'node', args: ['tools/test/test-logger-scalars-single-source.cjs'], repro: 'node tools/test/test-logger-scalars-single-source.cjs' },
	{ name: 'tap-hold shared defaults lifecycle (docs match what the three loaders do)', cmd: 'node', args: ['tools/test/test-tap-hold-defaults-lifecycle.cjs'], repro: 'node tools/test/test-tap-hold-defaults-lifecycle.cjs' },
	{ name: 'locale native names single-source (every ordered locale is named, no driver copy)', cmd: 'node', args: ['tools/test/test-locale-names-single-source.cjs'], repro: 'node tools/test/test-locale-names-single-source.cjs' },
	{ name: 'locale catalogue completeness (all 21 carry en.json key-for-key, nothing renders blank)', cmd: 'node', args: ['tools/test/test-locale-catalogue-complete.cjs'], repro: 'node tools/test/test-locale-catalogue-complete.cjs' },
	{ name: 'generator registry runs (npm run gen: every declared output is produced)', cmd: 'node', args: ['tools/build/gen-all.cjs'], repro: 'npm run gen' },
	{ name: 'new-driver scaffold emits one adapter per port spec (not zero)', cmd: 'node', args: ['tools/test/test-new-driver-scaffold.cjs'], repro: 'node tools/test/test-new-driver-scaffold.cjs' },
	{ name: 'driver tree parity I1 (shared directory ratio, ratcheted)', cmd: 'node', args: ['tools/test/test-driver-tree-parity.cjs'], repro: 'node tools/test/test-driver-tree-parity.cjs --measure' },
	{ name: 'stubs intercept something (no package.loaded key naming a missing module)', cmd: 'node', args: ['tools/test/test-stubs-intercept-something.cjs'], repro: 'node tools/test/test-stubs-intercept-something.cjs' },
	{ name: 'action emit rows stay per-OS (13 of 24 keystrokes genuinely differ)', cmd: 'node', args: ['tools/test/test-action-emit-is-per-os.cjs'], repro: 'node tools/test/test-action-emit-is-per-os.cjs' },
	{ name: 'macOS keyboard-slot config surface is reachable (readers called, writer binds, list entry has a provider)', cmd: 'node', args: ['tools/test/test-keyboard-slot-surface-is-live.cjs'], repro: 'node tools/test/test-keyboard-slot-surface-is-live.cjs' },
	{ name: 'chord native mappings single source (adapter prefixes/key spellings + both slot vocabularies pinned to modifier_chords.json)', cmd: 'node', args: ['tools/test/test-chord-native-mapping-single-source.cjs'], repro: 'node tools/test/test-chord-native-mapping-single-source.cjs' },
	{ name: 'port contract single source (contracts.json fresh from the spec.js files; every AHK ADAPTER_ map matches its contract)', cmd: 'node', args: ['tools/test/test-port-compliance.cjs'], repro: 'node tools/test/test-port-compliance.cjs' },
	{ name: 'hotstring priority parity (priority.json honoured identically by the drivers)', cmd: 'node', args: ['tools/test/test-priority-parity.cjs'], repro: 'node tools/test/test-priority-parity.cjs' },
	{ name: 'feature manifest parity (the generated AHK and Lua manifests describe the same features)', cmd: 'node', args: ['tools/test/test-manifest-parity.cjs'], repro: 'node tools/test/test-manifest-parity.cjs' },
	{ name: 'npm alias ⇄ suite parity (no alias names a gate the suite does not run; the aliasless count only falls)', cmd: 'node', args: ['tools/test/test-npm-aliases-match-the-suite.cjs'], repro: 'node tools/test/test-npm-aliases-match-the-suite.cjs' },
	{ name: 'keylogger walker constants single source (bucket edges and caps: shared helpers vs both walkers)', cmd: 'node', args: ['tools/test/test-walker-constants-single-source.cjs'], repro: 'node tools/test/test-walker-constants-single-source.cjs' },
	{ name: 'port × driver adapter matrix (cross-tree presence; every absence declared with a reason)', cmd: 'node', args: ['tools/test/test-port-adapter-matrix.cjs'], repro: 'node tools/test/test-port-adapter-matrix.cjs' },
	{ name: 'HotPath segment inventory (every measured hot path declared with what it covers)', cmd: 'node', args: ['tools/test/test-hotpath-segments-declared.cjs'], repro: 'node tools/test/test-hotpath-segments-declared.cjs' },
	{ name: 'shared JS reachability (every _shared module is runtime-mirrored, an oracle, or declared with a reason)', cmd: 'node', args: ['tools/test/test-shared-js-is-reachable.cjs'], repro: 'node tools/test/test-shared-js-is-reachable.cjs' },
	{ name: 'tooltip lifecycle phases (the shared four-phase contract vs the AutoHotkey renderer)', cmd: 'node', args: ['tools/test/test-tooltip-lifecycle-phases.cjs'], repro: 'node tools/test/test-tooltip-lifecycle-phases.cjs' },
	{ name: 'tap-hold namespace correspondence ([tap_hold.keys.*] vs [hs_tap_hold] paired by position, divergences named)', cmd: 'node', args: ['tools/test/test-tap-hold-namespace-correspondence.cjs'], repro: 'node tools/test/test-tap-hold-namespace-correspondence.cjs' },
	{ name: 'hotstring flag support per driver (every corpus flag honoured by all three)', cmd: 'node', args: ['tools/test/test-hotstring-flag-support-per-driver.cjs'], repro: 'node tools/test/test-hotstring-flag-support-per-driver.cjs' },
	{ name: 'magic key single source (declared once in the feature manifest, no driver copy)', cmd: 'node', args: ['tools/test/test-magic-key-single-source.cjs'], repro: 'node tools/test/test-magic-key-single-source.cjs' },
	{ name: 'tap-hold threshold parity (macOS global sits inside the per-key range)', cmd: 'node', args: ['tools/test/test-tap-hold-threshold-parity.cjs'], repro: 'node tools/test/test-tap-hold-threshold-parity.cjs' },
	{ name: 'adapter reachability (an adapter nothing requires is a port claimed, not wired)', cmd: 'node', args: ['tools/test/test-adapter-reachability.cjs'], repro: 'node tools/test/test-adapter-reachability.cjs' },
	{ name: 'hotstring telemetry is deferred (no open/write/flush inside the keyDown tap)', cmd: 'node', args: ['tools/test/test-hotstring-telemetry-is-deferred.cjs'], repro: 'node tools/test/test-hotstring-telemetry-is-deferred.cjs' },
	{ name: 'feature-state boot smoke (4 fixtures, real include graph, own process)', cmd: 'node', args: ['tools/test/test-feature-state-boot-smoke.cjs'], repro: 'node tools/test/test-feature-state-boot-smoke.cjs' },
	{ name: 'port contract vector traceability (ratchet: ids linked to the macOS mirror)', cmd: 'node', args: ['tools/test/test-port-vector-traceability.cjs'], repro: 'node tools/test/test-port-vector-traceability.cjs --measure' },
	{ name: 'lua gsub returns one value (bare return leaks the replacement count)', cmd: 'node', args: ['tools/test/test-lua-gsub-single-return.cjs'], repro: 'node tools/test/test-lua-gsub-single-return.cjs' },
	{ name: 'tooltip [positioning] constant reach (which driver reads which value)', cmd: 'node', args: ['tools/test/test-tooltip-positioning-reach.cjs'], repro: 'node tools/test/test-tooltip-positioning-reach.cjs' },
	{ name: 'shared JS is loadable (module.exports in an ESM package exports nothing)', cmd: 'node', args: ['tools/test/test-shared-js-is-loadable.cjs'], repro: 'node tools/test/test-shared-js-is-loadable.cjs' },
	{ name: 'hotstring editor confirm dialog wiring (delete actually fires)', cmd: 'node', args: ['tools/test/test-hotstring-editor-confirm-wiring.cjs'], repro: 'node tools/test/test-hotstring-editor-confirm-wiring.cjs' },
	{ name: 'WebView2 host teardown order (closing a window must not quit AHK)', cmd: 'node', args: ['tools/test/test-webview-teardown-order.cjs'], repro: 'node tools/test/test-webview-teardown-order.cjs' },
	{ name: 'dynamic hotstrings menu labels (resolver bridge + locale keys)', cmd: 'node', args: ['tools/test/test-dynamic-hotstrings-menu-labels.cjs'], repro: 'node tools/test/test-dynamic-hotstrings-menu-labels.cjs' },
	{ name: 'manifest menu labels resolve (whole class, not a sample)', cmd: 'node', args: ['tools/test/test-manifest-menu-labels-resolve.cjs'], repro: 'node tools/test/test-manifest-menu-labels-resolve.cjs' },
	// Five gate scripts under tools/test/ used to be invoked by nothing at all —
	// not by this umbrella, not by any CI workflow, not by the pre-commit hook.
	// They passed when run by hand, so nothing looked wrong; a gate that never
	// runs is the purest false green there is. test-feature-read-sites in
	// particular guards a keyboard-thread crash class and the features README
	// documents it as a "CI gate".
	{ name: 'feature read sites resolve against the manifest (UnsetItemError crash class)', cmd: 'node', args: ['tools/test/test-feature-read-sites.js'], repro: 'node tools/test/test-feature-read-sites.js' },
	{ name: 'manifest menu labels (no driver-namespaced description_key; untranslated-label ratchet)', cmd: 'node', args: ['tools/test/test-menu-labels-resolve.cjs'], repro: 'node tools/test/test-menu-labels-resolve.cjs' },
	{ name: 'Convention P (platform/ is the only OS-specific word; symmetrical across drivers)', cmd: 'node', args: ['tools/test/test-convention-p-platform-only.cjs'], repro: 'node tools/test/test-convention-p-platform-only.cjs' },
	{ name: 'source-tree scan coverage (no scanner list forgets platform/)', cmd: 'node', args: ['tools/test/test-source-trees-are-scanned.cjs'], repro: 'node tools/test/test-source-trees-are-scanned.cjs' },
	{ name: 'driver config surface is declared in the manifest (ratchet)', cmd: 'node', args: ['tools/test/test-driver-config-surface-is-declared.cjs'], repro: 'node tools/test/test-driver-config-surface-is-declared.cjs' },
	{ name: 'config schema (v2 TOML shape)', cmd: 'node', args: ['tools/test/test-config-schema.cjs'], repro: 'node tools/test/test-config-schema.cjs' },
	{ name: 'metrics heatmap translation coverage', cmd: 'node', args: ['tools/test/test-metrics-heatmap-translation.cjs'], repro: 'node tools/test/test-metrics-heatmap-translation.cjs' },
	// CI verifies AHK encoding with an inline PowerShell step rather than this
	// script, so the script itself never ran anywhere: a divergence between the
	// two implementations was invisible. Run the real one here too.
	{ name: 'AHK source encoding (UTF-8 BOM + LF)', cmd: 'node', args: ['tools/test/test-ahk-encoding.cjs'], repro: 'npm run test:ahk-encoding' },
	// Stryker's own harness. Running it here proves it still passes un-mutated,
	// which is the precondition for the mutation score meaning anything.
	{ name: 'mutation-test harness passes un-mutated (Stryker precondition)', cmd: 'node', args: ['tools/test/test-mutation-targets.cjs'], repro: 'node tools/test/test-mutation-targets.cjs' },
	{ name: 'every gate script is actually wired into a runner', cmd: 'node', args: ['tools/test/test-gate-scripts-are-wired.cjs'], repro: 'node tools/test/test-gate-scripts-are-wired.cjs' },
	{ name: 'hotstrings config window bridge (shared frontend ↔ Windows host)', cmd: 'node', args: ['tools/test/test-hotstrings-config-window-bridge.cjs'], repro: 'node tools/test/test-hotstrings-config-window-bridge.cjs' },
	{ name: 'hotstring colour presets identical on macOS and Linux', cmd: 'node', args: ['tools/test/test-color-presets-parity.cjs'], repro: 'node tools/test/test-color-presets-parity.cjs' },
	{ name: 'prompt editor bridge (shared frontend ↔ Windows host)', cmd: 'node', args: ['tools/test/test-prompt-editor-bridge.cjs'], repro: 'node tools/test/test-prompt-editor-bridge.cjs' },
	{ name: 'action picker bridge (shared frontend ↔ both hosts)', cmd: 'node', args: ['tools/test/test-action-picker-bridge.cjs'], repro: 'node tools/test/test-action-picker-bridge.cjs' },
	{ name: 'file-path headers (convention 3, every source file names itself)', cmd: 'node', args: ['tools/lint/audit-file-headers.cjs'], repro: 'node tools/lint/audit-file-headers.cjs' },
	{ name: 'window titles (Gui/windowTitle carry the "ErgoptiPlus" prefix)', cmd: 'node', args: ['tools/lint/audit-gui-titles.cjs'], repro: 'node tools/lint/audit-gui-titles.cjs' },
	{ name: 'kanata defalias parity (kanata.kbd timeouts match defaults.toml + golden corpus)', cmd: 'node', args: ['tools/test/test-kanata-defalias-parity.cjs'], repro: 'node tools/test/test-kanata-defalias-parity.cjs' },
	{ name: 'updater constants single source (owner/repo/timing literals match defaults.json)', cmd: 'node', args: ['tools/test/test-updater-constants-single-source.cjs'], repro: 'node tools/test/test-updater-constants-single-source.cjs' },
	{ name: 'name parity (text_utils + action_picker + manifest_menu symmetric across drivers)', cmd: 'node', args: ['tools/test/test-name-parity.cjs'], repro: 'node tools/test/test-name-parity.cjs' },
	{ name: 'git-mv resilience (every path pin in the three suites resolves — macOS + Linux files, AHK dirs)', cmd: 'node', args: ['tools/test/test-git-mv-resilience.cjs'], repro: 'node tools/test/test-git-mv-resilience.cjs' },
	{ name: 'shared UI JavaScript syntax (every browser script parses before WebView injection)', cmd: 'node', args: ['tools/test/test-shared-ui-js-syntax.cjs'], repro: 'node tools/test/test-shared-ui-js-syntax.cjs' },
	{ name: 'typing-speed source toggles (net expansion gain and filter semantics)', cmd: 'node', args: ['tools/test/test-metrics-speed-source-filters.cjs'], repro: 'node tools/test/test-metrics-speed-source-filters.cjs' },
	{ name: 'Linux metrics SQLite bridge (persistent manifest + selected-range refresh)', cmd: 'node', args: ['tools/test/test-linux-metrics-sqlite-bridge.cjs'], repro: 'node tools/test/test-linux-metrics-sqlite-bridge.cjs' },
	{ name: 'Windows metrics range bridge (native selected date/app refresh)', cmd: 'node', args: ['tools/test/test-windows-metrics-range-bridge.cjs'], repro: 'node tools/test/test-windows-metrics-range-bridge.cjs' },
	{ name: 'keycode data single source (generated JS matches azerty.json, DC-1)', cmd: 'node', args: ['tools/test/test-keycode-data-js-parity.cjs'], repro: 'node tools/test/test-keycode-data-js-parity.cjs' },
	{ name: 'tooltip corpus parity (JSON corpus matches JS layoutTestVectors + dequeueTestVectors)', cmd: 'node', args: ['tools/test/test-tooltip-corpus-parity.cjs'], repro: 'node tools/test/test-tooltip-corpus-parity.cjs' },
	{ name: 'TOML coercion parity (corpus cross-driver gate)', cmd: 'node', args: ['tools/test/test-toml-coercion-parity.cjs'], repro: 'node tools/test/test-toml-coercion-parity.cjs' },
	{ name: 'shared test.format single source (inspect/deep_equal/fail_msg_for consumed from _shared, no local copies)', cmd: 'node', args: ['tools/test/test-shared-test-format.cjs'], repro: 'node tools/test/test-shared-test-format.cjs' },
	{ name: 'file watchers constants single source (SCAN_MAX_DEPTH=16 + debounce=0.5s match across Linux + macOS infra/file_watchers.lua)', cmd: 'node', args: ['tools/test/test-file-watchers-constants-single-source.cjs'], repro: 'node tools/test/test-file-watchers-constants-single-source.cjs' },
	{ name: 'format_toml CLI behavioral test (bare invocation exits 1 = usage; --preview sorts sections/keys + styles headers, file untouched)', cmd: 'node', args: ['tools/test/test-format-toml-importable.cjs'], repro: 'node tools/test/test-format-toml-importable.cjs' },
	{ name: 'gesture slot-space single source (Linux derives from actions.toml [slots]; macOS literals + DEFAULT_GESTURES key-space pinned to it)', cmd: 'node', args: ['tools/test/test-gesture-slots-single-source.cjs'], repro: 'node tools/test/test-gesture-slots-single-source.cjs' },
	{ name: 'keylogger timing constants single source (CONTEXT_TTL_MS / PARK_CHECK_MS / TOPO_TICK_MS match the shared timing registry)', cmd: 'node', args: ['tools/test/test-keylogger-timings-single-source.cjs'], repro: 'node tools/test/test-keylogger-timings-single-source.cjs' },
	{ name: 'no plan-item references in tracked source (refactor/delivery tokens purged; algorithmic Phase-N allowlisted)', cmd: 'node', args: ['tools/test/test-no-plan-refs-in-source.cjs'], repro: 'node tools/test/test-no-plan-refs-in-source.cjs' },
	{ name: 'WPM widget constants single source (macOS COLOR_FALLBACK + AHK IniCache defaults pinned to shared TOML canonical)', cmd: 'node', args: ['tools/test/test-wpm-constants-single-source.cjs'], repro: 'node tools/test/test-wpm-constants-single-source.cjs' },
	{ name: 'WPM colour normalisation cross-driver drift (both drivers round-half-up on shared HSL/darken constants; golden vectors)', cmd: 'node', args: ['tools/test/test-wpm-color-normalisation-single-source.cjs'], repro: 'node tools/test/test-wpm-color-normalisation-single-source.cjs' },
	{ name: 'tests that cannot fail (tautologies, vacuous absence assertions, dead tests, pcall-only — ratchet against a growing false green)', cmd: 'node', args: ['tools/test/find-false-greens.cjs'], repro: 'node tools/test/find-false-greens.cjs' }
];

const SLOW_CHECKS = [
	{ name: 'property-based tests (fast-check)', cmd: 'npm', args: ['run', '--silent', 'test:properties'], repro: 'npm run test:properties' },
	{ name: 'mutation tests (Stryker)', cmd: 'npm', args: ['run', '--silent', 'test:mutation'], repro: 'npm run test:mutation' }
];

const checks = FULL ? [...CHECKS, ...SLOW_CHECKS] : CHECKS;

console.log('\nErgopti+ JS validation suite' + (FULL ? ' (full)' : '') + '\n' + '='.repeat(50));

const results = [];
for (const check of checks) {
	process.stdout.write(`  • ${check.name} … `);
	const r = spawnSync(check.cmd, check.args, { cwd: ROOT, encoding: 'utf8', shell: true });
	const ok = r.status === 0;
	console.log(ok ? 'OK' : 'FAIL');
	results.push({ ...check, ok, out: (r.stdout || '') + (r.stderr || '') });
}

const failed = results.filter((r) => !r.ok);

console.log('\n' + '-'.repeat(50));
if (failed.length === 0) {
	console.log(`✅  All ${results.length} JS check(s) passed.`);
	if (!FULL) console.log('   (run "npm run test:js -- --full" to also run property + mutation tests)');
	console.log('');
	process.exit(0);
}

console.log(`❌  ${failed.length}/${results.length} JS check(s) FAILED:\n`);
for (const f of failed) {
	console.log(`  ✗ ${f.name}`);
	console.log(`    reproduce: ${f.repro}`);
	const tail = f.out.trim().split('\n').slice(-12).join('\n    ');
	console.log('    ' + tail + '\n');
}
process.exit(1);
