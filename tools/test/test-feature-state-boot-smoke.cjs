// tools/test/test-feature-state-boot-smoke.cjs

/**
 * ==============================================================================
 * MODULE: Feature-State Boot Smoke Runner
 * DESCRIPTION:
 * Runs windows/tests/startup/feature_state_boot_smoke.ahk once per fixture and
 * requires a zero exit code from each.
 *
 * WHY THIS RUNNER EXISTS:
 * That harness deliberately runs in its OWN AutoHotkey process with the
 * production include order and none of the test-runner stubs — its whole point
 * is that a boot-time dependency or function-resolution failure shows up as a
 * non-zero exit code. So it cannot be #Include'd into run_all.ahk without
 * destroying the thing it tests, and `test-ahk-test-coverage.cjs` does not see
 * it either: that gate scopes to `test_*.ahk`, and this file is named
 * `feature_state_boot_smoke.ahk`.
 *
 * The result was a harness that nothing invoked. It was written, committed, and
 * never once executed — the same shape as the three regression tests found
 * earlier in this backlog that had never run. Invoking it by hand shows why that
 * matters: with no argument it throws "expected exactly one startup fixture
 * name" and exits 1, which is exactly what a broken boot would look like from
 * outside. A reader checking "does it pass?" without knowing about the fixture
 * argument would conclude the boot was broken; a CI job wiring it up naively
 * would get a permanent red for the wrong reason.
 *
 * All four fixtures pass today. They cover the boot-order paths that the unit
 * suite cannot reach, because the unit suite stubs precisely the things this
 * harness exists to load for real.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const HARNESS_DIR = path.join(ROOT, 'static', 'ergopti_plus', 'windows', 'tests', 'startup');
const HARNESS = path.join(HARNESS_DIR, 'feature_state_boot_smoke.ahk');

// The fixtures the harness dispatches on. Kept here rather than discovered, so
// a fixture removed from the harness without updating this list fails loudly
// instead of quietly reducing coverage.
const FIXTURES = ['parsed', 'missing', 'malformed', 'non_map'];

const AHK_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey.exe',
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files (x86)\\AutoHotkey\\v2\\AutoHotkey.exe'
];

const errors = [];

if (!fs.existsSync(HARNESS)) {
	console.error(`\x1b[31m[ERROR] boot smoke harness missing: ${HARNESS}\x1b[0m`);
	process.exit(1);
}

// The harness must still dispatch on every fixture this runner drives.
const src = fs.readFileSync(HARNESS, 'utf8');
for (const fx of FIXTURES) {
	if (!src.includes(`case "${fx}":`)) {
		errors.push(
			`the harness no longer handles the "${fx}" fixture. Either it was renamed — update this ` +
				'list — or a boot scenario stopped being covered.'
		);
	}
}

const ahk = AHK_CANDIDATES.find((p) => fs.existsSync(p));
if (!ahk) {
	// Not a failure: the Lua and JS suites run on machines without AutoHotkey.
	// Saying so out loud beats a silent pass that looks like coverage.
	console.log(
		'\x1b[33m[SKIP] AutoHotkey v2 not installed — the boot smoke harness needs a real ' +
			'interpreter. It runs in CI on Windows.\x1b[0m'
	);
	process.exit(errors.length > 0 ? 1 : 0);
}

for (const fx of FIXTURES) {
	const r = spawnSync(ahk, [HARNESS, fx], { cwd: HARNESS_DIR, encoding: 'utf8', timeout: 120000 });
	if (r.status !== 0) {
		const out = ((r.stdout || '') + (r.stderr || '')).trim().split('\n').slice(-6).join('\n      ');
		errors.push(
			`fixture "${fx}" exited ${r.status}. This harness loads the production include graph for ` +
				`real, so a non-zero exit is a boot-order or dependency failure:\n      ${out}`
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] feature-state boot smoke:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] feature-state boot smoke: all ${FIXTURES.length} fixture(s) boot the production ` +
		'include graph cleanly.\x1b[0m'
);
