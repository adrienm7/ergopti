// tools/test/test-layout-comparer-page.cjs

/**
 * ==============================================================================
 * MODULE: Layout Comparer Page Gate
 * DESCRIPTION:
 * _shared/ui/layout_analysis/index.html is the « Comparer » tab of Ergopti
 * Studio on the site and in the app. This gate holds its wiring.
 *
 * WHAT IS CHECKED:
 * 1. Scripts: the generated data, then the engine, then the file reader, then
 *    the page script, each present on disk.
 * 2. Strings: every layout_analysis.* key the page uses (data-i18n attributes,
 *    option prefixes and t() calls, metric and finger keys built from the
 *    engine's own lists) exists in all 21 locales.
 * 3. Sources: every metric and sourced value has an « i » explanation in all
 *    21 locales, the page draws an « i » button for each, and the placeholders
 *    of each explanation match English.
 * 4. Corpora: every built-in corpus of the generated data has its tables file.
 *    Layouts: every layout has a display name, not its id (« Colemak-DH », not
 *    « colemak_dh »), and no two layouts share one.
 * 5. Globals: no page script reads `window.X` for an X a loaded script
 *    declares with a top-level const or let, which is a page global but not
 *    a window property (the .keylayout import once read window.LAYOUT_COMPOSER_DATA
 *    and got undefined).
 * 6. Editor panel: the site's editor page and the app's editor window load
 *    the panel's scripts in the same order, before editor_page.js; the app
 *    window loads built-in corpora through its host, not as static tags; an
 *    inlined corpus loader (no script URL) still loads.
 * 7. Incomplete layouts: the chart and the table flag a layout that cannot
 *    type the space or a letter in either case, in the engine's ranking
 *    order, and the editor panel ranks the edited layout by E.rankOrder.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');

const PAGE_DIR = shared('ui', 'layout_analysis');
const LOCALES_DIR = shared('core', 'i18n', 'data', 'locales');
const PREFIX = 'layout_analysis.';
const SCRIPTS = [
	// The website's accessibility settings, before the page paints.
	'../a11y_prefs.js',
	// The theme the site's visitor chose (theme_choice.js), before the first paint.
	'../theme_choice.js',
	'../i18n.js',
	'../host_bridge.js',
	// The shared key legend formatter (dead keys as their bare accent).
	'../_generated/key_legend.js',
	'_generated/analysis_data.js',
	'analysis_engine.js',
	'analyser_scores.js',
	'analyser_tab.js',
	'info_popover.js',
	// The « Undo » line of the restore buttons and the fingering reset.
	'undo_offer.js',
	'fingering_editor.js',
	'../layout_composer/_generated/composer_data.js',
	'../layout_composer/composer_model.js',
	'../layout_editor/toml_prelude.js',
	'../vendor/smol-toml.js',
	'layout_formats.js',
	// The PDF text reader corpus_files.js calls.
	'pdf_text.js',
	'corpus_files.js',
	// The score settings every Studio score reads (the Comparer's own, shared).
	'score_settings.js',
	// The overview's worst n-grams, shared with the editor panel.
	'worst_groups.js',
	// The heatmaps' PNG and SVG downloads, shared with the editor's board.
	'board_image.js',
	'comparer_page.js'
];
// Floor: a page that lost its strings must not read as complete.
const MIN_KEYS = 60;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};

// 1/ Scripts
const html = fs.readFileSync(path.join(PAGE_DIR, 'index.html'), 'utf8');
const scripts = Array.from(html.matchAll(/<script src="([^"]+)"/g), (m) => m[1]);
check(JSON.stringify(scripts) === JSON.stringify(SCRIPTS), `scripts: ${scripts.join(', ')}`);
for (const src of scripts) check(fs.existsSync(path.join(PAGE_DIR, src)), `missing ${src}`);

// 2/ Strings
const sandbox = {};
vm.createContext(sandbox);
for (const file of ['_generated/analysis_data.js', 'analysis_engine.js'])
	vm.runInContext(fs.readFileSync(path.join(PAGE_DIR, file), 'utf8'), sandbox);
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const DATA = vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox);
const page = fs.readFileSync(path.join(PAGE_DIR, 'comparer_page.js'), 'utf8');
// The Comparer's markup lives in comparer_page.js (it mounts into the site's
// page and into the app's Studio window); index.html holds only its root.
const markup = html + page;
const keys = new Set();
for (const m of markup.matchAll(/data-i18n(?:-placeholder|-title)?="([^"]+)"/g)) keys.add(m[1]);
for (const m of markup.matchAll(/data-i18n-option-prefix="([^"]+)"[^>]*>([\s\S]*?)<\/select>/g))
	for (const option of m[2].matchAll(/value="([^"]+)"/g)) keys.add(`${m[1]}.${option[1]}`);
// The page, its popovers and the editor's analysis panel share these strings.
for (const file of [
	'comparer_page.js',
	'info_popover.js',
	'analysis_panel.js',
	'fingering_editor.js',
	'undo_offer.js',
	'analyser_tab.js',
	'worst_groups.js',
	'best_swaps.js',
	'board_image.js',
	// The corpus picker the Comparer, the panel and the Optimiser share.
	'corpus_files.js'
])
	for (const m of fs.readFileSync(path.join(PAGE_DIR, file), 'utf8').matchAll(/\bt\('([a-z_.]+)'/g))
		keys.add(m[1]);
for (const id of Object.keys(E.METRICS)) keys.add(`${PREFIX}metric.${id}`);
// The picker names each built-in text's kind (corpus_files.js fillCorpusPicker).
for (const corpus of DATA.corpora) keys.add(`${PREFIX}corpus.kind.${corpus.kind}`);
for (const id of DATA.model.fingers) keys.add(`${PREFIX}finger.${id}`);
for (const id of Object.keys(DATA.model.keyboards)) keys.add(`${PREFIX}keyboard.${id}`);
for (const format of E.keyboardFormats()) keys.add(`${PREFIX}format.${format.id}`);
// Each text mode explains itself (comparer_page.js showTextMode); the modes are
// corpus_files.js TEXT_MODES, shared with the editor panel.
const textModes = Array.from(
	fs
		.readFileSync(path.join(PAGE_DIR, 'corpus_files.js'), 'utf8')
		.match(/const TEXT_MODES = Object\.freeze\(\{([^}]*)\}\)/)[1]
		.matchAll(/'([a-z]+)'/g),
	(m) => m[1]
);
check(
	JSON.stringify(textModes) === JSON.stringify(['typed', 'final', 'mixed']),
	`text modes: ${textModes.join(' ')}`
);
for (const mode of textModes) keys.add(`${PREFIX}text_mode.info_${mode}`);
// The fingering editor's base choices and the errors it reports.
for (const id of Object.keys(DATA.model.fingerings)) keys.add(`${PREFIX}fingering.base_${id}`);
for (const m of fs
	.readFileSync(path.join(PAGE_DIR, 'fingering_editor.js'), 'utf8')
	.matchAll(/notifyError\('([a-z_.]+)'/g))
	keys.add(m[1]);
// Every engine refusal the pages show in words (info_popover.js refusal).
const engineCodes = new Set(
	Array.from(
		fs
			.readFileSync(path.join(PAGE_DIR, 'analysis_engine.js'), 'utf8')
			.matchAll(/new AnalysisError\(\s*'([a-z_]+)'/g),
		(m) => m[1]
	)
);
check(
	engineCodes.has('ideal_load_order') && engineCodes.has('fingering_unknown_key'),
	'engine codes'
);
for (const code of [...engineCodes, 'not_json']) keys.add(`${PREFIX}error.${code}`);
for (const id of Object.keys(DATA.sources.items)) keys.add(`${PREFIX}info.${id}`);
// The other analysers' view shows each score-less analyser's headline parts.
for (const entry of Object.values(DATA.analysers))
	for (const part of entry.headline || []) keys.add(`${PREFIX}analysers.part.${part}`);
// A corpus with a localized name (the count tables) is named in every locale.
for (const corpus of DATA.corpora) if (corpus.title_key) keys.add(corpus.title_key);
check(
	page.includes('LAYOUT_ANALYSIS_FILES.fillCorpusPicker(') &&
		fs.readFileSync(path.join(PAGE_DIR, 'corpus_files.js'), 'utf8').includes('corpus.title_key'),
	'the corpus picker no longer shows the localized corpus names'
);
check(keys.size >= MIN_KEYS, `only ${keys.size} keys found`);
const locales = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
check(locales.length === 21, `${locales.length} locales`);
for (const file of locales) {
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8'));
	for (const key of keys)
		check(typeof strings[key] === 'string' && strings[key] !== '', `${file}: ${key}`);
}

// A refusal reaches the reader in their language, its fingers by their labels,
// never as the engine's English message (the fingering editor, the ideal load).
{
	const french = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, 'fr.json'), 'utf8'));
	const reader = { window: { _i18n_strings: french } };
	reader.window.window = reader.window;
	vm.createContext(reader.window);
	for (const file of ['_generated/analysis_data.js', 'analysis_engine.js', 'info_popover.js'])
		vm.runInContext(fs.readFileSync(path.join(PAGE_DIR, file), 'utf8'), reader.window);
	const said = (run) => {
		try {
			run();
		} catch (error) {
			return vm.runInContext('LAYOUT_ANALYSIS_INFO', reader.window).refusal(error);
		}
		return null;
	};
	const engine = vm.runInContext('LAYOUT_ANALYSIS', reader.window);
	const load = Object.assign({}, engine.defaultIdealLoad(), { lp: 11.5, lr: 6.5 });
	check(
		said(() => engine.idealLoad(load)) ===
			'Annulaire gauche porte moins que Auriculaire gauche : chaque main garde index ≥ majeur ≥ annulaire ≥ auriculaire',
		`refusal: ${said(() => engine.idealLoad(load))}`
	);
	check(
		said(() => engine.keyboard('iso', { fingers: { NoKey: 'lp' } })) ===
			'NoKey n’est pas une touche des claviers',
		'refusal: an unknown key'
	);
	check(
		said(() => JSON.parse('{')) === 'le fichier n’est pas du JSON',
		'refusal: an import that is not JSON'
	);
	let rethrown = false;
	try {
		said(() => {
			throw new TypeError('a programming error');
		});
	} catch {
		rethrown = true;
	}
	check(rethrown, 'refusal: an error the engine did not raise stays an error');
}

// Numbers: the page's way, one formatter per language and decimals. A ranking
// of every layout writes tens of thousands of numbers, and toLocaleString with
// options builds a new Intl.NumberFormat each time (a tenth of a load).
{
	const reader = { window: { _i18n_strings: { '_meta.locale': 'fr' } } };
	reader.window.window = reader.window;
	vm.createContext(reader.window);
	vm.runInContext(fs.readFileSync(path.join(PAGE_DIR, 'info_popover.js'), 'utf8'), reader.window);
	const made = vm.runInContext(
		`(() => {
			const Native = Intl.NumberFormat;
			const made = { count: 0 };
			Intl.NumberFormat = function (...args) { made.count++; return new Native(...args); };
			Number.prototype.toLocaleString = () => { throw new Error('toLocaleString per number'); };
			return made;
		})()`,
		reader.window
	);
	const { format } = vm.runInContext('LAYOUT_ANALYSIS_INFO', reader.window);
	const expected = (lang, value, digits) =>
		new Intl.NumberFormat(lang, {
			minimumFractionDigits: digits,
			maximumFractionDigits: digits
		}).format(value);
	let same = true;
	for (let i = 0; i < 2000; i++) same = same && format(i / 7, 2) === expected('fr', i / 7, 2);
	check(
		same && format('1234.5', 0) === expected('fr', 1234.5, 0),
		'format: the page’s French numbers'
	);
	check(made.count === 2, `format: ${made.count} formatters for 2 decimal counts`);
	reader.window._i18n_strings = { '_meta.locale': 'en' };
	check(format(1234.5, 1) === '1,234.5', 'format: a later language of the strings is followed');
}

// The site sizes its frame from this message (contract with src/routes/studio).
check(
	page.includes("'ergopti-layout-analysis:height'") && page.includes('postMessage'),
	'the page no longer posts its height to the framing site'
);

// A shared comparison is the framing site page's address: the site hands on
// exactly the parameters the page reads (src/lib/js/comparerLink.js).
{
	const listOf = (text, name) => {
		const m = text.match(new RegExp(`${name}\\s*=\\s*(?:Object\\.freeze\\()?\\[([^\\]]*)\\]`));
		return m ? Array.from(m[1].matchAll(/'([a-z]+)'/g), (x) => x[1]) : null;
	};
	const site = fs.readFileSync(
		path.join(__dirname, '..', '..', 'src', 'lib', 'js', 'comparerLink.js'),
		'utf8'
	);
	const pageParams = listOf(page, 'LINK_PARAMS');
	check(pageParams && pageParams.length >= 6, 'the page lost its LINK_PARAMS list');
	check(
		JSON.stringify(listOf(site, 'COMPARER_LINK_PARAMS')) === JSON.stringify(pageParams),
		`link parameters: the site hands on ${listOf(site, 'COMPARER_LINK_PARAMS')}, the page reads ${pageParams}`
	);
	for (const route of ['studio/comparer/+page.svelte', 'ergopti/benchmarks/+page.svelte'])
		check(
			fs
				.readFileSync(
					path.join(__dirname, '..', '..', 'src', 'routes', ...route.split('/')),
					'utf8'
				)
				.includes('#lib/js/comparerLink.js'),
			`${route} does not hand the link parameters on to the Comparer`
		);
}

// The app delivers « My typing » late, through this event (contract with T's bridge).
check(
	page.includes("'studio-ngrams'") && page.includes('LAYOUT_ANALYSIS_COMPARER'),
	'the page no longer accepts a late corpus from the app'
);

// 3/ Sources: each metric gets its button from the details table, the
// values from the static page or the shortcut row.
for (const id of Object.keys(E.METRICS))
	check(DATA.sources.items[id], `sources: no references for metric ${id}`);
check(
	page.includes("th.append(' ', infoButton(id))"),
	'sources: the metrics table lost its « i » buttons'
);
for (const id of ['fingering', 'weights', 'ideal_finger_load'])
	check(markup.includes(`data-info="${id}"`), `sources: no « i » button for ${id}`);
// The letters' usefulness: its own « i » in the score settings, and in the
// left-hand shortcuts row's single popover (info_popover.js ALSO_EXPLAINS),
// never a second button on that row (browser case one-info-per-row).
check(
	markup.includes('data-info="shortcut_letters"'),
	'sources: no « i » button for shortcut_letters'
);
check(
	/ALSO_EXPLAINS = Object\.freeze\(\{ shortcut_left: Object\.freeze\(\['shortcut_letters'\]\) \}\)/.test(
		fs.readFileSync(path.join(PAGE_DIR, 'info_popover.js'), 'utf8')
	),
	'sources: the left-hand shortcuts popover no longer explains the letters'
);
check(
	!page.includes("infoButton('shortcut_letters')"),
	'sources: a metric row draws a second « i » for shortcut_letters'
);
const english = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, 'en.json'), 'utf8'));
const placeholders = (text) => (text.match(/\{\w+\}/g) || []).sort().join(',');
for (const file of locales) {
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8'));
	for (const key of keys)
		if (typeof strings[key] === 'string')
			check(
				placeholders(strings[key]) === placeholders(english[key]),
				`${file}: ${key} placeholders`
			);
}

// 4/ Corpora
check(DATA.corpora.length > 0, 'no built-in corpus');
// A word frequency list counts each word with a space on either side.
const { wordListCounts } = require('../codegen/codegen-layout-analysis-data-js.cjs');
const counted = wordListCounts('ab 3\nc 2\n', 'test');
check(
	JSON.stringify(counted) ===
		JSON.stringify({
			chars: { a: 3, b: 3, ' ': 5, c: 2 },
			bigrams: { ' a': 3, ab: 3, 'b ': 3, ' c': 2, 'c ': 2 },
			trigrams: { ' ab': 3, 'ab ': 3, ' c ': 2 }
		}),
	`word list counts: ${JSON.stringify(counted)}`
);
let refusedLine = false;
try {
	wordListCounts('ab three\n', 'test');
} catch {
	refusedLine = true;
}
check(refusedLine, 'word list counts: a line without a count must be refused');
// A scanned word inside a longer token is escaped where it starts, not only
// at the token's first character (the Rust corpus word "completepowershell"
// raised the exe bundle's powershell ceiling).
{
	const { corpusSource } = require('../codegen/codegen-layout-analysis-data-js.cjs');
	const words = { completepowershell: 3, uac: 2, plain: 1 };
	const source = corpusSource(
		'scan_probe',
		{ chars: { a: 1 }, bigrams: { ab: 1 }, trigrams: { abc: 1 }, words },
		{ licence: 'test', attribution: 'test' }
	);
	check(!/powershell/i.test(source), 'corpus source: a scanned word inside a token is escaped');
	check(!/\bUAC\b/i.test(source), 'corpus source: a scanned token is escaped');
	const sandbox = {};
	new Function('LAYOUT_ANALYSIS_CORPORA', source.replace(/^var LAYOUT_ANALYSIS_CORPORA.*$/m, ''))(
		sandbox
	);
	check(
		JSON.stringify(sandbox.scan_probe.words) === JSON.stringify(words),
		`corpus source: escaped keys read back unchanged: ${JSON.stringify(sandbox.scan_probe?.words)}`
	);
}
// Each shipped corpus shows the licence and attribution static/corpus/register.json records.
for (const corpus of DATA.corpora)
	check(
		corpus.licence && corpus.attribution && corpus.source,
		`corpus ${corpus.id}: no licence, attribution or source to show`
	);
check(
	/attribution/.test(page.match(/function showCorpusInfo[\s\S]*?\n\t}/)[0]),
	'the corpus line no longer shows the attribution'
);
for (const corpus of DATA.corpora)
	check(
		fs.existsSync(path.join(PAGE_DIR, corpus.script)),
		`corpus ${corpus.id}: no ${corpus.script}`
	);

// Display names (maintainer, 2026-11-15): the library's one data source names
// each layout as people write it; its id stays the key.
const shownNames = new Map();
for (const layout of DATA.layouts) {
	check(
		layout.name !== layout.id && !/_/.test(layout.name) && !/^[a-z]+(-[a-z]+)*$/.test(layout.name),
		`layout ${layout.id}: « ${layout.name} » is not a display name`
	);
	check(
		!shownNames.has(layout.name),
		`layouts ${shownNames.get(layout.name)} and ${layout.id} share « ${layout.name} »`
	);
	shownNames.set(layout.name, layout.id);
}

// Keyboard formats (maintainer, 2026-11-15): one table for the editor's
// « Format », the Comparer's and the compact form factors; each smaller format
// hides what the larger one hides, and more.
const formats = E.keyboardFormats();
check(
	JSON.stringify(formats.map((f) => f.id)) === JSON.stringify(['full', 'tkl', '75', '65', '60']),
	`keyboard formats: ${formats.map((f) => f.id).join(', ')}`
);
for (let i = 1; i < formats.length; i++)
	check(
		[...formats[i - 1].hidden].every((code) => formats[i].hidden.has(code)) &&
			formats[i].hidden.size > formats[i - 1].hidden.size,
		`keyboard format ${formats[i].id} does not hide more than ${formats[i - 1].id}`
	);
check(E.formatHiddenKeys('tkl').has('Numpad5'), 'TKL hides the numeric keypad');
check(
	E.formatHiddenKeys('60').has('ArrowUp') && E.formatHiddenKeys('60').has('F5'),
	'60 % hides the arrows and the F row'
);
check(!E.formatHiddenKeys('65').has('ArrowUp'), '65 % keeps the arrows');
let unknownFormat = false;
try {
	E.formatHiddenKeys('50');
} catch {
	unknownFormat = true;
}
check(unknownFormat, 'an unknown keyboard format must be refused');
check(page.includes('id="la-format"'), 'the Comparer has no « Format »');
// The format feeds compact_fit: the per-format form factors are measured on it.
const ergopti = DATA.layouts.find((l) => l.id === 'ergopti');
const tablesForFit = E.prepareNgrams(E.ngramsFromText('le clavier ergonomique 2026 !'));
for (const format of formats)
	check(
		Number.isFinite(E.analyse(ergopti, tablesForFit, { format: format.id }).metrics.compact_fit),
		`compact_fit on ${format.id}`
	);

// 5/ Globals
const lexical = new Set();
for (const src of SCRIPTS)
	for (const m of fs
		.readFileSync(path.join(PAGE_DIR, src), 'utf8')
		.matchAll(/^(?:const|let|class)\s+([A-Za-z_$][\w$]*)/gm))
		lexical.add(m[1]);
check(lexical.has('LAYOUT_COMPOSER_DATA'), 'globals: composer_data.js no longer seen');
for (const file of [
	'comparer_page.js',
	'analysis_panel.js',
	'info_popover.js',
	'corpus_files.js',
	'score_settings.js'
])
	for (const m of fs
		.readFileSync(path.join(PAGE_DIR, file), 'utf8')
		.matchAll(/window\.([A-Za-z_$][\w$]*)/g))
		check(!lexical.has(m[1]), `${file}: window.${m[1]} is undefined (a top-level const)`);

// 6/ Editor panel
const PANEL_SCRIPTS = [
	'../layout_analysis/_generated/analysis_data.js',
	'../layout_analysis/analysis_engine.js',
	// The panel shows every analyser's score beside Ergopti's.
	'../layout_analysis/analyser_scores.js',
	'../layout_analysis/info_popover.js',
	'../layout_analysis/undo_offer.js',
	'../layout_analysis/fingering_editor.js',
	'../layout_analysis/corpus_files.js',
	'../layout_analysis/score_settings.js',
	// The panel's worst n-grams (worst_groups.js), before the panel that draws them.
	'../layout_analysis/worst_groups.js',
	// The panel's best swaps (best_swaps.js; the optimiser core is loaded too).
	'../layout_analysis/best_swaps.js',
	'../layout_analysis/analysis_panel.js',
	'../layout_editor/editor_page.js'
];
for (const page of ['layout_editor', 'layout_editor_window']) {
	const listed = Array.from(
		fs.readFileSync(shared('ui', page, 'index.html'), 'utf8').matchAll(/<script src="([^"]+)"/g),
		// The editor page names its own folder's scripts without the prefix.
		(m) => (m[1].startsWith('../') ? m[1] : `../${page}/${m[1]}`)
	).filter((src) => PANEL_SCRIPTS.includes(src));
	check(
		JSON.stringify(listed) === JSON.stringify(PANEL_SCRIPTS),
		`${page}/index.html: panel scripts ${listed.join(', ')}`
	);
}

// The app windows load built-in corpora through their host (loadCorpus), not
// as static tags: the inlining hosts would carry every table at start.
const windowScripts = Array.from(
	fs
		.readFileSync(shared('ui', 'layout_editor_window', 'index.html'), 'utf8')
		.matchAll(/<script src="([^"]+)"/g),
	(m) => m[1]
);
check(
	!windowScripts.some((src) => /_generated\/corpus_/.test(src)),
	'layout_editor_window/index.html: corpus tables load through LAYOUT_ANALYSIS_HOST.loadCorpus'
);
check(
	fs.readFileSync(path.join(PAGE_DIR, 'corpus_files.js'), 'utf8').includes('host.loadCorpus'),
	'corpus_files.js no longer asks the host to load a corpus'
);

// The app's Studio window mounts the Comparer in a tab: it loads every script
// of the Comparer's page (but i18n.js: its host seeds the strings;
// theme_choice.js: no site frames it, it follows the system; and
// a11y_prefs.js: the website's settings do not reach the app), the
// Comparer's own last, and its stylesheet.
const windowPage = fs.readFileSync(shared('ui', 'layout_editor_window', 'index.html'), 'utf8');
const inWindow = (src) => (src.startsWith('../') ? src : `../layout_analysis/${src}`);
const comparerAt = windowScripts.indexOf('../layout_analysis/comparer_page.js');
const NOT_IN_WINDOW = ['../i18n.js', '../theme_choice.js', '../a11y_prefs.js'];
for (const src of SCRIPTS.filter((s) => !NOT_IN_WINDOW.includes(s))) {
	const at = windowScripts.indexOf(inWindow(src));
	check(at >= 0, `layout_editor_window/index.html: no ${inWindow(src)} for the Comparer tab`);
	check(
		at <= comparerAt,
		`layout_editor_window/index.html: ${inWindow(src)} after comparer_page.js`
	);
}
check(
	windowPage.includes('href="../layout_analysis/style.css"'),
	'layout_editor_window/index.html: no Comparer stylesheet'
);

// The site frames the editor in /studio and sizes the frame from this message.
const standalone = fs.readFileSync(shared('ui', 'layout_editor', 'standalone.js'), 'utf8');
check(
	standalone.includes("'ergopti-layout-editor:height'") && standalone.includes('postMessage'),
	'the editor page no longer posts its height to the framing site'
);

// Inlined by the app (studio-inlined-corpus-files): the macOS and Linux hosts
// inline every script, so document.currentScript has an empty src. The corpus
// loader must still load (it once threw there, building its own URL, and the
// Studio window lost the analysis panel and the Comparer), and load the corpora
// through the host.
{
	const inlined = {
		document: { currentScript: { src: '' } },
		URL,
		Map,
		window: {}
	};
	vm.createContext(inlined);
	vm.runInContext(fs.readFileSync(path.join(PAGE_DIR, 'corpus_files.js'), 'utf8'), inlined);
	const files = vm.runInContext('typeof LAYOUT_ANALYSIS_FILES', inlined);
	check(
		files === 'object',
		`an inlined corpus_files.js defines no LAYOUT_ANALYSIS_FILES (${files})`
	);
}

// (studio-chosen-theme) The framed Studio pages follow the theme the site's
// visitor chose: a link's ?theme= and the framing page's message set
// <html data-theme> (theme.css reads it); 'system' removes it; a message from
// another origin or window, or an unknown theme, changes nothing.
{
	const listeners = [];
	const parent = {};
	const dataset = {};
	const warnings = [];
	const themed = {
		location: { search: '?lang=fr&theme=dark', origin: 'https://ergopti.fr' },
		URLSearchParams,
		document: { documentElement: { dataset } },
		console: { warn: (text) => warnings.push(text) },
		window: { parent, addEventListener: (type, listener) => listeners.push([type, listener]) }
	};
	vm.createContext(themed);
	vm.runInContext(fs.readFileSync(shared('ui', 'theme_choice.js'), 'utf8'), themed);
	check(dataset.theme === 'dark', `?theme=dark sets the theme (${dataset.theme})`);
	const message = listeners.find(([type]) => type === 'message');
	check(message, 'the page listens for the framing page');
	const send = (data, origin = 'https://ergopti.fr', source = parent) =>
		message[1]({ data, origin, source });
	send({ type: 'ergopti-theme', theme: 'light' });
	check(dataset.theme === 'light', 'the framing page chooses light');
	send({ type: 'ergopti-theme', theme: 'dark' }, 'https://example.com');
	send({ type: 'ergopti-theme', theme: 'dark' }, 'https://ergopti.fr', {});
	check(dataset.theme === 'light', 'another origin or window is not heard');
	send({ type: 'ergopti-theme', theme: 'sepia' });
	check(
		dataset.theme === 'light' && warnings.length === 1,
		'an unknown theme is named, not applied'
	);
	send({ type: 'ergopti-theme', theme: 'system' });
	check(!('theme' in dataset), "'system' gives the page back to the system");
	const site = fs.readFileSync(
		path.join(__dirname, '..', '..', 'src', 'lib', 'js', 'frameTheme.js'),
		'utf8'
	);
	check(
		site.includes("THEME_MESSAGE = 'ergopti-theme'") &&
			site.includes("THEME_CHOICES = Object.freeze(['system', 'light', 'dark'])"),
		'the site sends the message and the choices theme_choice.js reads'
	);
	check(
		fs
			.readFileSync(
				path.join(__dirname, '..', '..', 'src', 'routes', 'studio', '+layout.svelte'),
				'utf8'
			)
			.includes('#lib/js/frameTheme.js'),
		'the Studio shell does not send the chosen theme to its frames'
	);
}

// (studio-number-locale) Numbers follow the language of the page's strings,
// never the browser's: an app window seeds English strings without naming a
// locale, and a French browser printed « 1 949 220 » in its English status.
{
	const pageWindow = {};
	const numbers = {
		window: pageWindow,
		// Still loading: the popover waits for a DOMContentLoaded that never comes.
		document: { documentElement: { lang: 'fr' }, readyState: 'loading', addEventListener() {} },
		Number,
		Object,
		String
	};
	vm.createContext(numbers);
	vm.runInContext(fs.readFileSync(path.join(PAGE_DIR, 'info_popover.js'), 'utf8'), numbers);
	const info = vm.runInContext('LAYOUT_ANALYSIS_INFO', numbers);
	const written = (setup) => {
		delete pageWindow._i18n_strings;
		delete pageWindow._i18n_locale;
		Object.assign(pageWindow, setup);
		return info.format(1949220.5, 1);
	};
	check(
		written({ _i18n_strings: { '_meta.locale': 'en' }, _i18n_locale: 'de' }) === '1,949,220.5',
		'the locale of the strings shown decides how numbers are written'
	);
	check(
		written({ _i18n_locale: 'de' }) === '1.949.220,5',
		'without strings, the locale asked for decides'
	);
	check(
		written({}) === (1949220.5).toLocaleString('fr', { minimumFractionDigits: 1 }),
		"without either, the page's declared language decides"
	);
	// The whole class: every Studio script writes its numbers through INFO.format.
	for (const dir of ['layout_analysis', 'layout_editor', 'layout_editor_window'])
		for (const file of fs.readdirSync(shared('ui', dir)).filter((f) => f.endsWith('.js'))) {
			if (dir === 'layout_analysis' && file === 'info_popover.js') continue;
			const source = fs.readFileSync(shared('ui', dir, file), 'utf8');
			check(!/\.toLocaleString\(/.test(source), `${dir}/${file} formats numbers itself`);
		}
}

// (comparer-incomplete) An incomplete layout (no space or no letter in a case)
// ranks after every complete one everywhere a rank is shown: the chart draws
// the engine's order, and the editor panel counts the layouts before the edited
// one by the engine's own order (E.rankOrder), never by the score alone.
{
	const panel = fs.readFileSync(path.join(PAGE_DIR, 'analysis_panel.js'), 'utf8');
	check(
		/const rank = 1 \+ scores\.filter\(\(other\) => E\.rankOrder\(other, result\) < 0\)\.length;/.test(
			panel
		),
		'panel: the edited layout is ranked by E.rankOrder'
	);
	const body = (name) =>
		page.match(new RegExp(`function ${name}\\(\\) \\{[\\s\\S]*?\\n\\t\\t\\}`))[0];
	const chart = body('renderChart');
	check(!/\.sort\(/.test(chart), 'chart: the bars follow the ranking, not a sort of their own');
	const ranking = page.match(/function rankingTable\([^)]*\) \{[\s\S]*?\n\t\t\}/)[0];
	check(
		/incompleteFlag\(result\)/.test(chart) && /incompleteFlag\(result\)/.test(ranking),
		'chart and table: an incomplete layout carries its flag'
	);
	check(
		/rankingTable\(\s*\$\('la-table'\)/.test(body('renderTable')),
		'the ranking is a ranking table'
	);
	// Every other figure orders its layouts with the incomplete ones last.
	check(
		/Number\(a\.incomplete\) - Number\(b\.incomplete\)/.test(
			page.match(/function figureOrder\([^)]*\) \{[\s\S]*?\n\t\t\}/)[0]
		),
		'figures: the incomplete layouts come last'
	);
}

// (comparer-sub-tabs) The results are sub-tabs (maintainer, 2026-11-18): each
// has its panel and its label, every metric of the engine is charted in exactly
// one themed tab, the stacked figures' parts each have a categorical colour
// token in both themes, and every built-in corpus has a kind the picker groups.
{
	const literal = (name) => {
		const m = page.match(new RegExp(`const ${name} = (\\[[^\\]]*\\]|\\{[\\s\\S]*?\\n\\t\\});`));
		check(m, `the page lost ${name}`);
		return m ? vm.runInNewContext(`(${m[1]})`) : null;
	};
	const tabs = literal('TABS');
	check(
		JSON.stringify(tabs) ===
			JSON.stringify([
				'overview',
				'fingers',
				'bigrams',
				'trigrams',
				'rows',
				'heatmaps',
				'misc',
				'analysers',
				'details'
			]),
		`tabs: ${tabs}`
	);
	for (const id of tabs) {
		check(markup.includes(`id="la-panel-${id}"`), `tab ${id}: no panel`);
		check(page.includes(`t('layout_analysis.tab.${id}')`), `tab ${id}: no label`);
	}
	const tabMetrics = literal('TAB_METRICS');
	const charted = Object.values(tabMetrics).flat();
	for (const id of Object.keys(E.METRICS))
		check(
			charted.filter((m) => m === id).length === 1,
			`metric ${id} is charted ${charted.filter((m) => m === id).length} times`
		);
	for (const id of charted) check(id in E.METRICS, `tab metric ${id} is not an engine metric`);
	for (const tab of Object.keys(tabMetrics))
		check(markup.includes(`id="la-charts-${tab}"`), `tab ${tab}: no chart grid`);
	const parts = Math.max(literal('TRIGRAM_MIX').length, literal('ROW_MIX').length);
	const theme = fs.readFileSync(shared('ui', 'theme.css'), 'utf8');
	const style = fs.readFileSync(path.join(PAGE_DIR, 'style.css'), 'utf8');
	for (let slot = 1; slot <= parts; slot++) {
		check(
			(theme.match(new RegExp(`--theme-chart-cat-${slot}:`, 'g')) || []).length === 3,
			`theme.css: --theme-chart-cat-${slot} in light, system dark and chosen dark`
		);
		check(style.includes(`.la-seg-${slot},`), `style.css: no colour for part ${slot}`);
	}
	// The kinds live with the shared corpus picker (corpus_files.js).
	const files = fs.readFileSync(path.join(PAGE_DIR, 'corpus_files.js'), 'utf8');
	const kindsSource = files.match(/const CORPUS_KINDS = (\[[^\]]*\]);/);
	check(kindsSource, 'corpus_files.js lost CORPUS_KINDS');
	const kinds = kindsSource ? vm.runInNewContext(`(${kindsSource[1]})`) : [];
	for (const corpus of DATA.corpora) {
		check(kinds.includes(corpus.kind), `corpus ${corpus.id}: kind ${corpus.kind}`);
		check(
			(corpus.kind === 'code') === (corpus.language === 'code'),
			`corpus ${corpus.id}: only code has the language « code »`
		);
	}
	check(
		files.includes('t(`layout_analysis.corpus.kind.${corpus.kind}`)'),
		'the corpus picker names no kind'
	);
	for (const [id, source] of Object.entries(DATA.library_sources))
		check(source.name, `library collection ${id}: no name for the origin filter`);
}

// The score settings file: export, import and reset controls in « Réglages du
// score »; the import applies only what the engine's strict reading returns,
// and the app's Studio window saves the export through its host's download
// path (source_export), a WebView keeping no browser download.
{
	for (const id of ['la-config-export', 'la-config-import', 'la-config-reset', 'la-config-status'])
		check(page.includes(`id="${id}"`), `score settings: no #${id}`);
	const importer = page.slice(page.indexOf("$('la-config-import')"));
	check(
		importer.indexOf('E.readScoreConfig(') > 0 &&
			importer.indexOf('E.readScoreConfig(') < importer.indexOf('Object.assign(state, settings)'),
		'score settings: the import applies the file before the engine has read it whole'
	);
	check(
		page.includes('E.scoreConfig(') && page.includes('HOST.saveFile'),
		'score settings: the export does not go through E.scoreConfig and the host'
	);
	const appWindow = fs.readFileSync(shared('ui', 'layout_editor_window', 'script.js'), 'utf8');
	check(
		/saveFile: function \(filename, text\) \{[\s\S]*?hostSaveBinary\(/.test(appWindow),
		'score settings: the app window host has no saveFile through source_export'
	);
}

// The score settings read as titled sections (maintainer, 2026-11-18): each
// static section has its icon and accent, every weight is in exactly one
// titled group with its help in all 21 locales, each weight input is the
// target of its own label and described by its unit and definition, and the
// ideal finger load has its hands' picture, drawn from its inputs.
{
	const groupsMatch = page.match(/const WEIGHT_GROUPS = (\{[\s\S]*?\n\t\});/);
	check(groupsMatch, 'score settings: the page lost WEIGHT_GROUPS');
	const groups = groupsMatch ? vm.runInNewContext(`(${groupsMatch[1]})`) : {};
	const grouped = Object.values(groups).flat();
	const weightIds = Object.keys(E.defaultWeights());
	check(
		grouped.length === weightIds.length && weightIds.every((id) => grouped.includes(id)),
		`score settings: WEIGHT_GROUPS holds ${grouped.join(' ')}, the weights are ${weightIds.join(' ')}`
	);
	check(
		JSON.stringify(Object.keys(groups)) ===
			JSON.stringify(['pairs', 'rolls', 'load', 'position', 'access', 'bonuses']),
		`score settings: groups ${Object.keys(groups).join(' ')}`
	);
	const english = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, 'en.json'), 'utf8'));
	for (const file of locales) {
		const strings = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8'));
		for (const group of Object.keys(groups))
			for (const key of [`weights.group.${group}`, `weights.group_help.${group}`])
				check(
					typeof strings[`${PREFIX}${key}`] === 'string' && strings[`${PREFIX}${key}`] !== '',
					`${file}: ${PREFIX}${key}`
				);
		for (const better of ['lower', 'higher']) {
			const key = `${PREFIX}weights.per_${better}`;
			check(
				typeof strings[key] === 'string' && strings[key].includes('{unit}'),
				`${file}: ${key} with {unit}`
			);
		}
	}
	check(
		weightIds.every((id) => ['lower', 'higher'].includes(E.METRICS[id].better)),
		'score settings: a weight of a metric neither lower nor higher has no unit phrase'
	);
	check(english[`${PREFIX}weights.per_lower`], 'score settings: no English unit phrase');
	for (const section of ['config', 'weights', 'ideal', 'shortcuts', 'forms'])
		check(
			new RegExp(`class="la-weights[^"]* la-accent-[1-6]" data-section-icon="${section}"`).test(
				page
			),
			`score settings: the ${section} section has no accent or icon`
		);
	const iconsMatch = page.match(/const SECTION_ICONS = (\{[\s\S]*?\n\t\});/);
	const icons = iconsMatch ? vm.runInNewContext(`(${iconsMatch[1]})`) : {};
	for (const id of [...Object.keys(groups), 'config', 'weights', 'ideal', 'shortcuts', 'forms'])
		check(typeof icons[id] === 'string' && icons[id] !== '', `score settings: no icon for ${id}`);
	check(
		/svg\.setAttribute\('aria-hidden', 'true'\)/.test(page),
		'score settings: the section icons are not hidden from assistive technology'
	);
	const control = page.slice(page.indexOf('function weightControl('));
	const body = control.slice(0, control.indexOf('\n\t\t}\n'));
	check(
		/label\.htmlFor = inputId/.test(body) && /input\.id = inputId/.test(body),
		'score settings: a weight input is not the target of its label'
	);
	check(
		/aria-describedby', `\$\{inputId\}-unit \$\{inputId\}-help`/.test(body) &&
			body.includes('t(`layout_analysis.info.${id}`)'),
		'score settings: a weight input is not described by its unit and definition'
	);
	check(
		/<svg\s+id="la-ideal-hands"[^>]*aria-hidden="true"/.test(page),
		'score settings: the ideal finger load has no hands picture'
	);
	const ideal = page.slice(page.indexOf('function fillIdealLoad('));
	check(
		(ideal.slice(0, ideal.indexOf('\n\t\t}\n')).match(/drawIdealHands\(/g) || []).length === 2,
		'score settings: the hands picture does not follow the ideal load and its edits'
	);
	const css = fs.readFileSync(path.join(PAGE_DIR, 'style.css'), 'utf8');
	check(
		css.includes('minmax(min(100%, 240px), 1fr)'),
		'score settings: the weight grid does not reflow to one column at 320 px'
	);
	for (let slot = 1; slot <= 6; slot++)
		check(
			css.includes(`.la-accent-${slot} {\n\t--la-section-accent: var(--la-cat-${slot});`),
			`score settings: no accent for slot ${slot}`
		);
}

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-comparer-page: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-comparer-page: OK (${keys.size} keys × ${locales.length} locales, ${DATA.corpora.length} corpora)`
);
