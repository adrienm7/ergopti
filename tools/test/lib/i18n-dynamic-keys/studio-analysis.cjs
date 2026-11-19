// tools/test/lib/i18n-dynamic-keys/studio-analysis.cjs

/**
 * ==============================================================================
 * MODULE: Studio Analysis Key Families
 * DESCRIPTION:
 * The key families the layout analysis pages build at run time: the Comparer
 * (comparer_page.js), the editor's analysis panel and its boards, the info
 * popovers, the fingering editor, the corpus picker and the Optimiser. Each is
 * enumerated from what the page reads: the generated analysis data, the
 * engine's and the analysers' globals, a page table, or the literal choices a
 * site writes (a ternary's arms, a loop's array), never from a catalogue.
 * ==============================================================================
 */

'use strict';

const ctx = require('./context.cjs');

const UI = 'static/ergopti_plus/_shared/ui/';
const LA = UI + 'layout_analysis/';
const LO = UI + 'layout_optimizer/';
const PANEL = LA + 'analysis_panel.js';
const COMPARER = LA + 'comparer_page.js';
const ENGINE = LA + 'analysis_engine.js';
const POPOVER = LA + 'info_popover.js';
const FINGERING = LA + 'fingering_editor.js';
const ANALYSER_TAB = LA + 'analyser_tab.js';
const CORPUS = LA + 'corpus_files.js';
const WORST = LA + 'board/worst_groups.js';
const SWAPS = LA + 'board/best_swaps.js';
const IMAGE = LA + 'board/board_image.js';
const EDITOR = UI + 'layout_editor/editor_page.js';
const OPTIMIZER = LO + 'optimizer_page.js';
const OPTIMIZER_CORE = LO + 'optimizer_core.js';
const OPTIMIZER_RUNNER = LO + 'optimizer_runner.js';
// The data and model scripts of the analysis pages, in page order: they only
// define their globals at load.
const MODEL = [LA + '_generated/analysis_data.js', ENGINE];
const SCORES = MODEL.concat([LA + 'analyser_scores.js']);

const data = () => ctx.page(MODEL, 'LAYOUT_ANALYSIS_DATA');
const engine = () => ctx.page(MODEL, 'LAYOUT_ANALYSIS');
const analysers = () => ctx.page(SCORES, 'LAYOUT_ANALYSER_SCORES.analysers()');
const weightGroups = () => ctx.literal(COMPARER, 'WEIGHT_GROUPS');
const weightIds = () => Object.values(weightGroups()).flat();

/**
 * The single-quoted strings of a source text.
 * @param {string} text - Source text.
 * @returns {string[]}
 */
function quoted(text) {
	return Array.from(text.matchAll(/'([^'\\]*)'/g), (m) => m[1]);
}

/**
 * The first capture of a pattern in a file, which must match: a site whose
 * shape changed fails here instead of leaving its family short.
 * @param {string} rel - Repository-relative path.
 * @param {RegExp} pattern - A pattern with one capture.
 * @returns {string}
 */
function capture(rel, pattern) {
	const m = pattern.exec(ctx.read(rel));
	if (!m) throw new Error(`${rel}: ${pattern} matches nothing`);
	return m[1];
}

/**
 * The value of a `const NAME = 'value'` string constant of a file.
 * @param {string} rel - Repository-relative path.
 * @param {string} name - The constant's name.
 * @returns {string}
 */
function constString(rel, name) {
	return capture(rel, new RegExp(`const ${name} = '([^']+)';`));
}

/**
 * Both arms of every literal ternary a template key writes after its head
 * (`head${cond ? 'a' : 'b'}tail`), the head spelt as in the source.
 * @param {string} rel - Repository-relative path.
 * @param {string} head - The template's text before `${`.
 * @param {string} [tail] - The template's text after the ternary.
 * @returns {string[]}
 */
function ternaryArms(rel, head, tail = '') {
	const escape = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	const pattern = new RegExp(
		'`' + escape(head) + "\\$\\{[^`?]*\\? '(\\w+)' : '(\\w+)'\\}" + escape(tail) + '`',
		'g'
	);
	const arms = Array.from(ctx.read(rel).matchAll(pattern), (m) => [m[1], m[2]]).flat();
	if (arms.length === 0) throw new Error(`${rel}: no ternary key after ${head}`);
	return [...new Set(arms)];
}

/**
 * The strings of every literal array a `for (const VAR of [...])` loop of a
 * file walks.
 * @param {string} rel - Repository-relative path.
 * @param {string} name - The loop variable.
 * @returns {string[]}
 */
function loopArrays(rel, name) {
	return [
		...new Set(
			ctx
				.matches(rel, new RegExp(`for \\(const ${name} of (\\[[^\\]]*\\])\\)`, 'g'))
				.flatMap(quoted)
		)
	];
}

/**
 * The ids a family suffixes, each with every ending a site appends.
 * @param {string} prefix - The family head.
 * @param {string[]} ids - The ids.
 * @param {string[]} endings - What the sites write after the id.
 * @returns {string[]}
 */
function withEndings(prefix, ids, endings) {
	return ids.flatMap((id) => endings.map((ending) => prefix + id + ending));
}

/**
 * The formula each info item's popover quotes, as info_popover.js formulaOf
 * picks it from its tables and the metrics' `of`.
 * @returns {string[]}
 */
function formulas() {
	const metrics = engine().METRICS;
	const own = ctx.literal(POPOVER, 'OWN_FORMULAS');
	const shares = ctx.literal(POPOVER, 'SHARE_FORMULAS');
	const scoreItem = constString(POPOVER, 'SCORE_ITEM');
	const found = new Set();
	for (const item of Object.keys(data().sources.items)) {
		if (item === scoreItem) found.add(constString(POPOVER, 'SCORE_FORMULA'));
		else if (!Object.hasOwn(metrics, item)) continue;
		else if (own.includes(item)) found.add(item);
		else if (shares.includes(metrics[item].of)) found.add(metrics[item].of);
		else throw new Error(`info_popover.js: metric ${item} has no formula`);
	}
	return [...found];
}

/**
 * Every metric id a site names: the engine's metrics and key lists, and the
 * tables the pages walk (a list that held a non-metric would fail as a key).
 * @returns {string[]}
 */
function metricIds() {
	const E = engine();
	// The trigram classes the Comparer names with its own labels instead.
	const ownLabels = Array.from(
		capture(COMPARER, /const trigramLabel = \{([^}]*)\}/).matchAll(/(\w+):/g),
		(m) => m[1]
	);
	const heats = [constString(COMPARER, 'HEAT_PRESSES'), constString(COMPARER, 'HEAT_SCORE')];
	return [
		...Object.keys(E.METRICS),
		...E.KEY_EVENTS,
		...E.KEY_COST_METRICS,
		...E.KEY_GAINS,
		...E.KEY_INFO_METRICS,
		...E.KEY_METRICS.filter((id) => !heats.includes(id)),
		...E.WORD_EFFORT_METRICS,
		...Object.keys(E.defaultWeights()),
		...weightIds(),
		...ctx.literal(WORST, 'EVENTS'),
		...ctx.literal(PANEL, 'PANEL_METRICS'),
		...ctx.literal(OPTIMIZER, 'DELTA_METRICS'),
		...ctx.literal(COMPARER, 'BIGRAM_CLASSES'),
		...ctx.literal(COMPARER, 'TRIGRAM_CLASSES').filter((id) => !ownLabels.includes(id)),
		// The hands figure's row bars (renderResult).
		...quoted(
			capture(
				COMPARER,
				/(\[[^\]]*\])\.map\(\(id\) => \(\{\s*label: t\(`layout_analysis\.metric\.\$\{id\}`\)/
			)
		)
	];
}

/**
 * The verdicts the pages word: the arms the panel and the Optimiser choose
 * from, the Comparer's marked verdicts (relativeCell marks), the editor's
 * score chip verdict.
 * @returns {string[]}
 */
function verdicts() {
	const head = 'layout_analysis.details.verdict_';
	const marks = capture(COMPARER, /const marks = \{([^}]*)\}/);
	return [
		...ternaryArms(PANEL, head),
		...ternaryArms(OPTIMIZER, head),
		// A verdict marked with nothing ('') is not worded.
		...Array.from(marks.matchAll(/(\w+): '([^']+)'/g), (m) => m[1]),
		...quoted(capture(EDITOR, /const verdict = (!moved \?[^;]*);/))
	];
}

module.exports = [
	{
		prefix: 'layout_analysis.analysers.better.',
		files: [PANEL],
		source: 'the better direction of each LAYOUT_ANALYSER_SCORES.analysers() entry',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.analysers.better.',
				analysers().map((a) => a.better)
			)
	},
	{
		prefix: 'layout_analysis.analysers.part.',
		files: [ANALYSER_TAB, PANEL],
		source: 'the headline parts of each LAYOUT_ANALYSER_SCORES.analysers() entry',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.analysers.part.',
				analysers().flatMap((a) => a.headline)
			)
	},
	{
		prefix: 'layout_analysis.corpus.kind.',
		files: [CORPUS],
		source: 'the kind of each LAYOUT_ANALYSIS_DATA.corpora entry',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.corpus.kind.',
				data().corpora.map((corpus) => corpus.kind)
			)
	},
	{
		prefix: 'layout_analysis.details.',
		files: [COMPARER],
		source: 'the typing table headers comparer_page.js renderTyping loops over',
		keys: () => ctx.keysOf('layout_analysis.details.', loopArrays(COMPARER, 'key'))
	},
	{
		prefix: 'layout_analysis.details.verdict_',
		files: [PANEL, COMPARER, EDITOR, OPTIMIZER],
		source: 'the verdict ternaries, the Comparer relativeCell marks and the editor chip verdict',
		keys: () => ctx.keysOf('layout_analysis.details.verdict_', verdicts())
	},
	{
		prefix: 'layout_analysis.error.',
		files: [POPOVER],
		source: 'every literal new AnalysisError code of analysis_engine.js',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.error.',
				ctx.matches(ENGINE, /new AnalysisError\(\s*'([a-z_]+)'/g)
			)
	},
	{
		prefix: 'layout_analysis.finger.',
		files: [PANEL, COMPARER, FINGERING],
		source: 'LAYOUT_ANALYSIS_DATA.model.fingers and the engine ideal load fingers',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.finger.',
				data().model.fingers.concat(Object.keys(engine().defaultIdealLoad()))
			)
	},
	{
		prefix: 'layout_analysis.fingering.base_',
		files: [FINGERING],
		source: 'fingering_editor.js BASES',
		keys: () => ctx.keysOf('layout_analysis.fingering.base_', ctx.literal(FINGERING, 'BASES'))
	},
	{
		prefix: 'layout_analysis.format.',
		files: [COMPARER, EDITOR],
		source: 'the ids of LAYOUT_ANALYSIS.keyboardFormats()',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.format.',
				engine()
					.keyboardFormats()
					.map((format) => format.id)
			)
	},
	{
		prefix: 'layout_analysis.forms.',
		files: [COMPARER],
		source: 'the form factors of LAYOUT_ANALYSIS.defaultFormFactorWeights()',
		keys: () =>
			ctx.keysOf('layout_analysis.forms.', Object.keys(engine().defaultFormFactorWeights()))
	},
	{
		prefix: 'layout_analysis.formula.',
		files: [POPOVER],
		source: 'info_popover.js formulaOf over LAYOUT_ANALYSIS_DATA.sources.items',
		keys: () => ctx.keysOf('layout_analysis.formula.', formulas())
	},
	{
		prefix: 'layout_analysis.image.',
		files: [IMAGE],
		source: 'board_image.js FORMATS',
		keys: () => ctx.keysOf('layout_analysis.image.', Object.keys(ctx.literal(IMAGE, 'FORMATS')))
	},
	{
		prefix: 'layout_analysis.info.',
		files: [COMPARER, POPOVER],
		source: 'LAYOUT_ANALYSIS_DATA.sources.items, info_popover.js ALSO_EXPLAINS, WEIGHT_GROUPS ids',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.info.',
				Object.keys(data().sources.items)
					.concat(Object.values(ctx.literal(POPOVER, 'ALSO_EXPLAINS')).flat())
					.concat(weightIds())
			)
	},
	{
		prefix: 'layout_analysis.keyboard.',
		files: [PANEL, COMPARER, OPTIMIZER],
		source: 'the keys of LAYOUT_ANALYSIS_DATA.model.keyboards',
		keys: () => ctx.keysOf('layout_analysis.keyboard.', Object.keys(data().model.keyboards))
	},
	{
		prefix: 'layout_analysis.matrix.by_',
		files: [COMPARER],
		source: 'comparer_page.js MATRIX_CHOICES',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.matrix.by_',
				capture(COMPARER, /const MATRIX_CHOICES = \[([^\]]*)\]/)
					.split(',')
					.map((name) => constString(COMPARER, name.trim()))
			)
	},
	{
		prefix: 'layout_analysis.metric.',
		files: [PANEL, WORST, COMPARER, POPOVER, OPTIMIZER],
		source: 'LAYOUT_ANALYSIS.METRICS, its key and weight lists, and the pages metric tables',
		keys: () => ctx.keysOf('layout_analysis.metric.', metricIds())
	},
	{
		prefix: 'layout_analysis.mine.',
		files: [COMPARER],
		source: 'the actions comparer_page.js calls mineButton with',
		keys: () =>
			withEndings('layout_analysis.mine.', ctx.callArguments(COMPARER, 'mineButton'), [
				'',
				'_named'
			])
	},
	{
		prefix: 'layout_analysis.panel.heat.',
		files: [PANEL],
		source: 'the analysis_panel.js heat constants heatName words with the panel family',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.panel.heat.',
				capture(
					PANEL,
					/if \((id === \w+ \|\| id === \w+)\) return t\(`layout_analysis\.panel\.heat\./
				)
					.split('||')
					.map((test) => constString(PANEL, test.replace('id ===', '').trim()))
			)
	},
	{
		prefix: 'layout_analysis.presets.',
		files: [COMPARER],
		source: 'the ids of score_settings.js PRESETS',
		keys: () =>
			withEndings(
				'layout_analysis.presets.',
				ctx.literal(LA + 'score_settings.js', 'PRESETS').map((preset) => preset.id),
				['.name', '.help']
			)
	},
	{
		prefix: 'layout_analysis.simplicity.',
		files: [COMPARER],
		source: 'the rules analysis_engine.js simplicity() returns',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.simplicity.',
				Array.from(
					capture(
						ENGINE,
						/const rules = \{([^}]*)\};\s*const values = Object\.values\(rules\)/
					).matchAll(/(\w+):/g),
					(m) => m[1]
				)
			)
	},
	{
		prefix: 'layout_analysis.swaps.',
		files: [SWAPS],
		source: 'the ternary arms of best_swaps.js',
		keys: () => ctx.keysOf('layout_analysis.swaps.', ternaryArms(SWAPS, 'layout_analysis.swaps.'))
	},
	{
		prefix: 'layout_analysis.text_mode.info_',
		files: [COMPARER],
		source: 'corpus_files.js TEXT_MODES',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.text_mode.info_',
				Object.values(ctx.literal(CORPUS, 'TEXT_MODES'))
			)
	},
	{
		prefix: 'layout_analysis.typing.',
		files: [COMPARER],
		source: 'the kinds analysis_engine.js typingReport kind() returns',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.typing.',
				quoted(capture(ENGINE, /const kind = \(way\) => \{([\s\S]*?)\n\t\t\};/))
			)
	},
	{
		prefix: 'layout_analysis.weights.group.',
		files: [COMPARER],
		source: 'the groups of comparer_page.js WEIGHT_GROUPS',
		keys: () => ctx.keysOf('layout_analysis.weights.group.', Object.keys(weightGroups()))
	},
	{
		prefix: 'layout_analysis.weights.group_help.',
		files: [COMPARER],
		source: 'the groups of comparer_page.js WEIGHT_GROUPS',
		keys: () => ctx.keysOf('layout_analysis.weights.group_help.', Object.keys(weightGroups()))
	},
	{
		prefix: 'layout_analysis.weights.per_',
		files: [COMPARER],
		source: 'LAYOUT_ANALYSIS.METRICS better of each WEIGHT_GROUPS metric',
		keys: () =>
			ctx.keysOf(
				'layout_analysis.weights.per_',
				weightIds().map((id) => engine().METRICS[id].better)
			)
	},
	{
		prefix: 'layout_analysis.worst.',
		files: [WORST],
		source: 'the ternary arms of worst_groups.js',
		keys: () => ctx.keysOf('layout_analysis.worst.', ternaryArms(WORST, 'layout_analysis.worst.'))
	},
	{
		prefix: 'layout_optimizer.error.',
		files: [OPTIMIZER],
		source: 'every literal new OptimizerError code of optimizer_core.js',
		keys: () =>
			ctx.keysOf(
				'layout_optimizer.error.',
				ctx.matches(OPTIMIZER_CORE, /new OptimizerError\(\s*'([a-z_]+)'/g)
			)
	},
	{
		prefix: 'layout_optimizer.library.gap_',
		files: [OPTIMIZER],
		source: 'the sides optimizer_page.js libraryCard gapChip chooses',
		keys: () =>
			ctx.keysOf(
				'layout_optimizer.library.gap_',
				quoted(capture(OPTIMIZER, /const side = ([^;]*);/))
			)
	},
	{
		prefix: 'layout_optimizer.library.open_',
		files: [OPTIMIZER],
		source: 'the where arrays optimizer_page.js loops over for its open buttons',
		keys: () =>
			withEndings('layout_optimizer.library.open_', loopArrays(OPTIMIZER, 'where'), ['', '_label'])
	},
	{
		prefix: 'layout_optimizer.library.verdict.',
		files: [OPTIMIZER],
		source: 'the verdicts optimizer_runner.js librarySummary returns',
		keys: () =>
			ctx.keysOf(
				'layout_optimizer.library.verdict.',
				quoted(capture(OPTIMIZER_RUNNER, /const verdict =([^;]*);/))
			)
	},
	{
		prefix: 'layout_optimizer.option.',
		files: [OPTIMIZER],
		source: 'optimizer_page.js SWITCHES',
		keys: () =>
			withEndings('layout_optimizer.option.', ctx.literal(OPTIMIZER, 'SWITCHES'), [
				'.label',
				'.help'
			])
	},
	{
		prefix: 'layout_optimizer.qwerty.preset.',
		files: [OPTIMIZER],
		source: 'optimizer_core.js QWERTY_PIN_PRESETS',
		keys: () =>
			ctx.keysOf(
				'layout_optimizer.qwerty.preset.',
				Object.keys(ctx.literal(OPTIMIZER_CORE, 'QWERTY_PIN_PRESETS'))
			)
	},
	{
		prefix: 'layout_optimizer.settings.',
		files: [OPTIMIZER],
		source: 'the ternary arms of optimizer_page.js drawSettings',
		keys: () =>
			ctx.keysOf('layout_optimizer.settings.', ternaryArms(OPTIMIZER, '${PREFIX}settings.'))
	},
	{
		prefix: 'layout_optimizer.status.',
		files: [OPTIMIZER],
		source: 'the ternary arms of optimizer_page.js run end status',
		keys: () => ctx.keysOf('layout_optimizer.status.', ternaryArms(OPTIMIZER, '${PREFIX}status.'))
	}
];
