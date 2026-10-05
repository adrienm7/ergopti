// tools/test/test-hotstrings-config-window-fold.cjs

/**
 * ==============================================================================
 * MODULE: Hotstrings Config Window Fold Tests
 * DESCRIPTION:
 * Executes the shipped « Délais et couleurs » page with a small DOM built from
 * its own index.html and checks that a category's sections fold.
 *
 * FEATURES & RATIONALE:
 * 1. The fold is the `hidden` attribute, and the stylesheet gives the sections
 *    `display: flex`: an author `display` beats the browser's own rule for
 *    `hidden`, so a click turned the caret and hid nothing
 *    (hotstrings-config-fold). The stylesheet must restore `display: none`.
 * 2. Every edit makes the host push a fresh state and the page draws again:
 *    a folded category must stay folded across that push.
 * 3. The caret and the title both fold, and the other categories stay open.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const shared = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
const page = path.join(shared, 'ui/hotstrings_config_window');
const html = fs.readFileSync(path.join(page, 'index.html'), 'utf8');
const css = fs.readFileSync(path.join(page, 'style.css'), 'utf8').replace(/\/\*[\s\S]*?\*\//g, '');

const VOID_TAGS = new Set(['input', 'meta', 'link', 'br', 'img', 'hr']);

/** One element of the small DOM: attributes, classes, children and listeners. */
class El {
	constructor(tag, attrs = {}) {
		this.tag = tag;
		this.attrs = { ...attrs };
		this.children = [];
		this.listeners = {};
		this.style = {};
		this.text = '';
		const owner = this;
		this.classList = {
			list: () => (owner.attrs.class || '').split(/\s+/).filter(Boolean),
			contains: (name) => owner.classList.list().includes(name),
			add: (name) => owner.classList.toggle(name, true),
			remove: (name) => owner.classList.toggle(name, false),
			toggle(name, force) {
				const names = owner.classList.list().filter((entry) => entry !== name);
				const on = force === undefined ? names.length === owner.classList.list().length : force;
				if (on) names.push(name);
				owner.attrs.class = names.join(' ');
				return on;
			}
		};
	}
	get hidden() {
		return 'hidden' in this.attrs;
	}
	set hidden(value) {
		if (value) this.attrs.hidden = '';
		else delete this.attrs.hidden;
	}
	get content() {
		return this;
	}
	get textContent() {
		return this.text;
	}
	set textContent(value) {
		this.text = String(value);
		this.children = [];
	}
	set innerHTML(value) {
		assert.equal(value, '', 'the page only empties a container through innerHTML');
		this.children = [];
	}
	setAttribute(name, value) {
		this.attrs[name] = String(value);
	}
	getAttribute(name) {
		return name in this.attrs ? this.attrs[name] : null;
	}
	hasAttribute(name) {
		return name in this.attrs;
	}
	removeAttribute(name) {
		delete this.attrs[name];
	}
	appendChild(child) {
		// A fragment (an imported template) hands over its children, as in a browser.
		if (child.tag === 'template') this.children.push(...child.children.splice(0));
		else this.children.push(child);
		return child;
	}
	addEventListener(name, callback) {
		(this.listeners[name] = this.listeners[name] || []).push(callback);
	}
	click() {
		for (const callback of this.listeners.click || []) callback({ target: this });
	}
	clone() {
		const copy = new El(this.tag, this.attrs);
		copy.text = this.text;
		copy.children = this.children.map((child) => child.clone());
		return copy;
	}
	matches(selector) {
		if (selector.includes(','))
			return selector.split(',').some((part) => this.matches(part.trim()));
		if (selector.startsWith('.')) return this.classList.contains(selector.slice(1));
		const attribute = /^\[([\w-]+)(?:=([\w-]+))?\]$/.exec(selector);
		if (attribute) {
			return (
				attribute[1] in this.attrs &&
				(attribute[2] === undefined || this.attrs[attribute[1]] === attribute[2])
			);
		}
		return this.tag === selector;
	}
	querySelectorAll(selector) {
		const found = [];
		for (const child of this.children) {
			if (child.matches(selector)) found.push(child);
			found.push(...child.querySelectorAll(selector));
		}
		return found;
	}
	querySelector(selector) {
		return this.querySelectorAll(selector)[0] || null;
	}
}

/** Parses the page's markup into the small DOM. */
function parse(source) {
	const root = new El('#document');
	const stack = [root];
	for (const token of source.matchAll(/<!--[\s\S]*?-->|<(\/?)([\w-]+)([^>]*)>|([^<]+)/g)) {
		if (token[4] !== undefined) {
			if (token[4].trim()) stack[stack.length - 1].text += token[4].trim();
			continue;
		}
		if (token[2] === undefined || token[2] === 'doctype') continue;
		if (token[1]) {
			assert.equal(stack.pop().tag, token[2], 'the page markup must be well nested');
			continue;
		}
		const attrs = {};
		for (const attr of token[3].matchAll(/([\w-]+)(?:="([^"]*)")?/g))
			attrs[attr[1]] = attr[2] || '';
		const element = new El(token[2], attrs);
		stack[stack.length - 1].children.push(element);
		if (!VOID_TAGS.has(token[2]) && !token[3].trim().endsWith('/')) stack.push(element);
	}
	assert.equal(stack.length, 1, 'every element of the page must be closed');
	return root;
}

const root = parse(html.replace(/^<!doctype html>/i, ''));
const byId = (id) => root.querySelectorAll('[id]').find((element) => element.attrs.id === id);
const sandbox = {
	document: {
		getElementById: byId,
		createElement: (tag) => new El(tag),
		importNode: (node) => node.clone()
	},
	console,
	webkit: { messageHandlers: { hotstrings_config_bridge: { postMessage: () => {} } } }
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(shared, 'ui/host_bridge.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(page, 'script.js'), 'utf8'), sandbox);

/** The state a host pushes: two categories of one group, each with a section. */
function hostState() {
	const section = { name: 's1', title: 'Section', delay_ms: 0, delay_default_ms: 0 };
	return {
		groups: [{ key: 'common', label: 'Commun' }],
		presets: [],
		global_default_delay_ms: 750,
		categories: ['first', 'second'].map((name) => ({
			name,
			title: name,
			group: 'common',
			sections: [{ ...section }]
		}))
	};
}

/** The drawn cards, in order. */
function cards() {
	return byId('content').querySelectorAll('.cat');
}

// 1/ The stylesheet lets the `hidden` attribute hide an element it displays.
const sectionsDisplay = /\.sections\s*\{[^}]*display:\s*([a-z-]+)/.exec(css);
assert.ok(sectionsDisplay, 'the sections box is laid out by the stylesheet');
assert.match(
	css,
	/(^|[\s,}])\[hidden\]\s*\{[^}]*display:\s*none\s*!important/,
	`.sections is "display: ${sectionsDisplay[1]}", which beats the browser's rule for the hidden ` +
		'attribute: the stylesheet must hide [hidden] itself, or folding hides nothing'
);

// 2/ Categories open unfolded, and the caret folds only its own category.
sandbox.setData(hostState());
assert.equal(cards().length, 2, 'both categories of the active group are drawn');
for (const card of cards()) {
	assert.equal(card.querySelector('.sections').hidden, false, 'a category opens unfolded');
	assert.equal(card.querySelector('.sections').children.length, 1, 'its sections are drawn');
	assert.equal(card.querySelector('[data-role=toggle]').getAttribute('aria-expanded'), 'true');
}
cards()[0].querySelector('[data-role=toggle]').click();
assert.equal(cards()[0].querySelector('.sections').hidden, true, 'a click on the caret folds');
assert.equal(
	cards()[0].querySelector('[data-role=toggle]').getAttribute('aria-expanded'),
	'false',
	'the caret says the category is folded'
);
assert.equal(
	cards()[0].querySelector('[data-role=toggle]').classList.contains('open'),
	false,
	'the caret turns back'
);
assert.equal(cards()[1].querySelector('.sections').hidden, false, 'the other category stays open');

// 3/ The fold survives the state the host pushes after every edit.
sandbox.setData(hostState());
assert.equal(cards()[0].querySelector('.sections').hidden, true, 'the fold outlives a redraw');
assert.equal(cards()[1].querySelector('.sections').hidden, false);

// 4/ The title folds and unfolds too.
cards()[0].querySelector('.cat-title').click();
assert.equal(cards()[0].querySelector('.sections').hidden, false, 'a click on the title unfolds');
cards()[1].querySelector('.cat-title').click();
assert.equal(cards()[1].querySelector('.sections').hidden, true, 'a click on the title folds');

// 5/ A refused personal owner exposes its data without offering mutations.
// A later admitted state rebuild restores ordinary editability.
const ownedState = hostState();
ownedState.categories[0].readonly = true;
sandbox.setData(ownedState);
const controls = (card) => card.querySelectorAll('input, select, button');
assert.ok(controls(cards()[0]).length > 0, 'actual template controls are exercised');
assert.ok(
	controls(cards()[0]).every((control) => control.disabled === true),
	'readonly disables file and section controls'
);
assert.ok(
	controls(cards()[1]).some((control) => control.disabled !== true),
	'a sibling remains editable'
);
sandbox.setData(hostState());
assert.ok(
	controls(cards()[0]).some((control) => control.disabled !== true),
	'an admitted replacement restores editability'
);

// 6/ An ambiguous source field disables only that control; other source controls
// and sections stay editable, and a fresh authoritative state clears the flag.
const fieldState = hostState();
fieldState.categories[0].readonly_metadata = { delay: true };
fieldState.categories[0].readonly_metadata_reason = 'Edit this field in the source file.';
fieldState.categories[0].sections[0].readonly_metadata = { color: true };
fieldState.categories[0].sections[0].readonly_metadata_reason =
	'Edit this section field in the source file.';
sandbox.setData(fieldState);
const fileFields = cards()[0];
const sectionFields = fileFields.querySelector('.sections').children[0];
assert.ok(
	controls(fileFields.querySelector('.field-delay')).every((control) => control.disabled === true)
);
assert.equal(
	fileFields.querySelector('.field-delay').title,
	fieldState.categories[0].readonly_metadata_reason
);
assert.ok(
	controls(fileFields.querySelector('.field-color')).some((control) => control.disabled !== true)
);
assert.ok(
	controls(sectionFields.querySelector('.field-color')).every(
		(control) => control.disabled === true
	)
);
assert.equal(
	sectionFields.querySelector('.field-color').title,
	fieldState.categories[0].sections[0].readonly_metadata_reason
);
assert.ok(
	controls(sectionFields.querySelector('.field-delay')).some((control) => control.disabled !== true)
);
assert.ok(controls(cards()[1]).some((control) => control.disabled !== true));
sandbox.setData(hostState());
assert.ok(
	controls(cards()[0].querySelector('.field-delay')).some((control) => control.disabled !== true)
);

console.log(
	'[OK] hotstrings config window: sections fold from the caret and the title, stay folded across a host push, and [hidden] is honoured.'
);
