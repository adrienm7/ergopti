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
		if (owners.has(output))
			duplicates.push(`${output}: ${owners.get(output)} + ${generator.script}`);
		owners.set(output, generator.script);
	}
}
assert.deepEqual(duplicates, [], 'each output must be generated once per registry traversal');
assert.deepEqual(
	[...owners.keys()].sort(),
	allOutputs(),
	'execution and snapshot inventories must agree'
);
console.log(`[OK] ${owners.size} generated outputs have exactly one execution owner.`);

// The personal identity owner must actually emit both native contracts in a
// private root; the registry alone cannot prove it writes its declared outputs.
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const PersonalFiles = require('../codegen/codegen-personal-file-descriptors.cjs');
const personalOwner = GENERATORS.find(
	(entry) => entry.script === 'codegen/codegen-personal-file-descriptors.cjs'
);
assert.deepEqual(personalOwner.outputs, [PersonalFiles.LUA_OUTPUT, PersonalFiles.AHK_OUTPUT]);
const privateRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-personal-descriptors-'));
try {
	const source = path.join(privateRoot, PersonalFiles.SOURCE);
	fs.mkdirSync(path.dirname(source), { recursive: true });
	fs.copyFileSync(path.resolve(__dirname, '../..', PersonalFiles.SOURCE), source);
	PersonalFiles.main(privateRoot);
	const lua = fs.readFileSync(path.join(privateRoot, PersonalFiles.LUA_OUTPUT), 'utf8');
	const ahk = fs.readFileSync(path.join(privateRoot, PersonalFiles.AHK_OUTPUT), 'utf8');
	assert.ok(lua.includes('local NAMESPACE = "personal-file:"'));
	assert.ok(ahk.startsWith('\uFEFF; _generated/personal_file_descriptors.ahk\n'));
	assert.ok(ahk.includes('Identity := "personal-file:"'));
	assert.ok(!lua.includes('\r') && !ahk.includes('\r'), 'both owned outputs remain LF');
	const policy = require(source);
	for (const invalid of [
		{ ...policy, namespace: 'personal.file:' },
		{ ...policy, version: 2 },
		{ ...policy, future: true },
		{ ...policy, label_separator: '\u0001' }
	]) {
		assert.throws(() => PersonalFiles.render(invalid), TypeError);
	}
} finally {
	fs.rmSync(privateRoot, { recursive: true, force: true });
}
