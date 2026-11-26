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
 * 5. « Show more »: each card lists its first rows; a button under it unfolds
 *    the rest the engine keeps (and folds them again), says how many it adds,
 *    moves the focus to the first row it adds, and stays unfolded across the
 *    next analyses of the same box.
 * 6. « Corpus words » (an idea seen in the Layouts Wiki playground): with a
 *    words lookup, each row gets a button that opens the words of the corpus's
 *    word table typing its keys in a row, the most frequent first.
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
	// The events each box shows unfolded (« Show more »), kept across redraws.
	const unfolded = new WeakMap();
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
		// A repeat or magic key (the layout's own) shows its label.
		const own = LAYOUT_ANALYSIS.contextLabel(layout, code, 0);
		if (own !== '') return own;
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
	 *   limit?: number, words?: function(string[]): {words: Array<{word: string}>,
	 *   occurrences: number}}} options - groups: the engine's topGroups (event →
	 *   [{keys, count, share}]); highlight: told the keys of the row hovered or
	 *   focused; words: the corpus words typing the keys in a row (a « Corpus
	 *   words » button per row when given).
	 */
	function draw(box, options) {
		const t = window.LAYOUT_ANALYSIS_INFO.t;
		// A number and its unit, tied by a no-break space.
		const measure = window.LAYOUT_ANALYSIS_INFO.measure;
		const limit = options.limit || DEFAULT_LIMIT;
		box.replaceChildren();
		box.classList.add('la-ngrams');
		const clear = () => options.highlight(null);
		if (!unfolded.has(box)) unfolded.set(box, new Set());
		const open = unfolded.get(box);
		for (const event of EVENTS) {
			const all = options.groups[event] || [];
			const groups = open.has(event) ? all : all.slice(0, limit);
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
			list.id = `${title.id}-list`;
			const top = groups[0].share;
			for (const group of groups) {
				const keys = group.keys.map((code) => keyLabel(options.layout, code));
				const share = measure(group.share, SHARE_DIGITS, '%');
				const button = el('button', 'la-ngram');
				button.type = 'button';
				// The keys typed in turn: a kbd of kbds, as HTML writes a key sequence.
				// The spaces between the keys and before the share are not drawn (flex
				// and grid items), but they part the words of the visible text, which
				// the name then contains (WCAG 2.5.3) instead of one run « ct0,06 % ».
				const chips = el('kbd', 'la-ngram-keys');
				keys.forEach((key, at) => {
					if (at > 0) chips.append(' ');
					chips.append(el('kbd', 'la-ngram-chip', key));
				});
				const bar = el('span', 'la-ngram-bar');
				bar.setAttribute('aria-hidden', 'true');
				bar.style.setProperty('--la-ngram-share', `${top > 0 ? (group.share / top) * 100 : 0}%`);
				const value = el('data', 'la-ngram-share', share);
				value.value = String(group.share);
				button.append(chips, ' ', bar, ' ', value);
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
				if (options.words) item.append(...wordsToggle(options.words, group.keys, keys));
				list.append(item);
			}
			card.append(list);
			if (all.length > limit) card.append(moreButton(box, event, all.length - limit, list, limit));
			box.append(card);
		}
	}

	/**
	 * A row's « Corpus words » button and the paragraph it opens, filled on
	 * first opening from the lookup.
	 * @param {function(string[]): {words: Array<{word: string}>, occurrences: number}} lookup
	 * @param {string[]} codes - The row's key codes.
	 * @param {string[]} labels - The keys as the row writes them.
	 * @returns {HTMLElement[]}
	 */
	function wordsToggle(lookup, codes, labels) {
		const t = window.LAYOUT_ANALYSIS_INFO.t;
		const button = el('button', 'la-ngram-words', t('layout_analysis.trace.words'));
		button.type = 'button';
		button.setAttribute(
			'aria-label',
			t('layout_analysis.trace.words_for', { keys: labels.join(' ') })
		);
		const found = el('p', 'la-muted la-ngram-found');
		found.id = `la-ngram-words-${++wordsSerial}`;
		found.hidden = true;
		button.setAttribute('aria-expanded', 'false');
		button.setAttribute('aria-controls', found.id);
		button.addEventListener('click', () => {
			const open = button.getAttribute('aria-expanded') !== 'true';
			button.setAttribute('aria-expanded', String(open));
			found.hidden = !open;
			if (!open || found.textContent !== '') return;
			const hits = lookup(codes);
			found.textContent =
				hits.words.length === 0
					? t('layout_analysis.trace.words_none')
					: t('layout_analysis.trace.words_found', {
							words: hits.words.map((w) => w.word).join(', '),
							count: hits.occurrences
						});
		});
		return [' ', button, found];
	}

	// A counter for the ids of the words paragraphs, unique in the page.
	let wordsSerial = 0;

	/**
	 * The button under a card that unfolds its other rows, or folds them back.
	 * @param {HTMLElement} box - The cards' box (its unfolded events).
	 * @param {string} event - The card's event.
	 * @param {number} extra - The rows beyond the first ones.
	 * @param {HTMLElement} list - The card's list, which the button controls.
	 * @param {number} limit - The first rows shown.
	 * @returns {HTMLElement}
	 */
	function moreButton(box, event, extra, list, limit) {
		const t = window.LAYOUT_ANALYSIS_INFO.t;
		const open = unfolded.get(box);
		const shown = open.has(event);
		const button = el(
			'button',
			'la-ngram-more',
			t(`layout_analysis.worst.${shown ? 'fewer' : 'more'}`, { count: extra })
		);
		button.type = 'button';
		button.dataset.event = event;
		// An id of its own, so the button drawn again after a click is the same control.
		button.id = `${list.id}-more`;
		button.setAttribute('aria-expanded', String(shown));
		button.setAttribute('aria-controls', list.id);
		button.addEventListener('click', () => {
			if (shown) open.delete(event);
			else open.add(event);
			const draw = drawn.get(box);
			draw();
			// The focus on the first row added, or back on the button once folded.
			const card = box.querySelector(`.la-ngram-${event}`);
			const target = shown
				? card.querySelector('.la-ngram-more')
				: card.querySelectorAll('.la-ngram')[limit];
			if (target) target.focus();
		});
		return button;
	}

	// The last draw of each box, so « Show more » draws it again with the same groups.
	const drawn = new WeakMap();

	/** draw(), remembered for « Show more ». */
	function drawRemembered(box, options) {
		drawn.set(box, () => draw(box, options));
		draw(box, options);
	}

	return {
		EVENTS,
		DEFAULT_LIMIT,
		keyLabel,
		highlighter,
		draw: drawRemembered,
		KEY_CLASS,
		ORDER_ATTRIBUTE
	};
})();
