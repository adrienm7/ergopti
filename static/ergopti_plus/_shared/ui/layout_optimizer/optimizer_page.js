// _shared/ui/layout_optimizer/optimizer_page.js

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Page
 * DESCRIPTION:
 * The « Optimiser » tab of Ergopti Studio, in four steps: pick a corpus and
 * a start layout (or a random arrangement of its keys); say what may move;
 * run with the Comparer's score settings and a budget; watch the best layout
 * found so far beside the start, its score and its metrics against the
 * start; stop at any time; open the result in « Éditer » or compare it in
 * « Comparer ». Everything runs in the page.
 *
 * FEATURES & RATIONALE:
 * 1. Responsive: the search runs in Web Workers (optimizer_worker.js), one
 *    share of the restarts each; where a worker cannot start (a page a host
 *    inlines), the same runner runs on the page in short slices.
 * 2. Deterministic: the seed and the budget in swaps give the same layout on
 *    every machine, whatever the number of workers (LAYOUT_OPTIMIZER.bestOf).
 * 3. Honest: the score shown at the end is the engine's score of the layout
 *    on the whole corpus, the one the Comparer shows.
 * 4. Mountable: LAYOUT_OPTIMIZER_PAGE.mount(root, {host?}) fills any element;
 *    the site's page mounts its <main>. Every visible string is a locale key.
 * 5. Pins: a click on a key of the start layout keeps it in place; the QWERTY
 *    board keeps chosen letters at their QWERTY place, or only their Ctrl/Cmd
 *    shortcut while the letter moves (presets for Z X C V and A S), whatever
 *    the start. Fixed keys, shortcuts and zones are sub-tabs of one step, so
 *    one board shows at a time.
 * 6. Corpora: the built-in ones, or the reader's own text, pasted or opened
 *    from a file (the Comparer's reader), counted on the device, with its
 *    size limits said in words.
 * 7. Zones: a click on the zone board keeps a character on the keys chosen.
 * 8. Remembered: the choices and the last text are kept in this browser's
 *    storage; a browser that refuses storage gets the same page, unsaved.
 * 9. Fails in words: a stage of a run that fails is logged and said in the
 *    reader's language with « Try again », and a page that declares no
 *    language writes its numbers in the documented fallback.
 * 10. One score: the search maximises the Comparer's global score with the
 *    Comparer's own settings (weights, ideal finger load, shortcut table,
 *    compact keyboards, fingering), read through score_settings.js at each
 *    run; the page sums them up and opens the Comparer to change them, so
 *    no second copy of a weight exists.
 * 11. Honest about the library: after a run, the library is scored on the
 *    same corpus and settings (in a worker, or the runner's slices) and the
 *    result says which existing layout comes close, by how much it is alike
 *    (LAYOUT_ANALYSIS.layoutSimilarity) and its score gap, with links to
 *    open it in « Comparer » or « Éditer ».
 * 12. Edit, then improve: the editor's « Optimize this layout » opens the
 *    page on the edited layout as its start (setStart in the app, the tab's
 *    hand-off on the site), said in the status line.
 * 14. Thumb keys: a switch lets the search place characters on the thumb
 *    keys (the core's thumbKeys, the chosen keyboard), enabled only on a
 *    keyboard that has them; its « i » says why it is off by default.
 * 15. A results shelf: the SHELF_SIZE best distinct layouts the search
 *    reported, each with its score, the keys it moves and its buttons to
 *    open it in « Éditer » or « Comparer ».
 * 13. Progress in sight: a live chart draws the best score over the
 *    run's time above the start's score, with the evaluations per second, the
 *    same said in words and as a table (the drawing is hidden from assistive
 *    technology, its text is not).
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const O = window.LAYOUT_OPTIMIZER;
	const FILES = window.LAYOUT_ANALYSIS_FILES;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	// The Comparer's score settings, the one source of every Studio score.
	const SCORE_SETTINGS = window.LAYOUT_ANALYSIS_SCORE_SETTINGS;
	const PREFIX = 'layout_optimizer.';
	// The constraint switches the page offers, in the core's order (DEFAULT_OPTIONS).
	const SWITCHES = [
		'moveDigits',
		'digitsOutsideNumberRow',
		'lettersOnNumberRow',
		'movePunctuation',
		'moveSymbols',
		'altgr',
		'deadKeyLayer'
	];
	// The switch that lets characters onto the chosen keyboard's thumb keys
	// (LAYOUT_OPTIMIZER thumbKeys: that keyboard's id, or null when off).
	const THUMB_SWITCH = 'thumbKeys';
	// The metrics compared with the start, as the Comparer's table shows them.
	const DELTA_METRICS = [
		'sfb',
		'sfs',
		'lsb',
		'scissors',
		'redirect',
		'roll_in',
		'roll_out',
		'alternation',
		'home_row',
		'distance',
		'finger_imbalance',
		'hand_imbalance',
		'pinky_load',
		'shortcut_left',
		'simplicity'
	];
	// The sub-tabs of the position constraints, in order.
	const PLACE_TABS = ['pins', 'shortcuts', 'zones'];
	// What the QWERTY board keeps: the letter itself, or only its Ctrl/Cmd shortcut.
	const SHORTCUT_MODES = ['letter', 'shortcut'];
	const DEFAULT_START = 'azerty';
	const DEFAULT_CORPUS = 'fr_swann';
	const DEFAULT_SECONDS = 30;
	const DEFAULT_ITERATIONS = 4000;
	const DEFAULT_SEED = 1;
	// The search accuracies: the share of each n-gram table the search scores on.
	const ACCURACIES = { full: 1, fast: 0.99 };
	// Workers at most, and the threads left to the page.
	const MAX_WORKERS = 8;
	// Size of one key unit of a drawn board, in pixels, at most and at least.
	const KEY_UNIT_MAX = 44;
	const KEY_UNIT_MIN = 20;
	// The library layouts most alike to the optimized one the result lists.
	const LIBRARY_CLOSEST = 5;
	// The best layout's metrics are measured again at most this often (ms).
	const METRICS_MS = 500;
	const HEIGHT_MESSAGE = 'ergopti-layout-optimizer:height';
	// The progress chart: its width when its box is not laid out yet and its
	// height (px, drawn at the box's width so the text keeps its size), its
	// margins for the axes, the room under the start's line for its label, the
	// points it keeps (older ones thinned), the rows of its table, and a new
	// point at least this often while the best holds (s).
	const CHART_WIDTH = 640;
	const CHART_HEIGHT = 240;
	const CHART_MARGIN = Object.freeze({ top: 16, right: 20, bottom: 34, left: 64 });
	const CHART_START_ROOM = 24;
	const CHART_MAX_POINTS = 240;
	const CHART_TABLE_ROWS = 12;
	const CHART_POINT_SECONDS = 1;
	const SVG_NS = 'http://www.w3.org/2000/svg';
	// The best distinct layouts of a run the results shelf keeps.
	const SHELF_SIZE = 5;
	// The corpus a pasted text or an opened file makes.
	const CUSTOM_ID = 'custom';
	// The app's keystats corpus (« My typing ») and the event its Studio window
	// dispatches with those n-grams (layout_editor_window/script.js).
	const MY_TYPING_ID = 'my_typing';
	const NGRAMS_EVENT = 'studio-ngrams';
	// A text shorter than this gives the search too few n-grams to measure; a
	// longer one would hold the page while it is counted and sent to the workers.
	const MIN_TEXT_CHARS = 200;
	const MAX_TEXT_CHARS = 5000000;
	// Files larger than this are refused before they are read (MB).
	const MAX_FILE_MB = 50;
	// The reader's choices and last text, kept in this browser for the next visit.
	const STORAGE_KEY = 'ergopti.layout_optimizer.v1';
	const TEXT_KEY = 'ergopti.layout_optimizer.text.v1';
	const STANDALONE_ROOT_ID = 'layout-optimizer';
	// The stages of a run, each with its own failure message (error.stage.<id>).
	const RUN_STAGES = ['start', 'corpus', 'analysis', 'search', 'result'];

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	// The page's markup; data-i18n attributes are filled by applyStrings(). Four
	// numbered steps (corpus and start, what may move, run, result); the
	// position constraints are sub-tabs, the search budget is folded.
	const MARKUP = `<header class="lo-header">
	<h1 data-i18n="layout_optimizer.title"></h1>
	<p class="lo-muted lo-lead" data-i18n="layout_optimizer.intro"></p>
</header>
<div class="lo-steps">
<section class="lo-card lo-step lo-step-setup" aria-labelledby="lo-setup-title">
	<h2 id="lo-setup-title" data-i18n="layout_optimizer.setup.title"></h2>
	<div class="lo-fields">
		<label class="lo-field"><span data-i18n="layout_optimizer.corpus.label"></span>
			<select id="lo-corpus"></select></label>
		<label class="lo-field"><span data-i18n="layout_optimizer.start.label"></span>
			<select id="lo-start"></select></label>
		<label class="lo-field"><span data-i18n="layout_optimizer.keyboard"></span>
			<select id="lo-keyboard"></select></label>
	</div>
	<div id="lo-custom" class="lo-field lo-custom" hidden>
		<textarea id="lo-text" rows="4" data-i18n-placeholder="layout_optimizer.corpus.paste_placeholder"></textarea>
		<label class="lo-file"><span data-i18n="layout_optimizer.corpus.file"></span>
			<input id="lo-file" type="file" accept=".txt,.md,.csv,.tsv,.html,.htm,.json,.tex,.docx,.odt,.pdf" /></label>
		<p id="lo-text-status" class="lo-muted" role="status" aria-live="polite"></p>
	</div>
	<fieldset class="lo-radios">
		<legend data-i18n="layout_optimizer.start.mode"></legend>
		<label><input type="radio" name="lo-start-mode" value="layout" checked />
			<span data-i18n="layout_optimizer.start.mode_layout"></span></label>
		<label><input type="radio" name="lo-start-mode" value="random" />
			<span data-i18n="layout_optimizer.start.mode_random"></span></label>
	</fieldset>
</section>
<section class="lo-card lo-step lo-step-move" aria-labelledby="lo-move-title">
	<h2 id="lo-move-title" data-i18n="layout_optimizer.constraints.title"></h2>
	<p class="lo-muted" data-i18n="layout_optimizer.constraints.fixed"></p>
	<div id="lo-switches" class="lo-switches"></div>
	<h3 id="lo-place-title" data-i18n="layout_optimizer.place.title"></h3>
	<div class="lo-tabs" role="tablist" aria-labelledby="lo-place-title">
		<button type="button" role="tab" id="lo-tab-pins" aria-controls="lo-panel-pins" data-i18n="layout_optimizer.pins.title"></button>
		<button type="button" role="tab" id="lo-tab-shortcuts" aria-controls="lo-panel-shortcuts" data-i18n="layout_optimizer.shortcuts.tab"></button>
		<button type="button" role="tab" id="lo-tab-zones" aria-controls="lo-panel-zones" data-i18n="layout_optimizer.zones.title"></button>
	</div>
	<div id="lo-panel-pins" class="lo-tab-panel" role="tabpanel" aria-labelledby="lo-tab-pins">
		<p class="lo-muted" data-i18n="layout_optimizer.pins.help"></p>
		<div class="lo-board-box"><div id="lo-pin-board" class="lo-board"></div></div>
	</div>
	<div id="lo-panel-shortcuts" class="lo-tab-panel" role="tabpanel" aria-labelledby="lo-tab-shortcuts" hidden>
		<p class="lo-muted" data-i18n="layout_optimizer.qwerty.help"></p>
		<fieldset class="lo-radios">
			<legend data-i18n="layout_optimizer.qwerty.mode"></legend>
			<label><input type="radio" name="lo-shortcut-mode" value="letter" checked />
				<span data-i18n="layout_optimizer.qwerty.mode_letter"></span></label>
			<label><input type="radio" name="lo-shortcut-mode" value="shortcut" />
				<span data-i18n="layout_optimizer.qwerty.mode_shortcut"></span></label>
		</fieldset>
		<div class="lo-buttons" id="lo-qwerty-presets"></div>
		<div class="lo-board-box"><div id="lo-qwerty-board" class="lo-board"></div></div>
		<p class="lo-muted lo-note" data-i18n="layout_optimizer.qwerty.scored"></p>
	</div>
	<div id="lo-panel-zones" class="lo-tab-panel" role="tabpanel" aria-labelledby="lo-tab-zones" hidden>
		<p class="lo-muted" data-i18n="layout_optimizer.zones.help"></p>
		<div class="lo-buttons">
			<label class="lo-field lo-inline"><span data-i18n="layout_optimizer.zones.char"></span>
				<select id="lo-zone-char"></select></label>
			<button type="button" id="lo-zone-clear" data-i18n="layout_optimizer.zones.clear"></button>
			<button type="button" id="lo-zones-clear" data-i18n="layout_optimizer.zones.clear_all"></button>
		</div>
		<div class="lo-board-box"><div id="lo-zone-board" class="lo-board"></div></div>
		<p id="lo-zones-summary" class="lo-muted" role="status"></p>
	</div>
</section>
<section class="lo-card lo-step lo-step-run" aria-labelledby="lo-run-title">
	<h2 id="lo-run-title" data-i18n="layout_optimizer.run_title"></h2>
	<div class="lo-settings">
		<h3 data-i18n="layout_optimizer.settings.title"></h3>
		<p class="lo-muted" data-i18n="layout_optimizer.settings.help"></p>
		<ul id="lo-settings-list" class="lo-settings-list"></ul>
		<button type="button" id="lo-settings-edit" data-i18n="layout_optimizer.settings.edit"></button>
	</div>
	<details class="lo-advanced">
		<summary data-i18n="layout_optimizer.budget.advanced"></summary>
		<div class="lo-row">
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.seconds"></span>
				<input id="lo-seconds" type="number" min="1" max="3600" step="1" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.iterations"></span>
				<input id="lo-iterations" type="number" min="10" max="1000000" step="10" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.restarts"></span>
				<input id="lo-restarts" type="number" min="1" max="64" step="1" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.seed"></span>
				<input id="lo-seed" type="number" min="0" max="4294967295" step="1" /></label>
			<label class="lo-field"><span data-i18n="layout_optimizer.budget.accuracy"></span>
				<select id="lo-accuracy" data-i18n-option-prefix="layout_optimizer.accuracy">
					<option value="full"></option>
					<option value="fast"></option>
				</select></label>
		</div>
		<p class="lo-muted" data-i18n="layout_optimizer.budget.help"></p>
	</details>
	<div class="lo-buttons lo-run-buttons">
		<button type="button" id="lo-run" class="lo-primary" data-i18n="layout_optimizer.run"></button>
		<button type="button" id="lo-stop" data-i18n="layout_optimizer.stop" disabled></button>
	</div>
	<progress id="lo-progress" max="1" value="0" aria-labelledby="lo-status"></progress>
	<p id="lo-status" class="lo-muted" role="status" aria-live="polite"></p>
	<button type="button" id="lo-retry" data-i18n="layout_optimizer.retry" hidden></button>
</section>
<section id="lo-result" class="lo-card lo-step lo-step-result" aria-labelledby="lo-result-title" hidden>
	<h2 id="lo-result-title" data-i18n="layout_optimizer.result.title"></h2>
	<div id="lo-score" class="lo-tiles"></div>
	<figure id="lo-chart" class="lo-chart" aria-labelledby="lo-chart-title" hidden>
		<figcaption id="lo-chart-title" data-i18n="layout_optimizer.chart.title"></figcaption>
		<div class="lo-chart-box">
			<svg id="lo-chart-svg" class="lo-chart-svg" aria-hidden="true" focusable="false"></svg>
			<p id="lo-chart-tip" class="lo-chart-tip" aria-hidden="true" hidden></p>
		</div>
		<p id="lo-chart-summary" class="lo-chart-summary"></p>
		<details class="lo-chart-details">
			<summary data-i18n="layout_optimizer.chart.table"></summary>
			<div class="lo-table-box"><table class="lo-table lo-chart-table">
				<thead><tr>
					<th scope="col" data-i18n="layout_optimizer.chart.time"></th>
					<th scope="col" data-i18n="layout_optimizer.chart.best"></th>
					<th scope="col" data-i18n="layout_optimizer.chart.gain"></th>
				</tr></thead>
				<tbody id="lo-chart-rows"></tbody>
			</table></div>
		</details>
	</figure>
	<div class="lo-boards">
		<figure class="lo-figure">
			<figcaption data-i18n="layout_optimizer.start.label"></figcaption>
			<div class="lo-board-box"><div id="lo-start-board" class="lo-board"></div></div>
		</figure>
		<figure class="lo-figure">
			<figcaption data-i18n="layout_optimizer.result.best_board"></figcaption>
			<div class="lo-board-box"><div id="lo-result-board" class="lo-board"></div></div>
		</figure>
	</div>
	<p id="lo-changed" class="lo-muted"></p>
	<details id="lo-board-table" class="lo-chart-details lo-board-table">
		<summary id="lo-board-table-title" data-i18n="layout_optimizer.result.table"></summary>
		<div class="lo-table-box lo-board-table-box" tabindex="0" role="region"
			aria-labelledby="lo-board-table-title"><table class="lo-table">
			<thead><tr>
				<th scope="col" data-i18n="layout_editor.board.table_key"></th>
				<th scope="col" data-i18n="layout_optimizer.start.label"></th>
				<th scope="col" data-i18n="layout_optimizer.result.best_board"></th>
				<th scope="col" data-i18n="layout_optimizer.result.table_changed"></th>
			</tr></thead>
			<tbody id="lo-board-rows"></tbody>
		</table></div>
	</details>
	<h3 data-i18n="layout_optimizer.result.metrics"></h3>
	<div class="lo-metric-tables">
	<div class="lo-table-box"><table class="lo-table">
		<thead><tr>
			<th data-i18n="layout_optimizer.result.metric"></th>
			<th data-i18n="layout_optimizer.result.start"></th>
			<th data-i18n="layout_optimizer.result.best"></th>
			<th data-i18n="layout_optimizer.result.change"></th>
		</tr></thead>
		<tbody id="lo-metrics"></tbody>
	</table></div>
	<div class="lo-table-box"><table class="lo-table">
		<thead><tr>
			<th data-i18n="layout_optimizer.result.metric"></th>
			<th data-i18n="layout_optimizer.result.start"></th>
			<th data-i18n="layout_optimizer.result.best"></th>
			<th data-i18n="layout_optimizer.result.change"></th>
		</tr></thead>
		<tbody id="lo-metrics-more"></tbody>
	</table></div>
	</div>
	<div class="lo-buttons">
		<button type="button" id="lo-open-editor" class="lo-primary" data-i18n="layout_optimizer.result.open_editor" disabled></button>
		<button type="button" id="lo-open-comparer" data-i18n="layout_optimizer.result.open_comparer" disabled></button>
	</div>
	<section id="lo-shelf" class="lo-shelf" aria-labelledby="lo-shelf-title" hidden>
		<h3 id="lo-shelf-title" data-i18n="layout_optimizer.shelf.title"></h3>
		<p class="lo-muted" data-i18n="layout_optimizer.shelf.help"></p>
		<ol id="lo-shelf-list" class="lo-shelf-list"></ol>
	</section>
	<section id="lo-library" class="lo-library" aria-labelledby="lo-library-title" hidden>
		<h3 id="lo-library-title" data-i18n="layout_optimizer.library.title"></h3>
		<p class="lo-muted" data-i18n="layout_optimizer.library.help"></p>
		<progress id="lo-library-progress" max="1" value="0" aria-labelledby="lo-library-status"></progress>
		<p id="lo-library-status" class="lo-muted" role="status" aria-live="polite"></p>
		<div id="lo-library-body"></div>
	</section>
</section>
</div>`;

	/**
	 * The language the page writes its numbers in: info_popover.js locale(),
	 * the one language of every Studio page's numbers.
	 * @returns {string} A BCP 47 language tag.
	 */
	const numberLocale = () => window.LAYOUT_ANALYSIS_INFO.locale();

	/** A number written with `digits` decimals in the page's language (info_popover.js format()). */
	const formatNumber = (value, digits) => window.LAYOUT_ANALYSIS_INFO.format(value, digits);

	// The glyph beside each verdict and gap, so none is told by its colour alone.
	const VERDICT_MARKS = { small_gap: '≈', optimized_ahead: '▲', existing_better: '★' };
	const GAP_MARKS = { behind: '▼', ahead: '▲', same: '=' };

	/**
	 * The card that compares the optimized layout with the library: the
	 * verdict in words, the best-scoring existing layout with a gauge of how
	 * alike it is, and the most alike layouts as bars, each with its score
	 * gap and its buttons to open it in « Comparer » or « Éditer ». Every
	 * visual repeats its number in text (the bars and the gauge are hidden
	 * from assistive technology, their text is not).
	 * @param {Document} doc - The document that makes the nodes.
	 * @param {object} summary - LAYOUT_OPTIMIZER_RUNNER.librarySummary().
	 * @param {{t: function(string, object=): string, number: function(number,
	 *   number): string, onOpen: function(object, string): void}} deps - The
	 *   page's translator and number writer, and what opens a layout
	 *   (`comparer` or `editor`).
	 * @returns {HTMLElement} The card's content.
	 */
	function libraryCard(doc, summary, deps) {
		const { t, number, onOpen } = deps;
		const el = (tag, className, text) => {
			const node = doc.createElement(tag);
			if (className) node.className = className;
			if (text !== undefined) node.textContent = text;
			return node;
		};
		const percent = (value) => t('layout_optimizer.library.percent', { value: number(value, 1) });
		const points = (value) => number(Math.abs(value), 2);
		const best = summary.best;
		const box = el('div', 'lo-library-content');

		// The verdict, the best existing layout's gap read against the small gap.
		const banner = el('div', `lo-library-verdict lo-library-${summary.verdict}`);
		const mark = el('span', 'lo-library-mark', VERDICT_MARKS[summary.verdict]);
		mark.setAttribute('aria-hidden', 'true');
		banner.append(
			mark,
			el(
				'p',
				'',
				t(`layout_optimizer.library.verdict.${summary.verdict}`, {
					name: best.name,
					gap: points(best.gap),
					threshold: number(summary.smallGap, 2)
				})
			)
		);
		box.append(banner);

		const gapChip = (entry) => {
			const side = entry.gap > 0 ? 'behind' : entry.gap < 0 ? 'ahead' : 'same';
			const chip = el('span', `lo-gap lo-gap-${side}`);
			const glyph = el('span', 'lo-gap-mark', GAP_MARKS[side]);
			glyph.setAttribute('aria-hidden', 'true');
			chip.append(
				glyph,
				el('span', '', t(`layout_optimizer.library.gap_${side}`, { gap: points(entry.gap) }))
			);
			return chip;
		};
		const buttons = (entry) => {
			const row = el('div', 'lo-library-actions');
			for (const where of ['comparer', 'editor']) {
				const button = el('button', 'lo-link', t(`layout_optimizer.library.open_${where}`));
				button.type = 'button';
				button.dataset.open = where;
				button.dataset.layout = entry.id;
				// The visible word first (WCAG 2.5.3), then the layout it opens.
				button.setAttribute(
					'aria-label',
					t(`layout_optimizer.library.open_${where}_label`, { name: entry.name })
				);
				button.addEventListener('click', () => onOpen(entry, where));
				row.append(button);
			}
			return row;
		};
		const facts = (entry) => {
			const list = el('ul', 'lo-library-facts');
			list.append(
				el('li', '', t('layout_optimizer.library.score', { score: number(entry.score, 2) })),
				el(
					'li',
					'',
					t('layout_optimizer.library.same_finger', {
						value: percent(entry.similarity.weighted.sameFingerRow)
					})
				),
				el(
					'li',
					'',
					t('layout_optimizer.library.distinct', {
						value: percent(entry.similarity.unweighted.sameKey)
					})
				)
			);
			if (entry.incomplete)
				list.append(el('li', 'lo-bad', t('layout_optimizer.library.incomplete')));
			return list;
		};

		// The best-scoring existing layout: a gauge of how alike it is.
		const bestBox = el('div', 'lo-library-best');
		const alike = best.similarity.weighted.sameKey;
		const gauge = el('div', 'lo-gauge');
		gauge.style.setProperty('--lo-gauge', String(Math.max(0, Math.min(100, alike))));
		gauge.setAttribute('aria-hidden', 'true');
		gauge.append(el('span', 'lo-gauge-value', percent(alike)));
		const bestText = el('div', 'lo-library-best-text');
		bestText.append(
			el('p', 'lo-library-kicker', t('layout_optimizer.library.best_title')),
			el('h4', 'lo-library-name', best.name),
			el('p', 'lo-library-alike', t('layout_optimizer.library.alike', { value: percent(alike) })),
			gapChip(best),
			facts(best),
			buttons(best)
		);
		bestBox.append(gauge, bestText);
		box.append(bestBox);

		// The most alike layouts: a bar each, same key over same finger and row.
		box.append(el('h4', 'lo-library-subtitle', t('layout_optimizer.library.closest_title')));
		const list = el('ol', 'lo-library-list');
		for (const entry of summary.closest) {
			const item = el(
				'li',
				entry.id === best.id ? 'lo-library-item lo-library-is-best' : 'lo-library-item'
			);
			item.dataset.layout = entry.id;
			const head = el('div', 'lo-library-item-head');
			head.append(el('span', 'lo-library-name', entry.name), gapChip(entry));
			const bars = el('div', 'lo-bars');
			bars.setAttribute('aria-hidden', 'true');
			const finger = el('span', 'lo-bar lo-bar-finger');
			finger.style.width = `${Math.max(0, Math.min(100, entry.similarity.weighted.sameFingerRow))}%`;
			const key = el('span', 'lo-bar lo-bar-key');
			key.style.width = `${Math.max(0, Math.min(100, entry.similarity.weighted.sameKey))}%`;
			bars.append(finger, key);
			item.append(
				head,
				bars,
				el(
					'p',
					'lo-library-alike',
					t('layout_optimizer.library.alike', { value: percent(entry.similarity.weighted.sameKey) })
				),
				facts(entry),
				buttons(entry)
			);
			list.append(item);
		}
		box.append(list);
		// The bars' key, in words beside its two swatches.
		const legend = el('p', 'lo-library-legend lo-muted');
		const swatch = (className, text) => {
			const part = el('span', 'lo-legend-item');
			const chip = el('span', `lo-swatch ${className}`);
			chip.setAttribute('aria-hidden', 'true');
			part.append(chip, el('span', '', text));
			return part;
		};
		legend.append(
			swatch('lo-bar-key', t('layout_optimizer.library.legend_key')),
			swatch('lo-bar-finger', t('layout_optimizer.library.legend_finger'))
		);
		box.append(legend);
		return box;
	}

	let mounted = null;
	// The app's last keystats tables, kept when they arrive before the mount
	// (the Studio window mounts this tab the first time it opens).
	let lastNgrams = null;
	let onNgrams = null;
	document.addEventListener(NGRAMS_EVENT, (event) => {
		lastNgrams = event.detail;
		if (onNgrams) onNgrams(event.detail);
	});

	/**
	 * Fills an element with the optimizer.
	 * @param {HTMLElement} root - The element the page fills.
	 * @param {{reportHeight?: boolean, host?: {openEditor?: function(object): void,
	 *   openComparer?: function(object): void, openScoreSettings?: function(): void}}}
	 *   [options] - reportHeight: post the page height to a framing parent (the
	 *   site); host: the app's Studio window, which opens the result, and the
	 *   score settings, in its own « Éditer » and « Comparer » tabs instead of
	 *   the site's.
	 * @returns {{setCorpus: function(object): void, setStart: function(string): void}}
	 *   The mounted page.
	 * @throws {Error} On a missing root or a second mount.
	 */
	function mount(root, options) {
		if (!root || typeof root.append !== 'function')
			throw new Error('layout_optimizer: mount needs an element');
		if (mounted) throw new Error('layout_optimizer: the page is already mounted');
		const opts = options || {};
		const HOST = opts.host || {};
		root.classList.add('layout-optimizer');
		// A constant of this script, no user data: safe as markup.
		root.innerHTML = MARKUP;
		const $ = (id) => root.querySelector(`#${id}`);

		// ============================
		// ======= 1/ Helpers =========
		// ============================

		/** Translates a locale key (info_popover.js t(): numbers as every number shown). */
		const t = (key, values) => window.LAYOUT_ANALYSIS_INFO.t(key, values);

		function el(tag, className, text) {
			const node = document.createElement(tag);
			if (className) node.className = className;
			if (text !== undefined) node.textContent = text;
			return node;
		}

		const number = formatNumber;
		// A number and its unit, tied by a no-break space (info_popover.js).
		const withUnit = (text, unit) => window.LAYOUT_ANALYSIS_INFO.withUnit(text, unit);
		const signed = (value, digits) => (value > 0 ? '+' : '') + number(value, digits);
		const metricDigits = E.metricDigits;

		function applyStrings() {
			for (const node of root.querySelectorAll('[data-i18n]'))
				node.textContent = t(node.dataset.i18n);
			for (const node of root.querySelectorAll('[data-i18n-placeholder]'))
				node.placeholder = t(node.dataset.i18nPlaceholder);
			for (const select of root.querySelectorAll('select[data-i18n-option-prefix]'))
				for (const option of select.options)
					option.textContent = t(`${select.dataset.i18nOptionPrefix}.${option.value}`);
		}

		/** The message of a refusal in the reader's language. */
		function errorText(code, message, values) {
			const key = `${PREFIX}error.${code}`;
			const strings = window._i18n_strings || {};
			return typeof strings[key] === 'string'
				? t(key, values)
				: t(`${PREFIX}error.failed`, { message });
		}

		// ============================
		// ======= 2/ State ===========
		// ============================

		const library = E.libraryLayouts();
		const qwerty = library.find((layout) => layout.id === 'qwerty');
		const state = {
			editorLayouts: [],
			pinnedCodes: new Set(),
			// Letters of the QWERTY board, and what of them stays (SHORTCUT_MODES).
			qwertyPins: new Set(),
			shortcutMode: 'letter',
			placeTab: PLACE_TABS[0],
			// Character → the keys it may sit on (LAYOUT_OPTIMIZER zones).
			zones: new Map(),
			tables: new Map(),
			// The pasted or opened text's tables: {hash, chars, tables}.
			custom: null,
			// A run reading its choices, corpus and start, before its runners start.
			loading: false,
			// The saved start layout, until the reader picks another.
			savedStart: null,
			// The editor layout « Optimize this layout » handed over, said once it is chosen.
			handedStart: null,
			handedName: null,
			// The host's corpora: {id, title, tables}, listed first.
			hostCorpora: [],
			running: null,
			startResult: null,
			best: null,
			bestLayout: null,
			lastMetrics: 0,
			// The run's progress chart: {start, points: [{seconds, best, evaluations}]}.
			chart: null,
			// The best distinct layouts reported, best first: [{layout, score, key}].
			shelf: [],
			// The library scan after a run (scanLibrary): {runner}, or null.
			library: null
		};

		function startLayouts() {
			return state.editorLayouts.map(E.layoutFromRows).concat(library);
		}

		function startLayout() {
			const id = $('lo-start').value;
			return startLayouts().find((layout) => layout.id === id) || null;
		}

		// ============================
		// ======= 3/ Controls ========
		// ============================

		/**
		 * The corpus picker the Comparer and the editor's panel share
		 * (LAYOUT_ANALYSIS_FILES.fillCorpusPicker): the host's corpora (« My
		 * typing ») and the user's own text first, then the texts by language.
		 */
		function fillCorpora() {
			const select = $('lo-corpus');
			const kept = select.value;
			const mine = state.hostCorpora
				.map((corpus) => ({ id: corpus.id, label: corpus.title }))
				.concat([{ id: CUSTOM_ID, label: t(`${PREFIX}corpus.custom`) }]);
			FILES.fillCorpusPicker(select, {
				mine,
				builtins: DATA.corpora,
				value: kept,
				t,
				locale: numberLocale()
			});
			const values = Array.from(select.options, (option) => option.value);
			if (!values.includes(kept)) select.value = DEFAULT_CORPUS;
			syncCorpus();
		}

		/** Shows the text box under « Your own text » only. */
		function syncCorpus() {
			$('lo-custom').hidden = $('lo-corpus').value !== CUSTOM_ID;
		}

		/**
		 * Reduces the user's text to tables, once per distinct text, and says
		 * whether the optimizer can use it.
		 * @param {string} text - The pasted or opened text.
		 */
		function useText(text) {
			const trimmed = text.trim();
			const chars = Array.from(trimmed).length;
			const status = $('lo-text-status');
			let problem = null;
			if (chars > 0 && chars < MIN_TEXT_CHARS)
				problem = t(`${PREFIX}corpus.text_short`, {
					chars: number(chars, 0),
					min: number(MIN_TEXT_CHARS, 0)
				});
			else if (chars > MAX_TEXT_CHARS)
				problem = t(`${PREFIX}corpus.text_long`, {
					chars: number(chars, 0),
					max: number(MAX_TEXT_CHARS, 0)
				});
			if (chars === 0 || problem) {
				if (restored && chars === 0) writeStored(TEXT_KEY, null);
				state.custom = null;
				status.textContent = problem || '';
				status.classList.toggle('lo-error', Boolean(problem));
				return;
			}
			const hash = E.hashText(trimmed);
			if (!state.custom || state.custom.hash !== hash) {
				state.custom = { hash, chars, tables: E.ngramsFromText(trimmed) };
				// Too long for the storage quota: the text is simply not kept.
				if (restored) writeStored(TEXT_KEY, { text: trimmed });
			}
			status.textContent = t(`${PREFIX}corpus.text_ready`, { chars: number(chars, 0) });
			status.classList.remove('lo-error');
		}

		/** Reads an opened file into the text box, or says why it cannot. */
		async function useFile(file) {
			const status = $('lo-text-status');
			const fail = (text) => {
				state.custom = null;
				status.textContent = text;
				status.classList.add('lo-error');
			};
			const megabytes = file.size / (1024 * 1024);
			if (megabytes > MAX_FILE_MB) {
				fail(
					t(`${PREFIX}corpus.file_large`, {
						size: number(megabytes, 1),
						max: number(MAX_FILE_MB, 0)
					})
				);
				return;
			}
			let text;
			try {
				text = await FILES.readText(file);
			} catch (failure) {
				// The Comparer's words for each refusal: an unknown type, a PDF that is
				// locked or holds no text (a scan), or a file that could not be read.
				const known = {
					file_unsupported: 'layout_analysis.corpus.file_unsupported',
					pdf_encrypted: 'layout_analysis.corpus.pdf_encrypted',
					pdf_no_text: 'layout_analysis.corpus.pdf_no_text'
				};
				fail(t(known[failure.code] || 'layout_analysis.corpus.file_unreadable'));
				return;
			}
			// A text over the limit is not put in the box, where it would hold the page.
			if (text.length <= MAX_TEXT_CHARS * 2) $('lo-text').value = text;
			useText(text);
		}

		function fillStarts() {
			const select = $('lo-start');
			// A saved layout of « Éditer » is chosen once its tab is listed.
			const kept = state.savedStart || select.value || DEFAULT_START;
			const group = (label, layouts) => {
				const node = el('optgroup');
				node.label = label;
				for (const layout of layouts) {
					const option = el('option', '', layout.name);
					option.value = layout.id;
					node.append(option);
				}
				return node;
			};
			const sorted = library
				.slice()
				.sort((a, b) => a.name.localeCompare(b.name, undefined, { sensitivity: 'base' }));
			const groups = [];
			if (state.editorLayouts.length)
				groups.push(
					group(t(`${PREFIX}start.editor_group`), state.editorLayouts.map(E.layoutFromRows))
				);
			groups.push(group(t(`${PREFIX}start.library_group`), sorted));
			select.replaceChildren(...groups);
			select.value = startLayouts().some((layout) => layout.id === kept) ? kept : DEFAULT_START;
			// The layout the editor handed over, once listed: chosen, and said in words.
			if (state.handedStart && select.value === state.handedStart) {
				state.handedStart = null;
				state.handedName = startLayout().name;
				sayHanded();
				select.focus({ preventScroll: true });
				select.scrollIntoView({ block: 'nearest' });
			}
		}

		/** Says where the search starts; the locale's arrival says it again. */
		function sayHanded() {
			setStatus(t(`${PREFIX}start.handed`, { name: state.handedName }));
			$('lo-status').dataset.handed = 'true';
		}

		/**
		 * Starts from a layout of « Éditer » (its « Optimize this layout »): it is
		 * chosen as soon as the editor's list holds it, the fixed keys of the
		 * previous start cleared.
		 * @param {string} id - The editor_… id the editor publishes it under.
		 * @throws {Error} On an id that is not an editor layout's.
		 */
		function setStart(id) {
			if (typeof id !== 'string' || !id.startsWith('editor_'))
				throw new Error(`layout_optimizer: ${id} is not a layout of the editor`);
			if ($('lo-start').value !== id) state.pinnedCodes.clear();
			state.savedStart = id;
			state.handedStart = id;
			fillStarts();
			drawPinBoards();
		}

		function fillKeyboards() {
			const select = $('lo-keyboard');
			const kept = select.value || 'iso';
			select.replaceChildren(
				...Object.keys(DATA.model.keyboards).map((id) => {
					const option = el('option', '', t(`layout_analysis.keyboard.${id}`));
					option.value = id;
					return option;
				})
			);
			select.value = kept;
		}

		function fillSwitches() {
			const box = $('lo-switches');
			const checked = {};
			for (const input of box.querySelectorAll('input')) checked[input.value] = input.checked;
			box.replaceChildren(
				...SWITCHES.map((id) => {
					const input = el('input');
					input.type = 'checkbox';
					input.value = id;
					input.id = `lo-switch-${id}`;
					input.checked = id in checked ? checked[id] : O.DEFAULT_OPTIONS[id];
					const label = el('label', 'lo-switch');
					label.append(input, el('span', '', t(`${PREFIX}option.${id}.label`)));
					const help = el('p', 'lo-muted lo-help', t(`${PREFIX}option.${id}.help`));
					const item = el('div', 'lo-switch-item');
					item.append(label, help);
					return item;
				}),
				thumbSwitch(THUMB_SWITCH in checked ? checked[THUMB_SWITCH] : false)
			);
			syncSwitches();
		}

		/**
		 * The thumb keys' switch: off by default (O.DEFAULT_OPTIONS.thumbKeys is
		 * null), its « i » saying why, its help line saying which keyboards have
		 * thumb keys.
		 * @param {boolean} checked - The reader's choice.
		 */
		function thumbSwitch(checked) {
			const input = el('input');
			input.type = 'checkbox';
			input.value = THUMB_SWITCH;
			input.id = `lo-switch-${THUMB_SWITCH}`;
			input.checked = checked;
			const name = el('span', '', t(`${PREFIX}option.thumbKeys.label`));
			const label = el('label', 'lo-switch');
			label.htmlFor = input.id;
			label.append(input, name);
			const why = window.LAYOUT_ANALYSIS_INFO.note(
				t(`${PREFIX}option.thumbKeys.why_label`),
				t(`${PREFIX}option.thumbKeys.why`)
			);
			why.id = 'lo-thumb-why';
			const head = el('div', 'lo-switch-head');
			head.append(label, why);
			const help = el('p', 'lo-muted lo-help');
			help.id = 'lo-thumb-help';
			input.setAttribute('aria-describedby', help.id);
			const item = el('div', 'lo-switch-item lo-switch-thumb');
			item.append(head, help);
			return item;
		}

		/** The keyboards of the model that have thumb keys, in the model's order. */
		function thumbKeyboards() {
			const codes = E.thumbKeys();
			return Object.keys(DATA.model.keyboards).filter((id) => {
				const board = E.keyboard(id);
				return codes.some((code) => board.index.has(code));
			});
		}

		/** A switch that only means something with another one follows it. */
		function syncSwitches() {
			const digits = $('lo-switch-moveDigits');
			const outside = $('lo-switch-digitsOutsideNumberRow');
			outside.disabled = !digits.checked;
			if (!digits.checked) outside.checked = false;
			// The thumb keys only on a keyboard that has them; the choice is kept for one that does.
			const thumb = $(`lo-switch-${THUMB_SWITCH}`);
			const boards = thumbKeyboards();
			const has = boards.includes($('lo-keyboard').value);
			thumb.disabled = !has;
			thumb.closest('.lo-switch-item').classList.toggle('lo-switch-off', !has);
			$('lo-thumb-help').textContent = has
				? t(`${PREFIX}option.thumbKeys.help`)
				: t(`${PREFIX}option.thumbKeys.absent`, {
						keyboards: boards.map((id) => t(`layout_analysis.keyboard.${id}`)).join(', ')
					});
		}

		function fillPresets() {
			const box = $('lo-qwerty-presets');
			const buttons = Object.entries(O.QWERTY_PIN_PRESETS).map(([id, letters]) => {
				const button = el('button', '', t(`${PREFIX}qwerty.preset.${id}`));
				button.type = 'button';
				button.addEventListener('click', () => {
					for (const letter of letters) state.qwertyPins.add(letter);
					drawPinBoards();
				});
				return button;
			});
			const clear = el('button', '', t(`${PREFIX}qwerty.clear`));
			clear.type = 'button';
			clear.addEventListener('click', () => {
				state.qwertyPins.clear();
				drawPinBoards();
			});
			box.replaceChildren(...buttons, clear);
		}

		/**
		 * Shows one sub-tab of the position constraints (fixed keys, Ctrl
		 * shortcuts, zones); its board is drawn again at the panel's width.
		 * @param {string} id - One of PLACE_TABS.
		 * @param {boolean} [focus] - Moves the focus to the tab (arrow keys).
		 */
		function showPlaceTab(id, focus) {
			if (!PLACE_TABS.includes(id)) throw new Error(`layout_optimizer: unknown tab ${id}`);
			state.placeTab = id;
			for (const tab of PLACE_TABS) {
				const button = $(`lo-tab-${tab}`);
				const selected = tab === id;
				button.setAttribute('aria-selected', String(selected));
				// One tab stop for the list; the arrow keys move between tabs.
				button.tabIndex = selected ? 0 : -1;
				$(`lo-panel-${tab}`).hidden = !selected;
			}
			if (focus) $(`lo-tab-${id}`).focus();
			drawPinBoards();
		}

		/** The score settings the next run uses, summed up beside « Optimize ». */
		function drawSettings() {
			const keyboard = $('lo-keyboard').value;
			if (!keyboard) return;
			const custom = SCORE_SETTINGS.customised(keyboard);
			const rows = [
				['layout_analysis.weights.title', custom.weights > 0],
				['layout_analysis.ideal.title', custom.idealLoad],
				['layout_analysis.shortcuts.title', custom.shortcuts],
				['layout_analysis.forms.title', custom.formWeights],
				['layout_analysis.fingering.title', custom.fingering]
			];
			$('lo-settings-list').replaceChildren(
				...rows.map(([key, changed]) => {
					const item = el(
						'li',
						changed ? 'lo-custom-setting' : '',
						t(`${PREFIX}settings.${changed ? 'custom' : 'default'}`, { label: t(key) })
					);
					return item;
				})
			);
		}

		// ============================
		// ======= 4/ Boards ==========
		// ============================

		/** The legend of a key's base level: a dead key shows its bare accent. */
		function legend(layout, code) {
			const row = layout.rows[code];
			if (!row) return '';
			const cell = row[0];
			if (cell && typeof cell === 'object')
				return KEY_LEGEND.deadKeyText(((layout.dead || {})[cell.dead] || {})[' '] || '') || '★';
			if (code === 'Space') return '␣';
			return typeof cell === 'string' ? cell : '';
		}

		/**
		 * Where each drawn key is, in words: its row from the top and its rank
		 * from the left in that row (the Comparer's heatmap says it the same way).
		 * @returns {Map<string, string>} code → « row 2, key 5 ».
		 */
		function keyPlaces(board, modifiers) {
			const keys = board.codes
				.map((code, k) => ({ code, x: board.x[k], y: board.y[k] }))
				.filter((key) => !modifiers.has(key.code));
			const rows = Array.from(new Set(keys.map((key) => key.y))).sort((a, b) => a - b);
			const out = new Map();
			rows.forEach((y, r) =>
				keys
					.filter((key) => key.y === y)
					.sort((a, b) => a.x - b.x)
					.forEach((key, c) =>
						out.set(key.code, t('layout_analysis.heat.position', { row: r + 1, column: c + 1 }))
					)
			);
			return out;
		}

		/**
		 * Draws a layout's base level on the chosen keyboard.
		 * @param {HTMLElement} box - The board element.
		 * @param {object} layout - Library shape.
		 * @param {{marked?: function(string): boolean, onKey?: function(string): void,
		 *   changed?: function(string): boolean, label?: function(string): string}} [how]
		 */
		function drawBoard(box, layout, how) {
			const opts = how || {};
			box.replaceChildren();
			const board = E.keyboard($('lo-keyboard').value);
			const modifiers = new Set(Object.values(DATA.model.modifier_keys));
			const minX = Math.min(...board.x) - 0.5;
			const maxX = Math.max(...board.x) + 0.5;
			const maxY = Math.max(...board.y);
			const width = box.parentElement.clientWidth || KEY_UNIT_MAX * (maxX - minX);
			const unit = Math.max(
				KEY_UNIT_MIN,
				Math.min(KEY_UNIT_MAX, Math.floor(width / (maxX - minX)))
			);
			box.style.width = `${(maxX - minX) * unit}px`;
			box.style.height = `${maxY * unit}px`;
			box.style.fontSize = `${Math.round(unit * 0.38)}px`;
			const where = keyPlaces(board, modifiers);
			board.codes.forEach((code, k) => {
				if (modifiers.has(code)) return;
				const text = opts.label ? opts.label(code) : legend(layout, code);
				const key = el(opts.onKey ? 'button' : 'span', 'lo-key', text);
				key.dataset.code = code;
				const row = layout.rows[code];
				if (row && row[0] && typeof row[0] === 'object')
					key.classList.add(KEY_LEGEND.DEAD_KEY_CLASS);
				const wide = code === 'Space' ? 6 : 1;
				key.style.left = `${(board.x[k] - wide / 2 - minX) * unit}px`;
				key.style.top = `${(board.y[k] - 1) * unit}px`;
				key.style.width = `${wide * unit - 3}px`;
				key.style.height = `${unit - 3}px`;
				if (opts.marked && opts.marked(code)) key.classList.add('lo-marked');
				if (opts.changed && opts.changed(code)) key.classList.add('lo-changed');
				if (opts.onKey) {
					key.type = 'button';
					key.setAttribute('aria-pressed', opts.marked && opts.marked(code) ? 'true' : 'false');
					// The visible character first (WCAG 2.5.3), then where the key is.
					key.setAttribute('aria-label', text ? `${text}, ${where.get(code)}` : where.get(code));
					key.addEventListener('click', () => opts.onKey(code));
				}
				box.append(key);
			});
		}

		function drawPinBoards() {
			const start = startLayout();
			if (start)
				drawBoard($('lo-pin-board'), start, {
					marked: (code) => state.pinnedCodes.has(code),
					onKey: (code) => {
						if (code === 'Space') return;
						if (state.pinnedCodes.has(code)) state.pinnedCodes.delete(code);
						else state.pinnedCodes.add(code);
						drawPinBoards();
					}
				});
			// The QWERTY board: only its letters can be held at their place.
			const letterAt = (code) => {
				const cell = (qwerty.rows[code] || [])[0];
				return typeof cell === 'string' && /^[a-z]$/.test(cell) ? cell : '';
			};
			drawBoard($('lo-qwerty-board'), qwerty, {
				label: letterAt,
				marked: (code) => state.qwertyPins.has(letterAt(code)),
				onKey: (code) => {
					const letter = letterAt(code);
					if (!letter) return;
					if (state.qwertyPins.has(letter)) state.qwertyPins.delete(letter);
					else state.qwertyPins.add(letter);
					drawPinBoards();
				}
			});
			if (start) drawZones(start);
			save();
		}

		/** The characters a zone can hold: each one on a base level of the start layout's keys. */
		function zoneChars(layout) {
			const out = [];
			for (const code of E.typingCodes()) {
				const cell = (layout.rows[code] || [])[0];
				if (typeof cell === 'string' && cell.trim() && Array.from(cell).length === 1)
					out.push(cell);
			}
			return out.sort((a, b) => a.localeCompare(b));
		}

		/** The zone board: the chosen character's keys marked; a click adds or removes a key. */
		function drawZones(start) {
			const select = $('lo-zone-char');
			const chars = zoneChars(start);
			// A zone of a character the start lacks would be refused: it goes.
			for (const char of [...state.zones.keys()])
				if (!chars.includes(char)) state.zones.delete(char);
			const kept = select.value;
			select.replaceChildren(
				...chars.map((char) => {
					const option = el('option', '', state.zones.has(char) ? `${char} ●` : char);
					option.value = char;
					return option;
				})
			);
			if (chars.includes(kept)) select.value = kept;
			const char = select.value;
			const zone = state.zones.get(char) || new Set();
			drawBoard($('lo-zone-board'), start, {
				marked: (code) => zone.has(code),
				changed: (code) => legend(start, code) === char,
				onKey: (code) => {
					if (code === 'Space' || !char) return;
					if (zone.has(code)) zone.delete(code);
					else zone.add(code);
					if (zone.size) state.zones.set(char, zone);
					else state.zones.delete(char);
					drawPinBoards();
				}
			});
			const summary = [...state.zones.entries()]
				.sort(([a], [b]) => a.localeCompare(b))
				.map(([key, codes]) => t(`${PREFIX}zones.summary`, { char: key, count: codes.size }));
			$('lo-zones-summary').textContent = summary.length
				? summary.join(' · ')
				: t(`${PREFIX}zones.none`);
		}

		// ============================
		// ======= 5/ Run =============
		// ============================

		/** The constraints of the run (LAYOUT_OPTIMIZER.problem options). */
		function problemOptions() {
			const letters = [...state.qwertyPins].sort();
			const out = {
				pinnedCodes: [...state.pinnedCodes].sort(),
				// The letter itself on its QWERTY key, or only its Ctrl/Cmd shortcut.
				qwertyPins: state.shortcutMode === 'letter' ? letters : [],
				qwertyShortcuts: state.shortcutMode === 'shortcut' ? letters : [],
				zones: Object.fromEntries(
					[...state.zones.entries()]
						.sort(([a], [b]) => (a < b ? -1 : 1))
						.map(([char, codes]) => [char, [...codes].sort()])
				)
			};
			for (const id of SWITCHES) out[id] = $(`lo-switch-${id}`).checked;
			const thumb = $(`lo-switch-${THUMB_SWITCH}`);
			out.thumbKeys = thumb.checked && !thumb.disabled ? $('lo-keyboard').value : null;
			return out;
		}

		/**
		 * The analyse() options of the run: the Comparer's score settings and the
		 * keyboard's fingering (score_settings.js), on the chosen keyboard and the
		 * Studio's keyboard format, so the score is the one the Comparer shows.
		 */
		function analysisOptions() {
			const format = FILES.savedFormat();
			const keyboard = $('lo-keyboard').value;
			return Object.assign(SCORE_SETTINGS.analysisOptions(keyboard), {
				keyboard,
				format: E.keyboardFormats().some((f) => f.id === format)
					? format
					: E.defaultKeyboardFormat()
			});
		}

		function readInteger(id, min, max, fallback) {
			const value = Math.floor(Number($(id).value));
			if (!Number.isFinite(value) || value < min || value > max) {
				$(id).value = String(fallback);
				return fallback;
			}
			return value;
		}

		function setStatus(text, error) {
			delete $('lo-status').dataset.handed;
			$('lo-status').textContent = text;
			$('lo-status').classList.toggle('lo-error', Boolean(error));
		}

		async function loadTables(id) {
			if (id === CUSTOM_ID) {
				if (!state.custom) throw Object.assign(new Error('no text'), { code: 'text_missing' });
				return state.custom.tables;
			}
			const hosted = state.hostCorpora.find((corpus) => corpus.id === id);
			if (hosted) return hosted.tables;
			if (state.tables.has(id)) return state.tables.get(id);
			const corpus = DATA.corpora.find((entry) => entry.id === id);
			const tables = await FILES.builtinTables(corpus);
			state.tables.set(id, tables);
			return tables;
		}

		/** A worker, or the page's own runner when workers cannot start here. */
		function makeRunner(onMessage) {
			try {
				if (!SCRIPT_BASE || typeof Worker !== 'function') throw new Error('no worker');
				const worker = new Worker(new URL('optimizer_worker.js', SCRIPT_BASE).href);
				worker.onmessage = (event) => onMessage(event.data);
				worker.onerror = (event) => {
					event.preventDefault();
					onMessage({ type: 'error', code: 'worker', message: event.message || '' });
				};
				return {
					start: (request) => worker.postMessage({ type: 'start', request }),
					scan: (request) => worker.postMessage({ type: 'library', request }),
					stop: () => worker.postMessage({ type: 'stop' }),
					end: () => worker.terminate()
				};
			} catch {
				// A page the host inlines has no URL to load a worker from: run here.
				let local = null;
				let scanner = null;
				return {
					start: (request) => {
						local = window.LAYOUT_OPTIMIZER_RUNNER.start(request, onMessage);
					},
					scan: (request) => {
						scanner = window.LAYOUT_OPTIMIZER_RUNNER.scoreLibrary(request, onMessage);
					},
					stop: () => local && local.stop(),
					// A finished search needs no end; a library scan stops at its next slice.
					end: () => scanner && scanner.stop()
				};
			}
		}

		/**
		 * Starts a search. Each stage that can fail (reading the choices,
		 * loading the corpus, measuring the start, starting the runners) ends
		 * in failRun on an unexpected error: logged, said in words, with
		 * « Try again », never a page left on « Loading the corpus… ».
		 */
		async function run() {
			if (state.running || state.loading) return;
			$('lo-retry').hidden = true;
			let stage = 'start';
			state.loading = true;
			try {
				await runStages((next) => {
					stage = next;
				});
			} catch (error) {
				failRun(stage, error);
			} finally {
				state.loading = false;
			}
		}

		/** run()'s stages; `enter` names the stage under way for failRun. */
		async function runStages(enter) {
			const start = startLayout();
			if (!start) return;
			const opts = problemOptions();
			const analysis = analysisOptions();
			const seconds = readInteger('lo-seconds', 1, 3600, DEFAULT_SECONDS);
			const iterations = readInteger('lo-iterations', 10, 1000000, DEFAULT_ITERATIONS);
			const restarts = readInteger('lo-restarts', 1, 64, defaultRestarts());
			const seed = readInteger('lo-seed', 0, 4294967295, DEFAULT_SEED);
			const share = ACCURACIES[$('lo-accuracy').value];
			// Refused constraints are said before anything starts.
			try {
				O.problem(E, start, opts);
			} catch (error) {
				if (!(error instanceof O.OptimizerError)) throw error;
				setStatus(errorText(error.code, error.message, error.values), true);
				return;
			}
			enter('corpus');
			setStatus(t(`${PREFIX}status.loading`));
			// A text typed just now is read before the run, not after its pause.
			if ($('lo-corpus').value === CUSTOM_ID) useText($('lo-text').value);
			let tables;
			try {
				tables = await loadTables($('lo-corpus').value);
			} catch (error) {
				// A missing text is the reader's to give, not a failure to retry.
				if (error.code !== 'text_missing') throw error;
				setStatus(errorText(error.code, error.message), true);
				return;
			}
			enter('analysis');
			const identity = {
				id: `${start.id}_optimized`,
				name: t(`${PREFIX}result.name`, { name: start.name })
			};
			state.startResult = E.analyse(start, tables, analysis);
			state.best = null;
			state.bestLayout = null;
			state.tablesInUse = tables;
			state.analysisInUse = analysis;
			state.startInUse = start;
			endLibrary();
			$('lo-result').hidden = false;
			$('lo-open-editor').disabled = true;
			$('lo-open-comparer').disabled = true;
			showBest(start, state.startResult.score.total, false);
			resetChart();
			state.shelf = [];
			drawShelf();

			enter('search');
			// One share of the restarts per worker, in order, so the split never changes the winner.
			const workers = Math.max(1, Math.min(restarts, MAX_WORKERS, threads()));
			const began = Date.now();
			const shares = [];
			let first = 0;
			for (let w = 0; w < workers; w++) {
				const count = Math.floor(restarts / workers) + (w < restarts % workers ? 1 : 0);
				shares.push({ firstRestart: first, restarts: count, progress: null, result: null });
				first += count;
			}
			const running = { shares, runners: [], finished: 0, stopped: false };
			state.running = running;
			$('lo-run').disabled = true;
			$('lo-stop').disabled = false;
			shares.forEach((part) => {
				const runner = makeRunner((message) => receive(running, part, message, began, iterations));
				running.runners.push(runner);
				runner.start({
					start,
					options: opts,
					tables,
					analysis,
					share,
					seed,
					restarts: part.restarts,
					firstRestart: part.firstRestart,
					iterations,
					startMode: root.querySelector('input[name="lo-start-mode"]:checked').value,
					timeBudgetMs: seconds * 1000,
					identity
				});
			});
		}

		/**
		 * Ends a run that failed unexpectedly at `stage`: logs the error, stops
		 * the runners, gives the buttons back and says what failed in words,
		 * with « Try again ».
		 * @param {string} stage - One of RUN_STAGES.
		 * @param {*} error - What was thrown.
		 */
		function failRun(stage, error) {
			if (!RUN_STAGES.includes(stage))
				throw new Error(`layout_optimizer: unknown run stage ${stage}`);
			console.error(`[layout_optimizer] the run failed at its ${stage} stage:`, error);
			const running = state.running;
			state.running = null;
			if (running)
				for (const runner of running.runners) {
					try {
						runner.end();
					} catch (failure) {
						console.error('[layout_optimizer] a runner could not be ended:', failure);
					}
				}
			$('lo-run').disabled = false;
			$('lo-stop').disabled = true;
			const message = error && error.message ? error.message : String(error);
			const strings = window._i18n_strings || {};
			const own =
				error && error.code && typeof strings[`${PREFIX}error.${error.code}`] === 'string';
			setStatus(
				own
					? t(`${PREFIX}error.${error.code}`, error.values)
					: t(`${PREFIX}error.stage.${stage}`, { message }),
				true
			);
			$('lo-retry').hidden = false;
		}

		/** A runner's message; one the page cannot show ends the run (failRun). */
		function receive(running, part, message, began, iterations) {
			try {
				handle(running, part, message, began, iterations);
			} catch (error) {
				if (state.running === running) failRun('result', error);
				else console.error('[layout_optimizer] a message after the run ended failed:', error);
			}
		}

		function handle(running, part, message, began, iterations) {
			if (state.running !== running) return;
			if (message.type === 'error') {
				console.error('[layout_optimizer] a runner failed:', message.code, message.message);
				stop();
				finish(running, began, errorText(message.code, message.message, message.values));
				return;
			}
			if (message.type === 'progress') {
				part.progress = message.progress;
				if (message.layout && (!state.best || message.progress.best > state.best.searchScore)) {
					state.best = { searchScore: message.progress.best };
					showBest(message.layout, message.progress.best, true);
				}
				showProgress(running, began, iterations);
				chartProgress(running, began, false);
				if (message.layout) shelve(message.layout, message.progress.best);
				return;
			}
			part.result = message.result;
			running.finished += 1;
			if (running.finished === running.shares.length) {
				chartProgress(running, began, true);
				const winner = O.bestOf(running.shares.map((entry) => entry.result));
				showBest(winner.layout, winner.score, true, true);
				finish(running, began, null);
				scanLibrary(winner.layout, winner.score);
			}
		}

		function showProgress(running, began, iterations) {
			const done = running.shares.reduce(
				(sum, part) =>
					sum +
					(part.progress
						? Math.min(
								1,
								(part.progress.restart -
									part.firstRestart +
									(part.progress.iteration || 0) / Math.max(1, iterations)) /
									part.restarts
							)
						: 0),
				0
			);
			const seconds = (Date.now() - began) / 1000;
			const budget = Number($('lo-seconds').value) || DEFAULT_SECONDS;
			$('lo-progress').value = Math.max(
				done / running.shares.length,
				Math.min(1, seconds / budget)
			);
			setStatus(
				t(`${PREFIX}status.running`, {
					evaluations: number(evaluations(running), 0),
					seconds: number(seconds, 0)
				})
			);
		}

		const evaluations = (running) =>
			running.shares.reduce(
				(sum, part) =>
					sum +
					(part.result ? part.result.evaluations : part.progress ? part.progress.evaluations : 0),
				0
			);

		function finish(running, began, error) {
			for (const runner of running.runners) runner.end();
			state.running = null;
			$('lo-run').disabled = false;
			$('lo-stop').disabled = true;
			$('lo-progress').value = 1;
			const values = {
				evaluations: number(evaluations(running), 0),
				seconds: number((Date.now() - began) / 1000, 1)
			};
			if (error) {
				setStatus(error, true);
				$('lo-retry').hidden = false;
			} else setStatus(t(`${PREFIX}status.${running.stopped ? 'stopped' : 'done'}`, values));
		}

		function stop() {
			const running = state.running;
			if (!running) return;
			running.stopped = true;
			for (const runner of running.runners) runner.stop();
		}

		/** Ends the library scan under way, if any, and hides its card. */
		function endLibrary() {
			const scan = state.library;
			state.library = null;
			if (scan) scan.runner.end();
			$('lo-library').hidden = true;
			$('lo-library-body').replaceChildren();
		}

		/**
		 * Scores the library on the run's corpus and settings, off the page's
		 * thread where a worker starts (else in the runner's slices), then
		 * shows which existing layouts come close to the optimized one.
		 * @param {object} layout - The optimized layout.
		 * @param {number} score - Its score on the whole corpus.
		 */
		function scanLibrary(layout, score) {
			endLibrary();
			$('lo-library').hidden = false;
			$('lo-library-progress').value = 0;
			$('lo-library-progress').hidden = false;
			setLibraryStatus(t(`${PREFIX}library.starting`));
			const scan = { runner: null };
			scan.runner = makeRunner((message) => {
				if (state.library !== scan) return;
				try {
					libraryMessage(scan, message, score);
				} catch (error) {
					failLibrary(error);
				}
			});
			state.library = scan;
			scan.runner.scan({ layout, tables: state.tablesInUse, analysis: state.analysisInUse });
		}

		function setLibraryStatus(text, error) {
			$('lo-library-status').textContent = text;
			$('lo-library-status').classList.toggle('lo-error', Boolean(error));
		}

		/** A library scan that failed: logged, said in words, the run's result kept. */
		function failLibrary(error) {
			console.error('[layout_optimizer] the library comparison failed:', error);
			const scan = state.library;
			state.library = null;
			if (scan) scan.runner.end();
			$('lo-library-progress').hidden = true;
			setLibraryStatus(
				t(`${PREFIX}library.failed`, {
					message: error && error.message ? error.message : String(error)
				}),
				true
			);
		}

		function libraryMessage(scan, message, score) {
			if (message.type === 'error') {
				failLibrary(new Error(message.message || message.code));
				return;
			}
			if (message.type === 'library_progress') {
				$('lo-library-progress').value = message.done / message.total;
				setLibraryStatus(
					t(`${PREFIX}library.scoring`, {
						done: number(message.done, 0),
						total: number(message.total, 0)
					})
				);
				return;
			}
			if (message.type !== 'library_done')
				throw new Error(`layout_optimizer: unknown library message ${message.type}`);
			state.library = null;
			scan.runner.end();
			const summary = window.LAYOUT_OPTIMIZER_RUNNER.librarySummary(message.entries, score, {
				smallGap: E.similarScoreGap(),
				closest: LIBRARY_CLOSEST
			});
			$('lo-library-progress').hidden = true;
			setLibraryStatus(t(`${PREFIX}library.done`, { total: number(message.entries.length, 0) }));
			$('lo-library-body').replaceChildren(
				libraryCard(document, summary, { t, number, onOpen: openLibraryLayout })
			);
		}

		/** Opens a library layout of the card in « Comparer » or « Éditer ». */
		function openLibraryLayout(entry, where) {
			const layout = library.find((item) => item.id === entry.id);
			if (!layout) throw new Error(`layout_optimizer: no library layout ${entry.id}`);
			if (where === 'comparer') openInComparer(layout);
			else if (where === 'editor') openInEditor(layout);
			else throw new Error(`layout_optimizer: cannot open a layout in ${where}`);
		}

		/**
		 * Shows a layout as the best so far: its board, its score and, at most
		 * every METRICS_MS (always for the final one), its metrics against the start.
		 */
		function showBest(layout, score, better, final) {
			state.bestLayout = layout;
			drawResultBoards();
			const startScore = state.startResult.score.total;
			const change = score - startScore;
			const tile = (key, value, className) => {
				const node = el('div', `lo-tile ${className || ''}`.trim());
				node.append(el('span', 'lo-tile-label', t(key)), el('span', 'lo-tile-value', value));
				return node;
			};
			$('lo-score').replaceChildren(
				tile(`${PREFIX}result.start`, number(startScore, 2)),
				tile(`${PREFIX}result.best`, number(score, 2), 'lo-tile-best'),
				tile(
					`${PREFIX}result.change`,
					signed(change, 2),
					change > 0 ? 'lo-tile-good' : change < 0 ? 'lo-tile-bad' : ''
				)
			);
			if (!final && Date.now() - state.lastMetrics < METRICS_MS) return;
			state.lastMetrics = Date.now();
			const result = E.analyse(layout, state.tablesInUse, state.analysisInUse);
			drawMetrics(result);
			if (final) {
				$('lo-open-editor').disabled = false;
				$('lo-open-comparer').disabled = false;
			}
		}

		/**
		 * The start and the best layout side by side, each key that changed
		 * outlined on both, and how many changed.
		 */
		function drawResultBoards() {
			const start = state.startInUse;
			const best = state.bestLayout;
			if (!start || !best) return;
			const changed = (code) => code !== 'Space' && legend(best, code) !== legend(start, code);
			drawBoard($('lo-start-board'), start, { changed });
			drawBoard($('lo-result-board'), best, { changed });
			const count = Object.keys(best.rows).filter(changed).length;
			$('lo-changed').textContent = t(`${PREFIX}result.changed`, { count: number(count, 0) });
			drawBoardTable(start, best, changed);
		}

		/** What a key types on a layout's base level, in words a screen reader says. */
		function spokenLegend(layout, code) {
			const cell = (layout.rows[code] || [])[0];
			if (code === 'Space') return t('key_name.space');
			if (cell && typeof cell === 'object')
				return t('layout_editor.board.dead_key', { name: legend(layout, code) });
			return legend(layout, code);
		}

		/**
		 * The two boards as one table, their text alternative: a row per drawn
		 * key in reading order (where it is), what it types on the start and on
		 * the best layout, and whether it changed, in words and with a mark.
		 */
		function drawBoardTable(start, best, changed) {
			const board = E.keyboard($('lo-keyboard').value);
			const modifiers = new Set(Object.values(DATA.model.modifier_keys));
			const where = keyPlaces(board, modifiers);
			const keys = board.codes
				.map((code, k) => ({ code, x: board.x[k], y: board.y[k] }))
				.filter((key) => !modifiers.has(key.code))
				.sort((a, b) => a.y - b.y || a.x - b.x);
			const rows = keys.map(({ code }) => {
				const moved = changed(code);
				const tr = el('tr', moved ? 'lo-board-row-changed' : '');
				tr.dataset.code = code;
				const mark = el('td', 'lo-board-mark');
				mark.append(
					el('span', 'lo-board-mark-glyph', moved ? '⇄' : '·'),
					' ',
					t(`${PREFIX}result.table_${moved ? 'yes' : 'no'}`)
				);
				mark.firstChild.setAttribute('aria-hidden', 'true');
				tr.append(
					el('th', '', where.get(code)),
					el('td', 'lo-board-char', spokenLegend(start, code)),
					el('td', 'lo-board-char', spokenLegend(best, code)),
					mark
				);
				tr.firstChild.scope = 'row';
				return tr;
			});
			$('lo-board-rows').replaceChildren(...rows);
		}

		/**
		 * The metrics against the start, in two tables side by side on a wide
		 * screen (one under the other on a phone), so the result uses the width.
		 */
		function drawMetrics(result) {
			const rows = DELTA_METRICS.map((id) => {
				const before = state.startResult.metrics[id];
				const after = result.metrics[id];
				const change = after - before;
				const tr = el('tr');
				const digits = metricDigits(id);
				const unit = window.LAYOUT_ANALYSIS_INFO.metricUnit(id);
				const cell = el('td', 'lo-num', withUnit(signed(change, digits), unit));
				const better = E.METRICS[id].better;
				const good = better === 'lower' ? change < 0 : better === 'higher' ? change > 0 : false;
				const bad = better === 'lower' ? change > 0 : better === 'higher' ? change < 0 : false;
				if (Math.abs(change) >= Math.pow(10, -digits) && (good || bad)) {
					cell.classList.add(good ? 'lo-good' : 'lo-bad');
					// Better or worse with a mark and in words, never by its colour alone.
					const words = t(`layout_analysis.details.verdict_${good ? 'better' : 'worse'}`);
					cell.title = words;
					cell.append(' ', el('span', 'lo-verdict', good ? '▲' : '▼'));
					cell.append(el('span', 'lo-sr-only', ` ${words}`));
				}
				tr.append(
					el('th', '', t(`layout_analysis.metric.${id}`)),
					el('td', 'lo-num', withUnit(number(before, digits), unit)),
					el('td', 'lo-num', withUnit(number(after, digits), unit)),
					cell
				);
				return tr;
			});
			const half = Math.ceil(rows.length / 2);
			$('lo-metrics').replaceChildren(...rows.slice(0, half));
			$('lo-metrics-more').replaceChildren(...rows.slice(half));
		}

		// ============================
		// ======= 5b/ Progress chart =
		// ============================

		/** The run's chart, emptied: it draws from the first progress. */
		function resetChart() {
			state.chart = { start: null, points: [], geometry: null };
			$('lo-chart').hidden = false;
			drawChart();
		}

		/**
		 * Adds the runners' best so far to the chart: a point when it rose, or
		 * once per CHART_POINT_SECONDS while it holds, so the line reaches now.
		 */
		function chartProgress(running, began, final) {
			const chart = state.chart;
			if (!chart) return;
			const reported = running.shares.filter((part) => part.progress);
			if (reported.length === 0) return;
			if (chart.start === null) chart.start = reported[0].progress.startScore;
			const best = Math.max(...reported.map((part) => part.progress.best));
			const point = {
				seconds: (Date.now() - began) / 1000,
				best,
				evaluations: evaluations(running)
			};
			const last = chart.points[chart.points.length - 1];
			if (last && !final && best <= last.best && point.seconds - last.seconds < CHART_POINT_SECONDS)
				return;
			chart.points.push(point);
			// A long run keeps its first and last points and thins the others.
			if (chart.points.length > CHART_MAX_POINTS)
				chart.points = chart.points.filter(
					(_, i, all) => i === 0 || i === all.length - 1 || i % 2 === 1
				);
			drawChart();
		}

		/** A number of seconds and its unit, tied by a no-break space. */
		const secondsText = (value, digits) =>
			withUnit(number(value, digits), t(`${PREFIX}unit.seconds`));
		/** A score and its unit. */
		const pointsText = (value) => withUnit(number(value, 2), t('layout_analysis.unit.points'));

		/** The round steps (1, 2 or 5 times a power of ten) that cover [low, high] in about three. */
		function ticks(low, high) {
			const raw = (high - low || 1) / 3;
			const power = Math.pow(10, Math.floor(Math.log10(raw)));
			const step = [1, 2, 5, 10].map((f) => f * power).find((f) => f >= raw);
			const values = [];
			for (let v = Math.ceil(low / step) * step; v <= high + step * 1e-9; v += step) values.push(v);
			return { values, digits: Math.max(0, -Math.floor(Math.log10(step))) };
		}

		function svg(tag, attrs, text) {
			const node = document.createElementNS(SVG_NS, tag);
			for (const [name, value] of Object.entries(attrs || {}))
				node.setAttribute(name, String(value));
			if (text !== undefined) node.textContent = text;
			return node;
		}

		/**
		 * Draws the best score over time: a step line and its area above the
		 * start's score, a dashed line at the start, the last point marked,
		 * round ticks on both axes. The summary says the same in words and the
		 * table gives the points, so nothing is told by the drawing alone.
		 */
		function drawChart() {
			const chart = state.chart;
			const box = $('lo-chart-svg');
			const width = Math.round(box.parentElement.clientWidth) || CHART_WIDTH;
			box.setAttribute('viewBox', `0 0 ${width} ${CHART_HEIGHT}`);
			box.replaceChildren();
			$('lo-chart-tip').hidden = true;
			const points = chart ? chart.points : [];
			if (!chart || points.length === 0 || chart.start === null) {
				$('lo-chart-summary').textContent = t(`${PREFIX}chart.waiting`);
				$('lo-chart-rows').replaceChildren();
				return;
			}
			const m = CHART_MARGIN;
			const right = width - m.right;
			const bottom = CHART_HEIGHT - m.bottom;
			const last = points[points.length - 1];
			const xMax = Math.max(1, last.seconds);
			const yLow = Math.min(chart.start, ...points.map((p) => p.best));
			const yHigh = Math.max(chart.start, ...points.map((p) => p.best));
			// The start's line sits CHART_START_ROOM above the axis, for its label.
			const floor = bottom - CHART_START_ROOM;
			const perPixel = (yHigh - yLow || 1) / (floor - m.top);
			const y0 = yLow - CHART_START_ROOM * perPixel;
			const y1 = yLow + (bottom - m.top) * perPixel;
			const x = (seconds) => m.left + (seconds / xMax) * (right - m.left);
			const y = (score) => bottom - (score - y0) / perPixel;
			// The grid and the axes' values, recessive.
			const yTicks = ticks(y0, y1);
			for (const value of yTicks.values) {
				box.append(
					svg('line', { class: 'lo-chart-grid', x1: m.left, x2: right, y1: y(value), y2: y(value) })
				);
				box.append(
					svg(
						'text',
						{ class: 'lo-chart-tick', x: m.left - 8, y: y(value) + 4, 'text-anchor': 'end' },
						number(value, yTicks.digits)
					)
				);
			}
			const xTicks = ticks(0, xMax);
			for (const value of xTicks.values)
				box.append(
					svg(
						'text',
						{ class: 'lo-chart-tick', x: x(value), y: bottom + 22, 'text-anchor': 'middle' },
						secondsText(value, xTicks.digits)
					)
				);
			box.append(
				svg('line', { class: 'lo-chart-axis', x1: m.left, x2: right, y1: bottom, y2: bottom })
			);
			// The start's score, the line the search climbs from.
			box.append(
				svg('line', {
					class: 'lo-chart-start',
					x1: m.left,
					x2: right,
					y1: y(chart.start),
					y2: y(chart.start)
				})
			);
			box.append(
				svg(
					'text',
					{ class: 'lo-chart-label', x: right, y: y(chart.start) + 16, 'text-anchor': 'end' },
					t(`${PREFIX}result.start`)
				)
			);
			// A step line: the best holds until the next gain.
			let path = `M ${x(0)} ${y(chart.start)}`;
			for (const point of points) path += ` H ${x(point.seconds)} V ${y(point.best)}`;
			const area = `${path} H ${x(last.seconds)} V ${y(chart.start)} Z`;
			box.append(svg('path', { class: 'lo-chart-area', d: area }));
			box.append(svg('path', { class: 'lo-chart-line', d: path }));
			box.append(
				svg('circle', { class: 'lo-chart-dot', cx: x(last.seconds), cy: y(last.best), r: 5 })
			);
			chart.geometry = { x, y, points, width };

			// The same in words, and the points as a table.
			const gains = points.filter((point, i) => i === 0 || point.best > points[i - 1].best);
			const lastGain = gains[gains.length - 1];
			$('lo-chart-summary').textContent = t(`${PREFIX}chart.summary`, {
				best: pointsText(last.best),
				at: secondsText(lastGain.seconds, 1),
				gain: withUnit(signed(last.best - chart.start, 2), t('layout_analysis.unit.points')),
				rate: number(last.seconds > 0 ? last.evaluations / last.seconds : 0, 0)
			});
			const every = Math.max(1, Math.ceil(points.length / CHART_TABLE_ROWS));
			const rows = points.filter((_, i) => i % every === 0 || i === points.length - 1);
			$('lo-chart-rows').replaceChildren(
				...rows.map((point) => {
					const tr = el('tr');
					tr.append(
						el('td', 'lo-num', secondsText(point.seconds, 1)),
						el('td', 'lo-num', pointsText(point.best)),
						el(
							'td',
							'lo-num',
							withUnit(signed(point.best - chart.start, 2), t('layout_analysis.unit.points'))
						)
					);
					return tr;
				})
			);
		}

		/** The point under the pointer: a guide line, and its time and score beside it. */
		function chartHover(event) {
			const chart = state.chart;
			if (!chart || !chart.geometry) return;
			const box = $('lo-chart-svg');
			const rect = box.getBoundingClientRect();
			if (rect.width === 0) return;
			const { x, y, points, width } = chart.geometry;
			const at = ((event.clientX - rect.left) / rect.width) * width;
			let point = points[0];
			for (const candidate of points) if (x(candidate.seconds) <= at) point = candidate;
			let guide = box.querySelector('.lo-chart-guide');
			if (!guide) {
				guide = svg('line', { class: 'lo-chart-guide' });
				box.append(guide);
			}
			guide.setAttribute('x1', x(point.seconds));
			guide.setAttribute('x2', x(point.seconds));
			guide.setAttribute('y1', CHART_MARGIN.top);
			guide.setAttribute('y2', CHART_HEIGHT - CHART_MARGIN.bottom);
			const tip = $('lo-chart-tip');
			tip.textContent = `${secondsText(point.seconds, 1)} · ${pointsText(point.best)}`;
			tip.style.left = `${(x(point.seconds) / width) * 100}%`;
			tip.style.top = `${(y(point.best) / CHART_HEIGHT) * 100}%`;
			tip.hidden = false;
		}

		function chartLeave() {
			$('lo-chart-tip').hidden = true;
			const guide = $('lo-chart-svg').querySelector('.lo-chart-guide');
			if (guide) guide.remove();
		}

		// ============================
		// ======= 5c/ Results shelf ==
		// ============================

		/**
		 * Keeps a layout a runner reported among the run's SHELF_SIZE best: a
		 * layout already kept (the same keys) is not listed twice.
		 */
		function shelve(layout, score) {
			const key = JSON.stringify(layout.rows);
			if (state.shelf.some((entry) => entry.key === key)) return;
			state.shelf.push({ layout, score, key });
			state.shelf.sort((a, b) => b.score - a.score);
			state.shelf.length = Math.min(state.shelf.length, SHELF_SIZE);
			drawShelf();
		}

		/**
		 * The shelf: each kept layout's rank, score, a bar of its gain over the
		 * start (its number said beside it), the keys it moves, and its buttons.
		 */
		function drawShelf() {
			const list = $('lo-shelf-list');
			$('lo-shelf').hidden = state.shelf.length === 0;
			if (state.shelf.length === 0 || !state.chart || state.chart.start === null) {
				list.replaceChildren();
				return;
			}
			const start = state.startInUse;
			const from = state.chart.start;
			const top = Math.max(...state.shelf.map((entry) => entry.score - from), 0);
			list.replaceChildren(
				...state.shelf.map((entry, i) => {
					const rank = i + 1;
					const layout = Object.assign({}, entry.layout, {
						id: `${entry.layout.id}_${rank}`,
						name: t(`${PREFIX}shelf.name`, { name: start.name, rank })
					});
					const item = el('li', 'lo-shelf-item');
					item.dataset.rank = String(rank);
					const head = el('div', 'lo-shelf-head');
					const badge = el('span', 'lo-shelf-rank', `#${number(rank, 0)}`);
					badge.setAttribute('aria-hidden', 'true');
					head.append(badge, el('span', 'lo-shelf-name', layout.name));
					const gain = entry.score - from;
					const bar = el('span', 'lo-shelf-bar');
					bar.setAttribute('aria-hidden', 'true');
					bar.style.setProperty('--lo-shelf', `${top > 0 ? (Math.max(0, gain) / top) * 100 : 0}%`);
					const moved = Object.keys(entry.layout.rows).filter(
						(code) => code !== 'Space' && legend(entry.layout, code) !== legend(start, code)
					).length;
					const facts = el(
						'p',
						'lo-shelf-facts',
						t(`${PREFIX}shelf.facts`, {
							score: pointsText(entry.score),
							gain: withUnit(signed(gain, 2), t('layout_analysis.unit.points')),
							count: moved
						})
					);
					const actions = el('div', 'lo-library-actions');
					for (const where of ['editor', 'comparer']) {
						const button = el('button', 'lo-link', t(`${PREFIX}library.open_${where}`));
						button.type = 'button';
						button.dataset.shelf = where;
						button.setAttribute(
							'aria-label',
							t(`${PREFIX}library.open_${where}_label`, { name: layout.name })
						);
						button.addEventListener('click', () =>
							where === 'editor' ? openInEditor(layout) : openInComparer(layout)
						);
						actions.append(button);
					}
					item.append(head, bar, facts, actions);
					return item;
				})
			);
		}

		// ============================
		// ======= 6/ Hand-offs =======
		// ============================

		/** Opens another tab of the Studio: the framing site's, or the sibling page. */
		function openTab(message, page) {
			if (window.parent !== window) window.parent.postMessage({ type: message }, location.origin);
			else location.href = new URL(`${page}${location.search}`, BASE).href;
		}

		/** Opens a layout in « Éditer »: the app's own tab, or the site's page. */
		function openInEditor(layout) {
			if (typeof HOST.openEditor === 'function') {
				HOST.openEditor(layout);
				return;
			}
			try {
				FILES.handOffToEditor(layout);
			} catch (error) {
				setStatus(errorText(error.code, error.message), true);
				return;
			}
			openTab(FILES.OPEN_EDITOR_MESSAGE, '../layout_editor/index.html');
		}

		/**
		 * Opens a layout in « Comparer », added and ticked there (a library
		 * layout replaces its own entry): the app's own tab, or the site's page.
		 */
		function openInComparer(layout) {
			if (typeof HOST.openComparer === 'function') {
				HOST.openComparer(layout);
				return;
			}
			try {
				FILES.handOff(layout);
			} catch (error) {
				setStatus(errorText(error.code, error.message), true);
				return;
			}
			openTab(FILES.OPEN_COMPARER_MESSAGE, '../layout_analysis/index.html');
		}

		function openEditor() {
			if (state.bestLayout) openInEditor(state.bestLayout);
		}

		function openComparer() {
			if (state.bestLayout) openInComparer(state.bestLayout);
		}

		/**
		 * Opens the Comparer's « Réglages du score », where the settings of
		 * every Studio score are changed: the app's window shows its own tab,
		 * the site opens the Comparer's page.
		 */
		function openScoreSettings() {
			if (typeof HOST.openScoreSettings === 'function') {
				HOST.openScoreSettings();
				return;
			}
			openTab(FILES.OPEN_COMPARER_MESSAGE, '../layout_analysis/index.html');
		}

		// ============================
		// ======= 7/ Saved choices ===
		// ============================

		/** Reads a saved value; a browser that refuses storage gives none. */
		function readStored(key) {
			try {
				const raw = window.localStorage.getItem(key);
				return raw ? JSON.parse(raw) : null;
			} catch {
				return null;
			}
		}

		/** Writes a saved value; a refused or full storage keeps none, the page works the same. */
		function writeStored(key, value) {
			try {
				if (value === null) window.localStorage.removeItem(key);
				else window.localStorage.setItem(key, JSON.stringify(value));
			} catch {
				// A private window, blocked site data or a full quota: nothing is kept.
			}
		}

		/** The reader's choices, kept for their next visit (this browser only). */
		function save() {
			if (!restored) return;
			const switches = {};
			for (const id of SWITCHES.concat(THUMB_SWITCH)) switches[id] = $(`lo-switch-${id}`).checked;
			writeStored(STORAGE_KEY, {
				corpus: $('lo-corpus').value,
				start: $('lo-start').value,
				startMode: root.querySelector('input[name="lo-start-mode"]:checked').value,
				keyboard: $('lo-keyboard').value,
				switches,
				pinnedCodes: [...state.pinnedCodes],
				qwertyPins: [...state.qwertyPins],
				shortcutMode: state.shortcutMode,
				placeTab: state.placeTab,
				zones: problemOptions().zones,
				seconds: $('lo-seconds').value,
				iterations: $('lo-iterations').value,
				restarts: $('lo-restarts').value,
				seed: $('lo-seed').value,
				accuracy: $('lo-accuracy').value
			});
		}

		/** Puts back the saved choices; a value this page no longer knows is skipped. */
		function restore() {
			const saved = readStored(STORAGE_KEY);
			if (!saved || typeof saved !== 'object') return;
			const choose = (id, value) => {
				const select = $(id);
				if (Array.from(select.options).some((option) => option.value === value))
					select.value = value;
			};
			const strings = (list) =>
				Array.isArray(list) ? list.filter((item) => typeof item === 'string') : [];
			choose('lo-corpus', saved.corpus);
			syncCorpus();
			// A layout open in « Éditer » may arrive after the mount: it is chosen then.
			state.savedStart = typeof saved.start === 'string' ? saved.start : null;
			choose('lo-start', saved.start);
			if (saved.startMode === 'layout' || saved.startMode === 'random')
				root.querySelector(`input[name="lo-start-mode"][value="${saved.startMode}"]`).checked =
					true;
			choose('lo-keyboard', saved.keyboard);
			for (const id of SWITCHES.concat(THUMB_SWITCH))
				if (saved.switches && typeof saved.switches[id] === 'boolean')
					$(`lo-switch-${id}`).checked = saved.switches[id];
			syncSwitches();
			state.pinnedCodes = new Set(strings(saved.pinnedCodes));
			state.qwertyPins = new Set(strings(saved.qwertyPins));
			if (SHORTCUT_MODES.includes(saved.shortcutMode)) state.shortcutMode = saved.shortcutMode;
			root.querySelector(`input[name="lo-shortcut-mode"][value="${state.shortcutMode}"]`).checked =
				true;
			if (PLACE_TABS.includes(saved.placeTab)) state.placeTab = saved.placeTab;
			state.zones = new Map();
			for (const [char, codes] of Object.entries(saved.zones || {}))
				if (strings(codes).length) state.zones.set(char, new Set(strings(codes)));
			for (const id of ['seconds', 'iterations', 'restarts', 'seed'])
				if (typeof saved[id] === 'string' && /^\d+$/.test(saved[id]))
					$(`lo-${id}`).value = saved[id];
			choose('lo-accuracy', saved.accuracy);
			const text = readStored(TEXT_KEY);
			if (text && typeof text.text === 'string') {
				$('lo-text').value = text.text;
				useText(text.text);
			}
		}

		// ============================
		// ======= 8/ Start ===========
		// ============================

		const threads = () => Math.max(1, (navigator.hardwareConcurrency || 2) - 1);
		const defaultRestarts = () => Math.min(MAX_WORKERS, threads());

		function bind() {
			$('lo-corpus').addEventListener('change', syncCorpus);
			let textTimer = null;
			$('lo-text').addEventListener('input', (event) => {
				clearTimeout(textTimer);
				textTimer = setTimeout(
					() => useText(event.target.value),
					window.LAYOUT_ANALYSIS_FILES.TEXT_DEBOUNCE_MS
				);
			});
			$('lo-file').addEventListener('change', (event) => {
				const file = event.target.files && event.target.files[0];
				if (file) useFile(file);
				event.target.value = '';
			});
			$('lo-start').addEventListener('change', () => {
				state.savedStart = null;
				state.pinnedCodes.clear();
				drawPinBoards();
			});
			$('lo-keyboard').addEventListener('change', () => {
				syncSwitches();
				drawPinBoards();
				// Each keyboard has its own fingering profile.
				drawSettings();
			});
			for (const id of PLACE_TABS)
				$(`lo-tab-${id}`).addEventListener('click', () => showPlaceTab(id));
			root.querySelector('.lo-tabs').addEventListener('keydown', (event) => {
				const step = { ArrowRight: 1, ArrowLeft: -1 }[event.key];
				if (!step) return;
				event.preventDefault();
				const at = PLACE_TABS.indexOf(state.placeTab);
				showPlaceTab(PLACE_TABS[(at + step + PLACE_TABS.length) % PLACE_TABS.length], true);
			});
			for (const input of root.querySelectorAll('input[name="lo-shortcut-mode"]'))
				input.addEventListener('change', () => {
					if (input.checked) state.shortcutMode = input.value;
				});
			$('lo-settings-edit').addEventListener('click', openScoreSettings);
			SCORE_SETTINGS.onChange(drawSettings);
			$('lo-zone-char').addEventListener('change', drawPinBoards);
			$('lo-zone-clear').addEventListener('click', () => {
				state.zones.delete($('lo-zone-char').value);
				drawPinBoards();
			});
			$('lo-zones-clear').addEventListener('click', () => {
				state.zones.clear();
				drawPinBoards();
			});
			$('lo-switches').addEventListener('change', syncSwitches);
			$('lo-run').addEventListener('click', run);
			$('lo-retry').addEventListener('click', run);
			$('lo-stop').addEventListener('click', stop);
			$('lo-open-editor').addEventListener('click', openEditor);
			$('lo-open-comparer').addEventListener('click', openComparer);
			$('lo-chart-svg').addEventListener('pointermove', chartHover);
			$('lo-chart-svg').addEventListener('pointerleave', chartLeave);
			if (typeof ResizeObserver === 'function') {
				let width = root.clientWidth;
				new ResizeObserver(() => {
					if (root.clientWidth === width) return;
					width = root.clientWidth;
					drawPinBoards();
					drawResultBoards();
					if (state.chart) drawChart();
				}).observe(root);
			}
		}

		/** Every string again, once the locale has arrived. */
		function refreshStrings() {
			applyStrings();
			fillCorpora();
			fillStarts();
			fillKeyboards();
			fillSwitches();
			fillPresets();
			drawSettings();
			if (state.chart) drawChart();
			drawShelf();
		}

		// Saving waits until the saved choices are back, or the defaults would replace them.
		let restored = false;
		refreshStrings();
		$('lo-seconds').value = String(DEFAULT_SECONDS);
		$('lo-iterations').value = String(DEFAULT_ITERATIONS);
		$('lo-restarts').value = String(defaultRestarts());
		$('lo-seed').value = String(DEFAULT_SEED);
		bind();
		restore();
		showPlaceTab(state.placeTab);
		restored = true;
		// Every field and switch saves on change; the boards save as they redraw.
		root.addEventListener('change', save);
		drawPinBoards();
		// « Optimize this layout » of the site's editor: its id waits in this tab's storage.
		const handed = FILES.takeOptimizerHandoff();
		if (handed) {
			if (handed !== $('lo-start').value) state.pinnedCodes.clear();
			state.savedStart = handed;
			state.handedStart = handed;
		}
		FILES.onEditorLayouts((layouts) => {
			state.editorLayouts = Array.isArray(layouts) ? layouts : [];
			fillStarts();
		});
		document.addEventListener('i18n:applied', () => {
			refreshStrings();
			drawPinBoards();
			if ($('lo-status').dataset.handed) sayHanded();
		});
		if (opts.reportHeight && window.parent !== window) {
			const post = () =>
				window.parent.postMessage(
					{ type: HEIGHT_MESSAGE, height: document.documentElement.scrollHeight },
					location.origin
				);
			post();
			if (typeof ResizeObserver === 'function') new ResizeObserver(post).observe(document.body);
		}
		/**
		 * Adds or replaces a corpus the host provides (the app's keystats), listed
		 * first, and selects it when it is the default.
		 * @param {{id: string, title: string, tables: object, default?: boolean}} corpus
		 * @throws {Error} On tables the engine cannot read.
		 */
		function setCorpus(corpus) {
			E.prepareNgrams(corpus.tables);
			const entry = { id: corpus.id, title: corpus.title, tables: corpus.tables };
			const at = state.hostCorpora.findIndex((c) => c.id === corpus.id);
			if (at >= 0) state.hostCorpora.splice(at, 1, entry);
			else state.hostCorpora.unshift(entry);
			fillCorpora();
			if (corpus.default) $('lo-corpus').value = corpus.id;
			syncCorpus();
			save();
		}

		// « My typing »: the app's keystats n-grams, the default corpus in the app.
		onNgrams = (ngrams) =>
			setCorpus({
				id: MY_TYPING_ID,
				title: t('layout_analysis.corpus.my_typing'),
				tables: ngrams,
				default: true
			});
		if (lastNgrams) onNgrams(lastNgrams);
		mounted = { setCorpus, setStart };
		return mounted;
	}

	// This folder's URL, read while the script runs: the worker and the sibling
	// pages resolve against it. A script a host inlines has none: it runs the
	// search on the page and opens no sibling page.
	const SCRIPT_BASE =
		document.currentScript && document.currentScript.src
			? new URL('.', document.currentScript.src).href
			: null;
	const BASE = SCRIPT_BASE || location.href;

	window.LAYOUT_OPTIMIZER_PAGE = { mount, numberLocale, formatNumber, libraryCard };

	/** The site's page: mount into its <main>. */
	function autostart() {
		const root = document.getElementById(STANDALONE_ROOT_ID);
		if (root) mount(root, { reportHeight: true });
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', autostart);
	else autostart();
})();
