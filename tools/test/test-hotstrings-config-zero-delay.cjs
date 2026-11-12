// tools/test/test-hotstrings-config-zero-delay.cjs

/** Checks the real settings field before and after a zero-delay host update. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const messages = [];
const context = vm.createContext({
	document: {},
	makeHostBridge: () => (value) => messages.push(value)
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
		placeholder: '',
		addEventListener(_, fn) {
			this.change = fn;
		}
	};
	const reset = { addEventListener() {} };
	return {
		input,
		classList: { toggle() {} },
		querySelector: (selector) => (selector === 'input' ? input : reset)
	};
}
const category = { name: 'general', group: 'common', delay_ms: 750, delay_default_ms: 750 };
const before = field();
context.bindDelay(before, category, null);
before.input.value = '0';
before.input.change();
assert.equal(messages[0].ms, 0, 'zero must be sent as unlimited delay');
const after = field();
context.bindDelay(after, { ...category, delay_ms: 0, delay_overridden: true }, null);
assert.equal(
	Number(after.input.value),
	0,
	'host-confirmed unlimited delay must remain visible as zero'
);
const section = field();
context.bindDelay(section, category, {
	name: 'custom',
	delay_ms: 0,
	delay_default_ms: 750,
	delay_overridden: true
});
assert.equal(Number(section.input.value), 0, 'section unlimited delay must remain visible');
const absent = field();
context.bindDelay(absent, { ...category, delay_ms: null }, null);
assert.equal(Number(absent.input.value), 750, 'absent values still show the default');
console.log('zero unlimited delay remains visible after a settings round trip');
