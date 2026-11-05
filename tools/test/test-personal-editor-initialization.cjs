// tools/test/test-personal-editor-initialization.cjs

/** Drives the shared personal-information page through its real host bridge. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const source = fs.readFileSync(
	path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui/personal_info_editor/script.js'),
	'utf8'
);
const messages = [];
const button = () => ({
	disabled: true,
	addEventListener(_, fn) {
		this.click = fn;
	}
});
const save = button();
const cancel = button();
const rows = {
	children: [],
	set innerHTML(_) {
		this.children = [];
	},
	appendChild(row) {
		this.children.push(row);
	}
};
const inputs = () => rows.children.map((row) => row.children[1]);
const document = {
	getElementById: (id) => ({ rows, 'btn-save': save, 'btn-cancel': cancel })[id],
	querySelectorAll: (selector) => (selector === '#rows input, #rows textarea' ? inputs() : []),
	querySelector: () => inputs()[0] || null,
	addEventListener() {},
	createElement: () => ({
		children: [],
		attributes: {},
		appendChild(child) {
			this.children.push(child);
		},
		setAttribute(key, value) {
			this.attributes[key] = value;
		},
		getAttribute(key) {
			return this.attributes[key];
		},
		focus() {}
	})
};
const context = vm.createContext({
	document,
	makeHostBridge: () => (value) => messages.push(value)
});
context.window = context;
vm.runInContext(source, context);
const lua = fs.readFileSync(
	path.resolve(__dirname, '../../static/ergopti_plus/macos/ui/personal_info_editor/init.lua'),
	'utf8'
);
const expression = lua.match(/evaluateJavaScript\("([^"\n]*)" \.\. json \.\. "([^"\n]*)"/);
assert.ok(expression, 'host must submit its initialization expression');
function initialize(data) {
	vm.runInContext(expression[1] + JSON.stringify(data) + expression[2], context);
}
initialize({ fields: [{ key: 'first_name', label: 'Name', value: 'Initial' }] });
inputs()[0].value = 'Unsaved edit';
initialize({ fields: [{ key: 'first_name', label: 'Name', value: 'Initial' }] });
save.click();
assert.equal(messages.length, 1);
assert.equal(
	messages[0].values.first_name,
	'Unsaved edit',
	'late duplicate init must preserve the draft'
);
console.log('personal information form preserves edits across duplicate initialization');
