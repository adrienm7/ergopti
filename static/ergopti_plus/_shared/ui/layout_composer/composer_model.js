// _shared/ui/layout_composer/composer_model.js

/**
 * ==============================================================================
 * MODULE: Layout Composer Model
 * DESCRIPTION:
 * The pure core of the per-layer layout composer. It reads registry layouts
 * (.keylayout) into sources, builds a layout from four layers (base, Shift,
 * AltGr, Shift+AltGr) that each come from any source, adds a shortcuts layer
 * for the held Ctrl, Alt and Win keys, applies the user's key-by-key
 * overrides, validates the declaration, and writes the result as one complete
 * .keylayout. It touches no DOM and no file: the page and the Node tests (in a
 * vm context, as the classic script a page loads) run this file unchanged.
 *
 * FEATURES & RATIONALE:
 * 1. One output format. Every driver already reads, installs or converts a
 *    registry .keylayout, so the composer's only product is such a file
 *    (docs/layout-composer.md); no driver re-implements the composition.
 * 2. The reader follows the rules of the Windows reader
 *    (windows/modules/keymap/keylayout/keylayout_parser.ahk) and the Linux
 *    converter: comments stripped, character references decoded, control
 *    characters type nothing, modifierMap tokens folded, baseMapSet followed;
 *    the shared vectors (_shared/tests/corpus/layouts/keylayout_vectors.json)
 *    pin it to the same answers.
 * 3. Dead keys compose by character, not by position: the composed layout
 *    gives each typed character the compositions its dead keys' source
 *    defines, so a QWERTY letter under an AZERTY circumflex still makes its
 *    accented form.
 * 4. Fail fast: validation returns stable problem codes and a composition with
 *    a problem is never serialized.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
var LayoutComposer = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const SCHEMA_VERSION = 1;

	// The id the compiled composition goes by in every driver. The registry may
	// not hold a layout of this id (tools/test/test-layout-composer-model.cjs).
	const COMPOSED_ID = 'composed';

	const LAYER_IDS = ['base', 'shift', 'altgr', 'shift_altgr'];
	// What a source offers: its four layers and its own Command level.
	const SOURCE_LAYERS = LAYER_IDS.concat(['command']);
	// Derived from base and Shift, overridable key by key, never a source.
	const CAPS_LAYER = 'caps';
	const SHORTCUT_MODIFIERS = ['meta', 'ctrl', 'alt'];
	const OVERRIDE_TARGETS = LAYER_IDS.concat([CAPS_LAYER], SHORTCUT_MODIFIERS);
	const CONVENTIONS = ['iso', 'ansi'];

	const NEUTRAL_STATE = 'none';
	const ID_PATTERN = /^[a-z][a-z0-9_]*$/;
	const MAX_OUTPUT_CODE_POINTS = 8;
	const MAX_NAME_CODE_POINTS = 64;
	const MAX_BASE_DEPTH = 8;
	const STATE_SEPARATOR = '__';

	// modifierMap tokens (Apple TN2056) folded onto the modifiers a layout tells
	// apart; left and right variants are not told apart.
	const MODIFIER_TOKENS = {
		shift: 'shift',
		rightShift: 'shift',
		anyShift: 'shift',
		option: 'option',
		rightOption: 'option',
		anyOption: 'option',
		control: 'control',
		rightControl: 'control',
		anyControl: 'control',
		command: 'command',
		caps: 'caps'
	};

	// The modifiers a source layer is read with.
	const PRESSED = {
		base: [],
		shift: ['shift'],
		altgr: ['option'],
		shift_altgr: ['shift', 'option'],
		command: ['command']
	};

	// keyMap index and modifier selector of every composed level. The selectors
	// are mutually exclusive, so the first match is the only one.
	const LEVELS = [
		{ id: 'base', index: 0, keys: '' },
		{ id: 'shift', index: 1, keys: 'anyShift caps?' },
		{ id: CAPS_LAYER, index: 2, keys: 'caps' },
		{ id: 'altgr', index: 3, keys: 'anyOption caps?' },
		{ id: 'shift_altgr', index: 4, keys: 'anyShift anyOption caps?' },
		{ id: 'meta', index: 5, keys: 'command anyShift? caps?' },
		{ id: 'ctrl', index: 6, keys: 'anyControl anyShift? caps?' },
		{ id: 'alt', index: 7, keys: 'anyOption command anyShift? caps?' }
	];

	// The keys that type no character, written the way every registry file
	// writes them: [macOS code, output]. Control characters are C0 codes.
	const UNUSED_OUTPUT = 0x10;
	const OTHER_KEYS = [
		[36, 0x0d],
		[48, 0x09],
		[51, 0x08],
		[52, 0x03],
		[53, 0x1b],
		[64, UNUSED_OUTPUT],
		[65, '.'],
		[66, 0x1d],
		[67, '*'],
		[69, '+'],
		[70, 0x1c],
		[71, 0x1b],
		[72, 0x1f],
		[75, '/'],
		[76, 0x03],
		[77, 0x1e],
		[78, '-'],
		[79, UNUSED_OUTPUT],
		[80, UNUSED_OUTPUT],
		[81, '='],
		[82, '0'],
		[83, '1'],
		[84, '2'],
		[85, '3'],
		[86, '4'],
		[87, '5'],
		[88, '6'],
		[89, '7'],
		[91, '8'],
		[92, '9'],
		[96, UNUSED_OUTPUT],
		[97, UNUSED_OUTPUT],
		[98, UNUSED_OUTPUT],
		[99, UNUSED_OUTPUT],
		[100, UNUSED_OUTPUT],
		[101, UNUSED_OUTPUT],
		[102, UNUSED_OUTPUT],
		[103, UNUSED_OUTPUT],
		[104, UNUSED_OUTPUT],
		[105, UNUSED_OUTPUT],
		[106, UNUSED_OUTPUT],
		[107, UNUSED_OUTPUT],
		[108, UNUSED_OUTPUT],
		[109, UNUSED_OUTPUT],
		[110, UNUSED_OUTPUT],
		[111, UNUSED_OUTPUT],
		[112, UNUSED_OUTPUT],
		[113, UNUSED_OUTPUT],
		[114, 0x05],
		[115, 0x01],
		[116, 0x0b],
		[117, 0x7f],
		[118, UNUSED_OUTPUT],
		[119, 0x04],
		[120, UNUSED_OUTPUT],
		[121, 0x0c],
		[122, UNUSED_OUTPUT],
		[123, 0x1c],
		[124, 0x1d],
		[125, 0x1f],
		[126, 0x1e]
	];

	// The macOS keyboard group and the id range the Ergopti files use.
	const KEYBOARD_GROUP = 126;
	const KEYBOARD_ID_BASE = 2700000;
	const KEYBOARD_ID_SPAN = 100000;
	const FNV_OFFSET = 0x811c9dc5;
	const FNV_PRIME = 0x01000193;

	const TAG_PATTERN =
		/<(\/?)([A-Za-z][A-Za-z0-9]*)((?:\s+[A-Za-z_:][\w:.-]*\s*=\s*"[^"]*")*)\s*(\/?)>/g;
	const ATTRIBUTE_PATTERN = /([A-Za-z_:][\w:.-]*)\s*=\s*"([^"]*)"/g;
	const ENTITY_PATTERN = /&(#x[0-9A-Fa-f]+|#[0-9]+|lt|gt|amp|quot|apos);/g;
	const NAMED_ENTITIES = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'" };
	const CONTROL_PATTERN = /[\u0000-\u001F\u007F-\u009F]/;

	const hasOwn = (object, key) => Object.prototype.hasOwnProperty.call(object, key);
	const isTable = (value) => value !== null && typeof value === 'object' && !Array.isArray(value);
	const codePoints = (text) => Array.from(text);
	const copy = (value) => JSON.parse(JSON.stringify(value));

	/** An error that carries a stable code instead of prose. */
	class ComposerError extends Error {
		constructor(code, detail) {
			super(detail === undefined ? code : `${code}: ${detail}`);
			this.name = 'ComposerError';
			this.code = code;
		}
	}

	// =========================
	// ======= 2/ Reader =======
	// =========================

	/** Decodes the XML character references a .keylayout attribute can hold. */
	function decodeEntities(value) {
		return value.replace(ENTITY_PATTERN, (all, token) => {
			if (token.startsWith('#x')) return String.fromCodePoint(parseInt(token.slice(2), 16));
			if (token.startsWith('#')) return String.fromCodePoint(parseInt(token.slice(1), 10));
			return NAMED_ENTITIES[token];
		});
	}

	/** Whether a text types something visible: not empty, free of C0/C1 controls. */
	function isPrintable(text) {
		return typeof text === 'string' && text !== '' && !CONTROL_PATTERN.test(text);
	}

	function readAttributes(raw) {
		const out = {};
		ATTRIBUTE_PATTERN.lastIndex = 0;
		let match;
		while ((match = ATTRIBUTE_PATTERN.exec(raw)) !== null) out[match[1]] = decodeEntities(match[2]);
		return out;
	}

	function readModifierKeys(keys) {
		const required = new Set();
		const optional = new Set();
		for (const token of keys.split(/[ \t]+/)) {
			if (token === '') continue;
			const isOptional = token.endsWith('?');
			const name = isOptional ? token.slice(0, -1) : token;
			if (!hasOwn(MODIFIER_TOKENS, name))
				throw new ComposerError('keylayout_modifier_token', token);
			(isOptional ? optional : required).add(MODIFIER_TOKENS[name]);
		}
		for (const name of required) optional.delete(name);
		return { required, optional };
	}

	/**
	 * Reads the text of a .keylayout into the maps the readers walk.
	 * @param {string} text - The file content.
	 * @returns {object} Name, mapSet, defaultIndex, selects, keyMapSets, bases,
	 *   actions and terminators.
	 * @throws {ComposerError} When a part every reader needs is missing.
	 */
	function parseModel(text) {
		const body = text.replace(/<!--[\s\S]*?-->/g, '');
		const model = {
			name: '',
			mapSet: '',
			defaultIndex: 0,
			selects: [],
			keyMapSets: new Map(),
			bases: new Map(),
			actions: new Map(),
			terminators: new Map()
		};
		const layouts = [];
		const modifierMaps = new Map();
		let currentModifierMap = '';
		let currentSelect = null;
		let currentSet = '';
		let currentKeyMap = null;
		let currentAction = null;
		let inTerminators = false;
		TAG_PATTERN.lastIndex = 0;
		let match;
		while ((match = TAG_PATTERN.exec(body)) !== null) {
			const tag = match[2];
			if (match[1] === '/') {
				if (tag === 'modifierMap') currentModifierMap = '';
				else if (tag === 'keyMapSelect') currentSelect = null;
				else if (tag === 'keyMapSet') currentSet = '';
				else if (tag === 'keyMap') currentKeyMap = null;
				else if (tag === 'action') currentAction = null;
				else if (tag === 'terminators') inTerminators = false;
				continue;
			}
			const selfClosing = match[4] === '/';
			const attrs = readAttributes(match[3]);
			if (tag === 'keyboard') {
				model.name = attrs.name || '';
			} else if (tag === 'layout') {
				layouts.push(attrs);
			} else if (tag === 'modifierMap') {
				currentModifierMap = attrs.id;
				modifierMaps.set(currentModifierMap, {
					defaultIndex: parseInt(attrs.defaultIndex || '0', 10),
					selects: []
				});
			} else if (tag === 'keyMapSelect') {
				if (currentModifierMap !== '') {
					currentSelect = { index: parseInt(attrs.mapIndex, 10), modifiers: [] };
					modifierMaps.get(currentModifierMap).selects.push(currentSelect);
				}
			} else if (tag === 'modifier') {
				if (currentSelect) currentSelect.modifiers.push(readModifierKeys(attrs.keys || ''));
			} else if (tag === 'keyMapSet') {
				currentSet = attrs.id;
				if (!model.keyMapSets.has(currentSet)) model.keyMapSets.set(currentSet, new Map());
			} else if (tag === 'keyMap') {
				if (currentSet !== '') {
					currentKeyMap = parseInt(attrs.index, 10);
					const sets = model.keyMapSets.get(currentSet);
					if (!sets.has(currentKeyMap)) sets.set(currentKeyMap, new Map());
					if (attrs.baseIndex !== undefined) {
						if (!model.bases.has(currentSet)) model.bases.set(currentSet, new Map());
						model.bases
							.get(currentSet)
							.set(currentKeyMap, [attrs.baseMapSet || currentSet, parseInt(attrs.baseIndex, 10)]);
					}
					if (selfClosing) currentKeyMap = null;
				}
			} else if (tag === 'key') {
				if (currentSet !== '' && currentKeyMap !== null) {
					const keys = model.keyMapSets.get(currentSet).get(currentKeyMap);
					const code = parseInt(attrs.code, 10);
					if (keys.has(code)) continue;
					if (attrs.output !== undefined) keys.set(code, { kind: 'output', value: attrs.output });
					else if (attrs.action !== undefined)
						keys.set(code, { kind: 'action', value: attrs.action });
				}
			} else if (tag === 'action') {
				if (!model.actions.has(attrs.id)) model.actions.set(attrs.id, new Map());
				currentAction = selfClosing ? null : model.actions.get(attrs.id);
			} else if (tag === 'when') {
				const state = attrs.state === undefined ? NEUTRAL_STATE : attrs.state;
				if (currentAction) {
					if (!currentAction.has(state))
						currentAction.set(state, { output: attrs.output || '', next: attrs.next || '' });
				} else if (inTerminators && attrs.state !== undefined) {
					if (!model.terminators.has(state)) model.terminators.set(state, attrs.output || '');
				}
			} else if (tag === 'terminators') {
				inTerminators = true;
			}
		}
		const first = layouts.find((candidate) => candidate.first === '0');
		if (!first) throw new ComposerError('keylayout_no_layout');
		model.mapSet = first.mapSet || '';
		if (!model.keyMapSets.has(model.mapSet))
			throw new ComposerError('keylayout_no_map_set', model.mapSet);
		const modifiers = modifierMaps.get(first.modifiers || '');
		if (!modifiers) throw new ComposerError('keylayout_no_modifier_map', first.modifiers);
		model.defaultIndex = modifiers.defaultIndex;
		model.selects = modifiers.selects;
		return model;
	}

	/**
	 * The keyMap index the layout selects when exactly `pressed` modifiers are
	 * down.
	 * @param {object} model - From parseModel.
	 * @param {string[]} pressed - Modifier names (shift, caps, option, command, control).
	 * @returns {number}
	 */
	function keyMapIndex(model, pressed) {
		const down = new Set(pressed);
		for (const select of model.selects) {
			for (const modifier of select.modifiers) {
				let matches = true;
				for (const name of modifier.required) if (!down.has(name)) matches = false;
				for (const name of down)
					if (!modifier.required.has(name) && !modifier.optional.has(name)) matches = false;
				if (matches) return select.index;
			}
		}
		return model.defaultIndex;
	}

	/** The <key> of a code in a keyMap, following baseMapSet. */
	function keyEntry(model, index, code) {
		let mapSet = model.mapSet;
		let current = index;
		for (let depth = 0; depth < MAX_BASE_DEPTH; depth++) {
			const sets = model.keyMapSets.get(mapSet);
			if (!sets) throw new ComposerError('keylayout_no_map_set', mapSet);
			const keys = sets.get(current);
			if (keys && keys.has(code)) return keys.get(code);
			const bases = model.bases.get(mapSet);
			if (!bases || !bases.has(current)) return null;
			[mapSet, current] = bases.get(current);
		}
		throw new ComposerError('keylayout_base_chain');
	}

	/**
	 * What a code types in a keyMap from the neutral state.
	 * @returns {{kind: 'none'|'text'|'dead', text: string, state: string, action: string}}
	 */
	function resolve(model, index, code) {
		const none = { kind: 'none', text: '', state: '', action: '' };
		const entry = keyEntry(model, index, code);
		if (!entry) return none;
		if (entry.kind === 'output')
			return isPrintable(entry.value)
				? { kind: 'text', text: entry.value, state: '', action: '' }
				: none;
		if (!model.actions.has(entry.value))
			throw new ComposerError('keylayout_undefined_action', entry.value);
		const when = model.actions.get(entry.value).get(NEUTRAL_STATE);
		if (!when) return Object.assign({}, none, { action: entry.value });
		if (when.next !== '') {
			const alone = model.terminators.get(when.next) || '';
			return {
				kind: 'dead',
				text: alone !== '' ? alone : entry.value,
				state: when.next,
				action: entry.value
			};
		}
		if (isPrintable(when.output))
			return { kind: 'text', text: when.output, state: '', action: entry.value };
		return Object.assign({}, none, { action: entry.value });
	}

	/**
	 * One keystroke of the dead-key state machine, as macOS runs it.
	 * @returns {{output: string, next: string}}
	 */
	function step(model, state, index, code) {
		let pending = '';
		const entry = keyEntry(model, index, code);
		if (state !== NEUTRAL_STATE) {
			if (entry && entry.kind === 'action') {
				const action = model.actions.get(entry.value);
				if (action && action.has(state)) {
					const when = action.get(state);
					return {
						output: isPrintable(when.output) ? when.output : '',
						next: when.next !== '' ? when.next : NEUTRAL_STATE
					};
				}
			}
			const terminator = model.terminators.get(state) || '';
			pending = isPrintable(terminator) ? terminator : '';
		}
		const resolved = resolve(model, index, code);
		if (resolved.kind === 'dead') return { output: pending, next: resolved.state };
		return { output: pending + resolved.text, next: NEUTRAL_STATE };
	}

	// ==========================
	// ======= 3/ Sources =======
	// ==========================

	// A source is what the composer reads a layout as: its cells per physical
	// key and layer, and the dead-key machinery they refer to.
	//   cell: null (types nothing) | {text} | {dead: {action}}
	//   source: {id, name, cells: {code: {layer: cell}}, actions, terminators,
	//            compositions: {state: {text: {output, next}}}, ambiguous: Set}

	/** The macOS code of a key of the shared table under one convention. */
	function macCode(key, convention) {
		return typeof key.mac === 'object' ? key.mac[convention] : key.mac;
	}

	/** The compositions a layout defines: state -> typed text -> result. */
	function buildCompositions(actions) {
		const compositions = {};
		const ambiguous = new Set();
		for (const action of Object.values(actions)) {
			const neutral = action[NEUTRAL_STATE];
			if (!neutral || neutral.next !== '' || !isPrintable(neutral.output)) continue;
			for (const state of Object.keys(action)) {
				if (state === NEUTRAL_STATE) continue;
				if (!hasOwn(compositions, state)) compositions[state] = {};
				const previous = compositions[state][neutral.output];
				if (previous !== undefined) {
					if (previous.output !== action[state].output || previous.next !== action[state].next)
						ambiguous.add(state + '\u0000' + neutral.output);
					continue;
				}
				compositions[state][neutral.output] = {
					output: action[state].output,
					next: action[state].next
				};
			}
		}
		return { compositions, ambiguous };
	}

	/**
	 * Reads a registry layout as a source.
	 * @param {string} id - Its registry id.
	 * @param {string} text - The .keylayout content.
	 * @param {string} convention - Its keycode_convention ("iso" | "ansi").
	 * @param {object} table - Parsed _shared/modules/layouts/mac_keycodes.json.
	 * @returns {object} The source.
	 * @throws {ComposerError} On a malformed layout or an unknown convention.
	 */
	function parseSource(id, text, convention, table) {
		if (!CONVENTIONS.includes(convention))
			throw new ComposerError('unknown_convention', convention);
		const model = parseModel(text);
		const indexes = {};
		for (const layer of SOURCE_LAYERS) indexes[layer] = keyMapIndex(model, PRESSED[layer]);
		const cells = {};
		for (const key of table.keys) {
			const code = macCode(key, convention);
			cells[key.code] = {};
			for (const layer of SOURCE_LAYERS) {
				const resolved = resolve(model, indexes[layer], code);
				let cell = null;
				if (resolved.kind === 'text') cell = { text: resolved.text };
				else if (resolved.kind === 'dead') cell = { dead: { action: resolved.action } };
				cells[key.code][layer] = cell;
			}
		}
		const actions = {};
		for (const [actionId, whens] of model.actions) {
			actions[actionId] = {};
			for (const [state, when] of whens)
				actions[actionId][state] = { output: when.output, next: when.next };
		}
		const terminators = {};
		for (const [state, output] of model.terminators) terminators[state] = output;
		const built = buildCompositions(actions);
		return {
			id,
			name: model.name,
			cells,
			actions,
			terminators,
			compositions: built.compositions,
			ambiguous: built.ambiguous
		};
	}

	/**
	 * Reads a built-in reference layout (reference_layouts.js) as a source.
	 * @param {string} id - "qwerty" or "azerty".
	 * @param {object} reference - LAYOUT_COMPOSER_REFERENCE[id].
	 * @returns {object} The source.
	 */
	function referenceSource(id, reference) {
		const actions = {};
		const terminators = {};
		const compositions = {};
		for (const [name, dead] of Object.entries(reference.dead)) {
			actions['dead_' + name] = { [NEUTRAL_STATE]: { output: '', next: name } };
			terminators[name] = dead.terminator;
			compositions[name] = {};
			for (const [typed, made] of Object.entries(dead.compose))
				compositions[name][typed] = { output: made, next: '' };
		}
		const cellOf = (value) => {
			if (value === null) return null;
			if (typeof value === 'object') return { dead: { action: 'dead_' + value.dead } };
			return { text: value };
		};
		const cells = {};
		for (const [code, row] of Object.entries(reference.rows)) {
			cells[code] = {};
			LAYER_IDS.forEach((layer, position) => {
				cells[code][layer] = cellOf(row[position]);
			});
			// The reference layouts keep their shortcuts on the base layer.
			const base = cells[code].base;
			cells[code].command = base && base.text !== undefined ? { text: base.text } : null;
		}
		return {
			id,
			name: reference.name,
			cells,
			actions,
			terminators,
			compositions,
			ambiguous: new Set()
		};
	}

	// ============================
	// ======= 4/ Validation ======
	// ============================

	const problem = (code, path, detail) => ({
		code,
		path,
		detail: detail === undefined ? '' : detail
	});

	/** Whether a value is a legal key output: 1 to 8 code points, no control character. */
	function isLegalOutput(value) {
		return (
			typeof value === 'string' &&
			value !== '' &&
			!CONTROL_PATTERN.test(value) &&
			codePoints(value).length <= MAX_OUTPUT_CODE_POINTS
		);
	}

	function validateSpec(spec, path, sources, problems) {
		if (!isTable(spec)) {
			problems.push(problem('spec_invalid', path));
			return;
		}
		if (typeof spec.source !== 'string' || !hasOwn(sources, spec.source)) {
			problems.push(problem('unknown_source', path + '.source', String(spec.source)));
			return;
		}
		if (spec.layer !== undefined && !SOURCE_LAYERS.includes(spec.layer))
			problems.push(problem('unknown_layer', path + '.layer', String(spec.layer)));
	}

	/**
	 * Checks a declaration against the available sources.
	 * @param {object} declaration - The composition.
	 * @param {Object<string, object>} sources - id -> source.
	 * @param {object} table - Parsed mac_keycodes.json.
	 * @returns {{ok: boolean, problems: {code: string, path: string, detail: string}[]}}
	 */
	function validate(declaration, sources, table) {
		const problems = [];
		if (!isTable(declaration)) return { ok: false, problems: [problem('declaration_invalid', '')] };
		if (declaration.schema_version !== SCHEMA_VERSION)
			problems.push(
				problem('schema_version', 'schema_version', String(declaration.schema_version))
			);
		const name = declaration.name;
		if (
			typeof name !== 'string' ||
			name.trim() === '' ||
			CONTROL_PATTERN.test(name) ||
			codePoints(name).length > MAX_NAME_CODE_POINTS
		)
			problems.push(problem('name_invalid', 'name'));
		if (!CONVENTIONS.includes(declaration.keycode_convention))
			problems.push(problem('convention_invalid', 'keycode_convention'));
		const layers = declaration.layers;
		if (!isTable(layers)) {
			problems.push(problem('layers_invalid', 'layers'));
		} else {
			if (!hasOwn(layers, 'base')) problems.push(problem('base_missing', 'layers.base'));
			for (const id of Object.keys(layers)) {
				if (!LAYER_IDS.includes(id)) problems.push(problem('unknown_layer', 'layers.' + id, id));
				else validateSpec(layers[id], 'layers.' + id, sources, problems);
			}
		}
		if (declaration.shortcuts !== undefined) {
			if (!isTable(declaration.shortcuts)) {
				problems.push(problem('shortcuts_invalid', 'shortcuts'));
			} else {
				for (const id of Object.keys(declaration.shortcuts)) {
					if (id !== 'default' && !SHORTCUT_MODIFIERS.includes(id))
						problems.push(problem('unknown_shortcut', 'shortcuts.' + id, id));
					else validateSpec(declaration.shortcuts[id], 'shortcuts.' + id, sources, problems);
				}
			}
		}
		const keyCodes = new Set(table.keys.map((key) => key.code));
		if (declaration.overrides !== undefined) {
			if (!isTable(declaration.overrides)) {
				problems.push(problem('overrides_invalid', 'overrides'));
			} else {
				for (const target of Object.keys(declaration.overrides)) {
					const where = 'overrides.' + target;
					if (!OVERRIDE_TARGETS.includes(target)) {
						problems.push(problem('unknown_target', where, target));
						continue;
					}
					const entries = declaration.overrides[target];
					if (!isTable(entries)) {
						problems.push(problem('overrides_invalid', where));
						continue;
					}
					for (const code of Object.keys(entries)) {
						const path = where + '.' + code;
						const value = entries[code];
						if (!keyCodes.has(code)) problems.push(problem('unknown_key', path, code));
						else if (value === null) continue;
						else if (typeof value === 'string') {
							if (!isLegalOutput(value)) problems.push(problem('output_invalid', path));
						} else if (isTable(value) && isTable(value.copy)) {
							const from = value.copy;
							if (typeof from.source !== 'string' || !hasOwn(sources, from.source))
								problems.push(
									problem('unknown_source', path + '.copy.source', String(from.source))
								);
							else if (!keyCodes.has(from.key))
								problems.push(problem('unknown_key', path + '.copy.key', String(from.key)));
							else if (!SOURCE_LAYERS.includes(from.layer))
								problems.push(problem('unknown_layer', path + '.copy.layer', String(from.layer)));
						} else {
							problems.push(problem('override_invalid', path));
						}
					}
				}
			}
		}
		return { ok: problems.length === 0, problems };
	}

	// ==========================
	// ======= 5/ Compose =======
	// ==========================

	const renameState = (source, state) =>
		state === NEUTRAL_STATE ? NEUTRAL_STATE : source + STATE_SEPARATOR + state;

	const textActionId = (text) =>
		'c_' +
		codePoints(text)
			.map((c) => c.codePointAt(0).toString(16).padStart(4, '0'))
			.join('_');

	/** The cell a spec takes for a key: the source's layer (the same-named one by default). */
	function takeCell(sources, spec, defaultLayer, code) {
		const row = sources[spec.source].cells[code];
		const cell = row ? row[spec.layer || defaultLayer] : null;
		if (!cell) return null;
		return cell.dead
			? { dead: { source: spec.source, action: cell.dead.action } }
			: { text: cell.text };
	}

	const isCased = (text) => text.toLowerCase() !== text.toUpperCase();

	/**
	 * Builds the layout a valid declaration describes.
	 * @param {object} declaration - A declaration that validate accepted.
	 * @param {Object<string, object>} sources - id -> source.
	 * @param {object} table - Parsed mac_keycodes.json.
	 * @returns {{name: string, convention: string, keys: object, actions: object,
	 *   terminators: object, problems: object[]}} Every key's cell per level:
	 *   {output} or {action} (an action id of `actions`), or null. `problems`
	 *   lists what composition itself found (ambiguous compositions).
	 */
	function compose(declaration, sources, table) {
		const overrides = declaration.overrides || {};
		const shortcuts = declaration.shortcuts || {};
		const cells = {};
		for (const key of table.keys) {
			const code = key.code;
			const row = {};
			cells[code] = row;
			const overridden = (target, taken) => {
				const entries = overrides[target];
				if (!entries || !hasOwn(entries, code)) return taken;
				const value = entries[code];
				if (value === null) return null;
				if (typeof value === 'string') return { text: value };
				return takeCell(sources, value.copy, value.copy.layer, value.copy.key);
			};
			for (const layer of LAYER_IDS) {
				const spec = declaration.layers[layer];
				row[layer] = overridden(layer, spec ? takeCell(sources, spec, layer, code) : null);
			}
			let caps = row.base;
			if (
				row.base &&
				row.base.text !== undefined &&
				isCased(row.base.text) &&
				row.shift &&
				row.shift.text !== undefined
			)
				caps = row.shift;
			row[CAPS_LAYER] = overridden(CAPS_LAYER, caps);
			for (const modifier of SHORTCUT_MODIFIERS) {
				const spec = shortcuts[modifier] || shortcuts.default;
				let taken = row.base;
				if (spec) taken = takeCell(sources, spec, spec.layer || 'base', code);
				// A dead key in a chord types nothing, as in the shared vectors.
				if (taken && taken.dead) taken = null;
				row[modifier] = overridden(modifier, taken);
				if (row[modifier] && row[modifier].dead) row[modifier] = null;
			}
		}
		return finalize(declaration, sources, cells);
	}

	/** Gives the dead keys their state machines and the typed text its compositions. */
	function finalize(declaration, sources, cells) {
		const typedLayers = LAYER_IDS.concat([CAPS_LAYER]);
		const typed = new Set();
		const problems = [];
		for (const row of Object.values(cells))
			for (const layer of typedLayers)
				if (row[layer] && row[layer].text !== undefined) typed.add(row[layer].text);

		const actions = {};
		const terminators = {};
		const compositionsOf = {};
		const entered = new Set();
		const queue = [];
		const enter = (sourceId, state) => {
			const key = sourceId + '\u0000' + state;
			if (entered.has(key)) return;
			entered.add(key);
			queue.push([sourceId, state]);
		};
		const copyAction = (sourceId, actionId) => {
			const name = sourceId + STATE_SEPARATOR + actionId;
			if (hasOwn(actions, name)) return name;
			actions[name] = {};
			for (const [state, when] of Object.entries(sources[sourceId].actions[actionId])) {
				actions[name][renameState(sourceId, state)] = {
					output: when.output,
					next: when.next === '' ? '' : renameState(sourceId, when.next)
				};
				if (when.next !== '') enter(sourceId, when.next);
			}
			return name;
		};

		const keys = {};
		for (const [code, row] of Object.entries(cells)) {
			keys[code] = {};
			for (const level of LEVELS) {
				const cell = row[level.id];
				if (!cell) keys[code][level.id] = null;
				else if (cell.dead)
					keys[code][level.id] = { action: copyAction(cell.dead.source, cell.dead.action) };
				else keys[code][level.id] = { output: cell.text };
			}
		}

		for (let index = 0; index < queue.length; index++) {
			const [sourceId, state] = queue[index];
			const source = sources[sourceId];
			const renamed = renameState(sourceId, state);
			if (hasOwn(source.terminators, state)) terminators[renamed] = source.terminators[state];
			const entries = source.compositions[state] || {};
			for (const text of typed) {
				if (!hasOwn(entries, text)) continue;
				if (source.ambiguous.has(state + '\u0000' + text)) {
					problems.push(
						problem('ambiguous_composition', 'sources.' + sourceId, state + ' ' + text)
					);
					continue;
				}
				const made = entries[text];
				if (!hasOwn(compositionsOf, text)) compositionsOf[text] = {};
				compositionsOf[text][renamed] = {
					output: made.output,
					next: made.next === '' ? '' : renameState(sourceId, made.next)
				};
				if (made.next !== '') enter(sourceId, made.next);
			}
		}

		for (const text of Object.keys(compositionsOf).sort()) {
			const id = textActionId(text);
			actions[id] = Object.assign(
				{ [NEUTRAL_STATE]: { output: text, next: '' } },
				compositionsOf[text]
			);
		}
		for (const row of Object.values(keys)) {
			for (const level of LEVELS) {
				const cell = row[level.id];
				if (
					cell &&
					cell.output !== undefined &&
					typedLayers.includes(level.id) &&
					hasOwn(compositionsOf, cell.output)
				)
					row[level.id] = { action: textActionId(cell.output) };
			}
		}
		return {
			name: declaration.name,
			convention: declaration.keycode_convention,
			keys,
			actions,
			terminators,
			problems
		};
	}

	/**
	 * Validates a declaration and builds its layout.
	 * @returns {{ok: boolean, problems: object[], layout: object|null}} The layout
	 *   is null whenever there is a problem.
	 */
	function build(declaration, sources, table) {
		const checked = validate(declaration, sources, table);
		if (!checked.ok) return { ok: false, problems: checked.problems, layout: null };
		const layout = compose(declaration, sources, table);
		if (layout.problems.length > 0) return { ok: false, problems: layout.problems, layout: null };
		const base = Object.values(layout.keys).some((row) => row.base !== null);
		if (!base) return { ok: false, problems: [problem('base_empty', 'layers.base')], layout: null };
		return { ok: true, problems: [], layout };
	}

	// ================================
	// ======= 6/ Serialization =======
	// ================================

	function escapeAttribute(text) {
		let out = '';
		for (const c of text) {
			if (c === '&') out += '&amp;';
			else if (c === '<') out += '&lt;';
			else if (c === '>') out += '&gt;';
			else if (c === '"') out += '&quot;';
			else if (c.codePointAt(0) < 0x20 || c.codePointAt(0) === 0x7f)
				out += '&#x' + c.codePointAt(0).toString(16).toUpperCase().padStart(4, '0') + ';';
			else out += c;
		}
		return out;
	}

	const controlReference = (code) => '&#x' + code.toString(16).toUpperCase().padStart(4, '0') + ';';

	/** A stable negative keyboard id derived from the layout name (FNV-1a). */
	function keyboardId(name) {
		let hash = FNV_OFFSET;
		for (const c of name) {
			hash ^= c.codePointAt(0);
			hash = Math.imul(hash, FNV_PRIME) >>> 0;
		}
		return -(KEYBOARD_ID_BASE + (hash % KEYBOARD_ID_SPAN));
	}

	/**
	 * Writes a built layout as a complete .keylayout.
	 * @param {object} layout - From build().
	 * @param {object} table - Parsed mac_keycodes.json.
	 * @returns {string} The file content, LF line ends and a final newline.
	 */
	function serialize(layout, table) {
		const macByCode = new Map(table.keys.map((key) => [key.code, macCode(key, layout.convention)]));
		let maxout = 1;
		const note = (text) => {
			maxout = Math.max(maxout, codePoints(text).length);
		};
		for (const whens of Object.values(layout.actions))
			for (const when of Object.values(whens)) note(when.output);
		for (const row of Object.values(layout.keys))
			for (const cell of Object.values(row))
				if (cell && cell.output !== undefined) note(cell.output);

		const lines = [
			'<?xml version="1.1" encoding="UTF-8"?>',
			'<!DOCTYPE keyboard SYSTEM "file://localhost/System/Library/DTDs/KeyboardLayout.dtd">',
			'<!-- Written by the ErgoptiPlus layout composer from a composition of registry layouts. -->',
			`<keyboard group="${KEYBOARD_GROUP}" id="${keyboardId(layout.name)}" maxout="${maxout}" name="${escapeAttribute(layout.name)}">`,
			'\t<layouts>',
			`\t\t<layout first="0" last="0" mapSet="${COMPOSED_ID}" modifiers="composedModifiers"/>`,
			'\t</layouts>',
			'\t<modifierMap id="composedModifiers" defaultIndex="0">'
		];
		for (const level of LEVELS) {
			lines.push(`\t\t<keyMapSelect mapIndex="${level.index}">`);
			lines.push(`\t\t\t<modifier keys="${level.keys}"/>`);
			lines.push('\t\t</keyMapSelect>');
		}
		lines.push('\t</modifierMap>', `\t<keyMapSet id="${COMPOSED_ID}">`);
		for (const level of LEVELS) {
			lines.push(`\t\t<keyMap index="${level.index}">`);
			const rows = [];
			for (const [code, row] of Object.entries(layout.keys)) {
				const cell = row[level.id];
				const mac = macByCode.get(code);
				if (!cell) rows.push([mac, `output="${controlReference(UNUSED_OUTPUT)}"`]);
				else if (cell.action !== undefined)
					rows.push([mac, `action="${escapeAttribute(cell.action)}"`]);
				else rows.push([mac, `output="${escapeAttribute(cell.output)}"`]);
			}
			for (const [mac, output] of OTHER_KEYS)
				rows.push([
					mac,
					`output="${typeof output === 'number' ? controlReference(output) : escapeAttribute(output)}"`
				]);
			rows.sort((a, b) => a[0] - b[0]);
			for (const [mac, attribute] of rows) lines.push(`\t\t\t<key code="${mac}" ${attribute}/>`);
			lines.push('\t\t</keyMap>');
		}
		lines.push('\t</keyMapSet>', '\t<actions>');
		for (const [id, whens] of Object.entries(layout.actions)) {
			lines.push(`\t\t<action id="${escapeAttribute(id)}">`);
			for (const [state, when] of Object.entries(whens)) {
				const output = when.output === '' ? '' : ` output="${escapeAttribute(when.output)}"`;
				const next = when.next === '' ? '' : ` next="${escapeAttribute(when.next)}"`;
				lines.push(`\t\t\t<when state="${escapeAttribute(state)}"${output}${next}/>`);
			}
			lines.push('\t\t</action>');
		}
		lines.push('\t</actions>', '\t<terminators>');
		for (const [state, output] of Object.entries(layout.terminators))
			lines.push(
				`\t\t<when state="${escapeAttribute(state)}" output="${escapeAttribute(output)}"/>`
			);
		lines.push('\t</terminators>', '</keyboard>');
		return lines.join('\n') + '\n';
	}

	// ====================================
	// ======= 7/ Declaration edits =======
	// ====================================

	/** A new declaration: every layer from one source, no overrides, dormant until saved. */
	function emptyDeclaration(name, convention, sourceId) {
		const layers = {};
		for (const layer of LAYER_IDS) layers[layer] = { source: sourceId };
		return {
			schema_version: SCHEMA_VERSION,
			name,
			keycode_convention: convention,
			layers,
			shortcuts: {},
			overrides: {}
		};
	}

	/** Takes a layer from a source (another layer of it when `from` is given). */
	function setLayerSource(declaration, layer, sourceId, from) {
		const spec = { source: sourceId };
		if (from !== undefined && from !== layer) spec.layer = from;
		declaration.layers[layer] = spec;
	}

	/** Sets or, with null, removes the shortcuts entry of a modifier (or "default"). */
	function setShortcutSource(declaration, modifier, spec) {
		if (!declaration.shortcuts) declaration.shortcuts = {};
		if (spec === null) delete declaration.shortcuts[modifier];
		else declaration.shortcuts[modifier] = copy(spec);
	}

	/** Overrides one key of one layer (text, null, or {copy}). */
	function setOverride(declaration, target, code, value) {
		if (!declaration.overrides) declaration.overrides = {};
		if (!hasOwn(declaration.overrides, target)) declaration.overrides[target] = {};
		declaration.overrides[target][code] = copy(value);
	}

	/** Gives a key the layer's own cell back. */
	function clearOverride(declaration, target, code) {
		const entries = declaration.overrides && declaration.overrides[target];
		if (!entries) return;
		delete entries[code];
		if (Object.keys(entries).length === 0) delete declaration.overrides[target];
	}

	/**
	 * The declaration as the file stores it: fixed key order, tab indentation,
	 * final newline, so the same composition is always the same bytes.
	 */
	function writeDeclaration(declaration) {
		const ordered = {
			schema_version: declaration.schema_version,
			name: declaration.name,
			keycode_convention: declaration.keycode_convention,
			layers: {},
			shortcuts: {},
			overrides: {}
		};
		for (const layer of LAYER_IDS)
			if (declaration.layers && hasOwn(declaration.layers, layer))
				ordered.layers[layer] = declaration.layers[layer];
		for (const modifier of ['default'].concat(SHORTCUT_MODIFIERS))
			if (declaration.shortcuts && hasOwn(declaration.shortcuts, modifier))
				ordered.shortcuts[modifier] = declaration.shortcuts[modifier];
		for (const target of OVERRIDE_TARGETS) {
			const entries = declaration.overrides && declaration.overrides[target];
			if (!entries) continue;
			ordered.overrides[target] = {};
			for (const code of Object.keys(entries).sort())
				ordered.overrides[target][code] = entries[code];
		}
		return JSON.stringify(ordered, null, '\t') + '\n';
	}

	/**
	 * Reads a stored declaration.
	 * @param {string|null} text - The file content, or null when there is none.
	 * @returns {{declaration: object|null, problem: string|null}}
	 */
	function readDeclaration(text) {
		if (text === null || text === undefined) return { declaration: null, problem: null };
		let parsed;
		try {
			parsed = JSON.parse(text);
		} catch (error) {
			return { declaration: null, problem: 'declaration_not_json' };
		}
		if (!isTable(parsed)) return { declaration: null, problem: 'declaration_invalid' };
		return { declaration: parsed, problem: null };
	}

	return {
		SCHEMA_VERSION,
		COMPOSED_ID,
		LAYER_IDS,
		SOURCE_LAYERS,
		CAPS_LAYER,
		SHORTCUT_MODIFIERS,
		OVERRIDE_TARGETS,
		CONVENTIONS,
		LEVELS,
		MAX_OUTPUT_CODE_POINTS,
		ComposerError,
		parseModel,
		keyMapIndex,
		resolve,
		step,
		parseSource,
		referenceSource,
		validate,
		compose,
		build,
		serialize,
		isLegalOutput,
		emptyDeclaration,
		setLayerSource,
		setShortcutSource,
		setOverride,
		clearOverride,
		writeDeclaration,
		readDeclaration
	};
})();
