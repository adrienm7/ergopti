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
	{ name: 'architecture diagram (ports resolve + architecture.md in sync)', cmd: 'node', args: ['tools/test/test-architecture-diagram.cjs'], repro: 'node tools/test/test-architecture-diagram.cjs' },
	{ name: 'dev-tool paths (private-AHK workflow points at live paths)', cmd: 'node', args: ['tools/test/test-dev-tool-paths.cjs'], repro: 'node tools/test/test-dev-tool-paths.cjs' },
	{ name: 'driver-doc paths (no stale static/drivers in docs)', cmd: 'node', args: ['tools/test/test-doc-paths.cjs'], repro: 'node tools/test/test-doc-paths.cjs' },
	{ name: 'no new location-pinned source reads in AHK tests (ratchet)', cmd: 'node', args: ['tools/test/test-no-pinned-source-reads.cjs'], repro: 'node tools/test/test-no-pinned-source-reads.cjs' },
	{ name: 'no new location-pinned source reads in macOS tests (ratchet)', cmd: 'node', args: ['tools/test/test-no-pinned-source-reads-lua.cjs'], repro: 'node tools/test/test-no-pinned-source-reads-lua.cjs' },
	{ name: 'AHK test coverage (every test_*.ahk reachable from run_all)', cmd: 'node', args: ['tools/test/test-ahk-test-coverage.cjs'], repro: 'node tools/test/test-ahk-test-coverage.cjs' },
	{ name: 'e2e gate symmetry (every driver e2e runner is selected by verify-change)', cmd: 'node', args: ['tools/test/test-e2e-gate-symmetry.cjs'], repro: 'node tools/test/test-e2e-gate-symmetry.cjs' },
	{ name: 'source encoding (no double-encoded UTF-8, no repeated BOM, valid UTF-8 — every driver)', cmd: 'node', args: ['tools/test/test-source-encoding.cjs'], repro: 'node tools/test/test-source-encoding.cjs' },
	{ name: 'AHK v2.0 parse-breakers (v1 quotes / block-body arrows that abort the whole suite)', cmd: 'node', args: ['tools/test/test-ahk-v2-syntax-antipatterns.cjs'], repro: 'node tools/test/test-ahk-v2-syntax-antipatterns.cjs' },
	{ name: 'unified reporter parses TAP + Lua output (report.cjs)', cmd: 'node', args: ['tools/test/test-report.cjs'], repro: 'node tools/test/test-report.cjs' },
	{ name: 'max_tokens single source (no literal default in backend adapters)', cmd: 'node', args: ['tools/test/test-max-tokens-single-source.cjs'], repro: 'node tools/test/test-max-tokens-single-source.cjs' },
	{ name: 'temperature single source (no literal 0.1 default in macOS adapters)', cmd: 'node', args: ['tools/test/test-temperature-single-source.cjs'], repro: 'node tools/test/test-temperature-single-source.cjs' },
	{ name: 'ollama port single source (no hardcoded port literal in AHK LLM files)', cmd: 'node', args: ['tools/test/test-ollama-port-single-source.cjs'], repro: 'node tools/test/test-ollama-port-single-source.cjs' },
	{ name: 'Linux LLM defaults single source (temp/port/context/keep_alive from _shared canonicals; P0-B)', cmd: 'node', args: ['tools/test/test-linux-llm-defaults-single-source.cjs'], repro: 'node tools/test/test-linux-llm-defaults-single-source.cjs' },
	{ name: 'locale resolution single source (macOS+Linux wrappers delegate to shared locale.core; P0-G)', cmd: 'node', args: ['tools/test/test-locale-resolution-single-source.cjs'], repro: 'node tools/test/test-locale-resolution-single-source.cjs' },
	{ name: 'webview i18n browser-fallback path (bridge-less locale fetch resolves)', cmd: 'node', args: ['tools/test/test-i18n-fallback-path.cjs'], repro: 'node tools/test/test-i18n-fallback-path.cjs' },
	{ name: 'menu labels single source (shared labels.lua consumed by macOS; P0-G)', cmd: 'node', args: ['tools/test/test-menu-labels-single-source.cjs'], repro: 'node tools/test/test-menu-labels-single-source.cjs' },
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
	{ name: 'launcher single-instance guard (LSMultipleInstancesProhibited in Info.plist)', cmd: 'node', args: ['tools/test/test-launcher-single-instance.cjs'], repro: 'node tools/test/test-launcher-single-instance.cjs' },
	{ name: 'menu manifest drift (feature paths + i18n keys resolve against manifest.toml)', cmd: 'node', args: ['tools/test/test-menu-manifest.cjs'], repro: 'node tools/test/test-menu-manifest.cjs' },
	{ name: 'features manifest no-drift (committed .lua/.ahk match the live generator)', cmd: 'node', args: ['tools/test/test-features-manifest-no-drift.cjs'], repro: 'node tools/test/test-features-manifest-no-drift.cjs' },
	{ name: 'hotstring editor confirm dialog wiring (delete actually fires)', cmd: 'node', args: ['tools/test/test-hotstring-editor-confirm-wiring.cjs'], repro: 'node tools/test/test-hotstring-editor-confirm-wiring.cjs' },
	{ name: 'WebView2 host teardown order (closing a window must not quit AHK)', cmd: 'node', args: ['tools/test/test-webview-teardown-order.cjs'], repro: 'node tools/test/test-webview-teardown-order.cjs' },
	{ name: 'dynamic hotstrings menu labels (resolver bridge + locale keys)', cmd: 'node', args: ['tools/test/test-dynamic-hotstrings-menu-labels.cjs'], repro: 'node tools/test/test-dynamic-hotstrings-menu-labels.cjs' },
	{ name: 'manifest menu labels resolve (whole class, not a sample)', cmd: 'node', args: ['tools/test/test-manifest-menu-labels-resolve.cjs'], repro: 'node tools/test/test-manifest-menu-labels-resolve.cjs' },
	{ name: 'hotstrings config window bridge (shared frontend ↔ Windows host)', cmd: 'node', args: ['tools/test/test-hotstrings-config-window-bridge.cjs'], repro: 'node tools/test/test-hotstrings-config-window-bridge.cjs' },
	{ name: 'prompt editor bridge (shared frontend ↔ Windows host)', cmd: 'node', args: ['tools/test/test-prompt-editor-bridge.cjs'], repro: 'node tools/test/test-prompt-editor-bridge.cjs' },
	{ name: 'action picker bridge (shared frontend ↔ both hosts)', cmd: 'node', args: ['tools/test/test-action-picker-bridge.cjs'], repro: 'node tools/test/test-action-picker-bridge.cjs' },
	{ name: 'file-path headers (convention 3, every source file names itself)', cmd: 'node', args: ['tools/lint/audit-file-headers.cjs'], repro: 'node tools/lint/audit-file-headers.cjs' },
	{ name: 'window titles (Gui/windowTitle carry the "ErgoptiPlus" prefix)', cmd: 'node', args: ['tools/lint/audit-gui-titles.cjs'], repro: 'node tools/lint/audit-gui-titles.cjs' },
	{ name: 'kanata defalias parity (kanata.kbd timeouts match defaults.toml + golden corpus)', cmd: 'node', args: ['tools/test/test-kanata-defalias-parity.cjs'], repro: 'node tools/test/test-kanata-defalias-parity.cjs' },
	{ name: 'updater constants single source (owner/repo/timing literals match defaults.json)', cmd: 'node', args: ['tools/test/test-updater-constants-single-source.cjs'], repro: 'node tools/test/test-updater-constants-single-source.cjs' },
	{ name: 'name parity (text_utils + action_picker + manifest_menu symmetric across drivers)', cmd: 'node', args: ['tools/test/test-name-parity.cjs'], repro: 'node tools/test/test-name-parity.cjs' },
	{ name: 'git-mv resilience (all path-pinned macOS tests point to existing files)', cmd: 'node', args: ['tools/test/test-git-mv-resilience.cjs'], repro: 'node tools/test/test-git-mv-resilience.cjs' },
	{ name: 'shared UI JavaScript syntax (every browser script parses before WebView injection)', cmd: 'node', args: ['tools/test/test-shared-ui-js-syntax.cjs'], repro: 'node tools/test/test-shared-ui-js-syntax.cjs' },
	{ name: 'typing-speed source toggles (net expansion gain and filter semantics)', cmd: 'node', args: ['tools/test/test-metrics-speed-source-filters.cjs'], repro: 'node tools/test/test-metrics-speed-source-filters.cjs' },
	{ name: 'Linux metrics SQLite bridge (persistent manifest + selected-range refresh)', cmd: 'node', args: ['tools/test/test-linux-metrics-sqlite-bridge.cjs'], repro: 'node tools/test/test-linux-metrics-sqlite-bridge.cjs' },
	{ name: 'Windows metrics range bridge (native selected date/app refresh)', cmd: 'node', args: ['tools/test/test-windows-metrics-range-bridge.cjs'], repro: 'node tools/test/test-windows-metrics-range-bridge.cjs' },
	{ name: 'keycode data single source (generated JS matches azerty.json, DC-1)', cmd: 'node', args: ['tools/test/test-keycode-data-js-parity.cjs'], repro: 'node tools/test/test-keycode-data-js-parity.cjs' },
	{ name: 'tooltip corpus parity (JSON corpus matches JS layoutTestVectors + dequeueTestVectors; P0-G)', cmd: 'node', args: ['tools/test/test-tooltip-corpus-parity.cjs'], repro: 'node tools/test/test-tooltip-corpus-parity.cjs' },
	{ name: 'TOML coercion parity (corpus cross-driver gate; P0-G)', cmd: 'node', args: ['tools/test/test-toml-coercion-parity.cjs'], repro: 'node tools/test/test-toml-coercion-parity.cjs' },
	{ name: 'shared test.format single source (inspect/deep_equal/fail_msg_for consumed from _shared, no local copies; P0 SSoT)', cmd: 'node', args: ['tools/test/test-shared-test-format.cjs'], repro: 'node tools/test/test-shared-test-format.cjs' },
	{ name: 'file watchers constants single source (SCAN_MAX_DEPTH=16 + debounce=0.5s match across Linux + macOS lib/file_watchers.lua; P0 SSoT)', cmd: 'node', args: ['tools/test/test-file-watchers-constants-single-source.cjs'], repro: 'node tools/test/test-file-watchers-constants-single-source.cjs' },
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
