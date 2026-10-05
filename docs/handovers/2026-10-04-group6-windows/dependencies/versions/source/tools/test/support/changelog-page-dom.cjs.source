// tools/test/support/changelog-page-dom.cjs

/**
 * ==============================================================================
 * MODULE: Changelog Page Recording DOM
 * DESCRIPTION:
 * Runs a shared page that renders release notes (the changelog window by
 * default, or the update prompt's release_notes pane) in a VM against a
 * recording DOM, exactly as its index.html loads it, for the page tests that
 * inspect what remote release notes become.
 *
 * FEATURES & RATIONALE:
 * 1. Real page chain: scripts are read from index.html, so a module written
 *    but never loaded by the document fails the tests that use this harness.
 * 2. No HTML parser: the recording DOM throws on innerHTML/outerHTML and
 *    insertAdjacentHTML, so remote text can only reach the page as text nodes.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const SHARED_UI = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'ui');

// Scripts the recording sandbox replaces with stubs: they talk to the native
// host or fetch locale files, neither of which the page tests exercise.
const STUBBED_SCRIPTS = new Set(['host_bridge.js', 'i18n.js']);

// ==========================================
// ==========================================
// ======= 1/ Recording DOM ================
// ==========================================
// ==========================================

class FakeNode {
	constructor(tagName, nodeType) {
		this.tagName = tagName;
		this.nodeType = nodeType;
		this.children = [];
		this.attributes = {};
		this.listeners = {};
		this.style = {};
		this.className = '';
		this.id = '';
		this._text = '';
		const node = this;
		this.classList = {
			toggle(name, force) {
				const set = new Set(node.className.split(/\s+/).filter(Boolean));
				if (force === undefined ? !set.has(name) : force) set.add(name);
				else set.delete(name);
				node.className = Array.from(set).join(' ');
			},
			add(name) {
				this.toggle(name, true);
			}
		};
	}

	get textContent() {
		if (this.nodeType === 3) return this._text;
		return this.children.map((child) => child.textContent).join('');
	}

	set textContent(value) {
		if (this.nodeType === 3) {
			this._text = String(value);
			return;
		}
		this.children = [];
		if (value !== '') this.children.push(makeText(String(value)));
	}

	set innerHTML(_value) {
		throw new Error('innerHTML is forbidden for remote release notes');
	}

	set outerHTML(_value) {
		throw new Error('outerHTML is forbidden for remote release notes');
	}

	insertAdjacentHTML() {
		throw new Error('insertAdjacentHTML is forbidden for remote release notes');
	}

	appendChild(child) {
		this.children.push(child);
		return child;
	}

	replaceChildren(...children) {
		this.children = children;
	}

	setAttribute(name, value) {
		this.attributes[name] = String(value);
	}

	getAttribute(name) {
		return Object.prototype.hasOwnProperty.call(this.attributes, name)
			? this.attributes[name]
			: null;
	}

	addEventListener(type, handler) {
		(this.listeners[type] = this.listeners[type] || []).push(handler);
	}

	dispatch(type, event) {
		(this.listeners[type] || []).forEach((handler) => handler(event));
	}
}

function makeText(value) {
	const node = new FakeNode('#text', 3);
	node._text = value;
	return node;
}

/** Depth-first list of every element below (and including) a node. */
function elements(node, acc = []) {
	if (node.nodeType === 1) acc.push(node);
	node.children.forEach((child) => elements(child, acc));
	return acc;
}

/** Depth-first list of every text node below a node. */
function textNodes(node, acc = []) {
	if (node.nodeType === 3) acc.push(node);
	node.children.forEach((child) => textNodes(child, acc));
	return acc;
}

function byTag(root, tag) {
	return elements(root).filter((node) => node.tagName === tag);
}

/** Text of a subtree, skipping every element with the given tag. */
function textOutside(node, skippedTag) {
	if (node.nodeType === 3) return node._text;
	if (node.tagName === skippedTag) return '';
	return node.children.map((child) => textOutside(child, skippedTag)).join('');
}

// ==========================================
// ==========================================
// ======= 2/ Page Execution ================
// ==========================================
// ==========================================

/**
 * Returns the local scripts a page's index.html loads, in document order.
 * @param {string} [page] - Shared UI page directory (default: the changelog).
 */
function pageScripts(page = 'changelog') {
	const html = fs.readFileSync(path.join(SHARED_UI, page, 'index.html'), 'utf8');
	const scripts = [];
	const pattern = /<script\s+src="([^"]+)"/g;
	let match;
	while ((match = pattern.exec(html)) !== null) scripts.push(match[1]);
	if (scripts.length === 0) throw new Error('index.html loads no scripts; the scan is broken');
	return scripts;
}

/**
 * Executes a page and returns its sandbox, document and posted messages.
 * @param {Object} [globals] - Extra window globals (e.g. _i18n_strings).
 * @param {string} [page] - Shared UI page directory (default: the changelog).
 */
function runPage(globals = {}, page = 'changelog') {
	const byId = new Map();
	const posted = [];
	const document = {
		readyState: 'complete',
		getElementById(id) {
			if (!byId.has(id)) {
				const node = new FakeNode('div', 1);
				node.id = id;
				byId.set(id, node);
			}
			return byId.get(id);
		},
		querySelectorAll: () => [],
		createElement: (tag) => new FakeNode(String(tag).toLowerCase(), 1),
		createTextNode: (value) => makeText(String(value)),
		addEventListener() {}
	};
	const sandbox = {
		console,
		URL,
		Date,
		document,
		makeHostBridge: (name) => (payload) => posted.push({ name, payload }),
		decodeHostBridgeResponse: (_isBase64, payload) => JSON.parse(payload),
		setTimeout: () => 1,
		clearTimeout() {},
		...globals
	};
	sandbox.window = sandbox;
	vm.createContext(sandbox);
	for (const src of pageScripts(page)) {
		const file = path.resolve(SHARED_UI, page, src);
		if (STUBBED_SCRIPTS.has(path.basename(file))) continue;
		if (!file.startsWith(SHARED_UI + path.sep))
			throw new Error(`page script ${src} escapes the shared UI root`);
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: src });
	}
	return { sandbox, document, posted };
}

module.exports = {
	FakeNode,
	makeText,
	elements,
	textNodes,
	byTag,
	textOutside,
	pageScripts,
	runPage
};
