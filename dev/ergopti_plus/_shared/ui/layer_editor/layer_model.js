// _shared/ui/layer_editor/layer_model.js

/**
 * ==============================================================================
 * MODULE: Layer Editor Model
 * DESCRIPTION:
 * The pure half of the navigation layer editor. It reads a layer file into a
 * document, applies the editor's edits to it, says what a binding means and
 * whether it exists on an OS, and writes the document back as a layer file.
 * It touches no DOM: the page (script.js) and the Node tests (in a vm
 * context, as the classic script a page loads) run this file unchanged, and
 * the generated LAYER_EDITOR_DATA (_generated/layer_data.js) is the only
 * knowledge it has of keys and actions.
 *
 * FEATURES & RATIONALE:
 * 1. One file format: the reader takes the line-oriented TOML subset every
 *    loader reads (_shared/keymap/layer_actions.toml, "File format") and
 *    refuses what they refuse as toml_invalid; the writer writes only that
 *    subset.
 * 2. An edit made on one OS never changes what another OS does: a binding is
 *    written to that OS's section, and making a key native on one OS moves a
 *    shared `all` entry into the other OSes' sections before removing it.
 * 3. Restore and Clear act on the whole layer, every OS at once: they are the
 *    two presets, Ergopti's recommended layer and no layer at all.
 * 4. The host validates every saved file with its own loader on every OS;
 *    this model only offers what the generated data says exists on the OS it
 *    edits for, and says why the rest does not.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm
// context), which is how script.js and the tests reach the model.
var LayerModel = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const SECTION_ALL = 'all';
	const BOM = '﻿';

	// The layer-file format, as tools/lib/keymap-layers.cjs states it.
	const CONTROL_CHARACTER = /[\u0000-\u0008\u000A-\u001F\u007F]/;
	const TABLE_HEADER = /^\[[ \t]*([A-Za-z0-9_-]+(?:[ \t]*\.[ \t]*[A-Za-z0-9_-]+)*)[ \t]*\][ \t]*(?:#.*)?$/;
	const KEY_VALUE = /^(?:([A-Za-z0-9_-]+)|"((?:[^"\\]|\\.)*)"|'([^']*)')[ \t]*=[ \t]*(.*)$/;
	const BASIC_STRING_VALUE = /^"((?:[^"\\]|\\.)*)"[ \t]*(?:#.*)?$/;
	const LITERAL_STRING_VALUE = /^'([^']*)'[ \t]*(?:#.*)?$/;
	const BOOLEAN_VALUE = /^(true|false)[ \t]*(?:#.*)?$/;
	const INTEGER_VALUE = /^([+-]?(?:0|[1-9](?:_?[0-9])*))[ \t]*(?:#.*)?$/;
	const FLOAT_VALUE = /^([+-]?(?:0|[1-9][0-9]*)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?)[ \t]*(?:#.*)?$/;
	const MAX_INTEGER_DIGITS = 15;
	const MAX_UNICODE_SCALAR = 0x10ffff;
	const SURROGATE_FIRST = 0xd800;
	const SURROGATE_LAST = 0xdfff;
	const SIMPLE_ESCAPES = { b: '\b', t: '\t', n: '\n', f: '\f', r: '\r', '"': '"', '\\': '\\' };

	// What the saved file says about itself. The format allows comments only on
	// their own line, so the header is written as comment lines.
	const FILE_HEADER = [
		'# layers.toml — written by the ErgoptiPlus layer editor.',
		'#',
		'# Each [layers.<layer>.<section>] table binds physical keys, named by their',
		'# W3C KeyboardEvent.code, while the layer is held. `all` applies on every',
		'# system; a `windows`, `macos` or `linux` entry replaces it on that system.',
		'# The values are the actions of _shared/keymap/layer_actions.toml.'
	];

	// Key legends a code does not spell out by itself. Letters, digits and
	// function keys read from the code (KeyQ -> Q, Digit1 -> 1, F5 -> F5).
	const LEGENDS = {
		Escape: 'Esc',
		Backquote: '`',
		Minus: '-',
		Equal: '=',
		Backspace: '⌫',
		Tab: '⇥',
		BracketLeft: '[',
		BracketRight: ']',
		Backslash: '\\',
		CapsLock: '⇪',
		Semicolon: ';',
		Quote: "'",
		Enter: '↵',
		ShiftLeft: '⇧',
		ShiftRight: '⇧',
		IntlBackslash: '<',
		Comma: ',',
		Period: '.',
		Slash: '/',
		Space: '␣',
		ContextMenu: '☰',
		Insert: 'Ins',
		Delete: '⌦',
		Home: '⇱',
		End: '⇲',
		PageUp: '⇞',
		PageDown: '⇟',
		ArrowUp: '↑',
		ArrowDown: '↓',
		ArrowLeft: '←',
		ArrowRight: '→',
		NumLock: 'Num',
		NumpadDivide: '/',
		NumpadMultiply: '*',
		NumpadSubtract: '-',
		NumpadAdd: '+',
		NumpadEnter: '↵',
		NumpadDecimal: '.',
		AudioVolumeMute: '🔇',
		AudioVolumeDown: '🔉',
		AudioVolumeUp: '🔊'
	};

	// Legends that follow the OS's own keycaps.
	const OS_LEGENDS = {
		windows: { ControlLeft: 'Ctrl', ControlRight: 'Ctrl', AltLeft: 'Alt', AltRight: 'AltGr', MetaLeft: 'Win', MetaRight: 'Win' },
		macos: { ControlLeft: '⌃', ControlRight: '⌃', AltLeft: '⌥', AltRight: '⌥', MetaLeft: '⌘', MetaRight: '⌘' },
		linux: { ControlLeft: 'Ctrl', ControlRight: 'Ctrl', AltLeft: 'Alt', AltRight: 'AltGr', MetaLeft: 'Super', MetaRight: 'Super' }
	};

	// Modifier names in a chord, and what joins them, as each OS writes them.
	const MODIFIER_NAMES = {
		windows: { ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', meta: 'Win', fn: 'Fn' },
		macos: { ctrl: '⌃', alt: '⌥', shift: '⇧', meta: '⌘', fn: 'fn' },
		linux: { ctrl: 'Ctrl', alt: 'Alt', shift: 'Shift', meta: 'Super', fn: 'Fn' }
	};
	const CHORD_JOINERS = { windows: '+', macos: '', linux: '+' };

	const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
	const isTable = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);





	// ==============================
	// ======= 2/ File reader =======
	// ==============================

	/**
	 * Decodes the contents of a TOML basic string (TOML 1.0 escapes only).
	 * @param {string} contents - The text between the quotes.
	 * @returns {string} The decoded text.
	 * @throws {Error} On an escape the format does not allow.
	 */
	function unescapeBasic(contents) {
		let out = '';
		for (let i = 0; i < contents.length; i++) {
			const c = contents[i];
			if (c !== '\\') {
				out += c;
				continue;
			}
			const next = contents[i + 1];
			if (hasOwn(SIMPLE_ESCAPES, next)) {
				out += SIMPLE_ESCAPES[next];
				i += 1;
				continue;
			}
			const width = next === 'u' ? 4 : next === 'U' ? 8 : 0;
			const hex = contents.slice(i + 2, i + 2 + width);
			if (width === 0 || hex.length !== width || /[^0-9A-Fa-f]/.test(hex)) throw new Error(`"\\${next}" is not a TOML escape`);
			const code = parseInt(hex, 16);
			if (code === 0 || code > MAX_UNICODE_SCALAR || (code >= SURROGATE_FIRST && code <= SURROGATE_LAST))
				throw new Error(`"\\${next}${hex}" is not a character a layer file can hold`);
			out += String.fromCodePoint(code);
			i += 1 + width;
		}
		return out;
	}

	/**
	 * Reads one value of the format.
	 * @param {string} text - Everything after the `=` of a line.
	 * @returns {string|boolean|number}
	 * @throws {Error} When the value is not a one-line string, a boolean or a number.
	 */
	function parseValue(text) {
		let m = BASIC_STRING_VALUE.exec(text);
		if (m) return unescapeBasic(m[1]);
		m = LITERAL_STRING_VALUE.exec(text);
		if (m) return m[1];
		m = BOOLEAN_VALUE.exec(text);
		if (m) return m[1] === 'true';
		m = INTEGER_VALUE.exec(text);
		if (m) {
			const digits = m[1].replace(/[+_-]/g, '');
			if (digits.length > MAX_INTEGER_DIGITS) throw new Error(`an integer has at most ${MAX_INTEGER_DIGITS} digits`);
			return Number(m[1].replace(/_/g, ''));
		}
		m = FLOAT_VALUE.exec(text);
		if (m) return Number(m[1]);
		throw new Error('a value is a one-line string, true, false, a decimal integer or a decimal float');
	}

	/**
	 * Parses a layer file into nested plain objects.
	 * @param {string} text - The file content.
	 * @returns {{root: object|null, problem: string|null}} The tables, or the
	 *   first line that is outside the format.
	 */
	function parseToml(text) {
		const body = text.startsWith(BOM) ? text.slice(BOM.length) : text;
		const rootTable = {};
		// dotted path -> "table" (a header), "implicit" (a header's parent) or "value"
		const kinds = new Map();
		let current = rootTable;
		let currentPath = [];
		const lines = body.split('\n');
		for (let index = 0; index < lines.length; index++) {
			const where = `line ${index + 1}`;
			let line = lines[index];
			if (line.endsWith('\r')) line = line.slice(0, -1);
			if (CONTROL_CHARACTER.test(line)) return { root: null, problem: `${where}: control characters other than tab are not allowed` };
			line = line.replace(/^[ \t]+|[ \t]+$/g, '');
			if (line === '' || line.startsWith('#')) continue;
			if (line.startsWith('[')) {
				const header = TABLE_HEADER.exec(line);
				if (!header) return { root: null, problem: `${where}: a table header names bare keys only, like [layers.nav.all]` };
				const segments = header[1].split('.').map((s) => s.trim());
				let node = rootTable;
				for (let depth = 0; depth < segments.length; depth++) {
					const path = JSON.stringify(segments.slice(0, depth + 1));
					const kind = kinds.get(path);
					if (kind === 'value') return { root: null, problem: `${where}: "${segments[depth]}" is already a value, not a table` };
					if (depth === segments.length - 1) {
						if (kind === 'table') return { root: null, problem: `${where}: this table is defined twice` };
						kinds.set(path, 'table');
					} else if (kind === undefined) {
						kinds.set(path, 'implicit');
					}
					if (!hasOwn(node, segments[depth])) node[segments[depth]] = {};
					node = node[segments[depth]];
				}
				current = node;
				currentPath = segments;
				continue;
			}
			const pair = KEY_VALUE.exec(line);
			if (!pair) return { root: null, problem: `${where}: expected a table header or one key = value pair (dotted keys are not part of the format)` };
			let key;
			let value;
			try {
				key = pair[1] !== undefined ? pair[1] : pair[2] !== undefined ? unescapeBasic(pair[2]) : pair[3];
				value = parseValue(pair[4]);
			} catch (e) {
				return { root: null, problem: `${where}: ${e.message}` };
			}
			const path = JSON.stringify(currentPath.concat([key]));
			if (kinds.has(path)) return { root: null, problem: `${where}: "${key}" is defined twice` };
			kinds.set(path, 'value');
			current[key] = value;
		}
		return { root: rootTable, problem: null };
	}

	/**
	 * Reads a user's layer file into the document the editor edits.
	 * @param {string|null} text - The file content, or null when there is none.
	 * @param {object} data - LAYER_EDITOR_DATA.
	 * @returns {{doc: {layers: object}, problem: string|null}} The document, or
	 *   an empty one and why the file cannot be edited.
	 */
	function readLayerFile(text, data) {
		const empty = () => ({ layers: {} });
		if (text === null || text === undefined) return { doc: empty(), problem: null };
		if (typeof text !== 'string') return { doc: empty(), problem: 'the file content is not text' };
		const parsed = parseToml(text);
		if (parsed.problem) return { doc: empty(), problem: parsed.problem };
		const rootTable = parsed.root;
		if (Object.keys(rootTable).length === 0) return { doc: empty(), problem: null };
		const meta = rootTable._meta;
		if (!isTable(meta) || meta.schema_version !== data.schema_version)
			return { doc: empty(), problem: `[_meta].schema_version must be ${data.schema_version}` };
		const layers = rootTable.layers === undefined ? {} : rootTable.layers;
		if (!isTable(layers)) return { doc: empty(), problem: '"layers" must be a table' };
		const doc = empty();
		for (const layerId of Object.keys(layers)) {
			const layer = layers[layerId];
			if (!isTable(layer)) return { doc: empty(), problem: `layers.${layerId} must be a table` };
			doc.layers[layerId] = {};
			for (const section of Object.keys(layer)) {
				if (!isTable(layer[section])) return { doc: empty(), problem: `layers.${layerId}.${section} must be a table` };
				doc.layers[layerId][section] = Object.assign({}, layer[section]);
			}
		}
		return { doc, problem: null };
	}





	// ==============================
	// ======= 3/ File writer =======
	// ==============================

	/** A TOML basic string holding any text. */
	function quote(text) {
		let out = '"';
		for (const c of String(text)) {
			const code = c.codePointAt(0);
			if (c === '"' || c === '\\') out += '\\' + c;
			else if (code < 0x20 || code === 0x7f) out += '\\u' + code.toString(16).toUpperCase().padStart(4, '0');
			else out += c;
		}
		return out + '"';
	}

	/** One value as the format writes it. */
	function formatValue(value) {
		if (typeof value === 'string') return quote(value);
		if (typeof value === 'boolean' || (typeof value === 'number' && Number.isFinite(value))) return String(value);
		throw new Error(`a layer file cannot hold ${JSON.stringify(value)}`);
	}

	/** The codes of a section: registry order first, then any other sorted. */
	function orderedCodes(section, data) {
		const known = data.keys.map((k) => k.code).filter((code) => hasOwn(section, code));
		const others = Object.keys(section)
			.filter((code) => !known.includes(code))
			.sort();
		return known.concat(others);
	}

	/**
	 * Writes a document as a layer file.
	 * @param {{layers: object}} doc - The document.
	 * @param {object} data - LAYER_EDITOR_DATA.
	 * @returns {string} The file content, LF line ends and a final newline.
	 */
	function serialize(doc, data) {
		const lines = FILE_HEADER.concat(['', '[_meta]', `schema_version = ${data.schema_version}`]);
		const layerIds = Object.keys(doc.layers).sort((a, b) => (a === data.layer ? -1 : b === data.layer ? 1 : a < b ? -1 : a > b ? 1 : 0));
		for (const layerId of layerIds) {
			const layer = doc.layers[layerId];
			const standard = [SECTION_ALL].concat(data.platforms);
			const sections = standard.filter((s) => hasOwn(layer, s)).concat(
				Object.keys(layer)
					.filter((s) => !standard.includes(s))
					.sort()
			);
			for (const section of sections) {
				const codes = orderedCodes(layer[section], data);
				if (codes.length === 0) continue;
				lines.push('', `[layers.${layerId}.${section}]`);
				for (const code of codes) lines.push(`${quote(code)} = ${formatValue(layer[section][code])}`);
			}
		}
		return lines.join('\n') + '\n';
	}





	// ========================
	// ======= 4/ Edits =======
	// ========================

	/** A deep copy of a JSON-shaped value. */
	const copy = (value) => JSON.parse(JSON.stringify(value));

	/** Drops the empty sections of a layer, and the layer once it is empty. */
	function prune(doc, layerId) {
		const layer = doc.layers[layerId];
		if (!layer) return;
		for (const section of Object.keys(layer)) if (Object.keys(layer[section]).length === 0) delete layer[section];
		if (Object.keys(layer).length === 0) delete doc.layers[layerId];
	}

	/**
	 * What each key of a layer does on one OS: its OS entry, else its `all` entry.
	 * @returns {Object<string, {value: any, section: string}>}
	 */
	function effective(doc, layerId, os) {
		const layer = doc.layers[layerId] || {};
		const out = {};
		for (const section of [SECTION_ALL, os]) {
			const table = layer[section];
			if (!isTable(table)) continue;
			for (const code of Object.keys(table)) out[code] = { value: table[code], section };
		}
		return out;
	}

	/**
	 * Binds a key on one OS, leaving every other OS as it was.
	 * @param {object} doc - The document, changed in place.
	 * @param {string} layerId - The layer.
	 * @param {string} os - The OS the edit is made for.
	 * @param {string} code - The physical key.
	 * @param {string} value - The binding.
	 */
	function setBinding(doc, layerId, os, code, value) {
		if (!hasOwn(doc.layers, layerId)) doc.layers[layerId] = {};
		const layer = doc.layers[layerId];
		const all = layer[SECTION_ALL] || {};
		if (hasOwn(all, code) && all[code] === value) {
			if (layer[os]) delete layer[os][code];
		} else {
			if (!layer[os]) layer[os] = {};
			layer[os][code] = value;
		}
		prune(doc, layerId);
	}

	/**
	 * Gives a key its normal behaviour back on one OS, leaving every other OS as
	 * it was: a shared `all` entry moves into the other OSes' sections first.
	 * @param {object} doc - The document, changed in place.
	 * @param {string} layerId - The layer.
	 * @param {string} os - The OS the edit is made for.
	 * @param {string} code - The physical key.
	 * @param {string[]} platforms - Every OS.
	 */
	function makeNative(doc, layerId, os, code, platforms) {
		const layer = doc.layers[layerId];
		if (!layer) return;
		if (layer[os]) delete layer[os][code];
		const all = layer[SECTION_ALL];
		if (all && hasOwn(all, code)) {
			const shared = all[code];
			delete all[code];
			for (const other of platforms) {
				if (other === os || (layer[other] && hasOwn(layer[other], code))) continue;
				if (!layer[other]) layer[other] = {};
				layer[other][code] = shared;
			}
		}
		prune(doc, layerId);
	}

	/** Replaces a layer, on every OS, with Ergopti's recommended one. */
	function restoreRecommended(doc, layerId, recommended) {
		doc.layers[layerId] = copy(recommended);
		prune(doc, layerId);
	}

	/** Removes a layer on every OS: every key keeps its normal behaviour. */
	function clearLayer(doc, layerId) {
		delete doc.layers[layerId];
	}





	// ===================================
	// ======= 5/ Meaning of a value =====
	// ===================================

	// data -> Map(code -> registry entry), built once per data object.
	const keyIndexes = new WeakMap();

	/** The registry entry of a code, or undefined. */
	function keyEntry(code, data) {
		if (!keyIndexes.has(data)) keyIndexes.set(data, new Map(data.keys.map((k) => [k.code, k])));
		return keyIndexes.get(data).get(code);
	}

	/**
	 * Parses a binding value.
	 * @returns {{type: 'action', id: string}|{type: 'repeat_count', count: number}|
	 *   {type: 'keystroke', chords: {mods: string[], key: string}[]}|{type: 'invalid', problem: string}}
	 */
	function parseBinding(value, data) {
		if (typeof value !== 'string') return { type: 'invalid', problem: 'a binding must be a string' };
		const colon = value.indexOf(':');
		if (colon < 0) {
			if (hasOwn(data.actions, value)) return { type: 'action', id: value };
			return { type: 'invalid', problem: `"${value}" is not a layer action` };
		}
		const head = value.slice(0, colon);
		const rest = value.slice(colon + 1);
		if (head === 'repeat_count') {
			const count = Number(rest);
			if (!/^[0-9]+$/.test(rest) || count < data.repeat_count.min || count > data.repeat_count.max)
				return { type: 'invalid', problem: `repeat_count takes an integer from ${data.repeat_count.min} to ${data.repeat_count.max}` };
			return { type: 'repeat_count', count };
		}
		if (head === 'keystroke') {
			const chords = [];
			for (const part of rest.split(',')) {
				const tokens = part.split('+');
				const key = tokens.pop();
				const entry = keyEntry(key, data);
				if (!entry || entry.kind !== 'key') return { type: 'invalid', problem: `"${key}" is not a keyboard key` };
				const seen = new Set();
				for (const mod of tokens) {
					if (mod !== 'primary' && !data.modifier_order.includes(mod)) return { type: 'invalid', problem: `unknown modifier "${mod}"` };
					if (seen.has(mod)) return { type: 'invalid', problem: `modifier "${mod}" named twice` };
					seen.add(mod);
				}
				chords.push({ mods: tokens, key });
			}
			return { type: 'keystroke', chords };
		}
		return { type: 'invalid', problem: `"${head}:" is not a binding form` };
	}

	/**
	 * Whether a binding exists on one OS.
	 * @returns {{ok: boolean, reason_key: string|null}}
	 */
	function bindingAvailability(value, os, data) {
		const binding = parseBinding(value, data);
		if (binding.type === 'invalid') return { ok: false, reason_key: null };
		if (binding.type === 'action') {
			const action = data.actions[binding.id];
			return action.platforms.includes(os) ? { ok: true, reason_key: null } : { ok: false, reason_key: action.reason_key };
		}
		if (binding.type === 'repeat_count')
			return data.repeat_count.platforms.includes(os) ? { ok: true, reason_key: null } : { ok: false, reason_key: data.repeat_count.reason_key };
		for (const chord of binding.chords) {
			for (const raw of chord.mods) {
				const mod = raw === 'primary' ? data.primary_modifier[os] : raw;
				const rule = data.modifiers[mod];
				if (!rule.platforms.includes(os)) return { ok: false, reason_key: rule.reason_key };
			}
		}
		return { ok: true, reason_key: null };
	}

	/**
	 * Whether a physical input can be a layer key on one OS.
	 * @returns {{ok: boolean, reason_key: string|null}}
	 */
	function inputAvailability(code, os, data) {
		const entry = keyEntry(code, data);
		if (!entry) return { ok: false, reason_key: null };
		const rule = data.source_kinds[entry.kind];
		return rule.platforms.includes(os) ? { ok: true, reason_key: null } : { ok: false, reason_key: rule.reason_key };
	}

	/** The keycap legend of a code on one OS. */
	function keyLegend(code, os) {
		const own = OS_LEGENDS[os] || {};
		if (hasOwn(own, code)) return own[code];
		if (hasOwn(LEGENDS, code)) return LEGENDS[code];
		let m = /^Key([A-Z])$/.exec(code);
		if (m) return m[1];
		m = /^(?:Digit|Numpad)([0-9])$/.exec(code);
		if (m) return m[1];
		if (/^F[0-9]{1,2}$/.test(code)) return code;
		return code;
	}

	/** A modifier's name as the OS writes it on its keycaps and menus. */
	function modifierName(mod, os) {
		return MODIFIER_NAMES[os][mod];
	}

	/** A chord list as the OS writes shortcuts: Ctrl+Shift+Home, ⇧⌘Z. */
	function chordText(chords, os, data) {
		const names = MODIFIER_NAMES[os];
		return chords
			.map((chord) => {
				const mods = new Set(chord.mods.map((m) => (m === 'primary' ? data.primary_modifier[os] : m)));
				const ordered = os === 'macos' ? ['ctrl', 'alt', 'shift', 'meta', 'fn'] : data.modifier_order;
				const parts = ordered.filter((m) => mods.has(m)).map((m) => names[m]);
				parts.push(keyLegend(chord.key, os));
				return parts.join(CHORD_JOINERS[os]);
			})
			.join(', ');
	}

	/**
	 * What a binding does, in words.
	 * @param {any} value - A binding value, or undefined for none.
	 * @param {string} os - The OS it is read for.
	 * @param {object} data - LAYER_EDITOR_DATA.
	 * @param {function(string, ...any): string} t - The page's translator.
	 * @returns {string}
	 */
	function describeBinding(value, os, data, t) {
		if (value === undefined) return t('layer_editor.value.native');
		const binding = parseBinding(value, data);
		if (binding.type === 'invalid') return t('layer_editor.value.invalid', String(value));
		if (binding.type === 'action') return t(data.actions[binding.id].label_key);
		if (binding.type === 'repeat_count') return t('layer_editor.value.repeat_count', binding.count);
		return t('layer_editor.value.keystroke', chordText(binding.chords, os, data));
	}

	/**
	 * The picker's rows, in the shared action picker's item shape
	 * ({type: 'heading', level, text} and {type: 'action', id, label}), plus
	 * whether each action exists on the OS and why not.
	 */
	function pickerItems(data, os, t) {
		const items = [];
		for (const group of data.groups) {
			items.push({ type: 'heading', level: 1, id: group.id, text: t(group.label_key) });
			for (const id of group.actions) {
				const action = data.actions[id];
				const available = action.platforms.includes(os);
				items.push({ type: 'action', id, label: t(action.label_key), available, reason: available ? null : t(action.reason_key) });
			}
		}
		return items;
	}

	return {
		SECTION_ALL,
		parseToml,
		readLayerFile,
		serialize,
		effective,
		setBinding,
		makeNative,
		restoreRecommended,
		clearLayer,
		keyEntry,
		parseBinding,
		bindingAvailability,
		inputAvailability,
		keyLegend,
		modifierName,
		chordText,
		describeBinding,
		pickerItems
	};
})();
