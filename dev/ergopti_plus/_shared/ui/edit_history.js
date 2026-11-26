// _shared/ui/edit_history.js

/**
 * ==============================================================================
 * MODULE: Studio Edit History
 * DESCRIPTION:
 * The undo and redo history of Ergopti Studio (maintainer, 2026-11-21): every
 * edit of the layout editor, the Comparer's score settings and layout list,
 * and the Optimiser's settings is one step that Undo takes back and Redo
 * replays, in order, as in a word processor. Restores and imports are steps
 * too. The editor keeps one history per layout tab; the Comparer and the
 * Optimiser each keep one for the page.
 *
 * FEATURES & RATIONALE:
 * 1. Named steps: each step carries a locale key and its values (« change key
 *    A »), so the Undo and Redo buttons say what they would take back or
 *    replay (WCAG 2.4.6, 3.3.4), in all 21 locales (edit_history.*).
 * 2. Bounded: HISTORY_LIMIT steps, the oldest dropped first. A page script
 *    cannot read the timing registry, so the value is pinned to [ui]
 *    studio_history_steps of _shared/core/timing/data/constants.toml.
 * 3. Branching: a new edit after an undo clears the steps that Redo would
 *    have replayed.
 * 4. Fail fast: undoing with nothing to undo, a step without a name, an edit
 *    recorded while a step is being taken back, or a page that does not take
 *    back the state it was given throws instead of leaving the history and
 *    the page apart.
 * 5. Two shapes: create() holds values the page already keeps immutable (the
 *    editor's documents); track() captures a page's settings as JSON, records
 *    a step when they changed and puts a captured state back on undo.
 * 6. One shortcut table: Ctrl+Z undoes, Ctrl+Y and Ctrl+Shift+Z redo, with Cmd
 *    on macOS (Ctrl and Cmd both work on every OS, a Mac keyboard on Windows).
 *    A text field keeps its own Ctrl+Z, which undoes its typing.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var ERGOPTI_EDIT_HISTORY = (function () {
	'use strict';

	// ============================
	// ======= 1/ Constants =======
	// ============================

	// Pinned to [ui] studio_history_steps (test-keystats-timings-single-source.cjs).
	const HISTORY_LIMIT = 200;
	// The fields whose own Ctrl+Z undoes their text: the history leaves it to them.
	const TEXT_INPUT_TYPES = new Set(['text', 'search', 'url', 'tel', 'email', 'password', 'number']);
	// For assistive technologies: every chord the buttons answer to.
	const SHORTCUTS = Object.freeze({
		undo: 'Control+Z Meta+Z',
		redo: 'Control+Y Meta+Y Control+Shift+Z Meta+Shift+Z'
	});

	// ============================
	// ======= 2/ Helpers =========
	// ============================

	/**
	 * Refuses a step name that is not a locale key with optional values.
	 * @param {{key: string, values?: object}} label
	 */
	function checkLabel(label) {
		if (!label || typeof label.key !== 'string' || !/^[a-z0-9_]+(\.[a-z0-9_]+)+$/.test(label.key))
			throw new Error('edit history: a step needs a locale key as its name');
		if (label.values !== undefined && (typeof label.values !== 'object' || label.values === null))
			throw new Error('edit history: the values of a step name are an object');
	}

	/** Refuses a limit that is not a positive integer. */
	function checkLimit(limit) {
		if (!Number.isInteger(limit) || limit < 1)
			throw new Error(`edit history: the limit is a positive integer, not ${limit}`);
	}

	/**
	 * Whether a key press belongs to a text field (its own undo history).
	 * @param {EventTarget} target - The focused element.
	 * @returns {boolean}
	 */
	function inTextField(target) {
		if (!target || target.nodeType !== 1) return false;
		if (target.isContentEditable || target.tagName === 'TEXTAREA') return true;
		return target.tagName === 'INPUT' && TEXT_INPUT_TYPES.has(target.type);
	}

	/**
	 * The history action of a key press: Ctrl or Cmd with Z undoes, with Y or
	 * Shift+Z redoes, by the character typed (Ctrl+Z on AZERTY is the key
	 * marked Z).
	 * @param {KeyboardEvent} event
	 * @returns {'undo'|'redo'|null}
	 */
	function action(event) {
		if (!(event.ctrlKey || event.metaKey) || event.altKey) return null;
		const key = String(event.key).toLowerCase();
		if (key === 'z') return event.shiftKey ? 'redo' : 'undo';
		return key === 'y' && !event.shiftKey ? 'redo' : null;
	}

	// ============================
	// ======= 3/ Stack ===========
	// ============================

	/**
	 * A history of immutable states.
	 * @param {*} initial - The state before any step.
	 * @param {{limit?: number}} [options] - limit replaces HISTORY_LIMIT (tests).
	 * @returns {object} current, push, reset, undo, redo, canUndo, canRedo,
	 *   undoLabel, redoLabel, size.
	 */
	function create(initial, options) {
		const limit = options && options.limit !== undefined ? options.limit : HISTORY_LIMIT;
		checkLimit(limit);
		// steps[0] is the state before the first kept step; each later entry is
		// the state a step made, with its name and its side effects.
		let steps = [{ state: initial, label: null, effect: null }];
		let cursor = 0;
		let busy = false;

		function check() {
			if (!Number.isInteger(cursor) || cursor < 0 || cursor >= steps.length)
				throw new Error(`edit history: step ${cursor} is outside the ${steps.length} kept`);
		}

		function idle(what) {
			if (busy) throw new Error(`edit history: ${what} while a step is being taken back`);
		}

		const canUndo = () => cursor > 0;
		const canRedo = () => cursor < steps.length - 1;

		return {
			current() {
				check();
				return steps[cursor].state;
			},
			/**
			 * Records a step.
			 * @param {*} next - The state the step made.
			 * @param {{key: string, values?: object}} label - What the step did.
			 * @param {{undo: function, redo: function}} [effect] - What the step
			 *   changed outside its state (the fingering beside a document).
			 * @returns {*} next.
			 */
			push(next, label, effect) {
				idle('an edit was recorded');
				checkLabel(label);
				if (
					effect !== undefined &&
					(typeof effect.undo !== 'function' || typeof effect.redo !== 'function')
				)
					throw new Error('edit history: a side effect needs undo and redo');
				check();
				steps.length = cursor + 1;
				steps.push({ state: next, label, effect: effect || null });
				cursor += 1;
				while (steps.length - 1 > limit) {
					steps.shift();
					cursor -= 1;
				}
				return next;
			},
			/** Forgets every step: the state is a new start (another file, a new tab). */
			reset(next) {
				idle('the history was reset');
				steps = [{ state: next, label: null, effect: null }];
				cursor = 0;
				return next;
			},
			canUndo,
			canRedo,
			/** The name of the step Undo would take back, or null. */
			undoLabel: () => (canUndo() ? steps[cursor].label : null),
			/** The name of the step Redo would replay, or null. */
			redoLabel: () => (canRedo() ? steps[cursor + 1].label : null),
			/** How many steps can be undone and redone in all. */
			size: () => steps.length - 1,
			undo() {
				idle('undo was asked');
				if (!canUndo()) throw new Error('edit history: nothing to undo');
				const step = steps[cursor];
				cursor -= 1;
				busy = true;
				try {
					if (step.effect) step.effect.undo();
				} finally {
					busy = false;
				}
				check();
				return steps[cursor].state;
			},
			redo() {
				idle('redo was asked');
				if (!canRedo()) throw new Error('edit history: nothing to redo');
				cursor += 1;
				const step = steps[cursor];
				busy = true;
				try {
					if (step.effect) step.effect.redo();
				} finally {
					busy = false;
				}
				check();
				return step.state;
			}
		};
	}

	// ============================
	// ======= 4/ Tracker =========
	// ============================

	/**
	 * A history of a page's settings, captured as JSON.
	 * @param {{capture: function(): object, apply: function(object): void,
	 *   describe: function(object, object): {key: string, values?: object},
	 *   onChange?: function(): void, limit?: number}} page - capture() reads the
	 *   settings, apply(state) puts captured settings back (and saves them),
	 *   describe(before, after) names a step from what changed, onChange() is
	 *   told after every step, undo and redo.
	 * @returns {object} start, record, label, undo, redo, canUndo, canRedo,
	 *   undoLabel, redoLabel, size.
	 */
	function track(page) {
		for (const name of ['capture', 'apply', 'describe'])
			if (!page || typeof page[name] !== 'function')
				throw new Error(`edit history: a tracked page needs ${name}()`);
		const changed = typeof page.onChange === 'function' ? page.onChange : () => {};
		let stack = null;
		let applying = false;
		let pending = null;
		const snapshot = () => JSON.stringify(page.capture());

		function started() {
			if (!stack) throw new Error('edit history: the tracked page has not started');
			return stack;
		}

		function move(direction) {
			if (applying) throw new Error(`edit history: ${direction} while a state is being put back`);
			const history = started();
			const target = direction === 'undo' ? history.undo() : history.redo();
			applying = true;
			try {
				page.apply(JSON.parse(target));
			} finally {
				applying = false;
			}
			if (snapshot() !== target)
				throw new Error(`edit history: the page did not take back the state of this ${direction}`);
			pending = null;
			changed();
		}

		return {
			/** Captures the settings the first step starts from. */
			start() {
				if (stack) throw new Error('edit history: the tracked page has already started');
				stack = create(snapshot(), {
					limit: page.limit === undefined ? HISTORY_LIMIT : page.limit
				});
				changed();
			},
			/**
			 * Records a step if the settings changed since the last one; the
			 * page's own saves while a state is put back are not steps.
			 * @returns {boolean} Whether a step was recorded.
			 */
			record() {
				const history = started();
				if (applying) return false;
				const now = snapshot();
				const before = history.current();
				if (now === before) {
					// A restore that changed nothing names no later step.
					pending = null;
					return false;
				}
				const label = pending || page.describe(JSON.parse(before), JSON.parse(now));
				pending = null;
				history.push(now, label);
				changed();
				return true;
			},
			/** Names the next recorded step (a restore, an import) instead of describe(). */
			label(next) {
				checkLabel(next);
				pending = next;
			},
			undo: () => move('undo'),
			redo: () => move('redo'),
			canUndo: () => started().canUndo(),
			canRedo: () => started().canRedo(),
			undoLabel: () => started().undoLabel(),
			redoLabel: () => started().redoLabel(),
			size: () => started().size()
		};
	}

	// ============================
	// ======= 5/ Controls ========
	// ============================

	/**
	 * The accessible name of an Undo or Redo button: « Undo: change key A »,
	 * or the bare action when there is nothing to take back.
	 * @param {function(string, object=): string} t - The page's translator.
	 * @param {'undo'|'redo'} which
	 * @param {{key: string, values?: object}|null} label - The step's name.
	 * @returns {string}
	 */
	function buttonName(t, which, label) {
		if (which !== 'undo' && which !== 'redo') throw new Error(`edit history: no ${which} button`);
		if (!label) return which === 'undo' ? t('edit_history.undo') : t('edit_history.redo');
		const step = t(label.key, label.values);
		return which === 'undo'
			? t('edit_history.undo_step', { step })
			: t('edit_history.redo_step', { step });
	}

	/**
	 * Undo and Redo buttons for a tracked page, and the polite line that says
	 * what was undone or redone (a screen reader hears it; the buttons stay).
	 * @param {object} history - A track() history.
	 * @param {function(string, object=): string} t - The page's translator.
	 * @param {string} prefix - The page's class prefix ('la', 'lo').
	 * @returns {{node: HTMLElement, refresh: function(): void, run: function(string): void}}
	 */
	function controls(history, t, prefix) {
		if (typeof prefix !== 'string' || !prefix)
			throw new Error('edit history: controls need a prefix');
		const node = document.createElement('div');
		node.className = `${prefix}-history`;
		node.setAttribute('role', 'group');
		const status = document.createElement('p');
		status.className = `${prefix}-history-status theme-sr-only`;
		status.setAttribute('role', 'status');
		const make = (which) => {
			const button = document.createElement('button');
			button.type = 'button';
			button.id = `${prefix}-${which}`;
			button.className = `${prefix}-history-button`;
			button.setAttribute('aria-keyshortcuts', SHORTCUTS[which]);
			button.addEventListener('click', () => run(which));
			return button;
		};
		const undo = make('undo');
		const redo = make('redo');
		let said = null;

		function refresh() {
			node.setAttribute('aria-label', t('edit_history.group'));
			undo.textContent = t('edit_history.undo');
			redo.textContent = t('edit_history.redo');
			for (const [button, which, label, can] of [
				[undo, 'undo', history.undoLabel(), history.canUndo()],
				[redo, 'redo', history.redoLabel(), history.canRedo()]
			]) {
				const name = buttonName(t, which, label);
				button.setAttribute('aria-label', name);
				button.title = name;
				// aria-disabled keeps the button in the tab order, so its name stays heard.
				button.setAttribute('aria-disabled', String(!can));
			}
			status.textContent = said
				? t(said.which === 'undo' ? 'edit_history.undone' : 'edit_history.redone', {
						step: t(said.label.key, said.label.values)
					})
				: '';
		}

		/** Undoes or redoes one step; nothing to take back does nothing. */
		function run(which) {
			const can = which === 'undo' ? history.canUndo() : history.canRedo();
			if (!can) return;
			const label = which === 'undo' ? history.undoLabel() : history.redoLabel();
			if (which === 'undo') history.undo();
			else history.redo();
			said = { which, label };
			refresh();
		}

		node.append(undo, redo, status);
		return { node, refresh, run };
	}

	/**
	 * Answers the history shortcuts on a page, outside text fields.
	 * @param {Document|HTMLElement} target - Where key presses are heard.
	 * @param {function('undo'|'redo'): void} run - Undoes or redoes.
	 * @param {function(): boolean} [enabled] - False while the page is hidden.
	 */
	function bindKeys(target, run, enabled) {
		if (!target || typeof target.addEventListener !== 'function' || typeof run !== 'function')
			throw new Error('edit history: shortcuts need a target and a run function');
		target.addEventListener('keydown', (event) => {
			const which = action(event);
			if (!which || event.defaultPrevented || inTextField(event.target)) return;
			if (enabled && !enabled()) return;
			event.preventDefault();
			run(which);
		});
	}

	return Object.freeze({
		HISTORY_LIMIT,
		SHORTCUTS,
		create,
		track,
		action,
		inTextField,
		buttonName,
		controls,
		bindKeys
	});
})();
