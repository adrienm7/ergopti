// tools/test/test-layout-analysis-engine.cjs

/**
 * ==============================================================================
 * MODULE: Layout Analysis Engine Gate
 * DESCRIPTION:
 * _shared/ui/layout_analysis/analysis_engine.js measures a layout on n-gram
 * counts for the site's /studio page and the app's Ergopti Studio. This gate
 * holds it to the definitions of docs/design/layout-analysis.md.
 *
 * WHAT IS CHECKED:
 * 1. Metrics: every reference vector of
 *    _shared/tests/corpus/layout_analysis/metric_vectors.json gives the value
 *    computed by hand from its definition, and the per-key heatmap data blames
 *    the keys of each event.
 * 2. Exact keystrokes: the key n-grams rebuilt from character n-gram tables
 *    equal those counted on the expanded key stream of the text itself.
 * 3. Score: each contribution is sign × weight × value, the total their sum,
 *    weights override the defaults without changing them, rescoring re-ranks
 *    without re-analysis, and an unknown or invalid weight throws.
 * 4. Library: about a hundred layouts with unique ids, every registry layout
 *    with its dead keys, and the reference QWERTY as its source says.
 * 5. Speed: the whole library on a 2.5 MB corpus, from prepared tables, well
 *    under a second.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const DATA_PATH = shared('ui', 'layout_analysis', '_generated', 'analysis_data.js');
const ENGINE_PATH = shared('ui', 'layout_analysis', 'analysis_engine.js');
const VECTORS_PATH = shared('tests', 'corpus', 'layout_analysis', 'metric_vectors.json');
const REGISTRY_INDEX = path.join(REPO_ROOT, 'static', 'layouts', 'registry', 'index.json');
const SPEED_CORPUS = path.join(
	REPO_ROOT,
	'static',
	'corpus',
	'original',
	'fr',
	'corpus_nemolivier.txt'
);

// Floors: an empty library or vector file must not read as a pass.
const MIN_VECTORS = 20;
const MIN_LIBRARY = 100;
// Budget for the whole library on the speed corpus, from prepared tables. The
// measured time is about 0.3 s; the budget leaves room for a slow CI runner.
const SPEED_BUDGET_MS = 1500;
const TOLERANCE = 1e-6;

const errors = [];
const check = (condition, message) => {
	if (!condition) errors.push(message);
};
const near = (a, b) => Math.abs(a - b) <= TOLERANCE * Math.max(1, Math.abs(b));

const sandbox = {};
vm.createContext(sandbox);
for (const file of [DATA_PATH, ENGINE_PATH])
	vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const library = E.libraryLayouts();
const byId = new Map(library.map((layout) => [layout.id, layout]));

// ==========================
// ======= 1/ Metrics =======
// ==========================

const vectors = JSON.parse(fs.readFileSync(VECTORS_PATH, 'utf8')).vectors;
check(vectors.length >= MIN_VECTORS, `only ${vectors.length} metric vectors`);
let compared = 0;
for (const vector of vectors) {
	const layout = byId.get(vector.layout);
	check(layout, `${vector.name}: no layout ${vector.layout}`);
	if (!layout) continue;
	const result = E.analyse(layout, E.ngramsFromText(vector.text), { keyboard: vector.keyboard });
	for (const [metric, expected] of Object.entries(vector.expect)) {
		check(metric in E.METRICS, `${vector.name}: unknown metric ${metric}`);
		const got = result.metrics[metric];
		check(near(got, expected), `${vector.name}: ${metric} = ${got}, expected ${expected}`);
		compared++;
	}
}

// The heatmap's per-key data: both keys of an SFB carry it, each names the other.
const heat = E.analyse(byId.get('qwerty'), E.ngramsFromText('ed'), { keyboard: 'iso' }).keys;
check(heat.KeyE.sfb === 100 && heat.KeyD.sfb === 100, 'keys: both keys of "ed" carry the SFB');
check(heat.KeyE.sfbWith[0][0] === 'KeyD', 'keys: KeyE names KeyD as its SFB partner');
check(heat.KeyF.sfb === 0 && heat.KeyE.presses === 50, 'keys: other keys carry nothing');

// =====================================
// ======= 2/ Exact key n-grams ========
// =====================================

/**
 * Counts SFBs and alternations on the expanded key stream of a text, the
 * definition the tables must reproduce.
 */
function streamCounts(layout, text, keyboardId) {
	const board = E.keyboard(keyboardId);
	const best = E.compileLayout(layout, board, null);
	const thumb = (k) => board.finger[k] === 4 || board.finger[k] === 5;
	const counts = { bigrams: 0, sfb: 0, trigrams: 0, alternation: 0, sfs: 0 };
	for (const segment of text.split(/[\r\n\t]+/)) {
		const keys = [];
		const flush = () => {
			for (let i = 0; i + 1 < keys.length; i++) {
				const [a, b] = [keys[i], keys[i + 1]];
				if (thumb(a) || thumb(b)) continue;
				counts.bigrams++;
				if (a !== b && board.finger[a] === board.finger[b]) counts.sfb++;
			}
			for (let i = 0; i + 2 < keys.length; i++) {
				const [a, b, c] = [keys[i], keys[i + 1], keys[i + 2]];
				if (thumb(a) || thumb(b) || thumb(c)) continue;
				counts.trigrams++;
				if (board.finger[a] === board.finger[c] && a !== c) counts.sfs++;
				const sameFinger =
					board.finger[a] === board.finger[b] || board.finger[b] === board.finger[c];
				if (!sameFinger && board.hand[a] !== board.hand[b] && board.hand[b] !== board.hand[c])
					counts.alternation++;
			}
			keys.length = 0;
		};
		for (const char of Array.from(segment)) {
			const seq = best.get(char);
			// An unsupported character cuts the stream, as it cuts the tables.
			if (!seq) flush();
			else keys.push(...seq.keys);
		}
		flush();
	}
	return counts;
}

const STREAM_TEXT =
	'À l’été, ça bêêle : « où êtes-vous ? » Ô déjà-vu, Noël à Ïle-de-France ; naïf cœur, ' +
	'l’âme sœur dîne. The quick brown fox jumps over the lazy dog.';
for (const id of ['azerty', 'bepo', 'ergol', 'ergopti_plus', 'qwerty']) {
	const layout = byId.get(id);
	const expected = streamCounts(layout, STREAM_TEXT, 'iso');
	const result = E.analyse(layout, E.ngramsFromText(STREAM_TEXT), { keyboard: 'iso' });
	check(
		result.coverage.bigrams === expected.bigrams,
		`${id}: ${result.coverage.bigrams} key bigrams from tables, ${expected.bigrams} on the stream`
	);
	check(
		result.coverage.trigrams === expected.trigrams,
		`${id}: ${result.coverage.trigrams} key trigrams from tables, ${expected.trigrams} on the stream`
	);
	const pct = (part, whole) => (whole > 0 ? (100 * part) / whole : 0);
	check(
		near(result.metrics.sfb, pct(expected.sfb, expected.bigrams)),
		`${id}: SFB differs from the stream`
	);
	check(
		near(result.metrics.sfs, pct(expected.sfs, expected.trigrams)),
		`${id}: SFS differs from the stream`
	);
	check(
		near(result.metrics.alternation, pct(expected.alternation, expected.trigrams)),
		`${id}: alternation differs from the stream`
	);
}
check(
	E.analyse(byId.get('ergol'), E.ngramsFromText('été'), {}).metrics.dead_key_usage > 0,
	'Ergo-L types é with its dead key: the stream test needs a dead key'
);

// ========================
// ======= 3/ Score =======
// ========================

const ngrams = E.ngramsFromText(STREAM_TEXT);
const result = E.analyse(byId.get('ergopti'), ngrams, {});
const defaults = E.defaultWeights();
let sum = 0;
for (const [metric, weight] of Object.entries(defaults)) {
	const sign = E.METRICS[metric].better === 'higher' ? 1 : -1;
	check(
		near(result.score.contributions[metric], sign * weight * result.metrics[metric]),
		`score: contribution of ${metric}`
	);
	sum += result.score.contributions[metric];
}
check(near(result.score.total, sum), 'score: the total is the sum of the contributions');
const custom = E.score(result, { sfb: 0 });
check(custom.contributions.sfb === 0, 'score: a zero weight removes the metric');
check(
	near(custom.total, sum - result.score.contributions.sfb),
	'score: only the changed weight moves'
);
check(
	E.defaultWeights().sfb === defaults.sfb,
	'score: a custom weight leaves the defaults unchanged'
);
for (const bad of [{ nonsense: 1 }, { repeat: 1 }, { sfb: -1 }, { sfb: Infinity }]) {
	let threw = false;
	try {
		E.score(result, bad);
	} catch {
		threw = true;
	}
	check(threw, `score: ${JSON.stringify(bad)} must throw`);
}
const ranked = E.compare([byId.get('qwerty'), byId.get('ergopti')], ngrams, {});
check(ranked[0].layout.id === 'ergopti' && ranked[0].rank === 1, 'compare: Ergopti beats QWERTY');
const flipped = E.rescore(ranked, Object.fromEntries(Object.keys(defaults).map((m) => [m, 0])));
check(
	flipped.every((r) => r.score.total === 0),
	'rescore: all-zero weights give every layout zero'
);

// ==========================
// ======= 4/ Library =======
// ==========================

check(library.length >= MIN_LIBRARY, `library: only ${library.length} layouts`);
check(byId.size === library.length, 'library: duplicate ids');
const registry = JSON.parse(fs.readFileSync(REGISTRY_INDEX, 'utf8')).layouts;
for (const entry of registry) {
	const layout = byId.get(entry.id);
	check(layout && layout.origin === 'registry', `library: registry layout ${entry.id} is missing`);
}
check(Object.keys(byId.get('bepo').dead).length > 0, 'library: Bépo keeps its dead keys');
check(byId.get('qwerty').rows.KeyQ[0] === 'q', 'library: QWERTY types q on KeyQ');
// Credits: a registry layout from its meta.toml, another from layout_credits.json.
check(
	byId.get('bepo').authors[0] === 'bépo community (bepo.fr)',
	'library: bépo is not credited from its meta.toml'
);
check(byId.get('dvorak').authors.includes('August Dvorak'), 'library: Dvorak is not credited');
check(
	library.every((layout) => layout.authors.length > 0 || layout.source !== ''),
	'library: a layout has neither an author nor a source'
);
check(byId.get('azerty').rows.KeyQ[0] === 'a', 'library: AZERTY types a on KeyQ');
for (const layout of library) {
	const r = E.analyse(layout, ngrams, {});
	check(Number.isFinite(r.score.total), `library: ${layout.id} has no finite score`);
}

// ========================
// ======= 5/ Speed =======
// ========================

const prepared = E.prepareNgrams(E.ngramsFromText(fs.readFileSync(SPEED_CORPUS, 'utf8')));
const start = process.hrtime.bigint();
E.compare(library, prepared, {});
const elapsedMs = Number(process.hrtime.bigint() - start) / 1e6;
check(
	elapsedMs < SPEED_BUDGET_MS,
	`speed: ${library.length} layouts took ${elapsedMs.toFixed(0)} ms`
);

if (errors.length > 0) {
	for (const error of errors) console.error(`  ✗ ${error}`);
	console.error(`test-layout-analysis-engine: ${errors.length} problem(s)`);
	process.exit(1);
}
console.log(
	`test-layout-analysis-engine: OK (${vectors.length} vectors, ${compared} values, ` +
		`${library.length} layouts in ${elapsedMs.toFixed(0)} ms)`
);
