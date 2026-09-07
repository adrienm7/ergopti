// tools/test/test-model-browser-session.cjs

/**
 * ==============================================================================
 * MODULE: Model Browser Operation Bridge Regression
 * DESCRIPTION:
 * Executes both native bridge adapters and replays old page actions into Lua.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const shared = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const messages = [];
const context = vm.createContext({
	console,
	window: { webkit: { messageHandlers: { model_browser_bridge: {
		postMessage: message => messages.push(JSON.parse(JSON.stringify(message)))
	} } } },
	document: {
		readyState: 'complete',
		getElementById() { return null; },
		querySelectorAll() { return []; },
		addEventListener() {},
		createElement() { return {}; }
	}
});
vm.runInContext(fs.readFileSync(path.join(shared, 'host_bridge.js'), 'utf8'), context);
vm.runInContext(fs.readFileSync(path.join(shared, 'model_browser/script.js'), 'utf8'), context);
assert.deepEqual(messages.splice(0), ['ready']);

function inject(session) {
	const payload = { models: [], backend: 'mlx' };
	if (arguments.length) payload.session = session;
	context.injectModels(payload);
}

function actions() {
	context.selectRow('model-A');
	context.useSelected();
	const row = context.buildRow({ name: 'model-A', url: 'https://huggingface.co/model-A' });
	row.onclick({
		target: { closest: () => ({ getAttribute: () => 'https://huggingface.co/model-A' }) },
		stopPropagation() {}
	});
	return messages.splice(0);
}

const legacy = [
	{ action: 'select_model', name: 'model-A' },
	{ action: 'open_url', url: 'https://huggingface.co/model-A' }
];
inject(1);
const oldRow = context.buildRow({ name: 'model-A', url: 'https://huggingface.co/model-A' });
const oldMessages = actions();
assert.deepEqual(oldMessages, legacy.map(action => ({ ...action, session: 1 })));
inject(2);
oldRow.onclick({ target: {}, stopPropagation() {} });
context.useSelected();
oldRow.ondblclick();
oldRow.onclick({
	target: { closest: () => ({ getAttribute: () => 'https://huggingface.co/model-A' }) },
	stopPropagation() {}
});
assert.deepEqual(messages.splice(0), [], 'retired DOM row callbacks must not acquire the successor session');
assert.deepEqual(actions(), legacy.map(action => ({ ...action, session: 2 })));
assert.equal(oldMessages[0].session, 1);
for (const invalid of [null, undefined, 0, -1, 1.5, NaN, Infinity, '2', {}, 9007199254740992]) {
	assert.throws(() => inject(invalid), /session/);
	assert.deepEqual(actions(), legacy.map(action => ({ ...action, session: 2 })),
		'invalid injection must not replace the current operation identity');
}

const luaBodies = oldMessages.map(message => '{ ' + Object.entries(message)
	.map(([key, value]) => `${key} = ${JSON.stringify(value)}`).join(', ') + ' }').join(',');
const lua = spawnSync('lua', ['-'], {
	cwd: path.resolve(__dirname, '../../static/ergopti_plus/macos'),
	encoding: 'utf8',
	input: `
package.path = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;' .. package.path
local helpers = require('tests.helpers')
local bridge, created, calls, opened = nil, 0, 0, 0
local payloads = {}
package.loaded['infra.deferred_work'] = { after = function() return true end }
package.loaded['ui.ui_builder'] = {
	get_app_geometry = function() return { width = 880, height = 560 } end,
	get_centered_frame = function() return {} end,
	build_injected_html = function() return '' end,
	force_focus = function() end,
	open_http_url = function() opened = opened + 1; return true end,
	show_webview = function(opts)
		created = created + 1
		local native = {}
		function native:evaluateJavaScript() return self end
		function native:delete() return self end
		opts.on_webview_created(native)
		return native
	end,
}
local browser = helpers.load_with_stubs('ui.model_browser', {
	webview = { usercontent = { new = function()
		return { setCallback = function(_, callback) bridge = callback end }
	end } },
	json = { encode = function(payload)
		payloads[#payloads + 1] = payload
		return '{}'
	end },
})
assert(browser.open({ presets = {}, active_backend = 'mlx' }))
bridge({ body = 'ready' })
assert(browser.open({ presets = {}, active_backend = 'ollama', on_select = function()
	calls = calls + 1
	return false
end }))
assert(created == 1)
assert(payloads[1].session == 1 and payloads[2].session == 2)
for _, body in ipairs({ ${luaBodies} }) do bridge({ body = body }) end
assert(calls == 0 and opened == 0, 'old frontend actions reached the successor operation')
bridge({ body = { action = 'select_model', name = 'current', session = 2 } })
bridge({ body = { action = 'open_url', url = 'https://huggingface.co/current', session = 2 } })
assert(calls == 1 and opened == 1, 'current operation must remain actionable')
`
});
assert.ifError(lua.error);
assert.equal(lua.status, 0, lua.stdout + lua.stderr);

inject();
assert.deepEqual(actions(), legacy, 'legacy WebKit hosts retain untagged objects');
context.window.chrome = { webview: { postMessage: message => messages.push(message) } };
inject();
assert.deepEqual(actions(), legacy.map(message => JSON.stringify(message)),
	'legacy Windows hosts retain their original JSON strings');
console.log('Model browser session bridge: native reuse, validation and legacy hosts passed.');
