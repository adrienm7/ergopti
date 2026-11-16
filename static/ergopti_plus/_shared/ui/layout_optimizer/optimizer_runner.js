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
	 *   iterations, startMode ('layout' | 'random'), timeBudgetMs?, identity
	 *   ({id, name} of the result)}.
	 * @param {function(object): void} post - Receives the messages.
	 * @returns {{stop: function(): void}}
	 */
	function start(request, post) {
		const E = LAYOUT_ANALYSIS;
		const O = LAYOUT_OPTIMIZER;
		let search;
		let full;
		try {
			const p = O.problem(E, request.start, request.options);
			full = O.engineObjective(E, request.tables, request.analysis);
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
				start: request.startMode,
				timeBudgetMs: request.timeBudgetMs
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
					post({
						type: 'progress',
						progress: state,
						layout: improved ? search.result(request.identity).layout : null
					});
					lastBest = state.best;
				}
				if (!search.done()) {
					timer = setTimeout(tick, 0);
					return;
				}
				const result = search.result(request.identity);
				result.searchScore = result.score;
				result.score = full(result.layout);
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

	return { start };
})();
