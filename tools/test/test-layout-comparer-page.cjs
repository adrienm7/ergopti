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
 * 3. Corpora: every built-in corpus of the generated data has its tables file.
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
	'_generated/analysis_data.js',
	'analysis_engine.js',
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
for (const m of page.matchAll(/\bt\('([a-z_.]+)'/g)) keys.add(PREFIX + m[1]);
for (const id of Object.keys(E.METRICS)) keys.add(`${PREFIX}metric.${id}`);
for (const id of DATA.model.fingers) keys.add(`${PREFIX}finger.${id}`);
check(keys.size >= MIN_KEYS, `only ${keys.size} keys found`);
const locales = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
check(locales.length === 21, `${locales.length} locales`);
for (const file of locales) {
	const strings = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8'));
	for (const key of keys)
		check(typeof strings[key] === 'string' && strings[key] !== '', `${file}: ${key}`);
}

// 3/ Corpora
check(DATA.corpora.length > 0, 'no built-in corpus');
for (const corpus of DATA.corpora)
	check(
		fs.existsSync(path.join(PAGE_DIR, corpus.script)),
		`corpus ${corpus.id}: no ${corpus.script}`
	);

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-comparer-page: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-comparer-page: OK (${keys.size} keys × ${locales.length} locales, ${DATA.corpora.length} corpora)`
);
