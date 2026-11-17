// _shared/ui/layout_analysis/undo_offer.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Undo Offer
 * DESCRIPTION:
 * The « Undo » line of Ergopti Studio's restore buttons: the Comparer's four
 * « Restore » buttons (weights, ideal load, shortcut letters, keyboard forms)
 * and the fingering editor's reset act at once, so each says what it did and
 * offers to put the user's values back (WCAG 3.3.4, cognitive accessibility).
 *
 * FEATURES & RATIONALE:
 * 1. An in-page line, not window.confirm: a WebView host may not show the
 *    browser's dialogs, and a question before every restore slows the user
 *    who meant it.
 * 2. A polite status region present from the start, so a screen reader
 *    announces « … restored » when it is filled; the « Undo » button follows
 *    the restore button in the tab order, one Tab away.
 * 3. No time limit (WCAG 2.2.1): the offer stays until the user edits the
 *    same section again (its values would no longer be the ones restored)
 *    or another restore replaces it. After an undo the focus goes back to
 *    the restore button, since the « Undo » button it was on is gone.
 * 4. Strings are locale keys layout_analysis.undo.* (21 locales).
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_UNDO = (function () {
	'use strict';

	const INFO = window.LAYOUT_ANALYSIS_INFO;
	const t = INFO.t;

	/**
	 * Creates the undo line of one section, placed by the caller.
	 * @param {HTMLElement} section - Its input and change events withdraw the offer.
	 * @returns {{node: HTMLElement, offer: function(object): void, clear: function(): void}}
	 */
	function create(section) {
		if (!section || typeof section.addEventListener !== 'function')
			throw new Error('layout_analysis: an undo line needs its section');
		const node = document.createElement('p');
		node.className = 'la-undo';
		node.setAttribute('role', 'status');
		let current = null;

		function clear() {
			current = null;
			node.replaceChildren();
		}

		/**
		 * Says that a section was restored and offers to put it back.
		 * @param {{name: string, undo: function(): void, focus: HTMLElement}} what -
		 *   The section's visible name, the function that puts the user's values
		 *   back, and the restore button the focus returns to after an undo.
		 */
		function offer(what) {
			if (!what || typeof what.undo !== 'function' || typeof what.name !== 'string')
				throw new Error('layout_analysis: an undo offer needs a name and an undo function');
			current = what;
			const text = document.createElement('span');
			text.textContent = t('layout_analysis.undo.restored', { name: what.name });
			const button = document.createElement('button');
			button.type = 'button';
			button.className = 'la-undo-button';
			button.textContent = t('layout_analysis.undo.button');
			button.addEventListener('click', () => {
				if (current !== what) return;
				current = null;
				what.undo();
				node.replaceChildren(t('layout_analysis.undo.undone', { name: what.name }));
				if (what.focus && typeof what.focus.focus === 'function') what.focus.focus();
			});
			node.replaceChildren(text, ' ', button);
		}

		// An edit after the restore: undoing would erase it, so the offer goes.
		for (const type of ['input', 'change'])
			section.addEventListener(type, (event) => {
				if (node.firstChild && !node.contains(event.target)) clear();
			});
		return { node, offer, clear };
	}

	return { create };
})();
