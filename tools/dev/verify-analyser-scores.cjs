// tools/dev/verify-analyser-scores.cjs

/**
 * ==============================================================================
 * MODULE: Analyser Scores Fidelity Check
 * DESCRIPTION:
 * A maintainer tool, never run in CI (it needs the network or a local build of
 * an analyser): compares our reproductions of the other layout analysers
 * (_shared/ui/layout_analysis/analyser_scores.js) with the real tools on many
 * corpora and prints the gap per corpus, per layout and per analyser.
 *
 * FEATURES & RATIONALE:
 * 1. KLAnext (closed source): its own numbers, read on its site, are kept in
 *    tools/dev/analyser-reference/klanext.json; its preset texts, whose
 *    licence is unknown, are downloaded at run time and never stored in the
 *    repository. Each layout is scored twice: our library's layout (what the
 *    Studio shows) and the same layout with the keys KLAnext's own layout
 *    file places differently (the « definitions » of the reference), which
 *    isolates the formula from the layout data.
 * 2. Oxeylyzer (--oxeylyzer=<exe> --oxeylyzer-data=<dir>): runs the real REPL
 *    on our shippable corpus texts in a temporary copy of its data folder (the
 *    one it downloads on its first run), one language per text, and compares
 *    its « Score » line with ours on its ortho board. Its weights are those of
 *    the config it wrote on its first run (--oxeylyzer-config, by default
 *    beside the data folder).
 * 3. Exit status: 0 when every comparison ran, 1 when a download, a run or a
 *    parse failed. The gaps are reported, not judged: the fidelity of each
 *    analyser is recorded in docs/design/analyser-scores.md.
 *
 * Usage:
 *   node tools/dev/verify-analyser-scores.cjs [--analyser=klanext|oxeylyzer]
 *        [--verbose] [--oxeylyzer=<exe> --oxeylyzer-data=<dir>
 *        [--oxeylyzer-config=<file>]]
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const https = require('https');
const { spawnSync } = require('child_process');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const UI = shared('ui', 'layout_analysis');
const SCRIPTS = ['_generated/analysis_data.js', 'analysis_engine.js', 'analyser_scores.js'];
const KLANEXT_REFERENCE = path.join(__dirname, 'analyser-reference', 'klanext.json');
const KLANEXT_CORPUS_URL = 'https://klanext.keyboard-design.com/corpus/';
const DOWNLOAD_TIMEOUT_MS = 30000;
// Oxeylyzer's layouts that our library holds with the same 3 × 10 letter block.
const OXEYLYZER_LAYOUTS = [
	'qwerty',
	'dvorak',
	'colemak',
	'colemak_dh',
	'workman',
	'mtgap30',
	'canary',
	'semimak',
	'engram',
	'norman',
	'qgmlwy',
	'sturdy',
	'isrt',
	'hands_down',
	'boo',
	'recurva',
	'whorf',
	'noctum'
];
// Our shippable texts Oxeylyzer reads as languages (static/corpus/register.json).
const OXEYLYZER_TEXTS = {
	alice: 'static/corpus/original/en/carroll_alice_in_wonderland.txt',
	sherlock: 'static/corpus/original/en/doyle_adventures_of_sherlock_holmes.txt',
	wikien: 'static/corpus/original/en/wikipedia_en_20_articles.txt',
	pyrich: 'static/corpus/original/code/rich_13.7.1.py.txt'
};
const OXEYLYZER_TIMEOUT_MS = 600000;

const args = process.argv.slice(2);
const option = (name) => {
	const found = args.find((a) => a.startsWith(`--${name}=`));
	return found ? found.slice(name.length + 3) : null;
};
const verbose = args.includes('--verbose');
const only = option('analyser');

// =====================================
// ======= 1/ The scorers and data =====
// =====================================

const sandbox = {};
vm.createContext(sandbox);
for (const file of SCRIPTS)
	vm.runInContext(fs.readFileSync(path.join(UI, file), 'utf8'), sandbox, { filename: file });
const E = vm.runInContext('LAYOUT_ANALYSIS', sandbox);
const S = vm.runInContext('LAYOUT_ANALYSER_SCORES', sandbox);
const library = new Map(E.libraryLayouts().map((layout) => [layout.id, layout]));

/** One library layout, or an error naming it. */
function libraryLayout(id) {
	const layout = library.get(id);
	if (!layout) throw new Error(`no library layout ${id}`);
	return layout;
}

/** A UTF-8 text over HTTPS, following redirects. */
function download(url) {
	return new Promise((resolve, reject) => {
		const request = https.get(url, { timeout: DOWNLOAD_TIMEOUT_MS }, (response) => {
			if (response.statusCode >= 300 && response.statusCode < 400 && response.headers.location) {
				response.resume();
				download(new URL(response.headers.location, url).href).then(resolve, reject);
				return;
			}
			if (response.statusCode !== 200) {
				response.resume();
				reject(new Error(`${url}: HTTP ${response.statusCode}`));
				return;
			}
			const chunks = [];
			response.on('data', (chunk) => chunks.push(chunk));
			response.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
		});
		request.on('timeout', () => request.destroy(new Error(`${url}: timed out`)));
		request.on('error', reject);
	});
}

/** Mean and largest of a list of gaps, as « mean |gap| … max … ». */
function summary(values, digits, unit) {
	const abs = values.map(Math.abs);
	const mean = abs.reduce((sum, v) => sum + v, 0) / abs.length;
	return `mean |gap| ${mean.toFixed(digits)}${unit}, max ${Math.max(...abs).toFixed(digits)}${unit}`;
}

// =========================
// ======= 2/ KLAnext ======
// =========================

/** Our library layout with the keys KLAnext's own layout file places elsewhere. */
function asKlanextDefines(layout, moves) {
	const copy = JSON.parse(JSON.stringify(layout));
	for (const [, , char] of moves)
		if (char !== null)
			for (const row of Object.values(copy.rows))
				for (let k = 0; k < row.length; k++) if (row[k] === char) row[k] = null;
	for (const [code, layer, char] of moves) copy.rows[code][layer] = char;
	return copy;
}

async function verifyKlanext() {
	const reference = JSON.parse(fs.readFileSync(KLANEXT_REFERENCE, 'utf8'));
	const columns = reference.columns;
	const gaps = { library: [], defined: [] };
	const relative = [];
	for (const [preset, rows] of Object.entries(reference.presets)) {
		const text = await download(`${KLANEXT_CORPUS_URL}${encodeURIComponent(preset)}.txt`);
		const tables = E.prepareNgrams(E.ngramsFromText(text));
		for (const [id, published] of Object.entries(rows)) {
			const layout = libraryLayout(id);
			const variants = {
				library: layout,
				defined: asKlanextDefines(layout, reference.definitions[id] || [])
			};
			const line = [];
			for (const [kind, scored] of Object.entries(variants)) {
				const result = S.score('klanext', scored, tables, { keyboard: 'ansi' });
				const ours = [result.value, ...columns.slice(1).map((c) => result.parts[c])];
				ours.forEach((v, k) => gaps[kind].push(v - published[k]));
				if (kind === 'library') relative.push((100 * (ours[0] - published[0])) / published[0]);
				line.push(`${kind} ${ours.map((v) => v.toFixed(2)).join(' ')}`);
			}
			if (verbose)
				console.log(
					`  ${preset.padEnd(22)} ${id.padEnd(16)} KLAnext ${published.join(' ')} | ${line.join(' | ')}`
				);
		}
	}
	const points = relative.length;
	console.log(`KLAnext: ${points} points (${Object.keys(reference.presets).length} presets)`);
	console.log(`  library layouts, overall: ${summary(relative, 3, ' %')}`);
	console.log(`  library layouts, every column: ${summary(gaps.library, 3, '')}`);
	console.log(`  KLAnext's layout definitions, every column: ${summary(gaps.defined, 4, '')}`);
}

// ===========================
// ======= 3/ Oxeylyzer ======
// ===========================

function verifyOxeylyzer(exe, data, configFile) {
	if (!fs.existsSync(configFile)) throw new Error(`no Oxeylyzer config at ${configFile}`);
	if (!fs.existsSync(exe)) throw new Error(`no Oxeylyzer executable at ${exe}`);
	if (!fs.existsSync(path.join(data, 'static', 'layouts')))
		throw new Error(`${data} is not Oxeylyzer's data folder (no static/layouts)`);
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'oxeylyzer-'));
	try {
		fs.cpSync(data, root, { recursive: true });
		const configs = path.join(root, 'static', 'corpus_configs', 'provided');
		for (const [id, file] of Object.entries(OXEYLYZER_TEXTS)) {
			const dir = path.join(root, 'static', 'text', id);
			fs.mkdirSync(dir, { recursive: true });
			fs.copyFileSync(path.join(REPO_ROOT, file), path.join(dir, `${id}.txt`));
			fs.writeFileSync(
				path.join(configs, `${id}.toml`),
				`sources = [ "../../text/${id}" ]\n\ninherits = [ "./default.toml" ]\n`
			);
		}
		// The config it wrote on its first run (its default weights), its paths
		// pointed at the copy: its English layouts, our texts' language data.
		const toml = (p) => JSON.stringify(p.split(path.sep).join('/'));
		const paths = {
			corpus: path.join(root, 'static', 'language_data', 'english.json'),
			layouts: path.join(root, 'static', 'layouts', 'english', '*.dof'),
			corpus_configs: path.join(root, 'static', 'corpus_configs', '**', '*.toml')
		};
		let config = fs.readFileSync(configFile, 'utf8');
		for (const [key, value] of Object.entries(paths)) {
			const line = new RegExp(`^${key} = .*$`, 'm');
			if (!line.test(config)) throw new Error(`${configFile} has no ${key} line`);
			config = config.replace(line, `${key} = ${toml(value)}`);
		}
		fs.writeFileSync(path.join(root, 'config.toml'), config);
		const gaps = [];
		for (const [id, file] of Object.entries(OXEYLYZER_TEXTS)) {
			const input = [
				`load ${id}`,
				`language ${id}`,
				...OXEYLYZER_LAYOUTS.map((l) => `analyze ${l}`),
				'quit',
				''
			].join('\n');
			const run = spawnSync(exe, [], {
				input,
				env: Object.assign({}, process.env, { OXEYLYZER_DATA_DIR: root }),
				encoding: 'utf8',
				timeout: OXEYLYZER_TIMEOUT_MS,
				maxBuffer: 1 << 26
			});
			// eslint-disable-next-line no-control-regex
			const out = `${run.stdout}${run.stderr}`.replace(/\x1b\[[0-9;]*m/g, '');
			const scores = Array.from(out.matchAll(/^Score: (-?[0-9.]+)/gm), (m) => Number(m[1]));
			if (run.status !== 0 || scores.length !== OXEYLYZER_LAYOUTS.length)
				throw new Error(
					`Oxeylyzer on ${id}: ${scores.length} scores, exit ${run.status}
${out.slice(-600)}`
				);
			const tables = E.prepareNgrams(
				E.ngramsFromText(fs.readFileSync(path.join(REPO_ROOT, file), 'utf8'))
			);
			const line = OXEYLYZER_LAYOUTS.map((layout, k) => {
				const ours = S.score('oxeylyzer', libraryLayout(layout), tables, { keyboard: 'ortho' });
				gaps.push(ours.value - scores[k]);
				return `${layout} ${scores[k]}/${ours.value.toFixed(3)}`;
			});
			if (verbose) console.log(`  ${id.padEnd(9)} ${line.join('  ')}`);
		}
		console.log(`Oxeylyzer: ${gaps.length} points, Score ${summary(gaps, 4, '')}`);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

// ======================
// ======= 4/ Main ======
// ======================

async function main() {
	if (!only || only === 'klanext') await verifyKlanext();
	if (!only || only === 'oxeylyzer') {
		const exe = option('oxeylyzer');
		const data = option('oxeylyzer-data');
		// Oxeylyzer writes its config beside its data folder (config/ and data/).
		const config =
			option('oxeylyzer-config') || (data && path.join(data, '..', 'config', 'config.toml'));
		if (exe && data) verifyOxeylyzer(exe, data, config);
		else console.log('Oxeylyzer: skipped (needs --oxeylyzer=<exe> --oxeylyzer-data=<dir>)');
	}
}

main().catch((error) => {
	console.error(`verify-analyser-scores: ${error.message}`);
	process.exit(1);
});
