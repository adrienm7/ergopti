// tools/test/fixtures/linux-e2e-shards.cjs
'use strict';

/** Maps a Linux E2E step to its matrix row and the row-guarded condition it carries. */
const assert = require('node:assert/strict');
const fixture = require('./linux-e2e-shards.json');

const owner = new Map();
for (const [shard, names] of Object.entries(fixture.shards))
	for (const name of names) {
		assert.ok(!owner.has(name), 'Linux E2E step listed twice: ' + name);
		owner.set(name, shard);
	}
for (const name of fixture.shared) {
	assert.ok(!owner.has(name), 'Linux E2E step both shared and sharded: ' + name);
	owner.set(name, null);
}

/** The row that runs a step, or null for a step every row runs. */
function shardOf(name) {
	assert.ok(owner.has(name), 'Unknown Linux E2E step: ' + name);
	return owner.get(name);
}

/** The step condition: the original predicate, narrowed to the step's own row. */
function condition(name, predicate) {
	const shard = shardOf(name);
	if (shard === null) return predicate;
	// A predicate already narrowed to this row (a reviewed fixture) stays as it is.
	if (predicate.endsWith(" && matrix.shard == '" + shard + "' }}")) return predicate;
	const inner =
		predicate === 'always()'
			? 'always()'
			: predicate
					.trim()
					.replace(/^\$\{\{\s*/, '')
					.replace(/\s*\}\}$/, '')
					.trim();
	return '${{ ' + inner + " && matrix.shard == '" + shard + "' }}";
}

/** Whether a step name belongs to the Linux E2E matrix inventory. */
function has(name) {
	return owner.has(name);
}

module.exports = { fixture, shards: Object.keys(fixture.shards), shardOf, condition, has };
