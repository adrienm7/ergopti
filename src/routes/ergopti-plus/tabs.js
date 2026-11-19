// src/routes/ergopti-plus/tabs.js

/**
 * ==============================================================================
 * MODULE: Tab List Keys
 * DESCRIPTION:
 * The keyboard of the ARIA tabs pattern, shared by the Ergopti+ page's tab
 * lists (the AI tooltip modes, the metrics dashboards): the arrows move the
 * selection and the focus and wrap around, Home and End jump to the ends.
 * Only the selected tab is in the Tab order (tabindex 0, the others -1).
 * ==============================================================================
 */

const TAB_KEYS = Object.freeze({ ArrowLeft: -1, ArrowRight: 1, Home: 'first', End: 'last' });

/**
 * Answer one key pressed on a tab.
 * @param {KeyboardEvent} event
 * @param {number} index - The tab the key was pressed on.
 * @param {number} count - How many tabs the list holds.
 * @param {function(number): void} select - Selects the tab at an index.
 */
export function moveTab(event, index, count, select) {
	const move = TAB_KEYS[event.key];
	if (move === undefined) return;
	event.preventDefault();
	const next = move === 'first' ? 0 : move === 'last' ? count - 1 : (index + move + count) % count;
	select(next);
	const list = /** @type {HTMLElement} */ (event.currentTarget).closest('[role="tablist"]');
	if (!list) throw new Error('A tab must sit inside its role="tablist"');
	/** @type {HTMLElement} */ (list.querySelectorAll('[role="tab"]')[next]).focus();
}
