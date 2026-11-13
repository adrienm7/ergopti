// tools/test/test-shared-literal-inventory.cjs

/**
 * ==============================================================================
 * MODULE: Shared Literal Inventory Ratchet (Rule A)
 * DESCRIPTION:
 * Holds the hand-typed values the drivers declare instead of reading them
 * from _shared (durations, sizes and limits, colours, file and enum names,
 * bare timer delays) and the Lua logic macOS and Linux both carry, to the
 * counts measured when the structure plan was written
 * (docs/design/structure-plan.md, Rule A). The measurement is
 * tools/audit/shared-literal-inventory.cjs.
 *
 * Counts, not lines: the detectors are lexical and over-report, so a line
 * list would churn with every edit. A count per driver and kind still fails
 * on the thing Rule A forbids, a new hand-typed copy, and the migration of
 * one copy lowers it. A count that falls fails until the baseline is lowered
 * in the same change (`--update-baseline`, which refuses to raise anything).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Inventory = require('../audit/shared-literal-inventory.cjs');

const BASELINE_FILE = path.join(__dirname, 'shared-literal-inventory-baseline.json');

/** Flattens the inventory counts into "tree.kind" numbers. */
function numbers(counts) {
	const out = {};
	for (const [tree, kinds] of Object.entries(counts)) {
		if (typeof kinds === 'number') out[tree] = kinds;
		else for (const [kind, n] of Object.entries(kinds)) out[`${tree}.${kind}`] = n;
	}
	return out;
}

/** The classifiers recognise what the inventory is about, and nothing else. */
function selfTest() {
	const v = (rhs) => Inventory.valueOf(rhs);
	assert.equal(Inventory.kindOf('RETRY_DELAY_MS', v('250')), 'duration');
	assert.equal(Inventory.kindOf('MAX_ENTRIES', v('64')), 'limit');
	assert.equal(Inventory.kindOf('ACCENT', v('"#1A2B3C"')), 'color');
	assert.equal(Inventory.kindOf('CONFIG_FILE', v('"config.toml"')), 'path_name');
	assert.equal(Inventory.kindOf('REASON_BUSY', v('"busy"')), 'enum_name');
	assert.equal(
		Inventory.kindOf('GREETING', v('"Hello, world"')),
		null,
		"a sentence is the i18n gate's, not this one"
	);
	assert.equal(Inventory.valueOf('compute(1)'), null, 'a computed value is not a literal');
}

function main() {
	selfTest();
	const inventory = Inventory.inventory();
	assert.ok(inventory.files > 1000, `the scan read only ${inventory.files} driver files`);
	const measured = numbers(Inventory.counts(inventory));
	const baseline = JSON.parse(fs.readFileSync(BASELINE_FILE, 'utf8'));
	const failures = [];
	for (const [key, value] of Object.entries(measured)) {
		const base = baseline[key];
		if (base === undefined) failures.push(`${key}: ${value} has no baseline entry`);
		else if (value > base) failures.push(`${key} rose to ${value} (baseline ${base})`);
		else if (value < base)
			failures.push(
				`${key} fell to ${value} (baseline ${base}): lower the baseline in this change (--update-baseline)`
			);
	}
	for (const key of Object.keys(baseline))
		if (!key.startsWith('_') && !(key in measured) && baseline[key] !== 0)
			failures.push(`${key} fell to 0: lower the baseline (--update-baseline)`);

	if (process.argv.includes('--update-baseline')) {
		const rising = failures.filter((f) => / rose to |has no baseline/.test(f));
		// The structure phase 2 runner only: a step that brings two drivers'
		// copies of one function to the same spelling exposes a duplicate the
		// tree already had. The rise moves the baseline and is named in the
		// step's commit, one [RISE] line each, never taken silently.
		if (
			rising.length > 0 &&
			process.argv.includes('--allow-rise') &&
			process.env.ERGOPTI_STRUCTURE_PHASE === '2'
		) {
			fs.writeFileSync(
				BASELINE_FILE,
				JSON.stringify({ _comment: baseline._comment, ...measured }, null, '\t') + '\n',
				'utf8'
			);
			for (const [key, value] of Object.entries(measured))
				if (baseline[key] === undefined || value > baseline[key])
					console.log(`[RISE] Rule A ${key} rose to ${value} (baseline ${baseline[key] ?? 0})`);
			return;
		}
		if (rising.length > 0) {
			console.error(
				'[ERROR] refusing to raise the shared literal baseline:\n    - ' + rising.join('\n    - ')
			);
			process.exit(1);
		}
		fs.writeFileSync(
			BASELINE_FILE,
			JSON.stringify({ _comment: baseline._comment, ...measured }, null, '\t') + '\n',
			'utf8'
		);
		console.log('[OK] shared literal baseline lowered to the measurement.');
		return;
	}
	if (failures.length > 0) {
		console.error('\x1b[31m[ERROR] shared literal inventory (Rule A):\x1b[0m');
		for (const f of failures) console.error('    - ' + f);
		console.error(
			'    Read the value from its shared home (docs/design/structure-plan.md, Rule A) instead of typing it.'
		);
		process.exit(1);
	}
	console.log(
		`\x1b[32m[OK] shared literal inventory (Rule A): ${inventory.items.length} item(s), every count at its baseline.\x1b[0m`
	);
}

main();
