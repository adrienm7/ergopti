// tools/test/test-config-cleanup-page.cjs

/**
 * MODULE: Configuration Cleanup Page Tests
 * DESCRIPTION:
 * Executes the shipped page with a small DOM and the real host bridge. Covers
 * long lists, literal config values, duplicate clicks and stale host responses.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const shared = path.resolve(__dirname, '../../static/ergopti_plus/_shared');
const page = path.join(shared, 'ui/config_cleanup');
const html = fs.readFileSync(path.join(page, 'index.html'), 'utf8');
const elements = {};

/** Minimal DOM whose text assignment clears children, as the browser does. */
function element() {
	return {
		children: [], listeners: {}, disabled: false, text: '',
		set textContent(value) { this.text = String(value); this.children = []; },
		get textContent() { return this.text; },
		appendChild(child) { this.children.push(child); },
		addEventListener(name, callback) { this.listeners[name] = callback; },
		click() { this.listeners.click(); },
	};
}
for (const match of html.matchAll(/<\w+[^>]*\bid="([^"]+)"[^>]*>/g)) {
	elements[match[1]] = element();
	elements[match[1]].disabled = /\bdisabled\b/.test(match[0]);
}
const messages = [];
const strings = JSON.parse(fs.readFileSync(path.join(shared, 'data/locales/en.json'), 'utf8'));
const sandbox = {
	document: { getElementById: id => elements[id], createElement: element, readyState: 'complete', querySelectorAll: () => [] },
	console, TextDecoder, atob: value => Buffer.from(value, 'base64').toString('binary'),
	_i18n_strings: strings,
	__i18n_base: 'https://preview/data/locales/', _i18n_locale: 'en',
	fetch: () => Promise.resolve({ ok: true, json: () => Promise.resolve(strings) }),
	webkit: { messageHandlers: { config_cleanup_bridge: { postMessage: message => messages.push(message) } } },
};
sandbox.window = sandbox;
vm.createContext(sandbox);
vm.runInContext(fs.readFileSync(path.join(shared, 'ui/host_bridge.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(shared, 'ui/i18n.js'), 'utf8'), sandbox);
vm.runInContext(fs.readFileSync(path.join(page, 'script.js'), 'utf8'), sandbox);
assert.equal(messages[0], 'ready');
assert.equal(elements['btn-clean'].disabled, true);
elements['btn-clean'].click();
assert.equal(messages.length, 1, 'no cleanup before a host-owned scan');
const keys = Array.from({ length: 80 }, (_, i) => ({ section: 'obsolete', key: 'setting_' + i, value: '<img src=x onerror=alert(1)>' }));
const ready = { session: '42', status: 'ready', path: '/config.toml', keys };
sandbox.receiveConfigCleanup(ready);
assert.equal(elements.keys.children.length, 80, 'every setting is rendered beyond the old limit');
assert.equal(elements.keys.children[79].children[1].textContent, keys[79].value, 'config is literal text');
assert.equal(elements['btn-clean'].disabled, false);
elements['btn-clean'].click();
elements['btn-clean'].click();
assert.equal(messages.length, 2, 'double click emits exactly one cleanup');
assert.equal(JSON.stringify(messages[1]), '{"action":"clean","session":"42"}', 'page cannot choose paths or targets');
sandbox.receiveConfigCleanup({ ...ready, session: 'old', status: 'removed', keys: [] });
assert.equal(elements['btn-clean'].disabled, true, 'stale responses cannot unlock actions');
sandbox.receiveConfigCleanup({ ...ready, status: 'changed' });
assert.equal(elements.status.textContent, strings['config_cleanup.changed']);
assert.equal(elements['btn-clean'].disabled, true);
elements['btn-refresh'].click();
assert.equal(messages.at(-1).action, 'refresh');
sandbox.__hostBridgeResponse('config_cleanup_bridge', true, Buffer.from(JSON.stringify(ready)).toString('base64'));
assert.equal(elements['btn-clean'].disabled, false, 'Linux bridge routes to the same renderer');
sandbox.receiveConfigCleanup({ ...ready, status: 'removed', keys: [], removed: 80, backup: '/config.backup.toml' });
assert.equal(elements.keys.children.length, 0);
assert.ok(elements.status.textContent.includes('/config.backup.toml'));
assert.equal(elements['btn-clean'].disabled, true);
elements['btn-close'].click();
assert.equal(messages.at(-1).action, 'close');
const sources = html + fs.readFileSync(path.join(page, 'script.js'), 'utf8');
const localeKeys = new Set([...sources.matchAll(/['"]((?:config_cleanup|dialog\.unused_keys|common|ui_apps)\.[a-z_.]+)['"]/g)].map(match => match[1]));
for (const file of fs.readdirSync(path.join(shared, 'data/locales')).filter(file => file.endsWith('.json'))) {
	const locale = JSON.parse(fs.readFileSync(path.join(shared, 'data/locales', file), 'utf8'));
	for (const key of localeKeys) assert.equal(typeof locale[key], 'string', file + ': ' + key);
}
delete sandbox._i18n_strings;
sandbox.receiveConfigCleanup(ready);
setImmediate(() => {
	assert.equal(elements.count.textContent, '80 unused settings', 'asynchronous locale loading translates dynamic counts');
	console.log('[OK] cleanup page: 80 literal rows, actions, duplicate clicks, stale responses, Linux bridge, async i18n, 21 locales.');
});
