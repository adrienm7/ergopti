// tools/build/import-count-tables.cjs

/**
 * ==============================================================================
 * MODULE: Count Table Import
 * DESCRIPTION:
 * Builds the count tables of static/corpus/frequency (format ergopti-count-table)
 * from the pinned sources of static/corpus/count_table_sources.json: a large
 * corpus ships its character, bigram and trigram counts and its most frequent
 * words, never its text. The layout analysis codegen reads the tables
 * (corpora.json format count_table).
 * USAGE: node tools/build/import-count-tables.cjs [--only <output>] [--archive-dir <dir>]
 *        [--record-pins]
 *
 * FEATURES & RATIONALE:
 * 1. One counting rule: sentences go through the analysis engine's own
 *    ngramsFromText, word lists through the codegen's wordListCounts, so a
 *    table counts what the same text or list would count as a built-in corpus.
 * 2. Pinned input: an archive whose SHA-256 is not the pin's is refused before
 *    it is read; --archive-dir takes archives already downloaded (by their
 *    URL's file name), otherwise curl downloads them (the maintainer's tool,
 *    never run by CI, which has no network).
 * 3. Bounded tables: n-grams rarer than the register's prune_ratio of their
 *    table's total are dropped, and the table states the counts it kept from
 *    (pruned_below). Pruning must not change the analysis: every metric of
 *    PRUNE_CHECK_LAYOUTS, measured on the full and on the pruned counts,
 *    differs by at most PRUNE_TOLERANCE, or the table is refused; the table
 *    records the largest difference (prune_check).
 * 4. Deterministic output: entries sorted by count, then by n-gram.
 * 5. The register (static/corpus/register.json) owns licences: a table is
 *    written only for a source the register already lists by its URL.
 * 6. One word rule: the words of the same sentences or list, counted by the
 *    engine's countWords and bounded by its wordTable (WORD_TABLE_SIZE, the
 *    most frequent first), as a built-in corpus's word table is.
 * 7. Streamed shards: a Google Books 1-gram export (several GB per language)
 *    is never stored: each shard is read from curl's output (or from
 *    --archive-dir), hashed and unzipped as it streams, and refused at its
 *    end unless its SHA-256 is its pin. A shard with no pin yet is refused
 *    too, unless --record-pins writes the hash it streamed into the sources.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const vm = require('node:vm');
const zlib = require('node:zlib');
const readline = require('node:readline');
const { spawn, spawnSync } = require('node:child_process');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');
const Analysis = require('../codegen/codegen-layout-analysis-data-js.cjs');

const CORPUS_DIR = path.join(REPO_ROOT, 'static', 'corpus');
const SOURCES_PATH = path.join(CORPUS_DIR, 'count_table_sources.json');
const ANALYSIS_DATA_PATH = shared('ui', 'layout_analysis', '_generated', 'analysis_data.js');
const REGISTER_PATH = path.join(CORPUS_DIR, 'register.json');
const KINDS = ['leipzig_sentences', 'lexique_words', 'google_books_1grams'];
// A Google Books token kept as a word: letters and combining marks, with
// apostrophes and hyphens inside or at the end (« l' », « peut-être »). A
// tagged token (« livre_NOUN ») or one holding digits or punctuation is not.
const BOOKS_WORD = /^[\p{L}\p{M}]+(?:['\u2019-][\p{L}\p{M}]*)*$/u;
// How many times a streamed shard is tried before the import fails.
const SHARD_ATTEMPTS = 3;
// Words counted by the word-list rule per call (wordListCounts).
const WORDS_PER_BATCH = 50000;
const TABLES = ['chars', 'bigrams', 'trigrams'];
// Lines counted per call of the engine: its segments end at a newline, so
// counting chunk by chunk gives exactly the counts of the whole text.
const LINES_PER_CHUNK = 20000;
// The layouts the pruning check measures: Latin layouts of the languages the
// tables count. A layout that types few of a table's characters (a Cyrillic
// one on French) has metrics over a handful of n-grams, which no table needs.
const PRUNE_CHECK_LAYOUTS = ['qwerty', 'azerty', 'bepo', 'ergopti', 'dvorak', 'colemak', 'ergol'];
// The largest change pruning may make to any metric of those layouts, in the
// metric's own unit (percentage points for the shares). A metric is shown
// with one decimal; 0.05 never moves it by more than one rounding step.
const PRUNE_TOLERANCE = 0.05;

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
 * One member of an uncompressed tar archive (ustar or GNU, long names included).
 * Read in Node, not by a tar program: Git for Windows' GNU tar reads « C:\… »
 * as a remote host, and Windows' own bsdtar takes other options.
 * @param {Buffer} tar - The archive.
 * @param {string} name - The member's path.
 * @returns {Buffer} Its bytes.
 * @throws {Error} When the archive has no such member.
 */
function tarMember(tar, name) {
	const text = (from, length) => {
		const field = tar.subarray(from, from + length);
		const end = field.indexOf(0);
		return field.toString('utf8', 0, end < 0 ? length : end);
	};
	let longName = '';
	for (let at = 0; at + 512 <= tar.length; ) {
		if (tar[at] === 0) break;
		const size = parseInt(text(at + 124, 12).trim() || '0', 8);
		const type = String.fromCharCode(tar[at + 156]);
		const dataAt = at + 512;
		const next = dataAt + Math.ceil(size / 512) * 512;
		if (type === 'L') {
			longName = tar.toString('utf8', dataAt, dataAt + size).replace(/\0+$/, '');
			at = next;
			continue;
		}
		const prefix = text(at + 257, 6).startsWith('ustar') ? text(at + 345, 155) : '';
		const entry = longName || (prefix ? `${prefix}/${text(at, 100)}` : text(at, 100));
		longName = '';
		if (entry === name && (type === '0' || type === '\0'))
			return Buffer.from(tar.subarray(dataAt, dataAt + size));
		at = next;
	}
	throw new Error(`the archive has no ${name}`);
}

/**
 * The text of one member of a pinned archive (zip or tar.gz).
 * @param {object} source - A count_table_sources.json entry.
 * @param {string} archivePath - The archive, already checked.
 * @returns {string}
 */
function memberText(source, archivePath) {
	const bytes = fs.readFileSync(archivePath);
	if (archivePath.endsWith('.zip')) return zipMember(bytes, source.member).toString('utf8');
	return tarMember(zlib.gunzipSync(bytes), source.member).toString('utf8');
}

/** Adds the counts of `from` into `into`. */
function merge(into, from) {
	for (const name of TABLES)
		for (const [gram, n] of Object.entries(from[name]))
			into[name][gram] = (into[name][gram] || 0) + n;
}

// The characters CP1252 gives the bytes 0x80-0x9F (Latin-1 gives the others
// their own code point). 0x81, 0x8D, 0x8F, 0x90 and 0x9D are undefined there.
// Written as escapes: spelling a mojibake run here would trip the encoding gate.
const CP1252_HIGH = [
	0x20ac, 0, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152,
	0, 0x017d, 0, 0, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161,
	0x203a, 0x0153, 0, 0x017e, 0x0178
];
const CP1252_BYTE = new Map();
for (let byte = 0xa0; byte <= 0xff; byte++) CP1252_BYTE.set(String.fromCharCode(byte), byte);
CP1252_HIGH.forEach((code, i) => code && CP1252_BYTE.set(String.fromCharCode(code), 0x80 + i));
const UTF8_STRICT = new TextDecoder('utf-8', { fatal: true });
// The code points a repaired run may yield: Latin-1 and Latin Extended-A
// (« œ »), the spacing modifiers, the phonetic superscripts (« 1ᵉʳ ») and the
// punctuation and symbol blocks. Anything else is a coincidence of real text:
// « Ç’a » forms the valid UTF-8 of « ǒ » (Latin Extended-B), a run of
// accented letters and quotes can form a CJK character.
const REPAIRABLE = /^[\u00a0-\u017f\u02b0-\u02ff\u1d00-\u1dbf\u2000-\u2bff]$/u;

/**
 * Repairs the UTF-8 sequences a source page decoded as CP1252 before Leipzig
 * crawled it (« d’un » reaching the corpus as « d », « â », « € », « ™ », « un »):
 * counted as they are, they turn one apostrophe into three rare characters.
 * A run is repaired only when its CP1252 bytes are one valid UTF-8 character
 * in REPAIRABLE and one of them is a CP1252-only character (0x80-0x9F), so
 * Latin-1 text that happens to form valid UTF-8 (« précédé»« ») stays as written.
 * @param {string} line - One sentence.
 * @returns {string} The sentence with each such run decoded.
 */
function repairMojibake(line) {
	let out = '';
	for (let i = 0; i < line.length; ) {
		const lead = CP1252_BYTE.get(line[i]);
		const size =
			lead >= 0xc2 && lead <= 0xdf ? 2 : lead >= 0xe0 && lead <= 0xf4 ? 3 + (lead >= 0xf0) : 0;
		const bytes = [lead];
		let cp1252Only = false;
		for (let k = 1; k < size; k++) {
			const byte = CP1252_BYTE.get(line[i + k]);
			if (byte === undefined || byte > 0xbf) break;
			cp1252Only ||= byte < 0xa0;
			bytes.push(byte);
		}
		if (size && bytes.length === size && cp1252Only) {
			let decoded = '';
			try {
				decoded = UTF8_STRICT.decode(Uint8Array.from(bytes));
			} catch {
				decoded = '';
			}
			if (REPAIRABLE.test(decoded)) {
				out += decoded;
				i += size;
				continue;
			}
		}
		out += line[i];
		i += 1;
	}
	return out;
}

/**
 * The counts of a Leipzig sentence file: its « number<TAB> » prefixes removed,
 * its CP1252-decoded UTF-8 repaired (repairMojibake), each line counted as text
 * by the engine, and its words by the engine's word rule (countWords).
 * @param {string} text - The sentence file.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @returns {{chars: object, bigrams: object, trigrams: object, words: object}}
 *   The n-gram counts and every word's count, unbounded.
 */
function leipzigCounts(text, engine) {
	const lines = text.replace(/﻿/g, '').split('\n');
	const counts = { chars: {}, bigrams: {}, trigrams: {} };
	const words = {};
	for (let i = 0; i < lines.length; i += LINES_PER_CHUNK) {
		const chunk = lines
			.slice(i, i + LINES_PER_CHUNK)
			.map((line) => repairMojibake(line.replace(/^\d+\t/, '')))
			.join('\n');
		merge(counts, engine.ngramsFromText(chunk));
		engine.countWords(chunk, 1, words);
	}
	counts.words = words;
	return counts;
}

/**
 * The counts of a Lexique table: each distinct word once, weighted by the sum
 * of its rows' frequencies per million times scale (rounded), counted by the
 * word-list rule, and its words by the engine's word rule on that list.
 * @param {string} text - The TSV.
 * @param {object} source - With word_column, frequency_column and scale.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @returns {{chars: object, bigrams: object, trigrams: object, words: object}}
 *   The n-gram counts and every word's count, unbounded.
 */
function lexiqueCounts(text, source, engine) {
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
	return {
		...Analysis.wordListCounts(list, source.output),
		words: Analysis.wordListWords(engine, list)
	};
}

/**
 * Counts one Google Books 1-gram shard as it streams: each kept token (BOOKS_WORD)
 * weighs the sum of its match counts over source.years, and one weighing at
 * least source.min_count joins the counts by the word-list rule, as a word of
 * a frequency list does.
 * @param {NodeJS.ReadableStream} gzipped - The shard's gzip bytes.
 * @param {object} source - With years ([first, last]) and min_count.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @param {object} counts - The counts to add to (chars, bigrams, trigrams, words).
 * @returns {Promise<{sha256: string, kept: number}>} The shard's hash and how
 *   many tokens it added.
 */
async function booksShardCounts(gzipped, source, engine, counts) {
	const [first, last] = source.years;
	const hash = crypto.createHash('sha256');
	gzipped.on('data', (chunk) => hash.update(chunk));
	const gunzip = zlib.createGunzip();
	const lines = readline.createInterface({ input: gzipped.pipe(gunzip), crlfDelay: Infinity });
	// A cut download ends the gzip early: the shard fails, its caller retries it.
	let failure = null;
	gunzip.on('error', (error) => {
		failure = error;
		lines.close();
	});
	let batch = [];
	let kept = 0;
	const flush = () => {
		if (batch.length === 0) return;
		const list = batch.join('\n');
		merge(counts, Analysis.wordListCounts(list, source.output));
		Analysis.wordListWords(engine, list, counts.words);
		batch = [];
	};
	for await (const line of lines) {
		const tab = line.indexOf('\t');
		const token = line.slice(0, tab);
		if (tab < 1 || !BOOKS_WORD.test(token)) continue;
		let total = 0;
		for (const cell of line.slice(tab + 1).split('\t')) {
			const [year, matches] = cell.split(',');
			if (Number(year) >= first && Number(year) <= last) total += Number(matches);
		}
		if (total < source.min_count) continue;
		batch.push(`${token} ${total}`);
		kept++;
		if (batch.length === WORDS_PER_BATCH) flush();
	}
	if (failure) throw failure;
	flush();
	return { sha256: hash.digest('hex'), kept };
}

/**
 * The counts of a Google Books 1-gram export, shard by shard (booksShardCounts),
 * each shard checked against its pin once streamed.
 * @param {object} source - A google_books_1grams entry.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @param {{archiveDir: string|undefined, recordPins: boolean}} options
 * @returns {Promise<object>} The counts, with words.
 * @throws {Error} When a shard is not its pin (or has none without --record-pins).
 */
async function booksCounts(source, engine, { archiveDir, recordPins }) {
	if (
		!Array.isArray(source.years) ||
		source.years.length !== 2 ||
		!source.years.every(Number.isInteger) ||
		!Number.isInteger(source.min_count) ||
		source.min_count < 1 ||
		!Array.isArray(source.shards) ||
		source.shards.length === 0
	)
		throw new Error(`${source.output}: years, min_count and shards are required`);
	const counts = { chars: {}, bigrams: {}, trigrams: {}, words: {} };
	for (const shard of source.shards) {
		const name = path.basename(new URL(shard.url).pathname);
		let streamed = '';
		let kept = 0;
		// A shard is counted apart and added once whole: a reset connection
		// (seen on the 535 MB French shards) restarts that shard only.
		for (let attempt = 1; ; attempt++) {
			const own = { chars: {}, bigrams: {}, trigrams: {}, words: {} };
			let child = null;
			let input;
			if (archiveDir) input = fs.createReadStream(path.join(archiveDir, name));
			else {
				child = spawn('curl', ['-sSfL', '--retry', '3', shard.url], {
					stdio: ['ignore', 'pipe', 'inherit']
				});
				input = child.stdout;
			}
			const exited = child
				? new Promise((resolve) => child.on('close', (code) => resolve(code)))
				: Promise.resolve(0);
			try {
				({ sha256: streamed, kept } = await booksShardCounts(input, source, engine, own));
				if ((await exited) !== 0) throw new Error(`download of ${shard.url} failed`);
			} catch (error) {
				if (child) child.kill();
				if (attempt >= SHARD_ATTEMPTS) throw error;
				console.log(`import-count-tables: ${name}: ${error.message}, attempt ${attempt + 1}`);
				continue;
			}
			merge(counts, own);
			for (const [word, n] of Object.entries(own.words))
				counts.words[word] = (counts.words[word] || 0) + n;
			break;
		}
		if (shard.sha256 !== streamed) {
			if (!(recordPins && shard.sha256 === ''))
				throw new Error(`${shard.url} is not its pin (SHA-256 ${streamed})`);
			shard.sha256 = streamed;
		}
		console.log(`import-count-tables: ${source.output}: ${name}, ${kept} tokens kept`);
	}
	return counts;
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

/**
 * The analysis engine with its layout library, from the generated data.
 * @returns {object} LAYOUT_ANALYSIS.
 */
function engineWithLibrary() {
	const sandbox = {};
	vm.createContext(sandbox);
	for (const file of [ANALYSIS_DATA_PATH, Analysis.ENGINE_PATH])
		vm.runInContext(fs.readFileSync(file, 'utf8'), sandbox, { filename: file });
	return vm.runInContext('LAYOUT_ANALYSIS', sandbox);
}

/**
 * The largest change pruning makes to a metric of the check layouts.
 * @param {object} engine - LAYOUT_ANALYSIS with its library.
 * @param {object} counts - The full counts.
 * @param {object} tables - The kept [n-gram, count] pairs (prune).
 * @returns {{max_metric_change: number, at: string}} The change and where.
 * @throws {Error} When a check layout is missing or a metric is not finite.
 */
function pruneDeviation(engine, counts, tables) {
	const library = new Map(engine.libraryLayouts().map((layout) => [layout.id, layout]));
	const full = engine.prepareNgrams(counts);
	const kept = engine.prepareNgrams(
		Object.fromEntries(TABLES.map((name) => [name, Object.fromEntries(tables[name])]))
	);
	let worst = { max_metric_change: 0, at: '' };
	for (const id of PRUNE_CHECK_LAYOUTS) {
		const layout = library.get(id);
		if (!layout) throw new Error(`the layout library has no ${id}`);
		const before = engine.analyse(layout, full, {}).metrics;
		const after = engine.analyse(layout, kept, {}).metrics;
		for (const [metric, value] of Object.entries(before)) {
			const change = Math.abs(value - after[metric]);
			if (!Number.isFinite(change)) throw new Error(`${id} ${metric} is not finite`);
			if (change > worst.max_metric_change)
				worst = { max_metric_change: change, at: `${id} ${metric}` };
		}
	}
	return { max_metric_change: Number(worst.max_metric_change.toPrecision(3)), at: worst.at };
}

/**
 * The count-table file of a source's tables, one entry per line.
 * @param {string} countedAs - text or word_list.
 * @param {object} tables - The kept [n-gram, count] pairs (prune).
 * @param {object} prunedBelow - Per table, the smallest count kept.
 * @param {object} pruneCheck - From pruneDeviation.
 * @param {object} words - The word table (the engine's wordTable), in order.
 * @returns {string}
 */
function tableText(countedAs, tables, prunedBelow, pruneCheck, words) {
	const block = (entries) =>
		`{\n${entries.map(([gram, n]) => `\t\t${JSON.stringify(gram)}: ${n}`).join(',\n')}\n\t}`;
	return [
		'{',
		`\t"format": ${JSON.stringify(Analysis.COUNT_TABLE_FORMAT)},`,
		`\t"version": ${Analysis.COUNT_TABLE_VERSION},`,
		`\t"counted_as": ${JSON.stringify(countedAs)},`,
		`\t"pruned_below": { ${['chars', 'bigrams', 'trigrams'].map((name) => `"${name}": ${prunedBelow[name]}`).join(', ')} },`,
		'\t"prune_check": {',
		`\t\t"layouts": ${JSON.stringify(PRUNE_CHECK_LAYOUTS).replace(/,/g, ', ')},`,
		`\t\t"max_metric_change": ${pruneCheck.max_metric_change},`,
		`\t\t"at": ${JSON.stringify(pruneCheck.at)}`,
		'\t},',
		`\t"chars": ${block(tables.chars)},`,
		`\t"bigrams": ${block(tables.bigrams)},`,
		`\t"trigrams": ${block(tables.trigrams)},`,
		`\t"words": ${block(Object.entries(words))}`,
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
 * The counts of a source read from one pinned archive.
 * @param {object} source - A leipzig_sentences or lexique_words entry.
 * @param {string} archivePath - Its checked archive.
 * @param {object} engine - LAYOUT_ANALYSIS.
 * @returns {object} The counts, with words.
 */
function archiveCounts(source, archivePath, engine) {
	const text = memberText(source, archivePath);
	return source.kind === 'leipzig_sentences'
		? leipzigCounts(text, engine)
		: lexiqueCounts(text, source, engine);
}

/**
 * Builds one table from its counts.
 * @param {object} source - A count_table_sources.json entry.
 * @param {number} ratio - Its register entry's prune_ratio.
 * @param {object} counts - Its full counts, with words.
 * @param {object} engine - LAYOUT_ANALYSIS with its library.
 * @returns {string} The table file's text.
 * @throws {Error} When pruning changes a metric by more than PRUNE_TOLERANCE.
 */
function buildTable(source, ratio, counts, engine) {
	if (!KINDS.includes(source.kind)) throw new Error(`${source.output}: kind ${source.kind}`);
	const { tables, prunedBelow } = prune(counts, ratio);
	const check = pruneDeviation(engine, counts, tables);
	console.log(
		`import-count-tables: ${source.output}: pruning changes a metric by at most ${check.max_metric_change} (${check.at})`
	);
	if (check.max_metric_change > PRUNE_TOLERANCE)
		throw new Error(
			`${source.output}: pruning at ${ratio} changes ${check.at} by ${check.max_metric_change}, over ${PRUNE_TOLERANCE}`
		);
	return tableText(
		source.kind === 'leipzig_sentences' ? 'text' : 'word_list',
		tables,
		prunedBelow,
		check,
		engine.wordTable(counts.words)
	);
}

async function main() {
	const sources = JSON.parse(fs.readFileSync(SOURCES_PATH, 'utf8'));
	if (sources.schema_version !== 1 || !Array.isArray(sources.tables))
		fail('count_table_sources.json is refused');
	const register = JSON.parse(fs.readFileSync(REGISTER_PATH, 'utf8')).files;
	const only = option('only');
	const archiveDir = option('archive-dir');
	const recordPins = process.argv.includes('--record-pins');
	const engine = engineWithLibrary();
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-count-sources-'));
	try {
		for (const source of sources.tables) {
			if (only && source.output !== only) continue;
			const entry = register[source.output];
			if (!entry || entry.url !== source.url)
				fail(`${source.output}: static/corpus/register.json must list it with url ${source.url}`);
			if (!KINDS.includes(source.kind)) fail(`${source.output}: kind ${source.kind}`);
			const counts =
				source.kind === 'google_books_1grams'
					? await booksCounts(source, engine, { archiveDir, recordPins })
					: archiveCounts(source, archiveOf(source, archiveDir, scratch), engine);
			const text = buildTable(source, entry.prune_ratio, counts, engine);
			// The hashes a first streaming recorded (--record-pins), kept once the table is.
			if (recordPins) fs.writeFileSync(SOURCES_PATH, `${JSON.stringify(sources, null, '\t')}\n`);
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

if (require.main === module)
	main().catch((error) => {
		console.error(error);
		process.exit(1);
	});

module.exports = {
	memberText,
	tarMember,
	booksShardCounts,
	BOOKS_WORD,
	PRUNE_CHECK_LAYOUTS,
	PRUNE_TOLERANCE,
	zipMember,
	leipzigCounts,
	lexiqueCounts,
	repairMojibake,
	prune,
	pruneDeviation,
	engineWithLibrary,
	tableText,
	buildTable
};
