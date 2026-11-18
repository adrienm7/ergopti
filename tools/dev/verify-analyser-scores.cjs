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
 * 3. genkey (--genkey=<exe> --genkey-data=<its source folder>): `genkey load`
 *    on each of our texts, then `genkey rank`, in a temporary copy of its
 *    layouts, against our scorer on the same layout files (those whose finger
 *    matrix is genkey's column fingering).
 * 4. keygen (--keygen=<exe> --keygen-data=<its source folder>): `keygen
 *    run-ref` for its built-in layouts (read from its src/layout.rs), and
 *    `keygen refine` on a layout file written from each of a few library
 *    layouts, its first printed score read and the process then stopped. The
 *    texts go in ASCII (keygen reads nothing else), any other character as #.
 * 5. carpalx (--perl=<exe> --carpalx-data=<its source folder>
 *    [--carpalx-perl5lib=<dirs>]): `carpalx -action
 *    loadkeyboard,loadtriads,reporteffort` with its own carpalx.conf, on each
 *    text and each of a few of its keyboard files fingered as our model. It
 *    needs Config::General, Math::VecStat and Set::IntSpan, and loads GD,
 *    which only its drawing uses (an empty GD.pm on the library path does).
 * 6. Keyboard Layout Optimizer (--klo=<its evaluate exe> --klo-data=<its source
 *    folder>): each of a few library layouts written into the base layout of
 *    its config/keyboard/standard_qwerty_iso.yml (base and Shift: the file
 *    has no AltGr), `evaluate --corpus <text> --json` with the layout string
 *    that keeps it, against our scorer on the same two layers.
 * 7. Exit status: 0 when every comparison ran, 1 when a download, a run or a
 *    parse failed. The gaps are reported, not judged: the fidelity of each
 *    analyser is recorded in docs/design/analyser-scores.md.
 *
 * Usage:
 *   node tools/dev/verify-analyser-scores.cjs [--analyser=<id>] [--verbose]
 *        [--oxeylyzer=<exe> --oxeylyzer-data=<dir> [--oxeylyzer-config=<file>]]
 *        [--genkey=<exe> --genkey-data=<dir>] [--keygen=<exe> --keygen-data=<dir>]
 *        [--perl=<exe> --carpalx-data=<dir> [--carpalx-perl5lib=<dirs>]]
 *        [--klo=<exe> --klo-data=<dir>]
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const vm = require('vm');
const https = require('https');
const { spawn, spawnSync } = require('child_process');
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
// genkey: the same texts and a French one (its filter keeps a-z and a few signs).
const GENKEY_TEXTS = Object.assign({}, OXEYLYZER_TEXTS, {
	germinal: 'static/corpus/original/fr/zola_germinal.txt'
});
// keygen: library layouts fed to it as layout files (refine prints their score first).
const KEYGEN_LIBRARY = [
	'qwerty',
	'azerty',
	'dvorak',
	'colemak',
	'workman',
	'bepo',
	'ergopti',
	'xpert',
	'engram',
	'canary'
];
const KEYGEN_TIMEOUT_MS = 120000;
// carpalx: its keyboard files fingered as our model (etc/keyboards/<id>.conf).
const CARPALX_KEYBOARDS = [
	'qwerty',
	'dvorak',
	'colemak',
	'workman',
	'qgmlwy',
	'norman',
	'klausler',
	'arensito',
	'tnwmlc',
	'qwkrfy'
];
// Keyboard Layout Optimizer: library layouts written into its QWERTY ISO file.
const KLO_LIBRARY = [
	'qwerty',
	'azerty',
	'qwertz',
	'dvorak',
	'colemak',
	'workman',
	'canary',
	'ergopti',
	'ergol',
	'bepo'
];

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
const MODELS = vm.runInContext('LAYOUT_ANALYSIS_DATA', sandbox).analysers;
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

// ========================
// ======= 4/ genkey ======
// ========================

/**
 * One of genkey's layout files as a library layout: its three rows on the
 * keys of our genkey model (ANSI rows), base layer only. Its finger matrix
 * must be genkey's column fingering, the one our scorer applies.
 */
function genkeyLayout(file) {
	const rowsOf = MODELS.genkey.model.rows_ansi;
	const columns = MODELS.genkey.model.column_fingers;
	const lines = fs.readFileSync(file, 'utf8').split('\n');
	const rows = {};
	lines.slice(1, 4).forEach((line, r) => {
		line
			.trim()
			.split(/\s+/)
			.filter(Boolean)
			.forEach((char, col) => {
				if (rowsOf[r][col]) rows[rowsOf[r][col]] = [char.toLowerCase(), null, null, null];
			});
	});
	const standard = lines.slice(4, 7).every((line, r) =>
		line
			.trim()
			.split(/\s+/)
			.filter(Boolean)
			.every((finger, col) => Number(finger) === columns[Math.min(col, columns.length - 1)])
	);
	const keys = lines.slice(1, 4).map((l) => l.trim().split(/\s+/).filter(Boolean).length);
	const fingers = lines.slice(4, 7).map((l) => l.trim().split(/\s+/).filter(Boolean).length);
	const name = lines[0].trim();
	return {
		layout: { id: name, name, rows, fingering: 'standard' },
		usable: standard && keys.every((n, r) => n === fingers[r])
	};
}

function verifyGenkey(exe, data) {
	if (!fs.existsSync(exe)) throw new Error(`no genkey executable at ${exe}`);
	for (const needed of ['config.toml', 'layouts', path.join('corpora', 'shai-iweb.json')])
		if (!fs.existsSync(path.join(data, needed)))
			throw new Error(`${data} is not genkey's folder (no ${needed})`);
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'genkey-'));
	try {
		fs.cpSync(path.join(data, 'layouts'), path.join(root, 'layouts'), { recursive: true });
		fs.mkdirSync(path.join(root, 'corpora'));
		fs.copyFileSync(
			path.join(data, 'corpora', 'shai-iweb.json'),
			path.join(root, 'corpora', 'shai-iweb.json')
		);
		const config = fs.readFileSync(path.join(data, 'config.toml'), 'utf8');
		if (!/^Corpus = .*$/m.test(config)) throw new Error('genkey config.toml has no Corpus line');
		const withCorpus = (name) => config.replace(/^Corpus = .*$/m, `Corpus = "${name}"`);
		const run = (argv) => {
			const result = spawnSync(exe, argv, { cwd: root, encoding: 'utf8', maxBuffer: 1 << 26 });
			if (result.status !== 0)
				throw new Error(`genkey ${argv.join(' ')}: exit ${result.status}\n${result.stderr}`);
			return result.stdout;
		};
		const files = fs
			.readdirSync(path.join(data, 'layouts'))
			.filter((f) => !f.startsWith('_'))
			.map((f) => Object.assign({ file: f }, genkeyLayout(path.join(data, 'layouts', f))))
			.filter((l) => l.usable);
		const gaps = [];
		for (const [id, file] of Object.entries(GENKEY_TEXTS)) {
			// `load` needs a valid config (an existing corpus) before it writes the new one.
			fs.writeFileSync(path.join(root, 'config.toml'), withCorpus('shai-iweb'));
			fs.copyFileSync(path.join(REPO_ROOT, file), path.join(root, `${id}.txt`));
			run(['load', `${id}.txt`]);
			fs.writeFileSync(path.join(root, 'config.toml'), withCorpus(id));
			const theirs = new Map();
			for (const m of run(['rank']).matchAll(/^(.*?)\s+(-?[0-9.]+)\s*$/gm))
				theirs.set(m[1].trim(), Number(m[2]));
			const tables = E.prepareNgrams(
				E.ngramsFromText(fs.readFileSync(path.join(REPO_ROOT, file), 'utf8'))
			);
			const line = [];
			for (const { layout } of files) {
				const published = theirs.get(layout.name);
				if (published === undefined)
					throw new Error(`genkey on ${id}: no score for ${layout.name}`);
				const ours = S.score('genkey', layout, tables, { keyboard: 'ansi' }).value;
				gaps.push((100 * (ours - published)) / published);
				line.push(`${layout.name} ${published}/${ours.toFixed(3)}`);
			}
			if (verbose) console.log(`  ${id.padEnd(9)} ${line.join('  ')}`);
		}
		console.log(
			`genkey: ${gaps.length} points (${files.length} of its layouts), Score ${summary(gaps, 3, ' %')}`
		);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

// ========================
// ======= 5/ keygen ======
// ========================

/**
 * keygen's built-in layouts (its `layout.rs`, read at run time) as library
 * layouts on the keys of our keygen model: {NAME: layout}, without those that
 * put a character on the left thumb, a key our model does not have.
 */
function keygenBuiltins(source) {
	const codes = MODELS.keygen.model.pos_to_code;
	const text = fs.readFileSync(source, 'utf8');
	const layouts = {};
	const pattern =
		/pub static (\w+)_LAYOUT: Layout = Layout\(\s*Layer\(KeyMap\(\[([^\]]*)\]\)\),\s*Layer\(KeyMap\(\[([^\]]*)\]\)\)\);/g;
	const escapes = { "\\'": "'", '\\0': '\0', '\\\\': '\\' };
	const chars = (list) =>
		Array.from(list.matchAll(/'(\\.|[^'\\])'/g), (m) => escapes[m[1]] || m[1]);
	for (const m of text.matchAll(pattern)) {
		const [base, shift] = [chars(m[2]), chars(m[3])];
		if (base.length !== codes.length || shift.length !== codes.length)
			throw new Error(`keygen ${m[1]}: ${base.length} keys, expected ${codes.length}`);
		if (base[32] !== '\0') continue;
		const rows = {};
		codes.forEach((code, p) => {
			if (code) rows[code] = [base[p], shift[p], null, null].map((c) => (c === '\0' ? null : c));
		});
		layouts[m[1]] = { id: m[1], name: m[1], rows, fingering: 'standard' };
	}
	if (Object.keys(layouts).length === 0) throw new Error(`no keygen layout in ${source}`);
	return layouts;
}

/**
 * A library layout as a keygen layout file (Layout::from_string: per layer,
 * three rows of 5 + 6, 5 + 6 and 5 + 5 keys and the two thumb keys, the
 * Shift layer 40 characters after the base one); NUL stands for no key.
 */
function keygenLayoutFile(layout) {
	const codes = MODELS.keygen.model.pos_to_code;
	const layer = (l) => {
		const c = codes.map((code) => {
			const cell = code && layout.rows[code] ? layout.rows[code][l] : null;
			return typeof cell === 'string' && Array.from(cell).length === 1 ? cell : '\0';
		});
		const row = (from, left, right) =>
			`${c.slice(from, from + left).join('')} ${c.slice(from + left, from + left + right).join('')}`;
		return `${row(0, 5, 6)}\n${row(11, 5, 6)}\n${row(22, 5, 5)}${c[32]}${c[33]}\n`;
	};
	return layer(0) + layer(1);
}

/** keygen's first « total: …; scaled: … » line, the process killed once read. */
function keygenFirstScore(exe, argv) {
	return new Promise((resolve, reject) => {
		const child = spawn(exe, argv);
		let out = '';
		const timer = setTimeout(() => {
			child.kill();
			reject(new Error(`keygen ${argv.join(' ')}: no score in ${KEYGEN_TIMEOUT_MS} ms`));
		}, KEYGEN_TIMEOUT_MS);
		child.stdout.on('data', (chunk) => {
			out += chunk;
			const m = /total: [0-9.e+-]+; scaled: (-?[0-9.e+-]+)/.exec(out);
			if (!m) return;
			clearTimeout(timer);
			child.kill();
			resolve(Number(m[1]));
		});
		child.on('error', reject);
		child.on('exit', (code) => {
			if (!/scaled:/.test(out)) {
				clearTimeout(timer);
				reject(new Error(`keygen ${argv.join(' ')}: exit ${code} without a score`));
			}
		});
	});
}

async function verifyKeygen(exe, data) {
	if (!fs.existsSync(exe)) throw new Error(`no keygen executable at ${exe}`);
	const builtins = keygenBuiltins(path.join(data, 'src', 'layout.rs'));
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'keygen-'));
	try {
		const gaps = { builtin: [], library: [] };
		for (const [id, file] of Object.entries(GENKEY_TEXTS)) {
			// keygen slices its text by character index as if it were bytes: it
			// reads ASCII only. A non-ASCII character becomes « # », outside its
			// character set, so its run is cut there as keygen means to.
			const text = fs.readFileSync(path.join(REPO_ROOT, file), 'utf8').replace(/\P{ASCII}/gu, '#');
			const corpus = path.join(root, `${id}.txt`);
			fs.writeFileSync(corpus, text);
			const tables = E.prepareNgrams(E.ngramsFromText(text));
			const line = [];
			const run = spawnSync(exe, ['run-ref', corpus], { encoding: 'utf8', maxBuffer: 1 << 26 });
			if (run.status !== 0) throw new Error(`keygen run-ref on ${id}: exit ${run.status}`);
			for (const m of run.stdout.matchAll(/Reference: (\w+)[\s\S]*?scaled: (-?[0-9.e+-]+)/g)) {
				if (!builtins[m[1]]) continue;
				const ours = S.score('keygen', builtins[m[1]], tables, { keyboard: 'ansi' }).value;
				gaps.builtin.push((100 * (ours - Number(m[2]))) / Number(m[2]));
				line.push(`${m[1]} ${Number(m[2]).toFixed(4)}/${ours.toFixed(4)}`);
			}
			for (const layoutId of KEYGEN_LIBRARY) {
				const layout = libraryLayout(layoutId);
				const file = path.join(root, `${layoutId}.layout`);
				fs.writeFileSync(file, keygenLayoutFile(layout));
				const theirs = await keygenFirstScore(exe, ['refine', corpus, file]);
				const ours = S.score('keygen', layout, tables, { keyboard: 'ansi' }).value;
				gaps.library.push((100 * (ours - theirs)) / theirs);
				line.push(`${layoutId} ${theirs.toFixed(4)}/${ours.toFixed(4)}`);
			}
			if (verbose) console.log(`  ${id.padEnd(9)} ${line.join('  ')}`);
		}
		console.log(
			`keygen: its ${Object.keys(builtins).length} layouts, ${gaps.builtin.length} points, ${summary(gaps.builtin, 3, ' %')}`
		);
		console.log(
			`keygen: ${KEYGEN_LIBRARY.length} library layouts, ${gaps.library.length} points, ${summary(gaps.library, 3, ' %')}`
		);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

// =========================
// ======= 6/ carpalx ======
// =========================

/**
 * carpalx's keyboard files (etc/keyboards/*.conf) as library layouts on the
 * rows of our carpalx model, keeping those whose fingers are the model's.
 */
function carpalxKeyboards(dir) {
	const model = MODELS.carpalx.model;
	const keyboards = {};
	for (const file of fs.readdirSync(dir).filter((f) => f.endsWith('.conf'))) {
		const text = fs.readFileSync(path.join(dir, file), 'utf8').split('\r').join('');
		const rows = {};
		let same = true;
		const blocks = Array.from(
			text.matchAll(/<row (\d)>\s*keys\s*=\s*(.*)\n\s*fingers\s*=\s*(.*)\n/g)
		);
		for (const [, index, keyList, fingerList] of blocks) {
			const r = Number(index) - 1;
			const keys = keyList.trim().split(/\s+/);
			const fingers = fingerList.trim().split(/\s+/).map(Number);
			if (!model.rows_to_code[r] || keys.length !== model.rows_to_code[r].length) same = false;
			if (!same) break;
			keys.forEach((key, col) => {
				if (fingers[col] !== model.finger[r][col]) same = false;
				const chars = Array.from(key.replace(/\\(.)/g, '$1'));
				const letter = /^[a-z]$/i.test(chars[0]);
				rows[model.rows_to_code[r][col]] = letter
					? [chars[0].toLowerCase(), chars[0].toUpperCase(), null, null]
					: [chars[0], chars[1] || null, null, null];
			});
		}
		if (same && blocks.length === model.rows_to_code.length)
			keyboards[file.replace(/\.conf$/, '')] = {
				id: file,
				name: file,
				rows,
				fingering: 'standard'
			};
	}
	return keyboards;
}

function verifyCarpalx(perl, data) {
	if (!fs.existsSync(perl)) throw new Error(`no Perl at ${perl}`);
	if (!fs.existsSync(path.join(data, 'bin', 'carpalx')))
		throw new Error(`${data} is not carpalx's folder (no bin/carpalx)`);
	const keyboards = carpalxKeyboards(path.join(data, 'etc', 'keyboards'));
	const chosen = CARPALX_KEYBOARDS.filter((id) => keyboards[id]);
	if (chosen.length === 0) throw new Error('none of the carpalx keyboards has our fingering');
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'carpalx-'));
	try {
		const env = Object.assign({}, process.env);
		const lib = option('carpalx-perl5lib');
		if (lib) env.PERL5LIB = env.PERL5LIB ? `${lib}${path.delimiter}${env.PERL5LIB}` : lib;
		const gaps = [];
		for (const [id, file] of Object.entries(GENKEY_TEXTS)) {
			// carpalx caches a corpus's triads beside it: a fresh file per text.
			const corpus = path.join(root, `${id}.txt`);
			fs.copyFileSync(path.join(REPO_ROOT, file), corpus);
			const tables = E.prepareNgrams(E.ngramsFromText(fs.readFileSync(corpus, 'utf8')));
			const line = [];
			for (const keyboard of chosen) {
				const run = spawnSync(
					perl,
					[
						path.join(data, 'bin', 'carpalx'),
						'-configfile',
						path.join(data, 'etc', 'carpalx.conf'),
						'-action',
						'loadkeyboard,loadtriads,reporteffort,quit',
						'-corpus',
						corpus,
						'-keyboard_input',
						path.join(data, 'etc', 'keyboards', `${keyboard}.conf`)
					],
					{ env, encoding: 'utf8', maxBuffer: 1 << 26 }
				);
				const m = /#data effort_all=>\[([0-9.]+)/.exec(run.stdout);
				if (run.status !== 0 || !m)
					throw new Error(
						`carpalx on ${id} with ${keyboard}: exit ${run.status}\n${run.stderr.slice(-400)}`
					);
				const theirs = Number(m[1]);
				const ours = S.score('carpalx', keyboards[keyboard], tables, { keyboard: 'ansi' }).value;
				gaps.push((100 * (ours - theirs)) / theirs);
				line.push(`${keyboard} ${theirs}/${ours.toFixed(3)}`);
			}
			if (verbose) console.log(`  ${id.padEnd(9)} ${line.join('  ')}`);
		}
		console.log(
			`carpalx: ${gaps.length} points (${chosen.length} of its keyboards), ${summary(gaps, 3, ' %')}`
		);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

// ===========================================
// ======= 7/ Keyboard Layout Optimizer ======
// ===========================================

// Our keys on the rows of its standard_qwerty_iso.yml base_layout, in its
// order (null: a key of its own, kept: Backspace, Tab, Caps Lock, Enter, the
// Shifts and the bottom row's modifiers), and the columns its layout string
// permutes (fixed_keys false) per row.
const KLO_ROWS = [
	[
		'Backquote',
		'Digit1',
		'Digit2',
		'Digit3',
		'Digit4',
		'Digit5',
		'Digit6',
		'Digit7',
		'Digit8',
		'Digit9',
		'Digit0',
		'Minus',
		'Equal',
		null
	],
	[
		null,
		'KeyQ',
		'KeyW',
		'KeyE',
		'KeyR',
		'KeyT',
		'KeyY',
		'KeyU',
		'KeyI',
		'KeyO',
		'KeyP',
		'BracketLeft',
		'BracketRight'
	],
	[
		null,
		'KeyA',
		'KeyS',
		'KeyD',
		'KeyF',
		'KeyG',
		'KeyH',
		'KeyJ',
		'KeyK',
		'KeyL',
		'Semicolon',
		'Quote',
		'Backslash',
		null
	],
	[
		null,
		'IntlBackslash',
		'KeyZ',
		'KeyX',
		'KeyC',
		'KeyV',
		'KeyB',
		'KeyN',
		'KeyM',
		'Comma',
		'Period',
		'Slash',
		null
	],
	[null, null, null, 'Space', null, null, null, null]
];
const KLO_FREE = [null, [1, 10], [1, 9], [2, 10], null];

/** A key's base and Shift characters, as its keyboard file can hold them. */
function kloCells(layout, code) {
	const row = layout.rows[code] || [];
	const cell = (c) => (typeof c === 'string' && Array.from(c).length === 1 ? c : null);
	// A Shift character on a key without a base one is left out: the tool
	// names a key by its base symbol.
	return cell(row[0]) === null ? [] : [cell(row[0]), cell(row[1])].filter((c) => c !== null);
}

/**
 * A library layout written into the tool's QWERTY ISO keyboard file (base and
 * Shift layers), and the layout string that keeps it as it is: the base
 * symbols of the keys it permutes. Null when a permuted key has no base
 * symbol (a dead key there).
 */
function kloKeyboard(template, layout) {
	const lines = template.split('\n');
	const start = lines.findIndex((l) => /^base_layout:/.test(l));
	if (start < 0) throw new Error('the keyboard file has no base_layout');
	const free = [];
	let row = -1;
	let col = 0;
	for (let i = start + 1; i < lines.length && !/^\S/.test(lines[i]); i++) {
		const m = /^(\s*)- (- )?(\[.*\])\s*$/.exec(lines[i]);
		if (!m) continue;
		if (m[2]) {
			row++;
			col = 0;
		} else col++;
		const code = KLO_ROWS[row] ? KLO_ROWS[row][col] : undefined;
		if (code === undefined && row !== 4) throw new Error(`base_layout row ${row} has a key ${col}`);
		if (!code) continue;
		const cells = kloCells(layout, code);
		lines[i] =
			`${m[1]}- ${m[2] || ''}[${(cells.length ? cells : ['']).map((c) => JSON.stringify(c)).join(', ')}]`;
		if (KLO_FREE[row] && col >= KLO_FREE[row][0] && col <= KLO_FREE[row][1]) {
			if (cells.length === 0 || cells[0] === ' ') return null;
			free.push(cells[0]);
		}
	}
	return { file: lines.join('\n'), layoutString: free.join('') };
}

/** The library layout as the keyboard file holds it: base and Shift only. */
function kloAsWritten(layout) {
	const rows = {};
	for (const code of Object.keys(layout.rows)) {
		const cells = kloCells(layout, code);
		rows[code] = [cells[0] || null, cells[1] || null, null, null];
	}
	return Object.assign({}, layout, { rows, dead: {}, command: {} });
}

function verifyKlo(exe, data) {
	if (!fs.existsSync(exe)) throw new Error(`no evaluate executable at ${exe}`);
	const templatePath = path.join(data, 'config', 'keyboard', 'standard_qwerty_iso.yml');
	if (!fs.existsSync(templatePath)) throw new Error(`${data} has no ${templatePath}`);
	const template = fs.readFileSync(templatePath, 'utf8').split('\r').join('');
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'klo-'));
	try {
		const gaps = [];
		const skipped = new Set();
		for (const [id, file] of Object.entries(GENKEY_TEXTS)) {
			const text = fs.readFileSync(path.join(REPO_ROOT, file), 'utf8');
			const tables = E.prepareNgrams(E.ngramsFromText(text));
			const line = [];
			for (const layoutId of KLO_LIBRARY) {
				const layout = libraryLayout(layoutId);
				const keyboard = kloKeyboard(template, layout);
				if (!keyboard) {
					skipped.add(layoutId);
					continue;
				}
				const conf = path.join(root, `${layoutId}.yml`);
				fs.writeFileSync(conf, keyboard.file);
				const run = spawnSync(
					exe,
					['-l', conf, '--corpus', path.join(REPO_ROOT, file), '--json', keyboard.layoutString],
					{ cwd: data, encoding: 'utf8', maxBuffer: 1 << 28 }
				);
				if (run.status !== 0)
					throw new Error(
						`evaluate ${layoutId} on ${id}: exit ${run.status}\n${run.stderr.slice(-400)}`
					);
				const theirs = JSON.parse(run.stdout)[0].total_cost;
				const ours = S.score('dariogoetz', kloAsWritten(layout), tables, { keyboard: 'iso' }).value;
				gaps.push((100 * (ours - theirs)) / theirs);
				line.push(`${layoutId} ${theirs.toFixed(3)}/${ours.toFixed(3)}`);
			}
			if (verbose) console.log(`  ${id.padEnd(9)} ${line.join('  ')}`);
		}
		const note = skipped.size
			? ` (skipped, a dead key on a permuted key: ${[...skipped].join(', ')})`
			: '';
		console.log(
			`Keyboard Layout Optimizer: ${gaps.length} points, ${summary(gaps, 6, ' %')}${note}`
		);
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

// ======================
// ======= 8/ Main ======
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
	if (!only || only === 'genkey') {
		const exe = option('genkey');
		const data = option('genkey-data');
		if (exe && data) verifyGenkey(exe, data);
		else console.log('genkey: skipped (needs --genkey=<exe> --genkey-data=<its source folder>)');
	}
	if (!only || only === 'keygen') {
		const exe = option('keygen');
		const data = option('keygen-data');
		if (exe && data) await verifyKeygen(exe, data);
		else console.log('keygen: skipped (needs --keygen=<exe> --keygen-data=<its source folder>)');
	}
	if (!only || only === 'carpalx') {
		const perl = option('perl');
		const data = option('carpalx-data');
		if (perl && data) verifyCarpalx(perl, data);
		else console.log('carpalx: skipped (needs --perl=<exe> --carpalx-data=<its source folder>)');
	}
	if (!only || only === 'dariogoetz') {
		const exe = option('klo');
		const data = option('klo-data');
		if (exe && data) verifyKlo(exe, data);
		else
			console.log(
				'Keyboard Layout Optimizer: skipped (needs --klo=<evaluate exe> --klo-data=<its source folder>)'
			);
	}
}

main().catch((error) => {
	console.error(`verify-analyser-scores: ${error.message}`);
	process.exit(1);
});
