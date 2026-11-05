const fs = require('node:fs');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const [root, out] = process.argv.slice(2);
const fixture = JSON.parse(fs.readFileSync(out + '/probes/editor-fixture.json', 'utf8'));
const messages = [];
let assertions = 0;
class Element {
	constructor(tag) {
		this.tagName = tag.toUpperCase();
		this.children = [];
		this.attrs = {};
		this.listeners = {};
		this.value = '';
		this.textContent = '';
	}
	setAttribute(k, v) {
		this.attrs[k] = v;
	}
	getAttribute(k) {
		return this.attrs[k];
	}
	appendChild(x) {
		this.children.push(x);
	}
	addEventListener(k, f) {
		this.listeners[k] = f;
	}
	focus() {
		this.focused = true;
	}
	set innerHTML(x) {
		assert.equal(x, '');
		this.children = [];
	}
}
const rows = new Element('div'),
	save = new Element('button'),
	cancel = new Element('button');
const handlers = {};
const inputs = () => rows.children.flatMap((r) => r.children.filter((x) => x.tagName === 'INPUT'));
const doc = {
	getElementById(id) {
		return { rows, 'btn-save': save, 'btn-cancel': cancel }[id];
	},
	querySelectorAll(selector) {
		return selector === '#rows input' ? inputs() : [];
	},
	querySelector(selector) {
		return selector === '#rows input' ? inputs()[0] : null;
	},
	createElement(tag) {
		return new Element(tag);
	},
	addEventListener(k, f) {
		handlers[k] = f;
	}
};
const ctx = {
	document: doc,
	window: {},
	makeHostBridge(name) {
		assert.equal(name, 'hsPersonalInfo');
		return (x) => messages.push(JSON.parse(JSON.stringify(x)));
	}
};
vm.createContext(ctx);
vm.runInContext(
	fs.readFileSync(root + '/static/ergopti_plus/_shared/ui/personal_info_editor/script.js', 'utf8'),
	ctx,
	{ filename: 'actual-personal-info-editor-script.js' }
);
ctx.window.initData(fixture);
assert.equal(inputs().length, 15);
assertions++;
assert.equal(inputs()[0].focused, true);
assertions++;
for (let i = 0; i < 15; i++) {
	assert.equal(inputs()[i].getAttribute('name'), fixture.fields[i].key);
	assert.equal(inputs()[i].value, fixture.fields[i].value);
	assertions += 2;
}
inputs()[1].value = 'EDITED_🙂\n<literal>';
save.listeners.click();
const actual = messages.at(-1);
assert.equal(actual.action, 'save');
assertions++;
assert.equal(Object.keys(actual.values).length, 15);
assertions++;
assert.equal(actual.values[fixture.fields[1].key], 'EDITED_🙂\n<literal>');
assertions++;
cancel.listeners.click();
assert.equal(messages.at(-1).action, 'cancel');
assertions++;
handlers.keydown({ key: 'Escape' });
assert.equal(messages.at(-1).action, 'cancel');
assertions++;
const before = messages.length;
handlers.keydown({ key: 'x' });
assert.equal(messages.length, before);
assertions++;
handlers.DOMContentLoaded();
assert.equal(messages.at(-1).action, 'ready');
assertions++;
console.log(
	'ACTUAL_SHARED_FRONTEND canonical_fields=15 save_values=15 Unicode/multiline/empty values retained; save/cancel/Escape/ready messages verified; assertions=' +
		assertions +
		'; minimal DOM/bridge ports only, no native rendering or save acknowledgment claimed'
);
