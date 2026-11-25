// tools/test/test-hotstring-editor-trigger-capture.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Editor — Only The Trigger Field Records Raw Keys
 * DESCRIPTION:
 * Maintainer decision of 2026-11-25: the layout emulation and the hotstrings
 * stay active in every Ergopti window and text field; only a field that records
 * a trigger, a key or a shortcut receives the raw keys. The editor page used to
 * tell the daemon « focused » for the whole window, so the Linux capture gate
 * withheld the emulation and the hotstrings in the replacement field too (Arch
 * Linux field report: the user typed his physical layout in Ergopti's own
 * fields).
 *
 * FEATURES & RATIONALE:
 * 1. Runs the page's own focus wiring (the block from TRIGGER_FIELD_ID to the
 *    window blur listener) in a VM against recording document and window
 *    doubles, so the messages are the page's, not a copy.
 * 2. Pins each transition: the replacement field holds nothing, the trigger
 *    field holds the gate, leaving it or the window releases it, and a message
 *    is sent only on a change.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const SCRIPT = path.resolve(
	__dirname,
	'../../static/ergopti_plus/_shared/ui/hotstring_editor/script.js'
);

/**
 * Extracts the page's focus wiring.
 * @param {string} source - The editor script.
 * @returns {string} The wiring block.
 */
function wiring(source) {
	const first = source.indexOf("const TRIGGER_FIELD_ID = 'e-trig';");
	assert.ok(first >= 0, 'the page names the trigger field that records raw keys');
	const blur = source.indexOf("window.addEventListener(\n\t'blur',", first);
	assert.ok(blur > first, 'the window blur listener follows the trigger field wiring');
	const last = source.indexOf('\n);', blur);
	assert.ok(last > blur, 'the window blur listener ends');
	return source.slice(first, last + 3);
}

/**
 * Runs the wiring and returns its listeners and the messages it sent.
 * @returns {{ fire: Function, sent: Array }} The doubles.
 */
function load() {
	const listeners = { document: {}, window: {} };
	const sent = [];
	const target = (name) => ({
		addEventListener: (type, fn) => {
			listeners[name][type] = fn;
		}
	});
	const window = target('window');
	const document = target('document');
	const context = {
		window,
		document,
		Boolean,
		toLua: (action, payload) => sent.push({ action, focused: payload.focused })
	};
	vm.runInNewContext(`${wiring(fs.readFileSync(SCRIPT, 'utf8'))}\n`, context);
	const fire = (on, type, element) =>
		listeners[on][type]({ target: element === 'window' ? window : element });
	return { fire, sent };
}

const checks = [];
function check(name, body) {
	checks.push({ name, body });
}

check('a replacement field holds no capture: emulation and hotstrings type there', () => {
	const { fire, sent } = load();
	fire('document', 'focusin', { id: 'e-out' });
	fire('document', 'focusin', { id: 'search-input' });
	assert.deepEqual(sent, []);
});

check('the trigger field holds the capture, and releases it when it loses the focus', () => {
	const { fire, sent } = load();
	fire('document', 'focusin', { id: 'e-trig' });
	fire('document', 'focusout', { id: 'e-trig' });
	fire('document', 'focusin', { id: 'e-out' });
	assert.deepEqual(sent, [
		{ action: 'window_focus', focused: true },
		{ action: 'window_focus', focused: false }
	]);
});

check('moving from the trigger field to another field releases it', () => {
	const { fire, sent } = load();
	fire('document', 'focusin', { id: 'e-trig' });
	fire('document', 'focusin', { id: 'e-out' });
	assert.deepEqual(
		sent.map((m) => m.focused),
		[true, false]
	);
});

check('leaving the window releases the trigger field, and coming back to it holds it again', () => {
	const { fire, sent } = load();
	fire('document', 'focusin', { id: 'e-trig' });
	fire('window', 'blur', 'window');
	fire('document', 'focusin', { id: 'e-trig' });
	assert.deepEqual(
		sent.map((m) => m.focused),
		[true, false, true]
	);
});

let failed = 0;
for (const { name, body } of checks) {
	try {
		body();
		console.log(`  ✓  ${name}`);
	} catch (error) {
		failed += 1;
		console.log(`  ✗  ${name}\n       ${error.message}`);
	}
}
console.log(`\nResults: ${checks.length - failed} passed, ${failed} failed.`);
process.exit(failed === 0 ? 0 : 1);
