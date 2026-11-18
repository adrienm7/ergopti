// _shared/ui/layout_analysis/analyser_tab.js

/**
 * ==============================================================================
 * MODULE: Other Analysers Tab
 * DESCRIPTION:
 * The « Autres analyseurs » view of the Comparer: for each compared layout,
 * its score as every public analyser of analyser_scores.js computes it, with
 * the analyser's own fingering (« official ») and with the user's finger model
 * (« custom ») side by side, each analyser with its « i » popover (source,
 * licence, fidelity). Same page on ergopti.fr and in the app's Studio window.
 *
 * FEATURES & RATIONALE:
 * 1. Follows the Comparer through LAYOUT_ANALYSIS_COMPARER.onResults, never
 *    its state: the same layouts, corpus and keyboard.
 * 2. Lazy: nothing is scored until the view is shown, then one layout per
 *    idle slice, so the Comparer stays responsive (every analyser, both
 *    fingerings, costs about 70 ms per layout).
 * 3. Every string is a locale key; numbers use the page's locale.
 * 4. Scores or ranks: each analyser's rank of the layouts beside the
 *    Comparer's, the cell shaded on one blue ramp (rank 1 darkest), the rank
 *    always written; every column sorts from a header button (aria-sort).
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSER_TAB = (function () {
	'use strict';

	const FINGERINGS = ['official', 'custom'];
	// Literal keys, so the locale gate finds every string the view shows.
	const FINGERING_LABEL = {
		official: () => t('layout_analysis.analysers.official'),
		custom: () => t('layout_analysis.analysers.custom')
	};
	// What the cells show: each analyser's score, or the rank it gives.
	const VIEWS = ['scores', 'ranks'];
	const VIEW_LABEL = {
		scores: () => t('layout_analysis.analysers.view_scores'),
		ranks: () => t('layout_analysis.analysers.view_ranks')
	};
	// A rank cell at least this share of the darkest is dark enough for light ink.
	const STRONG_SHARE = 0.55;
	const DIRECTION_LABEL = {
		higher: () => t('layout_analysis.analysers.better.higher'),
		lower: () => t('layout_analysis.analysers.better.lower'),
		none: () => t('layout_analysis.analysers.better.none')
	};

	/** Translates a locale key; an unknown key shows itself so the gap is visible. */
	function t(key, values) {
		const strings = window._i18n_strings || {};
		let text = typeof strings[key] === 'string' ? strings[key] : key;
		for (const [name, value] of Object.entries(values || {}))
			text = text.split(`{${name}}`).join(String(value));
		return text;
	}

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	// Every number in the language of the page's strings; info_popover.js loads
	// after this script, so it is read when a number is written.
	const format = (value, digits) => window.LAYOUT_ANALYSIS_INFO.format(value, digits);

	/**
	 * Draws the view in a container and follows the Comparer.
	 * @param {HTMLElement} container - Where the view goes (the owner places it).
	 * @param {{comparer?: object}} [options] - The mounted Comparer (default
	 *   window.LAYOUT_ANALYSIS_COMPARER). The user's finger model is
	 *   LAYOUT_ANALYSIS_FINGERING.current(keyboard); a change re-scores.
	 * @throws {Error} On a missing container or Comparer.
	 */
	function attach(container, options) {
		if (!container || typeof container.append !== 'function')
			throw new Error('analyser_tab: attach needs an element');
		const opts = options || {};
		const comparer = opts.comparer || window.LAYOUT_ANALYSIS_COMPARER;
		if (!comparer || typeof comparer.onResults !== 'function')
			throw new Error('analyser_tab: no Comparer to follow');
		const S = window.LAYOUT_ANALYSER_SCORES;
		const INFO = window.LAYOUT_ANALYSIS_INFO;
		const analysers = S.analysers();

		const section = el('section', 'la-analysers');
		// Texts are set on every render: the page's strings may arrive after attach.
		const title = el('h2');
		const intro = el('p', 'la-muted');
		const status = el('p', 'la-muted');
		const viewField = el('label', 'la-filter-field');
		const viewName = el('span');
		const view = el('select');
		view.id = 'la-analysers-view';
		viewField.append(viewName, view);
		const viewCaption = el('p', 'la-muted');
		const wrap = el('div', 'la-table-wrap');
		wrap.tabIndex = 0;
		const table = el('table', 'la-table la-heat-table la-analysers-table');
		wrap.append(table);
		section.append(title, intro, viewField, viewCaption, status, wrap);
		container.append(section);
		container.hidden = false;

		const state = {
			results: [],
			layouts: new Map(),
			tables: null,
			keyboard: 'iso',
			scores: new Map(),
			sort: null,
			view: VIEWS[0],
			job: 0
		};
		view.addEventListener('change', () => {
			state.view = view.value;
			render();
		});
		const FINGERING = window.LAYOUT_ANALYSIS_FINGERING;

		/** The text of one score: its value, or the headline statistics of a score-less analyser. */
		function cellText(a, r) {
			if (!r) return '…';
			if (a.better !== 'none') return format(r.value, a.digits);
			return a.headline
				.map(
					(part) => `${t(`layout_analysis.analysers.part.${part}`)} ${format(r.parts[part], 1)} %`
				)
				.join(' · ');
		}

		function header() {
			const thead = el('thead');
			const top = el('tr');
			const sub = el('tr');
			const name = el('th', '', t('layout_analysis.analysers.layout'));
			name.scope = 'col';
			top.append(name);
			sub.append(el('td'));
			for (const a of analysers) {
				const th = el('th', 'la-analyser');
				th.scope = 'colgroup';
				th.colSpan = FINGERINGS.length;
				th.append(el('span', '', a.name), INFO.button(`analyser.${a.id}`));
				th.append(el('small', 'la-muted', DIRECTION_LABEL[a.better]()));
				top.append(th);
				for (const fingering of FINGERINGS) {
					const cell = el('th', 'la-sortable');
					cell.scope = 'col';
					// A score-less analyser has nothing to sort by.
					if (a.better === 'none') cell.textContent = FINGERING_LABEL[fingering]();
					else {
						// The sort is a button, so the keyboard reaches it.
						const button = el('button', 'la-sort', FINGERING_LABEL[fingering]());
						button.type = 'button';
						button.dataset.sort = `${a.id}.${fingering}`;
						button.addEventListener('click', () => {
							sortBy(a, fingering);
							const again = table.querySelector(`button[data-sort="${a.id}.${fingering}"]`);
							if (again) again.focus();
						});
						cell.append(button);
						if (state.sort && state.sort.id === a.id && state.sort.fingering === fingering)
							cell.setAttribute(
								'aria-sort',
								// The values' order: the best first, lowest or highest by the analyser.
								(a.better === 'lower') !== state.sort.flip ? 'ascending' : 'descending'
							);
					}
					sub.append(cell);
				}
			}
			thead.append(top, sub);
			return thead;
		}

		/**
		 * Each layout's rank by each analyser and fingering (1: the analyser's
		 * best), among the layouts scored so far; ties share a rank.
		 * @returns {Map<string, number>} `${layout}|${analyser}|${fingering}` → rank.
		 */
		function ranks() {
			const out = new Map();
			const scored = state.results.filter((r) => state.scores.has(r.layout.id));
			for (const a of analysers) {
				if (a.better === 'none') continue;
				for (const fingering of FINGERINGS) {
					const value = (r) => state.scores.get(r.layout.id)[a.id][fingering].value;
					const sorted = scored
						.filter((r) => Number.isFinite(value(r)))
						.sort((x, y) => (a.better === 'lower' ? value(x) - value(y) : value(y) - value(x)));
					sorted.forEach((r, i) => {
						const tied = i > 0 && value(sorted[i - 1]) === value(r);
						const rank = tied ? out.get(`${sorted[i - 1].layout.id}|${a.id}|${fingering}`) : i + 1;
						out.set(`${r.layout.id}|${a.id}|${fingering}`, rank);
					});
				}
			}
			return out;
		}

		function sortBy(a, fingering) {
			const same = state.sort && state.sort.id === a.id && state.sort.fingering === fingering;
			state.sort = { id: a.id, fingering, better: a.better, flip: same && !state.sort.flip };
			render();
		}

		function ordered() {
			const rows = state.results.slice();
			if (!state.sort) return rows;
			const { id, fingering, better, flip } = state.sort;
			const value = (r) => {
				const s = state.scores.get(r.layout.id);
				return s ? s[id][fingering].value : NaN;
			};
			rows.sort((x, y) => {
				const d = better === 'lower' ? value(x) - value(y) : value(y) - value(x);
				return (Number.isNaN(d) ? 0 : d) * (flip ? -1 : 1);
			});
			return rows;
		}

		function render() {
			title.textContent = t('layout_analysis.analysers.title');
			intro.textContent = t('layout_analysis.analysers.intro');
			viewName.textContent = t('layout_analysis.analysers.view');
			view.replaceChildren(
				...VIEWS.map((id) => {
					const option = el('option', '', VIEW_LABEL[id]());
					option.value = id;
					return option;
				})
			);
			view.value = state.view;
			viewCaption.textContent =
				state.view === 'ranks' ? t('layout_analysis.analysers.ranks_caption') : '';
			const byRank = state.view === 'ranks' ? ranks() : null;
			const last = byRank ? Math.max(...byRank.values(), 1) : 1;
			const tbody = el('tbody');
			for (const result of ordered()) {
				const tr = el('tr');
				const name = el('th', 'la-name', result.layout.name);
				name.scope = 'row';
				tr.append(name);
				const s = state.scores.get(result.layout.id);
				for (const a of analysers)
					for (const fingering of FINGERINGS) {
						const rank = byRank && byRank.get(`${result.layout.id}|${a.id}|${fingering}`);
						if (!rank) {
							tr.append(el('td', 'la-num', cellText(a, s && s[a.id][fingering])));
							continue;
						}
						// One blue ramp, the first rank darkest; the rank is written in the cell.
						const share = last > 1 ? (last - rank) / (last - 1) : 1;
						const cell = el('td', 'la-num la-cell la-cell-count', format(rank, 0));
						cell.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
						if (share >= STRONG_SHARE) cell.classList.add('la-cell-strong');
						cell.title = `${a.name} (${FINGERING_LABEL[fingering]()}): ${cellText(a, s[a.id][fingering])}`;
						tr.append(cell);
					}
				tbody.append(tr);
			}
			table.replaceChildren(header(), tbody);
			const done = state.results.filter((r) => state.scores.has(r.layout.id)).length;
			status.textContent =
				done < state.results.length
					? t('layout_analysis.analysers.computing', { done, total: state.results.length })
					: '';
		}

		const idle = (fn) =>
			typeof window.requestIdleCallback === 'function'
				? window.requestIdleCallback(fn)
				: setTimeout(fn, 0);

		/** Scores the compared layouts one per idle slice; a new comparison restarts. */
		function compute() {
			const job = ++state.job;
			const pending = state.results.filter((r) => !state.scores.has(r.layout.id));
			const next = () => {
				if (job !== state.job || pending.length === 0) return;
				const result = pending.shift();
				const layout = state.layouts.get(result.layout.id);
				if (!layout)
					throw new Error(`analyser_tab: no layout ${result.layout.id} from the Comparer`);
				state.scores.set(
					result.layout.id,
					S.scoreAll(layout, state.tablesOf(result), {
						keyboard: state.keyboard,
						profile: FINGERING.current(state.keyboard) || undefined
					})
				);
				render();
				idle(next);
			};
			render();
			idle(next);
		}

		let visible = typeof IntersectionObserver !== 'function';
		if (!visible)
			new IntersectionObserver((entries) => {
				visible = entries.some((e) => e.isIntersecting);
				if (visible) compute();
			}).observe(section);

		const restart = () => {
			state.scores = new Map();
			if (visible) compute();
			else render();
		};
		comparer.onResults((results, tables, { keyboard, layouts, tablesOf }) => {
			// Each result's own tables: the Comparer's « + » layouts type another text.
			if (typeof tablesOf !== 'function')
				throw new Error('analyser_tab: the Comparer names the tables of each result');
			state.results = results;
			state.layouts = layouts;
			state.tables = tables;
			state.tablesOf = tablesOf;
			state.keyboard = keyboard;
			restart();
		});
		// A new finger model changes every « custom » score.
		FINGERING.onChange(restart);
	}

	return { attach };
})();
