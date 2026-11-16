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
	'../i18n.js',
	'../host_bridge.js',
	// The shared key legend formatter (dead keys as their bare accent).
	'../_generated/key_legend.js',
	'_generated/analysis_data.js',
	'analysis_engine.js',
	'analyser_scores.js',
	'analyser_tab.js',
	'info_popover.js',
	'fingering_editor.js',
	'../layout_composer/_generated/composer_data.js',
	'../layout_composer/composer_model.js',
	'../layout_editor/toml_prelude.js',
	'../vendor/smol-toml.js',
	'layout_formats.js',
	// The PDF text reader corpus_files.js calls.
	'pdf_text.js',
	'corpus_files.js',
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
	'analyser_tab.js'
])
	for (const m of fs.readFileSync(path.join(PAGE_DIR, file), 'utf8').matchAll(/\bt\('([a-z_.]+)'/g))
		keys.add(m[1]);
for (const id of Object.keys(E.METRICS)) keys.add(`${PREFIX}metric.${id}`);
for (const id of DATA.model.fingers) keys.add(`${PREFIX}finger.${id}`);
for (const id of Object.keys(DATA.model.keyboards)) keys.add(`${PREFIX}keyboard.${id}`);
for (const format of E.keyboardFormats()) keys.add(`${PREFIX}format.${format.id}`);
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
			'Annulaire gauche porte moins que Auriculaire gauche : chaque main garde index ≥ majeur ≥ annulaire ≥ auriculaire',
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
check(
	page.includes("infoButton('shortcut_letters')"),
	'sources: no « i » button for shortcut_letters'
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
for (const file of ['comparer_page.js', 'analysis_panel.js', 'info_popover.js', 'corpus_files.js'])
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
	'../layout_analysis/fingering_editor.js',
	'../layout_analysis/corpus_files.js',
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
// of the Comparer's page (but i18n.js: its host seeds the strings), the
// Comparer's own last, and its stylesheet.
const windowPage = fs.readFileSync(shared('ui', 'layout_editor_window', 'index.html'), 'utf8');
const inWindow = (src) => (src.startsWith('../') ? src : `../layout_analysis/${src}`);
const comparerAt = windowScripts.indexOf('../layout_analysis/comparer_page.js');
for (const src of SCRIPTS.filter((s) => s !== '../i18n.js')) {
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

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-comparer-page: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-comparer-page: OK (${keys.size} keys × ${locales.length} locales, ${DATA.corpora.length} corpora)`
);
