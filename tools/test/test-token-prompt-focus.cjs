'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const callbacks = {};
const timers = [];
const body = {};
const input = {
	value: '',
	selections: 0,
	focus() {
		document.activeElement = this;
	},
	select() {
		this.selections++;
	},
	addEventListener() {}
};
const document = { body, activeElement: body, getElementById: () => input, addEventListener() {} };
const context = vm.createContext({
	document,
	makeHostBridge: () => () => {},
	setTimeout: (fn) => timers.push(fn),
	window: { addEventListener: (_, fn) => (callbacks.load = fn) }
});
vm.runInContext(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/ui/token_prompt/script.js'),
		'utf8'
	),
	context
);
callbacks.load();
assert.equal(document.activeElement, input, 'initial focus remains available');
input.value = 'hf_first';
timers[0]();
assert.equal(input.selections, 0, 'retry must not select and replace the token being typed');
const cancel = {};
document.activeElement = cancel;
timers[1]();
assert.equal(
	document.activeElement,
	cancel,
	'retry must not steal focus from a control chosen by the user'
);
console.log('token prompt retries preserve typing and user focus');
