// _shared/ui/layout_analysis/analysis_engine.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Engine
 * DESCRIPTION:
 * The one engine that measures a keyboard layout on character n-gram counts:
 * finger and hand load, row usage, travel distance, same-finger bigrams and
 * skipgrams, lateral stretches, scissors, two- and three-key rolls,
 * alternation, redirects, modifier and dead-key use, character coverage,
 * compact-keyboard fitness, direct digits and shortcut placement, then one
 * global score from editable weights. The site's /studio page and the
 * Ergopti Studio window of the app load it unchanged; the Node tests run it in
 * a vm context. Every metric is defined in docs/design/layout-analysis.md.
 *
 * FEATURES & RATIONALE:
 * 1. Instant: a corpus or the keystats store is reduced once to n-gram tables
 *    (prepareNgrams); a layout is scored by mapping those tables onto its
 *    keys, never by a pass over the text, so a hundred layouts take well under
 *    a second.
 * 2. Exact keystrokes: each character becomes the key sequence that types it
 *    (dead keys included, the cheapest when there are several), and the key
 *    bigrams and trigrams are those of the expanded stream, rebuilt exactly
 *    from the character uni-, bi- and trigrams.
 * 3. One source for data: fingers, keyboards, weights and the layout library
 *    come from LAYOUT_ANALYSIS_DATA (_generated/analysis_data.js), read on
 *    first use so the codegen can load this file to convert layouts.
 * 4. Fail fast: an unknown keyboard, metric or weight throws.
 * 5. Incremental: scoreSession re-scores a changed layout by walking only the
 *    n-grams of the characters whose key sequence changed, through the same
 *    visitor and metric code as analyse(), for the layout optimizer.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const LAYER_IDS = ['base', 'shift', 'altgr', 'shift_altgr'];
	// Modifier presses each layer adds: Shift, AltGr.
	const LAYER_SHIFT = [0, 1, 0, 1];
	const LAYER_ALTGR = [0, 0, 1, 1];
	// A key press costs one; a held modifier half of one when choosing between
	// two ways of typing a character.
	const MODIFIER_COST = 0.5;
	// Finger indexes: lp lr lm li lt rt ri rm rr rp.
	const LEFT_THUMB = 4;
	const RIGHT_THUMB = 5;
	// Order from the pinky (0) to the index (3), on either hand.
	const INDEX_ORDER = 3;
	// How far each finger reaches, by order (pinky, ring, middle, index), for half scissors.
	const FINGER_LENGTH = [0, 2, 3, 1];
	const DEFAULT_KEYBOARD = 'iso';
	// An edited ideal finger load may miss 100 % by this much (rounding of inputs).
	const LOAD_SUM_TOLERANCE = 0.05;
	/**
	 * A refusal with a stable code and the values its message names, so a page
	 * shows it in the reader's language (layout_analysis.error.<code>).
	 */
	class AnalysisError extends Error {
		constructor(code, values, message) {
			super(`layout_analysis: ${message}`);
			this.name = 'AnalysisError';
			this.code = code;
			this.values = values;
		}
	}

	// A dead-key rule typed by another dead key: « dead:<state> » names the dead
	// key that enters <state> (Ergo-L's 1dk pressed twice gives the diaeresis).
	const DEAD_TYPED = 'dead:';
	// A key is lateral from this far (in key units, on the column grid) beyond
	// its finger's home column: the index's inner column, the pinky's outer keys.
	const LATERAL_MIN_STEP = 0.75;
	// Dead-key chains deeper than this are not followed.
	const MAX_DEAD_DEPTH = 4;

	/**
	 * Every metric: unit, direction and what it is a share of. The definitions
	 * are in docs/design/layout-analysis.md.
	 */
	const METRICS = {
		sfb: { unit: '%', better: 'lower', of: 'bigrams' },
		repeat: { unit: '%', better: 'none', of: 'bigrams' },
		sfs: { unit: '%', better: 'lower', of: 'trigrams' },
		lsb: { unit: '%', better: 'lower', of: 'bigrams' },
		scissors: { unit: '%', better: 'lower', of: 'bigrams' },
		half_scissors: { unit: '%', better: 'lower', of: 'bigrams' },
		roll_in: { unit: '%', better: 'higher', of: 'bigrams' },
		roll_out: { unit: '%', better: 'higher', of: 'bigrams' },
		hand_change: { unit: '%', better: 'none', of: 'bigrams' },
		roll3_in: { unit: '%', better: 'higher', of: 'trigrams' },
		roll3_out: { unit: '%', better: 'higher', of: 'trigrams' },
		alternation: { unit: '%', better: 'higher', of: 'trigrams' },
		redirect: { unit: '%', better: 'lower', of: 'trigrams' },
		redirect_bad: { unit: '%', better: 'lower', of: 'trigrams' },
		home_row: { unit: '%', better: 'higher', of: 'keystrokes' },
		top_row: { unit: '%', better: 'none', of: 'keystrokes' },
		bottom_row: { unit: '%', better: 'none', of: 'keystrokes' },
		number_row: { unit: '%', better: 'none', of: 'keystrokes' },
		distance: { unit: 'mm', better: 'lower', of: 'characters' },
		finger_imbalance: { unit: '%', better: 'lower', of: 'keystrokes' },
		hand_imbalance: { unit: '%', better: 'lower', of: 'keystrokes' },
		pinky_load: { unit: '%', better: 'lower', of: 'keystrokes' },
		modifier_usage: { unit: '%', better: 'lower', of: 'characters' },
		dead_key_usage: { unit: '%', better: 'lower', of: 'characters' },
		outer_column: { unit: '%', better: 'lower', of: 'keystrokes' },
		unsupported: { unit: '%', better: 'lower', of: 'characters' },
		compact_fit: { unit: '%', better: 'higher', of: 'characters' },
		char_coverage: { unit: '%', better: 'higher', of: 'layout' },
		direct_digits: { unit: '%', better: 'higher', of: 'layout' },
		shortcut_left: { unit: '%', better: 'higher', of: 'layout' }
	};

	// =======================
	// ======= 2/ Data =======
	// =======================

	/**
	 * The generated data, read on first use.
	 * @returns {object} LAYOUT_ANALYSIS_DATA.
	 * @throws {Error} When _generated/analysis_data.js was not loaded first.
	 */
	function data() {
		if (typeof LAYOUT_ANALYSIS_DATA === 'undefined' || !LAYOUT_ANALYSIS_DATA)
			throw new Error('layout_analysis: load _generated/analysis_data.js before the engine');
		return LAYOUT_ANALYSIS_DATA;
	}

	/** Splits a string into code points. */
	const codePoints = (text) => Array.from(text);

	/** Whether a string is one code point (codePoints(text).length === 1), without splitting it. */
	const isOneCodePoint = (text) =>
		text.length === 1 || (text.length === 2 && text.codePointAt(0) > 0xffff);

	/**
	 * FNV-1a 32-bit hash of a text, the cache key of its n-gram tables.
	 * @param {string} text - The corpus.
	 * @returns {string} Eight hexadecimal digits.
	 */
	function hashText(text) {
		let hash = 0x811c9dc5;
		for (let i = 0; i < text.length; i++) {
			hash ^= text.charCodeAt(i);
			hash = Math.imul(hash, 0x01000193) >>> 0;
		}
		return hash.toString(16).padStart(8, '0');
	}

	// ===========================
	// ======= 3/ Keyboards ======
	// ===========================

	const keyboardCache = new Map();

	const unknownKey = (code) =>
		new AnalysisError('fingering_unknown_key', { key: String(code) }, `unknown key ${code}`);
	const unknownFinger = (finger) =>
		new AnalysisError(
			'fingering_unknown_finger',
			{ finger: String(finger) },
			`unknown finger ${finger}`
		);

	/**
	 * Checks a fingering profile: the user's own model of which finger presses
	 * each key and where each finger rests.
	 * @param {object} profile - {id?, name?, base?: 'standard'|'angle',
	 *   fingers?: {code: finger}, home?: {finger: code}}.
	 * @returns {object} The profile, with empty maps filled in.
	 * @throws {AnalysisError} On an unknown base, finger or key.
	 */
	function fingeringProfile(profile) {
		const { model, geometry } = data();
		if (!profile || typeof profile !== 'object')
			throw new AnalysisError('fingering_not_object', {}, 'a fingering profile is an object');
		if (profile.base !== undefined && !model.fingerings[profile.base])
			throw new AnalysisError(
				'fingering_unknown_base',
				{ base: String(profile.base) },
				`unknown fingering ${profile.base}`
			);
		const fingers = profile.fingers || {};
		const home = profile.home || {};
		for (const [code, finger] of Object.entries(fingers)) {
			if (!geometry[code]) throw unknownKey(code);
			if (!model.fingers.includes(finger)) throw unknownFinger(finger);
		}
		for (const [finger, code] of Object.entries(home)) {
			if (!model.fingers.includes(finger)) throw unknownFinger(finger);
			if (!geometry[code]) throw unknownKey(code);
		}
		return {
			id: profile.id || 'custom',
			name: profile.name || '',
			base: profile.base,
			fingers,
			home
		};
	}

	/**
	 * The keys of one keyboard with their finger, hand, row and position.
	 * @param {string} keyboardId - A key of model.keyboards.
	 * @param {object} [profile] - A fingering profile (fingeringProfile): its
	 *   base fingering, finger of each key and home key of each finger replace
	 *   the keyboard's own; absent, the model's defaults.
	 * @returns {object} {id, codes, index: Map code → i, finger, order, hand,
	 *   row, relRow (row relative to the finger's home key), x, y, home,
	 *   lateral, outer, homeOf: finger → key index}.
	 * @throws {Error} On an unknown keyboard, an invalid profile, or a home key
	 *   that is not on the board or not pressed by its own finger (a shared
	 *   home key, the space bar, rests both thumbs).
	 */
	function keyboard(keyboardId, profile) {
		const checked = profile === undefined ? null : fingeringProfile(profile);
		const cacheKey = checked ? `${keyboardId}|${JSON.stringify(checked)}` : keyboardId;
		if (keyboardCache.has(cacheKey)) return keyboardCache.get(cacheKey);
		const { model, geometry } = data();
		const spec = model.keyboards[keyboardId];
		if (!spec) throw new Error(`layout_analysis: unknown keyboard ${keyboardId}`);
		// A split, ortholinear or column-staggered board brings its own positions,
		// fingers and home keys; a profile's base fingering applies to the
		// row-staggered boards only.
		const board3d = spec.board ? data().boards[spec.board] : null;
		const baseFingering = board3d
			? board3d.fingers
			: model.fingerings[checked && checked.base ? checked.base : spec.fingering];
		const fingering = Object.assign({}, baseFingering, checked ? checked.fingers : {});
		const homeKeys = Object.assign(
			{},
			board3d ? board3d.home_keys : model.home_keys,
			checked ? checked.home : {}
		);
		const form = spec.geometry === 'ortho' ? 'iso' : spec.geometry;
		const outer = new Set(model.outer_keys);
		const modifierCodes = new Set(Object.values(model.modifier_keys));
		const homeCodes = new Set(Object.values(homeKeys));
		const board = {
			id: keyboardId,
			profile: checked,
			codes: [],
			index: new Map(),
			finger: [],
			order: [],
			hand: [],
			row: [],
			relRow: [],
			x: [],
			y: [],
			// The column grid: x without the row stagger, for lateral keys.
			grid: [],
			home: [],
			lateral: [],
			outer: []
		};
		for (const [code, fingerId] of Object.entries(fingering)) {
			// A board key: its centre already, no row stagger to remove.
			const g = board3d
				? board3d.keys[code] && {
						col: board3d.keys[code].x - board3d.keys[code].w / 2,
						width: board3d.keys[code].w,
						row: board3d.keys[code].row,
						y: board3d.keys[code].y
					}
				: geometry[code] && geometry[code][form];
			if (!g) continue;
			const finger = model.fingers.indexOf(fingerId);
			if (finger < 0) throw unknownFinger(fingerId);
			const grid = board3d
				? g.col + g.width / 2
				: g.col + g.width / 2 + model.ortho_row_offsets[String(g.row)];
			let x = g.col + g.width / 2;
			if (spec.geometry === 'ortho') x = grid;
			board.index.set(code, board.codes.length);
			board.codes.push(code);
			board.finger.push(finger);
			board.order.push(finger < LEFT_THUMB ? finger : finger > RIGHT_THUMB ? 9 - finger : 4);
			board.hand.push(finger <= LEFT_THUMB ? 0 : 1);
			board.row.push(g.row);
			board.x.push(x);
			// A column-staggered board measures its real height; the others their rows.
			board.y.push(board3d ? g.y : g.row);
			board.grid.push(grid);
			board.home.push(homeCodes.has(code));
			board.outer.push(outer.has(code));
			// A wide modifier is pressed at its end nearest the home row.
			if (modifierCodes.has(code) && !board3d) {
				board.x[board.x.length - 1] =
					code === model.modifier_keys.shift_for_right_hand ? g.col + g.width - 0.5 : g.col + 0.5;
			}
		}
		board.homeOf = model.fingers.map((fingerId) => {
			const k = board.index.get(homeKeys[fingerId]);
			if (k === undefined)
				throw new AnalysisError(
					'home_key_not_on_keyboard',
					{ key: String(homeKeys[fingerId]), finger: fingerId, keyboard: keyboardId },
					`home key ${homeKeys[fingerId]} of ${fingerId} is not on ${keyboardId}`
				);
			// The space bar is wide: both thumbs rest on it, whichever presses it.
			if (
				model.fingers[board.finger[k]] !== fingerId &&
				!model.shared_home_keys.includes(homeKeys[fingerId])
			)
				throw new AnalysisError(
					'home_key_other_finger',
					{ key: homeKeys[fingerId], finger: fingerId },
					`home key ${homeKeys[fingerId]} is not pressed by ${fingerId}`
				);
			return k;
		});
		board.codes.forEach((code, k) => {
			const home = board.homeOf[board.finger[k]];
			board.relRow.push(board.row[k] - board.row[home]);
			// Lateral: an index key toward the centre of its home column, a pinky key
			// outward of it, on the column grid (stagger aside), modifiers excepted.
			const inward = (board.grid[k] - board.grid[home]) * (board.hand[k] === 0 ? 1 : -1);
			const order = board.order[k];
			board.lateral.push(
				!modifierCodes.has(code) &&
					((order === INDEX_ORDER && inward >= LATERAL_MIN_STEP) ||
						(order === 0 && inward <= -LATERAL_MIN_STEP))
			);
		});
		// Distance in millimetres from each finger's home key to each key.
		board.reach = board.codes.map((_, k) => {
			const home = board.homeOf[board.finger[k]];
			const dx = board.x[k] - board.x[home];
			const dy = board.y[k] - board.y[home];
			return Math.hypot(dx, dy) * model.key_unit_mm;
		});
		board.modifiers = {
			shiftForLeft: board.index.get(model.modifier_keys.shift_for_left_hand),
			shiftForRight: board.index.get(model.modifier_keys.shift_for_right_hand),
			altgr: board.index.get(model.modifier_keys.altgr)
		};
		keyboardCache.set(cacheKey, board);
		return board;
	}

	// =========================
	// ======= 4/ Layouts ======
	// =========================

	/**
	 * Checks and returns a layout in the library shape.
	 * @param {object} layout - {id, name, rows: code → [base, shift, altgr,
	 *   shift_altgr], dead?: state → {typed: output | {dead: state}} (typed is
	 *   a character, or « dead:<state> » for the dead key entering <state>),
	 *   command?: code → letter, fingering?: 'standard' | 'angle'}. A cell is a
	 *   string, null, or {dead: state}.
	 * @returns {object} The same layout, with empty dead/command maps filled in.
	 * @throws {Error} On a malformed layout.
	 */
	function layoutFromRows(layout) {
		if (!layout || typeof layout.id !== 'string' || typeof layout.rows !== 'object')
			throw new Error('layout_analysis: a layout needs an id and rows');
		for (const [code, row] of Object.entries(layout.rows)) {
			if (!Array.isArray(row) || row.length !== LAYER_IDS.length)
				throw new Error(`layout_analysis: ${layout.id}.${code} is not four cells`);
			for (const cell of row)
				if (!(cell === null || typeof cell === 'string' || (cell && typeof cell.dead === 'string')))
					throw new Error(`layout_analysis: ${layout.id}.${code} has an invalid cell`);
		}
		for (const [code, letter] of Object.entries(layout.command || {}))
			if (typeof letter !== 'string')
				throw new Error(`layout_analysis: ${layout.id} command.${code} is not text`);
		return {
			id: layout.id,
			name: layout.name || layout.id,
			language: layout.language || '',
			origin: layout.origin || 'user',
			source: layout.source || '',
			authors: Array.isArray(layout.authors) ? layout.authors : [],
			year: layout.year,
			url: layout.url || '',
			licence: layout.licence || '',
			fingering: layout.fingering || 'standard',
			rows: layout.rows,
			command: layout.command || {},
			dead: layout.dead || {},
			// A registry layout's family and board (iso or ansi), when its family
			// ships one layout per board: the Comparer's default selection.
			family: layout.family || '',
			geometry: layout.geometry || ''
		};
	}

	/**
	 * Converts a layout composer source (LayoutComposer.parseSource or
	 * referenceSource) to the library shape.
	 * @param {object} source - The composer source.
	 * @param {string[]} codes - The physical keys to keep.
	 * @returns {object} The layout.
	 * @throws {Error} When a dead action names no state.
	 */
	function layoutFromComposerSource(source, codes) {
		const cellOf = (cell) => {
			if (!cell) return null;
			if (cell.text !== undefined) return cell.text;
			const action = source.actions[cell.dead.action];
			const state = action && action.none ? action.none.next : '';
			if (!state) throw new Error(`layout_analysis: ${source.id} dead action has no state`);
			return { dead: state };
		};
		const rows = {};
		const command = {};
		for (const code of codes) {
			const cells = source.cells[code];
			if (!cells) continue;
			const row = LAYER_IDS.map((layer) => cellOf(cells[layer]));
			if (row.some((cell) => cell !== null)) rows[code] = row;
			const shortcut = cells.command ? cells.command.text : undefined;
			if (typeof shortcut === 'string' && shortcut !== row[0]) command[code] = shortcut;
		}
		const dead = {};
		// A dead key pressed in another dead state: its action's other states.
		const chained = {};
		for (const code of codes) {
			const cells = source.cells[code];
			if (!cells) continue;
			for (const layer of LAYER_IDS) {
				const cell = cells[layer];
				if (!cell || cell.text !== undefined) continue;
				const action = source.actions[cell.dead.action];
				// The state the key enters from none names it; without one it is not a dead key.
				if (!action || !action.none || !action.none.next) continue;
				for (const [state, when] of Object.entries(action)) {
					if (state === 'none') continue;
					const rule = when.output ? when.output : when.next ? { dead: when.next } : null;
					if (rule) (chained[state] || (chained[state] = {}))[DEAD_TYPED + action.none.next] = rule;
				}
			}
		}
		for (const state of Object.keys(source.compositions).sort()) {
			dead[state] = {};
			for (const [typed, result] of Object.entries(source.compositions[state])) {
				if (result.output) dead[state][typed] = result.output;
				else if (result.next) dead[state][typed] = { dead: result.next };
			}
			if (source.terminators[state]) dead[state][' '] = source.terminators[state];
		}
		for (const [state, rules] of Object.entries(chained))
			dead[state] = Object.assign(dead[state] || {}, rules);
		return layoutFromRows({ id: source.id, name: source.name, rows, command, dead });
	}

	/**
	 * The keys a layout types characters on: every finger-assigned key but the
	 * held modifiers. The codes layoutFromComposerSource keeps.
	 * @param {object} [model] - analysis_model.json; the loaded data's when absent
	 *   (the codegen passes it before the data exists).
	 * @returns {string[]} KeyboardEvent codes.
	 */
	function typingCodes(model) {
		const m = model || data().model;
		const modifiers = new Set(Object.values(m.modifier_keys));
		return Object.keys(m.fingerings.standard).filter((code) => !modifiers.has(code));
	}

	/** The layouts of the shared library, in the library shape. */
	function libraryLayouts() {
		return data().layouts.map(layoutFromRows);
	}

	/**
	 * Every character a layout types and the cheapest key sequence for each.
	 * @param {object} layout - Library shape.
	 * @param {object} board - From keyboard().
	 * @param {Set<string>|null} missing - Codes absent from a compact board.
	 * @returns {Map<string, {keys: number[], shift: number, altgr: number,
	 *   dead: boolean, cost: number}>} Character → sequence.
	 */
	function compileLayout(layout, board, missing) {
		const best = new Map();
		const deadSeq = new Map();
		// Equal costs are settled the same way whatever order the file lists its
		// keys in: fewer AltGr presses (the lower level, as Kalamine prefers),
		// then fewer keys, then the lower key indexes.
		const better = (a, b) => {
			if (a.cost !== b.cost) return a.cost < b.cost;
			if (a.altgr !== b.altgr) return a.altgr < b.altgr;
			if (a.keys.length !== b.keys.length) return a.keys.length < b.keys.length;
			for (let i = 0; i < a.keys.length; i++)
				if (a.keys[i] !== b.keys[i]) return a.keys[i] < b.keys[i];
			return false;
		};
		const offer = (map, key, candidate) => {
			const current = map.get(key);
			if (!current || better(candidate, current)) map.set(key, candidate);
		};
		for (const [code, row] of Object.entries(layout.rows)) {
			const k = board.index.get(code);
			if (k === undefined || (missing && missing.has(code))) continue;
			row.forEach((cell, layer) => {
				if (cell === null) return;
				const stroke = {
					keys: [k],
					shift: LAYER_SHIFT[layer],
					altgr: LAYER_ALTGR[layer],
					dead: false,
					cost: 1 + MODIFIER_COST * (LAYER_SHIFT[layer] + LAYER_ALTGR[layer])
				};
				if (typeof cell === 'string') {
					if (isOneCodePoint(cell)) offer(best, cell, stroke);
				} else offer(deadSeq, cell.dead, stroke);
			});
		}
		const join = (a, b, dead) => ({
			keys: a.keys.concat(b.keys),
			shift: a.shift + b.shift,
			altgr: a.altgr + b.altgr,
			dead: dead || a.dead || b.dead,
			cost: a.cost + b.cost
		});
		for (let depth = 0; depth < MAX_DEAD_DEPTH; depth++) {
			let changed = false;
			for (const [state, prefix] of Array.from(deadSeq.entries())) {
				const rules = layout.dead[state];
				if (!rules) continue;
				for (const [typed, result] of Object.entries(rules)) {
					const tail = typed.startsWith(DEAD_TYPED)
						? deadSeq.get(typed.slice(DEAD_TYPED.length))
						: best.get(typed);
					if (!tail) continue;
					const candidate = join(prefix, tail, true);
					const map = typeof result === 'string' ? best : deadSeq;
					const target = typeof result === 'string' ? result : result.dead;
					if (typeof result === 'string' && !isOneCodePoint(result)) continue;
					const before = map.get(target);
					offer(map, target, candidate);
					if (map.get(target) !== before) changed = true;
				}
			}
			if (!changed) break;
		}
		// A typographic character the layout lacks is typed as its plain form; a
		// copy, so the plain character's own sequence stays unmarked.
		for (const [fancy, plain] of Object.entries(data().model.substitutions)) {
			if (best.has(fancy)) continue;
			const parts = codePoints(plain).map((c) => best.get(c));
			if (parts.some((part) => !part)) continue;
			offer(
				best,
				fancy,
				Object.assign(
					{},
					parts.reduce((a, b) => join(a, b, false)),
					{ substituted: true }
				)
			);
		}
		return best;
	}

	// ========================
	// ======= 5/ N-grams =====
	// ========================

	/**
	 * Counts the characters, bigrams and trigrams of a text. Line breaks and
	 * tabs cut the text: no n-gram spans them and they are not counted.
	 * @param {string} text - The corpus.
	 * @returns {{chars: object, bigrams: object, trigrams: object}} Counts.
	 */
	function ngramsFromText(text) {
		const chars = {};
		const bigrams = {};
		const trigrams = {};
		for (const segment of text.split(/[\r\n\t]+/)) {
			const c = codePoints(segment);
			for (let i = 0; i < c.length; i++) {
				chars[c[i]] = (chars[c[i]] || 0) + 1;
				if (i + 1 < c.length) {
					const b = c[i] + c[i + 1];
					bigrams[b] = (bigrams[b] || 0) + 1;
				}
				if (i + 2 < c.length) {
					const t = c[i] + c[i + 1] + c[i + 2];
					trigrams[t] = (trigrams[t] || 0) + 1;
				}
			}
		}
		return { chars, bigrams, trigrams };
	}

	const preparedCache = new WeakMap();

	/**
	 * Splits the n-gram tables once into arrays the analysis walks.
	 * @param {{chars: object, bigrams: object, trigrams?: object}} ngrams - Counts.
	 * @returns {object} {uni, bi, tri, totalChars}; uni entries are [char, n],
	 *   bi [a, b, n], tri [a, b, c, n].
	 * @throws {Error} On a malformed table.
	 */
	function prepareNgrams(ngrams) {
		if (ngrams && ngrams.prepared === true) return ngrams;
		if (preparedCache.has(ngrams)) return preparedCache.get(ngrams);
		if (!ngrams || typeof ngrams.chars !== 'object' || typeof ngrams.bigrams !== 'object')
			throw new Error('layout_analysis: n-grams need chars and bigrams');
		const split = (table, size) => {
			const out = [];
			for (const [token, n] of Object.entries(table || {})) {
				const c = codePoints(token);
				if (c.length !== size) throw new Error(`layout_analysis: "${token}" is not a ${size}-gram`);
				if (!(n > 0)) continue;
				out.push(c.concat([n]));
			}
			return out;
		};
		const prepared = {
			prepared: true,
			uni: split(ngrams.chars, 1),
			bi: split(ngrams.bigrams, 2),
			tri: split(ngrams.trigrams, 3)
		};
		prepared.totalChars = prepared.uni.reduce((sum, entry) => sum + entry[1], 0);
		preparedCache.set(ngrams, prepared);
		return prepared;
	}

	// ==========================
	// ======= 6/ Analysis ======
	// ==========================

	/**
	 * The keyboard a layout is measured on: an angle-mod layout uses the angle
	 * fingering of an ISO board.
	 */
	function boardFor(layout, keyboardId, profile) {
		// A profile with its own base fingering decides; otherwise an angle-mod
		// layout on an ISO board takes the angle fingering.
		if (keyboardId === 'iso' && layout.fingering === 'angle' && !(profile && profile.base))
			return keyboard('iso_angle', profile);
		return keyboard(keyboardId, profile);
	}

	/**
	 * Measures one layout.
	 * @param {object} layoutInput - Library shape (see layoutFromRows).
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {{keyboard?: string, format?: string, weights?: object, idealLoad?: object,
	 *   profile?: object, keyGroups?: boolean, shortcuts?: object, formWeights?: object}} [options]
	 *   - The user's shortcut table (shortcuts(): letter usefulness and key ease of
	 *   shortcut_left) and compact form factor weights (formFactorWeights(): of
	 *   compact_fit), the model's when absent; board, keyboard format
	 *   (keyboard_formats id: compact_fit measures the per-format form factors on
	 *   it alone), weights, the ideal finger load of finger_imbalance (finger → %
	 *   of the non-thumb presses; the model's ideal_finger_load when absent), the
	 *   fingering profile, and whether each key's worst groups are counted for
	 *   every event (keys[code].worst; the SFB ones always are).
	 * @returns {object} {layout, keyboard, metrics, fingers, fingerShares,
	 *   idealLoad, hands, rows, coverage, trigramClasses, keys, score}.
	 */
	function analyse(layoutInput, ngrams, options) {
		const opts = options || {};
		const layout = layoutFromRows(layoutInput);
		const board = boardFor(layout, opts.keyboard || DEFAULT_KEYBOARD, opts.profile);
		const table = prepareNgrams(ngrams);
		const best = compileLayout(layout, board, null);
		const keyCount = new Float64Array(board.codes.length);
		const c = streamCounts();
		const unsupportedChars = {};
		// Per key: how often it takes part in each bad event, and each event's
		// key groups (a pair, or the trigram of a redirect), for the heatmap.
		const perKey = {};
		const groups = {};
		for (const event of KEY_EVENTS) {
			perKey[event] = new Float64Array(board.codes.length);
			groups[event] = new Map();
		}
		// A pair's or a trigram's group id holds its keys in increasing order.
		// Counting every event's groups costs about 40 % on a whole library, so
		// only the SFB partners the ranking shows are counted unless asked.
		const grouped = {};
		for (const event of KEY_EVENTS) grouped[event] = opts.keyGroups === true || event === 'sfb';
		const count = (event, id, n) => groups[event].set(id, (groups[event].get(id) || 0) + n);
		const blame = {
			pair(event, n, a, b) {
				perKey[event][a] += n;
				perKey[event][b] += n;
				if (grouped[event]) count(event, a < b ? a * KEY_BASE + b : b * KEY_BASE + a, n);
			},
			triple(event, n, a, b, d) {
				perKey[event][a] += n;
				perKey[event][b] += n;
				perKey[event][d] += n;
				if (!grouped[event]) return;
				const low = Math.min(a, b, d);
				const high = Math.max(a, b, d);
				count(event, (low * KEY_BASE + (a + b + d - low - high)) * KEY_BASE + high, n);
			}
		};

		walkKeyStream(board, best, table, streamVisitor(board, c, keyCount, unsupportedChars, blame));
		const m = streamMetrics(
			layout,
			board,
			best,
			c,
			keyCount,
			opts,
			compactFit(layout, board, table, opts.format, opts.formWeights)
		);
		const metrics = m.metrics;
		const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
		const fingerIds = data().model.fingers;
		const result = {
			layout: {
				id: layout.id,
				name: layout.name,
				origin: layout.origin,
				source: layout.source,
				authors: layout.authors,
				url: layout.url,
				language: layout.language
			},
			keyboard: board.id,
			// The fingering profile measured with (null: the defaults), for the key map.
			profile: board.profile,
			metrics,
			fingers: m.fingers,
			// Each non-thumb finger's share of the non-thumb presses, and the ideal
			// load it is measured against: the two sides of finger_imbalance.
			fingerShares: Object.fromEntries(
				Object.keys(m.ideal).map((id) => [id, pct(m.fingerLoad[fingerIds.indexOf(id)], m.pressed)])
			),
			idealLoad: Object.assign({}, m.ideal),
			hands: { left: pct(m.left, m.left + m.right), right: pct(m.right, m.left + m.right) },
			rows: {
				number: metrics.number_row,
				top: metrics.top_row,
				home: metrics.home_row,
				bottom: metrics.bottom_row
			},
			trigramClasses: {
				roll3_in: metrics.roll3_in,
				roll3_out: metrics.roll3_out,
				alternation: metrics.alternation,
				redirect: metrics.redirect,
				roll_mixed: pct(c.roll_mixed, c.trigrams),
				same_finger: pct(c.same_finger_trigram, c.trigrams)
			},
			keys: keyReport(board, {
				keyCount,
				allPresses: m.allPresses,
				pressed: m.pressed,
				fingerLoad: m.fingerLoad,
				ideal: m.ideal,
				perKey,
				groups,
				counts: c
			}),
			coverage: {
				// Keys the layout puts characters on that this keyboard lacks (a
				// 36-key board has no number row): their characters count as unsupported.
				missingKeys: Object.keys(layout.rows)
					.filter(
						(code) => !board.index.has(code) && layout.rows[code].some((cell) => cell !== null)
					)
					.sort(),
				typed: c.chars,
				unsupported: c.unsupported,
				unsupportedChars,
				bigrams: c.bigrams,
				trigrams: c.trigrams
			}
		};
		result.score = score(result, opts.weights);
		return result;
	}

	/** The counters the key stream adds to: every one a sum over the n-grams. */
	function streamCounts() {
		return {
			chars: 0,
			unsupported: 0,
			modifiers: 0,
			dead: 0,
			distance: 0,
			bigrams: 0,
			sfb: 0,
			repeat: 0,
			lsb: 0,
			scissors: 0,
			half_scissors: 0,
			roll_in: 0,
			roll_out: 0,
			hand_change: 0,
			trigrams: 0,
			sfs: 0,
			roll3_in: 0,
			roll3_out: 0,
			alternation: 0,
			redirect: 0,
			redirect_bad: 0,
			roll_mixed: 0,
			same_finger_trigram: 0
		};
	}

	/**
	 * The visitor of walkKeyStream that classifies every press, key bigram and
	 * key trigram into the counters: the one definition of the stream metrics.
	 * Every count is a sum, so a negative n takes an n-gram back out (scoreSession).
	 * @param {object} board - From keyboard().
	 * @param {object} c - From streamCounts().
	 * @param {Float64Array} keyCount - Presses per key, modifiers included.
	 * @param {object} unsupportedChars - Character → count, filled.
	 * @param {{pair: function, triple: function}|null} blame - Receives each bad
	 *   event's keys (the heatmap), or null.
	 * @returns {object} The visitor.
	 */
	function streamVisitor(board, c, keyCount, unsupportedChars, blame) {
		const thumb = board.finger.map((f) => f === LEFT_THUMB || f === RIGHT_THUMB);
		const blame2 = blame ? blame.pair : () => {};
		const blame3 = blame ? blame.triple : () => {};
		return {
			char(char, seq, n) {
				c.chars += n;
				if (seq.dead) c.dead += n;
				if (seq.shift + seq.altgr > 0) c.modifiers += n;
			},
			unsupported(char, n) {
				c.unsupported += n;
				unsupportedChars[char] = (unsupportedChars[char] || 0) + n;
			},
			press(k, n) {
				keyCount[k] += n;
				c.distance += board.reach[k] * n;
			},
			bigram(k1, k2, n) {
				if (thumb[k1] || thumb[k2]) return;
				c.bigrams += n;
				const f1 = board.finger[k1];
				const f2 = board.finger[k2];
				if (k1 === k2) {
					c.repeat += n;
					return;
				}
				if (f1 === f2) {
					c.sfb += n;
					blame2('sfb', n, k1, k2);
					return;
				}
				if (board.hand[k1] !== board.hand[k2]) {
					c.hand_change += n;
					return;
				}
				const o1 = board.order[k1];
				const o2 = board.order[k2];
				if (Math.abs(o1 - o2) === 1) {
					// A scissor: the longer finger bends down while the shorter one
					// reaches up, one row apart (half) or two (full).
					const longer = FINGER_LENGTH[o1] > FINGER_LENGTH[o2] ? k1 : k2;
					const shorter = longer === k1 ? k2 : k1;
					const down = board.row[longer] - board.row[shorter];
					if (down >= 2) {
						c.scissors += n;
						blame2('scissors', n, k1, k2);
					} else if (down === 1) {
						c.half_scissors += n;
						blame2('half_scissors', n, k1, k2);
					}
					if (board.lateral[k1] || board.lateral[k2]) {
						c.lsb += n;
						blame2('lsb', n, k1, k2);
					}
				}
				if (o2 > o1) c.roll_in += n;
				else c.roll_out += n;
			},
			trigram(k1, k2, k3, n) {
				if (thumb[k1] || thumb[k2] || thumb[k3]) return;
				c.trigrams += n;
				const f1 = board.finger[k1];
				const f2 = board.finger[k2];
				const f3 = board.finger[k3];
				if (f1 === f3 && k1 !== k3) {
					c.sfs += n;
					blame2('sfs', n, k1, k3);
				}
				if (f1 === f2 || f2 === f3) {
					c.same_finger_trigram += n;
					return;
				}
				const h1 = board.hand[k1];
				const h2 = board.hand[k2];
				const h3 = board.hand[k3];
				if (h1 === h2 && h2 === h3) {
					const d = (board.order[k2] - board.order[k1]) * (board.order[k3] - board.order[k2]);
					if (d > 0) {
						if (board.order[k2] > board.order[k1]) c.roll3_in += n;
						else c.roll3_out += n;
					} else {
						c.redirect += n;
						blame3('redirect', n, k1, k2, k3);
						const index = [k1, k2, k3].some((k) => board.order[k] === INDEX_ORDER);
						if (!index) {
							c.redirect_bad += n;
							blame3('redirect_bad', n, k1, k2, k3);
						}
					}
					return;
				}
				if (h1 !== h2 && h2 !== h3) c.alternation += n;
				else c.roll_mixed += n;
			}
		};
	}

	/**
	 * Every metric of a layout from its stream counters, and the loads the
	 * report shows: the one definition analyse() and scoreSession() share.
	 * @param {object} layout - Library shape, checked.
	 * @param {object} board - From keyboard().
	 * @param {Map} best - From compileLayout().
	 * @param {object} c - The stream counters (streamCounts).
	 * @param {Float64Array} keyCount - Presses per key.
	 * @param {object} opts - The analyse() options.
	 * @param {number} compact - compact_fit, measured by the caller.
	 * @returns {object} {metrics, fingers, fingerLoad, ideal, pressed, allPresses, left, right}.
	 */
	function streamMetrics(layout, board, best, c, keyCount, opts, compact) {
		const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
		const allChars = c.chars + c.unsupported;
		// Finger load over every press but the thumbs'.
		const fingerIds = data().model.fingers;
		const fingerLoad = new Float64Array(fingerIds.length);
		const rowLoad = {};
		let pressed = 0;
		let outer = 0;
		let typing = 0;
		const isThumb = (k) => board.finger[k] === LEFT_THUMB || board.finger[k] === RIGHT_THUMB;
		for (let k = 0; k < keyCount.length; k++) {
			fingerLoad[board.finger[k]] += keyCount[k];
			if (isThumb(k)) continue;
			pressed += keyCount[k];
			if (board.outer[k]) outer += keyCount[k];
		}
		const modifierKeys = new Set(Object.values(board.modifiers));
		for (let k = 0; k < keyCount.length; k++) {
			if (isThumb(k) || modifierKeys.has(k)) continue;
			typing += keyCount[k];
			// Rows relative to each finger's home key: a staggered home counts as home.
			rowLoad[board.relRow[k]] = (rowLoad[board.relRow[k]] || 0) + keyCount[k];
		}
		const allPresses = fingerLoad.reduce((sum, v) => sum + v, 0);
		const fingers = {};
		fingerIds.forEach((id, f) => {
			fingers[id] = pct(fingerLoad[f], allPresses);
		});
		const ideal = idealLoad(opts.idealLoad);
		let imbalance = 0;
		for (const [id, target] of Object.entries(ideal))
			imbalance += Math.abs(pct(fingerLoad[fingerIds.indexOf(id)], pressed) - target);
		const left = fingerLoad.slice(0, LEFT_THUMB).reduce((sum, v) => sum + v, 0);
		const right = fingerLoad.slice(RIGHT_THUMB + 1).reduce((sum, v) => sum + v, 0);
		const metrics = {
			sfb: pct(c.sfb, c.bigrams),
			repeat: pct(c.repeat, c.bigrams),
			sfs: pct(c.sfs, c.trigrams),
			lsb: pct(c.lsb, c.bigrams),
			scissors: pct(c.scissors, c.bigrams),
			half_scissors: pct(c.half_scissors, c.bigrams),
			roll_in: pct(c.roll_in, c.bigrams),
			roll_out: pct(c.roll_out, c.bigrams),
			hand_change: pct(c.hand_change, c.bigrams),
			roll3_in: pct(c.roll3_in, c.trigrams),
			roll3_out: pct(c.roll3_out, c.trigrams),
			alternation: pct(c.alternation, c.trigrams),
			redirect: pct(c.redirect, c.trigrams),
			redirect_bad: pct(c.redirect_bad, c.trigrams),
			home_row: pct(rowLoad[0] || 0, typing),
			top_row: pct(rowLoad[-1] || 0, typing),
			bottom_row: pct(rowLoad[1] || 0, typing),
			number_row: pct(rowLoad[-2] || 0, typing),
			distance: c.chars > 0 ? c.distance / c.chars : 0,
			finger_imbalance: imbalance / 2,
			hand_imbalance: pct(Math.abs(left - right), left + right),
			pinky_load: pct(fingerLoad[0] + fingerLoad[9], pressed),
			modifier_usage: pct(c.modifiers, c.chars),
			dead_key_usage: pct(c.dead, c.chars),
			outer_column: pct(outer, pressed),
			unsupported: pct(c.unsupported, allChars),
			compact_fit: compact,
			char_coverage: charCoverage(best),
			direct_digits: directDigits(layout, board),
			shortcut_left: shortcutLeft(layout, board, shortcuts(opts.shortcuts))
		};
		return { metrics, fingers, fingerLoad, ideal, pressed, allPresses, left, right };
	}

	/**
	 * The key held for Shift when a key is typed: the pinky's Shift of the other
	 * hand (ShiftRight for a left-hand key).
	 */
	function shiftKeyFor(board, k) {
		const f = board.finger[k];
		return board.hand[k] === 0 && f !== LEFT_THUMB && f !== RIGHT_THUMB
			? board.modifiers.shiftForLeft
			: board.modifiers.shiftForRight;
	}

	/**
	 * Walks the expanded key stream of a corpus from its character tables: the
	 * pairs and triples inside a character's sequence come from its unigram
	 * count, the pair across two characters from their bigram, and the triples
	 * across three characters from their trigram. Held modifiers are pressed
	 * (press) but are not in the stream (bigram, trigram).
	 * @param {object} board - From keyboard().
	 * @param {Map} best - From compileLayout().
	 * @param {object} table - From prepareNgrams().
	 * @param {{char, unsupported, press, bigram, trigram}} visit - Callbacks:
	 *   char(char, seq, n), unsupported(char, n), press(k, n) for every press
	 *   (modifiers included), bigram(k1, k2, n), trigram(k1, k2, k3, n).
	 */
	function walkKeyStream(board, best, table, visit) {
		for (const [char, n] of table.uni) walkChar(board, best.get(char), char, n, visit);
		for (const [a, b, n] of table.bi) walkPair(best.get(a), best.get(b), n, visit);
		for (const [a, b, d, n] of table.tri)
			walkTriple(best.get(a), best.get(b), best.get(d), n, visit);
	}

	/**
	 * The stream of one character typed n times: its presses and inner key
	 * n-grams. seq is its sequence (compileLayout), undefined when unsupported.
	 */
	function walkChar(board, seq, char, n, visit) {
		if (!seq) {
			visit.unsupported(char, n);
			return;
		}
		visit.char(char, seq, n);
		for (const k of seq.keys) visit.press(k, n);
		// The held modifiers: Shift by the other hand's pinky, AltGr by a thumb.
		if (seq.shift > 0)
			visit.press(shiftKeyFor(board, seq.keys[seq.keys.length - 1]), n * seq.shift);
		if (seq.altgr > 0) visit.press(board.modifiers.altgr, n * seq.altgr);
		const keys = seq.keys;
		for (let i = 0; i + 1 < keys.length; i++) visit.bigram(keys[i], keys[i + 1], n);
		for (let i = 0; i + 2 < keys.length; i++) visit.trigram(keys[i], keys[i + 1], keys[i + 2], n);
	}

	/**
	 * The key n-grams across one character bigram (sequences sa, sb): the pair,
	 * and the key triples that start in a and end in b.
	 */
	function walkPair(sa, sb, n, visit) {
		if (!sa || !sb) return;
		const ka = sa.keys;
		const kb = sb.keys;
		const la = ka.length;
		const length = la + kb.length;
		const at = (j) => (j < la ? ka[j] : kb[j - la]);
		visit.bigram(ka[la - 1], kb[0], n);
		for (let i = Math.max(0, la - 2); i < la; i++)
			if (i + 2 < length) visit.trigram(at(i), at(i + 1), at(i + 2), n);
	}

	/** The key trigram across one character trigram whose middle is one key. */
	function walkTriple(sa, sb, sd, n, visit) {
		if (!sb || sb.keys.length !== 1 || !sa || !sd) return;
		visit.trigram(sa.keys[sa.keys.length - 1], sb.keys[0], sd.keys[0], n);
	}

	// Key n-gram codes: k1 * KEY_BASE + k2, and (k1 * KEY_BASE + k2) * KEY_BASE + k3.
	const KEY_BASE = 1024;
	// The bad events the heatmap blames on keys: how many keys each one
	// involves, and those counted over trigrams.
	const EVENT_KEYS = {
		sfb: 2,
		sfs: 2,
		lsb: 2,
		scissors: 2,
		half_scissors: 2,
		redirect: 3,
		redirect_bad: 3
	};
	const KEY_EVENTS = Object.keys(EVENT_KEYS);
	const TRIGRAM_EVENTS = new Set(['sfs', 'redirect', 'redirect_bad']);
	// The metrics whose value the keys share exactly (keyReport cost).
	const KEY_COST_METRICS = KEY_EVENTS.concat([
		'distance',
		'finger_imbalance',
		'pinky_load',
		'outer_column'
	]);
	// How many of its worst pairs or trigrams each key names.
	const WORST_GROUPS = 3;
	const keyNgramCache = new WeakMap();

	/**
	 * The key n-grams of a layout on a corpus, for the scorers that model
	 * another analyser (analyser_scores.js): the same expanded key stream the
	 * metrics are computed on, as sparse counts. Cached per prepared table,
	 * layout object and keyboard.
	 * @param {object} layoutInput - Library shape (see layoutFromRows).
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {{keyboard?: string}} [options] - Board.
	 * @returns {object} {board, layout, best, presses: Float64Array per key
	 *   (held modifiers included), stream: Float64Array per key (the stream
	 *   only), bigrams: Map code → n, trigrams: Map code → n, chars (typed
	 *   characters), unsupported, modifiers (characters typed with a held
	 *   modifier), dead (characters typed through a dead key), KEY_BASE}.
	 */
	function keyNgrams(layoutInput, ngrams, options) {
		const opts = options || {};
		const table = prepareNgrams(ngrams);
		const layout = layoutFromRows(layoutInput);
		const board = boardFor(layout, opts.keyboard || DEFAULT_KEYBOARD);
		if (!keyNgramCache.has(table)) keyNgramCache.set(table, new WeakMap());
		const perLayout = keyNgramCache.get(table);
		if (!perLayout.has(layoutInput)) perLayout.set(layoutInput, new Map());
		const perBoard = perLayout.get(layoutInput);
		if (perBoard.has(board.id)) return perBoard.get(board.id);
		const best = compileLayout(layout, board, null);
		const out = {
			board,
			layout,
			best,
			presses: new Float64Array(board.codes.length),
			stream: new Float64Array(board.codes.length),
			bigrams: new Map(),
			trigrams: new Map(),
			chars: 0,
			unsupported: 0,
			modifiers: 0,
			dead: 0,
			KEY_BASE
		};
		const add = (map, code, n) => map.set(code, (map.get(code) || 0) + n);
		walkKeyStream(board, best, table, {
			char(char, seq, n) {
				out.chars += n;
				if (seq.dead) out.dead += n;
				if (seq.shift + seq.altgr > 0) out.modifiers += n;
				for (const k of seq.keys) out.stream[k] += n;
			},
			unsupported(char, n) {
				out.unsupported += n;
			},
			press(k, n) {
				out.presses[k] += n;
			},
			bigram(k1, k2, n) {
				add(out.bigrams, k1 * KEY_BASE + k2, n);
			},
			trigram(k1, k2, k3, n) {
				add(out.trigrams, (k1 * KEY_BASE + k2) * KEY_BASE + k3, n);
			}
		});
		perBoard.set(board.id, out);
		return out;
	}

	/** Whether two key sequences put the same presses and modifiers in the stream. */
	function sameSequence(a, b) {
		if (a === b) return true;
		if (!a || !b) return false;
		if (a.shift !== b.shift || a.altgr !== b.altgr || a.dead !== b.dead) return false;
		if (a.keys.length !== b.keys.length) return false;
		for (let i = 0; i < a.keys.length; i++) if (a.keys[i] !== b.keys[i]) return false;
		return true;
	}

	/** A cell as a token for a multiset comparison: null adds nothing. */
	const cellToken = (cell) =>
		cell === null ? null : typeof cell === 'string' ? `s${cell}` : `d${cell.dead}`;

	/** Whether two layouts' dead-key rules are the same. */
	function sameDead(a, b) {
		const states = Object.keys(a);
		if (states.length !== Object.keys(b).length) return false;
		for (const state of states) {
			const ra = a[state];
			const rb = b[state];
			if (!rb) return false;
			const typed = Object.keys(ra);
			if (typed.length !== Object.keys(rb).length) return false;
			for (const t of typed)
				if (cellToken(ra[t]) !== cellToken(rb[t] === undefined ? null : rb[t])) return false;
		}
		return true;
	}

	/**
	 * An incremental scorer for a search that changes a layout a little at a
	 * time (the optimizer's swaps). trial(layout).total is the global score
	 * analyse(layout, ngrams, options).score.total gives, up to float
	 * rounding, but a trial walks only the corpus n-grams that hold a
	 * character whose key sequence changed: the whole layout is compiled
	 * again (so a change anywhere in a dead-key chain or a cheapest-way
	 * choice is seen), each character's sequence is compared with the
	 * current one, and those n-grams are taken out with the old sequences and
	 * put back with the new ones through the same visitor analyse() uses.
	 * A compact form factor is measured again only when the trial changes the
	 * cells on the keys that form keeps, or the dead-key rules.
	 * @param {object} layoutInput - The current layout (library shape).
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {object} [options] - As analyse() (keyGroups aside).
	 * @returns {{total: number, trial: function(object): {total: number,
	 *   changed: number, commit: function(): void}}} total is the current
	 *   layout's score; trial scores another layout on the same board without
	 *   changing the session, and its commit makes that layout the current one.
	 * @throws {Error} When a trial's layout is measured on another board.
	 */
	function scoreSession(layoutInput, ngrams, options) {
		const opts = options || {};
		const table = prepareNgrams(ngrams);
		const keyboardId = opts.keyboard || DEFAULT_KEYBOARD;
		const firstLayout = layoutFromRows(layoutInput);
		const board = boardFor(firstLayout, keyboardId, opts.profile);
		const forms = compactForms(opts.format, opts.formWeights);
		const formMissing = forms.map((form) => new Set(form.missing));
		// The corpus's characters as ids, and its n-grams as id lists: an array
		// lookup costs a fraction of a Map lookup by string.
		const chars = [];
		const idOf = new Map();
		const id = (char) => {
			if (!idOf.has(char)) {
				idOf.set(char, chars.length);
				chars.push(char);
			}
			return idOf.get(char);
		};
		const uniIds = Int32Array.from(table.uni, (entry) => id(entry[0]));
		const uniN = Float64Array.from(table.uni, (entry) => entry[1]);
		const biN = Float64Array.from(table.bi, (entry) => entry[2]);
		const triN = Float64Array.from(table.tri, (entry) => entry[3]);
		const biIds = new Int32Array(2 * table.bi.length);
		table.bi.forEach((entry, i) => {
			biIds[2 * i] = id(entry[0]);
			biIds[2 * i + 1] = id(entry[1]);
		});
		const triIds = new Int32Array(3 * table.tri.length);
		table.tri.forEach((entry, i) => {
			for (let j = 0; j < 3; j++) triIds[3 * i + j] = id(entry[j]);
		});
		// Character id → the entries it appears in, each entry once.
		const uniOf = chars.map(() => []);
		const biOf = chars.map(() => []);
		const triOf = chars.map(() => []);
		uniIds.forEach((u, i) => uniOf[u].push(i));
		for (let i = 0; i < table.bi.length; i++) {
			biOf[biIds[2 * i]].push(i);
			if (biIds[2 * i + 1] !== biIds[2 * i]) biOf[biIds[2 * i + 1]].push(i);
		}
		for (let i = 0; i < table.tri.length; i++) {
			const [a, b, d] = [triIds[3 * i], triIds[3 * i + 1], triIds[3 * i + 2]];
			triOf[a].push(i);
			if (b !== a) triOf[b].push(i);
			if (d !== a && d !== b) triOf[d].push(i);
		}
		// An entry already walked in this trial carries the trial's stamp.
		const stamps = {
			uni: new Uint32Array(table.uni.length),
			bi: new Uint32Array(table.bi.length),
			tri: new Uint32Array(table.tri.length)
		};
		let stamp = 0;
		// The unsupported characters are not scored; the visitor needs a place for them.
		const unsupportedChars = {};
		const sequences = (best) => chars.map((char) => best.get(char));

		// What one key bigram or trigram adds, probed once from the visitor with
		// n = 1: the counters it raises (each by n). The trial then adds n to
		// those counters in a typed array, the same sums at a fraction of the cost.
		const names = Object.keys(streamCounts());
		const K = board.codes.length;
		const patterns = [];
		const patternOf = new Map();
		const probe = (call) => {
			const counts = streamCounts();
			call(streamVisitor(board, counts, new Float64Array(K), {}, null));
			const raised = [];
			names.forEach((name, j) => {
				if (counts[name] === 0) return;
				if (counts[name] !== 1)
					throw new Error(`layout_analysis: ${name} is not a plain count of the key stream`);
				raised.push(j);
			});
			const key = raised.join(',');
			if (!patternOf.has(key)) {
				patternOf.set(key, patterns.length);
				patterns.push(Int32Array.from(raised));
			}
			return patternOf.get(key);
		};
		const pairPattern = new Int32Array(K * K).fill(-1);
		const triplePattern = new Int32Array(K * K * K).fill(-1);
		/** The session's visitor: the presses through analyse()'s own, the key n-grams memoized. */
		const sessionVisitor = (c, keyCount, counts) => {
			const plain = streamVisitor(board, c, keyCount, unsupportedChars, null);
			return {
				char: plain.char,
				unsupported: plain.unsupported,
				press: plain.press,
				bigram(k1, k2, n) {
					const at = k1 * K + k2;
					if (pairPattern[at] < 0) pairPattern[at] = probe((v) => v.bigram(k1, k2, 1));
					const raised = patterns[pairPattern[at]];
					for (let j = 0; j < raised.length; j++) counts[raised[j]] += n;
				},
				trigram(k1, k2, k3, n) {
					const at = (k1 * K + k2) * K + k3;
					if (triplePattern[at] < 0) triplePattern[at] = probe((v) => v.trigram(k1, k2, k3, 1));
					const raised = patterns[triplePattern[at]];
					for (let j = 0; j < raised.length; j++) counts[raised[j]] += n;
				}
			};
		};

		const totalOf = (layout, best, c, counts, keyCount, formValues) => {
			const all = Object.assign({}, c);
			names.forEach((name, j) => {
				all[name] += counts[j];
			});
			return score(
				streamMetrics(layout, board, best, all, keyCount, opts, weightedFit(forms, formValues)),
				opts.weights
			).total;
		};

		const delta = {
			c: streamCounts(),
			counts: new Float64Array(names.length),
			keyCount: new Float64Array(K)
		};
		const deltaVisitor = sessionVisitor(delta.c, delta.keyCount, delta.counts);
		const best = compileLayout(firstLayout, board, null);
		const c = streamCounts();
		const counts = new Float64Array(names.length);
		const keyCount = new Float64Array(K);
		walkKeyStream(board, best, table, sessionVisitor(c, keyCount, counts));
		const formValues = forms.map((form) => formFit(firstLayout, board, table, form));
		let state = {
			layout: firstLayout,
			best,
			seqs: sequences(best),
			c,
			counts,
			keyCount,
			formValues,
			total: totalOf(firstLayout, best, c, counts, keyCount, formValues)
		};

		/** Whether a form keeps the same cells on its keys in both layouts. */
		function sameForm(before, after, codes, missing) {
			const tokens = (layout) => {
				const out = [];
				for (const code of codes) {
					if (!board.index.has(code) || missing.has(code)) continue;
					for (const cell of layout.rows[code] || []) {
						const token = cellToken(cell);
						if (token !== null) out.push(token);
					}
				}
				return out.sort().join('\u0000');
			};
			return tokens(before) === tokens(after);
		}

		/** The keys whose cells differ between two layouts. */
		function changedCodes(before, after) {
			const out = [];
			const cellAt = (layout, code, i) =>
				layout.rows[code] && layout.rows[code][i] !== undefined ? layout.rows[code][i] : null;
			for (const code of new Set(Object.keys(before.rows).concat(Object.keys(after.rows))))
				for (let i = 0; i < LAYER_IDS.length; i++)
					if (cellToken(cellAt(before, code, i)) !== cellToken(cellAt(after, code, i))) {
						out.push(code);
						break;
					}
			return out;
		}

		function trial(layoutInput) {
			const layout = layoutFromRows(layoutInput);
			if (boardFor(layout, keyboardId, opts.profile) !== board)
				throw new Error('layout_analysis: a score session keeps the board it started on');
			const nextBest = compileLayout(layout, board, null);
			const old = state.seqs;
			const seqs = sequences(nextBest);
			// The trial's changes go to the delta buffers, then onto a copy of the state.
			for (const name of names) delta.c[name] = 0;
			delta.counts.fill(0);
			delta.keyCount.fill(0);
			const visit = deltaVisitor;
			stamp += 1;
			let changed = 0;
			for (let ch = 0; ch < chars.length; ch++) {
				if (sameSequence(old[ch], seqs[ch])) continue;
				changed += 1;
				for (const i of uniOf[ch]) {
					if (stamps.uni[i] === stamp) continue;
					stamps.uni[i] = stamp;
					const u = uniIds[i];
					const n = uniN[i];
					walkChar(board, old[u], chars[u], -n, visit);
					walkChar(board, seqs[u], chars[u], n, visit);
				}
				for (const i of biOf[ch]) {
					if (stamps.bi[i] === stamp) continue;
					stamps.bi[i] = stamp;
					const a = biIds[2 * i];
					const b = biIds[2 * i + 1];
					const n = biN[i];
					walkPair(old[a], old[b], -n, visit);
					walkPair(seqs[a], seqs[b], n, visit);
				}
				for (const i of triOf[ch]) {
					if (stamps.tri[i] === stamp) continue;
					stamps.tri[i] = stamp;
					const a = triIds[3 * i];
					const b = triIds[3 * i + 1];
					const d = triIds[3 * i + 2];
					const n = triN[i];
					walkTriple(old[a], old[b], old[d], -n, visit);
					walkTriple(seqs[a], seqs[b], seqs[d], n, visit);
				}
			}
			const nextC = Object.assign({}, state.c);
			for (const name of names) nextC[name] += delta.c[name];
			const nextCounts = state.counts.slice();
			for (let j = 0; j < nextCounts.length; j++) nextCounts[j] += delta.counts[j];
			const nextKeys = state.keyCount.slice();
			for (let k = 0; k < K; k++) nextKeys[k] += delta.keyCount[k];
			// A compact form is measured again only when its kept cells changed.
			const before = state.layout;
			const deadSame = sameDead(before.dead, layout.dead);
			const codes = changedCodes(before, layout);
			const nextForms = forms.map((form, i) =>
				deadSame && sameForm(before, layout, codes, formMissing[i])
					? state.formValues[i]
					: formFit(layout, board, table, form)
			);
			const total = totalOf(layout, nextBest, nextC, nextCounts, nextKeys, nextForms);
			return {
				total,
				changed,
				commit() {
					state = {
						layout,
						best: nextBest,
						seqs,
						c: nextC,
						counts: nextCounts,
						keyCount: nextKeys,
						formValues: nextForms,
						total
					};
				}
			};
		}

		return {
			get total() {
				return state.total;
			},
			trial
		};
	}

	/**
	 * The per-key data of the heatmap.
	 * - presses, sfb, sfs, lsb, scissors (full and half), redirect: the key's
	 *   share of the presses, or of the bigrams or trigrams it takes part in;
	 * - cost: for each metric of KEY_COST_METRICS, the part of that metric's
	 *   value the key causes; each event is shared equally between the keys it
	 *   involves, so the keys' parts add up to the metric (finger_imbalance
	 *   goes to the keys of the fingers above their ideal load, in proportion
	 *   to their presses);
	 * - worst: for each event metric, the key's WORST_GROUPS heaviest groups
	 *   with it (the other key of a pair, the two others of a redirect), each
	 *   [codes, % of the bigrams or trigrams].
	 * @param {object} board - From keyboard().
	 * @param {object} m - What analyse() measured: keyCount, allPresses, pressed
	 *   (every press but the thumbs'), fingerLoad, ideal, perKey, groups, counts.
	 * @returns {object} code → {presses, sfb, sfs, lsb, scissors, redirect,
	 *   cost, worst}.
	 */
	function keyReport(board, m) {
		const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
		const c = m.counts;
		const fingerIds = data().model.fingers;
		const thumb = (k) => board.finger[k] === LEFT_THUMB || board.finger[k] === RIGHT_THUMB;
		const whole = (event) => (TRIGRAM_EVENTS.has(event) ? c.trigrams : c.bigrams);
		// Each finger's load above its ideal, in points of the non-thumb presses.
		const over = fingerIds.map((id, f) =>
			m.ideal[id] === undefined ? 0 : Math.max(0, pct(m.fingerLoad[f], m.pressed) - m.ideal[id])
		);
		const keys = {};
		board.codes.forEach((code, k) => {
			const share = (event) => pct(m.perKey[event][k], whole(event));
			const f = board.finger[k];
			const cost = {
				distance: c.chars > 0 ? (board.reach[k] * m.keyCount[k]) / c.chars : 0,
				finger_imbalance: m.fingerLoad[f] > 0 ? (over[f] * m.keyCount[k]) / m.fingerLoad[f] : 0,
				pinky_load: !thumb(k) && (f === 0 || f === 9) ? pct(m.keyCount[k], m.pressed) : 0,
				outer_column: !thumb(k) && board.outer[k] ? pct(m.keyCount[k], m.pressed) : 0
			};
			const worst = {};
			for (const event of KEY_EVENTS) {
				cost[event] = share(event) / EVENT_KEYS[event];
				worst[event] = [];
			}
			keys[code] = {
				presses: pct(m.keyCount[k], m.allPresses),
				sfb: share('sfb'),
				sfs: share('sfs'),
				lsb: share('lsb'),
				scissors: share('scissors') + share('half_scissors'),
				redirect: share('redirect'),
				cost,
				worst
			};
		});
		// One pass per event: each key keeps its WORST_GROUPS heaviest groups (id, n).
		for (const event of KEY_EVENTS) {
			const top = new Map();
			for (const [id, n] of m.groups[event]) {
				let rest = id;
				for (let i = 0; i < EVENT_KEYS[event]; i++, rest = Math.floor(rest / KEY_BASE)) {
					const k = rest % KEY_BASE;
					if (!top.has(k)) top.set(k, []);
					const list = top.get(k);
					if (list.length && list[list.length - 1][0] === id) continue;
					if (list.length === WORST_GROUPS && list[WORST_GROUPS - 1][1] >= n) continue;
					list.push([id, n]);
					list.sort((x, y) => y[1] - x[1] || x[0] - y[0]);
					if (list.length > WORST_GROUPS) list.pop();
				}
			}
			for (const [k, list] of top)
				keys[board.codes[k]].worst[event] = list.map(([id, n]) => {
					const others = [];
					for (let i = 0, rest = id; i < EVENT_KEYS[event]; i++, rest = Math.floor(rest / KEY_BASE))
						if (rest % KEY_BASE !== k) others.unshift(board.codes[rest % KEY_BASE]);
					return [others, pct(n, whole(event))];
				});
		}
		return keys;
	}

	/**
	 * What each key costs the global score: the points of the score's penalty
	 * metrics (KEY_COST_METRICS) it causes, with these weights. The keys' costs
	 * add up to those metrics' part of the score.
	 * @param {object} result - analyse() output.
	 * @param {object} [weights] - As score(); the defaults when absent.
	 * @returns {object} code → points lost.
	 */
	function keyScoreCost(result, weights) {
		const used = weights ? Object.assign(defaultWeights(), weights) : defaultWeights();
		const out = {};
		for (const [code, key] of Object.entries(result.keys)) {
			let points = 0;
			for (const id of KEY_COST_METRICS) points += (used[id] || 0) * key.cost[id];
			out[code] = points;
		}
		return out;
	}

	/**
	 * The keyboard formats (100 %, TKL, 75 %, 65 %, 60 %), each with the keys
	 * it lacks: the one table the editor's « Format », the Comparer's and the
	 * compact form factors read (analysis_model.json).
	 * @returns {Array<{id: string, hidden: Set<string>}>} In the model's order.
	 */
	function keyboardFormats() {
		const model = data().model;
		return model.keyboard_formats.map((format) => ({
			id: format.id,
			hidden: new Set(format.hides.flatMap((block) => model.keyboard_blocks[block]))
		}));
	}

	/** The format a keyboard has when nothing chose one. */
	function defaultKeyboardFormat() {
		return data().model.default_keyboard_format;
	}

	/**
	 * The keys one keyboard format lacks.
	 * @param {string} id A keyboard_formats id.
	 * @returns {Set<string>} The hidden key codes.
	 * @throws {Error} On an unknown format.
	 */
	function formatHiddenKeys(id) {
		const format = keyboardFormats().find((entry) => entry.id === id);
		if (!format) throw new Error(`unknown keyboard format ${id}`);
		return format.hidden;
	}

	/**
	 * The compact form factors measured: the model's, a form factor marked
	 * per_keyboard_format split over the keyboard formats (its weight shared
	 * equally) or, when one format is chosen, measured on that one alone.
	 * @param {string|undefined} format The chosen keyboard format, if any.
	 * @returns {Array<{weight: number, missing: string[]}>} The form factors.
	 */
	function compactForms(format, weights) {
		const formats =
			format === undefined ? keyboardFormats() : [{ hidden: formatHiddenKeys(format) }];
		const chosen = formFactorWeights(weights);
		const forms = [];
		for (const [id, form] of Object.entries(data().model.form_factors)) {
			if (!form.per_keyboard_format) {
				forms.push({ weight: chosen[id], missing: form.missing });
				continue;
			}
			for (const entry of formats)
				forms.push({
					weight: chosen[id] / formats.length,
					missing: form.missing.concat([...entry.hidden])
				});
		}
		return forms;
	}

	/**
	 * Frequency-weighted share of the characters still typed on each compact
	 * form factor, averaged with the form factors' weights.
	 */
	function compactFit(layout, board, table, format, formWeights) {
		const forms = compactForms(format, formWeights);
		return weightedFit(
			forms,
			forms.map((form) => formFit(layout, board, table, form))
		);
	}

	/** The share of the characters still typed on one compact form factor. */
	function formFit(layout, board, table, form) {
		const reachable = compileLayout(layout, board, new Set(form.missing));
		let kept = 0;
		let all = 0;
		for (const [char, n] of table.uni) {
			all += n;
			if (reachable.has(char)) kept += n;
		}
		return all > 0 ? (100 * kept) / all : 0;
	}

	/** The form factors' shares averaged with their weights: compact_fit. */
	function weightedFit(forms, values) {
		let sum = 0;
		let weights = 0;
		forms.forEach((form, i) => {
			sum += form.weight * values[i];
			weights += form.weight;
		});
		return weights > 0 ? sum / weights : 0;
	}

	/** Share of the reference character set the layout can type. */
	function charCoverage(best) {
		const reference = codePoints(data().model.reference_characters);
		const typed = reference.filter((char) => best.has(char) && !best.get(char).substituted).length;
		return (100 * typed) / reference.length;
	}

	/** Share of the ten digits typed on the base layer. */
	function directDigits(layout, board) {
		const digits = new Set();
		for (const [code, row] of Object.entries(layout.rows)) {
			if (!board.index.has(code)) continue;
			if (typeof row[0] === 'string' && /^[0-9]$/.test(row[0])) digits.add(row[0]);
		}
		return digits.size * 10;
	}

	/** A copy of the model's shortcut table: each letter's usefulness, each key's ease. */
	function defaultShortcuts() {
		const { model } = data();
		return {
			letters: Object.assign({}, model.shortcut_letters),
			ease: Object.assign({}, model.shortcut_key_ease)
		};
	}

	/**
	 * The shortcut table shortcut_left measures with (maintainer, 2026-11-14:
	 * editable in the Studio like the weights).
	 * @param {object} [table] - {letters: letter → usefulness 0–10, ease: key →
	 *   ease 0–1}, the same letters and keys as the model's; the model's when absent.
	 * @returns {object} The table, checked.
	 * @throws {AnalysisError} On another shape, a letter or key the model lacks
	 *   or misses, or a value out of its range.
	 */
	function shortcuts(table) {
		const defaults = defaultShortcuts();
		if (table === undefined) return defaults;
		if (!table || typeof table !== 'object' || !table.letters || !table.ease)
			throw new AnalysisError('shortcuts_not_object', {}, 'a shortcut table has letters and ease');
		const checkPart = (part, max, unknownCode, valueCode, field) => {
			for (const id of Object.keys(table[part]))
				if (!(id in defaults[part]))
					throw new AnalysisError(unknownCode, { [field]: id }, `unknown shortcut ${field} ${id}`);
			for (const id of Object.keys(defaults[part])) {
				const value = table[part][id];
				if (!Number.isFinite(value) || value < 0 || value > max)
					throw new AnalysisError(
						valueCode,
						{ [field]: id, max },
						`shortcut ${field} ${id} must be a number from 0 to ${max}`
					);
			}
		};
		checkPart('letters', 10, 'shortcut_letter_unknown', 'shortcut_letter_value', 'letter');
		checkPart('ease', 1, 'shortcut_key_unknown', 'shortcut_key_value', 'key');
		return { letters: Object.assign({}, table.letters), ease: Object.assign({}, table.ease) };
	}

	/** A copy of the compact form factors' weights (analysis_model.json form_factors). */
	function defaultFormFactorWeights() {
		return Object.fromEntries(
			Object.entries(data().model.form_factors).map(([id, form]) => [id, form.weight])
		);
	}

	/**
	 * The weights compact_fit gives each compact form factor (maintainer,
	 * 2026-11-14: editable).
	 * @param {object} [weights] - form factor id → weight ≥ 0, every model form
	 *   factor and no other, not all zero; the model's when absent.
	 * @returns {object} The weights, checked.
	 * @throws {AnalysisError} On an unknown or missing form factor, a negative or
	 *   non-finite weight, or weights that are all zero.
	 */
	function formFactorWeights(weights) {
		const defaults = defaultFormFactorWeights();
		if (weights === undefined) return defaults;
		if (!weights || typeof weights !== 'object')
			throw new AnalysisError('form_weights_not_object', {}, 'form factor weights are an object');
		for (const id of Object.keys(weights))
			if (!(id in defaults))
				throw new AnalysisError('form_factor_unknown', { form: id }, `unknown form factor ${id}`);
		let sum = 0;
		for (const id of Object.keys(defaults)) {
			const value = weights[id];
			if (!Number.isFinite(value) || value < 0)
				throw new AnalysisError(
					'form_factor_weight',
					{ form: id },
					`form factor ${id} needs a weight >= 0`
				);
			sum += value;
		}
		if (sum <= 0)
			throw new AnalysisError('form_weights_zero', {}, 'at least one form factor needs a weight');
		return Object.assign({}, weights);
	}

	/** A copy of the default ideal finger load (analysis_model.json). */
	function defaultIdealLoad() {
		return Object.assign({}, data().model.ideal_finger_load);
	}

	/**
	 * The ideal finger load an analysis measures finger_imbalance against.
	 * @param {object} [load] - finger → %; the default when absent.
	 * @returns {object} The load, checked.
	 * @throws {AnalysisError} On a finger the default lacks or misses, a negative
	 *   or non-finite share, shares that do not sum to 100, or a hand whose
	 *   shares break index ≥ middle ≥ ring ≥ pinky (the maintainer's order, which
	 *   the default keeps: model.ideal_finger_load_hands).
	 */
	function idealLoad(load) {
		const { model } = data();
		if (load === undefined) return model.ideal_finger_load;
		const fingers = Object.keys(model.ideal_finger_load);
		const given = Object.keys(load);
		if (given.length !== fingers.length || !fingers.every((f) => given.includes(f)))
			throw new AnalysisError(
				'ideal_load_fingers',
				{},
				`idealLoad needs exactly ${fingers.join(', ')}`
			);
		let sum = 0;
		for (const f of fingers) {
			if (!Number.isFinite(load[f]) || load[f] < 0)
				throw new AnalysisError(
					'ideal_load_share',
					{ finger: f },
					`idealLoad.${f} must be a finite number >= 0`
				);
			sum += load[f];
		}
		if (Math.abs(sum - 100) > LOAD_SUM_TOLERANCE)
			throw new AnalysisError('ideal_load_sum', { sum }, `idealLoad sums to ${sum}, not 100`);
		// Each hand from the pinky to the index: a finger never carries less than
		// the one before it.
		for (const hand of model.ideal_finger_load_hands)
			for (let i = 1; i < hand.length; i++)
				if (load[hand[i]] < load[hand[i - 1]])
					throw new AnalysisError(
						'ideal_load_order',
						{ finger: hand[i], below: hand[i - 1] },
						`idealLoad.${hand[i]} is below idealLoad.${hand[i - 1]}`
					);
		return load;
	}

	/**
	 * Usefulness-weighted share of the shortcut letters on easy left-hand keys:
	 * a letter counts its weight times the ease of its key (0 on the right hand).
	 */
	function shortcutLeft(layout, board, table) {
		const { letters, ease } = table;
		const where = {};
		for (const [code, row] of Object.entries(layout.rows)) {
			const letter = layout.command[code] !== undefined ? layout.command[code] : row[0];
			if (typeof letter !== 'string') continue;
			const lower = letter.toLowerCase();
			if (letters[lower] !== undefined && where[lower] === undefined) where[lower] = code;
		}
		for (const [code, letter] of Object.entries(layout.command)) {
			const lower = letter.toLowerCase();
			if (letters[lower] !== undefined) where[lower] = code;
		}
		let got = 0;
		let all = 0;
		for (const [letter, weight] of Object.entries(letters)) {
			all += weight;
			const code = where[letter];
			if (code === undefined || !board.index.has(code)) continue;
			got += weight * (ease[code] || 0);
		}
		return all > 0 ? (100 * got) / all : 0;
	}

	// =======================
	// ======= 7/ Score ======
	// =======================

	/** A copy of the default weights (score_weights.json). */
	function defaultWeights() {
		return Object.assign({}, data().weights);
	}

	/**
	 * The global score of an analysis: each metric adds weight × value points
	 * when higher is better and subtracts them when lower is better.
	 * @param {object} result - analyse() output (or {metrics}).
	 * @param {object} [weights] - metric → points per unit; defaults when absent.
	 * @returns {{total: number, contributions: object, weights: object}} Score.
	 * @throws {Error} On a weight for an unknown or unscored metric, or a
	 *   negative or non-finite weight.
	 */
	function score(result, weights) {
		const used = weights ? Object.assign(defaultWeights(), weights) : defaultWeights();
		const contributions = {};
		let total = 0;
		for (const [id, weight] of Object.entries(used)) {
			const metric = METRICS[id];
			if (!metric || metric.better === 'none')
				throw new Error(`layout_analysis: ${id} is not a scored metric`);
			if (!(weight >= 0) || !Number.isFinite(weight))
				throw new Error(`layout_analysis: weight of ${id} must be a finite number >= 0`);
			const sign = metric.better === 'higher' ? 1 : -1;
			contributions[id] = sign * weight * result.metrics[id];
			total += contributions[id];
		}
		return { total, contributions, weights: used };
	}

	/**
	 * Analyses several layouts on the same n-grams and ranks them by score.
	 * @param {object[]} layouts - Library-shape layouts.
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {object} [options] - As analyse().
	 * @returns {object[]} Results, best first, each with its rank (1-based).
	 */
	function compare(layouts, ngrams, options) {
		const table = prepareNgrams(ngrams);
		const results = layouts.map((layout) => analyse(layout, table, options));
		return rank(results);
	}

	/** Sorts results by score, best first, and numbers them. */
	function rank(results) {
		const sorted = results.slice().sort((a, b) => b.score.total - a.score.total);
		sorted.forEach((result, i) => {
			result.rank = i + 1;
		});
		return sorted;
	}

	/**
	 * Compares two analyses metric by metric: each value, the difference and
	 * which one the metric prefers, then the global score the same way.
	 * @param {object} a - analyse() output, the layout read.
	 * @param {object} b - analyse() output, the layout it is compared with.
	 * @returns {{metrics: object, score: object}} metric → {a, b, delta, verdict},
	 *   delta = a − b; verdict is `better` or `worse` for a, `same` when equal,
	 *   `none` for a metric shown but not scored; score → {a, b, delta, verdict}.
	 * @throws {Error} When either result lacks a metric of METRICS or its score.
	 */
	function diff(a, b) {
		const verdict = (better, delta) => {
			if (better === 'none') return 'none';
			if (delta === 0) return 'same';
			return (better === 'higher') === delta > 0 ? 'better' : 'worse';
		};
		const metrics = {};
		for (const [id, metric] of Object.entries(METRICS)) {
			const [x, y] = [a.metrics[id], b.metrics[id]];
			if (!Number.isFinite(x) || !Number.isFinite(y))
				throw new Error(`layout_analysis: diff needs the metric ${id} on both results`);
			metrics[id] = { a: x, b: y, delta: x - y, verdict: verdict(metric.better, x - y) };
		}
		if (!a.score || !b.score) throw new Error('layout_analysis: diff needs both scores');
		const delta = a.score.total - b.score.total;
		return {
			metrics,
			score: { a: a.score.total, b: b.score.total, delta, verdict: verdict('higher', delta) }
		};
	}

	/** Re-scores and re-ranks results with new weights (no re-analysis). */
	function rescore(results, weights) {
		for (const result of results) result.score = score(result, weights);
		return rank(results);
	}

	return {
		METRICS,
		LAYER_IDS,
		AnalysisError,
		KEY_EVENTS,
		KEY_COST_METRICS,
		hashText,
		keyboard,
		fingeringProfile,
		layoutFromRows,
		layoutFromComposerSource,
		typingCodes,
		keyboardFormats,
		defaultKeyboardFormat,
		formatHiddenKeys,
		libraryLayouts,
		compileLayout,
		keyNgrams,
		ngramsFromText,
		prepareNgrams,
		analyse,
		scoreSession,
		score,
		keyScoreCost,
		defaultWeights,
		defaultIdealLoad,
		idealLoad,
		defaultShortcuts,
		shortcuts,
		defaultFormFactorWeights,
		formFactorWeights,
		compare,
		rescore,
		diff
	};
})();

// Node (tests, codegen) reads the engine through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_ANALYSIS;
