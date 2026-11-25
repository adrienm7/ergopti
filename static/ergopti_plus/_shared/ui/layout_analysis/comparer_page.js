// _shared/ui/layout_analysis/comparer_page.js

/**
 * ==============================================================================
 * MODULE: Layout Comparer Page
 * DESCRIPTION:
 * The « Comparer » tab of Ergopti Studio, the same page on ergopti.fr
 * (/studio/comparer) and in the app's Studio window: pick a corpus (built-in,
 * pasted, a file, or one the host provides such as the user's own keystats),
 * a keyboard and layouts; see the ranking, the global score chart, each
 * layout's contributions and finger load; edit every weight and watch the
 * ranking move. Everything runs in the page; no text leaves the device.
 *
 * FEATURES & RATIONALE:
 * 1. Instant: a corpus becomes n-gram tables once (cached by its hash);
 *    changing a weight re-scores without re-analysis.
 * 1b. Mountable: LAYOUT_ANALYSIS_COMPARER.mount(root, {host}) fills any
 *    element; the site's page mounts its <main>, the app's Studio window its
 *    « Comparer » tab. The markup lives here, its strings in data-i18n*.
 * 2. Host hook: a host may define window.LAYOUT_ANALYSIS_HOST before this
 *    script runs, with `corpora` ({id, title, tables}[], listed first and the
 *    first one selected) and `layouts` (library-shape layouts, e.g. the
 *    user's own from « Éditer »). The site defines none.
 * 3. Every visible string is a locale key (21 locales).
 * 4. Per-viewer conveniences (weights, selection, corpus, keyboard, the last
 *    pasted text's tables, the layouts imported from files) are kept in
 *    localStorage when it is available; the page works the same without it.
 * 5. A layout file of any common format (layout_formats.js) joins the
 *    comparison; what it could not read is listed.
 * 6. Framed by the site, it posts its height to the parent
 *    ({type: 'ergopti-layout-analysis:height', height}) on load and resize.
 * 7. Late host data: the app's 'studio-ngrams' event (or
 *    LAYOUT_ANALYSIS_COMPARER.setCorpus) adds « My typing » and selects it;
 *    a later one (the app's fresh read after its saved one) replaces its
 *    tables without changing the user's corpus;
 *    LAYOUT_ANALYSIS_COMPARER.addLayouts adds personal layouts, and
 *    LAYOUT_ANALYSIS_COMPARER.compare adds the layouts a visitor asked to
 *    compare (a handoff, a link) and shows their ranking; a host `store` ({list, save, remove}, promises) keeps imported layouts instead
 *    of localStorage. LAYOUT_ANALYSIS_COMPARER.onResults(listener) lets an
 *    extra view (other analysers' scores) follow every comparison.
 * 8. Every metric and sourced value has an « i » button (info_popover.js):
 *    its popover says where the value comes from and links the sources.
 * 9. The ideal finger load of finger_imbalance is editable (eight targets
 *    summing to 100 %), kept with the other conveniences.
 * 10. The user's fingering profile (fingering_editor.js: finger of each key,
 *    home key of each finger) is edited here and applies to every analysis.
 * 11. A link may open the comparison on a corpus, a keyboard and a keyboard
 *    format (?corpus=<id>&keyboard=<id>&format=<id>, the site's benchmark page), over the saved
 *    choice; a value the page does not know is named in the console and the
 *    saved choice stays. It may also name the compared layouts, the one shown
 *    in detail and the one it is compared with (&layouts=a,b&details=a&versus=b),
 *    shown without replacing the visitor's saved selection; « Copy the link »
 *    writes that address (the user's own layouts and texts stay out of it).
 * 12. Details: a layout against another (the engine's diff, each difference
 *    with its verdict in words), each finger's share against its ideal load,
 *    hands and rows, and a one-hue key heatmap with its scale that shrinks
 *    with the page. The score settings are folded under the results.
 * 13. The heatmap shows the presses, the points each key costs the score or
 *    any per-key metric (costs and gains), each key naming its worst groups;
 *    against another layout it shows the key-by-key difference. Folded
 *    figures follow: the worst pairs and trigrams of the board, bigram and
 *    trigram classes, each finger's travel, modifiers and dead keys, and the
 *    layout's standing among the compared ones; every number is the engine's.
 * 14. The ranking table's columns (any metric) and row filters (name, family,
 *    score range) are the viewer's, kept with the other conveniences.
 * 15. The key pair matrix (how often, or score points, each key pair) scrolls
 *    inside its own box at phone width and is also a sortable table; the
 *    effort per word reads the corpus's word table (built-in or pasted).
 * 16. Sub-tabs (maintainer, 2026-11-18): overview, fingers and hands,
 *    bigrams, trigrams, rows and distance, side-by-side heat maps, coverage
 *    and more, other analysers, one layout. Every figure follows the filters
 *    (name, family, origin, language, completeness, score) and has a table;
 *    the corpus picker groups the built-in texts by language, each entry
 *    naming its kind.
 * 17. Add a layout (ux-study items 6 and 15): a file chosen or dropped on the
 *    layouts card, or a text pasted or dropped, read by its content with the
 *    format it recognised named live; a refusal says where to fix it.
 * 18. The user's own layouts (ux-study item 5): « Rename » in place,
 *    « Duplicate » and « Remove » with an « Undo », kept through the host's
 *    store in the app (the same studio_layout_save and studio_layout_remove
 *    on the three OS) or this browser's storage on the site.
 * ==============================================================================
 */

(function () {
	'use strict';

	const E = window.LAYOUT_ANALYSIS;
	const DATA = window.LAYOUT_ANALYSIS_DATA;
	const INFO = window.LAYOUT_ANALYSIS_INFO;
	const FINGERING = window.LAYOUT_ANALYSIS_FINGERING;
	// The score settings every Studio score reads (score_settings.js).
	const SCORE_SETTINGS = window.LAYOUT_ANALYSIS_SCORE_SETTINGS;
	const UNDO = window.LAYOUT_ANALYSIS_UNDO;
	const infoButton = INFO.button;
	const STORAGE_KEY = window.LAYOUT_ANALYSIS_FILES.SETTINGS_KEY;
	const CUSTOM_ID = 'custom';
	// The metrics shown as table columns; every metric is in the details.
	const TABLE_METRICS = [
		'sfb',
		'sfs',
		'lsb',
		'scissors',
		'roll_in',
		'roll_out',
		'alternation',
		'redirect',
		'redirect_bad',
		'home_row',
		'distance',
		'unsupported',
		'distinct_chars',
		'coverage_bonus',
		'simplicity'
	];
	// What the heatmap can show: the presses, the points each key costs the
	// score, or any per-key metric of the engine (its costs and its gains).
	const HEAT_PRESSES = 'presses';
	const HEAT_SCORE = 'score';
	const HEAT_CHOICES = [HEAT_PRESSES, HEAT_SCORE].concat(
		E.KEY_COST_METRICS,
		E.KEY_GAINS,
		E.KEY_INFO_METRICS
	);
	// The key pair matrix: its busiest keys on each axis (every letter of a
	// layout fits), how its cells are coloured, and the rows of its table.
	const MATRIX_MAX_KEYS = 32;
	const MATRIX_COUNT = 'count';
	const MATRIX_POINTS = 'points';
	const MATRIX_CHOICES = [MATRIX_COUNT, MATRIX_POINTS];
	const MATRIX_TABLE_ROWS = 100;
	// The word effort figure: its ranges of effort and its hardest words.
	const WORD_BINS = 10;
	const HARDEST_WORDS = 15;
	// Digits of a key's value in the heatmap.
	const HEAT_DIGITS = 2;
	// The class of a rank's cell: an ordinal, the one number a table writes
	// without a unit (studio-numbers.cjs).
	const RANK_CELL = 'la-rank';
	// The class of a mark's cell: an index on QWERTY (QWERTY reads 100), a
	// number with no unit, written alone like a rank (studio-numbers.cjs).
	const MARK_CELL = 'la-cell-mark';
	// The class of a table's layout-name cells (the ranking's and every
	// heat table's), the column that stays in view while it scrolls sideways.
	const NAME_COLUMN = 'la-name-col';
	// How many metrics a key's score tooltip names, worst first.
	const HEAT_SCORE_PARTS = 3;
	// A difference key is at most this mix of its colour, so its ink stays readable.
	const HEAT_DIFF_MAX_SHARE = 0.7;
	// The bigram classes and trigram classes shown as shares (engine metrics and
	// trigramClasses).
	const BIGRAM_CLASSES = [
		'sfb',
		'repeat',
		'lsb',
		'scissors',
		'half_scissors',
		'pinky_ring',
		'row_jump',
		'roll_in',
		'roll_out',
		'hand_change'
	];
	const TRIGRAM_CLASSES = [
		'roll3_in',
		'roll3_out',
		'alternation',
		'redirect',
		'roll_mixed',
		'same_finger'
	];
	// How many characters « typed via » lists, most frequent first.
	const TYPING_ROWS = 12;
	// Layouts ticked on a first visit: the registry and the two references.
	// The layouts scored between two yields to the page: one slice stays a short
	// task (each layout takes some 6 to 50 ms, by the corpus), so the page
	// answers while the whole library is scored and shows it as it comes.
	const ANALYSE_SLICE = 4;
	// The best so far is drawn again at most this often while the slices run
	// (ms), and at most once per this many times its own drawing cost, so the
	// drawing never takes more than a fifth of the time (649 layouts,
	// 2026-11-19: a full redraw of every tab cost 300 to 800 ms each time).
	const PARTIAL_RENDER_MS = 400;
	const PARTIAL_RENDER_FACTOR = 4;
	// The letter heading of a layout whose name starts with a digit or a sign.
	const LETTER_OTHER = '#';
	// The collapsed layout list names this many compared layouts, then counts the rest.
	const SUMMARY_NAMES = 8;
	const CHART_MAX_BARS = 40;
	// Widest size of one key unit of the heatmap, in pixels; narrower screens
	// shrink the whole board instead of scrolling it.
	const HEAT_UNIT_PX = 44;
	// Widest the space bar is drawn, in key units (the ISO and ANSI bar, shortened).
	const SPACE_UNITS = 6;
	const SPACE_CODE = 'Space';
	// Where a shared link opens when the page has no web address of its own
	// (the app's Studio window): the site's Comparer.
	const SITE_COMPARER_URL = 'https://ergopti.fr/studio/comparer';
	// The link parameters this page reads; the others of the address are dropped.
	// tab: the tab shown; px, py: the Pareto tab's two values; text: the trace's text.
	const LINK_PARAMS = [
		'corpus',
		'keyboard',
		'format',
		'layouts',
		'details',
		'versus',
		'tab',
		'px',
		'py',
		'text',
		'blend'
	];
	// The layout origins a link can name: the user's own layouts stay on their device.
	const SHAREABLE_ORIGINS = ['registry', 'reference', 'library'];
	// The message the framing page listens for to size its frame.
	const HEIGHT_MESSAGE = 'ergopti-layout-analysis:height';
	// The app's keystats n-grams: the event its Studio window dispatches and the
	// corpus id they take (the default corpus in the app, maintainer 2026-11-14).
	const NGRAMS_EVENT = 'studio-ngrams';
	// The state of that read: 'loading', then the tables, or 'failed'.
	const NGRAMS_STATE_EVENT = 'studio-ngrams-state';
	const MY_TYPING_ID = 'my_typing';
	// Which text each layout types (maintainer, 2026-11-17): the keys typed
	// (the raw text, hotstring abbreviations included), the final text (after
	// hotstring expansions and AI completions), or the final text except the
	// layouts ticked « + » (Ergopti+ hotstrings), which type the keys typed. Only
	// a corpus that brings both texts (« My typing », schema 2) tells them apart.
	const TEXT_TYPED = window.LAYOUT_ANALYSIS_FILES.TEXT_MODES.typed;
	const TEXT_MIXED = window.LAYOUT_ANALYSIS_FILES.TEXT_MODES.mixed;
	const TEXT_MODES = Object.values(window.LAYOUT_ANALYSIS_FILES.TEXT_MODES);
	// A layout ticked « + » is ranked as « <name>+ » under the id « <id>+ »: a
	// library id never holds a « + », so the two never collide.
	const PLUS_SUFFIX = '+';

	// The Comparer's tabs, in order, at the top of the page (maintainer,
	// 2026-11-18): « Home » (the corpus, the layouts and the score settings),
	// then the results: the ranking, the figures by theme (after KLAnext's
	// result tabs), the other analysers and one layout in detail. A fresh visit
	// opens « Home », a link to a comparison its ranking, a link naming a
	// layout to detail the last.
	const TABS = [
		'home',
		'overview',
		'fingers',
		'bigrams',
		'trigrams',
		'rows',
		'heatmaps',
		'misc',
		'pareto',
		'trace',
		'analysers',
		'help',
		'details'
	];
	const HOME_TAB = 'home';
	// The task help (an idea seen in the Layouts Wiki playground's Docs pane):
	// static text, no filter applies to it.
	const HELP_TAB = 'help';
	const DEFAULT_TAB = 'overview';
	const DETAILS_TAB = 'details';
	// The score settings' weight groups, each a titled sub-section; every
	// weight of the score is in exactly one (test-layout-comparer-page.cjs).
	const WEIGHT_GROUPS = {
		pairs: [
			'sfb',
			'sfs',
			'sfb_distance',
			'lsb',
			'scissors',
			'half_scissors',
			'pinky_ring',
			'row_jump'
		],
		rolls: [
			'roll_in',
			'roll_out',
			'roll3_in',
			'roll3_out',
			'alternation',
			'hand_run',
			'redirect',
			'redirect_bad'
		],
		load: ['finger_imbalance', 'hand_imbalance', 'pinky_load'],
		position: ['home_row', 'distance', 'outer_column'],
		access: ['modifier_usage', 'altgr_usage', 'dead_key_usage'],
		bonuses: [
			'unsupported',
			'compact_fit',
			'char_coverage',
			'coverage_bonus',
			'simplicity',
			'direct_digits',
			'shortcut_left'
		]
	};
	// Each weight group's accent: its slot of theme.css « Chart look », drawn
	// on the section's edge and icon only, so the text keeps its contrast (the
	// static sections name theirs in the markup, la-accent-<slot>).
	const SECTION_SLOT = { pairs: 1, rolls: 2, load: 3, position: 4, access: 5, bonuses: 6 };
	// The settings sections' icons (24 × 24 strokes), decorative: each section
	// is named by its heading.
	const SECTION_ICONS = {
		pairs: 'M6 3h12v7H6zM6 14h12v7H6zM12 10v4',
		rolls: 'M4 17c2-7 9-10 15-6M16 8l3 3-3 3',
		load: 'M5 21V12M9 21V7M13 21V5M17 21V9M21 21V14',
		position: 'M12 3v5M12 16v5M3 12h5M16 12h5M12 9a3 3 0 1 0 0.01 0',
		access: 'M4 10h9v10H4zM10 4h10v10h-4M7 15h3',
		bonuses: 'M12 3l2.7 5.6 6.1.9-4.4 4.3 1 6.1L12 17l-5.4 2.9 1-6.1-4.4-4.3 6.1-.9z',
		config: 'M8 3v12M4 11l4 4 4-4M16 21V9M12 13l4-4 4 4',
		weights: 'M12 4v16M5 8h14M5 8l-3 6h6zM19 8l-3 6h6zM8 20h8',
		ideal: 'M6 21v-9M10 21V5M14 21V4M18 21V8M3 21h18',
		shortcuts: 'M3 7h18v10H3zM7 11h1M11 11h1M15 11h1M7 14h10',
		forms: 'M3 8h18v8H3zM3 12h18M9 8v8M15 8v8'
	};
	const SVG_NS = 'http://www.w3.org/2000/svg';
	// The actions on the user's own layouts in the list: a pencil, two sheets, a bin.
	const MINE_ICONS = {
		rename: 'M4 20h4L19 9l-4-4L4 16zM13 7l4 4',
		duplicate: 'M8 8h12v12H8zM4 16V4h12',
		remove: 'M4 7h16M9 7V4h6v3M6 7l1 13h10l1-13M10 11v6M14 11v6'
	};
	// Each tab's icon (24 × 24 strokes, the settings sections' set) and its
	// accent slot of theme.css « Chart look » (maintainer, 2026-11-18: the tabs
	// say at a glance what each holds). Both are decorative: the tab's text
	// names it, and the chosen tab is marked by its bar and weight too.
	const TAB_ICONS = {
		home: 'M3 11l9-7 9 7M5 10v10h14V10M10 20v-6h4v6',
		overview: 'M4 20V11M10 20V4M16 20v-7M2 20h20',
		fingers: 'M7 21v-7l-2-3M10 14V5M13 14V3M16 14V5M19 14V8M7 14h12v2a5 5 0 0 1-5 5h-2',
		bigrams: 'M3 7h7v10H3zM14 7h7v10h-7z',
		trigrams: 'M2 8h5v8H2zM9.5 8h5v8h-5zM17 8h5v8h-5z',
		rows: 'M3 6h18M5 12h16M7 18h14',
		heatmaps: 'M3 3h8v8H3zM13 3h8v8h-8zM3 13h8v8H3zM13 13h8v8h-8z',
		misc: 'M12 3v18M3 12h18M6 6l12 12M18 6L6 18',
		pareto: 'M3 3v18h18M6 8h3v4h4v3h4v3',
		trace: 'M3 17h4l3-8 4 10 3-6h4',
		analysers: 'M10 4a6 6 0 1 0 0.01 0M15 15l6 6',
		details: 'M7 3h7l5 5v13H7zM14 3v5h5M10 13h6M10 17h6',
		help: 'M12 3a9 9 0 1 0 0.01 0M9.5 9a2.5 2.5 0 1 1 3.5 2.3c-.6.3-1 .9-1 1.6V14M12 17v.5'
	};
	const TAB_SLOT = {
		home: 1,
		overview: 2,
		fingers: 3,
		bigrams: 4,
		trigrams: 5,
		rows: 6,
		heatmaps: 1,
		misc: 2,
		pareto: 5,
		trace: 6,
		analysers: 3,
		details: 4,
		help: 5
	};

	// The metrics each themed tab charts, one bar chart each and one table;
	// every metric of the engine is in exactly one tab (test-layout-comparer-page.cjs).
	const TAB_METRICS = {
		fingers: ['finger_imbalance', 'hand_imbalance', 'pinky_load'],
		bigrams: [
			'sfb',
			'sfs',
			'sfb_distance',
			'lsb',
			'scissors',
			'half_scissors',
			'pinky_ring',
			'row_jump',
			'repeat',
			'roll_in',
			'roll_out',
			'hand_change'
		],
		trigrams: ['roll3_in', 'roll3_out', 'alternation', 'hand_run', 'redirect', 'redirect_bad'],
		rows: ['home_row', 'top_row', 'bottom_row', 'number_row', 'distance', 'outer_column'],
		misc: [
			'unsupported',
			'char_coverage',
			'distinct_chars',
			'coverage_bonus',
			'simplicity',
			'compact_fit',
			'direct_digits',
			'shortcut_left',
			'modifier_usage',
			'altgr_usage',
			'dead_key_usage'
		]
	};
	// The parts of the stacked figures, each drawn in its categorical slot of
	// theme.css « Chart look », in this fixed order (colour follows the part).
	const TRIGRAM_MIX = [
		'roll3_in',
		'roll3_out',
		'alternation',
		'redirect',
		'roll_mixed',
		'same_finger'
	];
	const ROW_MIX = ['number_row', 'top_row', 'home_row', 'bottom_row'];
	// The metrics whose best layout the overview names, beside the score.
	const LEADER_METRICS = [
		'sfb',
		'sfs',
		'lsb',
		'scissors',
		'redirect',
		'distance',
		'home_row',
		'roll_in',
		'finger_imbalance'
	];
	// How many boards the side-by-side heat maps draw, the first of the ranking.
	const HEATS_COUNTS = [2, 4, 6, 9, 12];
	// The level a board shows on its keys: the base one unless the viewer picks
	// another (a layout's own levels, Neo's Mod3 and Mod4, included).
	const LEVEL_BASE = 'base';
	const DEFAULT_HEATS_COUNT = 6;
	// The Pareto tab (an idea seen in the Layouts Wiki playground): its two
	// values are the mark (higher is better) or a metric the score weighs one
	// way; the default trade-off is the SFB against the lateral stretches.
	const PARETO_MARK = 'mark';
	const PARETO_DEFAULT = { x: 'sfb', y: 'lsb', frontOnly: false };
	// How many frontier layouts the chart names beside their point.
	const PARETO_NAMED = 12;
	// The chart's drawing box (SVG units; it scales to the page's width).
	const PARETO_SIZE = { width: 640, height: 400, margin: 56 };
	// The trace tab (an idea seen in the Layouts Wiki playground): the text it
	// types when the visitor has written none.
	const TRACE_SAMPLE_KEY = 'layout_analysis.trace.sample';
	// The tabs under the Principal and Comparison frame (an idea seen in the
	// Layouts Wiki playground's Main and Comp pickers): the detailed layout and
	// the one it is compared with, the same as « One layout »'s own pickers.
	const FRAME_TABS = [
		'overview',
		'fingers',
		'bigrams',
		'trigrams',
		'rows',
		'heatmaps',
		'misc',
		'pareto',
		'trace'
	];
	// The quantiles the Pareto tab's spread marks and lists (the Layouts Wiki
	// playground's Ranking view snaps its range to these), in percent.
	const SPREAD_QUANTILES = [0, 10, 25, 50, 75, 90, 100];
	// The user metrics a first visit starts with (an idea seen in the Layouts
	// Wiki playground's metric queries), each named by its locale key.
	const USER_METRIC_EXAMPLES = [
		{ key: 'pinky_sfb', window: 'bigram', query: 'same_finger & !same_key & finger1 = 4' },
		{
			key: 'pinky_redirect',
			window: 'trigram',
			query: 'redirect & (finger1 = 4 | finger2 = 4 | finger3 = 4)'
		},
		{
			key: 'top_row_sfs',
			window: 'skipgram',
			query: 'same_finger & !same_key & (row1 = -1 | row2 = -1)'
		}
	];
	// The smoothed distribution above the spread (an idea seen in the Layouts
	// Wiki playground's Ranking view): its band's height and its samples.
	const SPREAD_DENSITY_BAND = 44;
	const SPREAD_DENSITY_POINTS = 160;
	// Corpus blends (an idea seen in the Layouts Wiki playground): how many
	// corpora a blend mixes, its id in the corpus list, and the first parts.
	const BLEND_PARTS = 3;
	const BLEND_ID = 'blend';
	const BLEND_DEFAULT_WEIGHTS = [50, 50, 0];
	// How many corpus words the drill-down of a penalised group names.
	const TRACE_WORDS_SHOWN = 12;
	// A filter set to this value keeps everything.
	const ALL = '';
	const COMPLETE_CHOICES = ['all', 'yes', 'no'];
	// The narrowest page that opens the filters at first (a phone folds them).
	const FILTERS_OPEN_MIN_PX = 720;

	// The site's standalone page mounts the Comparer into this element.
	const STANDALONE_ROOT_ID = 'layout-analysis';

	// The site passes ?lang=<code>; i18n.js loads that locale, then English and French.
	const lang = new URLSearchParams(location.search).get('lang');
	if (lang && /^[a-z]{2}$/.test(lang)) window._i18n_locale = lang;

	// The Comparer's markup; data-i18n* attributes are filled by applyStrings().
	const MARKUP = `<header class="la-top">
	<h1 id="la-title" data-i18n="layout_analysis.title"></h1>
	<button id="la-share" type="button" data-i18n="layout_analysis.share.button"></button>
</header>
<p id="la-share-status" class="la-muted" role="status" hidden></p>

<div id="la-tabs" class="la-tabs" role="tablist" aria-labelledby="la-title"></div>
<p id="la-status" class="la-status" role="status" aria-live="polite"></p>

<section id="la-panel-home" class="la-tab-panel la-home" role="tabpanel" aria-labelledby="la-tab-home" hidden>
<div class="la-setup">
<section class="la-card la-corpus-card" aria-labelledby="la-corpus-label">
	<div class="la-field">
		<label
			id="la-corpus-label"
			class="la-card-title"
			for="la-corpus"
			data-i18n="layout_analysis.corpus.label"
		></label>
		<select id="la-corpus"></select>
		<p id="la-corpus-info" class="la-muted"></p>
	</div>
	<div class="la-corpus-file">
		<label class="la-file la-file-button la-file-primary" data-i18n-text="layout_analysis.corpus.file">
			<svg class="la-file-icon" viewBox="0 0 16 16" aria-hidden="true" focusable="false">
				<path d="M8 10.5V2.5M4.75 5.75 8 2.5l3.25 3.25M2.5 10v2.5a1 1 0 0 0 1 1h9a1 1 0 0 0 1-1V10" />
			</svg>
			<input id="la-file" type="file" />
		</label>
		<p id="la-file-formats" class="la-muted la-file-formats"></p>
		<p id="la-file-name" class="la-muted la-file-name"></p>
		<p id="la-file-error" class="la-error" hidden></p>
	</div>
	<div id="la-text-mode-field" class="la-field" hidden>
		<label for="la-text-mode" data-i18n="layout_analysis.text_mode.label"></label>
		<select id="la-text-mode" data-i18n-option-prefix="layout_analysis.text_mode">
			<option value="typed"></option>
			<option value="final"></option>
			<option value="mixed"></option>
		</select>
		<p id="la-text-mode-info" class="la-muted"></p>
	</div>
	<p id="la-custom" class="la-field la-custom" hidden>
		<textarea
			id="la-text"
			rows="5"
			data-i18n-placeholder="layout_analysis.corpus.paste_placeholder"
		></textarea>
	</p>
	<details id="la-blend" class="la-section la-blend">
		<summary id="la-blend-name" data-i18n="layout_analysis.blend.title"></summary>
		<p id="la-blend-caption" class="la-muted" data-i18n="layout_analysis.blend.caption"></p>
		<fieldset class="la-blend-parts" aria-labelledby="la-blend-name" aria-describedby="la-blend-caption">
			<p class="la-blend-part">
				<label id="la-blend-corpus-label-0" for="la-blend-corpus-0"></label>
				<select id="la-blend-corpus-0"></select>
				<label id="la-blend-weight-label-0" for="la-blend-weight-0"></label>
				<input id="la-blend-weight-0" type="number" min="0" max="100" step="5" inputmode="numeric" />
			</p>
			<p class="la-blend-part">
				<label id="la-blend-corpus-label-1" for="la-blend-corpus-1"></label>
				<select id="la-blend-corpus-1"></select>
				<label id="la-blend-weight-label-1" for="la-blend-weight-1"></label>
				<input id="la-blend-weight-1" type="number" min="0" max="100" step="5" inputmode="numeric" />
			</p>
			<p class="la-blend-part">
				<label id="la-blend-corpus-label-2" for="la-blend-corpus-2"></label>
				<select id="la-blend-corpus-2"></select>
				<label id="la-blend-weight-label-2" for="la-blend-weight-2"></label>
				<input id="la-blend-weight-2" type="number" min="0" max="100" step="5" inputmode="numeric" />
			</p>
		</fieldset>
		<button id="la-blend-use" type="button" data-i18n-text="layout_analysis.blend.use"></button>
		<p id="la-blend-status" class="la-muted" role="status"></p>
	</details>
</section>

<section class="la-card la-options" aria-labelledby="la-options-label">
	<h2 id="la-options-label" class="la-card-title" data-i18n="layout_analysis.options.title"></h2>
	<div class="la-option-pair">
		<div class="la-field">
			<p class="la-heading">
				<label for="la-keyboard" data-i18n="layout_analysis.keyboard.label"></label>
				<button
					class="la-info"
					type="button"
					data-info="fingering"
					data-i18n-title="layout_analysis.info.button"
				>
					i
				</button>
			</p>
			<select id="la-keyboard" data-i18n-option-prefix="layout_analysis.keyboard"></select>
		</div>
		<p class="la-field">
			<label for="la-format" data-i18n="layout_analysis.format.label"></label>
			<select id="la-format" data-i18n-option-prefix="layout_analysis.format"></select>
		</p>
	</div>
</section>
</div>

<section class="la-card la-layouts" aria-labelledby="la-layouts-label">
	<h2 id="la-layouts-label" class="la-card-title" data-i18n="layout_analysis.layouts.label"></h2>
	<details id="la-layouts-box" class="la-layouts-box">
	<summary id="la-layouts-summary"></summary>
	<div class="la-row">
		<label class="la-filter-field la-pick-search" data-i18n-text="layout_analysis.layouts.search">
			<input
				id="la-filter"
				type="search"
				aria-describedby="la-pick-count"
				data-i18n-placeholder="layout_analysis.layouts.filter_placeholder"
			/>
		</label>
		<label class="la-filter-field" data-i18n-text="layout_analysis.filter.origin">
			<select id="la-pick-origin"></select>
		</label>
		<label class="la-filter-field" data-i18n-text="layout_analysis.filter.language">
			<select id="la-pick-language"></select>
		</label>
	</div>
	<p id="la-pick-count" class="la-pick-count" role="status" aria-live="polite"></p>
	<p class="la-row la-pick-actions">
		<button id="la-every" type="button" data-i18n="layout_analysis.layouts.every"></button>
		<button id="la-clear" type="button" data-i18n="layout_analysis.layouts.clear"></button>
		<button id="la-all" type="button" data-i18n="layout_analysis.layouts.all"></button>
		<button id="la-none" type="button" data-i18n="layout_analysis.layouts.none"></button>
	</p>
	<section id="la-add" class="la-add" aria-labelledby="la-add-title">
		<h3 id="la-add-title" class="la-add-title" data-i18n="layout_analysis.add.title"></h3>
		<p class="la-muted" data-i18n="layout_analysis.add.help"></p>
		<p id="la-drop" class="la-drop" data-i18n-text="layout_analysis.add.drop">
			<svg class="la-drop-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
				<path d="M12 3v12m0 0-5-5m5 5 5-5M4 17v3h16v-3" />
			</svg>
			<label class="la-file la-file-button" data-i18n-text="layout_analysis.add.file">
				<input id="la-import" type="file" />
			</label>
		</p>
		<label class="la-paste-label" for="la-paste" data-i18n="layout_analysis.add.paste_label"></label>
		<textarea id="la-paste" class="la-paste" rows="4" spellcheck="false" aria-describedby="la-paste-detected"></textarea>
		<p class="la-paste-actions">
			<output id="la-paste-detected" class="la-detected" for="la-paste" aria-live="polite"></output>
			<button id="la-paste-add" type="button" data-i18n="layout_analysis.add.paste_button"></button>
		</p>
	</section>
	<p id="la-import-report" class="la-import-report" role="status" hidden></p>
	<p id="la-mine-status" class="la-mine-status" role="status" hidden></p>
	<nav id="la-letters" class="la-letters"></nav>
	<div id="la-layout-list" class="la-layout-list"></div>
	</details>
</section>

<details id="la-settings" class="la-settings">
<summary data-i18n="layout_analysis.settings.title"></summary>
<section class="la-weights la-config la-accent-1" data-section-icon="config" aria-labelledby="la-config-label">
	<header class="la-heading">
		<h2 id="la-config-label" data-i18n="layout_analysis.config.title"></h2>
	</header>
	<p class="la-muted" data-i18n="layout_analysis.config.help"></p>
	<p class="la-config-actions">
		<button id="la-config-export" type="button" data-i18n="layout_analysis.config.export"></button>
		<label class="la-file la-file-button" data-i18n-text="layout_analysis.config.import">
			<input id="la-config-import" type="file" accept=".json,application/json" />
		</label>
		<button id="la-config-reset" type="button" data-i18n="layout_analysis.config.reset"></button>
	</p>
	<p id="la-config-status" class="la-muted" role="status"></p>
	<section class="la-presets" aria-labelledby="la-presets-title">
		<h3 id="la-presets-title" data-i18n="layout_analysis.presets.title"></h3>
		<p class="la-muted" data-i18n="layout_analysis.presets.help"></p>
		<ul id="la-preset-list" class="la-preset-list" aria-labelledby="la-presets-title"></ul>
		<h3 id="la-presets-mine-title" data-i18n="layout_analysis.presets.mine_title"></h3>
		<p id="la-preset-none" class="la-muted" data-i18n="layout_analysis.presets.none"></p>
		<ul id="la-preset-mine" class="la-preset-mine" aria-labelledby="la-presets-mine-title"></ul>
		<form id="la-preset-save" class="la-preset-save">
			<label for="la-preset-name" data-i18n="layout_analysis.presets.name_label"></label>
			<input id="la-preset-name" type="text" maxlength="60" autocomplete="off" />
			<button type="submit" data-i18n="layout_analysis.presets.save"></button>
		</form>
	</section>
</section>

<section class="la-weights la-accent-2" data-section-icon="weights" aria-labelledby="la-weights-label">
	<header class="la-heading">
		<h2 id="la-weights-label" data-i18n="layout_analysis.weights.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="weights"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</header>
	<p class="la-muted" data-i18n="layout_analysis.weights.help"></p>
	<button id="la-restore" type="button" data-i18n="layout_analysis.weights.restore"></button>
	<div id="la-weight-list" class="la-weight-groups"></div>
</section>

<section class="la-weights la-accent-3" data-section-icon="ideal" aria-labelledby="la-ideal-label">
	<header class="la-heading">
		<h2 id="la-ideal-label" data-i18n="layout_analysis.ideal.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="ideal_finger_load"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</header>
	<p class="la-muted" data-i18n="layout_analysis.ideal.help"></p>
	<button
		id="la-ideal-restore"
		type="button"
		data-i18n="layout_analysis.ideal.restore"
	></button>
	<div class="la-ideal-layout">
		<svg
			id="la-ideal-hands"
			class="la-ideal-hands"
			viewBox="0 0 220 120"
			aria-hidden="true"
			focusable="false"
		></svg>
		<ul id="la-ideal-list" class="la-weight-list"></ul>
	</div>
	<p id="la-ideal-sum" class="la-muted" role="status"></p>
</section>

<section class="la-weights la-accent-4" data-section-icon="shortcuts" aria-labelledby="la-shortcuts-label">
	<header class="la-heading">
		<h2 id="la-shortcuts-label" data-i18n="layout_analysis.shortcuts.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="shortcut_letters"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</header>
	<p class="la-muted" data-i18n="layout_analysis.shortcuts.help"></p>
	<button
		id="la-shortcuts-restore"
		type="button"
		data-i18n="layout_analysis.shortcuts.restore"
	></button>
	<h3 data-i18n="layout_analysis.shortcuts.letters"></h3>
	<ul id="la-shortcut-letters" class="la-weight-list"></ul>
	<h3 data-i18n="layout_analysis.shortcuts.ease"></h3>
	<ul id="la-shortcut-ease" class="la-weight-list"></ul>
	<p id="la-shortcuts-status" class="la-muted" role="status"></p>
</section>

<section class="la-weights la-accent-6" data-section-icon="forms" aria-labelledby="la-forms-label">
	<header class="la-heading">
		<h2 id="la-forms-label" data-i18n="layout_analysis.forms.title"></h2>
		<button
			class="la-info"
			type="button"
			data-info="compact_fit"
			data-i18n-title="layout_analysis.info.button"
		>
			i
		</button>
	</header>
	<p class="la-muted" data-i18n="layout_analysis.forms.help"></p>
	<button id="la-forms-restore" type="button" data-i18n="layout_analysis.forms.restore"></button>
	<ul id="la-form-list" class="la-weight-list"></ul>
	<p id="la-forms-status" class="la-muted" role="status"></p>
</section>

<section id="la-fingering" class="la-weights la-fingering"></section>
</details>
</section>

<section id="la-results" class="la-results" aria-labelledby="la-results-label">
	<h2 id="la-results-label" class="la-sr-only" data-i18n="layout_analysis.results.title"></h2>
	<p id="la-frame" class="la-heat-controls la-frame" hidden>
		<label class="la-filter-field" data-i18n-text="layout_analysis.frame.main">
			<select id="la-frame-main"></select>
		</label>
		<label class="la-filter-field" data-i18n-text="layout_analysis.frame.comp">
			<select id="la-frame-comp"></select>
		</label>
	</p>
	<details id="la-filters-box" class="la-filters-box">
	<summary>
		<b id="la-filters-label" class="la-filters-title" data-i18n="layout_analysis.filter.title"></b>
		<output id="la-table-count" class="la-muted la-table-count" role="status"></output>
	</summary>
	<fieldset class="la-filters">
		<legend class="la-sr-only" data-i18n="layout_analysis.filter.title"></legend>
		<label class="la-filter-field la-filter-name" data-i18n-text="layout_analysis.table.filter_name">
			<input id="la-row-name" type="search" />
		</label>
		<label class="la-filter-field" data-i18n-text="layout_analysis.table.filter_family">
			<select id="la-row-family"></select>
		</label>
		<label class="la-filter-field" data-i18n-text="layout_analysis.filter.origin">
			<select id="la-row-origin"></select>
		</label>
		<label class="la-filter-field" data-i18n-text="layout_analysis.filter.language">
			<select id="la-row-language"></select>
		</label>
		<label class="la-filter-field" data-i18n-text="layout_analysis.filter.complete">
			<select id="la-row-complete" data-i18n-option-prefix="layout_analysis.filter.complete_choice">
				<option value="all"></option>
				<option value="yes"></option>
				<option value="no"></option>
			</select>
		</label>
		<label class="la-filter-field la-filter-score" data-i18n-text="layout_analysis.table.score_min">
			<input id="la-row-min" type="number" step="any" />
		</label>
		<label class="la-filter-field la-filter-score" data-i18n-text="layout_analysis.table.score_max">
			<input id="la-row-max" type="number" step="any" />
		</label>
		<label class="la-filter-field la-filter-query" data-i18n-text="layout_analysis.filter.query">
			<input id="la-row-query" type="text" spellcheck="false" autocomplete="off" aria-describedby="la-row-query-hint la-row-query-status" />
		</label>
		<button id="la-table-reset" type="button" data-i18n="layout_analysis.table.reset"></button>
	</fieldset>
	<p id="la-row-query-hint" class="la-muted la-query-hint" data-i18n="layout_analysis.filter.query_hint"></p>
	<p id="la-row-query-status" class="la-query-status" role="status"></p>
	<details class="la-query-names">
		<summary id="la-query-names-title" data-i18n="layout_analysis.filter.query_names"></summary>
		<ul id="la-query-names" aria-labelledby="la-query-names-title"></ul>
	</details>
	</details>
	<details id="la-frame-diff" class="la-frame-diff" open hidden>
		<summary id="la-frame-diff-label"></summary>
		<p id="la-frame-diff-none" class="la-muted" data-i18n="layout_analysis.frame.diff_none"></p>
		<section id="la-frame-diff-wrap" class="la-table-wrap" tabindex="0" aria-labelledby="la-frame-diff-label">
			<table id="la-frame-diff-table" class="la-table"></table>
		</section>
	</details>

	<section id="la-panel-overview" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-overview">
		<div class="la-overview">
			<section class="la-figure" aria-labelledby="la-chart-label">
				<h3 id="la-chart-label" data-i18n="layout_analysis.chart.title"></h3>
				<p class="la-muted" data-i18n="layout_analysis.chart.caption"></p>
				<table id="la-chart" class="la-chart la-bars" role="table" aria-labelledby="la-chart-label"></table>
			</section>
			<section class="la-leaders-box" aria-labelledby="la-leaders-label">
				<h3 id="la-leaders-label" data-i18n="layout_analysis.leaders.title"></h3>
				<dl id="la-leaders" class="la-leaders"></dl>
			</section>
			<section class="la-figure la-figure-wide">
				<h3 id="la-ranking-label" data-i18n="layout_analysis.ranking.title"></h3>
				<details id="la-table-options" class="la-table-options">
					<summary id="la-table-columns" data-i18n="layout_analysis.table.columns"></summary>
					<fieldset id="la-column-list" class="la-column-list" aria-labelledby="la-table-columns"></fieldset>
				</details>
				<label id="la-table-relative-label" class="la-check">
					<input id="la-table-relative" type="checkbox" aria-describedby="la-table-relative-help" />
				</label>
				<p id="la-table-relative-help" class="la-muted" hidden></p>
				<div class="la-ranking-tools">
					<label class="la-check" data-i18n-text="layout_analysis.table.fold">
						<input id="la-table-fold" type="checkbox" aria-describedby="la-table-fold-help" />
					</label>
					<p id="la-table-fold-help" class="la-muted" data-i18n="layout_analysis.table.fold_help"></p>
					<button id="la-table-csv" class="la-csv-button" type="button" data-i18n-text="layout_analysis.table.csv">
						<svg class="la-row-icon" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
							<path d="M12 3v12m0 0-5-5m5 5 5-5M4 17v3h16v-3" />
						</svg>
					</button>
				</div>
				<p id="la-table-csv-status" class="la-muted" role="status"></p>
				<section class="la-table-wrap" tabindex="0" aria-labelledby="la-ranking-label">
					<table id="la-table" class="la-table"></table>
				</section>
			</section>
			<section class="la-figure la-figure-wide" aria-labelledby="la-ngrams-label">
				<h3 id="la-ngrams-label" data-i18n="layout_analysis.ngrams.title"></h3>
				<p id="la-ngrams-caption" class="la-muted"></p>
				<div class="la-ngrams-view">
					<div id="la-ngrams-board" class="la-heatmap la-ngrams-board" aria-hidden="true"></div>
					<div id="la-ngrams-list"></div>
				</div>
			</section>
		</div>
	</section>

	<section id="la-panel-fingers" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-fingers" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_fingers"></p>
		<section class="la-figure la-figure-wide">
			<h3 id="la-finger-table-label" data-i18n="layout_analysis.fingers.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.fingers.caption"></p>
			<ul class="la-legend">
				<li data-i18n-text="layout_analysis.fingers.over"><span class="la-swatch la-swatch-more" aria-hidden="true"></span></li>
				<li data-i18n-text="layout_analysis.fingers.under"><span class="la-swatch la-swatch-less" aria-hidden="true"></span></li>
			</ul>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-finger-table-label">
				<table id="la-finger-table" class="la-table la-heat-table"></table>
			</section>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-hands-label">
			<h3 id="la-hands-label" data-i18n="layout_analysis.hands.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.hands.caption"></p>
			<ul id="la-hands-legend" class="la-legend"></ul>
			<table id="la-hands" class="la-bars" aria-labelledby="la-hands-label" role="table"></table>
		</section>
		<div id="la-charts-fingers" class="la-chart-grid"></div>
	</section>

	<section id="la-panel-bigrams" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-bigrams" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_bigrams"></p>
		<div id="la-charts-bigrams" class="la-chart-grid"></div>
	</section>

	<section id="la-panel-trigrams" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-trigrams" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_trigrams"></p>
		<section class="la-figure la-figure-wide" aria-labelledby="la-trigram-mix-label">
			<h3 id="la-trigram-mix-label" data-i18n="layout_analysis.trigram_mix.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.trigram_mix.caption"></p>
			<div id="la-trigram-mix"></div>
		</section>
		<div id="la-charts-trigrams" class="la-chart-grid"></div>
	</section>

	<section id="la-panel-rows" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-rows" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_rows"></p>
		<section class="la-figure la-figure-wide" aria-labelledby="la-row-mix-label">
			<h3 id="la-row-mix-label" data-i18n="layout_analysis.row_mix.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.row_mix.caption"></p>
			<div id="la-row-mix"></div>
		</section>
		<section class="la-figure la-figure-wide">
			<h3 id="la-travel-table-label" data-i18n="layout_analysis.travel.title"></h3>
			<p class="la-muted" data-i18n="layout_analysis.travel.caption"></p>
			<p id="la-travel-legend" class="la-heat-legend"></p>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-travel-table-label">
				<table id="la-travel-table" class="la-table la-heat-table"></table>
			</section>
		</section>
		<div id="la-charts-rows" class="la-chart-grid"></div>
	</section>

	<section id="la-panel-heatmaps" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-heatmaps" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_heatmaps"></p>
		<p class="la-heat-controls">
			<label class="la-filter-field" data-i18n-text="layout_analysis.heats.metric">
				<select id="la-heats-metric"></select>
			</label>
			<label class="la-filter-field" data-i18n-text="layout_analysis.heats.count">
				<select id="la-heats-count"></select>
			</label>
			<label class="la-check" data-i18n-text="layout_analysis.heats.shared">
				<input id="la-heats-shared" type="checkbox" />
			</label>
			<label class="la-filter-field" data-i18n-text="layout_analysis.heat.level">
				<select id="la-heats-level"></select>
			</label>
		</p>
		<p id="la-heats-legend" class="la-heat-legend"></p>
		<div id="la-heats" class="la-heat-grid"></div>
	</section>

	<section id="la-panel-misc" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-misc" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.tab.intro_misc"></p>
		<div id="la-charts-misc" class="la-chart-grid"></div>
	</section>

	<section id="la-panel-pareto" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-pareto" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.pareto.intro"></p>
		<p class="la-heat-controls">
			<label class="la-filter-field" data-i18n-text="layout_analysis.pareto.x">
				<select id="la-pareto-x"></select>
			</label>
			<label class="la-filter-field" data-i18n-text="layout_analysis.pareto.y">
				<select id="la-pareto-y"></select>
			</label>
			<label class="la-check" data-i18n-text="layout_analysis.pareto.front_only">
				<input id="la-pareto-front" type="checkbox" />
			</label>
		</p>
		<p id="la-pareto-summary" class="la-muted"></p>
		<section class="la-figure la-figure-wide" aria-labelledby="la-pareto-chart-label">
			<h3 id="la-pareto-chart-label" data-i18n="layout_analysis.pareto.chart"></h3>
			<ul class="la-legend">
				<li data-i18n-text="layout_analysis.pareto.legend_front"><span class="la-swatch la-swatch-cat-1" aria-hidden="true"></span></li>
				<li data-i18n-text="layout_analysis.pareto.legend_other"><span class="la-swatch la-swatch-muted" aria-hidden="true"></span></li>
				<li data-i18n-text="layout_analysis.pareto.legend_details"><span class="la-swatch la-swatch-ring" aria-hidden="true"></span></li>
				<li data-i18n-text="layout_analysis.pareto.legend_versus"><span class="la-swatch la-swatch-versus" aria-hidden="true"></span></li>
			</ul>
			<div id="la-pareto-chart" class="la-pareto-chart"></div>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-pareto-spread-label">
			<h3 id="la-pareto-spread-label"></h3>
			<p id="la-pareto-spread-text" class="la-muted"></p>
			<div id="la-pareto-spread" class="la-pareto-chart"></div>
			<p id="la-pareto-quantiles-note" class="la-muted" data-i18n="layout_analysis.pareto.quantiles_note"></p>
			<h4 id="la-pareto-quantiles-label"></h4>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-pareto-quantiles-label">
				<table id="la-pareto-quantiles" class="la-table"></table>
			</section>
		</section>
		<section class="la-figure la-figure-wide">
			<h3 id="la-pareto-table-label" data-i18n="layout_analysis.pareto.table"></h3>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-pareto-table-label">
				<table id="la-pareto-table" class="la-table"></table>
			</section>
		</section>
	</section>

	<section id="la-panel-trace" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-trace" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.trace.intro"></p>
		<p class="la-field la-trace-field">
			<label for="la-trace-text" data-i18n="layout_analysis.trace.text"></label>
			<textarea id="la-trace-text" rows="3" maxlength="2000" aria-describedby="la-trace-note"></textarea>
		</p>
		<p id="la-trace-note" class="la-muted" data-i18n="layout_analysis.trace.note"></p>
		<div id="la-trace-out"></div>
	</section>

	<section id="la-panel-analysers" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-analysers" hidden>
		<section id="la-analysers" class="la-card" hidden></section>
	</section>

	<section id="la-panel-help" class="la-tab-panel la-help" role="tabpanel" aria-labelledby="la-tab-help" hidden>
		<p class="la-muted la-tab-intro" data-i18n="layout_analysis.help.intro"></p>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-compare">
			<h3 id="la-help-compare" data-i18n="layout_analysis.help.compare_title"></h3>
			<p data-i18n="layout_analysis.help.compare_text"></p>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-rank">
			<h3 id="la-help-rank" data-i18n="layout_analysis.help.rank_title"></h3>
			<p data-i18n="layout_analysis.help.rank_text"></p>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-pareto">
			<h3 id="la-help-pareto" data-i18n="layout_analysis.help.pareto_title"></h3>
			<p data-i18n="layout_analysis.help.pareto_text"></p>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-trace">
			<h3 id="la-help-trace" data-i18n="layout_analysis.help.trace_title"></h3>
			<p data-i18n="layout_analysis.help.trace_text"></p>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-words">
			<h3 id="la-help-words" data-i18n="layout_analysis.help.words_title"></h3>
			<p data-i18n="layout_analysis.help.words_text"></p>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-blend">
			<h3 id="la-help-blend" data-i18n="layout_analysis.help.blend_title"></h3>
			<p data-i18n="layout_analysis.help.blend_text"></p>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-share">
			<h3 id="la-help-share" data-i18n="layout_analysis.help.share_title"></h3>
			<p data-i18n="layout_analysis.help.share_text"></p>
		</section>
		<section class="la-figure la-figure-wide" aria-labelledby="la-help-metrics">
			<h3 id="la-help-metrics" data-i18n="layout_analysis.help.metrics_title"></h3>
			<p data-i18n="layout_analysis.help.metrics_text"></p>
			<p data-i18n="layout_analysis.help.metrics_syntax"></p>
		</section>
		<p class="la-muted" data-i18n="layout_analysis.help.credit"></p>
	</section>

	<section id="la-panel-details" class="la-tab-panel" role="tabpanel" aria-labelledby="la-tab-details" hidden>
	<p class="la-field la-details-pick">
		<label for="la-details-layout" data-i18n="layout_analysis.details.layout"></label>
		<select id="la-details-layout"></select>
	</p>
	<section id="la-details" class="la-details" hidden>
		<h2 id="la-details-title"></h2>
		<p class="la-muted">
			<small id="la-details-credit" class="la-details-credit"></small>
			<a id="la-details-link" target="_blank" rel="noopener" hidden></a>
		</p>
		<p class="la-field la-versus">
			<label for="la-versus" data-i18n="layout_analysis.details.versus"></label>
			<select id="la-versus"></select>
		</p>
		<div class="la-detail-grid">
			<section class="la-detail-main">
				<h3 data-i18n="layout_analysis.details.heatmap"></h3>
				<p class="la-heat-controls">
					<label class="la-sr-only" for="la-heat-metric" data-i18n="layout_analysis.details.heatmap"></label>
					<select id="la-heat-metric"></select>
					<label class="la-filter-field" data-i18n-text="layout_analysis.heat.level">
						<select id="la-heat-level"></select>
					</label>
					<label id="la-heat-diff-field" class="la-check" hidden>
						<input id="la-heat-diff" type="checkbox" />
					</label>
				</p>
				<div id="la-heatmap" class="la-heatmap"></div>
				<div id="la-heatmap-image"></div>
				<p id="la-heat-legend" class="la-heat-legend"></p>
				<details id="la-heat-table-box" class="la-section">
					<summary id="la-heat-table-name" data-i18n="layout_analysis.heat.table"></summary>
					<section class="la-table-wrap" tabindex="0" aria-labelledby="la-heat-table-name">
						<table id="la-heat-table" class="la-table"></table>
					</section>
				</details>
				<section class="la-detail-loads">
				<h3 id="la-fingers-label" data-i18n="layout_analysis.details.fingers"></h3>
				<p class="la-muted" data-i18n="layout_analysis.details.fingers_caption"></p>
				<ul class="la-legend">
					<li data-i18n-text="layout_analysis.details.share_mark"><span class="la-swatch la-swatch-load" aria-hidden="true"></span></li>
					<li data-i18n-text="layout_analysis.details.ideal_mark"><span class="la-swatch la-swatch-ideal" aria-hidden="true"></span></li>
				</ul>
				<table id="la-fingers" class="la-bars" aria-labelledby="la-fingers-label" role="table"></table>
				<h3 id="la-hands-rows-label" data-i18n="layout_analysis.details.hands_rows"></h3>
				<table id="la-hands-rows" class="la-bars" aria-labelledby="la-hands-rows-label" role="table"></table>
				</section>
			</section>
			<section>
				<h3 id="la-contributions-label" data-i18n="layout_analysis.details.contributions"></h3>
				<table id="la-contributions" class="la-bars" aria-labelledby="la-contributions-label" role="table"></table>
			</section>
		</div>
		<details class="la-section">
			<summary id="la-movement-name" data-i18n="layout_analysis.movement.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.movement.caption"></p>
			<p class="la-movement-rank">
				<button type="button" id="la-movement-rank" aria-describedby="la-movement-rank-note" data-i18n="layout_analysis.movement.rank"></button>
			</p>
			<p id="la-movement-rank-note" class="la-muted" data-i18n="layout_analysis.movement.rank_note"></p>
			<p id="la-movement-rank-status" class="la-muted" role="status"></p>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-movement-name">
				<table id="la-movement" class="la-table"></table>
			</section>
			<h4 id="la-rhythm-name" data-i18n="layout_analysis.movement.rhythm_title"></h4>
			<p class="la-muted" data-i18n="layout_analysis.movement.rhythm_caption"></p>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-rhythm-name">
				<table id="la-rhythm" class="la-table"></table>
			</section>
		</details>
		<details id="la-tap-holds-box" class="la-section" hidden>
			<summary id="la-tap-holds-name" data-i18n="layout_analysis.tap_hold.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.tap_hold.note"></p>
			<p id="la-tap-holds-summary" class="la-muted"></p>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-tap-holds-name">
				<table id="la-tap-holds" class="la-table"></table>
			</section>
		</details>
		<details id="la-user-metrics-box" class="la-section">
			<summary id="la-user-metrics-name" data-i18n="layout_analysis.user_metrics.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.user_metrics.caption"></p>
			<ol id="la-user-metrics-list" class="la-user-metrics-list"></ol>
			<p class="la-user-metrics-actions">
				<button type="button" id="la-user-metrics-add" data-i18n="layout_analysis.user_metrics.add"></button>
				<output id="la-user-metrics-full" class="la-muted"></output>
			</p>
			<details class="la-query-names">
				<summary id="la-user-metrics-names-title" data-i18n="layout_analysis.user_metrics.names"></summary>
				<ul id="la-user-metrics-names" aria-labelledby="la-user-metrics-names-title"></ul>
			</details>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-user-metrics-name">
				<table id="la-user-metrics" class="la-table"></table>
			</section>
			<p class="la-user-metrics-actions">
				<button type="button" id="la-user-metrics-all" data-i18n="layout_analysis.user_metrics.measure_all"></button>
			</p>
			<p id="la-user-metrics-status" class="la-muted" role="status"></p>
			<h4 id="la-user-metrics-all-name" data-i18n="layout_analysis.user_metrics.all_title" hidden></h4>
			<section id="la-user-metrics-all-wrap" class="la-table-wrap" tabindex="0" aria-labelledby="la-user-metrics-all-name" hidden>
				<table id="la-user-metrics-ranking" class="la-table"></table>
			</section>
		</details>
		<details class="la-section">
			<summary id="la-worst-name" data-i18n="layout_analysis.worst.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.worst.caption"></p>
			<label for="la-worst-event" data-i18n="layout_analysis.worst.event"></label>
			<select id="la-worst-event"></select>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-worst-name">
				<table id="la-worst" class="la-table"></table>
			</section>
		</details>
		<details class="la-section">
			<summary data-i18n="layout_analysis.matrix.title"></summary>
			<p id="la-matrix-caption" class="la-muted"></p>
			<label for="la-matrix-by" data-i18n="layout_analysis.matrix.by"></label>
			<select id="la-matrix-by"></select>
			<p id="la-matrix-legend" class="la-heat-legend"></p>
			<section class="la-matrix-wrap" tabindex="0" aria-labelledby="la-matrix-caption">
				<table id="la-matrix" class="la-matrix"></table>
			</section>
			<h4 id="la-matrix-pairs-name" data-i18n="layout_analysis.matrix.table"></h4>
			<p id="la-matrix-count" class="la-muted"></p>
			<section class="la-table-wrap" tabindex="0" aria-labelledby="la-matrix-pairs-name">
				<table id="la-matrix-pairs" class="la-table"></table>
			</section>
		</details>
		<details class="la-section">
			<summary data-i18n="layout_analysis.words.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.words.caption"></p>
			<p id="la-words-none" class="la-muted" data-i18n="layout_analysis.words.none" hidden></p>
			<section id="la-words-body">
				<p id="la-words-mean" class="la-muted"></p>
				<h4 id="la-words-bins-label" data-i18n="layout_analysis.words.distribution"></h4>
				<table id="la-words-bins" class="la-bars" aria-labelledby="la-words-bins-label" role="table"></table>
				<h4 id="la-words-name" data-i18n="layout_analysis.words.hardest"></h4>
				<section class="la-table-wrap" tabindex="0" aria-labelledby="la-words-name">
					<table id="la-words" class="la-table"></table>
				</section>
			</section>
		</details>
		<details class="la-section">
			<summary data-i18n="layout_analysis.classes.title"></summary>
			<h4 id="la-bigram-classes-label" data-i18n="layout_analysis.classes.bigrams"></h4>
			<table id="la-bigram-classes" class="la-bars" aria-labelledby="la-bigram-classes-label" role="table"></table>
			<h4 id="la-trigram-classes-label" data-i18n="layout_analysis.classes.trigrams"></h4>
			<table id="la-trigram-classes" class="la-bars" aria-labelledby="la-trigram-classes-label" role="table"></table>
		</details>
		<details class="la-section">
			<summary id="la-travel-label" data-i18n="layout_analysis.travel.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.travel.caption"></p>
			<table id="la-travel" class="la-bars" aria-labelledby="la-travel-label" role="table"></table>
		</details>
		<details class="la-section">
			<summary id="la-layers-label" data-i18n="layout_analysis.layers.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.layers.caption"></p>
			<table id="la-layers" class="la-bars" aria-labelledby="la-layers-label" role="table"></table>
		</details>
		<details class="la-section">
			<summary id="la-standing-label" data-i18n="layout_analysis.standing.title"></summary>
			<p class="la-muted" data-i18n="layout_analysis.standing.caption"></p>
			<table id="la-standing" class="la-bars" aria-labelledby="la-standing-label" role="table"></table>
		</details>
		<h3 id="la-metrics-name" data-i18n="layout_analysis.details.metrics"></h3>
		<section class="la-table-wrap" tabindex="0" aria-labelledby="la-metrics-name">
			<table id="la-metrics" class="la-table"></table>
		</section>
		<p id="la-unsupported" class="la-muted"></p>
		<div class="la-detail-grid">
			<section>
				<h3 id="la-typing-name" data-i18n="layout_analysis.details.typing"></h3>
				<p id="la-typing-caption" class="la-muted"></p>
				<section class="la-table-wrap" tabindex="0" aria-labelledby="la-typing-name">
					<table id="la-typing" class="la-table"></table>
				</section>
			</section>
			<section>
				<h3 data-i18n="layout_analysis.details.simplicity"></h3>
				<table id="la-simplicity" class="la-table"></table>
			</section>
		</div>
	</section>
	</section>
</section>`;

	/**
	 * The « My typing » read as the Comparer lists it: none when the user has no
	 * keystats store yet.
	 * @param {{state: string, reason?: string}} detail
	 * @returns {{state: string, reason: string}|null}
	 */
	function readingState(detail) {
		if (!detail || (detail.state !== 'loading' && detail.state !== 'failed')) return null;
		return { state: detail.state, reason: String(detail.reason || '') };
	}

	let mounted = null;
	// The app's last keystats tables, kept when they arrive before the mount.
	let lastNgrams = null;
	// The app's keystats read: null (none: the site, or no store yet), else
	// { state: 'loading' | 'failed', reason }.
	let myTypingState = null;

	/**
	 * Mounts the Comparer into an element: the site's page mounts it into its
	 * <main>, the app's Studio window into its « Comparer » tab.
	 * @param {HTMLElement} root - The element the Comparer fills.
	 * @param {{host?: object, reportHeight?: boolean}} [options] - host: the
	 *   LAYOUT_ANALYSIS_HOST contract (window.LAYOUT_ANALYSIS_HOST when absent);
	 *   reportHeight: post the page height to a framing parent (the site).
	 * @returns {{setCorpus: function, addLayouts: function, compare: function, setFormat: function, onResults: function}}
	 * @throws {Error} On a missing root or a second mount.
	 */
	function mount(root, options) {
		if (!root || typeof root.append !== 'function')
			throw new Error('layout_analysis: mount needs an element');
		if (mounted) throw new Error('layout_analysis: the Comparer is already mounted');
		const opts = options || {};
		const HOST = opts.host || window.LAYOUT_ANALYSIS_HOST || {};
		root.classList.add('layout-analysis');
		// A constant of this script, no user data: safe as markup.
		root.innerHTML = MARKUP;

		// ============================
		// ======= 1/ Helpers =========
		// ============================

		/** Translates a locale key (info_popover.js t(): numbers as every number shown). */
		const t = INFO.t;

		/** Creates an element with a class and optional text. */
		function el(tag, className, text) {
			const node = document.createElement(tag);
			if (className) node.className = className;
			if (text !== undefined) node.textContent = text;
			return node;
		}

		const $ = (id) => document.getElementById(id);
		// Every number in the language of the page's strings (info_popover.js).
		const format = INFO.format;
		// A number and its unit, tied by a no-break space (info_popover.js).
		const measure = INFO.measure;
		const withUnit = INFO.withUnit;
		const metricDigits = E.metricDigits;

		/** Reads the saved conveniences; an unavailable storage gives none. */
		function loadSaved() {
			try {
				const raw = window.localStorage.getItem(STORAGE_KEY);
				return raw ? JSON.parse(raw) : {};
			} catch {
				return {};
			}
		}

		/** Saves the conveniences; an unavailable or full storage keeps none. */
		function save() {
			// Which preset the settings now match (a weight edited by hand matches none);
			// a preset's name field being edited is left as it is.
			if (presetsReady && state.presetRenaming === null) fillPresets();
			try {
				window.localStorage.setItem(
					STORAGE_KEY,
					JSON.stringify({
						corpus: state.corpus,
						keyboard: state.keyboard,
						// Until the visitor ticks a layout, a link's selection is not theirs to keep.
						selected: state.linkedSelection ? saved.selected : Array.from(state.selected),
						selectionChosen: state.linkedSelection ? saved.selectionChosen : state.selectionChosen,
						weights: state.weights,
						floors: state.floors,
						grades: state.grades,
						idealLoad: state.idealLoad,
						shortcuts: state.shortcuts,
						formWeights: state.formWeights,
						custom: state.custom,
						textMode: state.textMode,
						plus: Array.from(state.plus),
						imported,
						// The ranking table's columns and filters, and the heatmap's choice.
						table: state.table,
						heat: state.heat,
						heatLevel: state.heatLevel,
						heatDiff: state.heatDiff,
						matrixBy: state.matrixBy,
						// The sub-tab the visitor last chose, the side-by-side heat maps'
						// choices and the layout list's filters.
						tab: state.tabSaved,
						heats: state.heats,
						pareto: state.pareto,
						blend: state.blendRecipe,
						traceText: state.trace.text,
						userMetrics: state.userMetrics,
						// The user's own score presets, each a score settings file and its name.
						presets: state.presets,
						pick: state.pick
					})
				);
				// The editor's panel and the optimizer of this page score with them too.
				SCORE_SETTINGS.notify();
			} catch {
				// A private window or a full quota: the page keeps working unsaved.
			}
			// Every change of the score settings or the layout list passes here.
			if (historyStarted) history.record();
		}

		// ==========================
		// ======= 2/ State =========
		// ==========================

		const saved = loadSaved();
		// Layouts the user imported from files, kept with the other conveniences.
		const imported = Array.isArray(saved.imported) ? saved.imported.filter(isLayout) : [];
		// The layouts the user keeps (imported here, in the host's store or this
		// browser's storage): the ones « Rename », « Duplicate » and « Remove » manage.
		const own = new Set(imported.map((layout) => layout.id));
		// Whether the presets' lists are drawn (wirePresets), so a save can mark the one in use.
		let presetsReady = false;
		const layouts = E.libraryLayouts()
			.concat((HOST.layouts || []).map(E.layoutFromRows))
			.concat(imported.map(E.layoutFromRows));
		const byId = new Map(layouts.map((layout) => [layout.id, layout]));

		/**
		 * The layouts ticked until the user chooses: every layout the page lists
		 * (maintainer, 2026-11-18, after the registry and reference ones of
		 * 2026-11-15), but of a family that ships one layout per board (Ergopti
		 * and Ergopti ANSI) only the one of the chosen keyboard's geometry; the
		 * other stays listed, unticked. A board with no row-staggered geometry
		 * (split, ortholinear) takes ISO's. The page scores them by slices
		 * (ANALYSE_SLICE), so the whole library keeps it responsive.
		 * @param {string} keyboard A model keyboard id.
		 * @returns {Set<string>} The ids to tick.
		 */
		function defaultSelection(keyboard) {
			const spec = DATA.model.keyboards[keyboard];
			// A JIS or ABNT board takes the layouts made for ISO (its layout_geometry).
			const geometry = spec.layout_geometry || spec.geometry || 'iso';
			const otherBoard = (layout) =>
				layout.geometry !== '' &&
				layout.geometry !== geometry &&
				layouts.some((other) => other.family === layout.family && other.geometry === geometry);
			return new Set(layouts.filter((l) => !otherBoard(l)).map((l) => l.id));
		}
		const corpora = (HOST.corpora || [])
			.map((corpus) => ({ id: corpus.id, title: corpus.title, host: corpus }))
			.concat(
				DATA.corpora.map((corpus) => ({ id: corpus.id, title: corpus.title, builtin: corpus }))
			)
			.concat([{ id: CUSTOM_ID }]);
		const linked = linkedChoices(corpora);
		// A saved blend may mix the user's own texts still listed at start.
		const savedBlendAccepts = {
			own: true,
			custom: Boolean(saved.custom && saved.custom.tables)
		};
		/**
		 * The stored user metrics, each {id, name, window, query} with a window
		 * the engine knows, at most E.WINDOW_MAX_METRICS; the examples when none
		 * was stored (an empty list stored stays empty).
		 */
		function savedUserMetrics(stored) {
			// An example keeps no name of its own: it is named in the page's language.
			if (!Array.isArray(stored))
				return USER_METRIC_EXAMPLES.map((example, index) => ({
					id: `m${index + 1}`,
					name: '',
					example: example.key,
					window: example.window,
					query: example.query
				}));
			const ids = new Set();
			return stored
				.filter(
					(m) =>
						m &&
						typeof m.id === 'string' &&
						!ids.has(m.id) &&
						ids.add(m.id) &&
						typeof m.name === 'string' &&
						typeof m.query === 'string' &&
						E.WINDOW_KINDS.includes(m.window)
				)
				.slice(0, E.WINDOW_MAX_METRICS)
				.map(({ id, name, example, window, query }) =>
					USER_METRIC_EXAMPLES.some((e) => e.key === example)
						? { id, name, example, window, query }
						: { id, name, window, query }
				);
		}

		const state = {
			corpus:
				linked.corpus ||
				(corpora.some((c) => c.id === saved.corpus) ? saved.corpus : corpora[0].id),
			keyboard: linked.keyboard || (DATA.model.keyboards[saved.keyboard] ? saved.keyboard : 'iso'),
			// The keyboard format (the editor's « Format » too, one stored choice for the
			// Studio's two tabs): compact_fit measures on it.
			format:
				linked.format ||
				(E.keyboardFormats().some((f) => f.id === window.LAYOUT_ANALYSIS_FILES.savedFormat())
					? window.LAYOUT_ANALYSIS_FILES.savedFormat()
					: E.defaultKeyboardFormat()),
			// The id of the own layout whose name is being edited in the list, if any.
			renaming: null,
			// The user's score presets: {name, config}, config a score settings file.
			presets: Array.isArray(saved.presets)
				? saved.presets.filter(
						(p) => p && typeof p.name === 'string' && p.name.trim() !== '' && p.config
					)
				: [],
			// The index of the user preset whose name is being edited, if any.
			presetRenaming: null,
			// Whether the user chose the ticked layouts; until then they follow the keyboard.
			selectionChosen: saved.selectionChosen === true && Array.isArray(saved.selected),
			selected: null,
			// The weights, ideal load, shortcut table (shortcut_left) and form factor
			// weights (compact_fit), read as every Studio score reads them.
			...SCORE_SETTINGS.parse(saved),
			custom: saved.custom && saved.custom.tables ? saved.custom : null,
			// Which text each layout types, and the layouts ticked « + » (TEXT_MIXED).
			textMode: TEXT_MODES.includes(saved.textMode) ? saved.textMode : TEXT_TYPED,
			plus: new Set(Array.isArray(saved.plus) ? saved.plus : []),
			tables: null,
			// The keys typed, which the « + » layouts type in TEXT_MIXED; null otherwise.
			rawTables: null,
			results: [],
			sort: { key: 'rank', descending: false },
			table: validTable(saved.table),
			heat: HEAT_CHOICES.includes(saved.heat) ? saved.heat : HEAT_PRESSES,
			// The level the details' board shows; one no compared layout has shows the base.
			heatLevel: typeof saved.heatLevel === 'string' ? saved.heatLevel : LEVEL_BASE,
			// With a layout to compare with, the heatmap shows the key-by-key difference.
			heatDiff: saved.heatDiff === true,
			// The key pair matrix's colour (how often, or score points) and its table's sort.
			matrixBy: MATRIX_CHOICES.includes(saved.matrixBy) ? saved.matrixBy : MATRIX_COUNT,
			matrixSort: { key: 'count', descending: true },
			// The chosen corpus's word table (word → count), null when it has none.
			words: null,
			details: linked.details || null,
			// The layout the details compare with (diff), null for none.
			versus: linked.versus || null,
			// The sub-tab shown: a link's layout in detail opens « One layout »,
			// else the visitor's last choice (tabSaved, kept only when they click).
			tab: linked.tab
				? linked.tab
				: linked.details
					? DETAILS_TAB
					: linked.corpus || linked.layouts
						? DEFAULT_TAB
						: TABS.includes(saved.tab)
							? saved.tab
							: HOME_TAB,
			tabSaved: TABS.includes(saved.tab) ? saved.tab : HOME_TAB,
			// Each themed table's sort, by table name.
			tabSorts: {},
			heats: validHeats(saved.heats),
			pick: validFilters(saved.pick, ['origin', 'language']),
			// The last blend's recipe ([{id, weight}]), rebuilt at start when it was
			// the corpus compared or a link names it.
			blendRecipe: linked.blend || validBlend(saved.blend, corpora, savedBlendAccepts),
			restoreBlend:
				Boolean(linked.blend) ||
				(saved.corpus === BLEND_ID && Boolean(validBlend(saved.blend, corpora, savedBlendAccepts))),
			// The Pareto tab's two values and whether it shows the frontier only.
			pareto: validPareto(
				linked.px || linked.py
					? Object.assign(
							{},
							saved.pareto,
							linked.px ? { x: linked.px } : {},
							linked.py ? { y: linked.py } : {}
						)
					: saved.pareto
			),
			// The trace tab's text (null: the sample) and its two layouts.
			// The trace's text; its layouts are the frame's (state.details, state.versus).
			trace: {
				text:
					linked.text !== undefined
						? linked.text
						: typeof saved.traceText === 'string'
							? saved.traceText
							: null
			},
			// The visitor's own metrics over key windows, kept on this device.
			userMetrics: savedUserMetrics(saved.userMetrics)
		};
		// A link's layouts are shown, not saved: the visitor's own choice stays.
		state.linkedSelection = Boolean(linked.layouts);
		if (linked.layouts) {
			state.selected = new Set(linked.layouts);
			state.selectionChosen = true;
		} else {
			state.selected = state.selectionChosen
				? new Set(saved.selected.filter((id) => byId.has(id)))
				: defaultSelection(state.keyboard);
		}
		if (HOST.corpora && HOST.corpora.length > 0 && saved.corpus === undefined && !linked.corpus)
			state.corpus = HOST.corpora[0].id;

		// ==================================
		// ======= 2b/ Undo history =========
		// ==================================

		// Every change of the score settings (weights, floors, ideal load, shortcut
		// letters, keyboard forms, presets, fingering, corpus, keyboard, format) and
		// of the layout list (the ticked layouts and their « + ») is one step of
		// the page's history (maintainer, 2026-11-21, edit_history.js). The own
		// layouts' Rename, Duplicate and Remove keep their own store and « Undo ».
		const HISTORY_PARTS = [
			['layouts', ['selected', 'selectionChosen', 'plus']],
			['weights', ['weights', 'floors']],
			['ideal_load', ['idealLoad']],
			['shortcut_letters', ['shortcuts']],
			['keyboard_forms', ['formWeights']],
			['corpus', ['corpus']],
			['text_mode', ['textMode']],
			['keyboard', ['keyboard']],
			['format', ['format']],
			['presets', ['presets']],
			['fingering', ['fingering']]
		];
		// Each part's step name, a literal key (test-studio-edit-history.cjs).
		const HISTORY_STEPS = {
			layouts: 'edit_history.step.layouts',
			weights: 'edit_history.step.weights',
			ideal_load: 'edit_history.step.ideal_load',
			shortcut_letters: 'edit_history.step.shortcut_letters',
			keyboard_forms: 'edit_history.step.keyboard_forms',
			corpus: 'edit_history.step.corpus',
			text_mode: 'edit_history.step.text_mode',
			keyboard: 'edit_history.step.keyboard',
			format: 'edit_history.step.format',
			presets: 'edit_history.step.presets',
			fingering: 'edit_history.step.fingering'
		};
		let historyStarted = false;
		let historyControls = null;
		const history = window.ERGOPTI_EDIT_HISTORY.track({
			capture: () => ({
				selected: Array.from(state.selected).sort(),
				selectionChosen: state.selectionChosen,
				plus: Array.from(state.plus).sort(),
				weights: state.weights,
				floors: state.floors,
				idealLoad: state.idealLoad,
				shortcuts: state.shortcuts,
				formWeights: state.formWeights,
				corpus: state.corpus,
				textMode: state.textMode,
				keyboard: state.keyboard,
				format: state.format,
				presets: state.presets,
				fingering: FINGERING.snapshot()
			}),
			apply: applyHistory,
			describe: (before, after) => {
				const changed = HISTORY_PARTS.filter(([, fields]) =>
					fields.some((field) => JSON.stringify(before[field]) !== JSON.stringify(after[field]))
				);
				return {
					key: changed.length === 1 ? HISTORY_STEPS[changed[0][0]] : 'edit_history.step.settings'
				};
			},
			onChange: () => {
				if (historyControls) historyControls.refresh();
			}
		});

		/**
		 * Puts a captured state of the history back: the score settings, the
		 * fingering, the corpus, keyboard and format, and the ticked layouts.
		 * @param {object} next - A capture of the history.
		 */
		function applyHistory(next) {
			for (const part of [
				'weights',
				'floors',
				'idealLoad',
				'shortcuts',
				'formWeights',
				'corpus',
				'textMode',
				'keyboard',
				'presets',
				'selectionChosen'
			])
				state[part] = next[part];
			state.selected = new Set(next.selected);
			state.plus = new Set(next.plus);
			// The ticked layouts are the visitor's own once they move through the history.
			state.linkedSelection = false;
			if (JSON.stringify(FINGERING.snapshot()) !== JSON.stringify(next.fingering))
				FINGERING.restore(next.fingering);
			$('la-corpus').value = state.corpus;
			$('la-text-mode').value = state.textMode;
			$('la-keyboard').value = state.keyboard;
			showCorpusInfo();
			showTextMode();
			fingeringView.draw();
			setFormat(next.format);
			fillLayouts();
			applyScoreSettings();
		}

		/**
		 * The corpus, keyboard and keyboard format a link asks for
		 * (?corpus=&keyboard=&format=), each only when the page knows it; the
		 * ticked layouts stay the visitor's (selectionChosen) or the keyboard's.
		 * @returns {{corpus?: string, keyboard?: string, format?: string}}
		 */
		function linkedChoices(known) {
			const query = new URLSearchParams(location.search);
			const out = {};
			const corpus = query.get('corpus');
			if (corpus !== null) {
				if (known.some((c) => c.id === corpus && c.id !== CUSTOM_ID)) out.corpus = corpus;
				else console.warn(`layout comparer: the link names no built-in corpus ${corpus}`);
			}
			const keyboard = query.get('keyboard');
			if (keyboard !== null) {
				if (DATA.model.keyboards[keyboard]) out.keyboard = keyboard;
				else console.warn(`layout comparer: the link names no keyboard ${keyboard}`);
			}
			const format = query.get('format');
			if (format !== null) {
				if (E.keyboardFormats().some((f) => f.id === format)) out.format = format;
				else console.warn(`layout comparer: the link names no keyboard format ${format}`);
			}
			// The compared layouts, the one shown in detail and the one it is compared with.
			const named = query.get('layouts');
			if (named !== null) {
				const ids = named.split(',').filter((id) => id !== '');
				for (const id of ids)
					if (!byId.has(id)) console.warn(`layout comparer: the link names no layout ${id}`);
				const kept = ids.filter((id) => byId.has(id));
				if (kept.length > 0) out.layouts = kept;
			}
			for (const name of ['details', 'versus']) {
				const id = query.get(name);
				if (id === null) continue;
				if (byId.has(id)) out[name] = id;
				else console.warn(`layout comparer: the link names no layout ${id} (${name})`);
			}
			// The tab shown, the Pareto tab's two values and the trace's text.
			const tab = query.get('tab');
			if (tab !== null) {
				if (TABS.includes(tab)) out.tab = tab;
				else console.warn(`layout comparer: the link names no tab ${tab}`);
			}
			for (const name of ['px', 'py']) {
				const id = query.get(name);
				if (id === null) continue;
				if (paretoChoices().includes(id)) out[name] = id;
				else console.warn(`layout comparer: the link names no Pareto value ${id} (${name})`);
			}
			// A blend's recipe: « id:weight » parts, each a built-in corpus.
			const blend = query.get('blend');
			if (blend !== null) {
				const recipe = validBlend(
					blend.split(',').map((part) => {
						const [id, weight] = part.split(':');
						return { id, weight: Number(weight) };
					}),
					known,
					{ own: false }
				);
				if (recipe) out.blend = recipe;
				else console.warn(`layout comparer: the link's blend ${blend} does not read`);
			}
			const text = query.get('text');
			if (text !== null) {
				if (Array.from(text).length <= E.TRACE_MAX_CHARS) out.text = text;
				else console.warn('layout comparer: the link’s trace text is too long');
			}
			return out;
		}

		/** Whether a saved value still reads as a layout. */
		function isLayout(value) {
			try {
				E.layoutFromRows(value);
				return true;
			} catch {
				return false;
			}
		}

		/**
		 * The ranking table's saved columns (metric ids the engine still has, the
		 * default set when none) and row filters (a name, a family, a score range).
		 */
		function validTable(table) {
			const value = table && typeof table === 'object' ? table : {};
			const columns = Array.isArray(value.columns)
				? value.columns.filter((id) => id in E.METRICS)
				: TABLE_METRICS.slice();
			const bound = (v) => (typeof v === 'number' && Number.isFinite(v) ? v : null);
			const text = (v) => (typeof v === 'string' ? v : ALL);
			return {
				columns,
				name: text(value.name),
				family: text(value.family),
				origin: text(value.origin),
				language: text(value.language),
				complete: COMPLETE_CHOICES.includes(value.complete) ? value.complete : COMPLETE_CHOICES[0],
				min: bound(value.min),
				max: bound(value.max),
				// The values query (« sfb < 1.2 & complete »), '' for none.
				query: typeof value.query === 'string' ? value.query : '',
				// The relative view: each value as its difference to the reference layout.
				relative: value.relative === true,
				// Families folded to their best member, and the layouts pinned to the top.
				fold: value.fold === true,
				pins: Array.isArray(value.pins)
					? Array.from(new Set(value.pins.filter((id) => typeof id === 'string')))
					: []
			};
		}

		/** The saved choices of the side-by-side heat maps, the defaults otherwise. */
		function validHeats(heats) {
			const value = heats && typeof heats === 'object' ? heats : {};
			return {
				metric: HEAT_CHOICES.includes(value.metric) ? value.metric : HEAT_PRESSES,
				count: HEATS_COUNTS.includes(value.count) ? value.count : DEFAULT_HEATS_COUNT,
				shared: value.shared !== false,
				level: typeof value.level === 'string' ? value.level : LEVEL_BASE
			};
		}

		/** The values the Pareto tab offers: the mark, then every metric the score weighs one way. */
		function paretoChoices() {
			return [PARETO_MARK].concat(
				Object.keys(E.METRICS).filter((id) => E.METRICS[id].better !== 'none')
			);
		}

		/**
		 * Whether a corpus can be a part of a blend: a built-in corpus, or one of
		 * the user's own texts with its tables (a loaded file, « My typing » once
		 * read, the pasted text when there is one), never a blend.
		 * @param {object} corpus - An entry of the corpus list.
		 * @param {boolean} custom - Whether the pasted text has tables.
		 */
		function blendable(corpus, custom) {
			if (corpus.builtin) return true;
			if (corpus.id === BLEND_ID) return false;
			return corpus.id === CUSTOM_ID ? custom : Boolean(corpus.host);
		}

		/**
		 * A blend's recipe as saved or linked: one to BLEND_PARTS parts, each a
		 * corpus of the list and a weight ≥ 0, one at least above 0; null
		 * otherwise. A link's parts are built-in corpora only (own: false); a
		 * saved recipe may name the user's own texts still in the list.
		 * @param {{own: boolean, custom?: boolean}} accepts - Whether own texts are
		 *   parts, and whether the pasted text has tables.
		 */
		function validBlend(recipe, known, accepts) {
			if (!Array.isArray(recipe) || recipe.length === 0 || recipe.length > BLEND_PARTS) return null;
			const usable = (c) =>
				accepts.own ? blendable(c, accepts.custom === true) : Boolean(c.builtin);
			const ok = recipe.every(
				(part) =>
					part &&
					known.some((c) => c.id === part.id && usable(c)) &&
					Number.isFinite(part.weight) &&
					part.weight >= 0
			);
			if (!ok || !recipe.some((part) => part.weight > 0)) return null;
			return recipe.map((part) => ({ id: part.id, weight: part.weight }));
		}

		/** The saved Pareto choices; an unknown value takes the default. */
		function validPareto(pareto) {
			const value = pareto && typeof pareto === 'object' ? pareto : {};
			const choices = paretoChoices();
			const x = choices.includes(value.x) ? value.x : PARETO_DEFAULT.x;
			const y = choices.includes(value.y) && value.y !== x ? value.y : PARETO_DEFAULT.y;
			return {
				x,
				y: y === x ? choices.find((id) => id !== x) : y,
				frontOnly: value.frontOnly === true
			};
		}

		/** Saved filter values (strings) by name; a missing one keeps everything. */
		function validFilters(filters, names) {
			const value = filters && typeof filters === 'object' ? filters : {};
			return Object.fromEntries(
				names.map((name) => [name, typeof value[name] === 'string' ? value[name] : ALL])
			);
		}

		// ==========================
		// ======= 3/ Corpora =======
		// ==========================

		/**
		 * The final-text tables of a corpus that brings two texts (« My typing »
		 * since schema 2: the keys typed at the top level, the final text under
		 * `final`), or null for a corpus of one text. A built-in corpus is a
		 * book's n-gram tables: no keys were typed for it, and the Ergopti+
		 * hotstrings cannot be undone at n-gram level (an abbreviation replaces
		 * whole words, which character trigrams do not delimit), so it has one.
		 */
		function finalTables(corpus) {
			return corpus && corpus.host && corpus.host.tables.final ? corpus.host.tables.final : null;
		}

		/** Whether the chosen corpus tells the keys typed from the final text. */
		function hasTwoTexts() {
			return Boolean(finalTables(corpora.find((c) => c.id === state.corpus)));
		}

		/**
		 * The prepared tables of the chosen corpus by the text mode: `plain`, the
		 * text every layout types (null when the corpus has none yet), and `raw`,
		 * the keys typed that the layouts ticked « + » type (TEXT_MIXED on a
		 * corpus of two texts; null otherwise).
		 * @returns {Promise<{plain: object|null, raw: object|null}>}
		 */
		async function corpusTables() {
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus.host) {
				const plain = window.LAYOUT_ANALYSIS_FILES.plainTables(
					corpus.host.tables,
					appliedTextMode()
				);
				return {
					plain: E.prepareNgrams(plain),
					raw:
						finalTables(corpus) && appliedTextMode() === TEXT_MIXED
							? E.prepareNgrams(corpus.host.tables)
							: null
				};
			}
			if (corpus.builtin) {
				return {
					plain: E.prepareNgrams(await window.LAYOUT_ANALYSIS_FILES.builtinTables(corpus.builtin)),
					raw: null
				};
			}
			return { plain: state.custom ? E.prepareNgrams(state.custom.tables) : null, raw: null };
		}

		/**
		 * The chosen corpus's word table, once its tables are loaded: a built-in
		 * corpus's (shipped with its n-grams), a host's when it sends one, the
		 * user's text's; null for a corpus of letter counts only (count tables,
		 * the keystats).
		 */
		function corpusWords() {
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus.host) return corpus.host.tables.words || null;
			if (corpus.builtin) {
				const raw = (window.LAYOUT_ANALYSIS_CORPORA || {})[corpus.id];
				return (raw && raw.words) || null;
			}
			return (state.custom && state.custom.words) || null;
		}

		/** Reduces the user's text to tables and its word table, once per distinct text. */
		function useText(text) {
			const trimmed = text.trim();
			if (trimmed === '') {
				state.custom = null;
			} else {
				const hash = E.hashText(trimmed);
				// A text saved before its analysers' own counts (genkey's and
				// Oxeylyzer's skipgrams of every gap) is counted again.
				if (
					!state.custom ||
					state.custom.hash !== hash ||
					!state.custom.words ||
					!state.custom.tables.analysers
				)
					state.custom = {
						hash,
						tables: Object.assign(E.ngramsFromText(trimmed), {
							analysers: window.LAYOUT_ANALYSER_SCORES.textTables(trimmed)
						}),
						words: E.wordsFromText(trimmed)
					};
			}
			// The pasted text is a part a blend can mix from now on, or no longer.
			fillBlend();
			save();
			analyse();
		}

		// ==========================
		// ======= 4/ Analysis ======
		// ==========================

		/** The options every analysis of the page uses: board, format, weights and tables. */
		function analysisOptions() {
			return {
				keyboard: state.keyboard,
				format: state.format,
				weights: state.weights,
				floors: state.floors,
				grades: state.grades,
				idealLoad: state.idealLoad,
				shortcuts: state.shortcuts,
				formWeights: state.formWeights,
				profile: FINGERING.current(state.keyboard) || undefined
			};
		}

		// The « + » layouts compared (id « <id>+ » → the layout under its « + »
		// name), rebuilt by each analysis; they are not in the layout list.
		const plusById = new Map();

		/** A compared layout by its result's id: a listed layout or a « + » one. */
		function layoutOf(id) {
			return byId.get(id) || plusById.get(id);
		}

		/** The prepared tables a result was analysed on: a « + » layout types the keys typed. */
		function tablesOf(result) {
			return plusById.has(result.layout.id) ? state.rawTables : state.tables;
		}

		/** A layout ticked « + »: the same keys under « <name>+ ». */
		function plusLayout(layout) {
			return Object.assign({}, layout, {
				id: layout.id + PLUS_SUFFIX,
				name: layout.name + PLUS_SUFFIX
			});
		}

		// The layout shown in detail, analysed again with every key's worst groups
		// (keyGroups): a ranking counts only the SFB ones. Kept per result, so a new
		// analysis (new results) analyses it again.
		const detailed = new WeakMap();
		function detailOf(result) {
			if (!detailed.has(result))
				detailed.set(
					result,
					E.analyse(
						layoutOf(result.layout.id),
						tablesOf(result),
						Object.assign(analysisOptions(), { keyGroups: true })
					)
				);
			return detailed.get(result);
		}

		let generation = 0;
		// Extra views (other analysers' scores) told about each comparison.
		const resultListeners = [];

		/** Analyses the selected layouts on the chosen corpus and redraws. */
		/** The collapsed list's line: how many layouts are compared, and which. */
		function showLayoutsSummary() {
			const names = layouts.filter((l) => state.selected.has(l.id)).map((l) => l.name);
			$('la-layouts-summary').textContent =
				names.length > SUMMARY_NAMES
					? t('layout_analysis.layouts.summary_more', {
							count: names.length,
							names: names.slice(0, SUMMARY_NAMES).join(', '),
							more: names.length - SUMMARY_NAMES
						})
					: t('layout_analysis.layouts.summary', {
							count: names.length,
							names: names.join(', ')
						});
		}

		/** Gives the page a turn (input, paint) before the next slice of scoring. */
		function nextTask() {
			return new Promise((resolve) => {
				const channel = new MessageChannel();
				channel.port1.onmessage = () => resolve();
				channel.port2.postMessage(null);
			});
		}

		async function analyse() {
			showLayoutsSummary();
			const mine = ++generation;
			// A built-in corpus loads its tables once (up to a few megabytes): say so meanwhile.
			setBusy(true);
			let tables;
			let raw;
			try {
				({ plain: tables, raw } = await corpusTables());
			} catch {
				if (mine !== generation) return;
				setBusy(false);
				showStatus(t('layout_analysis.status.corpus_failed'));
				return;
			}
			if (mine !== generation) return;
			state.tables = tables;
			state.rawTables = raw;
			state.words = tables ? corpusWords() : null;
			showTextMode();
			const chosen = layouts.filter((layout) => state.selected.has(layout.id));
			// The « + » layouts type the keys typed, beside the others on the final text.
			plusById.clear();
			if (raw)
				for (const layout of layouts)
					if (state.plus.has(layout.id)) {
						const plus = plusLayout(layout);
						plusById.set(plus.id, plus);
					}
			if (!tables || chosen.length + plusById.size === 0) {
				setBusy(false);
				state.results = [];
				showStatus(t('layout_analysis.status.empty'));
				render();
				return;
			}
			const start = performance.now();
			const options = analysisOptions();
			// Each layout on its text: the « + » layouts on the keys typed.
			const pending = chosen
				.map((layout) => [layout, tables])
				.concat(Array.from(plusById.values(), (layout) => [layout, raw]));
			// The compared layouts themselves (rows, dead keys…), for extra scorers.
			const compared = new Map(pending.map(([layout]) => [layout.id, layout]));
			state.compared = compared;
			const scored = [];
			let drawn = start;
			let drawEvery = PARTIAL_RENDER_MS;
			for (let at = 0; at < pending.length; at += ANALYSE_SLICE) {
				try {
					for (const [layout, table] of pending.slice(at, at + ANALYSE_SLICE))
						scored.push(E.analyse(layout, table, options));
				} catch (error) {
					if (!markRefused(error)) throw error;
					setBusy(false);
					state.results = [];
					showStatus(INFO.refusal(error));
					render();
					return;
				}
				if (scored.length === pending.length) break;
				showStatus(
					t('layout_analysis.status.scoring', { done: scored.length, count: pending.length })
				);
				// The best so far (chart and leaders, not the table or the other tabs),
				// drawn now and then while the rest is scored, less often as it costs
				// more, and not at all behind « Home ».
				if (state.tab !== HOME_TAB && performance.now() - drawn >= drawEvery) {
					state.results = E.rank(scored.slice());
					const began = performance.now();
					renderLeaders();
					renderChart();
					drawn = performance.now();
					drawEvery = Math.max(PARTIAL_RENDER_MS, PARTIAL_RENDER_FACTOR * (drawn - began));
				}
				await nextTask();
				if (mine !== generation) return;
			}
			state.results = E.rank(scored);
			setBusy(false);
			const ms = Math.round(performance.now() - start);
			for (const listener of resultListeners)
				listener(state.results, tables, {
					keyboard: state.keyboard,
					layouts: compared,
					tablesOf
				});
			showStatus(
				t('layout_analysis.status.ready', {
					count: state.results.length,
					chars: format(tables.totalChars, 0),
					ms
				})
			);
			render();
		}

		/**
		 * Whether an error is the mark's refusal of settings where QWERTY costs
		 * nothing (E.markIndex): said in words, the results left as they were.
		 */
		function markRefused(error) {
			return (
				Boolean(error) && error.name === 'AnalysisError' && error.code === 'mark_reference_cost'
			);
		}

		/** Re-scores after a weight change, without re-analysis. */
		function rescore() {
			try {
				state.results = E.rescore(state.results, state.weights, state.floors, state.grades);
			} catch (error) {
				if (!markRefused(error)) throw error;
				showStatus(INFO.refusal(error));
				return;
			}
			save();
			render();
		}

		function showStatus(text) {
			$('la-status').textContent = text;
		}

		/**
		 * « Edit » on a ranking row: the layout opens in « Éditer » as a copy
		 * (« AZERTY (copy) »), in a new
		 * tab of its own: the app's editor through the host, the site's through
		 * this tab's storage and the Studio's message, a page alone by going to
		 * the editor's page.
		 * @param {object} result - The row's result.
		 */
		function editCopy(result) {
			const source = layoutOf(result.layout.id);
			if (!source) throw new Error(`layout_analysis: no compared layout ${result.layout.id}`);
			const layout = Object.assign({}, source, {
				id: `${source.id}_copy`,
				name: t('layout_analysis.mine.copy_name', { name: source.name }),
				origin: 'user'
			});
			if (typeof HOST.openEditor === 'function') {
				HOST.openEditor(layout);
				return;
			}
			try {
				window.LAYOUT_ANALYSIS_FILES.handOffToEditor(layout);
			} catch (error) {
				if (!error || error.code !== 'studio_handoff_failed') throw error;
				showStatus(t('layout_analysis.error.studio_handoff_failed'));
				return;
			}
			if (window.parent !== window)
				window.parent.postMessage(
					{ type: window.LAYOUT_ANALYSIS_FILES.OPEN_EDITOR_MESSAGE },
					location.origin
				);
			else
				location.href = new URL(
					`../layout_editor/index.html${location.search}`,
					location.href
				).href;
		}

		/**
		 * Marks the results as being computed: the status says so at once and
		 * assistive technology waits for the new ranking before reading it.
		 */
		function setBusy(busy) {
			$('la-results').setAttribute('aria-busy', String(busy));
			$('la-results').classList.toggle('la-busy', busy);
			if (busy) showStatus(t('layout_analysis.status.loading'));
		}

		// ==========================
		// ======= 5/ Rendering =====
		// ==========================

		/**
		 * The required characters a layout lacks, as the page writes them: the
		 * space by its name, the letters as they are.
		 * @param {string[]} chars - result.coverage.missingRequired.
		 * @returns {string}
		 */
		function missingText(chars) {
			return chars
				.map((char) => (char === ' ' ? t('layout_analysis.incomplete.space') : char))
				.join(' ');
		}

		/** The flag an incomplete layout carries in the chart and the table. */
		function incompleteFlag(result) {
			return el(
				'strong',
				'la-incomplete-flag',
				t('layout_analysis.incomplete.flag', {
					chars: missingText(result.coverage.missingRequired)
				})
			);
		}

		// Literal keys, so the locale gate finds every string these labels show.
		const TAB_LABEL = {
			home: () => t('layout_analysis.tab.home'),
			overview: () => t('layout_analysis.tab.overview'),
			fingers: () => t('layout_analysis.tab.fingers'),
			bigrams: () => t('layout_analysis.tab.bigrams'),
			trigrams: () => t('layout_analysis.tab.trigrams'),
			rows: () => t('layout_analysis.tab.rows'),
			heatmaps: () => t('layout_analysis.tab.heatmaps'),
			misc: () => t('layout_analysis.tab.misc'),
			pareto: () => t('layout_analysis.tab.pareto'),
			trace: () => t('layout_analysis.tab.trace'),
			analysers: () => t('layout_analysis.tab.analysers'),
			details: () => t('layout_analysis.tab.details'),
			help: () => t('layout_analysis.tab.help')
		};
		const DIRECTION_LABEL = {
			lower: () => t('layout_analysis.analysers.better.lower'),
			higher: () => t('layout_analysis.analysers.better.higher'),
			none: () => t('layout_analysis.details.verdict_none')
		};

		/** A metric's name as the page writes it. */
		function metricName(id) {
			return t(`layout_analysis.metric.${id}`);
		}

		/** A trigram class's name: a metric's, or one of the two classes that are not metrics. */
		function trigramClassName(id) {
			if (id === 'roll_mixed') return t('layout_analysis.classes.roll_mixed');
			if (id === 'same_finger') return t('layout_analysis.classes.same_finger');
			return metricName(id);
		}

		/**
		 * Where a layout comes from, as the filters group it: the registry, the
		 * references, the user's own, or the library collection it was imported from.
		 */
		function originOf(layout) {
			return layout.origin === 'library' ? layout.source : layout.origin;
		}

		/** An origin's name in the filters. */
		function originName(origin) {
			if (origin === 'registry') return t('layout_analysis.filter.origin_registry');
			if (origin === 'reference') return t('layout_analysis.filter.origin_reference');
			if (origin === 'user') return t('layout_analysis.filter.origin_user');
			const source = DATA.library_sources[origin];
			if (!source) throw new Error(`layout comparer: no library collection ${origin}`);
			return t('layout_analysis.filter.origin_collection', { name: source.name });
		}

		/** A language's own name in the page's language (« Français », « Deutsch » in English: « French »…). */
		function languageName(code) {
			const name = new Intl.DisplayNames([INFO.locale()], { type: 'language' }).of(code);
			return name.charAt(0).toUpperCase() + name.slice(1);
		}

		/**
		 * Fills a select with [value, label] entries and keeps its value when it
		 * is still offered, else the first entry's.
		 * @returns {string} The value chosen.
		 */
		function fillSelect(select, entries, value) {
			select.replaceChildren(
				...entries.map(([id, label]) => {
					const option = el('option', '', label);
					option.value = id;
					return option;
				})
			);
			select.value = entries.some(([id]) => id === value) ? value : entries[0][0];
			return select.value;
		}

		/** The distinct values of a list, the most frequent first, then by name. */
		function byFrequency(values, name) {
			const counts = new Map();
			for (const value of values) counts.set(value, (counts.get(value) || 0) + 1);
			return Array.from(counts.keys()).sort(
				(a, b) => counts.get(b) - counts.get(a) || name(a).localeCompare(name(b))
			);
		}

		/** Whether a result is one of the user's own layouts (accent colour). */
		function isPersonal(result) {
			const layout = layoutOf(result.layout.id);
			return !layout || !SHAREABLE_ORIGINS.includes(layout.origin);
		}

		function render() {
			const count = $('la-table-count');
			count.textContent =
				state.results.length > 0
					? t('layout_analysis.table.count', {
							shown: shownRows().length,
							total: state.results.length
						})
					: '';
			renderActive();
		}

		/**
		 * Draws the overview and the sub-tab shown; the others are drawn when
		 * they are chosen.
		 */
		function renderActive() {
			fillFrame();
			const draw = {
				overview: () => {
					renderLeaders();
					renderChart();
					renderTable();
					renderNgrams();
				},
				fingers: () => {
					renderFingerTable();
					renderHands();
					renderMetricTab('fingers');
				},
				bigrams: () => renderMetricTab('bigrams'),
				trigrams: () => {
					renderTrigramMix();
					renderMetricTab('trigrams');
				},
				rows: () => {
					renderRowMix();
					renderTravelTable();
					renderMetricTab('rows');
				},
				// « Home » holds controls only, filled as they change.
				home: () => {},
				heatmaps: renderHeatGrid,
				misc: () => renderMetricTab('misc'),
				pareto: renderPareto,
				trace: renderTrace,
				// The other analysers' view follows the Comparer by itself (analyser_tab.js).
				analysers: () => {},
				details: () => {
					fillDetailsPick();
					renderDetails();
				},
				// The help is static text, filled with the page's strings.
				help: () => {}
			};
			// The ranking is cheap and always current, whichever tab is shown.
			draw.overview();
			if (state.tab !== DEFAULT_TAB) draw[state.tab]();
			renderFrameDiff();
		}

		// ===================================
		// ======= Pareto and trace tabs =====
		// ===================================

		/** A Pareto value's name: the mark's, or the metric's. */
		function paretoName(id) {
			return id === PARETO_MARK ? t('layout_analysis.pareto.mark') : metricName(id);
		}

		/** A Pareto value of a result. */
		function paretoValue(result, id) {
			return id === PARETO_MARK ? result.score.mark : result.metrics[id];
		}

		/** Which way a Pareto value is better. */
		function paretoBetter(id) {
			return id === PARETO_MARK ? 'higher' : E.METRICS[id].better;
		}

		/** A Pareto value as the tables write it, in its unit. */
		function paretoText(id, value) {
			return id === PARETO_MARK ? format(value, 1) : measure(value, metricDigits(id), unitText(id));
		}

		/**
		 * The Pareto layers of the complete layouts the filters keep, on the two
		 * chosen values: an incomplete layout's low counts are not a trade-off,
		 * so it is left out (the summary says how many).
		 * @returns {{rows: object[], layers: Map<string, object>, left: number}}
		 */
		function paretoView() {
			const shown = shownRows();
			const rows = shown.filter((r) => !r.incomplete);
			const { x, y } = state.pareto;
			const layers = new Map(
				E.pareto(
					rows.map((r) => ({ id: r.layout.id, values: [paretoValue(r, x), paretoValue(r, y)] })),
					[paretoBetter(x), paretoBetter(y)]
				).map((entry) => [entry.id, entry])
			);
			return { rows, layers, left: shown.length - rows.length };
		}

		/** Creates an SVG element with attributes. */
		function svgEl(tag, attributes) {
			const node = document.createElementNS(SVG_NS, tag);
			for (const [name, value] of Object.entries(attributes || {}))
				node.setAttribute(name, String(value));
			return node;
		}

		/** The Comparison layout's mark on a Pareto figure: a square, beside the Principal's ring. */
		function versusMark(cx, cy) {
			const side = 14;
			return svgEl('rect', {
				x: cx - side / 2,
				y: cy - side / 2,
				width: side,
				height: side,
				class: 'la-pareto-versus'
			});
		}

		/**
		 * A linear scale from a value range to a pixel range, the better end of
		 * the value on the right or at the top (the chart reads « up and right is
		 * better »).
		 */
		function paretoScale(values, better, from, to) {
			let min = Math.min(...values);
			let max = Math.max(...values);
			if (min === max) {
				min -= 1;
				max += 1;
			}
			const flip = better === 'lower';
			return (v) => {
				const at = (v - min) / (max - min);
				return from + (flip ? 1 - at : at) * (to - from);
			};
		}

		/** The Pareto tab: the chart, the spread of the X value and the table. */
		function renderPareto() {
			fillFrame();
			const choices = paretoChoices().map((id) => [id, paretoName(id)]);
			state.pareto.x = fillSelect($('la-pareto-x'), choices, state.pareto.x);
			state.pareto.y = fillSelect(
				$('la-pareto-y'),
				choices.filter(([id]) => id !== state.pareto.x),
				state.pareto.y
			);
			$('la-pareto-front').checked = state.pareto.frontOnly;
			const { rows, layers, left } = paretoView();
			const { x, y } = state.pareto;
			const front = rows.filter((r) => layers.get(r.layout.id).front);
			$('la-pareto-summary').textContent =
				rows.length === 0
					? t('layout_analysis.status.empty')
					: t('layout_analysis.pareto.summary', {
							front: front.length,
							count: rows.length,
							x: paretoName(x),
							y: paretoName(y)
						}) +
						(left > 0 ? ` ${t('layout_analysis.pareto.incomplete_left', { count: left })}` : '');
			renderParetoChart(rows, layers, front);
			renderParetoSpread(rows);
			renderParetoTable(rows, layers);
			renderFrameDiff();
		}

		/** The scatter plot: every layout, the frontier joined, the detailed one ringed. */
		function renderParetoChart(rows, layers, front) {
			const box = $('la-pareto-chart');
			box.replaceChildren();
			if (rows.length === 0) return;
			const { x, y } = state.pareto;
			const { width, height, margin } = PARETO_SIZE;
			const sx = paretoScale(
				rows.map((r) => paretoValue(r, x)),
				paretoBetter(x),
				margin,
				width - margin / 2
			);
			const sy = paretoScale(
				rows.map((r) => paretoValue(r, y)),
				paretoBetter(y),
				height - margin,
				margin / 2
			);
			const svg = svgEl('svg', {
				viewBox: `0 0 ${width} ${height}`,
				class: 'la-pareto-svg',
				role: 'img',
				'aria-labelledby': 'la-pareto-chart-label la-pareto-summary'
			});
			// The axes, each titled with its value and its better end.
			svg.append(
				svgEl('line', {
					x1: margin,
					y1: height - margin,
					x2: width - margin / 2,
					y2: height - margin,
					class: 'la-pareto-axis'
				}),
				svgEl('line', {
					x1: margin,
					y1: height - margin,
					x2: margin,
					y2: margin / 2,
					class: 'la-pareto-axis'
				})
			);
			const xTitle = svgEl('text', {
				x: (width + margin / 2) / 2,
				y: height - 14,
				class: 'la-pareto-axis-title',
				'text-anchor': 'middle'
			});
			xTitle.textContent = t('layout_analysis.pareto.axis', { name: paretoName(x) });
			const yTitle = svgEl('text', {
				x: 14,
				y: (height - margin / 2) / 2,
				class: 'la-pareto-axis-title',
				'text-anchor': 'middle',
				transform: `rotate(-90 14 ${(height - margin / 2) / 2})`
			});
			yTitle.textContent = t('layout_analysis.pareto.axis', { name: paretoName(y) });
			svg.append(xTitle, yTitle);
			// Each axis's two ends, as values.
			const ends = (id, scale) => {
				const values = rows.map((r) => paretoValue(r, id));
				return [Math.min(...values), Math.max(...values)].map((v) => [v, scale(v)]);
			};
			for (const [v, px] of ends(x, sx)) {
				const tick = svgEl('text', {
					x: px,
					y: height - margin + 18,
					class: 'la-pareto-tick',
					'text-anchor': 'middle'
				});
				tick.textContent = paretoText(x, v);
				svg.append(tick);
			}
			for (const [v, py] of ends(y, sy)) {
				const tick = svgEl('text', {
					x: margin - 6,
					y: py + 4,
					class: 'la-pareto-tick',
					'text-anchor': 'end'
				});
				tick.textContent = paretoText(y, v);
				svg.append(tick);
			}
			// The frontier, joined as steps from left to right.
			const steps = front
				.map((r) => [sx(paretoValue(r, x)), sy(paretoValue(r, y))])
				.sort((a, b) => a[0] - b[0] || a[1] - b[1]);
			if (steps.length > 1) {
				let d = `M${steps[0][0]} ${steps[0][1]}`;
				for (let i = 1; i < steps.length; i++) d += ` H${steps[i][0]} V${steps[i][1]}`;
				svg.append(svgEl('path', { d, class: 'la-pareto-front-line' }));
			}
			// The others first, the frontier over them, the detailed layout last.
			const ordered = rows
				.slice()
				.sort(
					(a, b) => Number(layers.get(a.layout.id).front) - Number(layers.get(b.layout.id).front)
				);
			let named = 0;
			for (const result of ordered) {
				const onFront = layers.get(result.layout.id).front;
				const cx = sx(paretoValue(result, x));
				const cy = sy(paretoValue(result, y));
				const point = svgEl('circle', {
					cx,
					cy,
					r: onFront ? 5 : 3.5,
					class: onFront ? 'la-pareto-point la-pareto-point-front' : 'la-pareto-point'
				});
				svg.append(point);
				if (onFront && named < PARETO_NAMED) {
					named++;
					// A name on the right half reads leftwards, so none leaves the chart.
					const right = cx > width / 2;
					const label = svgEl('text', {
						x: right ? cx - 9 : cx + 9,
						y: cy - 8,
						class: 'la-pareto-label',
						'text-anchor': right ? 'end' : 'start'
					});
					label.textContent = result.layout.name;
					svg.append(label);
				}
			}
			const detailed = rows.find((r) => r.layout.id === state.details);
			if (detailed)
				svg.append(
					svgEl('circle', {
						cx: sx(paretoValue(detailed, x)),
						cy: sy(paretoValue(detailed, y)),
						r: 9,
						class: 'la-pareto-ring'
					})
				);
			const versus = rows.find((r) => r.layout.id === state.versus);
			if (versus) svg.append(versusMark(sx(paretoValue(versus, x)), sy(paretoValue(versus, y))));
			box.append(svg);
		}

		/**
		 * Where the detailed layout stands among the others on the X value: one
		 * tick per layout on a line, the detailed one marked, and its
		 * percentile against the library in words.
		 */
		function renderParetoSpread(rows) {
			const { x } = state.pareto;
			setText(
				$('la-pareto-spread-label'),
				t('layout_analysis.pareto.spread', { name: paretoName(x) })
			);
			const box = $('la-pareto-spread');
			box.replaceChildren();
			const detailed = rows.find((r) => r.layout.id === state.details) || rows[0];
			const text = $('la-pareto-spread-text');
			if (!detailed) {
				text.textContent = '';
				$('la-pareto-quantiles').replaceChildren();
				$('la-pareto-quantiles-label').textContent = '';
				return;
			}
			const value = paretoValue(detailed, x);
			const better = paretoBetter(x);
			const beaten = rows.filter((r) =>
				better === 'lower' ? paretoValue(r, x) > value : paretoValue(r, x) < value
			).length;
			text.textContent = t('layout_analysis.pareto.spread_text', {
				layout: detailed.layout.name,
				value: paretoText(x, value),
				beaten,
				count: rows.length - 1
			});
			const compared = rows.find((r) => r.layout.id === state.versus && r !== detailed);
			if (compared) {
				const other = paretoValue(compared, x);
				const gap = value - other;
				text.append(
					' ',
					t('layout_analysis.pareto.spread_versus', {
						layout: compared.layout.name,
						value: paretoText(x, other),
						delta: `${gap > 0 ? '+' : ''}${paretoText(x, gap)}`
					})
				);
			}
			const { width, margin } = PARETO_SIZE;
			// Room under the strip for the quantiles' names, on two alternating
			// lines, and above it for the smoothed distribution.
			const height = 68 + SPREAD_DENSITY_BAND;
			const sx = paretoScale(
				rows.map((r) => paretoValue(r, x)),
				better,
				margin,
				width - margin / 2
			);
			const svg = svgEl('svg', {
				viewBox: `0 0 ${width} ${height}`,
				class: 'la-pareto-svg',
				role: 'img',
				'aria-labelledby': 'la-pareto-spread-label la-pareto-spread-text'
			});
			const values = rows.map((r) => paretoValue(r, x));
			svg.append(spreadDensity(values, sx));
			// The strip under the curve.
			const strip = svgEl('g', { transform: `translate(0 ${SPREAD_DENSITY_BAND})` });
			svg.append(strip);
			strip.append(
				svgEl('line', {
					x1: margin,
					y1: 28,
					x2: width - margin / 2,
					y2: 28,
					class: 'la-pareto-axis'
				})
			);
			for (const result of rows)
				strip.append(
					svgEl('line', {
						x1: sx(paretoValue(result, x)),
						x2: sx(paretoValue(result, x)),
						y1: 20,
						y2: 36,
						class: 'la-pareto-spread-tick'
					})
				);
			const quantiles = spreadQuantiles(values);
			// The inner quantiles as taller dashed marks, named above (P0 and P100 are the ends).
			const inner = quantiles.filter((q) => q.p !== 0 && q.p !== 100);
			for (const [index, { p, value: at }] of inner.entries()) {
				strip.append(
					svgEl('line', {
						x1: sx(at),
						x2: sx(at),
						y1: 14,
						y2: 42,
						class: 'la-pareto-quantile'
					})
				);
				const label = svgEl('text', {
					x: sx(at),
					// Two lines, so close quantiles keep their names apart.
					y: index % 2 === 0 ? 54 : 66,
					'text-anchor': 'middle',
					class: 'la-pareto-tick'
				});
				label.textContent = t('layout_analysis.percentile.chip', { percent: p });
				strip.append(label);
			}
			const versus = rows.find((r) => r.layout.id === state.versus && r !== detailed);
			if (versus) strip.append(versusMark(sx(paretoValue(versus, x)), 28));
			strip.append(svgEl('circle', { cx: sx(value), cy: 28, r: 8, class: 'la-pareto-ring' }));
			box.append(svg);
			renderParetoQuantiles(x, quantiles, rows.length);
		}

		/**
		 * The smoothed distribution of the spread's values (E.densityCurve, an
		 * idea seen in the Layouts Wiki playground's Ranking view), drawn as a
		 * filled curve over the values' range in the band above the strip, its
		 * peak at the band's top. Decorative beside the strip and the quantiles'
		 * table, which say the same in numbers.
		 * @param {number[]} values - The values the strip shows.
		 * @param {function(number): number} sx - The strip's scale.
		 * @returns {SVGElement} The curve's group, its fill and its outline.
		 */
		function spreadDensity(values, sx) {
			const low = Math.min(...values);
			const high = Math.max(...values);
			const { points } = E.densityCurve(values, { points: SPREAD_DENSITY_POINTS });
			const inside = points.filter((p) => p.x >= low && p.x <= high);
			const peak = Math.max(...inside.map((p) => p.density), 0);
			const base = SPREAD_DENSITY_BAND - 2;
			const y = (density) => (peak > 0 ? base - (density / peak) * (base - 4) : base);
			const line = inside.map((p, i) => `${i === 0 ? 'M' : 'L'} ${sx(p.x)} ${y(p.density)}`);
			const group = svgEl('g', { 'aria-hidden': 'true' });
			// The fill closes on the band's floor; the outline is the curve alone.
			group.append(
				svgEl('path', {
					d: [`M ${sx(low)} ${base}`]
						.concat(line.map((step) => `L${step.slice(1)}`))
						.concat([`L ${sx(high)} ${base}`, 'Z'])
						.join(' '),
					class: 'la-pareto-density-fill'
				}),
				svgEl('path', { d: line.join(' '), class: 'la-pareto-density' })
			);
			return group;
		}

		/**
		 * The quantiles of values (linear between the two nearest ranks): the
		 * value under which each SPREAD_QUANTILES share of them lies.
		 * @param {number[]} values - At least one finite value.
		 * @returns {{p: number, value: number}[]}
		 */
		function spreadQuantiles(values) {
			const sorted = values.slice().sort((a, b) => a - b);
			return SPREAD_QUANTILES.map((p) => {
				const at = (p / 100) * (sorted.length - 1);
				const low = Math.floor(at);
				const high = Math.ceil(at);
				return { p, value: sorted[low] + (sorted[high] - sorted[low]) * (at - low) };
			});
		}

		/** The spread's quantiles as a table: the strip's marks in words. */
		function renderParetoQuantiles(x, quantiles, count) {
			const table = $('la-pareto-quantiles');
			$('la-pareto-quantiles-label').textContent = t('layout_analysis.pareto.quantiles', {
				name: paretoName(x),
				count
			});
			const head = el('tr');
			for (const label of [
				t('layout_analysis.pareto.quantile'),
				t('layout_analysis.pareto.quantile_value')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			for (const { p, value } of quantiles) {
				const row = el('tr');
				const name = el('th', '', t('layout_analysis.percentile.chip', { percent: p }));
				name.scope = 'row';
				row.append(name, el('td', 'la-num', paretoText(x, value)));
				body.append(row);
			}
			table.replaceChildren(thead, body);
		}

		/**
		 * The table every chart of the tab stands for: each layout, its two
		 * values, its Pareto layer and the layouts that beat it on both.
		 */
		function renderParetoTable(rows, layers) {
			const table = $('la-pareto-table');
			table.replaceChildren();
			if (rows.length === 0) return;
			const { x, y, frontOnly } = state.pareto;
			const head = el('tr');
			for (const label of [
				t('layout_analysis.table.layout'),
				paretoName(x),
				paretoName(y),
				t('layout_analysis.pareto.layer'),
				t('layout_analysis.pareto.dominated_by')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const nameOf = new Map(rows.map((r) => [r.layout.id, r.layout.name]));
			const body = el('tbody');
			const sorted = rows
				.filter((r) => !frontOnly || layers.get(r.layout.id).front || r.layout.id === state.details)
				.sort(
					(a, b) =>
						layers.get(a.layout.id).layer - layers.get(b.layout.id).layer ||
						(paretoBetter(x) === 'lower' ? 1 : -1) * (paretoValue(a, x) - paretoValue(b, x)) ||
						a.rank - b.rank
				);
			for (const result of sorted) {
				const entry = layers.get(result.layout.id);
				const row = el('tr');
				if (entry.front) row.classList.add('la-pareto-row-front');
				if (state.details === result.layout.id) row.classList.add('la-selected');
				if (state.versus === result.layout.id) row.classList.add('la-versus');
				const name = el('th');
				name.scope = 'row';
				const button = el('button', 'la-chart-name', result.layout.name);
				button.type = 'button';
				button.addEventListener('click', () => showDetails(result.layout.id));
				name.append(button);
				const dominators = entry.dominatedBy.map((id) => nameOf.get(id));
				const shownNames = dominators.slice(0, 3).join(', ');
				row.append(
					name,
					el('td', 'la-num', paretoText(x, paretoValue(result, x))),
					el('td', 'la-num', paretoText(y, paretoValue(result, y))),
					el(
						'td',
						'',
						entry.front ? t('layout_analysis.pareto.layer_front') : format(entry.layer, 0)
					),
					el(
						'td',
						'',
						dominators.length > 3
							? t('layout_analysis.pareto.dominated_more', {
									names: shownNames,
									count: dominators.length - 3
								})
							: shownNames
					)
				);
				body.append(row);
			}
			table.append(thead, body);
		}

		/** The text the trace types: the visitor's, else the sample of the page's language. */
		function traceInput() {
			return state.trace.text === null ? t(TRACE_SAMPLE_KEY) : state.trace.text;
		}

		/**
		 * The trace tab: the text typed on one layout, and on a second one to
		 * compare, keystroke by keystroke, with the events of each key pair and
		 * triple counted side by side.
		 */
		function renderTrace() {
			const textBox = $('la-trace-text');
			if (document.activeElement !== textBox) textBox.value = traceInput();
			fillFrame();
			const out = $('la-trace-out');
			out.replaceChildren();
			if (!state.details) return;
			const text = traceInput();
			const options = {
				keyboard: state.keyboard,
				weights: state.weights,
				profile: FINGERING.current(state.keyboard) || undefined
			};
			const traced = [state.details, state.versus].filter(Boolean).map((id) => {
				const layout = layoutOf(id);
				return { id, layout, trace: E.traceText(layout, text, options) };
			});
			out.append(traceEvents(traced));
			traced.forEach((entry, i) => out.append(traceLayout(entry, i)));
		}

		/** The events of the traced layouts side by side, with the difference of two. */
		function traceEvents(traced) {
			const section = el('section', 'la-figure la-figure-wide');
			const titleId = 'la-trace-events-label';
			const title = el('h3', '', t('layout_analysis.trace.events'));
			title.id = titleId;
			const wrap = el('section', 'la-table-wrap');
			wrap.tabIndex = 0;
			wrap.setAttribute('aria-labelledby', titleId);
			const table = el('table', 'la-table');
			table.id = 'la-trace-events';
			const head = el('tr');
			const columns = [t('layout_analysis.trace.event')]
				.concat(traced.map((entry) => entry.layout.name))
				.concat(traced.length === 2 ? [t('layout_analysis.trace.difference')] : []);
			for (const label of columns) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			const share = (trace, event) => {
				const whole = E.TRACE_TRIPLE_EVENTS.includes(event) ? trace.trigrams : trace.bigrams;
				return whole > 0 ? (100 * trace.counts[event]) / whole : 0;
			};
			for (const event of E.TRACE_PAIR_EVENTS.concat(E.TRACE_TRIPLE_EVENTS)) {
				const row = el('tr');
				const name = el('th', '', metricName(event));
				name.scope = 'row';
				row.append(name);
				for (const entry of traced)
					row.append(
						el(
							'td',
							'la-num',
							t('layout_analysis.trace.count', {
								count: entry.trace.counts[event],
								share: measure(share(entry.trace, event), 1, '%')
							})
						)
					);
				if (traced.length === 2) {
					const delta = traced[1].trace.counts[event] - traced[0].trace.counts[event];
					row.append(el('td', 'la-num', `${delta > 0 ? '+' : ''}${format(delta, 0)}`));
				}
				body.append(row);
			}
			table.append(thead, body);
			wrap.append(table);
			section.append(title, el('p', 'la-muted', t('layout_analysis.trace.events_caption')), wrap);
			return section;
		}

		/**
		 * One traced layout: the text as a strip of characters over their keys
		 * (each key in its finger's colour, its finger printed under it, a key of
		 * a penalised pair or triple outlined), then the same keystroke by
		 * keystroke as a table, and the penalised pairs and triples in words.
		 */
		function traceLayout({ layout, trace }, index) {
			const section = el('section', 'la-figure la-figure-wide la-trace-layout');
			const titleId = `la-trace-${index}-title`;
			const title = el('h3', '', layout.name);
			title.id = titleId;
			section.setAttribute('aria-labelledby', titleId);
			const penalties = (events) => events.filter((event) => E.METRICS[event].better === 'lower');
			const bad = new Set();
			const marked = [];
			for (const group of trace.pairs.concat(trace.triples)) {
				const events = penalties(group.events);
				if (events.length === 0) continue;
				for (const k of group.keys) bad.add(k);
				marked.push({ keys: group.keys, events });
			}
			const keyLabel = (code, layer) => levelText(layout, code, layer) || code;
			const fingerShort = (finger) => t(`layout_analysis.finger_short.${finger}`);
			// The strip repeats the table below it for sighted readers.
			const strip = el('ol', 'la-trace-strip');
			strip.setAttribute('aria-hidden', 'true');
			trace.chars.forEach((char) => {
				const item = el(
					'li',
					char.kind === null ? 'la-trace-cell la-trace-missing' : 'la-trace-cell'
				);
				item.append(
					el(
						'span',
						'la-trace-char',
						char.char === ' ' ? '␣' : char.char === '\n' ? '↵' : char.char
					)
				);
				char.steps.forEach(([code, , layer], j) => {
					const index = char.keys[j];
					const key = el('span', bad.has(index) ? 'la-trace-key la-trace-bad' : 'la-trace-key');
					key.dataset.finger = trace.keys[index].finger;
					key.append(
						el('span', 'la-trace-key-text', keyLabel(code, layer)),
						el('span', 'la-trace-finger', fingerShort(trace.keys[index].finger))
					);
					item.append(key);
				});
				strip.append(item);
			});
			const legend = el('p', 'la-muted', t('layout_analysis.trace.strip_caption'));
			// The keystroke table.
			const tableBox = el('details', 'la-section');
			const summaryId = `la-trace-${index}-keys`;
			const summary = el('summary', '', t('layout_analysis.trace.keys_table'));
			summary.id = summaryId;
			const wrap = el('section', 'la-table-wrap');
			wrap.tabIndex = 0;
			wrap.setAttribute('aria-labelledby', summaryId);
			const table = el('table', 'la-table');
			const head = el('tr');
			for (const label of [
				t('layout_analysis.trace.char'),
				t('layout_analysis.trace.keys'),
				t('layout_analysis.trace.fingers'),
				t('layout_analysis.trace.held')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			for (const char of trace.chars) {
				const row = el('tr');
				const name = el('th', '', char.char === ' ' ? '␣' : char.char === '\n' ? '↵' : char.char);
				name.scope = 'row';
				const keys =
					char.kind === null
						? t('layout_analysis.trace.not_typed')
						: char.steps.map(([code, , layer]) => keyLabel(code, layer)).join(' → ');
				const fingers = char.keys
					.map((i) => t(`layout_analysis.finger.${trace.keys[i].finger}`))
					.join(', ');
				row.append(
					name,
					el('td', '', keys),
					el('td', '', fingers),
					el('td', '', char.held.join(', '))
				);
				body.append(row);
			}
			table.append(thead, body);
			wrap.append(table);
			tableBox.append(summary, wrap);
			// The penalised groups, in the text's order.
			const groupText = (keys) =>
				keys
					.map((i) => {
						const key = trace.keys[i];
						const char = trace.chars[key.char];
						const step = char.steps[char.keys.indexOf(i)];
						return keyLabel(step[0], step[2]);
					})
					.join(' ');
			const list = el('ul', 'la-trace-groups');
			marked.forEach((group, at) => {
				const item = el(
					'li',
					'',
					t('layout_analysis.trace.group', {
						keys: groupText(group.keys),
						events: group.events.map(metricName).join(', ')
					})
				);
				// The drill-down to the corpus's words holding these keys in a row.
				if (state.words) {
					const button = el('button', 'la-trace-words-button', t('layout_analysis.trace.words'));
					button.type = 'button';
					// Its name starts with its visible text and says which keys (WCAG 2.5.3).
					button.setAttribute(
						'aria-label',
						t('layout_analysis.trace.words_for', { keys: groupText(group.keys) })
					);
					const listId = `la-trace-${index}-words-${at}`;
					button.setAttribute('aria-expanded', 'false');
					button.setAttribute('aria-controls', listId);
					const found = el('p', 'la-muted la-trace-words');
					found.id = listId;
					found.hidden = true;
					button.addEventListener('click', () => {
						const open = button.getAttribute('aria-expanded') !== 'true';
						button.setAttribute('aria-expanded', String(open));
						found.hidden = !open;
						if (!open || found.textContent !== '') return;
						const hits = E.wordsWithKeys(
							layout,
							state.words,
							group.keys.map((k) => trace.keys[k].code),
							{
								keyboard: state.keyboard,
								profile: FINGERING.current(state.keyboard) || undefined,
								limit: TRACE_WORDS_SHOWN
							}
						);
						found.textContent =
							hits.words.length === 0
								? t('layout_analysis.trace.words_none')
								: t('layout_analysis.trace.words_found', {
										words: hits.words.map((w) => w.word).join(', '),
										count: hits.occurrences
									});
					});
					item.append(' ', button, found);
				}
				list.append(item);
			});
			const groupsTitle = el('h4', '', t('layout_analysis.trace.groups', { count: marked.length }));
			section.append(title, strip, legend, tableBox, groupsTitle);
			if (marked.length > 0) section.append(list);
			if (trace.unsupported > 0)
				section.append(
					el('p', 'la-muted', t('layout_analysis.trace.unsupported', { count: trace.unsupported }))
				);
			return section;
		}

		/** The tab strip: one button per sub-tab, its panel shown when it is chosen. */
		function fillTabs() {
			const list = $('la-tabs');
			list.replaceChildren(
				...TABS.map((id) => {
					const button = el('button', `la-tab la-tab-accent-${TAB_SLOT[id]}`);
					button.append(tabIcon(id), TAB_LABEL[id]());
					button.type = 'button';
					button.id = `la-tab-${id}`;
					button.setAttribute('role', 'tab');
					button.setAttribute('aria-controls', `la-panel-${id}`);
					button.addEventListener('click', () => chooseTab(id, true));
					// Arrows, Home and End move between the tabs (the ARIA tabs pattern).
					button.addEventListener('keydown', (event) => {
						const at = TABS.indexOf(id);
						const next = {
							ArrowRight: TABS[(at + 1) % TABS.length],
							ArrowLeft: TABS[(at - 1 + TABS.length) % TABS.length],
							Home: TABS[0],
							End: TABS[TABS.length - 1]
						}[event.key];
						if (!next) return;
						event.preventDefault();
						chooseTab(next, true);
						$(`la-tab-${next}`).focus();
					});
					return button;
				})
			);
			showTab();
		}

		/** A tab's decorative icon (TAB_ICONS): its text names the tab. */
		function tabIcon(id) {
			const svg = document.createElementNS(SVG_NS, 'svg');
			svg.setAttribute('class', 'la-tab-icon');
			svg.setAttribute('viewBox', '0 0 24 24');
			svg.setAttribute('aria-hidden', 'true');
			svg.setAttribute('focusable', 'false');
			const path = document.createElementNS(SVG_NS, 'path');
			path.setAttribute('d', TAB_ICONS[id]);
			svg.append(path);
			return svg;
		}

		/** Marks the chosen tab and shows its panel only. */
		function showTab() {
			for (const id of TABS) {
				const button = $(`la-tab-${id}`);
				const chosen = id === state.tab;
				button.setAttribute('aria-selected', String(chosen));
				button.tabIndex = chosen ? 0 : -1;
				$(`la-panel-${id}`).hidden = !chosen;
			}
			// The results' filters narrow the figures, not « Home »'s controls.
			$('la-filters-box').hidden = state.tab === HOME_TAB || state.tab === HELP_TAB;
			$('la-frame').hidden = !FRAME_TABS.includes(state.tab);
			// The trace counts its own difference, per event of the text typed.
			$('la-frame-diff').hidden = !FRAME_TABS.includes(state.tab) || state.tab === 'trace';
		}

		/**
		 * The values of a frame tab that its difference table compares, each
		 * {label, a, b, text, better} for the Principal (a) and the Comparison
		 * (b): the overview's mark and leading metrics, a themed tab's metrics
		 * (with each finger's load on « Fingers » and « Heat maps », better the
		 * closer to the ideal), the Pareto tab's two values.
		 * @param {string} tab - A FRAME_TABS id but the trace.
		 * @param {object} a - The Principal's result.
		 * @param {object} b - The Comparison's result.
		 * @returns {Array<{label: string, info?: string, a: number, b: number,
		 *   text: function(number, boolean): string, verdict: string}>}
		 */
		function frameDiffRows(tab, a, b) {
			const verdict = (better, x, y) => {
				if (better === 'none') return 'none';
				if (x === y) return 'same';
				return (better === 'higher') === x > y ? 'better' : 'worse';
			};
			const signed = (value, digits) => `${value > 0 ? '+' : ''}${format(value, digits)}`;
			const metricRow = (id) => ({
				label: metricName(id),
				info: id,
				a: a.metrics[id],
				b: b.metrics[id],
				text: (value, delta) =>
					delta
						? withUnit(signed(value, metricDigits(id)), unitText(id))
						: measure(value, metricDigits(id), unitText(id)),
				verdict: verdict(E.METRICS[id].better, a.metrics[id], b.metrics[id])
			});
			const markRow = () => ({
				label: t('layout_analysis.table.score'),
				a: a.score.mark,
				b: b.score.mark,
				text: (value, delta) =>
					withUnit(delta ? signed(value, 1) : format(value, 1), t('layout_analysis.unit.points')),
				verdict: verdict('higher', a.score.mark, b.score.mark)
			});
			// A finger's share of the presses: better the closer to the ideal load.
			const fingerRows = () =>
				Object.keys(a.idealLoad).map((id) => {
					const ideal = a.idealLoad[id];
					const [x, y] = [a.fingerShares[id], b.fingerShares[id]];
					const gap = Math.abs(x - ideal) - Math.abs(y - ideal);
					return {
						label: t('layout_analysis.frame.diff_finger', {
							finger: t(`layout_analysis.finger.${id}`)
						}),
						a: x,
						b: y,
						text: (value, delta) =>
							delta ? withUnit(signed(value, 1), '%') : measure(value, 1, '%'),
						verdict: gap === 0 ? 'same' : gap < 0 ? 'better' : 'worse'
					};
				});
			if (tab === 'overview') return [markRow()].concat(LEADER_METRICS.map(metricRow));
			if (tab === 'fingers') return fingerRows().concat(TAB_METRICS.fingers.map(metricRow));
			if (tab === 'heatmaps') return fingerRows();
			if (tab === 'pareto')
				return [state.pareto.x, state.pareto.y].map((id) =>
					id === PARETO_MARK ? markRow() : metricRow(id)
				);
			return TAB_METRICS[tab].map(metricRow);
		}

		/**
		 * The difference of the Principal and the Comparison layouts on the tab
		 * shown (an idea seen in the Layouts Wiki playground, whose views show
		 * Main, Comp or their difference): a folding table above the tab's
		 * figures, each value with both layouts, the difference (Principal −
		 * Comparison) and which one it favours in words; without a Comparison,
		 * a line saying how to choose one.
		 */
		function renderFrameDiff() {
			const box = $('la-frame-diff');
			if (!FRAME_TABS.includes(state.tab) || state.tab === 'trace') return;
			const a = state.results.find((r) => r.layout.id === state.details) || null;
			const b = state.results.find((r) => r.layout.id === state.versus) || null;
			const table = $('la-frame-diff-table');
			$('la-frame-diff-none').hidden = Boolean(a && b);
			$('la-frame-diff-wrap').hidden = !(a && b);
			if (!a || !b) {
				setText($('la-frame-diff-label'), t('layout_analysis.frame.diff_title_none'));
				table.replaceChildren();
				return;
			}
			setText(
				$('la-frame-diff-label'),
				t('layout_analysis.frame.diff_title', { main: a.layout.name, comp: b.layout.name })
			);
			const head = el('tr');
			for (const label of [
				t('layout_analysis.details.metric_column'),
				a.layout.name,
				b.layout.name,
				t('layout_analysis.details.delta')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			for (const row of frameDiffRows(state.tab, a, b)) {
				const tr = el('tr');
				const th = el('th', '', row.label);
				th.scope = 'row';
				if (row.info && DATA.sources.items[row.info]) th.append(' ', infoButton(row.info));
				const delta = el('td', 'la-delta');
				delta.append(row.text(row.a - row.b, true), ' ', verdictCell(row.verdict));
				tr.append(
					th,
					el('td', '', row.text(row.a, false)),
					el('td', '', row.text(row.b, false)),
					delta
				);
				tbody.append(tr);
			}
			table.replaceChildren(thead, tbody);
			box.dataset.tab = state.tab;
		}

		/**
		 * The Principal and Comparison frame: the detailed layout and the one it
		 * is compared with (state.details, state.versus), which « One layout »,
		 * the Pareto tab's ring and the trace all follow.
		 */
		function fillFrame() {
			const entries = state.results.map((r) => [r.layout.id, r.layout.name]);
			if (entries.length > 0 && !entries.some(([id]) => id === state.details))
				state.details = entries[0][0];
			if (
				entries.length > 0 &&
				(!entries.some(([id]) => id === state.versus) || state.versus === state.details)
			)
				state.versus = null;
			fillSelect(
				$('la-frame-main'),
				entries.length > 0 ? entries : [['', t('layout_analysis.status.empty')]],
				state.details || ''
			);
			fillSelect(
				$('la-frame-comp'),
				[['', t('layout_analysis.details.versus_none')]].concat(
					entries.filter(([id]) => id !== state.details)
				),
				state.versus || ''
			);
		}

		/** Shows a sub-tab; the visitor's own choice is kept for the next visit. */
		function chooseTab(id, byUser) {
			state.tab = id;
			if (byUser) {
				state.tabSaved = id;
				save();
			}
			showTab();
			renderActive();
		}

		/**
		 * Horizontal bars of the mark, best first. The mark is an index on
		 * QWERTY on this text and these settings (E.markIndex): QWERTY reads
		 * 100, so a value says its gap to QWERTY by itself. Each bar runs from
		 * 0 (a layout costing twice QWERTY's), and a mark at or below 0 draws
		 * none. The user's own layouts take the accent colour. The filters
		 * choose the layouts drawn.
		 */
		function renderChart() {
			const box = $('la-chart');
			box.replaceChildren();
			const rows = shownRows();
			const shown = rows.slice(0, CHART_MAX_BARS);
			moreNoteAfter(box, shown.length, rows.length);
			if (shown.length === 0) return;
			const best = Math.max(...shown.map((r) => r.score.mark));
			for (const result of shown) {
				const value = format(result.score.mark, 1);
				// An incomplete layout ranks after the complete ones and says what it lacks.
				const flag = result.incomplete ? incompleteFlag(result) : null;
				const track = el('td', 'la-chart-track');
				const bar = el('span', isPersonal(result) ? 'la-bar la-bar-mine' : 'la-bar la-bar-score');
				bar.style.left = '0%';
				bar.style.width = `${best > 0 ? Math.max(0, (100 * result.score.mark) / best) : 0}%`;
				track.append(bar);
				const row = barRow(result.layout.name, track, value, '', result.layout.id);
				row.querySelector('.la-chart-value').classList.add(MARK_CELL);
				// The button's name starts with its visible text, the layout (WCAG 2.5.3).
				rowName(row).setAttribute(
					'aria-label',
					t('layout_analysis.chart.row', {
						layout: flag ? `${result.layout.name} (${flag.textContent})` : result.layout.name,
						rank: result.rank,
						score: value
					})
				);
				if (state.details === result.layout.id) row.classList.add('la-selected');
				if (state.versus === result.layout.id) row.classList.add('la-versus');
				if (flag) {
					row.classList.add('la-incomplete');
					rowName(row).append(' ', flag);
				}
				row.title = `${result.layout.name}: ${value}${flag ? ` (${flag.textContent})` : ''}`;
				box.append(row);
			}
		}

		/** The line under a chart that shows the first of the layouts only. */
		function moreNote(shown, total) {
			return el('p', 'la-muted', t('layout_analysis.chart.more', { shown, total }));
		}

		/**
		 * The « more » line after a figure's table, which holds rows only:
		 * replaced at each drawing, absent when every layout is shown.
		 * @param {HTMLTableElement} table - A figure with an id.
		 * @param {number} shown
		 * @param {number} total
		 */
		function moreNoteAfter(table, shown, total) {
			const id = `${table.id}-more`;
			const old = document.getElementById(id);
			if (old) old.remove();
			if (total <= shown) return;
			const note = moreNote(shown, total);
			note.id = id;
			table.after(note);
		}

		/**
		 * The overview's tiles: the best complete layout shown by the score and by
		 * a few telling metrics, each opening that layout's details.
		 */
		function renderLeaders() {
			const box = $('la-leaders');
			box.replaceChildren();
			const complete = shownRows().filter((r) => !r.incomplete);
			box.closest('section').hidden = complete.length === 0;
			if (complete.length === 0) return;
			const tile = (label, result, text) => {
				const item = el('div', isPersonal(result) ? 'la-leader la-leader-mine' : 'la-leader');
				const value = el('dd', 'la-leader-value', text);
				const name = el('button', 'la-leader-name', result.layout.name);
				name.type = 'button';
				name.addEventListener('click', () => showDetails(result.layout.id));
				const who = el('dd', 'la-leader-who');
				who.append(name);
				item.append(el('dt', '', label), value, who);
				box.append(item);
			};
			tile(t('layout_analysis.chart.title'), complete[0], format(complete[0].score.mark, 1));
			for (const id of LEADER_METRICS) {
				const higher = E.METRICS[id].better === 'higher';
				const best = complete.reduce((a, b) =>
					(higher ? b.metrics[id] > a.metrics[id] : b.metrics[id] < a.metrics[id]) ? b : a
				);
				tile(metricName(id), best, measure(best.metrics[id], metricDigits(id), unitText(id)));
			}
		}

		// The values a query may name: the mark, every metric, and two yes-or-no
		// values (complete, the user's own layout).
		const QUERY_FLAGS = ['complete', 'mine'];
		const QUERY_MARK = 'mark';

		/** A result's values as a query reads them. */
		function queryValues(result) {
			return Object.assign({}, result.metrics, {
				[QUERY_MARK]: result.score.mark,
				complete: !result.incomplete,
				mine: isPersonal(result)
			});
		}

		// The last query compiled: {text, test, error}; test null when it keeps
		// every row (empty, or not readable: said in words, never applied).
		let queryCache = null;

		/** The table's values query, compiled once per text. */
		function compiledQuery() {
			const text = state.table.query;
			if (queryCache && queryCache.text === text) return queryCache;
			try {
				const test = E.compileQuery(text, {
					numbers: [QUERY_MARK].concat(Object.keys(E.METRICS)),
					flags: QUERY_FLAGS
				});
				queryCache = { text, test: text.trim() === '' ? null : test, error: null };
			} catch (error) {
				if (!(error instanceof E.QueryError)) throw error;
				queryCache = { text, test: null, error };
			}
			return queryCache;
		}

		/** Why the query does not read, in words, or '' when it does. */
		function queryStatus() {
			const { error } = compiledQuery();
			return error
				? t('layout_analysis.filter.query_invalid', { reason: queryErrorText(error) })
				: '';
		}

		/** A values query's refusal (an E.QueryError) in words, with where it happens. */
		function queryErrorText(error) {
			const values = { at: error.at + 1, token: error.token };
			const words = {
				query_unexpected: () => t('layout_analysis.filter.query_unexpected', values),
				query_unknown_name: () => t('layout_analysis.filter.query_unknown_name', values),
				query_number: () => t('layout_analysis.filter.query_number', values),
				query_comparison: () => t('layout_analysis.filter.query_comparison', values),
				query_flag: () => t('layout_analysis.filter.query_flag', values),
				query_parenthesis: () => t('layout_analysis.filter.query_parenthesis', values),
				query_end: () => t('layout_analysis.filter.query_end', values)
			};
			if (!words[error.code]) throw new Error(`layout comparer: no words for ${error.code}`);
			return words[error.code]();
		}

		/** The names a query may use, each with what it is. */
		function fillQueryNames() {
			const item = (id, text) => {
				const li = el('li');
				li.append(el('code', '', id), ` ${text}`);
				return li;
			};
			$('la-query-names').replaceChildren(
				item(QUERY_MARK, t('layout_analysis.filter.query_name_mark')),
				item('complete', t('layout_analysis.filter.query_name_complete')),
				item('mine', t('layout_analysis.filter.query_name_mine')),
				...Object.keys(E.METRICS).map((id) => item(id, metricName(id)))
			);
		}

		/** A compared layout's family ('' for none). */
		function familyOf(result) {
			const layout = layoutOf(result.layout.id);
			return (layout && layout.family) || '';
		}

		/**
		 * The results the filters keep, in the ranking's order: name, family,
		 * origin, language, completeness and score range. Every figure and table
		 * of the sub-tabs draws these.
		 */
		function shownRows() {
			const { name, family, origin, language, complete, min, max } = state.table;
			const needle = name.trim().toLowerCase();
			const query = compiledQuery();
			return state.results.filter((r) => {
				const layout = layoutOf(r.layout.id);
				return (
					(query.test === null || query.test(queryValues(r))) &&
					(!needle || r.layout.name.toLowerCase().includes(needle)) &&
					(!family || familyOf(r) === family) &&
					(!origin || originOf(layout) === origin) &&
					(!language || layout.language === language) &&
					(complete === 'all' || (complete === 'yes') === !r.incomplete) &&
					(min === null || r.score.mark >= min) &&
					(max === null || r.score.mark <= max)
				);
			});
		}

		/** The origins and languages of the listed layouts, the most frequent first. */
		function layoutFacets() {
			return {
				origins: byFrequency(layouts.map(originOf), originName),
				languages: byFrequency(layouts.map((l) => l.language).filter(Boolean), languageName)
			};
		}

		/** The column choices (every metric, in the engine's order) and the filters' values. */
		function fillTableOptions() {
			const list = $('la-column-list');
			list.replaceChildren(
				...Object.keys(E.METRICS).map((id) => {
					const label = el('label', 'la-check');
					const box = el('input');
					box.type = 'checkbox';
					box.value = id;
					box.checked = state.table.columns.includes(id);
					box.addEventListener('change', () => {
						// The engine's order, whatever order the boxes were ticked in.
						const ticked = new Set(
							Array.from(list.querySelectorAll('input:checked'), (input) => input.value)
						);
						state.table.columns = Object.keys(E.METRICS).filter((m) => ticked.has(m));
						save();
						renderTable();
					});
					label.append(box, metricName(id));
					return label;
				})
			);
			const families = Array.from(new Set(layouts.map((l) => l.family).filter(Boolean))).sort();
			state.table.family = fillSelect(
				$('la-row-family'),
				[[ALL, t('layout_analysis.table.family_all')]].concat(
					// A family is named by its first layout's name (Ergopti, Bépo…).
					families.map((family) => [family, layouts.find((l) => l.family === family).name])
				),
				state.table.family
			);
			const { origins, languages } = layoutFacets();
			const originEntries = [[ALL, t('layout_analysis.filter.origin_all')]].concat(
				origins.map((id) => [id, originName(id)])
			);
			const languageEntries = [[ALL, t('layout_analysis.filter.language_all')]].concat(
				languages.map((id) => [id, languageName(id)])
			);
			state.table.origin = fillSelect($('la-row-origin'), originEntries, state.table.origin);
			state.table.language = fillSelect(
				$('la-row-language'),
				languageEntries,
				state.table.language
			);
			state.pick.origin = fillSelect($('la-pick-origin'), originEntries, state.pick.origin);
			state.pick.language = fillSelect($('la-pick-language'), languageEntries, state.pick.language);
			$('la-row-complete').value = state.table.complete;
			$('la-row-name').value = state.table.name;
			$('la-row-min').value = state.table.min === null ? '' : String(state.table.min);
			$('la-row-max').value = state.table.max === null ? '' : String(state.table.max);
			$('la-row-query').value = state.table.query;
			$('la-row-query-status').textContent = queryStatus();
			fillQueryNames();
		}

		/**
		 * A ranking table of results, sortable by any column (a header button,
		 * its order in aria-sort): rank, layout, score and the given metrics. A
		 * row opens the layout's details by a click or Enter; an incomplete
		 * layout carries its flag.
		 * @param {HTMLTableElement} table
		 * @param {object[]} rows The results, in the ranking's order.
		 * @param {string[]} metricIds The metric columns.
		 * @param {{key: string, descending: boolean}} sort
		 * @param {function({key: string, descending: boolean}): void} resort
		 *   Called with the new sort when a header is chosen.
		 * @param {object} [reference] The result the relative view measures the
		 *   score and the metrics against (referenceResult), or none.
		 * @param {object} [view] The overview's own view (rankingView): pinned
		 *   rows first, families folded to their best member.
		 * @returns {{key: string, descending: boolean}} The sort applied (rank
		 *   when the sorted column is gone).
		 */
		function rankingTable(table, rows, metricIds, sort, resort, reference, view) {
			table.replaceChildren();
			if (rows.length === 0) return sort;
			const columns = [
				{ key: 'rank', label: t('layout_analysis.table.rank'), value: (r) => r.rank, digits: 0 },
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name },
				{
					key: 'score',
					label: t('layout_analysis.table.score'),
					// Its popover: the weights' explanation and the score's formula.
					info: 'weights',
					value: (r) => r.score.mark,
					digits: 1
				}
			].concat(
				metricIds.map((id) => ({
					key: id,
					// The usual acronym when the name has one (« SFB »), the full
					// name in the button's accessible name and the « i » popover.
					label: INFO.metricShort(id) || metricName(id),
					name: metricName(id),
					spoken: INFO.metricSpoken(id),
					info: id,
					value: (r) => r.metrics[id],
					digits: metricDigits(id),
					unit: unitText(id),
					// The order a first click asks for: the metric's better value first.
					higher: E.METRICS[id].better !== 'lower'
				}))
			);
			// A sorted column the user hid sorts by rank again.
			const applied = columns.some((c) => c.key === sort.key)
				? sort
				: { key: 'rank', descending: false };
			const head = el('tr');
			for (const column of columns) {
				// A metric's header wraps on two lines at most (style.css la-th-metric).
				const th = el('th', column.name ? 'la-sortable la-th-metric' : 'la-sortable');
				// The layout's name stays in view while the metrics scroll by (style.css la-name-col).
				if (column.key === 'name') th.classList.add(NAME_COLUMN);
				th.scope = 'col';
				// The sort is a button, so the keyboard reaches it.
				const button = el('button', 'la-sort', column.label);
				button.type = 'button';
				button.dataset.sort = column.key;
				// An acronym's button is named in full after the acronym it shows
				// (INFO.metricSpoken, WCAG 2.5.3).
				if (column.name && column.name !== column.label)
					button.setAttribute('aria-label', column.spoken);
				button.addEventListener('click', () => {
					resort(
						applied.key === column.key
							? { key: column.key, descending: !applied.descending }
							: { key: column.key, descending: column.key === 'score' || Boolean(column.higher) }
					);
					// The table is drawn again: the focus stays on the same header.
					const again = table.isConnected ? table : document.getElementById(table.id) || table;
					const focus = again.querySelector(`button[data-sort="${column.key}"]`);
					if (focus) focus.focus();
				});
				const info =
					column.info && DATA.sources.items[column.info] ? infoButton(column.info) : null;
				if (column.name) {
					// The « i » stays beside the header's last line, never on a line of its own.
					const head = el('span', 'la-th-head');
					head.append(button, info);
					th.append(head);
				} else {
					th.append(button);
					if (info) th.append(' ', info);
				}
				if (applied.key === column.key)
					th.setAttribute('aria-sort', applied.descending ? 'descending' : 'ascending');
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const sortColumn = columns.find((c) => c.key === applied.key);
			const sorted = rows.slice().sort((a, b) => {
				const x = sortColumn.value(a);
				const y = sortColumn.value(b);
				const order = typeof x === 'string' ? x.localeCompare(y) : x - y;
				return applied.descending ? -order : order;
			});
			const tbody = el('tbody');
			const shown = view ? view.order(sorted) : sorted;
			// What the CSV download writes: these rows, in this order, these columns.
			if (view) Object.assign(view, { shown, columns });
			for (const result of shown) {
				const tr = el('tr');
				if (view) view.mark(tr, result);
				if (state.details === result.layout.id) tr.className = 'la-selected';
				if (isPersonal(result)) tr.classList.add('la-row-mine');
				// The relative view: the score and each metric as their difference to the reference.
				const versus = reference ? E.diff(result, reference) : null;
				for (const column of columns) {
					const value = column.value(result);
					const cell =
						// The rank is an ordinal: it reads as is in the relative view too.
						versus && column.digits !== undefined && column.key !== 'rank'
							? relativeCell(
									column.key === 'score' ? versus.score : versus.metrics[column.key],
									column.digits,
									column.unit
								)
							: el(
									'td',
									column.key === 'rank' ? RANK_CELL : '',
									column.digits === undefined
										? String(value)
										: column.unit === undefined
											? format(value, column.digits)
											: measure(value, column.digits, column.unit)
								);
					if (column.key === 'score') cell.classList.add(MARK_CELL);
					// The name opens the layout's details: a button for the keyboard, the
					// row answers to the pointer too.
					if (column.key === 'name') {
						cell.replaceChildren(rowNameButton(String(value)));
						cell.classList.add(NAME_COLUMN);
					}
					if (column.key === 'name' && result.incomplete) cell.append(' ', incompleteFlag(result));
					if (column.key === 'name' && view) cell.prepend(...view.controls(result));
					// The relative view shows differences: a percentile is of a value.
					const standing =
						E.METRICS[column.key] && !versus ? libraryPercentile(column.key, value) : null;
					if (standing) cell.append(INFO.percentile(metricName(column.key), standing));
					tr.append(cell);
				}
				tr.addEventListener('click', () => showDetails(result.layout.id));
				tbody.append(tr);
			}
			table.append(thead, tbody);
			return applied;
		}

		/**
		 * The overview's worst n-grams of the layout shown in detail (else the
		 * best ranked): each bad event's heaviest pairs and trigrams, their keys
		 * outlined on its board when a row is hovered or focused (worst_groups.js).
		 */
		function renderNgrams() {
			const result =
				state.results.find((r) => r.layout.id === state.details) || state.results[0] || null;
			const box = $('la-ngrams-list');
			if (!result) {
				box.replaceChildren();
				$('la-ngrams-board').replaceChildren();
				return;
			}
			const layout = layoutOf(result.layout.id);
			// Every key uncoloured: the board only shows where the n-gram's keys are.
			const board = E.layoutKeyboard(layout, result.keyboard, result.profile || undefined);
			const flat = Object.fromEntries(board.codes.map((code) => [code, 0]));
			drawBoard($('la-ngrams-board'), result, layout, flat, {
				other: false,
				title: (code) => keyText(layout, code)
			});
			$('la-ngrams-caption').textContent = t('layout_analysis.ngrams.caption', {
				layout: result.layout.name
			});
			window.LAYOUT_ANALYSIS_WORST.draw(box, {
				groups: detailOf(result).topGroups,
				layout,
				highlight: window.LAYOUT_ANALYSIS_WORST.highlighter(() => $('la-ngrams-board')),
				// The drill-down to the corpus's words, when the corpus has a word table.
				words: state.words
					? (codes) =>
							E.wordsWithKeys(layout, state.words, codes, {
								keyboard: state.keyboard,
								profile: FINGERING.current(state.keyboard) || undefined,
								limit: TRACE_WORDS_SHOWN
							})
					: undefined
			});
		}

		/**
		 * One cell of the relative view: a difference to the reference, signed,
		 * with which side the metric prefers as a mark and in words (never by
		 * the mark alone).
		 * @param {{delta: number, verdict: string}} entry - From E.diff().
		 * @param {number} digits - The column's decimals.
		 * @param {string} [unit] - The column's unit, shown beside the difference.
		 * @returns {HTMLTableCellElement}
		 */
		function relativeCell(entry, digits, unit) {
			const marks = { better: '▲', worse: '▼', same: '=', none: '' };
			const cell = el(
				'td',
				'la-delta',
				`${entry.delta > 0 ? '+' : ''}${unit === undefined ? format(entry.delta, digits) : measure(entry.delta, digits, unit)}`
			);
			if (marks[entry.verdict]) {
				const mark = el(
					'span',
					`la-verdict la-verdict-${entry.verdict}`,
					` ${marks[entry.verdict]}`
				);
				mark.setAttribute('aria-hidden', 'true');
				cell.append(
					mark,
					el('span', 'la-sr-only', ` ${t(`layout_analysis.details.verdict_${entry.verdict}`)}`)
				);
			}
			return cell;
		}

		// The reference analysed for the relative view when it is not compared,
		// per analysis (generation) and layout id.
		let referenceAnalysis = null;

		/**
		 * The result the relative view measures against (E.referenceLayout:
		 * QWERTY on every corpus, the layout every mark is an index on): the compared one,
		 * else that layout analysed once on the same text with the same options
		 * and scored with the current weights.
		 * @returns {object|null} An analyse() result; null without a text.
		 */
		function referenceResult() {
			const id = E.referenceLayout();
			const compared = state.results.find((r) => r.layout.id === id);
			if (compared) return compared;
			if (!state.tables || !byId.has(id)) return null;
			if (
				!referenceAnalysis ||
				referenceAnalysis.generation !== generation ||
				referenceAnalysis.id !== id
			)
				referenceAnalysis = {
					generation,
					id,
					result: E.analyse(byId.get(id), state.tables, analysisOptions())
				};
			const result = referenceAnalysis.result;
			result.score = E.score(result, state.weights, state.floors, state.grades);
			return result;
		}

		// Each metric's percentile function over the library's complete layouts
		// of the current results (E.percentiles), made once per comparison.
		let percentileResults = null;
		const percentileOf = new Map();

		/**
		 * A metric value's percentile against the library (ux-study item 9): the
		 * complete library layouts of this comparison, the user's own left out;
		 * null when fewer are compared than E.PERCENTILE_MIN_REFERENCES.
		 */
		function libraryPercentile(metric, value) {
			if (percentileResults !== state.results) {
				percentileResults = state.results;
				percentileOf.clear();
			}
			if (!percentileOf.has(metric)) {
				const references = state.results
					.filter((r) => !r.incomplete && !isPersonal(r))
					.map((r) => r.metrics[metric]);
				percentileOf.set(metric, E.percentiles(metric, references));
			}
			return percentileOf.get(metric)(value);
		}

		// The families whose other members are shown while folded (not kept: a view).
		const expandedFamilies = new Set();

		/** An icon of the ranking's row controls (pin, fold); its button's name says what it does. */
		function rowIcon(path) {
			const svg = document.createElementNS(SVG_NS, 'svg');
			svg.setAttribute('viewBox', '0 0 24 24');
			svg.setAttribute('class', 'la-row-icon');
			svg.setAttribute('aria-hidden', 'true');
			svg.setAttribute('focusable', 'false');
			const line = document.createElementNS(SVG_NS, 'path');
			line.setAttribute('d', path);
			svg.append(line);
			return svg;
		}

		/**
		 * The overview ranking's view (ux-study item 14): pinned rows first in
		 * the order they were pinned, under any sort; with « Fold » on, each
		 * family shows its best member only (the lowest rank among the rows
		 * shown), with a button that shows its other members where the sort
		 * puts them.
		 */
		function rankingView(rows) {
			const pins = state.table.pins;
			const pinned = new Set(pins);
			const best = new Map();
			const members = new Map();
			for (const result of rows) {
				const family = familyOf(result);
				if (!family || pinned.has(result.layout.id)) continue;
				members.set(family, (members.get(family) || 0) + 1);
				const current = best.get(family);
				if (!current || result.rank < current.rank) best.set(family, result);
			}
			const folded = (result) => {
				const family = familyOf(result);
				return (
					state.table.fold &&
					family !== '' &&
					!pinned.has(result.layout.id) &&
					best.get(family) !== result &&
					!expandedFamilies.has(family)
				);
			};
			const togglePin = (result) => {
				const id = result.layout.id;
				state.table.pins = pinned.has(id) ? pins.filter((p) => p !== id) : pins.concat([id]);
				save();
				renderTable();
				const again = $('la-table').querySelector(`button[data-pin="${CSS.escape(id)}"]`);
				if (again) again.focus();
			};
			return {
				order(sorted) {
					const top = pins.map((id) => sorted.find((r) => r.layout.id === id)).filter(Boolean);
					return top.concat(sorted.filter((r) => !pinned.has(r.layout.id) && !folded(r)));
				},
				mark(tr, result) {
					if (pinned.has(result.layout.id)) tr.classList.add('la-row-pinned');
					const family = familyOf(result);
					if (state.table.fold && expandedFamilies.has(family) && best.get(family) !== result)
						tr.classList.add('la-row-member');
				},
				controls(result) {
					const out = [];
					const id = result.layout.id;
					const isPinned = pinned.has(id);
					const pin = el('button', 'la-row-button la-pin');
					pin.type = 'button';
					pin.dataset.pin = id;
					pin.setAttribute('aria-pressed', String(isPinned));
					pin.setAttribute(
						'aria-label',
						t(isPinned ? 'layout_analysis.table.unpin' : 'layout_analysis.table.pin', {
							name: result.layout.name
						})
					);
					pin.title = pin.getAttribute('aria-label');
					pin.append(rowIcon('M9 3h6l-1 6 4 4H6l4-4zM12 13v8'));
					pin.addEventListener('click', (event) => {
						event.stopPropagation();
						togglePin(result);
					});
					pin.addEventListener('keydown', (event) => event.stopPropagation());
					out.push(pin);
					// A layout open in « Éditer » is edited there already.
					if (!id.startsWith('editor_')) {
						const edit = el('button', 'la-row-button la-edit');
						edit.type = 'button';
						edit.dataset.edit = id;
						edit.setAttribute(
							'aria-label',
							t('layout_analysis.table.edit', { name: result.layout.name })
						);
						edit.title = edit.getAttribute('aria-label');
						edit.append(rowIcon('M4 20h4L19 9l-4-4L4 16zM14 6l4 4'));
						edit.addEventListener('click', (event) => {
							event.stopPropagation();
							editCopy(result);
						});
						edit.addEventListener('keydown', (event) => event.stopPropagation());
						out.push(edit);
					}
					const family = familyOf(result);
					const others = (members.get(family) || 0) - 1;
					if (state.table.fold && best.get(family) === result && others > 0) {
						const open = expandedFamilies.has(family);
						const fold = el('button', 'la-row-button la-fold');
						fold.type = 'button';
						fold.dataset.family = family;
						fold.dataset.count = `+${others}`;
						fold.setAttribute('aria-expanded', String(open));
						fold.setAttribute(
							'aria-label',
							t(open ? 'layout_analysis.table.collapse' : 'layout_analysis.table.expand', {
								count: others,
								name: result.layout.name
							})
						);
						fold.title = fold.getAttribute('aria-label');
						fold.append(rowIcon(open ? 'M6 15l6-6 6 6' : 'M6 9l6 6 6-6'));
						fold.addEventListener('click', (event) => {
							event.stopPropagation();
							if (open) expandedFamilies.delete(family);
							else expandedFamilies.add(family);
							renderTable();
							const again = $('la-table').querySelector(
								`button[data-family="${CSS.escape(family)}"]`
							);
							if (again) again.focus();
						});
						fold.addEventListener('keydown', (event) => event.stopPropagation());
						out.push(fold);
					}
					return out;
				}
			};
		}

		// The overview ranking as last drawn (rankingView with its rows and columns).
		let lastRanking = null;
		const RANKING_CSV_FILE = 'ergopti-ranking.csv';
		// A value's decimals in the CSV: the raw value, not the page's rounding.
		const CSV_DIGITS = 6;

		/** One CSV field (RFC 4180), a text a spreadsheet would read as a formula made inert. */
		function csvField(value) {
			if (typeof value === 'number') return String(Number(value.toFixed(CSV_DIGITS)));
			let text = String(value);
			if (/^[=+\-@\t\r]/.test(text)) text = `'${text}`;
			return /[",\r\n;]/.test(text) ? `"${text.replace(/"/g, '""')}"` : text;
		}

		/**
		 * The ranking as shown (ux-study item 16): its rows in their order (the
		 * sort, the pinned rows, the folded families) and its columns, each
		 * value as the engine computed it (a dot for decimals, not rounded as
		 * the page shows it), the headers in the page's language.
		 * @returns {string} CSV text, one line per row, ending with a newline.
		 */
		function rankingCsv() {
			if (!lastRanking || !lastRanking.shown) throw new Error('layout_analysis: no ranking drawn');
			const { columns, shown } = lastRanking;
			const lines = [columns.map((c) => csvField(c.label))].concat(
				shown.map((result) => columns.map((c) => csvField(c.value(result))))
			);
			return `${lines.map((cells) => cells.join(',')).join('\r\n')}\r\n`;
		}

		/** « Download the table (CSV) »: the host's download path in the app, a browser download on the site. */
		async function downloadRanking() {
			const status = $('la-table-csv-status');
			const text = `\ufeff${rankingCsv()}`;
			if (typeof HOST.saveFile === 'function') {
				try {
					const where = await HOST.saveFile(RANKING_CSV_FILE, text);
					status.className = 'la-muted';
					status.textContent = t('layout_analysis.table.csv_saved', { path: where });
				} catch (error) {
					status.className = 'la-error';
					status.textContent = t('layout_analysis.table.csv_failed', {
						code: (error && error.code) || String(error)
					});
				}
				return;
			}
			const url = URL.createObjectURL(new Blob([text], { type: 'text/csv;charset=utf-8' }));
			const link = el('a');
			link.href = url;
			link.download = RANKING_CSV_FILE;
			document.body.append(link);
			link.click();
			link.remove();
			setTimeout(() => URL.revokeObjectURL(url), 0);
			status.className = 'la-muted';
			status.textContent = t('layout_analysis.table.csv_downloaded', { name: RANKING_CSV_FILE });
		}

		/** The overview's ranking table, with the viewer's columns and the filters' rows. */
		function renderTable() {
			const reference = state.results.length > 0 ? referenceResult() : null;
			const toggle = $('la-table-relative');
			toggle.checked = state.table.relative;
			toggle.disabled = reference === null;
			const name = reference ? reference.layout.name : '';
			setText(
				$('la-table-relative-label'),
				t('layout_analysis.table.relative', {
					layout: name
				})
			);
			const help = $('la-table-relative-help');
			help.hidden = !state.table.relative || reference === null;
			help.textContent = t('layout_analysis.table.relative_help', { layout: name });
			state.sort = rankingTable(
				$('la-table'),
				shownRows(),
				state.table.columns,
				state.sort,
				(sort) => {
					state.sort = sort;
					renderTable();
				},
				state.table.relative ? reference : null,
				(lastRanking = rankingView(shownRows()))
			);
			$('la-table-csv').disabled = state.results.length === 0;
			$('la-table-fold').checked = state.table.fold;
		}

		/**
		 * A bar of one result in a figure from zero: the user's own layouts in the
		 * accent colour, an incomplete one faded with its flag in words. Read as a
		 * table row (barRow) whose name is the button opening the layout's details.
		 */
		function resultBar(result, value, scale, text) {
			const track = el('td', 'la-chart-track');
			const bar = el('span', isPersonal(result) ? 'la-bar la-bar-mine' : 'la-bar la-bar-score');
			bar.style.left = '0';
			bar.style.width = `${scale > 0 ? Math.max(0, Math.min(100, (value / scale) * 100)) : 0}%`;
			track.append(bar);
			const flag = result.incomplete ? incompleteFlag(result) : null;
			const row = barRow(result.layout.name, track, text, undefined, result.layout.id);
			if (flag) {
				row.classList.add('la-incomplete');
				rowName(row).append(' ', flag);
			}
			if (state.details === result.layout.id) row.classList.add('la-selected');
			if (state.versus === result.layout.id) row.classList.add('la-versus');
			row.title = `${result.layout.name}: ${text}${flag ? ` (${flag.textContent})` : ''}`;
			return row;
		}

		/**
		 * The results ordered for a figure of one value: complete layouts first
		 * (incomplete ones rank last everywhere), each group by the value, the
		 * better first (the larger first for a value not scored), then by rank.
		 */
		function figureOrder(rows, value, better) {
			const sign = better === 'lower' ? 1 : -1;
			return rows
				.slice()
				.sort(
					(a, b) =>
						Number(a.incomplete) - Number(b.incomplete) ||
						sign * (value(a) - value(b)) ||
						a.rank - b.rank
				);
		}

		/** One metric's bar chart over the results shown: named, its direction in words. */
		function metricChart(id, rows) {
			const section = el('section', 'la-figure');
			const titleId = `la-chart-${id}`;
			const title = el('h3', '', `${metricName(id)} (${unitText(id)})`);
			title.id = titleId;
			if (DATA.sources.items[id]) title.append(' ', infoButton(id));
			section.setAttribute('aria-labelledby', titleId);
			const better = E.METRICS[id].better;
			section.append(title, el('p', 'la-muted la-direction', DIRECTION_LABEL[better]()));
			const box = barTable();
			box.setAttribute('aria-labelledby', titleId);
			const sorted = figureOrder(rows, (r) => r.metrics[id], better);
			const shown = sorted.slice(0, CHART_MAX_BARS);
			const scale = Math.max(...shown.map((r) => r.metrics[id]), 0);
			const digits = metricDigits(id);
			const unit = unitText(id);
			for (const result of shown)
				box.append(
					resultBar(result, result.metrics[id], scale, measure(result.metrics[id], digits, unit))
				);
			section.append(box);
			if (sorted.length > shown.length) section.append(moreNote(shown.length, sorted.length));
			return section;
		}

		/** A themed tab's sortable table: rank, layout, score and the tab's metrics. */
		function metricTable(name, metricIds, rows) {
			const section = el('section', 'la-figure la-figure-wide');
			const titleId = `la-table-${name}-label`;
			const title = el('h3', '', t('layout_analysis.heat.table'));
			title.id = titleId;
			// The scrolling box is the region named by the title, the section only groups.
			const wrap = el('section', 'la-table-wrap');
			wrap.tabIndex = 0;
			wrap.setAttribute('aria-labelledby', titleId);
			const table = el('table', 'la-table');
			table.id = `la-table-${name}`;
			wrap.append(table);
			section.append(title, wrap);
			const sortOf = () => state.tabSorts[name] || { key: 'rank', descending: false };
			const draw = (target) =>
				rankingTable(target, rows, metricIds, sortOf(), (sort) => {
					state.tabSorts[name] = sort;
					draw($(`la-table-${name}`));
				});
			draw(table);
			return section;
		}

		/** A themed tab: one chart per metric, then the table of them all. */
		function renderMetricTab(tab) {
			const rows = shownRows();
			const grid = $(`la-charts-${tab}`);
			grid.replaceChildren();
			if (rows.length === 0) return;
			grid.append(
				...TAB_METRICS[tab].map((id) => metricChart(id, rows)),
				metricTable(tab, TAB_METRICS[tab], rows)
			);
		}

		/**
		 * A table header row of sort buttons over a table of its own (a heat
		 * table): the sort is the viewer's, kept in state.tabSorts[name].
		 */
		function tabSortHead(columns, name, redraw) {
			tabSort(name);
			return sortableHead(columns, null, redraw, {
				get: () => state.tabSorts[name],
				set: (sort) => {
					state.tabSorts[name] = sort;
				}
			});
		}

		/** A tab table's sort, by rank until the viewer chooses a column. */
		function tabSort(name) {
			if (!state.tabSorts[name]) state.tabSorts[name] = { key: 'rank', descending: false };
			return state.tabSorts[name];
		}

		/** Sorts rows by the column a tab table's sort names. */
		function sortedBy(rows, columns, sort) {
			const column = columns.find((c) => c.key === sort.key) || columns[0];
			return rows.slice().sort((a, b) => {
				const x = column.value(a);
				const y = column.value(b);
				const order = typeof x === 'string' ? x.localeCompare(y) : x - y;
				return sort.descending ? -order : order;
			});
		}

		/**
		 * A table row's layout name, the native control that opens its details
		 * (Enter, Space or a click, which reaches the row's own listener).
		 */
		function rowNameButton(name) {
			const button = el('button', 'la-row-name', name);
			button.type = 'button';
			return button;
		}

		/** A row of a heat table: the layout as its header, opening its details. */
		function heatTableRow(result) {
			const tr = el('tr');
			if (state.details === result.layout.id) tr.className = 'la-selected';
			const th = el('th', NAME_COLUMN);
			th.append(rowNameButton(result.layout.name));
			th.scope = 'row';
			if (result.incomplete) th.append(' ', incompleteFlag(result));
			tr.append(th);
			tr.addEventListener('click', () => showDetails(result.layout.id));
			return tr;
		}

		/**
		 * Finger load against the ideal, every layout shown: each finger's share
		 * of the non-thumb presses, its gap to the ideal written under it (signed),
		 * the cell orange above the ideal and blue below, stronger with the gap,
		 * mixed into the neutral surface. The ideal load is the first row.
		 */
		function renderFingerTable() {
			const table = $('la-finger-table');
			const rows = shownRows();
			table.replaceChildren();
			if (rows.length === 0) return;
			const ideal = rows[0].idealLoad;
			const fingers = Object.keys(ideal);
			const columns = [
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name }
			]
				.concat(
					fingers.map((id) => ({
						key: id,
						label: t(`layout_analysis.finger.${id}`),
						numeric: true,
						value: (r) => r.fingerShares[id]
					}))
				)
				.concat([
					{
						key: 'finger_imbalance',
						label: metricName('finger_imbalance'),
						numeric: true,
						value: (r) => r.metrics.finger_imbalance
					},
					{
						key: 'rank',
						label: t('layout_analysis.table.rank'),
						numeric: true,
						value: (r) => r.rank
					}
				]);
			const thead = tabSortHead(columns, 'fingers_load', renderFingerTable);
			const extent = Math.max(
				...rows.flatMap((r) => fingers.map((id) => Math.abs(r.fingerShares[id] - ideal[id]))),
				1e-9
			);
			const tbody = el('tbody');
			const idealRow = el('tr', 'la-ideal-row');
			const idealHead = el('th', '', t('layout_analysis.details.ideal_mark'));
			idealHead.scope = 'row';
			idealRow.append(idealHead, ...fingers.map((id) => el('td', '', measure(ideal[id], 1, '%'))));
			idealRow.append(el('td'), el('td'));
			tbody.append(idealRow);
			for (const result of sortedBy(rows, columns, tabSort('fingers_load'))) {
				const tr = heatTableRow(result);
				for (const id of fingers) {
					const value = result.fingerShares[id];
					// A gap that rounds to zero is written without a sign (never « -0.0 »).
					const gap = Math.abs(value - ideal[id]) < 0.05 ? 0 : value - ideal[id];
					const td = el(
						'td',
						`la-cell ${gap > 0 ? 'la-cell-over' : gap < 0 ? 'la-cell-under' : ''}`
					);
					td.style.setProperty(
						'--la-share',
						`${Math.round((Math.abs(gap) / extent) * HEAT_DIFF_MAX_SHARE * 100)}%`
					);
					const signed = `${gap > 0 ? '+' : ''}${format(gap, 1)}`;
					td.append(measure(value, 1, '%'), el('small', 'la-gap', signed));
					td.title = `${t(`layout_analysis.finger.${id}`)}: ${measure(value, 1, '%')} (${t(
						'layout_analysis.details.ideal_mark'
					)} ${measure(ideal[id], 1, '%')}, ${signed})`;
					tr.append(td);
				}
				tr.append(
					el(
						'td',
						'',
						measure(
							result.metrics.finger_imbalance,
							metricDigits('finger_imbalance'),
							unitText('finger_imbalance')
						)
					),
					el('td', RANK_CELL, format(result.rank, 0))
				);
				tbody.append(tr);
			}
			table.append(thead, tbody);
		}

		/**
		 * Hand balance, the most balanced first: each layout's left and right
		 * shares of the non-thumb presses in one bar (two categorical slots, a
		 * surface gap between them), the middle marked, both values written.
		 */
		function renderHands() {
			const box = $('la-hands');
			box.replaceChildren();
			const left = t('layout_analysis.details.hand_left');
			const right = t('layout_analysis.details.hand_right');
			$('la-hands-legend').replaceChildren(
				legendItem('la-swatch-cat-1', left),
				legendItem('la-swatch-cat-2', right)
			);
			const sorted = figureOrder(shownRows(), (r) => r.metrics.hand_imbalance, 'lower');
			const shown = sorted.slice(0, CHART_MAX_BARS);
			moreNoteAfter(box, shown.length, sorted.length);
			for (const result of shown) {
				const track = el('td', 'la-chart-track la-stack');
				const share = result.hands.left;
				const leftBar = el('span', 'la-bar la-seg la-seg-1');
				leftBar.style.left = '0';
				leftBar.style.width = `${share}%`;
				const rightBar = el('span', 'la-bar la-seg la-seg-2');
				rightBar.style.left = `${share}%`;
				rightBar.style.width = `${result.hands.right}%`;
				const middle = el('span', 'la-target');
				middle.style.left = '50%';
				track.append(leftBar, rightBar, middle);
				const text = `${measure(result.hands.left, 1, '%')} · ${measure(result.hands.right, 1, '%')}`;
				const row = barRow(
					result.layout.name,
					track,
					text,
					` (${left} ${measure(result.hands.left, 1, '%')}, ${right} ${measure(result.hands.right, 1, '%')})`,
					result.layout.id
				);
				if (result.incomplete) {
					row.classList.add('la-incomplete');
					rowName(row).append(' ', incompleteFlag(result));
				}
				if (state.details === result.layout.id) row.classList.add('la-selected');
				if (state.versus === result.layout.id) row.classList.add('la-versus');
				row.title = `${result.layout.name}: ${left} ${measure(result.hands.left, 1, '%')}, ${right} ${measure(result.hands.right, 1, '%')}`;
				box.append(row);
			}
		}

		/** A legend entry: a swatch of a class and its name. */
		function legendItem(swatch, label) {
			const item = el('li');
			item.append(swatchMark(swatch), label);
			return item;
		}

		/** A heat scale's ramp between its two ends: drawn only, the ends are its text. */
		function heatRamp() {
			const ramp = el('span', 'la-heat-ramp');
			ramp.setAttribute('aria-hidden', 'true');
			return ramp;
		}

		/** One item of a value list holding its labelled field (style.css la-weight-item). */
		function weightItem(node) {
			const item = el('li', 'la-weight-item');
			item.append(node);
			return item;
		}

		/** A legend's colour sample: drawn only, its entry's words say what it stands for. */
		function swatchMark(swatch) {
			const mark = el('span', `la-swatch ${swatch}`);
			mark.setAttribute('aria-hidden', 'true');
			return mark;
		}

		/**
		 * A stacked figure: each layout shown (ranking order) in one bar split
		 * into its parts (categorical slots in a fixed order, a surface gap
		 * between them), with a legend, and its values as a folded table.
		 * @param {HTMLElement} box
		 * @param {Array<{id: string, label: string}>} parts
		 * @param {function(object, string): number} value A result's share of a part (%).
		 * @param {string} name Its tables' name (the sort's).
		 * @param {string|null} written The part whose value is written beside
		 *   each bar (the home row), or null when no part speaks for the bar.
		 */
		function stackedFigure(box, parts, value, name, written) {
			box.replaceChildren();
			const rows = shownRows();
			if (rows.length === 0) return;
			const legend = el('ul', 'la-legend');
			parts.forEach((part, i) => legend.append(legendItem(`la-swatch-cat-${i + 1}`, part.label)));
			const bars = barTable();
			bars.setAttribute('aria-labelledby', box.closest('section').getAttribute('aria-labelledby'));
			const shown = rows.slice(0, CHART_MAX_BARS);
			for (const result of shown) {
				const track = el('td', 'la-chart-track la-stack');
				let at = 0;
				parts.forEach((part, i) => {
					const share = value(result, part.id);
					const segment = el('span', `la-bar la-seg la-seg-${i + 1}`);
					segment.style.left = `${at}%`;
					segment.style.width = `${Math.max(0, share)}%`;
					at += Math.max(0, share);
					track.append(segment);
				});
				const said = parts
					.map((part) => `${part.label} ${measure(value(result, part.id), 1, '%')}`)
					.join(', ');
				// One part's value beside the bar at most; all of them are in the title and the table.
				const row = barRow(
					result.layout.name,
					track,
					written ? measure(value(result, written), 1, '%') : '',
					` (${said})`,
					result.layout.id
				);
				if (result.incomplete) {
					row.classList.add('la-incomplete');
					rowName(row).append(' ', incompleteFlag(result));
				}
				if (state.details === result.layout.id) row.classList.add('la-selected');
				if (state.versus === result.layout.id) row.classList.add('la-versus');
				row.title = `${result.layout.name}: ${said}`;
				bars.append(row);
			}
			const tableBox = el('details', 'la-section');
			const summary = el('summary', '', t('layout_analysis.heat.table'));
			summary.id = `la-table-${name}-name`;
			tableBox.append(summary);
			// The scrolling box is a region named by its figure and its fold, so the
			// tables of two figures are told apart in the landmarks.
			const wrap = el('section', 'la-table-wrap');
			wrap.tabIndex = 0;
			wrap.setAttribute(
				'aria-labelledby',
				`${box.closest('section').getAttribute('aria-labelledby')} ${summary.id}`
			);
			const table = el('table', 'la-table');
			table.id = `la-table-${name}`;
			wrap.append(table);
			tableBox.append(wrap);
			const columns = [
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name }
			]
				.concat(
					parts.map((part) => ({
						key: part.id,
						label: part.label,
						numeric: true,
						value: (r) => value(r, part.id)
					}))
				)
				.concat([
					{
						key: 'rank',
						label: t('layout_analysis.table.rank'),
						numeric: true,
						value: (r) => r.rank
					}
				]);
			const drawTable = () => {
				const target = $(`la-table-${name}`) || table;
				const tbody = el('tbody');
				for (const result of sortedBy(rows, columns, tabSort(name))) {
					const tr = heatTableRow(result);
					for (const part of parts)
						tr.append(el('td', '', measure(value(result, part.id), 1, '%')));
					tr.append(el('td', RANK_CELL, format(result.rank, 0)));
					tbody.append(tr);
				}
				target.replaceChildren(tabSortHead(columns, name, drawTable), tbody);
			};
			box.append(legend, bars);
			if (rows.length > shown.length) box.append(moreNote(shown.length, rows.length));
			box.append(tableBox);
			drawTable();
		}

		/** How the trigrams split into their six classes, layout by layout. */
		function renderTrigramMix() {
			stackedFigure(
				$('la-trigram-mix'),
				TRIGRAM_MIX.map((id) => ({ id, label: trigramClassName(id) })),
				(result, id) => result.trigramClasses[id],
				'trigram_mix',
				null
			);
		}

		/** Each layout's presses on the number, top, home and bottom rows. */
		function renderRowMix() {
			stackedFigure(
				$('la-row-mix'),
				ROW_MIX.map((id) => ({ id, label: metricName(id) })),
				(result, id) => result.metrics[id],
				'row_mix',
				'home_row'
			);
		}

		/**
		 * Each finger's travel (mm per typed character), every layout shown, on
		 * one blue ramp from zero to the longest; the total is the distance.
		 */
		function renderTravelTable() {
			const table = $('la-travel-table');
			const rows = shownRows();
			table.replaceChildren();
			$('la-travel-legend').replaceChildren();
			if (rows.length === 0) return;
			const fingers = Object.keys(rows[0].fingerDistance);
			const mm = t('layout_analysis.unit.mm');
			const columns = [
				{ key: 'name', label: t('layout_analysis.table.layout'), value: (r) => r.layout.name }
			]
				.concat(
					fingers.map((id) => ({
						key: id,
						label: t(`layout_analysis.finger.${id}`),
						numeric: true,
						value: (r) => r.fingerDistance[id]
					}))
				)
				.concat([
					{
						key: 'distance',
						label: metricName('distance'),
						numeric: true,
						value: (r) => r.metrics.distance
					},
					{
						key: 'rank',
						label: t('layout_analysis.table.rank'),
						numeric: true,
						value: (r) => r.rank
					}
				]);
			const extent = Math.max(...rows.flatMap((r) => fingers.map((id) => r.fingerDistance[id])), 0);
			const tbody = el('tbody');
			for (const result of sortedBy(rows, columns, tabSort('travel'))) {
				const tr = heatTableRow(result);
				for (const id of fingers) {
					const value = result.fingerDistance[id];
					const share = extent > 0 ? value / extent : 0;
					const td = el('td', 'la-cell la-cell-count', measure(value, 2, mm));
					td.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
					td.title = `${t(`layout_analysis.finger.${id}`)}: ${measure(value, 2, mm)}`;
					tr.append(td);
				}
				tr.append(
					el('td', '', measure(result.metrics.distance, metricDigits('distance'), mm)),
					el('td', RANK_CELL, format(result.rank, 0))
				);
				tbody.append(tr);
			}
			table.append(tabSortHead(columns, 'travel', renderTravelTable), tbody);
			$('la-travel-legend').replaceChildren(measure(0, 2, mm), heatRamp(), measure(extent, 2, mm));
		}

		/**
		 * The side-by-side heat maps: the first boards of the results shown (the
		 * ranking's order), each layout on its own board coloured by the chosen
		 * per-key value, on one scale for all or each on its own; each board has
		 * its values as a folded table and opens the layout's details.
		 */
		function renderHeatGrid() {
			const grid = $('la-heats');
			grid.replaceChildren();
			$('la-heats-legend').replaceChildren();
			const { metric, count, shared } = state.heats;
			const boards = shownRows()
				.slice(0, count)
				.map((result) => ({ result, values: heatValuesOf(result, metric, null) }));
			if (boards.length === 0) return;
			const unit = heatUnit(metric);
			// The levels of every board drawn; a board without the chosen one shows no character.
			const level = fillSelect(
				$('la-heats-level'),
				levelChoices(boards.map((b) => layoutOf(b.result.layout.id))),
				state.heats.level
			);
			// The space bar takes a share of the presses no other key comes near: the
			// scale is the other keys', and the space bar is drawn at its darkest.
			// A held key the layout types on (Caps Lock) is one of its keys.
			const extentOf = (values, layout) => {
				const modifiers = new Set(E.heldCodesOf(layout));
				return Math.max(
					...Object.entries(values)
						.filter(([code]) => !modifiers.has(code) && code !== SPACE_CODE)
						.map(([, v]) => Math.abs(v)),
					0
				);
			};
			const common = Math.max(
				...boards.map((b) => extentOf(b.values, layoutOf(b.result.layout.id))),
				0
			);
			const ramp = (extent) => [
				measure(0, HEAT_DIGITS, unit),
				heatRamp(),
				`≥ ${measure(extent, HEAT_DIGITS, unit)}`
			];
			if (shared)
				$('la-heats-legend').replaceChildren(
					...ramp(common),
					el('small', 'la-muted', t('layout_analysis.heat.scale', { metric: heatName(metric) }))
				);
			for (const { result, values } of boards) {
				const layout = layoutOf(result.layout.id);
				const card = el(
					'section',
					isPersonal(result) ? 'la-figure la-heat-card la-heat-mine' : 'la-figure la-heat-card'
				);
				const titleId = `la-heats-${grid.children.length}`;
				const title = el('h3');
				title.id = titleId;
				const open = el(
					'button',
					'la-link-button',
					t('layout_analysis.details.title', { layout: result.layout.name, rank: result.rank })
				);
				open.type = 'button';
				open.addEventListener('click', () => showDetails(result.layout.id));
				title.append(open);
				if (result.incomplete) title.append(' ', incompleteFlag(result));
				card.setAttribute('aria-labelledby', titleId);
				const box = el('div', 'la-heatmap la-heatmap-small');
				const extent = shared ? common : extentOf(values, layout);
				const tableRows = drawBoard(box, result, layout, values, {
					extent,
					other: false,
					level,
					title: (code, value, shown) =>
						`${shown} · ${heatName(metric)}: ${measure(value, HEAT_DIGITS, unit)}`
				});
				card.append(title, box);
				// Each card's heatmap as a PNG or SVG image (board_image.js).
				card.append(
					window.LAYOUT_BOARD_IMAGE.buttons({
						id: `la-heat-image-${titleId}`,
						board: () => box,
						options: () => ({
							title: `${result.layout.name} · ${heatName(metric)}`,
							words: [result.layout.name, 'heatmap', metric]
						})
					})
				);
				if (!shared) {
					const legend = el('p', 'la-heat-legend');
					legend.append(...ramp(extent));
					card.append(legend);
				}
				const tableBox = el('details', 'la-section');
				const summary = el('summary', '', t('layout_analysis.heat.table'));
				summary.id = `${titleId}-table`;
				tableBox.append(summary);
				// The scrolling box is a region named by its board and its fold.
				const wrap = el('section', 'la-table-wrap');
				wrap.tabIndex = 0;
				wrap.setAttribute('aria-labelledby', `${titleId} ${summary.id}`);
				const table = el('table', 'la-table');
				heatTableInto(table, layout, tableRows, metric, false);
				wrap.append(table);
				tableBox.append(wrap);
				card.append(tableBox);
				grid.append(card);
			}
		}

		/** The layout list of « One layout »: every compared layout, in the ranking's order. */
		function fillDetailsPick() {
			// Before the first results (a link's layout waits for them) nothing is replaced.
			if (state.results.length > 0 && !state.results.some((r) => r.layout.id === state.details))
				state.details = state.results[0].layout.id;
			fillSelect(
				$('la-details-layout'),
				state.results.length > 0
					? state.results.map((r) => [r.layout.id, `${format(r.rank, 0)}. ${r.layout.name}`])
					: [['', t('layout_analysis.status.empty')]],
				state.details || ''
			);
		}

		/** Opens a layout's details in « One layout ». */
		function showDetails(id) {
			state.details = id;
			if (state.versus === id) state.versus = null;
			state.tab = DETAILS_TAB;
			showTab();
			render();
			$('la-tabs').scrollIntoView({ block: 'nearest' });
		}

		/**
		 * Bars around zero: one per entry, labelled, signed (points gained in
		 * the gain colour, lost in the loss colour, the value's sign written).
		 */
		function signedBars(box, entries, digits, unit) {
			box.replaceChildren();
			const extent = Math.max(...entries.map(([, v]) => Math.abs(v)), 1e-9);
			for (const [label, value] of entries) {
				const track = el('td', 'la-chart-track la-signed');
				const bar = el('span', value >= 0 ? 'la-bar la-bar-gain' : 'la-bar la-bar-loss');
				const width = (Math.abs(value) / extent) * 50;
				bar.style.left = value >= 0 ? '50%' : `${50 - width}%`;
				bar.style.width = `${width}%`;
				track.append(bar);
				const text = withUnit(`${value > 0 ? '+' : ''}${format(value, digits)}`, unit);
				const row = barRow(label, track, text);
				row.title = `${label}: ${text}`;
				box.append(row);
			}
		}

		/**
		 * A bar figure's table, named by its heading. Its rows are laid out as a
		 * grid (style.css), which drops a table's implicit roles in some
		 * browsers, so the table, its rows and cells state them.
		 * @returns {HTMLTableElement}
		 */
		function barTable() {
			const table = el('table', 'la-bars');
			table.setAttribute('role', 'table');
			return table;
		}

		/**
		 * One bar of a figure, a row of its table (barTable, or a la-bars table
		 * of the markup): the label is its row header, the value its cell, the
		 * drawn bar hidden (it repeats the value). With a layout to open, the
		 * label is the button opening that layout's details, and a click
		 * anywhere on the row does the same.
		 * @param {string} label
		 * @param {HTMLTableCellElement} track The drawn bar, a td.
		 * @param {string} text The value as written beside the bar.
		 * @param {string} [spoken] What the cell adds for a screen reader only:
		 *   the unit, the ideal load.
		 * @param {string} [open] The id of the layout the row opens.
		 * @returns {HTMLTableRowElement}
		 */
		function barRow(label, track, text, spoken, open) {
			const row = el('tr', 'la-chart-row');
			row.setAttribute('role', 'row');
			const header = el('th', 'la-chart-label');
			header.scope = 'row';
			header.setAttribute('role', 'rowheader');
			if (open === undefined) header.append(label);
			else {
				const button = el('button', 'la-chart-name', label);
				button.type = 'button';
				header.append(button);
				row.classList.add('la-clickable');
				// The button's own activation (Enter, Space, a click) reaches the row too.
				row.addEventListener('click', () => showDetails(open));
			}
			track.setAttribute('aria-hidden', 'true');
			const value = el('td', 'la-chart-value', text);
			value.setAttribute('role', 'cell');
			if (spoken) value.append(el('span', 'la-sr-only', spoken));
			row.append(header, track, value);
			return row;
		}

		/** Where a bar row writes its layout's name: its button, else its header. */
		function rowName(row) {
			return row.querySelector('.la-chart-name') || row.firstChild;
		}

		/**
		 * Magnitude bars from zero, in one colour, each with an optional target
		 * mark (the ideal finger load); the value is written in its unit.
		 * @param {HTMLElement} box
		 * @param {Array<{label: string, value: number, target?: number, text?: string}>} entries
		 *   text: the value as written, when it is not the value in its unit.
		 * @param {number} scale The value a full bar stands for.
		 * @param {{unit?: string, digits?: number}} [written] The unit (%) and
		 *   decimals (1) of the values.
		 */
		function loadBars(box, entries, scale, written) {
			const unit = (written && written.unit) || '%';
			const digits = written && written.digits !== undefined ? written.digits : 1;
			const value = (v) => measure(v, digits, unit);
			box.replaceChildren();
			for (const entry of entries) {
				const track = el('td', 'la-chart-track');
				const bar = el('span', 'la-bar la-bar-load');
				bar.style.left = '0';
				bar.style.width = `${scale > 0 ? Math.min(100, (entry.value / scale) * 100) : 0}%`;
				track.append(bar);
				const text = entry.text === undefined ? value(entry.value) : entry.text;
				// The ideal mark is drawn only: a screen reader hears it with the value.
				let ideal = '';
				if (entry.target !== undefined) {
					const mark = el('span', 'la-target');
					mark.style.left = `${Math.min(100, (entry.target / scale) * 100)}%`;
					track.append(mark);
					ideal = ` (${t('layout_analysis.details.ideal_mark')}: ${value(entry.target)})`;
				}
				const row = barRow(entry.label, track, text, ideal);
				row.title = `${entry.label}: ${text}${ideal}`;
				box.append(row);
			}
		}

		/** A metric's unit as written beside its value. */
		function unitText(id) {
			return INFO.metricUnit(id);
		}

		/**
		 * What a key types on one level, as a board's key shows it: a dead key its
		 * bare accent (what it types alone), nothing when the level types none.
		 * @param {object} layout
		 * @param {string} code
		 * @param {number} level - The level's index in the layout's rows (-1: none).
		 * @returns {string}
		 */
		function levelText(layout, code, level) {
			if (code === 'Space' && level === 0) return '␣';
			const cell = level < 0 ? null : (layout.rows[code] || [])[level];
			if (cell && typeof cell === 'object')
				return (
					KEY_LEGEND.deadKeyText(((layout.dead || {})[cell.dead] || {})[' '] || '') || cell.dead
				);
			return typeof cell === 'string' ? cell : '';
		}

		/** What a key types on its base layer, as the heatmap and the tables show it. */
		function keyText(layout, code) {
			return levelText(layout, code, 0) || code;
		}

		/** A level's choice key: Shift and the modifiers it holds by name (« shift+mod3 »). */
		function levelKey(level) {
			const parts = (level.shift ? ['shift'] : []).concat(level.hold);
			return parts.length === 0 ? LEVEL_BASE : parts.join('+');
		}

		/** A level's words: Base, Shift, its modifiers' labels (Mod3, Shift + Mod4…). */
		function levelName(level) {
			if (level.hold.length === 0)
				return t(level.shift ? 'layout_analysis.level.shift' : 'layout_analysis.level.base');
			const modifiers = level.labels.join(' + ');
			return level.shift ? t('layout_analysis.level.shift_with', { modifiers }) : modifiers;
		}

		/**
		 * The level choices of a set of layouts: every level one of them has, in
		 * the order the layouts list them (the four default levels, then Neo's
		 * Mod3, Mod4…), each with its words.
		 * @param {object[]} shown - The layouts drawn.
		 * @returns {Array<[string, string]>} [key, words] for fillSelect.
		 */
		function levelChoices(shown) {
			const choices = new Map();
			for (const layout of shown)
				for (const level of E.levelsOf(layout))
					if (!choices.has(levelKey(level))) choices.set(levelKey(level), levelName(level));
			return Array.from(choices);
		}

		/** The index of a level choice in a layout's rows, -1 when the layout has none. */
		function levelIndex(layout, key) {
			return E.levelsOf(layout).findIndex((level) => levelKey(level) === key);
		}

		/**
		 * What a key types on each of its levels, in words: « Shift L, Mod3 [,
		 * Mod3 + Mod4 Λ », the levels it types nothing on left out; a board's key
		 * names every level, whichever one it shows.
		 */
		function levelsSpoken(layout, code) {
			return E.levelsOf(layout)
				.map((level, index) => [level, levelText(layout, code, index)])
				.filter(([, text]) => text !== '')
				.map(([level, text]) => `${levelName(level)} ${text}`)
				.join(', ');
		}

		/** The name of a heatmap choice. */
		function heatName(id) {
			if (id === HEAT_PRESSES) return t('layout_analysis.heat.presses');
			if (id === HEAT_SCORE) return t('layout_analysis.panel.heat.score');
			return t(`layout_analysis.metric.${id}`);
		}

		/** The unit of a heatmap choice's values. */
		function heatUnit(id) {
			if (id === HEAT_PRESSES) return '%';
			if (id === HEAT_SCORE) return t('layout_analysis.unit.points');
			return unitText(id);
		}

		/**
		 * Each key's value for the chosen heatmap: the engine's per-key value
		 * (keyValues) or the points it costs the score (keyScoreCost); with a
		 * layout to compare with and the difference asked for, this layout's
		 * value minus the other's on the same physical key (keyDiff).
		 * @returns {object} code → value.
		 */
		function heatValues(detail, other) {
			return heatValuesOf(detail, state.heat, other);
		}

		/** Each key's value of a heatmap choice for one result (heatValues), any choice. */
		function heatValuesOf(result, metric, other) {
			if (metric === HEAT_SCORE) {
				const own = E.keyScoreCost(result, state.weights, state.floors, state.grades);
				if (!other) return own;
				const theirs = E.keyScoreCost(other, state.weights, state.floors, state.grades);
				return Object.fromEntries(Object.keys(own).map((code) => [code, own[code] - theirs[code]]));
			}
			return other ? E.keyDiff(result, other, metric) : E.keyValues(result, metric);
		}

		/**
		 * A key's tooltip line: its value in the chosen unit, then its worst
		 * groups for a bad event, or the metrics it costs the most points on.
		 */
		function heatTitle(detail, layout, code, value, signed, shown) {
			const unit = heatUnit(state.heat);
			const written = `${signed && value > 0 ? '+' : ''}${measure(value, HEAT_DIGITS, unit)}`;
			let title = `${shown} · ${heatName(state.heat)}: ${written}`;
			if (signed) return title;
			const key = detail.keys[code];
			if (E.KEY_EVENTS.includes(state.heat) && key.worst[state.heat].length > 0) {
				const groups = key.worst[state.heat]
					.map(
						([others, share]) =>
							`${[code]
								.concat(others)
								.map((c) => keyText(layout, c))
								.join(' ')} ${measure(share, HEAT_DIGITS, '%')}`
					)
					.join(', ');
				title += ` — ${t('layout_analysis.panel.heat.worst', { groups })}`;
			} else if (state.heat === HEAT_SCORE) {
				const used = Object.assign(E.defaultWeights(), state.weights);
				const parts = E.KEY_COST_METRICS.map((id) => [id, (used[id] || 0) * key.cost[id]])
					.filter(([, part]) => part > 0)
					.sort((a, b) => b[1] - a[1])
					.slice(0, HEAT_SCORE_PARTS)
					.map(([id, part]) => `${t(`layout_analysis.metric.${id}`)} ${format(part, HEAT_DIGITS)}`);
				if (parts.length > 0) title += ` (${parts.join(' · ')})`;
			}
			return title;
		}

		/**
		 * Where each drawn key is, in words a screen reader and the table can
		 * say: its row from the top and its rank from the left in that row.
		 * @param {{codes: string[], x: number[], y: number[]}} board
		 * @param {string[]} shown The drawn codes.
		 * @returns {Map<string, {row: number, column: number}>}
		 */
		function keyPositions(board, shown) {
			const drawn = new Set(shown);
			const keys = board.codes
				.map((code, k) => ({ code, x: board.x[k], y: board.y[k] }))
				.filter((key) => drawn.has(key.code));
			const rows = Array.from(new Set(keys.map((key) => key.y))).sort((a, b) => a - b);
			const out = new Map();
			rows.forEach((y, r) => {
				keys
					.filter((key) => key.y === y)
					.sort((a, b) => a.x - b.x)
					.forEach((key, c) => out.set(key.code, { row: r + 1, column: c + 1 }));
			});
			return out;
		}

		/**
		 * The heatmap's numbers as a table, its text alternative: every drawn
		 * key with its place, its finger and its value, largest first (by size
		 * for a difference, its sign written).
		 * @param {object} layout
		 * @param {Array<{code: string, where: string, finger: string, value: number}>} rows
		 * @param {boolean} signed A difference with another layout.
		 */
		function renderHeatTable(layout, rows, signed) {
			heatTableInto($('la-heat-table'), layout, rows, state.heat, signed);
		}

		/** The heatmap's numbers of one choice as a table (renderHeatTable), into any table. */
		function heatTableInto(table, layout, rows, metric, signed) {
			const unit = heatUnit(metric);
			const head = el('tr');
			for (const label of [
				t('layout_analysis.heat.table_key'),
				t('layout_analysis.heat.table_position'),
				t('layout_analysis.heat.table_finger'),
				heatName(metric)
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			for (const row of rows.slice().sort((a, b) => Math.abs(b.value) - Math.abs(a.value))) {
				const tr = el('tr');
				const th = el('th', 'la-keys', keyText(layout, row.code));
				th.scope = 'row';
				const written = `${signed && row.value > 0 ? '+' : ''}${measure(row.value, HEAT_DIGITS, unit)}`;
				tr.append(
					th,
					el('td', '', row.where),
					el('td', '', row.finger ? t(`layout_analysis.finger.${row.finger}`) : ''),
					el('td', '', written)
				);
				tbody.append(tr);
			}
			table.replaceChildren(thead, tbody);
		}

		/**
		 * Draws a board of a result's keyboard into a box, each key showing the
		 * layout's base character, positioned in % so the board scales with its
		 * box. One layout: the heat scale (theme.css), blue for the least to red
		 * for the most, by the key's share of the extent. A difference (other): orange where this layout puts more,
		 * blue where less, mixed into the neutral surface.
		 * @param {HTMLElement} box
		 * @param {object} result
		 * @param {object} layout
		 * @param {object} byCode code → value.
		 * @param {{extent?: number, other: boolean, level?: string,
		 *   title: function(string, number, string): string}} options extent: the
		 *   value of the darkest key (the box's own largest when absent); level:
		 *   the level choice its keys show (levelKey, the base when absent); title
		 *   gets the key's code, value and shown text. A key is an image named by
		 *   its shown text, its value, its place and what it types on every level,
		 *   never a Tab stop: nothing on it is operated, and the board's table
		 *   holds every value.
		 * @returns {Array<{code: string, where: string, finger: string, value: number}>}
		 *   The drawn keys, the rows of the board's table.
		 */
		function drawBoard(box, result, layout, byCode, options) {
			box.replaceChildren();
			// The layout's own board: its Tab or Enter key when it types there.
			const board = E.layoutKeyboard(layout, result.keyboard, result.profile || undefined);
			const modifiers = new Set(E.heldCodesOf(layout));
			const shown = board.codes.filter((code) => !modifiers.has(code));
			const extent =
				options.extent !== undefined
					? options.extent
					: Math.max(...shown.map((code) => Math.abs(byCode[code])), 0);
			const minX = Math.min(...board.x) - 0.5;
			const maxX = Math.max(...board.x) + 0.5;
			const maxY = Math.max(...board.y);
			const width = maxX - minX;
			// Positions in % of the board, so the whole board scales with its box.
			const across = (units) => `${(units / width) * 100}%`;
			const down = (units) => `${(units / maxY) * 100}%`;
			box.style.maxWidth = `${width * HEAT_UNIT_PX}px`;
			box.style.aspectRatio = `${width} / ${maxY}`;
			box.classList.toggle('la-heatmap-diff', options.other);
			const position = keyPositions(board, shown);
			const levelKeyShown = options.level || LEVEL_BASE;
			const level = levelIndex(layout, levelKeyShown);
			box.dataset.level = levelKeyShown;
			const tableRows = [];
			board.codes.forEach((code, k) => {
				if (modifiers.has(code)) return;
				// The base level names a key without a character by its code, as before.
				const text = level === 0 ? keyText(layout, code) : levelText(layout, code, level);
				const key = el('span', 'la-key', text);
				// The worst n-grams outline keys by their code (worst_groups.js).
				key.dataset.code = code;
				const cell = level < 0 ? null : (layout.rows[code] || [])[level];
				if (cell && typeof cell === 'object') key.classList.add(KEY_LEGEND.DEAD_KEY_CLASS);
				const value = byCode[code];
				const share = extent > 0 ? Math.min(1, Math.abs(value) / extent) : 0;
				// The space bar as wide as the board makes it, at most SPACE_UNITS: a split
				// board's one-unit thumb key, JIS's shorter bar beside its thumb keys.
				const span = code === 'Space' ? Math.min(SPACE_UNITS, board.width[k]) : 1;
				const left = board.x[k] - span / 2;
				key.style.left = across(left - minX);
				key.style.top = down(board.y[k] - 1);
				key.style.width = across(span);
				key.style.height = down(1);
				if (options.other) {
					key.classList.add(value > 0 ? 'la-key-more' : value < 0 ? 'la-key-less' : 'la-key-same');
					key.style.setProperty('--la-share', `${Math.round(share * HEAT_DIFF_MAX_SHARE * 100)}%`);
				} else {
					key.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
				}
				const valueTitle = options.title(code, value, text || t('layout_analysis.level.none'));
				const spoken = levelsSpoken(layout, code);
				// What the key types on each level, whichever one the board shows.
				const title = spoken
					? `${valueTitle}; ${t('layout_analysis.heat.key_levels', { levels: spoken })}`
					: valueTitle;
				const where = t('layout_analysis.heat.position', position.get(code));
				key.title = title;
				key.setAttribute('role', 'img');
				// The name also says where the key is, which the drawing shows.
				key.setAttribute('aria-label', `${title} (${where})`);
				box.append(key);
				tableRows.push({ code, where, finger: DATA.model.fingers[board.finger[k]], value });
			});
			return tableRows;
		}

		/**
		 * The board of the chosen keyboard in the details, each key showing the
		 * layout's base character. One layout: coloured on the heat scale (blue to red) by
		 * its share of the largest value of the chosen per-key metric. Against
		 * another layout (the difference): orange where this layout puts more,
		 * blue where less, stronger with the size of the gap, each tooltip
		 * signed. The legend gives the scale; every key is reachable from the
		 * keyboard with its value as its name. The board shrinks with the page
		 * instead of scrolling.
		 */
		function renderHeatmap(result) {
			const box = $('la-heatmap');
			const detail = detailOf(result);
			const versus = state.results.find((r) => r.layout.id === state.versus) || null;
			const field = $('la-heat-diff-field');
			field.hidden = !versus;
			if (versus)
				setText(
					field,
					t('layout_analysis.heat.diff', {
						layout: versus.layout.name
					})
				);
			$('la-heat-diff').checked = state.heatDiff;
			const other = versus && state.heatDiff ? versus : null;
			const layout = layoutOf(result.layout.id);
			const byCode = heatValues(detail, other);
			const level = fillSelect($('la-heat-level'), levelChoices([layout]), state.heatLevel);
			const tableRows = drawBoard(box, result, layout, byCode, {
				other: Boolean(other),
				level,
				title: (code, value, shown) => heatTitle(detail, layout, code, value, Boolean(other), shown)
			});
			// The heatmap as a PNG or SVG image (board_image.js).
			$('la-heatmap-image').replaceChildren(
				window.LAYOUT_BOARD_IMAGE.buttons({
					id: 'la-heatmap-image',
					board: () => $('la-heatmap'),
					options: () => ({
						title: `${result.layout.name} · ${heatName(state.heat)}`,
						words: [result.layout.name, 'heatmap', state.heat]
					})
				})
			);
			const extent = Math.max(...tableRows.map((row) => Math.abs(row.value)), 0);
			renderHeatTable(layout, tableRows, Boolean(other));
			const legend = $('la-heat-legend');
			const unit = heatUnit(state.heat);
			if (other) {
				// Both directions in words with a sign, never by colour alone.
				const swatch = (kind, mark, words) => {
					const item = el('span', 'la-heat-key');
					item.append(swatchMark(`la-swatch-${kind}`), `${mark} ${words}`);
					return item;
				};
				legend.replaceChildren(
					swatch('more', '+', t('layout_analysis.heat.diff_more', { layout: other.layout.name })),
					swatch('less', '−', t('layout_analysis.heat.diff_less', { layout: other.layout.name })),
					el('small', 'la-muted', `± ${measure(extent, HEAT_DIGITS, unit)}`)
				);
				return;
			}
			// The scale: what the lightest and the darkest key stand for.
			legend.replaceChildren(
				measure(0, HEAT_DIGITS, unit),
				heatRamp(),
				measure(extent, HEAT_DIGITS, unit),
				el('small', 'la-muted', t('layout_analysis.heat.scale', { metric: heatName(state.heat) }))
			);
		}

		/** The heatmap's choices: the presses, the score, then every per-key metric. */
		function fillHeatChoices() {
			const select = $('la-heat-metric');
			select.replaceChildren(
				...HEAT_CHOICES.map((id) => {
					const option = el('option', '', heatName(id));
					option.value = id;
					return option;
				})
			);
			select.value = state.heat;
			// The side-by-side heat maps offer the same choices, and how many boards.
			fillSelect(
				$('la-heats-metric'),
				HEAT_CHOICES.map((id) => [id, heatName(id)]),
				state.heats.metric
			);
			fillSelect(
				$('la-heats-count'),
				HEATS_COUNTS.map((n) => [String(n), format(n, 0)]),
				String(state.heats.count)
			);
			$('la-heats-shared').checked = state.heats.shared;
			const events = $('la-worst-event');
			const chosen = events.value || E.KEY_EVENTS[0];
			events.replaceChildren(
				...E.KEY_EVENTS.map((id) => {
					const option = el('option', '', t(`layout_analysis.metric.${id}`));
					option.value = id;
					return option;
				})
			);
			events.value = chosen;
			const by = $('la-matrix-by');
			by.replaceChildren(
				...MATRIX_CHOICES.map((id) => {
					const option = el('option', '', t(`layout_analysis.matrix.by_${id}`));
					option.value = id;
					return option;
				})
			);
			by.value = state.matrixBy;
		}

		/**
		 * The heaviest key groups of the chosen bad event over the whole board
		 * (the engine's topGroups): the keys as typed, how often the corpus has
		 * them, and their share of the bigrams or trigrams.
		 */
		function renderWorst(result) {
			const detail = detailOf(result);
			const layout = layoutOf(result.layout.id);
			const event = $('la-worst-event').value || E.KEY_EVENTS[0];
			const table = $('la-worst');
			const head = el('tr');
			for (const label of [
				t('layout_analysis.worst.keys'),
				t('layout_analysis.worst.count'),
				t('layout_analysis.worst.share')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			const groups = detail.topGroups[event];
			if (groups.length === 0) {
				const tr = el('tr');
				const td = el('td', 'la-muted', t('layout_analysis.worst.none'));
				td.colSpan = 3;
				tr.append(td);
				tbody.append(tr);
			}
			for (const group of groups) {
				const tr = el('tr');
				tr.append(
					el('td', 'la-keys', group.keys.map((code) => keyText(layout, code)).join(' ')),
					el('td', '', measure(group.count, 0, t('layout_analysis.unit.times'))),
					el('td', '', measure(group.share, HEAT_DIGITS, '%'))
				);
				tbody.append(tr);
			}
			table.replaceChildren(thead, tbody);
		}

		// The pair matrix and word efforts of a result, kept per result and weights
		// (a weight change re-scores the same results without a new analysis).
		const figureCache = new WeakMap();
		function cachedFigure(result, name, compute) {
			if (!figureCache.has(result)) figureCache.set(result, {});
			const entry = figureCache.get(result);
			const key = `${JSON.stringify(state.weights)}|${name === 'words' ? state.corpus : ''}`;
			if (!entry[name] || entry[name].key !== key || entry[name].words !== state.words)
				entry[name] = { key, words: state.words, value: compute() };
			return entry[name].value;
		}

		/**
		 * A table header row of sort buttons; the sort is the viewer's
		 * (state[sortName], or the holder's get and set). After a redraw the focus
		 * returns to the same header, found by its data-sort in the document.
		 */
		function sortableHead(columns, sortName, redraw, holder) {
			const get = holder ? holder.get : () => state[sortName];
			const set = holder
				? holder.set
				: (sort) => {
						state[sortName] = sort;
					};
			const head = el('tr');
			const scope = `${sortName || 'tab'}-${columns.map((c) => c.key).join('.')}`;
			for (const column of columns) {
				const th = el('th', 'la-sortable');
				th.scope = 'col';
				// Over a layout's row header, which stays in view (heatTableRow).
				if (column.key === 'name') th.classList.add(NAME_COLUMN);
				const sort = el('button', 'la-sort', column.label);
				sort.type = 'button';
				sort.dataset.sortScope = scope;
				sort.dataset.sort = column.key;
				sort.addEventListener('click', () => {
					const current = get();
					set(
						current.key === column.key
							? { key: column.key, descending: !current.descending }
							: { key: column.key, descending: Boolean(column.numeric) }
					);
					redraw();
					const again = root.querySelector(
						`button[data-sort-scope="${scope}"][data-sort="${column.key}"]`
					);
					if (again) again.focus();
				});
				th.append(sort);
				if (get().key === column.key)
					th.setAttribute('aria-sort', get().descending ? 'descending' : 'ascending');
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			return thead;
		}
		/**
		 * The key pair matrix (the engine's bigramMatrix): the busiest keys on
		 * both axes, first key by row, second by column, each cell coloured by
		 * how often the pair occurs (the heat scale, blue to red) or by the score
		 * points it gains (blue, « + ») or costs (orange, « − ») into the
		 * neutral surface. The figure scrolls inside its own box on a narrow
		 * screen; every pair is also in a sortable table, and each cell names
		 * its pair, share, count, kind and points to assistive technology.
		 */
		/**
		 * The detailed layout's tap-hold keys (E.tapHoldReport, an idea seen in
		 * the Layouts Wiki playground, which models tap and hold keys): the
		 * level each holds, its taps and holds, its taps rolled on its hand and
		 * its holds typed by its hand. Hidden for a layout without tap-holds
		 * (every library layout: they come from the editor).
		 */
		function renderTapHolds(result) {
			const layout = layoutOf(result.layout.id);
			const box = $('la-tap-holds-box');
			box.hidden = E.tapHoldKeys(layout).size === 0;
			const table = $('la-tap-holds');
			if (box.hidden) {
				table.replaceChildren();
				return;
			}
			const report = cachedFigure(result, 'tapHolds', () =>
				E.tapHoldReport(layout, tablesOf(result), analysisOptions())
			);
			$('la-tap-holds-summary').textContent = t('layout_analysis.tap_hold.summary', {
				share: measure(report.holdShare, 2, '%')
			});
			const head = el('tr');
			for (const id of ['key', 'level', 'taps', 'holds', 'hold_share', 'roll', 'same_hand']) {
				const th = el('th', '', t(`layout_analysis.tap_hold.col_${id}`));
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			const pct = (value) => measure(value, 1, '%');
			for (const key of report.keys) {
				const name = el('th', '', `${keyText(layout, key.code)} (${key.code})`);
				name.scope = 'row';
				const row = el('tr');
				row.dataset.code = key.code;
				row.append(
					name,
					el('td', '', key.holds.map((id) => layout.modifiers[id].label).join(', ')),
					el('td', 'la-num', format(key.taps, 0)),
					el('td', 'la-num', format(key.held, 0)),
					el('td', 'la-num', pct(key.holdShare)),
					el('td', 'la-num', pct(key.rollAfterTap)),
					el('td', 'la-num', pct(key.sameHandHold))
				);
				body.append(row);
			}
			table.replaceChildren(thead, body);
		}

		// ===================================
		// ======= User metrics ==============
		// ===================================

		/** A user metric's name: its own, an example's in the page's language, or its number. */
		function userMetricName(metric, index) {
			if (metric.name) return metric.name;
			if (metric.example) return t(`layout_analysis.user_metrics.example_${metric.example}`);
			return t('layout_analysis.user_metrics.unnamed', { n: index + 1 });
		}

		/**
		 * The user metrics' tests, each compiled once per text: {metric, error};
		 * error an E.QueryError when its query does not read (not measured).
		 */
		function userMetricChecks() {
			return state.userMetrics.map((metric) => {
				try {
					E.compileQuery(metric.query, E.windowNames(metric.window));
					return { metric, error: null };
				} catch (error) {
					if (!(error instanceof E.QueryError)) throw error;
					return { metric, error };
				}
			});
		}

		/** The user metrics that read, as windowMetrics takes them, and their cache key. */
		function readableUserMetrics() {
			const metrics = userMetricChecks()
				.filter((check) => check.error === null)
				.map(({ metric }) => ({ id: metric.id, window: metric.window, query: metric.query }));
			return { metrics, key: JSON.stringify(metrics) };
		}

		/** A result's user metrics (E.windowMetrics), kept with its figures while they stay the same. */
		function userMetricsOf(r) {
			const { metrics, key } = readableUserMetrics();
			const entry = cachedFigure(r, 'userMetrics', () => new Map());
			if (!entry.has(key))
				entry.set(
					key,
					E.windowMetrics(layoutOf(r.layout.id), tablesOf(r), metrics, analysisOptions())
				);
			return entry.get(key);
		}

		/** Saves the user metrics and redraws them, the editor list included when asked. */
		function userMetricsChanged(redrawList) {
			userMetricsRun = null;
			save();
			const shown = state.results.find((r) => r.layout.id === state.details);
			if (shown) renderUserMetrics(shown, redrawList);
		}

		/** The editor of one user metric: its name, window and query, and the button removing it. */
		function userMetricItem(metric, check, index) {
			const li = el('li', 'la-user-metric');
			const group = el('fieldset', 'la-user-metric-fields');
			const shownName = userMetricName(metric, index);
			const legend = el('legend', 'la-sr-only', shownName);
			const field = (labelKey, control) => {
				const label = el('label', 'la-filter-field', t(labelKey));
				label.append(control);
				return label;
			};
			const name = el('input');
			name.type = 'text';
			name.value = shownName;
			name.className = 'la-user-metric-name';
			name.addEventListener('change', () => {
				metric.name = name.value.trim();
				// A renamed example is the visitor's own.
				delete metric.example;
				userMetricsChanged(true);
			});
			const window = el('select', 'la-user-metric-window');
			for (const kind of E.WINDOW_KINDS) {
				const option = el('option', '', t(`layout_analysis.user_metrics.window_${kind}`));
				option.value = kind;
				window.append(option);
			}
			window.value = metric.window;
			window.addEventListener('change', () => {
				metric.window = window.value;
				userMetricsChanged(true);
			});
			const query = el('input');
			query.type = 'text';
			query.value = metric.query;
			query.spellcheck = false;
			query.autocomplete = 'off';
			query.className = 'la-user-metric-query';
			const status = el('p', 'la-query-status');
			status.id = `la-user-metric-status-${metric.id}`;
			status.setAttribute('role', 'status');
			query.setAttribute('aria-describedby', status.id);
			if (check.error)
				status.textContent = t('layout_analysis.user_metrics.invalid', {
					reason: queryErrorText(check.error)
				});
			query.addEventListener('change', () => {
				metric.query = query.value;
				userMetricsChanged(true);
			});
			const remove = el('button', '', t('layout_analysis.user_metrics.remove'));
			remove.type = 'button';
			remove.className = 'la-user-metric-remove';
			remove.setAttribute(
				'aria-label',
				t('layout_analysis.user_metrics.remove_named', { name: shownName })
			);
			remove.addEventListener('click', () => {
				state.userMetrics = state.userMetrics.filter((m) => m !== metric);
				userMetricsChanged(true);
				$('la-user-metrics-add').focus();
			});
			group.append(
				legend,
				field('layout_analysis.user_metrics.name', name),
				field('layout_analysis.user_metrics.window', window),
				field('layout_analysis.user_metrics.query', query),
				remove
			);
			li.append(group, status);
			return li;
		}

		/** The names a user metric's query may use, each with what it is. */
		function fillUserMetricNames() {
			const item = (names, text) => {
				const li = el('li');
				names.forEach((name, i) => {
					if (i > 0) li.append(', ');
					li.append(el('code', '', name));
				});
				li.append(` ${text}`);
				return li;
			};
			const places = (name) => [1, 2, 3].map((place) => `${name}${place}`);
			const words = (id) => t(`layout_analysis.user_metrics.name_${id}`);
			const events = E.TRACE_PAIR_EVENTS.concat(E.TRACE_TRIPLE_EVENTS);
			$('la-user-metrics-names').replaceChildren(
				...['finger', 'hand', 'row', 'reach', 'thumb', 'home'].map((id) =>
					item(places(id), words(id))
				),
				...['rows_apart', 'columns_apart', 'distance', 'same_finger', 'same_hand', 'same_key'].map(
					(id) => item([id], words(id))
				),
				...events.map((id) =>
					item([id], t('layout_analysis.user_metrics.name_event', { metric: metricName(id) }))
				)
			);
		}

		// The user metrics of every compared layout, measured on request one
		// layout per slice: {results, key, rows, done}; null before a request.
		let userMetricsRun = null;

		/**
		 * The user metrics (an idea seen in the Layouts Wiki playground's metric
		 * queries): each one's editor, then its share on the Principal and the
		 * Comparison layouts with their difference; once measured on every
		 * compared layout, the table of them all.
		 */
		function renderUserMetrics(result, redrawList) {
			const checks = userMetricChecks();
			const list = $('la-user-metrics-list');
			// The list is redrawn only when it or the page's words change, so a
			// field keeps its focus while the figures redraw.
			const signature = JSON.stringify([state.userMetrics, t('layout_analysis.user_metrics.name')]);
			if (redrawList || list.dataset.signature !== signature) {
				list.replaceChildren(...checks.map((check, i) => userMetricItem(check.metric, check, i)));
				list.dataset.signature = signature;
			}
			const full = state.userMetrics.length >= E.WINDOW_MAX_METRICS;
			$('la-user-metrics-add').disabled = full;
			$('la-user-metrics-full').textContent = full
				? t('layout_analysis.user_metrics.full', { count: E.WINDOW_MAX_METRICS })
				: '';
			if ($('la-user-metrics-names').children.length === 0) fillUserMetricNames();
			const versus = state.results.find(
				(r) => r.layout.id === state.versus && r.layout.id !== result.layout.id
			);
			const shown = [result].concat(versus ? [versus] : []);
			const measured = shown.map((r) => userMetricsOf(r));
			const table = $('la-user-metrics');
			const head = el('tr');
			const columns = [
				t('layout_analysis.details.metric_column'),
				t('layout_analysis.user_metrics.window')
			]
				.concat(shown.map((r) => r.layout.name))
				.concat(versus ? [t('layout_analysis.details.delta')] : []);
			for (const label of columns) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			const pct = (v) => measure(v, 2, '%');
			for (const [index, { metric, error }] of checks.entries()) {
				if (error) continue;
				const row = el('tr');
				const name = el('th', '', userMetricName(metric, index));
				name.scope = 'row';
				row.append(name, el('td', '', t(`layout_analysis.user_metrics.window_${metric.window}`)));
				for (const m of measured) row.append(el('td', 'la-num', pct(m.values[metric.id])));
				if (versus) {
					const gap = measured[0].values[metric.id] - measured[1].values[metric.id];
					row.append(
						el('td', 'la-num la-delta', withUnit(`${gap > 0 ? '+' : ''}${format(gap, 2)}`, '%'))
					);
				}
				body.append(row);
			}
			table.replaceChildren(thead, body);
			renderUserMetricsRanking();
		}

		/** The user metrics of every compared layout, once measured and still current. */
		function renderUserMetricsRanking() {
			const run = userMetricsRun;
			const current =
				run && run.done && run.results === state.results && run.key === readableUserMetrics().key;
			$('la-user-metrics-all-name').hidden = !current;
			$('la-user-metrics-all-wrap').hidden = !current;
			const table = $('la-user-metrics-ranking');
			if (!current) {
				table.replaceChildren();
				return;
			}
			const metrics = state.userMetrics.filter((m) => run.ids.includes(m.id));
			const head = el('tr');
			for (const label of [t('layout_analysis.table.layout')].concat(
				metrics.map((m) => userMetricName(m, state.userMetrics.indexOf(m)))
			)) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			for (const { result, values } of run.rows) {
				const row = el('tr');
				if (state.details === result.layout.id) row.classList.add('la-selected');
				if (state.versus === result.layout.id) row.classList.add('la-versus');
				const name = el('th', '', result.layout.name);
				name.scope = 'row';
				row.append(name, ...metrics.map((m) => el('td', 'la-num', measure(values[m.id], 2, '%'))));
				body.append(row);
			}
			table.replaceChildren(thead, body);
		}

		/**
		 * « Measure every compared layout »: the user metrics of each layout the
		 * filters show, one per slice so the page keeps answering; a change of
		 * the comparison or of the metrics while it runs ends it unfinished.
		 */
		async function measureUserMetrics() {
			const results = state.results;
			const { key, metrics } = readableUserMetrics();
			const rows = shownRows();
			const run = { results, key, ids: metrics.map((m) => m.id), rows: [], done: false };
			userMetricsRun = run;
			const status = $('la-user-metrics-status');
			const button = $('la-user-metrics-all');
			button.disabled = true;
			try {
				for (const [index, result] of rows.entries()) {
					if (userMetricsRun !== run || state.results !== results) return;
					run.rows.push({ result, values: userMetricsOf(result).values });
					status.textContent = t('layout_analysis.user_metrics.all_progress', {
						done: index + 1,
						count: rows.length
					});
					// Lets the page answer between two layouts.
					await new Promise((resolve) => setTimeout(resolve, 0));
				}
				if (userMetricsRun !== run || state.results !== results) return;
				run.done = true;
				status.textContent = t('layout_analysis.user_metrics.all_done', { count: rows.length });
				renderUserMetricsRanking();
			} finally {
				button.disabled = false;
			}
		}

		/** A result's movement table, kept with its other figures. */
		function movementOf(r) {
			return cachedFigure(r, 'movement', () =>
				E.movementTable(layoutOf(r.layout.id), tablesOf(r), analysisOptions())
			);
		}

		// The movement tables of the library's complete layouts of this
		// comparison (the percentiles' references, the user's own left out),
		// measured on request: one layout per slice, so the page keeps answering
		// (movementTable takes 20 to 60 ms a layout on a large corpus).
		// {results, weights, tables, done}; null before a request.
		let movementLibrary = null;

		/** The measured references, when they belong to the comparison shown. */
		function placedMovement() {
			const run = movementLibrary;
			return run &&
				run.done &&
				run.results === state.results &&
				run.weights === JSON.stringify(state.weights)
				? run
				: null;
		}

		/**
		 * « Place among the library »: measures every complete library layout of
		 * the comparison, then shows each movement and rhythm cell's percentile.
		 * A change of the comparison while it runs ends the run unfinished.
		 */
		async function placeMovementAmongLibrary() {
			const results = state.results;
			const references = results.filter((r) => !r.incomplete && !isPersonal(r));
			const status = $('la-movement-rank-status');
			if (references.length < E.PERCENTILE_MIN_REFERENCES) {
				status.textContent = t('layout_analysis.movement.rank_too_few', {
					count: references.length,
					min: E.PERCENTILE_MIN_REFERENCES
				});
				return;
			}
			const run = { results, weights: JSON.stringify(state.weights), tables: [], done: false };
			movementLibrary = run;
			const button = $('la-movement-rank');
			button.disabled = true;
			try {
				for (const [index, reference] of references.entries()) {
					if (movementLibrary !== run || state.results !== results) return;
					run.tables.push(movementOf(reference));
					status.textContent = t('layout_analysis.movement.rank_progress', {
						done: index + 1,
						count: references.length
					});
					// Lets the page answer between two layouts.
					await new Promise((resolve) => setTimeout(resolve, 0));
				}
				if (movementLibrary !== run || state.results !== results) return;
				run.done = true;
				const shown = state.results.find((r) => r.layout.id === state.details);
				if (shown) renderMovement(shown);
			} finally {
				button.disabled = false;
			}
		}

		/**
		 * A cell's percentile chip among the measured references: in the class's
		 * direction (E.movementBetter), neutral when no direction is better.
		 * @param {object|null} placed - placedMovement().
		 * @param {function(object): object} column - The table's column of classes.
		 * @param {string} id - The class.
		 * @param {number} value - The cell's value.
		 * @param {string} label - The class and column, as the chip names them.
		 * @returns {HTMLButtonElement|null}
		 */
		function movementChip(placed, column, id, value, label) {
			if (!placed) return null;
			const better = E.movementBetter(id);
			const standing = E.rankAmong(
				better,
				placed.tables.map((m) => column(m)[id])
			)(value);
			return standing ? INFO.percentile(label, standing, better === 'none') : null;
		}

		/** A cell of a movement or rhythm table: its share, then its percentile when placed. */
		function movementCell(text, chip) {
			const cell = el('td', 'la-num', text);
			if (chip) cell.append(chip);
			return cell;
		}

		/**
		 * The movement table (an idea seen in the Layouts Wiki playground): each
		 * pair class over adjacent key pairs and over skipgrams, for the detailed
		 * layout and the one it is compared with, with their difference; once
		 * placed among the library, each cell carries its percentile.
		 */
		function renderMovement(result) {
			const versus = state.results.find((r) => r.layout.id === state.versus) || null;
			const shown = [result].concat(versus ? [versus] : []).map((r) => ({ r, m: movementOf(r) }));
			const placed = placedMovement();
			const running =
				movementLibrary !== null &&
				!movementLibrary.done &&
				movementLibrary.results === state.results;
			if (!placed && !running) $('la-movement-rank-status').textContent = '';
			if (placed)
				$('la-movement-rank-status').textContent = t('layout_analysis.movement.rank_done', {
					count: placed.tables.length
				});
			const table = $('la-movement');
			table.replaceChildren();
			const head = el('tr');
			const columns = [t('layout_analysis.movement.class')];
			for (const { r } of shown)
				columns.push(
					t('layout_analysis.movement.bigrams', { layout: r.layout.name }),
					t('layout_analysis.movement.skipgrams', { layout: r.layout.name })
				);
			if (versus)
				columns.push(
					t('layout_analysis.movement.delta_bigrams'),
					t('layout_analysis.movement.delta_skipgrams')
				);
			for (const label of columns) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			const pct = (v) => measure(v, 2, '%');
			const signed = (v) => `${v > 0 ? '+' : ''}${format(v, 2)}`;
			// The movement table's own classes have their words; the others are metrics.
			const className = (id) =>
				E.MOVEMENT_EXTRA.includes(id) ? t(`layout_analysis.movement.${id}`) : metricName(id);
			for (const id of E.MOVEMENT_CLASSES.concat(E.MOVEMENT_EXTRA)) {
				const row = el('tr');
				const name = el('th', '', className(id));
				name.scope = 'row';
				row.append(name);
				for (const { r, m } of shown)
					row.append(
						movementCell(
							pct(m.bigram[id]),
							movementChip(
								placed,
								(x) => x.bigram,
								id,
								m.bigram[id],
								t('layout_analysis.movement.bigrams', { layout: r.layout.name }) +
									` · ${className(id)}`
							)
						),
						movementCell(
							pct(m.skipgram[id]),
							movementChip(
								placed,
								(x) => x.skipgram,
								id,
								m.skipgram[id],
								t('layout_analysis.movement.skipgrams', { layout: r.layout.name }) +
									` · ${className(id)}`
							)
						)
					);
				if (versus) {
					const [a, b] = shown.map(({ m }) => m);
					row.append(
						el('td', 'la-num', signed(b.bigram[id] - a.bigram[id])),
						el('td', 'la-num', signed(b.skipgram[id] - a.skipgram[id]))
					);
				}
				body.append(row);
			}
			table.append(thead, body);
			renderRhythm(shown, placed);
		}

		/**
		 * The trigram rhythm under the movement table: each trigram class (and
		 * those whose ends are the same finger) over all trigrams and over those
		 * without a thumb, for the detailed layout and its comparison.
		 */
		function renderRhythm(shown, placed) {
			const table = $('la-rhythm');
			table.replaceChildren();
			const head = el('tr');
			const columns = [t('layout_analysis.movement.class')];
			for (const { r } of shown)
				columns.push(
					t('layout_analysis.movement.all', { layout: r.layout.name }),
					t('layout_analysis.movement.no_thumbs', { layout: r.layout.name })
				);
			if (shown.length === 2) columns.push(t('layout_analysis.movement.delta_all'));
			for (const label of columns) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const body = el('tbody');
			const pct = (v) => measure(v, 2, '%');
			const name = (id) =>
				id.endsWith('_sfs') ? t(`layout_analysis.movement.${id}`) : metricName(id);
			for (const id of E.RHYTHM_CLASSES) {
				const row = el('tr');
				const header = el('th', '', name(id));
				header.scope = 'row';
				row.append(header);
				for (const { r, m } of shown)
					row.append(
						movementCell(
							pct(m.rhythm.all[id]),
							movementChip(
								placed,
								(x) => x.rhythm.all,
								id,
								m.rhythm.all[id],
								t('layout_analysis.movement.all', { layout: r.layout.name }) + ` · ${name(id)}`
							)
						),
						movementCell(
							pct(m.rhythm.noThumbs[id]),
							movementChip(
								placed,
								(x) => x.rhythm.noThumbs,
								id,
								m.rhythm.noThumbs[id],
								t('layout_analysis.movement.no_thumbs', { layout: r.layout.name }) +
									` · ${name(id)}`
							)
						)
					);
				if (shown.length === 2) {
					const delta = shown[1].m.rhythm.all[id] - shown[0].m.rhythm.all[id];
					row.append(el('td', 'la-num', `${delta > 0 ? '+' : ''}${format(delta, 2)}`));
				}
				body.append(row);
			}
			table.append(thead, body);
		}

		function renderMatrix(result) {
			const layout = layoutOf(result.layout.id);
			const matrix = cachedFigure(result, 'matrix', () =>
				E.bigramMatrix(layout, tablesOf(result), analysisOptions())
			);
			const byPoints = state.matrixBy === MATRIX_POINTS;
			const keys = matrix.keys.slice(0, MATRIX_MAX_KEYS);
			$('la-matrix-caption').textContent = t('layout_analysis.matrix.caption', {
				keys: keys.length,
				all: matrix.keys.length
			});
			const value = (pair) => (byPoints ? pair.points : pair.share);
			const at = new Map(matrix.pairs.map((pair) => [pair.keys.join(' '), pair]));
			const shown = matrix.pairs.filter(
				(pair) => keys.includes(pair.keys[0]) && keys.includes(pair.keys[1])
			);
			const extent = Math.max(...shown.map((pair) => Math.abs(value(pair))), 0);
			const eventsText = (pair) =>
				pair.events.map((id) => t(`layout_analysis.metric.${id}`)).join(', ');
			const signed = (v, digits) => `${v > 0 ? '+' : ''}${format(v, digits)}`;
			const describe = (pair) =>
				t('layout_analysis.matrix.cell', {
					first: keyText(layout, pair.keys[0]),
					second: keyText(layout, pair.keys[1]),
					share: format(pair.share, HEAT_DIGITS),
					count: format(pair.count, 0),
					events: eventsText(pair),
					points: signed(pair.points, HEAT_DIGITS)
				});
			const table = $('la-matrix');
			const head = el('tr');
			head.append(el('td'));
			for (const code of keys) {
				const th = el('th', 'la-keys', keyText(layout, code));
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			for (const first of keys) {
				const tr = el('tr');
				const th = el('th', 'la-keys', keyText(layout, first));
				th.scope = 'row';
				tr.append(th);
				for (const second of keys) {
					const td = el('td', 'la-cell');
					const pair = at.get(`${first} ${second}`);
					if (pair) {
						const v = value(pair);
						const share = extent > 0 ? Math.abs(v) / extent : 0;
						if (byPoints) {
							// The sign in the cell, never the colour alone.
							td.classList.add(v > 0 ? 'la-cell-gain' : v < 0 ? 'la-cell-loss' : 'la-cell-zero');
							td.style.setProperty(
								'--la-share',
								`${Math.round(share * HEAT_DIFF_MAX_SHARE * 100)}%`
							);
							td.append(v > 0 ? '+' : v < 0 ? '−' : '');
						} else {
							td.classList.add('la-cell-count');
							td.style.setProperty('--la-share', `${Math.round(share * 100)}%`);
						}
						const text = describe(pair);
						td.title = text;
						td.append(el('span', 'la-sr-only', text));
					}
					tr.append(td);
				}
				tbody.append(tr);
			}
			table.replaceChildren(thead, tbody);
			const legend = $('la-matrix-legend');
			const unit = byPoints ? t('layout_analysis.unit.points') : '%';
			if (byPoints) {
				const swatch = (kind, mark, words) => {
					const item = el('span', 'la-heat-key');
					item.append(swatchMark(`la-swatch-${kind}`), `${mark} ${words}`);
					return item;
				};
				legend.replaceChildren(
					swatch('less', '+', t('layout_analysis.chart.gain')),
					swatch('more', '−', t('layout_analysis.chart.loss')),
					el('small', 'la-muted', `± ${measure(extent, HEAT_DIGITS, unit)}`)
				);
			} else {
				legend.replaceChildren(
					measure(0, HEAT_DIGITS, unit),
					heatRamp(),
					measure(extent, HEAT_DIGITS, unit),
					el(
						'small',
						'la-muted',
						t('layout_analysis.heat.scale', { metric: t('layout_analysis.matrix.by_count') })
					)
				);
			}
			renderMatrixPairs(layout, matrix, eventsText, signed);
		}

		/** Every pair of the matrix as a sortable table, the most frequent ones. */
		function renderMatrixPairs(layout, matrix, eventsText, signed) {
			const rows = matrix.pairs.slice(0, MATRIX_TABLE_ROWS);
			$('la-matrix-count').textContent = t('layout_analysis.matrix.table_count', {
				shown: rows.length,
				total: matrix.pairs.length
			});
			const columns = [
				{
					key: 'first',
					label: t('layout_analysis.matrix.first'),
					numeric: false,
					value: (p) => keyText(layout, p.keys[0])
				},
				{
					key: 'second',
					label: t('layout_analysis.matrix.second'),
					numeric: false,
					value: (p) => keyText(layout, p.keys[1])
				},
				{
					key: 'count',
					label: t('layout_analysis.worst.count'),
					numeric: true,
					value: (p) => p.count
				},
				{
					key: 'share',
					label: t('layout_analysis.worst.share'),
					numeric: true,
					value: (p) => p.share
				},
				{
					key: 'events',
					label: t('layout_analysis.matrix.events'),
					numeric: false,
					value: eventsText
				},
				{
					key: 'points',
					label: t('layout_analysis.matrix.points'),
					numeric: true,
					value: (p) => p.points
				}
			];
			const redraw = () => renderMatrixPairs(layout, matrix, eventsText, signed);
			const thead = sortableHead(columns, 'matrixSort', redraw);
			const column = columns.find((c) => c.key === state.matrixSort.key) || columns[2];
			const sorted = rows.slice().sort((a, b) => {
				const x = column.value(a);
				const y = column.value(b);
				const order = typeof x === 'string' ? x.localeCompare(y) : x - y;
				return state.matrixSort.descending ? -order : order;
			});
			const tbody = el('tbody');
			for (const pair of sorted) {
				const tr = el('tr');
				tr.append(
					el('td', 'la-keys', keyText(layout, pair.keys[0])),
					el('td', 'la-keys', keyText(layout, pair.keys[1])),
					el('td', '', measure(pair.count, 0, t('layout_analysis.unit.times'))),
					el('td', '', measure(pair.share, HEAT_DIGITS, '%')),
					el('td', '', eventsText(pair)),
					el('td', '', withUnit(signed(pair.points, HEAT_DIGITS), t('layout_analysis.unit.points')))
				);
				tbody.append(tr);
			}
			$('la-matrix-pairs').replaceChildren(thead, tbody);
		}

		/**
		 * Effort per word (the engine's wordEfforts on the corpus's word table):
		 * the mean, how the occurrences spread over ranges of effort, and the
		 * hardest words with what costs them most. A corpus of letter counts
		 * only says it has no word table.
		 */
		function renderWords(result) {
			const words = state.words && Object.keys(state.words).length > 0 ? state.words : null;
			$('la-words-none').hidden = Boolean(words);
			$('la-words-body').hidden = !words;
			if (!words) return;
			const layout = layoutOf(result.layout.id);
			const efforts = cachedFigure(result, 'words', () =>
				E.wordEfforts(layout, words, analysisOptions())
			);
			const points = t('layout_analysis.unit.points');
			$('la-words-mean').textContent = t('layout_analysis.words.mean', {
				mean: format(efforts.mean, 1),
				words: format(efforts.words.length, 0),
				unsupported: format(efforts.unsupported.length, 0)
			});
			// The Comparison's mean beside it (an idea seen in the Layouts Wiki
			// playground, whose views show Main, Comp or their difference).
			const other = state.results.find(
				(r) => r.layout.id === state.versus && r.layout.id !== result.layout.id
			);
			if (other) {
				const theirs = cachedFigure(other, 'words', () =>
					E.wordEfforts(layoutOf(other.layout.id), words, analysisOptions())
				);
				const gap = efforts.mean - theirs.mean;
				$('la-words-mean').append(
					' ',
					t('layout_analysis.words.mean_versus', {
						layout: other.layout.name,
						mean: format(theirs.mean, 1),
						delta: `${gap > 0 ? '+' : ''}${format(gap, 1)}`
					})
				);
			}
			const bins = E.effortDistribution(efforts.words, WORD_BINS);
			loadBars(
				$('la-words-bins'),
				bins.map((bin) => ({
					label: t('layout_analysis.words.bin', {
						from: format(bin.from, 0),
						to: format(bin.to, 0)
					}),
					value: bin.share
				})),
				Math.max(...bins.map((bin) => bin.share), 0)
			);
			const head = el('tr');
			for (const label of [
				t('layout_analysis.words.word'),
				t('layout_analysis.worst.count'),
				`${t('layout_analysis.words.effort')} (${points})`,
				t('layout_analysis.words.part')
			]) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			for (const entry of efforts.words.slice(0, HARDEST_WORDS)) {
				const [worst] = Object.entries(entry.parts).sort((a, b) => b[1] - a[1]);
				const tr = el('tr');
				tr.append(
					el('td', 'la-keys', entry.word),
					el('td', '', measure(entry.count, 0, t('layout_analysis.unit.times'))),
					el('td', '', measure(entry.effort, 1, points)),
					el(
						'td',
						'',
						worst && worst[1] > 0
							? `${t(`layout_analysis.metric.${worst[0]}`)} ${measure(worst[1], 1, points)}`
							: ''
					)
				);
				tbody.append(tr);
			}
			$('la-words').replaceChildren(thead, tbody);
		}

		/**
		 * The other figures of the details: bigram and trigram classes, each
		 * finger's travel, modifiers and dead keys, and the standing among the
		 * compared layouts, all from the engine's numbers.
		 */
		function renderFigures(result) {
			const metricLabel = (id) => t(`layout_analysis.metric.${id}`);
			loadBars(
				$('la-bigram-classes'),
				BIGRAM_CLASSES.map((id) => ({ label: metricLabel(id), value: result.metrics[id] })),
				100
			);
			const trigramLabel = {
				roll_mixed: t('layout_analysis.classes.roll_mixed'),
				same_finger: t('layout_analysis.classes.same_finger')
			};
			loadBars(
				$('la-trigram-classes'),
				TRIGRAM_CLASSES.map((id) => ({
					label: trigramLabel[id] || metricLabel(id),
					value: result.trigramClasses[id]
				})),
				100
			);
			const travel = Object.entries(result.fingerDistance);
			loadBars(
				$('la-travel'),
				travel.map(([id, mm]) => ({ label: t(`layout_analysis.finger.${id}`), value: mm })),
				Math.max(...travel.map(([, mm]) => mm), 0),
				{ unit: t('layout_analysis.unit.mm'), digits: 2 }
			);
			loadBars(
				$('la-layers'),
				['modifier_usage', 'altgr_usage', 'dead_key_usage'].map((id) => ({
					label: metricLabel(id),
					value: result.metrics[id]
				})),
				100
			);
			const standing = E.standing(state.results, result.layout.id);
			loadBars(
				$('la-standing'),
				Object.entries(standing).map(([id, entry]) => ({
					label: metricLabel(id),
					value: entry.others > 0 ? entry.beats / entry.others : 0,
					text: t('layout_analysis.standing.value', { beats: entry.beats, others: entry.others })
				})),
				1
			);
		}

		/** The versus choice: every other compared layout, or none. */
		function fillVersus(result) {
			const select = $('la-versus');
			const none = el('option', '', t('layout_analysis.details.versus_none'));
			none.value = '';
			const others = state.results
				.filter((r) => r.layout.id !== result.layout.id)
				.map((r) => {
					const option = el('option', '', r.layout.name);
					option.value = r.layout.id;
					return option;
				});
			select.replaceChildren(none, ...others);
			if (!state.results.some((r) => r.layout.id === state.versus)) state.versus = null;
			select.value = state.versus || '';
		}

		/**
		 * Every metric of the layout; with a layout to compare with, its value
		 * and the difference beside it, with which one the metric prefers in
		 * words (the engine's diff).
		 */
		/**
		 * A difference's verdict in words with a mark, never by colour alone:
		 * better, worse or equal for the Principal layout, or not scored.
		 * @param {'better'|'worse'|'same'|'none'} verdict
		 * @returns {HTMLElement}
		 */
		function verdictCell(verdict) {
			const verdicts = {
				better: ['▲', t('layout_analysis.details.verdict_better')],
				worse: ['▼', t('layout_analysis.details.verdict_worse')],
				same: ['=', t('layout_analysis.details.verdict_same')],
				none: ['', t('layout_analysis.details.verdict_none')]
			};
			const cell = el('small', `la-verdict la-verdict-${verdict}`);
			const [mark, words] = verdicts[verdict];
			if (mark) {
				const drawn = el('span', 'la-verdict-mark', mark);
				drawn.setAttribute('aria-hidden', 'true');
				cell.append(drawn, ' ');
			}
			cell.append(words);
			return cell;
		}

		function renderMetrics(result) {
			const table = $('la-metrics');
			table.replaceChildren();
			const other = state.results.find((r) => r.layout.id === state.versus) || null;
			const diff = other ? E.diff(result, other) : null;
			const head = el('tr');
			const columns = [t('layout_analysis.details.metric_column'), result.layout.name];
			if (other) columns.push(other.layout.name, t('layout_analysis.details.delta'));
			for (const label of columns) {
				const th = el('th', '', label);
				th.scope = 'col';
				head.append(th);
			}
			const thead = el('thead');
			thead.append(head);
			const tbody = el('tbody');
			const addRow = (th, values, delta) => {
				const tr = el('tr');
				tr.append(th, ...values.map((text) => el('td', '', text)));
				if (delta) {
					const td = el('td', 'la-delta');
					td.append(delta.text, ' ', verdictCell(delta.verdict));
					tr.append(td);
				}
				tbody.append(tr);
			};
			const signed = (value, digits) => `${value > 0 ? '+' : ''}${format(value, digits)}`;
			if (diff) {
				const th = el('th', '', t('layout_analysis.table.score'));
				th.scope = 'row';
				const points = t('layout_analysis.unit.points');
				addRow(th, [measure(diff.score.a, 1, points), measure(diff.score.b, 1, points)], {
					text: withUnit(signed(diff.score.delta, 1), points),
					verdict: diff.score.verdict
				});
			}
			for (const id of Object.keys(E.METRICS)) {
				const th = el('th', '', t(`layout_analysis.metric.${id}`));
				th.scope = 'row';
				th.append(' ', infoButton(id));
				const digits = metricDigits(id);
				const unit = unitText(id);
				const values = [measure(result.metrics[id], digits, unit)];
				let delta = null;
				if (diff) {
					const entry = diff.metrics[id];
					values.push(measure(entry.b, digits, unit));
					delta = { text: withUnit(signed(entry.delta, digits), unit), verdict: entry.verdict };
				}
				addRow(th, values, delta);
			}
			table.append(thead, tbody);
		}

		/**
		 * How the layout types the corpus where it offers a choice: the share of
		 * the characters typed otherwise than their cheapest way out of context,
		 * each concerned character's ways with their shares, then the simplicity
		 * rules.
		 */
		function renderTyping(result, layout) {
			const rows = E.typingRows(result, layout, TYPING_ROWS);
			$('la-typing-caption').textContent =
				rows.length > 0
					? t('layout_analysis.details.typing_caption', {
							share: format(result.typing.changed, 2),
							count: result.typing.alternatives
						})
					: t('layout_analysis.details.typing_none');
			const table = $('la-typing');
			table.replaceChildren();
			table.hidden = rows.length === 0;
			if (rows.length > 0) {
				const head = el('tr');
				for (const key of ['typing_char', 'typing_ways']) {
					const th = el('th', '', t(`layout_analysis.details.${key}`));
					th.scope = 'col';
					head.append(th);
				}
				const thead = el('thead');
				thead.append(head);
				const tbody = el('tbody');
				for (const row of rows) {
					const tr = el('tr');
					// An invisible character is named by its code point.
					const name = /^[\s\p{C}]$/u.test(row.char)
						? `U+${row.char.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`
						: row.char;
					const th = el('th', '', name);
					th.scope = 'row';
					const ways = row.ways
						.map(
							(way) =>
								`${t(`layout_analysis.typing.${way.kind}`)} ${way.keys} (${measure(way.share, 0, '%')})`
						)
						.join(' · ');
					tr.append(th, el('td', '', ways));
					tbody.append(tr);
				}
				table.append(thead, tbody);
			}
			const simplicity = $('la-simplicity');
			simplicity.replaceChildren();
			const body = el('tbody');
			for (const [id, rule] of Object.entries(result.simplicity)) {
				const tr = el('tr');
				const th = el('th', '', t(`layout_analysis.simplicity.${id}`));
				th.scope = 'row';
				const value = rule
					? measure(rule.value, 0, '%')
					: t('layout_analysis.simplicity.not_measured');
				tr.append(th, el('td', '', value));
				body.append(tr);
			}
			simplicity.append(body);
		}

		/** One layout's contributions, finger load and every metric. */
		function renderDetails() {
			const section = $('la-details');
			const result = state.results.find((r) => r.layout.id === state.details);
			section.hidden = !result;
			if (!result) return;
			$('la-details-title').textContent = t('layout_analysis.details.title', {
				layout: result.layout.name,
				rank: result.rank
			});
			const layout = layoutOf(result.layout.id);
			const credit = $('la-details-credit');
			credit.textContent =
				layout.authors.length > 0
					? t('layout_analysis.details.by', { authors: layout.authors.join(', ') })
					: layout.source
						? t('layout_analysis.details.from', { source: layout.source })
						: '';
			const link = $('la-details-link');
			link.hidden = !layout.url;
			link.href = layout.url || '#';
			link.textContent = layout.url;
			INFO.routeLink(link);
			fillVersus(result);
			renderHeatmap(result);
			renderWorst(result);
			renderMatrix(result);
			renderMovement(result);
			renderTapHolds(result);
			renderUserMetrics(result);
			renderWords(result);
			renderFigures(result);
			const contributions = Object.entries(result.score.contributions)
				.filter(([, v]) => v !== 0)
				.sort((a, b) => Math.abs(b[1]) - Math.abs(a[1]))
				.map(([id, v]) => [t(`layout_analysis.metric.${id}`), v]);
			signedBars($('la-contributions'), contributions, 1, t('layout_analysis.unit.points'));
			// Each finger against the ideal load the score aims for, on one scale.
			const shares = Object.entries(result.fingerShares);
			const fingerScale = Math.max(
				...shares.map(([id, v]) => Math.max(v, result.idealLoad[id])),
				1e-9
			);
			loadBars(
				$('la-fingers'),
				shares.map(([id, value]) => ({
					label: t(`layout_analysis.finger.${id}`),
					value,
					target: result.idealLoad[id]
				})),
				fingerScale
			);
			loadBars(
				$('la-hands-rows'),
				[
					{ label: t('layout_analysis.details.hand_left'), value: result.hands.left },
					{ label: t('layout_analysis.details.hand_right'), value: result.hands.right }
				].concat(
					['number_row', 'top_row', 'home_row', 'bottom_row'].map((id) => ({
						label: t(`layout_analysis.metric.${id}`),
						value: result.metrics[id]
					}))
				),
				100
			);
			renderMetrics(result);
			renderTyping(result, layout);
			const missing = Object.entries(result.coverage.unsupportedChars)
				.sort((a, b) => b[1] - a[1])
				// An invisible character is named by its code point.
				.map(([char]) =>
					/^[\s\p{C}]$/u.test(char)
						? `U+${char.codePointAt(0).toString(16).toUpperCase().padStart(4, '0')}`
						: char
				)
				.join(' ');
			$('la-unsupported').textContent = [
				result.incomplete
					? t('layout_analysis.incomplete.details', {
							chars: missingText(result.coverage.missingRequired)
						})
					: '',
				missing ? t('layout_analysis.details.unsupported', { chars: missing }) : '',
				result.coverage.missingKeys.length > 0
					? t('layout_analysis.details.missing_keys', {
							keys: result.coverage.missingKeys.join(' ')
						})
					: ''
			]
				.filter(Boolean)
				.join(' ');
		}

		/**
		 * The address of this comparison: the site's Comparer (or the page the
		 * visitor sees it framed in) with the corpus, keyboard, format, the
		 * shareable compared layouts and the details shown.
		 * @returns {{url: string, own: object[], personal: boolean}} own: the
		 *   compared layouts that are the visitor's own, which share() puts in the
		 *   link's fragment; personal: the text is the visitor's own, not in it.
		 */
		function shareLink() {
			let base = HOST.shareUrl || null;
			if (!base) {
				let shown = location;
				try {
					// The site frames this page; the link is the framing page's.
					if (window.top !== window && window.top.location.origin === location.origin)
						shown = window.top.location;
				} catch {
					// A frame from another origin: this page's own address.
				}
				base = /^https?:$/.test(shown.protocol)
					? `${shown.origin}${shown.pathname}`
					: SITE_COMPARER_URL;
			}
			const chosen = layouts.filter((l) => state.selected.has(l.id));
			const shareable = chosen.filter((l) => SHAREABLE_ORIGINS.includes(l.origin));
			const query = new URLSearchParams();
			const corpus = corpora.find((c) => c.id === state.corpus);
			if (corpus && corpus.builtin) query.set('corpus', state.corpus);
			// A blend of built-in corpora travels; one holding the user's own text does not.
			const blendShared =
				state.corpus === BLEND_ID &&
				state.blendRecipe !== null &&
				state.blendRecipe.every((part) => corpora.some((c) => c.id === part.id && c.builtin));
			if (blendShared)
				query.set('blend', state.blendRecipe.map((part) => `${part.id}:${part.weight}`).join(','));
			query.set('keyboard', state.keyboard);
			query.set('format', state.format);
			query.set('layouts', shareable.map((l) => l.id).join(','));
			const canShare = (id) => shareable.some((l) => l.id === id);
			if (state.details && canShare(state.details)) query.set('details', state.details);
			if (state.versus && canShare(state.versus)) query.set('versus', state.versus);
			// The tab shown, with the Pareto tab's values or the trace's own text.
			if (state.tab !== HOME_TAB) query.set('tab', state.tab);
			if (state.tab === 'pareto') {
				query.set('px', state.pareto.x);
				query.set('py', state.pareto.y);
			}
			if (state.tab === 'trace' && state.trace.text !== null) query.set('text', state.trace.text);
			if (lang) query.set('lang', lang);
			return {
				url: `${base}?${query.toString().replace(/%2C/g, ',')}`,
				own: chosen.filter((l) => !SHAREABLE_ORIGINS.includes(l.origin)),
				personal: !(corpus && corpus.builtin) && !blendShared
			};
		}

		/** Copies the comparison's link, or shows it when the clipboard refuses. */
		async function share() {
			const { url, own, personal } = shareLink();
			const status = $('la-share-status');
			// The status shows once its outcome is known: shown while the link is
			// still being built and copied, it would announce a copy not yet made.
			const report = (text) => {
				status.textContent = text;
				status.hidden = false;
			};
			status.hidden = true;
			// The visitor's own layouts travel in the fragment (layout_formats.js toLink).
			let link = url;
			try {
				if (own.length > 0) link = `${url}#${await window.LAYOUT_FORMATS.toLink(own)}`;
			} catch (error) {
				const refusal = window.LAYOUT_FORMATS.refusalMessage(error);
				report(t(refusal.key, refusal.values));
				return;
			}
			try {
				await navigator.clipboard.writeText(link);
				report(
					link.length > window.LAYOUT_FORMATS.LINK_LONG
						? t('layout_analysis.share.copied_long', { size: format(link.length / 1024, 0) })
						: personal
							? t('layout_analysis.share.copied_partial')
							: t('layout_analysis.share.copied')
				);
			} catch {
				report(t('layout_analysis.share.failed', { url: link }));
			}
		}

		// ===========================
		// ======= 6/ Controls =======
		// ===========================

		function fillCorpora() {
			// The user's own texts first (maintainer, 2026-11-17): « My typing »,
			// listed at once while the app reads it, then the pasted text.
			const mine = [];
			if (!corpora.some((c) => c.id === MY_TYPING_ID) && myTypingState)
				mine.push({
					id: MY_TYPING_ID,
					label: t(
						myTypingState.state === 'loading'
							? 'layout_analysis.corpus.my_typing_loading'
							: 'layout_analysis.corpus.my_typing_unavailable'
					),
					disabled: true,
					title: myTypingState.reason
				});
			for (const corpus of corpora.filter((c) => !c.builtin))
				mine.push({
					id: corpus.id,
					label:
						corpus.id === CUSTOM_ID
							? t('layout_analysis.corpus.custom')
							: corpus.id === MY_TYPING_ID && !corpus.title
								? t('layout_analysis.corpus.my_typing')
								: corpus.title
				});
			window.LAYOUT_ANALYSIS_FILES.fillCorpusPicker($('la-corpus'), {
				mine,
				builtins: corpora.filter((c) => c.builtin).map((c) => c.builtin),
				value: state.corpus,
				t,
				locale: INFO.locale()
			});
			$('la-corpus').classList.toggle('la-corpus-mine', state.corpus === MY_TYPING_ID);
			showCorpusInfo();
			fillBlend();
		}

		/** A personal corpus's name in the pickers: the pasted text and « My typing » by their words. */
		function ownCorpusLabel(corpus) {
			if (corpus.id === CUSTOM_ID) return t('layout_analysis.corpus.custom');
			if (corpus.id === MY_TYPING_ID && !corpus.title) return t('layout_analysis.corpus.my_typing');
			return corpus.title;
		}

		/**
		 * The blend's parts: each a corpus picker (the user's own texts that can
		 * be mixed first, then the built-in corpora) and its weight.
		 */
		function fillBlend() {
			const builtins = corpora.filter((c) => c.builtin);
			const mine = corpora
				.filter((c) => !c.builtin && blendable(c, Boolean(state.custom)))
				.map((c) => ({ id: c.id, label: ownCorpusLabel(c) }));
			for (let i = 0; i < BLEND_PARTS; i++) {
				$(`la-blend-corpus-label-${i}`).textContent = t('layout_analysis.blend.corpus', {
					n: i + 1
				});
				$(`la-blend-weight-label-${i}`).textContent = t('layout_analysis.blend.weight', {
					n: i + 1
				});
				const select = $(`la-blend-corpus-${i}`);
				// A part whose own text left the list goes back to a built-in corpus.
				const kept = [...builtins, ...mine].some((c) => c.id === select.value);
				const chosen = kept ? select.value : (builtins[i] || builtins[0]).id;
				window.LAYOUT_ANALYSIS_FILES.fillCorpusPicker(select, {
					mine,
					builtins: builtins.map((c) => c.builtin),
					value: chosen,
					t,
					locale: INFO.locale()
				});
				const weight = $(`la-blend-weight-${i}`);
				if (weight.value === '') weight.value = String(BLEND_DEFAULT_WEIGHTS[i]);
			}
		}

		/**
		 * A blend part's tables: a built-in corpus loaded, the pasted text, or an
		 * own text's typed keys (the text every other corpus is).
		 */
		function blendPartTables(corpus) {
			if (corpus.builtin) return window.LAYOUT_ANALYSIS_FILES.builtinTables(corpus.builtin);
			if (corpus.id === CUSTOM_ID) return Promise.resolve(state.custom.tables);
			return Promise.resolve(
				window.LAYOUT_ANALYSIS_FILES.plainTables(corpus.host.tables, TEXT_TYPED)
			);
		}

		/**
		 * Mixes the chosen corpora, built-in or the user's own texts, by their
		 * weights (E.blendNgrams) and compares on the blend, listed with the
		 * user's own texts.
		 */
		async function useBlend() {
			const status = $('la-blend-status');
			const parts = [];
			for (let i = 0; i < BLEND_PARTS; i++) {
				const weight = Number($(`la-blend-weight-${i}`).value);
				if (!Number.isFinite(weight) || weight < 0) {
					status.textContent = t('layout_analysis.blend.weight_invalid', { n: i + 1 });
					return;
				}
				if (weight === 0) continue;
				const select = $(`la-blend-corpus-${i}`);
				const corpus = corpora.find((c) => c.id === select.value);
				parts.push({ corpus, weight, name: select.selectedOptions[0].textContent });
			}
			if (parts.length === 0) {
				status.textContent = t('layout_analysis.blend.empty');
				return;
			}
			status.textContent = t('layout_analysis.blend.loading');
			const loaded = await Promise.all(parts.map((part) => blendPartTables(part.corpus)));
			const all = parts.reduce((sum, part) => sum + part.weight, 0);
			const tables = E.blendNgrams(
				loaded.map((ngrams, i) => ({ ngrams, weight: parts[i].weight }))
			);
			const title = t('layout_analysis.blend.entry', {
				parts: parts
					.map((part) =>
						t('layout_analysis.blend.entry_part', {
							name: part.name,
							share: measure((100 * part.weight) / all, 0, '%')
						})
					)
					.join(', ')
			});
			state.blendRecipe = parts.map((part) => ({ id: part.corpus.id, weight: part.weight }));
			state.corpus = BLEND_ID;
			setCorpus({ id: BLEND_ID, title, tables, default: true });
			// A blend of the user's own text stays on this device: no link carries it.
			status.textContent = parts.every((part) => part.corpus.builtin)
				? t('layout_analysis.blend.done', { title })
				: t('layout_analysis.blend.done_own', { title });
		}

		/** Fills the blend's form from a recipe and compares on it again. */
		function restoreBlend(recipe) {
			fillBlend();
			for (let i = 0; i < BLEND_PARTS; i++) {
				const part = recipe[i];
				if (part) $(`la-blend-corpus-${i}`).value = part.id;
				$(`la-blend-weight-${i}`).value = String(part ? part.weight : 0);
			}
			return useBlend();
		}

		/**
		 * The text the layouts type: the chosen mode on « My typing », the one
		 * corpus that can bring the keys typed and the final text apart; the
		 * keys typed on every other corpus, whose single text both are, so the
		 * saved mode is kept but not applied there.
		 * @returns {string} A TEXT_MODES value.
		 */
		function appliedTextMode() {
			return state.corpus === MY_TYPING_ID ? state.textMode : TEXT_TYPED;
		}

		/**
		 * The text mode control, under the corpus picker and shown on « My
		 * typing » only (maintainer, 2026-11-18): elsewhere the choice means
		 * nothing (appliedTextMode). Its value, and why it is greyed on a read
		 * of one text, or what the chosen mode does.
		 */
		function showTextMode() {
			$('la-text-mode-field').hidden = state.corpus !== MY_TYPING_ID;
			const select = $('la-text-mode');
			const two = hasTwoTexts();
			select.value = state.textMode;
			select.disabled = !two;
			$('la-text-mode-info').textContent = two
				? t(`layout_analysis.text_mode.info_${state.textMode}`)
				: t('layout_analysis.text_mode.one_text');
		}

		function showCorpusInfo() {
			const corpus = corpora.find((c) => c.id === state.corpus);
			$('la-custom').hidden = corpus.id !== CUSTOM_ID;
			$('la-file-formats').textContent = t('layout_analysis.corpus.file_formats', {
				formats: window.LAYOUT_ANALYSIS_FILES.FILE_EXTENSIONS.map((extension) =>
					extension.toUpperCase()
				).join(', ')
			});
			$('la-corpus-info').textContent = corpus.builtin
				? t('layout_analysis.corpus.info', {
						chars: format(corpus.builtin.characters, 0),
						licence: corpus.builtin.licence,
						// The attribution the licence requires, then where the text comes from.
						source: `${corpus.builtin.attribution} — ${corpus.builtin.source}`
					})
				: corpus.host
					? t('layout_analysis.corpus.private')
					: t('layout_analysis.corpus.local');
			// A corpus counted from a word list says what its n-grams leave out.
			if (corpus.builtin && corpus.builtin.word_list)
				$('la-corpus-info').textContent += ` ${t('layout_analysis.corpus.word_list')}`;
		}

		/** The visitor picks the layouts: from now on the selection is theirs and kept. */
		function chooseSelection() {
			state.selectionChosen = true;
			state.linkedSelection = false;
		}

		/** Text as the layout search compares it: lower case, without accents. */
		function folded(text) {
			return String(text).normalize('NFD').replace(/\p{M}/gu, '').toLowerCase();
		}

		/** The words the layout search reads: the name, id, family and authors. */
		function searchText(layout) {
			const authors = Array.isArray(layout.authors)
				? layout.authors.join(' ')
				: layout.authors || '';
			return folded([layout.name, layout.id, layout.family || '', authors].join(' '));
		}

		/**
		 * The letter heading a layout is listed under: the first letter of its
		 * name without its accent (« É » under « E »), « # » for a digit or a sign.
		 */
		function letterOf(layout) {
			const first = folded(layout.name).charAt(0).toUpperCase();
			return /\p{L}/u.test(first) ? first : LETTER_OTHER;
		}

		/** Whether the layout list's filters (text, origin, language) show a layout. */
		function pickShows(layout) {
			const filter = folded($('la-filter').value.trim());
			return (
				(!filter || filter.split(/\s+/).every((word) => searchText(layout).includes(word))) &&
				(!state.pick.origin || originOf(layout) === state.pick.origin) &&
				(!state.pick.language || layout.language === state.pick.language)
			);
		}

		/**
		 * The layout list (maintainer, 2026-11-18): one column in alphabetical
		 * order under a heading per first letter, a letter index that jumps to
		 * each heading, the ticked layouts marked, and a count the search and
		 * the ticks announce.
		 */
		function fillLayouts() {
			const list = $('la-layout-list');
			const letters = $('la-letters');
			const shown = layouts
				.filter(pickShows)
				.sort((a, b) => folded(a.name).localeCompare(folded(b.name)) || a.id.localeCompare(b.id));
			const groups = new Map();
			for (const layout of shown) {
				const letter = letterOf(layout);
				if (!groups.has(letter)) groups.set(letter, []);
				groups.get(letter).push(layout);
			}
			const sections = [];
			const jumps = [];
			for (const [letter, members] of groups) {
				const id = `la-letter-${letter === LETTER_OTHER ? 'other' : letter}`;
				const section = el('section', 'la-letter-group');
				section.setAttribute('aria-labelledby', id);
				const heading = el('h3', 'la-letter', letter);
				heading.id = id;
				heading.tabIndex = -1;
				const items = el('ul', 'la-letter-items');
				for (const layout of members) items.append(layoutItem(layout));
				section.append(heading, items);
				sections.push(section);
				const jump = el('a', 'la-letter-jump', letter);
				jump.href = `#${id}`;
				jump.title = t('layout_analysis.layouts.jump', { letter });
				jump.addEventListener('click', (event) => {
					event.preventDefault();
					heading.scrollIntoView({ block: 'start' });
					const first = section.querySelector('input');
					(first || heading).focus({ preventScroll: true });
				});
				jumps.push(jump);
			}
			list.replaceChildren(...sections);
			letters.replaceChildren(...jumps);
			letters.setAttribute('aria-label', t('layout_analysis.layouts.letters'));
			letters.hidden = jumps.length < 2;
			showPickCount(shown.length);
		}

		/** The live line under the search: how many layouts are shown and ticked. */
		function showPickCount(shown) {
			$('la-pick-count').textContent = t('layout_analysis.layouts.count', {
				shown,
				total: layouts.length,
				selected: layouts.filter((layout) => state.selected.has(layout.id)).length
			});
		}

		/** One layout of the list: its box and name, its family, its « + » twin. */
		function layoutItem(layout) {
			const item = el('li', 'la-layout-item');
			const label = el('label', 'la-layout');
			const box = el('input');
			box.type = 'checkbox';
			box.checked = state.selected.has(layout.id);
			item.classList.toggle('la-picked', box.checked);
			box.addEventListener('change', () => {
				if (box.checked) state.selected.add(layout.id);
				else state.selected.delete(layout.id);
				item.classList.toggle('la-picked', box.checked);
				chooseSelection();
				save();
				showPickCount(visibleLayoutIds().length);
				analyse();
			});
			label.append(box, el('b', 'la-layout-name', layout.name));
			const authors = Array.isArray(layout.authors) ? layout.authors.join(', ') : '';
			// The authors beside the label, so the box is named by the layout alone.
			item.append(label);
			if (own.has(layout.id)) {
				item.classList.add('la-own');
				item.append(state.renaming === layout.id ? renameForm(layout) : ownActions(layout, item));
			}
			if (authors) item.append(el('small', 'la-layout-meta', authors));
			// « + »: this layout also ranks as « <name>+ », typing the keys typed with
			// the Ergopti+ hotstrings, while the others type the final text.
			if (appliedTextMode() !== TEXT_MIXED) return item;
			const plusLabel = el('label', 'la-plus');
			const plus = el('input');
			plus.type = 'checkbox';
			plus.checked = state.plus.has(layout.id);
			plus.disabled = !hasTwoTexts();
			plusLabel.title = hasTwoTexts()
				? t('layout_analysis.text_mode.plus_title', { layout: layout.name + PLUS_SUFFIX })
				: t('layout_analysis.text_mode.one_text');
			plus.addEventListener('change', () => {
				if (plus.checked) state.plus.add(layout.id);
				else state.plus.delete(layout.id);
				save();
				analyse();
			});
			plusLabel.append(plus, layout.name + PLUS_SUFFIX);
			item.append(plusLabel);
			return item;
		}

		// ======================================
		// ======= 4b/ The user's own layouts ===
		// ======================================

		/** A small icon of a list action (MINE_ICONS); its button's name says what it does. */
		function mineIcon(id) {
			const svg = document.createElementNS(SVG_NS, 'svg');
			svg.setAttribute('viewBox', '0 0 24 24');
			svg.setAttribute('class', `la-mine-icon la-mine-icon-${id}`);
			svg.setAttribute('aria-hidden', 'true');
			svg.setAttribute('focusable', 'false');
			const path = document.createElementNS(SVG_NS, 'path');
			path.setAttribute('d', MINE_ICONS[id]);
			svg.append(path);
			return svg;
		}

		/** One action button of an own layout: its icon and its word, named with the layout. */
		function mineButton(id, layout, run) {
			const button = el('button', `la-mine-button la-mine-${id}`);
			button.type = 'button';
			button.dataset.mine = id;
			button.dataset.layout = layout.id;
			button.append(mineIcon(id), t(`layout_analysis.mine.${id}`));
			button.setAttribute(
				'aria-label',
				t(`layout_analysis.mine.${id}_named`, { name: layout.name })
			);
			button.addEventListener('click', run);
			return button;
		}

		/** « Rename », « Duplicate » and « Remove » beside an own layout of the list. */
		function ownActions(layout) {
			const box = el('p', 'la-mine-actions');
			box.append(
				el('b', 'la-mine-badge', t('layout_analysis.mine.badge')),
				mineButton('rename', layout, () => {
					state.renaming = layout.id;
					fillLayouts();
					const field = $('la-rename-field');
					field.focus();
					field.select();
				}),
				mineButton('duplicate', layout, () => duplicateLayout(layout.id)),
				mineButton('remove', layout, () => removeLayout(layout.id))
			);
			return box;
		}

		/** The name field that replaces an own layout's actions while it is renamed. */
		function renameForm(layout) {
			const form = el('form', 'la-rename');
			const field = el('input', 'la-rename-input');
			field.id = 'la-rename-field';
			field.value = layout.name;
			field.setAttribute('aria-label', t('layout_analysis.mine.name_label', { name: layout.name }));
			field.setAttribute('aria-describedby', 'la-mine-status');
			const saveButton = el('button', 'la-mine-button', t('layout_analysis.mine.save'));
			saveButton.type = 'submit';
			const cancel = el('button', 'la-mine-button', t('layout_analysis.mine.cancel'));
			cancel.type = 'button';
			const close = () => {
				state.renaming = null;
				fillLayouts();
				const again = root.querySelector(`button[data-mine="rename"][data-layout="${layout.id}"]`);
				if (again) again.focus();
			};
			cancel.addEventListener('click', close);
			field.addEventListener('keydown', (event) => {
				if (event.key !== 'Escape') return;
				event.preventDefault();
				close();
			});
			form.addEventListener('submit', async (event) => {
				event.preventDefault();
				if (await renameLayout(layout.id, field.value)) close();
				else field.focus();
			});
			form.append(field, saveButton, cancel);
			return form;
		}

		/** The line under the list that says what was done to an own layout, with its « Undo ». */
		function mineStatus(text, error, undo) {
			const node = $('la-mine-status');
			node.hidden = false;
			node.className = `la-mine-status ${error ? 'la-error' : 'la-ok'}`;
			node.replaceChildren(text);
			if (!undo) return;
			const button = el('button', 'la-mine-undo', t('layout_analysis.undo.button'));
			button.type = 'button';
			button.addEventListener('click', async () => {
				button.disabled = true;
				await undo();
			});
			node.append(' ', button);
		}

		/** Keeps an own layout where the user's layouts live: the host's store, else this browser. */
		async function keepOwn(layout) {
			if (HOST.store) {
				await HOST.store.save(layout);
				return;
			}
			const at = imported.findIndex((entry) => entry.id === layout.id);
			if (at >= 0) imported.splice(at, 1, layout);
			else imported.push(layout);
			save();
		}

		/** Takes an own layout out of where it is kept. */
		async function dropOwn(id) {
			if (HOST.store) {
				await HOST.store.remove(id);
				return;
			}
			const at = imported.findIndex((entry) => entry.id === id);
			if (at >= 0) imported.splice(at, 1);
			save();
		}

		/** A reason a host or a browser gave for a failed save, for the status line. */
		function failure(error) {
			return t('layout_analysis.mine.failed', {
				reason: (error && (error.code || error.message)) || String(error)
			});
		}

		/**
		 * Renames an own layout, kept at once; an empty name is refused in words.
		 * @returns {Promise<boolean>} Whether the name was taken.
		 */
		async function renameLayout(id, name) {
			const clean = String(name).trim();
			if (clean === '') {
				mineStatus(t('layout_analysis.mine.name_empty'), true);
				return false;
			}
			const layout = byId.get(id);
			const before = layout.name;
			if (clean === before) return true;
			layout.name = clean;
			try {
				await keepOwn(layout);
			} catch (error) {
				layout.name = before;
				mineStatus(failure(error), true);
				return false;
			}
			mineStatus(t('layout_analysis.mine.renamed', { before, name: clean }), false);
			fillLayouts();
			analyse();
			return true;
		}

		/** Adds a copy of an own layout, named as a copy, kept and ticked. */
		async function duplicateLayout(id) {
			const layout = byId.get(id);
			const copy = E.layoutFromRows(
				Object.assign(JSON.parse(JSON.stringify(layout)), {
					name: t('layout_analysis.mine.copy_name', { name: layout.name })
				})
			);
			let copyId = `${id}_copy`;
			for (let n = 2; byId.has(copyId); n++) copyId = `${id}_copy_${n}`;
			copy.id = copyId;
			try {
				await keepOwn(copy);
			} catch (error) {
				mineStatus(failure(error), true);
				return;
			}
			layouts.push(copy);
			byId.set(copyId, copy);
			own.add(copyId);
			state.selected.add(copyId);
			save();
			mineStatus(t('layout_analysis.mine.duplicated', { name: copy.name }), false);
			fillLayouts();
			analyse();
		}

		/** Removes an own layout from the list and from where it is kept, with an « Undo ». */
		async function removeLayout(id) {
			const layout = byId.get(id);
			const wasSelected = state.selected.has(id);
			try {
				await dropOwn(id);
			} catch (error) {
				mineStatus(failure(error), true);
				return;
			}
			layouts.splice(layouts.indexOf(layout), 1);
			byId.delete(id);
			own.delete(id);
			state.selected.delete(id);
			state.plus.delete(id);
			if (state.details === id) state.details = null;
			if (state.versus === id) state.versus = null;
			save();
			fillLayouts();
			analyse();
			mineStatus(t('layout_analysis.mine.removed', { name: layout.name }), false, async () => {
				try {
					await keepOwn(layout);
				} catch (error) {
					mineStatus(failure(error), true);
					return;
				}
				layouts.push(layout);
				byId.set(id, layout);
				own.add(id);
				if (wasSelected) state.selected.add(id);
				save();
				mineStatus(t('layout_analysis.mine.restored', { name: layout.name }), false);
				fillLayouts();
				analyse();
			});
			$('la-mine-status').querySelector('button').focus();
		}

		// The file name a score settings export is saved under.
		const SCORE_CONFIG_FILE = 'ergopti-score-settings.json';

		/** Shows one line of the score settings status; error marks a refusal. */
		function configStatus(text, error) {
			const status = $('la-config-status');
			status.className = error ? 'la-error' : 'la-muted';
			status.textContent = text;
		}

		/** Fills every score settings control again, then analyses with them. */
		function applyScoreSettings() {
			fillPresets();
			fillWeights();
			fillIdealLoad();
			fillShortcuts();
			fillForms();
			save();
			// The access weights may have changed: the layouts are typed again.
			analyse();
		}

		/**
		 * The score settings file: export (the host's download path in the app,
		 * a browser download on the site), a strict import that applies a file
		 * whole or not at all, and a reset of every setting with an « Undo ».
		 */
		/** The current score settings as a file (E.scoreConfig): what a preset holds. */
		function currentConfig() {
			return E.scoreConfig({
				weights: state.weights,
				floors: state.floors,
				grades: state.grades,
				idealLoad: state.idealLoad,
				shortcuts: state.shortcuts,
				formWeights: state.formWeights
			});
		}

		/**
		 * Applies a preset's settings whole (as an import does) and offers to
		 * put the previous ones back.
		 * @returns {boolean} Whether it applied; a refusal is said in words.
		 */
		function applyPreset(config, name) {
			let settings;
			try {
				settings = E.readScoreConfig(config);
			} catch (error) {
				configStatus(
					t('layout_analysis.presets.refused', { name, reason: INFO.refusal(error) }),
					true
				);
				return false;
			}
			const before = currentConfig();
			history.label({ key: 'edit_history.step.preset', values: { name } });
			Object.assign(state, settings);
			applyScoreSettings();
			presetStatus(t('layout_analysis.presets.applied', { name }), () => {
				Object.assign(state, E.readScoreConfig(before));
				applyScoreSettings();
				configStatus(t('layout_analysis.presets.undone', { name }), false);
			});
			return true;
		}

		/** The settings status with an « Undo » that runs undo. */
		function presetStatus(text, undo) {
			configStatus(text, false);
			const button = el('button', 'la-mine-undo', t('layout_analysis.undo.button'));
			button.type = 'button';
			button.addEventListener('click', () => {
				button.disabled = true;
				undo();
			});
			$('la-config-status').append(' ', button);
		}

		/** Whether a preset holds exactly the settings in use. */
		function isCurrent(config) {
			return JSON.stringify(config) === JSON.stringify(currentConfig());
		}

		/** The built-in presets as cards, then the user's own, each with its actions. */
		function fillPresets() {
			$('la-preset-list').replaceChildren(
				...SCORE_SETTINGS.PRESET_IDS.map((id, index) => {
					const config = SCORE_SETTINGS.presetConfig(id);
					const name = t(`layout_analysis.presets.${id}.name`);
					const item = el('li', `la-preset la-preset-accent-${(index % 5) + 1}`);
					const button = el('button', 'la-preset-apply');
					button.type = 'button';
					button.dataset.preset = id;
					const active = isCurrent(config);
					button.setAttribute('aria-pressed', String(active));
					button.append(
						el('b', 'la-preset-name', name),
						el('small', 'la-preset-help', t(`layout_analysis.presets.${id}.help`))
					);
					if (active)
						button.append(el('b', 'la-preset-active', t('layout_analysis.presets.active')));
					button.addEventListener('click', () => applyPreset(config, name));
					item.append(button);
					return item;
				})
			);
			$('la-preset-none').hidden = state.presets.length > 0;
			$('la-preset-mine').replaceChildren(...state.presets.map(userPresetItem));
		}

		/** The name field of a user preset being renamed; Escape cancels. */
		function presetRenameForm(preset, index) {
			const form = el('form', 'la-rename');
			const field = el('input', 'la-rename-input');
			field.id = 'la-preset-rename-field';
			field.value = preset.name;
			field.maxLength = 60;
			field.setAttribute('aria-label', t('layout_analysis.mine.name_label', { name: preset.name }));
			const ok = el('button', 'la-mine-button', t('layout_analysis.mine.save'));
			ok.type = 'submit';
			const cancel = el('button', 'la-mine-button', t('layout_analysis.mine.cancel'));
			cancel.type = 'button';
			const close = () => {
				state.presetRenaming = null;
				fillPresets();
				const again = $('la-preset-mine').querySelector(
					`li[data-index="${index}"] button[data-mine="rename"]`
				);
				if (again) again.focus();
			};
			cancel.addEventListener('click', close);
			field.addEventListener('keydown', (event) => {
				if (event.key !== 'Escape') return;
				event.preventDefault();
				close();
			});
			form.addEventListener('submit', (event) => {
				event.preventDefault();
				const name = field.value.trim();
				if (name === '') {
					configStatus(t('layout_analysis.mine.name_empty'), true);
					field.focus();
					return;
				}
				const before = preset.name;
				preset.name = name;
				save();
				configStatus(t('layout_analysis.mine.renamed', { before, name }), false);
				close();
			});
			form.append(field, ok, cancel);
			return form;
		}

		/** One of the user's presets: its name, « Apply », « Rename » and « Remove ». */
		function userPresetItem(preset, index) {
			const item = el('li', 'la-preset-own');
			item.dataset.index = String(index);
			if (state.presetRenaming === index) {
				item.append(presetRenameForm(preset, index));
				return item;
			}
			let readable = true;
			try {
				E.readScoreConfig(preset.config);
			} catch {
				readable = false;
			}
			item.append(el('b', 'la-preset-name', preset.name));
			if (readable && isCurrent(preset.config))
				item.append(el('b', 'la-preset-active', t('layout_analysis.presets.active')));
			// A preset saved by an older Studio: said, never applied in part.
			if (!readable) item.append(el('b', 'la-preset-stale', t('layout_analysis.presets.stale')));
			const actions = el('p', 'la-mine-actions');
			const apply = el(
				'button',
				'la-mine-button la-preset-use',
				t('layout_analysis.presets.apply')
			);
			apply.type = 'button';
			apply.disabled = !readable;
			apply.setAttribute(
				'aria-label',
				t('layout_analysis.presets.apply_named', { name: preset.name })
			);
			apply.addEventListener('click', () => applyPreset(preset.config, preset.name));
			const named = { id: `preset-${index}`, name: preset.name };
			actions.append(
				apply,
				mineButton('rename', named, () => {
					state.presetRenaming = index;
					fillPresets();
					const field = $('la-preset-rename-field');
					field.focus();
					field.select();
				}),
				mineButton('remove', named, () => {
					const [removed] = state.presets.splice(index, 1);
					save();
					fillPresets();
					presetStatus(t('layout_analysis.mine.removed', { name: removed.name }), () => {
						state.presets.splice(Math.min(index, state.presets.length), 0, removed);
						save();
						fillPresets();
						configStatus(t('layout_analysis.mine.restored', { name: removed.name }), false);
					});
					$('la-config-status').querySelector('button').focus();
				})
			);
			item.append(actions);
			return item;
		}

		/** « Save as a preset »: the current settings under a name; a name taken replaces that preset. */
		function wirePresets() {
			$('la-preset-save').addEventListener('submit', (event) => {
				event.preventDefault();
				const name = $('la-preset-name').value.trim();
				if (name === '') {
					configStatus(t('layout_analysis.mine.name_empty'), true);
					$('la-preset-name').focus();
					return;
				}
				const entry = { name, config: currentConfig() };
				const at = state.presets.findIndex((p) => p.name === name);
				if (at >= 0) state.presets.splice(at, 1, entry);
				else state.presets.push(entry);
				save();
				$('la-preset-name').value = '';
				fillPresets();
				configStatus(
					t(at >= 0 ? 'layout_analysis.presets.replaced' : 'layout_analysis.presets.saved', {
						name
					}),
					false
				);
			});
			presetsReady = true;
			fillPresets();
		}

		function wireScoreConfig() {
			wirePresets();
			const parts = ['weights', 'floors', 'grades', 'idealLoad', 'shortcuts', 'formWeights'];
			$('la-config-export').addEventListener('click', async () => {
				const text = `${JSON.stringify(
					E.scoreConfig({
						weights: state.weights,
						floors: state.floors,
						grades: state.grades,
						idealLoad: state.idealLoad,
						shortcuts: state.shortcuts,
						formWeights: state.formWeights
					}),
					null,
					'\t'
				)}\n`;
				if (typeof HOST.saveFile === 'function') {
					try {
						const where = await HOST.saveFile(SCORE_CONFIG_FILE, text);
						configStatus(t('layout_analysis.config.exported', { path: where }), false);
					} catch (error) {
						configStatus(
							t('layout_analysis.config.save_failed', {
								code: (error && error.code) || String(error)
							}),
							true
						);
					}
					return;
				}
				const url = URL.createObjectURL(new Blob([text], { type: 'application/json' }));
				const link = el('a');
				link.href = url;
				link.download = SCORE_CONFIG_FILE;
				document.body.append(link);
				link.click();
				link.remove();
				setTimeout(() => URL.revokeObjectURL(url), 0);
				configStatus(t('layout_analysis.config.downloaded', { name: SCORE_CONFIG_FILE }), false);
			});
			const input = $('la-config-import');
			input.addEventListener('change', async () => {
				const file = input.files && input.files[0];
				input.value = '';
				if (!file) return;
				let settings;
				try {
					settings = E.readScoreConfig(JSON.parse(await file.text()));
				} catch (error) {
					// Nothing is applied: the reason says what to change in the file.
					configStatus(
						t('layout_analysis.config.refused', { name: file.name, reason: INFO.refusal(error) }),
						true
					);
					return;
				}
				history.label({ key: 'edit_history.step.import', values: { name: file.name } });
				Object.assign(state, settings);
				applyScoreSettings();
				configStatus(t('layout_analysis.config.imported', { name: file.name }), false);
			});
			const reset = $('la-config-reset');
			const undo = UNDO.create(reset.closest('section'));
			$('la-config-status').before(undo.node);
			reset.addEventListener('click', () => {
				const before = JSON.stringify(parts.map((part) => state[part]));
				history.label({
					key: 'edit_history.step.restore',
					values: { name: t('layout_analysis.config.title') }
				});
				state.weights = E.defaultWeights();
				state.floors = E.defaultFloors();
				state.grades = E.defaultGrades();
				state.idealLoad = Object.assign({}, E.defaultIdealLoad());
				state.shortcuts = E.defaultShortcuts();
				state.formWeights = E.defaultFormFactorWeights();
				applyScoreSettings();
				configStatus('', false);
				if (before === JSON.stringify(parts.map((part) => state[part]))) {
					undo.clear();
					return;
				}
				undo.offer({
					name: t('layout_analysis.config.title'),
					focus: reset,
					undo: () => {
						JSON.parse(before).forEach((value, i) => {
							state[parts[i]] = value;
						});
						applyScoreSettings();
					}
				});
			});
		}

		/** A section's decorative icon (SECTION_ICONS): its heading names it. */
		function sectionIcon(id) {
			const svg = document.createElementNS(SVG_NS, 'svg');
			svg.setAttribute('viewBox', '0 0 24 24');
			svg.setAttribute('class', 'la-section-icon');
			svg.setAttribute('aria-hidden', 'true');
			svg.setAttribute('focusable', 'false');
			const path = document.createElementNS(SVG_NS, 'path');
			path.setAttribute('d', SECTION_ICONS[id]);
			svg.append(path);
			return svg;
		}

		/** Puts each static settings section's icon before its heading text, once. */
		function placeSectionIcons() {
			for (const section of document.querySelectorAll('#la-settings [data-section-icon]')) {
				const heading = section.querySelector('.la-heading h2');
				if (heading.querySelector('.la-section-icon')) continue;
				heading.prepend(sectionIcon(section.dataset.sectionIcon));
			}
		}

		/**
		 * The bars of the ideal finger load, one per finger, left hand then right,
		 * each as tall as its share: a picture of the inputs beside it, which stay
		 * the controls (the figure is hidden from assistive technology).
		 * @param {object} values - finger id → share (%), possibly not a number.
		 */
		function drawIdealHands(values) {
			const svg = $('la-ideal-hands');
			svg.replaceChildren();
			const fingers = Object.keys(E.defaultIdealLoad());
			const shares = fingers.map((id) => (Number.isFinite(values[id]) ? values[id] : 0));
			const top = Math.max(20, ...shares);
			const width = 20;
			const base = 100;
			fingers.forEach((id, i) => {
				// A gap between the hands: the four left fingers, then the four right.
				const x = 10 + i * 24 + (i >= fingers.length / 2 ? 12 : 0);
				const height = Math.max(4, (shares[i] / top) * 80);
				const bar = document.createElementNS(SVG_NS, 'rect');
				bar.setAttribute('x', String(x));
				bar.setAttribute('y', String(base - height));
				bar.setAttribute('width', String(width));
				bar.setAttribute('height', String(height));
				bar.setAttribute('rx', '9');
				bar.setAttribute('class', 'la-ideal-finger');
				const value = document.createElementNS(SVG_NS, 'text');
				value.setAttribute('x', String(x + width / 2));
				value.setAttribute('y', String(base - height - 4));
				value.setAttribute('class', 'la-ideal-value');
				value.textContent = format(shares[i], 0);
				bar.dataset.finger = id;
				svg.append(bar, value);
			});
			// Each hand's palm under its four fingers.
			for (const x of [8, 116]) {
				const palm = document.createElementNS(SVG_NS, 'rect');
				palm.setAttribute('x', String(x));
				palm.setAttribute('y', String(base + 2));
				palm.setAttribute('width', '96');
				palm.setAttribute('height', '16');
				palm.setAttribute('rx', '8');
				palm.setAttribute('class', 'la-ideal-palm');
				svg.append(palm);
			}
		}

		/**
		 * One weight's control: its name (the label of its input), its « i », the
		 * input with the points it is worth per unit, and the metric's definition
		 * (the « i » text, one source with the popover) as the input's description.
		 */
		function weightControl(id) {
			const metric = E.METRICS[id];
			const control = el('li', 'la-weight-card');
			const inputId = `la-weight-${id}`;
			const top = el('p', 'la-weight-top');
			const label = el('label', 'la-weight-name', t(`layout_analysis.metric.${id}`));
			label.htmlFor = inputId;
			top.append(label, infoButton(id));
			const field = el('p', 'la-weight-field');
			const input = el('input');
			input.id = inputId;
			input.type = 'number';
			input.min = '0';
			input.step = 'any';
			input.value = String(state.weights[id]);
			input.setAttribute('aria-describedby', `${inputId}-unit ${inputId}-help`);
			const unit = el(
				'small',
				'la-weight-unit',
				t(`layout_analysis.weights.per_${metric.better}`, {
					unit: metric.unit === 'mm' ? t('layout_analysis.unit.mm') : '%'
				})
			);
			unit.id = `${inputId}-unit`;
			field.append(input, unit);
			const help = el('p', 'la-weight-help', t(`layout_analysis.info.${id}`));
			help.id = `${inputId}-help`;
			control.append(top, field);
			// A penalty's floor: the part of its value under it costs nothing.
			if (id in state.floors) control.append(floorField(id, metric));
			// A graded metric's scale: what each kind of its events weighs.
			if (id in state.grades) control.append(gradeFields(id));
			control.append(help);
			return { control, input };
		}

		/**
		 * A graded metric's grades (E.GRADES), a group named by its legend: one
		 * labelled control per grade, re-scoring as it is edited (a checkbox for
		 * a switch, else a number: a factor of the weight or a run multiplier,
		 * checked by the engine); the help says what the grades weigh.
		 */
		function gradeFields(id) {
			const group = el('fieldset', 'la-grade-group');
			const legend = el('legend', 'la-floor-name', t(`layout_analysis.grade_legend.${id}`));
			const help = el('p', 'la-weight-help', t(`layout_analysis.grade_help.${id}`));
			help.id = `la-grades-${id}-help`;
			const list = el('ul', 'la-grade-list');
			for (const grade of E.GRADES[id]) {
				const inputId = `la-grade-${id}-${grade}`;
				const item = el('li', 'la-weight-field');
				const label = el('label', 'la-grade-name', t(`layout_analysis.grade.${id}.${grade}`));
				label.htmlFor = inputId;
				const input = el('input');
				input.id = inputId;
				if (E.GRADE_KINDS[id] === E.GRADE_SWITCH) {
					input.type = 'checkbox';
					input.checked = state.grades[id][grade];
					input.setAttribute('aria-describedby', help.id);
					input.addEventListener('change', () => {
						state.grades[id][grade] = input.checked;
						rescore();
					});
					item.append(input, label);
					list.append(item);
					continue;
				}
				input.type = 'number';
				input.min = String(E.gradeMinimum(id, grade));
				input.step = 'any';
				input.value = String(state.grades[id][grade]);
				const unit = el(
					'small',
					'la-weight-unit',
					t(
						E.GRADE_KINDS[id] === E.GRADE_RUN
							? 'layout_analysis.weights.run_unit'
							: 'layout_analysis.weights.grade_unit'
					)
				);
				unit.id = `${inputId}-unit`;
				input.setAttribute('aria-describedby', `${unit.id} ${help.id}`);
				input.addEventListener('input', () => {
					const value = Number(input.value);
					// The engine's own check of the grade (scoreGrades) decides.
					let accepted = input.value !== '';
					if (accepted)
						try {
							E.scoreGrades({ [id]: { [grade]: value } });
						} catch {
							accepted = false;
						}
					if (!accepted) {
						input.setAttribute('aria-invalid', 'true');
						return;
					}
					input.removeAttribute('aria-invalid');
					state.grades[id][grade] = value;
					rescore();
				});
				item.append(label, input, unit);
				list.append(item);
			}
			group.append(legend, list, help);
			return group;
		}

		/** A penalty metric's floor field, in its unit, re-scoring as it is edited. */
		function floorField(id, metric) {
			const inputId = `la-floor-${id}`;
			const field = el('p', 'la-weight-field la-floor-field');
			const label = el('label', 'la-floor-name', t('layout_analysis.weights.floor'));
			label.htmlFor = inputId;
			const input = el('input');
			input.id = inputId;
			input.type = 'number';
			input.min = '0';
			input.step = 'any';
			input.value = String(state.floors[id]);
			const unit = el(
				'small',
				'la-weight-unit',
				t('layout_analysis.weights.floor_unit', {
					unit: metric.unit === 'mm' ? t('layout_analysis.unit.mm') : '%'
				})
			);
			unit.id = `${inputId}-unit`;
			// Its help says what the floor does to this metric's points.
			const help = el(
				'small',
				'la-weight-help la-floor-help',
				t('layout_analysis.weights.floor_help', { metric: t(`layout_analysis.metric.${id}`) })
			);
			help.id = `${inputId}-help`;
			input.setAttribute('aria-describedby', `${unit.id} ${help.id}`);
			// Every card has a floor: each field is named with its metric.
			input.setAttribute(
				'aria-label',
				t('layout_analysis.weights.floor_named', { metric: t(`layout_analysis.metric.${id}`) })
			);
			input.addEventListener('input', () => {
				const value = Number(input.value);
				if (input.value === '' || !Number.isFinite(value) || value < 0) {
					input.setAttribute('aria-invalid', 'true');
					return;
				}
				input.removeAttribute('aria-invalid');
				state.floors[id] = value;
				rescore();
			});
			field.append(label, input, unit, help);
			return field;
		}

		function fillWeights() {
			const list = $('la-weight-list');
			list.replaceChildren();
			const grouped = Object.values(WEIGHT_GROUPS).flat();
			for (const id of Object.keys(E.defaultWeights()))
				if (!grouped.includes(id))
					throw new Error(`layout_analysis: the weight ${id} is in no WEIGHT_GROUPS group`);
			for (const [group, ids] of Object.entries(WEIGHT_GROUPS)) {
				const section = el('section', `la-weight-group la-accent-${SECTION_SLOT[group]}`);
				const headingId = `la-weight-group-${group}`;
				section.setAttribute('aria-labelledby', headingId);
				const heading = el('h3', 'la-group-heading');
				heading.id = headingId;
				heading.append(sectionIcon(group), t(`layout_analysis.weights.group.${group}`));
				const grid = el('ul', 'la-weight-list');
				section.append(
					heading,
					el('p', 'la-muted', t(`layout_analysis.weights.group_help.${group}`)),
					grid
				);
				list.append(section);
				for (const id of ids) {
					const { control, input } = weightControl(id);
					grid.append(control);
					wireWeight(id, input);
				}
			}
			placeSectionIcons();
		}

		/** Re-scores (or, for an access weight, analyses again) as a weight is edited. */
		function wireWeight(id, input) {
			input.addEventListener('input', () => {
				const value = Number(input.value);
				if (input.value === '' || !Number.isFinite(value) || value < 0) {
					input.setAttribute('aria-invalid', 'true');
					return;
				}
				input.removeAttribute('aria-invalid');
				state.weights[id] = value;
				// An access weight chooses the ways of typing: the layouts are typed again.
				if (E.ACCESS_WEIGHTS.includes(id)) {
					save();
					analyse();
				} else rescore();
			});
		}

		function fillIdealLoad() {
			const list = $('la-ideal-list');
			list.replaceChildren();
			const inputs = {};
			const showSum = () => {
				drawIdealHands(
					Object.fromEntries(
						Object.keys(inputs).map((id) => [
							id,
							inputs[id].value === '' ? NaN : Number(inputs[id].value)
						])
					)
				);
				const sum = Object.keys(inputs).reduce((total, id) => total + Number(inputs[id].value), 0);
				const box = $('la-ideal-sum');
				box.textContent = t('layout_analysis.ideal.sum', { sum: format(sum, 1) });
				let load;
				try {
					load = E.idealLoad(
						Object.fromEntries(
							Object.keys(inputs).map((id) => [
								id,
								inputs[id].value === '' ? NaN : Number(inputs[id].value)
							])
						)
					);
				} catch (error) {
					// Why the load is refused (its sum, a share, the finger order), in words.
					box.className = 'la-error';
					box.textContent = t('layout_analysis.ideal.refused', { reason: INFO.refusal(error) });
					for (const input of Object.values(inputs)) input.setAttribute('aria-invalid', 'true');
					return;
				}
				box.className = 'la-muted';
				for (const input of Object.values(inputs)) input.removeAttribute('aria-invalid');
				state.idealLoad = Object.assign({}, load);
				save();
				analyse();
			};
			for (const id of Object.keys(E.defaultIdealLoad())) {
				const label = el('label', 'la-weight');
				label.append(t(`layout_analysis.finger.${id}`));
				const input = el('input');
				input.type = 'number';
				input.min = '0';
				input.max = '100';
				input.step = 'any';
				input.value = String(state.idealLoad[id]);
				input.addEventListener('input', showSum);
				inputs[id] = input;
				label.append(input);
				list.append(weightItem(label));
			}
			drawIdealHands(state.idealLoad);
			$('la-ideal-sum').textContent = t('layout_analysis.ideal.sum', {
				sum: format(
					Object.values(state.idealLoad).reduce((a, b) => a + b, 0),
					1
				)
			});
		}

		/**
		 * One editable table of numbers (the shortcut letters, the key ease, the
		 * form factor weights): every change is checked by the engine as a whole;
		 * a refused one marks the inputs and says why, an accepted one is kept.
		 * @param {Array<{list: string, values: object, label: function(string): string, max?: number}>} parts
		 * @param {string} statusId The status line.
		 * @param {function(Array<object>): object} accept Builds and checks the whole value; throws on a refusal.
		 */
		function fillTable(parts, statusId, accept) {
			const inputs = parts.map(() => ({}));
			const changed = () => {
				const status = $(statusId);
				const read = inputs.map((group) =>
					Object.fromEntries(
						Object.entries(group).map(([id, input]) => [
							id,
							input.value === '' ? NaN : Number(input.value)
						])
					)
				);
				try {
					accept(read);
				} catch (error) {
					status.className = 'la-error';
					status.textContent = t('layout_analysis.table.refused', { reason: INFO.refusal(error) });
					for (const group of inputs)
						for (const input of Object.values(group)) input.setAttribute('aria-invalid', 'true');
					return;
				}
				status.className = 'la-muted';
				status.textContent = '';
				for (const group of inputs)
					for (const input of Object.values(group)) input.removeAttribute('aria-invalid');
				save();
				analyse();
			};
			parts.forEach((part, index) => {
				const list = $(part.list);
				list.replaceChildren();
				for (const [id, value] of Object.entries(part.values)) {
					const label = el('label', 'la-weight');
					label.append(part.label(id));
					const input = el('input');
					input.type = 'number';
					input.min = '0';
					if (part.max !== undefined) input.max = String(part.max);
					input.step = 'any';
					input.dataset.id = id;
					input.value = String(value);
					input.addEventListener('input', changed);
					inputs[index][id] = input;
					label.append(input);
					list.append(weightItem(label));
				}
			});
		}

		/** The shortcut letters' usefulness and their keys' ease (shortcut_left). */
		function fillShortcuts() {
			fillTable(
				[
					{
						list: 'la-shortcut-letters',
						values: state.shortcuts.letters,
						label: (letter) => letter.toUpperCase(),
						max: 10
					},
					{ list: 'la-shortcut-ease', values: state.shortcuts.ease, label: (code) => code, max: 1 }
				],
				'la-shortcuts-status',
				([letters, ease]) => {
					state.shortcuts = E.shortcuts({ letters, ease });
				}
			);
		}

		/** The compact form factors' weights (compact_fit). */
		function fillForms() {
			fillTable(
				[
					{
						list: 'la-form-list',
						values: state.formWeights,
						label: (id) => t(`layout_analysis.forms.${id}`)
					}
				],
				'la-forms-status',
				([weights]) => {
					state.formWeights = E.formFactorWeights(weights);
				}
			);
		}

		/** What a reader could not carry, worded in the page's language (eight at most). */
		function lossList(unmapped) {
			const words = unmapped.slice(0, 8).map((entry) => {
				const loss = window.LAYOUT_FORMATS.lossMessage(entry);
				return t(loss.key, loss.values);
			});
			return unmapped.length > 8 ? `${words.join(', ')}…` : words.join(', ');
		}

		/** What the layout readers need from the page (layout_formats.js). */
		function readerTools() {
			return {
				parseToml: window.exports && window.exports.parse,
				scancodes: DATA.scancodes,
				composer: window.LayoutComposer,
				// A top-level const of composer_data.js: a page global, not a window property.
				table: LAYOUT_COMPOSER_DATA,
				analysis: E
			};
		}

		/** A format's name in the page's language (what the readers recognised). */
		function formatName(format) {
			return t(window.LAYOUT_FORMATS.formatNameKey(format));
		}

		/** Reads a layout file into the comparison, and says what could not be read. */
		async function importLayout(file) {
			let result;
			try {
				const bytes = new Uint8Array(await file.arrayBuffer());
				result = window.LAYOUT_FORMATS.readBytes(file.name, bytes, readerTools());
			} catch (error) {
				refuseImport(error);
				return;
			}
			await addRead(result, file.name);
		}

		/**
		 * Reads the pasted text (or a dropped one) into the comparison by its
		 * content; the text stays in its field when it is refused, to be fixed.
		 */
		async function importPasted(text) {
			let result;
			try {
				result = window.LAYOUT_FORMATS.readText(text, readerTools());
			} catch (error) {
				refuseImport(error);
				return false;
			}
			await addRead(result, formatName(result.format));
			return true;
		}

		/** Says why a file or a text was not added: where it is wrong, and how to fix it. */
		function refuseImport(error) {
			const report = $('la-import-report');
			report.hidden = false;
			report.className = 'la-import-report la-error';
			const refusal = window.LAYOUT_FORMATS.refusalMessage(error);
			report.textContent = t(refusal.key, refusal.values);
		}

		/** Live under the paste field: the format the text is in, or that none is recognised yet. */
		function showDetected() {
			const text = $('la-paste').value;
			const node = $('la-paste-detected');
			const format = text.trim() === '' ? null : window.LAYOUT_FORMATS.detect(text);
			node.classList.toggle('la-detected-yes', Boolean(format));
			node.classList.toggle('la-detected-no', !format && text.trim() !== '');
			node.textContent =
				text.trim() === ''
					? ''
					: format
						? `✓ ${t('layout_analysis.formats.detected', { format: formatName(format) })}`
						: t('layout_analysis.formats.not_detected');
			$('la-paste-add').disabled = !format;
		}

		/** Adds a read layout to the comparison and the user's own layouts, and says what was read. */
		async function addRead(result, sourceName) {
			const report = $('la-import-report');
			report.hidden = false;
			report.className = 'la-import-report la-ok';
			try {
				const layout = E.layoutFromRows(
					Object.assign({}, result.layout, { origin: 'user', source: sourceName })
				);
				let id = `user_${layout.id}`;
				for (let n = 2; byId.has(id); n++) id = `user_${layout.id}_${n}`;
				layout.id = id;
				layouts.push(layout);
				byId.set(id, layout);
				if (HOST.store) await HOST.store.save(layout);
				else imported.push(layout);
				own.add(id);
				state.selected.add(id);
				history.label({ key: 'edit_history.step.import', values: { name: layout.name } });
				const format = formatName(result.format);
				report.textContent =
					result.unmapped.length === 0
						? t('layout_analysis.layouts.imported', { name: layout.name, format })
						: t('layout_analysis.layouts.import_partial', {
								name: layout.name,
								format,
								count: result.unmapped.length,
								list: lossList(result.unmapped)
							});
				save();
				fillLayouts();
				analyse();
			} catch (error) {
				refuseImport(error);
			}
		}

		/**
		 * The « Add a layout » card: a file chosen or dropped on the layouts
		 * card, or a text pasted (or dropped) and read by its content.
		 */
		function wireAdd() {
			// The file types every layout reader opens (layout_formats.js).
			$('la-import').accept = window.LAYOUT_FORMATS.EXTENSIONS.map((ext) => `.${ext}`).join(',');
			$('la-import').addEventListener('change', (event) => {
				const file = event.target.files && event.target.files[0];
				if (file) importLayout(file);
				event.target.value = '';
			});
			$('la-paste').addEventListener('input', showDetected);
			$('la-paste-add').addEventListener('click', async () => {
				if (await importPasted($('la-paste').value)) {
					$('la-paste').value = '';
					showDetected();
				}
			});
			showDetected();
			const card = root.querySelector('.la-layouts');
			const carries = (event) =>
				event.dataTransfer &&
				Array.from(event.dataTransfer.types || []).some((type) =>
					['Files', 'text/plain', 'text/uri-list'].includes(type)
				);
			card.addEventListener('dragover', (event) => {
				if (!carries(event)) return;
				event.preventDefault();
				event.dataTransfer.dropEffect = 'copy';
				// The list opens, so the drop lands where its result shows.
				$('la-layouts-box').open = true;
				$('la-drop').classList.add('la-drop-active');
			});
			card.addEventListener('dragleave', (event) => {
				if (!card.contains(event.relatedTarget)) $('la-drop').classList.remove('la-drop-active');
			});
			card.addEventListener('drop', async (event) => {
				if (!carries(event)) return;
				event.preventDefault();
				$('la-drop').classList.remove('la-drop-active');
				const files = Array.from(event.dataTransfer.files || []);
				if (files.length > 0) {
					for (const file of files) await importLayout(file);
					return;
				}
				const text =
					event.dataTransfer.getData('text/plain') || event.dataTransfer.getData('text/uri-list');
				if (text) importPasted(text);
			});
		}

		function visibleLayoutIds() {
			return layouts.filter(pickShows).map((l) => l.id);
		}

		function bind() {
			$('la-corpus').addEventListener('change', (event) => {
				state.corpus = event.target.value;
				showCorpusInfo();
				showTextMode();
				fillLayouts();
				save();
				analyse();
			});
			$('la-text-mode').addEventListener('change', (event) => {
				state.textMode = event.target.value;
				fillLayouts();
				save();
				analyse();
			});
			// Every keyboard of the model: the row-staggered boards, then the split,
			// ortholinear and column-staggered ones.
			$('la-keyboard').replaceChildren(
				...Object.keys(DATA.model.keyboards).map((id) => {
					const option = el('option', '', t(`layout_analysis.keyboard.${id}`));
					option.value = id;
					return option;
				})
			);
			$('la-keyboard').value = state.keyboard;
			$('la-keyboard').addEventListener('change', (event) => {
				state.keyboard = event.target.value;
				if (!state.selectionChosen) {
					state.selected = defaultSelection(state.keyboard);
					fillLayouts();
				}
				fingeringView.draw();
				save();
				analyse();
			});
			$('la-format').replaceChildren(
				...E.keyboardFormats().map((entry) => {
					const option = el('option', '', t(`layout_analysis.format.${entry.id}`));
					option.value = entry.id;
					return option;
				})
			);
			$('la-format').value = state.format;
			$('la-format').addEventListener('change', (event) => setFormat(event.target.value));
			let timer = null;
			$('la-text').addEventListener('input', (event) => {
				clearTimeout(timer);
				timer = setTimeout(
					() => useText(event.target.value),
					window.LAYOUT_ANALYSIS_FILES.TEXT_DEBOUNCE_MS
				);
			});
			$('la-file').accept = window.LAYOUT_ANALYSIS_FILES.FILE_EXTENSIONS.map(
				(extension) => '.' + extension
			).join(',');
			$('la-file').addEventListener('change', async (event) => {
				const file = event.target.files && event.target.files[0];
				const error = $('la-file-error');
				error.hidden = true;
				// The browser's own « no file chosen » text is hidden with its input.
				$('la-file-name').textContent = file ? file.name : '';
				if (!file) return;
				try {
					const text = await window.LAYOUT_ANALYSIS_FILES.readText(file);
					$('la-text').value = text;
					// The button sits under any corpus: its file becomes the chosen one.
					if (state.corpus !== CUSTOM_ID) {
						state.corpus = CUSTOM_ID;
						$('la-corpus').value = CUSTOM_ID;
						showCorpusInfo();
						showTextMode();
						fillLayouts();
					}
					useText(text);
				} catch (failure) {
					// Each refusal in words: an unknown type, a PDF that is locked or holds no
					// text (a scan), or a file that could not be read.
					const known = {
						file_unsupported: 'layout_analysis.corpus.file_unsupported',
						pdf_encrypted: 'layout_analysis.corpus.pdf_encrypted',
						pdf_no_text: 'layout_analysis.corpus.pdf_no_text'
					};
					error.textContent = t(known[failure.code] || 'layout_analysis.corpus.file_unreadable');
					error.hidden = false;
				}
			});
			$('la-filter').addEventListener('input', fillLayouts);
			wireAdd();
			$('la-heat-metric').addEventListener('change', (event) => {
				state.heat = event.target.value;
				save();
				renderDetails();
			});
			$('la-heat-diff').addEventListener('change', (event) => {
				state.heatDiff = event.target.checked;
				save();
				renderDetails();
			});
			$('la-heat-level').addEventListener('change', (event) => {
				state.heatLevel = event.target.value;
				save();
				renderDetails();
			});
			$('la-worst-event').addEventListener('change', renderDetails);
			$('la-blend-use').addEventListener('click', () => {
				useBlend().catch((error) => {
					$('la-blend-status').textContent = t('layout_analysis.blend.failed');
					throw error;
				});
			});
			// The Pareto tab's choices, kept with the other conveniences.
			$('la-pareto-x').addEventListener('change', (event) => {
				state.pareto.x = event.target.value;
				if (state.pareto.y === state.pareto.x)
					state.pareto.y = paretoChoices().find((id) => id !== state.pareto.x);
				save();
				renderPareto();
			});
			$('la-pareto-y').addEventListener('change', (event) => {
				state.pareto.y = event.target.value;
				save();
				renderPareto();
			});
			$('la-pareto-front').addEventListener('change', (event) => {
				state.pareto.frontOnly = event.target.checked;
				save();
				renderPareto();
			});
			// The trace follows its text as it is typed, and its two layouts.
			$('la-trace-text').addEventListener('input', (event) => {
				state.trace.text = event.target.value;
				save();
				renderTrace();
			});
			// The frame chooses the detailed layout and its comparison for every tab.
			$('la-frame-main').addEventListener('change', (event) => {
				if (!event.target.value) return;
				state.details = event.target.value;
				if (state.versus === state.details) state.versus = null;
				render();
			});
			$('la-frame-comp').addEventListener('change', (event) => {
				state.versus = event.target.value || null;
				render();
			});
			$('la-matrix-by').addEventListener('change', (event) => {
				state.matrixBy = event.target.value;
				save();
				renderDetails();
			});
			// The table's row filters: an empty or unreadable bound filters nothing.
			const bound = (input) => {
				const value = Number(input.value);
				return input.value === '' || !Number.isFinite(value) ? null : value;
			};
			// The filters choose the layouts every sub-tab draws.
			const filtered = () => {
				state.table.name = $('la-row-name').value;
				state.table.family = $('la-row-family').value;
				state.table.origin = $('la-row-origin').value;
				state.table.language = $('la-row-language').value;
				state.table.complete = $('la-row-complete').value;
				state.table.min = bound($('la-row-min'));
				state.table.max = bound($('la-row-max'));
				state.table.query = $('la-row-query').value;
				$('la-row-query-status').textContent = queryStatus();
				save();
				render();
			};
			for (const id of ['la-row-name', 'la-row-min', 'la-row-max', 'la-row-query'])
				$(id).addEventListener('input', filtered);
			for (const id of ['la-row-family', 'la-row-origin', 'la-row-language', 'la-row-complete'])
				$(id).addEventListener('change', filtered);
			$('la-table-csv').addEventListener('click', downloadRanking);
			$('la-table-fold').addEventListener('change', (event) => {
				state.table.fold = event.target.checked;
				save();
				renderTable();
			});
			$('la-table-relative').addEventListener('change', (event) => {
				state.table.relative = event.target.checked;
				save();
				renderTable();
			});
			$('la-table-reset').addEventListener('click', () => {
				// The filters go back; the folding and the pinned rows are a view, kept.
				state.table = Object.assign(validTable(null), {
					fold: state.table.fold,
					pins: state.table.pins
				});
				fillTableOptions();
				save();
				render();
			});
			// The layout list's filters, which « Select all shown » follows.
			for (const [id, name] of [
				['la-pick-origin', 'origin'],
				['la-pick-language', 'language']
			])
				$(id).addEventListener('change', (event) => {
					state.pick[name] = event.target.value;
					save();
					fillLayouts();
				});
			$('la-heats-metric').addEventListener('change', (event) => {
				state.heats.metric = event.target.value;
				save();
				renderHeatGrid();
			});
			$('la-heats-count').addEventListener('change', (event) => {
				state.heats.count = Number(event.target.value);
				save();
				renderHeatGrid();
			});
			$('la-heats-shared').addEventListener('change', (event) => {
				state.heats.shared = event.target.checked;
				save();
				renderHeatGrid();
			});
			$('la-heats-level').addEventListener('change', (event) => {
				state.heats.level = event.target.value;
				save();
				renderHeatGrid();
			});
			$('la-details-layout').addEventListener('change', (event) => {
				if (event.target.value) showDetails(event.target.value);
			});
			$('la-versus').addEventListener('change', (event) => {
				state.versus = event.target.value || null;
				renderDetails();
			});
			$('la-share').addEventListener('click', share);
			$('la-user-metrics-add').addEventListener('click', () => {
				if (state.userMetrics.length >= E.WINDOW_MAX_METRICS) return;
				const taken = new Set(state.userMetrics.map((m) => m.id));
				let n = state.userMetrics.length + 1;
				while (taken.has(`m${n}`)) n++;
				state.userMetrics.push({ id: `m${n}`, name: '', window: E.WINDOW_KINDS[0], query: '' });
				userMetricsChanged(true);
				const names = root.querySelectorAll('#la-user-metrics-list .la-user-metric-query');
				if (names.length > 0) names[names.length - 1].focus();
			});
			$('la-user-metrics-all').addEventListener('click', () =>
				measureUserMetrics().catch((error) => {
					$('la-user-metrics-status').textContent = t('layout_analysis.movement.rank_failed', {
						reason: error && error.message ? error.message : String(error)
					});
					throw error;
				})
			);
			// A failed measure is said in words, then raised to the page's error report.
			$('la-movement-rank').addEventListener('click', () =>
				placeMovementAmongLibrary().catch((error) => {
					$('la-movement-rank-status').textContent = t('layout_analysis.movement.rank_failed', {
						reason: error && error.message ? error.message : String(error)
					});
					throw error;
				})
			);
			// Every layout or none, whatever the search shows.
			for (const [id, tick] of [
				['la-every', true],
				['la-clear', false]
			])
				$(id).addEventListener('click', () => {
					state.selected = tick ? new Set(layouts.map((l) => l.id)) : new Set();
					chooseSelection();
					save();
					fillLayouts();
					analyse();
				});
			$('la-all').addEventListener('click', () => {
				for (const id of visibleLayoutIds()) state.selected.add(id);
				chooseSelection();
				save();
				fillLayouts();
				analyse();
			});
			$('la-none').addEventListener('click', () => {
				for (const id of visibleLayoutIds()) state.selected.delete(id);
				chooseSelection();
				save();
				fillLayouts();
				analyse();
			});
			// Each restore acts at once and offers to put the user's values back
			// (undo_offer.js); a section already at its defaults has nothing to undo.
			const restorer = (buttonId, nameKey, part, defaults, refill) => {
				const button = $(buttonId);
				const undo = UNDO.create(button.closest('section'));
				button.after(undo.node);
				button.addEventListener('click', () => {
					const before = JSON.stringify(state[part]);
					history.label({ key: 'edit_history.step.restore', values: { name: t(nameKey) } });
					state[part] = defaults();
					refill();
					if (before === JSON.stringify(state[part])) {
						undo.clear();
						return;
					}
					undo.offer({
						name: t(nameKey),
						focus: button,
						undo: () => {
							state[part] = JSON.parse(before);
							refill();
						}
					});
				});
			};
			restorer(
				'la-shortcuts-restore',
				'layout_analysis.shortcuts.title',
				'shortcuts',
				E.defaultShortcuts,
				() => {
					fillShortcuts();
					$('la-shortcuts-status').textContent = '';
					save();
					analyse();
				}
			);
			restorer(
				'la-forms-restore',
				'layout_analysis.forms.title',
				'formWeights',
				E.defaultFormFactorWeights,
				() => {
					fillForms();
					$('la-forms-status').textContent = '';
					save();
					analyse();
				}
			);
			restorer(
				'la-ideal-restore',
				'layout_analysis.ideal.title',
				'idealLoad',
				E.defaultIdealLoad,
				() => {
					fillIdealLoad();
					save();
					analyse();
				}
			);
			wireScoreConfig();
			restorer('la-restore', 'layout_analysis.weights.title', 'weights', E.defaultWeights, () => {
				fillWeights();
				// The access weights may change with the others: the layouts are typed again.
				save();
				analyse();
			});
			// Dynamic labels follow the strings, whenever they land.
			document.addEventListener('i18n:applied', () => {
				applyStrings();
				fillCorpora();
				fillLayouts();
				fillWeights();
				fillIdealLoad();
				fillShortcuts();
				fillForms();
				fillTableOptions();
				fillHeatChoices();
				fillTabs();
				render();
				analyse();
			});
		}

		/**
		 * Tells the framing page (the site's /studio/comparer) how tall the page
		 * is, so the frame fits without an inner scroll bar; a page opened on its
		 * own has no parent to tell.
		 */
		function reportHeight() {
			if (window.parent === window) return;
			const post = () =>
				window.parent.postMessage(
					{ type: HEIGHT_MESSAGE, height: document.documentElement.scrollHeight },
					'*'
				);
			post();
			if (typeof ResizeObserver === 'function') new ResizeObserver(post).observe(document.body);
		}

		// ==========================
		// ======= 7/ Host API ======
		// ==========================

		/**
		 * Adds or replaces a corpus after load (the app's keystats tables arrive
		 * when the Studio opens: the last saved read at once, then a fresh one).
		 * A new corpus is listed first and selected when it is the default; a
		 * replaced one keeps the user's current choice, and is analysed again only
		 * while it is the chosen corpus.
		 * @param {{id: string, title?: string, tables: object, default?: boolean}} corpus
		 * @throws {Error} On tables the engine cannot read.
		 */
		function setCorpus(corpus) {
			E.prepareNgrams(corpus.tables);
			// The final text of « My typing » (schema 2) is read the same way.
			if (corpus.tables.final !== undefined) E.prepareNgrams(corpus.tables.final);
			const entry = { id: corpus.id, title: corpus.title || '', host: { tables: corpus.tables } };
			const at = corpora.findIndex((c) => c.id === corpus.id);
			if (at >= 0) {
				corpora.splice(at, 1, entry);
				fillCorpora();
				// A refresh may bring or drop the final text: the « + » boxes follow it.
				fillLayouts();
				if (state.corpus === corpus.id) analyse();
				return;
			}
			corpora.unshift(entry);
			if (corpus.default) state.corpus = corpus.id;
			fillCorpora();
			fillLayouts();
			save();
			analyse();
		}

		/** Adds the host's layouts (e.g. the user's own from « Éditer ») to the list, ticked. */
		/**
		 * Chooses the keyboard format (the Studio passes the editor's « Format »).
		 * @param {string} id A keyboard_formats id.
		 * @throws {Error} On an unknown format.
		 */
		function setFormat(id) {
			E.formatHiddenKeys(id);
			if (state.format === id) return;
			state.format = id;
			$('la-format').value = id;
			window.LAYOUT_ANALYSIS_FILES.saveFormat(id);
			if (historyStarted) history.record();
			analyse();
		}

		// The layouts open in « Éditer » (ids editor_…), listed as personal layouts
		// and replaced whenever the editor's tabs change.
		const editorIds = new Set();
		function useEditorLayouts(list) {
			const next = new Map();
			for (const value of Array.isArray(list) ? list : []) {
				try {
					const layout = E.layoutFromRows(Object.assign({}, value, { origin: 'user' }));
					if (layout.id.startsWith('editor_')) next.set(layout.id, layout);
				} catch (error) {
					console.warn(`layout comparer: an editor layout is refused (${error.message})`);
				}
			}
			for (const id of editorIds)
				if (!next.has(id)) {
					layouts.splice(layouts.indexOf(byId.get(id)), 1);
					byId.delete(id);
					state.selected.delete(id);
					editorIds.delete(id);
				}
			for (const [id, layout] of next) {
				if (byId.has(id)) layouts.splice(layouts.indexOf(byId.get(id)), 1, layout);
				else {
					layouts.push(layout);
					state.selected.add(id);
				}
				byId.set(id, layout);
				editorIds.add(id);
			}
			fillLayouts();
			if (state.tables) analyse();
		}

		function addLayouts(list) {
			for (const value of list) {
				const layout = E.layoutFromRows(Object.assign({ origin: 'user' }, value));
				if (!byId.has(layout.id)) layouts.push(layout);
				else layouts.splice(layouts.indexOf(byId.get(layout.id)), 1, layout);
				byId.set(layout.id, layout);
				state.selected.add(layout.id);
			}
			// A new origin or language joins the filters.
			fillTableOptions();
			fillLayouts();
			analyse();
		}

		/**
		 * Adds the layouts the visitor asked to compare (the editor's « Compare
		 * with other layouts », a link's own layouts) and shows the ranking they
		 * join: « Home » holds controls only, so a visitor left there would not
		 * see the comparison asked for. Another results tab stays shown, and the
		 * visitor's own tab choice (tabSaved) is kept.
		 * @param {object[]} list - Layouts in the library shape.
		 */
		function compare(list) {
			addLayouts(list);
			if (state.tab === HOME_TAB) chooseTab(DEFAULT_TAB, false);
		}

		/**
		 * Calls a listener after each comparison with (results, tables, {keyboard,
		 * layouts: Map id → the compared layout object, tablesOf: result → the
		 * prepared tables it was analysed on (a « + » layout types the keys typed)}),
		 * and at once with the current ones: the hook of extra views.
		 * @param {function(object[], object, object): void} listener
		 */
		function onResults(listener) {
			if (typeof listener !== 'function')
				throw new Error('layout_analysis: onResults needs a function');
			resultListeners.push(listener);
			if (state.tables)
				listener(state.results, state.tables, {
					keyboard: state.keyboard,
					layouts: state.compared || new Map(),
					tablesOf
				});
		}

		/** Fills the markup's data-i18n, -placeholder, -title and option-prefix strings. */
		/**
		 * Writes an element's own text and keeps the elements it holds: a label
		 * keeps its field, a button or a legend entry its icon. The text comes
		 * after a decorative icon or a checkbox and before any other field, so a
		 * label's words are the label itself rather than a span inside it.
		 * @param {Element} node
		 * @param {string} text
		 */
		function setText(node, text) {
			const kept = Array.from(node.children);
			const before = kept.filter(
				(child) =>
					child.matches('svg, [aria-hidden="true"]') ||
					(child.tagName === 'INPUT' && child.type === 'checkbox')
			);
			const after = kept.filter((child) => !before.includes(child));
			node.replaceChildren(...before, text, ...after);
		}

		function applyStrings() {
			for (const node of root.querySelectorAll('[data-i18n]'))
				node.textContent = t(node.dataset.i18n);
			// An element that holds a field or an icon beside its words: i18n.js
			// replaces a data-i18n element's whole content, so these name their
			// key apart and only the page writes them.
			for (const node of root.querySelectorAll('[data-i18n-text]'))
				setText(node, t(node.dataset.i18nText));
			for (const node of root.querySelectorAll('[data-i18n-placeholder]'))
				node.placeholder = t(node.dataset.i18nPlaceholder);
			for (const node of root.querySelectorAll('[data-i18n-title]'))
				node.title = t(node.dataset.i18nTitle);
			for (const select of root.querySelectorAll('select[data-i18n-option-prefix]'))
				for (const option of select.options)
					option.textContent = t(`${select.dataset.i18nOptionPrefix}.${option.value}`);
		}

		document.addEventListener(NGRAMS_EVENT, (event) =>
			setCorpus({ id: MY_TYPING_ID, tables: event.detail, default: true })
		);
		// « My typing » listed at once, greyed while the app reads it or when it cannot.
		document.addEventListener(NGRAMS_STATE_EVENT, (event) => {
			myTypingState = readingState(event.detail);
			fillCorpora();
		});

		// The fingering editor, drawn on the chosen keyboard.
		let fingeringView = null;

		function start() {
			applyStrings();
			fillCorpora();
			showTextMode();
			fillLayouts();
			fillWeights();
			fillIdealLoad();
			fillShortcuts();
			fillForms();
			fillTableOptions();
			fillHeatChoices();
			fillTabs();
			// The filters stay open where the width holds them in a row, and
			// wherever one is set, so a narrowed list never hides its reason.
			const { name, family, origin, language, complete, min, max } = state.table;
			$('la-filters-box').open =
				window.matchMedia(`(min-width: ${FILTERS_OPEN_MIN_PX}px)`).matches ||
				Boolean(name || family || origin || language) ||
				complete !== COMPLETE_CHOICES[0] ||
				min !== null ||
				max !== null ||
				state.table.query.trim() !== '';
			fingeringView = FINGERING.mount($('la-fingering'), { keyboard: () => state.keyboard });
			window.LAYOUT_ANALYSIS_FILES.onEditorLayouts(useEditorLayouts);
			FINGERING.onChange(() => analyse());
			// A fingering change is a step: analyse() saves nothing by itself.
			FINGERING.onEdit(() => {
				if (historyStarted) history.record();
			});
			bind();
			historyControls = window.ERGOPTI_EDIT_HISTORY.controls(history, t, 'la');
			$('la-share').before(historyControls.node);
			window.ERGOPTI_EDIT_HISTORY.bindKeys(document, historyControls.run, () => {
				const focused = document.activeElement;
				const inside =
					!focused || focused === document.body || focused === document.documentElement;
				return (inside || root.contains(focused)) && root.getClientRects().length > 0;
			});
			document.addEventListener('i18n:applied', historyControls.refresh);
			history.start();
			historyStarted = true;
			analyse();
			// The blend compared last time, or the one a link names, is mixed again.
			if (state.restoreBlend)
				restoreBlend(state.blendRecipe).catch((error) => {
					$('la-blend-status').textContent = t('layout_analysis.blend.failed');
					throw error;
				});
			// The blend compared last time named an own text that is no longer listed.
			else if (saved.corpus === BLEND_ID && !linked.blend && !linked.corpus)
				$('la-blend-status').textContent = t('layout_analysis.blend.lost');
			if (opts.reportHeight) reportHeight();
			// The host's personal layouts (app data folder, site IndexedDB).
			if (HOST.store)
				HOST.store.list().then(
					(list) => {
						for (const layout of list) own.add(layout.id);
						addLayouts(list);
					},
					() => showStatus(t('layout_analysis.status.store_failed'))
				);
		}

		start();
		if (lastNgrams) setCorpus({ id: MY_TYPING_ID, tables: lastNgrams, default: true });
		// The « Autres analyseurs » view (analyser_tab.js): both pages load it.
		window.LAYOUT_ANALYSER_TAB.attach(root.querySelector('#la-analysers'), {
			comparer: { onResults }
		});
		mounted = { setCorpus, addLayouts, compare, setFormat, onResults };
		return mounted;
	}

	/** The mounted Comparer; the late-data calls need one. */
	function instance() {
		if (!mounted) throw new Error('layout_analysis: the Comparer is not mounted');
		return mounted;
	}

	window.LAYOUT_ANALYSIS_COMPARER = {
		mount,
		setCorpus: (corpus) => instance().setCorpus(corpus),
		addLayouts: (list) => instance().addLayouts(list),
		compare: (list) => instance().compare(list),
		setFormat: (id) => instance().setFormat(id),
		onResults: (listener) => instance().onResults(listener),
		// The metrics each themed tab charts, read by the Studio browser test.
		tabMetrics: () => JSON.parse(JSON.stringify(TAB_METRICS))
	};
	// Keystats tables that arrive before the mount wait for it, and so does their state.
	document.addEventListener(NGRAMS_EVENT, (event) => {
		if (!mounted) lastNgrams = event.detail;
	});
	document.addEventListener(NGRAMS_STATE_EVENT, (event) => {
		if (!mounted) myTypingState = readingState(event.detail);
	});

	/** The site's page: mount into its <main>, and size the framing page. */
	function autostart() {
		const root = document.getElementById(STANDALONE_ROOT_ID);
		if (!root) return;
		mount(root, { reportHeight: true });
		// The layout the site's editor handed over with « Compare with other layouts ».
		const handed = window.LAYOUT_ANALYSIS_FILES.takeHandoff();
		if (handed) instance().compare([handed]);
		openLinkLayouts();
	}

	/**
	 * The visitor's own layouts a shared link carries in its fragment (the
	 * framing page's, on the site), compared as personal layouts named « from
	 * a link »; a fragment that does not read is refused in words, whole.
	 */
	function openLinkLayouts() {
		let hash = location.hash;
		try {
			if (window.top !== window && window.top.location.origin === location.origin)
				hash = window.top.location.hash;
		} catch {
			// A frame from another origin: this page's own address.
		}
		const t = INFO.t;
		// The mark becomes part of the layouts' names: wait for the page's strings.
		const ready = () =>
			typeof (window._i18n_strings || {})['layout_analysis.share.from_link'] === 'string';
		const strings = ready()
			? Promise.resolve()
			: new Promise((resolve) => {
					document.addEventListener('i18n:applied', function wait() {
						if (!ready()) return;
						document.removeEventListener('i18n:applied', wait);
						resolve();
					});
				});
		strings
			.then(() => window.LAYOUT_FORMATS.fromLink(hash, E))
			.then(
				(list) => {
					if (list.length === 0) return;
					const mark = t('layout_analysis.share.from_link');
					instance().compare(
						list.map((l) => Object.assign({}, l, { name: `${l.name} (${mark})` }))
					);
				},
				(error) => {
					const refusal = window.LAYOUT_FORMATS.refusalMessage(error);
					const status = document.getElementById('la-share-status');
					status.hidden = false;
					status.textContent = t('layout_analysis.share.link_refused', {
						reason: t(refusal.key, refusal.values)
					});
				}
			);
	}

	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', autostart);
	else autostart();
})();
