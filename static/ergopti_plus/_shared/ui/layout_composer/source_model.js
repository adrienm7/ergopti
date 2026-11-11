// _shared/ui/layout_composer/source_model.js

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Model
 * DESCRIPTION:
 * Validates the versioned TOML document shared by the future unified layout
 * editor and build tools. TOML parsing is supplied by the caller; the existing
 * composer remains the only browser reader of .keylayout files.
 *
 * FEATURES & RATIONALE:
 * 1. Imported XML stays verbatim: the composer's conversion projection folds
 *    modifiers and cannot stand in for the original hardware maps and actions.
 * 2. Explicit superset records describe edits without pretending an unfinished
 *    exporter or driver can apply them. Unsupported exports fail before writing.
 * 3. This pure classic script runs unchanged in a page and in the Node loader.
 * ==============================================================================
 */

var LayoutSource = (function () {
	'use strict';

	const FORMAT = 'ergopti-layout';
	const VERSION = 1;
	const ID = /^[a-z][a-z0-9_]*$/;
	const KEY = /^[A-Z][A-Za-z0-9]*$/;
	const CONTROL = /[\u0000-\u001F\u007F-\u009F]/;
	// A bundle resource stem: no path separator, quote, backslash or leading dot.
	const FILE_NAME = /^[^./\\"][^/\\"]*$/;
	const BUILTIN_MODIFIERS = [
		'shift',
		'shift_left',
		'shift_right',
		'control',
		'control_left',
		'control_right',
		'alt',
		'alt_left',
		'alt_right',
		'meta',
		'meta_left',
		'meta_right',
		'caps_lock',
		'num_lock',
		'scroll_lock',
		// Windows' Kana level (KBDKANA), the level Ergopti's KbdEdit layout uses in
		// place of AltGr; each target maps it to its closest native level.
		'kana'
	];
	const TARGETS = [
		{ target: 'macos', artifact: 'keylayout' },
		{ target: 'linux', artifact: 'xkb', unavailable: 'tooling_export_required' },
		{ target: 'windows', artifact: 'klc', unavailable: 'tooling_export_required' },
		{ target: 'driver_macos', artifact: 'emulation' },
		{ target: 'driver_linux', artifact: 'emulation' },
		{ target: 'driver_windows', artifact: 'emulation' },
		{ target: 'web', artifact: 'emulation' }
	];
	// Export fields holding a table of LCID (4 hex digits) -> text instead of a
	// string: the Windows version resource's per-language texts.
	const EXPORT_TABLES = { windows: ['descriptions', 'language_names'] };
	const EXPORT_METADATA = {
		windows: [
			'locale',
			'layout_id',
			'dll_name',
			'copyright',
			'company',
			'descriptions',
			'language_names'
		],
		linux: ['name', 'description']
	};
	const EDITS = [
		'modifiers',
		'layers',
		'dead_keys',
		'keys',
		'remap',
		'shortcuts',
		// config-key-literal-ok: field of the versioned layout format, not application config.
		'tap_holds',
		'windows'
	];
	// The ISO key left of Z, and where the ANSI derivation moves it by default.
	const ISO_EXTRA_KEY = 'IntlBackslash';
	const ANSI_EXTRA_KEY = 'Backquote';
	const MACOS_EXPORT_STRINGS = [
		'internal_name',
		'ansi_internal_name',
		'ansi_display_name',
		'input_source_id',
		'version'
	];
	const MACOS_ICONS = ['icon', 'ansi_icon'];
	const ICON_FILE = /^[A-Za-z0-9][A-Za-z0-9._-]*\.png$/;
	const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
	const table = (value) => Object.prototype.toString.call(value) === '[object Object]';

	/** A validation or export refusal with a stable code and source path. */
	class SourceError extends Error {
		constructor(code, path) {
			super(`${code}: ${path}`);
			this.name = 'SourceError';
			this.code = code;
			this.path = path;
		}
	}

	/** Refuse invalid input at its owning source path. */
	function requireValue(condition, path, code = 'source_invalid') {
		if (!condition) throw new SourceError(code, path);
	}

	/** Check a closed record without discarding misspelled or future fields. */
	function record(value, allowed, required, path) {
		requireValue(table(value), path);
		for (const key of Object.keys(value))
			requireValue(allowed.includes(key), `${path}.${key}`, 'source_unknown_field');
		for (const key of required) requireValue(own(value, key), `${path}.${key}`);
	}

	/** Strings are Unicode scalar sequences, including non-BMP and control output. */
	function string(value, path, empty = false) {
		requireValue(typeof value === 'string' && (empty || value.length > 0), path);
		for (const character of value) {
			const point = character.codePointAt(0);
			requireValue(point < 0xd800 || point > 0xdfff, path, 'source_unicode');
		}
	}

	/** Check a source identifier rather than a translated display name. */
	function identifier(value, path) {
		string(value, path);
		requireValue(ID.test(value), path);
	}

	/** Physical positions use KeyboardEvent.code spelling, not typed characters. */
	function keyCode(value, path) {
		string(value, path);
		requireValue(KEY.test(value), path);
	}

	/** Check one ordered list and reject duplicate identities. */
	function list(value, path, check, identity = (entry) => entry) {
		requireValue(Array.isArray(value), path);
		const seen = new Set();
		value.forEach((entry, index) => {
			check(entry, `${path}[${index}]`);
			const id = identity(entry);
			requireValue(!seen.has(id), `${path}[${index}]`, 'source_duplicate');
			seen.add(id);
		});
		return seen;
	}

	/** Require a declared reference; accepting a typo would lose its mapping later. */
	function reference(value, names, path) {
		identifier(value, path);
		requireValue(names.has(value), path, 'source_reference');
	}

	/** Validate a text, dead-state, action, physical chord or disabled mapping. */
	function mapping(value, path, deadKeys, modifiers) {
		record(
			value,
			['text', 'compose', 'compose_as', 'dead_key', 'action', 'key', 'modifiers', 'disabled'],
			[],
			path
		);
		const kinds = ['text', 'dead_key', 'action', 'key', 'disabled'].filter((kind) =>
			own(value, kind)
		);
		requireValue(kinds.length === 1, path);
		if (own(value, 'text')) string(value.text, `${path}.text`, true);
		if (own(value, 'dead_key')) reference(value.dead_key, deadKeys, `${path}.dead_key`);
		if (own(value, 'action')) identifier(value.action, `${path}.action`);
		if (own(value, 'key')) keyCode(value.key, `${path}.key`);
		if (own(value, 'disabled')) requireValue(value.disabled === true, `${path}.disabled`);
		// A text's dead-key identity: compose = false types it outside every dead key,
		// compose_as names the rule input it answers to when that differs from the text.
		if (own(value, 'compose')) {
			requireValue(own(value, 'text'), `${path}.compose`);
			requireValue(typeof value.compose === 'boolean', `${path}.compose`);
		}
		if (own(value, 'compose_as')) {
			requireValue(own(value, 'text') && value.compose !== false, `${path}.compose_as`);
			string(value.compose_as, `${path}.compose_as`);
		}
		if (own(value, 'modifiers')) {
			requireValue(own(value, 'key'), `${path}.modifiers`);
			list(value.modifiers, `${path}.modifiers`, (id, at) => reference(id, modifiers, at));
		}
	}

	/** Check one modifier combination: required and optional modifiers never overlap. */
	function selector(value, path, modifiers) {
		const required = list(value.required, `${path}.required`, (id, where) =>
			reference(id, modifiers, where)
		);
		list(value.optional, `${path}.optional`, (id, where) => {
			reference(id, modifiers, where);
			requireValue(!required.has(id), where, 'source_modifier_overlap');
		});
	}

	/** Read an imported document through the existing composer, never a second parser. */
	function importedModel(source) {
		const text = source.imported_keylayout.text;
		// The retained document is inert data; an external/custom entity is never expanded.
		requireValue(!/<!ENTITY\b/i.test(text), 'imported_keylayout.text', 'source_xml_entity');
		try {
			return LayoutComposer.parseModel(text);
		} catch (error) {
			throw new SourceError('source_keylayout', error.code || error.message);
		}
	}

	/**
	 * Validate the complete version-1 document and its cross references.
	 * Key/action catalogue admission is an exporter responsibility, not evidence
	 * that a syntactically valid position or action already runs on a driver.
	 * @param {object} source - Decoded TOML.
	 * @returns {object} The same source, without defaults or discarded fields.
	 */
	function validate(source) {
		record(
			source,
			['format', 'version', 'layout', 'physical', 'imported_keylayout', ...EDITS, 'exports'],
			['format', 'version', 'layout', 'physical'],
			'source'
		);
		requireValue(source.format === FORMAT, 'format', 'source_format');
		requireValue(source.version === VERSION, 'version', 'source_version');
		record(
			source.layout,
			['id', 'name', 'description', 'author', 'languages'],
			['id', 'name'],
			'layout'
		);
		identifier(source.layout.id, 'layout.id');
		string(source.layout.name, 'layout.name');
		for (const field of ['description', 'author'])
			if (own(source.layout, field)) string(source.layout[field], `layout.${field}`, true);
		if (own(source.layout, 'languages')) list(source.layout.languages, 'layout.languages', string);
		record(source.physical, ['base', 'ansi_extra_key', 'ansi_swaps'], ['base'], 'physical');
		requireValue(['iso', 'ansi'].includes(source.physical.base), 'physical.base');
		if (own(source.physical, 'ansi_extra_key'))
			keyCode(source.physical.ansi_extra_key, 'physical.ansi_extra_key');
		if (own(source.physical, 'ansi_swaps')) {
			// Each position moves once: a key in two pairs would make the derivation order-dependent.
			const moved = new Set([ISO_EXTRA_KEY, source.physical.ansi_extra_key || ANSI_EXTRA_KEY]);
			list(
				source.physical.ansi_swaps,
				'physical.ansi_swaps',
				(pair, at) => {
					requireValue(Array.isArray(pair) && pair.length === 2, at);
					pair.forEach((key, index) => {
						keyCode(key, `${at}[${index}]`);
						requireValue(!moved.has(key), `${at}[${index}]`, 'source_duplicate');
						moved.add(key);
					});
				},
				(pair) => pair.join(':')
			);
		}
		if (own(source, 'imported_keylayout')) {
			record(
				source.imported_keylayout,
				['text', 'convention'],
				['text', 'convention'],
				'imported_keylayout'
			);
			string(source.imported_keylayout.text, 'imported_keylayout.text');
			requireValue(
				['iso', 'ansi'].includes(source.imported_keylayout.convention),
				'imported_keylayout.convention'
			);
			importedModel(source);
		} else {
			requireValue(source.physical.base === 'iso', 'physical.base', 'source_base_convention');
		}
		const modifiers = new Set(BUILTIN_MODIFIERS);
		if (own(source, 'modifiers'))
			list(
				source.modifiers,
				'modifiers',
				(entry, at) => {
					record(entry, ['id', 'mode', 'keys'], ['id', 'mode', 'keys'], at);
					identifier(entry.id, `${at}.id`);
					requireValue(!modifiers.has(entry.id), `${at}.id`, 'source_duplicate');
					requireValue(['held', 'locked'].includes(entry.mode), `${at}.mode`);
					list(entry.keys, `${at}.keys`, keyCode);
					requireValue(entry.keys.length > 0, `${at}.keys`);
					modifiers.add(entry.id);
				},
				(entry) => entry.id
			);
		const deadKeys = new Set();
		const states = new Set();
		if (own(source, 'dead_keys'))
			list(
				source.dead_keys,
				'dead_keys',
				(entry, at) => {
					record(
						entry,
						['id', 'name', 'state', 'action_id', 'terminator', 'rules'],
						['id', 'terminator', 'rules'],
						at
					);
					identifier(entry.id, `${at}.id`);
					if (own(entry, 'name')) string(entry.name, `${at}.name`);
					// The .keylayout state and action names, kept when an import's differ from the id.
					for (const field of ['state', 'action_id'])
						if (own(entry, field)) {
							string(entry[field], `${at}.${field}`);
							requireValue(!CONTROL.test(entry[field]), `${at}.${field}`);
						}
					const state = own(entry, 'state') ? entry.state : entry.id;
					requireValue(state !== 'none' && !states.has(state), `${at}.state`, 'source_duplicate');
					states.add(state);
					string(entry.terminator, `${at}.terminator`, true);
					deadKeys.add(entry.id);
				},
				(entry) => entry.id
			);
		for (const [index, entry] of (source.dead_keys || []).entries())
			list(
				entry.rules,
				`dead_keys[${index}].rules`,
				(rule, at) => {
					record(rule, ['input', 'input_dead_key', 'text', 'next'], [], at);
					// The typed text a rule answers to, or the dead key pressed while this one is pending.
					requireValue(own(rule, 'input') !== own(rule, 'input_dead_key'), at);
					if (own(rule, 'input')) string(rule.input, `${at}.input`);
					else reference(rule.input_dead_key, deadKeys, `${at}.input_dead_key`);
					requireValue(own(rule, 'text') || own(rule, 'next'), at);
					if (own(rule, 'text')) string(rule.text, `${at}.text`, true);
					if (own(rule, 'next')) reference(rule.next, deadKeys, `${at}.next`);
				},
				(rule) => (own(rule, 'input') ? `text:${rule.input}` : `dead:${rule.input_dead_key}`)
			);
		const layers = new Set();
		if (own(source, 'layers'))
			list(
				source.layers,
				'layers',
				(entry, at) => {
					record(
						entry,
						['id', 'required', 'optional', 'alternatives', 'keys', 'platform_keys', 'ansi_keys'],
						['id', 'required', 'optional', 'keys'],
						at
					);
					identifier(entry.id, `${at}.id`);
					layers.add(entry.id);
					selector(entry, at, modifiers);
					// Further modifier combinations that select the same layer (one keyMapSelect).
					if (own(entry, 'alternatives'))
						list(entry.alternatives, `${at}.alternatives`, (alternative, where) => {
							record(alternative, ['required', 'optional'], ['required', 'optional'], where);
							selector(alternative, where, modifiers);
						});
					requireValue(table(entry.keys), `${at}.keys`);
					for (const [key, value] of Object.entries(entry.keys)) {
						keyCode(key, `${at}.keys.${key}`);
						mapping(value, `${at}.keys.${key}`, deadKeys, modifiers);
					}
					// The ANSI variant's own mappings where the derivation rule is not enough
					// (Bépo's ANSI hardware map), applied after it, on every platform.
					if (own(entry, 'ansi_keys')) {
						requireValue(table(entry.ansi_keys), `${at}.ansi_keys`);
						for (const [key, value] of Object.entries(entry.ansi_keys)) {
							keyCode(key, `${at}.ansi_keys.${key}`);
							mapping(value, `${at}.ansi_keys.${key}`, deadKeys, modifiers);
						}
					}
					if (own(entry, 'platform_keys')) {
						record(entry.platform_keys, ['windows', 'macos', 'linux'], [], `${at}.platform_keys`);
						for (const [platform, bindings] of Object.entries(entry.platform_keys)) {
							const where = `${at}.platform_keys.${platform}`;
							requireValue(table(bindings), where);
							for (const [key, value] of Object.entries(bindings)) {
								keyCode(key, `${where}.${key}`);
								mapping(value, `${where}.${key}`, deadKeys, modifiers);
							}
						}
					}
				},
				(entry) => entry.id
			);
		if (!own(source, 'imported_keylayout'))
			requireValue(layers.has('base'), 'layers.base', 'source_base_layer');
		if (own(source, 'keys')) {
			requireValue(table(source.keys), 'keys');
			for (const [key, entry] of Object.entries(source.keys)) {
				const at = `keys.${key}`;
				keyCode(key, at);
				record(
					entry,
					['name', 'caps_lock', 'caps_layer', 'caps_shift_layer', 'caps_altgr', 'virtual_key'],
					[],
					at
				);
				if (own(entry, 'name')) string(entry.name, `${at}.name`);
				if (own(entry, 'caps_lock'))
					requireValue(
						['unaffected', 'shift', 'separate'].includes(entry.caps_lock),
						`${at}.caps_lock`
					);
				for (const field of ['caps_layer', 'caps_shift_layer']) {
					if (entry.caps_lock === 'separate') requireValue(own(entry, field), `${at}.${field}`);
					if (own(entry, field)) {
						requireValue(entry.caps_lock === 'separate', `${at}.${field}`);
						reference(entry[field], layers, `${at}.${field}`);
					}
				}
				if (own(entry, 'caps_altgr'))
					requireValue(typeof entry.caps_altgr === 'boolean', `${at}.caps_altgr`);
				if (own(entry, 'virtual_key'))
					requireValue(
						Number.isInteger(entry.virtual_key) &&
							entry.virtual_key >= 0 &&
							entry.virtual_key <= 255,
						`${at}.virtual_key`
					);
			}
		}
		if (own(source, 'remap')) {
			requireValue(table(source.remap), 'remap');
			for (const [key, target] of Object.entries(source.remap)) {
				keyCode(key, `remap.${key}`);
				if (target !== '') keyCode(target, `remap.${key}`);
			}
		}
		if (own(source, 'shortcuts'))
			list(
				source.shortcuts,
				'shortcuts',
				(entry, at) => {
					record(
						entry,
						['key', 'modifiers', 'send_key', 'send_modifiers'],
						['key', 'modifiers', 'send_key', 'send_modifiers'],
						at
					);
					keyCode(entry.key, `${at}.key`);
					keyCode(entry.send_key, `${at}.send_key`);
					for (const field of ['modifiers', 'send_modifiers'])
						list(entry[field], `${at}.${field}`, (id, where) => reference(id, modifiers, where));
				},
				(entry) => `${entry.key}:${entry.modifiers.slice().sort().join(',')}`
			);
		// config-key-literal-ok: field of the versioned layout format, not application config.
		if (own(source, 'tap_holds'))
			list(
				source.tap_holds,
				// config-key-literal-ok: schema diagnostic path, not application config.
				'tap_holds',
				(entry, at) => {
					record(
						entry,
						['key', 'tap', 'hold_layer', 'hold_modifier', 'threshold_ms'],
						['key', 'tap', 'threshold_ms'],
						at
					);
					keyCode(entry.key, `${at}.key`);
					mapping(entry.tap, `${at}.tap`, deadKeys, modifiers);
					requireValue(own(entry, 'hold_layer') !== own(entry, 'hold_modifier'), at);
					if (own(entry, 'hold_layer')) reference(entry.hold_layer, layers, `${at}.hold_layer`);
					if (own(entry, 'hold_modifier'))
						reference(entry.hold_modifier, modifiers, `${at}.hold_modifier`);
					requireValue(
						Number.isSafeInteger(entry.threshold_ms) && entry.threshold_ms > 0,
						`${at}.threshold_ms`
					);
				},
				(entry) => entry.key
			);
		if (own(source, 'windows')) {
			record(source.windows, ['flags', 'nls', 'key_names', 'kana_key'], [], 'windows');
			// The physical key that holds the Kana level on Windows (Right Alt by default).
			if (own(source.windows, 'kana_key')) keyCode(source.windows.kana_key, 'windows.kana_key');
			if (own(source.windows, 'flags')) list(source.windows.flags, 'windows.flags', identifier);
			// The key names of scan codes no physical key of the registry names
			// (F13 to F24, Pause, Sys Req…), keyed sc_<hex> or e0_<hex> for an extended one.
			if (own(source.windows, 'key_names')) {
				const names = source.windows.key_names;
				requireValue(
					names && typeof names === 'object' && !Array.isArray(names),
					'windows.key_names'
				);
				for (const [scan, name] of Object.entries(names)) {
					requireValue(/^(sc|e0)_[0-9a-f]{2}$/.test(scan), `windows.key_names.${scan}`);
					string(name, `windows.key_names.${scan}`);
				}
			}
			if (own(source.windows, 'nls'))
				list(
					source.windows.nls,
					'windows.nls',
					(entry, at) => {
						record(
							entry,
							[
								'key',
								'modifiers',
								'function',
								'parameter_key',
								'keyup_function',
								'keyup_parameter_key'
							],
							['key', 'modifiers', 'function'],
							at
						);
						keyCode(entry.key, `${at}.key`);
						list(entry.modifiers, `${at}.modifiers`, (id, where) =>
							reference(id, modifiers, where)
						);
						identifier(entry.function, `${at}.function`);
						if (own(entry, 'keyup_function'))
							identifier(entry.keyup_function, `${at}.keyup_function`);
						for (const field of ['parameter_key', 'keyup_parameter_key'])
							if (own(entry, field)) keyCode(entry[field], `${at}.${field}`);
					},
					(entry) => `${entry.key}:${entry.modifiers.slice().sort().join(',')}`
				);
		}
		if (own(source, 'exports')) {
			record(source.exports, ['macos', 'windows', 'linux'], [], 'exports');
			if (own(source.exports, 'macos')) {
				const macos = source.exports.macos;
				record(
					macos,
					['format', ...MACOS_EXPORT_STRINGS, 'keyboard_id', 'ansi_keyboard_id', ...MACOS_ICONS],
					['format'],
					'exports.macos'
				);
				requireValue(['bundle', 'iso', 'ansi'].includes(macos.format), 'exports.macos.format');
				for (const field of MACOS_EXPORT_STRINGS)
					if (own(macos, field)) {
						string(macos[field], `exports.macos.${field}`);
						requireValue(!CONTROL.test(macos[field]), `exports.macos.${field}`);
					}
				// The internal name is the .keylayout file name, its KLInfo key and its strings key.
				for (const field of ['internal_name', 'ansi_internal_name'])
					if (own(macos, field))
						requireValue(FILE_NAME.test(macos[field]), `exports.macos.${field}`);
				// A PNG beside the source file, wrapped into each variant's .icns by the exporter.
				for (const field of MACOS_ICONS)
					if (own(macos, field))
						requireValue(
							typeof macos[field] === 'string' && ICON_FILE.test(macos[field]),
							`exports.macos.${field}`
						);
				for (const field of ['keyboard_id', 'ansi_keyboard_id'])
					if (own(macos, field))
						requireValue(Number.isSafeInteger(macos[field]), `exports.macos.${field}`);
			}
			for (const [target, fields] of Object.entries(EXPORT_METADATA))
				if (own(source.exports, target)) {
					record(source.exports[target], fields, [], `exports.${target}`);
					for (const [key, value] of Object.entries(source.exports[target])) {
						if ((EXPORT_TABLES[target] || []).includes(key)) {
							requireValue(
								value && typeof value === 'object' && !Array.isArray(value),
								`exports.${target}.${key}`
							);
							for (const [lang, text] of Object.entries(value)) {
								requireValue(/^[0-9a-f]{4}$/.test(lang), `exports.${target}.${key}.${lang}`);
								string(text, `exports.${target}.${key}.${lang}`);
							}
						} else string(value, `exports.${target}.${key}`);
					}
				}
		}
		return source;
	}

	/** Import a readable layout while retaining every XML byte outside the projection. */
	function importKeylayout(text, id, convention) {
		const source = {
			format: FORMAT,
			version: VERSION,
			layout: { id, name: 'import' },
			physical: { base: convention },
			imported_keylayout: { text, convention }
		};
		string(text, 'imported_keylayout.text');
		source.layout.name = importedModel(source).name;
		return validate(source);
	}

	/** List every edit the preservation exporter would otherwise silently ignore. */
	function exportBlockers(source, preservation = true) {
		const blockers = [];
		if (!source.imported_keylayout) return ['keylayout_generation_not_implemented'];
		const imported = importedModel(source);
		if (preservation && source.layout.name !== imported.name) blockers.push('layout.name');
		if (source.physical.base !== source.imported_keylayout.convention)
			blockers.push('physical.base');
		if (own(source.physical, 'ansi_extra_key')) blockers.push('physical.ansi_extra_key');
		for (const field of EDITS)
			if (own(source, field) && Object.keys(source[field]).length > 0) blockers.push(field);
		if (
			preservation &&
			source.exports &&
			source.exports.macos &&
			source.exports.macos.format !== source.physical.base
		)
			blockers.push('exports.macos.format');
		return blockers;
	}

	/** Export only what is implemented; this never emits custom XML elements. */
	function exportKeylayout(source) {
		validate(source);
		const blockers = exportBlockers(source);
		if (blockers.length) throw new SourceError('source_export_unavailable', blockers.join(', '));
		return source.imported_keylayout.text;
	}

	/** Admit an unmodified imported mapping for a target-specific converter. */
	function conversionSource(source) {
		validate(source);
		const blockers = exportBlockers(source, false);
		if (blockers.length) throw new SourceError('source_export_unavailable', blockers.join(', '));
		return source.imported_keylayout;
	}

	/**
	 * Report this pure model's operations, not operating-system capability.
	 * Native tooling augments this report after running its own admission checks.
	 */
	function capabilities(source) {
		validate(source);
		const blockers = exportBlockers(source);
		return TARGETS.map(({ target, artifact, unavailable = 'exporter_not_implemented' }) => ({
			target,
			status: artifact === 'keylayout' && blockers.length === 0 ? 'native' : 'unavailable',
			artifact,
			reason:
				artifact === 'keylayout'
					? blockers.length
						? 'source_edits_not_compiled'
						: 'original_keylayout_preserved'
					: unavailable,
			blockers: artifact === 'keylayout' ? blockers : [unavailable]
		}));
	}

	/** Decode ordinary TOML, including comments, through the supplied codec. */
	function read(text, codec) {
		return validate(codec.parse(text));
	}

	/** Write validated source with the same codec the tooling already owns. */
	function write(source, codec) {
		validate(source);
		return codec.stringify(source);
	}

	return {
		FORMAT,
		VERSION,
		ISO_EXTRA_KEY,
		ANSI_EXTRA_KEY,
		BUILTIN_MODIFIERS,
		SourceError,
		validate,
		importKeylayout,
		exportKeylayout,
		conversionSource,
		capabilities,
		read,
		write
	};
})();
