// tools/test/test-e2e-gate-symmetry.cjs

/**
 * ==============================================================================
 * MODULE: E2E Gate Symmetry Guard
 * DESCRIPTION:
 * Asserts that every driver shipping an end-to-end runner has that runner wired
 * into verify-change.cjs, so a behaviour change to that driver selects the e2e
 * tier locally instead of discovering it red in CI.
 *
 * ROOT CAUSE ENCODED:
 * verify-change.cjs carried an "ahk-e2e" rule for the Windows driver, justified
 * in the file itself as "the e2e runner exercises the expansion pipeline end to
 * end", and no equivalent for macOS. The macOS "hs" gate ran the unit suite
 * alone. A keymap change therefore shipped with a fully green 3548/3548 local
 * suite while the macOS e2e harness — which CI does run, and which the
 * macos-ok gate depends on — failed 14 of 38 assertions. The two tiers are
 * disjoint, and only the one nobody ran locally could see the regression.
 *
 * FEATURES & RATIONALE:
 * 1. Discovers e2e runners from the filesystem rather than from a hardcoded
 *    list, so the next driver to gain one is covered without editing this file.
 * 2. Asserts SELECTION (does a driver source file pull in an e2e gate?) using
 *    verify-change's own exported selectGates, never a regex over its source —
 *    a guard anchored on a phrasing survives the phrasing changing under it.
 * 3. Asserts every selectable gate resolves to a real command, and that every
 *    npm-backed command exists in package.json. A rule whose gate has no
 *    command runs nothing, which is indistinguishable from a passing gate.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS_DIR = path.join(ROOT, 'static', 'ergopti_plus');

const { RULES, GATE_COMMANDS, selectGates } = require('./verify-change.cjs');
const PKG = JSON.parse(fs.readFileSync(path.join(ROOT, 'package.json'), 'utf8'));

const failures = [];

function check(condition, message) {
	if (!condition) failures.push(message);
}

// A driver source file the rules can be evaluated against. Deliberately NOT under
// tests/, because both e2e rules exclude that directory on purpose: editing a
// harness does not require re-running the behaviour it drives.
const REPRESENTATIVE_SOURCE = {
	windows: 'static/ergopti_plus/windows/modules/hotstrings.ahk',
	macos: 'static/ergopti_plus/macos/modules/keymap/expander.lua',
	linux: 'static/ergopti_plus/linux/modules/hotstrings/injector.lua',
};

/**
 * Collects every driver directory that ships an end-to-end runner.
 * @returns {Array<{driver: string, runner: string}>} Driver name + repo-relative runner path.
 */
function discoverE2eRunners() {
	const found = [];
	for (const entry of fs.readdirSync(DRIVERS_DIR, { withFileTypes: true })) {
		if (!entry.isDirectory()) continue;
		const e2eDir = path.join(DRIVERS_DIR, entry.name, 'tests', 'e2e');
		if (!fs.existsSync(e2eDir)) continue;
		for (const file of fs.readdirSync(e2eDir)) {
			if (/^run_e2e\.(lua|ahk)$/.test(file)) {
				found.push({
					driver: entry.name,
					runner: path
						.relative(ROOT, path.join(e2eDir, file))
						.replace(/\\/g, '/'),
				});
			}
		}
	}
	return found;
}

// ==========================================
// ==========================================
// ======= 1/ Every gate has a command ======
// ==========================================
// ==========================================

for (const rule of RULES) {
	check(
		Object.prototype.hasOwnProperty.call(GATE_COMMANDS, rule.gate),
		`rule "${rule.gate}" selects a gate that GATE_COMMANDS does not know how to run — ` +
			'it would be reported as required and then execute nothing'
	);
}

for (const [gate, spec] of Object.entries(GATE_COMMANDS)) {
	check(
		Boolean(spec.npm || spec.ahk),
		`gate "${gate}" has neither an npm script nor an AutoHotkey runner`
	);
	if (spec.npm) {
		check(
			Object.prototype.hasOwnProperty.call(PKG.scripts, spec.npm),
			`gate "${gate}" runs npm script "${spec.npm}", which package.json does not define`
		);
	}
}

// ==============================================
// ==============================================
// ======= 2/ Every e2e runner is selected ======
// ==============================================
// ==============================================

const runners = discoverE2eRunners();
check(runners.length > 0, 'no e2e runner found at all — the discovery walk is broken, not the wiring');

for (const { driver, runner } of runners) {
	const source = REPRESENTATIVE_SOURCE[driver];
	check(
		Boolean(source),
		`driver "${driver}" ships ${runner} but this test has no representative source file for it — ` +
			'add one to REPRESENTATIVE_SOURCE so the driver is actually covered'
	);
	if (!source) continue;

	check(
		fs.existsSync(path.join(ROOT, source)),
		`representative source "${source}" no longer exists — pick a live file, or this check passes vacuously`
	);

	const selected = selectGates([source]);
	const e2eGates = [...selected.keys()].filter((g) => g.endsWith('-e2e'));
	check(
		e2eGates.length > 0,
		`changing "${source}" selects [${[...selected.keys()].join(', ')}] — none of which is an e2e gate, ` +
			`so ${runner} would only ever run in CI`
	);

	// The selected e2e gate must actually reach THIS driver's runner, not another
	// driver's: a gate that exists but points elsewhere is the same blind spot.
	const runnerFile = path.basename(runner);
	const reaches = e2eGates.some((gate) => {
		const spec = GATE_COMMANDS[gate] || {};
		if (spec.ahk) return spec.ahk.endsWith(runnerFile);
		if (spec.npm) return (PKG.scripts[spec.npm] || '').includes(runner.replace(/^static\/ergopti_plus\/[^/]+\//, ''));
		return false;
	});
	check(
		reaches,
		`driver "${driver}" selects [${e2eGates.join(', ')}] but none of those commands runs ${runner}`
	);
}

// ==================================
// ==================================
// ======= 3/ Report ================
// ==================================
// ==================================

if (failures.length > 0) {
	console.error('[FAIL] e2e gate symmetry:');
	for (const f of failures) console.error(`  - ${f}`);
	process.exit(1);
}

console.log(
	`[OK] e2e gate symmetry (${runners.length} driver runner(s), ${RULES.length} rules, ${Object.keys(GATE_COMMANDS).length} gates).`
);
