// tools/codegen/codegen-touchpad-registry.cjs

/**
 * ==============================================================================
 * MODULE: Precision Touchpad Registry Codegen
 * DESCRIPTION:
 * Emits windows/modules/gestures/precision_touchpad_registry.toml as the data
 * both Windows touchpad writers read: the in-process registry writer and the
 * elevated PowerShell script of the first-run wizard.
 *
 * WHY THIS EXISTS:
 * The wizard's PowerShell script carried its own hand-typed copy of every value
 * name and every KeyParams number, "kept in sync" by a comment with the maps in
 * modules/gestures/init.ahk. Two copies of a registry contract drift, and the
 * one Ergopti writes first is the one a restore must undo. A compiled AHK build
 * has no TOML reader at include time, so it gets a generated copy; the TOML file
 * stays the only place a value is written by hand. The KeyParams numbers are
 * derived here from the function key and the modifier mask, never typed.
 *
 * USAGE:  node tools/codegen/codegen-touchpad-registry.cjs
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const SOURCE = path.join(SP, 'windows', 'modules', 'gestures', 'precision_touchpad_registry.toml');
const AHK_OUTPUT = path.join(SP, 'windows', '_generated', 'touchpad_registry.ahk');
const RUN_HINT = 'npm run codegen:touchpad-registry';

// The registry root the key must live under, and its PowerShell drive spelling.
const REGISTRY_ROOT = 'HKEY_CURRENT_USER\\';
const POWERSHELL_ROOT = 'HKCU:\\';
// F1 is virtual key 0x70, so function key n is 0x6F + n.
const VK_BEFORE_F1 = 0x6f;
const MAX_FUNCTION_KEY = 24;
const MAX_DWORD = 0xffffffff;
// Registry value names are plain identifiers here; anything else is a typo.
const VALUE_NAME = /^[A-Za-z]+$/;

// ==========================================
// ==========================================
// ======= 1/ Validation ===================
// ==========================================
// ==========================================

/** A DWORD, refused otherwise so a malformed value cannot reach the registry. */
function dword(value, name) {
	if (!Number.isInteger(value) || value < 0 || value > MAX_DWORD)
		throw new Error(`${name} must be a REG_DWORD, got ${JSON.stringify(value)}`);
	return value;
}

/** A registry value name, refused unless it is a plain identifier. */
function valueName(value, where) {
	if (typeof value !== 'string' || !VALUE_NAME.test(value))
		throw new Error(`${where} must be a registry value name, got ${JSON.stringify(value)}`);
	return value;
}

/**
 * Validates the decoded TOML and derives the ordered write list.
 * @param {Object} data - Decoded precision_touchpad_registry.toml.
 * @return {Object} The normalized registry contract.
 */
function buildContract(data) {
	if (typeof data.key !== 'string' || !data.key.startsWith(REGISTRY_ROOT))
		throw new Error(`key must live under ${REGISTRY_ROOT}`);
	const relative = data.key.slice(REGISTRY_ROOT.length);
	if (data.powershell_key !== POWERSHELL_ROOT + relative)
		throw new Error('powershell_key must name the same key as key');
	const customValue = dword(data.custom_value, 'custom_value');
	const customTapValue = dword(data.custom_tap_value, 'custom_tap_value');
	const modifiers = dword(data.key_params_modifiers, 'key_params_modifiers');

	const names = new Set();
	const claim = (name, where) => {
		valueName(name, where);
		if (names.has(name)) throw new Error(`${where}: value ${name} is written twice`);
		names.add(name);
		return name;
	};
	const values = [];
	const families = new Map();
	for (const family of data.families || []) {
		if (typeof family.id !== 'string' || families.has(family.id))
			throw new Error(`family id ${JSON.stringify(family.id)} is missing or duplicated`);
		families.set(family.id, claim(family.enable, `family ${family.id}`));
		values.push({ name: family.enable, value: customValue });
	}
	if (families.size === 0) throw new Error('at least one gesture family is required');

	const slots = [];
	for (const slot of data.slots || []) {
		const where = `slot ${slot.id}`;
		if (typeof slot.id !== 'string' || slots.some((other) => other.id === slot.id))
			throw new Error(`${where}: id is missing or duplicated`);
		if (!families.has(slot.family)) throw new Error(`${where}: unknown family ${slot.family}`);
		if ((slot.custom_tap === undefined) === (slot.enable === undefined))
			throw new Error(`${where}: needs exactly one of custom_tap (tap) or enable (swipe)`);
		if (
			!Number.isInteger(slot.function_key) ||
			slot.function_key < 1 ||
			slot.function_key > MAX_FUNCTION_KEY
		)
			throw new Error(`${where}: function_key must be 1..${MAX_FUNCTION_KEY}`);
		const keyParams = dword(
			((VK_BEFORE_F1 + slot.function_key) << 16) | modifiers,
			`${where} key params`
		);
		const entry = {
			id: slot.id,
			familyEnable: families.get(slot.family),
			functionKey: slot.function_key,
			keyParamsName: claim(slot.key_params, `${where} key_params`),
			keyParams,
			action: claim(slot.action, `${where} action`)
		};
		if (slot.enable !== undefined) {
			entry.enable = claim(slot.enable, `${where} enable`);
			values.push({ name: entry.enable, value: customValue });
		} else {
			entry.customTap = claim(slot.custom_tap, `${where} custom_tap`);
			values.push({ name: entry.customTap, value: customTapValue });
		}
		values.push({ name: entry.keyParamsName, value: keyParams });
		values.push({ name: entry.action, value: customValue });
		slots.push(entry);
	}
	if (slots.length === 0) throw new Error('at least one gesture slot is required');
	return {
		key: data.key,
		powershellKey: data.powershell_key,
		customValue,
		customTapValue,
		familyEnables: [...families.values()],
		slots,
		values
	};
}

// ==========================================
// ==========================================
// ======= 2/ Emitters =====================
// ==========================================
// ==========================================

/** An AHK v2 double-quoted string literal (backtick is the escape character). */
function ahkStr(value) {
	return '"' + String(value).replace(/`/g, '``').replace(/"/g, '`"') + '"';
}

/** One AHK Map literal from ordered [key, literal] pairs. */
function ahkMap(pairs) {
	return 'Map(' + pairs.map(([key, literal]) => `${ahkStr(key)}, ${literal}`).join(', ') + ')';
}

function emitAhk(contract) {
	const slotMaps = contract.slots
		.map((slot) => {
			const pairs = [
				['family_enable', ahkStr(slot.familyEnable)],
				['function_key', String(slot.functionKey)],
				['key_params_name', ahkStr(slot.keyParamsName)],
				['key_params', String(slot.keyParams)],
				['action', ahkStr(slot.action)]
			];
			if (slot.enable) pairs.push(['enable', ahkStr(slot.enable)]);
			if (slot.customTap) pairs.push(['custom_tap', ahkStr(slot.customTap)]);
			return `\t\t\t${ahkStr(slot.id)}, ${ahkMap(pairs)}`;
		})
		.join(',\n');
	const values = contract.values
		.map(
			(entry) =>
				`\t\t\t${ahkMap([
					['name', ahkStr(entry.name)],
					['value', String(entry.value)]
				])}`
		)
		.join(',\n');
	return (
		'﻿; _generated/touchpad_registry.ahk\n' +
		'; AUTO-GENERATED from windows/modules/gestures/precision_touchpad_registry.toml.\n' +
		`; DO NOT EDIT BY HAND — run \`${RUN_HINT}\` to refresh.\n` +
		'#Requires AutoHotkey v2.0\n' +
		'\n' +
		'; ==============================================================================\n' +
		'; MODULE: Precision Touchpad Registry Data (Windows)\n' +
		'; DESCRIPTION:\n' +
		'; Every registry value Ergopti writes so each gesture slot sends its\n' +
		'; Ctrl + Win + Shift + Fn shortcut, in write order. The in-process writer and\n' +
		"; the first-run wizard's elevated PowerShell script both read this data, and\n" +
		'; modules/gestures/touchpad_registry.ahk backs it up and restores it.\n' +
		'; ==============================================================================\n' +
		'\n' +
		'; A function rather than a global initialiser so include ORDER cannot matter:\n' +
		'; the first-run wizard reads it before modules/gestures/init.ahk runs. Each\n' +
		'; call returns fresh maps, so no caller can alter what another one reads.\n' +
		'TouchpadRegistryData() {\n' +
		'\treturn Map(\n' +
		`\t\t"key", ${ahkStr(contract.key)},\n` +
		`\t\t"powershell_key", ${ahkStr(contract.powershellKey)},\n` +
		`\t\t"custom_value", ${contract.customValue},\n` +
		`\t\t"custom_tap_value", ${contract.customTapValue},\n` +
		`\t\t"family_enables", [${contract.familyEnables.map(ahkStr).join(', ')}],\n` +
		`\t\t"slot_ids", [${contract.slots.map((slot) => ahkStr(slot.id)).join(', ')}],\n` +
		'\t\t"slots", Map(\n' +
		slotMaps +
		'\n\t\t),\n' +
		'\t\t"values", [\n' +
		values +
		'\n\t\t])\n' +
		'}\n'
	);
}

// ==========================================
// ==========================================
// ======= 3/ Public API & Main ============
// ==========================================
// ==========================================

/**
 * Renders every generated artifact of the registry contract without writing.
 * @param {Object} data - Decoded precision_touchpad_registry.toml.
 * @return {{path: string, content: string}[]}
 */
function renderOutputs(data) {
	return [{ path: AHK_OUTPUT, content: emitAhk(buildContract(data)) }];
}

async function main() {
	const { parse } = await import('smol-toml');
	const data = parse(fs.readFileSync(SOURCE, 'utf8'));
	for (const output of renderOutputs(data)) {
		fs.mkdirSync(path.dirname(output.path), { recursive: true });
		// LF everywhere, per the repository's source-encoding rule; the AHK payload
		// already carries its required UTF-8 BOM as the first character.
		fs.writeFileSync(output.path, output.content.replace(/\r\n/g, '\n'), 'utf8');
		console.log(`  wrote ${path.relative(ROOT, output.path).split(path.sep).join('/')}`);
	}
	console.log(`[OK] touchpad registry generated: ${buildContract(data).values.length} value(s).`);
}

if (require.main === module) {
	main().catch((error) => {
		console.error(`[ERROR] ${error.message}`);
		process.exit(1);
	});
}

module.exports = { buildContract, renderOutputs, SOURCE };
