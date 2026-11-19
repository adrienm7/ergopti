// tools/test/test-keyboard-operability.cjs

/**
 * ==============================================================================
 * MODULE: Keyboard Operability Judgement Test
 * DESCRIPTION:
 * Proves without a browser that tools/test/lib/keyboard-operability.cjs
 * refuses every way a control can be left to the mouse, and accepts the
 * keyboard-operable ones, so the browser gates that feed it real pages
 * (keyboard-operability.playwright.cjs, app-windows-accessibility.playwright.cjs)
 * cannot pass vacuously. Also pins that the gates are wired: the site gate
 * runs in CI on the received site, and the app windows gate calls the check.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const {
	operabilityProblems,
	widgetProblems,
	INTERACTIVE_ROLES,
	POINTER_EVENTS,
	KEY_EVENTS
} = require('./lib/keyboard-operability.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

/** A reported row with sensible defaults: a focusable native button. */
function row(fields) {
	return {
		id: 'x',
		tag: 'button',
		role: '',
		pointer: true,
		native: true,
		disabled: false,
		focusable: true,
		roving: false,
		keyHandled: false,
		delegating: false,
		labelControlFocusable: null,
		equivalent: false,
		hiddenFromAT: false,
		...fields
	};
}

function checkOperability() {
	// Accepted: a native button, a delegating container, a roving tab, a label
	// of a focusable input, a custom button with a key listener, a disabled control.
	assert.deepEqual(
		operabilityProblems([
			row({}),
			row({ tag: 'ul', native: false, focusable: false, delegating: true }),
			row({ tag: 'button', role: 'tab', focusable: false, roving: true }),
			row({ tag: 'label', focusable: false, labelControlFocusable: true }),
			row({ tag: 'div', native: false, role: 'button', keyHandled: true }),
			row({ tag: 'div', native: false, focusable: false, disabled: true }),
			row({ tag: 'option', focusable: false }),
			row({ tag: 'dialog', focusable: false }),
			row({ tag: 'keyboard-key', role: 'cell', native: false, focusable: false, equivalent: true })
		]),
		[]
	);
	// Refused: a clickable div, one with a tabindex but no role, one with a
	// role but no key listener, a native control out of the Tab order, a label
	// of an unreachable control, a focusable control inside aria-hidden.
	const refused = (fields) => operabilityProblems([row({ id: 'probe', ...fields })]);
	assert.match(refused({ tag: 'div', native: false, focusable: false })[0], /mouse only/);
	assert.match(refused({ tag: 'div', native: false })[0], /no interactive role/);
	assert.match(refused({ tag: 'span', native: false, role: 'button' })[0], /no key listener/);
	assert.match(refused({ focusable: false })[0], /Tab cannot reach it/);
	assert.match(
		refused({ tag: 'label', focusable: false, labelControlFocusable: false })[0],
		/label whose control/
	);
	assert.match(refused({ hiddenFromAT: true })[0], /inside aria-hidden/);
	// A declared equivalent whose control is missing does not excuse the element.
	assert.match(
		refused({ tag: 'keyboard-key', native: false, focusable: false, equivalent: false })[0],
		/mouse only/
	);
	// Every interactive role is one a user operates.
	for (const role of ['button', 'link', 'tab', 'checkbox', 'menuitem', 'option'])
		assert.ok(INTERACTIVE_ROLES.includes(role), role);
	assert.ok(POINTER_EVENTS.includes('click') && POINTER_EVENTS.includes('pointerdown'));
	assert.deepEqual([...KEY_EVENTS], ['keydown', 'keyup', 'keypress']);
}

function checkWidgets() {
	assert.deepEqual(
		widgetProblems([
			{ kind: 'disclosure', id: 'a', popup: false, opened: true, closed: true },
			{ kind: 'disclosure', id: 'b', popup: true, opened: true, closed: true, focusBack: true },
			{ kind: 'composite', id: 'c', moved: true }
		]),
		[]
	);
	assert.match(
		widgetProblems([{ kind: 'disclosure', id: 'a', opened: false }])[0],
		/does not open/
	);
	assert.match(
		widgetProblems([{ kind: 'disclosure', id: 'a', popup: true, opened: true, closed: false }])[0],
		/Escape does not close/
	);
	assert.match(
		widgetProblems([
			{ kind: 'disclosure', id: 'a', popup: true, opened: true, closed: true, focusBack: false }
		])[0],
		/focus away/
	);
	assert.match(
		widgetProblems([{ kind: 'disclosure', id: 'a', popup: false, opened: true, closed: false }])[0],
		/second time/
	);
	assert.match(widgetProblems([{ kind: 'composite', id: 'c', moved: false }])[0], /arrow keys/);
}

function checkWiring() {
	const ci = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-common.yml'), 'utf8');
	assert.match(
		ci,
		/node tools\/test\/browser\/keyboard-operability\.playwright\.cjs "\$RUNNER_TEMP\/received-site\/site" "\$BASE_PATH"/,
		'CI runs the keyboard operability gate on the received production site'
	);
	const app = fs.readFileSync(
		path.join(ROOT, 'tools/test/browser/app-windows-accessibility.playwright.cjs'),
		'utf8'
	);
	assert.match(app, /operabilityProblems\(/, 'The app windows gate judges their operability');
	assert.match(app, /rule: OPERABILITY_RULE/, 'Its mouse-only controls are counted by its ratchet');
	assert.match(app, /instrumentListeners/, 'The app windows gate records their listeners');
	const studio = fs.readFileSync(
		path.join(ROOT, 'tools/test/browser/studio-keyboard.playwright.cjs'),
		'utf8'
	);
	assert.match(studio, /operabilityProblems\(rows\)/, 'The Studio keyboard gate judges its pages');
}

checkOperability();
checkWidgets();
checkWiring();
console.log(
	'Keyboard operability: the judgement refuses every mouse-only control and the gates are wired'
);
