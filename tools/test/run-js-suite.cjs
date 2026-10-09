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
 *    in isolation plus bounded opening and closing output and process status.
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
	{
		name: 'macOS native PAC and WPAD qualification requires all twelve original cases',
		cmd: process.execPath,
		args: ['tools/test/test-macos-native-pac-qualification.cjs'],
		repro: 'npm run test:macos-native-pac-qualification'
	},
	{
		name: 'macOS archive qualification requires exact native cases and compiler inputs',
		cmd: process.execPath,
		args: ['tools/test/test-item36-native-qualification.cjs'],
		repro: 'node tools/test/test-item36-native-qualification.cjs'
	},
	{
		name: 'Signed native query CI publisher retains compiler and nested-signature provenance',
		cmd: process.execPath,
		args: ['tools/test/test-automation-query-ci-publisher.cjs'],
		repro: 'npm run test:automation-query-ci-publisher'
	},
	{
		name: 'dev156 qualification deferrals retain full default execution and strict accounting',
		cmd: process.execPath,
		args: ['tools/test/test-dev-release-qualification.cjs'],
		repro: 'npm run test:dev-release-qualification'
	},
	{
		name: 'macOS launch qualification retains strict source and lifecycle evidence',
		cmd: process.execPath,
		args: ['tools/test/test-macos-launch-qualification.cjs'],
		repro: 'node tools/test/test-macos-launch-qualification.cjs'
	},
	{
		name: 'macOS launch qualification models restore environment and owned resources',
		cmd: process.execPath,
		args: ['tools/test/test-macos-launch-qualification-lifetime.cjs'],
		repro: 'node tools/test/test-macos-launch-qualification-lifetime.cjs'
	},
	{
		name: 'source toolchain admission preserves genuine compiler, headers and checkout',
		cmd: process.execPath,
		args: ['tools/test/test-linux-source-toolchain.cjs'],
		repro: 'npm run test:linux-source-toolchain'
	},
	{
		name: 'openSUSE first-install prep and requested-capability diagnostics retain native refusal',
		cmd: process.execPath,
		args: ['tools/test/test-opensuse-first-install-tooling.cjs'],
		repro: 'npm run test:opensuse-first-install-tooling'
	},
	{
		name: 'Nix runtime receipts and hosted registration preserve native admission',
		cmd: process.execPath,
		args: ['tools/test/test-linux-nix-native.cjs'],
		repro: 'node tools/test/test-linux-nix-native.cjs'
	},
	{
		name: 'Ubuntu CI dependencies retain signed archive scope and native failure status',
		cmd: process.execPath,
		args: ['tools/test/test-ubuntu-ci-acquisition.cjs'],
		repro: 'npm run test:ubuntu-ci-acquisition'
	},
	{
		name: 'native typing consumer retains actual selection and KPI dependencies',
		cmd: process.execPath,
		args: ['tools/test/test-linux-typing-consumer-closure.cjs'],
		repro: 'node tools/test/test-linux-typing-consumer-closure.cjs'
	},
	{
		name: 'Windows packaging stamp preserves exact AHK source encoding',
		cmd: 'node',
		args: ['tools/test/test-windows-bundle-stamp-encoding.cjs'],
		repro: 'npm run test:windows-bundle-stamp-encoding'
	},
	{
		name: 'JS suite failures preserve error headlines and process status',
		cmd: 'node',
		args: ['tools/test/test-js-suite-failure-diagnostics.cjs'],
		repro: 'node tools/test/test-js-suite-failure-diagnostics.cjs'
	},
	{
		name: 'Agent Skills canonical tree matches the generated Claude mirror',
		cmd: 'node',
		args: ['tools/test/test-agent-skills-sync.cjs'],
		repro: 'npm run test:agent-skills'
	},
	{
		name: 'audit manifests and dedicated worktrees obey the portable workflow contract',
		cmd: 'node',
		args: ['tools/test/test-audit-workflow.cjs'],
		repro: 'npm run test:audit-workflow'
	},
	{
		name: 'verify-change distinguishes current regressions, historical debt, and environment failures',
		cmd: 'node',
		args: ['tools/test/test-verify-change-red-classification.cjs'],
		repro: 'npm run test:verify-red-classification'
	},
	{
		name: 'native AHK gates report parse failures without dialogs',
		cmd: 'node',
		args: ['tools/test/test-verify-change-ahk-launch.cjs'],
		repro: 'npm run test:verify-change-ahk-launch'
	},
	{
		name: 'Windows range stages acknowledge completed reads and failures',
		cmd: 'node',
		args: ['tools/test/test-windows-range-consumption.cjs'],
		repro: 'npm run test:windows-range-consumption'
	},
	{
		name: 'native WebView receives ranges through a private HTTPS mount',
		cmd: 'node',
		args: ['tools/test/test-windows-range-transport.cjs'],
		repro: 'npm run test:windows-range-transport'
	},
	{
		name: 'AHK E2E admission requires every pure and native Edit corpus result',
		cmd: process.execPath,
		args: ['tools/test/test-ahk-e2e-manifest.cjs'],
		repro: 'npm run test:ahk-e2e-manifest'
	},
	{
		name: 'AHK suite manifest rejects early completion before the slow tail',
		cmd: 'node',
		args: ['tools/test/test-ahk-suite-manifest.cjs'],
		repro: 'npm run test:ahk-suite-manifest'
	},
	{
		name: 'repository text resolves to LF on every platform',
		cmd: 'node',
		args: ['tools/test/test-repository-eol-policy.cjs'],
		repro: 'npm run test:repository-eol-policy'
	},
	{
		name: 'project RTK bootstrap stays pinned and network-free in CI',
		cmd: 'node',
		args: ['tools/test/test-rtk-project-integration.cjs'],
		repro: 'npm run test:project-rtk'
	},
	{
		name: 'tools spawn the Git for Windows bash through one resolver, never the WSL launcher',
		cmd: 'node',
		args: ['tools/test/test-bash-resolution.cjs'],
		repro: 'npm run test:bash-resolution'
	},
	{
		name: 'Node runtime is exact and single-sourced across CI and Unicode generation',
		cmd: 'node',
		args: ['tools/test/test-node-runtime-single-source.cjs'],
		repro: 'node tools/test/test-node-runtime-single-source.cjs'
	},
	{
		name: 'VS Code and Zed format on save with the repository Prettier only',
		cmd: 'node',
		args: ['tools/test/test-editor-format-on-save.cjs'],
		repro: 'npm run test:editor-format-on-save'
	},
	{
		name: 'domain pipeline (manifest, parity, ports, schema, read-sites, drift)',
		cmd: 'npm',
		args: ['run', '--silent', 'build:domain'],
		repro: 'npm run build:domain'
	},
	{
		name: 'hotstring priority parity (shared JSON ↔ AHK + Lua)',
		cmd: 'npm',
		args: ['run', '--silent', 'test:priority-parity'],
		repro: 'npm run test:priority-parity'
	},
	{
		name: 'translation key consistency audit',
		cmd: 'node',
		args: ['tools/lint/audit-translations.cjs'],
		repro: 'node tools/lint/audit-translations.cjs'
	},
	{
		name: 'convention lint (banners, spacing, section headers — strict)',
		cmd: 'npm',
		args: ['run', '--silent', 'lint:conventions:strict'],
		repro: 'npm run lint:conventions:strict'
	},
	{
		name: 'lint banner-marker safety (no hardcoded-prefix corruption of "--"-marker Lua banners)',
		cmd: 'node',
		args: ['tools/test/test-lint-banner-marker-safety.cjs'],
		repro: 'node tools/test/test-lint-banner-marker-safety.cjs'
	},
	{
		name: 'LLM legacy_ids + BASIC_PROMPT single source',
		cmd: 'node',
		args: ['tools/test/test-llm-legacy-basic-prompt-single-source.cjs'],
		repro: 'node tools/test/test-llm-legacy-basic-prompt-single-source.cjs'
	},
	{
		name: 'locale display order single source (locale_order.json ↔ macOS + Windows + Linux + site)',
		cmd: 'node',
		args: ['tools/test/test-locale-order-single-source.cjs'],
		repro: 'node tools/test/test-locale-order-single-source.cjs'
	},
	{
		name: 'no generator stamps the current date into its output (drift must mean drift)',
		cmd: 'node',
		args: ['tools/test/test-generated-output-is-time-independent.cjs'],
		repro: 'node tools/test/test-generated-output-is-time-independent.cjs'
	},
	{
		name: 'architecture diagram (ports resolve + architecture.md in sync)',
		cmd: 'node',
		args: ['tools/test/test-architecture-diagram.cjs'],
		repro: 'node tools/test/test-architecture-diagram.cjs'
	},
	{
		name: 'dev-tool paths (private-AHK workflow points at live paths)',
		cmd: 'node',
		args: ['tools/test/test-dev-tool-paths.cjs'],
		repro: 'node tools/test/test-dev-tool-paths.cjs'
	},
	{
		name: 'fast repeating timers are inventoried (no silent poller)',
		cmd: 'node',
		args: ['tools/test/test-fast-timer-inventory.cjs'],
		repro: 'node tools/test/test-fast-timer-inventory.cjs'
	},
	{
		name: 'metrics categories are id-keyed (colours survive a language switch)',
		cmd: 'node',
		args: ['tools/test/test-metrics-category-ids.cjs'],
		repro: 'node tools/test/test-metrics-category-ids.cjs'
	},
	{
		name: 'metrics apps revision-aware publication ordering',
		cmd: 'node',
		args: ['tools/test/test-metrics-apps-publication-order.cjs'],
		repro: 'npm run test:metrics-apps-publication-order'
	},
	{
		name: 'metrics filter projection caches and native invalidation',
		cmd: 'node',
		args: ['tools/test/test-metrics-filter-cache.cjs'],
		repro: 'npm run test:metrics-filter-cache'
	},
	{
		name: 'native menu flags preserve authoritative PNG pixels',
		cmd: 'node',
		args: ['tools/test/test-native-menu-flags.cjs'],
		repro: 'npm run test:native-menu-flags'
	},
	{
		name: 'typing metrics mailbox ownership',
		cmd: 'node',
		args: ['tools/test/test-typing-metrics-mailbox-ownership.cjs'],
		repro: 'npm run test:typing-metrics-mailbox'
	},
	{
		name: 'typing metrics revision-aware publication ordering',
		cmd: 'node',
		args: ['tools/test/test-typing-metrics-publication-ordering.cjs'],
		repro: 'npm run test:typing-metrics-publication-order'
	},
	{
		name: 'typing metrics range selection supersession',
		cmd: 'node',
		args: ['tools/test/test-typing-metrics-range-supersession.cjs'],
		repro: 'npm run test:typing-metrics-range-supersession'
	},
	{
		name: 'typing metrics reset transaction ownership',
		cmd: 'node',
		args: ['tools/test/test-typing-metrics-reset-transaction.cjs'],
		repro: 'npm run test:typing-metrics-reset'
	},
	{
		name: 'shared menu delegation follows reachable methods and refuses dormant or removed providers',
		cmd: 'node',
		args: ['tools/test/test-menu-shared-delegation.cjs'],
		repro: 'node tools/test/test-menu-shared-delegation.cjs'
	},
	{
		name: 'every menu-manifest field and section has a driver that reads it (no decorative declarations)',
		cmd: 'node',
		args: ['tools/test/test-menu-manifest-keys-have-readers.cjs'],
		repro: 'node tools/test/test-menu-manifest-keys-have-readers.cjs'
	},
	{
		name: 'no new menu row built outside the renderer (I3 ratchet — windows 220, macos 301, linux 3)',
		cmd: 'node',
		args: ['tools/test/test-menu-rows-outside-renderer.cjs'],
		repro: 'node tools/test/test-menu-rows-outside-renderer.cjs'
	},
	{
		name: 'every declared menu row has a handler in its driver (I3 ratchet — ahk 0, hs 5, linux 0)',
		cmd: 'node',
		args: ['tools/test/test-menu-action-handler-bijection.cjs'],
		repro: 'node tools/test/test-menu-action-handler-bijection.cjs'
	},
	{
		name: 'every registered menu row matches its declared type (handler slot vs provider slot)',
		cmd: 'node',
		args: ['tools/test/test-menu-provider-kind-matches-type.cjs'],
		repro: 'node tools/test/test-menu-provider-kind-matches-type.cjs'
	},
	{
		name: 'top-level menu shape agrees across the three drivers (I3 — the manifest finally has a Linux dimension)',
		cmd: 'node',
		args: ['tools/test/test-menu-top-level-parity.cjs'],
		repro: 'node tools/test/test-menu-top-level-parity.cjs'
	},
	{
		name: 'the whole menu tree agrees across the three drivers, submenus included (I3 — no empty submenu, no orphaned header, no unread getter)',
		cmd: 'node',
		args: ['tools/test/test-menu-parity.cjs'],
		repro: 'node tools/test/test-menu-parity.cjs'
	},
	{
		name: 'every top-level menu title reads ONE shared key on every driver that has it',
		cmd: 'node',
		args: ['tools/test/test-menu-titles-single-key.cjs'],
		repro: 'node tools/test/test-menu-titles-single-key.cjs'
	},
	{
		name: 'every declared menu is answered by every driver that shows it (per-category coverage)',
		cmd: 'node',
		args: ['tools/test/test-menu-category-coverage.cjs'],
		repro: 'node tools/test/test-menu-category-coverage.cjs'
	},
	{
		name: 'every feature submenu opens with its category switch, registered by every driver that shows it',
		cmd: 'node',
		args: ['tools/test/test-menu-toggle-registered.cjs'],
		repro: 'node tools/test/test-menu-toggle-registered.cjs'
	},
	{
		name: 'Enable all / Disable all stay retired on every driver (manifest rows, locale keys, handlers)',
		cmd: 'node',
		args: ['tools/test/test-menu-enable-disable-all-retired.cjs'],
		repro: 'node tools/test/test-menu-enable-disable-all-retired.cjs'
	},
	{
		name: 'the circular Spaces toggle stays retired (no setting, row, label or handler; existing data survives until cleanup)',
		cmd: 'node',
		args: ['tools/test/test-space-wrap-toggle-retired.cjs'],
		repro: 'npm run test:space-wrap-retired'
	},
	{
		name: 'every restore / clear row reads the two shared labels (restore recommended, clear to system)',
		cmd: 'node',
		args: ['tools/test/test-menu-reset-terminology.cjs'],
		repro: 'node tools/test/test-menu-reset-terminology.cjs'
	},
	{
		name: 'every settings menu opens with its switch, restore and clear, then a separator (menu-first-group)',
		cmd: 'node',
		args: ['tools/test/test-menu-first-group.cjs'],
		repro: 'npm run test:menu-first-group'
	},
	{
		name: 'the wrap toggle and its symbols form one group, named without AltGr (shortcuts-wrap-group)',
		cmd: 'node',
		args: ['tools/test/test-shortcuts-wrap-group.cjs'],
		repro: 'npm run test:shortcuts-wrap-group'
	},
	{
		name: 'a row a platform lacks is declared hidden (not applicable) or greyed with its reason (not yet ported)',
		cmd: 'node',
		args: ['tools/test/test-menu-unavailable-rows.cjs'],
		repro: 'npm run test:menu-unavailable-rows'
	},
	{
		name: 'no driver builds more menu rows outside the shared manifest than its baseline (native-menu-rows ratchet)',
		cmd: 'node',
		args: ['tools/test/test-native-menu-rows.cjs'],
		repro: 'npm run test:native-menu-rows'
	},
	{
		name: 'native-menu census admits migration to zero only with intact legacy detection and complete source coverage',
		cmd: 'node',
		args: ['tools/test/test-native-menu-census-admission.cjs'],
		repro: 'node tools/test/test-native-menu-census-admission.cjs'
	},
	{
		name: 'no restore or clear row asks a question on any driver (restore-recommended-no-confirm)',
		cmd: 'node',
		args: ['tools/test/test-restore-recommended-no-confirm.cjs'],
		repro: 'npm run test:restore-recommended-no-confirm'
	},
	{
		name: 'approved menu labels keep their wording and are translated in every locale',
		cmd: 'node',
		args: ['tools/test/test-approved-menu-labels.cjs'],
		repro: 'node tools/test/test-approved-menu-labels.cjs'
	},
	{
		name: 'one hold picker: the same options in the same order on every driver, from one shared table',
		cmd: 'node',
		args: ['tools/test/test-tap-hold-hold-options-parity.cjs'],
		repro: 'node tools/test/test-tap-hold-hold-options-parity.cjs'
	},
	{
		name: 'one tap-hold key catalogue: order, hands and labels shared, each column its engine, read by every tray',
		cmd: 'node',
		args: ['tools/test/test-tap-hold-key-catalog-single-source.cjs'],
		repro: 'node tools/test/test-tap-hold-key-catalog-single-source.cjs'
	},
	{
		name: 'one table for what the one-shot Shift types, read by Windows and Linux',
		cmd: 'node',
		args: ['tools/test/test-tap-hold-one-shot-results-single-source.cjs'],
		repro: 'node tools/test/test-tap-hold-one-shot-results-single-source.cjs'
	},
	{
		name: 'the hotstring category submenus agree across the three drivers (same controls, same order)',
		cmd: 'node',
		args: ['tools/test/test-hotstring-category-submenu-order.cjs'],
		repro: 'node tools/test/test-hotstring-category-submenu-order.cjs'
	},
	{
		name: 'hotstring language packs are complete data and every section ships disabled',
		cmd: 'node',
		args: ['tools/test/test-hotstring-language-packs.cjs'],
		repro: 'node tools/test/test-hotstring-language-packs.cjs'
	},
	{
		name: 'the hotstrings windows are one shared UI, and every driver bridge answers every action it sends',
		cmd: 'node',
		args: ['tools/test/test-hotstrings-bridge-parity.cjs'],
		repro: 'node tools/test/test-hotstrings-bridge-parity.cjs'
	},
	{
		name: 'no Lua 5.2+ constructs where LuaJIT has to load them (the interpreter CI and the daemon actually run)',
		cmd: 'node',
		args: ['tools/test/test-luajit-52-isms.cjs'],
		repro: 'node tools/test/test-luajit-52-isms.cjs'
	},
	{
		name: 'every skipped conformance case names a ledger row (skips are data, not prose)',
		cmd: 'node',
		args: ['tools/test/test-conformance-skips-declared.cjs'],
		repro: 'node tools/test/test-conformance-skips-declared.cjs'
	},
	{
		name: 'every script a git hook invokes exists (a moved script breaks the next commit that trips it)',
		cmd: 'node',
		args: ['tools/test/test-hook-scripts-exist.cjs'],
		repro: 'node tools/test/test-hook-scripts-exist.cjs'
	},
	{
		name: 'shared .lua/.toml/.json use LF (the AHK half is covered by test:ahk-encoding)',
		cmd: 'node',
		args: ['tools/test/test-shared-sources-are-lf.cjs'],
		repro: 'node tools/test/test-shared-sources-are-lf.cjs'
	},
	{
		name: 'no driver-namespaced manifest table (I2 — a feature lives at its semantic path, never under a driver)',
		cmd: 'node',
		args: ['tools/test/test-feature-namespace-ratchet.cjs'],
		repro: 'node tools/test/test-feature-namespace-ratchet.cjs'
	},
	{
		name: 'single-driver features reach only their own driver (platforms inherit from the section — pin them)',
		cmd: 'node',
		args: ['tools/test/test-driver-scoped-features-stay-scoped.cjs'],
		repro: 'node tools/test/test-driver-scoped-features-stay-scoped.cjs'
	},
	{
		name: 'platform-restriction reasons reach a reader (absences shipped, translated, consumed)',
		cmd: 'node',
		args: ['tools/test/test-reason-keys-are-readable.cjs'],
		repro: 'node tools/test/test-reason-keys-are-readable.cjs'
	},
	{
		name: 'no new unexplained platform restriction (I2 ratchet — 138 today; run with --report for the inventory)',
		cmd: 'node',
		args: ['tools/test/test-platform-restrictions-explained.cjs'],
		repro: 'node tools/test/test-platform-restrictions-explained.cjs --report'
	},
	{
		name: 'every declared action chord is well formed (I4 — an unknown modifier fires the wrong shortcut silently)',
		cmd: 'node',
		args: ['tools/test/test-action-chord-notation.cjs'],
		repro: 'node tools/test/test-action-chord-notation.cjs'
	},
	{
		name: 'one generated action catalogue per driver (strict schema, pruned headings, localized keys in 21 locales, runtime parity test in every driver suite)',
		cmd: 'node',
		args: ['tools/test/test-action-catalogue-codegen.cjs'],
		repro: 'npm run test:action-catalogue-codegen'
	},
	{
		name: 'the Karabiner and gesture action namespaces are one (54 tappable reachable, 19 hold-only out, no doubled keystroke)',
		cmd: 'node',
		args: ['tools/test/test-karabiner-namespace-is-merged.cjs'],
		repro: 'node tools/test/test-karabiner-namespace-is-merged.cjs'
	},
	{
		name: 'Karabiner binary paths declared once (a v16-style rename must not reach 3 of 4 copies)',
		cmd: 'node',
		args: ['tools/test/test-karabiner-binary-paths-single-source.cjs'],
		repro: 'node tools/test/test-karabiner-binary-paths-single-source.cjs'
	},
	{
		name: 'WPM divisor single source (Lua drivers use the shared constant; WebView copies frozen at 5)',
		cmd: 'node',
		args: ['tools/test/test-wpm-chars-per-word-single-source.cjs'],
		repro: 'node tools/test/test-wpm-chars-per-word-single-source.cjs'
	},
	{
		name: 'prompt-builder constants agree across Lua, JS and the generated AHK (all 10)',
		cmd: 'node',
		args: ['tools/test/test-prompt-builder-constants-parity.cjs'],
		repro: 'node tools/test/test-prompt-builder-constants-parity.cjs'
	},
	{
		name: 'every corpus field is read by a replay or documented as descriptive',
		cmd: 'node',
		args: ['tools/test/test-corpus-fields-are-read.cjs'],
		repro: 'node tools/test/test-corpus-fields-are-read.cjs'
	},
	{
		name: 'every source path a packaging script copies exists (no suite runs a build)',
		cmd: 'node',
		args: ['tools/test/test-packaging-paths-exist.cjs'],
		repro: 'node tools/test/test-packaging-paths-exist.cjs'
	},
	{
		name: 'every app window keeps the shared frame on macOS, Windows and Linux (no edgeless window)',
		cmd: 'node',
		args: ['tools/test/test-app-windows-keep-their-frame.cjs'],
		repro: 'node tools/test/test-app-windows-keep-their-frame.cjs'
	},
	{
		name: 'website stable downloads survive a page of newer prereleases',
		cmd: 'node',
		args: ['tools/test/test-site-github-release.cjs'],
		repro: 'node tools/test/test-site-github-release.cjs'
	},
	{
		name: 'every asset the release notes link to is uploaded by a build job (no dead download button)',
		cmd: 'node',
		args: ['tools/test/test-release-notes-assets-are-uploaded.cjs'],
		repro: 'node tools/test/test-release-notes-assets-are-uploaded.cjs'
	},
	{
		name: 'every macOS/Linux package build stamps the commit its diagnostics report (no "unknown" in a release)',
		cmd: 'node',
		args: ['tools/test/test-package-builds-stamp-commit.cjs'],
		repro: 'node tools/test/test-package-builds-stamp-commit.cjs'
	},
	{
		name: 'every registered action resolves a label in all 21 locales',
		cmd: 'node',
		args: ['tools/test/test-action-labels-have-locale-keys.cjs'],
		repro: 'node tools/test/test-action-labels-have-locale-keys.cjs'
	},
	{
		name: 'Linux install.sh leaves a working first install (sandboxed real run)',
		cmd: 'node',
		args: ['tools/test/test-linux-install-sandbox.cjs'],
		repro: 'node tools/test/test-linux-install-sandbox.cjs'
	},
	{
		name: 'Linux native packages provision graphical input access',
		cmd: 'node',
		args: ['tools/test/test-linux-package-setup.cjs'],
		repro: 'npm run test:linux-package-setup'
	},
	{
		name: 'Linux login startup preserves explicit user choices',
		cmd: 'node',
		args: ['tools/test/test-linux-start-at-login.cjs'],
		repro: 'npm run test:linux-start-at-login'
	},
	{
		name: 'Linux uninstall preserves personal data and rejects unrelated installations',
		cmd: 'node',
		args: ['tools/test/test-linux-uninstall-sandbox.cjs'],
		repro: 'npm run test:linux-uninstall-sandbox'
	},
	{
		name: 'Windows uninstall requires terminal authorization and preserves replaced files',
		cmd: 'node',
		args: ['tools/test/test-windows-uninstall.cjs'],
		repro: 'npm run test:windows-uninstall'
	},
	{
		name: 'Linux tray icons mirror the Ergopti logo byte for byte',
		cmd: 'node',
		args: ['tools/test/test-linux-tray-icon-assets.cjs'],
		repro: 'node tools/test/test-linux-tray-icon-assets.cjs'
	},
	{
		name: 'the apps metrics window keeps its state across the Linux poll',
		cmd: 'node',
		args: ['tools/test/test-metrics-apps-linux-poll.cjs'],
		repro: 'node tools/test/test-metrics-apps-linux-poll.cjs'
	},
	{
		name: 'shared pages only call translators that exist',
		cmd: 'node',
		args: ['tools/test/test-shared-ui-translators-defined.cjs'],
		repro: 'node tools/test/test-shared-ui-translators-defined.cjs'
	},
	{
		name: 'Linux modules resolve _shared through infra/paths.lua',
		cmd: 'node',
		args: ['tools/test/test-linux-shared-path-resolver.cjs'],
		repro: 'node tools/test/test-linux-shared-path-resolver.cjs'
	},
	{
		name: 'every _shared resolver executes and lands on a real file (Linux + macOS, and the unset-HOME fallback)',
		cmd: 'node',
		args: ['tools/test/test-shared-root-resolvers.cjs'],
		repro: 'node tools/test/test-shared-root-resolvers.cjs'
	},
	{
		name: 'driver-doc paths (no stale static/drivers in docs)',
		cmd: 'node',
		args: ['tools/test/test-doc-paths.cjs'],
		repro: 'node tools/test/test-doc-paths.cjs'
	},
	{
		name: 'no new location-pinned source reads in AHK tests (ratchet)',
		cmd: 'node',
		args: ['tools/test/test-no-pinned-source-reads.cjs'],
		repro: 'node tools/test/test-no-pinned-source-reads.cjs'
	},
	{
		name: 'no new location-pinned source reads in macOS tests (ratchet)',
		cmd: 'node',
		args: ['tools/test/test-no-pinned-source-reads-lua.cjs'],
		repro: 'node tools/test/test-no-pinned-source-reads-lua.cjs'
	},
	{
		name: 'macOS remap lease survives private-process SIGKILL through an exact-token LaunchAgent',
		cmd: 'node',
		args: ['tools/test/test-macos-remap-launchagent.cjs'],
		repro: 'npm run test:macos-remap-launchagent'
	},
	{
		name: 'AHK test coverage (every test_*.ahk reachable from run_all)',
		cmd: 'node',
		args: ['tools/test/test-ahk-test-coverage.cjs'],
		repro: 'node tools/test/test-ahk-test-coverage.cjs'
	},
	{
		name: 'AHK changed tests require transitive registration at every depth',
		cmd: 'node',
		args: ['tools/test/test-verify-change-ahk-registration.cjs'],
		repro: 'node tools/test/test-verify-change-ahk-registration.cjs'
	},
	{
		name: 'e2e gate symmetry (every driver e2e runner is selected by verify-change)',
		cmd: 'node',
		args: ['tools/test/test-e2e-gate-symmetry.cjs'],
		repro: 'node tools/test/test-e2e-gate-symmetry.cjs'
	},
	{
		name: 'verify-change recognizes multiline AHK definitions without accepting call sites',
		cmd: 'node',
		args: ['tools/test/test-verify-change-ahk-function-definitions.cjs'],
		repro: 'node tools/test/test-verify-change-ahk-function-definitions.cjs'
	},
	{
		name: 'shared-contract gate coverage (_shared/core + _shared/tests select all three driver suites)',
		cmd: 'node',
		args: ['tools/test/test-shared-contract-gate-coverage.cjs'],
		repro: 'node tools/test/test-shared-contract-gate-coverage.cjs'
	},
	{
		name: 'shared Lua sources select both consumer unit and E2E gates',
		cmd: 'node',
		args: ['tools/test/test-shared-lua-gate-coverage.cjs'],
		repro: 'node tools/test/test-shared-lua-gate-coverage.cjs'
	},
	{
		name: 'Git change paths preserve filenames and both renamed drivers',
		cmd: 'node',
		args: ['tools/test/test-verify-change-git-paths.cjs'],
		repro: 'npm run test:verify-change-git-paths'
	},
	{
		name: 'explicit full verification includes every declared gate',
		cmd: 'node',
		args: ['tools/test/test-verify-change-full-plan.cjs'],
		repro: 'npm run test:verify-change-full-plan'
	},
	{
		name: 'generated outputs have one execution owner without aggregate duplication',
		cmd: 'node',
		args: ['tools/test/test-generator-output-ownership.cjs'],
		repro: 'npm run test:generator-output-ownership'
	},
	{
		name: 'AHK parse coverage (Ahk2Exe compiles the whole #Include graph — Windows only, self-validating)',
		cmd: 'node',
		args: ['tools/test/test-ahk-parse-coverage.cjs'],
		repro: 'node tools/test/test-ahk-parse-coverage.cjs'
	},
	{
		name: 'AHK startup contract (early globals + actionable fatal diagnostics)',
		cmd: 'node',
		args: ['tools/test/test-ahk-startup-contract.cjs'],
		repro: 'node tools/test/test-ahk-startup-contract.cjs'
	},
	{
		name: 'AHK startup smoke requires fresh process-bound warm readiness (inert admission)',
		cmd: 'node',
		args: ['tools/test/test-ahk-startup-smoke-readiness.cjs'],
		repro: 'node tools/test/test-ahk-startup-smoke-readiness.cjs'
	},
	{
		name: 'full AHK startup smoke (real auto-execute to ready, isolated config)',
		cmd: 'node',
		args: ['tools/test/test-ahk-full-startup-smoke.cjs'],
		repro: 'node tools/test/test-ahk-full-startup-smoke.cjs'
	},
	{
		name: 'Kana installer refuses local execution and owns its native helper',
		cmd: 'node',
		args: ['tools/test/test-ci-kana-install.cjs'],
		repro: 'node tools/test/test-ci-kana-install.cjs'
	},
	{
		name: 'AHK runners are invoked (no run_*/bench_* file referenced by nothing)',
		cmd: 'node',
		args: ['tools/test/test-ahk-runners-are-invoked.cjs'],
		repro: 'node tools/test/test-ahk-runners-are-invoked.cjs'
	},
	{
		name: 'AHK runner references stream without retaining the full text corpus',
		cmd: 'node',
		args: ['tools/test/test-ahk-runner-scan-streaming.cjs'],
		repro: 'node tools/test/test-ahk-runner-scan-streaming.cjs'
	},
	{
		name: 'AHK runner rejects malformed filters before loading tests',
		cmd: 'node',
		args: ['tools/test/test-ahk-runner-arguments.cjs'],
		repro: 'npm run test:ahk-runner-arguments'
	},
	{
		name: 'AHK loop capture (no closure over a for-loop variable, no looped Test registration closing over the loop)',
		cmd: 'node',
		args: ['tools/test/test-ahk-loop-capture.cjs'],
		repro: 'node tools/test/test-ahk-loop-capture.cjs'
	},
	{
		name: 'Lua closure-binds-nil-global (ratchet against the fourth recurrence of the hs.task GC-pin trap)',
		cmd: 'node',
		args: ['tools/test/test-lua-closure-before-local.cjs'],
		repro: 'node tools/test/test-lua-closure-before-local.cjs'
	},
	{
		name: 'glossaries match the code (port count + names derived from _shared/core/ports, no retired driver dirs)',
		cmd: 'node',
		args: ['tools/test/test-glossary-matches-code.cjs'],
		repro: 'node tools/test/test-glossary-matches-code.cjs'
	},
	{
		name: 'Linux menu i18n keys exist (every i18n_safe key is defined in en.json)',
		cmd: 'node',
		args: ['tools/test/test-linux-menu-keys-exist.cjs'],
		repro: 'node tools/test/test-linux-menu-keys-exist.cjs'
	},
	{
		name: 'source encoding (no double-encoded UTF-8, no repeated BOM, valid UTF-8 — every driver)',
		cmd: 'node',
		args: ['tools/test/test-source-encoding.cjs'],
		repro: 'node tools/test/test-source-encoding.cjs'
	},
	{
		name: 'AHK v2.0 parse-breakers (v1 quotes / block-body arrows that abort the whole suite)',
		cmd: 'node',
		args: ['tools/test/test-ahk-v2-syntax-antipatterns.cjs'],
		repro: 'node tools/test/test-ahk-v2-syntax-antipatterns.cjs'
	},
	{
		name: 'unified reporter parses TAP + Lua output (report.cjs)',
		cmd: 'node',
		args: ['tools/test/test-report.cjs'],
		repro: 'node tools/test/test-report.cjs'
	},
	{
		name: 'max_tokens single source (no literal default in backend adapters)',
		cmd: 'node',
		args: ['tools/test/test-max-tokens-single-source.cjs'],
		repro: 'node tools/test/test-max-tokens-single-source.cjs'
	},
	{
		name: 'model-identity normaliser single source (one rule for active + installed)',
		cmd: 'node',
		args: ['tools/test/test-model-identity-single-source.cjs'],
		repro: 'node tools/test/test-model-identity-single-source.cjs'
	},
	{
		name: 'Lua test fixtures stay out of the repository (no working-directory fallback)',
		cmd: 'node',
		args: ['tools/test/test-lua-fixtures-stay-out-of-the-repo.cjs'],
		repro: 'node tools/test/test-lua-fixtures-stay-out-of-the-repo.cjs'
	},
	{
		name: 'temperature single source (no literal 0.1 default in macOS adapters)',
		cmd: 'node',
		args: ['tools/test/test-temperature-single-source.cjs'],
		repro: 'node tools/test/test-temperature-single-source.cjs'
	},
	{
		name: 'ollama port single source (no hardcoded port literal in AHK LLM files)',
		cmd: 'node',
		args: ['tools/test/test-ollama-port-single-source.cjs'],
		repro: 'node tools/test/test-ollama-port-single-source.cjs'
	},
	{
		name: 'Linux LLM defaults single source (temp/port/context/keep_alive from _shared canonicals)',
		cmd: 'node',
		args: ['tools/test/test-linux-llm-defaults-single-source.cjs'],
		repro: 'node tools/test/test-linux-llm-defaults-single-source.cjs'
	},
	{
		name: 'API test-request single source (probe text lives in api_providers.json only)',
		cmd: 'node',
		args: ['tools/test/test-llm-test-request-single-source.cjs'],
		repro: 'node tools/test/test-llm-test-request-single-source.cjs'
	},
	{
		name: 'API model-extras single source (per-model body fields live in api_providers.json only)',
		cmd: 'node',
		args: ['tools/test/test-llm-model-extras-single-source.cjs'],
		repro: 'node tools/test/test-llm-model-extras-single-source.cjs'
	},
	{
		name: 'locale resolution single source (macOS+Linux wrappers delegate to shared locale.core)',
		cmd: 'node',
		args: ['tools/test/test-locale-resolution-single-source.cjs'],
		repro: 'node tools/test/test-locale-resolution-single-source.cjs'
	},
	{
		name: 'webview i18n browser-fallback path (bridge-less locale fetch resolves)',
		cmd: 'node',
		args: ['tools/test/test-i18n-fallback-path.cjs'],
		repro: 'node tools/test/test-i18n-fallback-path.cjs'
	},
	{
		name: 'webview i18n fallback cascade (a failed locale fetch must not blank the page)',
		cmd: 'node',
		args: ['tools/test/test-webview-i18n-cascade.cjs'],
		repro: 'node tools/test/test-webview-i18n-cascade.cjs'
	},
	{
		name: 'webview host strings survive the page locale fetch (no raw keys on macOS pages)',
		cmd: 'node',
		args: ['tools/test/test-webview-host-strings-survive-failed-fetch.cjs'],
		repro: 'npm run test:webview-host-strings-survive-failed-fetch'
	},
	{
		name: 'shared pages never show a raw locale key (keys in en.json, catalogue delivered and shipped)',
		cmd: 'node',
		args: ['tools/test/test-shared-pages-never-show-raw-keys.cjs'],
		repro: 'npm run test:shared-pages-never-show-raw-keys'
	},
	{
		name: 'menu labels single source (shared labels.lua consumed by macOS)',
		cmd: 'node',
		args: ['tools/test/test-menu-labels-single-source.cjs'],
		repro: 'node tools/test/test-menu-labels-single-source.cjs'
	},
	{
		name: 'diagnostic snapshot fields, vectors and boot emission agree across the three drivers',
		cmd: 'node',
		args: ['tools/test/test-diagnostic-snapshot-parity.cjs'],
		repro: 'npm run test:diagnostic-snapshot-parity'
	},
	{
		name: 'Linux version single source (one BUNDLE_VERSION-style source, no re-typed 3.0.0; P0-E)',
		cmd: 'node',
		args: ['tools/test/test-linux-version-single-source.cjs'],
		repro: 'node tools/test/test-linux-version-single-source.cjs'
	},
	{
		name: 'hotstring buffer-cap parity (shared BUFFER_MAX_CHARS == both Windows mirrors; P0-F)',
		cmd: 'node',
		args: ['tools/test/test-hotstring-buffer-cap-parity.cjs'],
		repro: 'node tools/test/test-hotstring-buffer-cap-parity.cjs'
	},
	{
		name: 'LLM model + GPT link single source (no re-typed default literals in AHK)',
		cmd: 'node',
		args: ['tools/test/test-llm-model-single-source.cjs'],
		repro: 'node tools/test/test-llm-model-single-source.cjs'
	},
	{
		name: 'version compare parity (JS over shared vectors; AHK+macOS suites read the same table)',
		cmd: 'node',
		args: ['tools/test/test-version-compare-contract.cjs'],
		repro: 'node tools/test/test-version-compare-contract.cjs'
	},
	{
		name: 'showcase page lists each catalogue action on exactly its declared drivers',
		cmd: 'node',
		args: ['tools/test/test-showcase-action-platforms.cjs'],
		repro: 'npm run test:showcase-action-platforms'
	},
	{
		name: 'LLM stop-sequences single source (no re-inlined literals in backends)',
		cmd: 'node',
		args: ['tools/test/test-llm-stop-sequences-single-source.cjs'],
		repro: 'node tools/test/test-llm-stop-sequences-single-source.cjs'
	},
	{
		name: 'shared TOML codec purity (no hard driver requires — loads on every Lua runtime)',
		cmd: 'node',
		args: ['tools/test/test-shared-toml-codec-purity.cjs'],
		repro: 'node tools/test/test-shared-toml-codec-purity.cjs'
	},
	{
		name: 'no fallback literals (LLM defaults read from JSON, never a deleted mirror)',
		cmd: 'node',
		args: ['tools/test/test-no-fallback-literals.cjs'],
		repro: 'node tools/test/test-no-fallback-literals.cjs'
	},
	{
		name: 'cross-driver manifest equivalence (resolved values identical across drivers)',
		cmd: 'node',
		args: ['tools/test/test-manifest-equivalence.cjs'],
		repro: 'node tools/test/test-manifest-equivalence.cjs'
	},
	{
		name: 'webview geometry single source (macOS defers to manifest; Windows literals match; P0-A)',
		cmd: 'node',
		args: ['tools/test/test-webview-geometry-single-source.cjs'],
		repro: 'node tools/test/test-webview-geometry-single-source.cjs'
	},
	{
		name: 'diagnostic UI integrity (macOS + Windows healthcheck render path)',
		cmd: 'node',
		args: ['tools/test/test-diagnostic-ui-integrity.cjs'],
		repro: 'node tools/test/test-diagnostic-ui-integrity.cjs'
	},
	{
		name: 'GitHub issue link builder replays its vectors (bounded, UTF-8 percent-encoded prefill)',
		cmd: 'node',
		args: ['tools/test/test-issue-link-vectors.cjs'],
		repro: 'node tools/test/test-issue-link-vectors.cjs'
	},
	{
		name: 'diagnostics page redactor replays the Lua and AHK redaction vectors',
		cmd: 'node',
		args: ['tools/test/test-diagnostics-redaction-vectors.cjs'],
		repro: 'node tools/test/test-diagnostics-redaction-vectors.cjs'
	},
	{
		name: 'diagnostics page model renders, summarises and exports the v2 schema on every driver, in 21 locales',
		cmd: 'node',
		args: ['tools/test/test-healthcheck-model.cjs'],
		repro: 'node tools/test/test-healthcheck-model.cjs'
	},
	{
		name: 'diagnostics page behaviour (ready, preview of what is shared, buttons by id, details, probes, report mode)',
		cmd: 'node',
		args: ['tools/test/test-healthcheck-page.cjs'],
		repro: 'node tools/test/test-healthcheck-page.cjs'
	},
	{
		name: 'error window page behaviour (ready, report shown as sent, crash notice, buttons by name, folds, results, 21 locales)',
		cmd: 'node',
		args: ['tools/test/test-error-dialog-page.cjs'],
		repro: 'npm run test:error-dialog-page'
	},
	{
		name: 'update-check page (checking, up to date, new release, no release, failure, other channels, 21 locales, centered)',
		cmd: 'node',
		args: ['tools/test/test-update-check-dialog.cjs'],
		repro: 'npm run test:update-check-dialog'
	},
	{
		name: 'configuration cleanup page (long lists, literal values, session actions, 21 locales)',
		cmd: 'node',
		args: ['tools/test/test-config-cleanup-page.cjs'],
		repro: 'npm run test:config-cleanup-page'
	},
	{
		name: 'GitHub issue forms declare every field the app prefills, and a worst-case prefill fits the URL budget',
		cmd: 'node',
		args: ['tools/test/test-issue-templates.cjs'],
		repro: 'node tools/test/test-issue-templates.cjs'
	},
	{
		name: 'repository URL single source (every GitHub link derives from the updater defaults)',
		cmd: 'node',
		args: ['tools/test/test-repo-url-single-source.cjs'],
		repro: 'node tools/test/test-repo-url-single-source.cjs'
	},
	{
		name: 'UI windows are focused, never kept on top (macOS, Windows, Linux) + no raw blockAlert',
		cmd: 'node',
		args: ['tools/test/test-ui-focus-fix.cjs'],
		repro: 'node tools/test/test-ui-focus-fix.cjs'
	},
	{
		name: 'click-lock fix (non-consuming watcher + keystroke release, both drivers)',
		cmd: 'node',
		args: ['tools/test/test-click-lock-fix.cjs'],
		repro: 'node tools/test/test-click-lock-fix.cjs'
	},
	{
		name: 'Hammerspoon integrity (no global leaks, M.stop present, shutdown wired)',
		cmd: 'node',
		args: ['tools/test/test-hammerspoon-integrity.cjs'],
		repro: 'node tools/test/test-hammerspoon-integrity.cjs'
	},
	{
		name: 'section-title decoration parity (single "— … —" source per driver, no re-inlining)',
		cmd: 'node',
		args: ['tools/test/test-section-decoration-parity.cjs'],
		repro: 'node tools/test/test-section-decoration-parity.cjs'
	},
	{
		name: 'macOS bundle layout (build script + launcher mirror the repo)',
		cmd: 'node',
		args: ['tools/test/test-macos-bundle-layout.cjs'],
		repro: 'node tools/test/test-macos-bundle-layout.cjs'
	},
	{
		name: 'macOS bundle payload ships every path the runtime reads and no excluded group',
		cmd: 'node',
		args: ['tools/test/test-macos-bundle-payload.cjs'],
		repro: 'npm run test:macos-bundle-payload'
	},
	{
		name: 'macOS app ships the keyboard layout bundle its menu resolves (no "No Ergopti bundle found")',
		cmd: 'node',
		args: ['tools/test/test-macos-keyboard-layout-bundle.cjs'],
		repro: 'npm run test:macos-keyboard-layout-bundle'
	},
	{
		name: 'macOS launcher universal binary (arm64 + x86_64 verified)',
		cmd: 'node',
		args: ['tools/test/test-macos-launcher-universal.cjs'],
		repro: 'node tools/test/test-macos-launcher-universal.cjs'
	},
	{
		name: 'macOS native launcher CI (release build + XCTest + success-only aggregate)',
		cmd: 'node',
		args: ['tools/test/test-macos-swift-launcher-ci.cjs'],
		repro: 'npm run test:macos-swift-launcher-ci'
	},
	{
		name: 'native Swift XCTest evidence preserves failures and original pipeline statuses',
		cmd: 'node',
		args: ['tools/test/test-swift-xctest-evidence.cjs'],
		repro: 'npm run test:swift-xctest-evidence'
	},
	{
		name: 'macOS native launcher local gate (plist + release build + XCTest, deferred off macOS)',
		cmd: 'node',
		args: ['tools/test/run-macos-swift-launcher.cjs'],
		repro: 'npm run test:macos-swift-launcher'
	},
	{
		name: 'Linux package layout (.deb/.rpm install into /usr/lib/ergopti; wrapper boots the same bundle entry)',
		cmd: 'node',
		args: ['tools/test/test-linux-package-layout.cjs'],
		repro: 'node tools/test/test-linux-package-layout.cjs'
	},
	{
		name: 'Linux bundle copies tracked bytes without per-file shell processes',
		cmd: 'node',
		args: ['tools/test/test-linux-tracked-copy.cjs'],
		repro: 'node tools/test/test-linux-tracked-copy.cjs'
	},
	{
		name: 'Linux portable network packages retain native ABI and command ownership',
		cmd: 'node',
		args: ['tools/test/test-linux-portable-network-runtime.cjs'],
		repro: 'npm run test:linux-portable-network-runtime'
	},
	{
		name: 'Linux portable native admission rejects incomplete and skipped receipts',
		cmd: 'node',
		args: ['tools/test/test-linux-portable-network-registration.cjs'],
		repro: 'npm run test:linux-portable-network-registration'
	},
	{
		name: 'Linux native FD digest admission requires completed physical receipts',
		cmd: 'node',
		args: ['tools/test/test-linux-fd-sha256-native-gate.cjs'],
		repro: 'npm run test:linux-fd-sha256-native-gate'
	},
	{
		name: 'Linux CI requires successful mandatory jobs and assertion evidence',
		cmd: 'node',
		args: ['tools/test/test-linux-ci-evidence.cjs'],
		repro: 'npm run test:linux-ci-evidence'
	},
	{
		name: 'Linux native window receipts retain mandatory npm, planner and CI owners',
		cmd: 'node',
		args: ['tools/test/test-linux-window-switch-registration.cjs'],
		repro: 'npm run test:linux-window-switch-registration'
	},
	{
		name: 'Linux native streaming receipts retain mandatory npm, planner and CI owners',
		cmd: 'node',
		args: ['tools/test/test-linux-http-stream-registration.cjs'],
		repro: 'npm run test:linux-http-stream-registration'
	},
	{
		name: 'Linux native runtime prerequisite gate retains both ABIs and mandatory receipts',
		cmd: 'node',
		args: ['tools/test/test-linux-runtime-native-registration.cjs'],
		repro: 'npm run test:linux-runtime-native-registration'
	},
	{
		name: 'Desktop verdicts and parallel shared-core gates',
		cmd: 'node',
		args: ['tools/test/test-desktop-ci-evidence.cjs'],
		repro: 'npm run test:desktop-ci-evidence'
	},
	{
		name: 'Windows native desktop cohorts require exact native completion and mandatory evidence',
		cmd: process.execPath,
		args: ['tools/test/test-windows-native-desktop.cjs'],
		repro: 'npm run test:windows-native-desktop'
	},
	{
		name: 'Compiled upgrade admission requires actual prior-package and committed full-save evidence',
		cmd: process.execPath,
		args: ['tools/test/test-compiled-save-upgrade.cjs'],
		repro: 'node tools/test/test-compiled-save-upgrade.cjs'
	},
	{
		name: 'macOS canvas job admission and pure Python ownership remain mandatory',
		cmd: 'node',
		args: ['tools/test/test-macos-tooltip-canvas-admission.cjs'],
		repro: 'npm run test:macos-tooltip-canvas-admission'
	},
	{
		name: 'Linux WebViews use pinned offline code and one bridge per page',
		cmd: 'node',
		args: ['tools/test/test-linux-webview-security.cjs'],
		repro: 'npm run test:linux-webview-security'
	},
	{
		name: 'Linux metrics polling follows native and document visibility lifecycles',
		cmd: 'node',
		args: ['tools/test/test-linux-metrics-webview-lifecycle.cjs'],
		repro: 'npm run test:linux-metrics-webview-lifecycle'
	},
	{
		name: 'Linux standalone upgrades refresh intact canonical packs and preserve explicit overrides',
		cmd: 'node',
		args: ['tools/test/test-linux-canonical-pack-upgrade.cjs'],
		repro: 'npm run test:linux-canonical-pack-upgrade'
	},
	{
		name: 'Linux checkout installs ship the layout registry and its Ergopti extension hotstrings',
		cmd: 'node',
		args: ['tools/test/test-linux-install-layout-registry.cjs'],
		repro: 'npm run test:linux-install-layout-registry'
	},
	{
		name: 'openSUSE CI package installs use the coherent origin instead of a redirecting mirror',
		cmd: 'node',
		args: ['tools/test/test-opensuse-ci-origin.cjs'],
		repro: 'node tools/test/test-opensuse-ci-origin.cjs'
	},
	{
		name: 'release packaging workflow (live Windows stamp path + no Linux pipefail/SIGPIPE trap)',
		cmd: 'node',
		args: ['tools/test/test-release-packaging-workflow.cjs'],
		repro: 'node tools/test/test-release-packaging-workflow.cjs'
	},
	{
		name: 'CI pipeline loader refuses every missing lookup and unreadable layout (fixture self-test)',
		cmd: 'node',
		args: ['tools/test/test-ci-pipeline.cjs'],
		repro: 'npm run test:ci-pipeline'
	},
	{
		name: 'Full default CI source admission preserves mandatory gates and bounded diagnostic policy',
		cmd: 'node',
		args: ['tools/test/test-ci-full-default.cjs'],
		repro: 'node tools/test/test-ci-full-default.cjs'
	},
	{
		name: 'CI pipeline wiring (one root, plan outputs, lane callers, secrets and permissions, no skippable job or gate step, release preflight before any side effect)',
		cmd: 'node',
		args: ['tools/test/test-ci-pipeline-wiring.cjs'],
		repro: 'npm run test:ci-pipeline-wiring'
	},
	{
		name: 'CI release re-runs (plan never republishes a tagged commit and bumps from every subject; the preflight resumes a half-published release or stops; the release and its feed publish what was gated)',
		cmd: 'node',
		args: ['tools/test/test-ci-release-reruns.cjs'],
		repro: 'npm run test:ci-release-reruns'
	},
	{
		name: 'Linux launcher starts where install.sh leaves a machine (no hard dep the installer skips; every exported shared path exists)',
		cmd: 'node',
		args: ['tools/test/test-linux-launcher-deps.cjs'],
		repro: 'node tools/test/test-linux-launcher-deps.cjs'
	},
	{
		name: 'Linux managed networking admits actual runtime after package repair',
		cmd: 'node',
		args: ['tools/test/test-linux-network-runtime.cjs'],
		repro: 'npm run test:linux-network-runtime'
	},
	{
		name: 'Linux native network runtime is registered and refuses omitted receipts',
		cmd: 'node',
		args: ['tools/test/test-linux-network-runtime-registration.cjs'],
		repro: 'npm run test:linux-network-runtime-registration'
	},
	{
		name: 'Managed native HTTP phase owners preserve original modeled closure protocol',
		cmd: 'node',
		args: ['tools/test/test-linux-managed-http-phase-protocol.cjs'],
		repro: 'npm run test:linux-managed-http-phase-protocol'
	},
	{
		name: 'Managed native HTTP CI admits authenticated tools and complete source-bound receipts',
		cmd: 'node',
		args: ['tools/test/test-linux-managed-http-ci-registration.cjs'],
		repro: 'npm run test:linux-managed-http-ci-registration'
	},
	{
		name: 'test:linux-updater-temp-receipt',
		cmd: 'node',
		args: ['tools/test/test-linux-updater-temp-native.cjs'],
		repro: 'npm run test:linux-updater-temp-receipt'
	},
	{
		name: 'test:linux-updater-temp-registration',
		cmd: 'node',
		args: ['tools/test/test-linux-updater-temp-registration.cjs'],
		repro: 'npm run test:linux-updater-temp-registration'
	},
	{
		name: 'test:linux-updater-archive-receipt',
		cmd: 'node',
		args: ['tools/test/test-linux-updater-archive-receipt.cjs'],
		repro: 'npm run test:linux-updater-archive-receipt'
	},
	{
		name: 'test:linux-updater-archive-registration',
		cmd: 'node',
		args: ['tools/test/test-linux-updater-archive-registration.cjs'],
		repro: 'npm run test:linux-updater-archive-registration'
	},
	{
		name: 'Linux native digest runtime preserves exact OpenSSL 3 projection and build owners',
		cmd: 'node',
		args: ['tools/test/test-linux-crypto-runtime.cjs'],
		repro: 'npm run test:linux-crypto-runtime'
	},
	{
		name: 'extension-pack paths resolve (every read site lands on a real pack; pre-reorg prefix ratcheted out)',
		cmd: 'node',
		args: ['tools/test/test-extensions-path-resolves.cjs'],
		repro: 'node tools/test/test-extensions-path-resolves.cjs'
	},
	{
		name: 'Windows exe bundle ships every file the driver and its pages read, and no test, Lua, doc or dev-only group',
		cmd: 'node',
		args: ['tools/test/test-windows-bundle-manifest.cjs'],
		repro: 'npm run test:windows-bundle-manifest'
	},
	{
		name: 'LLM logs carry no typed text (context length only, never a slice of the buffer)',
		cmd: 'node',
		args: ['tools/test/test-llm-no-prompt-content-in-logs.cjs'],
		repro: 'node tools/test/test-llm-no-prompt-content-in-logs.cjs'
	},
	{
		name: 'the preview bubble is rendered from the shared masking corpus (ratchet: which drivers carry it)',
		cmd: 'node',
		args: ['tools/test/test-preview-masking-cross-driver.cjs'],
		repro: 'node tools/test/test-preview-masking-cross-driver.cjs'
	},
	{
		name: 'LLM privacy defaults single-sourced (secure fields blocked, URL bars allowed, all three drivers)',
		cmd: 'node',
		args: ['tools/test/test-llm-privacy-defaults-cross-driver.cjs'],
		repro: 'node tools/test/test-llm-privacy-defaults-cross-driver.cjs'
	},
	{
		name: 'at-rest encryption envelope parity (marker/cipher/PBKDF2 identical across the three drivers)',
		cmd: 'node',
		args: ['tools/test/test-text-crypto-envelope-parity.cjs'],
		repro: 'node tools/test/test-text-crypto-envelope-parity.cjs'
	},
	{
		name: 'metrics privacy defaults single-sourced (one id per filter; no driver keeps a hardcoded copy)',
		cmd: 'node',
		args: ['tools/test/test-metrics-privacy-single-source.cjs'],
		repro: 'node tools/test/test-metrics-privacy-single-source.cjs'
	},
	{
		name: 'every log/persist sink that can carry a hotstring trigger is redacted or judged (derived list, not a written one)',
		cmd: 'node',
		args: ['tools/test/test-personal-info-log-sinks-are-judged.cjs'],
		repro: 'node tools/test/test-personal-info-log-sinks-are-judged.cjs'
	},
	{
		name: 'launcher single-instance guard (LSMultipleInstancesProhibited in Info.plist)',
		cmd: 'node',
		args: ['tools/test/test-launcher-single-instance.cjs'],
		repro: 'node tools/test/test-launcher-single-instance.cjs'
	},
	{
		name: 'menu manifest drift (feature paths + i18n keys resolve against manifest.toml)',
		cmd: 'node',
		args: ['tools/test/test-menu-manifest.cjs'],
		repro: 'node tools/test/test-menu-manifest.cjs'
	},
	{
		name: 'features manifest no-drift (every committed _generated/ file matches the live generator)',
		cmd: 'node',
		args: ['tools/test/test-features-manifest-no-drift.cjs'],
		repro: 'node tools/test/test-features-manifest-no-drift.cjs'
	},
	{
		name: 'drift guard detects targeted output changes and preserves exact edits',
		cmd: 'node',
		args: ['tools/test/test-drift-guard-covers-every-output.cjs'],
		repro: 'node tools/test/test-drift-guard-covers-every-output.cjs'
	},
	{
		name: 'drift coverage rejects invalid receipts and restores damaged targets',
		cmd: 'node',
		args: ['tools/test/test-drift-guard-coverage-oracle.cjs'],
		repro: 'node tools/test/test-drift-guard-coverage-oracle.cjs'
	},
	{
		name: 'drift restoration preserves healthy siblings after filesystem refusals',
		cmd: 'node',
		args: ['tools/test/test-drift-restore-refusal.cjs'],
		repro: 'node tools/test/test-drift-restore-refusal.cjs'
	},
	{
		name: 'hotstring corpus backspace_count is a logical count, not emitted keystrokes',
		cmd: 'node',
		args: ['tools/test/test-corpus-backspace-count-semantics.cjs'],
		repro: 'node tools/test/test-corpus-backspace-count-semantics.cjs'
	},
	{
		name: 'one menu_manifest.json reader per driver (macOS parsed it three times, two of them caches of the same file)',
		cmd: 'node',
		args: ['tools/test/test-menu-manifest-single-reader.cjs'],
		repro: 'node tools/test/test-menu-manifest-single-reader.cjs'
	},
	{
		name: 'is_word means the same thing on all three drivers (no trigger asks for a boundary it carries)',
		cmd: 'node',
		args: ['tools/test/test-is-word-flag-is-honoured-identically.cjs'],
		repro: 'node tools/test/test-is-word-flag-is-honoured-identically.cjs'
	},
	{
		name: 'logger scalars single-source (retention/ring/dedup/flush vs the timing registry)',
		cmd: 'node',
		args: ['tools/test/test-logger-scalars-single-source.cjs'],
		repro: 'node tools/test/test-logger-scalars-single-source.cjs'
	},
	{
		name: 'log file names single-source (only the generated app_dirs data spells a log prefix)',
		cmd: 'node',
		args: ['tools/test/test-log-file-names-single-source.cjs'],
		repro: 'npm run test:log-file-names-single-source'
	},
	{
		name: 'tap-hold shared defaults lifecycle (docs match what the three loaders do)',
		cmd: 'node',
		args: ['tools/test/test-tap-hold-defaults-lifecycle.cjs'],
		repro: 'node tools/test/test-tap-hold-defaults-lifecycle.cjs'
	},
	{
		name: 'locale native names single-source (every ordered locale is named, no driver copy)',
		cmd: 'node',
		args: ['tools/test/test-locale-names-single-source.cjs'],
		repro: 'node tools/test/test-locale-names-single-source.cjs'
	},
	{
		name: 'locale catalogue completeness (all 21 carry en.json key-for-key, nothing renders blank)',
		cmd: 'node',
		args: ['tools/test/test-locale-catalogue-complete.cjs'],
		repro: 'node tools/test/test-locale-catalogue-complete.cjs'
	},
	{
		name: 'a hint that names a menu row quotes the label the tray draws, in every locale',
		cmd: 'node',
		args: ['tools/test/test-locale-hints-quote-live-labels.cjs'],
		repro: 'node tools/test/test-locale-hints-quote-live-labels.cjs'
	},
	{
		name: 'generator registry runs (npm run gen: every declared output is produced)',
		cmd: 'node',
		args: ['tools/build/gen-all.cjs'],
		repro: 'npm run gen'
	},
	{
		name: 'new-driver scaffold emits one adapter per port spec (not zero)',
		cmd: 'node',
		args: ['tools/test/test-new-driver-scaffold.cjs'],
		repro: 'node tools/test/test-new-driver-scaffold.cjs'
	},
	{
		name: 'driver tree parity I1 (shared directory ratio, ratcheted)',
		cmd: 'node',
		args: ['tools/test/test-driver-tree-parity.cjs'],
		repro: 'node tools/test/test-driver-tree-parity.cjs --measure'
	},
	{
		name: 'stubs intercept something (no package.loaded key naming a missing module)',
		cmd: 'node',
		args: ['tools/test/test-stubs-intercept-something.cjs'],
		repro: 'node tools/test/test-stubs-intercept-something.cjs'
	},
	{
		name: 'action emit rows stay per-OS (13 of 24 keystrokes genuinely differ)',
		cmd: 'node',
		args: ['tools/test/test-action-emit-is-per-os.cjs'],
		repro: 'node tools/test/test-action-emit-is-per-os.cjs'
	},
	{
		name: 'macOS keyboard-slot config surface is reachable (readers called, writer binds, list entry has a provider)',
		cmd: 'node',
		args: ['tools/test/test-keyboard-slot-surface-is-live.cjs'],
		repro: 'node tools/test/test-keyboard-slot-surface-is-live.cjs'
	},
	{
		name: 'chord native mappings single source (adapter prefixes/key spellings + both slot vocabularies pinned to modifier_chords.json)',
		cmd: 'node',
		args: ['tools/test/test-chord-native-mapping-single-source.cjs'],
		repro: 'node tools/test/test-chord-native-mapping-single-source.cjs'
	},
	{
		name: 'port contract single source (contracts.json fresh from the spec.js files; every AHK ADAPTER_ map matches its contract)',
		cmd: 'node',
		args: ['tools/test/test-port-compliance.cjs'],
		repro: 'node tools/test/test-port-compliance.cjs'
	},
	{
		name: 'hotstring priority parity (priority.json honoured identically by the drivers)',
		cmd: 'node',
		args: ['tools/test/test-priority-parity.cjs'],
		repro: 'node tools/test/test-priority-parity.cjs'
	},
	{
		name: 'feature manifest parity (Windows, macOS, and Linux projections agree)',
		cmd: 'node',
		args: ['tools/test/test-manifest-parity.cjs'],
		repro: 'node tools/test/test-manifest-parity.cjs'
	},
	{
		name: 'neutral defaults and explicit recommended scopes',
		cmd: 'node',
		args: ['tools/test/test-defaults-single-source.cjs'],
		repro: 'node tools/test/test-defaults-single-source.cjs'
	},
	{
		name: 'Linux feature parity status (canonical rows with explicit ownership and proof tiers)',
		cmd: 'node',
		args: ['tools/test/test-linux-feature-parity.cjs'],
		repro: 'npm run test:linux-feature-parity'
	},
	{
		name: 'npm alias ⇄ suite parity (no alias names a gate the suite does not run; the aliasless count only falls)',
		cmd: 'node',
		args: ['tools/test/test-npm-aliases-match-the-suite.cjs'],
		repro: 'node tools/test/test-npm-aliases-match-the-suite.cjs'
	},
	{
		name: 'keylogger walker constants single source (bucket edges and caps: shared helpers vs both walkers)',
		cmd: 'node',
		args: ['tools/test/test-walker-constants-single-source.cjs'],
		repro: 'node tools/test/test-walker-constants-single-source.cjs'
	},
	{
		name: 'port × driver adapter matrix (cross-tree presence; every absence declared with a reason)',
		cmd: 'node',
		args: ['tools/test/test-port-adapter-matrix.cjs'],
		repro: 'node tools/test/test-port-adapter-matrix.cjs'
	},
	{
		name: 'HotPath segment inventory (every measured hot path declared with what it covers)',
		cmd: 'node',
		args: ['tools/test/test-hotpath-segments-declared.cjs'],
		repro: 'node tools/test/test-hotpath-segments-declared.cjs'
	},
	{
		name: 'shared JS reachability (every _shared module is runtime-mirrored, an oracle, or declared with a reason)',
		cmd: 'node',
		args: ['tools/test/test-shared-js-is-reachable.cjs'],
		repro: 'node tools/test/test-shared-js-is-reachable.cjs'
	},
	{
		name: 'tooltip lifecycle phases (the shared four-phase contract vs the AutoHotkey renderer)',
		cmd: 'node',
		args: ['tools/test/test-tooltip-lifecycle-phases.cjs'],
		repro: 'node tools/test/test-tooltip-lifecycle-phases.cjs'
	},
	{
		name: 'tap-hold namespace correspondence ([tap_hold.keys.*] vs [hs_tap_hold] paired by position, divergences named)',
		cmd: 'node',
		args: ['tools/test/test-tap-hold-namespace-correspondence.cjs'],
		repro: 'node tools/test/test-tap-hold-namespace-correspondence.cjs'
	},
	{
		name: 'hotstring flag support per driver (every corpus flag honoured by all three)',
		cmd: 'node',
		args: ['tools/test/test-hotstring-flag-support-per-driver.cjs'],
		repro: 'node tools/test/test-hotstring-flag-support-per-driver.cjs'
	},
	{
		name: 'magic key single source (declared once in the feature manifest, no driver copy)',
		cmd: 'node',
		args: ['tools/test/test-magic-key-single-source.cjs'],
		repro: 'node tools/test/test-magic-key-single-source.cjs'
	},
	{
		name: 'tap-hold threshold parity (macOS global sits inside the per-key range)',
		cmd: 'node',
		args: ['tools/test/test-tap-hold-threshold-parity.cjs'],
		repro: 'node tools/test/test-tap-hold-threshold-parity.cjs'
	},
	{
		name: 'adapter reachability (an adapter nothing requires is a port claimed, not wired)',
		cmd: 'node',
		args: ['tools/test/test-adapter-reachability.cjs'],
		repro: 'node tools/test/test-adapter-reachability.cjs'
	},
	{
		name: 'hotstring telemetry is deferred (no open/write/flush inside the keyDown tap)',
		cmd: 'node',
		args: ['tools/test/test-hotstring-telemetry-is-deferred.cjs'],
		repro: 'node tools/test/test-hotstring-telemetry-is-deferred.cjs'
	},
	{
		name: 'feature-state boot smoke (4 fixtures, real include graph, own process)',
		cmd: 'node',
		args: ['tools/test/test-feature-state-boot-smoke.cjs'],
		repro: 'node tools/test/test-feature-state-boot-smoke.cjs'
	},
	{
		name: 'port contract vector traceability (ratchet: ids linked to the macOS mirror)',
		cmd: 'node',
		args: ['tools/test/test-port-vector-traceability.cjs'],
		repro: 'node tools/test/test-port-vector-traceability.cjs --measure'
	},
	{
		name: 'lua gsub returns one value (bare return leaks the replacement count)',
		cmd: 'node',
		args: ['tools/test/test-lua-gsub-single-return.cjs'],
		repro: 'node tools/test/test-lua-gsub-single-return.cjs'
	},
	{
		name: 'tooltip [positioning] constant reach (which driver reads which value)',
		cmd: 'node',
		args: ['tools/test/test-tooltip-positioning-reach.cjs'],
		repro: 'node tools/test/test-tooltip-positioning-reach.cjs'
	},
	{
		name: 'tooltip style single source (both drivers read constants.toml; hex companions match macOS)',
		cmd: 'node',
		args: ['tools/test/test-tooltip-style-single-source.cjs'],
		repro: 'node tools/test/test-tooltip-style-single-source.cjs'
	},
	{
		name: 'keyboard-layout registry (index.json in sync, checksums, schema, vendored digests)',
		cmd: 'node',
		args: ['tools/test/test-layouts-registry.cjs'],
		repro: 'npm run test:layouts-registry'
	},
	{
		name: 'keyboard-layout registry location single source (defaults.json folder; no driver retypes the URL)',
		cmd: 'node',
		args: ['tools/test/test-layouts-defaults-single-source.cjs'],
		repro: 'npm run test:layouts-defaults-single-source'
	},
	{
		name: 'layout features an emulated layout supersedes (declared in the manifest, reason translated, read by the gate and the menu)',
		cmd: 'node',
		args: ['tools/test/test-layout-supersession-declared.cjs'],
		repro: 'npm run test:layout-supersession-declared'
	},
	{
		name: 'Linux package ships the .keylayout converter (every data file it reads; packaged and source paths)',
		cmd: 'node',
		args: ['tools/test/test-linux-ships-keylayout-converter.cjs'],
		repro: 'npm run test:linux-ships-keylayout-converter'
	},
	{
		name: 'shared JS is loadable (module.exports in an ESM package exports nothing)',
		cmd: 'node',
		args: ['tools/test/test-shared-js-is-loadable.cjs'],
		repro: 'node tools/test/test-shared-js-is-loadable.cjs'
	},
	{
		name: 'hotstring editor confirm dialog wiring (delete actually fires)',
		cmd: 'node',
		args: ['tools/test/test-hotstring-editor-confirm-wiring.cjs'],
		repro: 'node tools/test/test-hotstring-editor-confirm-wiring.cjs'
	},
	{
		name: 'WebView2 host teardown order (closing a window must not quit AHK)',
		cmd: 'node',
		args: ['tools/test/test-webview-teardown-order.cjs'],
		repro: 'node tools/test/test-webview-teardown-order.cjs'
	},
	{
		name: 'dynamic hotstrings menu labels (resolver bridge + locale keys)',
		cmd: 'node',
		args: ['tools/test/test-dynamic-hotstrings-menu-labels.cjs'],
		repro: 'node tools/test/test-dynamic-hotstrings-menu-labels.cjs'
	},
	{
		name: 'manifest menu labels resolve (whole class, not a sample)',
		cmd: 'node',
		args: ['tools/test/test-manifest-menu-labels-resolve.cjs'],
		repro: 'node tools/test/test-manifest-menu-labels-resolve.cjs'
	},
	// Five gate scripts under tools/test/ used to be invoked by nothing at all —
	// not by this umbrella, not by any CI workflow, not by the pre-commit hook.
	// They passed when run by hand, so nothing looked wrong; a gate that never
	// runs is the purest false green there is. test-feature-read-sites in
	// particular guards a keyboard-thread crash class and the features README
	// documents it as a "CI gate".
	{
		name: 'feature read sites resolve against the manifest (UnsetItemError crash class)',
		cmd: 'node',
		args: ['tools/test/test-feature-read-sites.js'],
		repro: 'node tools/test/test-feature-read-sites.js'
	},
	{
		name: 'manifest menu labels (no driver-namespaced description_key; untranslated-label ratchet)',
		cmd: 'node',
		args: ['tools/test/test-menu-labels-resolve.cjs'],
		repro: 'node tools/test/test-menu-labels-resolve.cjs'
	},
	{
		name: 'Convention P (platform/ is the only OS-specific word; symmetrical across drivers)',
		cmd: 'node',
		args: ['tools/test/test-convention-p-platform-only.cjs'],
		repro: 'node tools/test/test-convention-p-platform-only.cjs'
	},
	{
		name: 'source-tree scan coverage (no scanner list forgets platform/)',
		cmd: 'node',
		args: ['tools/test/test-source-trees-are-scanned.cjs'],
		repro: 'node tools/test/test-source-trees-are-scanned.cjs'
	},
	{
		name: 'untracked driver artifacts cannot contaminate commit-candidate gates',
		cmd: 'node',
		args: ['tools/test/test-untracked-driver-artifacts-do-not-affect-gates.cjs'],
		repro: 'node tools/test/test-untracked-driver-artifacts-do-not-affect-gates.cjs'
	},
	{
		name: 'driver config surface is declared in the manifest (ratchet)',
		cmd: 'node',
		args: ['tools/test/test-driver-config-surface-is-declared.cjs'],
		repro: 'node tools/test/test-driver-config-surface-is-declared.cjs'
	},
	{
		name: 'config schema (v2 TOML shape)',
		cmd: 'node',
		args: ['tools/test/test-config-schema.cjs'],
		repro: 'node tools/test/test-config-schema.cjs'
	},
	{
		name: 'config migrations (registry chain, closed op set, corpus replay)',
		cmd: 'node',
		args: ['tools/test/test-config-migrations.cjs'],
		repro: 'node tools/test/test-config-migrations.cjs'
	},
	{
		name: 'physical magic key single source (manifest candidates, key tables, v5 migration, Ergopti declaration)',
		cmd: 'node',
		args: ['tools/test/test-magic-key-source.cjs'],
		repro: 'node tools/test/test-magic-key-source.cjs'
	},
	{
		name: 'metrics heatmap translation coverage',
		cmd: 'node',
		args: ['tools/test/test-metrics-heatmap-translation.cjs'],
		repro: 'node tools/test/test-metrics-heatmap-translation.cjs'
	},
	{
		name: 'metrics rebuild banner (partial snapshots are labelled)',
		cmd: 'node',
		args: ['tools/test/test-metrics-rebuild-banner.cjs'],
		repro: 'npm run test:metrics-rebuild-banner'
	},
	{
		name: 'metrics freshness banner (cached snapshots carry their date)',
		cmd: 'node',
		args: ['tools/test/test-metrics-freshness-banner.cjs'],
		repro: 'npm run test:metrics-freshness-banner'
	},
	// CI verifies AHK encoding with an inline PowerShell step rather than this
	// script, so the script itself never ran anywhere: a divergence between the
	// two implementations was invisible. Run the real one here too.
	{
		name: 'AHK source encoding (UTF-8 BOM + LF)',
		cmd: 'node',
		args: ['tools/test/test-ahk-encoding.cjs'],
		repro: 'npm run test:ahk-encoding'
	},
	// Stryker's own harness. Running it here proves it still passes un-mutated,
	// which is the precondition for the mutation score meaning anything.
	{
		name: 'mutation-test harness passes un-mutated (Stryker precondition)',
		cmd: 'node',
		args: ['tools/test/test-mutation-targets.cjs'],
		repro: 'node tools/test/test-mutation-targets.cjs'
	},
	{
		name: 'macOS Sparkle feed, URL command, and sole-owner cadence',
		cmd: 'node',
		args: ['tools/test/test-macos-sparkle-feed.cjs'],
		repro: 'node tools/test/test-macos-sparkle-feed.cjs'
	},
	{
		name: 'macOS launcher declares every driver language so Sparkle windows follow it',
		cmd: 'node',
		args: ['tools/test/test-macos-launcher-localizations.cjs'],
		repro: 'npm run test:macos-launcher-localizations'
	},
	{
		name: 'macOS embedded Hammerspoon and native helper cannot update themselves',
		cmd: 'node',
		args: ['tools/test/test-macos-sparkle-disarmed-bundles.cjs'],
		repro: 'npm run test:macos-sparkle-disarmed-bundles'
	},
	{
		name: 'macOS app signed with the stable certificate when set, ad hoc loudly otherwise, identity never overwritten',
		cmd: 'node',
		args: ['tools/test/test-macos-stable-signing-identity.cjs'],
		repro: 'npm run test:macos-stable-signing-identity'
	},
	{
		name: 'Homebrew casks follow the release channel, let brew upgrade quit, replace and relaunch the app, and name what the release published',
		cmd: 'node',
		args: ['tools/test/test-homebrew-cask.cjs'],
		repro: 'npm run test:homebrew-cask'
	},
	{
		name: 'formatting gate (hook formats staged files, CI checks the tree with the pinned Ruff, generated files ignored)',
		cmd: 'node',
		args: ['tools/test/test-format-gate.cjs'],
		repro: 'npm run test:format-gate'
	},
	{
		name: 'updater copy shown before consent claims no download, in all 21 locales',
		cmd: 'node',
		args: ['tools/test/test-updater-copy-before-consent.cjs'],
		repro: 'npm run test:updater-copy-before-consent'
	},
	{
		name: 'every updater catalogue string is shown by a driver',
		cmd: 'node',
		args: ['tools/test/test-updater-copy-is-shown.cjs'],
		repro: 'npm run test:updater-copy-is-shown'
	},
	{
		name: 'Windows Format(t(...)) strings carry numbered placeholders only, in all 21 locales',
		cmd: 'node',
		args: ['tools/test/test-ahk-format-placeholders.cjs'],
		repro: 'npm run test:ahk-format-placeholders'
	},
	{
		name: 'hotstring editor preserves strict-case state across the shared bridge',
		cmd: 'node',
		args: ['tools/test/test-hotstring-editor-strict-case.cjs'],
		repro: 'npm run test:hs-editor-strict-case'
	},
	{
		name: 'Karabiner package identity is shared and cached bytes are verified',
		cmd: 'node',
		args: ['tools/test/test-karabiner-package-manifest.cjs'],
		repro: 'node tools/test/test-karabiner-package-manifest.cjs'
	},
	{
		name: 'input-source Python supervisor enforces one bounded process group',
		cmd: 'node',
		args: ['tools/test/test-input-source-python-supervisor.cjs'],
		repro: 'npm run test:input-source-python-supervisor'
	},
	{
		name: 'input-source list edit adds and removes exactly the named layout',
		cmd: 'node',
		args: ['tools/test/test-input-source-enabled-list-edit.cjs'],
		repro: 'npm run test:input-source-enabled-list-edit'
	},
	{
		name: 'layout manager page decides its rows and posts only allowlisted actions',
		cmd: 'node',
		args: ['tools/test/test-layout-manager-page.cjs'],
		repro: 'npm run test:layout-manager-page'
	},
	{
		name: 'PTY process groups escalate and reap bounded descendants',
		cmd: 'node',
		args: ['tools/test/test-pty-process-group-escalation.cjs'],
		repro: 'npm run test:pty-process-group-escalation'
	},
	{
		name: 'MLX dependency bootstrap fingerprints both dependency manifests',
		cmd: 'node',
		args: ['tools/test/test-mlx-deps-lock-fingerprint.cjs'],
		repro: 'npm run test:mlx-deps-lock-fingerprint'
	},
	{
		name: 'App Cloner shortcuts preserve maximize intent',
		cmd: 'node',
		args: ['tools/test/test-app-cloner-shortcut-maximize.cjs'],
		repro: 'npm run test:app-cloner-shortcut-maximize'
	},
	{
		name: 'App Cloner launchers isolate runtime arguments',
		cmd: 'node',
		args: ['tools/test/test-app-cloner-run-isolation.cjs'],
		repro: 'npm run test:app-cloner-run-isolation'
	},
	{
		name: 'App Cloner logging stays isolated from generated launchers',
		cmd: 'node',
		args: ['tools/test/test-app-cloner-log-isolation.cjs'],
		repro: 'npm run test:app-cloner-log-isolation'
	},
	{
		name: 'App Cloner generated literals survive hostile values',
		cmd: 'node',
		args: ['tools/test/test-app-cloner-generated-literals.cjs'],
		repro: 'npm run test:app-cloner-generated-literals'
	},
	{
		name: 'App Cloner Dock URLs remain canonical',
		cmd: 'node',
		args: ['tools/test/test-app-cloner-dock-url.cjs'],
		repro: 'npm run test:app-cloner-dock-url'
	},
	{
		name: 'Ollama bootstrap bounds and authenticates network acquisition',
		cmd: 'node',
		args: ['tools/test/test-ollama-bootstrap-network-hardening.cjs'],
		repro: 'npm run test:ollama-bootstrap-network-hardening'
	},
	{
		name: 'MLX emitted downloader refuses failed system trust activation',
		cmd: process.execPath,
		args: ['tools/test/test-mlx-download-trust-activation.cjs'],
		repro: 'node tools/test/test-mlx-download-trust-activation.cjs'
	},
	{
		name: 'managed native HTTP receives actual pipe closure and shared routing',
		cmd: process.execPath,
		args: ['tools/test/test-macos-native-http-receiving.cjs'],
		repro: 'node tools/test/test-macos-native-http-receiving.cjs'
	},
	{
		name: 'managed bootstrap admits pinned bytes before offline installation',
		cmd: process.execPath,
		args: ['tools/test/test-macos-managed-bootstrap-http.cjs'],
		repro: 'node tools/test/test-macos-managed-bootstrap-http.cjs'
	},
	{
		name: 'managed Python release projections retain the independent official pin',
		cmd: process.execPath,
		args: ['tools/test/test-managed-python-release.cjs'],
		repro: 'node tools/test/test-managed-python-release.cjs'
	},
	{
		name: 'managed bootstrap shared policy and generated Swift remain source-qualified',
		cmd: process.execPath,
		args: ['tools/test/test-managed-bootstrap-policy.cjs'],
		repro: 'node tools/test/test-managed-bootstrap-policy.cjs'
	},
	{
		name: 'macOS guardian preserves public strict and offline signature flags',
		cmd: process.execPath,
		args: ['tools/test/test-macos-guardian-signature-flags.cjs'],
		repro: 'node tools/test/test-macos-guardian-signature-flags.cjs'
	},
	{
		name: 'bootstrap retry canonical data preserves original shell and generated Lua',
		cmd: process.execPath,
		args: ['tools/test/test-bootstrap-retry-projection.cjs'],
		repro: 'node tools/test/test-bootstrap-retry-projection.cjs'
	},
	{
		name: 'managed Ollama portable admission and operation retirement',
		cmd: process.execPath,
		args: ['tools/test/test-managed-ollama-protocol.cjs'],
		repro: 'node tools/test/test-managed-ollama-protocol.cjs'
	},
	{
		name: 'managed Ollama catalogue preserves native source and publication admission',
		cmd: process.execPath,
		args: ['tools/test/test-macos-managed-ollama-catalogue.cjs'],
		repro: 'node tools/test/test-macos-managed-ollama-catalogue.cjs'
	},
	{
		name: 'native PAC helpers preserve independent standard function vectors',
		cmd: process.execPath,
		args: ['tools/test/test-network-pac-helpers.cjs'],
		repro: 'node tools/test/test-network-pac-helpers.cjs'
	},
	{
		name: 'macOS opaque clients refuse unsupported automatic proxy routing',
		cmd: process.execPath,
		args: ['tools/test/test-macos-opaque-network-admission.cjs'],
		repro: 'node tools/test/test-macos-opaque-network-admission.cjs'
	},
	{
		name: 'CPython resolution refuses configured interpreter substitution',
		cmd: process.execPath,
		args: ['tools/test/test-python-resolution.cjs'],
		repro: 'node tools/test/test-python-resolution.cjs'
	},
	{
		name: 'Ollama server command preserves exact process ownership',
		cmd: 'node',
		args: ['tools/test/test-ollama-server-command.cjs'],
		repro: 'npm run test:ollama-server-command'
	},
	{
		name: 'every gate script is actually wired into a runner',
		cmd: 'node',
		args: ['tools/test/test-gate-scripts-are-wired.cjs'],
		repro: 'node tools/test/test-gate-scripts-are-wired.cjs'
	},
	{
		name: 'hotstrings config window bridge (shared frontend ↔ Windows host)',
		cmd: 'node',
		args: ['tools/test/test-hotstrings-config-window-bridge.cjs'],
		repro: 'node tools/test/test-hotstrings-config-window-bridge.cjs'
	},
	{
		name: 'metrics menu: the two dashboard rows start with the same word and carry no verb in the 21 locales',
		cmd: 'node',
		args: ['tools/test/test-metrics-open-rows-wording.cjs'],
		repro: 'npm run test:metrics-open-rows-wording'
	},
	{
		name: 'report button is white on blue with enough contrast in both appearances (diagnostics and error windows)',
		cmd: 'node',
		args: ['tools/test/test-report-button-contrast.cjs'],
		repro: 'npm run test:report-button-contrast'
	},
	{
		name: 'hotstrings config window folds (hidden honoured, caret and title, fold kept across a host push)',
		cmd: 'node',
		args: ['tools/test/test-hotstrings-config-window-fold.cjs'],
		repro: 'npm run test:hs-config-fold'
	},
	{
		name: 'hotstring colour presets identical on macOS and Linux',
		cmd: 'node',
		args: ['tools/test/test-color-presets-parity.cjs'],
		repro: 'node tools/test/test-color-presets-parity.cjs'
	},
	{
		name: 'prompt editor bridge (shared frontend ↔ Windows host)',
		cmd: 'node',
		args: ['tools/test/test-prompt-editor-bridge.cjs'],
		repro: 'node tools/test/test-prompt-editor-bridge.cjs'
	},
	{
		name: 'action picker bridge (shared frontend ↔ both hosts)',
		cmd: 'node',
		args: ['tools/test/test-action-picker-bridge.cjs'],
		repro: 'node tools/test/test-action-picker-bridge.cjs'
	},
	{
		name: 'the selection case actions share one text-case corpus that every driver suite replays',
		cmd: 'node',
		args: ['tools/test/test-text-case-vectors-shared.cjs'],
		repro: 'npm run test:text-case-vectors-shared'
	},
	{
		name: 'the previous/next desktop actions share one desktop-navigation corpus that every driver suite replays',
		cmd: 'node',
		args: ['tools/test/test-desktop-navigation-vectors-shared.cjs'],
		repro: 'npm run test:desktop-navigation-vectors-shared'
	},
	{
		name: 'the wrap_selection parameter rule is one shared corpus every driver suite replays',
		cmd: 'node',
		args: ['tools/test/test-wrap-pair-vectors-shared.cjs'],
		repro: 'npm run test:wrap-pair-vectors-shared'
	},
	{
		name: 'one ready-made prompt action per built-in prompt profile',
		cmd: 'node',
		args: ['tools/test/test-llm-prompt-actions-single-source.cjs'],
		repro: 'npm run test:llm-prompt-actions-single-source'
	},
	{
		name: 'Windows rewrite prompt and prompt action ports are included, ordered and wired',
		cmd: 'node',
		args: ['tools/test/test-windows-rewrite-prompt-wiring.cjs'],
		repro: 'npm run test:windows-rewrite-prompt-wiring'
	},
	{
		name: 'Windows types an accepted prediction as one exact Text-mode batch at TextSender SendLevel',
		cmd: 'node',
		args: ['tools/test/test-windows-llm-accept-injection.cjs'],
		repro: 'npm run test:windows-llm-accept-injection'
	},
	{
		name: 'Windows children inherit only their own streams and a held capture is retried, not an error',
		cmd: 'node',
		args: ['tools/test/test-windows-child-handle-inheritance.cjs'],
		repro: 'npm run test:windows-child-handle-inheritance'
	},
	{
		name: 'Windows cycles a visible prediction once per navigation chord in either keyboard-hook order',
		cmd: 'node',
		args: ['tools/test/test-windows-llm-nav-cycle.cjs'],
		repro: 'npm run test:windows-llm-nav-cycle'
	},
	{
		name: 'every driver cycles a visible prediction on each chord its tooltip advertises: the arrows and either Shift+Tab',
		cmd: 'node',
		args: ['tools/test/test-llm-nav-chord-contract.cjs'],
		repro: 'npm run test:llm-nav-chord-contract'
	},
	{
		name: 'Windows script chords belong to the driver only while their slot runs an action',
		cmd: 'node',
		args: ['tools/test/test-windows-script-chords-follow-their-slot.cjs'],
		repro: 'npm run test:windows-script-chords-follow-their-slot'
	},
	{
		name: 'the three drivers share the script chords, their presets, their defaults and their submenu',
		cmd: 'node',
		args: ['tools/test/test-script-chords-three-os.cjs'],
		repro: 'npm run test:script-chords-three-os'
	},
	{
		name: 'Windows times every observed character, so the hotstring preview bubble and the delayed expansions work without the layout emulation',
		cmd: 'node',
		args: ['tools/test/test-windows-hotstring-preview-shows.cjs'],
		repro: 'npm run test:windows-hotstring-preview-shows'
	},
	{
		name: 'the send_text, send_key and send_shortcut parameter rules are one shared corpus every driver suite replays',
		cmd: 'node',
		args: ['tools/test/test-send-input-vectors-shared.cjs'],
		repro: 'npm run test:send-input-vectors-shared'
	},
	{
		name: 'the number-row tap keys are one list, pinned to the manifest defaults and the Windows hotkeys',
		cmd: 'node',
		args: ['tools/test/test-tap-keys-single-source.cjs'],
		repro: 'npm run test:tap-keys-single-source'
	},
	{
		name: 'a manual prediction is refused for the same four reasons, with the same notices, on every driver',
		cmd: 'node',
		args: ['tools/test/test-manual-prediction-refusals-single-source.cjs'],
		repro: 'npm run test:manual-prediction-refusals'
	},
	{
		name: 'keyboard slots keep neutral defaults and independent manifest recommendations across drivers',
		cmd: 'node',
		args: ['tools/test/test-keyboard-slot-recommended-bindings.cjs'],
		repro: 'npm run test:keyboard-slot-defaults'
	},
	{
		name: 'the number-row key left of 1 recommends an instant capture of every screen on every driver',
		cmd: 'node',
		args: ['tools/test/test-number-row-full-capture.cjs'],
		repro: 'npm run test:number-row-full-capture'
	},
	{
		name: 'app and window switching actions carry one explicit label each and migrate the ids macOS merged',
		cmd: 'node',
		args: ['tools/test/test-app-switch-labels.cjs'],
		repro: 'npm run test:app-switch-labels'
	},
	{
		name: 'action picker greys a host-disabled row with its reason and never confirms it',
		cmd: 'node',
		args: ['tools/test/test-action-picker-disabled-rows.cjs'],
		repro: 'npm run test:action-picker-disabled-rows'
	},
	{
		name: 'action picker edits a text, a key or a shortcut and validates it as the drivers do',
		cmd: 'node',
		args: ['tools/test/test-action-picker-parameter-editor.cjs'],
		repro: 'npm run test:action-picker-parameter-editor'
	},
	{
		name: 'Apple Shortcuts cold CLI diagnostic preserves ownership and never admits a provider',
		cmd: 'node',
		args: ['tools/test/test-apple-shortcuts-cold-cli-probe.cjs'],
		repro: 'npm run test:apple-shortcuts-cold-cli'
	},
	{
		name: 'file-path headers (convention 3, every source file names itself)',
		cmd: 'node',
		args: ['tools/lint/audit-file-headers.cjs'],
		repro: 'node tools/lint/audit-file-headers.cjs'
	},
	{
		name: 'window title audit mutations',
		cmd: 'node',
		args: ['tools/test/test-gui-title-audit.cjs'],
		repro: 'node tools/test/test-gui-title-audit.cjs'
	},
	{
		name: 'window titles (Gui/windowTitle carry the "ErgoptiPlus" prefix)',
		cmd: 'node',
		args: ['tools/lint/audit-gui-titles.cjs'],
		repro: 'node tools/lint/audit-gui-titles.cjs'
	},
	{
		name: 'updater constants single source (owner/repo/timing literals match defaults.json)',
		cmd: 'node',
		args: ['tools/test/test-updater-constants-single-source.cjs'],
		repro: 'node tools/test/test-updater-constants-single-source.cjs'
	},
	{
		name: 'name parity (text_utils + action_picker + manifest_menu symmetric across drivers)',
		cmd: 'node',
		args: ['tools/test/test-name-parity.cjs'],
		repro: 'node tools/test/test-name-parity.cjs'
	},
	{
		name: 'git-mv resilience (every path pin in the three suites resolves — macOS + Linux files, AHK dirs)',
		cmd: 'node',
		args: ['tools/test/test-git-mv-resilience.cjs'],
		repro: 'node tools/test/test-git-mv-resilience.cjs'
	},
	{
		name: 'shared UI JavaScript syntax (every browser script parses before WebView injection)',
		cmd: 'node',
		args: ['tools/test/test-shared-ui-js-syntax.cjs'],
		repro: 'node tools/test/test-shared-ui-js-syntax.cjs'
	},
	{
		name: 'changelog remote content and native bridge stay inside their authenticated boundary',
		cmd: 'node',
		args: ['tools/test/test-changelog-security.cjs'],
		repro: 'npm run test:changelog-security'
	},
	{
		name: 'changelog release notes render as sanitized Markdown (DOM-only, repository links only)',
		cmd: 'node',
		args: ['tools/test/test-changelog-markdown.cjs'],
		repro: 'npm run test:changelog-markdown'
	},
	{
		name: 'changelog loads are bounded and fall back to the releases Atom feed',
		cmd: 'node',
		args: ['tools/test/test-changelog-network-resilience.cjs'],
		repro: 'npm run test:changelog-network-resilience'
	},
	{
		name: 'release bodies split into changelog, downloads, intro and footer (CI markers, legacy and feed bodies)',
		cmd: 'node',
		args: ['tools/test/test-release-body-sections.cjs'],
		repro: 'npm run test:release-body-sections'
	},
	{
		name: 'update channel registry: shared vectors, locales, generated data and release tag families agree',
		cmd: 'node',
		args: ['tools/test/test-update-channels-contract.cjs'],
		repro: 'npm run test:update-channels-contract'
	},
	{
		name: 'update-check schedule: shared vectors, presets, locales and generated Windows data agree',
		cmd: 'node',
		args: ['tools/test/test-update-schedule-contract.cjs'],
		repro: 'npm run test:update-schedule-contract'
	},
	{
		name: 'Windows touchpad registry: one data file, both writers through one backing-up owner, restore row',
		cmd: 'node',
		args: ['tools/test/test-touchpad-registry-single-source.cjs'],
		repro: 'npm run test:touchpad-registry'
	},
	{
		name: 'Versions page: tabs change the view, the banner subscribes through the host',
		cmd: 'node',
		args: ['tools/test/test-changelog-channel-sync.cjs'],
		repro: 'npm run test:changelog-channel-sync'
	},
	{
		name: 'Versions managed failures retain safe report and exact action ownership',
		cmd: 'node',
		args: ['tools/test/test-changelog-managed-failure.cjs'],
		repro: 'npm run test:changelog-managed-failure'
	},
	{
		name: 'Linux document bridge challenges retain intrinsic page nonce and exact lease',
		cmd: 'node',
		args: [
			'tools/test/test-linux-document-lease.cjs',
			'static/ergopti_plus/_shared/ui/host_bridge.js'
		],
		repro: 'npm run test:linux-document-lease'
	},
	{
		name: 'Versions page: one click installs a chosen release through the host, restore banner',
		cmd: 'node',
		args: ['tools/test/test-changelog-release-install.cjs'],
		repro: 'npm run test:changelog-release-install'
	},
	{
		name: 'release install: only clicks install on every driver, one set of install reasons',
		cmd: 'node',
		args: ['tools/test/test-release-install-contract.cjs'],
		repro: 'npm run test:release-install-contract'
	},
	{
		name: 'one installed-build-or-source-run owner per driver; Uninstall greyed on a source run',
		cmd: 'node',
		args: ['tools/test/test-source-run-single-owner.cjs'],
		repro: 'npm run test:source-run-single-owner'
	},
	{
		name: 'download actions retain their operation session across native reuse',
		cmd: 'node',
		args: ['tools/test/test-download-window-session.cjs'],
		repro: 'npm run test:download-window-session'
	},
	{
		name: 'managed download failures render safe translated actions with captured owners',
		cmd: 'node',
		args: ['tools/test/test-managed-network-failure-ui.cjs'],
		repro: 'npm run test:managed-network-failure-ui'
	},
	{
		name: 'managed fixture late accepted clients retain exact retirement ownership',
		cmd: 'node',
		args: ['tools/test/test-managed-remote-retirement.cjs'],
		repro: 'npm run test:managed-remote-retirement'
	},
	{
		name: 'model browser actions retain their operation session across native reuse',
		cmd: 'node',
		args: ['tools/test/test-model-browser-session.cjs'],
		repro: 'npm run test:model-browser-session'
	},
	{
		name: 'onboarding wizard asks one No-first page per scope and emits manifest paths only',
		cmd: 'node',
		args: ['tools/test/test-onboarding-wizard-page.cjs'],
		repro: 'npm run test:onboarding-wizard-page'
	},
	{
		name: 'metrics manifest payload contract (reader vocabulary reaches real consumers)',
		cmd: 'node',
		args: ['tools/test/test-metrics-manifest-contract.cjs'],
		repro: 'node tools/test/test-metrics-manifest-contract.cjs'
	},
	{
		name: 'typing-speed source toggles (net expansion gain and filter semantics)',
		cmd: 'node',
		args: ['tools/test/test-metrics-speed-source-filters.cjs'],
		repro: 'node tools/test/test-metrics-speed-source-filters.cjs'
	},
	{
		name: 'Linux metrics SQLite bridge (persistent manifest + selected-range refresh)',
		cmd: 'node',
		args: ['tools/test/test-linux-metrics-sqlite-bridge.cjs'],
		repro: 'node tools/test/test-linux-metrics-sqlite-bridge.cjs'
	},
	{
		name: 'Windows metrics range bridge (native selected date/app refresh)',
		cmd: 'node',
		args: ['tools/test/test-windows-metrics-range-bridge.cjs'],
		repro: 'node tools/test/test-windows-metrics-range-bridge.cjs'
	},
	{
		name: 'keycode data single source (generated JS matches azerty.json, DC-1)',
		cmd: 'node',
		args: ['tools/test/test-keycode-data-js-parity.cjs'],
		repro: 'node tools/test/test-keycode-data-js-parity.cjs'
	},
	{
		name: 'physical-key registry is complete, unique per driver and agrees with every hand copy (evdev, kVK, SC, Karabiner, kanata)',
		cmd: 'node',
		args: ['tools/test/test-physical-keys-registry.cjs'],
		repro: 'npm run test:physical-keys-registry'
	},
	{
		name: 'HS-274 native run refuses a Hammerspoon consumer on Linux while the producer and consumer baseline versions differ',
		cmd: 'node',
		args: ['tools/test/test-hs274-baseline-contract.cjs'],
		repro: 'npm run test:hs274-baseline-contract'
	},
	{
		name: 'layer-action vocabulary resolves on every OS or says why, and sends what the action catalogue sends',
		cmd: 'node',
		args: ['tools/test/test-layer-actions-vocabulary.cjs'],
		repro: 'npm run test:layer-actions-vocabulary'
	},
	{
		name: 'layer editor data is generated from the registry, the vocabulary and the preset, with every label translated',
		cmd: 'node',
		args: ['tools/test/test-layer-editor-data.cjs'],
		repro: 'npm run test:layer-editor-data'
	},
	{
		name: 'layer editor model reads and writes what the loaders read, and an edit on one OS changes no other OS',
		cmd: 'node',
		args: ['tools/test/test-layer-editor-model.cjs'],
		repro: 'npm run test:layer-editor-model'
	},
	{
		name: 'layer editor page renders, picks and saves a layers.toml every OS loads, through the host protocol',
		cmd: 'node',
		args: ['tools/test/test-layer-editor-page.cjs'],
		repro: 'npm run test:layer-editor-page'
	},
	{
		name: 'layer editor legends: the hosts send the current layout and the layer key by one contract',
		cmd: 'node',
		args: ['tools/test/test-layer-editor-legends.cjs'],
		repro: 'npm run test:layer-editor-legends'
	},
	{
		name: 'recommended navigation layer reproduces the Windows nav_layer.ahk key for key (golden) and resolves on every OS',
		cmd: 'node',
		args: ['tools/test/test-nav-layer-recommended-golden.cjs'],
		repro: 'npm run test:nav-layer-recommended-golden'
	},
	{
		name: 'layer-file schema corpus replays through the JS loader (every error code, OS and binding form)',
		cmd: 'node',
		args: ['tools/test/test-keymap-layers-corpus.cjs'],
		repro: 'npm run test:keymap-layers-corpus'
	},
	{
		name: 'tooltip corpus parity (JSON corpus matches JS layoutTestVectors + dequeueTestVectors)',
		cmd: 'node',
		args: ['tools/test/test-tooltip-corpus-parity.cjs'],
		repro: 'node tools/test/test-tooltip-corpus-parity.cjs'
	},
	{
		name: 'TOML coercion parity (corpus cross-driver gate)',
		cmd: 'node',
		args: ['tools/test/test-toml-coercion-parity.cjs'],
		repro: 'node tools/test/test-toml-coercion-parity.cjs'
	},
	{
		name: 'shared test.format single source (inspect/deep_equal/fail_msg_for consumed from _shared, no local copies)',
		cmd: 'node',
		args: ['tools/test/test-shared-test-format.cjs'],
		repro: 'node tools/test/test-shared-test-format.cjs'
	},
	{
		name: 'file watchers constants single source (SCAN_MAX_DEPTH=16 + debounce=0.5s match across Linux + macOS infra/file_watchers.lua)',
		cmd: 'node',
		args: ['tools/test/test-file-watchers-constants-single-source.cjs'],
		repro: 'node tools/test/test-file-watchers-constants-single-source.cjs'
	},
	{
		name: 'format_toml CLI behavioral test (bare invocation exits 1 = usage; --preview sorts sections/keys + styles headers, file untouched)',
		cmd: 'node',
		args: ['tools/test/test-format-toml-importable.cjs'],
		repro: 'node tools/test/test-format-toml-importable.cjs'
	},
	{
		name: 'gesture slot-space single source (Linux derives from actions.toml [slots]; macOS literals + DEFAULT_GESTURES key-space pinned to it)',
		cmd: 'node',
		args: ['tools/test/test-gesture-slots-single-source.cjs'],
		repro: 'node tools/test/test-gesture-slots-single-source.cjs'
	},
	{
		name: 'gesture recommended actions single source (macOS DEFAULT_GESTURES and Windows GESTURE_FACTORY_DEFAULTS built from the manifest)',
		cmd: 'node',
		args: ['tools/test/test-gesture-defaults-single-source.cjs'],
		repro: 'node tools/test/test-gesture-defaults-single-source.cjs'
	},
	{
		name: 'keylogger timing constants single source (CONTEXT_TTL_MS / PARK_CHECK_MS / TOPO_TICK_MS match the shared timing registry)',
		cmd: 'node',
		args: ['tools/test/test-keylogger-timings-single-source.cjs'],
		repro: 'node tools/test/test-keylogger-timings-single-source.cjs'
	},
	{
		name: 'SQLite event cursor numeric policy single source',
		cmd: 'node',
		args: ['tools/test/test-sqlite-event-id-single-source.cjs'],
		repro: 'node tools/test/test-sqlite-event-id-single-source.cjs'
	},
	{
		name: 'no plan-item references in tracked source (refactor/delivery tokens purged; algorithmic Phase-N allowlisted)',
		cmd: 'node',
		args: ['tools/test/test-no-plan-refs-in-source.cjs'],
		repro: 'node tools/test/test-no-plan-refs-in-source.cjs'
	},
	{
		name: 'WPM readout constants single source (every canon key read by a driver, none restated)',
		cmd: 'node',
		args: ['tools/test/test-wpm-constants-single-source.cjs'],
		repro: 'node tools/test/test-wpm-constants-single-source.cjs'
	},
	{
		name: 'WPM strip darkening cross-driver drift (Lua model and AHK round-half-up on the canon factor; golden vectors)',
		cmd: 'node',
		args: ['tools/test/test-wpm-color-normalisation-single-source.cjs'],
		repro: 'node tools/test/test-wpm-color-normalisation-single-source.cjs'
	},
	{
		name: 'expected pcall rejection stays distinct from weak success assertions',
		cmd: 'node',
		args: ['tools/test/test-false-green-pcall-rejection.cjs'],
		repro: 'node tools/test/test-false-green-pcall-rejection.cjs'
	},
	{
		name: 'every Hammerspoon deadline keeps 2 s over the native worker budget it waits for (hardening-d)',
		cmd: 'node',
		args: ['tools/test/test-hardening-d-native-timeout-contract.cjs'],
		repro: 'node tools/test/test-hardening-d-native-timeout-contract.cjs'
	},
	{
		name: 'no AHK name or VK hotkey targets a key another hotkey declares by scan code (hardening-c)',
		cmd: 'node',
		args: ['tools/test/test-hardening-c-ahk-scan-code-precedence.cjs'],
		repro: 'node tools/test/test-hardening-c-ahk-scan-code-precedence.cjs'
	},
	{
		name: 'no macOS or Linux module builds a user-data path inside the installed driver folder (hardening-b)',
		cmd: 'node',
		args: ['tools/test/test-hardening-b-no-user-data-under-driver-dir.cjs'],
		repro: 'node tools/test/test-hardening-b-no-user-data-under-driver-dir.cjs'
	},
	{
		name: 'every Windows meta test census the Linux lane can recompute matches the driver source (hardening-f)',
		cmd: 'node',
		args: ['tools/test/test-hardening-f-ahk-meta-counts.cjs'],
		repro: 'node tools/test/test-hardening-f-ahk-meta-counts.cjs'
	},
	{
		name: 'every dialog or notice that reports a fixable state offers its fix as an action (hardening-g)',
		cmd: 'node',
		args: ['tools/test/test-hardening-g-fixable-errors-offer-an-action.cjs'],
		repro: 'node tools/test/test-hardening-g-fixable-errors-offer-an-action.cjs'
	},
	{
		name: 'tests that cannot fail (tautologies, vacuous absence assertions, dead tests, pcall-only — ratchet against a growing false green)',
		cmd: 'node',
		args: ['tools/test/find-false-greens.cjs'],
		repro: 'node tools/test/find-false-greens.cjs'
	}
];

const SLOW_CHECKS = [
	{
		name: 'property-based tests (fast-check)',
		cmd: 'npm',
		args: ['run', '--silent', 'test:properties'],
		repro: 'npm run test:properties'
	},
	{
		name: 'mutation tests (Stryker)',
		cmd: 'npm',
		args: ['run', '--silent', 'test:mutation'],
		repro: 'npm run test:mutation'
	}
];

const checks = FULL ? [...CHECKS, ...SLOW_CHECKS] : CHECKS;

console.log('\nErgopti+ JS validation suite' + (FULL ? ' (full)' : '') + '\n' + '='.repeat(50));

const results = [];
for (const check of checks) {
	process.stdout.write(`  • ${check.name} … `);
	const r = spawnSync(check.cmd, check.args, { cwd: ROOT, encoding: 'utf8', shell: true });
	const ok = r.status === 0;
	console.log(ok ? 'OK' : 'FAIL');
	results.push({
		...check,
		ok,
		status: r.status,
		signal: r.signal,
		errorCode: r.error?.code,
		stdout: r.stdout || '',
		stderr: r.stderr || ''
	});
}

const failed = results.filter((r) => !r.ok);

console.log('\n' + '-'.repeat(50));
if (failed.length === 0) {
	console.log(`✅  All ${results.length} JS check(s) passed.`);
	if (!FULL)
		console.log('   (run "npm run test:js -- --full" to also run property + mutation tests)');
	console.log('');
	process.exit(0);
}

console.log(`❌  ${failed.length}/${results.length} JS check(s) FAILED:\n`);
for (const f of failed) {
	if (process.env?.GITHUB_ACTIONS === 'true') {
		// Check names remain available through the API when archived log access
		// fails. Never copy command output, URLs or native receipts here.
		const name = f.name.replace(/%/g, '%25').replace(/\r/g, '%0D').replace(/\n/g, '%0A');
		console.log(`::error title=Shared validation check failed::${name}`);
	}
	console.log(`  ✗ ${f.name}`);
	console.log(`    reproduce: ${f.repro}`);
	console.log(
		`    process: status=${f.status ?? 'none'} signal=${f.signal ?? 'none'} error=${f.errorCode ?? 'none'}`
	);
	// Stack tails often omit the actual error. Keep both ends without dumping
	// unbounded fixture output or silently hiding that a middle was removed.
	// Summarize streams separately: verbose stdout must not hide stderr's head.
	for (const stream of ['stdout', 'stderr']) {
		if (!f[stream].trim()) continue;
		const lines = f[stream].trim().split(/\r?\n/);
		const edgeLines = 12;
		const excerpt =
			lines.length <= edgeLines * 2
				? lines
				: [
						...lines.slice(0, edgeLines),
						`... ${lines.length - edgeLines * 2} lines omitted ...`,
						...lines.slice(-edgeLines)
					];
		console.log(`    ${stream}:\n    ` + excerpt.join('\n    ') + '\n');
	}
}
process.exit(1);
