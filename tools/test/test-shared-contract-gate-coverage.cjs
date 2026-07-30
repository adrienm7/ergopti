// tools/test/test-shared-contract-gate-coverage.cjs

/**
 * ==============================================================================
 * MODULE: Shared-Contract Gate Coverage Guard
 * DESCRIPTION:
 * Asserts that editing a cross-driver contract — anything under
 * `_shared/core/` (the port specs) or `_shared/tests/` (the corpora the three
 * suites replay) — selects the unit suite of EVERY driver in verify-change.cjs.
 *
 * ROOT CAUSE ENCODED:
 * ADR-006 declares those two trees binding on all three drivers, yet they were
 * the one file class whose edit selected no driver suite at all: the rules
 * matched on `static/ergopti_plus/<driver>/` prefixes, and `_shared/` starts
 * with none of them. Only the "js" gate fired, and no JS gate executes a corpus
 * vector. A vector could therefore be changed, reported as fully verified, and
 * have run nothing that consumes it — the exact silent-green shape this repo
 * has documented three times.
 *
 * FEATURES & RATIONALE:
 * 1. Asserts SELECTION through verify-change's own exported selectGates, never
 *    a regex over its source: a guard anchored on phrasing dies when the
 *    phrasing changes, and this one has to outlive several refactors.
 * 2. Derives the driver suites from GATE_COMMANDS rather than hardcoding three
 *    names, so a fourth driver is covered the day its gate is added.
 * 3. Uses REAL files under each shared tree. A path that no longer exists would
 *    make the assertion pass against a fiction.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');

const { GATE_COMMANDS, selectGates } = require('./verify-change.cjs');

// The unit-suite gate of each driver. An e2e gate is deliberately NOT required:
// the e2e rules exclude tests/ on purpose, and a corpus edit is a contract
// change, not a behaviour change.
const DRIVER_UNIT_GATES = ['ahk-suite', 'hs', 'linux'];

const failures = [];

function check(condition, message) {
	if (!condition) failures.push(message);
}

/**
 * Returns a repo-relative path to a real file somewhere under `rel`, so the
 * selection is exercised against something that actually exists.
 * @param {string} rel Path relative to the `_shared` root.
 * @returns {string|null} Repo-relative POSIX path, or null when the tree is empty.
 */
function findRealFile(rel) {
	const root = path.join(SHARED, rel);
	if (!fs.existsSync(root)) return null;
	const stack = [root];
	while (stack.length > 0) {
		const dir = stack.pop();
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const p = path.join(dir, entry.name);
			if (entry.isDirectory()) stack.push(p);
			else return path.relative(ROOT, p).replace(/\\/g, '/');
		}
	}
	return null;
}

// ==========================================================
// ==========================================================
// ======= 1/ The gates exist before anything else ==========
// ==========================================================
// ==========================================================

for (const gate of DRIVER_UNIT_GATES) {
	check(
		Object.prototype.hasOwnProperty.call(GATE_COMMANDS, gate),
		`this guard expects a "${gate}" gate and verify-change no longer defines one — ` +
			'update DRIVER_UNIT_GATES rather than letting the assertions below check nothing'
	);
}

// ==========================================================
// ==========================================================
// ======= 2/ Every shared contract tree selects them =======
// ==========================================================
// ==========================================================

for (const tree of ['core', 'tests']) {
	const sample = findRealFile(tree);
	check(sample !== null, `_shared/${tree}/ holds no file — the sample walk found nothing, so nothing below was verified`);
	if (sample === null) continue;

	const selected = [...selectGates([sample]).keys()];
	for (const gate of DRIVER_UNIT_GATES) {
		check(
			selected.includes(gate),
			`editing "${sample}" selects [${selected.join(', ')}] — "${gate}" is missing. ` +
				'ADR-006 makes this tree binding on every driver, so every driver suite has to run for it'
		);
	}
}

// ==================================
// ==================================
// ======= 3/ Report ================
// ==================================
// ==================================

if (failures.length > 0) {
	console.error('[FAIL] shared-contract gate coverage:');
	for (const f of failures) console.error(`  - ${f}`);
	process.exit(1);
}

console.log(`[OK] shared-contract gate coverage (2 shared trees x ${DRIVER_UNIT_GATES.length} driver suites).`);
