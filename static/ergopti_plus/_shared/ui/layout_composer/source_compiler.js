// _shared/ui/layout_composer/source_compiler.js

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Compiler
 * DESCRIPTION:
 * The one generator of the Ergopti layout source (docs/design/layout-source-format.md).
 * It imports a .keylayout into structured records, compiles those records into a
 * .keylayout for each physical variant (ISO, and ANSI by the fixed derivation
 * rule), lays out the macOS bundle, and reports per feature what each target
 * carries natively and what it leaves out. Linux XKB and Windows KLC consume the
 * compiled .keylayout through their existing converters, so every target reads
 * the same compilation.
 *
 * FEATURES & RATIONALE:
 * 1. One intermediate form: a compiled .keylayout holds exactly what the three
 *    native formats share, and the existing converters already turn it into XKB
 *    and KLC; a second per-target compiler would drift from it.
 * 2. Nothing is dropped silently: every record a target cannot express is listed
 *    in the report with its path and reason, never skipped without a trace.
 * 3. Lossless import of what the .keylayout holds: unfolded modifier tokens,
 *    action and state names and per-key dead-key participation survive, so the
 *    compiled file behaves as the imported one, state by state.
 * 4. Pure classic script: the page, the app webviews and the Node tools load it
 *    unchanged after composer_model.js and source_model.js. Key tables are
 *    passed in, never fetched.
 * ==============================================================================
 */

var LayoutSourceCompiler = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const ID = /^[a-z][a-z0-9_]*$/;
	const NEUTRAL = 'none';
	const UNUSED = '\u0010';
	const MAX_CODE = 127;
	// A macOS code no key table names (Ergo-L types at code 66, a legacy keypad
	// position): the source names it MacCode<n>, which only the macOS target owns.
	const MAC_CODE = /^MacCode(\d{1,3})$/;

	// Built-in modifier -> TN2056 modifierMap token. A plain token is the left key.
	const TOKENS = {
		shift: 'anyShift',
		shift_left: 'shift',
		shift_right: 'rightShift',
		alt: 'anyOption',
		alt_left: 'option',
		alt_right: 'rightOption',
		control: 'anyControl',
		control_left: 'control',
		control_right: 'rightControl',
		meta: 'command',
		caps_lock: 'caps'
	};
	// The XKB and KLC converters read Option as AltGr, which is the right Alt key of a
	// PC keyboard; every other sided modifier has no level there.
	const CONVERTER_TOKENS = Object.assign({}, TOKENS, {
		alt_right: 'anyOption',
		shift_left: null,
		shift_right: null,
		alt_left: null,
		control_left: null,
		control_right: null
	});
	const FROM_TOKEN = Object.fromEntries(Object.entries(TOKENS).map(([id, token]) => [token, id]));
	// Selector names follow this order so an imported layer id does not depend on token order.
	const NAME_ORDER = Object.keys(TOKENS);
	// Physical modifier positions: a keyMap entry for them is ignored by macOS.
	const MODIFIER_KEYS = new Set([
		'ShiftLeft',
		'ShiftRight',
		'ControlLeft',
		'ControlRight',
		'AltLeft',
		'AltRight',
		'MetaLeft',
		'MetaRight',
		'CapsLock',
		'Fn'
	]);
	// What each compilation target can carry. macOS reads the keylayout itself, with
	// every sided token and an unused cell for a disabled key; Linux and Windows reach
	// it through the XKB and KLC converters, which have neither and place no key at
	// an unnamed macOS key code.
	const TARGETS = {
		macos: { tokens: TOKENS, disabledCharacterCell: true, unnamedMacCodes: true },
		linux: { tokens: CONVERTER_TOKENS, disabledCharacterCell: false, unnamedMacCodes: false },
		windows: { tokens: CONVERTER_TOKENS, disabledCharacterCell: false, unnamedMacCodes: false }
	};
	const VARIANTS = ['iso', 'ansi'];
	const MACOS_FORMATS = ['bundle', 'iso', 'ansi'];
	const DEFAULT_VERSION = '1.0';
	// The PNG-carrying icon element of each square size macOS reads from an .icns.
	const ICNS_TYPES = new Map([
		[16, 'icp4'],
		[32, 'icp5'],
		[64, 'icp6'],
		[128, 'ic07'],
		[256, 'ic08'],
		[512, 'ic09'],
		[1024, 'ic10']
	]);
	const PNG_SIGNATURE = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a];
	const INPUT_SOURCE_PREFIX = 'com.apple.keyboardlayout.';

	const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
	const scalars = (text) => Array.from(text).length;
	const fail = (code, path) => {
		throw new LayoutSource.SourceError(code, path);
	};

	// ==============================
	// ======= 2/ Key tables ========
	// ==============================

	/**
	 * Physical key name <-> macOS code under one numbering convention. The 49
	 * character keys come from mac_keycodes.json (the two ISO/ANSI keys depend on
	 * the convention); every other key from physical_keys.json, then the keys no
	 * layer binds from hid_usages.json `unregistered` (keypad =, F13 to F20, JIS),
	 * named as macOS names them: F13 wins over PrintScreen for the same code.
	 * @param {{macKeycodes: object, physicalKeys: object, hidUsages: object}} tables
	 * @param {'iso'|'ansi'} convention
	 */
	function keyTable(tables, convention) {
		const byName = new Map();
		const byMac = new Map();
		const character = new Set();
		const add = (name, mac) => {
			if (byName.has(name) || byMac.has(mac)) fail('source_key_table', `${name}:${mac}`);
			byName.set(name, mac);
			byMac.set(mac, name);
		};
		for (const key of tables.macKeycodes.keys) {
			add(key.code, typeof key.mac === 'object' ? key.mac[convention] : key.mac);
			character.add(key.code);
		}
		for (const [name, key] of Object.entries(tables.physicalKeys.keys))
			if (key.kind === 'key' && typeof key.hs === 'number' && !character.has(name))
				add(name, key.hs);
		const unregistered = Object.entries(tables.hidUsages.unregistered).sort(
			([a], [b]) => Number(!/^F\d+$/.test(a)) - Number(!/^F\d+$/.test(b))
		);
		for (const [name, key] of unregistered)
			if (!byName.has(name) && !byMac.has(key.hs)) add(name, key.hs);
		return { byName, byMac, character, code: (name) => macCode(byName, byMac, name) };
	}

	/** The macOS code of a physical name: its table entry, or the MacCode<n> it spells. */
	function macCode(byName, byMac, name) {
		if (byName.has(name)) return byName.get(name);
		const match = MAC_CODE.exec(name);
		if (!match) return undefined;
		const mac = Number(match[1]);
		return mac <= MAX_CODE && !byMac.has(mac) && String(mac) === match[1] ? mac : undefined;
	}

	/** macOS code -> the standard control output of a key that types no character. */
	function systemDefaults() {
		const defaults = new Map();
		for (const [mac, output] of LayoutComposer.OTHER_KEYS)
			if (typeof output === 'number') defaults.set(mac, String.fromCharCode(output));
		return defaults;
	}

	// ======================================
	// ======= 3/ Variants and naming =======
	// ======================================

	/** The ISO -> ANSI position pairs: the ISO extra key first, then the declared swaps. */
	function ansiPairs(source) {
		const physical = source.physical;
		return [
			[LayoutSource.ISO_EXTRA_KEY, physical.ansi_extra_key || LayoutSource.ANSI_EXTRA_KEY],
			...(physical.ansi_swaps || [])
		];
	}

	/** Swap the mappings of each pair; an absent mapping moves as an absence. */
	function swapped(keys, pairs) {
		const result = Object.assign({}, keys);
		for (const [a, b] of pairs) {
			const left = result[a];
			const right = result[b];
			delete result[a];
			delete result[b];
			if (right !== undefined) result[a] = right;
			if (left !== undefined) result[b] = left;
		}
		return result;
	}

	/** Names, ids and display strings of one physical variant of the macOS layout. */
	function variantNames(source, variant) {
		const macos = (source.exports && source.exports.macos) || {};
		const internal = macos.internal_name || source.layout.id;
		const inputSource = macos.input_source_id || INPUT_SOURCE_PREFIX + source.layout.id;
		if (variant === 'iso')
			return {
				internal,
				display: source.layout.name,
				keyboardId: own(macos, 'keyboard_id')
					? macos.keyboard_id
					: LayoutComposer.keyboardId(internal),
				inputSource
			};
		const ansi = macos.ansi_internal_name || `${internal}_ansi`;
		return {
			internal: ansi,
			display: macos.ansi_display_name || `${source.layout.name} ANSI`,
			keyboardId: own(macos, 'ansi_keyboard_id')
				? macos.ansi_keyboard_id
				: LayoutComposer.keyboardId(ansi),
			inputSource: `${inputSource}.ansi`
		};
	}

	/**
	 * The .keylayout action id of every dead key: an explicit action_id, else its
	 * terminator when that is one free character, else dead_<state>.
	 */
	function deadActionIds(source, identities) {
		const ids = new Map();
		const taken = new Set(identities);
		for (const dead of source.dead_keys || []) {
			const state = dead.state || dead.id;
			let id = dead.action_id;
			if (id === undefined)
				id =
					scalars(dead.terminator) === 1 && !taken.has(dead.terminator)
						? dead.terminator
						: `dead_${state}`;
			if (taken.has(id)) fail('source_action_conflict', `dead_keys.${dead.id}.action_id`);
			taken.add(id);
			ids.set(dead.id, id);
		}
		return ids;
	}

	// =============================
	// ======= 4/ Compilation ======
	// =============================

	/** The modifierMap tokens a platform's compilation may use. */
	function platformTokens(platform) {
		return TARGETS[platform].tokens;
	}

	/** One modifier combination as a modifierMap keys attribute, or null when the target has no token. */
	function selectorKeys(selector, tokens = TOKENS) {
		const keys = [];
		for (const [ids, suffix] of [
			[selector.required, ''],
			[selector.optional, '?']
		])
			for (const id of ids) {
				if (!own(tokens, id) || tokens[id] === null) return null;
				keys.push(tokens[id] + suffix);
			}
		return keys.join(' ');
	}

	/** True when a remap moves one character key onto another (or disables it). */
	function nativeRemap(table, from, to) {
		return table.character.has(from) && (to === '' || table.character.has(to));
	}

	/**
	 * A layer's mappings for one platform and variant. A remap reads the layer
	 * before any remap applies, so swapping two keys is two plain entries.
	 */
	function layerKeys(source, layer, platform, variant, table) {
		const original = Object.assign({}, layer.keys, (layer.platform_keys || {})[platform] || {});
		let keys = Object.assign({}, original);
		for (const [from, to] of Object.entries(source.remap || {})) {
			if (!nativeRemap(table, from, to)) continue;
			if (to === '') keys[from] = { disabled: true };
			else if (original[to] !== undefined) keys[from] = original[to];
			else delete keys[from];
		}
		if (variant === 'ansi')
			keys = Object.assign(swapped(keys, ansiPairs(source)), layer.ansi_keys || {});
		return keys;
	}

	/**
	 * The records of a source no .keylayout can hold, each with its path and reason.
	 * The compiled .keylayout is the intermediate form of every native target, so
	 * this list is common to macOS, Linux and Windows.
	 */
	function omissions(source, table, platform) {
		const omitted = [];
		const note = (path, reason) => omitted.push({ path, reason });
		const custom = new Set((source.modifiers || []).map((modifier) => modifier.id));
		for (const modifier of source.modifiers || [])
			note(`modifiers.${modifier.id}`, 'custom_modifier_not_in_keylayout');
		(source.layers || []).forEach((layer) => {
			const selectors = [layer, ...(layer.alternatives || [])];
			if (selectors.every((selector) => selectorKeys(selector, platformTokens(platform)) !== null))
				return;
			const ids = selectors.flatMap((selector) => [...selector.required, ...selector.optional]);
			const reason = ids.some((id) => custom.has(id) || !own(TOKENS, id))
				? 'modifier_not_in_keylayout'
				: `sided_modifier_not_in_${platform}`;
			note(`layers.${layer.id}`, reason);
		});
		for (const [from, to] of Object.entries(source.remap || {}))
			if (!nativeRemap(table, from, to)) note(`remap.${from}`, 'system_or_modifier_key_remap');
		for (const [field, reason] of [
			['shortcuts', 'shortcut_output_not_in_keylayout'],
			// config-key-literal-ok: field of the versioned layout format, not application config.
			['tap_holds', 'tap_hold_not_in_keylayout']
		])
			(source[field] || []).forEach((entry) => note(`${field}.${entry.key}`, reason));
		if (source.windows) note('windows', 'windows_only_flags');
		for (const [key, entry] of Object.entries(source.keys || {}))
			for (const field of Object.keys(entry))
				if (field !== 'name') note(`keys.${key}.${field}`, 'layer_selection_owns_caps_lock');
		return omitted;
	}

	/**
	 * Compile a structured source into one .keylayout.
	 * @param {object} source - A validated structured source (no imported_keylayout).
	 * @param {object} tables - {macKeycodes, physicalKeys, hidUsages}.
	 * @param {{variant?: 'iso'|'ansi', platform?: 'macos'|'linux'|'windows'}} [options]
	 * @returns {{text: string, convention: 'iso', names: object, omitted: object[]}}
	 */
	function compileKeylayout(source, tables, options = {}) {
		LayoutSource.validate(source);
		const variant = options.variant || 'iso';
		const platform = options.platform || 'macos';
		if (!VARIANTS.includes(variant)) fail('source_variant', String(variant));
		if (!Object.hasOwn(TARGETS, platform)) fail('source_platform', String(platform));
		if (source.imported_keylayout) fail('source_imported_preserved', 'imported_keylayout');
		const table = keyTable(tables, 'iso');
		const defaults = systemDefaults();
		const omitted = omissions(source, table, platform);
		const deadById = new Map((source.dead_keys || []).map((dead) => [dead.id, dead]));
		const stateOf = (id) => deadById.get(id).state || id;

		// Every text a dead-key rule answers to, and every key text that composes.
		const ruleInputs = new Set();
		for (const dead of source.dead_keys || [])
			for (const rule of dead.rules) if (own(rule, 'input')) ruleInputs.add(rule.input);
		const layers = [];
		for (const layer of source.layers || []) {
			const selectors = [layer, ...(layer.alternatives || [])].map((selector) =>
				selectorKeys(selector, platformTokens(platform))
			);
			if (selectors.includes(null)) continue;
			layers.push({ layer, selectors, keys: layerKeys(source, layer, platform, variant, table) });
		}
		const identities = new Set(ruleInputs);
		const composes = (mapping) =>
			mapping.compose !== false && (own(mapping, 'compose_as') || ruleInputs.has(mapping.text));
		for (const { keys } of layers)
			for (const mapping of Object.values(keys))
				if (own(mapping, 'text') && composes(mapping))
					identities.add(own(mapping, 'compose_as') ? mapping.compose_as : mapping.text);
		const deadActions = deadActionIds(source, identities);

		// Actions in first-use order: keys by layer then position, then unbound rule inputs.
		const actions = new Map();
		const textAction = (identity, text, path) => {
			if (!actions.has(identity)) actions.set(identity, { output: text, next: '' });
			else if (actions.get(identity).output !== text) fail('source_compose_conflict', path);
			return identity;
		};
		const deadAction = (id) => {
			const action = deadActions.get(id);
			if (!actions.has(action)) actions.set(action, { output: '', next: stateOf(id) });
			return action;
		};
		let maxout = 1;
		const keyMaps = layers.map(({ layer, keys }) => {
			const rows = new Map();
			for (const [name, mapping] of Object.entries(keys)) {
				const path = `layers.${layer.id}.keys.${name}`;
				const mac = table.code(name);
				if (mac === undefined || MODIFIER_KEYS.has(name)) {
					omitted.push({ path, reason: 'physical_key_not_in_keylayout' });
					continue;
				}
				if (!TARGETS[platform].unnamedMacCodes && !table.byName.has(name)) {
					omitted.push({ path, reason: `mac_only_key_code_not_in_${platform}` });
					continue;
				}
				if (own(mapping, 'text')) {
					maxout = Math.max(maxout, scalars(mapping.text));
					rows.set(
						mac,
						composes(mapping)
							? ['action', textAction(mapping.compose_as || mapping.text, mapping.text, path)]
							: ['output', mapping.text]
					);
				} else if (own(mapping, 'dead_key'))
					rows.set(mac, ['action', deadAction(mapping.dead_key)]);
				else if (own(mapping, 'disabled')) {
					// The converters refuse a control output on a character key: there the key
					// becomes an empty cell, which XKB and KLC report and may let inherit.
					if (TARGETS[platform].disabledCharacterCell || !table.character.has(name))
						rows.set(mac, ['output', UNUSED]);
					else omitted.push({ path, reason: 'disabled_key_is_empty_cell' });
				} else
					omitted.push({
						path,
						reason: own(mapping, 'action')
							? 'action_not_in_keylayout'
							: 'key_chord_not_in_keylayout'
					});
			}
			for (const [mac, output] of defaults) if (!rows.has(mac)) rows.set(mac, ['output', output]);
			return rows;
		});
		// A rule input no key types keeps its action, as an imported file had it; a
		// dead key only reached through a chain needs none.
		for (const input of ruleInputs) if (!actions.has(input)) textAction(input, input, 'dead_keys');
		for (const dead of source.dead_keys || [])
			for (const rule of dead.rules)
				if (own(rule, 'input_dead_key')) deadAction(rule.input_dead_key);

		// Transitions, attached to the action of the typed text or of the pressed dead key.
		const whens = new Map([...actions.keys()].map((id) => [id, []]));
		for (const dead of source.dead_keys || [])
			for (const rule of dead.rules) {
				const action = own(rule, 'input') ? rule.input : deadActions.get(rule.input_dead_key);
				const text = own(rule, 'text') ? rule.text : '';
				maxout = Math.max(maxout, scalars(text));
				whens.get(action).push({
					state: stateOf(dead.id),
					output: text,
					next: own(rule, 'next') ? stateOf(rule.next) : ''
				});
			}

		const names = variantNames(source, variant);
		const esc = LayoutComposer.escapeAttribute;
		const lines = [
			'<?xml version="1.1" encoding="UTF-8"?>',
			'<!DOCTYPE keyboard SYSTEM "file://localhost/System/Library/DTDs/KeyboardLayout.dtd">',
			'<!-- Generated by the Ergopti layout source compiler; edit the TOML source instead. -->',
			`<keyboard group="${LayoutComposer.KEYBOARD_GROUP}" id="${names.keyboardId}" maxout="${maxout}" name="${esc(names.internal)}">`,
			'\t<layouts>',
			'\t\t<layout first="0" last="0" mapSet="layout" modifiers="modifiers"/>',
			'\t</layouts>',
			'\t<modifierMap id="modifiers" defaultIndex="0">'
		];
		layers.forEach(({ selectors }, index) => {
			lines.push(`\t\t<keyMapSelect mapIndex="${index}">`);
			for (const keys of selectors) lines.push(`\t\t\t<modifier keys="${keys}"/>`);
			lines.push('\t\t</keyMapSelect>');
		});
		lines.push('\t</modifierMap>', '\t<keyMapSet id="layout">');
		keyMaps.forEach((rows, index) => {
			lines.push(`\t\t<keyMap index="${index}">`);
			for (const mac of [...rows.keys()].sort((a, b) => a - b)) {
				const [kind, value] = rows.get(mac);
				lines.push(`\t\t\t<key code="${mac}" ${kind}="${esc(value)}"/>`);
			}
			lines.push('\t\t</keyMap>');
		});
		lines.push('\t</keyMapSet>', '\t<actions>');
		for (const [id, neutral] of actions) {
			lines.push(`\t\t<action id="${esc(id)}">`);
			for (const when of [{ state: NEUTRAL, ...neutral }, ...whens.get(id)]) {
				const output =
					when.output === '' && when.next !== '' ? '' : ` output="${esc(when.output)}"`;
				const next = when.next === '' ? '' : ` next="${esc(when.next)}"`;
				lines.push(`\t\t\t<when state="${esc(when.state)}"${output}${next}/>`);
			}
			lines.push('\t\t</action>');
		}
		lines.push('\t</actions>', '\t<terminators>');
		for (const dead of source.dead_keys || [])
			lines.push(`\t\t<when state="${esc(stateOf(dead.id))}" output="${esc(dead.terminator)}"/>`);
		lines.push('\t</terminators>', '</keyboard>');
		return { text: lines.join('\n') + '\n', convention: 'iso', names, omitted };
	}

	// ===========================
	// ======= 5/ Emulation ======
	// ===========================

	const EMULATION_FORMAT = 'ergopti-layout-emulation';
	const EMULATION_VERSION = 1;
	// The built-in modifiers a driver reports, by family; a sided id other than
	// alt_right (AltGr, macOS Option) is not reported by the Linux hook or the
	// macOS tap flags, so a layer needing one cannot be selected by the engine.
	const REPORTED = new Set(['shift', 'control', 'alt', 'alt_right', 'meta', 'caps_lock']);

	/** A mapping the engine can perform, or the reason it cannot. */
	function emulatedMapping(mapping, sendable) {
		if (own(mapping, 'text')) return { text: mapping.text };
		if (own(mapping, 'key')) {
			if (!sendable(mapping.key)) return 'physical_key_not_emulated';
			return { key: mapping.key, modifiers: (mapping.modifiers || []).slice() };
		}
		if (own(mapping, 'disabled')) return { disabled: true };
		return own(mapping, 'dead_key') ? 'dead_key_not_emulated' : 'action_not_emulated';
	}

	/**
	 * The records a platform's compiled .keylayout leaves out, as the table the
	 * ErgoptiPlus drivers and the web emulation perform on top of it: custom
	 * modifiers and their layers, key-chord mappings, shortcuts sending another
	 * key, tap-holds and the remaps of system keys. What even the emulation
	 * cannot perform is listed in not_emulated with its path and reason.
	 * @param {object} source - A validated structured source.
	 * @param {object} tables - {macKeycodes, physicalKeys, hidUsages}.
	 * @param {{platform?: 'macos'|'linux'|'windows'}} [options]
	 * @returns {object} The emulation table (JSON-serializable).
	 */
	function compileEmulation(source, tables, options = {}) {
		LayoutSource.validate(source);
		const platform = options.platform || 'macos';
		if (!Object.hasOwn(TARGETS, platform)) fail('source_platform', String(platform));
		if (source.imported_keylayout) fail('source_imported_preserved', 'imported_keylayout');
		const table = keyTable(tables, 'iso');
		const custom = new Set((source.modifiers || []).map((modifier) => modifier.id));
		const notEmulated = [];
		const skip = (path, reason) => notEmulated.push({ path, reason });
		// A key a driver can press for the user: one of the registry's own keys.
		const sendable = (name) =>
			own(tables.physicalKeys.keys, name) && tables.physicalKeys.keys[name].kind === 'key';
		// A physical key the drivers see as a key press of its own (not a modifier flag).
		const pressable = (name, path) => {
			if (MODIFIER_KEYS.has(name)) skip(path, 'modifier_key_not_emulated');
			else if (!sendable(name)) skip(path, 'physical_key_not_emulated');
			else return true;
			return false;
		};
		const reported = (ids) => ids.every((id) => custom.has(id) || REPORTED.has(id));

		// Every custom modifier is listed, keyless when none of its keys can be seen:
		// a tap-hold can still hold it, and the engine refuses an undeclared id.
		const modifiers = (source.modifiers || []).map((modifier) => ({
			id: modifier.id,
			mode: modifier.mode,
			keys: modifier.keys.filter((key, index) =>
				pressable(key, `modifiers.${modifier.id}.keys[${index}]`)
			)
		}));

		const layers = (source.layers || []).map((layer) => {
			const selectors = [layer, ...(layer.alternatives || [])].map((selector) => ({
				required: selector.required.slice(),
				optional: selector.optional.slice()
			}));
			const native = selectors.every(
				(selector) => selectorKeys(selector, platformTokens(platform)) !== null
			);
			const ids = selectors.flatMap((selector) => [...selector.required, ...selector.optional]);
			const entry = { id: layer.id, selectors, native, keys: {} };
			if (!native && !reported(ids)) {
				skip(`layers.${layer.id}`, 'sided_modifier_not_emulated');
				entry.selectable = false;
				return entry;
			}
			for (const [name, mapping] of Object.entries(
				layerKeys(source, layer, platform, 'iso', table)
			)) {
				const path = `layers.${layer.id}.keys.${name}`;
				// The compiled .keylayout already types a native layer's text, dead keys and
				// disabled keys; the emulation adds what it leaves out.
				if (native && !own(mapping, 'key') && !own(mapping, 'action')) continue;
				if (!pressable(name, path)) continue;
				const emulated = emulatedMapping(mapping, sendable);
				if (typeof emulated === 'string') skip(path, emulated);
				else entry.keys[name] = emulated;
			}
			return entry;
		});

		const shortcuts = [];
		for (const [index, shortcut] of (source.shortcuts || []).entries()) {
			const path = `shortcuts[${index}]`;
			if (!pressable(shortcut.key, path)) continue;
			if (!sendable(shortcut.send_key)) skip(`${path}.send_key`, 'physical_key_not_emulated');
			else if (!reported([...shortcut.modifiers, ...shortcut.send_modifiers]))
				skip(path, 'sided_modifier_not_emulated');
			else
				shortcuts.push({
					key: shortcut.key,
					modifiers: shortcut.modifiers.slice(),
					send_key: shortcut.send_key,
					send_modifiers: shortcut.send_modifiers.slice()
				});
		}

		const tapHolds = [];
		for (const [index, entry] of (source.tap_holds || []).entries()) {
			const path = `tap_holds[${index}]`;
			if (!pressable(entry.key, path)) continue;
			const tap = emulatedMapping(entry.tap, sendable);
			if (typeof tap === 'string') {
				skip(`${path}.tap`, tap);
				continue;
			}
			const hold = own(entry, 'hold_layer')
				? { hold_layer: entry.hold_layer }
				: { hold_modifier: entry.hold_modifier };
			if (own(hold, 'hold_modifier') && !reported([hold.hold_modifier])) {
				skip(`${path}.hold_modifier`, 'sided_modifier_not_emulated');
				continue;
			}
			tapHolds.push({ key: entry.key, tap, ...hold, threshold_ms: entry.threshold_ms });
		}

		const remaps = [];
		for (const [from, to] of Object.entries(source.remap || {})) {
			if (nativeRemap(table, from, to)) continue;
			const path = `remap.${from}`;
			if (!pressable(from, path)) continue;
			if (to !== '' && MODIFIER_KEYS.has(to)) skip(path, 'modifier_target_not_emulated');
			else if (to !== '' && !sendable(to)) skip(path, 'physical_key_not_emulated');
			else remaps.push({ key: from, to });
		}

		return {
			format: EMULATION_FORMAT,
			version: EMULATION_VERSION,
			layout: source.layout.id,
			platform,
			modifiers,
			layers,
			shortcuts,
			tap_holds: tapHolds,
			remaps,
			not_emulated: notEmulated
		};
	}

	// ========================
	// ======= 6/ Import ======
	// ========================

	/** Parse one modifierMap keys attribute into source modifier ids. */
	function readSelector(keys, path) {
		const selector = { required: [], optional: [] };
		for (const token of keys.split(/[ \t]+/)) {
			if (token === '') continue;
			const optional = token.endsWith('?');
			const name = optional ? token.slice(0, -1) : token;
			if (!own(FROM_TOKEN, name)) fail('source_import_modifier', `${path}:${token}`);
			(optional ? selector.optional : selector.required).push(FROM_TOKEN[name]);
		}
		return selector;
	}

	/** A layer id from its first selector's required modifiers, unique within the source. */
	function layerId(selector, taken, index) {
		const required = NAME_ORDER.filter((id) => selector.required.includes(id));
		let id = required.length ? required.join('_') : 'base';
		if (taken.has(id)) id = `${id}_${index}`;
		taken.add(id);
		return id;
	}

	/**
	 * The keyMapSet of the ANSI hardware, for a file declaring several hardware
	 * layouts: null for a single one. Accepted only as Bépo has them, every layout
	 * on one modifierMap, keyboard type 0 on the ISO map the import reads and every
	 * other type on one ANSI map; the source then holds the ANSI variant itself.
	 */
	function ansiMapSet(model, convention) {
		if (model.layoutCount === 1) return null;
		const sets = new Set(model.layouts.map((layout) => layout.mapSet));
		const first = model.layouts.find((layout) => layout.first === '0');
		const others = model.layouts.filter((layout) => layout.mapSet !== first.mapSet);
		if (
			convention !== 'iso' ||
			sets.size !== 2 ||
			model.layouts.some((layout) => layout.modifiers !== first.modifiers) ||
			model.layouts.some((layout) => layout.mapSet === first.mapSet && layout !== first) ||
			first.last !== '0'
		)
			fail('source_import_hardware_layouts', 'layouts');
		return others[0].mapSet;
	}

	/**
	 * Import a .keylayout into structured records that compile back to the same
	 * behaviour. Refuses what the records cannot hold instead of approximating it.
	 * @param {string} text - The .keylayout content.
	 * @param {string} id - Source identifier.
	 * @param {'iso'|'ansi'} convention - The file's keycode numbering.
	 * @param {object} tables - {macKeycodes, physicalKeys, hidUsages}.
	 */
	function importStructured(text, id, convention, tables) {
		if (!VARIANTS.includes(convention)) fail('source_invalid', 'convention');
		if (/<!ENTITY\b/i.test(text)) fail('source_xml_entity', 'keylayout');
		let model;
		try {
			model = LayoutComposer.parseModel(text);
		} catch (error) {
			fail('source_keylayout', error.code || error.message);
		}
		const ansiSet = ansiMapSet(model, convention);
		if (model.defaultIndex !== 0) fail('source_import_default_index', 'modifier_map.default_index');
		const table = keyTable(tables, convention);
		const defaults = systemDefaults();

		// Dead-key states, in terminator order, then in order of first reference.
		const stateIds = new Map();
		const usedIds = new Set();
		const addState = (state) => {
			if (stateIds.has(state) || state === NEUTRAL || state === '') return;
			let base = ID.test(state) ? state : `s_${state.toLowerCase().replace(/[^a-z0-9_]/g, '_')}`;
			let candidate = base;
			for (let n = 2; usedIds.has(candidate); n++) candidate = `${base}_${n}`;
			usedIds.add(candidate);
			stateIds.set(state, candidate);
		};
		for (const state of model.terminators.keys()) addState(state);
		for (const whens of model.actions.values())
			for (const [state, when] of whens) {
				addState(state);
				addState(when.next);
			}

		// Classify actions: a dead key enters a state from neutral, a text action types.
		const deadOfState = new Map();
		const composing = new Set();
		for (const [action, whens] of model.actions) {
			const neutral = whens.get(NEUTRAL);
			if (!neutral) fail('source_import_action_without_neutral', action);
			if (neutral.next !== '') {
				if (neutral.output !== '') fail('source_import_dead_key_output', action);
				if (deadOfState.has(neutral.next)) fail('source_import_dead_key_conflict', action);
				deadOfState.set(neutral.next, action);
			} else if (whens.size > 1) composing.add(action);
		}

		/** One keyMap entry as a named mapping, or null for a key left implicit. */
		const keyMapping = (entry, mac, at) => {
			let name = table.byMac.get(mac);
			if (entry.kind === 'output') {
				if (name === undefined && LayoutComposer.isPrintable(entry.value)) name = `MacCode${mac}`;
				if (name === undefined || MODIFIER_KEYS.has(name)) {
					if (LayoutComposer.isPrintable(entry.value)) fail('source_import_unnamed_key', at);
					return null;
				}
				if (!table.character.has(name) && defaults.get(mac) === entry.value) return null;
				if (entry.value === UNUSED) return { name, mapping: { disabled: true } };
				const mapping = { text: entry.value };
				if (composing.has(entry.value)) mapping.compose = false;
				return { name, mapping };
			}
			const whens = model.actions.get(entry.value);
			if (!whens) fail('source_import_undefined_action', at);
			const neutral = whens.get(NEUTRAL);
			if (name === undefined && neutral.next === '' && LayoutComposer.isPrintable(neutral.output))
				name = `MacCode${mac}`;
			if (name === undefined || MODIFIER_KEYS.has(name)) fail('source_import_unnamed_key', at);
			if (neutral.next !== '') return { name, mapping: { dead_key: stateIds.get(neutral.next) } };
			const mapping = { text: neutral.output };
			if (entry.value !== neutral.output) mapping.compose_as = entry.value;
			return { name, mapping };
		};

		const layers = [];
		const takenLayers = new Set();
		model.selects.forEach((select, position) => {
			const selectors = select.keys.map((keys, index) =>
				readSelector(keys, `keyMapSelect[${position}].modifier[${index}]`)
			);
			const layer = { id: layerId(selectors[0], takenLayers, select.index), ...selectors[0] };
			if (selectors.length > 1) layer.alternatives = selectors.slice(1);
			layer.keys = {};
			for (let mac = 0; mac <= MAX_CODE; mac++) {
				const entry = LayoutComposer.keyEntry(model, select.index, mac);
				const imported = entry && keyMapping(entry, mac, `keyMap[${select.index}].key[${mac}]`);
				if (imported) layer.keys[imported.name] = imported.mapping;
			}
			if (ansiSet !== null) {
				// The ANSI map is read in the same numbering, so it differs from the
				// derived ANSI variant exactly where the rule moves too little.
				const ansiModel = Object.assign({}, model, { mapSet: ansiSet });
				const derived = swapped(layer.keys, ansiPairs({ physical: {} }));
				const ansiKeys = {};
				for (let mac = 0; mac <= MAX_CODE; mac++) {
					const at = `ANSI keyMap[${select.index}].key[${mac}]`;
					const entry = LayoutComposer.keyEntry(ansiModel, select.index, mac);
					const imported = entry && keyMapping(entry, mac, at);
					const name = imported ? imported.name : table.byMac.get(mac);
					if (name === undefined) continue;
					const expected = imported ? imported.mapping : undefined;
					if (JSON.stringify(expected) === JSON.stringify(derived[name])) continue;
					// An ANSI key that types nothing where the derivation types something has no record.
					if (expected === undefined) fail('source_import_hardware_layouts', at);
					ansiKeys[name] = expected;
				}
				if (Object.keys(ansiKeys).length) layer.ansi_keys = ansiKeys;
			}
			layers.push(layer);
		});

		const deadKeys = [];
		for (const [state, dead] of stateIds) {
			const record = { id: dead };
			if (dead !== state) record.state = state;
			const action = deadOfState.get(state);
			if (action !== undefined) record.action_id = action;
			record.terminator = model.terminators.get(state) || '';
			record.rules = [];
			deadKeys.push(record);
		}
		const byState = new Map(deadKeys.map((record) => [record.state || record.id, record]));
		const referenced = new Set();
		for (const maps of model.keyMapSets.values())
			for (const keys of maps.values())
				for (const entry of keys.values()) if (entry.kind === 'action') referenced.add(entry.value);
		for (const [action, whens] of model.actions) {
			// No key reaches an action with an empty id (Bépo declares one), and no rule
			// can answer to empty text: it has no behaviour to keep.
			if (action === '' && !referenced.has(action)) continue;
			const neutral = whens.get(NEUTRAL);
			for (const [state, when] of whens) {
				if (state === NEUTRAL) continue;
				const rule =
					neutral.next !== '' ? { input_dead_key: stateIds.get(neutral.next) } : { input: action };
				if (when.next !== '' && when.next !== NEUTRAL) rule.next = stateIds.get(when.next);
				if (when.output !== '' || rule.next === undefined) rule.text = when.output;
				byState.get(state).rules.push(rule);
			}
		}

		const source = {
			format: LayoutSource.FORMAT,
			version: LayoutSource.VERSION,
			layout: { id, name: model.name || id },
			physical: { base: 'iso' },
			layers,
			...(deadKeys.length ? { dead_keys: deadKeys } : {}),
			exports: { macos: { format: 'bundle' } }
		};
		if (model.name !== id) source.exports.macos.internal_name = model.name;
		const keyboardId = Number(model.keyboardId);
		if (model.keyboardId !== '' && Number.isSafeInteger(keyboardId))
			source.exports.macos.keyboard_id = keyboardId;
		LayoutSource.validate(source);
		// Drop each action_id the compiler would derive anyway, so the TOML stays short.
		const identities = new Set();
		for (const layer of layers)
			for (const mapping of Object.values(layer.keys))
				if (own(mapping, 'text') && mapping.compose !== false)
					identities.add(mapping.compose_as || mapping.text);
		for (const record of deadKeys)
			for (const rule of record.rules) if (rule.input) identities.add(rule.input);
		const derived = deadActionIds(
			{ dead_keys: deadKeys.map(({ action_id, ...rest }) => rest) },
			identities
		);
		for (const record of deadKeys)
			if (record.action_id === derived.get(record.id)) delete record.action_id;
		return LayoutSource.validate(source);
	}

	// ==============================
	// ======= 7/ macOS export ======
	// ==============================

	/**
	 * Wrap one square PNG into an .icns holding it as its size's element. The
	 * image itself is the user's; only its header is read.
	 * @param {Uint8Array} png
	 * @param {string} path - Source path named in a refusal.
	 * @returns {Uint8Array}
	 */
	function icns(png, path) {
		// Checked by shape: a page or a Node vm passes bytes from another realm.
		if (!ArrayBuffer.isView(png) || png.BYTES_PER_ELEMENT !== 1 || png.length < 24)
			fail('source_icon_png', path);
		const view = new DataView(png.buffer, png.byteOffset, png.byteLength);
		const header = String.fromCharCode(...png.subarray(12, 16));
		if (PNG_SIGNATURE.some((byte, index) => png[index] !== byte) || header !== 'IHDR')
			fail('source_icon_png', path);
		const width = view.getUint32(16);
		const type = ICNS_TYPES.get(width);
		if (type === undefined || view.getUint32(20) !== width) fail('source_icon_size', path);
		const out = new Uint8Array(16 + png.length);
		const outView = new DataView(out.buffer);
		out.set(
			[...'icns'].map((c) => c.charCodeAt(0)),
			0
		);
		outView.setUint32(4, out.length);
		out.set(
			[...type].map((c) => c.charCodeAt(0)),
			8
		);
		outView.setUint32(12, 8 + png.length);
		out.set(png, 16);
		return out;
	}

	const plistEscape = (text) =>
		text.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
	const stringsEscape = (text) => text.replace(/\\/g, '\\\\').replace(/"/g, '\\"');

	/**
	 * The macOS artifacts: a bundle holding ISO and ANSI (the default), or one
	 * .keylayout. InfoPlist.strings entries are UTF-16LE with a byte-order mark,
	 * as the shipped Ergopti bundles carry them. `exports.macos.icon` (and
	 * `ansi_icon` for the ANSI variant, else the same) names a PNG whose bytes the
	 * caller passes in `icons`, keyed by that name; each variant gets its .icns.
	 * @param {object} [icons] - PNG file name -> Uint8Array.
	 * @returns {{files: {path: string, text?: string, bytes?: Uint8Array,
	 *   encoding: 'utf8'|'utf16le'|'binary'}[], report: object}}
	 */
	function exportMacos(source, tables, format, icons = {}) {
		LayoutSource.validate(source);
		const declared = (source.exports && source.exports.macos) || {};
		const iconOf = (variant) => {
			const field = variant === 'ansi' && own(declared, 'ansi_icon') ? 'ansi_icon' : 'icon';
			if (!own(declared, field)) return null;
			const png = own(icons, declared[field]) ? icons[declared[field]] : undefined;
			if (png === undefined) fail('source_icon_missing', `exports.macos.${field}`);
			return icns(png, `exports.macos.${field}`);
		};
		const chosen = format || ((source.exports && source.exports.macos) || {}).format || 'bundle';
		if (!MACOS_FORMATS.includes(chosen)) fail('source_invalid', 'exports.macos.format');
		const variants = chosen === 'bundle' ? VARIANTS : [chosen];
		const compiled = variants.map((variant) => ({
			variant,
			icon: iconOf(variant),
			...compileKeylayout(source, tables, { variant })
		}));
		const files = [];
		if (chosen !== 'bundle') {
			// A loose .keylayout takes the .icns of the same name beside it.
			const [only] = compiled;
			files.push({ path: `${only.names.internal}.keylayout`, text: only.text, encoding: 'utf8' });
			if (only.icon)
				files.push({ path: `${only.names.internal}.icns`, bytes: only.icon, encoding: 'binary' });
		} else {
			const macos = (source.exports && source.exports.macos) || {};
			const version = macos.version || DEFAULT_VERSION;
			const language = (source.layout.languages || [])[0];
			const root = `${compiled[0].names.internal}.bundle/Contents`;
			const entries = compiled.map(({ names, icon }) =>
				[
					`\t<key>KLInfo_${plistEscape(names.internal)}</key>`,
					'\t<dict>',
					'\t\t<key>TICapsLockLanguageSwitchCapable</key>',
					'\t\t<true/>',
					...(icon
						? [
								'\t\t<key>TISIconIsTemplate</key>',
								'\t\t<false/>',
								'\t\t<key>ICNS</key>',
								`\t\t<string>${plistEscape(names.internal)}.icns</string>`
							]
						: []),
					'\t\t<key>TISInputSourceID</key>',
					`\t\t<string>${plistEscape(names.inputSource)}</string>`,
					...(language
						? [
								'\t\t<key>TISIntendedLanguage</key>',
								`\t\t<string>${plistEscape(language)}</string>`
							]
						: []),
					'\t</dict>'
				].join('\n')
			);
			const header = [
				'<?xml version="1.0" encoding="UTF-8"?>',
				'<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">',
				'<plist version="1.0">',
				'<dict>'
			];
			const info = [
				...header,
				'\t<key>CFBundleIdentifier</key>',
				`\t<string>${plistEscape(compiled[0].names.inputSource)}</string>`,
				'\t<key>CFBundleName</key>',
				`\t<string>${plistEscape(source.layout.name)}</string>`,
				'\t<key>CFBundleShortVersionString</key>',
				`\t<string>${plistEscape(version)}</string>`,
				'\t<key>CFBundleVersion</key>',
				`\t<string>${plistEscape(version)}</string>`,
				...entries,
				'</dict>',
				'</plist>'
			];
			const versionPlist = [
				...header,
				'\t<key>BuildVersion</key>',
				`\t<string>${plistEscape(version)}</string>`,
				'\t<key>ProjectName</key>',
				`\t<string>${plistEscape(source.layout.name)}</string>`,
				'\t<key>SourceVersion</key>',
				`\t<string>${plistEscape(version)}</string>`,
				'</dict>',
				'</plist>'
			];
			files.push({ path: `${root}/Info.plist`, text: info.join('\n') + '\n', encoding: 'utf8' });
			files.push({
				path: `${root}/version.plist`,
				text: versionPlist.join('\n') + '\n',
				encoding: 'utf8'
			});
			for (const { names, text, icon } of compiled) {
				files.push({
					path: `${root}/Resources/${names.internal}.keylayout`,
					text,
					encoding: 'utf8'
				});
				if (icon)
					files.push({
						path: `${root}/Resources/${names.internal}.icns`,
						bytes: icon,
						encoding: 'binary'
					});
			}
			// The strings key is the internal name; macOS refuses a bundle keyed otherwise.
			const strings = compiled
				.map(
					({ names }) => `"${stringsEscape(names.internal)}" = "${stringsEscape(names.display)}";`
				)
				.join('\n');
			for (const locale of ['en', 'fr'])
				files.push({
					path: `${root}/Resources/${locale}.lproj/InfoPlist.strings`,
					text: '﻿' + strings + '\n',
					encoding: 'utf16le'
				});
		}
		const internals = new Set(compiled.map(({ names }) => names.internal));
		if (internals.size !== compiled.length)
			fail('source_duplicate', 'exports.macos.ansi_internal_name');
		return {
			files,
			report: {
				target: 'macos',
				status: compiled[0].omitted.length ? 'partial' : 'native',
				artifact: chosen === 'bundle' ? 'bundle' : 'keylayout',
				format: chosen,
				variants: compiled.map(({ variant, names }) => ({ variant, ...names })),
				omitted: compiled[0].omitted,
				limitations: [
					...(compiled.some(({ icon }) => icon === null)
						? ['A variant without exports.macos.icon shows the generic layout icon.']
						: []),
					'Native loading by macOS is not certified by this export; install and select it to check.'
				]
			}
		};
	}

	/**
	 * The .keylayout a converter target reads: the preserved import unchanged, or
	 * the ISO compilation of a structured source for that platform.
	 */
	function targetKeylayout(source, tables, platform) {
		LayoutSource.validate(source);
		if (source.imported_keylayout) return { ...LayoutSource.conversionSource(source), omitted: [] };
		const compiled = compileKeylayout(source, tables, { variant: 'iso', platform });
		return { text: compiled.text, convention: compiled.convention, omitted: compiled.omitted };
	}

	return {
		TOKENS,
		MODIFIER_KEYS,
		MACOS_FORMATS,
		keyTable,
		ansiPairs,
		compileKeylayout,
		compileEmulation,
		importStructured,
		exportMacos,
		targetKeylayout
	};
})();
