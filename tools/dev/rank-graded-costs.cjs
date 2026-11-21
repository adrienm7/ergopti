// tools/dev/rank-graded-costs.cjs

/**
 * ==============================================================================
 * MODULE: Graded Costs Ranking Impact
 * DESCRIPTION:
 * A maintainer tool, never run in CI: ranks the whole layout library twice on
 * the Studio's main corpora, once by the flat model (the single weights of
 * before 2026-11-21: LAYOUT_ANALYSIS.flatGrades(), row_jump and hand_run at
 * 0) and once
 * by a graded scale (score_weights.json's shipped one, or a candidate file),
 * and prints the comparison as Markdown: each corpus's top 30 by the graded
 * scale beside its flat rank, Ergopti's layouts, the largest moves and the
 * rank correlation. docs/audits/layout-analysers/graded-costs-ranking.md is
 * written from its output.
 *
 * FEATURES & RATIONALE:
 * 1. Each model is a whole analysis, not a rescore: the ways of typing choose
 *    by the default weights and grades, so each model runs in its own engine
 *    whose generated data carries that model as its defaults.
 * 2. The board is the Comparer's default (ISO), the format its default, the
 *    library every layout of the generated data (783 on 2026-11-21).
 * 3. A candidate (--candidate=<file>, a score_weights.json-shaped file) gives
 *    the weights and grades of the graded model before they ship; without
 *    one, the shipped defaults are the graded model.
 *
 * Usage:
 *   node tools/dev/rank-graded-costs.cjs [--candidate=<file>] [--corpora=<id,...>]
 *        [--top=<n>] [--all]
 *   --all adds every layout's flat and graded score on each corpus.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const vm = require('vm');
const { shared } = require('../lib/paths.cjs');

const UI = shared('ui');
const LA = path.join(UI, 'layout_analysis');
const SCRIPTS = [
	path.join(UI, '_generated', 'key_legend.js'),
	path.join(LA, '_generated', 'analysis_data.js'),
	path.join(LA, 'analysis_engine.js')
];
// The Comparer's default corpus (the first of corpora.json) and the largest
// French and English texts of each kind the Studio ships.
const DEFAULT_CORPORA = [
	'fr_don_quichotte',
	'fr_wikipedia_1m',
	'en_don_quixote',
	'en_wikipedia_1m'
];
const DEFAULT_TOP = 30;
const KEYBOARD = 'iso';
// The layouts whose ranks the report follows: Ergopti's own.
const OWN_LAYOUT = /^ergopti/;
// How many of the largest moves up and down each corpus lists.
const MOVERS = 8;
// The metrics whose points the graded costs change.
const GRADED_METRICS = ['sfb', 'row_jump', 'distance', 'hand_run'];

// ===========================
// ======= 1/ Engines ========
// ===========================

/**
 * An engine whose defaults are one model, with a corpus's tables loaded.
 * @param {function(object, object): void} patch - Rewrites the generated data
 *   (LAYOUT_ANALYSIS_DATA) and receives the engine, before any analysis.
 * @param {string} corpus - A corpus id.
 * @returns {{E: object, tables: object}}
 */
function engine(patch, corpus) {
	const sandbox = {};
	vm.createContext(sandbox);
	for (const file of SCRIPTS.concat([path.join(LA, '_generated', `corpus_${corpus}.js`)]))
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
	patch(vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox), E);
	const tables = vm.runInContext(`LAYOUT_ANALYSIS_CORPORA[${JSON.stringify(corpus)}]`, sandbox);
	if (!tables) throw new Error(`rank-graded-costs: no corpus ${corpus}`);
	return { E, tables };
}

/** The flat model: every grade flat, row_jump and hand_run at 0. */
function flatModel(data, E) {
	data.grades = E.flatGrades();
	data.weights.row_jump = 0;
	data.weights.hand_run = 0;
}

/**
 * The graded model: a candidate file's weights, floors and grades, or the
 * shipped defaults.
 * @param {string|null} file - A score_weights.json-shaped file.
 * @returns {function(object): void}
 */
function gradedModel(file) {
	if (!file) return () => {};
	const candidate = JSON.parse(fs.readFileSync(file, 'utf8'));
	for (const key of ['weights', 'floors', 'grades'])
		if (!candidate[key] || typeof candidate[key] !== 'object')
			throw new Error(`rank-graded-costs: ${file} has no ${key}`);
	return (data) => {
		data.weights = candidate.weights;
		data.floors = candidate.floors;
		data.grades = candidate.grades;
	};
}

/**
 * The library ranked by one model on one corpus.
 * @returns {Map<string, {rank: number, score: number, name: string, incomplete: boolean}>}
 */
function ranking(patch, corpus) {
	const { E, tables } = engine(patch, corpus);
	const table = E.prepareNgrams(tables);
	const results = E.rank(
		E.libraryLayouts().map((layout) => E.analyse(layout, table, { keyboard: KEYBOARD }))
	);
	return new Map(
		results.map((r) => [
			r.layout.id,
			{
				rank: r.rank,
				score: r.score.total,
				name: r.layout.name,
				incomplete: r.incomplete,
				contributions: r.score.contributions
			}
		])
	);
}

// ===========================
// ======= 2/ Report =========
// ===========================

/** Spearman's rank correlation of two rankings of the same layouts. */
function spearman(a, b) {
	const n = a.size;
	let sum = 0;
	for (const [id, entry] of a) sum += (entry.rank - b.get(id).rank) ** 2;
	return 1 - (6 * sum) / (n * (n * n - 1));
}

/** A signed rank move, « +3 » up, « −2 » down, « = » none. */
function move(before, after) {
	const delta = before - after;
	if (delta === 0) return '=';
	return delta > 0 ? `+${delta}` : `−${-delta}`;
}

/** The Markdown of one corpus. */
function corpusReport(corpus, flat, graded, top) {
	const lines = [`### ${corpus}`, ''];
	const ids = Array.from(graded.keys());
	const byRank = ids.slice().sort((x, y) => graded.get(x).rank - graded.get(y).rank);
	const flatTop = new Set(ids.filter((id) => flat.get(id).rank <= top));
	const kept = byRank.slice(0, top).filter((id) => flatTop.has(id)).length;
	lines.push(
		`Spearman rank correlation ${spearman(flat, graded).toFixed(4)}; ${kept} of the flat top ${top} stay in the graded top ${top}.`,
		''
	);
	// What each graded metric moves, in points, over the complete layouts.
	const complete = ids.filter((id) => !graded.get(id).incomplete);
	const shift = (metric) =>
		complete.reduce(
			(sum, id) => sum + graded.get(id).contributions[metric] - flat.get(id).contributions[metric],
			0
		) / complete.length;
	lines.push(
		`Mean change of each graded metric's points over the ${complete.length} complete layouts: ${GRADED_METRICS.map((m) => `${m} ${shift(m).toFixed(2)}`).join(', ')}.`,
		''
	);
	lines.push('| Graded rank | Layout | Graded score | Flat rank | Flat score | Move |');
	lines.push('| ---: | --- | ---: | ---: | ---: | :---: |');
	for (const id of byRank.slice(0, top)) {
		const g = graded.get(id);
		const f = flat.get(id);
		lines.push(
			`| ${g.rank} | ${g.name} | ${g.score.toFixed(1)} | ${f.rank} | ${f.score.toFixed(1)} | ${move(f.rank, g.rank)} |`
		);
	}
	lines.push('', "Ergopti's layouts:", '');
	lines.push('| Layout | Graded rank | Graded score | Flat rank | Flat score | Move |');
	lines.push('| --- | ---: | ---: | ---: | ---: | :---: |');
	for (const id of byRank.filter((x) => OWN_LAYOUT.test(x))) {
		const g = graded.get(id);
		const f = flat.get(id);
		lines.push(
			`| ${g.name} | ${g.rank} | ${g.score.toFixed(1)} | ${f.rank} | ${f.score.toFixed(1)} | ${move(f.rank, g.rank)} |`
		);
	}
	const moves = complete
		.map((id) => [id, flat.get(id).rank - graded.get(id).rank])
		.sort((x, y) => y[1] - x[1] || (x[0] < y[0] ? -1 : 1));
	const named = (list) =>
		list.map(([id, d]) => `${graded.get(id).name} (${d > 0 ? '+' : '−'}${Math.abs(d)})`).join(', ');
	lines.push(
		'',
		`Largest moves up: ${named(moves.slice(0, MOVERS))}.`,
		'',
		`Largest moves down: ${named(moves.slice(-MOVERS).reverse())}.`,
		''
	);
	return lines.join('\n');
}

// ===========================
// ======= 3/ Main ===========
// ===========================

function main() {
	const arg = (name) => {
		const found = process.argv.find((a) => a.startsWith(`--${name}=`));
		return found ? found.slice(name.length + 3) : null;
	};
	const corpora = arg('corpora') ? arg('corpora').split(',') : DEFAULT_CORPORA;
	const top = arg('top') ? Number(arg('top')) : DEFAULT_TOP;
	if (!Number.isInteger(top) || top < 1)
		throw new Error('rank-graded-costs: --top is a positive integer');
	const graded = gradedModel(arg('candidate'));
	const out = [];
	const every = [];
	for (const corpus of corpora) {
		const flat = ranking(flatModel, corpus);
		const scaled = ranking(graded, corpus);
		if (flat.size !== scaled.size)
			throw new Error('rank-graded-costs: the two rankings differ in size');
		out.push(corpusReport(corpus, flat, scaled, top));
		every.push({ corpus, flat, scaled });
		console.error(`rank-graded-costs: ${corpus} ranked (${flat.size} layouts)`);
	}
	if (process.argv.includes('--all')) out.push(everyScore(every));
	process.stdout.write(`${out.join('\n')}\n`);
}

/**
 * Every layout's flat and graded score on each corpus, in the library's
 * order: the list of every score the graded scale changes (--all).
 */
function everyScore(every) {
	const lines = ['### Every layout score', ''];
	lines.push(`| Layout | ${every.map((e) => `${e.corpus} flat → graded`).join(' | ')} |`);
	lines.push(`| --- | ${every.map(() => '---:').join(' | ')} |`);
	for (const [id, entry] of every[0].flat)
		lines.push(
			`| ${entry.name} | ${every
				.map((e) => `${e.flat.get(id).score.toFixed(1)} → ${e.scaled.get(id).score.toFixed(1)}`)
				.join(' | ')} |`
		);
	lines.push('');
	return lines.join('\n');
}

main();
