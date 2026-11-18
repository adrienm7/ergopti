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
 * 2. Keystrokes as typed: each character is typed, where it stands, the way
 *    that costs least among those the layout offers (keys on any level, dead
 *    keys, multi-character outputs), and the key bigrams and trigrams are
 *    those of the expanded stream, rebuilt from the character uni-, bi- and
 *    trigrams (exactly where a character has one way).
 * 3. One source for data: fingers, keyboards, weights and the layout library
 *    come from LAYOUT_ANALYSIS_DATA (_generated/analysis_data.js), read on
 *    first use so the codegen can load this file to convert layouts.
 * 4. Fail fast: an unknown keyboard, metric or weight throws.
 * 5. Incremental: scoreSession re-scores a changed layout by compiling again
 *    only the ways its changed cells and dead-key rules reach
 *    (compileCoreFrom, list for list a whole compile's) and walking only the
 *    n-grams of the characters whose key sequence changed, through the same
 *    visitor and metric code as analyse(), for the layout optimizer.
 * 6. Bonuses apart from effort: the distinct characters a layout types
 *    (coverage_bonus, over a fixed cap) and objective simplicity rules.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS = (function () {
	'use strict';

	// The built-ins as locals. The Node tests and the codegen run the engine in
	// a vm context, where each read of a global goes through the context's
	// interceptor, about a thousand times slower than a local one; the walks
	// read Math, Map, the typed arrays and Infinity millions of times.
	const {
		Array,
		Error,
		Float64Array,
		Int32Array,
		JSON,
		Map,
		Math,
		Number,
		Object,
		Set,
		String,
		Uint8Array,
		Uint16Array,
		Uint32Array,
		WeakMap
	} = globalThis;
	const INFINITY = Number.POSITIVE_INFINITY;

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
	// A row jump: two keys of one hand at least this many rows apart (top and
	// bottom row, number and home row).
	const ROW_JUMP_ROWS = 2;
	// Ways to type one character kept for the context choice: a symbol on two
	// keys, on AltGr and behind a dead key all stay; more never occur in the
	// library and would multiply the cost of the choice.
	const MAX_WAYS = 4;
	// Separates two tokens in a map key (no layout types this control character).
	const TOKEN_SEP = '\u0001';
	// How many times over the key stream may count a table's whole total (a
	// character's keys, both keys of a pair): its sums must stay exact.
	const WHOLE_SUM_MARGIN = 64;

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
		row_jump: { unit: '%', better: 'none', of: 'bigrams' },
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
		shortcut_left: { unit: '%', better: 'higher', of: 'layout' },
		distinct_chars: { unit: 'chars', better: 'none', of: 'layout' },
		coverage_bonus: { unit: '%', better: 'higher', of: 'layout' },
		simplicity: { unit: '%', better: 'higher', of: 'layout' }
	};

	/**
	 * How many decimals the pages show a metric with: a count none, a distance
	 * one, a share two. The one source for the Comparer, the panel and the
	 * optimizer.
	 * @param {string} id - A METRICS id.
	 * @returns {number} Fraction digits.
	 */
	function metricDigits(id) {
		const unit = METRICS[id].unit;
		if (unit === 'chars') return 0;
		return unit === 'mm' ? 1 : 2;
	}

	// =======================
	// ======= 2/ Data =======
	// =======================

	let loadedData = null;

	/**
	 * The generated data, read on first use.
	 * @returns {object} LAYOUT_ANALYSIS_DATA.
	 * @throws {Error} When _generated/analysis_data.js was not loaded first.
	 */
	function data() {
		// Kept once found: a read of the global costs dearly in a vm context.
		if (loadedData) return loadedData;
		if (typeof LAYOUT_ANALYSIS_DATA === 'undefined' || !LAYOUT_ANALYSIS_DATA)
			throw new Error('layout_analysis: load _generated/analysis_data.js before the engine');
		loadedData = LAYOUT_ANALYSIS_DATA;
		return loadedData;
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
		// A JIS or ABNT board adds its own keys (Yen, Ro) to the base fingering.
		const fingering = Object.assign(
			{},
			baseFingering,
			board3d ? {} : spec.extra_fingers || {},
			checked ? checked.fingers : {}
		);
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

	/** The number of code points of a string, without splitting the usual one-unit case. */
	function codeLength(text) {
		return isOneCodePoint(text) ? 1 : textPoints(text).length;
	}

	const textPointCache = new Map();
	// Short texts split once: the cells, rule outputs and substitutions of the
	// layouts analysed, read again at every analysis.
	const TEXT_CACHE_SIZE = 8192;

	/** codePoints of a short text (a cell or a dead-key output), cached; the array is shared. */
	function textPoints(text) {
		let points = textPointCache.get(text);
		if (points) return points;
		points = codePoints(text);
		if (textPointCache.size >= TEXT_CACHE_SIZE) textPointCache.clear();
		textPointCache.set(text, points);
		return points;
	}

	const deadRuleCache = new WeakMap();

	/**
	 * The dead-key rules of a layout as a flat list, read once per dead table:
	 * what each rule needs (its state, then a typed character or another dead
	 * key) and what it gives (a character, a text of several, or a next state).
	 * @param {object} dead - layout.dead.
	 * @returns {Array<object>} {state, typedDead, typedChar, outChar, outText, outDead}.
	 */
	function deadRules(dead) {
		if (deadRuleCache.has(dead)) return deadRuleCache.get(dead);
		const rules = [];
		for (const [state, table] of Object.entries(dead)) {
			for (const [typed, result] of Object.entries(table)) {
				const rule = {
					state,
					typedDead: typed.startsWith(DEAD_TYPED) ? typed.slice(DEAD_TYPED.length) : null,
					typedChar: typed.startsWith(DEAD_TYPED) ? null : typed,
					outChar: null,
					outText: null,
					outDead: null
				};
				if (typeof result === 'string') {
					const length = codeLength(result);
					if (length === 0) continue;
					if (length === 1) rule.outChar = result;
					else rule.outText = result;
				} else rule.outDead = result.dead;
				rules.push(rule);
			}
		}
		deadRuleCache.set(dead, rules);
		return rules;
	}

	// Equal costs are settled the same way whatever order the file lists its
	// keys in: fewer AltGr presses (the lower level, as Kalamine prefers), then
	// fewer keys, then the lower key indexes, then fewer Shift presses.
	function betterWay(a, b) {
		if (a.cost !== b.cost) return a.cost < b.cost;
		if (a.altgr !== b.altgr) return a.altgr < b.altgr;
		if (a.keys.length !== b.keys.length) return a.keys.length < b.keys.length;
		for (let i = 0; i < a.keys.length; i++)
			if (a.keys[i] !== b.keys[i]) return a.keys[i] < b.keys[i];
		if (a.shift !== b.shift) return a.shift < b.shift;
		return false;
	}

	function sameWayKeys(a, b) {
		if (a.keys.length !== b.keys.length) return false;
		for (let i = 0; i < a.keys.length; i++) if (a.keys[i] !== b.keys[i]) return false;
		return true;
	}

	/** Adds a way to a character's list (best first, at most MAX_WAYS); true when the list changed. */
	function offerWay(map, key, candidate) {
		const list = map.get(key);
		if (!list) {
			map.set(key, [candidate]);
			return true;
		}
		for (let i = 0; i < list.length; i++) {
			if (!sameWayKeys(list[i], candidate)) continue;
			if (!betterWay(candidate, list[i])) return false;
			list.splice(i, 1);
			break;
		}
		let at = list.length;
		while (at > 0 && betterWay(candidate, list[at - 1])) at--;
		if (at >= MAX_WAYS) return false;
		list.splice(at, 0, candidate);
		if (list.length > MAX_WAYS) list.pop();
		return true;
	}

	/** Way a then way b; state: the dead state a enters, or null for two characters in a row. */
	function joinWays(a, b, state) {
		return {
			keys: a.keys.concat(b.keys),
			layers: a.layers.concat(b.layers),
			shift: a.shift + b.shift,
			altgr: a.altgr + b.altgr,
			dead: state !== null || a.dead || b.dead,
			cost: a.cost + b.cost,
			level: state === null ? b.level : `${state}/${b.level}`,
			state: state === null ? b.state : state
		};
	}

	/**
	 * Offers the way each cell of a layout gives: one key on one level. With
	 * `only`, the cells of those characters, dead states and texts alone.
	 * @param {object} core - {ways, deadWays, texts}, filled in place.
	 * @param {{chars: Set<string>, dead: Set<string>, texts: Set<string>}|null} only
	 */
	function offerCells(core, layout, board, missing, only) {
		for (const [code, row] of Object.entries(layout.rows)) {
			const k = board.index.get(code);
			if (k === undefined || (missing && missing.has(code))) continue;
			for (let layer = 0; layer < LAYER_IDS.length; layer++) {
				const cell = row[layer];
				if (cell === null) continue;
				let map;
				let key = cell;
				let width = 1;
				if (typeof cell !== 'string') [map, key] = [core.deadWays, cell.dead];
				else if (codeLength(cell) === 1) map = core.ways;
				else if (cell.length > 0) [map, width] = [core.texts, codeLength(cell)];
				else continue;
				if (
					only &&
					!(map === core.ways ? only.chars : map === core.texts ? only.texts : only.dead).has(key)
				)
					continue;
				const stroke = {
					keys: [k],
					layers: [layer],
					shift: LAYER_SHIFT[layer],
					altgr: LAYER_ALTGR[layer],
					dead: false,
					cost: 1 + MODIFIER_COST * (LAYER_SHIFT[layer] + LAYER_ALTGR[layer]),
					level: LAYER_IDS[layer]
				};
				if (map === core.texts) stroke.width = width;
				offerWay(map, key, stroke);
			}
		}
	}

	// When a joined way was first offered by a whole compile (followRules):
	// way → {d: pass, r: rule index, p: prefix, t: tail}. A cell's own way has
	// none (it is there before the first pass). Kept for scoreSession only.
	const wayTimes = new WeakMap();
	// Passes a partial compile may take before it gives up and compiles whole.
	const PARTIAL_PASS_LIMIT = 4 * MAX_DEAD_DEPTH;

	/**
	 * Which of two offers of a way on the same keys a whole compile makes
	 * first: the earlier pass, then the earlier rule, then (one rule's loop)
	 * the better prefix, then the better tail.
	 * @returns {number} Negative when a comes first, 0 when they tie.
	 */
	function compareTimes(a, b) {
		if (a.d !== b.d) return a.d - b.d;
		if (a.r !== b.r) return a.r - b.r;
		if (!sameWayKeys(a.p, b.p)) return betterWay(a.p, b.p) ? -1 : 1;
		if (!sameWayKeys(a.t, b.t)) return betterWay(a.t, b.t) ? -1 : 1;
		return 0;
	}

	/** Whether two ways on the same keys read alike (labels, levels, flags). */
	function sameLabels(a, b) {
		if (a.level !== b.level || a.state !== b.state) return false;
		if (a.terminated !== b.terminated || a.width !== b.width) return false;
		for (let i = 0; i < a.layers.length; i++) if (a.layers[i] !== b.layers[i]) return false;
		return true;
	}

	/**
	 * offerWay for a partial compile, which makes its offers in another order
	 * than a whole compile: of two offers on the same keys and of equal cost,
	 * the one a whole compile makes first (compareTimes) stays, so the lists
	 * read as a whole compile's.
	 */
	function offerTimed(map, key, candidate, time) {
		const list = map.get(key);
		if (!list) {
			map.set(key, [candidate]);
			wayTimes.set(candidate, time);
			return true;
		}
		for (let i = 0; i < list.length; i++) {
			const held = list[i];
			if (!sameWayKeys(held, candidate)) continue;
			if (!betterWay(candidate, held)) {
				if (betterWay(held, candidate)) return false;
				const order = compareTimes(time, wayTimes.get(held));
				// An equal time is the same offer from inputs replaced since: the newer reads right.
				if (order > 0 || (order === 0 && sameLabels(held, candidate))) return false;
				list[i] = candidate;
				wayTimes.set(candidate, time);
				return true;
			}
			list.splice(i, 1);
			break;
		}
		let at = list.length;
		while (at > 0 && betterWay(candidate, list[at - 1])) at--;
		if (at >= MAX_WAYS) return false;
		list.splice(at, 0, candidate);
		if (list.length > MAX_WAYS) list.pop();
		wayTimes.set(candidate, time);
		return true;
	}

	/** The first pass of a whole compile in which rule r can read a way. */
	function readablePass(way, r) {
		const time = wayTimes.get(way);
		if (time === undefined) return 0;
		return time.r < r ? time.d : time.d + 1;
	}

	/**
	 * Follows the dead-key rules (those of `order`, in that order, or all) up
	 * to MAX_DEAD_DEPTH passes: each joins the ways of its dead key with those
	 * of the key typed after it, and offers them to its output.
	 * @param {object} core - {ways, deadWays, texts}, filled in place.
	 * @param {Array<object>} rules - From deadRules().
	 * @param {number[]|null} order - Rule indexes, ascending; null for all.
	 * @param {object} board - From keyboard().
	 * @param {string} [timing] - 'record': note when each way is offered
	 *   (wayTimes); 'partial': the rules of a partial compile, which reads the
	 *   other lists as they end and gives each offer the time a whole compile
	 *   would (an offer a whole compile makes after its last pass is left out).
	 * @returns {boolean} Whether the rules were followed to their end (a pass
	 *   changed nothing); a partial compile that is not must compile whole.
	 */
	function followRules(core, rules, order, board, timing) {
		const partial = timing === 'partial';
		const record = timing === 'record';
		const { ways, deadWays, texts } = core;
		// A list's version rises with each change. A rule whose prefixes and
		// tails are the lists, at the versions, of its last pass would only
		// offer again what it offered then: lists only get better, so every
		// such offer is refused, and the rule is skipped (the same ways, in a
		// fraction of the joins).
		const versions = new WeakMap();
		const version = (list) => versions.get(list) || 0;
		const lastPass = new Array(rules.length);
		const count = order === null ? rules.length : order.length;
		const passes = partial ? PARTIAL_PASS_LIMIT : MAX_DEAD_DEPTH;
		for (let depth = 0; depth < passes; depth++) {
			let changed = false;
			for (let i = 0; i < count; i++) {
				const r = order === null ? i : order[i];
				const rule = rules[r];
				const prefixes = deadWays.get(rule.state);
				if (!prefixes) continue;
				const tails =
					rule.typedDead !== null ? deadWays.get(rule.typedDead) : ways.get(rule.typedChar);
				if (!tails) continue;
				const seen = lastPass[r];
				if (
					seen &&
					seen[0] === prefixes &&
					seen[1] === version(prefixes) &&
					seen[2] === tails &&
					seen[3] === version(tails)
				)
					continue;
				lastPass[r] = [prefixes, version(prefixes), tails, version(tails)];
				let map = ways;
				let target = rule.outChar;
				if (rule.outDead !== null) [map, target] = [deadWays, rule.outDead];
				else if (rule.outText !== null) [map, target] = [texts, rule.outText];
				for (const prefix of prefixes.slice())
					for (const tail of tails.slice()) {
						if (partial) {
							// A partial compile settles a tie of keys on the labels too (offerTimed).
							const d = Math.max(readablePass(prefix, r), readablePass(tail, r));
							if (d >= MAX_DEAD_DEPTH) continue;
							const candidate = joinWays(prefix, tail, rule.state);
							const closing = board.finger[candidate.keys[candidate.keys.length - 1]];
							if (closing === LEFT_THUMB || closing === RIGHT_THUMB) candidate.terminated = true;
							if (map === texts) candidate.width = codeLength(target);
							if (!offerTimed(map, target, candidate, { d, r, p: prefix, t: tail })) continue;
							changed = true;
							const list = map.get(target);
							versions.set(list, version(list) + 1);
							continue;
						}
						// join(prefix, tail, rule.state), with only what offer compares
						// until it keeps the candidate: most chains are refused.
						const candidate = {
							keys: prefix.keys.concat(tail.keys),
							layers: null,
							shift: prefix.shift + tail.shift,
							altgr: prefix.altgr + tail.altgr,
							dead: true,
							cost: prefix.cost + tail.cost,
							level: null,
							state: rule.state
						};
						if (!offerWay(map, target, candidate)) continue;
						changed = true;
						const list = map.get(target);
						versions.set(list, version(list) + 1);
						if (record) wayTimes.set(candidate, { d: depth, r, p: prefix, t: tail });
						candidate.layers = prefix.layers.concat(tail.layers);
						candidate.level = `${rule.state}/${tail.level}`;
						// A dead key closed by a thumb key (the space bar, on any level)
						// types its own sign: the fallback, never an alternative to
						// another way (planTyping).
						const closing = board.finger[candidate.keys[candidate.keys.length - 1]];
						if (closing === LEFT_THUMB || closing === RIGHT_THUMB) candidate.terminated = true;
						if (map === texts) candidate.width = codeLength(target);
					}
			}
			if (!changed) return true;
		}
		return false;
	}

	/**
	 * The ways of a layout before the substitutes: its cells, then its
	 * dead-key rules followed.
	 * @returns {{layout: object, ways: Map, deadWays: Map, texts: Map}} Lists
	 *   best first; deadWays maps a dead state to the ways of entering it.
	 */
	function compileCore(layout, board, missing, timing) {
		const core = { layout, ways: new Map(), deadWays: new Map(), texts: new Map() };
		offerCells(core, layout, board, missing, null);
		followRules(core, deadRules(layout.dead), null, board, timing);
		return core;
	}

	/**
	 * The distinct characters, the substitutes and the cheapest way of each
	 * character, from the ways before the substitutes.
	 * @param {Map} ways - Character → ways; the substitutes are added to it.
	 * @param {Map} texts - Multi-character output → ways.
	 * @returns {{ways, texts, best, distinct}} As compileWays.
	 */
	function finishWays(ways, texts) {
		let distinct = ways.size;
		const extra = new Set();
		for (const text of texts.keys())
			for (const char of textPoints(text)) if (!ways.has(char)) extra.add(char);
		distinct += extra.size;
		// A typographic character the layout lacks is typed as its plain form; a
		// copy, so the plain character's own way stays unmarked.
		for (const [fancy, plain] of Object.entries(data().model.substitutions)) {
			if (ways.has(fancy)) continue;
			const parts = textPoints(plain).map((c) => ways.get(c));
			if (parts.some((part) => !part)) continue;
			const way = parts.map((list) => list[0]).reduce((a, b) => joinWays(a, b, null));
			ways.set(fancy, [Object.assign({}, way, { substituted: true })]);
		}
		const best = new Map();
		for (const [char, list] of ways) best.set(char, list[0]);
		return { ways, texts, best, distinct };
	}

	/**
	 * Every way a layout types each character, best first: a key on a level, a
	 * dead key (itself on a level, possibly chained) followed by the key it
	 * composes with, and the multi-character outputs (a cell or a dead-key rule
	 * that types several characters at once). A way is {keys, layers (the level
	 * of each key), shift, altgr, dead, cost, level (where the last key is
	 * pressed: a level, or « state/level » behind a dead key), state? (the
	 * dead state of the last key), substituted?, width? (characters typed)}.
	 * Two ways on the same keys keep the cheaper one (it is never worse in any
	 * context); at most MAX_WAYS are kept per character.
	 * @param {object} layout - Library shape.
	 * @param {object} board - From keyboard().
	 * @param {Set<string>|null} missing - Codes absent from a compact board.
	 * @returns {{ways: Map<string, object[]>, texts: Map<string, object[]>,
	 *   best: Map<string, object>, distinct: number}} Character → ways,
	 *   multi-character output → ways, character → its cheapest way, and the
	 *   number of distinct characters typed (substitutes excluded, the
	 *   characters of multi-character outputs included).
	 */
	function compileWays(layout, board, missing) {
		const core = compileCore(layout, board, missing);
		return finishWays(core.ways, core.texts);
	}

	const ruleGraphCache = new WeakMap();

	/**
	 * The dead-key rules as a graph of symbols (« c » a character, « d » a dead
	 * state, « t » a text): what each rule gives, and the rules that read each.
	 * @param {Array<object>} rules - From deadRules().
	 * @returns {{outputs: string[], users: Map<string, number[]>}} Rule index →
	 *   its output's symbol; symbol → the indexes of the rules it is an input of.
	 */
	function ruleGraph(rules) {
		if (ruleGraphCache.has(rules)) return ruleGraphCache.get(rules);
		const users = new Map();
		const use = (symbol, r) => (users.get(symbol) || users.set(symbol, []).get(symbol)).push(r);
		const outputs = rules.map((rule, r) => {
			use(`d${rule.state}`, r);
			use(rule.typedDead !== null ? `d${rule.typedDead}` : `c${rule.typedChar}`, r);
			if (rule.outDead !== null) return `d${rule.outDead}`;
			return rule.outText !== null ? `t${rule.outText}` : `c${rule.outChar}`;
		});
		const graph = { outputs, users };
		ruleGraphCache.set(rules, graph);
		return graph;
	}

	/** Whether two cells (or dead-key rule results) are alike: null and undefined are no cell. */
	function sameCell(a, b) {
		if (a === b) return true;
		if (a === undefined || b === undefined)
			return (a === undefined ? null : a) === (b === undefined ? null : b);
		return (
			a !== null &&
			b !== null &&
			typeof a === 'object' &&
			typeof b === 'object' &&
			a.dead === b.dead
		);
	}

	/**
	 * compileCore of a layout a few cells or dead-key rules away from one
	 * already compiled (scoreSession's swaps), equal to compiling it from
	 * nothing: only the characters, dead states and texts whose ways can
	 * change are compiled again — those of the changed cells and rules, then
	 * every output of a rule that reads one of them, and so on — and the other
	 * lists are shared with `previous`. A list is the best MAX_WAYS of its
	 * candidates and each candidate is built from strictly cheaper ways, so a
	 * list whose inputs are the same is the same; a chain left unfollowed
	 * after MAX_DEAD_DEPTH passes compiles the layout whole.
	 * @param {object} previous - From compileCore() or compileCoreFrom(), on the same board.
	 * @param {object} layout - Library shape.
	 * @param {object} board - From keyboard().
	 * @returns {object} As compileCore, plus whole: true when compiled from nothing.
	 */
	function compileCoreFrom(previous, layout, board) {
		const before = previous.layout;
		const touched = new Set();
		const touch = (cell) => {
			if (cell === null || cell === undefined) return;
			if (typeof cell !== 'string') touched.add(`d${cell.dead}`);
			else if (codeLength(cell) === 1) touched.add(`c${cell}`);
			else if (cell.length > 0) touched.add(`t${cell}`);
		};
		const compareRows = (a, b) => {
			if (a === b) return;
			for (let layer = 0; layer < LAYER_IDS.length; layer++) {
				const ca = a ? a[layer] : null;
				const cb = b ? b[layer] : null;
				if (sameCell(ca, cb)) continue;
				touch(ca);
				touch(cb);
			}
		};
		for (const code of Object.keys(layout.rows))
			if (board.index.has(code)) compareRows(before.rows[code], layout.rows[code]);
		for (const code of Object.keys(before.rows))
			if (board.index.has(code) && !(code in layout.rows))
				compareRows(before.rows[code], undefined);
		const rules = deadRules(layout.dead);
		const { outputs, users } = ruleGraph(rules);
		if (before.dead !== layout.dead) {
			const changedStates = new Set();
			const compareStates = (ra, rb, state) => {
				if (ra === rb) return;
				const a = ra || {};
				const b = rb || {};
				for (const t of Object.keys(a)) if (!sameCell(a[t], b[t])) return changedStates.add(state);
				for (const t of Object.keys(b))
					if (!(t in a) && !sameCell(a[t], b[t])) return changedStates.add(state);
			};
			for (const state of Object.keys(layout.dead))
				compareStates(before.dead[state], layout.dead[state], state);
			for (const state of Object.keys(before.dead))
				if (!(state in layout.dead)) compareStates(before.dead[state], undefined, state);
			// Every output of a changed state's rules, before and after, is compiled again.
			if (changedStates.size) {
				const previousRules = deadRules(before.dead);
				const previousOutputs = ruleGraph(previousRules).outputs;
				previousRules.forEach((rule, r) => {
					if (changedStates.has(rule.state)) touched.add(previousOutputs[r]);
				});
				rules.forEach((rule, r) => {
					if (changedStates.has(rule.state)) touched.add(outputs[r]);
				});
			}
		}
		if (touched.size === 0) return previous;
		// What reads a touched symbol is touched in turn.
		const queue = [...touched];
		while (queue.length) {
			for (const r of users.get(queue.pop()) || []) {
				const out = outputs[r];
				if (touched.has(out)) continue;
				touched.add(out);
				queue.push(out);
			}
		}
		const only = { chars: new Set(), dead: new Set(), texts: new Set() };
		for (const symbol of touched) {
			const name = symbol.slice(1);
			if (symbol[0] === 'c') only.chars.add(name);
			else if (symbol[0] === 'd') only.dead.add(name);
			else only.texts.add(name);
		}
		const core = {
			layout,
			ways: new Map(previous.ways),
			deadWays: new Map(previous.deadWays),
			texts: new Map(previous.texts)
		};
		for (const char of only.chars) core.ways.delete(char);
		for (const state of only.dead) core.deadWays.delete(state);
		for (const text of only.texts) core.texts.delete(text);
		offerCells(core, layout, board, null, only);
		const order = [];
		for (let r = 0; r < rules.length; r++) if (touched.has(outputs[r])) order.push(r);
		if (!followRules(core, rules, order, board, 'partial'))
			return Object.assign(compileCore(layout, board, null, 'record'), { whole: true });
		return core;
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
		return compileWays(layout, board, missing).best;
	}

	/**
	 * The characters a layout still types when some keys are missing (a
	 * compact form factor): the same reach as compileWays, without the costs.
	 * @param {object} layout - Library shape.
	 * @param {object} board - From keyboard().
	 * @param {Set<string>} missing - Codes absent from the form factor.
	 * @returns {Set<string>} The characters typed, substitutes included.
	 */
	function reachableChars(layout, board, missing) {
		const chars = new Set();
		const states = new Set();
		for (const [code, row] of Object.entries(layout.rows)) {
			if (!board.index.has(code) || missing.has(code)) continue;
			for (const cell of row) {
				if (cell === null) continue;
				if (typeof cell !== 'string') states.add(cell.dead);
				else if (codeLength(cell) === 1) chars.add(cell);
			}
		}
		const rules = deadRules(layout.dead);
		for (let depth = 0; depth < MAX_DEAD_DEPTH; depth++) {
			let changed = false;
			for (const rule of rules) {
				if (!states.has(rule.state)) continue;
				const typed =
					rule.typedDead !== null ? states.has(rule.typedDead) : chars.has(rule.typedChar);
				if (!typed) continue;
				if (rule.outChar !== null && !chars.has(rule.outChar)) {
					chars.add(rule.outChar);
					changed = true;
				} else if (rule.outDead !== null && !states.has(rule.outDead)) {
					states.add(rule.outDead);
					changed = true;
				}
			}
			if (!changed) break;
		}
		for (const [fancy, plain] of Object.entries(data().model.substitutions))
			if (!chars.has(fancy) && textPoints(plain).every((c) => chars.has(c))) chars.add(fancy);
		return chars;
	}

	// ========================
	// ======= 5/ N-grams =====
	// ========================

	/**
	 * Counts the characters, bigrams and trigrams of a text. Line breaks and
	 * tabs cut the text: no n-gram of the main tables spans them and they are
	 * not counted there. The analysers that type them (KLA's and KLAnext's
	 * Enter and Tab) read them from `breaks`: the n-grams of the whole text that
	 * hold a line break or a tab (CR LF and a lone CR read as one line break), so
	 * that the main tables and `breaks` together count every n-gram of the text.
	 * @param {string} text - The corpus.
	 * @returns {{chars: object, bigrams: object, trigrams: object, breaks: {chars:
	 *   object, bigrams: object, trigrams: object}}} Counts.
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
		return { chars, bigrams, trigrams, breaks: breakNgrams(text) };
	}

	/** A line break or a tab: what cuts ngramsFromText's main tables. */
	const isBreak = (char) => char === '\n' || char === '\t';

	/**
	 * The n-grams of a text that hold a line break or a tab, line breaks read as
	 * one \n (CR LF, CR, LF).
	 * @param {string} text - The corpus.
	 * @returns {{chars: object, bigrams: object, trigrams: object}} Counts.
	 */
	function breakNgrams(text) {
		const chars = {};
		const bigrams = {};
		const trigrams = {};
		const c = codePoints(text.replace(/\r\n?/g, '\n'));
		const add = (table, key) => {
			table[key] = (table[key] || 0) + 1;
		};
		for (let i = 0; i < c.length; i++) {
			if (!isBreak(c[i])) continue;
			add(chars, c[i]);
			// Each n-gram once: where its first break is.
			const earlier = (from) => {
				for (let j = from; j < i; j++) if (isBreak(c[j])) return true;
				return false;
			};
			for (let start = Math.max(0, i - 1); start <= i && start + 1 < c.length; start++)
				if (!earlier(start)) add(bigrams, c[start] + c[start + 1]);
			for (let start = Math.max(0, i - 2); start <= i && start + 2 < c.length; start++)
				if (!earlier(start)) add(trigrams, c[start] + c[start + 1] + c[start + 2]);
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
			tri: split(ngrams.trigrams, 3),
			breaks: null
		};
		prepared.totalChars = prepared.uni.reduce((sum, entry) => sum + entry[1], 0);
		// The n-grams with a line break or a tab (ngramsFromText), when the
		// table has them; only the analysers that type Enter and Tab read them.
		if (ngrams.breaks !== undefined) {
			const b = ngrams.breaks;
			if (!b || typeof b.chars !== 'object' || typeof b.bigrams !== 'object')
				throw new Error('layout_analysis: breaks need chars and bigrams');
			prepared.breaks = {
				uni: split(b.chars, 1),
				bi: split(b.bigrams, 2),
				tri: split(b.trigrams, 3)
			};
			for (const [char] of prepared.breaks.uni)
				if (char !== '\n' && char !== '\t')
					throw new Error(`layout_analysis: breaks count ${JSON.stringify(char)}`);
		}
		preparedCache.set(ngrams, prepared);
		return prepared;
	}

	const tableIdsCache = new WeakMap();

	/**
	 * A prepared table's tokens as ids and its n-grams as typed arrays, in the
	 * table's order: a walk indexes arrays instead of looking each token up
	 * by string. Cached per table.
	 * @param {object} table - From prepareNgrams() or tokenTable().
	 * @returns {{tokens: string[], uniId: Int32Array, uniN: Float64Array,
	 *   biA: Int32Array, biB: Int32Array, biN: Float64Array, triA: Int32Array,
	 *   triB: Int32Array, triC: Int32Array, triN: Float64Array, allBi: Int32Array,
	 *   allTri: Int32Array, whole: boolean}} Ids; allBi, allTri: every entry's
	 *   index; whole: every count an integer, small enough for exact sums.
	 */
	function tableIds(table) {
		let out = tableIdsCache.get(table);
		if (out) return out;
		const tokens = [];
		const idOf = new Map();
		const id = (token) => {
			let i = idOf.get(token);
			if (i === undefined) {
				i = tokens.length;
				idOf.set(token, i);
				tokens.push(token);
			}
			return i;
		};
		const ids = (entries, j) => {
			const column = new Int32Array(entries.length);
			for (let i = 0; i < entries.length; i++) column[i] = id(entries[i][j]);
			return column;
		};
		let whole = true;
		let total = 0;
		const counts = (entries, j) => {
			const column = new Float64Array(entries.length);
			for (let i = 0; i < entries.length; i++) {
				const n = entries[i][j];
				column[i] = n;
				total += n;
				if (whole && !Number.isInteger(n)) whole = false;
			}
			return column;
		};
		out = {
			tokens,
			uniId: ids(table.uni, 0),
			uniN: counts(table.uni, 1),
			biA: ids(table.bi, 0),
			biB: ids(table.bi, 1),
			biN: counts(table.bi, 2),
			triA: ids(table.tri, 0),
			triB: ids(table.tri, 1),
			triC: ids(table.tri, 2),
			triN: counts(table.tri, 3)
		};
		// Whole counts whose sums stay exact integers whatever their order (a
		// character's own keys can count it a few times over).
		out.whole = whole && total * WHOLE_SUM_MARGIN <= Number.MAX_SAFE_INTEGER;
		const indexes = (length) => {
			const all = new Int32Array(length);
			for (let i = 0; i < length; i++) all[i] = i;
			return all;
		};
		out.allBi = indexes(out.biN.length);
		out.allTri = indexes(out.triN.length);
		tableIdsCache.set(table, out);
		return out;
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
	 *   every event (keys[code].worst; the SFB ones always are). typing:
	 *   'best' (the default) types each character the way that costs least in
	 *   its context and uses the multi-character outputs that save keystrokes
	 *   (planTyping); 'fixed' types each its cheapest way out of context.
	 * @returns {object} {layout, keyboard, metrics, fingers, fingerShares,
	 *   idealLoad, hands, rows, coverage, trigramClasses, keys, typing,
	 *   simplicity, score}.
	 */
	function analyse(layoutInput, ngrams, options) {
		const opts = options || {};
		const layout = layoutFromRows(layoutInput);
		const board = boardFor(layout, opts.keyboard || DEFAULT_KEYBOARD, opts.profile);
		const table = prepareNgrams(ngrams);
		const compiled = compileWays(layout, board, null);
		const plan = planTyping(compiled, board, table, typingMode(opts) === 'fixed');
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
		// The good events each key takes part in (rolls, alternation), never grouped.
		for (const gain of KEY_GAINS) perKey[gain] = new Float64Array(board.codes.length);
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

		walkTyped(board, plan, streamVisitor(board, c, keyCount, unsupportedChars, blame));
		const m = streamMetrics(
			layout,
			board,
			compiled,
			c,
			keyCount,
			opts,
			compactFit(layout, board, table, opts.format, opts.formWeights)
		);
		const metrics = m.metrics;
		const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
		const report = typingReport(board, plan);
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
			fingerDistance: m.fingerDistance,
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
				trigrams: c.trigrams,
				// The model's required characters (the space, a–z, A–Z) the layout
				// cannot type on this keyboard: any of them makes it incomplete.
				missingRequired: missingRequired(compiled.best)
			},
			typing: {
				mode: typingMode(opts),
				// The points the keystroke metrics take from the score along this
				// path, by the default weights and the corpus's own totals: what
				// the choice of ways minimises (typingCosts).
				cost: typingCost(table, c, {
					pinky: m.fingerLoad[0] + m.fingerLoad[9],
					outer: m.outer,
					home: m.home
				}),
				alternatives: plan.multi.size,
				changed: pct(report.changed, c.chars),
				paths: report.paths,
				chords: report.chords
			},
			simplicity: m.simplicity
		};
		// One layout analysed in detail: each event's heaviest groups over the board.
		if (opts.keyGroups === true) result.topGroups = topGroups(board, groups, c);
		result.incomplete = result.coverage.missingRequired.length > 0;
		result.score = score(result, opts.weights);
		return result;
	}

	/**
	 * The required characters (model required_characters: the space and the 26
	 * letters in each case, each checked on its own) a layout cannot type by
	 * any way of its own; a typographic substitute does not count.
	 * @param {Map<string, object>} best - compileWays().best.
	 * @returns {string[]} The missing ones, in the model's order.
	 */
	function missingRequired(best) {
		return codePoints(data().model.required_characters).filter(
			(char) => !best.has(char) || best.get(char).substituted === true
		);
	}

	/**
	 * The typing mode of analyse() options: 'best' unless 'fixed' is asked.
	 * @throws {Error} On another mode.
	 */
	function typingMode(opts) {
		if (opts.typing === undefined) return 'best';
		if (opts.typing !== 'best' && opts.typing !== 'fixed')
			throw new Error(`layout_analysis: unknown typing ${opts.typing}`);
		return opts.typing;
	}

	// What a key trigram is (tripleKind): one class, plus a flag when its first
	// and last keys are another same-finger skipgram; 0 is « not yet known ».
	const TRIPLE_CLASS = 7;
	const TRIPLE_SAME_FINGER = 1;
	const TRIPLE_ROLL_IN = 2;
	const TRIPLE_ROLL_OUT = 3;
	const TRIPLE_REDIRECT = 4;
	const TRIPLE_REDIRECT_BAD = 5;
	const TRIPLE_ALTERNATION = 6;
	const TRIPLE_ROLL_MIXED = 7;
	const TRIPLE_SFS = 8;
	const TRIPLE_THUMB = 16;
	const tripleKindCache = new WeakMap();

	/**
	 * The classification of streamVisitor's trigram rule for one key trigram:
	 * a thumb key leaves it out (TRIPLE_THUMB); otherwise TRIPLE_SFS when the
	 * first and last keys are different keys of one finger, and its class: a
	 * finger repeated in a row, then on one hand a roll in or out or a
	 * redirect (bad without the index), else alternation or a mixed roll.
	 */
	function tripleKind(board, k1, k2, k3) {
		const thumb = thumbKeys(board);
		if (thumb[k1] || thumb[k2] || thumb[k3]) return TRIPLE_THUMB;
		const f1 = board.finger[k1];
		const f2 = board.finger[k2];
		const f3 = board.finger[k3];
		const sfs = f1 === f3 && k1 !== k3 ? TRIPLE_SFS : 0;
		if (f1 === f2 || f2 === f3) return sfs | TRIPLE_SAME_FINGER;
		const h1 = board.hand[k1];
		const h2 = board.hand[k2];
		const h3 = board.hand[k3];
		if (h1 === h2 && h2 === h3) {
			const d = (board.order[k2] - board.order[k1]) * (board.order[k3] - board.order[k2]);
			if (d > 0)
				return sfs | (board.order[k2] > board.order[k1] ? TRIPLE_ROLL_IN : TRIPLE_ROLL_OUT);
			const index =
				board.order[k1] === INDEX_ORDER ||
				board.order[k2] === INDEX_ORDER ||
				board.order[k3] === INDEX_ORDER;
			return sfs | (index ? TRIPLE_REDIRECT : TRIPLE_REDIRECT_BAD);
		}
		return sfs | (h1 !== h2 && h2 !== h3 ? TRIPLE_ALTERNATION : TRIPLE_ROLL_MIXED);
	}

	/** A board's tripleKind memo, (k1 * K + k2) * K + k3, filled as read. */
	function tripleKinds(board) {
		let out = tripleKindCache.get(board);
		if (!out) {
			const K = board.codes.length;
			out = new Uint8Array(K * K * K);
			tripleKindCache.set(board, out);
		}
		return out;
	}

	const thumbCache = new WeakMap();

	/** Whether each key of a board is a thumb's (1) or not (0). */
	function thumbKeys(board) {
		let out = thumbCache.get(board);
		if (!out) {
			out = Uint8Array.from(board.finger, (f) => (f === LEFT_THUMB || f === RIGHT_THUMB ? 1 : 0));
			thumbCache.set(board, out);
		}
		return out;
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
			row_jump: 0,
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
		const thumb = thumbKeys(board);
		const K = board.codes.length;
		const kinds = tripleKinds(board);
		const blame2 = blame ? blame.pair : () => {};
		const blame3 = blame ? blame.triple : () => {};
		return {
			char(char, seq, n) {
				// A multi-character output counts each character it types.
				const typed = n * (seq.width || 1);
				c.chars += typed;
				if (seq.dead) c.dead += typed;
				if (seq.shift + seq.altgr > 0) c.modifiers += typed;
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
				// A row jump, whatever the fingers (an SFB or a scissor may be one
				// too): shown, not scored.
				if (
					board.hand[k1] === board.hand[k2] &&
					Math.abs(board.row[k1] - board.row[k2]) >= ROW_JUMP_ROWS
				) {
					c.row_jump += n;
					blame2('row_jump', n, k1, k2);
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
				const roll = o2 > o1 ? 'roll_in' : 'roll_out';
				c[roll] += n;
				blame2(roll, n, k1, k2);
			},
			trigram(k1, k2, k3, n) {
				const at = (k1 * K + k2) * K + k3;
				let kind = kinds[at];
				if (kind === 0) kind = kinds[at] = tripleKind(board, k1, k2, k3);
				if (kind === TRIPLE_THUMB) return;
				c.trigrams += n;
				if (kind & TRIPLE_SFS) {
					c.sfs += n;
					blame2('sfs', n, k1, k3);
				}
				switch (kind & TRIPLE_CLASS) {
					case TRIPLE_SAME_FINGER:
						c.same_finger_trigram += n;
						break;
					case TRIPLE_ROLL_IN:
						c.roll3_in += n;
						break;
					case TRIPLE_ROLL_OUT:
						c.roll3_out += n;
						break;
					case TRIPLE_REDIRECT:
					case TRIPLE_REDIRECT_BAD:
						c.redirect += n;
						blame3('redirect', n, k1, k2, k3);
						if ((kind & TRIPLE_CLASS) === TRIPLE_REDIRECT_BAD) {
							c.redirect_bad += n;
							blame3('redirect_bad', n, k1, k2, k3);
						}
						break;
					case TRIPLE_ALTERNATION:
						c.alternation += n;
						blame3('alternation', n, k1, k2, k3);
						break;
					default:
						c.roll_mixed += n;
				}
			}
		};
	}

	/**
	 * Every metric of a layout from its stream counters, and the loads the
	 * report shows: the one definition analyse() and scoreSession() share.
	 * @param {object} layout - Library shape, checked.
	 * @param {object} board - From keyboard().
	 * @param {object} compiled - From compileWays().
	 * @param {object} c - The stream counters (streamCounts).
	 * @param {Float64Array} keyCount - Presses per key.
	 * @param {object} opts - The analyse() options.
	 * @param {number} compact - compact_fit, measured by the caller.
	 * @returns {object} {metrics, fingers, fingerLoad, fingerDistance (each finger's
	 *   part of the travel, mm per character), ideal, pressed, allPresses, left,
	 *   right, outer, home (presses on the outer column, on the home row),
	 *   simplicity (the rules)}.
	 */
	function streamMetrics(layout, board, compiled, c, keyCount, opts, compact) {
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
		// Each finger's part of the travel distance (mm per typed character):
		// the parts add up to the distance metric.
		const travel = new Float64Array(fingerIds.length);
		for (let k = 0; k < keyCount.length; k++)
			travel[board.finger[k]] += board.reach[k] * keyCount[k];
		const fingerDistance = {};
		fingerIds.forEach((id, f) => {
			fingerDistance[id] = c.chars > 0 ? travel[f] / c.chars : 0;
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
			row_jump: pct(c.row_jump, c.bigrams),
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
			char_coverage: charCoverage(compiled.best),
			direct_digits: directDigits(layout, board),
			shortcut_left: shortcutLeft(layout, board, shortcuts(opts.shortcuts)),
			distinct_chars: compiled.distinct,
			coverage_bonus: coverageBonus(compiled.distinct)
		};
		const rules = simplicity(board, compiled);
		metrics.simplicity = rules.value;
		return {
			metrics,
			fingers,
			fingerLoad,
			fingerDistance,
			ideal,
			pressed,
			allPresses,
			left,
			right,
			outer,
			home: rowLoad[0] || 0,
			simplicity: rules.rules
		};
	}

	/**
	 * Each bad event's TOP_GROUPS heaviest key groups over the whole board,
	 * heaviest first: the keys (board order), how often the corpus has them,
	 * and their share of the bigrams (or trigrams) the event is counted on.
	 * @param {object} board - From keyboard().
	 * @param {object} groups - event → Map group id → count (analyse()).
	 * @param {object} c - analyse()'s counts (bigrams, trigrams).
	 * @returns {object} event → [{keys: string[], count: number, share: number}].
	 */
	function topGroups(board, groups, c) {
		const out = {};
		for (const event of KEY_EVENTS) {
			const whole = TRIGRAM_EVENTS.has(event) ? c.trigrams : c.bigrams;
			out[event] = Array.from(groups[event])
				.sort((x, y) => y[1] - x[1] || x[0] - y[0])
				.slice(0, TOP_GROUPS)
				.map(([id, n]) => {
					const keys = [];
					for (let i = 0, rest = id; i < EVENT_KEYS[event]; i++, rest = Math.floor(rest / KEY_BASE))
						keys.unshift(board.codes[rest % KEY_BASE]);
					return { keys, count: n, share: whole > 0 ? (100 * n) / whole : 0 };
				});
		}
		return out;
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
		const t = tableIds(table);
		const seqs = t.tokens.map((token) => best.get(token));
		for (let i = 0; i < t.uniId.length; i++)
			walkChar(board, seqs[t.uniId[i]], t.tokens[t.uniId[i]], t.uniN[i], visit);
		walkRest(board, t, seqs, t.allBi, t.allTri, visit);
	}

	/**
	 * Walks the pairs then the triples of a table whose tokens each have one
	 * sequence (seqs, by token id), the entries given by index. With whole
	 * counts, each step sums its key bigrams and trigrams and passes each
	 * distinct one on once, in the order it first came: every counter of the
	 * stream is a sum of exact integers, so the visitor ends with the very
	 * same values (and its maps with the same insertion order) for a
	 * fraction of the calls. Other counts are passed on one by one.
	 * @param {object} board - From keyboard().
	 * @param {object} t - From tableIds().
	 * @param {Array} seqs - Token id → sequence, undefined when unsupported.
	 * @param {Int32Array} bi - Indexes of the pairs to walk.
	 * @param {Int32Array} tri - Indexes of the triples to walk.
	 * @param {object} visit - As walkKeyStream.
	 */
	function walkRest(board, t, seqs, bi, tri, visit) {
		if (!t.whole) {
			for (let j = 0; j < bi.length; j++) {
				const i = bi[j];
				walkPair(seqs[t.biA[i]], seqs[t.biB[i]], t.biN[i], visit);
			}
			for (let j = 0; j < tri.length; j++) {
				const i = tri[j];
				walkTriple(seqs[t.triA[i]], seqs[t.triB[i]], seqs[t.triC[i]], t.triN[i], visit);
			}
			return;
		}
		// Each token's keys that reach across its neighbours (-1: none): its
		// first and last, its second and the one before its last.
		const size = seqs.length;
		const first = new Int32Array(size).fill(-1);
		const last = new Int32Array(size).fill(-1);
		const second = new Int32Array(size).fill(-1);
		const penult = new Int32Array(size).fill(-1);
		const single = new Uint8Array(size);
		for (let id = 0; id < size; id++) {
			const seq = seqs[id];
			if (!seq) continue;
			const keys = seq.keys;
			first[id] = keys[0];
			last[id] = keys[keys.length - 1];
			if (keys.length >= 2) {
				second[id] = keys[1];
				penult[id] = keys[keys.length - 2];
			} else single[id] = 1;
		}
		const s = summingBuffers(board);
		const { K, slot, ids, sums } = s;
		const K2 = K * K;
		let count = 0;
		const add = (id, n) => {
			let at = slot[id];
			if (at === 0) {
				if (count + 1 >= sums.length) flush();
				at = slot[id] = ++count;
				ids[at] = id;
				sums[at] = 0;
			}
			sums[at] += n;
		};
		function flush() {
			for (let at = 1; at <= count; at++) {
				const id = ids[at];
				const n = sums[at];
				slot[id] = 0;
				if (id < K2) visit.bigram((id / K) | 0, id % K, n);
				else {
					const rest = id - K2;
					visit.trigram((rest / K2) | 0, ((rest / K) | 0) % K, rest % K, n);
				}
			}
			count = 0;
		}
		let clean = false;
		try {
			// walkPair: the pair across, then the triples across.
			const { biA, biB, biN } = t;
			for (let j = 0; j < bi.length; j++) {
				const i = bi[j];
				const a = biA[i];
				const b = biB[i];
				if (first[a] < 0 || first[b] < 0) continue;
				const n = biN[i];
				add(last[a] * K + first[b], n);
				if (penult[a] >= 0) add(K2 + (penult[a] * K + last[a]) * K + first[b], n);
				if (second[b] >= 0) add(K2 + (last[a] * K + first[b]) * K + second[b], n);
			}
			flush();
			// walkTriple: the key trigram across a one-key middle.
			const { triA, triB, triC, triN } = t;
			for (let j = 0; j < tri.length; j++) {
				const i = tri[j];
				const b = triB[i];
				if (single[b] === 0) continue;
				const a = triA[i];
				const d = triC[i];
				if (first[a] < 0 || first[d] < 0) continue;
				add(K2 + (last[a] * K + first[b]) * K + first[d], triN[i]);
			}
			flush();
			clean = true;
		} finally {
			// A visitor that threw leaves sums behind: those buffers are dropped.
			if (!clean && summingCache.get(board) === s) summingCache.delete(board);
			s.busy = false;
		}
	}

	const summingCache = new WeakMap();

	// Distinct key n-grams walkRest sums before it passes them on: a slot
	// index fits 16 bits, so the slot table of a board stays in cache.
	const SUM_SLOTS = 65535;

	/**
	 * walkRest's sums on a board: key bigram k1 k2 has id k1 * K + k2,
	 * trigram k1 k2 k3 id K² + (k1 * K + k2) * K + k3; slot[id] is its place
	 * (1-based, 0: not seen) in ids and sums, filled in the order the ids
	 * first come. Kept per board, released with every slot at 0.
	 */
	function summingBuffers(board) {
		let s = summingCache.get(board);
		if (!s || s.busy) {
			const K = board.codes.length;
			s = {
				K,
				slot: new Uint16Array(K * K + K * K * K),
				ids: new Int32Array(SUM_SLOTS + 1),
				sums: new Float64Array(SUM_SLOTS + 1)
			};
			if (!summingCache.has(board)) summingCache.set(board, s);
		}
		s.busy = true;
		return s;
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
		visit.bigram(ka[la - 1], kb[0], n);
		// The triples across: the last two keys of a with b's first, then a's
		// last key with b's first two.
		if (la >= 2) visit.trigram(ka[la - 2], ka[la - 1], kb[0], n);
		if (kb.length >= 2) visit.trigram(ka[la - 1], kb[0], kb[1], n);
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
		redirect_bad: 3,
		row_jump: 2
	};
	const KEY_EVENTS = Object.keys(EVENT_KEYS);
	const TRIGRAM_EVENTS = new Set(['sfs', 'redirect', 'redirect_bad']);
	// The scored events (an event shown but not scored, row_jump, is shared
	// over its keys the same way but stays out of the points a key costs).
	const SCORED_EVENTS = KEY_EVENTS.filter((event) => METRICS[event].better !== 'none');
	const KEY_INFO_METRICS = KEY_EVENTS.filter((event) => METRICS[event].better === 'none');
	// The metrics whose value the keys share exactly (keyReport cost) and the score weighs.
	const KEY_COST_METRICS = SCORED_EVENTS.concat([
		'distance',
		'finger_imbalance',
		'pinky_load',
		'outer_column'
	]);
	// The good events the keys share the same way (keyReport gain): rolls over
	// bigrams, alternation over trigrams; not part of the score's key costs.
	const GAIN_KEYS = { roll_in: 2, roll_out: 2, alternation: 3 };
	const KEY_GAINS = Object.keys(GAIN_KEYS);
	// Every per-key value keyValues() reads: the presses, the costs, the gains,
	// the events shown but not scored.
	const KEY_METRICS = ['presses'].concat(KEY_COST_METRICS, KEY_GAINS, KEY_INFO_METRICS);
	// How many of its worst pairs or trigrams each key names.
	const WORST_GROUPS = 3;
	// How many groups of each event topGroups() lists for the whole board.
	const TOP_GROUPS = 10;
	// A word: a run of letters and combining marks (countWords).
	const WORD_PATTERN = /[\p{L}\p{M}]+/gu;
	// How many words a corpus's word table keeps, the most frequent ones: enough
	// for the hardest frequent words, a few kilobytes per corpus.
	const WORD_TABLE_SIZE = 1000;
	// The penalty metrics a word's effort adds up (wordEfforts): the scored key
	// events and the travel; the loads (finger, pinky, outer column) belong to a
	// whole text, not to a word.
	const WORD_EFFORT_METRICS = SCORED_EVENTS.concat(['distance']);
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
		const compiled = compileWays(layout, board, null);
		const plan = planTyping(compiled, board, table, false);
		const out = {
			board,
			layout,
			best: compiled.best,
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
		walkTyped(board, plan, {
			char(char, seq, n) {
				const typed = n * (seq.width || 1);
				out.chars += typed;
				if (seq.dead) out.dead += typed;
				if (seq.shift + seq.altgr > 0) out.modifiers += typed;
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

	/** Whether two characters' lists of ways (planTyping) type alike in every context. */
	function sameWays(a, b) {
		if (a === b) return true;
		if (!a || !b || a.length !== b.length) return false;
		for (let i = 0; i < a.length; i++)
			if (!sameSequence(a[i], b[i]) || (a[i].width || 1) !== (b[i].width || 1)) return false;
		return true;
	}

	/** A cell as a token for a multiset comparison: null adds nothing. */
	const cellToken = (cell) =>
		cell === null ? null : typeof cell === 'string' ? `s${cell}` : `d${cell.dead}`;

	/** Whether two layouts' dead-key rules are the same. */
	function sameDead(a, b) {
		if (a === b) return true;
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
	 * character whose key sequence changed: the layout is compiled from the
	 * current one (compileCoreFrom: only the characters, dead states and
	 * texts the changed cells and dead-key rules reach, through every chain,
	 * to the same lists as a whole compile), each character's sequence is
	 * compared with the current one, and those n-grams are taken out with the
	 * old sequences and put back with the new ones through the same visitor
	 * analyse() uses.
	 * A compact form factor is measured again only when the trial changes the
	 * cells on the keys that form keeps, or the dead-key rules.
	 * A layout that offers a choice of ways (planTyping) is planned from the
	 * current plan: only the choices whose context (the trigram around an
	 * occurrence, and the tokens before and after it) holds a token whose
	 * ways changed are made again, by the same code and in the same order as
	 * from nothing, so the plan is the same to the last bit; the trial then
	 * walks only the tokens, pairs and triples whose ways, choice or shares
	 * of ways changed ('context'). A trial that changes the chords or the
	 * multi-way tokens walks the whole stream again ('whole'), still through
	 * the same visitor, so its total stays exact.
	 * @param {object} layoutInput - The current layout (library shape).
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {object} [options] - As analyse() (keyGroups aside).
	 * @returns {{total: number, trial: function(object): {total: number,
	 *   changed: number, walk: string, compile: string, compiled: object,
	 *   commit: function(): void}}} total is the current layout's score; trial
	 *   scores another layout on the same board without changing the session
	 *   (compile: 'incremental', 'whole' or 'none'; compiled: its compileWays()
	 *   result), and its commit makes that layout the current one.
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

		const totalOf = (layout, compiled, c, counts, keyCount, formValues) => {
			const all = Object.assign({}, c);
			names.forEach((name, j) => {
				all[name] += counts[j];
			});
			return score(
				streamMetrics(layout, board, compiled, all, keyCount, opts, weightedFit(forms, formValues)),
				opts.weights
			).total;
		};

		const delta = {
			c: streamCounts(),
			counts: new Float64Array(names.length),
			keyCount: new Float64Array(K)
		};
		const deltaVisitor = sessionVisitor(delta.c, delta.keyCount, delta.counts);
		const fixed = typingMode(opts) === 'fixed';
		// Every character typed one way whatever its context: the incremental walk holds.
		const simple = (plan) => plan.multi.size === 0 && plan.chords.length === 0;
		// What decides a plan's stream: each character's ways and the chords.
		const planState = (plan) => ({
			ways: chars.map((char) => plan.ways.get(char)),
			chords: plan.chords,
			chordWays: plan.chords.map((chord) => plan.ways.get(chord))
		});
		// The whole stream of a plan, walked from nothing.
		const walkAll = (plan) => {
			const out = {
				c: streamCounts(),
				counts: new Float64Array(names.length),
				keyCount: new Float64Array(K)
			};
			walkTyped(board, plan, sessionVisitor(out.c, out.keyCount, out.counts));
			return out;
		};
		// The ways before the substitutes, which a trial compiles again only in part.
		const core = compileCore(firstLayout, board, null, 'record');
		const compiled = finishWays(new Map(core.ways), core.texts);
		const plan = planTyping(compiled, board, table, fixed);
		const walked = walkAll(plan);
		const formValues = forms.map((form) => formFit(firstLayout, board, table, form));
		let state = {
			layout: firstLayout,
			core,
			compiled,
			plan,
			simple: simple(plan),
			...planState(plan),
			seqs: sequences(compiled.best),
			c: walked.c,
			counts: walked.counts,
			keyCount: walked.keyCount,
			formValues,
			total: totalOf(firstLayout, compiled, walked.c, walked.counts, walked.keyCount, formValues)
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
			// Compiled from the current layout: only the ways the changed cells and rules reach.
			const nextCore = compileCoreFrom(state.core, layout, board);
			const nextCompiled =
				nextCore === state.core
					? state.compiled
					: finishWays(new Map(nextCore.ways), nextCore.texts);
			// Planned from the current plan: only the choices a changed token can reach are made again.
			const nextPlan = planTyping(nextCompiled, board, table, fixed, state.plan);
			const seqs = sequences(nextCompiled.best);
			let next;
			// How the trial was walked: the changed characters' n-grams ('stream'),
			// the changed contexts ('context'), or nothing to walk or all ('whole').
			let walk = 'whole';
			if (state.simple && simple(nextPlan)) {
				next = walkChanged(state.seqs, seqs);
				walk = 'stream';
			} else if (nextPlan.changed) {
				next = walkContext(state.plan, nextPlan);
				walk = 'context';
			} else {
				// A context choice: the stream changes only if some character's ways
				// (or the chords) do; then it is walked whole.
				const ways = chars.map((char) => nextPlan.ways.get(char));
				let moved = 0;
				for (let ch = 0; ch < chars.length; ch++)
					if (!sameWays(state.ways[ch], ways[ch])) moved += 1;
				const sameChords =
					state.chords.length === nextPlan.chords.length &&
					nextPlan.chords.every(
						(chord, i) =>
							chord === state.chords[i] && sameWays(state.chordWays[i], nextPlan.ways.get(chord))
					);
				next =
					moved === 0 && sameChords
						? { c: state.c, counts: state.counts, keyCount: state.keyCount }
						: walkAll(nextPlan);
				next.changed = moved + (sameChords ? 0 : 1);
			}
			const changed = next.changed;
			// A compact form is measured again only when its kept cells changed.
			const before = state.layout;
			const deadSame = sameDead(before.dead, layout.dead);
			const codes = changedCodes(before, layout);
			const nextForms = forms.map((form, i) =>
				deadSame && sameForm(before, layout, codes, formMissing[i])
					? state.formValues[i]
					: formFit(layout, board, table, form)
			);
			const total = totalOf(layout, nextCompiled, next.c, next.counts, next.keyCount, nextForms);
			return {
				total,
				walk,
				changed,
				// How the layout was compiled: not at all (the same ways), in part, or whole.
				compile: nextCore === state.core ? 'none' : nextCore.whole ? 'whole' : 'incremental',
				compiled: nextCompiled,
				commit() {
					adoptPlan(nextPlan);
					state = {
						layout,
						core: nextCore,
						compiled: nextCompiled,
						plan: nextPlan,
						simple: simple(nextPlan),
						...planState(nextPlan),
						seqs,
						c: next.c,
						counts: next.counts,
						keyCount: next.keyCount,
						formValues: nextForms,
						total
					};
				}
			};
		}

		/**
		 * The counters of a trial whose characters each have one way: the
		 * current ones, less the n-grams holding a changed character walked with
		 * the old sequences, plus the same walked with the new ones.
		 * @returns {{c, counts, keyCount, changed}} changed: characters whose sequence changed.
		 */
		function walkChanged(old, seqs) {
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
			return { c: nextC, counts: nextCounts, keyCount: nextKeys, changed };
		}

		/**
		 * The counters of a trial planned from the current plan (planTyping's
		 * previous): the current ones, less the token, pair and triple entries
		 * whose ways, choice or shares of ways may have changed walked with the
		 * current plan, plus the same walked with the trial's.
		 * @param {object} old - The current plan.
		 * @param {object} plan - The trial's, with plan.changed.
		 * @returns {{c, counts, keyCount, changed}} changed: tokens whose ways changed.
		 */
		function walkContext(old, plan) {
			for (const name of names) delta.c[name] = 0;
			delta.counts.fill(0);
			delta.keyCount.fill(0);
			const visit = deltaVisitor;
			const { dirty, picks, leftKeys, rightKeys, tokens } = plan.changed;
			const index = contextIndex(plan.table, plan.parts, plan.multi);
			const { restBi, restTri } = plan.parts;
			const marks = entryMarks(plan.table, plan.parts);
			stamp += 1;
			const once = (list, i) => {
				if (list[i] === stamp) return false;
				list[i] = stamp;
				return true;
			};
			for (const token of new Set([...dirty, ...tokens]))
				for (const i of index.uniAt.get(token) || []) {
					if (!once(marks.uni, i)) continue;
					const [t, n] = plan.table.uni[i];
					walkTypedToken(board, old, t, n, -1, visit);
					walkTypedToken(board, plan, t, n, 1, visit);
				}
			for (const token of dirty) {
				for (const i of index.restBiOf.get(token) || []) {
					if (!once(marks.restBi, i)) continue;
					const [a, b, n] = restBi[i];
					walkPair(old.best.get(a), old.best.get(b), -n, visit);
					walkPair(plan.best.get(a), plan.best.get(b), n, visit);
				}
				for (const i of index.restTriOf.get(token) || []) {
					if (!once(marks.restTri, i)) continue;
					const [a, b, d, n] = restTri[i];
					walkTriple(old.best.get(a), old.best.get(b), old.best.get(d), -n, visit);
					walkTriple(plan.best.get(a), plan.best.get(b), plan.best.get(d), n, visit);
				}
			}
			const pair = (i) => {
				if (i === undefined || !once(marks.touchBi, i)) return;
				walkTypedPair(old, i, -1, visit);
				walkTypedPair(plan, i, 1, visit);
			};
			const triple = (i) => {
				if (!once(marks.touchTri, i)) return;
				walkTypedTriple(old, i, -1, visit);
				walkTypedTriple(plan, i, 1, visit);
			};
			for (const token of dirty) for (const i of index.biOf.get(token) || []) pair(i);
			for (const key of leftKeys) pair(index.biAt.get(key));
			for (const key of rightKeys) pair(index.biAt.get(key));
			for (const i of picks) triple(i);
			// A triple reads the shares of its first pair (its first token's ways)
			// and of its last pair (its last token's).
			for (const key of leftKeys) for (const i of index.byFirst.get(key) || []) triple(i);
			for (const key of rightKeys) for (const i of index.byLast.get(key) || []) triple(i);
			const nextC = Object.assign({}, state.c);
			for (const name of names) nextC[name] += delta.c[name];
			const nextCounts = state.counts.slice();
			for (let j = 0; j < nextCounts.length; j++) nextCounts[j] += delta.counts[j];
			const nextKeys = state.keyCount.slice();
			for (let k = 0; k < K; k++) nextKeys[k] += delta.keyCount[k];
			return { c: nextC, counts: nextCounts, keyCount: nextKeys, changed: dirty.size };
		}

		return {
			get total() {
				return state.total;
			},
			trial
		};
	}

	const entryMarkCache = new WeakMap();

	/** One stamp per entry of a plan's partition, for a walk that visits each entry once. */
	function entryMarks(table, parts) {
		if (entryMarkCache.has(parts)) return entryMarkCache.get(parts);
		const marks = {
			uni: new Uint32Array(table.uni.length),
			restBi: new Uint32Array(parts.restBi.length),
			restTri: new Uint32Array(parts.restTri.length),
			touchBi: new Uint32Array(parts.touchBi.length),
			touchTri: new Uint32Array(parts.touchTri.length)
		};
		entryMarkCache.set(parts, marks);
		return marks;
	}

	/**
	 * The typing plan of a layout on a corpus (planTyping): the chords it
	 * uses, each token's ways, and the way it types a token between two
	 * others, so a text can be typed exactly as the tables are (the tests'
	 * reference stream).
	 * @param {object} layoutInput - Library shape (see layoutFromRows).
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {{keyboard?: string, profile?: object, typing?: string}} [options] - As analyse().
	 * @returns {{board: object, chords: string[], ways: Map, choose: function}}
	 *   choose(before, token, after) → index in ways.get(token); before and
	 *   after are tokens the layout types, or null at an edge.
	 */
	function typingPlan(layoutInput, ngrams, options) {
		const opts = options || {};
		const layout = layoutFromRows(layoutInput);
		const board = boardFor(layout, opts.keyboard || DEFAULT_KEYBOARD, opts.profile);
		const plan = planTyping(
			compileWays(layout, board, null),
			board,
			prepareNgrams(ngrams),
			opts.typing === 'fixed'
		);
		return {
			board,
			chords: plan.chords.slice(),
			ways: plan.ways,
			choose: (before, token, after) =>
				plan.multi.has(token) ? plan.choose(before, token, after) : 0
		};
	}

	// Held modifiers of each level, as the pages write them before a key.
	const LEVEL_PREFIX = { base: '', shift: 'Shift+', altgr: 'AltGr+', shift_altgr: 'Shift+AltGr+' };

	/**
	 * The « typed via » rows of an analysis, for the pages: each character a
	 * choice concerned (several ways used, or a chord), most frequent first,
	 * with each way's keys written with the layout's own characters
	 * (« AltGr+o », a dead key as [its state]) and its share.
	 * @param {object} result - analyse() output.
	 * @param {object} layoutInput - The layout analysed (library shape).
	 * @param {number} [limit] - At most this many rows; all when absent.
	 * @returns {Array<{char: string, count: number, ways: Array<{kind: string,
	 *   keys: string, share: number}>}>} share in % of the character's count.
	 */
	function typingRows(result, layoutInput, limit) {
		const rows = layoutInput.rows || {};
		const label = (code, level) => {
			const base = rows[code] ? rows[code][0] : null;
			const name = typeof base === 'string' ? base : base && base.dead ? `[${base.dead}]` : code;
			return LEVEL_PREFIX[level] + name;
		};
		const out = [];
		for (const [char, ways] of Object.entries(result.typing.paths)) {
			const count = ways.reduce((sum, way) => sum + way.count, 0);
			if (!(count > 0) || (ways.length < 2 && !(char in result.typing.chords))) continue;
			out.push({
				char,
				count,
				ways: ways.map((way) => ({
					kind: way.kind,
					keys: way.steps.map(([code, level]) => label(code, level)).join(' '),
					share: (100 * way.count) / count
				}))
			});
		}
		out.sort((a, b) => b.count - a.count || (a.char < b.char ? -1 : 1));
		return limit === undefined ? out : out.slice(0, limit);
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
	 * - gain: the same for the good events of KEY_GAINS (rolls in and out over
	 *   the bigrams, alternation over the trigrams): the keys' parts add up to
	 *   the metric;
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
			const gain = {};
			for (const id of KEY_GAINS) {
				const whole = id === 'alternation' ? c.trigrams : c.bigrams;
				gain[id] = pct(m.perKey[id][k], whole) / GAIN_KEYS[id];
			}
			keys[code] = {
				presses: pct(m.keyCount[k], m.allPresses),
				sfb: share('sfb'),
				sfs: share('sfs'),
				lsb: share('lsb'),
				scissors: share('scissors') + share('half_scissors'),
				redirect: share('redirect'),
				cost,
				gain,
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
	 * One per-key value of every key: its share of the presses, its part of a
	 * cost metric (KEY_COST_METRICS) or of a good event (KEY_GAINS).
	 * @param {object} result - analyse() output.
	 * @param {string} metric - One of KEY_METRICS.
	 * @returns {object} code → value (% of the presses, or the metric's unit).
	 * @throws {Error} On a metric that is not per key.
	 */
	function keyValues(result, metric) {
		if (!KEY_METRICS.includes(metric))
			throw new Error(`layout_analysis: ${metric} is not a per-key value`);
		const out = {};
		for (const [code, key] of Object.entries(result.keys))
			out[code] =
				metric === 'presses'
					? key.presses
					: KEY_GAINS.includes(metric)
						? key.gain[metric]
						: key.cost[metric];
		return out;
	}

	/**
	 * Key by key, how much more of a per-key value one layout puts on each
	 * physical key than another, both measured on the same keyboard.
	 * @param {object} a - analyse() output, the layout read.
	 * @param {object} b - analyse() output, the layout it is compared with.
	 * @param {string} metric - One of KEY_METRICS.
	 * @returns {object} code → a's value − b's value.
	 * @throws {Error} On results measured on different keyboards, or a metric
	 *   that is not per key.
	 */
	function keyDiff(a, b, metric) {
		if (a.keyboard !== b.keyboard)
			throw new Error(`layout_analysis: keyDiff needs one keyboard (${a.keyboard}, ${b.keyboard})`);
		const x = keyValues(a, metric);
		const y = keyValues(b, metric);
		const out = {};
		for (const code of Object.keys(x)) out[code] = x[code] - y[code];
		return out;
	}

	/**
	 * Where one layout stands among compared ones, metric by metric: how many
	 * of the others it beats, ties and loses to on each scored metric (one
	 * whose `better` is higher or lower).
	 * @param {object[]} results - analyse() or compare() outputs.
	 * @param {string} id - The layout id read.
	 * @returns {object} metric → {beats, ties, loses, others}.
	 * @throws {Error} When the layout is not among the results.
	 */
	function standing(results, id) {
		const own = results.find((r) => r.layout.id === id);
		if (!own) throw new Error(`layout_analysis: standing needs the layout ${id} among the results`);
		const out = {};
		for (const [metric, definition] of Object.entries(METRICS)) {
			if (definition.better === 'none') continue;
			const entry = { beats: 0, ties: 0, loses: 0, others: results.length - 1 };
			for (const other of results) {
				if (other === own) continue;
				const delta = own.metrics[metric] - other.metrics[metric];
				if (delta === 0) entry.ties++;
				else if ((definition.better === 'higher') === delta > 0) entry.beats++;
				else entry.loses++;
			}
			out[metric] = entry;
		}
		return out;
	}

	/**
	 * The scored metrics a key pair or a word can raise, with their weight and
	 * direction: one place for the points of a pair (bigramMatrix) and of a
	 * word (wordEfforts).
	 * @param {object} [weights] - As score(); the defaults when absent.
	 * @returns {function(string): number} metric → signed points per unit (0
	 *   for a metric shown but not scored, or a counter that is no metric).
	 */
	function signedWeights(weights) {
		const used = weights ? Object.assign(defaultWeights(), weights) : defaultWeights();
		return (id) => {
			const metric = METRICS[id];
			if (!metric || metric.better === 'none') return 0;
			return (metric.better === 'higher' ? 1 : -1) * (used[id] || 0);
		};
	}

	/**
	 * Every key pair a layout makes on a corpus, key × key, with how often it
	 * occurs and what it is: the bigrams of the key stream analyse() measures
	 * (the ways of typing it chose, typing option included) without a thumb
	 * key, the ones every bigram metric is a share of, each classified by the
	 * one visitor analyse() uses. The pairs' counts and points add up to
	 * analyse()'s bigram metrics and their part of the score.
	 * @param {object} layoutInput - Library shape (see layoutFromRows).
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {{keyboard?: string, profile?: object, weights?: object, typing?: string}} [options]
	 *   - As analyse().
	 * @returns {{keyboard: string, bigrams: number, keys: string[], pairs:
	 *   Array<{keys: string[], count: number, share: number, events: string[],
	 *   points: number}>}} bigrams: the key bigrams counted; keys: every key of
	 *   a pair, the busiest first; pairs: the most frequent first, each with its
	 *   share of the bigrams (%), the counters it raises (metric ids such as
	 *   sfb, roll_in, row_jump, hand_change, repeat) and the score points it
	 *   gains (> 0) or costs (< 0): Σ sign × weight × share over those metrics.
	 */
	function bigramMatrix(layoutInput, ngrams, options) {
		const opts = options || {};
		const layout = layoutFromRows(layoutInput);
		const board = boardFor(layout, opts.keyboard || DEFAULT_KEYBOARD, opts.profile);
		const table = prepareNgrams(ngrams);
		const compiled = compileWays(layout, board, null);
		const plan = planTyping(compiled, board, table, typingMode(opts) === 'fixed');
		const K = board.codes.length;
		const names = Object.keys(streamCounts()).filter((name) => name !== 'bigrams');
		// A pair's class, probed once from the visitor: the counters it raises.
		const classes = new Map();
		const classOf = (k1, k2) => {
			const at = k1 * K + k2;
			if (!classes.has(at)) {
				const counts = streamCounts();
				streamVisitor(board, counts, new Float64Array(K), {}, null).bigram(k1, k2, 1);
				classes.set(at, counts.bigrams === 0 ? null : names.filter((name) => counts[name] !== 0));
			}
			return classes.get(at);
		};
		const pairs = new Map();
		let total = 0;
		walkTyped(board, plan, {
			char() {},
			unsupported() {},
			press() {},
			bigram(k1, k2, n) {
				// A pair with a thumb key is in no bigram metric.
				if (classOf(k1, k2) === null) return;
				total += n;
				const at = k1 * K + k2;
				pairs.set(at, (pairs.get(at) || 0) + n);
			},
			trigram() {}
		});
		const signed = signedWeights(opts.weights);
		const busy = new Float64Array(K);
		const out = Array.from(pairs, ([at, n]) => {
			const k1 = Math.floor(at / K);
			const k2 = at % K;
			busy[k1] += n;
			busy[k2] += n;
			const events = classOf(k1, k2);
			const share = total > 0 ? (100 * n) / total : 0;
			const points = events.reduce((sum, id) => sum + signed(id) * share, 0);
			return { keys: [board.codes[k1], board.codes[k2]], count: n, share, events, points, at };
		})
			.filter((pair) => pair.count !== 0)
			.sort((x, y) => y.count - x.count || x.at - y.at)
			.map(({ at, ...pair }) => pair);
		const keys = board.codes
			.map((code, k) => [code, k])
			.filter(([, k]) => busy[k] > 0)
			.sort((x, y) => busy[y[1]] - busy[x[1]] || x[1] - y[1])
			.map(([code]) => code);
		return { keyboard: board.id, bigrams: total, keys, pairs: out };
	}

	/**
	 * Adds every word of a text to a word count. A word is a run of letters and
	 * combining marks (Unicode L and M), folded to lower case: an apostrophe, a
	 * hyphen, a digit or a space ends it (« l'homme » is « l » and « homme »).
	 * A word of one character is not kept: it has no key pair to measure.
	 * @param {string} text - The text.
	 * @param {number} [n] - How many times the text counts (a word list's count); 1.
	 * @param {object} [into] - The count to add to; a new one when absent.
	 * @returns {object} word → count.
	 * @throws {Error} On a text that is not a string or a count that is not positive.
	 */
	function countWords(text, n, into) {
		if (typeof text !== 'string') throw new Error('layout_analysis: countWords needs a text');
		const times = n === undefined ? 1 : n;
		if (!(times > 0) || !Number.isFinite(times))
			throw new Error('layout_analysis: countWords needs a positive count');
		const counts = into || {};
		for (const match of text.matchAll(WORD_PATTERN)) {
			const word = match[0].toLowerCase();
			if (isOneCodePoint(word)) continue;
			// An own count only: « constructor » is a word, not Object.prototype's.
			counts[word] =
				(Object.prototype.hasOwnProperty.call(counts, word) ? counts[word] : 0) + times;
		}
		return counts;
	}

	/**
	 * The WORD_TABLE_SIZE most frequent words of a count, the most frequent
	 * first (ties in code point order): the bounded word table a corpus ships.
	 * @param {object} counts - word → count (countWords).
	 * @returns {object} word → count, in that order.
	 */
	function wordTable(counts) {
		return Object.fromEntries(
			Object.entries(counts)
				.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : a[0] > b[0] ? 1 : 0))
				.slice(0, WORD_TABLE_SIZE)
		);
	}

	/** The bounded word table of a text: wordTable(countWords(text)). */
	function wordsFromText(text) {
		return wordTable(countWords(text));
	}

	/**
	 * How hard each word is to type on a layout: the points the global score
	 * would take off a text made of that word alone, from the score's penalty
	 * metrics measured on the word's own key stream (WORD_EFFORT_METRICS: its
	 * SFBs, skipgrams, lateral stretches, scissors and redirects as shares of
	 * its key bigrams or trigrams, and its travel in mm per character), each
	 * times its weight. The word is typed alone as analyse() types a text, the
	 * ways of typing chosen the same way (typing option included). A word with
	 * a character the layout cannot type is listed apart.
	 * @param {object} layoutInput - Library shape (see layoutFromRows).
	 * @param {object|Array} words - word → count, or [[word, count], ...].
	 * @param {{keyboard?: string, profile?: object, weights?: object, typing?: string}} [options]
	 *   - As analyse().
	 * @returns {{words: Array<{word: string, count: number, effort: number,
	 *   parts: object}>, unsupported: Array<{word: string, count: number}>,
	 *   mean: number}} words: the hardest first (then the most frequent);
	 *   effort in points ≥ 0, parts: metric → its points; mean: the effort
	 *   averaged over the words' occurrences.
	 * @throws {Error} On a word that is not a non-empty string without line
	 *   breaks or tabs, or a count that is not positive.
	 */
	function wordEfforts(layoutInput, words, options) {
		const opts = options || {};
		const layout = layoutFromRows(layoutInput);
		const board = boardFor(layout, opts.keyboard || DEFAULT_KEYBOARD, opts.profile);
		const compiled = compileWays(layout, board, null);
		const fixed = typingMode(opts) === 'fixed';
		const signed = signedWeights(opts.weights);
		const entries = Array.isArray(words) ? words : Object.entries(words || {});
		const out = [];
		const unsupported = [];
		let occurrences = 0;
		let sum = 0;
		for (const [word, count] of entries) {
			if (typeof word !== 'string' || word === '' || /[\r\n\t]/.test(word))
				throw new Error(`layout_analysis: ${JSON.stringify(word)} is not a word`);
			if (!(count > 0) || !Number.isFinite(count))
				throw new Error(`layout_analysis: the word ${word} needs a positive count`);
			const c = streamCounts();
			const plan = planTyping(compiled, board, prepareNgrams(ngramsFromText(word)), fixed);
			walkTyped(
				board,
				plan,
				streamVisitor(board, c, new Float64Array(board.codes.length), {}, null)
			);
			if (c.unsupported > 0) {
				unsupported.push({ word, count });
				continue;
			}
			const parts = {};
			let effort = 0;
			for (const id of WORD_EFFORT_METRICS) {
				const whole = id === 'distance' ? c.chars : TRIGRAM_EVENTS.has(id) ? c.trigrams : c.bigrams;
				const value = whole > 0 ? ((id === 'distance' ? 1 : 100) * c[id]) / whole : 0;
				// A penalty metric's signed weight is negative: the points it takes off.
				parts[id] = -signed(id) * value;
				effort += parts[id];
			}
			out.push({ word, count, effort, parts });
			occurrences += count;
			sum += count * effort;
		}
		out.sort(
			(x, y) =>
				y.effort - x.effort || y.count - x.count || (x.word < y.word ? -1 : x.word > y.word ? 1 : 0)
		);
		return { words: out, unsupported, mean: occurrences > 0 ? sum / occurrences : 0 };
	}

	/**
	 * How the occurrences of measured words spread over equal ranges of effort,
	 * from 0 to the hardest word's: the distribution the Comparer draws.
	 * @param {Array<{effort: number, count: number}>} words - wordEfforts().words.
	 * @param {number} bins - How many ranges (an integer ≥ 1).
	 * @returns {Array<{from: number, to: number, count: number, words: number,
	 *   share: number}>} Each range [from, to) (the last one closed): the
	 *   occurrences it holds, the distinct words, and its share of all the
	 *   occurrences (%).
	 * @throws {Error} On a bin count that is not a positive integer.
	 */
	function effortDistribution(words, bins) {
		if (!Number.isInteger(bins) || bins < 1)
			throw new Error('layout_analysis: effortDistribution needs a positive integer of bins');
		const max = words.reduce((m, w) => Math.max(m, w.effort), 0);
		const width = max / bins;
		const out = Array.from({ length: bins }, (_, i) => ({
			from: i * width,
			to: i === bins - 1 ? max : (i + 1) * width,
			count: 0,
			words: 0,
			share: 0
		}));
		let all = 0;
		for (const w of words) {
			const i = width > 0 ? Math.min(bins - 1, Math.floor(w.effort / width)) : 0;
			out[i].count += w.count;
			out[i].words += 1;
			all += w.count;
		}
		for (const bin of out) bin.share = all > 0 ? (100 * bin.count) / all : 0;
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
		// The model's weights give the same forms every time: built once per format.
		const cacheKey = weights === undefined ? String(format) : null;
		if (cacheKey !== null && defaultFormsCache.has(cacheKey))
			return defaultFormsCache.get(cacheKey);
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
		if (cacheKey !== null) defaultFormsCache.set(cacheKey, forms);
		return forms;
	}

	const defaultFormsCache = new Map();
	const formSetsCache = new WeakMap();

	/** Each form's missing keys as a Set, once per forms list (compactForms). */
	function formSets(forms) {
		let out = formSetsCache.get(forms);
		if (!out) {
			out = forms.map((form) => new Set(form.missing));
			formSetsCache.set(forms, out);
		}
		return out;
	}

	/**
	 * Frequency-weighted share of the characters still typed on each compact
	 * form factor, averaged with the form factors' weights.
	 */
	function compactFit(layout, board, table, format, formWeights) {
		const forms = compactForms(format, formWeights);
		// Forms that take away the same keys of this layout (most differ only by
		// keys it leaves empty, a numpad or arrows) keep the same characters.
		const used = Object.keys(layout.rows).filter((code) => board.index.has(code));
		const fits = new Map();
		const sets = formSets(forms);
		return weightedFit(
			forms,
			forms.map((form, i) => {
				const key = used.filter((code) => sets[i].has(code)).join(' ');
				if (!fits.has(key)) fits.set(key, formFit(layout, board, table, form));
				return fits.get(key);
			})
		);
	}

	/** The share of the characters still typed on one compact form factor. */
	function formFit(layout, board, table, form) {
		const reachable = reachableChars(layout, board, new Set(form.missing));
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

	/**
	 * The coverage bonus: the distinct characters a layout types (any way),
	 * over the model's fixed cap (coverage_cap), at most 100 %. A fixed cap,
	 * not the best of the layouts compared, so one layout's value never
	 * depends on the others and the optimizer's objective stays stable.
	 * @param {number} distinct - compileWays().distinct.
	 * @returns {number} 0 to 100.
	 */
	function coverageBonus(distinct) {
		const cap = data().model.coverage_cap;
		return (100 * Math.min(distinct, cap)) / cap;
	}

	/**
	 * The simplicity rules, each an objective share from 0 to 100 % (null when
	 * the layout gives the rule nothing to measure); simplicity is their mean.
	 * - accents: of the accented letters typed through AltGr or a dead key (not
	 *   on a key of their own), the share whose last key is their base letter's
	 *   key (dead key then e for ê, AltGr+e for é);
	 * - pairs: each pair of simplicity_pairs typed, 1 when the closing
	 *   character is the key right of the opening one on the same level, ½
	 *   when it is left of it or both share one key (opening on the lower
	 *   level), 0 otherwise;
	 * - digits: of the nine steps 1→2 … 8→9, 9→0, the share where the next
	 *   digit is the key right of the previous one on the same level.
	 * « The key right of » is the next key of the same row (a split board's
	 * other half included). Every way of each character is tried.
	 * @param {object} board - From keyboard().
	 * @param {object} compiled - From compileWays().
	 * @returns {{value: number, rules: {accents, pairs, digits}}} Each rule
	 *   {value, measured} or null.
	 */
	function simplicity(board, compiled) {
		const { ways } = compiled;
		const right = rightNeighbours(board);
		const real = (char) => (ways.get(char) || []).filter((way) => !way.substituted);
		const placed = (char) => real(char).map((way) => [way.keys[way.keys.length - 1], way.level]);
		const share = (got, measured) =>
			measured > 0 ? { value: (100 * got) / measured, measured } : null;

		const baseKeys = new Map();
		for (const [char, list] of ways)
			for (const way of list)
				if (!way.substituted && way.keys.length === 1 && way.altgr === 0)
					(baseKeys.get(char) || baseKeys.set(char, new Set()).get(char)).add(way.keys[0]);
		let accented = 0;
		let mnemonic = 0;
		for (const [char, list] of ways) {
			const letter = accentBase(char);
			if (letter === null) continue;
			const own = list.filter((way) => !way.substituted);
			if (own.length === 0 || own.some((way) => way.altgr === 0 && !way.dead)) continue;
			accented++;
			const letterKeys = new Set([
				...(baseKeys.get(letter.toLowerCase()) || []),
				...(baseKeys.get(letter.toUpperCase()) || [])
			]);
			if (own.some((way) => letterKeys.has(way.keys[way.keys.length - 1]))) mnemonic++;
		}

		let pairScore = 0;
		let pairs = 0;
		for (const pair of data().model.simplicity_pairs) {
			const [open, close] = codePoints(pair);
			const o = placed(open);
			const c = placed(close);
			if (o.length === 0 || c.length === 0) continue;
			pairs++;
			let best = 0;
			for (const [ko, lo] of o)
				for (const [kc, lc] of c) {
					if (lo === lc && right[ko] === kc) best = Math.max(best, 1);
					else if (lo === lc && right[kc] === ko) best = Math.max(best, 0.5);
					else if (
						ko === kc &&
						LAYER_IDS.indexOf(lo) >= 0 &&
						LAYER_IDS.indexOf(lo) < LAYER_IDS.indexOf(lc)
					)
						best = Math.max(best, 0.5);
				}
			pairScore += best;
		}

		const DIGITS = '1234567890';
		let steps = 0;
		let ordered = 0;
		for (let i = 0; i + 1 < DIGITS.length; i++) {
			const a = placed(DIGITS[i]);
			const b = placed(DIGITS[i + 1]);
			if (a.length === 0 || b.length === 0) continue;
			steps++;
			if (a.some(([ka, la]) => b.some(([kb, lb]) => la === lb && right[ka] === kb))) ordered++;
		}

		const rules = {
			accents: share(mnemonic, accented),
			pairs: share(pairScore, pairs),
			digits: share(ordered, steps)
		};
		const values = Object.values(rules).filter((rule) => rule !== null);
		const value = values.length ? values.reduce((s, rule) => s + rule.value, 0) / values.length : 0;
		return { value, rules };
	}

	const accentCache = new Map();

	/**
	 * The base letter of an accented Latin letter (a letter A–Z followed by
	 * combining marks once decomposed: ê → e, Ǘ → U), null for anything else.
	 * @param {string} char - One character.
	 * @returns {string|null} The base letter.
	 */
	function accentBase(char) {
		if (accentCache.has(char)) return accentCache.get(char);
		const parts = codePoints(char.normalize('NFD'));
		const base =
			parts.length >= 2 &&
			/^[A-Za-z]$/.test(parts[0]) &&
			parts.slice(1).every((mark) => /^\p{M}$/u.test(mark))
				? parts[0]
				: null;
		accentCache.set(char, base);
		return base;
	}

	const neighbourCache = new WeakMap();

	/**
	 * The key right of each key: the next key of the same row by position.
	 * @param {object} board - From keyboard().
	 * @returns {Int32Array} key index → the next key's index, or -1.
	 */
	function rightNeighbours(board) {
		if (neighbourCache.has(board)) return neighbourCache.get(board);
		const out = new Int32Array(board.codes.length).fill(-1);
		const rows = new Map();
		board.codes.forEach((_, k) => {
			const row = board.row[k];
			(rows.get(row) || rows.set(row, []).get(row)).push(k);
		});
		for (const keys of rows.values()) {
			keys.sort((a, b) => board.x[a] - board.x[b] || a - b);
			for (let i = 0; i + 1 < keys.length; i++) out[keys[i]] = keys[i + 1];
		}
		neighbourCache.set(board, out);
		return out;
	}

	/**
	 * The points the keystroke metrics take from the score along the path an
	 * analysis typed, by the default weights, each share over the corpus's
	 * own totals (characters, bigrams, trigrams): the sum the choice of ways
	 * minimises (typingCosts), so a best path never costs more than the fixed
	 * one where the choices do not interact.
	 * @param {object} table - From prepareNgrams().
	 * @param {object} c - analyse()'s counts.
	 * @param {{pinky: number, outer: number, home: number}} presses - Presses
	 *   on the pinkies, on the outer column and on the home row.
	 * @returns {number} Points (positive: lost).
	 */
	function typingCost(table, c, presses) {
		const w = data().weights;
		const maps = ngramMaps(table);
		const nc = table.totalChars;
		const per = (n, total) => (total > 0 ? (100 * n) / total : 0);
		const bigrams =
			w.sfb * c.sfb +
			w.lsb * c.lsb +
			w.scissors * c.scissors +
			w.half_scissors * c.half_scissors -
			w.roll_in * c.roll_in -
			w.roll_out * c.roll_out;
		const trigrams =
			w.sfs * c.sfs +
			w.redirect * c.redirect +
			w.redirect_bad * c.redirect_bad -
			w.roll3_in * c.roll3_in -
			w.roll3_out * c.roll3_out -
			w.alternation * c.alternation;
		const chars =
			w.pinky_load * presses.pinky +
			w.outer_column * presses.outer -
			w.home_row * presses.home +
			w.modifier_usage * c.modifiers +
			w.dead_key_usage * c.dead;
		return (
			per(bigrams, maps.bigrams) +
			per(trigrams, maps.trigrams) +
			per(chars, nc) +
			(nc > 0 ? (w.distance * c.distance) / nc : 0)
		);
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

	// ==================================
	// ======= 7/ Ways of typing ========
	// ==================================

	const ngramMapCache = new WeakMap();

	/**
	 * Look-up maps of a prepared table: each bigram and trigram count by its
	 * tokens (joined by TOKEN_SEP), and each table's total.
	 * @param {object} table - From prepareNgrams() or tokenTable().
	 * @returns {{bi: Map, tri: Map, bigrams: number, trigrams: number}} Maps.
	 */
	function ngramMaps(table) {
		if (ngramMapCache.has(table)) return ngramMapCache.get(table);
		const bi = new Map();
		const tri = new Map();
		let bigrams = 0;
		let trigrams = 0;
		for (const [a, b, n] of table.bi) {
			bi.set(a + TOKEN_SEP + b, n);
			bigrams += n;
		}
		for (const [a, b, c, n] of table.tri) {
			tri.set(a + TOKEN_SEP + b + TOKEN_SEP + c, n);
			trigrams += n;
		}
		const maps = { bi, tri, bigrams, trigrams };
		ngramMapCache.set(table, maps);
		return maps;
	}

	/**
	 * The points one key pair takes from the score by the given weights, per
	 * percentage point of the bigrams: the events of analyse()'s bigram rule
	 * (SFB, scissors, lateral stretch, rolls), the same classification.
	 */
	function bigramPoints(board, w, k1, k2) {
		const f1 = board.finger[k1];
		const f2 = board.finger[k2];
		const thumb = (f) => f === LEFT_THUMB || f === RIGHT_THUMB;
		if (thumb(f1) || thumb(f2) || k1 === k2) return 0;
		if (f1 === f2) return w.sfb;
		if (board.hand[k1] !== board.hand[k2]) return 0;
		const o1 = board.order[k1];
		const o2 = board.order[k2];
		let points = 0;
		if (Math.abs(o1 - o2) === 1) {
			const longer = FINGER_LENGTH[o1] > FINGER_LENGTH[o2] ? k1 : k2;
			const shorter = longer === k1 ? k2 : k1;
			const down = board.row[longer] - board.row[shorter];
			if (down >= 2) points += w.scissors;
			else if (down === 1) points += w.half_scissors;
			if (board.lateral[k1] || board.lateral[k2]) points += w.lsb;
		}
		return points - (o2 > o1 ? w.roll_in : w.roll_out);
	}

	/**
	 * The points one key triple takes from the score, per percentage point of
	 * the trigrams: analyse()'s trigram rule (skipgram, redirects, rolls,
	 * alternation).
	 */
	function trigramPoints(board, w, k1, k2, k3) {
		const f1 = board.finger[k1];
		const f2 = board.finger[k2];
		const f3 = board.finger[k3];
		const thumb = (f) => f === LEFT_THUMB || f === RIGHT_THUMB;
		if (thumb(f1) || thumb(f2) || thumb(f3)) return 0;
		let points = f1 === f3 && k1 !== k3 ? w.sfs : 0;
		if (f1 === f2 || f2 === f3) return points;
		const h1 = board.hand[k1];
		const h2 = board.hand[k2];
		const h3 = board.hand[k3];
		if (h1 === h2 && h2 === h3) {
			const d = (board.order[k2] - board.order[k1]) * (board.order[k3] - board.order[k2]);
			if (d > 0) return points - (board.order[k2] > board.order[k1] ? w.roll3_in : w.roll3_out);
			points += w.redirect;
			const index =
				board.order[k1] === INDEX_ORDER ||
				board.order[k2] === INDEX_ORDER ||
				board.order[k3] === INDEX_ORDER;
			if (!index) points += w.redirect_bad;
			return points;
		}
		if (h1 !== h2 && h2 !== h3) points -= w.alternation;
		return points;
	}

	const typingCostCache = new WeakMap();

	/**
	 * What each press and each key pair of a board costs, by the default
	 * weights of the metrics that add up over keystrokes (score_weights.json):
	 * in score points times the number of characters (bigrams for a pair),
	 * so a sum divided by that number is the points it takes. The default
	 * weights, not the user's: the way a typist types does not follow the
	 * ranking weights, and rescore() stays exact without a new analysis.
	 * finger_imbalance and hand_imbalance are not sums over keystrokes and
	 * do not take part.
	 * @param {object} board - From keyboard().
	 * @returns {{w: object, n: number, press: Float64Array, pair: Float64Array,
	 *   triple: Float64Array}}
	 */
	function typingCosts(board) {
		if (typingCostCache.has(board)) return typingCostCache.get(board);
		const w = data().weights;
		const n = board.codes.length;
		const modifierKeys = new Set(Object.values(board.modifiers));
		const press = new Float64Array(n);
		for (let k = 0; k < n; k++) {
			const f = board.finger[k];
			press[k] = w.distance * board.reach[k];
			if (f === LEFT_THUMB || f === RIGHT_THUMB) continue;
			if (f === 0 || f === 9) press[k] += 100 * w.pinky_load;
			if (board.outer[k]) press[k] += 100 * w.outer_column;
			if (!modifierKeys.has(k) && board.relRow[k] === 0) press[k] -= 100 * w.home_row;
		}
		const pair = new Float64Array(n * n);
		for (let k1 = 0; k1 < n; k1++)
			for (let k2 = 0; k2 < n; k2++) pair[k1 * n + k2] = 100 * bigramPoints(board, w, k1, k2);
		// trigramPoints by the same weights, k1 k2 k3 at (k1 * n + k2) * n + k3,
		// each worked out the first time it is read (NaN until then).
		const triple = new Float64Array(n * n * n).fill(Number.NaN);
		const costs = { w, n, press, pair, triple };
		typingCostCache.set(board, costs);
		return costs;
	}

	/**
	 * Rewrites character tables into token tables where each chosen
	 * two-character output (a chord) is one token: its occurrences leave the
	 * counts of its two characters and become its own. A statistic that needs
	 * a fourth character (a chord beside another split token) completes the
	 * trigram table as a second-order Markov chain:
	 * P(w | a, b) = tri(w, a, b) / bi(a, b).
	 * @param {object} table - From prepareNgrams().
	 * @param {string[]} chords - Two-character outputs; no character ends one
	 *   and starts another, and none repeats its character.
	 * @returns {object} A prepared table whose tokens are characters or chords.
	 */
	function tokenTable(table, chords) {
		const key = chords.join(TOKEN_SEP);
		const cached = tokenTableCache.get(table);
		if (cached && cached.has(key)) return cached.get(key);
		const out = buildTokenTable(table, chords);
		(cached || tokenTableCache.set(table, new Map()).get(table)).set(key, out);
		return out;
	}

	const tokenTableCache = new WeakMap();

	/** tokenTable's work, uncached. */
	function buildTokenTable(table, chords) {
		const maps = ngramMaps(table);
		const bi = (a, b) => maps.bi.get(a + TOKEN_SEP + b) || 0;
		const tri = (a, b, c) => maps.tri.get(a + TOKEN_SEP + b + TOKEN_SEP + c) || 0;
		const chordSet = new Set();
		const startOf = new Map();
		const endOf = new Map();
		for (const chord of chords) {
			const [x, y] = textPoints(chord);
			chordSet.add(x + TOKEN_SEP + y);
			(startOf.get(x) || startOf.set(x, []).get(x)).push(y);
			(endOf.get(y) || endOf.set(y, []).get(y)).push(x);
		}
		// The token a ends when b follows: a chord w+a for the share of the
		// pairs preceded by w, a itself for the rest.
		const leftSplit = (a, b) => {
			const ws = endOf.get(a);
			const total = bi(a, b);
			if (!ws || !(total > 0)) return [[a, 1]];
			const out = [];
			let rest = total;
			for (const w of ws) {
				const m = Math.min(rest, tri(w, a, b));
				if (m > 0) out.push([w + a, m / total]);
				rest -= m;
			}
			if (rest > 0) out.push([a, rest / total]);
			return out;
		};
		// The token b starts after a: a chord b+y for the share followed by y.
		const rightSplit = (a, b) => {
			const ys = startOf.get(b);
			const total = bi(a, b);
			if (!ys || !(total > 0)) return [[b, 1]];
			const out = [];
			let rest = total;
			for (const y of ys) {
				const m = Math.min(rest, tri(a, b, y));
				if (m > 0) out.push([b + y, m / total]);
				rest -= m;
			}
			if (rest > 0) out.push([b, rest / total]);
			return out;
		};
		// Each source n-gram gives distinct token n-grams (a chord token names
		// the characters it joins), so entries are pushed, never merged; an
		// n-gram no chord touches keeps its own entry.
		const uni = [];
		const biOut = [];
		const triOut = [];
		const push = (out, tokens, n) => {
			if (n > 0) out.push(tokens.concat([n]));
		};
		for (const entry of table.uni) {
			const [c, n] = entry;
			if (!startOf.has(c) && !endOf.has(c)) {
				uni.push(entry);
				continue;
			}
			let rest = n;
			for (const y of startOf.get(c) || []) rest -= bi(c, y);
			for (const w of endOf.get(c) || []) rest -= bi(w, c);
			push(uni, [c], Math.max(0, rest));
		}
		for (const chord of chords) {
			const [x, y] = textPoints(chord);
			push(uni, [chord], bi(x, y));
		}
		for (const entry of table.bi) {
			const [a, b, n] = entry;
			if (!endOf.has(a) && !startOf.has(b) && !startOf.has(a)) {
				biOut.push(entry);
				continue;
			}
			if (chordSet.has(a + TOKEN_SEP + b)) continue;
			for (const [ta, pa] of leftSplit(a, b))
				for (const [tb, pb] of rightSplit(a, b)) push(biOut, [ta, tb], n * pa * pb);
		}
		const before = new Map();
		const after = new Map();
		for (const entry of table.tri) {
			const [a, b, c, n] = entry;
			if (!startOf.has(a) && !startOf.has(b) && !endOf.has(a) && !startOf.has(c)) {
				triOut.push(entry);
				continue;
			}
			const ab = a + TOKEN_SEP + b;
			const bc = b + TOKEN_SEP + c;
			if (chordSet.has(bc)) (before.get(bc) || before.set(bc, []).get(bc)).push([a, n]);
			if (chordSet.has(ab)) (after.get(ab) || after.set(ab, []).get(ab)).push([c, n]);
			if (chordSet.has(ab) || chordSet.has(bc)) continue;
			for (const [ta, pa] of leftSplit(a, b))
				for (const [tc, pc] of rightSplit(b, c)) push(triOut, [ta, b, tc], n * pa * pc);
		}
		// A chord in the middle: w before it and c after it, joined through it.
		for (const chord of chords) {
			const [x, y] = textPoints(chord);
			const key = x + TOKEN_SEP + y;
			const total = bi(x, y);
			if (!(total > 0)) continue;
			for (const [w, nw] of before.get(key) || [])
				for (const [c, nc] of after.get(key) || [])
					for (const [tw, pw] of leftSplit(w, x))
						for (const [tc, pc] of rightSplit(y, c))
							push(triOut, [tw, chord, tc], ((nw * nc) / total) * pw * pc);
		}
		return { prepared: true, uni, bi: biOut, tri: triOut, totalChars: table.totalChars };
	}

	/**
	 * How a layout types a corpus: which multi-character outputs replace
	 * their characters' taps, and, for each character with several ways, the
	 * way it is typed in each context.
	 *
	 * 1. Chords: a two-character output replaces the two taps of its bigram
	 *    when it costs less than them (each way's own cost plus the pair
	 *    between the taps); outputs that would overlap keep the one that saves
	 *    the most. Longer outputs count in distinct_chars only.
	 * 2. Context: a character with several ways is typed, at each occurrence,
	 *    the way that costs least with its neighbours: its own presses, the key
	 *    pairs and triples it forms with the characters before and after it
	 *    (typed their cheapest way), and the skipgram triples with the
	 *    characters two places away, weighted by how often each follows in the
	 *    corpus. A tie keeps the cheaper way out of context, so a layout with
	 *    one way per character is typed exactly as before.
	 * @param {object} compiled - From compileWays().
	 * @param {object} board - From keyboard().
	 * @param {object} charTable - From prepareNgrams().
	 * @param {boolean} fixed - Type every character its cheapest way out of
	 *   context, with no chord (the fixed path the best one is compared with).
	 * @param {object} [previous] - The plan of a layout a few keys away on the
	 *   same table (scoreSession): when both have the same chords and
	 *   multi-way tokens, only the choices whose context holds a token whose
	 *   ways changed are made again, and the plan records what changed
	 *   (plan.changed) for an incremental walk. The result is the plan made
	 *   from nothing, to the last bit.
	 * @returns {object} {table, ways, best, multi, chords, choose, uniDist,
	 *   leftDist, rightDist, pickAt, parts, before, after, changed?}.
	 */
	function planTyping(compiled, board, charTable, fixed, previous) {
		const plan = {
			table: charTable,
			ways: compiled.ways,
			best: compiled.best,
			multi: new Set(),
			chords: []
		};
		if (fixed) return plan;
		const charMaps = ngramMaps(charTable);
		const base = typingCosts(board);
		const w = base.w;
		const nc = charTable.totalChars;
		const rb = charMaps.bigrams > 0 ? nc / charMaps.bigrams : 0;
		const rt = charMaps.trigrams > 0 ? nc / charMaps.trigrams : 0;
		const pair = (k1, k2) => base.pair[k1 * base.n + k2] * rb;
		const tri = (k1, k2, k3) => {
			const at = (k1 * base.n + k2) * base.n + k3;
			let points = base.triple[at];
			if (Number.isNaN(points)) points = base.triple[at] = trigramPoints(board, w, k1, k2, k3);
			return 100 * rt * points;
		};
		const first = (way) => way.keys[0];
		const last = (way) => way.keys[way.keys.length - 1];
		const unitMemo = new Map();
		// A way's own cost: its presses (held modifiers included), the pairs
		// and triples inside it, and the per-character metrics it adds to.
		const unit = (way) => {
			let cost = unitMemo.get(way);
			if (cost !== undefined) return cost;
			const keys = way.keys;
			const width = way.width || 1;
			cost = 0;
			for (const k of keys) cost += base.press[k];
			if (way.shift > 0) cost += way.shift * base.press[shiftKeyFor(board, last(way))];
			if (way.altgr > 0) cost += way.altgr * base.press[board.modifiers.altgr];
			for (let i = 0; i + 1 < keys.length; i++) cost += pair(keys[i], keys[i + 1]);
			for (let i = 0; i + 2 < keys.length; i++) cost += tri(keys[i], keys[i + 1], keys[i + 2]);
			if (way.shift + way.altgr > 0) cost += 100 * w.modifier_usage * width;
			if (way.dead) cost += 100 * w.dead_key_usage * width;
			unitMemo.set(way, cost);
			return cost;
		};
		// The key pair and triples that start in way a and end in way b
		// (walkKeyStream's bigram step).
		const cross = (a, b) => {
			const ka = a.keys;
			const kb = b.keys;
			const la = ka.length;
			const length = la + kb.length;
			const at = (j) => (j < la ? ka[j] : kb[j - la]);
			let cost = pair(ka[la - 1], kb[0]);
			for (let i = Math.max(0, la - 2); i < la; i++)
				if (i + 2 < length) cost += tri(at(i), at(i + 1), at(i + 2));
			return cost;
		};

		// 1. Chords.
		const candidates = [];
		for (const [text, list] of compiled.texts) {
			const parts = textPoints(text);
			if (parts.length !== 2 || parts[0] === parts[1]) continue;
			const n = charMaps.bi.get(parts[0] + TOKEN_SEP + parts[1]);
			if (!n) continue;
			const a = compiled.ways.get(parts[0]);
			const b = compiled.ways.get(parts[1]);
			const taps = a && b ? unit(a[0]) + unit(b[0]) + cross(a[0], b[0]) : INFINITY;
			const chord = unit(list[0]);
			if (chord < taps)
				candidates.push({
					text,
					x: parts[0],
					y: parts[1],
					gain: taps === INFINITY ? INFINITY : (taps - chord) * n
				});
		}
		candidates.sort((p, q) =>
			p.gain !== q.gain
				? q.gain > p.gain
					? 1
					: -1
				: p.text < q.text
					? -1
					: p.text > q.text
						? 1
						: 0
		);
		const starts = new Set();
		const ends = new Set();
		for (const candidate of candidates) {
			if (ends.has(candidate.x) || starts.has(candidate.y)) continue;
			plan.chords.push(candidate.text);
			starts.add(candidate.x);
			ends.add(candidate.y);
		}
		if (plan.chords.length) {
			plan.table = tokenTable(charTable, plan.chords);
			plan.ways = new Map(compiled.ways);
			plan.best = new Map(compiled.best);
			for (const chord of plan.chords) {
				plan.ways.set(chord, compiled.texts.get(chord));
				plan.best.set(chord, compiled.texts.get(chord)[0]);
			}
		}
		// The alternatives: a dead key closed by a thumb key is not one. The
		// pair metrics leave thumb keys out, so such a way would hide an SFB
		// behind an extra press no typist makes; it stays the way of a
		// character that has no other, and the fixed path keeps its choice.
		const { table } = plan;
		for (const [token] of table.uni) {
			const list = plan.ways.get(token);
			if (!list || list.length < 2) continue;
			const kept = list.filter((way, i) => i === 0 || !way.terminated);
			if (kept.length === list.length) continue;
			if (plan.ways === compiled.ways) plan.ways = new Map(compiled.ways);
			plan.ways.set(token, kept);
		}
		const { ways, multi } = plan;

		// 2. Context.
		for (const [token] of table.uni) {
			const list = ways.get(token);
			if (list && list.length > 1) multi.add(token);
		}
		if (multi.size === 0) return plan;
		const maps = ngramMaps(table);
		// Multi-way tokens are rare: the passes below read only the n-grams
		// that hold one, and the walk takes the others the fast way.
		const parts = partition(table, multi);
		plan.parts = parts;
		const index = contextIndex(table, parts, multi);
		// From a previous plan on the same tokens and multi-way set (a search's
		// last layout), only what a token whose ways changed can reach is
		// decided again; everything is computed by the same code, in the same
		// order, as from nothing, so the plan is the same to the last bit.
		const prev =
			previous && previous.parts === parts && previous.table === table && previous.pickAt
				? previous
				: null;
		const dirty = new Set();
		if (prev)
			for (const [token] of table.uni)
				if (!sameWays(prev.ways.get(token), ways.get(token))) dirty.add(token);
		// The last key of the token two places before a multi-way token, and the
		// first key of the one two places after, with their counts.
		const before = prev ? new Map(prev.before) : new Map();
		const after = prev ? new Map(prev.after) : new Map();
		const tally = (map, key, k, n) => {
			const counts = map.get(key) || map.set(key, new Map()).get(key);
			counts.set(k, (counts.get(k) || 0) + n);
		};
		// One trigram entry's part of before (side 'B'), after ('A') or both.
		const tallyEntry = (i, side) => {
			const [x, y, z, n] = parts.touchTri[i];
			if (!multi.has(z) && !multi.has(x)) return;
			const wx = ways.get(x);
			const wy = ways.get(y);
			const wz = ways.get(z);
			if (!wx || !wy || !wz || wy[0].keys.length !== 1) return;
			if (side !== 'A' && multi.has(z)) tally(before, y + TOKEN_SEP + z, last(wx[0]), n);
			if (side !== 'B' && multi.has(x)) tally(after, x + TOKEN_SEP + y, first(wz[0]), n);
		};
		// The entries that hold a token whose ways changed, and the before and
		// after keys they feed: those keys are tallied again, in table order.
		const touched = new Set();
		const dirtyBefore = new Set();
		const dirtyAfter = new Set();
		if (prev) {
			for (const token of dirty) for (const i of index.triOf.get(token) || []) touched.add(i);
			for (const i of touched) {
				const [x, y, z] = parts.touchTri[i];
				if (multi.has(z)) dirtyBefore.add(y + TOKEN_SEP + z);
				if (multi.has(x)) dirtyAfter.add(x + TOKEN_SEP + y);
			}
			for (const key of dirtyBefore) {
				before.delete(key);
				for (const i of index.byLast.get(key) || []) tallyEntry(i, 'B');
			}
			for (const key of dirtyAfter) {
				after.delete(key);
				for (const i of index.byFirst.get(key) || []) tallyEntry(i, 'A');
			}
		} else for (let i = 0; i < parts.touchTri.length; i++) tallyEntry(i, null);
		plan.before = before;
		plan.after = after;
		// Each way's own cost, and per pair its cost beside the token before it
		// (the key pair and triples across, and the skipgrams with the token
		// before that, per occurrence of the pair) or after it: every term of
		// the choice but the triple across both neighbours, computed once.
		const unitMemo2 = new Map();
		const units = (b) => {
			let out = unitMemo2.get(b);
			if (!out) unitMemo2.set(b, (out = Float64Array.from(ways.get(b), unit)));
			return out;
		};
		const sideMemo = new Map();
		const leftCosts = (a, b) => {
			const key = a + TOKEN_SEP + b;
			let out = sideMemo.get('L' + key);
			if (out) return out;
			const list = ways.get(b);
			const wa = ways.get(a)[0];
			const counts = wa.keys.length === 1 ? before.get(key) : undefined;
			const total = maps.bi.get(key);
			out = Float64Array.from(list, (way) => {
				let cost = cross(wa, way);
				if (counts && total > 0) {
					let sum = 0;
					for (const [k, n] of counts) sum += n * tri(k, wa.keys[0], first(way));
					cost += sum / total;
				}
				return cost;
			});
			sideMemo.set('L' + key, out);
			return out;
		};
		const rightCosts = (b, c) => {
			const key = b + TOKEN_SEP + c;
			let out = sideMemo.get('R' + key);
			if (out) return out;
			const list = ways.get(b);
			const wc = ways.get(c)[0];
			const counts = wc.keys.length === 1 ? after.get(key) : undefined;
			const total = maps.bi.get(key);
			out = Float64Array.from(list, (way) => {
				let cost = cross(way, wc);
				if (counts && total > 0) {
					let sum = 0;
					for (const [k, n] of counts) sum += n * tri(last(way), wc.keys[0], k);
					cost += sum / total;
				}
				return cost;
			});
			sideMemo.set('R' + key, out);
			return out;
		};
		const choose = (a, b, c) => {
			const list = ways.get(b);
			const own = units(b);
			const left = a === null ? null : leftCosts(a, b);
			const right = c === null ? null : rightCosts(b, c);
			const wa = a === null ? null : ways.get(a)[0];
			const wc = c === null ? null : ways.get(c)[0];
			let pick = 0;
			let lowest = INFINITY;
			for (let i = 0; i < list.length; i++) {
				let cost = own[i];
				if (left) cost += left[i];
				if (right) cost += right[i];
				if (wa && wc && list[i].keys.length === 1)
					cost += tri(last(wa), list[i].keys[0], first(wc));
				// A tie (within rounding) keeps the earlier, cheaper-alone way.
				if (i === 0 || cost < lowest - 1e-9 * Math.max(1, Math.abs(lowest))) {
					lowest = cost;
					pick = i;
				}
			}
			return pick;
		};
		plan.choose = choose;

		// 3. How often each way is used: for every occurrence of a multi-way
		// token, its context is the trigram it is the middle of; at a segment
		// edge, the bigram it ends or starts; alone, nothing. leftDist holds the
		// ways of a in the pairs a b, rightDist those of b in the pairs a b;
		// pickAt the way of the middle token of each touchTri entry (-1 when the
		// middle has one way); edges the way and count of a multi-way token at
		// the edge of each touchBi entry (way -1: none), on its right ('R', the
		// second token) and left ('L', the first) side.
		const known = (token) => (ways.has(token) ? token : null);
		const sum = (v) => v.reduce((s, x) => s + x, 0);
		const size = parts.touchBi.length;
		const pickAt = prev ? prev.pickAt.slice() : new Int32Array(parts.touchTri.length).fill(-1);
		const edges = prev
			? {
					R: prev.edges.R.slice(),
					RN: prev.edges.RN.slice(),
					L: prev.edges.L.slice(),
					LN: prev.edges.LN.slice()
				}
			: {
					R: new Int32Array(size).fill(-1),
					RN: new Float64Array(size),
					L: new Int32Array(size).fill(-1),
					LN: new Float64Array(size)
				};
		const pickEntry = (i) => {
			const [a, b, c] = parts.touchTri[i];
			pickAt[i] = multi.has(b) ? choose(known(a), b, known(c)) : -1;
		};
		// A pick reads its pair's before tally and its pair's after tally.
		const repick = new Set(touched);
		for (const key of dirtyBefore) for (const i of index.byFirst.get(key) || []) repick.add(i);
		for (const key of dirtyAfter) for (const i of index.byLast.get(key) || []) repick.add(i);
		// The entries whose middle is typed otherwise, or whose tokens' ways changed.
		const moved = new Set(touched);
		if (prev)
			for (const i of repick) {
				const was = pickAt[i];
				pickEntry(i);
				if (pickAt[i] !== was) moved.add(i);
			}
		else for (let i = 0; i < parts.touchTri.length; i++) pickEntry(i);
		plan.pickAt = pickAt;
		plan.edges = edges;

		// The trigram part of a pair's distribution, in table order: the
		// middles of the entries starting with the pair (side 'R', the ways of
		// its second token) or ending with it (side 'L', its first token's).
		const triPart = (side, key) => {
			const list = side === 'R' ? index.byFirst.get(key) : index.byLast.get(key);
			let v = null;
			for (const i of list || []) {
				const entry = parts.touchTri[i];
				const b = entry[1];
				if (!multi.has(b)) continue;
				v = v || new Float64Array(ways.get(b).length);
				v[pickAt[i]] += entry[3];
			}
			return v;
		};
		// A pair's whole distribution: its trigram part, then, for the bigram of
		// a multi-way token, the way it takes at a segment edge for the bigram's
		// count less its trigram part (recorded in edges).
		const pairDist = (side, key) => {
			const i = index.biAt.get(key);
			if (i === undefined) return triPart(side, key);
			const [a, b, n] = parts.touchBi[i];
			const token = side === 'R' ? b : a;
			if (!multi.has(token)) return triPart(side, key);
			const v = triPart(side, key) || new Float64Array(ways.get(token).length);
			const rest = n - sum(v);
			let o = -1;
			if (rest > 0) {
				o = side === 'R' ? choose(known(a), b, null) : choose(null, a, known(b));
				v[o] += rest;
			}
			edges[side][i] = o;
			edges[side + 'N'][i] = rest > 0 ? rest : 0;
			return v;
		};
		// A token's distribution: its middles in table order, its bigram edges
		// in table order, then its occurrences alone.
		const tokenDist = (token) => {
			const v = new Float64Array(ways.get(token).length);
			for (const i of index.middleOf.get(token) || []) v[pickAt[i]] += parts.touchTri[i][3];
			for (const i of index.biOf.get(token) || []) {
				const [a, b] = parts.touchBi[i];
				if (b === token && edges.R[i] >= 0) v[edges.R[i]] += edges.RN[i];
				if (a === token && edges.L[i] >= 0) v[edges.L[i]] += edges.LN[i];
			}
			const n = index.uniCount.get(token) || 0;
			const rest = n - sum(v);
			if (rest > 0) v[choose(null, token, null)] += rest;
			return v;
		};
		const sameVector = (x, y) => {
			if (x === y) return true;
			if (!x || !y || x.length !== y.length) return false;
			for (let i = 0; i < x.length; i++) if (x[i] !== y[i]) return false;
			return true;
		};
		const uniDist = prev ? new Map(prev.uniDist) : new Map();
		const leftDist = prev ? new Map(prev.leftDist) : new Map();
		const rightDist = prev ? new Map(prev.rightDist) : new Map();
		const set = (map, key, v) => {
			if (v) map.set(key, v);
			else map.delete(key);
		};
		if (prev) {
			// The pairs whose distribution a moved middle or an edge choice may
			// change: those pairs are summed again; a token whose middles, edges
			// or own ways changed is summed again.
			const rightKeys = new Set();
			const leftKeys = new Set();
			const tokens = new Set();
			for (const i of moved) {
				const [a, b, c] = parts.touchTri[i];
				if (!multi.has(b)) continue;
				rightKeys.add(a + TOKEN_SEP + b);
				leftKeys.add(b + TOKEN_SEP + c);
				tokens.add(b);
			}
			for (const token of dirty) {
				if (multi.has(token)) tokens.add(token);
				for (const i of index.biOf.get(token) || []) {
					const [a, b] = parts.touchBi[i];
					rightKeys.add(a + TOKEN_SEP + b);
					leftKeys.add(a + TOKEN_SEP + b);
				}
			}
			for (const key of dirtyBefore) rightKeys.add(key);
			for (const key of dirtyAfter) leftKeys.add(key);
			const changedRight = new Set();
			const changedLeft = new Set();
			const redo = (side, keys, map, changed) => {
				for (const key of keys) {
					const i = index.biAt.get(key);
					const was = i === undefined ? -1 : edges[side][i];
					const wasN = i === undefined ? 0 : edges[side + 'N'][i];
					const v = pairDist(side, key);
					if (!sameVector(v, map.get(key))) {
						changed.add(key);
						set(map, key, v);
					}
					if (i !== undefined && (edges[side][i] !== was || edges[side + 'N'][i] !== wasN))
						tokens.add(parts.touchBi[i][side === 'R' ? 1 : 0]);
				}
			};
			redo('R', rightKeys, rightDist, changedRight);
			redo('L', leftKeys, leftDist, changedLeft);
			const changedTokens = new Set();
			for (const token of tokens) {
				const v = tokenDist(token);
				if (sameVector(v, uniDist.get(token))) continue;
				uniDist.set(token, v);
				changedTokens.add(token);
			}
			plan.changed = {
				dirty,
				picks: moved,
				rightKeys: changedRight,
				leftKeys: changedLeft,
				tokens: changedTokens
			};
			// The normalised shares of the unchanged pairs are the previous plan's.
			plan.shareBase = prev.shareBase || (prev.shareBase = new Map());
			plan.shareLocal = new Map();
			plan.shareOwn = new Set();
			for (const key of changedRight) plan.shareOwn.add('R' + key);
			for (const key of changedLeft) plan.shareOwn.add('L' + key);
		} else {
			for (const key of index.byFirst.keys()) set(rightDist, key, pairDist('R', key));
			for (const key of index.byLast.keys()) set(leftDist, key, pairDist('L', key));
			for (const [key, i] of index.biAt) {
				const [a, b] = parts.touchBi[i];
				if (multi.has(b) && !index.byFirst.has(key)) set(rightDist, key, pairDist('R', key));
				if (multi.has(a) && !index.byLast.has(key)) set(leftDist, key, pairDist('L', key));
			}
			for (const token of multi) uniDist.set(token, tokenDist(token));
		}
		Object.assign(plan, { uniDist, leftDist, rightDist });
		return plan;
	}

	const contextIndexCache = new WeakMap();

	/**
	 * Where each token and pair sits among a partition's context n-grams, for
	 * planTyping and the score session: touchTri indexes by token (any
	 * place), by middle token, by first pair and by last pair; touchBi
	 * indexes by token and by pair; the uni counts. Every list is in table
	 * order. Cached per partition.
	 * @param {object} table - The token table.
	 * @param {object} parts - From partition().
	 * @param {Set<string>} multi - The multi-way tokens.
	 * @returns {object} {triOf, middleOf, byFirst, byLast, biOf, biAt, uniCount,
	 *   uniAt, restBiOf, restTriOf}.
	 */
	function contextIndex(table, parts, multi) {
		if (contextIndexCache.has(parts)) return contextIndexCache.get(parts);
		const push = (map, key, i) => (map.get(key) || map.set(key, []).get(key)).push(i);
		const out = {
			triOf: new Map(),
			middleOf: new Map(),
			byFirst: new Map(),
			byLast: new Map(),
			biOf: new Map(),
			biAt: new Map(),
			uniCount: new Map(),
			uniAt: new Map(),
			restBiOf: new Map(),
			restTriOf: new Map()
		};
		parts.touchTri.forEach(([a, b, c], i) => {
			for (const token of new Set([a, b, c])) push(out.triOf, token, i);
			if (multi.has(b)) push(out.middleOf, b, i);
			push(out.byFirst, a + TOKEN_SEP + b, i);
			push(out.byLast, b + TOKEN_SEP + c, i);
		});
		parts.touchBi.forEach(([a, b], i) => {
			for (const token of new Set([a, b])) push(out.biOf, token, i);
			out.biAt.set(a + TOKEN_SEP + b, i);
		});
		table.uni.forEach(([token, n], i) => {
			out.uniCount.set(token, (out.uniCount.get(token) || 0) + n);
			push(out.uniAt, token, i);
		});
		parts.restBi.forEach(([a, b], i) => {
			for (const token of new Set([a, b])) push(out.restBiOf, token, i);
		});
		parts.restTri.forEach(([a, b, c], i) => {
			for (const token of new Set([a, b, c])) push(out.restTriOf, token, i);
		});
		contextIndexCache.set(parts, out);
		return out;
	}

	const partitionCache = new WeakMap();
	// Partitions kept per table: the multi-way sets of the layouts compared.
	const PARTITIONS_PER_TABLE = 64;

	/**
	 * The n-grams of a table split by whether they hold a multi-way token:
	 * touchBi, touchTri go through the context choice, restBi, restTri are
	 * typed the fast way. Cached per table and set of multi-way tokens.
	 * @param {object} table - A prepared (token) table.
	 * @param {Set<string>} multi - The multi-way tokens.
	 * @returns {{touchBi: Array, touchTri: Array, restBi: Array, restTri: Array,
	 *   restBiAt: Int32Array, restTriAt: Int32Array}} restBiAt, restTriAt: the
	 *   rest's entry indexes in the table.
	 */
	function partition(table, multi) {
		const key = Array.from(multi).sort().join(TOKEN_SEP);
		let byKey = partitionCache.get(table);
		if (!byKey) partitionCache.set(table, (byKey = new Map()));
		let out = byKey.get(key);
		if (out) return out;
		out = { touchBi: [], restBi: [], touchTri: [], restTri: [] };
		for (const entry of table.bi)
			(multi.has(entry[0]) || multi.has(entry[1]) ? out.touchBi : out.restBi).push(entry);
		for (const entry of table.tri)
			(multi.has(entry[0]) || multi.has(entry[1]) || multi.has(entry[2])
				? out.touchTri
				: out.restTri
			).push(entry);
		// The rest again as entry indexes of the table, for walkRest.
		const t = tableIds(table);
		const many = new Uint8Array(t.tokens.length);
		t.tokens.forEach((token, i) => {
			if (multi.has(token)) many[i] = 1;
		});
		const restBiAt = [];
		const restTriAt = [];
		for (let i = 0; i < t.biN.length; i++) if (!many[t.biA[i]] && !many[t.biB[i]]) restBiAt.push(i);
		for (let i = 0; i < t.triN.length; i++)
			if (!many[t.triA[i]] && !many[t.triB[i]] && !many[t.triC[i]]) restTriAt.push(i);
		out.restBiAt = Int32Array.from(restBiAt);
		out.restTriAt = Int32Array.from(restTriAt);
		if (byKey.size >= PARTITIONS_PER_TABLE) byKey.clear();
		byKey.set(key, out);
		return out;
	}

	/**
	 * Walks the key stream of a typing plan: walkKeyStream with each
	 * multi-way token split over its ways as the plan types them. A pair of
	 * two multi-way tokens, or a triple whose first or last token has several
	 * ways, needs a fourth character: it is completed as a second-order Markov
	 * chain of the trigrams (each side's share of ways, independent given the
	 * pair or triple).
	 * @param {object} board - From keyboard().
	 * @param {object} plan - From planTyping().
	 * @param {object} visit - As walkKeyStream.
	 */
	function walkTyped(board, plan, visit) {
		const { table, multi } = plan;
		if (multi.size === 0) {
			walkKeyStream(board, plan.best, table, visit);
			return;
		}
		for (const [token, n] of table.uni) walkTypedToken(board, plan, token, n, 1, visit);
		const { restBiAt, restTriAt, touchBi, touchTri } = plan.parts;
		const t = tableIds(table);
		const seqs = t.tokens.map((token) => plan.best.get(token));
		walkRest(board, t, seqs, restBiAt, restTriAt, visit);
		for (let i = 0; i < touchBi.length; i++) walkTypedPair(plan, i, 1, visit);
		for (let i = 0; i < touchTri.length; i++) walkTypedTriple(plan, i, 1, visit);
	}

	/**
	 * One token typed n times, its count times sign (-1 takes it out): alone,
	 * or split over its ways as the plan uses them (its distribution sums to n).
	 */
	function walkTypedToken(board, plan, token, n, sign, visit) {
		const list = plan.ways.get(token);
		if (!list) {
			visit.unsupported(token, sign * n);
			return;
		}
		if (!plan.multi.has(token)) {
			walkChar(board, list[0], token, sign * n, visit);
			return;
		}
		const dist = plan.uniDist.get(token);
		list.forEach((seq, i) => {
			if (dist[i] > 0) walkChar(board, seq, token, sign * dist[i], visit);
		});
	}

	const ONE_SHARE = [1];

	/**
	 * A multi-way token's shares of its ways in one pair, normalised once. A
	 * plan made from a previous one (planTyping's previous) shares its cache
	 * for every pair whose distribution did not change, and keeps its own for
	 * the others until adoptPlan() writes them into the shared one.
	 */
	function planShares(plan, side, a, b) {
		const key = side + a + TOKEN_SEP + b;
		if (!plan.shareBase) plan.shareBase = new Map();
		const own = plan.shareOwn && plan.shareOwn.has(key);
		const cache = own ? plan.shareLocal : plan.shareBase;
		let out = cache.get(key);
		if (out) return out;
		const v = (side === 'L' ? plan.leftDist : plan.rightDist).get(a + TOKEN_SEP + b);
		const total = v ? v.reduce((s, x) => s + x, 0) : 0;
		out = total > 0 ? Array.from(v, (x) => x / total) : ONE_SHARE;
		cache.set(key, out);
		return out;
	}

	/**
	 * Makes a plan made from a previous one the current one of its lineage:
	 * its own shares go into the shared cache (the previous plan's are stale).
	 * @param {object} plan - From planTyping() with a previous plan.
	 */
	function adoptPlan(plan) {
		if (!plan.shareOwn) return;
		for (const key of plan.shareOwn) {
			if (plan.shareLocal.has(key)) plan.shareBase.set(key, plan.shareLocal.get(key));
			else plan.shareBase.delete(key);
		}
		plan.shareOwn = null;
		plan.shareLocal = null;
	}

	/** touchBi entry i of a plan, its count times sign (-1 takes it out). */
	function walkTypedPair(plan, i, sign, visit) {
		const { ways, multi } = plan;
		const [a, b, n] = plan.parts.touchBi[i];
		const la = ways.get(a);
		const lb = ways.get(b);
		if (!la || !lb) return;
		const pa = multi.has(a) ? planShares(plan, 'L', a, b) : ONE_SHARE;
		const pb = multi.has(b) ? planShares(plan, 'R', a, b) : ONE_SHARE;
		for (let x = 0; x < pa.length; x++) {
			if (!(pa[x] > 0)) continue;
			for (let y = 0; y < pb.length; y++)
				if (pb[y] > 0) walkPair(la[x], lb[y], sign * n * pa[x] * pb[y], visit);
		}
	}

	/** touchTri entry i of a plan, its count times sign (-1 takes it out). */
	function walkTypedTriple(plan, i, sign, visit) {
		const { ways, multi } = plan;
		const [a, b, d, n] = plan.parts.touchTri[i];
		const lb = ways.get(b);
		if (!lb) return;
		const la = ways.get(a);
		const ld = ways.get(d);
		if (!la || !ld) return;
		const sb = multi.has(b) ? lb[plan.pickAt[i]] : lb[0];
		const pa = multi.has(a) ? planShares(plan, 'L', a, b) : ONE_SHARE;
		const pd = multi.has(d) ? planShares(plan, 'R', b, d) : ONE_SHARE;
		for (let x = 0; x < pa.length; x++) {
			if (!(pa[x] > 0)) continue;
			for (let y = 0; y < pd.length; y++)
				if (pd[y] > 0) walkTriple(la[x], sb, ld[y], sign * n * pa[x] * pd[y], visit);
		}
	}

	/**
	 * What the plan reports: each multi-way character's ways with how often
	 * each was used, and the chords with their counts.
	 * @param {object} board - From keyboard().
	 * @param {object} plan - From planTyping().
	 * @returns {{paths: object, chords: object, changed: number}} paths: char →
	 *   [{kind, steps: [[code, level]], count}] best way first; chords: text →
	 *   count; changed: characters typed otherwise than their cheapest way out
	 *   of context (chord characters included).
	 */
	function typingReport(board, plan) {
		const kind = (way) => {
			if (way.substituted) return 'substitution';
			if (way.width) return 'chord';
			if (way.dead) return 'dead';
			if (way.altgr > 0) return 'altgr';
			return way.shift > 0 ? 'shift' : 'direct';
		};
		const describe = (way, count) => ({
			kind: kind(way),
			steps: way.keys.map((k, i) => [board.codes[k], LAYER_IDS[way.layers[i]]]),
			count
		});
		const paths = {};
		let changed = 0;
		for (const token of plan.multi) {
			const dist = plan.uniDist.get(token);
			const list = plan.ways.get(token);
			if (!dist) continue;
			paths[token] = list
				.map((way, i) => describe(way, dist[i]))
				.filter((entry) => entry.count > 0);
			// A chord's characters all count as changed below.
			if (!plan.chords.includes(token)) changed += dist.reduce((s, x) => s + x, 0) - dist[0];
		}
		const chords = {};
		for (const [token, n] of plan.table.uni)
			if (plan.chords.includes(token)) {
				chords[token] = n;
				changed += codeLength(token) * n;
				if (!paths[token]) paths[token] = [describe(plan.ways.get(token)[0], n)];
			}
		return { paths, chords, changed };
	}

	// =======================
	// ======= 8/ Score ======
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

	/**
	 * The ranking order of two results: a complete layout before an incomplete
	 * one (it cannot type a required character, so no score makes it usable),
	 * then the higher score first.
	 * @param {{incomplete: boolean, score: {total: number}}} a
	 * @param {{incomplete: boolean, score: {total: number}}} b
	 * @returns {number} Negative when a ranks before b.
	 * @throws {Error} When a result does not say whether it is complete.
	 */
	function rankOrder(a, b) {
		if (typeof a.incomplete !== 'boolean' || typeof b.incomplete !== 'boolean')
			throw new Error('layout_analysis: a ranked result says whether it is complete');
		if (a.incomplete !== b.incomplete) return a.incomplete ? 1 : -1;
		return b.score.total - a.score.total;
	}

	/**
	 * Sorts results, complete layouts first and each group by score, best
	 * first, and numbers them.
	 * @param {object[]} results - analyse() outputs (may come from different
	 *   n-gram tables: the Comparer's text modes).
	 * @returns {object[]} The same results, sorted, each with its rank (1-based).
	 */
	function rank(results) {
		const sorted = results.slice().sort(rankOrder);
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
		KEY_GAINS,
		KEY_INFO_METRICS,
		KEY_METRICS,
		WORD_TABLE_SIZE,
		WORD_EFFORT_METRICS,
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
		compileWays,
		typingPlan,
		typingRows,
		metricDigits,
		keyNgrams,
		ngramsFromText,
		prepareNgrams,
		analyse,
		scoreSession,
		score,
		keyScoreCost,
		keyValues,
		keyDiff,
		standing,
		bigramMatrix,
		countWords,
		wordTable,
		wordsFromText,
		wordEfforts,
		effortDistribution,
		defaultWeights,
		defaultIdealLoad,
		idealLoad,
		defaultShortcuts,
		shortcuts,
		defaultFormFactorWeights,
		formFactorWeights,
		compare,
		rank,
		rankOrder,
		rescore,
		diff
	};
})();

// Node (tests, codegen) reads the engine through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_ANALYSIS;
