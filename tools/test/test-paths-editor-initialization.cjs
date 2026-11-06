// tools/test/test-paths-editor-initialization.cjs

/**
 * ==============================================================================
 * MODULE: Paths Editor Initialization
 * DESCRIPTION:
 * Replays the actual page and host bridge over the DOM fields from its HTML.
 * A delayed navigation initialization must not replace typed or browsed folders.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../..');
const ui = path.join(root, 'static/ergopti_plus/_shared/ui');
const html = fs.readFileSync(path.join(ui, 'paths_editor/index.html'), 'utf8');
const bridge = fs.readFileSync(path.join(ui, 'host_bridge.js'), 'utf8');
const script = fs.readFileSync(path.join(ui, 'paths_editor/script.js'), 'utf8');
const initial = {
	configDir: '/original/config/',
	defaultConfigDir: '/default/config/',
	logsDir: '/original/logs/',
	defaultLogsDir: '/default/logs/',
	strings: { 'paths_editor.tag_default': 'Default', 'paths_editor.tag_modified': 'Modified' }
};

function page(channel) {
	const nodes = new Map();
	for (const match of html.matchAll(/\bid="([^"]+)"/g)) {
		const listeners = new Map();
		const classes = new Set();
		nodes.set(match[1], {
			value: '',
			textContent: '',
			classList: {
				toggle(name, active) {
					if (active) classes.add(name);
					else classes.delete(name);
				}
			},
			addEventListener(name, callback) {
				listeners.set(name, callback);
			},
			dispatch(name) {
				assert(listeners.has(name), 'the page must bind ' + name);
				listeners.get(name)({ target: this });
			}
		});
	}
	assert(nodes.size >= 10, 'load the actual paths editor DOM');
	const posted = [];
	const receive = (value) => posted.push(typeof value === 'string' ? JSON.parse(value) : value);
	const window =
		channel === 'webkit'
			? { webkit: { messageHandlers: { hsPaths: { postMessage: receive } } } }
			: { chrome: { webview: { postMessage: receive } } };
	const context = vm.createContext({
		window,
		console,
		document: { getElementById: (id) => nodes.get(id), querySelectorAll: () => [] },
		setTimeout: (callback) => callback()
	});
	vm.runInContext(bridge, context);
	vm.runInContext(script, context);
	assert.equal(posted[0].action, 'ready');
	return { window, nodes, posted };
}

for (const channel of ['webkit', 'webview2']) {
	const p = page(channel);
	p.window.initData(initial);
	const config = p.nodes.get('input-config-dir');
	config.value = '/typed/config/';
	config.dispatch('input');
	p.window.applyBrowseResult('/picked/logs/', 'logs');
	p.window.initData({ ...initial, defaultConfigDir: '/late/default/' });
	assert.equal(
		config.value,
		'/typed/config/',
		'duplicate init preserves typed configuration folder'
	);
	assert.equal(
		p.nodes.get('input-logs-dir').value,
		'/picked/logs/',
		'duplicate init preserves browsed logs folder'
	);
	p.nodes.get('btn-save').dispatch('click');
	assert.deepEqual(JSON.parse(JSON.stringify(p.posted.at(-1))), {
		action: 'save',
		configDir: '/typed/config/',
		logsDir: '/picked/logs/'
	});
	p.nodes.get('btn-reset').dispatch('click');
	assert.equal(
		config.value,
		initial.defaultConfigDir,
		'Reset keeps the original document defaults'
	);
	assert.equal(p.nodes.get('input-logs-dir').value, initial.defaultLogsDir);
	const reopened = page(channel);
	reopened.window.initData({ ...initial, configDir: '/reopened/config/' });
	assert.equal(
		reopened.nodes.get('input-config-dir').value,
		'/reopened/config/',
		'a new document initializes normally'
	);
}
console.log(
	'PASS paths editor keeps typed and browsed drafts across duplicate initialization on both host bridges'
);
