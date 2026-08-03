// tools/test/test-npm-aliases-match-the-suite.cjs

/**
 * ==============================================================================
 * MODULE: npm Alias ⇄ Suite Entry Parity
 * DESCRIPTION:
 * The JS validation suite invokes every gate by PATH (`tools/test/test-*.cjs`),
 * and package.json separately declares a named alias for some of them so one
 * check can be run by hand. Nothing kept the two lists in step, and the two
 * directions turned out to matter very differently.
 *
 * ONE DIRECTION IS A BUG, THE OTHER IS A CONVENTION NOBODY HELD.
 *
 * An alias naming a gate the suite does NOT run is a check nobody runs and
 * everybody believes in. Measured on 2026-08-03, there were three:
 * `test:port-compliance`, `test:priority-parity` and `test:manifest-parity` —
 * all three passing, all three run by nothing at all. Port compliance is the gate
 * that validates the 21 ports against contracts.json and every AutoHotkey
 * ADAPTER_ map; it had been dark. They are in the suite now, and this direction
 * is an ASSERTION so no gate can go dark again.
 *
 * The reverse — every suite gate having an alias — was never true: 78 of them had
 * none. Turning that into a rule would mean 78 lines of package.json mirroring
 * the suite, which is churn, not safety. It is a RATCHET instead: the count may
 * only fall, so adding a gate with an alias is free and adding one without makes
 * the number worse, deliberately.
 *
 * The parses are floored: a regex that stopped matching would report zero and
 * pass over nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SUITE = path.join(ROOT, 'tools/test/run-js-suite.cjs');
const PKG = path.join(ROOT, 'package.json');

// Aliases that name something the suite is not expected to run: the aggregate
// runners and the developer helper. An entry here is a decision; anything else
// unlisted is a gate going dark.
const NOT_SUITE_ENTRIES = new Set([
	'tools/test/run-js-suite.cjs',   // the suite itself
	'tools/test/verify-change.cjs',  // derives which gates a change needs
	'tools/test/test-properties.cjs' // property + mutation pass, run under --full
]);

// Gates the suite runs with no npm alias, measured 2026-08-03. Lower it as
// aliases are added; never raise it.
const BASELINE_ALIASLESS = 78;

const errors = [];

const suiteSrc = fs.readFileSync(SUITE, 'utf8');
const scripts = JSON.parse(fs.readFileSync(PKG, 'utf8')).scripts || {};

// Every `args: ['tools/test/<file>.cjs']` the suite declares.
const suitePaths = new Set(
	[...suiteSrc.matchAll(/args:\s*\[\s*'(tools\/test\/[^']+\.cjs)'/g)].map((m) => m[1])
);
if (suitePaths.size < 50) {
	errors.push(
		`parsed ${suitePaths.size} gate path(s) out of run-js-suite.cjs — expected at least 50. ` +
			'The parser drifted, and a parity check over nothing passes forever.'
	);
}

// Every npm script whose command is a single node invocation of a tools/test file.
const aliasPaths = new Map();
for (const [name, cmd] of Object.entries(scripts)) {
	const m = String(cmd).match(/^node \.\/(tools\/test\/[^\s]+\.cjs)$/);
	if (m) aliasPaths.set(m[1], name);
}
if (aliasPaths.size < 20) {
	errors.push(`parsed ${aliasPaths.size} single-gate npm alias(es) — expected at least 20; the parser drifted`);
}




// ==================================================
// ==================================================
// ======= 1/ No Alias May Name A Dark Gate =========
// ==================================================
// ==================================================

const dark = [];
for (const [p, name] of aliasPaths) {
	if (suitePaths.has(p) || NOT_SUITE_ENTRIES.has(p)) continue;
	dark.push(
		fs.existsSync(path.join(ROOT, p))
			? `${name} → ${p} (the file exists and passes, and nothing runs it)`
			: `${name} → ${p} (the file does not exist)`
	);
}
if (dark.length > 0) {
	errors.push(
		`${dark.length} npm alias(es) name a gate the suite does not run — a check nobody runs and ` +
			'everybody believes in. Add it to run-js-suite.cjs, or to NOT_SUITE_ENTRIES with a reason:\n' +
			dark.map((s) => `      · ${s}`).join('\n')
	);
}




// ==================================================
// ==================================================
// ======= 2/ The Aliasless Count Only Falls ========
// ==================================================
// ==================================================

const aliasless = [...suitePaths].filter((p) => !aliasPaths.has(p));
if (aliasless.length > BASELINE_ALIASLESS) {
	errors.push(
		`gates the suite runs with no npm alias rose to ${aliasless.length} (baseline ${BASELINE_ALIASLESS}). ` +
			'A gate with no alias cannot be run alone, so the first thing anyone does when it fails is ' +
			're-run the whole suite. Add "test:<name>": "node ./<path>" and lower the baseline.\n' +
			aliasless.slice(-5).map((p) => `      · ${p}`).join('\n')
	);
}




// ==================================================
// ==================================================
// ======= 3/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] npm aliases and the JS suite disagree:\x1b[0m');
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] no npm alias names a gate the suite skips; ${aliasless.length}/${suitePaths.size} suite ` +
		`gate(s) still have no alias (baseline ${BASELINE_ALIASLESS}).\x1b[0m`
);
