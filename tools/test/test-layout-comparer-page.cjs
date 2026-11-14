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
 * 5. Globals: no page script reads `window.X` for an X a loaded script
 *    declares with a top-level const or let, which is a page global but not
 *    a window property (the .keylayout import once read window.LAYOUT_COMPOSER_DATA
 *    and got undefined).
 * 6. Editor panel: the site's editor page and the app's editor window load
 *    the panel's scripts in the same order, before editor_page.js; the app
 *    window loads built-in corpora through its host, not as static tags.
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
	'_generated/analysis_data.js',
	'analysis_engine.js',
	'info_popover.js',
	'fingering_editor.js',
	'../layout_composer/_generated/composer_data.js',
	'../layout_composer/composer_model.js',
	'../layout_editor/toml_prelude.js',
	'../vendor/smol-toml.js',
	'layout_formats.js',
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
	'fingering_editor.js'
])
	for (const m of fs.readFileSync(path.join(PAGE_DIR, file), 'utf8').matchAll(/\bt\('([a-z_.]+)'/g))
		keys.add(m[1]);
for (const id of Object.keys(E.METRICS)) keys.add(`${PREFIX}metric.${id}`);
for (const id of DATA.model.fingers) keys.add(`${PREFIX}finger.${id}`);
// The fingering editor's base choices and the errors it reports.
for (const id of Object.keys(DATA.model.fingerings)) keys.add(`${PREFIX}fingering.base_${id}`);
for (const m of fs
	.readFileSync(path.join(PAGE_DIR, 'fingering_editor.js'), 'utf8')
	.matchAll(/notifyError\('([a-z_.]+)'/g))
	keys.add(m[1]);
for (const id of Object.keys(DATA.sources.items)) keys.add(`${PREFIX}info.${id}`);
check(keys.size >= MIN_KEYS, `only ${keys.size} keys found`);
const locales = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
check(locales.length === 21, `${locales.length} locales`);
for (const file of locales) {
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8'));
	for (const key of keys)
		check(typeof strings[key] === 'string' && strings[key] !== '', `${file}: ${key}`);
}

// The site sizes its frame from this message (contract with src/routes/studio).
check(
	page.includes("'ergopti-layout-analysis:height'") && page.includes('postMessage'),
	'the page no longer posts its height to the framing site'
);

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

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-comparer-page: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-comparer-page: OK (${keys.size} keys × ${locales.length} locales, ${DATA.corpora.length} corpora)`
);
