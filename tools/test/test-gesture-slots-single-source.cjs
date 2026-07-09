// tools/test/test-gesture-slots-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Gesture Slot-Space Single-Source Guard
 * DESCRIPTION:
 * The gesture slot key-space (tap/swipe slot names) is identical on every driver:
 * a gesture bound on one platform must name the same slot on the other. This gate
 * pins the Linux and macOS gesture managers to the single declared slot-space in
 * _shared/modules/gestures/actions.toml [slots] so the two lists can never drift.
 * It also asserts each driver's DEFAULT_GESTURES key-space equals single + axis;
 * only the mapped action VALUES are allowed to differ per platform (not checked).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');
function read(rel) { return fs.readFileSync(path.join(SP, rel), 'utf8'); }

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

// Bareword keys of the DEFAULT_GESTURES table.
function defaultKeys(src, file) {
	const m = src.match(/M\.DEFAULT_GESTURES\s*=\s*\{([\s\S]*?)\n\}/);
	if (!m) throw new Error('could not find M.DEFAULT_GESTURES in ' + file);
	return [...m[1].matchAll(/^\s*([a-z0-9_]+)\s*=/gm)].map((x) => x[1]);
}

function eqOrdered(a, b) { return a.length === b.length && a.every((v, i) => v === b[i]); }

const errors = [];
try {
	const toml = read('_shared/modules/gestures/actions.toml');
	const single = tomlSlotArray(toml, 'single');
	const axis = tomlSlotArray(toml, 'axis');
	const union = new Set([...single, ...axis]);
	if (single.length + axis.length !== union.size) {
		errors.push('actions.toml [slots] single/axis overlap or contain duplicates');
	}

	const drivers = [
		{ name: 'linux', file: 'linux/modules/gestures/manager.lua' },
		{ name: 'macos', file: 'macos/modules/gestures/init.lua' },
	];
	for (const d of drivers) {
		const src = read(d.file);
		if (!eqOrdered(luaSlotArray(src, 'SINGLE_SLOTS', d.file), single)) {
			errors.push(d.name + ' SINGLE_SLOTS != actions.toml [slots].single');
		}
		if (!eqOrdered(luaSlotArray(src, 'AXIS_SLOTS', d.file), axis)) {
			errors.push(d.name + ' AXIS_SLOTS != actions.toml [slots].axis');
		}
		const keys = defaultKeys(src, d.file);
		const keyset = new Set(keys);
		if (keys.length !== keyset.size) errors.push(d.name + ' DEFAULT_GESTURES has duplicate keys');
		const missing = [...union].filter((s) => !keyset.has(s));
		const extra = [...keyset].filter((s) => !union.has(s));
		if (missing.length) errors.push(d.name + ' DEFAULT_GESTURES missing slot(s): ' + missing.join(', '));
		if (extra.length) errors.push(d.name + ' DEFAULT_GESTURES has unknown slot(s): ' + extra.join(', '));
	}
} catch (e) {
	errors.push(e.message);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Gesture slot-space is not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log('\x1b[32m[OK] Gesture slot-space single source — Linux + macOS SINGLE_SLOTS/AXIS_SLOTS and DEFAULT_GESTURES key-space match actions.toml [slots].\x1b[0m');
