// _shared/ui/layout_try/typing.js

/**
 * ==============================================================================
 * MODULE: Layout Try Typing
 * DESCRIPTION:
 * The typing emulator of Ergopti Studio's « Essayer » tab: given a layout of
 * the Studio's library (layout_analysis/_generated/analysis_data.js, the
 * Comparer's layouts), it says what a physical key press types, through the
 * layout's four levels (base, Shift, AltGr, Shift+AltGr) and its dead keys.
 * It took over the site's former « Essayer » page (/ergopti/utilisation,
 * maintainer, 2026-11-21), whose emulator knew only Ergopti's six dead keys
 * from its visualisation file; this one reads any library layout.
 *
 * FEATURES & RATIONALE:
 * 1. Physical keys: a press is read by its KeyboardEvent code, so the layout
 *    types the same whatever layout the visitor's OS has.
 * 2. Dead keys as the OS types them: a dead key waits; the next key gives its
 *    rule's result, a chained dead key, or (no rule) the dead key's own
 *    character before the typed one, as macOS, Windows and XKB do. Space after
 *    a dead key gives its own character.
 * 3. Caps Lock shifts a letter whose Shift level is its capital, nothing else.
 * 4. Pure: no DOM, no clock; the page inserts the text (layout_try/try_page.js).
 * 5. Fail fast: a layout without rows, a level or a dead key the layout does
 *    not declare throws, never types a guess.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_TRY_TYPING = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	// The library's four levels, in the order of each row's cells.
	const LEVELS = Object.freeze(['base', 'shift', 'altgr', 'shift_altgr']);
	// A dead key's rule for another dead key is keyed « dead:<state> ».
	const DEAD_TYPED = 'dead:';
	// The key whose rule gives a dead key's own character.
	const SPACE = ' ';

	const own = (value, key) => Object.prototype.hasOwnProperty.call(value, key);

	// ============================
	// ======= 2/ Typist ==========
	// ============================

	/**
	 * A typist for one library layout.
	 * @param {{id: string, rows: object, dead?: object}} layout - A library layout.
	 * @returns {object} press, reset, pending, level, legend, owns.
	 */
	function create(layout) {
		if (!layout || typeof layout.id !== 'string' || !layout.rows || typeof layout.rows !== 'object')
			throw new Error('layout try: a layout needs an id and its rows');
		const rows = layout.rows;
		const dead = layout.dead || {};
		let waiting = null;

		function deadTable(state) {
			if (!own(dead, state))
				throw new Error(`layout try: ${layout.id} names the undeclared dead key ${state}`);
			return dead[state];
		}

		/** A dead key's own character: its rule for Space, else none. */
		function deadChar(state) {
			const rule = deadTable(state)[SPACE];
			return typeof rule === 'string' ? rule : '';
		}

		/** The level index of the held modifiers. */
		function levelOf(held) {
			return (held.altgr ? 2 : 0) + (held.shift ? 1 : 0);
		}

		/** Whether the layout types something on a key (any level). */
		function owns(code) {
			return own(rows, code);
		}

		/**
		 * What a key shows on a level: its character, a dead key's own
		 * character, or '' when it types nothing there.
		 */
		function legend(code, level) {
			const index = LEVELS.indexOf(level);
			if (index < 0) throw new Error(`layout try: no level ${level}`);
			if (!owns(code)) return '';
			const cell = rows[code][index];
			if (typeof cell === 'string') return cell;
			if (cell && typeof cell.dead === 'string') return deadChar(cell.dead);
			return '';
		}

		/** The cell a press reaches, Caps Lock shifting a letter. */
		function cellOf(code, held) {
			const row = rows[code];
			let index = levelOf(held);
			if (held.caps && index % 2 === 0) {
				const lower = row[index];
				const upper = row[index + 1];
				if (
					typeof lower === 'string' &&
					typeof upper === 'string' &&
					lower.toUpperCase() === upper &&
					lower !== upper
				)
					index += 1;
			}
			return row[index];
		}

		/** The result of a typed character or dead key while a dead key waits. */
		function afterDead(typed) {
			const table = deadTable(waiting);
			const key = typed.dead ? DEAD_TYPED + typed.dead : typed.char;
			const rule = own(table, key) ? table[key] : undefined;
			const from = waiting;
			waiting = null;
			if (typeof rule === 'string') return rule;
			if (rule && typeof rule.dead === 'string') {
				deadTable(rule.dead);
				waiting = rule.dead;
				return '';
			}
			// No rule: the dead key's own character, then the key as typed.
			if (typed.dead) {
				deadTable(typed.dead);
				waiting = typed.dead;
				return deadChar(from);
			}
			return deadChar(from) + typed.char;
		}

		/**
		 * Types one press.
		 * @param {string} code - The KeyboardEvent code.
		 * @param {{shift?: boolean, altgr?: boolean, caps?: boolean}} held
		 * @returns {{owned: boolean, text: string, pending: string|null}} owned
		 *   is false for a key the layout does not hold (the page lets the
		 *   browser handle it: Backspace, arrows, Enter).
		 */
		function press(code, held) {
			if (!owns(code)) return { owned: false, text: '', pending: waiting };
			const cell = cellOf(code, held || {});
			let text = '';
			if (cell && typeof cell.dead === 'string') {
				if (waiting) text = afterDead({ dead: cell.dead });
				else {
					deadTable(cell.dead);
					waiting = cell.dead;
				}
			} else if (typeof cell === 'string' && cell !== '') {
				text = waiting ? afterDead({ char: cell }) : cell;
			}
			return { owned: true, text, pending: waiting };
		}

		return {
			press,
			owns,
			legend,
			/** Forgets a waiting dead key (Backspace, a click elsewhere, another layout). */
			reset() {
				waiting = null;
			},
			/** The waiting dead key's own character, or null. */
			pending: () => (waiting ? deadChar(waiting) : null),
			/** The level the held modifiers reach. */
			level: (held) => LEVELS[levelOf(held || {})]
		};
	}

	return Object.freeze({ LEVELS, create });
})();
