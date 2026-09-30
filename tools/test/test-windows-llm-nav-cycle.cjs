// tools/test/test-windows-llm-nav-cycle.cjs

/**
 * ==============================================================================
 * MODULE: Windows Prediction Navigation Cycle Gate
 * DESCRIPTION:
 * The Windows driver cycles the AI prediction tooltip on the configured Up /
 * Down chord. Only the AHK suite, on Windows CI, can run that path; this gate
 * checks from the sources, anywhere, that one key press moves the marker exactly
 * once whichever keyboard hook Windows calls first (llm-nav-cycle-windows):
 *
 * 1. The static hotkeys that consume the chord perform the cycle themselves:
 *    one wildcard hotkey per key, at the native routes' input level, with no
 *    pass-through prefix and an action that cycles, never a bare return.
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
 * marker never moved.
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
for (const route of routes.matchAll(
	/"(Up|Down)", Map\("index", (\d+), "code", "sc([0-9a-f]{4})", "delta", (-?1)\)/gi
)) {
	routeCodes.set(route[1], Number.parseInt(route[3], 16));
}
check(
	routeCodes.size === 2,
	`tab_accept.ahk must declare the Up and Down cycle routes with their scan code and delta, found ${routeCodes.size}`
);

const lines = tabAccept.split('\n');
let consumers = 0;
lines.forEach((line, index) => {
	const hotIf = /^#HotIf LLM_Menu_NavCycleChordIsOwned\("(Up|Down)"\)\s*$/.exec(line.trim());
	if (!hotIf) return;
	consumers += 1;
	const key = hotIf[1];
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
check(consumers === 2, `expected one consuming hotkey for Up and one for Down, found ${consumers}`);
const cycle = bodyOf(tabAccept, 'LLM_Menu_NavCycleChord');
check(
	/LLM_TooltipCycleActiveIdx\(\s*LLM_NAV_CYCLE_ROUTES\[Key\]\["delta"\]/.test(cycle),
	'LLM_Menu_NavCycleChord must move the marker by the route delta through LLM_TooltipCycleActiveIdx'
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
	for (const [key, code] of routeCodes) {
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
