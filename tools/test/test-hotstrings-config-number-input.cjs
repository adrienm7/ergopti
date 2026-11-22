// tools/test/test-hotstrings-config-number-input.cjs

/** Exercises numeric settings through the actual page bindings and host bridge. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const messages = [];
const documentListeners = {};
const context = vm.createContext({
	document: {
		// The page draws again once i18n.js has applied the strings.
		addEventListener(type, fn) {
			documentListeners[type] = fn;
		}
	},
	makeHostBridge: () => (packet) => messages.push(packet)
});
context.window = context;
// The page reads the shared value contract that its HTML loads first.
vm.runInContext(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/ui/value_check.js'),
		'utf8'
	),
	context
);
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
assert.equal(
	typeof documentListeners['i18n:applied'],
	'function',
	'the page redraws its cards once the locale strings are applied'
);
function field() {
	const input = {
		value: '',
		refusal: '',
		setCustomValidity(message) {
			this.refusal = message;
		},
		reportValidity() {},
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
	f.input.value = '100';
	f.input.change();
	assert.equal(messages.pop()[key], 100, `${method}: a whole number is sent as typed`);
	assert.equal(f.input.refusal, '', `${method}: an admitted value clears the refusal`);
	for (const invalid of ['1e2', '2.5', '9007199254740992']) {
		f.input.value = invalid;
		f.input.refusal = '';
		f.input.change();
		assert.equal(
			messages.length,
			0,
			`${method}: invalid integer ${invalid} must not be silently truncated`
		);
		assert.notEqual(f.input.refusal, '', `${method}: ${invalid} must be refused with a message`);
	}
}
// A blank delay or priority removes the override, so the inherited value
// applies again (maintainer decision of 2026-11-22, PCK-13 for overrides);
// text the number field cannot read stays refused.
for (const [method, action] of [
	['bindDelay', 'clear_delay'],
	['bindPriority', 'clear_priority']
]) {
	for (const section of [
		null,
		{ name: 'snippets', delay_ms: 50, priority: 3, priority_default: 5 }
	]) {
		const f = field();
		context[method](f, category, section);
		f.input.value = '';
		f.input.validity = { badInput: true };
		f.input.change();
		assert.equal(messages.length, 0, `${method}: an unreadable entry must not erase the override`);
		assert.notEqual(
			f.input.refusal,
			'',
			`${method}: an unreadable entry is refused with a message`
		);
		f.input.validity = { badInput: false };
		f.input.value = '  ';
		f.input.change();
		const clear = messages.pop();
		assert.equal(clear?.action, action, `${method}: a blank entry must request inheritance`);
		assert.equal(
			clear?.section,
			section?.name || '',
			`${method}: the correct category or section must be cleared`
		);
		assert.equal(f.input.refusal, '', `${method}: a blank entry is no refusal`);
	}
}
console.log('hotstring numeric settings preserve entered values and a blank clears the override');
