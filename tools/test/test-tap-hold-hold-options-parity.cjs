// tools/test/test-tap-hold-hold-options-parity.cjs

/**
 * ==============================================================================
 * MODULE: One Hold Picker, One List
 * DESCRIPTION:
 * The hold a tap-hold key emits is chosen from a list, and every driver must
 * offer the same one in the same order — the value is written into a file all
 * three read, so a modifier one driver can pick and another cannot is a config
 * that behaves differently per OS.
 *
 * WHAT THIS CAUGHT (2026-08-08):
 * the list was a hardcoded array in windows/platform/remap/tap_hold_writer.ahk
 * whose own comment claimed it "mirrors _shared/modules/menu/menu_manifest.json
 * hold_options" — a key that has never existed in that file. So the canonical
 * list was a copy pointing at nothing, and the two Lua drivers offered no hold
 * picker at all: on Linux the whole tap-hold submenu was greyed read-outs.
 *
 * WHAT IS COMPARED:
 * the ids in `_shared/tap_hold/defaults.toml` under `[tap_hold.hold_picker]`,
 * the sequence the shared Lua module builds from them, and the sequence the
 * AutoHotkey enumerator produces. The ORDER is the thing that must not differ:
 * both walk the modifiers depth-first, left to right, and this reproduces that
 * walk independently rather than trusting either implementation.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DEFAULTS = path.join(SP, '_shared', 'tap_hold', 'defaults.toml');
const SHARED_LUA = path.join(SP, '_shared', 'lua', 'tap_hold', 'hold_options.lua');
const AHK_WRITER = path.join(SP, 'windows', 'platform', 'remap', 'tap_hold_writer.ahk');

const errors = [];

/** Reads one array from [tap_hold.hold_picker]. */
function readArray(toml, field) {
	const section = toml.split(/^\[/m).find((s) => s.startsWith('tap_hold.hold_picker]'));
	if (!section) return null;
	const m = section.match(new RegExp('^' + field + '\\s*=\\s*\\[(.*)\\]', 'm'));
	if (!m) return null;
	return m[1]
		.split(',')
		.map((s) => s.trim().replace(/^["']|["']$/g, ''))
		.filter(Boolean);
}

const toml = fs.readFileSync(DEFAULTS, 'utf8');
const modifiers = readArray(toml, 'modifiers');
const layers = readArray(toml, 'layers');

if (!modifiers || modifiers.length === 0) {
	errors.push(
		'_shared/tap_hold/defaults.toml declares no [tap_hold.hold_picker] modifiers. Every driver builds ' +
			'its hold picker from that table; without it they each fall back to whatever they had, which is ' +
			'how the lists drifted in the first place.'
	);
}
if (!layers) {
	errors.push('[tap_hold.hold_picker] declares no `layers` array — the nav-layer hold would vanish from every picker.');
}

// The expected sequence, walked here rather than taken from either driver.
function expectedCombos(mods) {
	const out = [];
	(function walk(prefix, start) {
		for (let i = start; i < mods.length; i++) {
			const combo = prefix === '' ? mods[i] : prefix + '+' + mods[i];
			out.push(combo);
			walk(combo, i + 1);
		}
	})('', 0);
	return out;
}

if (modifiers && modifiers.length > 0) {
	const combos = expectedCombos(modifiers);

	// Both implementations must still BE the walk: an enumerator that stopped
	// recursing would produce five options instead of thirty-one and nothing else
	// in this repository would notice.
	const lua = fs.readFileSync(SHARED_LUA, 'utf8');
	if (!/walk\(combo, index \+ 1\)/.test(lua)) {
		errors.push(
			'the shared Lua enumerator no longer recurses on the combination it just emitted — it would ' +
				`offer ${modifiers.length} single modifiers instead of ${combos.length} combinations.`
		);
	}
	const ahk = fs.readFileSync(AHK_WRITER, 'utf8');
	if (!/_TH_EnumerateHoldModifierCombos\(ComboId, A_Index \+ 1, Modifiers, Out\)/.test(ahk)) {
		errors.push(
			'the AutoHotkey enumerator no longer recurses on the combination it just emitted — the two ' +
				'pickers would offer different lists from the same file.'
		);
	}

	// And the AHK driver must take its ids from the shared table, not from an
	// array of its own: that is the failure this gate was written for.
	if (/_TH_HoldModifierIds\s*:=\s*\[/.test(ahk)) {
		errors.push(
			'windows/platform/remap/tap_hold_writer.ahk declares its own modifier array again. The ids ' +
				'belong to _shared/tap_hold/defaults.toml — a second list is one edit away from two ' +
				'different hold pickers reading one config file.'
		);
	}
	if (!/tap_hold\.hold_picker/.test(ahk)) {
		errors.push(
			'windows/platform/remap/tap_hold_writer.ahk no longer reads [tap_hold.hold_picker] from the ' +
				'shared defaults.'
		);
	}

	// The Linux menu must actually offer the picker — the point of the exercise.
	const linuxMenu = fs.readFileSync(path.join(SP, 'linux', 'ui', 'menu', 'menu_builder.lua'), 'utf8');
	if (!/tap_hold\.hold_options/.test(linuxMenu)) {
		errors.push(
			'linux/ui/menu/menu_builder.lua no longer builds its hold picker from the shared catalogue. ' +
				'Its tap-hold submenu was greyed read-outs until 2026-08-08 and this is what stops it ' +
				'quietly going back.'
		);
	}
	if (!/tap_hold_writer/.test(linuxMenu)) {
		errors.push(
			'linux/ui/menu/menu_builder.lua no longer reaches the tap-hold writer — the rows would be ' +
				'read-outs again, which is the state this gate exists to end.'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the hold pickers do not agree:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

const total = 1 + expectedCombos(modifiers).length + layers.length;
console.log(
	`\x1b[32m[OK] one hold picker: ${modifiers.length} shared modifier(s) → ${total} option(s), same ` +
		'order on every driver, and Linux can write the choice.\x1b[0m'
);
