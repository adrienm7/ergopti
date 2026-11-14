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

	/**
	 * The keys of one keyboard with their finger, hand, row and position.
	 * @param {string} keyboardId - A key of model.keyboards.
	 * @returns {object} {id, codes, index: Map code → i, finger, order, hand,
	 *   row, x, y, home, lateral, outer, homeOf: finger → key index}.
	 * @throws {Error} On an unknown keyboard.
	 */
	function keyboard(keyboardId) {
		if (keyboardCache.has(keyboardId)) return keyboardCache.get(keyboardId);
		const { model, geometry } = data();
		const spec = model.keyboards[keyboardId];
		if (!spec) throw new Error(`layout_analysis: unknown keyboard ${keyboardId}`);
		const fingering = model.fingerings[spec.fingering];
		const form = spec.geometry === 'ortho' ? 'iso' : spec.geometry;
		const lateral = new Set(model.lateral_keys);
		const outer = new Set(model.outer_keys);
		const homeCodes = new Set(Object.values(model.home_keys));
		const board = {
			id: keyboardId,
			codes: [],
			index: new Map(),
			finger: [],
			order: [],
			hand: [],
			row: [],
			x: [],
			y: [],
			home: [],
			lateral: [],
			outer: []
		};
		for (const [code, fingerId] of Object.entries(fingering)) {
			const g = geometry[code] && geometry[code][form];
			if (!g) continue;
			const finger = model.fingers.indexOf(fingerId);
			if (finger < 0) throw new Error(`layout_analysis: unknown finger ${fingerId}`);
			let x = g.col + g.width / 2;
			if (spec.geometry === 'ortho') x += model.ortho_row_offsets[String(g.row)];
			board.index.set(code, board.codes.length);
			board.codes.push(code);
			board.finger.push(finger);
			board.order.push(finger < LEFT_THUMB ? finger : finger > RIGHT_THUMB ? 9 - finger : 4);
			board.hand.push(finger <= LEFT_THUMB ? 0 : 1);
			board.row.push(g.row);
			board.x.push(x);
			board.y.push(g.row);
			board.home.push(homeCodes.has(code));
			board.lateral.push(lateral.has(code));
			board.outer.push(outer.has(code));
			// A wide modifier is pressed at its end nearest the home row.
			if (Object.values(model.modifier_keys).includes(code)) {
				board.x[board.x.length - 1] =
					code === model.modifier_keys.shift_for_right_hand ? g.col + g.width - 0.5 : g.col + 0.5;
			}
		}
		board.homeOf = model.fingers.map((fingerId) => board.index.get(model.home_keys[fingerId]));
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
		keyboardCache.set(keyboardId, board);
		return board;
	}

	// =========================
	// ======= 4/ Layouts ======
	// =========================

	/**
	 * Checks and returns a layout in the library shape.
	 * @param {object} layout - {id, name, rows: code → [base, shift, altgr,
	 *   shift_altgr], dead?: state → {typed: output | {dead: state}},
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
			fingering: layout.fingering || 'standard',
			rows: layout.rows,
			command: layout.command || {},
			dead: layout.dead || {}
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
		for (const state of Object.keys(source.compositions).sort()) {
			dead[state] = {};
			for (const [typed, result] of Object.entries(source.compositions[state])) {
				if (result.output) dead[state][typed] = result.output;
				else if (result.next) dead[state][typed] = { dead: result.next };
			}
			if (source.terminators[state]) dead[state][' '] = source.terminators[state];
		}
		return layoutFromRows({ id: source.id, name: source.name, rows, command, dead });
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
		const offer = (map, key, candidate) => {
			const current = map.get(key);
			if (!current || candidate.cost < current.cost) map.set(key, candidate);
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
					if (codePoints(cell).length === 1) offer(best, cell, stroke);
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
					const tail = best.get(typed);
					if (!tail) continue;
					const candidate = join(prefix, tail, true);
					const map = typeof result === 'string' ? best : deadSeq;
					const target = typeof result === 'string' ? result : result.dead;
					if (typeof result === 'string' && codePoints(result).length !== 1) continue;
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
	function boardFor(layout, keyboardId) {
		if (keyboardId === 'iso' && layout.fingering === 'angle') return keyboard('iso_angle');
		return keyboard(keyboardId);
	}

	/**
	 * Measures one layout.
	 * @param {object} layoutInput - Library shape (see layoutFromRows).
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {{keyboard?: string, weights?: object}} [options] - Board and weights.
	 * @returns {object} {layout, keyboard, metrics, fingers, rows, coverage,
	 *   trigramClasses, score}.
	 */
	function analyse(layoutInput, ngrams, options) {
		const opts = options || {};
		const layout = layoutFromRows(layoutInput);
		const board = boardFor(layout, opts.keyboard || DEFAULT_KEYBOARD);
		const table = prepareNgrams(ngrams);
		const best = compileLayout(layout, board, null);
		const thumb = board.finger.map((f) => f === LEFT_THUMB || f === RIGHT_THUMB);
		const keyCount = new Float64Array(board.codes.length);
		const c = {
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
		const unsupportedChars = {};

		const bigram = (k1, k2, n) => {
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
				if (down >= 2) c.scissors += n;
				else if (down === 1) c.half_scissors += n;
				if (board.lateral[k1] || board.lateral[k2]) c.lsb += n;
			}
			if (o2 > o1) c.roll_in += n;
			else c.roll_out += n;
		};

		const trigram = (k1, k2, k3, n) => {
			if (thumb[k1] || thumb[k2] || thumb[k3]) return;
			c.trigrams += n;
			const f1 = board.finger[k1];
			const f2 = board.finger[k2];
			const f3 = board.finger[k3];
			if (f1 === f3 && k1 !== k3) c.sfs += n;
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
					const index = [k1, k2, k3].some((k) => board.order[k] === INDEX_ORDER);
					if (!index) c.redirect_bad += n;
				}
				return;
			}
			if (h1 !== h2 && h2 !== h3) c.alternation += n;
			else c.roll_mixed += n;
		};

		const strokesOf = (char) => best.get(char);
		const modifierKey = (k) =>
			board.hand[k] === 0 && !thumb[k]
				? board.modifiers.shiftForLeft
				: board.modifiers.shiftForRight;

		for (const [char, n] of table.uni) {
			const seq = strokesOf(char);
			if (!seq) {
				c.unsupported += n;
				unsupportedChars[char] = (unsupportedChars[char] || 0) + n;
				continue;
			}
			c.chars += n;
			if (seq.dead) c.dead += n;
			if (seq.shift + seq.altgr > 0) c.modifiers += n;
			for (const k of seq.keys) {
				keyCount[k] += n;
				c.distance += board.reach[k] * n;
			}
			// The held modifiers: Shift by the other hand's pinky, AltGr by a thumb.
			if (seq.shift > 0) {
				const m = modifierKey(seq.keys[seq.keys.length - 1]);
				keyCount[m] += n * seq.shift;
				c.distance += board.reach[m] * n * seq.shift;
			}
			if (seq.altgr > 0) {
				keyCount[board.modifiers.altgr] += n * seq.altgr;
				c.distance += board.reach[board.modifiers.altgr] * n * seq.altgr;
			}
			const keys = seq.keys;
			for (let i = 0; i + 1 < keys.length; i++) bigram(keys[i], keys[i + 1], n);
			for (let i = 0; i + 2 < keys.length; i++) trigram(keys[i], keys[i + 1], keys[i + 2], n);
		}
		for (const [a, b, n] of table.bi) {
			const sa = strokesOf(a);
			const sb = strokesOf(b);
			if (!sa || !sb) continue;
			const ka = sa.keys;
			const kb = sb.keys;
			bigram(ka[ka.length - 1], kb[0], n);
			// Key trigrams that start in a and end in b.
			const s = ka.concat(kb);
			for (let i = Math.max(0, ka.length - 2); i < ka.length; i++)
				if (i + 2 >= ka.length && i + 2 < s.length) trigram(s[i], s[i + 1], s[i + 2], n);
		}
		for (const [a, b, d, n] of table.tri) {
			const sb = strokesOf(b);
			if (!sb || sb.keys.length !== 1) continue;
			const sa = strokesOf(a);
			const sd = strokesOf(d);
			if (!sa || !sd) continue;
			trigram(sa.keys[sa.keys.length - 1], sb.keys[0], sd.keys[0], n);
		}

		const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
		const allChars = c.chars + c.unsupported;
		// Finger load over every press but the thumbs'.
		const fingerIds = data().model.fingers;
		const fingerLoad = new Float64Array(fingerIds.length);
		const rowLoad = {};
		let pressed = 0;
		let outer = 0;
		let typing = 0;
		for (let k = 0; k < keyCount.length; k++) {
			fingerLoad[board.finger[k]] += keyCount[k];
			if (thumb[k]) continue;
			pressed += keyCount[k];
			if (board.outer[k]) outer += keyCount[k];
		}
		const modifierKeys = new Set(Object.values(board.modifiers));
		for (let k = 0; k < keyCount.length; k++) {
			if (thumb[k] || modifierKeys.has(k)) continue;
			typing += keyCount[k];
			rowLoad[board.row[k]] = (rowLoad[board.row[k]] || 0) + keyCount[k];
		}
		const allPresses = fingerLoad.reduce((sum, v) => sum + v, 0);
		const fingers = {};
		fingerIds.forEach((id, f) => {
			fingers[id] = pct(fingerLoad[f], allPresses);
		});
		const ideal = data().model.ideal_finger_load;
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
			home_row: pct(rowLoad[3] || 0, typing),
			top_row: pct(rowLoad[2] || 0, typing),
			bottom_row: pct(rowLoad[4] || 0, typing),
			number_row: pct(rowLoad[1] || 0, typing),
			distance: c.chars > 0 ? c.distance / c.chars : 0,
			finger_imbalance: imbalance / 2,
			hand_imbalance: pct(Math.abs(left - right), left + right),
			pinky_load: pct(fingerLoad[0] + fingerLoad[9], pressed),
			modifier_usage: pct(c.modifiers, c.chars),
			dead_key_usage: pct(c.dead, c.chars),
			outer_column: pct(outer, pressed),
			unsupported: pct(c.unsupported, allChars),
			compact_fit: compactFit(layout, board, table),
			char_coverage: charCoverage(best),
			direct_digits: directDigits(layout, board),
			shortcut_left: shortcutLeft(layout, board)
		};
		const result = {
			layout: {
				id: layout.id,
				name: layout.name,
				origin: layout.origin,
				language: layout.language
			},
			keyboard: board.id,
			metrics,
			fingers,
			hands: { left: pct(left, left + right), right: pct(right, left + right) },
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
			coverage: {
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

	/**
	 * Frequency-weighted share of the characters still typed on each compact
	 * form factor, averaged with the form factors' weights.
	 */
	function compactFit(layout, board, table) {
		const forms = data().model.form_factors;
		let sum = 0;
		let weights = 0;
		for (const form of Object.values(forms)) {
			const reachable = compileLayout(layout, board, new Set(form.missing));
			let kept = 0;
			let all = 0;
			for (const [char, n] of table.uni) {
				all += n;
				if (reachable.has(char)) kept += n;
			}
			sum += form.weight * (all > 0 ? (100 * kept) / all : 0);
			weights += form.weight;
		}
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

	/**
	 * Usefulness-weighted share of the shortcut letters on easy left-hand keys:
	 * a letter counts its weight times the ease of its key (0 on the right hand).
	 */
	function shortcutLeft(layout, board) {
		const { shortcut_letters: letters, shortcut_key_ease: ease } = data().model;
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

	/** Re-scores and re-ranks results with new weights (no re-analysis). */
	function rescore(results, weights) {
		for (const result of results) result.score = score(result, weights);
		return rank(results);
	}

	return {
		METRICS,
		LAYER_IDS,
		hashText,
		keyboard,
		layoutFromRows,
		layoutFromComposerSource,
		libraryLayouts,
		compileLayout,
		ngramsFromText,
		prepareNgrams,
		analyse,
		score,
		defaultWeights,
		compare,
		rescore
	};
})();

// Node (tests, codegen) reads the engine through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_ANALYSIS;
