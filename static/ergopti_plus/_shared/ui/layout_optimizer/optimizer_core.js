// _shared/ui/layout_optimizer/optimizer_core.js

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Core
 * DESCRIPTION:
 * Searches key arrangements for the one the layout analysis engine
 * (layout_analysis/analysis_engine.js) scores best on a corpus: simulated
 * annealing over swaps of character pairs, with several restarts, under the
 * constraints the user chose. The score of an arrangement is always the
 * engine's own global score (analyse(...).score.total) with the user's
 * weights: this module measures nothing itself. The design note is
 * docs/design/layout-optimizer.md.
 *
 * FEATURES & RATIONALE:
 * 1. Pure and deterministic: no DOM, no clock unless one is passed, a seeded
 *    generator (mulberry32). The same problem, seed and iteration budget give
 *    the same layout on every machine, in a Web Worker or in Node.
 * 2. Pairs move together: a unit is the pair of cells one level pair of a key
 *    holds (base and Shift, or AltGr and Shift+AltGr), so a letter keeps its
 *    capital on Shift wherever it goes. Space never moves.
 * 3. Every constraint is a switch of the problem (DEFAULT_OPTIONS): which
 *    kinds of units move, whether digits leave the number row, whether the
 *    AltGr levels and a dead key's layer take part, keys pinned where they
 *    are, letters pinned at their QWERTY place (the Ctrl shortcuts), zones.
 * 4. Restarts are independent and numbered: restart k draws from its own seed,
 *    so a page may run them in parallel workers and keep the same result.
 * 5. Fail fast: an impossible constraint throws an OptimizerError with a
 *    stable code the page shows in the reader's language.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a worker or vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_OPTIMIZER = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	/**
	 * The constraints of a problem, each a real switch of the move set. The
	 * defaults move the letters only, on the base and Shift levels, as most
	 * published optimizers do.
	 */
	const DEFAULT_OPTIONS = Object.freeze({
		// Digit units (a digit on either level) may move.
		moveDigits: false,
		// A digit may leave the number row (needs moveDigits).
		digitsOutsideNumberRow: false,
		// A letter may go to the number row.
		lettersOnNumberRow: false,
		// The prose punctuation (PUNCTUATION) may move.
		movePunctuation: false,
		// Other symbols, the dead keys among them, may move.
		moveSymbols: false,
		// The AltGr and Shift+AltGr levels become places too.
		altgr: false,
		// The layer of a dead key becomes places too (deadState, or the largest).
		deadKeyLayer: false,
		deadState: null,
		// Keys whose base and Shift cells never move (KeyboardEvent codes).
		pinnedCodes: [],
		// Letters held at their QWERTY key (the Ctrl/Cmd shortcuts Z X C V…).
		qwertyPins: [],
		// Character → the only codes its unit may sit on.
		zones: {}
	});

	/** The presets of the QWERTY pins the pages offer. */
	const QWERTY_PIN_PRESETS = Object.freeze({
		undo_cut_copy_paste: ['z', 'x', 'c', 'v'],
		select_all_save: ['a', 's']
	});

	// The number row of ISO and ANSI boards.
	const NUMBER_ROW = new Set([
		'Backquote',
		'Digit1',
		'Digit2',
		'Digit3',
		'Digit4',
		'Digit5',
		'Digit6',
		'Digit7',
		'Digit8',
		'Digit9',
		'Digit0',
		'Minus',
		'Equal'
	]);
	// The prose punctuation movePunctuation releases.
	const PUNCTUATION = new Set(Array.from(',.;:!?\'"-’«»…–—'));
	const LEVEL_PAIRS = { key: [0, 1], altgr: [2, 3] };
	// Valid swaps tried before an iteration gives up and counts as rejected.
	const PICK_ATTEMPTS = 32;
	// Swaps measured to set a restart's starting temperature.
	const CALIBRATION_SWAPS = 24;
	// The starting temperature accepts an average worsening half of the time;
	// the last one is this fraction of it (near greedy).
	const FINAL_TEMPERATURE_RATIO = 1e-3;
	// Random valid swaps per movable unit that make a random start.
	const SHUFFLE_SWAPS_PER_UNIT = 20;
	// Scores kept per layout signature: annealing revisits arrangements.
	const CACHE_LIMIT = 20000;

	/** A refusal with a stable code the page translates (layout_optimizer.error.<code>). */
	class OptimizerError extends Error {
		constructor(code, values, message) {
			super(`layout_optimizer: ${message}`);
			this.name = 'OptimizerError';
			this.code = code;
			this.values = values;
		}
	}

	// ===========================
	// ======= 2/ Random =========
	// ===========================

	/**
	 * A seeded generator of floats in [0, 1) (mulberry32).
	 * @param {number} seed - Any integer.
	 * @returns {function(): number}
	 */
	function random(seed) {
		let a = seed >>> 0;
		return function () {
			a = (a + 0x6d2b79f5) >>> 0;
			let t = a;
			t = Math.imul(t ^ (t >>> 15), t | 1);
			t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
			return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
		};
	}

	/** The seed of restart k: the run's seed mixed with k, so restarts differ. */
	function restartSeed(seed, k) {
		let h = (seed ^ Math.imul(k + 1, 0x9e3779b1)) >>> 0;
		h = Math.imul(h ^ (h >>> 16), 0x85ebca6b) >>> 0;
		return (h ^ (h >>> 13)) >>> 0;
	}

	// ============================
	// ======= 3/ Problem =========
	// ============================

	const isLetter = (s) => typeof s === 'string' && /^\p{L}$/u.test(s);
	const isDigit = (s) => typeof s === 'string' && /^[0-9]$/.test(s);
	const isDead = (cell) => cell !== null && typeof cell === 'object';

	/**
	 * What kind of unit a pair of cells is, the first that matches of: empty,
	 * space, digit, letter (on the base level), dead, punctuation, symbol.
	 */
	function kindOf(cells) {
		if (cells.every((cell) => cell === null)) return 'empty';
		if (cells.some((cell) => cell === ' ' || cell === ' ' || cell === ' ')) return 'space';
		if (cells.some(isDigit)) return 'digit';
		// A letter on the base level makes a letter unit; AZERTY's « * µ » is a symbol.
		if (isLetter(cells[0])) return 'letter';
		if (cells.some(isDead)) return 'dead';
		if (cells.some((cell) => typeof cell === 'string' && PUNCTUATION.has(cell)))
			return 'punctuation';
		return 'symbol';
	}

	/** Checks the options, filled with the defaults. */
	function checkedOptions(options) {
		const opts = Object.assign({}, DEFAULT_OPTIONS, options || {});
		for (const key of Object.keys(options || {}))
			if (!(key in DEFAULT_OPTIONS))
				throw new OptimizerError('option_unknown', { option: key }, `unknown option ${key}`);
		for (const key of [
			'moveDigits',
			'digitsOutsideNumberRow',
			'lettersOnNumberRow',
			'movePunctuation',
			'moveSymbols',
			'altgr',
			'deadKeyLayer'
		])
			if (typeof opts[key] !== 'boolean')
				throw new OptimizerError('option_value', { option: key }, `${key} is not a boolean`);
		if (!Array.isArray(opts.pinnedCodes) || !Array.isArray(opts.qwertyPins))
			throw new OptimizerError('option_value', { option: 'pins' }, 'pins are lists');
		if (!opts.zones || typeof opts.zones !== 'object')
			throw new OptimizerError('option_value', { option: 'zones' }, 'zones is an object');
		return opts;
	}

	/** The dead state whose layer becomes places: the chosen one, or the one with most rules. */
	function chosenDeadState(layout, wanted) {
		const entered = new Set();
		for (const row of Object.values(layout.rows))
			for (const cell of row) if (isDead(cell)) entered.add(cell.dead);
		if (wanted !== null) {
			if (!entered.has(wanted))
				throw new OptimizerError(
					'dead_state_unknown',
					{ state: wanted },
					`no key enters ${wanted}`
				);
			return wanted;
		}
		const states = [...entered].sort(
			(a, b) =>
				Object.keys(layout.dead[b] || {}).length - Object.keys(layout.dead[a] || {}).length ||
				(a < b ? -1 : 1)
		);
		if (!states.length)
			throw new OptimizerError('no_dead_key', {}, 'the start layout has no dead key');
		return states[0];
	}

	/**
	 * Builds a problem: the places (slots), the pairs that fill them (units),
	 * where each unit may go, and the start arrangement.
	 * @param {object} engine - LAYOUT_ANALYSIS (its library gives QWERTY).
	 * @param {object} startLayout - The layout to start from (library shape).
	 * @param {object} [options] - See DEFAULT_OPTIONS.
	 * @returns {object} The problem, for createSearch and layoutOf.
	 * @throws {OptimizerError} On an unknown option or an impossible constraint.
	 */
	function problem(engine, startLayout, options) {
		const opts = checkedOptions(options);
		const layout = engine.layoutFromRows(startLayout);
		const codes = new Set(engine.typingCodes());
		const slots = [];
		const units = [];
		const place = (slot, cells) => {
			slot.index = slots.length;
			slots.push(slot);
			units.push({ index: units.length, cells, kind: kindOf(cells) });
		};
		const rowCodes = Object.keys(layout.rows)
			.filter((code) => codes.has(code))
			.sort();
		for (const code of rowCodes)
			place(
				{ kind: 'key', code },
				LEVEL_PAIRS.key.map((i) => layout.rows[code][i])
			);
		if (opts.altgr)
			for (const code of rowCodes)
				place(
					{ kind: 'altgr', code },
					LEVEL_PAIRS.altgr.map((i) => layout.rows[code][i])
				);

		// The dead key's layer: one place per letter of the base level, typed after
		// the dead key (« dead + e »); the place follows its letter, which keeps
		// every rule reachable whatever moves.
		let deadState = null;
		const deadKeys = [];
		if (opts.deadKeyLayer) {
			deadState = chosenDeadState(layout, opts.deadState);
			const rules = layout.dead[deadState] || {};
			for (const unit of units.slice(0, rowCodes.length)) {
				if (unit.kind !== 'letter' || !unit.cells.every((cell) => typeof cell === 'string'))
					continue;
				const read = (typed) => (typeof rules[typed] === 'string' ? rules[typed] : null);
				deadKeys.push(unit.index);
				place({ kind: 'dead', state: deadState, typed: unit.cells.slice() }, [
					read(unit.cells[0]),
					read(unit.cells[1])
				]);
			}
		}

		// Movable units, by kind.
		const pinnedCodes = new Set(opts.pinnedCodes);
		const movableKind = {
			space: false,
			empty: true,
			letter: true,
			digit: opts.moveDigits,
			punctuation: opts.movePunctuation,
			dead: opts.moveSymbols,
			symbol: opts.moveSymbols
		};
		const movable = units.map((unit) => movableKind[unit.kind]);
		for (const slot of slots)
			if (slot.code && pinnedCodes.has(slot.code)) movable[slot.index] = false;
		// The letters typed after the dead key stay on base places, or their rules would be lost.
		const typedLetters = new Set(deadKeys);

		// QWERTY pins: each letter is moved onto its QWERTY key first, then fixed.
		const qwerty = engine.libraryLayouts().find((entry) => entry.id === 'qwerty');
		if (!qwerty) throw new Error('layout_optimizer: the engine library has no qwerty');
		const qwertyCode = {};
		for (const [code, row] of Object.entries(qwerty.rows))
			if (typeof row[0] === 'string') qwertyCode[row[0]] = code;
		const assignment = units.map((unit) => unit.index);
		const slotOfUnit = units.map((unit) => unit.index);
		const fixed = movable.map((m) => !m);
		for (const letter of opts.qwertyPins) {
			const target = qwertyCode[letter];
			const targetSlot = slots.find((slot) => slot.kind === 'key' && slot.code === target);
			const unit = units.find((u) => u.cells[0] === letter);
			if (!target || !unit)
				throw new OptimizerError('pin_missing', { letter }, `${letter} cannot be pinned`);
			if (!targetSlot)
				throw new OptimizerError('pin_missing', { letter }, `${target} is not on the layout`);
			const from = slotOfUnit[unit.index];
			const displaced = assignment[targetSlot.index];
			if (from !== targetSlot.index) {
				if (fixed[unit.index] || fixed[displaced])
					throw new OptimizerError('pin_conflict', { letter }, `${letter} cannot reach ${target}`);
				assignment[targetSlot.index] = unit.index;
				assignment[from] = displaced;
				slotOfUnit[unit.index] = targetSlot.index;
				slotOfUnit[displaced] = from;
			}
			fixed[unit.index] = true;
		}

		const result = {
			layout,
			options: opts,
			slots,
			units,
			deadState,
			start: assignment,
			fixed,
			typedLetters
		};
		result.movable = units.filter((unit) => !fixed[unit.index]).map((unit) => unit.index);
		// Every pinned or fixed unit must already sit where it may.
		assignment.forEach((u, s) => {
			if (!allowed(result, u, s))
				throw new OptimizerError(
					'start_outside_zone',
					{ code: slots[s].code || '' },
					`the start puts a unit where its zone forbids`
				);
		});
		return result;
	}

	/**
	 * Whether unit u may sit in slot s under the problem's constraints.
	 * @param {object} p - From problem().
	 * @param {number} u - Unit index.
	 * @param {number} s - Slot index.
	 * @returns {boolean}
	 */
	function allowed(p, u, s) {
		const unit = p.units[u];
		const slot = p.slots[s];
		// A unit may always stay where the start layout had it, and a hole goes anywhere.
		if (u === s || unit.kind === 'empty') return true;
		if (slot.kind === 'dead') {
			// A dead key never hides behind a dead key, and the typed letters stay put.
			if (unit.kind === 'dead' || unit.cells.some(isDead)) return false;
			if (p.typedLetters.has(u)) return false;
		} else if (p.typedLetters.has(u) && slot.kind !== 'key') return false;
		const numberRow = slot.kind !== 'dead' && NUMBER_ROW.has(slot.code);
		if (unit.kind === 'digit' && !p.options.digitsOutsideNumberRow && !numberRow) return false;
		if (unit.kind === 'letter' && !p.options.lettersOnNumberRow && numberRow) return false;
		for (const cell of unit.cells) {
			const zone = typeof cell === 'string' ? p.options.zones[cell] : undefined;
			if (zone && (slot.kind === 'dead' || !zone.includes(slot.code))) return false;
		}
		return true;
	}

	/**
	 * The layout an arrangement gives (library shape), ready for the engine.
	 * @param {object} p - From problem().
	 * @param {number[]} assignment - Slot index → unit index.
	 * @param {{id?: string, name?: string}} [identity]
	 * @returns {object}
	 */
	function layoutOf(p, assignment, identity) {
		const rows = {};
		for (const [code, row] of Object.entries(p.layout.rows)) rows[code] = row.slice();
		const dead = {};
		for (const [state, rules] of Object.entries(p.layout.dead))
			dead[state] = Object.assign({}, rules);
		if (p.deadState !== null) {
			// The layer's places replace the rules of the letters they follow.
			for (const slot of p.slots)
				if (slot.kind === 'dead') for (const typed of slot.typed) delete dead[p.deadState][typed];
		}
		assignment.forEach((u, s) => {
			const slot = p.slots[s];
			const cells = p.units[u].cells;
			if (slot.kind === 'dead') {
				slot.typed.forEach((typed, i) => {
					if (cells[i] !== null) dead[p.deadState][typed] = cells[i];
				});
				return;
			}
			const levels = LEVEL_PAIRS[slot.kind];
			rows[slot.code][levels[0]] = cells[0];
			rows[slot.code][levels[1]] = cells[1];
		});
		// A Ctrl/Cmd letter that the key now types on its base level needs no entry.
		const command = {};
		for (const [code, letter] of Object.entries(p.layout.command))
			if (!rows[code] || rows[code][0] !== letter) command[code] = letter;
		const id = (identity && identity.id) || `${p.layout.id}_optimized`;
		return {
			id,
			name: (identity && identity.name) || id,
			fingering: p.layout.fingering,
			language: p.layout.language,
			rows,
			dead,
			command
		};
	}

	// ============================
	// ======= 4/ Evaluation ======
	// ============================

	/**
	 * The engine's global score as the objective, with a cache per arrangement.
	 * @param {object} engine - LAYOUT_ANALYSIS.
	 * @param {object} tables - Counts or prepareNgrams() output.
	 * @param {object} [analysis] - The analyse() options (weights, keyboard, format…).
	 * @returns {function(object): number} layout → score.total.
	 */
	function engineObjective(engine, tables, analysis) {
		const prepared = engine.prepareNgrams(tables);
		return (layout) => engine.analyse(layout, prepared, analysis).score.total;
	}

	/**
	 * The engine's global score as the objective, scored incrementally
	 * (LAYOUT_ANALYSIS.scoreSession): a swap walks only the n-grams of the
	 * characters it moves. The search tells it which layout it keeps
	 * (objective.accept), and each later layout is scored against that one.
	 * Equal to engineObjective up to float rounding (the property test of
	 * tools/test/test-layout-optimizer.cjs).
	 * @param {object} engine - LAYOUT_ANALYSIS.
	 * @param {object} tables - Counts or prepareNgrams() output.
	 * @param {object} [analysis] - The analyse() options.
	 * @returns {function(object): number} layout → score.total, with accept(layout).
	 */
	function incrementalObjective(engine, tables, analysis) {
		const prepared = engine.prepareNgrams(tables);
		let session = null;
		let pending = null;
		const objective = (layout) => {
			if (session === null) {
				session = engine.scoreSession(layout, prepared, analysis);
				pending = { layout, commit() {} };
				return session.total;
			}
			const trial = session.trial(layout);
			pending = { layout, commit: trial.commit };
			return trial.total;
		};
		/** Makes layout the one the next layouts are scored against. */
		objective.accept = (layout) => {
			if (session === null) objective(layout);
			else if (pending && pending.layout === layout) pending.commit();
			else session.trial(layout).commit();
			pending = null;
		};
		return objective;
	}

	/**
	 * Keeps the most frequent n-grams that make `share` of each table's count:
	 * a smaller corpus for the search, whose last word is always the full one.
	 * @param {object} engine - LAYOUT_ANALYSIS.
	 * @param {object} tables - Counts or prepareNgrams() output.
	 * @param {number} share - 0 < share ≤ 1.
	 * @returns {object} A prepared table.
	 */
	function searchTables(engine, tables, share) {
		if (!(share > 0 && share <= 1))
			throw new OptimizerError('option_value', { option: 'share' }, 'share is in (0, 1]');
		const prepared = engine.prepareNgrams(tables);
		if (share === 1) return prepared;
		const keep = (entries) => {
			const sorted = entries.slice().sort((a, b) => b[b.length - 1] - a[a.length - 1]);
			const total = sorted.reduce((sum, e) => sum + e[e.length - 1], 0);
			const out = [];
			let sum = 0;
			for (const entry of sorted) {
				if (sum >= share * total) break;
				out.push(entry);
				sum += entry[entry.length - 1];
			}
			return out;
		};
		return {
			prepared: true,
			uni: prepared.uni,
			bi: keep(prepared.bi),
			tri: keep(prepared.tri),
			totalChars: prepared.totalChars
		};
	}

	// ============================
	// ======= 5/ Search ==========
	// ============================

	/**
	 * A random valid arrangement: the start shuffled by random valid swaps of
	 * the movable units (the pinned ones stay where the problem put them).
	 */
	function shuffled(p, next) {
		const assignment = p.start.slice();
		const slotOf = slotsOf(assignment);
		const swaps = SHUFFLE_SWAPS_PER_UNIT * p.movable.length;
		for (let i = 0; i < swaps; i++) {
			const pair = pickSwap(p, assignment, slotOf, next);
			if (pair) swap(assignment, slotOf, pair[0], pair[1]);
		}
		return assignment;
	}

	const slotsOf = (assignment) => {
		const slotOf = new Array(assignment.length);
		assignment.forEach((u, s) => {
			slotOf[u] = s;
		});
		return slotOf;
	};

	function swap(assignment, slotOf, a, b) {
		const sa = slotOf[a];
		const sb = slotOf[b];
		assignment[sa] = b;
		assignment[sb] = a;
		slotOf[a] = sb;
		slotOf[b] = sa;
	}

	/** Two movable units that may trade places, or null after PICK_ATTEMPTS tries. */
	function pickSwap(p, assignment, slotOf, next) {
		const n = p.movable.length;
		if (n < 2) return null;
		for (let i = 0; i < PICK_ATTEMPTS; i++) {
			const a = p.movable[Math.floor(next() * n)];
			const b = p.movable[Math.floor(next() * n)];
			if (a === b) continue;
			// Two holes trading places change nothing.
			if (p.units[a].kind === 'empty' && p.units[b].kind === 'empty') continue;
			if (allowed(p, a, slotOf[b]) && allowed(p, b, slotOf[a])) return [a, b];
		}
		return null;
	}

	/**
	 * A resumable annealing run over several restarts.
	 * @param {object} p - From problem().
	 * @param {{objective: function(object): number, seed?: number, restarts?: number,
	 *   firstRestart?: number, iterations?: number, start?: 'layout'|'random',
	 *   timeBudgetMs?: number, now?: function(): number}} settings - objective scores a
	 *   layout (higher is better, engineObjective); iterations is per restart;
	 *   restarts firstRestart… firstRestart+restarts-1 run (a page splits them
	 *   between workers); start: every restart from the start layout, or each
	 *   from its own random arrangement; timeBudgetMs bounds the whole run, and
	 *   the cooling then follows the clock (now, Date.now by default).
	 * @returns {{step: function(number): object, done: function(): boolean, result: function(): object}}
	 */
	function createSearch(p, settings) {
		const s = Object.assign(
			{ seed: 1, restarts: 1, firstRestart: 0, iterations: 2000, start: 'layout' },
			settings
		);
		if (typeof s.objective !== 'function') throw new Error('layout_optimizer: no objective');
		if (!(Number.isInteger(s.restarts) && s.restarts >= 1))
			throw new OptimizerError('option_value', { option: 'restarts' }, 'restarts ≥ 1');
		if (!(Number.isInteger(s.iterations) && s.iterations >= 0))
			throw new OptimizerError('option_value', { option: 'iterations' }, 'iterations ≥ 0');
		if (s.start !== 'layout' && s.start !== 'random')
			throw new OptimizerError('option_value', { option: 'start' }, 'start is layout or random');
		const timed = s.timeBudgetMs !== undefined;
		const now = s.now || (() => Date.now());
		const began = timed ? now() : 0;
		const budgetPerRestart = timed ? s.timeBudgetMs / s.restarts : Infinity;

		const cache = new Map();
		let evaluations = 0;
		// The layout scored last, which an incremental objective may keep (accept).
		let scored = { key: '', layout: null };
		const score = (assignment) => {
			const key = assignment.join(',');
			if (cache.has(key)) return cache.get(key);
			const layout = layoutOf(p, assignment);
			const value = s.objective(layout);
			if (!Number.isFinite(value)) throw new Error('layout_optimizer: the objective is not finite');
			scored = { key, layout };
			evaluations += 1;
			if (cache.size >= CACHE_LIMIT) cache.clear();
			cache.set(key, value);
			return value;
		};
		/** Tells an incremental objective the arrangement the run now stands on. */
		const accept = (assignment) => {
			if (typeof s.objective.accept !== 'function') return;
			const key = assignment.join(',');
			s.objective.accept(scored.key === key ? scored.layout : layoutOf(p, assignment));
		};

		const startScore = score(p.start);
		let best = { score: startScore, assignment: p.start.slice(), restart: -1 };
		let restart = -1;
		let run = null;
		let stopped = false;

		/** Prepares restart k: its generator, start and temperature. */
		function begin(k) {
			const next = random(restartSeed(s.seed, k));
			const assignment = s.start === 'random' ? shuffled(p, next) : p.start.slice();
			const slotOf = slotsOf(assignment);
			let current = score(assignment);
			accept(assignment);
			// The mean worsening of a few random swaps sets the first temperature.
			let worse = 0;
			let counted = 0;
			for (let i = 0; i < CALIBRATION_SWAPS; i++) {
				const pair = pickSwap(p, assignment, slotOf, next);
				if (!pair) break;
				swap(assignment, slotOf, pair[0], pair[1]);
				const delta = score(assignment) - current;
				swap(assignment, slotOf, pair[0], pair[1]);
				if (delta < 0) {
					worse += -delta;
					counted += 1;
				}
			}
			const t0 = counted > 0 ? worse / counted / Math.LN2 : 1;
			run = {
				k,
				next,
				assignment,
				slotOf,
				current,
				iteration: 0,
				t0,
				began: timed ? now() : 0,
				temperature: t0
			};
			if (current > best.score)
				best = { score: current, assignment: assignment.slice(), restart: k };
		}

		function finished() {
			return stopped || (restart >= s.restarts - 1 && run === null);
		}

		/**
		 * Runs up to `count` iterations.
		 * @returns {object} The progress: restart, iteration, evaluations,
		 *   temperature, current, best (score), startScore, done.
		 */
		function step(count) {
			let left = count;
			while (left > 0 && !finished()) {
				if (run === null) {
					restart += 1;
					begin(s.firstRestart + restart);
				}
				if (timed && now() - began >= s.timeBudgetMs) {
					stopped = true;
					break;
				}
				const fraction = Math.max(
					s.iterations > 0 ? run.iteration / s.iterations : 1,
					timed ? (now() - run.began) / budgetPerRestart : 0
				);
				if (fraction >= 1 || p.movable.length < 2) {
					run = null;
					continue;
				}
				run.temperature = run.t0 * Math.pow(FINAL_TEMPERATURE_RATIO, fraction);
				run.iteration += 1;
				left -= 1;
				const pair = pickSwap(p, run.assignment, run.slotOf, run.next);
				if (!pair) continue;
				swap(run.assignment, run.slotOf, pair[0], pair[1]);
				const value = score(run.assignment);
				const delta = value - run.current;
				if (delta >= 0 || run.next() < Math.exp(delta / run.temperature)) {
					run.current = value;
					accept(run.assignment);
					if (value > best.score)
						best = { score: value, assignment: run.assignment.slice(), restart: run.k };
				} else swap(run.assignment, run.slotOf, pair[0], pair[1]);
			}
			return progress();
		}

		function progress() {
			return {
				restart: run ? run.k : s.firstRestart + Math.max(restart, 0),
				iteration: run ? run.iteration : 0,
				evaluations,
				temperature: run ? run.temperature : 0,
				current: run ? run.current : best.score,
				best: best.score,
				startScore,
				done: finished()
			};
		}

		return {
			step,
			done: finished,
			stop() {
				stopped = true;
			},
			progress,
			/** The best arrangement so far, its layout and score. */
			result(identity) {
				return {
					score: best.score,
					startScore,
					restart: best.restart,
					evaluations,
					assignment: best.assignment.slice(),
					layout: layoutOf(p, best.assignment, identity)
				};
			}
		};
	}

	/**
	 * Runs a whole search at once (Node, a worker).
	 * @param {object} p - From problem().
	 * @param {object} settings - As createSearch, plus onProgress(progress) and
	 *   progressEvery (iterations between two calls, 200 by default).
	 * @returns {object} createSearch's result().
	 */
	function run(p, settings) {
		const search = createSearch(p, settings);
		const every = settings.progressEvery || 200;
		while (!search.done()) {
			const state = search.step(every);
			if (settings.onProgress) settings.onProgress(state, search);
		}
		return search.result(settings.identity);
	}

	/**
	 * The best of several partial results (one per worker): highest score, then
	 * lowest restart, so the split between workers never changes the winner.
	 */
	function bestOf(results) {
		return results.slice().sort((a, b) => b.score - a.score || a.restart - b.restart)[0];
	}

	return {
		DEFAULT_OPTIONS,
		QWERTY_PIN_PRESETS,
		NUMBER_ROW,
		OptimizerError,
		random,
		restartSeed,
		kindOf,
		problem,
		allowed,
		layoutOf,
		engineObjective,
		incrementalObjective,
		searchTables,
		createSearch,
		run,
		bestOf
	};
})();

// Node (tests, tools) reads the module through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_OPTIMIZER;
