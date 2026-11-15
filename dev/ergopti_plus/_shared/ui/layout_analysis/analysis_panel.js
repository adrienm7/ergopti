// _shared/ui/layout_analysis/analysis_panel.js

/**
 * ==============================================================================
 * MODULE: Layout Analysis Panel
 * DESCRIPTION:
 * The live analysis beside the « Éditer » tab of Ergopti Studio: the score of
 * the layout being edited, its rank among the shared library, its main
 * metrics with what the last edit changed, and its finger load, on a chosen
 * corpus and keyboard. The editor page (site and app) creates one panel and
 * calls update(doc) after each render.
 *
 * FEATURES & RATIONALE:
 * 1. One engine: the edited source becomes the engine's layout through the
 *    same path as the registry layouts (its ISO .keylayout, read by the
 *    layout composer, converted by layoutFromComposerSource).
 * 2. Live: an edit is analysed after a short pause on prepared n-gram tables
 *    (a few milliseconds); the library is ranked once per corpus, keyboard,
 *    weights and ideal finger load.
 * 3. Same score as the Comparer: the weights and the ideal finger load set in
 *    « Comparer » (its saved settings) apply here.
 * 4. « Ma frappe »: the app's 'studio-ngrams' event adds the user's own
 *    typing as the default corpus, as in the Comparer.
 * 5. The other analysers' scores (LAYOUT_ANALYSER_SCORES): each analyser's
 *    official score is drawn with the analysis, the score with the user's
 *    finger model on the next tick, so the panel paints first. Extra
 *    sections register with addSection and draw after each analysis.
 * 6. A layout the page cannot analyse says why; nothing is shown as a score
 *    that was not computed.
 * ==============================================================================
 */

// A classic script's top-level var is a global of the page.
// eslint-disable-next-line no-unused-vars
var LAYOUT_ANALYSIS_PANEL = (function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const INFO = window.LAYOUT_ANALYSIS_INFO;
	const FILES = window.LAYOUT_ANALYSIS_FILES;
	const SCORES = window.LAYOUT_ANALYSER_SCORES;
	const t = INFO.t;
	// The metrics the panel lists; the Comparer shows them all.
	const PANEL_METRICS = [
		'sfb',
		'sfs',
		'lsb',
		'scissors',
		'redirect_bad',
		'roll_in',
		'alternation',
		'home_row',
		'distance',
		'pinky_load',
		'finger_imbalance',
		'shortcut_left',
		'unsupported'
	];
	// Every keyboard of the model, in its order.
	const KEYBOARDS = Object.keys(DATA.model.keyboards);
	const UPDATE_DEBOUNCE_MS = 150;
	const STORAGE_KEY = 'ergopti.layout_analysis.panel.v1';
	const NGRAMS_EVENT = 'studio-ngrams';
	const MY_TYPING_ID = 'my_typing';
	// The ISO board the edited source is described on.
	const SOURCE_BOARD = 'iso';
	const SCORE_DIGITS = 1;
	// A change smaller than this is shown as none.
	const DELTA_EPSILON = 0.005;
	// Digits of the headline statistics of an analyser without a score.
	const PART_DIGITS = 1;
	// Shown in a score's cell until it is computed.
	const PENDING_TEXT = '…';

	function el(tag, className, text) {
		const node = document.createElement(tag);
		if (className) node.className = className;
		if (text !== undefined) node.textContent = text;
		return node;
	}

	const format = (value, digits) =>
		Number(value).toLocaleString(window._i18n_locale || undefined, {
			minimumFractionDigits: digits,
			maximumFractionDigits: digits
		});
	const metricDigits = (id) => (E.METRICS[id].unit === 'mm' ? 1 : 2);
	const unitText = (id) => (E.METRICS[id].unit === 'mm' ? t('layout_analysis.unit.mm') : '%');

	/**
	 * The engine's layout for an editor document.
	 * @param {object} doc - A LayoutSourceIO document.
	 * @returns {object} The layout in the library shape.
	 * @throws {Error} When the document cannot be compiled to an ISO .keylayout
	 *   (the compiler's refusal, with its code).
	 */
	function layoutFromEditorDoc(doc) {
		const file = window.LayoutSourceIO.keylayoutFile(doc, SOURCE_BOARD);
		const source = window.LayoutComposer.parseSource(
			doc.layout.id,
			file.text,
			SOURCE_BOARD,
			// A top-level const of composer_data.js: a page global, not a window property.
			LAYOUT_COMPOSER_DATA
		);
		const layout = E.layoutFromComposerSource(source, E.typingCodes());
		layout.name = doc.layout.name || doc.layout.id;
		layout.origin = 'user';
		return layout;
	}

	/** Reads a stored value; an unavailable storage gives none. */
	function readStorage(key) {
		try {
			const raw = window.localStorage.getItem(key);
			return raw ? JSON.parse(raw) : {};
		} catch {
			return {};
		}
	}

	/** The Comparer's weights and ideal finger load, each checked by the engine. */
	function comparerSettings() {
		const saved = readStorage(FILES.SETTINGS_KEY);
		const settings = {};
		try {
			// score() refuses an unknown metric or an invalid weight.
			if (saved.weights) E.score({ metrics: {} }, saved.weights);
			settings.weights = saved.weights;
		} catch {
			settings.weights = undefined;
		}
		try {
			settings.idealLoad = saved.idealLoad ? E.idealLoad(saved.idealLoad) : undefined;
		} catch {
			settings.idealLoad = undefined;
		}
		// The user's fingering profile, shared with the Comparer.
		settings.profile = window.LAYOUT_ANALYSIS_FINGERING.current() || undefined;
		return settings;
	}

	/**
	 * Creates a panel. The page appends `node` where it wants it, every render
	 * (the same node), and calls update(doc) after each render.
	 * @returns {{node: HTMLElement, update: function(object): void,
	 *   addSection: function(function(HTMLElement, object): void): void}}
	 */
	function create() {
		const saved = readStorage(STORAGE_KEY);
		const corpora = DATA.corpora.map((c) => ({ id: c.id, title: c.title, builtin: c }));
		const state = {
			corpus: corpora.some((c) => c.id === saved.corpus) ? saved.corpus : corpora[0].id,
			keyboard: KEYBOARDS.includes(saved.keyboard) ? saved.keyboard : SOURCE_BOARD,
			doc: null,
			previous: null,
			library: null,
			libraryKey: '',
			timer: null,
			generation: 0
		};
		const sections = [];

		const node = el('details', 'la-panel');
		node.open = saved.open !== false;
		const summary = el('summary', 'la-panel-title');
		const corpusSelect = el('select');
		corpusSelect.id = 'la-panel-corpus';
		const keyboardSelect = el('select');
		keyboardSelect.id = 'la-panel-keyboard';
		const corpusLabel = el('label');
		corpusLabel.htmlFor = corpusSelect.id;
		const keyboardLabel = el('label');
		keyboardLabel.htmlFor = keyboardSelect.id;
		const controls = el('div', 'la-panel-controls');
		controls.append(corpusLabel, corpusSelect, keyboardLabel, keyboardSelect);
		const headline = el('p', 'la-panel-score');
		headline.setAttribute('role', 'status');
		const note = el('p', 'la-panel-note');
		const metrics = el('table', 'la-panel-metrics');
		const fingersTitle = el('h3');
		const fingers = el('div', 'la-panel-fingers');
		const analysersTitle = el('h3');
		const analysers = el('table', 'la-panel-metrics la-panel-analysers');
		const extra = el('div', 'la-panel-extra');
		node.append(
			summary,
			controls,
			headline,
			note,
			metrics,
			fingersTitle,
			fingers,
			analysersTitle,
			analysers,
			extra
		);

		function persist() {
			try {
				window.localStorage.setItem(
					STORAGE_KEY,
					JSON.stringify({ corpus: state.corpus, keyboard: state.keyboard, open: node.open })
				);
			} catch {
				// A private window or a full quota: the panel keeps working unsaved.
			}
		}

		function fillControls() {
			summary.textContent = t('layout_analysis.panel.title');
			corpusLabel.textContent = t('layout_analysis.corpus.label');
			keyboardLabel.textContent = t('layout_analysis.keyboard.label');
			fingersTitle.textContent = t('layout_analysis.details.fingers');
			analysersTitle.textContent = t('layout_analysis.analysers.title');
			note.textContent = t('layout_analysis.panel.weights_note');
			corpusSelect.replaceChildren(
				...corpora.map((c) => {
					const option = el(
						'option',
						'',
						c.id === MY_TYPING_ID ? t('layout_analysis.corpus.my_typing') : c.title
					);
					option.value = c.id;
					return option;
				})
			);
			corpusSelect.value = state.corpus;
			keyboardSelect.replaceChildren(
				...KEYBOARDS.map((id) => {
					const option = el('option', '', t(`layout_analysis.keyboard.${id}`));
					option.value = id;
					return option;
				})
			);
			keyboardSelect.value = state.keyboard;
		}

		async function tables() {
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus.host) return E.prepareNgrams(corpus.host);
			return E.prepareNgrams(await FILES.builtinTables(corpus.builtin));
		}

		/** The library's scores on these settings, computed once for them. */
		function libraryScores(prepared, settings) {
			const key = JSON.stringify([state.corpus, state.keyboard, settings]);
			if (state.libraryKey !== key) {
				state.library = E.compare(E.libraryLayouts(), prepared, {
					keyboard: state.keyboard,
					weights: settings.weights,
					idealLoad: settings.idealLoad,
					profile: settings.profile
				}).map((r) => r.score.total);
				state.libraryKey = key;
			}
			return state.library;
		}

		function showError(text) {
			headline.textContent = text;
			headline.className = 'la-panel-score la-panel-error';
			metrics.replaceChildren();
			fingers.replaceChildren();
			analysers.replaceChildren();
			extra.replaceChildren();
		}

		async function run() {
			if (!state.doc || !node.open) return;
			const mine = ++state.generation;
			let layout;
			try {
				layout = layoutFromEditorDoc(state.doc);
			} catch (error) {
				showError(
					t('layout_analysis.panel.unavailable', {
						reason: (error && (error.code || error.message)) || 'error'
					})
				);
				return;
			}
			let prepared;
			try {
				prepared = await tables();
			} catch {
				showError(t('layout_analysis.status.corpus_failed'));
				return;
			}
			if (mine !== state.generation) return;
			const settings = comparerSettings();
			const result = E.analyse(layout, prepared, {
				keyboard: state.keyboard,
				weights: settings.weights,
				idealLoad: settings.idealLoad,
				profile: settings.profile
			});
			note.textContent = settings.profile
				? `${t('layout_analysis.panel.weights_note')} ${t('layout_analysis.fingering.custom')}`
				: t('layout_analysis.panel.weights_note');
			if (state.libraryKey !== JSON.stringify([state.corpus, state.keyboard, settings]))
				headline.textContent = t('layout_analysis.panel.ranking');
			// The first ranking of a corpus takes a moment: let the page paint first.
			await new Promise((resolve) => setTimeout(resolve, 0));
			if (mine !== state.generation) return;
			const scores = libraryScores(prepared, settings);
			const rank = 1 + scores.filter((score) => score > result.score.total).length;
			headline.className = 'la-panel-score';
			headline.textContent = t('layout_analysis.panel.score', {
				score: format(result.score.total, SCORE_DIGITS),
				rank,
				count: scores.length + 1
			});
			const same =
				state.previous &&
				state.previous.corpus === state.corpus &&
				state.previous.keyboard === state.keyboard;
			drawMetrics(result, same ? state.previous.metrics : null);
			drawFingers(result);
			drawAnalysers(layout, prepared, settings, mine);
			extra.replaceChildren();
			for (const draw of sections) {
				const box = el('div', 'la-panel-section');
				extra.append(box);
				draw(box, { layout, tables: prepared, keyboard: state.keyboard, result });
			}
			state.previous = { corpus: state.corpus, keyboard: state.keyboard, metrics: result.metrics };
		}

		function drawMetrics(result, before) {
			metrics.replaceChildren();
			for (const id of PANEL_METRICS) {
				const tr = el('tr');
				const th = el('th', '', t(`layout_analysis.metric.${id}`));
				th.scope = 'row';
				th.append(' ', INFO.button(id));
				const value = result.metrics[id];
				const td = el('td', '', `${format(value, metricDigits(id))} ${unitText(id)}`);
				const delta = el('td', 'la-panel-delta');
				if (before && Math.abs(value - before[id]) >= DELTA_EPSILON) {
					const change = value - before[id];
					const better = E.METRICS[id].better;
					const good = better === 'higher' ? change > 0 : better === 'lower' ? change < 0 : null;
					delta.textContent = `${change > 0 ? '+' : '−'}${format(Math.abs(change), metricDigits(id))}`;
					if (good !== null) delta.classList.add(good ? 'la-panel-good' : 'la-panel-bad');
				}
				tr.append(th, td, delta);
				metrics.append(tr);
			}
		}

		function drawFingers(result) {
			fingers.replaceChildren();
			const ideal = comparerSettings().idealLoad || E.defaultIdealLoad();
			for (const id of DATA.model.fingers) {
				const row = el('div', 'la-panel-finger');
				const share = result.fingers[id];
				const bar = el('span', 'la-panel-bar');
				bar.style.width = `${Math.min(100, share * 2)}%`;
				const target = ideal[id];
				row.title =
					target === undefined
						? `${format(share, 1)} %`
						: `${format(share, 1)} % / ${format(target, 1)} %`;
				row.append(
					el('span', 'la-panel-finger-name', t(`layout_analysis.finger.${id}`)),
					el('span', 'la-panel-track'),
					el('span', 'la-panel-finger-value', `${format(share, 1)} %`)
				);
				row.children[1].append(bar);
				fingers.append(row);
			}
		}

		/** One analyser's score, or the headline statistics of one without a score. */
		function scoreText(analyser, score) {
			// The value alone, as in the Comparer: the units are the analysers' own words.
			if (analyser.better !== 'none') return format(score.value, analyser.digits);
			return analyser.headline
				.map(
					(part) =>
						`${t(`layout_analysis.analysers.part.${part}`)} ${format(score.parts[part], PART_DIGITS)} %`
				)
				.join(' · ');
		}

		/**
		 * Each analyser's official score now, its score with the user's finger
		 * model on the next tick (an analysis that started since drops it).
		 */
		function drawAnalysers(layout, prepared, settings, mine) {
			const head = el('tr');
			head.append(
				el('th'),
				el('th', '', t('layout_analysis.analysers.official')),
				el('th', '', t('layout_analysis.analysers.custom'))
			);
			const rows = SCORES.analysers().map((analyser) => {
				const tr = el('tr');
				const th = el('th', '', analyser.name);
				th.scope = 'row';
				th.append(
					' ',
					INFO.button(`analyser.${analyser.id}`),
					' ',
					el('small', 'la-muted', t(`layout_analysis.analysers.better.${analyser.better}`))
				);
				const official = SCORES.score(analyser.id, layout, prepared, {
					keyboard: state.keyboard,
					fingering: 'official'
				});
				const custom = el('td', '', PENDING_TEXT);
				tr.append(th, el('td', '', scoreText(analyser, official)), custom);
				return { analyser, tr, custom };
			});
			analysers.replaceChildren(head, ...rows.map((row) => row.tr));
			setTimeout(() => {
				if (mine !== state.generation) return;
				for (const row of rows)
					row.custom.textContent = scoreText(
						row.analyser,
						SCORES.score(row.analyser.id, layout, prepared, {
							keyboard: state.keyboard,
							profile: settings.profile,
							fingering: 'custom'
						})
					);
			}, 0);
		}

		function schedule() {
			clearTimeout(state.timer);
			state.timer = setTimeout(run, UPDATE_DEBOUNCE_MS);
		}

		corpusSelect.addEventListener('change', () => {
			state.corpus = corpusSelect.value;
			state.previous = null;
			persist();
			schedule();
		});
		keyboardSelect.addEventListener('change', () => {
			state.keyboard = keyboardSelect.value;
			state.previous = null;
			persist();
			schedule();
		});
		node.addEventListener('toggle', () => {
			persist();
			if (node.open) schedule();
		});
		document.addEventListener('i18n:applied', () => {
			fillControls();
			schedule();
		});
		// A new fingering profile changes every metric and the library's ranking.
		window.LAYOUT_ANALYSIS_FINGERING.onChange(() => {
			state.previous = null;
			schedule();
		});
		document.addEventListener(NGRAMS_EVENT, (event) => {
			E.prepareNgrams(event.detail);
			const entry = { id: MY_TYPING_ID, title: '', host: event.detail };
			const at = corpora.findIndex((c) => c.id === MY_TYPING_ID);
			if (at >= 0) corpora.splice(at, 1, entry);
			else corpora.unshift(entry);
			state.corpus = MY_TYPING_ID;
			state.previous = null;
			state.libraryKey = '';
			fillControls();
			schedule();
		});
		fillControls();

		return {
			node,
			update(doc) {
				state.doc = doc;
				schedule();
			},
			addSection(draw) {
				if (typeof draw !== 'function') throw new Error('layout_analysis: a section draws itself');
				sections.push(draw);
				schedule();
			}
		};
	}

	return { create, layoutFromEditorDoc, PANEL_METRICS };
})();
