// tools/test/test-download-window-session.cjs

/**
 * ==============================================================================
 * MODULE: Download Window Session Bridge Regression
 * DESCRIPTION:
 * Executes the shared frontend to preserve legacy hosts and fence reused pages.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const source = fs.readFileSync(path.resolve(__dirname,
	'../../static/ergopti_plus/_shared/ui/download_window/script.js'), 'utf8');
const hostBridge = fs.readFileSync(path.resolve(__dirname,
	'../../static/ergopti_plus/_shared/ui/host_bridge.js'), 'utf8');
const elements = new Map();
const messages = [];
const context = vm.createContext({
	console,
	window: { webkit: { messageHandlers: { dl_bridge: {
		postMessage: message => messages.push(JSON.parse(JSON.stringify(message)))
	} } } },
	document: {
		readyState: 'complete',
		body: { classList: { add() {}, remove() {} } },
		getElementById(id) {
			if (!elements.has(id)) elements.set(id, {
				style: {}, classList: { add() {}, remove() {} }
			});
			return elements.get(id);
		}
	}
});
vm.runInContext(hostBridge, context);
vm.runInContext(source, context);
assert.deepEqual(messages.splice(0), ['ready']);

function actions() {
	vm.runInContext("doCancel(); doTerm(); doRetry(); done(false, 'gated', 'gated'); doRetry(); showLog()", context);
	return messages.splice(0);
}

const names = ['cancel', 'terminal', 'retry', 'resolve', 'expand'];
vm.runInContext("setKind('mlx_model', 'A', '', 1)", context);
const oldMessages = actions();
assert.deepEqual(oldMessages, names.map(action => ({ action, session: 1 })),
	'HS-266: every action must retain the operation that emitted it');
vm.runInContext("setKind('mlx_model', 'B', '', 2); done(false, '', '')", context);
assert.deepEqual(actions(), names.map(action => ({ action, session: 2 })));
assert.equal(oldMessages[0].session, 1, 'already posted messages must not acquire the successor session');

for (const invalid of ['null', 'undefined', '0', '-1', '1.5', 'NaN', 'Infinity', "'42'", '{}', '9007199254740992']) {
	assert.throws(() => vm.runInContext(`setKind('mlx_model', 'invalid', '', ${invalid})`, context),
		/session/, `explicit invalid session ${invalid} must fail fast`);
	assert.equal(elements.get('title').textContent, 'B', 'invalid initialization must not mutate the page');
}
vm.runInContext('doTerm()', context);
assert.deepEqual(messages.splice(0), [{ action: 'terminal', session: 2 }]);

// Feed the actual frontend payloads into the real Lua host after native reuse.
const luaMessages = oldMessages.map(({ action, session }) =>
	`{ action = ${JSON.stringify(action)}, session = ${session} }`).join(',');
const lua = spawnSync('lua', ['-'], {
	cwd: path.resolve(__dirname, '../../static/ergopti_plus/macos'),
	encoding: 'utf8',
	input: `
package.path = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;' .. package.path
local helpers = require('tests.helpers')
local bridge, native, navigation
local created, calls = 0, 0
package.loaded['infra.deferred_work'] = { after = function() return true end }
package.loaded['adapters.shell_runner'] = { applescript = function()
	error('a stale terminal action must not launch a process')
end }
package.loaded['ui.ui_builder'] = {
	get_app_geometry = function() return { width = 460, height = 380 } end,
	show_webview = function(opts)
		created = created + 1
		native = { codes = {} }
		function native:evaluateJavaScript(code)
			self.codes[#self.codes + 1] = code
			return self
		end
		function native:delete() end
		function native:frame() error('a stale expand action must not inspect the native frame') end
		opts.on_webview_created(native)
		navigation = opts.on_navigation
		return native
	end,
}
local window = helpers.load_with_stubs('ui.download_window', {
	webview = { usercontent = { new = function()
		return { setCallback = function(_, callback) bridge = callback end }
	end } },
})
assert(window.show({ kind = 'mlx_model', title = 'A', subtitle = 'sub' }))
navigation('didFinishNavigation')
local first_codes = table.concat(native.codes, '\\n')
assert(first_codes:find('setKind("mlx_model","A","sub",1)', 1, true), first_codes)
local function called() calls = calls + 1 end
assert(window.show({ kind = 'mlx_model', title = 'B', subtitle = 'sub',
	on_cancel = called, on_retry = called, on_resolve = called }))
assert(created == 1, 'the operation must reuse the same native window')
local codes = table.concat(native.codes, '\\n')
assert(codes:find('setKind("mlx_model","B","sub",2)', 1, true), codes)
for _, body in ipairs({ ${luaMessages} }) do bridge({ body = body }) end
assert(calls == 0, 'HS-266: old frontend messages reached the successor')
bridge({ body = { action = 'cancel', session = 2 } })
assert(calls == 1, 'the current session must still cancel')
print('Real frontend payloads rejected by reused Lua host; current session accepted.')
`
});
assert.ifError(lua.error);
assert.equal(lua.status, 0, lua.stdout + lua.stderr);

vm.runInContext("setKind('mlx_model', 'legacy', ''); done(false, '', '')", context);
assert.deepEqual(actions(), names, 'three-argument Windows/Linux callers retain string messages');
context.window.chrome = { webview: {
	postMessage: message => messages.push(message)
} };
vm.runInContext("setKind('mlx_model', 'Windows', ''); done(false, '', '')", context);
assert.deepEqual(actions(), names, 'real WebView2 bridge must preserve legacy string messages');
console.log('Download session bridge: tagged actions, stale snapshots, validation and legacy hosts passed.');
