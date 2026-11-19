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
 *    prefixes, t() calls, the switches and presets it
 *    builds keys from, and every refusal code of the optimizer) exists in all
 *    21 locales with the placeholders of English; the metric and keyboard
 *    names it borrows from layout_analysis.* exist too.
 * 3. Studio: the site lists the tab, frames the page, and opens « Éditer »
 *    on the optimizer's message; the editor's host takes the layout handed
 *    over and opens it in a new tab.
 * 4. Runner: a page-thread run (no worker) posts progress and a final layout
 *    whose score is the engine's on the whole corpus, and a refused
 *    constraint comes back as an error message with its code.
 * 5. Robustness: numbers are written in the page's language, and a page that
 *    declares none (or a malformed one) writes them in the documented
 *    fallback instead of throwing; every stage of a run has its failure
 *    message, and a runner message the page cannot show ends the run.
 * 6. Library: after a run, the runner scores every library layout on the
 *    run's corpus and settings in slices (the worker too), each score and
 *    similarity the engine's; the summary's verdict reads the best existing
 *    layout's gap against the small gap; the library card renders its
 *    verdict, the gauge and bars with their numbers in words, a score gap
 *    per layout and labelled buttons that open each layout.
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
	// The fingering profiles the score reads, and what they need.
	'../layout_analysis/info_popover.js',
	'../layout_analysis/undo_offer.js',
	'../layout_analysis/fingering_editor.js',
	'../layout_analysis/corpus_files.js',
	// The Comparer's score settings, the one source of the score (no weights of its own).
	'../layout_analysis/score_settings.js',
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

/**
 * A document small enough for the library card: elements with children,
 * classes, attributes, dataset, style, text and click listeners.
 */
function fakeDocument() {
	const node = (tagName) => ({
		tagName: tagName.toUpperCase(),
		className: '',
		children: [],
		text: '',
		attributes: {},
		dataset: {},
		listeners: [],
		style: {
			props: {},
			setProperty(name, value) {
				this.props[name] = value;
			}
		},
		set textContent(value) {
			this.children = [];
			this.text = String(value);
		},
		get textContent() {
			return textOf(this);
		},
		append(...items) {
			for (const item of items)
				this.children.push(typeof item === 'string' ? { text: item, children: [] } : item);
		},
		setAttribute(name, value) {
			this.attributes[name] = String(value);
		},
		addEventListener(type, listener) {
			if (type === 'click') this.listeners.push(listener);
		},
		click() {
			for (const listener of this.listeners) listener();
		}
	});
	return { createElement: node };
}

/** A fake node and every node under it. */
const descendants = (root) => [root].concat(...(root.children || []).map(descendants));
/** A fake node's text, its children's after its own. */
const textOf = (root) => (root.text || '') + (root.children || []).map(textOf).join('');

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
// Each stage of a run says its own failure (failRun).
const stages = (page.match(/const RUN_STAGES = \[([\s\S]*?)\]/) || ['', ''])[1];
const stageIds = Array.from(stages.matchAll(/'([a-z]+)'/g), (m) => m[1]);
check(stageIds.length >= 5, `run stages: ${stageIds.join(', ')}`);
for (const id of stageIds) keys.add(`${PREFIX}error.stage.${id}`);
for (const id of switchIds) {
	keys.add(`${PREFIX}option.${id}.label`);
	keys.add(`${PREFIX}option.${id}.help`);
}
for (const id of Object.keys(O.QWERTY_PIN_PRESETS)) keys.add(`${PREFIX}qwerty.preset.${id}`);
// The score settings' summary: each one default or the user's own.
for (const id of ['default', 'custom']) keys.add(`${PREFIX}settings.${id}`);
// The page keeps no weight of its own: the run scores with the Comparer's settings.
check(
	page.includes('SCORE_SETTINGS.analysisOptions(') && !/defaultWeights\(\)/.test(page),
	'the optimizer scores with the shared score settings, not weights of its own'
);
// The library card builds its verdict, gap and button keys from lists.
const listKeys = (name) =>
	Array.from(
		(page.match(new RegExp(`const ${name} = \\{([^}]*)\\}`)) || ['', ''])[1].matchAll(
			/([a-z_]+):/g
		),
		(m) => m[1]
	);
const verdicts = listKeys('VERDICT_MARKS');
const gapSides = listKeys('GAP_MARKS');
check(
	JSON.stringify(verdicts) === JSON.stringify(['small_gap', 'optimized_ahead', 'existing_better']),
	`library verdicts: ${verdicts.join(', ')}`
);
check(
	JSON.stringify(gapSides) === JSON.stringify(['behind', 'ahead', 'same']),
	`library gap sides: ${gapSides.join(', ')}`
);
for (const id of verdicts) keys.add(`${PREFIX}library.verdict.${id}`);
for (const id of gapSides) keys.add(`${PREFIX}library.gap_${id}`);
for (const where of ['comparer', 'editor']) {
	keys.add(`${PREFIX}library.open_${where}`);
	keys.add(`${PREFIX}library.open_${where}_label`);
}
// A count table's localized name, shown in the corpus picker.
for (const corpus of DATA.corpora) if (corpus.title_key) keys.add(corpus.title_key);
check(
	page.includes('FILES.fillCorpusPicker(') &&
		read(shared('ui', 'layout_analysis', 'corpus_files.js')).includes('corpus.title_key'),
	'the corpus picker is the shared one, which shows the localized names'
);
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

// The app's Studio window mounts the page in its « Optimiser » tab: it loads
// the optimizer after the engine and the corpus reader (and before its own
// script), the optimizer's stylesheet, lists the tab's label, and opens the
// result in its own tabs. The Windows host sends the layout_optimizer.* keys
// (macOS and Linux seed the whole catalogue).
{
	const windowDir = shared('ui', 'layout_editor_window');
	const windowHtml = read(path.join(windowDir, 'index.html'));
	const windowScripts = Array.from(windowHtml.matchAll(/<script src="([^"]+)"/g), (m) => m[1]);
	const at = (src) => windowScripts.indexOf(src);
	const needed = [
		'../_generated/key_legend.js',
		'../layout_analysis/analysis_engine.js',
		'../layout_analysis/pdf_text.js',
		'../layout_analysis/corpus_files.js',
		'../layout_optimizer/optimizer_core.js',
		'../layout_optimizer/optimizer_runner.js',
		'../layout_optimizer/optimizer_page.js',
		'script.js'
	];
	for (let i = 0; i < needed.length; i++) {
		check(at(needed[i]) >= 0, `layout_editor_window: no ${needed[i]}`);
		if (i > 0) check(at(needed[i - 1]) < at(needed[i]), `layout_editor_window: ${needed[i]} order`);
	}
	check(
		windowHtml.includes('href="../layout_optimizer/style.css"'),
		'layout_editor_window: no optimizer stylesheet'
	);
	check(
		windowHtml.includes('id="studio-tab-optimize"') &&
			windowHtml.includes('data-i18n="layout_editor.studio.tab.optimize"') &&
			windowHtml.includes('id="studio-optimizer"'),
		'layout_editor_window: no « Optimiser » tab'
	);
	const windowStrings = JSON.parse(read(path.join(windowDir, 'strings.json'))).keys;
	check(
		windowStrings.includes('layout_editor.studio.tab.optimize'),
		'layout_editor_window/strings.json: no tab label'
	);
	for (const file of locales)
		check(
			typeof JSON.parse(read(path.join(LOCALES_DIR, file)))['layout_editor.studio.tab.optimize'] ===
				'string',
			`${file}: layout_editor.studio.tab.optimize`
		);
	const windowScript = read(path.join(windowDir, 'script.js'));
	check(
		/LAYOUT_OPTIMIZER_PAGE\.mount\(optimizer, \{\s*host: \{\s*openEditor: editOptimized,\s*openComparer: compareEdited,\s*openScoreSettings: showScoreSettings\s*\}/.test(
			windowScript
		),
		'layout_editor_window: the tab mounts the optimizer with the window as host'
	);
	check(
		/function editOptimized\(layout\) \{\s*showTab\('edit'\);\s*if \(_editor\) _editor\.openLayout\(layout\);/.test(
			windowScript
		),
		'layout_editor_window: the optimizer opens its layout in « Éditer »'
	);
	const windowsHost = read(
		path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'ui', 'layout_manager', 'init.ahk')
	);
	check(
		windowsHost.includes('SubStr(Key, 1, 17) == "layout_optimizer."'),
		'the Windows Studio window sends the layout_optimizer.* strings'
	);
}

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

// The library after a run: every library layout scored on the run's corpus
// and settings, in slices, with its similarity to the optimized layout.
let librarySummary = null;
if (done && typeof RUNNER.scoreLibrary === 'function') {
	const scanned = [];
	RUNNER.scoreLibrary(
		{ layout: done.result.layout, tables, analysis: request.analysis },
		(message) => scanned.push(message)
	);
	for (let i = 0; queue.length && i < 100000; i++) queue.shift()();
	const libraryDone = scanned.find((message) => message.type === 'library_done');
	const libraryLayouts = E.libraryLayouts();
	check(
		scanned.filter((message) => message.type === 'library_progress').length > 0,
		'the library scan posts its progress'
	);
	check(
		Boolean(libraryDone) && libraryDone.entries.length === libraryLayouts.length,
		`the library scan scores every library layout: ${libraryDone ? libraryDone.entries.length : 'none'}`
	);
	if (libraryDone) {
		for (const id of ['azerty', 'ergol', 'bepo']) {
			const entry = libraryDone.entries.find((item) => item.id === id);
			const layout = libraryLayouts.find((item) => item.id === id);
			const score = E.analyse(layout, tables, request.analysis).score.total;
			const alike = E.layoutSimilarity(done.result.layout, layout, tables, {});
			check(
				entry && entry.score === score,
				`library scan: ${id} scores ${entry && entry.score}, the engine ${score}`
			);
			check(
				entry && JSON.stringify(entry.similarity.weighted) === JSON.stringify(alike.weighted),
				`library scan: ${id} similarity is the engine's`
			);
		}
		librarySummary = RUNNER.librarySummary(libraryDone.entries, done.result.score, {
			smallGap: E.similarScoreGap(),
			closest: 5
		});
		check(librarySummary.closest.length === 5, 'the summary lists five alike layouts');
	}
} else check(false, 'the runner has no scoreLibrary');

// The summary's verdict, the best existing layout against the small gap.
if (typeof RUNNER.librarySummary === 'function') {
	const entry = (id, score, sameKey, incomplete) => ({
		id,
		name: id,
		score,
		incomplete: Boolean(incomplete),
		similarity: {
			weighted: { sameKey, sameFingerRow: sameKey },
			unweighted: { sameKey, sameFingerRow: sameKey }
		}
	});
	const entries = [entry('near', 9, 80), entry('far', 4, 20), entry('broken', 30, 10, true)];
	const summary = (score) => RUNNER.librarySummary(entries, score, { smallGap: 2, closest: 2 });
	const small = summary(10.5);
	check(
		small.verdict === 'small_gap' && small.best.id === 'near' && small.best.gap === 1.5,
		`a gap of 1.5 points is small: ${small.verdict}, ${small.best.id}`
	);
	check(
		JSON.stringify(small.closest.map((item) => item.id)) === JSON.stringify(['near', 'far']),
		'the alike layouts come most alike first'
	);
	check(summary(15).verdict === 'optimized_ahead', 'a gap of 6 points is not small');
	check(summary(8).verdict === 'existing_better', 'an existing layout that scores more says so');
	check(summary(11).verdict === 'small_gap', 'a gap equal to the threshold is small');
}

// =============================
// ======= 5/ Robustness =======
// =============================

// The page script in a bare context (no element to mount into): its number
// formatter, the Studio's one (info_popover.js, loaded before it as the page
// loads it). A host page without a language once made toLocaleString('')
// throw a RangeError in the middle of run(), which left the page on
// « Loading the corpus… ».
{
	const warnings = [];
	const doc = {
		documentElement: { lang: '' },
		readyState: 'complete',
		currentScript: null,
		addEventListener() {},
		getElementById: () => null
	};
	const pageBox = {
		document: doc,
		location: { search: '', href: 'http://localhost/' },
		URLSearchParams,
		URL,

		console: { warn: (...args) => warnings.push(args.join(' ')), error() {}, log() {} }
	};
	pageBox.window = pageBox;
	vm.createContext(pageBox);
	const info = read(path.join(PAGE_DIR, '..', 'layout_analysis', 'info_popover.js'));
	// Still loading: the popover waits for a DOMContentLoaded that never comes.
	doc.readyState = 'loading';
	vm.runInContext(info, pageBox, { filename: 'info_popover.js' });
	doc.readyState = 'complete';
	vm.runInContext(page, pageBox, { filename: 'optimizer_page.js' });
	const PAGE = pageBox.LAYOUT_OPTIMIZER_PAGE;
	check(!/toLocaleString\(/.test(page), 'the optimizer writes its numbers itself');
	const fallback = (info.match(/const FALLBACK_LOCALE = '([a-z]+)'/) || [])[1];
	check(Boolean(fallback), 'the page names its fallback number language');
	const expect = (locale, value) =>
		Number(value).toLocaleString(locale, { minimumFractionDigits: 2, maximumFractionDigits: 2 });
	for (const lang of ['', 'not a language tag!', undefined]) {
		doc.documentElement.lang = lang;
		delete pageBox._i18n_locale;
		let written = null;
		try {
			written = PAGE.formatNumber(1234.5, 2);
		} catch (error) {
			check(false, `lang ${JSON.stringify(lang)}: the formatter throws ${error.message}`);
		}
		check(
			PAGE.numberLocale() === fallback,
			`lang ${JSON.stringify(lang)}: falls back to ${fallback}`
		);
		if (written !== null)
			check(written === expect(fallback, 1234.5), `lang ${JSON.stringify(lang)}: wrote ${written}`);
	}
	check(warnings.length === 1, `the fallback is said once in the console: ${warnings.length}`);
	doc.documentElement.lang = 'de';
	check(PAGE.formatNumber(1234.5, 2) === expect('de', 1234.5), 'the declared language writes');
	pageBox._i18n_locale = 'en';
	check(PAGE.numberLocale() === 'en', 'the strings’ language comes first');
	pageBox._i18n_locale = '';
	check(PAGE.numberLocale() === 'de', 'an empty strings’ language gives way to the declared one');

	// The library card, drawn into a small document from a real summary.
	check(typeof PAGE.libraryCard === 'function', 'the page has no library card');
	if (typeof PAGE.libraryCard === 'function' && librarySummary) {
		const opened = [];
		const card = PAGE.libraryCard(fakeDocument(), librarySummary, {
			t: (key, values) =>
				Object.entries(values || {}).reduce(
					(text, [name, value]) => text.split(`{${name}}`).join(String(value)),
					english[key]
				),
			number: (value, digits) => Number(value).toFixed(digits),
			onOpen: (entry, where) => opened.push(`${where}:${entry.id}`)
		});
		const all = descendants(card);
		const text = textOf(card);
		const best = librarySummary.best;
		const hasClass = (node, name) => (node.className || '').split(' ').includes(name);
		const verdict = all.find((node) => hasClass(node, 'lo-library-verdict'));
		check(
			Boolean(verdict) && verdict.className.includes(`lo-library-${librarySummary.verdict}`),
			`library card: no ${librarySummary.verdict} verdict`
		);
		check(
			Boolean(verdict) && textOf(verdict).includes(best.name),
			'library card: the verdict names the best existing layout'
		);
		const gauge = all.find((node) => node.className === 'lo-gauge');
		check(
			Boolean(gauge) &&
				gauge.style.props['--lo-gauge'] === String(best.similarity.weighted.sameKey) &&
				gauge.attributes['aria-hidden'] === 'true',
			'library card: the gauge shows the best layout’s similarity, hidden from assistive technology'
		);
		check(
			text.includes(
				english['layout_optimizer.library.percent'].replace(
					'{value}',
					best.similarity.weighted.sameKey.toFixed(1)
				)
			),
			'library card: the gauge’s value is also in words'
		);
		const items = all.filter((node) => hasClass(node, 'lo-library-item'));
		check(
			items.length === librarySummary.closest.length,
			`library card: ${items.length} alike layouts drawn`
		);
		librarySummary.closest.forEach((entry, i) => {
			const item = items[i];
			if (!item) return;
			const bar = descendants(item).find((node) => node.className === 'lo-bar lo-bar-key');
			check(
				Boolean(bar) && bar.style.width === `${entry.similarity.weighted.sameKey}%`,
				`library card: ${entry.id} has no similarity bar`
			);
			check(textOf(item).includes(entry.name), `library card: ${entry.id} is not named`);
			const gap = descendants(item).find((node) => hasClass(node, 'lo-gap'));
			check(
				Boolean(gap) && textOf(gap).includes(Math.abs(entry.gap).toFixed(2)),
				`library card: ${entry.id} has no score gap in words`
			);
		});
		const buttons = all.filter((node) => node.tagName === 'BUTTON');
		check(
			buttons.length === 2 * (librarySummary.closest.length + 1),
			`library card: ${buttons.length} buttons`
		);
		for (const button of buttons) {
			const name = librarySummary.closest
				.concat([best])
				.find((entry) => entry.id === button.dataset.layout).name;
			check(
				button.attributes['aria-label'].includes(name) &&
					button.attributes['aria-label'].includes(textOf(button)),
				`library card: the ${button.dataset.open} button of ${name} is not labelled`
			);
			button.click();
		}
		check(
			opened.includes(`comparer:${best.id}`) && opened.includes(`editor:${best.id}`),
			`library card: the buttons open nothing: ${opened.join(', ')}`
		);
	}
}
// Every runner message goes through receive, which ends a run it cannot show.
check(
	/function receive\([^)]*\) \{\s*try \{\s*handle\(/.test(page) &&
		/catch \(error\) \{\s*if \(state\.running === running\) failRun\('result', error\)/.test(page),
	'a runner message the page cannot show ends the run (failRun)'
);
check(
	/async function run\(\) \{[\s\S]{0,400}try \{\s*await runStages\([\s\S]{0,120}catch \(error\) \{\s*failRun\(stage, error\)/.test(
		page
	),
	'run() ends every failing stage in failRun'
);
// The library is compared once the final layout is shown, off the page's
// thread where a worker starts.
check(
	/showBest\(winner\.layout, winner\.score, true, true\);\s*finish\(running, began, null\);\s*scanLibrary\(winner\.layout, winner\.score\);/.test(
		page
	),
	'the final layout is compared with the library'
);
check(
	/message\.type === 'library'[\s\S]{0,160}LAYOUT_OPTIMIZER_RUNNER\.scoreLibrary\(/.test(worker),
	'the worker scores the library'
);

if (errors.length) {
	console.error(`FAIL test-layout-optimizer-page: ${errors.length} problem(s)`);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}
console.log(`PASS test-layout-optimizer-page (${keys.size} keys in ${locales.length} locales)`);
