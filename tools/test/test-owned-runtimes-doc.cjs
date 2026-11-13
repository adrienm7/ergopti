// tools/test/test-owned-runtimes-doc.cjs

/**
 * ==============================================================================
 * MODULE: Owned Runtimes Document Drift Tests
 * DESCRIPTION:
 * Keeps the tables of docs/design/owned-runtimes.md equal to what
 * tools/codegen/codegen-owned-runtimes.cjs renders from
 * _shared/core/network/data/owned_runtimes.json, so the document never shows a decision the
 * registry does not hold.
 *
 * FEATURES & RATIONALE:
 * 1. The committed document equals its regeneration, byte for byte.
 * 2. The renderer follows the data: a row's decision, an alternative and a
 *    state change each reach the rendered table, so the drift check cannot
 *    pass on a renderer that ignores the registry.
 * 3. The splice refuses a document whose markers are missing or doubled
 *    instead of writing the tables somewhere else.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Registry = require('../lib/owned-runtimes.cjs');

let failures = 0;
let checks = 0;

/**
 * Runs one named check and records its outcome.
 * @param {string} name
 * @param {Function} body
 */
function check(name, body) {
	checks += 1;
	try {
		body();
		console.log(`PASS ${name}`);
	} catch (error) {
		failures += 1;
		console.error(`FAIL ${name}\n${error.stack || error}`);
	}
}

const registry = Registry.load();
const { current, next } = Registry.generate();

check('the committed document matches the registry', () => {
	assert.equal(
		current === next,
		true,
		'docs/design/owned-runtimes.md is stale: run node tools/codegen/codegen-owned-runtimes.cjs'
	);
});

check('every region is rendered between its markers', () => {
	for (const region of Registry.REGIONS) {
		const body = Registry.render(registry, region);
		assert(current.includes(body), `the ${region} region is not the rendered table`);
	}
});

check('a changed decision, alternative or state reaches the table', () => {
	const changed = structuredClone(registry);
	const row = changed.rows.find((candidate) => candidate.os === 'linux');
	row.decision_text = 'SYS: a decision no row holds';
	row.alternative = 'an alternative no row holds';
	row.status = Object.keys(changed.statuses).find((status) => status !== row.status);
	const before = Registry.render(registry, 'linux');
	const after = Registry.render(changed, 'linux');
	assert.notEqual(after, before);
	assert.match(
		after,
		/SYS: a decision no row holds \(alternative noted: an alternative no row holds\)/
	);
	assert.notEqual(Registry.splice(current, changed), current);
	assert.notEqual(Registry.render(changed, 'headline'), Registry.render(registry, 'headline'));
});

check('a cell holding a pipe is escaped, not split', () => {
	const piped = structuredClone(registry);
	piped.rows.find((row) => row.os === 'macos').used_for = 'curl ... | sh';
	assert.match(Registry.render(piped, 'macos'), /curl \.\.\. \\\| sh/);
});

check('the splice refuses a missing or doubled marker', () => {
	const marker = '<!-- END GENERATED linux -->';
	assert.throws(() => Registry.splice(current.replace(marker, ''), registry), /end marker/);
	const begin = current.match(/<!-- BEGIN GENERATED macos:[^\n]*\n/)[0];
	assert.throws(() => Registry.splice(current + begin, registry), /one "macos" begin marker/);
});

if (failures > 0) {
	console.error(`[FAIL] owned runtimes document: ${failures} of ${checks} checks failed.`);
	process.exit(1);
}
console.log(`[OK] owned runtimes document (${checks} checks).`);
