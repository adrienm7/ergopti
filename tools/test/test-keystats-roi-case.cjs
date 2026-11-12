// tools/test/test-keystats-roi-case.cjs

/**
 * ==============================================================================
 * MODULE: Qualified ROI Case Projection Contract
 * DESCRIPTION:
 * Keeps the native Windows receipt separate from general Unicode conversion.
 * Refuses stale sources, invented scalar ranges and changed observation counts,
 * and pins representative differences before the Lua and AHK corpus replays.
 * ==============================================================================
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Codegen = require('../codegen/codegen-keystats-roi-case.cjs');

const ROOT = path.resolve(__dirname, '../..');
const profile = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/data/keystats_roi_lowercase.json'),
		'utf8'
	)
);
const unicode = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/_shared/lua/unicode_case/data.lua')
);
const projected = Codegen.project(profile, unicode);

for (const [input, expected] of [
	['A', 'a'],
	['É', 'é'],
	['İ', 'İ'],
	['ǅ', 'ǅ'],
	['ẞ', 'ẞ'],
	['K', 'K'],
	['Σ', 'σ'],
	['𐐀', '𐐨']
]) {
	assert.equal(projected.mappings.get(input) ?? input, expected, input);
}
assert.equal(projected.vectors.length, 1488, 'the full measured candidate set is retained');
assert.equal(
	projected.mappings.size,
	1013,
	'the native profile retains expansions and 474 observations'
);
for (const [file, body] of Object.entries(Codegen.render(profile, unicode))) {
	assert.equal(fs.readFileSync(path.join(ROOT, file), 'utf8'), body, file);
}

/** Every mutant changes the admitted receipt, rather than the generated output. */
function refuses(edit, reason) {
	const changed = structuredClone(profile);
	edit(changed);
	assert.throws(() => Codegen.project(changed, unicode), reason);
}

// The header names the source's own place: the structure move rewrites it, and
// the measured table is unchanged. A changed table still needs requalifying.
const text = unicode.toString('utf8');
const moved = Buffer.from(text.replace(/^--- [^\n]*\n/, '--- _shared/elsewhere/data.lua\n'));
assert.equal(Codegen.project(profile, moved).mappings.size, 1013, 'a moved header stays qualified');
assert.throws(
	() => Codegen.project(profile, Buffer.from(text.replace('return {', 'return {\n\textra = 1,'))),
	/requalify/
);
refuses((changed) => (changed.qualification.node_version = 'unqualified'), /qualified Node/);
refuses((changed) => (changed.qualification.unicode_table_sha256 = 'unqualified'), /requalify/);
refuses((changed) => changed.retained_ranges.unshift([-1, -1]), /scalar intervals/);
refuses(
	(changed) => changed.retained_ranges.unshift(changed.retained_ranges[0]),
	/scalar intervals/
);
refuses((changed) => (changed.retained_ranges = [[0xd800, 0xd800]]), /scalar intervals/);
refuses((changed) => changed.retained_ranges.push([0x110000, 0x110000]), /scalar intervals/);
refuses((changed) => changed.qualification.retained_scalars++, /retained scalar receipt/);
refuses((changed) => changed.qualification.scalar_candidates++, /candidate census/);
refuses((changed) => {
	changed.retained_ranges.unshift([0, 0]);
	changed.qualification.retained_scalars++;
}, /unmeasured scalar/);
refuses((changed) => changed.context_vectors.push(['ΟΣ', 'ος']), /contextual Windows/);
assert.throws(
	() => Codegen.project(profile, Buffer.concat([unicode, Buffer.from('\n')])),
	/requalify/
);

console.log(
	'[OK] ROI case projection: 1,488 measured candidates, contextual cases and 11 refused receipts.'
);
