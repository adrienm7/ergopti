// tools/test/test-generator-output-ownership.cjs

/**
 * Each generated output must have one execution owner. Registering both an
 * aggregate build and its leaf generators repeats generation and validation
 * inside every drift probe, without producing any additional artifact.
 */

'use strict';

const assert = require('node:assert/strict');
const { GENERATORS, allOutputs } = require('../build/generators.cjs');

const owners = new Map();
const scripts = new Set();
const duplicates = [];
assert.ok(GENERATORS.length > 0, 'the generation registry must not be empty');
for (const generator of GENERATORS) {
	assert.ok(!scripts.has(generator.script), `duplicate generator: ${generator.script}`);
	scripts.add(generator.script);
	assert.ok(generator.outputs.length > 0, `${generator.script}: declare its outputs`);
	for (const output of generator.outputs) {
		if (owners.has(output)) duplicates.push(`${output}: ${owners.get(output)} + ${generator.script}`);
		owners.set(output, generator.script);
	}
}
assert.deepEqual(duplicates, [], 'each output must be generated once per registry traversal');
assert.deepEqual([...owners.keys()].sort(), allOutputs(), 'execution and snapshot inventories must agree');
console.log(`[OK] ${owners.size} generated outputs have exactly one execution owner.`);
