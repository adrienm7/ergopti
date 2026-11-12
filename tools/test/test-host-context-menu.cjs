// tools/test/test-host-context-menu.cjs

/**
 * ==============================================================================
 * MODULE: Host Pages Keep The Native Context Menu Closed
 * DESCRIPTION:
 * Windows turns WebView2's default context menu off for every page window;
 * WKWebView (macOS) and WebKitGTK (Linux) offered Reload, Back and Forward,
 * and a reload drops an unsaved draft (WVH-003). _shared/ui/host_bridge.js,
 * which every host page loads, now keeps the menu closed outside a text field.
 * This gate runs the real script against a recording document.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const ui = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const listeners = {};
const document = {
	addEventListener(type, listener, capture) {
		listeners[type] = { listener, capture };
	}
};
const context = vm.createContext({ document, window: {}, console });
vm.runInContext(fs.readFileSync(path.join(ui, 'host_bridge.js'), 'utf8'), context);

const menu = listeners.contextmenu;
assert.ok(menu, 'host_bridge.js listens to contextmenu');
assert.equal(menu.capture, true, 'it listens in the capture phase, before any page handler');

/** Fires a contextmenu on a target matching `selector` (or none). */
function fire(selector) {
	let prevented = false;
	const target = { closest: (query) => (selector && query.includes(selector) ? {} : null) };
	menu.listener({ target, preventDefault: () => (prevented = true) });
	return prevented;
}

assert.equal(fire(null), true, 'the page background keeps the menu closed');
for (const field of ['input', 'textarea', '[contenteditable="true"]']) {
	assert.equal(fire(field), false, `a ${field} keeps its editing menu`);
}
let prevented = false;
menu.listener({ target: null, preventDefault: () => (prevented = true) });
assert.equal(prevented, true, 'a target-less event keeps the menu closed');

const pages = fs
	.readdirSync(ui, { withFileTypes: true })
	.filter((entry) => entry.isDirectory() && fs.existsSync(path.join(ui, entry.name, 'index.html')))
	.map((entry) => entry.name)
	// The website's standalone layout editor runs in a browser, not in a host window.
	.filter((name) => name !== 'layout_editor');
for (const name of pages) {
	assert.match(
		fs.readFileSync(path.join(ui, name, 'index.html'), 'utf8'),
		/host_bridge\.js/,
		`${name} loads host_bridge.js`
	);
}
console.log(
	`\x1b[32m[OK] the native context menu stays closed outside text fields on ${pages.length} host pages.\x1b[0m`
);
