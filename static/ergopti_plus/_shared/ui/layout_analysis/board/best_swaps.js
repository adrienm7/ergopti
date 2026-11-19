// _shared/ui/layout_analysis/board/best_swaps.js

/**
 * ==============================================================================
 * MODULE: Best Swaps
 * DESCRIPTION:
 * « Best swaps » of the editor's analysis panel: the single swaps of two keys
 * that most improve the edited layout's global score, under the panel's
 * corpus, keyboard and score settings. The moves are the optimiser's own
 * (LAYOUT_OPTIMIZER.problem: a key's base and Shift pair moves together, the
 * letters and the prose punctuation move, Space and the digits stay) and so
 * is the scoring (incrementalObjective: each swap walks only the n-grams of
 * the characters it moves).
 *
 * FEATURES & RATIONALE:
 * 1. In slices: createRanking scores the swaps a few at a time (step), so the
 *    page runs it between frames and never freezes; mount drives the slices
 *    by time and can stop between two.
 * 2. Honest: a swap's gain is the engine's score of the swapped layout minus
 *    the edited layout's, never an estimate; only swaps that gain are listed.
 * 3. One click applies a swap through the page (onApply), as one edit the
 *    page's Undo takes back; any new analysis makes the list stale, so it is
 *    cleared and searched again on demand.
 * 4. Words and marks, not colour alone: each swap reads « é ↔ a » with its
 *    gain signed and the verdict spoken; progress is a native <progress> and
 *    the outcome is announced in a polite live region.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a vm context).
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_SWAPS = (function () {
	'use strict';

	// How many swaps the panel lists, and the smallest gain worth one.
	const LIMIT = 10;
	const MIN_GAIN = 0.005;
	// The main-thread budget of one search slice before the page yields to the
	// next frame (under one 16 ms frame, unlike a worker's slice), and swaps per step.
	const FRAME_BUDGET_MS = 12;
	const STEP_SWAPS = 4;
	// The moves: the optimiser's defaults with the prose punctuation.
	const MOVES = Object.freeze({ movePunctuation: true });
	// Digits of a gain.
	const GAIN_DIGITS = 2;

	/**
	 * The ranking of every allowed single swap of a layout.
	 * @param {object} optimizer - LAYOUT_OPTIMIZER.
	 * @param {object} engine - LAYOUT_ANALYSIS.
	 * @param {object} layout - The edited layout (library shape).
	 * @param {object} tables - Counts or prepareNgrams() output.
	 * @param {object} analysis - The analyse() options (keyboard, format, weights…).
	 * @returns {{total: number, done: function(): number, step: function(number): boolean,
	 *   best: function(number=): Array<{codes: string[], chars: string[], gain: number}>,
	 *   score: number}} step(count) scores the next count swaps and says whether
	 *   any is left.
	 * @throws {OptimizerError} When the optimiser refuses the layout (problem()).
	 */
	function createRanking(optimizer, engine, layout, tables, analysis) {
		const p = optimizer.problem(engine, layout, MOVES);
		const objective = optimizer.incrementalObjective(engine, tables, analysis);
		const base = optimizer.layoutOf(p, p.start, { id: layout.id, name: layout.name });
		const score = objective(base);
		objective.accept(base);
		const slotOf = [];
		p.start.forEach((unit, slot) => {
			slotOf[unit] = slot;
		});
		const pairs = [];
		const movable = p.movable.filter(
			(u) => p.units[u].kind !== 'empty' && p.slots[slotOf[u]].kind === 'key'
		);
		for (let i = 0; i < movable.length; i++)
			for (let j = i + 1; j < movable.length; j++) {
				const a = movable[i];
				const b = movable[j];
				if (optimizer.allowed(p, a, slotOf[b]) && optimizer.allowed(p, b, slotOf[a]))
					pairs.push([a, b]);
			}
		const found = [];
		let next = 0;
		/** The layout with two keys' base and Shift cells traded; the rest shared. */
		const swapped = (a, b) => {
			const [ca, cb] = [p.slots[slotOf[a]].code, p.slots[slotOf[b]].code];
			const rows = Object.assign({}, base.rows);
			rows[ca] = [base.rows[cb][0], base.rows[cb][1], base.rows[ca][2], base.rows[ca][3]];
			rows[cb] = [base.rows[ca][0], base.rows[ca][1], base.rows[cb][2], base.rows[cb][3]];
			return Object.assign({}, base, { rows });
		};
		return {
			total: pairs.length,
			score,
			done: () => next,
			step(count) {
				const end = Math.min(pairs.length, next + count);
				for (; next < end; next++) {
					const [a, b] = pairs[next];
					const gain = objective(swapped(a, b)) - score;
					if (gain >= MIN_GAIN)
						found.push({
							codes: [p.slots[slotOf[a]].code, p.slots[slotOf[b]].code],
							chars: [p.units[a].cells[0], p.units[b].cells[0]],
							gain
						});
				}
				return next < pairs.length;
			},
			best(limit) {
				return found
					.slice()
					.sort((x, y) => y.gain - x.gain || (x.codes.join() < y.codes.join() ? -1 : 1))
					.slice(0, limit === undefined ? LIMIT : limit);
			}
		};
	}

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	/**
	 * The « Best swaps » block: a button that searches, a progress bar, a stop
	 * button, then the best swaps, each with its gain and « Apply ».
	 * @param {HTMLElement} box - Where it draws (emptied).
	 * @param {{context: function(): (object|null), onApply: function(string[]): void}} options
	 *   context gives what to rank now ({layout, tables, analysis}, null when
	 *   nothing is analysed); onApply receives the two keys of a swap.
	 * @returns {{stale: function(): void, label: function(): void}} stale()
	 *   clears the list (a new analysis); label() redraws the words.
	 */
	function mount(box, options) {
		const t = window.LAYOUT_ANALYSIS_INFO.t;
		const format = window.LAYOUT_ANALYSIS_INFO.format;
		const title = el('h3', 'la-swaps-title');
		title.id = 'la-swaps-title';
		const note = el('p', 'la-panel-note');
		const run = el('button', 'la-swaps-run');
		run.type = 'button';
		run.id = 'la-swaps-run';
		const stop = el('button', 'la-swaps-stop');
		stop.type = 'button';
		stop.hidden = true;
		const bar = el('progress', 'la-swaps-progress');
		bar.id = 'la-swaps-progress';
		bar.hidden = true;
		const status = el('p', 'la-panel-note la-swaps-status');
		status.setAttribute('role', 'status');
		const list = el('ol', 'la-swaps-list');
		list.id = 'la-swaps-list';
		const actions = el('div', 'la-swaps-actions');
		actions.append(run, stop);
		box.replaceChildren(title, note, actions, bar, status, list);
		box.classList.add('la-swaps');
		box.setAttribute('aria-labelledby', title.id);
		let job = 0;

		function label() {
			title.textContent = t('layout_analysis.swaps.title');
			note.textContent = t('layout_analysis.swaps.note');
			run.textContent = t('layout_analysis.swaps.run');
			stop.textContent = t('layout_analysis.swaps.stop');
			bar.setAttribute('aria-label', t('layout_analysis.swaps.progress'));
		}

		function finish(text) {
			run.hidden = false;
			stop.hidden = true;
			bar.hidden = true;
			status.textContent = text;
		}

		function show(ranking) {
			const best = ranking.best();
			list.replaceChildren(
				...best.map((swap) => {
					const keys = swap.chars.map((char) => KEY_LEGEND.visibleText(char || ''));
					const gain = `+${format(swap.gain, GAIN_DIGITS)}`;
					const item = el('li', 'la-swap');
					const pair = el('span', 'la-swap-keys');
					pair.append(
						el('kbd', 'la-ngram-chip', keys[0]),
						el('span', 'la-swap-arrow', '↔'),
						el('kbd', 'la-ngram-chip', keys[1])
					);
					const verdict = t('layout_analysis.details.verdict_better');
					const score = el('span', 'la-swap-gain');
					score.append(el('span', 'la-panel-verdict', '▲'), ` ${gain}`);
					score.title = verdict;
					const apply = el('button', 'la-swap-apply', t('layout_analysis.swaps.apply'));
					apply.type = 'button';
					apply.dataset.codes = swap.codes.join(' ');
					apply.setAttribute(
						'aria-label',
						t('layout_analysis.swaps.apply_named', { a: keys[0], b: keys[1], gain })
					);
					apply.addEventListener('click', () => options.onApply(swap.codes.slice()));
					item.append(pair, score, apply);
					return item;
				})
			);
			finish(
				best.length > 0
					? t('layout_analysis.swaps.found', { count: best.length, total: ranking.total })
					: t('layout_analysis.swaps.none', { total: ranking.total })
			);
		}

		run.addEventListener('click', () => {
			const context = options.context();
			if (!context) return;
			const mine = ++job;
			list.replaceChildren();
			run.hidden = true;
			stop.hidden = false;
			bar.hidden = false;
			bar.removeAttribute('value');
			status.textContent = t('layout_analysis.swaps.preparing');
			// The first full score of the layout: after a paint, so the page shows it is busy.
			setTimeout(() => {
				if (mine !== job) return;
				let ranking;
				try {
					ranking = createRanking(
						window.LAYOUT_OPTIMIZER,
						window.LAYOUT_ANALYSIS,
						context.layout,
						context.tables,
						context.analysis
					);
				} catch (error) {
					const code = error && error.code ? error.code : 'error';
					finish(t('layout_analysis.swaps.failed', { reason: code }));
					return;
				}
				bar.max = Math.max(1, ranking.total);
				bar.value = 0;
				status.textContent = t('layout_analysis.swaps.searching', { total: ranking.total });
				const slice = () => {
					if (mine !== job) return;
					const until = performance.now() + FRAME_BUDGET_MS;
					let more = true;
					while (more && performance.now() < until) more = ranking.step(STEP_SWAPS);
					bar.value = ranking.done();
					if (more) setTimeout(slice, 0);
					else show(ranking);
				};
				setTimeout(slice, 0);
			}, 0);
		});
		stop.addEventListener('click', () => {
			job += 1;
			finish(t('layout_analysis.swaps.stopped'));
			run.focus();
		});

		label();
		return {
			stale() {
				// A list or a search of the layout before goes, and the page says why.
				if (list.children.length === 0 && stop.hidden) return;
				job += 1;
				list.replaceChildren();
				finish(t('layout_analysis.swaps.stale'));
			},
			label
		};
	}

	return { createRanking, mount, LIMIT, MIN_GAIN };
})();
