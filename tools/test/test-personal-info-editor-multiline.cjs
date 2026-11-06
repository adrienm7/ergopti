// tools/test/test-personal-info-editor-multiline.cjs
// Pins the page-to-host boundary using DOM line-ending semantics.
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

class Element {
	constructor(tag) {
		this.tagName = tag.toUpperCase();
		this.children = [];
		this.attrs = {};
		this.listeners = {};
		this._value = '';
	}
	set value(text) {
		this._value =
			this.tagName === 'INPUT'
				? String(text).replace(/[\r\n]/g, '')
				: String(text).replace(/\r\n?/g, '\n');
	}
	get value() {
		return this._value;
	}
	set innerHTML(value) {
		if (value === '') this.children = [];
	}
	setAttribute(name, value) {
		this.attrs[name] = value;
	}
	getAttribute(name) {
		return this.attrs[name];
	}
	appendChild(child) {
		this.children.push(child);
		return child;
	}
	addEventListener(name, callback) {
		this.listeners[name] = callback;
	}
	focus() {}
}
const elements = {
	rows: new Element('div'),
	'btn-save': new Element('button'),
	'btn-cancel': new Element('button')
};
const posted = [];
const context = {
	window: {},
	makeHostBridge: () => (message) => posted.push(message),
	document: {
		getElementById: (id) => elements[id],
		createElement: (tag) => new Element(tag),
		querySelectorAll: (selector) =>
			selector.startsWith('#rows ') ? elements.rows.children.map((row) => row.children[1]) : [],
		querySelector: () => elements.rows.children[0]?.children[1] || null,
		addEventListener: () => {}
	}
};
vm.createContext(context);
const script = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/ui/personal_info_editor/script.js'
);
vm.runInContext(fs.readFileSync(script, 'utf8'), context);
const original = 'first\r\nsecond\rthird\nfourth';
context.window.initData({
	fields: [
		{ key: 'address', label: 'address', value: original },
		{ key: 'city', label: 'city', value: 'Puteaux' }
	]
});
const address = elements.rows.children[0].children[1];
const city = elements.rows.children[1].children[1];
assert.equal(address.tagName, 'TEXTAREA');
assert.equal(city.tagName, 'TEXTAREA');
city.value = 'Paris';
elements['btn-save'].listeners.click();
assert.equal(posted.at(-1).values.address, original);
assert.equal(posted.at(-1).values.city, 'Paris');
address.value = 'changed\naddress';
elements['btn-save'].listeners.click();
assert.equal(posted.at(-1).values.address, 'changed\naddress');
address.value = 'first\nsecond\nthird\nfourth';
elements['btn-save'].listeners.click();
assert.equal(posted.at(-1).values.address, original);
city.value = 'Paris\nÎle-de-France';
elements['btn-save'].listeners.click();
assert.equal(posted.at(-1).values.city, 'Paris\nÎle-de-France');
// A late second initialization must not discard edits in this document.
context.window.initData({ fields: [{ key: 'city', label: 'city', value: 'Puteaux' }] });
assert.equal(city.value, 'Paris\nÎle-de-France');
assert.equal(elements.rows.children.length, 2);
// A navigation creates a fresh JavaScript realm and accepts its own initial data.
elements.rows.innerHTML = '';
const fresh = { ...context, window: {} };
vm.runInNewContext(fs.readFileSync(script, 'utf8'), fresh);
fresh.window.initData({ fields: [{ key: '__proto__', label: 'custom', value: 'before' }] });
elements.rows.children[0].children[1].value = 'after';
elements['btn-save'].listeners.click();
assert.equal(Object.getPrototypeOf(posted.at(-1).values), null);
assert.equal(posted.at(-1).values.__proto__, 'after');
console.log('personal-info editor preserves unchanged multiline values');
