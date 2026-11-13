// _shared/ui/layout_composer/target_compiler.js

/**
 * ==============================================================================
 * MODULE: Ergopti Layout Source Target Compiler
 * DESCRIPTION:
 * Compiles a structured layout source straight to what the Linux XKB and the
 * Windows KLC writers read, with no macOS .keylayout in between: each target
 * chooses which source modifier reaches which of its own levels, so a layer
 * held by a sided modifier, Kana or a custom modifier keeps its characters
 * where the format has a level for it.
 *
 * - XKB: Shift, Caps Lock, AltGr (Alt, right Alt and Kana) and the shortcut
 *   level as before; one more held or locked modifier on XKB's fifth level,
 *   its keys typing ISO_Level5_Shift or ISO_Level5_Lock (any modifier key:
 *   Caps Lock, a sided Shift, Control, Alt or Win key, Menu).
 * - KLC: base, Shift and AltGr columns as before; the Kana, Roya and Loya bits
 *   (KBDKANA, KBDROYA, KBDLOYA) for Kana and for held custom or sided
 *   modifiers whose key a KLC can move (a plain scan code, not an E0 one).
 *
 * What a target still cannot carry goes in its omission list with a stable
 * reason; the driver emulation table (compileEmulation) performs it.
 *
 * FEATURES & RATIONALE:
 * 1. Pure classic script loaded after source_compiler.js: no file, process or
 *    DOM access; the page and the Node tools run the same code.
 * 2. A source using none of these levels compiles to exactly the canonical
 *    form reading its compiled .keylayout gives, so the existing layouts stay
 *    byte for byte (tools/test/test-layout-source-compiler.cjs).
 * 3. Decided by the agent on 2026-11-13, to review by the maintainer: one
 *    extra XKB level (the first modifier in layer order whose keys can hold
 *    it); the KLC Kana bit only when the Kana key has a plain scan code
 *    (Right Alt, the default, keeps Kana on the AltGr columns as before).
 * ==============================================================================
 */

var LayoutTargetCompiler = (function () {
	'use strict';

	// Built-in modifier -> the canonical token both writers read (the .keylayout
	// reader folds sides away; right Alt is AltGr on a PC keyboard).
	const FOLDED = {
		shift: 'shift',
		alt: 'option',
		alt_right: 'option',
		control: 'control',
		meta: 'command',
		caps_lock: 'caps'
	};
	// The physical key of each sided built-in modifier that is not AltGr.
	const SIDED_KEYS = {
		shift_left: 'ShiftLeft',
		shift_right: 'ShiftRight',
		control_left: 'ControlLeft',
		control_right: 'ControlRight',
		alt_left: 'AltLeft',
		meta_left: 'MetaLeft',
		meta_right: 'MetaRight'
	};
	const DEFAULT_KANA_KEY = 'AltRight';

	// XKB keycode names (evdev) of the modifier keys that can hold the fifth
	// level. A character key keeps its row; Right Alt stays AltGr (the template
	// includes level3(ralt_switch)).
	const XKB_LEVEL5_KEYS = {
		CapsLock: 'CAPS',
		ShiftLeft: 'LFSH',
		ShiftRight: 'RTSH',
		ControlLeft: 'LCTL',
		ControlRight: 'RCTL',
		AltLeft: 'LALT',
		MetaLeft: 'LWIN',
		MetaRight: 'RWIN',
		ContextMenu: 'MENU'
	};
	const XKB_LEVEL5_TOKEN = 'level5';
	const XKB_LEVEL5_KEYSYMS = { held: 'ISO_Level5_Shift', locked: 'ISO_Level5_Lock' };

	// KLC modifier bits beyond Shift, Ctrl and Alt, and the virtual key a KLC
	// LAYOUT row puts on the modifier's key (kbd.h, MSKLC's VK names).
	const KLC_BITS = {
		kana: { shift_state: 8, vk: 'KANA' },
		roya: { shift_state: 16, vk: 'OEM_FJ_ROYA' },
		loya: { shift_state: 32, vk: 'OEM_FJ_LOYA' }
	};
	// A KLC LAYOUT row names a one-byte scan code: E0 keys cannot move.
	const MAX_KLC_SCAN_CODE = 0x7f;

	const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);
	const unique = (list) => [...new Set(list)];

	/** Every selector of a layer: itself and its alternatives. */
	function selectors(layer) {
		return [layer, ...(layer.alternatives || [])];
	}

	/** Modifier ids of a layer's selectors, required and optional. */
	function layerIds(layer) {
		return unique(
			selectors(layer).flatMap((selector) => [...selector.required, ...selector.optional])
		);
	}

	/** The ids no base token covers, in layer order: each target's candidates. */
	function extraIds(source, base) {
		return unique(
			(source.layers || []).flatMap((layer) =>
				layerIds(layer).filter((id) => !own(base, id) || base[id] === null)
			)
		);
	}

	/**
	 * What holds a modifier: its mode and keys (a custom declaration, a sided
	 * built-in's own key, Kana's key), or null for one with no key of its own.
	 */
	function holder(source, id) {
		const custom = (source.modifiers || []).find((modifier) => modifier.id === id);
		if (custom) return { mode: custom.mode, keys: custom.keys.slice() };
		if (own(SIDED_KEYS, id)) return { mode: 'held', keys: [SIDED_KEYS[id]] };
		if (id === 'kana')
			return {
				mode: 'held',
				keys: [(source.windows && source.windows.kana_key) || DEFAULT_KANA_KEY]
			};
		return null;
	}

	/** The base tokens of both targets: Kana on AltGr unless Alt selects a layer. */
	function baseTokens(source) {
		return Object.assign({}, FOLDED, {
			kana: LayoutSourceCompiler.usesAlt(source) ? null : 'option'
		});
	}

	/**
	 * Why a layer the tokens leave out is left out of a target.
	 * @param {object} source
	 * @param {object} tokens - The target's tokens.
	 * @param {Map<string, string>} refused - Modifier id -> its own reason.
	 * @param {string} taken - The reason of a candidate another modifier beat.
	 */
	function layerReason(source, tokens, refused, taken) {
		return (layer) => {
			const missing = layerIds(layer).filter((id) => !own(tokens, id) || tokens[id] === null);
			for (const id of missing) if (refused.has(id)) return refused.get(id);
			return missing.length ? taken : 'modifier_not_in_target';
		};
	}

	// =============================
	// ======= 1/ Linux XKB ========
	// =============================

	/**
	 * The XKB plan of a source: its tokens and the modifier on the fifth level.
	 * @param {object} source - A validated structured source.
	 * @returns {{tokens: object, level5: object|null, refused: Map<string, string>, omitted: object[]}}
	 */
	function xkbPlan(source) {
		const tokens = baseTokens(source);
		const refused = new Map();
		const omitted = [];
		let level5 = null;
		for (const id of extraIds(source, tokens)) {
			const held = holder(source, id);
			if (held === null) {
				refused.set(id, 'modifier_without_key_not_in_xkb');
				continue;
			}
			if (id === 'kana' && held.keys.every((key) => key === DEFAULT_KANA_KEY)) {
				refused.set(id, 'kana_level_taken_by_alt');
				continue;
			}
			const keys = held.keys.filter((key) => own(XKB_LEVEL5_KEYS, key));
			if (!keys.length) {
				refused.set(id, 'modifier_key_cannot_hold_xkb_level5');
				continue;
			}
			if (level5 !== null) {
				refused.set(id, 'xkb_level5_taken');
				continue;
			}
			for (const key of held.keys)
				if (!keys.includes(key))
					omitted.push({
						path: `modifiers.${id}.keys.${key}`,
						reason: 'modifier_key_cannot_hold_xkb_level5'
					});
			level5 = {
				modifier: id,
				mode: held.mode,
				keys: keys.map((key) => ({
					key,
					xkb: XKB_LEVEL5_KEYS[key],
					keysym: XKB_LEVEL5_KEYSYMS[held.mode]
				}))
			};
			tokens[id] = XKB_LEVEL5_TOKEN;
		}
		return { tokens, level5, refused, omitted };
	}

	// =============================
	// ======= 2/ Windows KLC ======
	// =============================

	/** The one-byte scan code of a physical key, or null for an E0 or unknown one. */
	function plainScanCode(tables, key) {
		const entry = tables.physicalKeys.keys[key];
		const match = entry && /^SC([0-9A-F]{3})$/.exec(entry.ahk || '');
		if (!match) return null;
		const sc = parseInt(match[1], 16);
		return sc <= MAX_KLC_SCAN_CODE ? sc : null;
	}

	/**
	 * The KLC plan of a source: its tokens, and each Kana, Roya or Loya bit with
	 * the modifier and key that hold it.
	 * @param {object} source - A validated structured source.
	 * @param {object} tables - {macKeycodes, physicalKeys, hidUsages}.
	 * @returns {{tokens: object, bits: object[], refused: Map<string, string>, omitted: object[]}}
	 */
	function klcPlan(source, tables) {
		const tokens = baseTokens(source);
		const refused = new Map();
		const omitted = [];
		const bits = [];
		const characterKeys = new Set(tables.macKeycodes.keys.map((key) => key.code));
		const free = ['roya', 'loya', 'kana'];
		const usesKana = (source.layers || []).some((layer) => layerIds(layer).includes('kana'));
		// The key a bit's virtual key goes on, or the reason it cannot.
		const placed = (keys) => {
			for (const key of keys) {
				if (characterKeys.has(key)) continue;
				const sc = plainScanCode(tables, key);
				if (sc !== null) return { key, scan_code: sc };
			}
			return null;
		};
		const take = (id, bit, key) => {
			free.splice(free.indexOf(bit), 1);
			bits.push(
				Object.assign({ modifier: id, bit, shift_state: KLC_BITS[bit].shift_state }, key, {
					vk: KLC_BITS[bit].vk
				})
			);
			tokens[id] = bit;
		};
		if (usesKana) {
			const kanaKey = placed(holder(source, 'kana').keys);
			// Right Alt (E0) keeps Kana on the AltGr columns, as before.
			if (kanaKey !== null) take('kana', 'kana', kanaKey);
			else if (tokens.kana === null) refused.set('kana', 'kana_level_taken_by_alt');
		}
		const candidates = extraIds(source, tokens).filter((id) => id !== 'kana');
		// A custom modifier named after a bit takes that bit first.
		candidates.sort(
			(a, b) =>
				Number(!(free.includes(a) && a !== 'kana')) - Number(!(free.includes(b) && b !== 'kana'))
		);
		for (const id of candidates) {
			const held = holder(source, id);
			if (held === null) {
				refused.set(id, 'modifier_without_key_not_in_klc');
				continue;
			}
			if (held.mode !== 'held') {
				refused.set(id, 'locked_modifier_not_in_klc');
				continue;
			}
			const key = placed(held.keys);
			if (key === null) {
				refused.set(id, 'modifier_key_not_in_klc');
				continue;
			}
			const bit = free.includes(id) && id !== 'kana' ? id : free[0];
			if (bit === undefined) {
				refused.set(id, 'klc_modifier_bits_taken');
				continue;
			}
			take(id, bit, key);
		}
		return { tokens, bits, refused, omitted };
	}

	// =============================
	// ======= 3/ Compilation ======
	// =============================

	/**
	 * Compile a structured source for one converter target.
	 * @param {object} source - A validated structured source.
	 * @param {object} tables - {macKeycodes, physicalKeys, hidUsages}.
	 * @param {'linux'|'windows'} platform
	 * @returns {{canonical: object, convention: 'iso', omitted: object[], plan: object}}
	 */
	function compile(source, tables, platform) {
		const linux = platform === 'linux';
		if (!linux && platform !== 'windows')
			throw new LayoutSource.SourceError('source_platform', String(platform));
		const plan = linux ? xkbPlan(source) : klcPlan(source, tables);
		const compiled = LayoutSourceCompiler.compileCanonical(source, tables, {
			platform,
			tokens: plan.tokens,
			format: linux ? 'xkb' : 'klc',
			layerReason: layerReason(
				source,
				plan.tokens,
				plan.refused,
				linux ? 'xkb_level5_taken' : 'klc_modifier_bits_taken'
			)
		});
		const report = linux
			? { level5: plan.level5 }
			: {
					modifier_bits: plan.bits.map((bit) => Object.assign({}, bit))
				};
		return {
			canonical: compiled.canonical,
			convention: compiled.convention,
			omitted: plan.omitted.concat(compiled.omitted),
			plan: report
		};
	}

	/**
	 * What a converter target reads: the preserved import's XML (read by the
	 * shared Lua reader), or the canonical form a structured source compiles to.
	 * @returns {{text?: string, canonical?: object, convention: string, omitted: object[], plan?: object}}
	 */
	function target(source, tables, platform) {
		LayoutSource.validate(source);
		if (source.imported_keylayout)
			return Object.assign({}, LayoutSource.conversionSource(source), { omitted: [] });
		return compile(source, tables, platform);
	}

	return { XKB_LEVEL5_KEYS, KLC_BITS, xkbPlan, klcPlan, compile, target };
})();
