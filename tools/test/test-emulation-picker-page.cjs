// tools/test/test-emulation-picker-page.cjs

/**
 * ==============================================================================
 * MODULE: Emulation Picker Page Tests
 * DESCRIPTION:
 * Executes the shipped « Layout to emulate › Others… » page
 * (_shared/ui/emulation_picker) with a small DOM and the real host bridge, as
 * the three hosts load it (maintainer decision of 2026-11-25): the search
 * ignores case and accents, the arrows and Enter choose from the field, a
 * click chooses a row, Escape clears the search and then cancels, a choice is
 * sent once with its session, a stale host message is refused and a refusal
 * re-enables the choice. Every string the page names exists in the 21 locales.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const shared = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
const page = path.join(shared, 'ui/emulation_picker');
const html = fs.readFileSync(path.join(page, 'index.html'), 'utf8');
const LOCALES = path.join(shared, 'core/i18n/data/locales');
const strings = JSON.parse(fs.readFileSync(path.join(LOCALES, 'en.json'), 'utf8'));

/** A minimal element: text, attributes, children, listeners and focus. */
function element(tag) {
	const node = {
		tag,
		id: '',
		className: '',
		dataset: {},
		attributes: {},
		children: [],
		listeners: {},
		disabled: false,
		dir: '',
		text: '',
		value: '',
		set textContent(value) {
			this.text = String(value);
			this.children = [];
		},
		get textContent() {
			return this.text + this.children.map((child) => child.textContent).join('');
		},
		setAttribute(name, value) {
			this.attributes[name] = String(value);
		},
		getAttribute(name) {
			return name in this.attributes ? this.attributes[name] : null;
		},
		removeAttribute(name) {
			delete this.attributes[name];
		},
		appendChild(child) {
			child.parent = this;
			this.children.push(child);
		},
		addEventListener(name, callback) {
			(this.listeners[name] = this.listeners[name] || []).push(callback);
		},
		focus() {
			sandbox.document.activeElement = this;
		},
		closest(selector) {
			for (let at = this; at; at = at.parent)
				if (selector === 'li[role="option"]' && at.attributes.role === 'option') return at;
			return null;
		}
	};
	return node;
}

const elements = {};
for (const match of html.matchAll(/<(\w+)[^>]*\bid="([^"]+)"[^>]*>/g)) {
	elements[match[2]] = element(match[1]);
	elements[match[2]].id = match[2];
	elements[match[2]].disabled = /\bdisabled\b/.test(match[0]);
}
const main = element('main');
elements.choices.parent = main;
const documentListeners = {};
const messages = [];
const sandbox = {
	document: {
		getElementById: (id) => elements[id],
		createElement: element,
		querySelector: (selector) => (selector === 'main' ? main : null),
		readyState: 'complete',
		querySelectorAll: () => [],
		documentElement: {},
		addEventListener(name, callback) {
			(documentListeners[name] = documentListeners[name] || []).push(callback);
		}
	},
	console,
	TextDecoder,
	atob: (value) => Buffer.from(value, 'base64').toString('binary'),
	_i18n_strings: strings,
	__i18n_base: 'https://preview/data/locales/',
	_i18n_locale: 'en',
	fetch: () => Promise.resolve({ ok: true, json: () => Promise.resolve(strings) }),
	webkit: {
		messageHandlers: {
			emulation_picker_bridge: { postMessage: (message) => messages.push(message) }
		}
	}
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(shared, 'ui/host_bridge.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(shared, 'ui/page_locale.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(shared, 'ui/i18n.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(page, 'script.js'), 'utf8'), sandbox);

/** Fires one listener set of an element. */
function fire(node, name, event = {}) {
	for (const callback of node.listeners[name] || [])
		callback({ preventDefault() {}, currentTarget: node, ...event });
}
/** Presses a key in the search field. */
function key(name, target = elements.search) {
	fire(target, 'keydown', { key: name });
}
/** Presses Escape anywhere on the page. */
function escape() {
	for (const callback of documentListeners.keydown || [])
		callback({ key: 'Escape', preventDefault() {} });
}
/** Types a query into the search field. */
function type(text) {
	elements.search.value = text;
	fire(elements.search, 'input');
}
/** A message the page posted, as plain data (it was built in the page's realm). */
const sent = (index) => JSON.parse(JSON.stringify(messages[index]));
const rows = () => elements.choices.children;
const activeLabel = () =>
	rows().find((row) => row.attributes['aria-selected'] === 'true').children[0].text;

assert.deepEqual(messages, ['ready'], 'the page asks for its choices once loaded');
assert.equal(
	elements['btn-choose'].disabled,
	true,
	'nothing can be chosen before the choices arrive'
);

const SESSION = 'emulation-picker-1';
sandbox.receiveEmulationPicker({
	session: SESSION,
	choices: [
		{ id: 'ergopti', label: 'Ergopti', current: false },
		{ id: 'ergopti_plus', label: 'Ergopti+', current: true },
		{ id: 'bepo', label: 'BÉPO', current: false },
		{ id: 'ergol', label: 'Ergo-L', current: false }
	]
});
assert.equal(rows().length, 4, 'every offered layout is listed');
assert.equal(activeLabel(), 'Ergopti+', 'the layout in force starts active');
assert.equal(
	rows()[1].children[1].text,
	strings['emulation_picker.current'],
	'and says it is in use'
);
assert.equal(elements.search.attributes['aria-activedescendant'], 'choice-1', 'the field names it');
assert.equal(
	sandbox.document.activeElement,
	elements.search,
	'the search field takes the keyboard'
);
assert.equal(elements['btn-choose'].disabled, false);

// The search ignores case and accents and reads the id too.
type('bepo');
assert.deepEqual(
	rows().map((row) => row.children[0].text),
	['BÉPO'],
	'« bepo » finds « BÉPO »'
);
type('ERGO');
assert.equal(rows().length, 3, 'a search matches every name holding it');
type('dvorak');
assert.equal(rows().length, 0);
assert.equal(elements.status.text, strings['emulation_picker.no_match'], 'an empty search says so');
assert.equal(elements['btn-choose'].disabled, true, 'nothing to choose');
assert.equal(elements.search.attributes['aria-activedescendant'], undefined);

// Escape clears the search first, without closing.
escape();
assert.equal(elements.search.value, '');
assert.equal(rows().length, 4, 'the whole list is back');
assert.deepEqual(messages, ['ready'], 'clearing the search sends nothing');

// The arrows move the active choice and wrap, from the field and the list.
assert.equal(activeLabel(), 'Ergopti', 'a cleared search starts at the top');
key('ArrowDown');
assert.equal(activeLabel(), 'Ergopti+');
key('ArrowUp');
key('ArrowUp');
assert.equal(activeLabel(), 'Ergo-L', 'up from the first wraps to the last');
key('ArrowDown', elements.choices);
assert.equal(activeLabel(), 'Ergopti', 'the list answers the same keys, down from the last wraps');
key('End', elements.choices);
assert.equal(activeLabel(), 'Ergo-L');
key('Home', elements.search);
assert.equal(activeLabel(), 'Ergo-L', 'Home stays the caret key in the search field');

// Enter sends the active choice once, with the session it came with.
key('ArrowUp');
key('Enter');
assert.deepEqual(sent(1), { action: 'choose', session: SESSION, id: 'bepo' });
key('Enter');
fire(elements['btn-choose'], 'click');
assert.equal(messages.length, 2, 'a choice in flight is not sent twice');

// A stale host refusal is ignored; this host's refusal re-enables the choice.
sandbox.receiveEmulationPicker({ session: 'other', choices: [], refused: true });
assert.equal(elements['btn-choose'].disabled, true, 'a message of another session changes nothing');
sandbox.receiveEmulationPicker({
	session: SESSION,
	refused: true,
	choices: [
		{ id: 'bepo', label: 'BÉPO', current: false },
		{ id: 'ergol', label: 'Ergo-L', current: true }
	]
});
assert.equal(elements.status.text, strings['menu.layout.emulation_not_saved'], 'a refusal says so');
assert.equal(elements['btn-choose'].disabled, false, 'and the choice can be made again');

// A click on a row chooses it.
fire(main, 'click', { target: rows()[1].children[0] });
assert.deepEqual(sent(2), { action: 'choose', session: SESSION, id: 'ergol' });

// Escape with an empty search cancels, as Cancel does.
sandbox.receiveEmulationPicker({ session: SESSION, choices: [{ id: 'bepo', label: 'BÉPO' }] });
escape();
assert.deepEqual(sent(3), { action: 'cancel', session: SESSION });
fire(elements['btn-cancel'], 'click');
assert.deepEqual(sent(4), { action: 'cancel', session: SESSION });

// Every key the page names exists in every locale.
const keys = new Set([
	...Array.from(html.matchAll(/data-i18n(?:-placeholder)?="([^"]+)"/g), (match) => match[1]),
	...Array.from(
		fs.readFileSync(path.join(page, 'script.js'), 'utf8').matchAll(/\bt\('([^']+)'\)/g),
		(match) => match[1]
	)
]);
assert.ok(keys.size >= 7, 'the page names its strings');
for (const file of fs.readdirSync(LOCALES).filter((name) => name.endsWith('.json'))) {
	const locale = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	for (const name of keys)
		assert.ok(typeof locale[name] === 'string' && locale[name] !== '', `${file} has no ${name}`);
}

console.log('PASS emulation picker page (search, keyboard, choice, refusal, 21 locales)');
