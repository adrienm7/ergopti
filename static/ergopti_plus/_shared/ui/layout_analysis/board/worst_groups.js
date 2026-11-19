// _shared/ui/layout_analysis/board/worst_groups.js

/**
 * ==============================================================================
 * MODULE: Worst N-grams
 * DESCRIPTION:
 * The key pairs and trigrams that cost a layout the most, by event (same-finger
 * bigrams and skipgrams, lateral stretches, scissors, bad redirects), drawn as
 * cards of focusable rows. Hovering or focusing a row outlines its keys on a
 * board, numbered in the order they are typed. Shared by the Comparer's
 * overview (its own board) and the editor's analysis panel (the editor's board).
 *
 * FEATURES & RATIONALE:
 * 1. One source: the engine's topGroups (analyse with keyGroups), so the lists
 *    match « One layout › Worst pairs and trigrams ».
 * 2. Keyboard first: each row is a button; focus shows the keys as hover
 *    does, Escape or leaving the list hides them (WCAG 2.1.1, 1.4.13).
 * 3. Never by colour alone: each row says its keys and share in text, and the
 *    keys on the board carry their order as a number.
 * 4. The keys read as every board shows them (the shared key legend): a dead
 *    key as its bare accent, the space as « ␣ ».
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_WORST = (function () {
	'use strict';

	// The events listed, in order: the scored bad events the study names.
	const EVENTS = ['sfb', 'sfs', 'lsb', 'scissors', 'redirect_bad'];
	// Rows per event, and the digits of a share.
	const DEFAULT_LIMIT = 8;
	const SHARE_DIGITS = 2;
	// The class of a key the focused n-gram uses, and its order attribute.
	const KEY_CLASS = 'la-ngram-key';
	const ORDER_ATTRIBUTE = 'data-ngram-order';

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	/**
	 * A key as the boards show it: its base character (a dead key as its bare
	 * accent, the space as « ␣ »), else its position code.
	 * @param {object} layout - Library shape.
	 * @param {string} code - KeyboardEvent code.
	 * @returns {string}
	 */
	function keyLabel(layout, code) {
		const row = layout.rows[code];
		const base = row ? row[0] : null;
		if (typeof base === 'string' && base !== '') return KEY_LEGEND.visibleText(base);
		if (base && typeof base === 'object') {
			const accent = KEY_LEGEND.deadKeyText(((layout.dead || {})[base.dead] || {})[' '] || '');
			if (accent !== '') return accent;
		}
		return code === 'Space' ? KEY_LEGEND.visibleText(' ') : code;
	}

	/**
	 * Outlines keys on a board: every element under it with a data-code the
	 * n-gram uses gets KEY_CLASS and its order (1, 2, 3); null clears.
	 * @param {function(): (Element|null)} board - Finds the board now (a page may redraw it).
	 * @returns {function((string[]|null)): void}
	 */
	function highlighter(board) {
		return (codes) => {
			const root = board();
			if (!root) return;
			for (const node of root.querySelectorAll(`.${KEY_CLASS}`)) {
				node.classList.remove(KEY_CLASS);
				node.removeAttribute(ORDER_ATTRIBUTE);
			}
			if (!codes) return;
			codes.forEach((code, index) => {
				for (const node of root.querySelectorAll(`[data-code="${CSS.escape(code)}"]`)) {
					node.classList.add(KEY_CLASS);
					// A key typed twice (a redirect) keeps its first number.
					if (!node.hasAttribute(ORDER_ATTRIBUTE))
						node.setAttribute(ORDER_ATTRIBUTE, String(index + 1));
				}
			});
		};
	}

	/**
	 * Draws the cards into a box.
	 * @param {HTMLElement} box - Emptied first.
	 * @param {{groups: object, layout: object, highlight: function((string[]|null)): void,
	 *   limit?: number}} options - groups: the engine's topGroups (event → [{keys,
	 *   count, share}]); highlight: told the keys of the row hovered or focused.
	 */
	function draw(box, options) {
		const t = window.LAYOUT_ANALYSIS_INFO.t;
		// A number and its unit, tied by a no-break space.
		const measure = window.LAYOUT_ANALYSIS_INFO.measure;
		const limit = options.limit || DEFAULT_LIMIT;
		box.replaceChildren();
		box.classList.add('la-ngrams');
		const clear = () => options.highlight(null);
		for (const event of EVENTS) {
			const groups = (options.groups[event] || []).slice(0, limit);
			const card = el('section', `la-ngram-card la-ngram-${event}`);
			const title = el('h4', 'la-ngram-title', t(`layout_analysis.metric.${event}`));
			title.id = `${box.id || 'la-ngrams'}-${event}`;
			card.setAttribute('aria-labelledby', title.id);
			card.append(title);
			if (groups.length === 0) {
				card.append(el('p', 'la-muted', t('layout_analysis.worst.none')));
				box.append(card);
				continue;
			}
			const list = el('ol', 'la-ngram-list');
			const top = groups[0].share;
			for (const group of groups) {
				const keys = group.keys.map((code) => keyLabel(options.layout, code));
				const share = measure(group.share, SHARE_DIGITS, '%');
				const button = el('button', 'la-ngram');
				button.type = 'button';
				const chips = el('span', 'la-ngram-keys');
				for (const key of keys) chips.append(el('kbd', 'la-ngram-chip', key));
				const bar = el('span', 'la-ngram-bar');
				bar.setAttribute('aria-hidden', 'true');
				bar.style.setProperty('--la-ngram-share', `${top > 0 ? (group.share / top) * 100 : 0}%`);
				button.append(chips, bar, el('span', 'la-ngram-share', share));
				button.setAttribute('aria-label', `${keys.join(' ')}: ${share}`);
				const show = () => options.highlight(group.keys);
				button.addEventListener('mouseenter', show);
				button.addEventListener('focus', show);
				button.addEventListener('mouseleave', () => {
					if (document.activeElement !== button) clear();
				});
				button.addEventListener('blur', clear);
				button.addEventListener('keydown', (keyEvent) => {
					if (keyEvent.key === 'Escape') clear();
				});
				const item = el('li');
				item.append(button);
				list.append(item);
			}
			card.append(list);
			box.append(card);
		}
	}

	return { EVENTS, keyLabel, highlighter, draw, KEY_CLASS, ORDER_ATTRIBUTE };
})();
