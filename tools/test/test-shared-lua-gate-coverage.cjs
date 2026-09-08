// tools/test/test-shared-lua-gate-coverage.cjs

/**
 * ==============================================================================
 * MODULE: Shared Lua Consumer Gate Coverage
 * DESCRIPTION:
 * Exercises the real gate selector for every shared Lua source. Shared runtime
 * changes must select both Lua drivers and their behavior suites, even when no
 * driver-local test file accompanies the change.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { GATE_COMMANDS, selectGates } = require('./verify-change.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const PREFIX = 'static/ergopti_plus/_shared/lua/';
const CONSUMER_GATES = ['hs', 'linux', 'hs-e2e', 'linux-e2e'];
const files = [];
const missing = [];

/** Discovers actual runtime sources without following directory symlinks. */
function collect(relative) {
	for (const entry of fs.readdirSync(path.join(ROOT, relative), { withFileTypes: true })) {
		const child = relative + entry.name;
		if (entry.isDirectory()) collect(child + '/');
		else if (entry.isFile() && child.endsWith('.lua')) files.push(child);
	}
}

collect(PREFIX);
assert(files.length > 0, 'shared Lua source discovery must not be empty');
for (const gate of CONSUMER_GATES) {
	assert(Object.hasOwn(GATE_COMMANDS, gate), `consumer gate ${gate} must have an executable command`);
}

for (const file of [...files, PREFIX + 'removed_module.lua']) {
	const gates = selectGates([file]);
	for (const gate of CONSUMER_GATES) {
		if (!gates.has(gate)) missing.push(`${file}: missing ${gate}`);
	}
	assert(gates.has('js'), `${file}: retain shared parity checks`);
	for (const gate of gates.keys()) {
		assert(!gate.startsWith('ahk'), `${file}: Lua implementations do not execute in AHK`);
	}
}

for (const file of [
	PREFIX + 'README.md', PREFIX + 'codec.json', PREFIX + 'codec.lua.bak',
	'static/ergopti_plus/_shared/lua_backup/codec.lua',
]) {
	const gates = selectGates([file]);
	for (const gate of CONSUMER_GATES) {
		assert(!gates.has(gate), `${file}: documentation and neighboring paths are not runtime changes`);
	}
}

for (const tree of ['core', 'tests']) {
	const gates = selectGates([`static/ergopti_plus/_shared/${tree}/contract.json`]);
	for (const gate of ['ahk-suite', 'hs', 'linux']) {
		assert(gates.has(gate), 'shared contracts retain every driver unit gate');
	}
	assert(!gates.has('hs-e2e') && !gates.has('linux-e2e'), 'contract changes retain unit-only policy');
}

console.log(`Shared Lua coverage: ${files.length} real sources; ${missing.length} missing selections.`);
assert.equal(missing.length, 0, missing.slice(0, 4).join('\n'));
