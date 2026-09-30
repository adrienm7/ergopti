// tools/test/test-windows-script-chords-follow-their-slot.cjs

/**
 * ==============================================================================
 * MODULE: Windows Script Chords Follow Their Slot
 * DESCRIPTION:
 * The Windows driver's script-management chords (AltGr+Enter, BackSpace,
 * Delete, Escape) run the action their slot of [shortcuts.script_control]
 * holds. Only the AHK suite, on Windows CI, can evaluate their criteria; this
 * gate checks from the sources, anywhere, that each chord hotkey belongs to the
 * driver only while its own slot runs an action (script-chord-slot-2026-09-30):
 *
 * 1. Every #HotIf criterion the registrar uses resolves to a criterion bound to
 *    one slot that asks ScriptShortcutSlotRunsAction(Slot).
 * 2. The plan registers three hotkeys per slot, the combination, the Kana twin
 *    and the paused twin, and every slot of the manifest has its scan code, its
 *    native key and its row in the plan.
 * 3. ScriptShortcutSlotRunsAction refuses an unassigned slot and, while paused,
 *    any action outside the script-management allowlist.
 * 4. RunScriptShortcutAction runs only what that gate admits, and never gives a
 *    chord's key back without logging why.
 * 5. « Raccourcis de gestion du script » opens with its switch, the restore and
 *    the clear, its title is ticked from the switch, and the switch off leaves
 *    every chord to the system (script-chords-switch-2026-09-30).
 * 6. The AHK regression tests are registered in run_all.ahk.
 *
 * ROOT CAUSE ENCODED:
 * The chords were registered under criteria that only checked the AltGr press
 * and the layout. With no action in the slot, as in a configuration that names
 * none, the chord still took AltGr+Entrée and RunScriptShortcutAction retyped a
 * bare {Enter}: the user saw the script-management shortcuts do nothing, and
 * the application never received AltGr+Enter either.
 *
 * `--root <dir>` scans another checkout's copy of the Windows tree.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const rootArg = process.argv.indexOf('--root');
const ROOT =
	rootArg > 0 ? path.resolve(process.argv[rootArg + 1]) : path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const WIN = path.join(SP, 'windows');

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

const read = (file) => fs.readFileSync(file, 'utf8').replace(/^﻿/, '');

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

/** Every production .ahk file of the driver, comments removed, concatenated. */
function driverSource(dir = WIN, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (!['tests', 'vendor', '_generated'].includes(entry.name)) driverSource(full, out);
		} else if (entry.name.endsWith('.ahk')) {
			out.push(stripComments(read(full)));
		}
	}
	return out;
}

const SOURCE = driverSource().join('\n');

/**
 * The body of one top-level AHK function, from its signature to its closing
 * brace at column zero. A signature opens its brace on the same line, which
 * tells it from a top-level call such as the entry's registration.
 * @param {string} name Function name.
 * @returns {string} The function text, or "" when it is not defined.
 */
function functionBody(name) {
	const start = SOURCE.search(new RegExp(`^${name}\\([^\\n]*\\)\\s*\\{\\s*$`, 'm'));
	if (start < 0) return '';
	const bodyStart = SOURCE.indexOf('\n', start) + 1;
	const close = SOURCE.slice(bodyStart).search(/^\}/m);
	return close < 0 ? SOURCE.slice(start) : SOURCE.slice(start, bodyStart + close + 1);
}

/**
 * The entries of a global AHK Map or Array literal of one driver file.
 * @param {string} file Absolute path.
 * @param {string} name Global name.
 * @returns {string[]|null} Its quoted strings in order, or null when absent.
 */
function globalLiteral(file, name) {
	const src = stripComments(read(file));
	const match = src.match(new RegExp(`^global ${name} := (?:Map\\(|\\[)([\\s\\S]*?)^[\\])]`, 'm'));
	return match ? [...match[1].matchAll(/"([^"]*)"/g)].map((m) => m[1]) : null;
}

/** Pairs a Map literal's strings into [key, value] entries. */
const pairs = (strings) =>
	strings
		? Array.from({ length: strings.length / 2 }, (_, i) => strings.slice(2 * i, 2 * i + 2))
		: [];

// ==================================================
// ==================================================
// ======= 1/ Every criterion asks its slot =========
// ==================================================
// ==================================================

const registrar = functionBody('_RegisterScriptAltGrHotkeys');
check(registrar !== '', '_RegisterScriptAltGrHotkeys must be defined');
const criteria = [...registrar.matchAll(/HotIf\(([^\n]*)\)\s*$/gm)]
	.map((m) => m[1].trim())
	.filter((arg) => arg !== '');
check(criteria.length > 0, 'the script chord registrar must register under a #HotIf criterion');

const plan = functionBody('ScriptAltGrChordPlan');
const bound = [...plan.matchAll(/"criterion",\s*([A-Za-z_]\w*)\.Bind\(Slot\)/g)].map((m) => m[1]);
for (const criterion of criteria) {
	if (/^\(.*\)\s*=>/.test(criterion)) {
		check(
			/ScriptShortcutSlotRunsAction\(/.test(criterion),
			`the script chords registered under "${criterion}" never ask whether their slot runs ` +
				'an action: an unassigned slot still takes AltGr+<key> and RunScriptShortcutAction ' +
				'retypes the bare key (script-chord-slot-2026-09-30)'
		);
		continue;
	}
	check(
		/^Row\["criterion"\]$/.test(criterion) && /ScriptAltGrChordPlan\(/.test(registrar),
		`the script chord criterion "${criterion}" must come from ScriptAltGrChordPlan`
	);
}
if (criteria.some((criterion) => /^Row\["criterion"\]$/.test(criterion))) {
	check(bound.length === 3, `the plan must bind three criteria per slot, found ${bound.length}`);
	for (const name of bound) {
		const body = functionBody(name);
		check(body !== '', `the plan's criterion ${name} must be defined`);
		check(
			/^\w+\(Slot, \*\)/.test(body) && /ScriptShortcutSlotRunsAction\(Slot\)/.test(body),
			`${name} must take the slot it is bound to and ask ScriptShortcutSlotRunsAction(Slot)`
		);
	}
}

// ==================================================
// ==================================================
// ======= 2/ Three hotkeys for every slot ==========
// ==================================================
// ==================================================

const { parse } = require('smol-toml');
const manifest = parse(
	read(path.join(SP, '_shared', 'modules', 'features', 'manifest.toml')).replace(
		/^\[\[features\.([^\]]+)\]\]$/gm,
		(_match, section) => `[[entries]]\nsection = "${section}"`
	)
);
const manifestSlots = manifest.entries
	.filter(
		(e) =>
			e.section === 'shortcuts.script_control' &&
			e.type === 'action' &&
			(e.platforms || []).includes('ahk')
	)
	.map((e) => e.id)
	.sort();
check(
	manifestSlots.length === 4,
	`the manifest must declare four Windows script slots, found ${manifestSlots.length}`
);

const featureState = path.join(WIN, 'infra', 'feature_state.ahk');
const slots = globalLiteral(featureState, 'SCRIPT_SHORTCUT_SLOTS') || [];
const fallbacks = new Map(pairs(globalLiteral(featureState, 'SCRIPT_SHORTCUT_FALLBACKS')));
const scanCodes = new Map(pairs(globalLiteral(featureState, 'SCRIPT_SHORTCUT_SCAN_CODES')));
check(
	JSON.stringify([...slots].sort()) === JSON.stringify(manifestSlots),
	`SCRIPT_SHORTCUT_SLOTS [${slots}] must be the manifest's Windows script slots [${manifestSlots}]`
);

// The key each slot names, through the shared physical-key registry.
const registry = JSON.parse(
	read(path.join(SP, '_shared', 'data', 'keycodes', 'physical_keys.json'))
);
const byName = new Map();
for (const record of Object.values(registry.keys)) {
	if (record.kind === 'key' && record.ahk_send && /^SC[0-9A-F]{3}$/.test(record.ahk))
		byName.set(record.ahk_send.toLowerCase(), record.ahk);
}
for (const slot of manifestSlots) {
	const key = slot.replace(/^script_altgr_/, '');
	const expected = byName.get(key);
	check(expected !== undefined, `the physical-key registry must name the ${key} key of ${slot}`);
	check(
		scanCodes.get(slot) === expected,
		`SCRIPT_SHORTCUT_SCAN_CODES must bind ${slot} to ${expected}, found ${scanCodes.get(slot)}`
	);
	check(
		(fallbacks.get(slot) || '').toLowerCase() === `{${key}}`,
		`SCRIPT_SHORTCUT_FALLBACKS must give ${slot} back as {${key}}, found ${fallbacks.get(slot)}`
	);
}
check(
	/"hotkey", "SC138 & " \. Sc/.test(plan) &&
		/"hotkey", "\$" \. Sc/.test(plan) &&
		/"hotkey", "\$\*" \. Sc/.test(plan),
	'ScriptAltGrChordPlan must register the SC138 combination, the Kana twin and the paused twin of each slot'
);

// ==================================================
// ==================================================
// ======= 3/ The gate and the dispatcher ===========
// ==================================================
// ==================================================

const gate = functionBody('ScriptShortcutSlotRunsAction');
check(gate !== '', 'ScriptShortcutSlotRunsAction must be defined');
check(
	/Action == "none"[^\n]*\n\s*return false/.test(gate),
	'ScriptShortcutSlotRunsAction must leave an unassigned slot to the system'
);
check(
	/SCRIPT_SHORTCUT_SUSPEND_ALLOWED\.Has\(Action\)/.test(gate) && /Suspended/.test(gate),
	'ScriptShortcutSlotRunsAction must scope a paused chord to the script-management actions'
);
const run = functionBody('RunScriptShortcutAction');
const admitted = run.indexOf('ScriptShortcutSlotRunsAction(Slot)');
check(
	admitted > 0 && admitted < run.indexOf('GestureInvokeAction('),
	'RunScriptShortcutAction must ask ScriptShortcutSlotRunsAction before invoking the action'
);
check(
	!/SendInput\(/.test(run) || /LoggerWarn\([^\n]*\n?[^\n]*\n?\s*SendInput\(/.test(run),
	'RunScriptShortcutAction must log before it gives a chord key back: a silent retype hid this bug'
);

// ==================================================
// ==================================================
// ======= 4/ The submenu and its switch ============
// ==================================================
// ==================================================

// The maintainer's first group (2026-09-30): the switch, the restore, the clear,
// a separator, then the slots; the Shortcuts submenu ticks the group's title
// from the same getter as the switch, so the tick can always be changed.
const menu = JSON.parse(read(path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json')));
const group = (menu.script_control_group || []).map((row) => `${row.type}:${row.id || ''}`);
check(
	JSON.stringify(group) ===
		JSON.stringify([
			'toggle:script_control_toggle',
			'command:scope_restore',
			'command:scope_clear',
			'---:',
			'list:script_control_shortcuts'
		]),
	`script_control_group must be switch, restore, clear, separator, slots; found [${group}]`
);
const parent = (menu.shortcuts_menu || []).find((row) => row.id === 'script_control');
const toggle = (menu.script_control_group || [])[0] || {};
check(
	parent !== undefined &&
		parent.type === 'group' &&
		JSON.stringify(parent.checked_when) === JSON.stringify(toggle.checked_when) &&
		Array.isArray(toggle.checked_when) &&
		toggle.checked_when.length === 1,
	'the Shortcuts submenu must tick the script-control title from the switch getter'
);
check(
	!(menu.shortcuts_menu || []).some((row) => row.id === 'script_control_shortcuts'),
	'the slots belong to script_control_group, not to a bare Shortcuts row without a switch'
);
const menuSource = functionBody('_SC_ScriptControlCommands');
for (const id of ['script_control_toggle', 'scope_restore', 'scope_clear']) {
	check(menuSource.includes(`"${id}",`), `_SC_ScriptControlCommands must register ${id}`);
}
check(
	functionBody('_SC_Getters').includes(
		'"script_control_enabled", () => ScriptShortcutChordsAreOn()'
	) &&
		functionBody('_SC_ScriptControlSubmenu').includes(
			'"script_control_enabled", () => ScriptShortcutChordsAreOn()'
		),
	'the title and the switch must read the same switch state'
);
const gateOn = gate.indexOf('ScriptShortcutChordsAreOn()');
check(
	gateOn > 0 && gateOn < gate.indexOf('ScriptShortcutAssignments[Slot]'),
	'ScriptShortcutSlotRunsAction must leave every chord to the system while the switch is off'
);
const scopeRows = functionBody('ScriptShortcutScopeRows');
check(
	/Mode == "clear" \? "none"/.test(scopeRows),
	'the clear must write "none" explicitly: deleting the key would restore the preset'
);

// ==================================================
// ==================================================
// ======= 5/ The AHK regression tests run ==========
// ==================================================
// ==================================================

const runAll = read(path.join(WIN, 'tests', 'run_all.ahk'));
for (const test of ['test_script_chords_follow_their_slot', 'test_script_control_submenu']) {
	check(
		new RegExp(`^#Include unit/${test}\\.ahk$`, 'm').test(runAll),
		`run_all.ahk must include unit/${test}.ahk`
	);
}

if (errors.length > 0) {
	for (const e of errors) console.error(`  FAIL  ${e}`);
	console.error(
		`\n[windows-script-chords-follow-their-slot] ${errors.length} of ${checks} check(s) failed.`
	);
	process.exit(1);
}
console.log(
	`[windows-script-chords-follow-their-slot] ${checks} checks: every script chord belongs to the driver only while its slot runs an action.`
);
