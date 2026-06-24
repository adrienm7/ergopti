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
	{ name: 'architecture diagram (ports resolve + architecture.md in sync)', cmd: 'node', args: ['tools/test/test-architecture-diagram.cjs'], repro: 'node tools/test/test-architecture-diagram.cjs' },
	{ name: 'dev-tool paths (private-AHK workflow points at live paths)', cmd: 'node', args: ['tools/test/test-dev-tool-paths.cjs'], repro: 'node tools/test/test-dev-tool-paths.cjs' },
	{ name: 'driver-doc paths (no stale static/drivers in docs)', cmd: 'node', args: ['tools/test/test-doc-paths.cjs'], repro: 'node tools/test/test-doc-paths.cjs' },
	{ name: 'no new location-pinned source reads in AHK tests (ratchet)', cmd: 'node', args: ['tools/test/test-no-pinned-source-reads.cjs'], repro: 'node tools/test/test-no-pinned-source-reads.cjs' },
	{ name: 'AHK test coverage (every test_*.ahk reachable from run_all)', cmd: 'node', args: ['tools/test/test-ahk-test-coverage.cjs'], repro: 'node tools/test/test-ahk-test-coverage.cjs' },
	{ name: 'unified reporter parses TAP + Lua output (report.cjs)', cmd: 'node', args: ['tools/test/test-report.cjs'], repro: 'node tools/test/test-report.cjs' },
	{ name: 'max_tokens single source (no literal default in backend adapters)', cmd: 'node', args: ['tools/test/test-max-tokens-single-source.cjs'], repro: 'node tools/test/test-max-tokens-single-source.cjs' },
	{ name: 'temperature single source (no literal 0.1 default in macOS adapters)', cmd: 'node', args: ['tools/test/test-temperature-single-source.cjs'], repro: 'node tools/test/test-temperature-single-source.cjs' },
	{ name: 'macOS bundle layout (build script + launcher mirror the repo)', cmd: 'node', args: ['tools/test/test-macos-bundle-layout.cjs'], repro: 'node tools/test/test-macos-bundle-layout.cjs' },
	{ name: 'menu manifest drift (feature paths + i18n keys resolve against manifest.toml)', cmd: 'node', args: ['tools/test/test-menu-manifest.cjs'], repro: 'node tools/test/test-menu-manifest.cjs' },
	{ name: 'file-path headers (convention 3, every source file names itself)', cmd: 'node', args: ['tools/lint/audit-file-headers.cjs'], repro: 'node tools/lint/audit-file-headers.cjs' }
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
