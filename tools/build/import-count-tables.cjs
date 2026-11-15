// tools/build/import-count-tables.cjs

/**
 * ==============================================================================
 * MODULE: Count Table Import
 * DESCRIPTION:
 * Builds the count tables of static/corpus/frequency (format ergopti-count-table)
 * from the pinned sources of static/corpus/count_table_sources.json: a large
 * corpus ships its character, bigram and trigram counts, never its text. The
 * layout analysis codegen reads the tables (corpora.json format count_table).
 * USAGE: node tools/build/import-count-tables.cjs [--only <output>] [--archive-dir <dir>]
 *
 * FEATURES & RATIONALE:
 * 1. One counting rule: sentences go through the analysis engine's own
 *    ngramsFromText, word lists through the codegen's wordListCounts, so a
 *    table counts what the same text or list would count as a built-in corpus.
 * 2. Pinned input: an archive whose SHA-256 is not the pin's is refused before
 *    it is read; --archive-dir takes archives already downloaded (by their
 *    URL's file name), otherwise curl downloads them (the maintainer's tool,
 *    never run by CI, which has no network).
 * 3. Bounded tables: n-grams rarer than prune_ratio of their table's total are
 *    dropped, and the table states the counts it kept from (pruned_below).
 * 4. Deterministic output: entries sorted by count, then by n-gram.
 * 5. The register (static/corpus/register.json) owns licences: a table is
 *    written only for a source the register already lists by its URL.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const zlib = require('node:zlib');
const { spawnSync } = require('node:child_process');
const { REPO_ROOT } = require('../lib/paths.cjs');
const Analysis = require('../codegen/codegen-layout-analysis-data-js.cjs');

const CORPUS_DIR = path.join(REPO_ROOT, 'static', 'corpus');
const SOURCES_PATH = path.join(CORPUS_DIR, 'count_table_sources.json');
const REGISTER_PATH = path.join(CORPUS_DIR, 'register.json');
const KINDS = ['leipzig_sentences', 'lexique_words'];
const TABLES = ['chars', 'bigrams', 'trigrams'];
// Lines counted per call of the engine: its segments end at a newline, so
// counting chunk by chunk gives exactly the counts of the whole text.
const LINES_PER_CHUNK = 20000;

/** Exits with a reason. */
function fail(message) {
	console.error(`import-count-tables: ${message}`);
	process.exit(1);
}

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/** The value after --name, or undefined. */
function option(name) {
	const index = process.argv.indexOf(`--${name}`);
	if (index === -1) return undefined;
	const value = process.argv[index + 1];
	if (!value || value.startsWith('--')) fail(`--${name} needs a value`);
	return value;
}

/**
 * One member of a zip archive (stored or deflated), from its central directory.
 * @param {Buffer} zip - The archive.
 * @param {string} name - The member's path.
 * @returns {Buffer} Its bytes.
 * @throws {Error} When the archive has no such member or another method.
 */
function zipMember(zip, name) {
	const end = zip.lastIndexOf(Buffer.from([0x50, 0x4b, 0x05, 0x06]));
	if (end < 0) throw new Error('not a zip archive');
	const count = zip.readUInt16LE(end + 10);
	let at = zip.readUInt32LE(end + 16);
	for (let i = 0; i < count; i++) {
		if (zip.readUInt32LE(at) !== 0x02014b50) throw new Error('broken zip central directory');
		const method = zip.readUInt16LE(at + 10);
		const compressed = zip.readUInt32LE(at + 20);
		const nameLength = zip.readUInt16LE(at + 28);
		const extraLength = zip.readUInt16LE(at + 30);
		const commentLength = zip.readUInt16LE(at + 32);
		const local = zip.readUInt32LE(at + 42);
		const entry = zip.toString('utf8', at + 46, at + 46 + nameLength);
		at += 46 + nameLength + extraLength + commentLength;
		if (entry !== name) continue;
		const dataAt = local + 30 + zip.readUInt16LE(local + 26) + zip.readUInt16LE(local + 28);
		const data = zip.subarray(dataAt, dataAt + compressed);
		if (method === 0) return Buffer.from(data);
		if (method === 8) return zlib.inflateRawSync(data);
		throw new Error(`${name} uses zip method ${method}`);
	}
	throw new Error(`the archive has no ${name}`);
}

/**
 * The text of one member of a pinned archive.
 * @param {object} source - A count_table_sources.json entry.
 * @param {string} archivePath - The archive, already checked.
 * @returns {string}
 */
function memberText(source, archivePath) {
	if (archivePath.endsWith('.zip'))
		return zipMember(fs.readFileSync(archivePath), source.member).toString('utf8');
	const folder = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-count-table-'));
	try {
		const run = spawnSync('tar', ['-xzf', archivePath, '-C', folder, source.member], {
			encoding: 'utf8'
		});
		if (run.error || run.status !== 0)
			throw new Error(`tar could not extract ${source.member}: ${run.stderr || run.error}`);
		return fs.readFileSync(path.join(folder, source.member), 'utf8');
	} finally {
		fs.rmSync(folder, { recursive: true, force: true });
	}
}

/** Adds the counts of `from` into `into`. */
function merge(into, from) {
	for (const name of TABLES)
		for (const [gram, n] of Object.entries(from[name]))
			into[name][gram] = (into[name][gram] || 0) + n;
}

/**
 * The counts of a Leipzig sentence file: its « number<TAB> » prefixes removed,
 * each line counted as text by the engine.
 * @param {string} text - The sentence file.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @returns {{chars: object, bigrams: object, trigrams: object}}
 */
function leipzigCounts(text, engine) {
	const lines = text.replace(/﻿/g, '').split('\n');
	const counts = { chars: {}, bigrams: {}, trigrams: {} };
	for (let i = 0; i < lines.length; i += LINES_PER_CHUNK) {
		const chunk = lines
			.slice(i, i + LINES_PER_CHUNK)
			.map((line) => line.replace(/^\d+\t/, ''))
			.join('\n');
		merge(counts, engine.ngramsFromText(chunk));
	}
	return counts;
}

/**
 * The counts of a Lexique table: each distinct word once, weighted by the sum
 * of its rows' frequencies per million times scale (rounded), counted by the
 * word-list rule.
 * @param {string} text - The TSV.
 * @param {object} source - With word_column, frequency_column and scale.
 * @returns {{chars: object, bigrams: object, trigrams: object}}
 */
function lexiqueCounts(text, source) {
	const lines = text.replace(/﻿/g, '').split('\n');
	const header = lines[0].replace(/\r$/, '').split('\t');
	const word = header.indexOf(source.word_column);
	const frequency = header.indexOf(source.frequency_column);
	if (word < 0 || frequency < 0)
		throw new Error(`the table has no ${source.word_column} or ${source.frequency_column} column`);
	if (!Number.isInteger(source.scale) || source.scale < 1)
		throw new Error('scale must be a positive integer');
	// A form has one row per lemma and part of speech, each with its own
	// frequency: the form's frequency is their sum. A multi-word entry
	// (« citizen band ») is no word of a word list: it is left out and counted,
	// so the register can say how many.
	const perMillionOf = new Map();
	let multiWord = 0;
	for (const line of lines.slice(1)) {
		if (line.trim() === '') continue;
		const cells = line.replace(/\r$/, '').split('\t');
		const form = cells[word];
		const perMillion = Number(cells[frequency]);
		if (!form || !Number.isFinite(perMillion) || perMillion < 0)
			throw new Error(`a row has no word or no frequency: ${JSON.stringify(cells.slice(0, 3))}`);
		if (/\s/.test(form)) {
			multiWord++;
			continue;
		}
		perMillionOf.set(form, (perMillionOf.get(form) || 0) + perMillion);
	}
	const weights = new Map();
	for (const [form, perMillion] of perMillionOf) {
		const weight = Math.round(perMillion * source.scale);
		if (weight > 0) weights.set(form, weight);
	}
	const list = [...weights].map(([form, weight]) => `${form} ${weight}`).join('\n');
	console.log(
		`import-count-tables: ${source.output}: ${weights.size} forms, ${multiWord} multi-word rows left out`
	);
	return Analysis.wordListCounts(list, source.output);
}

/**
 * The counts kept: in each table, the n-grams at least `ratio` of its total,
 * as [n-gram, count] pairs sorted by count, then by n-gram.
 * @returns {{tables: object, prunedBelow: object}}
 */
function prune(counts, ratio) {
	if (typeof ratio !== 'number' || !(ratio >= 0) || ratio >= 1)
		throw new Error('prune_ratio must be in [0, 1)');
	const tables = {};
	const prunedBelow = {};
	for (const name of TABLES) {
		const total = Object.values(counts[name]).reduce((sum, n) => sum + n, 0);
		const floor = Math.max(1, Math.ceil(total * ratio));
		prunedBelow[name] = floor;
		// Kept as [n-gram, count] pairs: an object would put the integer-like
		// keys (« 10 ») first, whatever their counts.
		tables[name] = Object.entries(counts[name])
			.filter(([, n]) => n >= floor)
			.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1));
	}
	return { tables, prunedBelow };
}

/** The count-table file of a source's tables, one entry per line. */
function tableText(tables, prunedBelow) {
	const block = (entries) =>
		`{\n${entries.map(([gram, n]) => `\t\t${JSON.stringify(gram)}: ${n}`).join(',\n')}\n\t}`;
	return [
		'{',
		`\t"format": ${JSON.stringify(Analysis.COUNT_TABLE_FORMAT)},`,
		`\t"version": ${Analysis.COUNT_TABLE_VERSION},`,
		`\t"pruned_below": { ${['chars', 'bigrams', 'trigrams'].map((name) => `"${name}": ${prunedBelow[name]}`).join(', ')} },`,
		`\t"chars": ${block(tables.chars)},`,
		`\t"bigrams": ${block(tables.bigrams)},`,
		`\t"trigrams": ${block(tables.trigrams)}`,
		'}',
		''
	].join('\n');
}

/** The archive of a source: given in --archive-dir, else downloaded; checked. */
function archiveOf(source, archiveDir, scratch) {
	const name = path.basename(new URL(source.url).pathname);
	let file = archiveDir ? path.join(archiveDir, name) : path.join(scratch, name);
	if (!archiveDir) {
		const run = spawnSync('curl', ['-sSfL', '-o', file, source.url], { encoding: 'utf8' });
		if (run.error || run.status !== 0)
			throw new Error(`download of ${source.url} failed: ${run.stderr}`);
	}
	if (sha256(fs.readFileSync(file)) !== source.sha256)
		throw new Error(`${file} is not the pinned ${source.url} (SHA-256 differs)`);
	return file;
}

/**
 * Builds one table from its source.
 * @param {object} source - A count_table_sources.json entry.
 * @param {string} archivePath - Its checked archive.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @returns {string} The table file's text.
 */
function buildTable(source, archivePath, engine) {
	if (!KINDS.includes(source.kind)) throw new Error(`${source.output}: kind ${source.kind}`);
	const text = memberText(source, archivePath);
	const counts =
		source.kind === 'leipzig_sentences' ? leipzigCounts(text, engine) : lexiqueCounts(text, source);
	const { tables, prunedBelow } = prune(counts, source.prune_ratio);
	return tableText(tables, prunedBelow);
}

function main() {
	const sources = JSON.parse(fs.readFileSync(SOURCES_PATH, 'utf8'));
	if (sources.schema_version !== 1 || !Array.isArray(sources.tables))
		fail('count_table_sources.json is refused');
	const register = JSON.parse(fs.readFileSync(REGISTER_PATH, 'utf8')).files;
	const only = option('only');
	const archiveDir = option('archive-dir');
	const engine = Analysis.loadEngine();
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-count-sources-'));
	try {
		for (const source of sources.tables) {
			if (only && source.output !== only) continue;
			const entry = register[source.output];
			if (!entry || entry.url !== source.url)
				fail(`${source.output}: static/corpus/register.json must list it with url ${source.url}`);
			const text = buildTable(source, archiveOf(source, archiveDir, scratch), engine);
			const target = path.join(CORPUS_DIR, source.output);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.writeFileSync(target, text);
			Analysis.countTableCounts(text, source.output);
			console.log(`import-count-tables: wrote ${source.output} (${text.length} bytes)`);
		}
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

if (require.main === module) main();

module.exports = { zipMember, leipzigCounts, lexiqueCounts, prune, tableText, buildTable };
