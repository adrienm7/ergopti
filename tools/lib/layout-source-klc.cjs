// tools/lib/layout-source-klc.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source KLC Export
 * DESCRIPTION:
 * Admits imported mappings through the shared reader and delegates character,
 * Caps Lock, dead-key and ligature generation to the existing Windows owner.
 * Returns MSKLC bytes and a source-specific report before any publication.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { shared } = require('./paths.cjs');
const { loadLayoutSource } = require('./layout-source.cjs');
const Windows = require('../codegen/lib/windows-keyboard-layout.cjs');

// The source schema has no release-version field. New editable MSKLC artifacts
// start at this explicit version; it is unrelated to the TOML schema version.
const KLC_ARTIFACT_VERSION = '1.0.0';
const controls = /[\u0000-\u001f\u007f-\u009f]/u;
// kbd.h reserves these WCHAR values for absent/dead/ligature table entries.
const reservedWchar = /[\uf000-\uf002]/u;
const asList = (value) => (Array.isArray(value) ? value : []);

/** Refuse unsupported source behavior with details retained by target reports. */
function refuse(reason, details) {
	const error = new Error(reason);
	if (details !== undefined) error.details = details;
	throw error;
}

/** Decode only the shared parser's admitted conversion form. */
function readCanonical(xml) {
	const result = spawnSync('lua', [path.join(__dirname, 'layout_source_read.lua'), shared()], {
		input: JSON.stringify({ xml }),
		encoding: 'utf8',
		timeout: 30000,
		maxBuffer: 16 * 1024 * 1024
	});
	if (result.error) refuse(`klc_runtime: ${result.error.message}`);
	if (result.status !== 0) refuse(`klc_runtime: ${result.stderr.trim()}`);
	const decoded = JSON.parse(result.stdout);
	if (!decoded.ok) refuse(decoded.reason);
	return decoded.canonical;
}

/** Metadata goes into quoted KLC/C-family fields of the established generator. */
function quoted(value, field) {
	if (typeof value !== 'string' || /["\\\u0000-\u001f\u007f-\u009f]/u.test(value))
		refuse(`${field}: unsupported quoted metadata`);
	return value;
}

/** Create native character files without installing or reserving a Windows KLID. */
function exportKlc(document) {
	const imported = loadLayoutSource().conversionSource(document);
	const metadata = document.exports?.windows;
	if (!metadata || !metadata.locale || !metadata.layout_id || !metadata.dll_name)
		refuse('exports.windows requires locale, layout_id and dll_name');
	if (!/^[a-z][a-z0-9]{0,7}$/.test(metadata.dll_name))
		refuse('exports.windows.dll_name must contain 1 to 8 lowercase letters/digits');
	// KLC carries a language LCID, not an installer's custom A0nn keyboard-layout ID.
	if (!/^0000[0-9a-fA-F]{4}$/.test(metadata.layout_id) || metadata.layout_id === '00000000')
		refuse(
			'exports.windows.layout_id must be a nonzero language LCID (0000xxxx); custom KLIDs require an installer'
		);
	const locale = quoted(metadata.locale, 'exports.windows.locale');
	try {
		new Intl.Locale(locale);
	} catch {
		refuse('exports.windows.locale must be a language tag');
	}
	const name = quoted(document.layout.name, 'layout.name');
	const author = quoted(document.layout.author ?? '', 'layout.author');
	const description = quoted(document.layout.description ?? name, 'layout.description');
	const canonical = readCanonical(imported.text);
	const keycodes = JSON.parse(
		fs.readFileSync(shared('modules', 'layouts', 'mac_keycodes.json'), 'utf8')
	);
	const physicalKeys = JSON.parse(
		fs.readFileSync(shared('data', 'keycodes', 'physical_keys.json'), 'utf8')
	);
	const physical = keycodes.keys.map((key) => ({
		code: key.code,
		mac: typeof key.mac === 'object' ? key.mac[imported.convention] : key.mac
	}));
	const placed = new Set(physical.map((key) => key.mac));
	const untouched = new Map();
	for (const set of asList(canonical.key_map_sets))
		for (const map of asList(set.key_maps))
			for (const key of asList(map.keys)) {
				if (placed.has(key.code)) {
					if (key.output && controls.test(key.output))
						refuse('control_output_on_character_key', { code: key.code });
					if (key.output && reservedWchar.test(key.output))
						refuse('reserved_windows_character', { code: key.code });
				} else {
					const printable =
						typeof key.output === 'string' && key.output !== '' && !controls.test(key.output);
					if ((key.action || printable) && !(key.code >= 65 && key.code <= 92))
						refuse('unplaced_character_key', { code: key.code });
					if (!untouched.has(key.code)) untouched.set(key.code, []);
					untouched.get(key.code).push({
						set: set.id,
						map: map.index,
						...(key.action ? { action: key.action } : { output: key.output })
					});
				}
			}
	for (const action of asList(canonical.actions)) {
		if (controls.test(action.id)) refuse('control_action_identifier');
		if (!asList(action.whens).some((when) => when.state === 'none'))
			refuse('action_without_neutral_transition', { action: action.id });
		for (const when of asList(action.whens)) {
			if (controls.test(when.state) || (when.next && controls.test(when.next)))
				refuse('control_state_identifier');
			if (when.output && controls.test(when.output))
				refuse('control_output_in_action', { action: action.id });
			if (when.output && reservedWchar.test(when.output))
				refuse('reserved_windows_character', { action: action.id });
		}
	}
	for (const terminator of asList(canonical.terminators)) {
		if (controls.test(terminator.state) || controls.test(terminator.output))
			refuse('control_terminator');
		if (reservedWchar.test(terminator.output))
			refuse('reserved_windows_character', { state: terminator.state });
	}
	const context = {
		meta: {
			name,
			author,
			version: KLC_ARTIFACT_VERSION,
			licence: '',
			keycode_convention: imported.convention
		},
		spec: {
			dll_name: metadata.dll_name,
			language_id: metadata.layout_id.slice(4).toUpperCase(),
			locale_name: locale,
			language_name: new Intl.DisplayNames(['en'], { type: 'language' }).of(locale),
			layout_text: name,
			layout_description: description
		},
		keycodes,
		physicalKeys,
		sourceRel: `layout-source:${document.layout.id}`
	};
	const generated = Windows.generate(canonical, context);
	if (!generated.model.keys.length) refuse('no_exportable_character_keys');
	if (generated.model.omitted.length)
		refuse('unrepresentable_dead_transitions', generated.model.omitted);
	const deadStates = new Set(generated.model.deadKeys.map((dead) => dead.state));
	for (const action of asList(canonical.actions))
		for (const when of asList(action.whens))
			if (when.state !== 'none' && !deadStates.has(when.state))
				refuse('unrepresented_dead_state', { action: action.id, state: when.state });
	const bound = new Set(
		generated.model.keys.flatMap((key) => Object.values(key.cells).map((cell) => cell.action))
	);
	const unbound = asList(canonical.actions).filter(
		(action) => !bound.has(action.id) && asList(action.whens).some((when) => when.state !== 'none')
	);
	if (unbound.length)
		refuse(
			'unbound_stateful_actions',
			unbound.map((action) => action.id)
		);
	const layout = Windows.indexLayout(canonical);
	const emittedKeys = new Set(generated.model.keys.map((key) => key.code));
	for (const key of physical)
		if (!emittedKeys.has(key.code))
			for (const pressed of [['caps'], ['shift', 'caps']]) {
				const cell = Windows.resolveCell(layout, Windows.keyMapIndex(layout, pressed), key.mac);
				if (cell.kind !== 'none')
					refuse('unrepresented_caps_character_key', {
						key: key.code,
						modifiers: pressed,
						source: cell
					});
			}
	const unsupported = [];
	const modifiers = ['shift', 'caps', 'option', 'control', 'command'];
	for (let mask = 0; mask < 32; mask++) {
		if (!(mask & 24)) continue;
		const pressed = modifiers.filter((_, bit) => mask & (1 << bit));
		const index = Windows.keyMapIndex(layout, pressed);
		unsupported.push({
			modifiers: pressed,
			source_map_index: index,
			source_cells: physical
				.map((key) => ({
					key: key.code,
					code: key.mac,
					...Windows.resolveCell(layout, index, key.mac)
				}))
				.filter((cell) => cell.kind !== 'none')
		});
	}
	const report = {
		target: 'windows',
		status: 'partial',
		artifact: 'klc',
		reason: 'msklc_character_columns',
		blockers: [],
		name: metadata.dll_name,
		locale,
		language_lcid: metadata.layout_id.toLowerCase(),
		artifact_version: KLC_ARTIFACT_VERSION,
		columns: Windows.COLUMNS.map((column) => ({
			shift_state: column.klc,
			source_modifiers: column.mac
		})),
		uncompiled_modifiers: unsupported,
		system_keys: [...untouched]
			.sort(([a], [b]) => a - b)
			.map(([code, source_mappings]) => ({ code, source_mappings })),
		character_keys: generated.model.keys.length,
		virtual_keys: generated.model.keys.map((key) => ({
			key: key.code,
			scan_code: key.scanCode,
			virtual_key: key.vk
		})),
		dead_keys: generated.model.deadKeys.length,
		ligatures: generated.model.ligatures.length,
		limitations: [
			'Ctrl and Shift+Ctrl cells are left empty for Windows control-key behavior; source Command mappings are not compiled. Listed combinations retain their source cells for review.',
			'Virtual keys follow the existing generator allocation; source shortcuts are not inferred from the displayed character.',
			'Listed system/keypad mappings are not compiled; the KLC generator emits the standard decimal point.',
			'KLC uses a language LCID, not a reserved keyboard-layout ID; locale/LCID association and native Windows loading are not certified.',
			'No DLL or installer is produced. The new KLC artifact starts at version 1.0; the source schema has no release-version field.'
		]
	};
	return {
		report,
		files: new Map([
			[`${metadata.dll_name}.klc`, Windows.encodeKlc(generated.klc)],
			['export.json', `${JSON.stringify(report, null, 2)}\n`]
		])
	};
}

module.exports = { exportKlc };
