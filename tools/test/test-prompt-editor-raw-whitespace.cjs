// Verifies that the real prompt editor sends the content it rendered.
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

function element() {
	return {
		childNodes: [],
		style: {},
		value: '',
		textContent: '',
		set innerHTML(value) {
			assert.equal(value, '');
			this.childNodes = [];
		},
		get innerHTML() {
			return '';
		},
		appendChild(node) {
			this.childNodes.push(node);
			this.textContent += node.textContent || '';
		},
		addEventListener() {},
		focus() {}
	};
}
const elements = Object.fromEntries(
	['e-out', 'e-out-ph', 'p-name', 'p-mode', 'title'].map((id) => [id, element()])
);
const messages = [];
const alerts = [];
const context = vm.createContext({
	console,
	setTimeout() {},
	clearTimeout() {},
	document: {
		getElementById: (id) => elements[id],
		addEventListener() {},
		createTextNode: (text) => ({ nodeType: 3, textContent: text }),
		createElement: () => element()
	},
	makeHostBridge: () => (message) => messages.push(message),
	alert: (message) => alerts.push(message)
});
context.window = context;
context._i18n_strings = { 'prompt_editor.required_fields': 'required' };
const source = fs.readFileSync(
	path.join(__dirname, '../../static/ergopti_plus/_shared/ui/prompt_editor/script.js'),
	'utf8'
);
vm.runInContext(source, context);
const prompt = '  \tRésumé “漢字”  \t';
context.init({
	edit_id: 'p',
	epoch: 7,
	title: 'Prompt',
	name: 'My profile',
	mode: 'parallel',
	prompt
});
context.doSave();
const saved = messages.find((message) => message.action === 'save');
assert.equal(
	saved.prompt,
	prompt,
	'editing an existing raw prompt preserves boundary spaces and tabs'
);
assert.equal(alerts.length, 0);
context.init({
	edit_id: 'p',
	epoch: 8,
	title: 'Prompt',
	name: 'My profile',
	mode: 'parallel',
	prompt: '  \t '
});
context.doSave();
assert.equal(messages.filter((message) => message.action === 'save').length, 1);
assert.deepEqual(alerts, ['required'], 'a whitespace-only prompt remains invalid');
console.log('[OK] prompt editor preserves raw prompt whitespace');
