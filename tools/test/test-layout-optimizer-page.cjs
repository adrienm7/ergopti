// tools/test/test-layout-optimizer-page.cjs

/**
 * ==============================================================================
 * MODULE: Layout Optimizer Page Gate
 * DESCRIPTION:
 * _shared/ui/layout_optimizer/index.html is the « Optimiser » tab of Ergopti
 * Studio. This gate holds its wiring.
 *
 * WHAT IS CHECKED:
 * 1. Scripts: the page loads the generated data, the engine, the corpus
 *    loader, the optimizer, its runner and the page script in that order, and
 *    the worker imports the same engine and optimizer; every file exists.
 * 2. Strings: every layout_optimizer.* key the page shows (data-i18n, option
 *    prefixes, t() calls, the switches, presets and corpus languages it
 *    builds keys from, and every refusal code of the optimizer) exists in all
 *    21 locales with the placeholders of English; the metric and keyboard
 *    names it borrows from layout_analysis.* exist too.
 * 3. Studio: the site lists the tab, frames the page, and opens « Éditer »
 *    on the optimizer's message; the editor's host takes the layout handed
 *    over and opens it in a new tab.
 * 4. Runner: a page-thread run (no worker) posts progress and a final layout
 *    whose score is the engine's on the whole corpus, and a refused
 *    constraint comes back as an error message with its code.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const PAGE_DIR = shared('ui', 'layout_optimizer');
const LOCALES_DIR = shared('core', 'i18n', 'data', 'locales');
const PREFIX = 'layout_optimizer.';
const SCRIPTS = [
	// The website's accessibility settings, before the page paints.
	'../a11y_prefs.js',
	// The theme the site's visitor chose (theme_choice.js), before the first paint.
	'../theme_choice.js',
	'../i18n.js',
	// Keeps the native context menu closed outside text fields (test-host-context-menu).
	'../host_bridge.js',
	'../_generated/key_legend.js',
	'../layout_analysis/_generated/analysis_data.js',
	'../layout_analysis/analysis_engine.js',
	'../layout_analysis/pdf_text.js',
	'../layout_analysis/corpus_files.js',
	'optimizer_core.js',
	'optimizer_runner.js',
	'optimizer_page.js'
];
const WORKER_SCRIPTS = [
	'../layout_analysis/_generated/analysis_data.js',
	'../layout_analysis/analysis_engine.js',
	'optimizer_core.js',
	'optimizer_runner.js'
];
// Floor: a page that lost its strings must not read as complete.
const MIN_KEYS = 60;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};
const read = (file) => fs.readFileSync(file, 'utf8');

// =========================
// ======= 1/ Scripts ======
// =========================

const html = read(path.join(PAGE_DIR, 'index.html'));
const scripts = Array.from(html.matchAll(/<script src="([^"]+)"/g), (m) => m[1]);
check(JSON.stringify(scripts) === JSON.stringify(SCRIPTS), `scripts: ${scripts.join(', ')}`);
const worker = read(path.join(PAGE_DIR, 'optimizer_worker.js'));
const imported = Array.from(
	(worker.match(/importScripts\(([\s\S]*?)\)/) || ['', ''])[1].matchAll(/'([^']+)'/g),
	(m) => m[1]
);
check(
	JSON.stringify(imported) === JSON.stringify(WORKER_SCRIPTS),
	`worker: ${imported.join(', ')}`
);
for (const src of SCRIPTS.concat(WORKER_SCRIPTS))
	check(fs.existsSync(path.join(PAGE_DIR, src)), `missing ${src}`);

// =========================
// ======= 2/ Strings ======
// =========================

const sandbox = {};
vm.createContext(sandbox);
for (const file of WORKER_SCRIPTS)
	vm.runInContext(read(path.join(PAGE_DIR, file)), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const O = vm.runInContext('LAYOUT_OPTIMIZER', sandbox);
const DATA = vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox);
const RUNNER = vm.runInContext('LAYOUT_OPTIMIZER_RUNNER', sandbox);
const page = read(path.join(PAGE_DIR, 'optimizer_page.js'));
const keys = new Set();
for (const m of page.matchAll(/data-i18n(?:-placeholder)?="([^"]+)"/g)) keys.add(m[1]);
for (const m of page.matchAll(/data-i18n-option-prefix="([^"]+)"[^>]*>([\s\S]*?)<\/select>/g))
	for (const option of m[2].matchAll(/value="([^"]+)"/g)) keys.add(`${m[1]}.${option[1]}`);
for (const m of page.matchAll(/t\(`\$\{PREFIX\}([a-z_.]+)`/g)) keys.add(PREFIX + m[1]);
for (const m of page.matchAll(/\bt\('([a-z_.]+)'/g)) keys.add(m[1]);
// The Comparer's words the page borrows (the file refusals).
for (const m of page.matchAll(/'(layout_analysis\.[a-z_.]+)'/g)) keys.add(m[1]);
// Keys the page builds from lists.
const switches = (page.match(/const SWITCHES = \[([\s\S]*?)\]/) || ['', ''])[1];
const switchIds = Array.from(switches.matchAll(/'([A-Za-z]+)'/g), (m) => m[1]);
check(
	JSON.stringify(switchIds) ===
		JSON.stringify(
			Object.keys(O.DEFAULT_OPTIONS).filter((id) => typeof O.DEFAULT_OPTIONS[id] === 'boolean')
		),
	'the page offers every switch of the optimizer'
);
for (const id of switchIds) {
	keys.add(`${PREFIX}option.${id}.label`);
	keys.add(`${PREFIX}option.${id}.help`);
}
for (const id of Object.keys(O.QWERTY_PIN_PRESETS)) keys.add(`${PREFIX}qwerty.preset.${id}`);
for (const corpus of DATA.corpora) keys.add(`${PREFIX}language.${corpus.language}`);
const codes = new Set(
	Array.from(
		read(path.join(PAGE_DIR, 'optimizer_core.js')).matchAll(/new OptimizerError\(\s*'([a-z_]+)'/g),
		(m) => m[1]
	)
);
check(codes.has('pin_conflict') && codes.has('no_dead_key'), 'optimizer codes');
// The refusals the page raises itself (a missing text, …).
for (const m of page.matchAll(/\{ code: '([a-z_]+)' \}/g)) codes.add(m[1]);
check(codes.has('text_missing'), 'the page refuses a run without its text');
for (const code of [...codes, 'failed', 'corpus', 'worker', 'studio_handoff_failed'])
	keys.add(`${PREFIX}error.${code}`);
for (const id of Object.keys(E.defaultWeights())) keys.add(`layout_analysis.metric.${id}`);
for (const id of Object.keys(DATA.model.keyboards)) keys.add(`layout_analysis.keyboard.${id}`);
check(keys.size >= MIN_KEYS, `only ${keys.size} keys found`);

const locales = fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json'));
check(locales.length === 21, `${locales.length} locales`);
const english = JSON.parse(read(path.join(LOCALES_DIR, 'en.json')));
const placeholders = (text) => JSON.stringify((String(text).match(/\{[a-z]+\}/g) || []).sort());
for (const file of locales) {
	const strings = JSON.parse(read(path.join(LOCALES_DIR, file)));
	for (const key of keys) {
		check(typeof strings[key] === 'string' && strings[key] !== '', `${file}: ${key}`);
		if (typeof strings[key] === 'string')
			check(
				placeholders(strings[key]) === placeholders(english[key]),
				`${file}: ${key} placeholders`
			);
	}
}

// A function declared inside mount() takes the name of mount's own parameter
// for the whole body: the run's options() once hid mount's options, so the
// site never got the page's height (reportHeight) and no host hook arrived.
{
	const signature = page.match(/function mount\(([^)]*)\)/);
	check(Boolean(signature), 'the page defines mount(root, options)');
	for (const name of signature ? signature[1].split(',').map((p) => p.trim()) : [])
		check(
			!new RegExp(`\\bfunction ${name}\\(`).test(page),
			`a function named ${name} hides mount's parameter`
		);
}

// =========================
// ======= 3/ Studio =======
// =========================

const navigation = read(path.join(REPO_ROOT, 'src', 'lib', 'js', 'siteNavigation.js'));
check(navigation.includes("route: '/studio/optimiser'"), 'the Studio lists « Optimiser »');
const route = read(path.join(REPO_ROOT, 'src', 'routes', 'studio', 'optimiser', '+page.svelte'));
check(
	route.includes("asset('ergopti_plus/_shared/ui/layout_optimizer/index.html')"),
	'the tab frames the page'
);
const shell = read(path.join(REPO_ROOT, 'src', 'routes', 'studio', '+layout.svelte'));
const files = read(shared('ui', 'layout_analysis', 'corpus_files.js'));
const openEditor = (files.match(/OPEN_EDITOR_MESSAGE = '([^']+)'/) || [])[1];
check(
	Boolean(openEditor) && shell.includes(`'${openEditor}'`),
	'the Studio opens « Éditer » on the message'
);
const standalone = read(shared('ui', 'layout_editor', 'standalone.js'));
check(
	/takeEditorHandoff\(\)[\s\S]{0,80}layoutEditor\.openLayout\(/.test(standalone),
	'the editor host opens the handed layout'
);
check(
	/\n\t\t\topenLayout,\n/.test(read(shared('ui', 'layout_editor', 'editor_page.js'))),
	'the editor exposes openLayout'
);

// =========================
// ======= 4/ Runner =======
// =========================

const tables = E.ngramsFromText(
	'le chat dort sur le tapis, la souris danse dans la cuisine.\n'.repeat(5)
);
const azerty = E.libraryLayouts().find((layout) => layout.id === 'azerty');
const request = {
	start: azerty,
	options: { qwertyPins: ['z', 'x', 'c', 'v'] },
	tables,
	analysis: { format: 'tkl' },
	share: 0.99,
	seed: 4,
	restarts: 2,
	firstRestart: 0,
	iterations: 40,
	startMode: 'random',
	identity: { id: 'azerty_optimized', name: 'AZERTY (optimized)' }
};
// The runner yields with setTimeout between slices; a queue runs them here.
const queue = [];
sandbox.setTimeout = (fn) => queue.push(fn);
const messages = [];
RUNNER.start(request, (message) => messages.push(message));
for (let i = 0; queue.length && i < 100000; i++) queue.shift()();
const done = messages.find((message) => message.type === 'done');
check(
	messages.some((message) => message.type === 'progress' && message.layout),
	'the runner posts progress'
);
check(Boolean(done), 'the runner finishes');
if (done) {
	const full = E.analyse(done.result.layout, tables, request.analysis).score.total;
	check(
		Math.abs(done.result.score - full) < 1e-9,
		`final score ${done.result.score} is the engine's ${full}`
	);
	check(done.result.layout.rows.KeyZ[0] === 'z', 'the final layout keeps the QWERTY pins');
	check(done.result.layout.name === 'AZERTY (optimized)', 'the result carries its name');
}
const refused = [];
RUNNER.start(
	Object.assign({}, request, {
		options: { deadKeyLayer: true },
		start: E.libraryLayouts().find((l) => l.id === 'qwerty')
	}),
	(m) => refused.push(m)
);
check(
	refused.length === 1 && refused[0].type === 'error' && refused[0].code === 'no_dead_key',
	'a refusal comes back with its code'
);

if (errors.length) {
	console.error(`FAIL test-layout-optimizer-page: ${errors.length} problem(s)`);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
console.log(`PASS test-layout-optimizer-page (${keys.size} keys in ${locales.length} locales)`);
