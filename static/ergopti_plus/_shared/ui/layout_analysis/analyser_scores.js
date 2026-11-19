// _shared/ui/layout_analysis/analyser_scores.js

/**
 * ==============================================================================
 * MODULE: Analyser Scores
 * DESCRIPTION:
 * A layout's score as each major public layout analyser computes it (KLA and
 * its SteveP fork, KLAnext, a200, carpalx, keygen, genkey, cmini, Oxeylyzer,
 * the Ergo-L analyser and Keyboard Layout Optimizer), beside Ergopti's own
 * global score. Each scorer is reimplemented from the analyser's published
 * source or results (formulas only, no code copied); the formula, constants,
 * revision read, licence and fidelity of each are in
 * docs/design/layout-analysis.md, section « Other analysers ».
 *
 * FEATURES & RATIONALE:
 * 1. One engine: every scorer reads the corpus's cached, layout-independent
 *    n-gram tables (LAYOUT_ANALYSIS.prepareNgrams) and applies the analyser's
 *    own character filter, fingering and geometry to them; no pass over the
 *    text per layout. Tables derived from a corpus alone (carpalx's letter
 *    triads) are cached per prepared table.
 * 2. Each analyser looks a character up the way it does: most see one key per
 *    character on the base and Shift layers and no dead keys, so a character
 *    the analyser cannot type is dropped or counted as unknown, as it would be.
 * 3. Constants come from LAYOUT_ANALYSIS_DATA.analysers
 *    (_shared/layouts/data/analysis/analyser_models.json); an unknown analyser
 *    or keyboard throws.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSER_SCORES = (function () {
	'use strict';

	// The built-ins as locals. The Node tests run the scorers in a vm context,
	// where each read of a global goes through the context's interceptor,
	// about a thousand times slower than a local one; the scorers' loops read
	// Math, Number and the typed arrays millions of times.
	const {
		Array,
		Boolean,
		Error,
		Float64Array,
		Int32Array,
		Map,
		Math,
		Number,
		Object,
		Set,
		String,
		Uint8Array,
		WeakMap
	} = globalThis;

	// ============================
	// ======= 1/ Constants =======
	// ============================

	const FINGERS = ['lp', 'lr', 'lm', 'li', 'lt', 'rt', 'ri', 'rm', 'rr', 'rp'];
	const LEFT_THUMB = 4;
	const RIGHT_THUMB = 5;
	// Order of the analysers in a result and in the Comparer's columns.
	const ORDER = [
		'kla',
		'kla_stevep',
		'klanext',
		'a200',
		'carpalx',
		'keygen',
		'genkey',
		'oxeylyzer',
		'dariogoetz',
		'cyanophage',
		'cmini',
		'ergol'
	];

	// =======================
	// ======= 2/ Data =======
	// =======================

	/** The engine, loaded first. */
	function engine() {
		if (typeof LAYOUT_ANALYSIS === 'undefined')
			throw new Error('analyser_scores: load analysis_engine.js first');
		return LAYOUT_ANALYSIS;
	}

	/**
	 * One analyser's entry of the generated data.
	 * @param {string} id - An analyser id.
	 * @returns {object} {name, author, url, repository, revision, licence,
	 *   fidelity, better, unit, digits, model}.
	 * @throws {Error} On an unknown analyser or missing data.
	 */
	function entry(id) {
		if (typeof LAYOUT_ANALYSIS_DATA === 'undefined' || !LAYOUT_ANALYSIS_DATA.analysers)
			throw new Error('analyser_scores: load _generated/analysis_data.js first');
		const found = LAYOUT_ANALYSIS_DATA.analysers[id];
		if (!found) throw new Error(`analyser_scores: unknown analyser ${id}`);
		return found;
	}

	/** Index of a finger id. */
	const fingerIndex = (id) => {
		const f = FINGERS.indexOf(id);
		if (f < 0) throw new Error(`analyser_scores: unknown finger ${id}`);
		return f;
	};
	const isThumb = (f) => f === LEFT_THUMB || f === RIGHT_THUMB;
	const handOf = (f) => (f <= LEFT_THUMB ? 0 : 1);
	// From the pinky (0) to the index (3), thumbs 4.
	const orderOf = (f) => (f < LEFT_THUMB ? f : f > RIGHT_THUMB ? 9 - f : 4);
	const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
	const single = (cell) => typeof cell === 'string' && Array.from(cell).length === 1;

	/**
	 * Values computed from a corpus alone, cached per prepared table.
	 * @param {object} table - prepareNgrams() output.
	 * @param {string} key - What is cached.
	 * @param {Function} build - Builds it from the table.
	 * @returns {*} The cached value.
	 */
	const corpusCache = new WeakMap();
	function perCorpus(table, key, build) {
		if (!corpusCache.has(table)) corpusCache.set(table, new Map());
		const map = corpusCache.get(table);
		if (!map.has(key)) map.set(key, build(table));
		return map.get(key);
	}

	/**
	 * A prepared table with its line breaks and tabs back in its n-grams, for
	 * the analysers that read the whole text: ngramsFromText keeps them in its
	 * break tables. A table without them (a count table) is returned as is.
	 * @param {object} table - prepareNgrams() output.
	 * @returns {{uni: Array, bi: Array, tri: Array}} The n-grams.
	 */
	function withBreaks(table) {
		const breaks = table.breaks;
		if (!breaks) return table;
		return perCorpus(table, 'with-breaks', () => ({
			uni: table.uni.concat(breaks.uni),
			bi: table.bi.concat(breaks.bi),
			tri: table.tri.concat(breaks.tri)
		}));
	}

	/**
	 * Which key types each character, the way an analyser that knows one key per
	 * character looks it up: keys in the given order, layers in the given order,
	 * the first hit wins. Dead keys and multi-character outputs are not seen.
	 * @param {object} layout - Library shape.
	 * @param {string[]} codes - Physical keys, in the analyser's scan order.
	 * @param {number[]} layers - Layer indexes (0 base, 1 Shift, 2 AltGr, 3 Shift+AltGr).
	 * @returns {Map<string, {code: string, layer: number}>} Character → key.
	 */
	function keyOfChar(layout, codes, layers) {
		const map = new Map();
		for (const code of codes) {
			const row = layout.rows[code];
			if (!row) continue;
			for (const layer of layers) {
				const cell = row[layer];
				if (single(cell) && !map.has(cell)) map.set(cell, { code, layer });
			}
		}
		return map;
	}

	/**
	 * The finger of each key on our fingering of a keyboard (the layout's
	 * standard or angle fingering), for the analysers that read the fingering
	 * from the layout file.
	 * @returns {{board: object, finger: Map<string, number>}} Board and code → finger.
	 */
	function ourFingers(layout, keyboardId, profile) {
		const E = engine();
		const board =
			keyboardId === 'iso' && layout.fingering === 'angle'
				? E.keyboard('iso_angle', profile)
				: E.keyboard(keyboardId, profile);
		const finger = new Map();
		board.codes.forEach((code, k) => finger.set(code, board.finger[k]));
		return { board, finger };
	}

	/**
	 * In « custom » mode, the user's finger model (the engine's board for the
	 * fingering profile): each key's finger and each finger's home key. Null in
	 * « official » mode, where every analyser keeps its own fingering.
	 * @returns {{finger: Map<string, number>, home: string[]}|null} The model.
	 */
	function customModel(ctx) {
		if (!ctx.custom) return null;
		if (ctx.cache.has('custom')) return ctx.cache.get('custom');
		const { board, finger } = ourFingers(ctx.layout, ctx.keyboard, ctx.profile);
		const model = { finger, home: FINGERS.map((id, f) => board.codes[board.homeOf[f]]) };
		ctx.cache.set('custom', model);
		return model;
	}

	/**
	 * A key's finger: the user's in « custom » mode when the model has the key,
	 * else the analyser's own.
	 * @param {object} ctx - The scoring context.
	 * @param {string} code - The physical key.
	 * @param {number} official - The analyser's finger index for it.
	 * @returns {number} The finger index (LP 0 … RP 9).
	 */
	function fingerFor(ctx, code, official) {
		const model = customModel(ctx);
		return model && model.finger.has(code) ? model.finger.get(code) : official;
	}

	// ==============================================
	// ======= 3/ KLA, its fork and KLAnext =========
	// ==============================================

	/**
	 * KLA's keyboard: its own key centres in pixels and its fingering (the
	 * layout's angle mod applied), for ANSI (`standard`) or ISO (`european`).
	 */
	function klaBoard(model, ctx) {
		const { layout, keyboard: keyboardId } = ctx;
		const form = keyboardId === 'ansi' ? 'standard' : 'european';
		const angle = layout.fingering === 'angle' || keyboardId === 'iso_angle';
		const geometry = model.geometry[form];
		const codes = Object.keys(geometry);
		const index = new Map(codes.map((code, k) => [code, k]));
		// KLAnext's own layout files finger a few keys their way (the Space thumb,
		// Dvorak's number row), by library layout id.
		const own = (model.layout_fingering && model.layout_fingering[layout.id]) || {};
		const finger = codes.map((code) =>
			fingerFor(
				ctx,
				code,
				fingerIndex(own[code] || (angle && model.angle_fingering[code]) || model.fingering[code])
			)
		);
		const custom = customModel(ctx);
		const home = FINGERS.map((id, f) =>
			custom && index.has(custom.home[f])
				? index.get(custom.home[f])
				: index.get(model.home_keys[id])
		);
		return {
			form,
			codes,
			index,
			finger,
			home,
			cx: codes.map((code) => geometry[code][0]),
			cy: codes.map((code) => geometry[code][1]),
			width: codes.map((code) => geometry[code][2])
		};
	}

	/**
	 * The KLA keystroke of each character: its key, its finger and the Shift and
	 * AltGr keys it needs (the Shift of the other hand). A character KLA cannot
	 * type (dead key, two keys, a modifier on the key's own finger) is absent.
	 */
	function klaStrokes(model, layout, board) {
		const map = keyOfChar(layout, board.codes, [0, 1, 2, 3]);
		if (!map.has('\n')) map.set('\n', { code: model.enter_key, layer: 0 });
		if (!map.has('\t')) map.set('\t', { code: model.tab_key, layer: 0 });
		for (const [fancy, plain] of Object.entries(model.fallbacks))
			if (!map.has(fancy) && map.has(plain)) map.set(fancy, map.get(plain));
		const strokes = new Map();
		for (const [char, { code, layer }] of map) {
			const key = board.index.get(code);
			const f = board.finger[key];
			let shift = -1;
			let altgr = -1;
			if (layer === 1 || layer === 3)
				shift = board.index.get(handOf(f) === 0 ? model.shift_keys.right : model.shift_keys.left);
			if (layer >= 2) altgr = board.index.get(model.altgr_key);
			if (shift >= 0 && board.finger[shift] === f) continue;
			if (altgr >= 0 && board.finger[altgr] === f) continue;
			strokes.set(char, { key, finger: f, shift, altgr });
		}
		return strokes;
	}

	/**
	 * The character bigrams KLA sees: those of the corpus between two characters
	 * it types, plus the pairs it joins across one character it skips (from the
	 * trigrams), and how often each character starts or ends a run.
	 */
	function klaBigrams(table, strokes) {
		// A table from ngramsFromText brings its line breaks and tabs apart.
		const breaks = table.breaks;
		const uni = breaks ? table.uni.concat(breaks.uni) : table.uni;
		const bi = breaks ? table.bi.concat(breaks.bi) : table.bi;
		const tri = breaks ? table.tri.concat(breaks.tri) : table.tri;
		const pairs = [];
		const into = new Map();
		const outOf = new Map();
		const add = (a, b, n) => {
			pairs.push([a, b, n]);
			into.set(b, (into.get(b) || 0) + n);
			outOf.set(a, (outOf.get(a) || 0) + n);
		};
		for (const [x, y, n] of bi) if (strokes.has(x) && strokes.has(y)) add(x, y, n);
		for (const [x, skipped, y, n] of tri)
			if (!strokes.has(skipped) && strokes.has(x) && strokes.has(y)) add(x, y, n);
		let starts = [];
		let ends = [];
		for (const [char, n] of uni) {
			if (!strokes.has(char)) continue;
			const s = n - (into.get(char) || 0);
			const e = n - (outOf.get(char) || 0);
			if (s > 0) starts.push([char, s]);
			if (e > 0) ends.push([char, e]);
		}
		// Tables cut at line breaks without their break tables (a count table, a
		// word list) hold no "\n": the S runs of such a text were joined by S − 1
		// line breaks, which KLA types as Enter. Each run's end and the next run's
		// start are paired through Enter in proportion; one run in S keeps its
		// true start and end.
		const runs = starts.reduce((sum, [, n]) => sum + n, 0);
		let enters = 0;
		if (runs > 1 && !uni.some(([char]) => char === '\n') && strokes.has('\n')) {
			enters = runs - 1;
			const joined = (runs - 1) / runs;
			for (const [char, n] of ends) add(char, '\n', n * joined);
			for (const [char, n] of starts) add('\n', char, n * joined);
			starts = starts.map(([char, n]) => [char, n / runs]);
			ends = ends.map(([char, n]) => [char, n / runs]);
		}
		// Every character of the text, typed or not, Enter and Tab included.
		const characters = uni.reduce((sum, [, n]) => sum + n, 0) + enters;
		return { pairs, starts, ends, characters };
	}

	/**
	 * KLA's typing simulation, summed over character bigrams: before each
	 * character the fingers it does not use go home; a released modifier
	 * becomes the previous press; a pressed modifier and then the key are
	 * pressed, each compared with the previous press for same finger and same
	 * hand. A run starts with every finger home and ends with every finger
	 * going home, as KLA's text does.
	 * @param {object} board - klaBoard().
	 * @param {Map} strokes - klaStrokes().
	 * @param {object} bigrams - klaBigrams().
	 * @param {Function} move - (finger, fromKey, toKey, pressing) → distance.
	 * @returns {object} {presses, distance[f], usage[f], sameFinger[f],
	 *   sameFingerNoRepeat[f], sameHand[g], sameHandNoRepeat[g], sameSide[h]}
	 *   with g 0 left, 1 right, 2 thumbs, and h the hand, its thumb included
	 *   (repeats counted).
	 */
	function klaSimulate(board, strokes, bigrams, move) {
		const c = {
			presses: 0,
			distance: new Float64Array(10),
			usage: new Float64Array(10),
			sameFinger: new Float64Array(10),
			sameFingerNoRepeat: new Float64Array(10),
			sameHand: new Float64Array(3),
			sameHandNoRepeat: new Float64Array(3),
			sameSide: new Float64Array(2)
		};
		const group = (f) => (isThumb(f) ? 2 : handOf(f));
		const pos = new Int32Array(10);
		const cur = new Int32Array(10);
		const used = new Uint8Array(10);
		const step = (a, b, n) => {
			pos.fill(-1);
			used.fill(0);
			if (a) {
				pos[a.finger] = a.key;
				if (a.shift >= 0) pos[board.finger[a.shift]] = a.shift;
				if (a.altgr >= 0) pos[board.finger[a.altgr]] = a.altgr;
			}
			if (b) {
				used[b.finger] = 1;
				if (b.shift >= 0) used[board.finger[b.shift]] = 1;
				if (b.altgr >= 0) used[board.finger[b.altgr]] = 1;
			}
			for (let f = 0; f < 10; f++) {
				if (pos[f] >= 0 && !used[f]) c.distance[f] += n * move(f, pos[f], board.home[f], false);
				cur[f] = pos[f] >= 0 && used[f] ? pos[f] : board.home[f];
			}
			if (!b) return;
			let prevFinger = a ? a.finger : -1;
			let prevKey = a ? a.key : -1;
			const press = (key) => {
				const f = board.finger[key];
				c.distance[f] += n * move(f, cur[f], key, true);
				cur[f] = key;
				c.usage[f] += n;
				c.presses += n;
				if (prevFinger >= 0) {
					if (prevFinger === f) {
						c.sameFinger[f] += n;
						if (prevKey !== key) c.sameFingerNoRepeat[f] += n;
					}
					if (handOf(prevFinger) === handOf(f)) c.sameSide[handOf(f)] += n;
					const g = group(f);
					if (group(prevFinger) === g) {
						c.sameHand[g] += n;
						if (prevKey !== key) c.sameHandNoRepeat[g] += n;
					}
				}
				prevFinger = f;
				prevKey = key;
			};
			const aShift = a ? a.shift : -1;
			const aAltgr = a ? a.altgr : -1;
			if (aShift >= 0 && aShift !== b.shift) {
				prevFinger = board.finger[aShift];
				prevKey = aShift;
			}
			if (b.shift >= 0 && b.shift !== aShift) press(b.shift);
			if (aAltgr >= 0 && aAltgr !== b.altgr) {
				prevFinger = board.finger[aAltgr];
				prevKey = aAltgr;
			}
			if (b.altgr >= 0 && b.altgr !== aAltgr) press(b.altgr);
			press(b.key);
		};
		for (const [char, n] of bigrams.starts) step(null, strokes.get(char), n);
		for (const [a, b, n] of bigrams.pairs) step(strokes.get(a), strokes.get(b), n);
		for (const [char, n] of bigrams.ends) step(strokes.get(char), null, n);
		return c;
	}

	/** The KLA simulation of a layout, shared by KLA and KLAnext. */
	function klaRun(ctx, id, move) {
		const key = `kla:${id}`;
		if (ctx.cache.has(key)) return ctx.cache.get(key);
		const model = entry(id).model;
		const board = klaBoard(model, ctx);
		const strokes = klaStrokes(model, ctx.layout, board);
		const bigrams = klaBigrams(ctx.table, strokes);
		const counters = klaSimulate(board, strokes, bigrams, move(model, board));
		const run = { model, board, strokes, bigrams, counters };
		ctx.cache.set(key, run);
		return run;
	}

	/** Euclidean distance between key centres, in pixels (KLA, KLAnext). */
	const euclid = (model, board) => (f, from, to) =>
		Math.hypot(board.cx[to] - board.cx[from], board.cy[to] - board.cy[from]);

	/**
	 * SteveP's Fitts-style penalty: the move, turned 10° toward each hand
	 * (thumbs not), scaled per axis by log2(1 + d / key size), then by the
	 * finger's lateral and vertical factors. The target key's size counts on a
	 * press, the left key's on the way home.
	 */
	const fitts = (model, board) => {
		const theta = (model.approach_angle_deg * Math.PI) / 180;
		const cos = Math.cos(theta);
		const sin = Math.sin(theta);
		const unit = model.key_unit_px;
		const vertical = [
			model.vertical_factor.p,
			model.vertical_factor.r,
			model.vertical_factor.m,
			model.vertical_factor.i
		];
		return (f, from, to, pressing) => {
			if (from === to) return 0;
			const [k1, k2] = pressing ? [to, from] : [from, to];
			const dx = (board.cx[k1] - board.cx[k2]) / unit;
			const dy = (board.cy[k1] - board.cy[k2]) / unit;
			let xr = dx;
			let yr = dy;
			if (!isThumb(f) && handOf(f) === 0) {
				xr = dx * cos + dy * sin;
				yr = -dx * sin + dy * cos;
			} else if (!isThumb(f)) {
				xr = dx * cos - dy * sin;
				yr = dx * sin + dy * cos;
			}
			let xf = Math.log2(1 + Math.abs(xr) / (board.width[k1] / unit));
			let yf = Math.log2(1 + Math.abs(yr));
			if (isThumb(f)) {
				xf *= model.thumb_factor;
				yf *= model.thumb_factor;
			} else {
				xf *= model.lateral_factor;
				yf *= vertical[orderOf(f)];
			}
			return Math.hypot(xf, yf);
		};
	};

	/** KLA's score: same hand, same finger, finger usage and distance, out of 100. */
	function scoreKla(ctx) {
		const { model, counters: c } = klaRun(ctx, 'kla', euclid);
		const n = c.presses;
		const cmPerPress = n > 0 ? c.distance.reduce((s, v) => s + v, 0) / model.px_per_cm / n : 0;
		const distance = Math.max(0, model.distance_cap_cm - cmPerPress) / model.distance_cap_cm;
		let finger = 0;
		FINGERS.forEach((id, f) => {
			finger += Math.min(pct(c.usage[f], n), model.finger_cap_pct) * model.finger_weight[id];
		});
		finger /= model.finger_divisor;
		const sameFingerPct = pct(
			c.sameFingerNoRepeat.reduce((s, v) => s + v, 0),
			n
		);
		const sameHandPct = pct(c.sameHandNoRepeat[0] + c.sameHandNoRepeat[1], n);
		const sameFinger =
			Math.max(0, model.same_finger_cap_pct - sameFingerPct) / model.same_finger_cap_pct;
		const sameHand = Math.max(0, model.same_hand_cap_pct - sameHandPct) / model.same_hand_cap_pct;
		const w = model.weights;
		return {
			value:
				w.same_hand * sameHand +
				w.same_finger * sameFinger +
				w.finger_usage * finger +
				w.distance * distance,
			parts: {
				distance_cm_per_press: cmPerPress,
				same_finger_pct: sameFingerPct,
				same_hand_pct: sameHandPct,
				distance_score: 100 * distance,
				finger_score: 100 * finger,
				same_finger_score: 100 * sameFinger,
				same_hand_score: 100 * sameHand
			},
			presses: n
		};
	}

	/** SteveP's fork: distance penalty, finger usage and same finger, out of 100. */
	function scoreKlaStevep(ctx) {
		const { model, counters: c } = klaRun(ctx, 'kla_stevep', fitts);
		const n = c.presses;
		const penalty = n > 0 ? c.distance.reduce((s, v) => s + v, 0) / n : 0;
		const distance = (100 * Math.max(0, model.distance_cap - penalty)) / model.distance_cap;
		let usage = 0;
		let imbalance = 0;
		FINGERS.forEach((id, f) => {
			const weight = model.finger_weight[id];
			usage += (c.usage[f] * weight) / (n || 1);
			if (!isThumb(f))
				imbalance += ((Math.max(0, c.usage[f] - c.usage[9 - f]) / 2) * weight) / (n || 1);
		});
		const finger =
			100 * Math.max(0, model.finger_offset - model.finger_slope * (usage + imbalance));
		const sameFingerPct = pct(
			c.sameFingerNoRepeat.reduce((s, v) => s + v, 0),
			n
		);
		const sameFinger = 10 * Math.max(0, model.same_finger_cap_pct - sameFingerPct);
		const w = model.weights;
		return {
			value: w.distance * distance + w.finger_usage * finger + w.same_finger * sameFinger,
			parts: {
				distance_penalty_per_press: penalty,
				same_finger_pct: sameFingerPct,
				distance_score: distance,
				finger_score: finger,
				same_finger_score: sameFinger
			},
			presses: n
		};
	}

	/**
	 * KLAnext, reconstructed from its output on texts written to isolate each
	 * term (docs/design/analyser-scores.md): over the characters of the text
	 * (Enter, Tab and the characters it cannot type included), the weighted
	 * distance with a fixed cost per press, the weighted same-finger presses
	 * (repeats included) and the square of the weighted share of presses on the
	 * hand of the previous one (thumbs with their hand); lower is better.
	 */
	function scoreKlanext(ctx) {
		const { model, bigrams, counters: c } = klaRun(ctx, 'klanext', euclid);
		const handWeight = [model.hand_weight.left, model.hand_weight.right];
		let distance = 0;
		let sameFinger = 0;
		FINGERS.forEach((id, f) => {
			const w = model.finger_weight[id] * handWeight[handOf(f)];
			distance += w * (c.distance[f] + model.press_overhead_px * c.usage[f]);
			sameFinger += w * c.sameFinger[f];
		});
		const sameHand = handWeight[0] * c.sameSide[0] + handWeight[1] * c.sameSide[1];
		const per = (v) => (bigrams.characters > 0 ? v / bigrams.characters : 0);
		const parts = {
			distance: model.c_distance * per(distance),
			same_finger: model.c_same_finger * per(sameFinger),
			same_hand: model.c_same_hand * per(sameHand) ** 2
		};
		return {
			value: parts.distance + parts.same_finger + parts.same_hand,
			parts,
			presses: c.presses
		};
	}

	// =====================================================
	// ======= 4/ Finger-triple statistics (a200, cmini) ===
	// =====================================================

	/**
	 * The finger of each character a layout types on one key of the base or
	 * Shift layer, from the layout's fingering.
	 */
	function charFingers(ctx, layers) {
		const key = `fingers:${layers.join('')}`;
		if (ctx.cache.has(key)) return ctx.cache.get(key);
		const { board, finger } = ourFingers(
			ctx.layout,
			ctx.keyboard,
			ctx.custom ? ctx.profile : undefined
		);
		const map = keyOfChar(ctx.layout, board.codes, layers);
		const out = new Map();
		const row = new Map();
		for (const [char, { code }] of map) {
			out.set(char, finger.get(code));
			row.set(char, board.row[board.index.get(code)]);
		}
		const result = { finger: out, row };
		ctx.cache.set(key, result);
		return result;
	}

	/**
	 * a200's trigram class of three fingers (hand and distance from the thumb:
	 * index 1 … pinky 4, thumb 0); the last matching rule wins, as in a200.
	 */
	function a200Class(f1, f2, f3) {
		const h = [handOf(f1), handOf(f2), handOf(f3)];
		const d = [f1, f2, f3].map((f) => 4 - orderOf(f));
		let type;
		if (h[0] === h[2] && h[0] !== h[1]) type = 'alternate';
		else if (h[0] !== h[2] && ((h[0] === h[1] && d[0] < d[1]) || (h[1] === h[2] && d[1] < d[2])))
			type = 'roll_out';
		else if (h[0] !== h[2] && ((h[0] === h[1] && d[0] > d[1]) || (h[1] === h[2] && d[1] > d[2])))
			type = 'roll_in';
		else if (d[0] > d[1] && d[1] > d[2]) type = 'oneh_in';
		else if (d[0] < d[1] && d[1] < d[2]) type = 'oneh_out';
		else type = 'redirect';
		if (f1 !== f3 && (f2 === f1 || f2 === f3)) type = 'sfb';
		else if (f1 === f3 && f1 !== f2 && h[0] === h[1]) type = 'dsfb_red';
		else if (f1 === f3 && f1 !== f2) type = 'dsfb_alt';
		else if (f1 === f2 && f2 === f3) type = 'sft';
		return type;
	}

	/**
	 * a200: trigram classes on the raw characters (spaces on a thumb, case
	 * kept, Shift not pressed), finger and row use; the default « AVG » mode
	 * averages every value with the space on the left and on the right thumb.
	 * a200 has no score.
	 */
	function scoreA200(ctx) {
		const model = entry('a200').model;
		const { finger, row } = charFingers(ctx, [0, 1]);
		const runs = model.space_thumbs.map((thumbId) => {
			const thumb = fingerIndex(thumbId);
			const fingerOf = (char) => (char === ' ' ? thumb : finger.get(char));
			const b = {
				alternate: 0,
				roll_in: 0,
				roll_out: 0,
				oneh_in: 0,
				oneh_out: 0,
				redirect: 0,
				sfb: 0,
				dsfb_red: 0,
				dsfb_alt: 0,
				sft: 0,
				sfr: 0,
				unknown: 0
			};
			for (const [x, y, z, n] of ctx.table.tri) {
				const f1 = fingerOf(x);
				const f2 = fingerOf(y);
				const f3 = fingerOf(z);
				if (f1 === undefined || f2 === undefined || f3 === undefined) b.unknown += n;
				else if (x === y || y === z || x === z) b.sfr += n;
				else b[a200Class(f1, f2, f3)] += n;
			}
			const sum = Object.values(b).reduce((s, v) => s + v, 0);
			const p = {};
			for (const [k, v] of Object.entries(b)) p[k] = pct(v, sum);
			p.roll = p.roll_in + p.roll_out;
			p.onehand = p.oneh_in + p.oneh_out;
			p.dsfb = p.dsfb_red + p.dsfb_alt;
			p.roll_ratio = p.roll_out > 0 ? p.roll_in / p.roll_out : null;
			p.onehand_ratio = p.oneh_out > 0 ? p.oneh_in / p.oneh_out : null;
			return p;
		});
		const parts = {};
		for (const k of Object.keys(runs[0])) {
			const values = runs.map((r) => r[k]);
			parts[k] = values.some((v) => v === null)
				? null
				: values.reduce((s, v) => s + v, 0) / values.length;
		}
		// Finger and row use: the space on the thumbs, other characters on their finger.
		const use = new Float64Array(10);
		let thumbs = 0;
		const rows = { top: 0, home: 0, bottom: 0 };
		for (const [char, n] of ctx.table.uni) {
			if (char === ' ') {
				thumbs += n;
				continue;
			}
			const f = finger.get(char);
			if (f === undefined) continue;
			use[f] += n;
			const name = model.rows[String(row.get(char))];
			if (name) rows[name] += n;
		}
		const all = use.reduce((s, v) => s + v, 0) + thumbs;
		const rowAll = rows.top + rows.home + rows.bottom;
		FINGERS.forEach((id, f) => {
			if (!isThumb(f)) parts[`finger_${id}`] = pct(use[f], all);
		});
		parts.thumb = pct(thumbs, all);
		parts.left_hand = pct(use[0] + use[1] + use[2] + use[3], all);
		parts.right_hand = pct(use[6] + use[7] + use[8] + use[9], all);
		for (const [name, n] of Object.entries(rows)) parts[`row_${name}`] = pct(n, rowAll);
		return { value: null, parts };
	}

	/**
	 * cmini's trigram class of three fingers (thumbs innermost; a bad redirect
	 * has no index finger).
	 */
	function cminiClass(f1, f2, f3) {
		const h = [handOf(f1), handOf(f2), handOf(f3)];
		const o = [orderOf(f1), orderOf(f2), orderOf(f3)];
		if (f1 === f2 && f2 === f3) return 'sft';
		if (f1 === f2 || f2 === f3) return 'sfb_trigram';
		if (f1 === f3) return h[0] === h[1] ? 'sfs_red' : 'sfs_alt';
		if (h[0] !== h[1] && h[1] !== h[2]) return 'alternate';
		if (h[0] === h[1] && h[1] === h[2]) {
			if (o[0] < o[1] && o[1] < o[2]) return 'onehand_in';
			if (o[0] > o[1] && o[1] > o[2]) return 'onehand_out';
			return o.includes(3) ? 'redirect' : 'redirect_bad';
		}
		const [a, b] = h[0] === h[1] ? [o[0], o[1]] : [o[1], o[2]];
		return a < b ? 'roll_in' : 'roll_out';
	}

	/**
	 * cmini's « view » statistics: n-grams inside words (no whitespace), case
	 * folded, base-layer characters; SFB over every bigram, trigram classes
	 * over every trigram. cmini has no score.
	 */
	function scoreCmini(ctx) {
		const { finger: baseFinger } = charFingers(ctx, [0]);
		const fingerOf = (char) => baseFinger.get(char.toLowerCase());
		const space = /\s/;
		let bigrams = 0;
		let sfb = 0;
		for (const [a, b, n] of ctx.table.bi) {
			if (space.test(a) || space.test(b)) continue;
			bigrams += n;
			const fa = fingerOf(a);
			if (fa !== undefined && a.toLowerCase() !== b.toLowerCase() && fa === fingerOf(b)) sfb += n;
		}
		const b = {
			alternate: 0,
			roll_in: 0,
			roll_out: 0,
			onehand_in: 0,
			onehand_out: 0,
			redirect: 0,
			redirect_bad: 0,
			sfs_red: 0,
			sfs_alt: 0,
			sfb_trigram: 0,
			sft: 0,
			sfr: 0,
			unknown: 0
		};
		let trigrams = 0;
		for (const [x, y, z, n] of ctx.table.tri) {
			if (space.test(x) || space.test(y) || space.test(z)) continue;
			trigrams += n;
			const [lx, ly, lz] = [x.toLowerCase(), y.toLowerCase(), z.toLowerCase()];
			if (lx === ly || ly === lz || lx === lz) {
				b.sfr += n;
				continue;
			}
			const f = [fingerOf(x), fingerOf(y), fingerOf(z)];
			if (f.includes(undefined)) b.unknown += n;
			else b[cminiClass(f[0], f[1], f[2])] += n;
		}
		const parts = { sfb: pct(sfb, bigrams) };
		for (const [k, v] of Object.entries(b)) parts[k] = pct(v, trigrams);
		parts.roll = parts.roll_in + parts.roll_out;
		parts.onehand = parts.onehand_in + parts.onehand_out;
		parts.roll_total = parts.roll + parts.onehand;
		parts.redirect_total = parts.redirect + parts.redirect_bad;
		parts.sfs = parts.sfs_red + parts.sfs_alt;
		let left = 0;
		let all = 0;
		for (const [char, n] of ctx.table.uni) {
			if (space.test(char)) continue;
			const f = fingerOf(char);
			if (f === undefined) continue;
			all += n;
			if (handOf(f) === 0) left += n;
		}
		parts.left_hand = pct(left, all);
		parts.right_hand = all > 0 ? 100 - parts.left_hand : 0;
		return { value: null, parts };
	}

	// =========================
	// ======= 5/ carpalx ======
	// =========================

	// Rounds of carpalx's chain through deleted characters: runs of deleted
	// characters longer than this between two letters are rare (a line of
	// punctuation), and each round adds one character.
	const CARPALX_CHAIN_ROUNDS = 12;

	/**
	 * carpalx's letter triads of a corpus: lower case, a-z only, every other
	 * character deleted (so triads join across spaces and punctuation, within a
	 * line), identical triplets dropped. Each trigram (a y b) around a letter y
	 * gives the triads (x y z) of x, the letter before y in its line, and z,
	 * the letter after: a itself when it is a letter, else the letters reached
	 * by the trigrams' second-order chain through the deleted characters
	 * (backward from a y, forward from y b), x and z independent given a y b.
	 * The chain's bigram counts the runs that end there, so a line's end stops
	 * it as carpalx's line does. Exact for letters-only text.
	 * @returns {object} Triads as typed arrays of letter indexes and counts.
	 */
	function carpalxTriads(table) {
		const SEP = '\u0000';
		const letters = new Map();
		const letterOf = (char) => {
			if (!letters.has(char)) {
				const lower = char.toLowerCase();
				letters.set(
					char,
					lower.length === 1 && lower >= 'a' && lower <= 'z' ? lower.charCodeAt(0) - 97 : -1
				);
			}
			return letters.get(char);
		};
		const bi = new Map();
		for (const [a, b, n] of table.bi) bi.set(a + SEP + b, n);
		// States of the chain, keyed by two characters: forward (p, c) with c
		// deleted, backward (c, y) with c deleted; each with its next characters.
		const forward = new Map();
		const backward = new Map();
		const step = (map, key, char, n, total) => {
			if (!map.has(key)) map.set(key, []);
			map.get(key).push([char, n / total]);
		};
		for (const [a, b, c, n] of table.tri) {
			if (letterOf(b) < 0) step(forward, a + SEP + b, c, n, bi.get(a + SEP + b));
			if (letterOf(b) < 0) step(backward, b + SEP + c, a, n, bi.get(b + SEP + c));
		}
		// Letter distribution reached from each state, by fixed-point iteration
		// (each round reaches one more deleted character).
		const solve = (map, nextKey) => {
			let reach = new Map();
			for (let round = 0; round < CARPALX_CHAIN_ROUNDS; round++) {
				const next = new Map();
				for (const [key, steps] of map) {
					const v = new Float64Array(26);
					for (const [char, p] of steps) {
						const l = letterOf(char);
						if (l >= 0) v[l] += p;
						else {
							const further = reach.get(nextKey(key, char));
							if (further) for (let i = 0; i < 26; i++) v[i] += p * further[i];
						}
					}
					next.set(key, v);
				}
				reach = next;
			}
			return reach;
		};
		const ahead = solve(forward, (key, char) => key.slice(key.indexOf(SEP) + 1) + SEP + char);
		const behind = solve(backward, (key, char) => char + SEP + key.slice(0, key.indexOf(SEP)));
		const counts = new Float64Array(26 * 26 * 26);
		const unit = (l) => {
			const v = new Float64Array(26);
			v[l] = 1;
			return v;
		};
		for (const [a, y, b, n] of table.tri) {
			const ly = letterOf(y);
			if (ly < 0) continue;
			const la = letterOf(a);
			const lb = letterOf(b);
			const left = la >= 0 ? unit(la) : behind.get(a + SEP + y);
			const right = lb >= 0 ? unit(lb) : ahead.get(y + SEP + b);
			if (!left || !right) continue;
			for (let x = 0; x < 26; x++) {
				if (left[x] === 0) continue;
				for (let z = 0; z < 26; z++)
					if (right[z] !== 0 && !(x === ly && ly === z))
						counts[(x * 26 + ly) * 26 + z] += n * left[x] * right[z];
			}
		}
		const triads = new Map();
		counts.forEach((n, k) => {
			if (n > 0)
				triads.set(
					String.fromCharCode(
						97 + Math.floor(k / 676),
						97 + (Math.floor(k / 26) % 26),
						97 + (k % 26)
					),
					n
				);
		});
		// As typed arrays of letter indexes, so a layout is scored in one pass.
		const size = triads.size;
		const out = {
			a: new Uint8Array(size),
			b: new Uint8Array(size),
			c: new Uint8Array(size),
			n: new Float64Array(size),
			total: 0
		};
		let i = 0;
		for (const [key, n] of triads) {
			out.a[i] = key.charCodeAt(0) - 97;
			out.b[i] = key.charCodeAt(1) - 97;
			out.c[i] = key.charCodeAt(2) - 97;
			out.n[i] = n;
			out.total += n;
			i++;
		}
		return out;
	}

	/** carpalx's row flag of a triad (rows 0 to 3). */
	function carpalxRowFlagOf(r1, r2, r3) {
		const diffs = [r1 - r2, r1 - r3, r2 - r3];
		let drmax = diffs[0];
		for (const d of diffs)
			if (Math.abs(d) > Math.abs(drmax) || (Math.abs(d) === Math.abs(drmax) && d < drmax))
				drmax = d;
		if (r1 < r2) {
			if (r3 === r2) return 1;
			if (r2 < r3) return 4;
			if (Math.abs(drmax) === 1) return 3;
			return drmax < 0 ? 7 : 5;
		}
		if (r1 > r2) {
			if (r3 === r2) return 2;
			if (r2 > r3) return 6;
			if (Math.abs(drmax) === 1) return 3;
			return drmax < 0 ? 7 : 5;
		}
		if (r2 > r3) return 2;
		if (r2 < r3) return 1;
		return 0;
	}

	// The 64 row flags, computed once.
	const CARPALX_ROW_FLAGS = new Uint8Array(64);
	for (let r = 0; r < 64; r++) CARPALX_ROW_FLAGS[r] = carpalxRowFlagOf(r >> 4, (r >> 2) & 3, r & 3);
	const carpalxRowFlag = (r1, r2, r3) => CARPALX_ROW_FLAGS[(r1 << 4) | (r2 << 2) | r3];

	/** carpalx's finger flag of a triad (fingers and characters). */
	function carpalxFingerFlag(f1, f2, f3, c1, c2, c3) {
		if (f1 > f2) {
			if (f2 > f3) return 0;
			if (f2 === f3) return c2 === c3 ? 1 : 6;
			if (f3 === f1) return 4;
			if (f1 > f3 && f3 > f2) return 2;
			return 3;
		}
		if (f1 < f2) {
			if (f2 < f3) return 0;
			if (f2 === f3) return c2 === c3 ? 1 : 6;
			if (f3 === f1) return 4;
			if (f1 < f3 && f3 < f2) return 2;
			return 3;
		}
		if (f3 !== f2) return c1 === c2 ? 1 : 6;
		return c1 !== c2 && c2 !== c3 && c1 !== c3 ? 7 : 5;
	}

	/**
	 * carpalx's typing effort: the mean over letter triads of base effort,
	 * penalty (hand, row, finger) and stroke path; lower is better, QWERTY 3.0
	 * on carpalx's own book corpus.
	 */
	function scoreCarpalx(ctx) {
		const model = entry('carpalx').model;
		const triads = perCorpus(ctx.table, 'carpalx:triads', carpalxTriads);
		const where = new Map();
		model.rows_to_code.forEach((codes, r) =>
			codes.forEach((code, col) => where.set(code, { r, col }))
		);
		const keyOf = keyOfChar(ctx.layout, Object.keys(ctx.layout.rows), [0, 1]);
		const keys = new Array(26).fill(null);
		for (let i = 0; i < 26; i++) {
			const letter = String.fromCharCode(97 + i);
			const hit = keyOf.get(letter) || keyOf.get(letter.toUpperCase());
			if (!hit) continue;
			let key;
			if (where.has(hit.code)) {
				const { r, col } = where.get(hit.code);
				key = {
					r,
					finger: fingerFor(ctx, hit.code, model.finger[r][col]),
					base: model.base_effort[r][col]
				};
			} else if (model.extension[hit.code]) {
				const ext = model.extension[hit.code];
				key = { r: ext.row, finger: fingerFor(ctx, hit.code, ext.finger), base: ext.base };
			} else continue;
			const w = model.weights;
			key.hand = key.finger > 5 ? 1 : 0;
			key.penalty =
				w.hand * model.hand_penalty[key.hand === 0 ? 'left' : 'right'] +
				w.row * model.row_penalty[key.r] +
				w.finger * model.finger_penalty[key.finger];
			keys[i] = key;
		}
		const threshold = model.min_triad_count;
		const { kb, kp, ks, k1, k2, k3 } = model.k;
		let kept = 0;
		let dropped = 0;
		let base = 0;
		let penalty = 0;
		let path = 0;
		for (let i = 0; i < triads.n.length; i++) {
			const n = triads.n[i];
			if (n < threshold) continue;
			const a = keys[triads.a[i]];
			const b = keys[triads.b[i]];
			const c = keys[triads.c[i]];
			if (!a || !b || !c) {
				dropped += n;
				continue;
			}
			kept += n;
			base += n * kb * k1 * a.base * (1 + k2 * b.base * (1 + k3 * c.base));
			penalty += n * kp * k1 * a.penalty * (1 + k2 * b.penalty * (1 + k3 * c.penalty));
			const ph = a.hand === c.hand ? (b.hand === c.hand ? 2 : 1) : 0;
			const pr = carpalxRowFlag(a.r, b.r, c.r);
			const pf = carpalxFingerFlag(
				a.finger,
				b.finger,
				c.finger,
				triads.a[i],
				triads.b[i],
				triads.c[i]
			);
			path += n * ks * (ph + 0.3 * pr + 0.3 * pf);
		}
		const per = (v) => (kept > 0 ? v / kept : 0);
		return {
			value: per(base + penalty + path),
			parts: {
				base: per(base),
				penalty: per(penalty),
				path: per(path),
				dropped_triads_pct: pct(dropped, kept + dropped)
			}
		};
	}

	// ========================
	// ======= 6/ keygen ======
	// ========================

	// keygen's finger names, by order from the pinky (0) to the thumb (4).
	const KEYGEN_FINGERS = ['pinky', 'ring', 'middle', 'index', 'thumb'];

	/**
	 * keygen's penalty per character: a base cost per key plus penalties on
	 * the last key given up to three previous keys (same finger, long jumps,
	 * twists, roll reversals, rolls, same-hand and alternating runs of four).
	 * Runs reset on a character outside keygen's own character set; the
	 * four-key runs are estimated from trigrams (Markov).
	 */
	function scoreKeygen(ctx) {
		const model = entry('keygen').model;
		const init = new Set(Array.from(model.init_chars));
		const posOf = new Map(model.pos_to_code.map((code, p) => [code, p]).filter(([c]) => c));
		// keygen fills its character map with the base layer, then the Shift
		// layer, each in key order: a character on two keys takes the last.
		const keyOf = new Map();
		for (const layer of [0, 1])
			for (const code of model.pos_to_code) {
				const cell = code && ctx.layout.rows[code] ? ctx.layout.rows[code][layer] : null;
				if (single(cell)) keyOf.set(cell, { code, layer });
			}
		const keys = new Map();
		const centre = new Set(model.center);
		for (const [char, { code }] of keyOf) {
			if (!init.has(char)) continue;
			const p = posOf.get(code);
			const custom = customModel(ctx);
			const f = custom ? custom.finger.get(code) : undefined;
			const own = f === undefined;
			keys.set(char, {
				pos: p,
				finger: own ? model.finger[p] : KEYGEN_FINGERS[orderOf(f)],
				hand: own ? model.hand[p] : handOf(f) === 0 ? 'L' : 'R',
				row: p >= 32 ? 'thumb' : p >= 22 ? 'bottom' : p >= 11 ? 'home' : 'top',
				center: centre.has(p),
				base: model.base_penalty[p]
			});
		}
		const rollOut = (cur, prev) =>
			({
				thumb: false,
				index: prev === 'thumb',
				middle: prev === 'thumb' || prev === 'index',
				ring: prev !== 'pinky' && prev !== 'ring',
				pinky: prev !== 'pinky'
			})[cur];
		const rollIn = (cur, prev) =>
			({
				thumb: prev !== 'thumb',
				index: prev !== 'thumb' && prev !== 'index',
				middle: prev === 'pinky' || prev === 'ring',
				ring: prev === 'pinky',
				pinky: false
			})[cur];
		const jump = (a, b) =>
			(a.row === 'top' && b.row === 'bottom') || (a.row === 'bottom' && b.row === 'top');
		const p = {
			base: 0,
			same_finger: 0,
			long_jump_hand: 0,
			long_jump: 0,
			long_jump_consecutive: 0,
			pinky_ring_twist: 0,
			roll_reversal: 0,
			same_hand: 0,
			alternating_hand: 0,
			roll_out: 0,
			roll_in: 0,
			long_jump_sandwich: 0,
			twist: 0
		};
		const ok = (char) => init.has(char);
		for (const [c, n] of ctx.table.uni) {
			const k = keys.get(c);
			if (ok(c) && k) p.base += n * k.base;
		}
		for (const [a, b, n] of ctx.table.bi) {
			if (!ok(a) || !ok(b)) continue;
			const cur = keys.get(b);
			const o1 = keys.get(a);
			if (!cur || !o1 || cur.hand !== o1.hand) continue;
			if (cur.finger === o1.finger && cur.pos !== o1.pos)
				p.same_finger += n * (5 + (cur.center ? 5 : 0) + (o1.center ? 5 : 0));
			if (jump(cur, o1)) {
				p.long_jump_hand += n;
				if (cur.finger === o1.finger) p.long_jump += 10 * n;
				const pair = `${cur.finger}/${o1.finger}`;
				if (
					['ring/pinky', 'pinky/ring', 'middle/ring', 'ring/middle'].includes(pair) ||
					(cur.finger === 'index' &&
						(o1.finger === 'middle' || o1.finger === 'ring') &&
						cur.row === 'top' &&
						o1.row === 'bottom')
				)
					p.long_jump_consecutive += 5 * n;
			}
			if (
				(cur.finger === 'ring' &&
					o1.finger === 'pinky' &&
					o1.row === 'top' &&
					(cur.row === 'home' || cur.row === 'bottom')) ||
				(cur.finger === 'pinky' &&
					o1.finger === 'ring' &&
					cur.row === 'top' &&
					(o1.row === 'home' || o1.row === 'bottom'))
			)
				p.pinky_ring_twist += 10 * n;
			if (o1.finger !== 'thumb' && rollOut(cur.finger, o1.finger)) p.roll_out += 0.125 * n;
			if (rollIn(cur.finger, o1.finger)) p.roll_in -= 0.125 * n;
		}
		// Per bigram (b, c) of a trigram's last two keys, the hand of the key
		// before it and after it, for the four-key runs.
		const before = new Map();
		const after = new Map();
		const bump = (map, key, hand, n) => {
			if (!map.has(key)) map.set(key, { L: 0, R: 0 });
			map.get(key)[hand] += n;
		};
		for (const [a, b, c, n] of ctx.table.tri) {
			if (!ok(a) || !ok(b) || !ok(c)) continue;
			const cur = keys.get(c);
			const o1 = keys.get(b);
			const o2 = keys.get(a);
			if (!cur || !o1 || !o2) continue;
			bump(after, a + b, cur.hand, n);
			bump(before, b + c, o2.hand, n);
			if (cur.hand === o1.hand && o1.hand === o2.hand) {
				if (
					(cur.finger === 'middle' && o1.finger === 'pinky' && o2.finger === 'ring') ||
					(cur.finger === 'ring' && o1.finger === 'pinky' && o2.finger === 'middle')
				)
					p.roll_reversal += 20 * n;
				const rows =
					(cur.row === 'top' && o1.row === 'home' && o2.row === 'bottom') ||
					(cur.row === 'bottom' && o1.row === 'home' && o2.row === 'top');
				if (
					rows &&
					((rollOut(cur.finger, o1.finger) && rollOut(o1.finger, o2.finger)) ||
						(rollIn(cur.finger, o1.finger) && rollIn(o1.finger, o2.finger)))
				)
					p.twist += 10 * n;
			}
			if (cur.hand === o2.hand && cur.finger === o2.finger && jump(cur, o2))
				p.long_jump_sandwich += 3 * n;
		}
		for (const [b, c, n] of ctx.table.bi) {
			const left = before.get(b + c);
			const right = after.get(b + c);
			if (!left || !right) continue;
			const hb = keys.get(b).hand;
			const hc = keys.get(c).hand;
			if (hb === hc) p.same_hand += (0.5 * left[hb] * right[hb]) / n;
			else p.alternating_hand += (0.5 * left[hc] * right[hb]) / n;
		}
		// keygen divides by the file's length, line breaks and tabs included:
		// counted in the break tables of ngramsFromText (blank lines and
		// indentation too); a table without them, cut into R runs (characters −
		// bigrams), had at least R − 1 of them.
		const breaks = ctx.table.breaks;
		const runs = ctx.table.totalChars - ctx.table.bi.reduce((sum, entry) => sum + entry[2], 0);
		const length =
			ctx.table.totalChars +
			(breaks ? breaks.uni.reduce((sum, entry) => sum + entry[1], 0) : Math.max(0, runs - 1));
		const parts = {};
		let total = 0;
		for (const [k, v] of Object.entries(p)) {
			parts[k] = length > 0 ? v / length : 0;
			total += parts[k];
		}
		return { value: total, parts };
	}

	// ========================
	// ======= 7/ genkey ======
	// ========================

	/**
	 * genkey's corpus, built from a prepared table: its letters, its bigrams
	 * and its skipgrams. genkey counts a pair of characters g apart (g from 1
	 * to 9, every character between them kept by its filter) with the weight
	 * 1/2^(g−1). The tables hold the gap of 1 (the trigrams); the longer gaps
	 * are carried forward by the trigrams' second-order chain, P(c | a b) =
	 * trigram(abc) / bigram(ab), whose bigram also counts the runs that end
	 * after b, so a run's end stops the chain as genkey's reset does.
	 * @param {object} table - prepareNgrams() output.
	 * @returns {{uni: Map, bi: Map, skip: Map}} Letter → n, pair → n, pair → weight.
	 */
	function genkeyTables(table) {
		const model = entry('genkey').model;
		const norm = genkeyNorm(model);
		const add = (map, key, n) => map.set(key, (map.get(key) || 0) + n);
		const uni = new Map();
		const bi = new Map();
		const tri = new Map();
		for (const [c, n] of table.uni) {
			const x = norm(c);
			if (x) add(uni, x, n);
		}
		for (const [a, b, n] of table.bi) {
			const x = norm(a);
			const y = norm(b);
			if (x && y) add(bi, x + y, n);
		}
		for (const [a, m, b, n] of table.tri) {
			const x = norm(a);
			const y = norm(m);
			const z = norm(b);
			if (x && y && z) add(tri, x + y + z, n);
		}
		const skip = new Map();
		const next = new Map();
		for (const [abc, n] of tri) {
			add(skip, abc[0] + abc[2], n);
			const ab = abc.slice(0, 2);
			if (!next.has(ab)) next.set(ab, []);
			next.get(ab).push([abc[2], n / bi.get(ab)]);
		}
		// chain: (first character, last two) → count, for the current gap.
		let chain = tri;
		for (let gap = 2; gap <= model.skipgram_max_gap; gap++) {
			const weight = model.skipgram_decay ** (gap - 1);
			const longer = new Map();
			for (const [key, n] of chain) {
				const follow = next.get(key.slice(1));
				if (!follow) continue;
				for (const [c, p] of follow) add(longer, key[0] + key[2] + c, n * p);
			}
			for (const [key, n] of longer) add(skip, key[0] + key[2], weight * n);
			chain = longer;
		}
		return { uni, bi, skip };
	}

	/** genkey's character filter: lower case, its substitutions, its valid set. */
	function genkeyNorm(model) {
		const valid = new Set(Array.from(model.valid_chars));
		return (char) => {
			const lower = char.toLowerCase();
			const sub = model.substitutions[lower] || lower;
			return valid.has(sub) ? sub : null;
		};
	}

	/**
	 * genkey's score: weighted finger speed (same-finger bigrams and
	 * skipgrams times squared distance, over each finger's speed), lateral
	 * stretch bigrams and index imbalance; lower is better. Corpus filter:
	 * lower case, a-z , . / ; - ' only, anything else resets.
	 */
	function scoreGenkey(ctx) {
		const model = entry('genkey').model;
		const t = perCorpus(ctx.table, 'genkey:tables', genkeyTables);
		const angle = ctx.layout.fingering === 'angle' || ctx.keyboard === 'iso_angle';
		const rows = ctx.keyboard === 'ansi' ? model.rows_ansi : model.rows_iso;
		const keys = new Map();
		rows.forEach((codes, r) =>
			codes.forEach((code, col) => {
				const row = ctx.layout.rows[code];
				if (!row || typeof row[0] !== 'string' || row[0] === '') return;
				// Its layout reader lower-cases a key and nothing else: a key whose
				// character the corpus filter substitutes (« " » for « ' ») is never
				// typed, and must not take the place of the key the corpus reaches.
				const char = Array.from(row[0])[0].toLowerCase();
				let finger = model.column_fingers[Math.min(col, model.column_fingers.length - 1)];
				if (angle && r === 2 && model.angle_fingers[col] !== undefined)
					finger = model.angle_fingers[col];
				const custom = customModel(ctx);
				if (custom && custom.finger.has(code)) {
					// genkey numbers the eight fingers without the thumbs.
					const f = custom.finger.get(code);
					if (isThumb(f)) return;
					finger = f < LEFT_THUMB ? f : f - 2;
				}
				keys.set(char, { r, col, finger });
			})
		);
		let T = 0;
		const index = [0, 0];
		for (const [c, n] of t.uni) {
			const k = keys.get(c);
			if (!k) continue;
			T += n;
			if (k.finger === 3) index[0] += n;
			if (k.finger === 4) index[1] += n;
		}
		const dist = (a, b) => {
			const dx = a.col - b.col;
			const dy = a.r - b.r;
			return model.lateral * dx * dx + dy * dy + 2 * model.key_travel;
		};
		const speed = new Float64Array(8);
		let lsb = 0;
		const lsbPairs = new Set(model.lsb_finger_pairs.map(([a, b]) => `${a}/${b}`));
		let sfbDistinct = 0;
		for (const [xy, n] of t.bi) {
			const ka = keys.get(xy[0]);
			const kb = keys.get(xy[1]);
			if (!ka || !kb) continue;
			if (ka.finger === kb.finger) {
				speed[ka.finger] += model.sfb * n * dist(ka, kb);
				if (xy[0] !== xy[1]) sfbDistinct += n;
			} else if (
				(lsbPairs.has(`${ka.finger}/${kb.finger}`) || lsbPairs.has(`${kb.finger}/${ka.finger}`)) &&
				Math.abs(ka.col - kb.col) >= model.lsb_min_dx
			)
				lsb += n;
		}
		for (const [xy, n] of t.skip) {
			const ka = keys.get(xy[0]);
			const kb = keys.get(xy[1]);
			if (!ka || !kb || ka.finger !== kb.finger) continue;
			speed[ka.finger] += model.dsfb * n * dist(ka, kb);
		}
		let fspeed = 0;
		const parts = {};
		model.finger_ids.forEach((id, f) => {
			const weighted = T > 0 ? (model.fspeed_scale * speed[f]) / model.kps[f] / T : 0;
			parts[`finger_speed_${id}`] = weighted;
			fspeed += weighted;
		});
		const li = pct(index[0], T);
		const ri = pct(index[1], T);
		parts.finger_speed = fspeed;
		parts.lsb_pct = pct(lsb, T);
		parts.sfb_pct = pct(sfbDistinct, T);
		parts.index_left_pct = li;
		parts.index_right_pct = ri;
		const w = model.weights;
		return {
			value: w.fspeed * fspeed + w.lsb * parts.lsb_pct + w.index_balance * Math.abs(ri - li),
			parts
		};
	}

	// ===========================
	// ======= 8/ Oxeylyzer ======
	// ===========================

	/**
	 * Oxeylyzer's corpus cleaner on one character: a-z and the unshifted
	 * punctuation and digits kept, their Shift forms kept with a Shift token,
	 * every other character (space, accents…) dropped.
	 * @returns {{token: string, shift: boolean}|null} The kept token or null.
	 */
	function oxeyToken(model, char) {
		if (char >= 'a' && char <= 'z') return { token: char, shift: false };
		if (char >= 'A' && char <= 'Z') return { token: char.toLowerCase(), shift: true };
		if (model.unshifted.includes(char)) return { token: char, shift: false };
		if (model.shifted[char] !== undefined) return { token: model.shifted[char], shift: true };
		if (model.one_to_one[char] !== undefined)
			return { token: model.one_to_one[char], shift: false };
		return null;
	}

	/**
	 * Oxeylyzer's token n-grams of a corpus, from the character tables. Its
	 * cleaner writes a Shift token before a capital unless the last character
	 * it kept was shifted too (a dropped character between them does not
	 * release Shift); a dropped character is a gap no n-gram spans. No layout
	 * types the Shift token, so the n-grams through it score nothing but count
	 * in the totals, and a skipgram can span it (x, Shift, y). The Shift state
	 * is read two characters back at most; skip-2 and skip-3 grams are not in
	 * the tables and are taken equal to skip-1.
	 */
	function oxeyTables(table) {
		const model = entry('oxeylyzer').model;
		const tok = new Map();
		const of = (char) => {
			if (!tok.has(char)) tok.set(char, oxeyToken(model, char));
			return tok.get(char);
		};
		const add = (map, key, n) => map.set(key, (map.get(key) || 0) + n);
		const bigrams = new Map();
		const skip = new Map();
		const trigrams = new Map();
		let chars = 0;
		let shiftTokens = 0;
		let bigramTotal = 0;
		let trigramTotal = 0;
		for (const [c, n] of table.uni) {
			const t = of(c);
			if (!t) continue;
			chars += n;
			if (t.shift) shiftTokens += n;
		}
		// Whether t writes a Shift token after the last kept token, prev.
		const shiftAfter = (prev, t) => t.shift && !(prev && prev.shift);
		// Bigrams starting with a capital, to split into run starts and the rest.
		const shiftedFirst = new Map();
		for (const [a, b, n] of table.bi) {
			const x = of(a);
			const y = of(b);
			if (!x || !y) continue;
			bigramTotal += n;
			if (x.shift && y.shift) shiftTokens -= n;
			if (x.shift) add(shiftedFirst, a + b, n);
			if (shiftAfter(x, y)) {
				// x, Shift, y: a token trigram and a skipgram through the Shift token.
				trigramTotal += n;
				add(skip, x.token + y.token, n);
			} else add(bigrams, x.token + y.token, n);
		}
		for (const [a, m, c, n] of table.tri) {
			const x = of(a);
			const y = of(m);
			const z = of(c);
			// Shift held across one dropped character: no new Shift token.
			if (x && !y && z && x.shift && z.shift) shiftTokens -= n;
			// Shift, y, z where y writes the Shift token.
			if (y && z && y.shift) {
				if (shiftAfter(x, y)) trigramTotal += n;
				shiftedFirst.set(m + c, shiftedFirst.get(m + c) - n);
			}
			if (!x || !z) continue;
			const breakAtM = y && shiftAfter(x, y);
			const breakAtZ = shiftAfter(y || x, z);
			if (!breakAtM && !breakAtZ) add(skip, x.token + z.token, n);
			if (!y || breakAtM) continue;
			trigramTotal += n;
			if (!breakAtZ) add(trigrams, x.token + y.token + z.token, n);
		}
		// A capital starting a run writes its Shift token: Shift, y, z.
		for (const n of shiftedFirst.values()) trigramTotal += Math.max(0, n);
		shiftTokens = Math.max(0, shiftTokens);
		return {
			bigrams,
			skip,
			trigrams,
			chars: chars + shiftTokens,
			// Every Shift token starts a bigram with its capital.
			bigramTotal: bigramTotal + shiftTokens,
			trigramTotal
		};
	}

	/** Oxeylyzer's trigram class of three finger numbers (LP 0 … RP 9). */
	function oxeyClass(f1, f2, f3) {
		const thumb = (f) => f === LEFT_THUMB || f === RIGHT_THUMB;
		if (thumb(f1) || thumb(f2) || thumb(f3)) return 'thumb';
		const h1 = handOf(f1);
		const h2 = handOf(f2);
		const h3 = handOf(f3);
		const bad = (f) => f !== 3 && f !== 6;
		if (h1 === h3 && h1 !== h2) return f1 === f3 ? 'alternates_sfs' : 'alternates';
		if (h1 === h2 && h2 === h3) {
			if (f1 === f2 && f2 === f3) return 'sft';
			if (f1 === f2 || f2 === f3) return 'bad_sfb';
			if (f1 < f2 === f2 > f3) {
				const sfs = f1 === f3 ? '_sfs' : '';
				return (bad(f1) && bad(f2) && bad(f3) ? 'bad_redirects' : 'redirects') + sfs;
			}
			return 'onehands';
		}
		if (f1 === f2 || f2 === f3) return 'sfb';
		if (h1 === h2) return (h1 === 0 ? f1 < f2 : f1 > f2) ? 'inrolls' : 'outrolls';
		return (h2 === 0 ? f2 < f3 : f2 > f3) ? 'inrolls' : 'outrolls';
	}

	/**
	 * Oxeylyzer's score: rolls, alternates, onehands and redirects from
	 * trigrams; same-finger bigrams and skipgrams weighted by distance and
	 * finger strength; stretches; pinky-ring bigrams. Higher is better; shown,
	 * as Oxeylyzer does, divided by the characters and by 100. Its letter block
	 * of 3 × 10 keys, on our row-staggered board or on its own ortho grid.
	 */
	function scoreOxeylyzer(ctx) {
		const model = entry('oxeylyzer').model;
		const t = perCorpus(ctx.table, 'oxeylyzer:tables', oxeyTables);
		const ortho = ctx.keyboard === 'ortho';
		const angle = !ortho && (ctx.layout.fingering === 'angle' || ctx.keyboard === 'iso_angle');
		const board = engine().keyboard('ansi');
		const pos = [];
		model.block.forEach((codes, r) =>
			codes.forEach((code, col) => {
				const row = ctx.layout.rows[code];
				const char = row && single(row[0]) ? row[0] : null;
				const fingers = angle && r === 2 ? model.angle_bottom : model.traditional;
				const k = board.index.get(code);
				pos.push({
					char,
					finger: fingerFor(ctx, code, fingerIndex(fingers[col])),
					x: ortho ? col : board.x[k],
					y: r
				});
			})
		);
		const w = model.weights;
		const r = w.sfs / w.sfbs;
		const mix = (a, b, weight) => {
			const s = t.skip.get(a + b) || 0;
			return Math.trunc(((t.bigrams.get(a + b) || 0) + (r + r * r + r * r * r) * s) * weight);
		};
		const both = (a, b, weight) => mix(a, b, weight) + mix(b, a, weight);
		const flen = (f) => model.f_len[['p', 'r', 'm', 'i', 't'][orderOf(f)]];
		const overlap = (f1, f2) =>
			model.x_finger_overlap[`${FINGERS[Math.min(f1, f2)]}-${FINGERS[Math.max(f1, f2)]}`] || 0;
		let fspeed = 0;
		let stretch = 0;
		let pinkyRing = 0;
		let sfb = 0;
		for (let i = 0; i < pos.length; i++) {
			for (let j = i + 1; j < pos.length; j++) {
				const a = pos[i];
				const b = pos[j];
				if (!a.char || !b.char || handOf(a.finger) !== handOf(b.finger)) continue;
				const xo = overlap(a.finger, b.finger);
				let dx = Math.abs(a.x - b.x);
				const dy = Math.abs(a.y + flen(a.finger) - (b.y + flen(b.finger)));
				const ca = a.x + 0.5;
				const cb = b.x + 0.5;
				if ((a.finger > b.finger && ca < cb + xo) || (a.finger < b.finger && ca + xo > cb))
					dx = -dx;
				if (a.finger === b.finger) {
					const d = Math.trunc(
						Math.hypot(dx, dy) *
							100 *
							(model.max_finger_weight / model.finger_weights[FINGERS[a.finger]])
					);
					fspeed += both(a.char, b.char, w.sfbs) * d;
					sfb += (t.bigrams.get(a.char + b.char) || 0) + (t.bigrams.get(b.char + a.char) || 0);
					continue;
				}
				const fd = Math.abs(a.finger - b.finger) * model.stretch.finger_step;
				const extra = Math.max(0, xo - model.stretch.dx_coeff * dx + model.stretch.dy_coeff * dy);
				const s = Math.hypot(dx, dy) + extra - fd;
				if (s > model.stretch.threshold)
					stretch += both(a.char, b.char, w.stretches) * Math.trunc(s * 100);
				const pr = [a.finger, b.finger].sort((p, q) => p - q).join('/');
				if (pr === '0/1' || pr === '8/9')
					pinkyRing +=
						(t.bigrams.get(a.char + b.char) || 0) + (t.bigrams.get(b.char + a.char) || 0);
			}
		}
		pinkyRing *= Math.trunc(w.pinky_ring_bigrams * 100);
		const fingerOf = new Map(pos.filter((p) => p.char).map((p) => [p.char, p.finger]));
		const classes = {};
		let trigram = 0;
		for (const [key, n] of t.trigrams) {
			const c = Array.from(key);
			const f = c.map((ch) => fingerOf.get(ch));
			if (f.includes(undefined)) continue;
			const type = oxeyClass(f[0], f[1], f[2]);
			classes[type] = (classes[type] || 0) + n;
			if (w[type] !== undefined) trigram += Math.trunc(w[type] * 100) * n;
		}
		const total = trigram + stretch + fspeed + pinkyRing;
		const parts = {
			sfb_pct: pct(sfb, t.bigramTotal),
			finger_speed: t.bigramTotal > 0 ? fspeed / t.bigramTotal / 10 : 0,
			stretches: t.bigramTotal > 0 ? (stretch / t.bigramTotal) * 10 : 0
		};
		for (const type of [
			'inrolls',
			'outrolls',
			'onehands',
			'alternates',
			'alternates_sfs',
			'redirects',
			'redirects_sfs',
			'bad_redirects',
			'bad_redirects_sfs'
		])
			parts[type] = pct(classes[type] || 0, t.trigramTotal);
		return { value: t.chars > 0 ? total / t.chars / 100 : 0, parts };
	}

	// ========================
	// ======= 9/ Ergo-L ======
	// ========================

	/**
	 * The key sequence the Ergo-L analyser picks for each character: every
	 * level of every key, then the dead-key compositions (chains included),
	 * the better of two sequences being the one through the one-dead-key, then
	 * the one with fewer keys outside the 3 × 10 block, a lower level, fewer
	 * keys; the first inserted wins a tie.
	 * @returns {Map<string, {code: string, level: number}[]>} Character → keys.
	 */
	function ergolSequences(model, layout) {
		const block = (code) => code.startsWith('Key') || model.block_extra.includes(code);
		const oneDk = new Set(model.one_dead_key_states);
		const usesOneDk = (seq) => seq.some((k) => k.oneDk);
		const better = (old, seq) => {
			if (old.length > 1 && seq.length > 1) {
				if (usesOneDk(seq) && !usesOneDk(old)) return true;
				if (usesOneDk(old) && !usesOneDk(seq)) return false;
			}
			const outside = (s) => s.filter((k) => !block(k.code)).length;
			if (outside(seq) !== outside(old)) return outside(seq) < outside(old);
			const level = (s) => Math.max(...s.map((k) => k.level));
			if (level(seq) !== level(old)) return level(seq) < level(old);
			return seq.length < old.length;
		};
		const chars = new Map();
		const deads = new Map();
		const insert = (map, key, seq) => {
			if (!map.has(key) || better(map.get(key), seq)) map.set(key, seq);
		};
		for (const [code, row] of Object.entries(layout.rows))
			row.forEach((cell, level) => {
				if (cell === null) return;
				if (typeof cell === 'string') {
					if (single(cell)) insert(chars, cell, [{ code, level }]);
				} else insert(deads, cell.dead, [{ code, level, oneDk: oneDk.has(cell.dead) }]);
			});
		if (!chars.has('\n')) chars.set('\n', [{ code: 'Enter', level: 0 }]);
		const expand = (state, seq, depth) => {
			if (depth > model.max_dead_depth) return;
			for (const [base, out] of Object.entries(layout.dead[state] || {})) {
				// A dead key can follow a dead key: Kalamine names the
				// one-dead-key "**" (ë = 1dk, 1dk, d), the engine "dead:<state>",
				// other dead keys by state.
				let tail = chars.get(base);
				if (!tail && base === model.one_dead_key_token)
					tail = model.one_dead_key_states.map((s) => deads.get(s)).find(Boolean);
				else if (!tail && base.startsWith(model.dead_rule_prefix))
					tail = deads.get(base.slice(model.dead_rule_prefix.length));
				else if (!tail) tail = deads.get(base);
				if (!tail) continue;
				const s = seq.concat(tail);
				if (typeof out === 'string') {
					if (single(out)) insert(chars, out, s);
				} else expand(out.dead, s, depth + 1);
			}
		};
		for (const [state, seq] of Array.from(deads.entries())) expand(state, seq, 0);
		for (const [fancy, plain] of Object.entries(model.substitutions))
			if (!chars.has(fancy) && chars.has(plain)) chars.set(fancy, chars.get(plain));
		return chars;
	}

	/**
	 * The Ergo-L analyser's statistics (it gives no score, by design): SFB,
	 * same-key repeats, lateral stretches, scissors, rolls, same-finger
	 * skipgrams, redirects and finger load, on its corpus filter (lower case,
	 * digits and whitespace dropped and cutting the n-grams) with its fixed
	 * ISO fingering.
	 */
	function scoreErgol(ctx) {
		const model = entry('ergol').model;
		const seqs = ergolSequences(model, ctx.layout);
		const finger = new Map();
		for (const [id, codes] of Object.entries(model.fingering))
			for (const code of codes) finger.set(code, id);
		// In « custom » mode the user's fingers; Ergo-L leaves thumb keys unassigned.
		const custom = customModel(ctx);
		if (custom)
			for (const [code, f] of custom.finger) {
				if (isThumb(f)) finger.delete(code);
				else finger.set(code, FINGERS[f]);
			}
		const ignored = new Set(Array.from(model.ignored));
		const fold = perCorpus(ctx.table, 'ergol:tables', (table) => {
			const merge = (rows, size) => {
				const map = new Map();
				for (const row of rows) {
					const chars = row.slice(0, size);
					if (chars.some((c) => ignored.has(c))) continue;
					const key = chars.map((c) => c.toLowerCase()).join('\u0000');
					map.set(key, (map.get(key) || 0) + row[size]);
				}
				return Array.from(map, ([key, n]) => [key.split('\u0000'), n]);
			};
			return { uni: merge(table.uni, 1), bi: merge(table.bi, 2), tri: merge(table.tri, 3) };
		});
		const block = (code) => code.startsWith('Key') || model.block_extra.includes(code);
		const extension = (code) =>
			(code.startsWith('Key') && model.extension_letters.includes(code.slice(3, 4))) ||
			!block(code);
		const rowOf = (code) => {
			const row = model.rows[code];
			return row === undefined ? 0 : row;
		};
		const digit = (code) =>
			Number(finger.get(code)[1] === 'p' ? 5 : { r: 4, m: 3, i: 2 }[finger.get(code)[1]]);
		const windows = (rows, size, classify) => {
			let total = 0;
			const out = {};
			for (const [chars, n] of rows) {
				const keys = [];
				let missing = false;
				for (const c of chars) {
					const seq = seqs.get(c);
					if (seq) keys.push(...seq.map((k) => k.code));
					else {
						keys.push(null);
						missing = true;
					}
				}
				for (let i = 0; i + size <= keys.length; i++) {
					total += n;
					if (missing) continue;
					const w = keys.slice(i, i + size);
					if (w.includes('Space') || w.some((k) => !finger.has(k))) continue;
					const type = classify(w);
					out[type] = (out[type] || 0) + n;
				}
			}
			const shares = {};
			for (const [type, n] of Object.entries(out)) shares[type] = pct(n, total);
			return shares;
		};
		const scissor = (c, p) => {
			const fc = digit(c);
			const fp = digit(p);
			if ((fc === 4 && fp === 5) || (fc === 5 && fp === 4)) {
				const pinky = fc === 5 ? c : p;
				const ring = fc === 5 ? p : c;
				return Math.abs(rowOf(c) - rowOf(p)) >= 1 && !(rowOf(pinky) === 2 && rowOf(ring) === 3);
			}
			return Math.abs(rowOf(c) - rowOf(p)) >= 2;
		};
		const bi = windows(fold.bi, 2, ([p, c]) => {
			if (p === c) return 'skb';
			const fp = finger.get(p);
			const fc = finger.get(c);
			if (fp === fc) return 'sfb';
			if (fp[0] !== fc[0]) return 'hand_change';
			if (scissor(c, p)) return extension(p) || extension(c) ? 'scissor_extended' : 'scissor';
			if (extension(p) || extension(c)) return 'lsb';
			return digit(c) < digit(p) ? 'roll_in' : 'roll_out';
		});
		const tri = windows(fold.tri, 3, ([a, b, c]) => {
			const fa = finger.get(a);
			const fb = finger.get(b);
			const fc = finger.get(c);
			if (fa === fc) return a === c ? 'sks' : 'sfs';
			if (!(fa[0] === fb[0] && fb[0] === fc[0])) return 'other';
			if (fa === fb || fb === fc) return 'other';
			const first = digit(a) > digit(b);
			const second = digit(b) > digit(c);
			if (first !== second)
				return [a, b, c].some((k) => digit(k) === 2) ? 'redirect' : 'redirect_bad';
			return 'other';
		});
		// Finger load over the characters, the extra keys of a sequence added.
		const load = {};
		let unsupported = 0;
		let all = 0;
		let extra = 0;
		for (const [[c], n] of fold.uni) {
			all += n;
			const seq = seqs.get(c);
			if (!seq) {
				unsupported += n;
				continue;
			}
			for (const k of seq)
				if (finger.has(k.code)) load[finger.get(k.code)] = (load[finger.get(k.code)] || 0) + n;
			extra += n * (seq.length - 1);
		}
		const parts = {};
		for (const type of ['sfb', 'skb', 'lsb', 'scissor', 'scissor_extended', 'roll_in', 'roll_out'])
			parts[type] = bi[type] || 0;
		for (const type of ['sfs', 'sks', 'redirect', 'redirect_bad']) parts[type] = tri[type] || 0;
		const denominator = all + extra;
		let left = 0;
		let right = 0;
		for (const id of FINGERS) {
			if (id === 'lt' || id === 'rt') continue;
			const v = pct(load[id] || 0, denominator);
			parts[`finger_${id}`] = v;
			if (id[0] === 'l') left += v;
			else right += v;
		}
		parts.left_hand = left;
		parts.right_hand = right;
		parts.unsupported = pct(unsupported, all);
		return { value: null, parts };
	}

	// ===============================================
	// ======= 10/ Keyboard Layout Optimizer =========
	// ===============================================

	const DG_TYPES = ['Pinky', 'Ring', 'Middle', 'Index', 'Thumb'];

	/**
	 * Keyboard Layout Optimizer's key presses of a layout on its ISO board: each
	 * character takes its cheapest key, held modifiers added (Shift of the other
	 * hand; AltGr on AltRight, our adaptation: the tool models Neo layers, not
	 * AltGr). A modifier press is a key of its own, flagged.
	 */
	function dgStrokes(model, ctx) {
		const layout = ctx.layout;
		const keys = new Map();
		let size = 0;
		const keyOf = (code, mod) => {
			const id = mod ? `${code}:mod` : code;
			if (keys.has(id)) return keys.get(id);
			const k = model.keys[code];
			const f = fingerFor(ctx, code, fingerIndex(k.finger));
			const row = layout.rows[code];
			const key = {
				id,
				index: size++,
				code,
				mod,
				symbol: row && typeof row[0] === 'string' ? row[0] : '',
				col: k.col,
				row: k.row,
				finger: f,
				hand: handOf(f),
				thumb: isThumb(f),
				type: DG_TYPES[orderOf(f)],
				cost: k.cost,
				ux: k.unbalancing[0],
				uy: k.unbalancing[1]
			};
			keys.set(id, key);
			return key;
		};
		const strokes = new Map();
		const best = new Map();
		for (const code of Object.keys(model.keys)) {
			const row = layout.rows[code];
			if (!row) continue;
			const hand = handOf(fingerFor(ctx, code, fingerIndex(model.keys[code].finger)));
			const shift = hand === 0 ? model.shift_keys.right : model.shift_keys.left;
			const mods = [[], [shift], [model.altgr_key], [shift, model.altgr_key]];
			row.forEach((cell, layer) => {
				if (!single(cell) || mods[layer].includes(code)) return;
				const cost =
					model.keys[code].cost + mods[layer].reduce((sum, m) => sum + model.keys[m].cost, 0);
				const old = best.get(cell);
				if (
					old &&
					!(cost < old.cost - model.cost_tie) &&
					!(Math.abs(cost - old.cost) < model.cost_tie && layer < old.layer)
				)
					return;
				best.set(cell, { code, layer, cost, mods: mods[layer] });
			});
		}
		if (!best.has('\n')) best.set('\n', { code: model.enter_key, layer: 0, mods: [] });
		for (const [char, b] of best) {
			// A character of a higher layer is pressed as its base-layer key, the
			// one the tool resolves it to (same index, same base symbol).
			const key = keyOf(b.code, false);
			if (b.layer === 0 && layout.rows[b.code] && layout.rows[b.code][0] === char)
				key.symbol = char;
			strokes.set(char, {
				key: b.layer === 0 ? Object.assign({}, key, { symbol: char }) : key,
				mods: b.mods.map((m) => keyOf(m, true))
			});
		}
		return { strokes, size };
	}

	/**
	 * Keyboard Layout Optimizer's cost of a layout, its default evaluation:
	 * finger balance, hand disbalance, modifier usage, key costs, finger
	 * repeats, movement pattern, no hand switch after an unbalancing key or in a
	 * trigram, irregularity, secondary bigrams and inward and outward rolls, on
	 * key n-grams where held modifiers are presses of their own; lower is
	 * better.
	 */
	function scoreDariogoetz(ctx) {
		const model = entry('dariogoetz').model;
		const W = model.weights;
		const { strokes, size } = dgStrokes(model, ctx);
		const fr = model.finger_repeats;
		const mp = model.movement_pattern;
		const nh = model.no_handswitch_in_trigram;
		const f = model.same_key_mod_factor;
		const inward = (a, b) => (a.hand === 0 ? a.col < b.col : a.col > b.col);
		const outward = (a, b) => (a.hand === 0 ? a.col > b.col : a.col < b.col);
		const fingerRepeat = (a, b) => {
			if ((a.id === b.id && a.mod) || a.hand !== b.hand || a.finger !== b.finger) return 0;
			const factor = fr.finger_factors[a.type];
			if (a.id === b.id) return factor * fr.same_key_offset;
			const up = b.row < a.row;
			const down = b.row > a.row;
			const [line, lat] = a.thumb
				? [Math.abs(a.col - b.col), Math.abs(a.row - b.row)]
				: [Math.abs(a.row - b.row), Math.abs(a.col - b.col)];
			let dir = 1;
			if (a.thumb ? inward(a, b) : up) dir = fr.stretch_factor;
			else if (a.thumb ? outward(a, b) : down) dir = fr.curl_factor;
			return factor * (fr.same_key_offset + dir * line + fr.lateral_factor * lat);
		};
		const movement = (a, b) => {
			if (a.thumb || b.thumb || a.hand !== b.hand || a.finger === b.finger) return 0;
			const d = mp.finger_lengths[a.type] - mp.finger_lengths[b.type];
			const up = b.row < a.row;
			const down = b.row > a.row;
			const dirf = (down && d < 0) || (up && d > 0) ? 1 + Math.abs(d) * mp.direction_factor : 1;
			const unb = 1 + mp.unbalancing_factor * (Math.abs(a.ux - b.ux) + Math.abs(a.uy - b.uy));
			const rows = Math.abs(a.row - b.row);
			const sw = mp.finger_switch[`${a.type.toLowerCase()}>${b.type.toLowerCase()}`] || 0;
			return (mp.same_row_offset + rows * rows) * sw * dirf * unb;
		};
		const unbalancing = (a, b) =>
			a.hand === b.hand && !a.thumb && !b.thumb ? Math.abs(a.ux - b.ux) + Math.abs(a.uy - b.uy) : 0;
		// The three bigram costs of each pair of keys, computed once.
		const pairs = new Float64Array(size * size * 4).fill(Number.NaN);
		const costs = (a, b) => {
			const at = (a.index * size + b.index) * 4;
			if (Number.isNaN(pairs[at])) {
				pairs[at + 1] = fingerRepeat(a, b);
				pairs[at + 2] = movement(a, b);
				pairs[at + 3] = unbalancing(a, b);
				pairs[at] =
					W.finger_repeats * pairs[at + 1] +
					W.movement_pattern * pairs[at + 2] +
					W.no_handswitch_after_unbalancing_key * pairs[at + 3];
			}
			return at;
		};
		const pairCost = (a, b) => pairs[costs(a, b)];
		const raw = {
			modifier_usage: 0,
			key_costs: 0,
			finger_repeats: 0,
			movement_pattern: 0,
			no_handswitch_after_unbalancing_key: 0,
			no_handswitch_in_trigram: 0,
			irregularity: 0,
			secondary_bigrams: 0,
			oxey_inward_rolls: 0,
			oxey_outward_rolls: 0
		};
		const found = { uni: 0, bi: 0, tri: 0 };
		// The tool reads the whole text: Enter is typed, and an n-gram from a line
		// break to another character is left out (below); the break tables of
		// ngramsFromText hold those n-grams, a table without them has none.
		const tables = withBreaks(ctx.table);
		const all = { uni: 0, bi: 0, tri: 0 };
		// Each character's expansion with unit weight, built once: One (the key
		// and its modifiers), Two (the pairs among them) and Three (triples).
		for (const st of strokes.values()) {
			const m = st.mods;
			st.one = [st.key].concat(m);
			st.two = m.map((x) => [[x, st.key], 1]);
			st.three = [];
			for (let i = 0; i < m.length; i++)
				for (let j = i + 1; j < m.length; j++) {
					st.two.push([[m[i], m[j]], f], [[m[j], m[i]], f]);
					st.three.push([[m[i], m[j], st.key], f], [[m[j], m[i], st.key], f]);
				}
		}
		const one = (st) => st.one;
		const two = (st, w) => st.two.map(([pair, factor]) => [pair, w * factor]);
		const three = (st, w) => st.three.map(([triple, factor]) => [triple, w * factor]);
		// Unigrams: finger and hand load, modifier usage, key costs.
		const load = new Float64Array(10);
		for (const [c, n] of tables.uni) {
			all.uni += n;
			const s = strokes.get(c);
			if (!s) continue;
			found.uni += n;
			for (const k of one(s)) {
				load[k.finger] += n;
				if (k.mod) raw.modifier_usage += n;
				raw.key_costs += n * k.cost;
			}
		}
		// Bigrams.
		const bigram = (a, b, w) => {
			if (a.mod && a.id === b.id) return;
			const at = costs(a, b);
			raw.finger_repeats += w * pairs[at + 1];
			raw.movement_pattern += w * pairs[at + 2];
			raw.no_handswitch_after_unbalancing_key += w * pairs[at + 3];
		};
		for (const [c1, c2, n] of tables.bi) {
			all.bi += n;
			// Left out after a line break before any lookup: found, at no cost.
			if (c1 === '\n' && c2 !== '\n') {
				found.bi += n;
				continue;
			}
			const s1 = strokes.get(c1);
			const s2 = strokes.get(c2);
			if (!s1 || !s2) continue;
			found.bi += n;
			bigram(s1.key, s2.key, n);
			for (const m of s1.mods) bigram(m, s2.key, n);
			for (const m of s1.mods) for (const o of s2.mods) bigram(m, o, n);
			for (const o of s2.mods) bigram(s1.key, o, n);
			for (const [[a, b], w] of two(s1, n).concat(two(s2, n))) bigram(a, b, w);
		}
		// Trigrams.
		const nhs = model.secondary_bigrams;
		const trigram = (a, b, c, w) => {
			if (b.mod && (b.id === a.id || b.id === c.id)) return;
			if (
				!a.mod &&
				!b.mod &&
				!c.mod &&
				!a.thumb &&
				!b.thumb &&
				!c.thumb &&
				a.hand === b.hand &&
				b.hand === c.hand
			) {
				let factor;
				if (a.code === b.code && b.code === c.code) factor = nh.factor_same_key;
				else if (a.finger === b.finger || b.finger === c.finger)
					factor = nh.factor_contains_finger_repeat;
				else if (a.code === c.code) factor = nh.factor_same_key_start_end;
				else if ((b.col < a.col && b.col < c.col) || (b.col > a.col && b.col > c.col))
					factor = nh.factor_with_direction_change;
				else factor = nh.factor_without_direction_change;
				if (a.type === 'Index' || b.type === 'Index' || c.type === 'Index')
					factor *= nh.factor_contains_index;
				raw.no_handswitch_in_trigram += w * factor;
			}
			raw.irregularity += Math.max(0, (1 + w * pairCost(a, b)) * (1 + w * pairCost(b, c)) - 1);
			const pause =
				nhs.initial_pause_indicators.includes(a.symbol) &&
				b.symbol === ' ' &&
				!nhs.initial_pause_indicators.includes(c.symbol) &&
				c.symbol !== ' ';
			if (!(a.id === c.id && a.mod) && !pause) {
				const sameHand = a.hand === b.hand && b.hand === c.hand;
				raw.secondary_bigrams +=
					(sameHand ? nhs.factor_no_handswitch : nhs.factor_handswitch) * w * pairCost(a, c);
			}
			const excluded =
				a.thumb ||
				b.thumb ||
				c.thumb ||
				a.mod ||
				b.mod ||
				c.mod ||
				a.symbol === '\n' ||
				b.symbol === '\n' ||
				c.symbol === '\n';
			if (!excluded) {
				let pair = null;
				if (a.hand === b.hand && c.hand !== b.hand) pair = [a, b];
				else if (a.hand !== b.hand && b.hand === c.hand) pair = [b, c];
				if (pair) {
					if (pair[0].finger !== pair[1].finger && inward(pair[0], pair[1]))
						raw.oxey_inward_rolls += w;
					if (outward(pair[0], pair[1])) raw.oxey_outward_rolls += w;
				}
			}
		};
		// The tool sums the weights of the key trigrams first (the ones a
		// character trigram and its modifier expansions share), then costs each
		// once: irregularity is not linear in the weight.
		const gathered = new Map();
		const gather = (a, b, c, w) => {
			const id = (a.index * size + b.index) * size + c.index;
			const old = gathered.get(id);
			if (old) old[3] += w;
			else gathered.set(id, [a, b, c, w]);
		};
		for (const [c1, c2, c3, n] of tables.tri) {
			all.tri += n;
			if ((c1 === '\n' && c2 !== '\n') || (c2 === '\n' && c3 !== '\n')) {
				found.tri += n;
				continue;
			}
			const s1 = strokes.get(c1);
			const s2 = strokes.get(c2);
			const s3 = strokes.get(c3);
			if (!s1 || !s2 || !s3) continue;
			found.tri += n;
			if (s1.mods.length + s2.mods.length + s3.mods.length === 0) {
				gather(s1.key, s2.key, s3.key, n);
				continue;
			}
			const s = [s1, s2, s3];
			const [o1, o2, o3] = s.map(one);
			for (const a of o1) for (const b of o2) for (const c of o3) gather(a, b, c, n);
			for (const [[a, b], w] of two(s[0], n)) for (const c of o2) gather(a, b, c, w);
			for (const a of o1) for (const [[b, c], w] of two(s[1], n)) gather(a, b, c, w);
			for (const [[a, b], w] of two(s[1], n)) for (const c of o3) gather(a, b, c, w);
			for (const a of o2) for (const [[b, c], w] of two(s[2], n)) gather(a, b, c, w);
			for (const st of s) for (const [[a, b, c], w] of three(st, n)) gather(a, b, c, w);
		}
		for (const [a, b, c, w] of gathered.values()) trigram(a, b, c, w);
		raw.irregularity = Math.sqrt(raw.irregularity);
		// Finger balance: sample standard deviation of load over intended load.
		const fingers = FINGERS.map((id, i) => i).filter((i) => !isThumb(i));
		const pressed = fingers.reduce((sum, i) => sum + load[i], 0);
		const intended = fingers.reduce((sum, i) => sum + model.finger_balance_intended[FINGERS[i]], 0);
		const ratios = fingers.map((i) =>
			pressed > 0 ? load[i] / pressed / (model.finger_balance_intended[FINGERS[i]] / intended) : 0
		);
		const mean = ratios.reduce((sum, v) => sum + v, 0) / ratios.length;
		const balance = Math.sqrt(
			ratios.reduce((sum, v) => sum + (v - mean) ** 2, 0) / (ratios.length - 1)
		);
		const left = fingers.filter((i) => handOf(i) === 0).reduce((sum, i) => sum + load[i], 0);
		const disbalance =
			pressed > 0 ? 0.5 * Math.abs(left / pressed - (pressed - left) / pressed) : 0;
		const per = (v, n) => (n > 0 ? v / n : 0);
		const parts = {
			finger_balance: W.finger_balance * balance,
			hand_disbalance: W.hand_disbalance * disbalance,
			modifier_usage: W.modifier_usage * per(raw.modifier_usage, found.uni),
			key_costs: W.key_costs * per(raw.key_costs, found.uni),
			finger_repeats: W.finger_repeats * per(raw.finger_repeats, found.bi),
			movement_pattern: W.movement_pattern * per(raw.movement_pattern, found.bi),
			no_handswitch_after_unbalancing_key:
				W.no_handswitch_after_unbalancing_key *
				per(raw.no_handswitch_after_unbalancing_key, found.bi),
			no_handswitch_in_trigram:
				W.no_handswitch_in_trigram * per(raw.no_handswitch_in_trigram, found.tri),
			irregularity: W.irregularity * per(raw.irregularity, found.tri),
			secondary_bigrams: W.secondary_bigrams * per(raw.secondary_bigrams, found.tri),
			oxey_inward_rolls: W.oxey_inward_rolls * per(raw.oxey_inward_rolls, 0.01 * all.tri),
			oxey_outward_rolls: W.oxey_outward_rolls * per(raw.oxey_outward_rolls, 0.01 * all.tri)
		};
		const value = Object.values(parts).reduce((sum, v) => sum + v, 0);
		parts.not_found_pct = pct(all.uni - found.uni, all.uni);
		return { value, parts };
	}

	// ======================================
	// ======= 11/ Cyanophage optimiser =====
	// ======================================

	/**
	 * Cyanophage's corpus from a prepared table. Its tool reads a list of words
	 * and counts each one as « word » with a space on both sides; the space's
	 * count is then halved and the trigrams seen 30 times or fewer are dropped.
	 * A text is read as its words: lower case, split at whitespace. Every count
	 * of that word list follows from the n-grams inside words, which a table
	 * holds whole (they never span a line break or a tab): a word starts at y
	 * as often as y is not preceded by a letter of its word, L(y) − Σx W(x y),
	 * and a one-character word is counted by inclusion and exclusion.
	 * @param {object} table - prepareNgrams() output.
	 * @returns {{letters: Map, bigrams: Map, trigrams: Map, length: number}}
	 *   Character, bigram and trigram counts and its input length (the
	 *   characters of the words and one space per word).
	 */
	function cyanophageTables(table) {
		const model = entry('cyanophage').model;
		const space = ' ';
		const all = withBreaks(table);
		const lower = new Map();
		// The character of a word list, or null for whitespace (a word break).
		const of = (c) => {
			if (!lower.has(c)) {
				const l = c.toLowerCase();
				lower.set(c, /^\s$/u.test(c) ? null : Array.from(l).length === 1 ? l : c);
			}
			return lower.get(c);
		};
		const add = (map, key, n) => map.set(key, (map.get(key) || 0) + n);
		const letters = new Map();
		const inner2 = new Map();
		const inner3 = new Map();
		for (const [c, n] of all.uni) {
			const x = of(c);
			if (x !== null) add(letters, x, n);
		}
		for (const [a, b, n] of all.bi) {
			const x = of(a);
			const y = of(b);
			if (x !== null && y !== null) add(inner2, x + y, n);
		}
		for (const [a, m, b, n] of all.tri) {
			const x = of(a);
			const y = of(m);
			const z = of(b);
			if (x !== null && y !== null && z !== null) add(inner3, x + y + z, n);
		}
		// Each character's count followed and preceded by a letter of its word,
		// and each inner bigram's count preceded and followed by one.
		const followed = new Map();
		const preceded = new Map();
		for (const [xy, n] of inner2) {
			const [x, y] = Array.from(xy);
			add(followed, x, n);
			add(preceded, y, n);
		}
		const extendedLeft = new Map();
		const extendedRight = new Map();
		const surrounded = new Map();
		for (const [xyz, n] of inner3) {
			const [x, y, z] = Array.from(xyz);
			add(extendedLeft, y + z, n);
			add(extendedRight, x + y, n);
			add(surrounded, y, n);
		}
		const bigrams = new Map(inner2);
		const trigrams = new Map(inner3);
		let words = 0;
		let length = 0;
		for (const [x, n] of letters) {
			const starts = n - (preceded.get(x) || 0);
			const ends = n - (followed.get(x) || 0);
			const alone = starts - (followed.get(x) || 0) + (surrounded.get(x) || 0);
			words += starts;
			length += n;
			if (starts > 0) add(bigrams, space + x, starts);
			if (ends > 0) add(bigrams, x + space, ends);
			if (alone > 0) add(trigrams, space + x + space, alone);
		}
		for (const [xy, n] of inner2) {
			const first = n - (extendedLeft.get(xy) || 0);
			const last = n - (extendedRight.get(xy) || 0);
			if (first > 0) add(trigrams, space + xy, first);
			if (last > 0) add(trigrams, xy + space, last);
		}
		for (const [xyz, n] of trigrams) if (n <= model.trigram_min_count) trigrams.delete(xyz);
		// Two spaces per word, halved.
		letters.set(space, words);
		return { letters, bigrams, trigrams, length: length + words };
	}

	/**
	 * Cyanophage's keys for one layout: each grid cell's character (the base
	 * layer of its key), row, column, finger (1 to 10 from the left pinky, the
	 * thumbs 5 and 6) and effort; the space bar is its fixed thumb key. A
	 * character on two cells takes the later one in the grid's order, as its
	 * worker's lookup does.
	 * @returns {Map<string, {row: number, col: number, finger: number, effort: number}>}
	 */
	function cyanophageKeys(ctx) {
		const model = entry('cyanophage').model;
		const keys = new Map();
		const custom = customModel(ctx);
		for (const cell of model.grid) {
			const row = ctx.layout.rows[cell.code];
			const char = row && single(row[0]) ? row[0] : null;
			if (char === null || char === ' ') continue;
			let finger = cell.finger;
			if (custom && custom.finger.has(cell.code)) finger = custom.finger.get(cell.code) + 1;
			keys.set(char, { row: cell.row, col: cell.col, finger, effort: cell.effort });
		}
		const s = model.space;
		keys.set(' ', { row: s.row, col: s.col, finger: s.finger, effort: s.effort });
		return keys;
	}

	/**
	 * Cyanophage's optimiser score, lower is better: the sum of eleven terms,
	 * each max(0, (metric − its floor) · its weight) but the vowels term, on
	 * its matrix of 3 rows of 12 columns. The metrics: SFB, its pinky and ring
	 * shares, scissors, pinky–ring scissors, wide scissors, lateral stretches
	 * and same-finger skipgrams as a percentage of the input length; effort per
	 * character (each character's grid effort, and again for each character of
	 * every trigram kept, as its worker sums it); the vowels on the minority
	 * hand; the hand imbalance in points. A bigram with a character the layout
	 * lacks is skipped: the worker then reads the previous bigram's key, an
	 * order-dependent slip no table can follow.
	 */
	function scoreCyanophage(ctx) {
		const model = entry('cyanophage').model;
		const t = perCorpus(ctx.table, 'cyanophage:tables', cyanophageTables);
		const keys = cyanophageKeys(ctx);
		const raw = {
			sfb: 0,
			effort: 0,
			psfb: 0,
			rsfb: 0,
			scissors: 0,
			prscissors: 0,
			wide_scissors: 0,
			lsb: 0,
			sfs: 0
		};
		const hands = [0, 0];
		const vowels = [0, 0];
		const vowelSet = new Set(Array.from(model.vowels));
		for (const [c, n] of t.letters) {
			const k = keys.get(c);
			if (!k) continue;
			raw.effort += k.effort * n;
			const hand = k.col <= model.left_last_col ? 0 : 1;
			if (k.row <= model.alpha_last_row) hands[hand] += n;
			if (vowelSet.has(c)) vowels[hand] += 1;
		}
		const pinky = new Set(model.pinkies);
		const ring = new Set(model.rings);
		const pinkyRing = new Set(model.pinky_ring_pairs.map(([a, b]) => `${a}/${b}`));
		const lsbPairs = new Map(model.lsb_pairs.map(([a, b, w]) => [`${a}/${b}`, w]));
		for (const [ab, n] of t.bigrams) {
			const [a, b] = Array.from(ab);
			const k1 = keys.get(a);
			const k2 = keys.get(b);
			if (!k1 || !k2) continue;
			if (k1.finger === k2.finger && a !== b) {
				raw.sfb += n;
				if (pinky.has(k1.finger)) raw.psfb += n;
				if (ring.has(k1.finger)) raw.rsfb += n;
				continue;
			}
			const left = k1.col <= model.left_last_col && k2.col <= model.left_last_col;
			const right = k1.col > model.left_last_col && k2.col > model.left_last_col;
			if ((!left && !right) || k1.row > model.alpha_last_row || k2.row > model.alpha_last_row)
				continue;
			const dRow = Math.abs(k1.row - k2.row);
			const dCol = Math.abs(k1.col - k2.col);
			if (dRow === 2) {
				if (dCol === 1) raw.scissors += n;
				else if (dCol > 1) raw.wide_scissors += n;
			}
			if (pinkyRing.has(`${k1.finger}/${k2.finger}`) && dRow >= 1) raw.prscissors += n;
			const lsb = lsbPairs.get(`${k1.col}/${k2.col}`);
			if (lsb !== undefined) raw.lsb += lsb * n;
		}
		for (const [abc, n] of t.trigrams) {
			const [a, b, c] = Array.from(abc);
			const k1 = keys.get(a);
			const k2 = keys.get(b);
			const k3 = keys.get(c);
			for (const k of [k1, k2, k3]) if (k) raw.effort += k.effort * n;
			// The worker reads a character it lacks as no finger: a skipgram
			// around it still counts.
			if (!k1 || !k3 || k1.finger !== k3.finger || (k2 && k2.finger === k1.finger)) continue;
			if (
				Math.abs(k1.row - k3.row) >= 1 &&
				k1.row <= model.alpha_last_row &&
				k3.row <= model.alpha_last_row
			)
				raw.sfs += n;
		}
		const L = t.length;
		const left = pct(hands[0], hands[0] + hands[1]);
		const parts = {
			sfb: pct(raw.sfb, L),
			effort: L > 0 ? raw.effort / L : 0,
			psfb: pct(raw.psfb, L),
			rsfb: pct(raw.rsfb, L),
			scissors: pct(raw.scissors, L),
			prscissors: pct(raw.prscissors, L),
			wide_scissors: pct(raw.wide_scissors, L),
			lsb: pct(raw.lsb, L),
			sfs: pct(raw.sfs, L),
			vowels: Math.min(vowels[0], vowels[1]),
			hand_balance: Math.abs(left - (100 - left))
		};
		let value = 0;
		for (const [term, { weight, min, clamp }] of Object.entries(model.terms)) {
			const s = (parts[term] - min) * weight;
			value += clamp ? Math.max(0, s) : s;
		}
		return { value, parts };
	}

	// ==========================
	// ======= 12/ Public API ====
	// ==========================

	const SCORERS = {
		kla: scoreKla,
		kla_stevep: scoreKlaStevep,
		klanext: scoreKlanext,
		a200: scoreA200,
		carpalx: scoreCarpalx,
		keygen: scoreKeygen,
		genkey: scoreGenkey,
		cmini: scoreCmini,
		oxeylyzer: scoreOxeylyzer,
		ergol: scoreErgol,
		dariogoetz: scoreDariogoetz,
		cyanophage: scoreCyanophage
	};

	const FINGERINGS = ['official', 'custom'];

	/** The context one layout is scored in, shared by the scorers. */
	function context(layout, ngrams, options) {
		const E = engine();
		const keyboardId = (options && options.keyboard) || 'iso';
		// « official »: every analyser's own fingering; « custom »: the user's
		// finger model, the engine's keyboard(id, profile).
		const fingering = (options && options.fingering) || 'official';
		if (!FINGERINGS.includes(fingering))
			throw new Error(`analyser_scores: unknown fingering ${fingering}`);
		const profile = options ? options.profile : undefined;
		E.keyboard(keyboardId, profile);
		return {
			layout: E.layoutFromRows(layout),
			table: E.prepareNgrams(ngrams),
			keyboard: keyboardId,
			profile,
			custom: fingering === 'custom',
			cache: new Map()
		};
	}

	/** The description of every analyser, in display order. */
	function analysers() {
		return ORDER.map((id) => {
			const e = entry(id);
			return {
				id,
				name: e.name,
				author: e.author,
				url: e.url,
				repository: e.repository,
				revision: e.revision,
				licence: e.licence,
				fidelity: e.fidelity,
				better: e.better,
				unit: e.unit,
				digits: e.digits,
				headline: e.headline || []
			};
		});
	}

	function finish(id, raw) {
		const e = entry(id);
		return Object.assign({ id, better: e.better, fidelity: e.fidelity, unit: e.unit }, raw);
	}

	/**
	 * One layout's score as one analyser computes it.
	 * @param {string} id - An analyser id (see analysers()).
	 * @param {object} layout - Library shape.
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {{keyboard?: string, profile?: object, fingering?: string}} [options] -
	 *   Board (iso, iso_angle, ansi, ortho), the engine's fingering profile, and
	 *   « official » (the analyser's own fingering, the default) or « custom »
	 *   (the user's finger model from the profile).
	 * @returns {{id, value: number|null, better, fidelity, unit, parts: object}}
	 *   value is null for an analyser without a score (its parts are its statistics).
	 * @throws {Error} On an unknown analyser, keyboard or malformed input.
	 */
	function score(id, layout, ngrams, options) {
		if (!SCORERS[id]) throw new Error(`analyser_scores: unknown analyser ${id}`);
		return finish(id, SCORERS[id](context(layout, ngrams, options)));
	}

	/**
	 * One layout's score as every analyser computes it, with its own fingering
	 * and with the user's finger model side by side.
	 * @param {object} layout - Library shape.
	 * @param {object} ngrams - Counts or prepareNgrams() output.
	 * @param {{keyboard?: string, profile?: object}} [options] - As score().
	 * @returns {object} analyser id → {official, custom}, each a score() result.
	 */
	function scoreAll(layout, ngrams, options) {
		const out = {};
		for (const fingering of FINGERINGS) {
			const ctx = context(layout, ngrams, Object.assign({}, options, { fingering }));
			for (const id of ORDER) {
				if (!out[id]) out[id] = {};
				out[id][fingering] = finish(id, SCORERS[id](ctx));
			}
		}
		return out;
	}

	return { ORDER, analysers, score, scoreAll };
})();

// Node (tests) reads the module through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_ANALYSER_SCORES;
