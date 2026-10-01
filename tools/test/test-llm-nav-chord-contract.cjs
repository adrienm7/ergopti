// tools/test/test-llm-nav-chord-contract.cjs

/**
 * ==============================================================================
 * MODULE: Prediction Navigation Chord Contract Gate
 * DESCRIPTION:
 * While the AI tooltip shows several predictions, the user moves between them
 * with the chords its footer and its menu advertise. The shared tooltip
 * constants (_shared/modules/tooltip/constants.toml [llm_ui]) are that
 * contract: the chords left of "Tab = accepter" step back, those right of it
 * step forward. "⇧G + Tab" / "⇧D + Tab" name the left and right Shift with Tab,
 * "↑/←" / "↓/→" the arrows, and menu.llm.nav_label repeats the arrows. This
 * gate reads that contract and every driver's tables, and requires each
 * advertised chord in its direction on Windows, macOS and Linux
 * (llm-nav-left-right-windows):
 *
 * 1. The contract: the footer hints parse into the six chords and their steps,
 *    and the label pairs the same arrows.
 * 2. macOS: the keymap fallback's ARROW_NAVIGATION_DELTA, and the tooltip
 *    watcher's arrow and Shift+Tab rules.
 * 3. Linux: the prediction engine's ARROW_NAVIGATION_DELTA and
 *    SHIFT_TAB_NAVIGATION_DELTA, fed the Shift side by the keyboard hook.
 * 4. Windows: LLM_NAV_CYCLE_KEYS by the step of the route each arrow shares,
 *    LLM_NAV_SHIFT_TAB_STEPS, a consuming hotkey for each chord, the tap-hold
 *    Tab under Shift, and a footer that shows the arrows even when bare.
 * The drivers' own suites drive the handlers; this gate keeps the three tables
 * and the advertised strings from drifting apart.
 *
 * ROOT CAUSE ENCODED:
 * macOS cycled on the four arrows and on Shift+Tab, but Windows only on Up and
 * Down and Linux only on Up and Down: Left, Right and Shift+Tab reached the
 * application behind a tooltip that advertised them (maintainer report of
 * 2026-09-30). The Windows footer also hid the bare arrows.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static', 'ergopti_plus');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (rel) => fs.readFileSync(path.join(PLUS, rel), 'utf8').replace(/^﻿/, '');

const registry = JSON.parse(read('_shared/data/keycodes/physical_keys.json')).keys;

// Glyphs of the footer and the label, by physical-key registry id.
const ARROW_GLYPHS = new Map([
	['↑', 'ArrowUp'],
	['↓', 'ArrowDown'],
	['←', 'ArrowLeft'],
	['→', 'ArrowRight']
]);
// The French canonical footer names the Shift side by its initial: Gauche, Droite.
const SHIFT_GLYPHS = new Map([
	['⇧G', 'ShiftLeft'],
	['⇧D', 'ShiftRight']
]);

/**
 * Reads one string of the [llm_ui] table.
 * @param {string} toml The constants file.
 * @param {string} key Key of [llm_ui].
 * @returns {string} Its value, "" when absent.
 */
const llmUi = (toml, key) => {
	const table = (/^\[llm_ui\]\s*$([\s\S]*?)^\[/m.exec(toml) || [])[1] || '';
	const match = new RegExp(`^${key}\\s*=\\s*"([^"]*)"`, 'm').exec(table);
	return match ? match[1] : '';
};

// 1. The contract, from the footer hints.
const toml = read('_shared/modules/tooltip/constants.toml');
const contract = { arrows: new Map(), shiftTab: new Map() };
for (const [key, step] of [
	['hint_arrow_left', -1],
	['hint_arrow_right', 1]
]) {
	const hint = llmUi(toml, key);
	const glyphs = hint.split('/').map((glyph) => glyph.trim());
	check(
		glyphs.length === 2 && glyphs.every((glyph) => ARROW_GLYPHS.has(glyph)),
		`[llm_ui] ${key} must name two arrows, found "${hint}"`
	);
	for (const glyph of glyphs) contract.arrows.set(ARROW_GLYPHS.get(glyph), step);
}
for (const [key, step] of [
	['hint_nav_left', -1],
	['hint_nav_right', 1]
]) {
	const hint = llmUi(toml, key);
	const match = /^(⇧[GD]) \+ Tab$/.exec(hint);
	check(match !== null, `[llm_ui] ${key} must name one Shift side with Tab, found "${hint}"`);
	if (match) contract.shiftTab.set(SHIFT_GLYPHS.get(match[1]), step);
}
check(
	contract.arrows.size === 4 &&
		contract.arrows.get('ArrowUp') === -1 &&
		contract.arrows.get('ArrowLeft') === -1 &&
		contract.arrows.get('ArrowDown') === 1 &&
		contract.arrows.get('ArrowRight') === 1,
	'the footer must advertise ↑/← back and ↓/→ forward'
);
check(
	contract.shiftTab.get('ShiftLeft') === -1 && contract.shiftTab.get('ShiftRight') === 1,
	'the footer must advertise the left Shift+Tab back and the right one forward'
);
for (const locale of ['en', 'fr']) {
	const label = JSON.parse(read(`_shared/data/locales/${locale}.json`))['menu.llm.nav_label'] || '';
	check(
		label.includes(llmUi(toml, 'hint_arrow_left')) &&
			label.indexOf(llmUi(toml, 'hint_arrow_left')) <
				label.indexOf(llmUi(toml, 'hint_arrow_right')),
		`${locale}.json menu.llm.nav_label must name the footer's arrows in order, found "${label}"`
	);
}

/**
 * Finds the registry id whose field equals value, among the given ids.
 * @param {Iterable<string>} ids Candidate registry ids.
 * @param {string} field Registry field (hs, evdev, ahk_send).
 * @param {number|string} value Driver-side code or name.
 * @returns {string} Registry id, "" when none matches.
 */
const idBy = (ids, field, value) =>
	[...ids].find((id) => registry[id] && registry[id][field] === value) || '';

/**
 * Compares one driver's table with the contract's.
 * @param {string} driver Driver and table name for messages.
 * @param {Map<string, number>} expected Registry id to step.
 * @param {Map<string, number>} steps The driver's registry id to step.
 */
const expectSteps = (driver, expected, steps) => {
	for (const [id, step] of expected) {
		check(
			steps.get(id) === step,
			`${driver}: ${id} must step ${step}, as the tooltip advertises, found ${steps.get(id)}`
		);
	}
	for (const id of steps.keys()) {
		check(expected.has(id), `${driver}: ${id || 'an unknown key'} is not an advertised chord`);
	}
};

/**
 * Reads a Lua table literal assigned to a module local.
 * @param {string} source Lua source.
 * @param {string} name Local name.
 * @returns {string} Table body, "" when absent.
 */
const luaTable = (source, name) =>
	(new RegExp(`^local ${name} = \\{([\\s\\S]*?)\\}`, 'm').exec(source) || [])[1] || '';

// 2. macOS.
{
	const bridge = read('macos/modules/keymap/llm_bridge.lua');
	const steps = new Map();
	for (const entry of luaTable(bridge, 'ARROW_NAVIGATION_DELTA').matchAll(
		/\[(\d+)\]\s*=\s*(-?1)\b/g
	)) {
		steps.set(idBy(contract.arrows.keys(), 'hs', Number(entry[1])), Number(entry[2]));
	}
	expectSteps('macOS ARROW_NAVIGATION_DELTA', contract.arrows, steps);

	const watcher = read('macos/ui/tooltip/tooltip_llm.lua');
	check(
		/if keycode >= Keycodes\.LEFT_ARROW and keycode <= Keycodes\.UP_ARROW then/.test(watcher) &&
			/\(keycode == Keycodes\.LEFT_ARROW or keycode == Keycodes\.UP_ARROW\) and -1 or 1/.test(
				watcher
			),
		'macOS tooltip watcher: the four arrows must cycle, Left and Up back, Right and Down forward'
	);
	check(
		/if keycode == Keycodes\.TAB then\s+if flags\.shift then/.test(watcher) &&
			/local direction = \(_shift_side == "right"\) and 1 or -1/.test(watcher),
		'macOS tooltip watcher: Shift+Tab must step back with the left Shift and forward with the right one'
	);
	check(
		/hint_left\s*=\s*ui\.hint_nav_left/.test(watcher) &&
			/hint_left\s*\.\. hint_or \.\. optional_nav_mod \.\. ui\.hint_arrow_left/.test(watcher),
		'macOS footer: Shift+Tab, then the arrows with the optional navigation modifiers'
	);
}

// 3. Linux.
{
	const codes = read('linux/infra/evdev_codes.lua');
	const named = new Map();
	for (const entry of codes.matchAll(/^M\.(KEY_[A-Z]+)\s*=\s*(\d+)/gm)) {
		named.set(entry[1], Number(entry[2]));
	}
	const engine = read('linux/modules/llm/prediction_engine.lua');
	const arrows = new Map();
	for (const entry of luaTable(engine, 'ARROW_NAVIGATION_DELTA').matchAll(
		/\[EvdevCodes\.(KEY_[A-Z]+)\]\s*=\s*(-?1)\b/g
	)) {
		arrows.set(idBy(contract.arrows.keys(), 'evdev', named.get(entry[1])), Number(entry[2]));
	}
	expectSteps('Linux ARROW_NAVIGATION_DELTA', contract.arrows, arrows);
	const LINUX_SIDES = new Map([
		['left', 'ShiftLeft'],
		['right', 'ShiftRight']
	]);
	const shiftTab = new Map();
	for (const entry of luaTable(engine, 'SHIFT_TAB_NAVIGATION_DELTA').matchAll(
		/(\w+)\s*=\s*(-?1)\b/g
	)) {
		shiftTab.set(LINUX_SIDES.get(entry[1]) || '', Number(entry[2]));
	}
	expectSteps('Linux SHIFT_TAB_NAVIGATION_DELTA', contract.shiftTab, shiftTab);
	check(
		/local navigation = ARROW_NAVIGATION_DELTA\[detail\.code\]/.test(engine) &&
			/local shift_tab = shift_tab_step\(detail\)/.test(engine) &&
			/return SHIFT_TAB_NAVIGATION_DELTA\[detail\.shift_side\]/.test(engine),
		'Linux handle_shortcut must step by both tables'
	);
	check(
		/shift_side = M\.held_shift_side\(\),/.test(read('linux/adapters/keyboard_hook.lua')),
		'the Linux keyboard hook must name the Shift side in every consume detail'
	);
}

// 4. Windows.
{
	const tabAccept = read('windows/ui/menu/menu_llm/tab_accept.ahk');
	const routes = new Map();
	for (const route of tabAccept.matchAll(
		/"(\w+)", Map\("index", \d+, "code", "sc[0-9a-f]{4}", "delta", (-?1)\)/gi
	)) {
		routes.set(route[1], Number(route[2]));
	}
	const keys =
		(/^global LLM_NAV_CYCLE_KEYS := Map\(([\s\S]*?)\)\s*$/m.exec(tabAccept) || [])[1] || '';
	const arrows = new Map();
	for (const pair of keys.matchAll(/"(\w+)", "(\w+)"/g)) {
		const id = idBy(contract.arrows.keys(), 'ahk_send', pair[1]);
		arrows.set(id, routes.get(pair[2]));
		check(
			new RegExp(
				`^#HotIf LLM_Menu_NavCycleChordIsOwned\\("${pair[1]}"\\)\\s*\\n\\*${registry[id]?.ahk}:: LLM_Menu_NavCycleChord\\("${pair[1]}"\\)`,
				'm'
			).test(tabAccept),
			`Windows: ${pair[1]} must consume through its shared physical scan code`
		);
	}
	expectSteps('Windows LLM_NAV_CYCLE_KEYS', contract.arrows, arrows);

	const sides =
		(/^global LLM_NAV_SHIFT_TAB_STEPS := Map\(([^)]*)\)/m.exec(tabAccept) || [])[1] || '';
	const shiftTab = new Map();
	for (const pair of sides.matchAll(/"(\w+)", (-?1)\b/g)) {
		shiftTab.set(idBy(contract.shiftTab.keys(), 'ahk_send', pair[1]), Number(pair[2]));
		const prefix = pair[1] === 'LShift' ? '<\\+' : '>\\+';
		check(
			new RegExp(
				`^#HotIf LLM_Menu_NavShiftTabIsOwned\\("${pair[1]}"\\)\\s*\\n${prefix}SC00F:: LLM_Menu_NavShiftTabCycle\\("${pair[1]}"\\)`,
				'm'
			).test(tabAccept),
			`Windows: ${pair[1]}+Tab must have its consuming SC00F hotkey`
		);
	}
	expectSteps('Windows LLM_NAV_SHIFT_TAB_STEPS', contract.shiftTab, shiftTab);

	const bridge = read('windows/modules/keymap/llm_bridge.ahk');
	check(
		/_LLM_Accept_TapHoldTapKey\(TabProvenance\) != ""\s*&& LLM_Menu_NavShiftTabTap\(ModifierIsHeldFn\)/.test(
			bridge
		),
		'Windows: a tap-hold Tab under one Shift must be offered to the Shift+Tab chord'
	);
	const footer = read('windows/ui/tooltip/llm.ahk');
	check(
		/hintLeft \.= UI_LLM_HINT_OR \. chord \. UI_LLM_HINT_ARROW_LEFT/.test(footer) &&
			/chord := navStr == "" \? "" : navStr \. " \+ "/.test(footer),
		'Windows footer: the arrows must follow Shift+Tab, bare when no navigation modifier is set'
	);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] Prediction navigation chord contract: ${checks} check(s) passed.\x1b[0m`);
