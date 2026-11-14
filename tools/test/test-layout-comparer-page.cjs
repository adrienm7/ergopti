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
const keys = new Set();
for (const m of html.matchAll(/data-i18n(?:-placeholder|-title)?="([^"]+)"/g)) keys.add(m[1]);
for (const m of html.matchAll(/data-i18n-option-prefix="([^"]+)"[^>]*>([\s\S]*?)<\/select>/g))
	for (const option of m[2].matchAll(/value="([^"]+)"/g)) keys.add(`${m[1]}.${option[1]}`);
// The page, its popovers and the editor's analysis panel share these strings.
for (const file of ['comparer_page.js', 'info_popover.js', 'analysis_panel.js'])
	for (const m of fs.readFileSync(path.join(PAGE_DIR, file), 'utf8').matchAll(/\bt\('([a-z_.]+)'/g))
		keys.add(m[1]);
for (const id of Object.keys(E.METRICS)) keys.add(`${PREFIX}metric.${id}`);
for (const id of DATA.model.fingers) keys.add(`${PREFIX}finger.${id}`);
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
	check(html.includes(`data-info="${id}"`), `sources: no « i » button for ${id}`);
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

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-comparer-page: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-comparer-page: OK (${keys.size} keys × ${locales.length} locales, ${DATA.corpora.length} corpora)`
);
