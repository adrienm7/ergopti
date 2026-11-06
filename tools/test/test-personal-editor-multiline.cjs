// tools/test/test-personal-editor-multiline.cjs

/** Replays personal information through actual page rendering and save handlers. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sent = [];
const nodes = {};
const elements = (selector) =>
	selector === '#rows input, #rows textarea' || selector === '#rows input'
		? nodes.rows.children.map((row) => row.children[1])
		: [];
function element(tag) {
	let value = '';
	return {
		tagName: tag.toUpperCase(),
		children: [],
		attributes: {},
		style: {},
		set value(text) {
			value =
				tag === 'input'
					? String(text).replace(/[\r\n]/g, '')
					: String(text).replace(/\r\n?/g, '\n');
		},
		get value() {
			return value;
		},
		set innerHTML(_) {
			this.children = [];
		},
		appendChild(child) {
			this.children.push(child);
		},
		setAttribute(key, val) {
			this.attributes[key] = val;
		},
		getAttribute(key) {
			return this.attributes[key];
		},
		addEventListener(_, fn) {
			this.click = fn;
		},
		focus() {}
	};
}
for (const id of ['rows', 'btn-save', 'btn-cancel']) nodes[id] = element('div');
const document = {
	getElementById: (id) => nodes[id],
	querySelectorAll: elements,
	querySelector: (s) => elements(s)[0] || null,
	createElement: element,
	addEventListener() {}
};
const context = vm.createContext({
	document,
	makeHostBridge: () => (message) => sent.push(message)
});
context.window = context;
vm.runInContext(
	fs.readFileSync(
		path.join(__dirname, '../../static/ergopti_plus/_shared/ui/personal_info_editor/script.js'),
		'utf8'
	),
	context
);
const original = '45 Rue Principale\r\nBâtiment B';
context.initData({ fields: [{ key: 'street_address', label: 'Address', value: original }] });
nodes['btn-save'].click();
assert.equal(
	sent.pop().values.street_address,
	original,
	'saving an untouched multiline value must preserve it exactly'
);
const editor = nodes.rows.children[0].children[1];
assert.equal(
	editor.tagName,
	'TEXTAREA',
	'multiline values must be editable without dropping lines'
);
editor.value = '45 Rue Principale\nBâtiment C';
nodes['btn-save'].click();
assert.equal(
	sent.pop().values.street_address,
	'45 Rue Principale\nBâtiment C',
	'editing must preserve multiple lines'
);
console.log('personal information multiline values survive editor saves');
