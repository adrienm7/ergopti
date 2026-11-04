// tools/test/test-editors-ime-keyboard.cjs

/** Dispatches composition keystrokes to the shared editors' real listeners. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
function fixture(name) {
	const elements = new Map();
	function element(id) {
		if (!elements.has(id))
			elements.set(id, {
				id,
				textContent: '',
				innerHTML: '',
				appendChild() {},
				listeners: {},
				style: {},
				classList: {
					add() {},
					remove() {},
					contains() {
						return false;
					}
				},
				addEventListener(type, fn) {
					(this.listeners[type] ||= []).push(fn);
				},
				querySelectorAll() {
					return [];
				},
				focus() {}
			});
		return elements.get(id);
	}
	const document = {
		listeners: {},
		createElement: () => ({ dataset: {}, classList: { add() {} } }),
		createTextNode: (text) => ({ textContent: text }),
		createRange: () => ({ setStartAfter() {}, collapse() {} }),
		getElementById: element,
		querySelectorAll: () => [],
		addEventListener(type, fn) {
			(this.listeners[type] ||= []).push(fn);
		}
	};
	const context = vm.createContext({
		document,
		makeHostBridge: () => () => {},
		setTimeout() {},
		clearTimeout() {}
	});
	context.window = context;
	context.addEventListener = () => {};
	context.getSelection = () => null;
	const script = path.join(__dirname, `../../static/ergopti_plus/_shared/ui/${name}/script.js`);
	vm.runInContext(fs.readFileSync(script, 'utf8'), context);
	return { context, element, document };
}
function dispatch(target, key, isComposing = true, keyCode = 0) {
	let prevented = false;
	const event = {
		key,
		isComposing,
		keyCode,
		preventDefault() {
			prevented = true;
		},
		stopPropagation() {}
	};
	for (const fn of target.listeners.keydown || []) fn(event);
	return prevented;
}
const actualPrompt = fixture('prompt_editor');
const listenerCount = () =>
	(actualPrompt.document.listeners.compositionstart || []).length +
	(actualPrompt.document.listeners.compositionend || []).length;
const originalCount = listenerCount();
for (let i = 0; i < 3; i++) {
	actualPrompt.context.checkPlaceholder();
	actualPrompt.context.insertBrAtCursor();
	actualPrompt.context.insertChipAtCursor('context');
}
assert.equal(originalCount, 2, 'composition listeners must be registered once');
assert.equal(
	listenerCount(),
	originalCount,
	'editing repeatedly must not add composition listeners'
);
const prompt = fixture('prompt_editor');
prompt.context.insertBrAtCursor = () => {};
assert.equal(
	dispatch(prompt.element('e-out'), 'Enter'),
	false,
	'composing Enter must not insert a newline'
);
let cancelled = 0;
prompt.context.doCancel = () => cancelled++;
dispatch(prompt.document, 'Escape');
assert.equal(cancelled, 0, 'composing Escape must not close the prompt editor');
dispatch(prompt.document, 'Escape', false, 229);
assert.equal(cancelled, 0, 'legacy IME keyCode must also be ignored');
dispatch(prompt.document, 'Escape', false);
assert.equal(cancelled, 1, 'ordinary Escape must still close');
const hotstring = fixture('hotstring_editor');
hotstring.context.insertBrAtCursor = () => {};
assert.equal(
	dispatch(hotstring.element('sec-modal'), 'Enter'),
	false,
	'composition must not submit section settings'
);
assert.equal(
	dispatch(hotstring.element('e-trig'), 'Enter'),
	false,
	'composing Enter must not move focus'
);
assert.equal(
	dispatch(hotstring.element('e-out'), 'Enter'),
	false,
	'composing Enter must not insert a hotstring command'
);
assert.equal(
	dispatch(hotstring.element('e-out'), 'Enter', false),
	true,
	'ordinary Enter must still insert a command'
);
for (const [name, fixture] of [
	['prompt', prompt],
	['hotstring', hotstring]
]) {
	let conversions = 0;
	let selectionReads = 0;
	fixture.context.tryConvertToken = () => conversions++;
	fixture.context.checkAc = () => {};
	fixture.context.checkPlaceholder = () => {};
	fixture.context.checkPh = () => {};
	fixture.context.getSelection = () => {
		selectionReads++;
		return null;
	};
	const editor = fixture.element('e-out');
	for (const fn of fixture.document.listeners.compositionstart || []) fn({ target: editor });
	for (const fn of editor.listeners.input || []) fn({ isComposing: true });
	for (const fn of editor.listeners.keyup || []) fn({ key: '}', isComposing: true });
	for (const fn of editor.listeners.input || []) fn({ isComposing: false });
	assert.equal(
		dispatch(editor, 'Enter', false),
		false,
		`${name}: composition state protects events missing the flag`
	);
	for (const fn of fixture.document.listeners.selectionchange || []) fn({});
	assert.equal(conversions, 0, `${name}: preedit must never become a token`);
	assert.equal(selectionReads, 0, `${name}: composition selection must stay untouched`);
	for (const fn of fixture.document.listeners.compositionend || []) fn({ target: editor });
	for (const fn of editor.listeners.input || []) fn({ isComposing: false });
	assert.equal(conversions, 1, `${name}: committed input must still be processed`);
}
console.log('editor keyboard shortcuts leave IME composition alone');
