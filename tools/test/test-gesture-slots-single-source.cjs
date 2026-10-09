// tools/test/test-gesture-slots-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Gesture Slot-Space Single-Source Guard
 * DESCRIPTION:
 * The gesture slot key-space (tap/swipe slot names) is identical on every driver:
 * a gesture bound on one platform must name the same slot on the other. The single
 * declared slot-space lives in _shared/modules/actions/actions.toml [slots]. The
 * Linux manager takes its lists from its generated action catalogue (this gate
 * checks the generated lists equal the TOML in order, and that the manager reads
 * them rather than re-hardcoding them; the Linux Lua suite proves the loaded lists
 * match at runtime). macOS still hardcodes the lists, so this gate
 * pins the macOS literals to the TOML and asserts its DEFAULT_GESTURES key-space
 * equals single + axis; only the mapped action VALUES may differ per platform.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');
function read(rel) {
	return fs.readFileSync(path.join(SP, rel), 'utf8');
}

// Ordered string list from the [slots] section's `key = [ "a", "b", … ]` array.
function tomlSlotArray(src, key) {
	const sec = src.match(/\n\[slots\]\s*\n([\s\S]*?)(?:\n\[|$)/);
	if (!sec) throw new Error('could not find [slots] section in actions.toml');
	const m = sec[1].match(new RegExp(key + '\\s*=\\s*\\[([\\s\\S]*?)\\]'));
	if (!m) throw new Error('could not find [slots].' + key + ' array in actions.toml');
	return [...m[1].matchAll(/"([a-z0-9_]+)"/g)].map((x) => x[1]);
}

// Ordered Lua array `M.NAME = { "a", "b", … }`.
function luaSlotArray(src, name, file) {
	const m = src.match(new RegExp('M\\.' + name + '\\s*=\\s*\\{([\\s\\S]*?)\\}'));
	if (!m) throw new Error('could not find M.' + name + ' in ' + file);
	return [...m[1].matchAll(/"([a-z0-9_]+)"/g)].map((x) => x[1]);
}

function eqOrdered(a, b) {
	return a.length === b.length && a.every((v, i) => v === b[i]);
}

const errors = [];
try {
	const toml = read('_shared/modules/actions/actions.toml');
	const single = tomlSlotArray(toml, 'single');
	const axis = tomlSlotArray(toml, 'axis');
	const union = new Set([...single, ...axis]);
	if (single.length + axis.length !== union.size) {
		errors.push('actions.toml [slots] single/axis overlap or contain duplicates');
	}

	// Native two-finger OS gestures remain unassigned until the user explicitly binds one.
	{
		const parse = require('smol-toml').parse;
		const source = read('_shared/modules/features/manifest.toml');
		const manifest = parse(
			source.replace(
				/^\[\[features\.([^\]]+)\]\]\r?$/gm,
				(_, section) => `[[entries]]\npath_prefix = "${section}"`
			)
		);
		const expected = [
			'tap_2',
			'swipe_2_left',
			'swipe_2_right',
			'swipe_2_up',
			'swipe_2_down',
			'swipe_2_left_up',
			'swipe_2_right_up',
			'swipe_2_left_down',
			'swipe_2_right_down',
			'swipe_2_diag'
		];
		const rows = manifest.entries.filter(
			(row) =>
				row.path_prefix === 'gestures' &&
				row.type === 'action' &&
				(row.id === 'tap_2' || row.id.startsWith('swipe_2_'))
		);
		if (
			rows.length !== expected.length ||
			expected.some((id) => rows.filter((row) => row.id === id).length !== 1)
		)
			errors.push('canonical two-finger action inventory must be complete and unique');
		for (const row of rows) {
			if (row.default !== 'none')
				errors.push(`${row.id}: startup must leave two-finger actions unassigned`);
			for (const platform of row.platforms) {
				const value = row.recommended_per_platform?.[platform] ?? row.recommended;
				if (value !== 'none')
					errors.push(
						`${row.id}: ${platform} recommendation must preserve native two-finger gestures`
					);
			}
		}
	}

	// macOS still hardcodes the slot arrays (deriving them would need an
	// unverifiable Hammerspoon reload), so its literals are pinned to the TOML.
	{
		const file = 'macos/modules/gestures/init.lua';
		const src = read(file);
		if (!eqOrdered(luaSlotArray(src, 'SINGLE_SLOTS', file), single)) {
			errors.push('macos SINGLE_SLOTS != actions.toml [slots].single');
		}
		if (!eqOrdered(luaSlotArray(src, 'AXIS_SLOTS', file), axis)) {
			errors.push('macos AXIS_SLOTS != actions.toml [slots].axis');
		}
		if (
			!/for _, slots in ipairs\(\{ M\.SINGLE_SLOTS, M\.AXIS_SLOTS \}\) do/.test(src) ||
			!src.includes('M.DEFAULT_GESTURES[slot] = Manifest.default_for("gestures." .. slot)')
		) {
			errors.push('macos must project both complete slot lists through the manifest');
		}
		for (const driver of ['macos', 'linux']) {
			const manifest = read(`${driver}/_generated/features_manifest.lua`);
			for (const slot of union) {
				if (!manifest.includes(`path = "gestures.${slot}"`)) {
					errors.push(`${driver} manifest has no owned default for ${slot}`);
				}
			}
		}
	}

	// Linux takes the slot arrays from linux/_generated/action_catalogue.lua,
	// which tools/codegen/codegen-action-catalogue.cjs writes from [slots]. Pin
	// the generated lists to the TOML in order, and assert the manager reads
	// them and never re-hardcodes the lists.
	{
		const generated = read('linux/_generated/action_catalogue.lua');
		const slots = generated.match(
			/\n\tslots = \{\n\t\tsingle = \{([^}]*)\},\n\t\taxis = \{([^}]*)\},/
		);
		if (!slots) {
			errors.push('linux/_generated/action_catalogue.lua carries no slots table');
		} else {
			const names = (body) => [...body.matchAll(/"([a-z0-9_]+)"/g)].map((x) => x[1]);
			if (!eqOrdered(names(slots[1]), single))
				errors.push('generated Linux slots.single != actions.toml [slots].single');
			if (!eqOrdered(names(slots[2]), axis))
				errors.push('generated Linux slots.axis != actions.toml [slots].axis');
		}
		const file = 'linux/modules/gestures/manager.lua';
		const src = read(file);
		if (
			!src.includes('M.SINGLE_SLOTS = copy_list(Catalogue.slots.single)') ||
			!src.includes('M.AXIS_SLOTS = copy_list(Catalogue.slots.axis)')
		) {
			errors.push('linux manager must take SINGLE_SLOTS/AXIS_SLOTS from the generated catalogue');
		}
		if (!src.includes('require, "_generated.action_catalogue"')) {
			errors.push('linux manager must load _generated/action_catalogue.lua');
		}
		if (/M\.SINGLE_SLOTS\s*=\s*\{\s*"/.test(src) || /M\.AXIS_SLOTS\s*=\s*\{\s*"/.test(src)) {
			errors.push('linux manager re-hardcodes SINGLE_SLOTS/AXIS_SLOTS instead of deriving them');
		}
	}
} catch (e) {
	errors.push(e.message);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Gesture slot-space is not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] Gesture slot-space single source — Linux takes the generated [slots]; macOS literals + DEFAULT_GESTURES key-space match it.\x1b[0m'
);
