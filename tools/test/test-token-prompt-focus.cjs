'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const callbacks = {};
const timers = [];
const posts = [];
const inputHandlers = {};
const documentHandlers = {};
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
	addEventListener: (type, fn) => (inputHandlers[type] = fn)
};
const document = {
	body,
	activeElement: body,
	getElementById: () => input,
	addEventListener: (type, fn) => (documentHandlers[type] = documentHandlers[type] || []).push(fn)
};
const context = vm.createContext({
	document,
	makeHostBridge: () => (message) => posts.push(message),
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

// pck-01: the token is a secret, typed in a masked field with no autofill
const html = fs.readFileSync(
	path.join(__dirname, '../../static/ergopti_plus/_shared/ui/token_prompt/index.html'),
	'utf8'
);
const field = html.match(/<input[^>]*id="token-input"[^>]*>/s);
assert.ok(field, 'the token field exists');
assert.match(field[0], /type="password"/, 'pck-01: the token field masks what is typed');
assert.match(
	field[0],
	/autocomplete="off"/,
	'pck-01: the browser does not offer to keep the token'
);

/**
 * Builds a keydown event that records whether the page consumed it.
 * @param {string} key Key name.
 * @param {object} extra Extra event fields.
 * @returns {object} Event.
 */
function keyEvent(key, extra = {}) {
	return {
		key,
		isComposing: false,
		defaultPrevented: false,
		preventDefault() {
			this.defaultPrevented = true;
		},
		...extra
	};
}
const pressDocument = (event) => (documentHandlers.keydown || []).forEach((fn) => fn(event));

// pck-05: Escape cancels the token page as it cancels the numeric prompt
posts.length = 0;
const escape = keyEvent('Escape');
pressDocument(escape);
assert.deepEqual(posts, ['cancel'], 'pck-05: Escape posts cancel');
assert.equal(escape.defaultPrevented, true, 'pck-05: Escape is consumed');
posts.length = 0;
pressDocument(keyEvent('Escape', { isComposing: true }));
assert.deepEqual(posts, [], 'an IME composition keeps its own Escape');

posts.length = 0;
assert.equal(typeof inputHandlers.keydown, 'function', 'Enter is read on keydown');
input.value = 'hf_secret';
inputHandlers.keydown(keyEvent('Enter'));
assert.equal(
	JSON.stringify(posts),
	JSON.stringify([{ type: 'validate', token: 'hf_secret' }]),
	'Enter validates the token'
);
posts.length = 0;
inputHandlers.keydown(keyEvent('Enter', { isComposing: true }));
assert.deepEqual(posts, [], 'Enter that ends a composition does not validate');

console.log(
	'token prompt retries preserve typing and user focus; Escape cancels; the field is masked'
);
