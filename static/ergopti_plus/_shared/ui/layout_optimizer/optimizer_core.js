// _shared/ui/layout_optimizer/optimizer_core.js

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Core
 * DESCRIPTION:
 * Searches key arrangements for the one the layout analysis engine
 * (layout_analysis/analysis_engine.js) scores best on a corpus: a local
 * search over swaps of character pairs (simulated annealing by default),
 * with several restarts, under the constraints the user chose. The score of an arrangement is always the
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
 *    are, letters pinned at their QWERTY place (the Ctrl shortcuts), or only
 *    their Ctrl/Cmd shortcut kept on that key while the letter moves, zones,
 *    and the thumb keys, places only when the user names a keyboard that has
 *    them (thumbKeys).
 * 4. Restarts are independent and numbered: restart k draws from its own seed,
 *    so a page may run them in parallel workers and keep the same result.
 * 5. One interface, several search methods (METHODS): simulated annealing,
 *    late-acceptance hill climbing, tabu search, a steady-state genetic
 *    algorithm and best-improvement hill climbing with kicks. Each is a pair
 *    begin(run) / iterate(run, fraction) over the same restarts, scorer,
 *    change penalty and constraints; one iteration is one scored trial, so
 *    an iteration budget is the same work for every method.
 * 6. Fail fast:an impossible constraint throws an OptimizerError with a
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
		// Letters whose Ctrl/Cmd shortcut stays on their QWERTY key (the layout's
		// command map) while the letter itself may move.
		qwertyShortcuts: [],
		// Character → the only codes its unit may sit on.
		zones: {},
		// The keyboard (a LAYOUT_ANALYSIS keyboard id) whose thumb keys
		// (LAYOUT_ANALYSIS.thumbKeys: NonConvert, Convert, KanaMode) become
		// places; null keeps them out of the search: nothing moves onto a thumb
		// key, and the start layout's thumb characters stay where they are.
		thumbKeys: null,
		// At most this many units (a character and its Shift pair) off the key
		// and level the start layout gives them; null sets no limit.
		maxChanges: null
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

	// The search methods a run may use (createSearch's `method`), in the order
	// the page lists them; the design note's benchmark chose the default.
	const METHODS = Object.freeze([
		'annealing',
		'late_acceptance',
		'tabu',
		'genetic',
		'hill_climbing'
	]);
	const DEFAULT_METHOD = 'annealing';
	// A move counts as an improvement only past this gain: the incremental
	// score of one arrangement may differ in its last bits by the path to it.
	const IMPROVEMENT_EPSILON = 1e-9;
	// Late acceptance: a candidate is kept when it beats the current
	// arrangement or the one this many trials ago (Burke and Bykov, 2017).
	const LATE_ACCEPTANCE_HISTORY = 50;
	// Tabu search: random valid swaps drawn and scored per move, the best of
	// them made even when it loses; the two units it moves may not move again
	// for a quarter of the movable units' count, within these bounds.
	const TABU_CANDIDATES = 24;
	const TABU_TENURE_MIN = 3;
	const TABU_TENURE_MAX = 12;
	// Genetic algorithm (steady state): the population, the tournament that
	// picks each parent, the chance a child is a crossover of two parents
	// (else a copy of the first), the chance of each further mutation swap
	// after the first, and the most swaps that make a seed individual from
	// the start.
	const GENETIC_POPULATION = 24;
	const GENETIC_TOURNAMENT = 3;
	const GENETIC_CROSSOVER = 0.7;
	const GENETIC_MORE_MUTATION = 0.5;
	const GENETIC_SEED_SWAPS = 8;
	// Hill climbing: random valid swaps that kick a local optimum before the
	// next climb (an iterated local search from the restart's best optimum).
	const HILL_KICK_SWAPS = 3;

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
		if (
			!Array.isArray(opts.pinnedCodes) ||
			!Array.isArray(opts.qwertyPins) ||
			!Array.isArray(opts.qwertyShortcuts)
		)
			throw new OptimizerError('option_value', { option: 'pins' }, 'pins are lists');
		if (!opts.zones || typeof opts.zones !== 'object')
			throw new OptimizerError('option_value', { option: 'zones' }, 'zones is an object');
		if (opts.thumbKeys !== null && typeof opts.thumbKeys !== 'string')
			throw new OptimizerError(
				'option_value',
				{ option: 'thumbKeys' },
				'thumbKeys is a keyboard id or null'
			);
		if (opts.maxChanges !== null && !(Number.isInteger(opts.maxChanges) && opts.maxChanges >= 0))
			throw new OptimizerError(
				'option_value',
				{ option: 'maxChanges' },
				'maxChanges is an integer ≥ 0 or null'
			);
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
		const layout = withQwertyShortcuts(
			engine,
			engine.layoutFromRows(startLayout),
			opts.qwertyShortcuts
		);
		const codes = new Set(engine.typingCodes());
		const slots = [];
		const units = [];
		const place = (slot, cells) => {
			slot.index = slots.length;
			slots.push(slot);
			units.push({ index: units.length, cells, kind: kindOf(cells) });
		};
		// The thumb keys are places only on a keyboard that has them, when asked;
		// those the start layout leaves empty join as holes.
		const thumbCodes = new Set(engine.thumbKeys());
		const thumbPlaces = new Set();
		if (opts.thumbKeys !== null) {
			const board = engine.keyboard(opts.thumbKeys);
			for (const code of thumbCodes) if (board.index.has(code)) thumbPlaces.add(code);
			if (thumbPlaces.size === 0)
				throw new OptimizerError(
					'thumb_keys_absent',
					{ keyboard: opts.thumbKeys },
					`${opts.thumbKeys} has no thumb key`
				);
		}
		const rowCodes = Object.keys(layout.rows)
			.filter((code) => codes.has(code))
			.concat([...thumbPlaces].filter((code) => !layout.rows[code]))
			.sort();
		const cellsOf = (code, levels) =>
			levels.map((i) => (layout.rows[code] ? layout.rows[code][i] : null));
		for (const code of rowCodes) place({ kind: 'key', code }, cellsOf(code, LEVEL_PAIRS.key));
		if (opts.altgr)
			for (const code of rowCodes) place({ kind: 'altgr', code }, cellsOf(code, LEVEL_PAIRS.altgr));

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
		// A thumb key outside the search keeps what the start puts there, a hole too.
		for (const slot of slots)
			if (slot.code && thumbCodes.has(slot.code) && !thumbPlaces.has(slot.code))
				movable[slot.index] = false;
		// The letters typed after the dead key stay on base places, or their rules would be lost.
		const typedLetters = new Set(deadKeys);

		// QWERTY pins: each letter is moved onto its QWERTY key first, then fixed.
		const qwertyCode = qwertyCodes(engine);
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
		// Zones: a character outside its zone is moved first onto the first key of
		// the zone whose unit may take its place, as the QWERTY pins are.
		for (const [char, codes] of Object.entries(opts.zones)) {
			if (!Array.isArray(codes) || !codes.length || codes.some((code) => typeof code !== 'string'))
				throw new OptimizerError(
					'option_value',
					{ option: 'zones' },
					`zone of ${char} is no key list`
				);
			const unit = units.find((u) => u.cells.includes(char));
			if (!unit) throw new OptimizerError('zone_missing', { char }, `${char} is not on the layout`);
			const from = slotOfUnit[unit.index];
			if (allowed(result, unit.index, from)) continue;
			const target = fixed[unit.index]
				? undefined
				: codes
						.map((code) => slots.find((slot) => slot.kind === 'key' && slot.code === code))
						.find(
							(slot) =>
								slot &&
								!fixed[assignment[slot.index]] &&
								allowed(result, unit.index, slot.index) &&
								allowed(result, assignment[slot.index], from)
						);
			if (!target)
				throw new OptimizerError('zone_unreachable', { char }, `${char} cannot reach its zone`);
			const displaced = assignment[target.index];
			assignment[target.index] = unit.index;
			assignment[from] = displaced;
			slotOfUnit[unit.index] = target.index;
			slotOfUnit[displaced] = from;
		}
		// Every pinned or fixed unit must already sit where it may.
		assignment.forEach((u, s) => {
			if (!allowed(result, u, s))
				throw new OptimizerError(
					'start_outside_zone',
					{ code: slots[s].code || '' },
					`the start puts a unit where its zone forbids`
				);
		});
		// The QWERTY pins and zones move units before the search: they count.
		const forced = changedUnits(result, assignment).length;
		if (opts.maxChanges !== null && forced > opts.maxChanges)
			throw new OptimizerError(
				'change_limit_start',
				{ count: forced, limit: opts.maxChanges },
				`the pins and zones already move ${forced} characters, over ${opts.maxChanges}`
			);
		return result;
	}

	/** Each letter of QWERTY's base level → its key. */
	function qwertyCodes(engine) {
		const qwerty = engine.libraryLayouts().find((entry) => entry.id === 'qwerty');
		if (!qwerty) throw new Error('layout_optimizer: the engine library has no qwerty');
		const out = {};
		for (const [code, row] of Object.entries(qwerty.rows))
			if (typeof row[0] === 'string') out[row[0]] = code;
		return out;
	}

	/**
	 * The start layout with each chosen letter's Ctrl/Cmd shortcut on its QWERTY
	 * key (its command map, which the engine's shortcut_left reads and the
	 * search never moves): Ctrl+the key Z of QWERTY stays « undo » wherever z
	 * goes. Another key's shortcut to the same letter is dropped.
	 * @param {object} engine - LAYOUT_ANALYSIS.
	 * @param {object} layout - The checked start layout (not changed).
	 * @param {string[]} letters - Lowercase letters.
	 * @returns {object} The layout, with its own command map when letters are given.
	 * @throws {OptimizerError} shortcut_missing when the layout lacks the letter
	 *   on a base level, or the letter's QWERTY key.
	 */
	function withQwertyShortcuts(engine, layout, letters) {
		if (!letters.length) return layout;
		const qwertyCode = qwertyCodes(engine);
		const command = Object.assign({}, layout.command);
		for (const letter of letters) {
			const target = qwertyCode[letter];
			const typed = Object.values(layout.rows).some((row) => row[0] === letter);
			if (typeof letter !== 'string' || !target || !layout.rows[target] || !typed)
				throw new OptimizerError(
					'shortcut_missing',
					{ letter: String(letter) },
					`the shortcut of ${letter} cannot stay on its QWERTY key`
				);
			for (const [code, made] of Object.entries(command)) if (made === letter) delete command[code];
			command[target] = letter;
		}
		return Object.assign({}, layout, { command });
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
		// A hole goes anywhere; a zoned character never leaves its zone, not even
		// for its start key; otherwise a unit may always stay where the start had it.
		if (unit.kind === 'empty') return true;
		for (const cell of unit.cells) {
			const zone = typeof cell === 'string' ? p.options.zones[cell] : undefined;
			if (zone && (slot.kind === 'dead' || !zone.includes(slot.code))) return false;
		}
		if (u === s) return true;
		if (slot.kind === 'dead') {
			// A dead key never hides behind a dead key, and the typed letters stay put.
			if (unit.kind === 'dead' || unit.cells.some(isDead)) return false;
			if (p.typedLetters.has(u)) return false;
		} else if (p.typedLetters.has(u) && slot.kind !== 'key') return false;
		const numberRow = slot.kind !== 'dead' && NUMBER_ROW.has(slot.code);
		if (unit.kind === 'digit' && !p.options.digitsOutsideNumberRow && !numberRow) return false;
		if (unit.kind === 'letter' && !p.options.lettersOnNumberRow && numberRow) return false;
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
		return arrange(p, assignment, identity, copiedDead(p.layout.dead));
	}

	/** A copy of a layout's dead-key tables, one level deep (each state's rules). */
	const copiedDead = (source) => {
		const dead = {};
		for (const [state, rules] of Object.entries(source)) dead[state] = Object.assign({}, rules);
		return dead;
	};

	// Problem → the dead-key tables its scored layouts share (read-only).
	const sharedDeadOf = new WeakMap();

	/**
	 * The layout an arrangement gives, for the objective only: the dead-key
	 * tables the search leaves alone are one object shared by every such
	 * layout, so the engine's incremental compile sees at once that their
	 * rules did not change (its caches are keyed by that object). Never handed
	 * out: layoutOf gives the result its own copy.
	 */
	function scoredLayoutOf(p, assignment) {
		if (!sharedDeadOf.has(p)) sharedDeadOf.set(p, copiedDead(p.layout.dead));
		const shared = sharedDeadOf.get(p);
		if (p.deadState === null) return arrange(p, assignment, null, shared);
		// The layer's state changes with the arrangement; the other states stay shared.
		const dead = Object.assign({}, shared);
		dead[p.deadState] = Object.assign({}, shared[p.deadState]);
		return arrange(p, assignment, null, dead);
	}

	/** layoutOf's body, with the dead-key tables to fill (the layer's state is written into). */
	function arrange(p, assignment, identity, dead) {
		const rows = {};
		for (const [code, row] of Object.entries(p.layout.rows)) rows[code] = row.slice();
		// A thumb key the start left empty is a row only once something lands on it.
		for (const slot of p.slots)
			if (slot.code && !rows[slot.code]) rows[slot.code] = [null, null, null, null];
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
		for (const code of Object.keys(rows))
			if (!p.layout.rows[code] && rows[code].every((cell) => cell === null)) delete rows[code];
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
	// ======= 5/ Changes =========
	// ============================

	/**
	 * The units holding a character (a hole aside) that an arrangement puts
	 * off their home, the slot the start layout gives them (the problem makes
	 * one unit per slot, in slot order, so unit u's home is slot u): what « at
	 * most N changed characters » counts, a letter and its capital being one
	 * unit. The QWERTY pins and zones count as changes.
	 * @param {object} p - From problem().
	 * @param {number[]} assignment - Slot index → unit index.
	 * @returns {number[]} Unit indices, in order.
	 */
	function changedUnits(p, assignment) {
		const out = [];
		assignment.forEach((u, s) => {
			if (u !== s && p.units[u].kind !== 'empty') out.push(u);
		});
		return out.sort((a, b) => a - b);
	}

	/**
	 * The cost of leaving the start layout, weighted by the corpus: the share
	 * of the characters typed (each by its occurrences, the space left out:
	 * LAYOUT_ANALYSIS.similarityWeights, the weighting of layoutSimilarity)
	 * whose keys change. A character is typed by the units on its way in the
	 * start layout: its own cell on a key or AltGr level, else the dead key
	 * that enters its rule and the letter typed after it (and the dead-key
	 * layer's place when that layer moves). It has changed when any of those
	 * units has left its home: 100 − layoutSimilarity's weighted sameKey for
	 * the arrangements a search makes. A character reached only through a
	 * chain of dead keys is left out, as one the start does not type.
	 * @param {object} engine - LAYOUT_ANALYSIS.
	 * @param {object} p - From problem().
	 * @param {object} tables - Counts or prepareNgrams() output.
	 * @returns {{total: number, share: function(number): number,
	 *   moved: function(number[]): number, tracker: function(number[]): object,
	 *   changed: function(number[]): object}} total: the weight of every
	 *   character weighed; share(weight) in %; moved(assignment) the weight
	 *   it moves, recomputed; tracker(assignment) follows swaps; changed()
	 *   says what an arrangement moves.
	 */
	function changeCost(engine, p, tables) {
		return costOf(p, engine.similarityWeights(tables), engine.substitutions());
	}

	/**
	 * changeCost's body, on each character's weight (character → occurrences)
	 * and the engine's substitutions (fancy character → plain text).
	 */
	function costOf(p, weighed, substituted) {
		const keyUnitOf = new Map();
		const deadUnitOf = new Map();
		p.units.forEach((unit, u) => {
			if (p.slots[u].kind === 'dead') return;
			for (const cell of unit.cells) {
				if (typeof cell === 'string' && !keyUnitOf.has(cell)) keyUnitOf.set(cell, u);
				if (isDead(cell) && !deadUnitOf.has(cell.dead)) deadUnitOf.set(cell.dead, u);
			}
		});
		// What the start types on cells no unit holds (a level or key outside
		// the search): those never move, but they weigh as typed characters.
		const typedCells = new Set();
		const enteredStates = new Set();
		for (const row of Object.values(p.layout.rows))
			for (const cell of row) {
				if (typeof cell === 'string') typedCells.add(cell);
				if (isDead(cell)) enteredStates.add(cell.dead);
			}
		const typedKey = (char) => keyUnitOf.has(char) || typedCells.has(char);
		// The units among a way's dead key and typed letter; a fixed one adds none.
		const unitsOf = (state, typed) =>
			[deadUnitOf.get(state), keyUnitOf.get(typed)].filter((u) => u !== undefined);
		/** The units on a character's way in the start layout ([] if none moves), or null. */
		const wayOf = (char) => {
			if (keyUnitOf.has(char)) return [keyUnitOf.get(char)];
			if (typedCells.has(char)) return [];
			for (const slot of p.slots) {
				if (slot.kind !== 'dead') continue;
				const i = p.units[slot.index].cells.indexOf(char);
				if (i >= 0) return [slot.index].concat(unitsOf(slot.state, slot.typed[i]));
			}
			for (const state of Object.keys(p.layout.dead).sort()) {
				if (!enteredStates.has(state)) continue;
				for (const [typed, made] of Object.entries(p.layout.dead[state]))
					if (made === char && typedKey(typed)) return unitsOf(state, typed);
			}
			return null;
		};
		/** wayOf, or a character the start lacks typed as its plain form (the engine's ways). */
		const wayOrPlain = (char) => {
			const way = wayOf(char);
			if (way !== null || !Object.prototype.hasOwnProperty.call(substituted, char)) return way;
			const parts = Array.from(substituted[char], wayOf);
			return parts.some((part) => part === null) ? null : [].concat(...parts);
		};
		const weights = [];
		const ways = [];
		const charsOf = p.units.map(() => []);
		for (const [char, n] of weighed) {
			const way = wayOrPlain(char);
			if (!way) continue;
			const c = weights.length;
			weights.push(n);
			ways.push(Array.from(new Set(way)));
			for (const u of ways[c]) charsOf[u].push(c);
		}
		const total = weights.reduce((sum, n) => sum + n, 0);
		const share = (weight) => {
			if (!(total > 0))
				throw new OptimizerError('change_empty', {}, 'the corpus types no character to weigh');
			return (100 * weight) / total;
		};
		const awayIn = (slotOf, u) => slotOf[u] !== u;
		/** The weight of the characters an arrangement moves, recomputed from nothing. */
		const movedOf = (slotOf) => {
			let sum = 0;
			ways.forEach((way, c) => {
				if (way.some((u) => awayIn(slotOf, u))) sum += weights[c];
			});
			return sum;
		};

		/**
		 * Follows one arrangement swap by swap: a swap of units a and b walks
		 * only the characters whose way holds a or b.
		 * @param {number[]} assignment - The arrangement it starts on (copied).
		 */
		function tracker(assignment) {
			const slotOf = slotsOf(assignment);
			const isAway = p.units.map((unit, u) => (awayIn(slotOf, u) ? 1 : 0));
			const out = ways.map((way) => way.reduce((n, u) => n + isAway[u], 0));
			const seen = new Uint32Array(weights.length);
			let stamp = 0;
			let moved = 0;
			out.forEach((n, c) => {
				if (n > 0) moved += weights[c];
			});
			const counts = (u) => p.units[u].kind !== 'empty';
			let units = isAway.reduce((n, flag, u) => n + (flag && counts(u) ? 1 : 0), 0);
			/** Each unit's home flag once a and b trade places. */
			const after = (a, b) => [slotOf[b] !== a ? 1 : 0, slotOf[a] !== b ? 1 : 0];
			/** The moved weight a swap adds; write keeps its counts. */
			const walk = (a, b, write) => {
				const [na, nb] = after(a, b);
				const da = na - isAway[a];
				const db = nb - isAway[b];
				if (da === 0 && db === 0) return 0;
				let delta = 0;
				stamp += 1;
				for (const u of [a, b])
					for (const c of charsOf[u]) {
						if (seen[c] === stamp) continue;
						seen[c] = stamp;
						const way = ways[c];
						const next = out[c] + (way.includes(a) ? da : 0) + (way.includes(b) ? db : 0);
						if (out[c] > 0 !== next > 0) delta += next > 0 ? weights[c] : -weights[c];
						if (write) out[c] = next;
					}
				return delta;
			};
			const unitsAfter = (a, b) => {
				const [na, nb] = after(a, b);
				return units + (counts(a) ? na - isAway[a] : 0) + (counts(b) ? nb - isAway[b] : 0);
			};
			return {
				/** The moved weight of the arrangement followed. */
				moved: () => moved,
				/** Its changed units, holes aside. */
				units: () => units,
				/** The moved weight if a and b traded places; nothing changes. */
				trial: (a, b) => moved + walk(a, b, false),
				/** The changed units if a and b traded places. */
				unitsAfter,
				/** Follows the swap of a and b (the caller swaps its own arrangement). */
				swap(a, b) {
					const [na, nb] = after(a, b);
					units = unitsAfter(a, b);
					moved += walk(a, b, true);
					isAway[a] = na;
					isAway[b] = nb;
					const sa = slotOf[a];
					slotOf[a] = slotOf[b];
					slotOf[b] = sa;
				}
			};
		}

		return {
			total,
			share,
			moved: (assignment) => movedOf(slotsOf(assignment)),
			tracker,
			/**
			 * What an arrangement changes: the share of the corpus's characters
			 * it moves, and the units it moves, each with its cells and the
			 * share of the characters it carries, most weighed first.
			 * @param {number[]} assignment
			 * @returns {{share: number, count: number, units: {cells: Array, share: number}[]}}
			 */
			changed(assignment) {
				const slotOf = slotsOf(assignment);
				const weigh = (weight) => (total > 0 ? share(weight) : 0);
				const units = changedUnits(p, assignment).map((u) => {
					let weight = 0;
					for (const c of charsOf[u]) if (ways[c][0] === u) weight += weights[c];
					return { u, cells: p.units[u].cells.slice(), weight };
				});
				units.sort((x, y) => y.weight - x.weight || x.u - y.u);
				return {
					share: weigh(movedOf(slotOf)),
					count: units.length,
					units: units.map((entry) => ({ cells: entry.cells, share: weigh(entry.weight) }))
				};
			}
		};
	}

	// ============================
	// ======= 6/ Search ==========
	// ============================

	/**
	 * A random valid arrangement: the start shuffled by random valid swaps of
	 * the movable units (the pinned ones stay where the problem put them).
	 */
	function shuffled(p, next) {
		const assignment = p.start.slice();
		const slotOf = slotsOf(assignment);
		// Under a change limit the shuffle stays within it, as every swap of the search does.
		const limit = p.options.maxChanges;
		const follow = limit === null ? null : homeTracker(p, assignment);
		const swaps = SHUFFLE_SWAPS_PER_UNIT * p.movable.length;
		for (let i = 0; i < swaps; i++) {
			const pair = pickSwap(p, assignment, slotOf, next, follow);
			if (!pair) continue;
			if (follow) follow.swap(pair[0], pair[1]);
			swap(assignment, slotOf, pair[0], pair[1]);
		}
		return assignment;
	}

	/** A tracker of the changed units alone (no corpus), for the change limit. */
	function homeTracker(p, assignment) {
		return costOf(p, new Map(), {}).tracker(assignment);
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

	/**
	 * Two movable units that may trade places, or null after PICK_ATTEMPTS
	 * tries; with a change limit (p.options.maxChanges), only a swap that
	 * keeps the changed units within it (follow: the arrangement's tracker).
	 */
	function pickSwap(p, assignment, slotOf, next, follow) {
		const n = p.movable.length;
		if (n < 2) return null;
		const limit = p.options.maxChanges;
		for (let i = 0; i < PICK_ATTEMPTS; i++) {
			const a = p.movable[Math.floor(next() * n)];
			const b = p.movable[Math.floor(next() * n)];
			if (a === b) continue;
			// Two holes trading places change nothing.
			if (p.units[a].kind === 'empty' && p.units[b].kind === 'empty') continue;
			if (!allowed(p, a, slotOf[b]) || !allowed(p, b, slotOf[a])) continue;
			if (limit !== null && follow.unitsAfter(a, b) > limit) continue;
			return [a, b];
		}
		return null;
	}

	/**
	 * A valid arrangement whose every unit sits where parent a or parent b
	 * has it (cycle crossover): each cycle of the two permutations comes
	 * whole from one parent, drawn at random. Any constraint a place puts on
	 * its unit (allowed) therefore holds without repair, and the fixed units,
	 * on the same slot in both parents, stay there.
	 * @param {number[]} a - Slot index → unit index.
	 * @param {number[]} b - The other parent, a permutation of the same units.
	 * @param {function(): number} next - The generator.
	 * @returns {number[]}
	 */
	function cycleCrossover(a, b, next) {
		const slotInA = slotsOf(a);
		const child = new Array(a.length).fill(-1);
		for (let s = 0; s < a.length; s++) {
			if (child[s] !== -1) continue;
			const from = next() < 0.5 ? a : b;
			let at = s;
			do {
				child[at] = from[at];
				at = slotInA[b[at]];
			} while (at !== s);
		}
		return child;
	}

	/**
	 * A resumable search over several restarts.
	 * @param {object} p - From problem().
	 * @param {{objective: function(object): number, method?: string, seed?: number,
	 *   restarts?: number, firstRestart?: number, iterations?: number,
	 *   start?: 'layout'|'random', timeBudgetMs?: number, now?: function(): number}} settings -
	 *   objective scores a layout (higher is better, engineObjective); method is
	 *   one of METHODS (DEFAULT_METHOD); iterations is per restart, one scored
	 *   trial each; restarts firstRestart… firstRestart+restarts-1 run (a page
	 *   splits them between workers); start: every restart from the start
	 *   layout, or each from its own random arrangement; timeBudgetMs bounds
	 *   the whole run, and the annealing's cooling then follows the clock (now,
	 *   Date.now by default).
	 * @returns {{step: function(number): object, done: function(): boolean, result: function(): object}}
	 */
	function createSearch(p, settings) {
		const s = Object.assign(
			{
				seed: 1,
				restarts: 1,
				firstRestart: 0,
				iterations: 2000,
				start: 'layout',
				method: DEFAULT_METHOD
			},
			settings
		);
		if (typeof s.objective !== 'function') throw new Error('layout_optimizer: no objective');
		if (!METHODS.includes(s.method))
			throw new OptimizerError(
				'option_value',
				{ option: 'method' },
				`method is one of ${METHODS.join(', ')}`
			);
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
		// The change penalty: changeWeight points per % of the corpus's
		// characters moved (changeCost), taken off the objective; with no
		// weight and no change limit the search follows no change at all.
		const changeWeight = s.changeWeight === undefined ? 0 : s.changeWeight;
		if (!(Number.isFinite(changeWeight) && changeWeight >= 0))
			throw new OptimizerError('option_value', { option: 'changeWeight' }, 'changeWeight ≥ 0');
		if (changeWeight > 0 && !s.changeCost)
			throw new Error('layout_optimizer: a change weight needs its changeCost');
		const follows = changeWeight > 0 || p.options.maxChanges !== null;
		const cost = follows ? s.changeCost || costOf(p, new Map(), {}) : null;
		const penalty = (moved) => (changeWeight > 0 ? changeWeight * cost.share(moved) : 0);

		const cache = new Map();
		let evaluations = 0;
		// The layout scored last, which an incremental objective may keep (accept).
		let scored = { key: '', layout: null };
		const score = (assignment) => {
			const key = assignment.join(',');
			if (cache.has(key)) return cache.get(key);
			const layout = scoredLayoutOf(p, assignment);
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
			s.objective.accept(scored.key === key ? scored.layout : scoredLayoutOf(p, assignment));
		};

		// The objective of an arrangement: the engine's score, less the change
		// penalty of the moved weight a tracker gives for it.
		const objectiveOf = (engineScore, moved) =>
			follows ? engineScore - penalty(moved) : engineScore;
		const startEngine = score(p.start);
		const startScore = objectiveOf(startEngine, follows ? cost.moved(p.start) : 0);
		let best = {
			score: startScore,
			engine: startEngine,
			assignment: p.start.slice(),
			restart: -1
		};
		let restart = -1;
		let run = null;
		let stopped = false;

		/** Keeps an arrangement as the best when it beats it. */
		const offer = (value, engineScore, assignment, k) => {
			if (value > best.score)
				best = { score: value, engine: engineScore, assignment: assignment.slice(), restart: k };
		};
		/** Scores the run's arrangement with units a and b traded, and leaves them traded. */
		const tryPair = (r, a, b) => {
			swap(r.assignment, r.slotOf, a, b);
			const engineScore = score(r.assignment);
			const moved = r.follow ? r.follow.trial(a, b) : 0;
			return { engineScore, value: objectiveOf(engineScore, moved) };
		};
		/** Keeps the trade tryPair left: the run now stands on it. */
		const keepPair = (r, a, b, value, engineScore) => {
			r.current = value;
			if (r.follow) r.follow.swap(a, b);
			accept(r.assignment);
			offer(value, engineScore, r.assignment, r.k);
		};
		/** Moves the run onto a whole arrangement (a kick, a child) and scores it. */
		const standOn = (r, assignment) => {
			r.assignment = assignment;
			r.slotOf = slotsOf(assignment);
			r.follow = follows ? cost.tracker(assignment) : null;
			const engineScore = score(assignment);
			r.current = objectiveOf(engineScore, r.follow ? r.follow.moved() : 0);
			accept(assignment);
			offer(r.current, engineScore, assignment, r.k);
			return engineScore;
		};
		/** Random valid swaps of an arrangement, in place, within the change limit. */
		const kicked = (assignment, swaps, next) => {
			const slotOf = slotsOf(assignment);
			const follow = p.options.maxChanges === null ? null : homeTracker(p, assignment);
			for (let i = 0; i < swaps; i++) {
				const pair = pickSwap(p, assignment, slotOf, next, follow);
				if (!pair) continue;
				if (follow) follow.swap(pair[0], pair[1]);
				swap(assignment, slotOf, pair[0], pair[1]);
			}
			return assignment;
		};
		/** The objective of a whole arrangement, scored on its own (no session move). */
		const valueOf = (assignment) => {
			const engineScore = score(assignment);
			return {
				engineScore,
				value: objectiveOf(engineScore, follows ? cost.moved(assignment) : 0)
			};
		};

		const strategy = {
			/**
			 * Simulated annealing: a random valid swap, kept when it is better or
			 * with probability e^(Δ/T); T falls geometrically from T₀, set by the
			 * mean worsening of CALIBRATION_SWAPS swaps, to T₀ × FINAL_TEMPERATURE_RATIO.
			 */
			annealing: {
				begin(r) {
					let worse = 0;
					let counted = 0;
					for (let i = 0; i < CALIBRATION_SWAPS; i++) {
						const pair = pickSwap(p, r.assignment, r.slotOf, r.next, r.follow);
						if (!pair) break;
						swap(r.assignment, r.slotOf, pair[0], pair[1]);
						const moved = r.follow ? r.follow.trial(pair[0], pair[1]) : 0;
						const delta = objectiveOf(score(r.assignment), moved) - r.current;
						swap(r.assignment, r.slotOf, pair[0], pair[1]);
						if (delta < 0) {
							worse += -delta;
							counted += 1;
						}
					}
					r.t0 = counted > 0 ? worse / counted / Math.LN2 : 1;
					r.temperature = r.t0;
				},
				iterate(r, fraction) {
					r.temperature = r.t0 * Math.pow(FINAL_TEMPERATURE_RATIO, fraction);
					const pair = pickSwap(p, r.assignment, r.slotOf, r.next, r.follow);
					if (!pair) return;
					const trial = tryPair(r, pair[0], pair[1]);
					const delta = trial.value - r.current;
					if (delta >= 0 || r.next() < Math.exp(delta / r.temperature))
						keepPair(r, pair[0], pair[1], trial.value, trial.engineScore);
					else swap(r.assignment, r.slotOf, pair[0], pair[1]);
				}
			},

			/**
			 * Late-acceptance hill climbing: a random valid swap, kept when it is
			 * no worse than the current arrangement or than the current one
			 * LATE_ACCEPTANCE_HISTORY trials ago; one parameter, no schedule.
			 */
			late_acceptance: {
				begin(r) {
					r.history = new Array(LATE_ACCEPTANCE_HISTORY).fill(r.current);
				},
				iterate(r) {
					const pair = pickSwap(p, r.assignment, r.slotOf, r.next, r.follow);
					if (!pair) return;
					const slot = r.iteration % LATE_ACCEPTANCE_HISTORY;
					const trial = tryPair(r, pair[0], pair[1]);
					if (trial.value >= r.current || trial.value >= r.history[slot])
						keepPair(r, pair[0], pair[1], trial.value, trial.engineScore);
					else swap(r.assignment, r.slotOf, pair[0], pair[1]);
					if (r.current > r.history[slot]) r.history[slot] = r.current;
				}
			},

			/**
			 * Tabu search on a candidate list: TABU_CANDIDATES random valid swaps
			 * are scored, and the best one whose units are not tabu (or that beats
			 * the best arrangement found, the aspiration) is made, even when it
			 * loses; its two units are tabu for the tenure.
			 */
			tabu: {
				begin(r) {
					r.tabuUntil = new Array(p.units.length).fill(0);
					r.tenure = Math.min(
						TABU_TENURE_MAX,
						Math.max(TABU_TENURE_MIN, Math.floor(p.movable.length / 4))
					);
					r.moves = 0;
					r.candidates = null;
				},
				iterate(r) {
					if (r.candidates === null) r.candidates = { tried: 0, best: null };
					const list = r.candidates;
					list.tried += 1;
					const pair = pickSwap(p, r.assignment, r.slotOf, r.next, r.follow);
					if (pair) {
						const [a, b] = pair;
						const trial = tryPair(r, a, b);
						swap(r.assignment, r.slotOf, a, b);
						const tabu = r.tabuUntil[a] > r.moves || r.tabuUntil[b] > r.moves;
						if (
							(!tabu || trial.value > best.score) &&
							(!list.best || trial.value > list.best.value)
						)
							list.best = { a, b, value: trial.value, engineScore: trial.engineScore };
					}
					if (list.tried < TABU_CANDIDATES) return;
					r.candidates = null;
					r.moves += 1;
					if (!list.best) return;
					const { a, b, value, engineScore } = list.best;
					swap(r.assignment, r.slotOf, a, b);
					keepPair(r, a, b, value, engineScore);
					r.tabuUntil[a] = r.moves + r.tenure;
					r.tabuUntil[b] = r.moves + r.tenure;
				}
			},

			/**
			 * A steady-state genetic algorithm: a population seeded from the
			 * restart's start (mutants of it, or random arrangements), then one
			 * child per trial: two parents by tournament, cycle crossover
			 * (cycleCrossover, which keeps every constraint) or a copy, one or
			 * more mutation swaps; the child replaces the worst individual when
			 * it beats it, never one of the GENETIC_ELITE best (elitism), and
			 * never joins twice.
			 */
			genetic: {
				begin(r) {
					r.population = [
						{ assignment: r.assignment.slice(), value: r.current, key: r.assignment.join(',') }
					];
					r.keys = new Set([r.population[0].key]);
				},
				iterate(r) {
					const population = r.population;
					let child;
					if (population.length < GENETIC_POPULATION) {
						child =
							s.start === 'random'
								? shuffled(p, r.next)
								: kicked(p.start.slice(), 1 + Math.floor(r.next() * GENETIC_SEED_SWAPS), r.next);
					} else {
						const pick = () => {
							let winner = population[Math.floor(r.next() * population.length)];
							for (let i = 1; i < GENETIC_TOURNAMENT; i++) {
								const rival = population[Math.floor(r.next() * population.length)];
								if (rival.value > winner.value) winner = rival;
							}
							return winner;
						};
						const first = pick();
						const second = pick();
						child =
							r.next() < GENETIC_CROSSOVER
								? cycleCrossover(first.assignment, second.assignment, r.next)
								: first.assignment.slice();
						const limit = p.options.maxChanges;
						if (limit !== null && changedUnits(p, child).length > limit)
							child = first.assignment.slice();
						let swaps = 1;
						while (r.next() < GENETIC_MORE_MUTATION) swaps += 1;
						kicked(child, swaps, r.next);
					}
					const key = child.join(',');
					if (r.keys.has(key)) return;
					const { value, engineScore } = valueOf(child);
					// The session follows the children, which stay near one another.
					accept(child);
					offer(value, engineScore, child, r.k);
					const entry = { assignment: child, value, key };
					if (population.length < GENETIC_POPULATION) population.push(entry);
					else {
						// Only the worst is ever replaced: every better individual survives (elitism).
						population.sort((x, y) => y.value - x.value);
						const worst = population[population.length - 1];
						if (value <= worst.value) return;
						r.keys.delete(worst.key);
						population[population.length - 1] = entry;
					}
					r.keys.add(key);
					if (value > r.current) {
						r.current = value;
						r.assignment = child.slice();
						r.slotOf = slotsOf(r.assignment);
					}
				}
			},

			/**
			 * Best-improvement hill climbing: every valid swap of the arrangement
			 * is scored, in an order the restart's generator shuffles, and the
			 * best gain is made; at a local optimum, the restart's best optimum
			 * is kicked by HILL_KICK_SWAPS random swaps and the climb starts again.
			 */
			hill_climbing: {
				begin(r) {
					r.scan = null;
					r.optimum = { value: r.current, assignment: r.assignment.slice() };
				},
				iterate(r) {
					if (r.scan === null) r.scan = { pairs: neighbours(r), at: 0, best: null };
					const scan = r.scan;
					if (scan.at < scan.pairs.length) {
						const [a, b] = scan.pairs[scan.at];
						scan.at += 1;
						const trial = tryPair(r, a, b);
						swap(r.assignment, r.slotOf, a, b);
						if (
							trial.value > r.current + IMPROVEMENT_EPSILON &&
							(!scan.best || trial.value > scan.best.value)
						)
							scan.best = { a, b, value: trial.value, engineScore: trial.engineScore };
						if (scan.at < scan.pairs.length) return;
					}
					r.scan = null;
					if (scan.best) {
						const { a, b, value, engineScore } = scan.best;
						swap(r.assignment, r.slotOf, a, b);
						keepPair(r, a, b, value, engineScore);
						return;
					}
					if (r.current > r.optimum.value)
						r.optimum = { value: r.current, assignment: r.assignment.slice() };
					standOn(r, kicked(r.optimum.assignment.slice(), HILL_KICK_SWAPS, r.next));
				}
			}
		}[s.method];

		/** Every valid swap of the run's arrangement, shuffled by its generator. */
		function neighbours(r) {
			const limit = p.options.maxChanges;
			const pairs = [];
			const units = p.movable;
			for (let i = 0; i < units.length; i++)
				for (let j = i + 1; j < units.length; j++) {
					const a = units[i];
					const b = units[j];
					if (p.units[a].kind === 'empty' && p.units[b].kind === 'empty') continue;
					if (!allowed(p, a, r.slotOf[b]) || !allowed(p, b, r.slotOf[a])) continue;
					if (limit !== null && r.follow.unitsAfter(a, b) > limit) continue;
					pairs.push([a, b]);
				}
			for (let i = pairs.length - 1; i > 0; i--) {
				const j = Math.floor(r.next() * (i + 1));
				const held = pairs[i];
				pairs[i] = pairs[j];
				pairs[j] = held;
			}
			return pairs;
		}

		/** Prepares restart k: its generator, start and the method's own state. */
		function begin(k) {
			const next = random(restartSeed(s.seed, k));
			const assignment = s.start === 'random' ? shuffled(p, next) : p.start.slice();
			const slotOf = slotsOf(assignment);
			const follow = follows ? cost.tracker(assignment) : null;
			const engineScore = score(assignment);
			const current = objectiveOf(engineScore, follow ? follow.moved() : 0);
			accept(assignment);
			run = { k, next, assignment, slotOf, follow, current, iteration: 0, temperature: 0 };
			strategy.begin(run);
			run.began = timed ? now() : 0;
			offer(current, engineScore, assignment, k);
		}

		function finished() {
			return stopped || (restart >= s.restarts - 1 && run === null);
		}

		/**
		 * Runs up to `count` iterations.
		 * @returns {object} The progress: restart, iteration, evaluations,
		 *   temperature, current, best (the objective: the score less the
		 *   change penalty), bestEngine (the engine's score of the best),
		 *   startScore (the start's objective), done.
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
				run.iteration += 1;
				left -= 1;
				strategy.iterate(run, fraction);
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
				bestEngine: best.engine,
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
			/**
			 * The best arrangement so far: its layout, its objective (score), the
			 * engine's score of it (engineScore) and, when a changeCost is given,
			 * what it changes from the start (changeCost's changed()).
			 */
			result(identity) {
				return {
					method: s.method,
					score: best.score,
					engineScore: best.engine,
					startScore,
					restart: best.restart,
					evaluations,
					assignment: best.assignment.slice(),
					layout: layoutOf(p, best.assignment, identity),
					change: s.changeCost ? s.changeCost.changed(best.assignment) : null
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
		METHODS,
		DEFAULT_METHOD,
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
		changeCost,
		changedUnits,
		createSearch,
		run,
		bestOf
	};
})();

// Node (tests, tools) reads the module through a vm context or require().
if (typeof module !== 'undefined' && module.exports) module.exports = LAYOUT_OPTIMIZER;
