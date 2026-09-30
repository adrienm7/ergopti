// tools/test/test-windows-llm-nav-cycle.cjs

/**
 * ==============================================================================
 * MODULE: Windows Prediction Navigation Cycle Gate
 * DESCRIPTION:
 * The Windows driver cycles the AI prediction tooltip on the configured
 * navigation chord: nav_modifiers with Up or Left for the previous prediction,
 * Down or Right for the next, as the shared menu.llm.nav_label (↑/← and ↓/→)
 * says, and on the footer's left and right Shift+Tab (⇧G + Tab, ⇧D + Tab).
 * Only the AHK suite, on Windows CI, can run that path; this gate checks
 * from the sources, anywhere, that one key press moves the marker exactly once
 * whichever keyboard hook Windows calls first (llm-nav-cycle-windows):
 *
 * 1. The static hotkeys that consume the chord perform the cycle themselves:
 *    one wildcard hotkey per arrow, at the native routes' input level, with no
 *    pass-through prefix and an action that cycles, never a bare return. Left
 *    and Right share the chord and the step of the Up and Down cycle routes.
 *    Shift+Tab is one SC00F hotkey per Shift side, without the wildcard, at
 *    the same input level.
 * 2. No native cycle route matches a key those hotkeys consume: the adapter
 *    marshals both cycle routes from the parked table, whose identities no
 *    keyboard produces (extended scan code zero), so the native owner never
 *    cycles an arrow and passes it on.
 * 3. The parking exists only while the DLL contract demands cycle routes.
 * 4. The AHK regression test is registered in run_all.ahk.
 *
 * ROOT CAUSE ENCODED:
 * The native owner cycled on the arrow and passed it on (its plan contract
 * requires a cycle route to pass through), and wildcard AutoHotkey hotkeys
 * swallowed it, assuming the DLL's hook ran first. AutoHotkey removes and
 * reinstalls its keyboard hook around every SendInput, and Windows calls the
 * most recently installed hook first: once the driver had typed anything,
 * AutoHotkey swallowed the arrow before the native owner saw it, and the
 * marker never moved. Then only Up and Down had a consuming hotkey, so Left,
 * Right and Shift+Tab reached the application behind the tooltip instead of
 * moving the marker, against the label, the footer and macOS
 * (llm-nav-left-right-windows, maintainer report of 2026-09-30).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'static', 'ergopti_plus', 'windows');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (rel) => fs.readFileSync(path.join(WIN, rel), 'utf8').replace(/^﻿/, '');

// The arrows the chord cycles on, with the step the shared label gives each:
// ↑/← the previous prediction, ↓/→ the next.
const ARROW_STEPS = new Map([
	['Up', -1],
	['Down', 1],
	['Left', -1],
	['Right', 1]
]);

// The scan code AutoHotkey resolves each arrow name to (its g_key_to_sc table),
// from the physical-key registry every driver shares.
const REGISTRY = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data', 'keycodes', 'physical_keys.json'),
		'utf8'
	)
);
const arrowScanCodes = new Map();
for (const record of Object.values(REGISTRY.keys)) {
	if (
		record.kind === 'key' &&
		ARROW_STEPS.has(record.ahk_send) &&
		/^SC[0-9A-F]{3}$/.test(record.ahk)
	)
		arrowScanCodes.set(record.ahk_send, Number.parseInt(record.ahk.slice(2), 16));
}
check(
	arrowScanCodes.size === ARROW_STEPS.size,
	`the physical-key registry must give the scan code of the four arrows, found ${arrowScanCodes.size}`
);

/**
 * Removes full-line and trailing AHK comments, keeping line positions.
 * @param {string} source AHK source text.
 * @returns {string} Source without comments.
 */
const stripComments = (source) =>
	source
		.split('\n')
		.map((line) => (/^\s*;/.test(line) ? '' : line.replace(/\s+;.*$/, '')))
		.join('\n');

/**
 * Returns the body of an AHK function declared at column 0, its signature
 * possibly continued on the following lines.
 * @param {string} source AHK source text.
 * @param {string} name Function name.
 * @returns {string} Body text, "" when absent.
 */
const bodyOf = (source, name) => {
	const start = source.search(new RegExp(`^${name}\\(`, 'm'));
	if (start < 0) return '';
	const open = source.slice(start).search(/\)\s*\{[ \t]*$/m);
	if (open < 0) return '';
	const end = source.indexOf('\n}', start + open);
	return end < 0 ? '' : source.slice(start, end);
};

/**
 * Returns the text of a top-level global assignment, up to the line that
 * closes it.
 * @param {string} source AHK source text.
 * @param {string} name Global name.
 * @returns {string} Assignment text, "" when absent.
 */
const globalOf = (source, name) => {
	const match = new RegExp(`^global ${name} := [\\s\\S]*?[\\])]\\s*$`, 'm').exec(source);
	return match ? match[0] : '';
};

// 1. The consuming hotkeys cycle.
const tabAccept = stripComments(read('ui/menu/menu_llm/tab_accept.ahk'));
const routes = globalOf(tabAccept, 'LLM_NAV_CYCLE_ROUTES');
const routeCodes = new Map();
const routeDeltas = new Map();
for (const route of routes.matchAll(
	/"(Up|Down)", Map\("index", (\d+), "code", "sc([0-9a-f]{4})", "delta", (-?1)\)/gi
)) {
	routeCodes.set(route[1], Number.parseInt(route[3], 16));
	routeDeltas.set(route[1], Number(route[4]));
}
check(
	routeCodes.size === 2,
	`tab_accept.ahk must declare the Up and Down cycle routes with their scan code and delta, found ${routeCodes.size}`
);
for (const [key, code] of routeCodes) {
	check(
		code === arrowScanCodes.get(key),
		`the ${key} cycle route must name the scan code AutoHotkey resolves ${key} to`
	);
}

// Every consumed arrow names the cycle route whose chord and step it shares.
const keyRoutes = new Map();
for (const pair of globalOf(tabAccept, 'LLM_NAV_CYCLE_KEYS').matchAll(/"(\w+)", "(\w+)"/g)) {
	keyRoutes.set(pair[1], pair[2]);
}
check(
	[...keyRoutes.keys()].sort().join(',') === [...ARROW_STEPS.keys()].sort().join(','),
	`tab_accept.ahk must map exactly the four arrows to a cycle route in LLM_NAV_CYCLE_KEYS, found [${[...keyRoutes.keys()].join(', ')}]`
);
for (const [key, route] of keyRoutes) {
	check(
		routeDeltas.get(route) === ARROW_STEPS.get(key),
		`${key} must step ${ARROW_STEPS.get(key)} like the label says, but shares the ${route} route`
	);
}

const lines = tabAccept.split('\n');
const consumed = new Set();
lines.forEach((line, index) => {
	const hotIf = /^#HotIf LLM_Menu_NavCycleChordIsOwned\("(\w+)"\)\s*$/.exec(line.trim());
	if (!hotIf) return;
	const key = hotIf[1];
	check(
		!consumed.has(key),
		`tab_accept.ahk:${index + 1} ${key} must have one consuming hotkey only`
	);
	consumed.add(key);
	const label = lines.slice(index + 1).find((next) => next.trim() !== '') || '';
	check(
		new RegExp(`^\\*${key}::\\s*LLM_Menu_NavCycleChord\\("${key}"\\)\\s*$`).test(label.trim()),
		`tab_accept.ahk:${index + 2} the hotkey consuming the ${key} chord must cycle through LLM_Menu_NavCycleChord("${key}"), with no pass-through prefix: ${label.trim()}`
	);
	const level = lines
		.slice(0, index)
		.reverse()
		.find((previous) => /^#InputLevel\b/.test(previous.trim()));
	check(
		/^#InputLevel 1\s*$/.test((level || '').trim()),
		`tab_accept.ahk:${index + 1} the ${key} consuming hotkey must take the native routes' #InputLevel 1`
	);
});
// Shift+Tab: one SC00F hotkey per Shift side, the most specific hotkey of the
// Tab key under that Shift, stepping like the footer says.
const SHIFT_TAB_STEPS = new Map([
	['LShift', ['<+', -1]],
	['RShift', ['>+', 1]]
]);
const shiftSteps = new Map();
for (const pair of (
	(/^global LLM_NAV_SHIFT_TAB_STEPS := Map\(([^)]*)\)/m.exec(tabAccept) || [])[1] || ''
).matchAll(/"(\w+)", (-?1)\b/g)) {
	shiftSteps.set(pair[1], Number(pair[2]));
}
const shiftConsumed = new Set();
lines.forEach((line, index) => {
	const hotIf = /^#HotIf LLM_Menu_NavShiftTabIsOwned\("(\w+)"\)\s*$/.exec(line.trim());
	if (!hotIf) return;
	const side = hotIf[1];
	const expected = SHIFT_TAB_STEPS.get(side);
	check(expected !== undefined, `tab_accept.ahk:${index + 1} ${side} is not a Shift side`);
	if (!expected) return;
	check(
		!shiftConsumed.has(side),
		`tab_accept.ahk:${index + 1} ${side}+Tab must have one consuming hotkey only`
	);
	shiftConsumed.add(side);
	check(
		shiftSteps.get(side) === expected[1],
		`LLM_NAV_SHIFT_TAB_STEPS must step ${expected[1]} for ${side}, found ${shiftSteps.get(side)}`
	);
	const label = lines.slice(index + 1).find((next) => next.trim() !== '') || '';
	check(
		label.trim() === `${expected[0]}SC00F:: LLM_Menu_NavShiftTabCycle("${side}")`,
		`tab_accept.ahk:${index + 2} the ${side}+Tab hotkey must be ${expected[0]}SC00F, cycling through LLM_Menu_NavShiftTabCycle: ${label.trim()}`
	);
	const level = lines
		.slice(0, index)
		.reverse()
		.find((previous) => /^#InputLevel\b/.test(previous.trim()));
	check(
		/^#InputLevel 1\s*$/.test((level || '').trim()),
		`tab_accept.ahk:${index + 1} the ${side}+Tab hotkey must take the native routes' #InputLevel 1`
	);
});
check(
	shiftConsumed.size === SHIFT_TAB_STEPS.size,
	`expected one consuming hotkey for each Shift side of Shift+Tab, found [${[...shiftConsumed].join(', ')}]`
);
check(
	/LLM_TooltipNavCycleIsOwned\(\)/.test(bodyOf(tabAccept, 'LLM_Menu_NavShiftTabIsOwned')) &&
		/TapHoldPressIsOwned\("tab"\)/.test(bodyOf(tabAccept, 'LLM_Menu_NavShiftTabIsOwned')),
	'LLM_Menu_NavShiftTabIsOwned must demand a routed multi-slot prediction and leave an owned Tab press to its tap-hold'
);
check(
	/LLM_TooltipCycleActiveIdx\(LLM_NAV_SHIFT_TAB_STEPS\[Side\]/.test(
		bodyOf(tabAccept, 'LLM_Menu_NavShiftTabCycle')
	),
	"LLM_Menu_NavShiftTabCycle must move the marker by the side's step through LLM_TooltipCycleActiveIdx"
);

check(
	[...consumed].sort().join(',') === [...ARROW_STEPS.keys()].sort().join(','),
	`expected one consuming hotkey for each of Up, Down, Left and Right, found [${[...consumed].join(', ')}]`
);
const cycle = bodyOf(tabAccept, 'LLM_Menu_NavCycleChord');
check(
	/_LLM_Menu_NavCycleRoute\(Key\)/.test(cycle) &&
		/LLM_TooltipCycleActiveIdx\(\s*Route\["delta"\]/.test(cycle),
	"LLM_Menu_NavCycleChord must move the marker by the delta of the key's cycle route through LLM_TooltipCycleActiveIdx"
);
check(
	/_LLM_Menu_NavCycleRoute\(Key\)/.test(bodyOf(tabAccept, 'LLM_Menu_NavCycleChordIsOwned')),
	"LLM_Menu_NavCycleChordIsOwned must read the chord of the key's cycle route"
);
check(
	/LLM_NAV_CYCLE_ROUTES\[LLM_NAV_CYCLE_KEYS\[Key\]\]/.test(
		bodyOf(tabAccept, '_LLM_Menu_NavCycleRoute')
	),
	'_LLM_Menu_NavCycleRoute must resolve a key through LLM_NAV_CYCLE_KEYS to its cycle route'
);

// 2. No native cycle route matches a consumed key.
const adapter = stripComments(read('adapters/llm_nav_event_owner.ahk'));
const parked = [
	...globalOf(adapter, 'LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES').matchAll(
		/Map\("axis", (\d+), "code", (0x[0-9A-F]+|\d+), "modifiers", (0x[0-9A-F]+|\d+)\)/gi
	)
].map((entry) => ({
	axis: Number(entry[1]),
	code: Number(entry[2]),
	modifiers: Number(entry[3])
}));
check(
	parked.length === 2,
	`the adapter must park exactly two cycle routes, found ${parked.length}`
);
const SC_AXIS = 2;
const identities = new Set();
parked.forEach((route, index) => {
	identities.add(`${route.axis}:${route.code}:${route.modifiers}`);
	check(
		route.axis === SC_AXIS && route.code === 0x100,
		`parked cycle route ${index + 1} must be extended scan code zero, which no key produces and AutoHotkey never sends`
	);
	check(
		route.modifiers >= 0 && route.modifiers <= 0x0f,
		`parked cycle route ${index + 1} must carry a modifier mask the DLL accepts`
	);
	for (const [key, code] of arrowScanCodes) {
		check(
			route.code !== code,
			`parked cycle route ${index + 1} must never be the ${key} key the AutoHotkey hotkey consumes`
		);
	}
});
check(
	identities.size === parked.length,
	'the parked cycle routes must be distinct native identities'
);

const bindings = bodyOf(adapter, '_LLM_NavEventOwnerNativeBindings');
check(
	bindings !== '',
	'the adapter must build the native bindings in _LLM_NavEventOwnerNativeBindings'
);
const cycleBranch = /if A_Index <= 2 \{([\s\S]*?)\n\t\t\}/.exec(bindings);
check(
	cycleBranch !== null &&
		/LLM_NAV_EVENT_OWNER_PARKED_CYCLE_ROUTES\[A_Index\]/.test(cycleBranch[1]) &&
		!/Match\[|physical_id/.test(cycleBranch[1]),
	'_LLM_NavEventOwnerNativeBindings must marshal a cycle route from the parked table, never from the plan key'
);
check(
	/"pass_through", A_Index <= 2 \? 1 : 0/.test(bindings),
	'only the parked cycle routes may pass their key on'
);
check(
	/_LLM_NavEventOwnerNativeBindings\(Plan\)/.test(
		bodyOf(adapter, '_LLM_NavEventOwnerNativePreparePlan')
	),
	'_LLM_NavEventOwnerNativePreparePlan must marshal exactly _LLM_NavEventOwnerNativeBindings'
);

// 3. The parking follows the DLL contract.
const native = fs.readFileSync(
	path.join(WIN, 'native', 'nav_event_owner', 'nav_event_owner.c'),
	'utf8'
);
check(
	/binding->pass_through != 1 \|\| binding->target != 0/.test(native) &&
		/return cycle_up_count == 1\s*&& cycle_down_count == 1/.test(native),
	'NavPlanIsValid no longer demands pass-through cycle routes: drop the parked routes and this check with the rebuilt DLL'
);

// 4. The behavioural regression runs in the AHK suite.
const testFile = 'tests/unit/test_llm_nav_cycle_windows.ahk';
check(
	/^#Include unit\/test_llm_nav_cycle_windows\.ahk\s*$/m.test(read('tests/run_all.ahk')),
	`tests/run_all.ahk must include ${testFile}`
);
check(
	fs.existsSync(path.join(WIN, testFile)) && read(testFile).includes('(llm-nav-cycle-windows)'),
	`${testFile} must carry the llm-nav-cycle-windows slug`
);

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] Windows prediction navigation cycle: ${checks} check(s) passed.\x1b[0m`);
