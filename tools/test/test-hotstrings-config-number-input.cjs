// tools/test/test-hotstrings-config-number-input.cjs

/** Exercises numeric settings through the actual page bindings and host bridge. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const messages = [];
const context = vm.createContext({
	document: {},
	makeHostBridge: () => (packet) => messages.push(packet)
});
context.window = context;
vm.runInContext(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/ui/hotstrings_config_window/script.js'),
		'utf8'
	),
	context
);
// The loaded page asks its host for the state once (WVH-001); the bindings
// under test send nothing else until a field changes.
assert.deepEqual(messages.splice(0), ['ready'], 'the page posts ready once on load');
function field() {
	const input = {
		value: '',
		addEventListener(_, callback) {
			this.change = callback;
		}
	};
	return {
		input,
		classList: { toggle() {} },
		querySelector: (selector) => (selector === 'input' ? input : { addEventListener() {} })
	};
}
const category = {
	name: 'general',
	group: 'common',
	delay_ms: 750,
	delay_default_ms: 750,
	priority: 1,
	priority_default: 1
};
for (const [method, key] of [
	['bindDelay', 'ms'],
	['bindPriority', 'priority']
]) {
	const f = field();
	context[method](f, category, null);
	f.input.value = '1e2';
	f.input.change();
	assert.equal(
		messages.pop()[key],
		100,
		`${method}: scientific notation must preserve its actual numeric value`
	);
	for (const invalid of method === 'bindDelay'
		? ['', '2.5', '9007199254740992']
		: ['2.5', '9007199254740992']) {
		f.input.value = invalid;
		f.input.change();
		assert.equal(
			messages.length,
			0,
			`${method}: invalid integer ${invalid} must not be silently truncated`
		);
	}
}
for (const section of [null, { name: 'snippets', priority: 3, priority_default: 5 }]) {
	const f = field();
	context.bindPriority(f, category, section);
	f.input.value = '';
	f.input.validity = { badInput: true };
	f.input.change();
	assert.equal(messages.length, 0, 'an unfinished numeric edit must not erase the override');
	f.input.validity = { badInput: false };
	f.input.change();
	const clear = messages.pop();
	assert.equal(clear?.action, 'clear_priority', 'clearing priority must request inheritance');
	assert.equal(
		clear?.section,
		section?.name || '',
		'the correct category or section must be cleared'
	);
}
console.log('hotstring numeric settings preserve entered values and clear priority');
