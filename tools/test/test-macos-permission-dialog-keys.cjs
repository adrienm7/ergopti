// tools/test/test-macos-permission-dialog-keys.cjs

/**
 * ==============================================================================
 * MODULE: macOS Permission Dialog Keys Guard
 * DESCRIPTION:
 * Replays the keyboard on the page script of macos/ui/permission_dialog in a
 * small DOM double: Enter answers once, with the focused button's action, and
 * Escape answers "later".
 *
 * ROOT CAUSE ENCODED (PRM-01):
 * The page answered every Enter with "open_settings" from a document listener
 * and let the browser's default action click the focused button as well. A user
 * who tabbed to « Later » and pressed Enter sent "open_settings" then "later":
 * System Settings opened although they had chosen to wait.
 *
 * WHY THE SCRIPT IS READ FROM THE SOURCE:
 * The page is assembled by render() from Lua string literals; the JavaScript
 * suite has no Lua runtime, so this guard reads those literals (and the bridge
 * name they interpolate) from the module and runs the resulting script.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCE = path.join(ROOT, 'static/ergopti_plus/macos/ui/permission_dialog/init.lua');

/**
 * Decodes the Lua double-quoted literals and the M.BRIDGE references of one
 * source fragment, in order.
 * @param {string} fragment Lua source between the script tags.
 * @param {string} bridge The value of M.BRIDGE.
 * @returns {string} The concatenated text.
 */
function decodeLuaConcat(fragment, bridge) {
	const withoutComments = fragment.replace(/^\s*--.*$/gm, '');
	const token = /"((?:[^"\\]|\\.)*)"|M\.BRIDGE/g;
	let text = '';
	for (const match of withoutComments.matchAll(token)) {
		text += match[1] === undefined ? bridge : match[1].replace(/\\(.)/g, '$1');
	}
	return text;
}

/**
 * Extracts the page script render() emits.
 * @returns {{ script: string, markup: string }}
 */
function pageScript() {
	const source = fs.readFileSync(SOURCE, 'utf8');
	const bridge = /M\.BRIDGE\s*=\s*"([^"]+)"/.exec(source);
	if (!bridge) throw new Error('M.BRIDGE is not declared in the permission dialog');
	const start = source.indexOf('"<script>",');
	const end = source.indexOf('"</script></body></html>"', start);
	if (start < 0 || end < 0)
		throw new Error('render() no longer emits its script between literal tags');
	const buttons = source.lastIndexOf('"<div class=\\"buttons\\">', start);
	return {
		script: decodeLuaConcat(source.slice(start + '"<script>",'.length, end), bridge[1]),
		markup: decodeLuaConcat(source.slice(buttons, start), bridge[1]),
		bridge: bridge[1]
	};
}

/**
 * Runs the page in a DOM double and presses one key on one focused element.
 * @param {string} key The key pressed.
 * @param {string|null} focused The id of the focused button, or null for the body.
 * @returns {string[]} The actions posted to the bridge.
 */
function press(key, focused) {
	const { script, bridge } = pageScript();
	const posted = [];
	const elements = { open: { tagName: 'BUTTON' }, later: { tagName: 'BUTTON' } };
	const body = { tagName: 'BODY' };
	const listeners = [];
	const context = {
		window: {
			webkit: {
				messageHandlers: { [bridge]: { postMessage: (message) => posted.push(message.action) } }
			}
		},
		document: {
			getElementById: (id) => elements[id],
			addEventListener: (type, listener) => {
				if (type === 'keydown') listeners.push(listener);
			}
		}
	};
	vm.runInNewContext(script, context);
	const target = focused ? elements[focused] : body;
	const event = {
		key,
		target,
		defaultPrevented: false,
		preventDefault() {
			this.defaultPrevented = true;
		}
	};
	for (const listener of listeners) listener(event);
	// The browser's default action: Enter on a focused button clicks it.
	if (!event.defaultPrevented && key === 'Enter' && target.tagName === 'BUTTON') target.onclick();
	return posted;
}

const failures = [];

/**
 * Records a failure when two action lists differ.
 * @param {string} label
 * @param {string[]} actual
 * @param {string[]} expected
 */
function expect(label, actual, expected) {
	if (JSON.stringify(actual) !== JSON.stringify(expected)) {
		failures.push(
			`${label}: posted ${JSON.stringify(actual)}, expected ${JSON.stringify(expected)}`
		);
	}
}

expect('Enter on the focused « Later » button', press('Enter', 'later'), ['later']);
expect('Enter on the focused « Open Settings » button', press('Enter', 'open'), ['open_settings']);
expect('Enter with no focused button', press('Enter', null), ['open_settings']);
expect('Escape', press('Escape', 'open'), ['later']);
if (!/id="open" class="default" autofocus/.test(pageScript().markup)) {
	failures.push('the default button is not focused when the dialog opens');
}

if (failures.length > 0) {
	console.error('[FAIL] macOS permission dialog keys (PRM-01):');
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	'[OK] macOS permission dialog: Enter answers once with the focused button, Escape answers later.'
);
