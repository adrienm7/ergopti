// _shared/ui/layout_optimizer/optimizer_runner.js

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Runner
 * DESCRIPTION:
 * Drives one share of an optimizer run in slices, so the thread that runs it
 * keeps answering: in a Web Worker (optimizer_worker.js) on the site, or on
 * the page itself where workers are unavailable (a page a host inlines).
 * It posts progress messages and, at the end, the best layout with the
 * engine's score of it on the whole corpus.
 *
 * FEATURES & RATIONALE:
 * 1. One protocol for both threads: start(request, post) posts
 *    {type: 'progress' | 'done' | 'error'} objects, stop() ends the run at
 *    the next slice and still posts the best layout found.
 * 2. The search may score on the corpus's most frequent n-grams (request.share);
 *    the score reported at the end is always the engine's score on the whole
 *    corpus, so it is the one the Comparer shows for the same layout.
 * 3. After a run, scoreLibrary() scores the layout library on the same corpus
 *    and settings, with each layout's similarity to the optimized one, in the
 *    same slices; librarySummary() reads which existing layout comes close.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page (and of a worker).
// eslint-disable-next-line no-unused-vars
var LAYOUT_OPTIMIZER_RUNNER = (function () {
	'use strict';

	// Time one slice may take before the thread yields (ms).
	const SLICE_MS = 40;
	// Iterations between two clock reads inside a slice.
	const STEP = 4;
	// Progress is posted at least this often (ms), and at once on a new best.
	const PROGRESS_MS = 250;

	/**
	 * Starts one share of a run.
	 * @param {object} request - {start (library-shape layout), options (the
	 *   problem's constraints), tables (n-gram counts), analysis (analyse()
	 *   options: weights, keyboard, format), share (0 < share ≤ 1 of each
	 *   n-gram table the search scores on), seed, restarts, firstRestart,
	 *   iterations, method (one of LAYOUT_OPTIMIZER.METHODS), startMode
	 *   ('layout' | 'random'), timeBudgetMs?, identity
	 *   ({id, name} of the result), changeWeight (score points per % of the
	 *   corpus's characters moved from the start, LAYOUT_OPTIMIZER.changeCost;
	 *   0 for none)}. A progress message with a new best carries its layout
	 *   and change (changeCost's changed()); the done message's result has
	 *   engineScore, the engine's score on the whole corpus, and score, that
	 *   less the change penalty (the objective bestOf compares).
	 * @param {function(object): void} post - Receives the messages.
	 * @returns {{stop: function(): void}}
	 */
	function start(request, post) {
		const E = LAYOUT_ANALYSIS;
		const O = LAYOUT_OPTIMIZER;
		let search;
		let full;
		let changeCost;
		try {
			const p = O.problem(E, request.start, request.options);
			full = O.engineObjective(E, request.tables, request.analysis);
			// What the result changes is always said; it costs only with a weight.
			changeCost = O.changeCost(E, p, request.tables);
			// The search scores each swap incrementally; the last word is the full analysis.
			const objective = O.incrementalObjective(
				E,
				O.searchTables(E, request.tables, request.share),
				request.analysis
			);
			search = O.createSearch(p, {
				objective,
				seed: request.seed,
				restarts: request.restarts,
				firstRestart: request.firstRestart,
				iterations: request.iterations,
				method: request.method,
				start: request.startMode,
				timeBudgetMs: request.timeBudgetMs,
				changeWeight: request.changeWeight,
				changeCost
			});
		} catch (error) {
			post({
				type: 'error',
				code: error.code || '',
				values: error.values || {},
				message: String(error.message)
			});
			return { stop() {} };
		}
		let lastBest = -Infinity;
		let lastPost = 0;
		let timer = null;

		function tick() {
			timer = null;
			let state;
			try {
				const until = Date.now() + SLICE_MS;
				do state = search.step(STEP);
				while (!search.done() && Date.now() < until);
				const improved = state.best > lastBest;
				if (improved || search.done() || Date.now() - lastPost >= PROGRESS_MS) {
					lastPost = Date.now();
					const best = improved ? search.result(request.identity) : null;
					post({
						type: 'progress',
						progress: state,
						layout: best ? best.layout : null,
						change: best ? best.change : null
					});
					lastBest = state.best;
				}
				if (!search.done()) {
					timer = setTimeout(tick, 0);
					return;
				}
				const result = search.result(request.identity);
				result.searchScore = result.score;
				result.engineScore = full(result.layout);
				result.score =
					request.changeWeight > 0
						? result.engineScore - request.changeWeight * result.change.share
						: result.engineScore;
				post({ type: 'done', result });
			} catch (error) {
				post({
					type: 'error',
					code: error.code || '',
					values: error.values || {},
					message: String(error.message)
				});
			}
		}
		timer = setTimeout(tick, 0);
		return {
			stop() {
				search.stop();
				// A slice already queued finishes the run; otherwise end it now.
				if (timer === null) tick();
			}
		};
	}

	/**
	 * Scores the layout library on a run's corpus and settings, and measures
	 * how alike each library layout is to the optimized one
	 * (LAYOUT_ANALYSIS.layoutSimilarity), a few layouts per slice so the
	 * thread keeps answering: one analysis of a layout with many dead keys
	 * takes a few hundred milliseconds.
	 * @param {object} request - {layout (the optimized layout, library
	 *   shape), tables (n-gram counts), analysis (the run's analyse()
	 *   options: keyboard, format, weights, profile…)}.
	 * @param {function(object): void} post - Receives {type:
	 *   'library_progress', done, total}, then {type: 'library_done',
	 *   entries: [{id, name, score, mark, reference, incomplete, similarity:
	 *   {weighted, unweighted}}]} in the library's order, or {type: 'error', code,
	 *   values, message}.
	 * @returns {{stop: function(): void}} Ends the scan at the next slice, with
	 *   no further message.
	 */
	function scoreLibrary(request, post) {
		const E = LAYOUT_ANALYSIS;
		const fail = (error) =>
			post({
				type: 'error',
				code: error.code || '',
				values: error.values || {},
				message: String(error.message)
			});
		let layouts;
		let table;
		try {
			layouts = E.libraryLayouts();
			table = E.prepareNgrams(request.tables);
		} catch (error) {
			fail(error);
			return { stop() {} };
		}
		const placing = { keyboard: request.analysis.keyboard, profile: request.analysis.profile };
		const entries = [];
		let at = 0;
		let stopped = false;

		function tick() {
			if (stopped) return;
			try {
				const until = Date.now() + SLICE_MS;
				do {
					const layout = layouts[at];
					at += 1;
					const result = E.analyse(layout, table, request.analysis);
					const similarity = E.layoutSimilarity(request.layout, layout, table, placing);
					entries.push({
						id: layout.id,
						name: layout.name,
						score: result.score.total,
						mark: result.score.mark,
						reference: result.score.reference,
						incomplete: result.incomplete,
						similarity: { weighted: similarity.weighted, unweighted: similarity.unweighted }
					});
				} while (at < layouts.length && Date.now() < until);
				post({ type: 'library_progress', done: at, total: layouts.length });
				if (at < layouts.length) setTimeout(tick, 0);
				else post({ type: 'library_done', entries });
			} catch (error) {
				fail(error);
			}
		}
		setTimeout(tick, 0);
		return {
			stop() {
				stopped = true;
			}
		};
	}

	/**
	 * What the library comparison says of an optimized layout: the library
	 * layouts most alike to it, and the best-scoring one (every complete
	 * layout before an incomplete one, as the Comparer ranks), each with its
	 * gap; the verdict reads the best one's gap, in % of its mark, against
	 * the small gap.
	 * @param {object[]} entries - scoreLibrary()'s entries, all on one
	 *   QWERTY total (one corpus and settings).
	 * @param {number} optimized - The optimized layout's score (its total).
	 * @param {{smallGap: number, closest: number}} settings - The mark gap,
	 *   in % of the best existing layout's mark, under which an existing
	 *   layout does the job (LAYOUT_ANALYSIS.similarMarkGap), and how many
	 *   alike layouts to list.
	 * @returns {{closest: object[], best: object, verdict: string, smallGap:
	 *   number, mark: number}} Each layout {id, name, score, mark, reference,
	 *   incomplete, similarity, gap, percent}, gap = the optimized layout's
	 *   mark − its mark (positive: the optimized layout marks more), percent =
	 *   that gap in % of the best existing layout's mark (LAYOUT_ANALYSIS
	 *   .markPercent); mark: the optimized layout's (LAYOUT_ANALYSIS
	 *   .markIndex); verdict `existing_better` (percent < 0), `small_gap`
	 *   (percent ≤ smallGap) or `optimized_ahead`.
	 * @throws {Error} On no entry, a non-finite score or mark, entries on two
	 *   QWERTY totals, a best mark not above 0, or invalid settings.
	 */
	function librarySummary(entries, optimized, settings) {
		if (!Array.isArray(entries) || entries.length === 0)
			throw new Error('layout_optimizer: no library layout to compare with');
		if (!Number.isFinite(optimized))
			throw new Error(`layout_optimizer: the optimized score ${optimized} is not a number`);
		const reference = entries[0].reference;
		if (!Number.isFinite(reference) || entries.some((entry) => entry.reference !== reference))
			throw new Error('layout_optimizer: the library layouts are not on one QWERTY total');
		// QWERTY's total is the same for every layout on one corpus and settings.
		const mark = LAYOUT_ANALYSIS.markIndex(optimized, reference);
		const { smallGap, closest } = settings;
		if (!Number.isFinite(smallGap) || smallGap < 0)
			throw new Error(`layout_optimizer: small gap ${smallGap} is not a number ≥ 0`);
		if (!Number.isInteger(closest) || closest < 1)
			throw new Error(`layout_optimizer: ${closest} alike layouts to list`);
		for (const entry of entries)
			if (!Number.isFinite(entry.score) || !Number.isFinite(entry.mark))
				throw new Error(`layout_optimizer: ${entry.id} has no score`);
		const top = entries
			.slice()
			.sort((a, b) => Number(a.incomplete) - Number(b.incomplete) || b.score - a.score)[0];
		// Every gap is a share of the best existing layout's mark: QWERTY is in
		// the library and complete, so that mark is at least 100.
		const rows = entries.map((entry) => {
			const gap = mark - entry.mark;
			const percent = LAYOUT_ANALYSIS.markPercent(gap, top.mark);
			return Object.assign({}, entry, { gap, percent });
		});
		const alike = rows
			.slice()
			.sort(
				(a, b) =>
					b.similarity.weighted.sameKey - a.similarity.weighted.sameKey ||
					b.similarity.weighted.sameFingerRow - a.similarity.weighted.sameFingerRow ||
					b.score - a.score
			)
			.slice(0, closest);
		const best = rows.find((row) => row.id === top.id);
		const verdict =
			best.percent < 0
				? 'existing_better'
				: best.percent <= smallGap
					? 'small_gap'
					: 'optimized_ahead';
		return { closest: alike, best, verdict, smallGap, mark };
	}

	return { start, scoreLibrary, librarySummary };
})();
