// tools/test/test-corpus-count-tables.cjs

/**
 * ==============================================================================
 * MODULE: Corpus Count Tables Test
 * DESCRIPTION:
 * Pins the count-table format of static/corpus/frequency (ergopti-count-table)
 * and its importer, tools/build/import-count-tables.cjs: every committed table
 * passes the codegen's strict reader, has its pinned source and its register
 * entry with the same URL; the importer's rules give hand-written counts on
 * small inputs (a Leipzig sentence file counts as text, across words; a
 * Lexique table sums a form's rows and leaves multi-word entries out; pruning
 * keeps the counts at its floor, sorted by count); pruning leaves every
 * metric of the check layouts within the importer's tolerance (each table
 * records its largest change, and a harsher pruning of a real text is caught
 * by the same check); a word-list table shows the word-list caveat; and the
 * reader refuses a malformed table. Each table also ships its word table: the
 * engine's WORD_TABLE_SIZE most frequent words of the same sentences or list,
 * counted by the engine's word rule; a tar.gz member is read in Node.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const zlib = require('node:zlib');
const { REPO_ROOT } = require('../lib/paths.cjs');
const Analysis = require('../codegen/codegen-layout-analysis-data-js.cjs');
const Import = require('../build/import-count-tables.cjs');

const CORPUS = path.join(REPO_ROOT, 'static', 'corpus');
const plain = (value) => JSON.parse(JSON.stringify(value));
let checks = 0;

// Every committed table is read by the codegen and traces to its pin and register entry.
{
	const engine = Analysis.loadEngine();
	const sources = JSON.parse(
		fs.readFileSync(path.join(CORPUS, 'count_table_sources.json'), 'utf8')
	);
	const register = JSON.parse(fs.readFileSync(path.join(CORPUS, 'register.json'), 'utf8')).files;
	const outputs = new Set(sources.tables.map((source) => source.output));
	const committed = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) walk(full);
			else if (entry.name.endsWith('.json'))
				committed.push(path.relative(CORPUS, full).split(path.sep).join('/'));
		}
	};
	walk(path.join(CORPUS, 'frequency'));
	assert(committed.length >= 3, 'the count tables are committed');
	for (const file of committed) {
		assert(outputs.has(file), `${file} has a pinned source`);
		const source = sources.tables.find((entry) => entry.output === file);
		for (const pinned of source.shards || [source])
			assert(/^[0-9a-f]{64}$/.test(pinned.sha256), `${file}: its archive is pinned by SHA-256`);
		assert.equal(
			register[file] && register[file].url,
			source.url,
			`${file}: the register names its URL`
		);
		const text = fs.readFileSync(path.join(CORPUS, file), 'utf8');
		const counts = Analysis.countTableCounts(text, file);
		assert(Object.keys(counts.trigrams).length > 0, `${file} has trigrams`);
		// The threshold is the register's, and pruning at it kept the analysis.
		const ratio = register[file].prune_ratio;
		assert(typeof ratio === 'number' && ratio > 0 && ratio < 1e-4, `${file}: prune_ratio ${ratio}`);
		assert(!('prune_ratio' in source), `${file}: the register is the one source of prune_ratio`);
		const check = JSON.parse(text).prune_check;
		assert.deepEqual(
			check.layouts,
			Import.PRUNE_CHECK_LAYOUTS,
			`${file}: checked on the check layouts`
		);
		assert(
			check.max_metric_change <= Import.PRUNE_TOLERANCE,
			`${file}: pruning changed ${check.at} by ${check.max_metric_change}`
		);
		assert.equal(
			counts.countedAs,
			source.kind === 'leipzig_sentences' ? 'text' : 'word_list',
			`${file}: counted as its kind counts`
		);
		// The word table is cut at the engine's size: every source has more words.
		assert.equal(
			Object.keys(counts.words).length,
			engine.WORD_TABLE_SIZE,
			`${file}: its word table keeps the ${engine.WORD_TABLE_SIZE} most frequent words`
		);
	}
	assert.equal(
		Analysis.COUNT_TABLE_MAX_WORDS,
		engine.WORD_TABLE_SIZE,
		'the reader bounds a word table where the engine cuts it'
	);
	checks++;
}

// A Leipzig sentence file: the numbers go, each line counts as text, across words.
{
	const engine = Analysis.loadEngine();
	const counts = plain(Import.leipzigCounts('1\tab c\n2\tc\n', engine));
	// A one-letter word has no key pair: the word rule leaves « c » out.
	assert.deepEqual(counts.words, { ab: 1 });
	assert.deepEqual(counts.chars, { a: 1, b: 1, ' ': 1, c: 2 });
	assert.deepEqual(counts.bigrams, { ab: 1, 'b ': 1, ' c': 1 });
	assert.deepEqual(counts.trigrams, { 'ab ': 1, 'b c': 1 });
	// Counting in chunks gives the counts of the whole text (lines end segments).
	const lines = Array.from({ length: 45000 }, (_, i) => `${i}\tmot ${i % 7}`).join('\n');
	const chunked = plain(Import.leipzigCounts(lines, engine));
	const whole = lines.replace(/^\d+\t/gm, '');
	assert.deepEqual(chunked.words, plain(engine.countWords(whole)));
	delete chunked.words;
	assert.deepEqual(chunked, plain(engine.ngramsFromText(whole)));
	checks++;
}

// A Leipzig sentence holding UTF-8 a crawled page decoded as CP1252 counts the
// characters it meant; Latin-1 text that happens to be valid UTF-8 stays. The
// runs are escaped: spelled out, they would trip the source encoding gate.
{
	const repair = Import.repairMojibake;
	assert.equal(repair('d\u00e2\u20ac\u2122un'), 'd\u2019un', 'apostrophe');
	assert.equal(repair('c\u00c5\u201cur'), 'c\u0153ur', 'oe ligature');
	assert.equal(repair('1\u00e1\u00b5\u2030r'), '1\u1d49r', 'superscript e');
	assert.equal(repair('fin\u00e2\u20ac\u00a6'), 'fin\u2026', 'ellipsis');
	// « Ç’a » is the UTF-8 of a Latin Extended-B letter, « é»« » of a CJK one.
	assert.equal(repair('\u00c7\u2019a'), '\u00c7\u2019a');
	assert.equal(
		repair('pr\u00e9c\u00e9d\u00e9\u00bb\u00abet'),
		'pr\u00e9c\u00e9d\u00e9\u00bb\u00abet'
	);
	// Only CP1252-only bytes mark a run: an all-Latin-1 run is left as written.
	assert.equal(repair('1\u00ca\u00b3'), '1\u00ca\u00b3');
	const engine = Analysis.loadEngine();
	const repaired = plain(Import.leipzigCounts('1\tl\u00e2\u20ac\u2122a\n', engine));
	delete repaired.words;
	assert.deepEqual(repaired, plain(engine.ngramsFromText('l\u2019a')));
	checks++;
}

// A Lexique table: a form's rows are summed, a multi-word entry is left out.
{
	const tsv = [
		'1_Mot\t10_FreqMot\textra',
		'le\t1.5\tA',
		'le\t0.5\tB',
		'ça va\t9\tC',
		'rare\t0.0001\tD'
	].join('\n');
	const engine = Analysis.loadEngine();
	const counts = plain(
		Import.lexiqueCounts(
			tsv,
			{
				output: 'test',
				word_column: '1_Mot',
				frequency_column: '10_FreqMot',
				scale: 1000
			},
			engine
		)
	);
	// The word table weighs each form as its n-grams do.
	assert.deepEqual(counts.words, { le: 2000 });
	// « le » weighs (1.5 + 0.5) × 1000 = 2000; « rare » rounds to 0 and is dropped.
	assert.deepEqual(counts.chars, { l: 2000, e: 2000, ' ': 2000 });
	assert.deepEqual(counts.bigrams, { ' l': 2000, le: 2000, 'e ': 2000 });
	assert.throws(
		() =>
			Import.lexiqueCounts(
				'1_Mot\n',
				{
					output: 'test',
					word_column: '1_Mot',
					frequency_column: '10_FreqMot',
					scale: 1000
				},
				engine
			),
		/no 1_Mot or 10_FreqMot column/
	);
	checks++;
}

// Pruning keeps the counts at its floor, sorted by count then n-gram, and the
// file written is one the reader admits.
{
	const counts = {
		chars: { a: 50, b: 30, c: 20 },
		bigrams: { ab: 9, 10: 1 },
		trigrams: { abc: 5 }
	};
	const { tables, prunedBelow } = Import.prune(counts, 0.25);
	assert.deepEqual(prunedBelow, { chars: 25, bigrams: 3, trigrams: 2 });
	assert.deepEqual(tables.chars, [
		['a', 50],
		['b', 30]
	]);
	assert.deepEqual(
		tables.bigrams,
		[['ab', 9]],
		'an integer-like n-gram below the floor is dropped'
	);
	const text = Import.tableText(
		'text',
		tables,
		prunedBelow,
		{ max_metric_change: 0, at: '' },
		{ abc: 4, ab: 2 }
	);
	const read = plain(Analysis.countTableCounts(text, 'test'));
	assert.deepEqual(read.chars, { a: 50, b: 30 });
	assert.deepEqual(read.words, { abc: 4, ab: 2 }, 'the word table is written in its order');
	const kept = Import.prune({ chars: { 10: 5, a: 7 }, bigrams: {}, trigrams: {} }, 0).tables.chars;
	assert.deepEqual(
		kept,
		[
			['a', 7],
			['10', 5]
		],
		'an integer-like n-gram keeps its place by count'
	);
	checks++;
}

// The reader refuses another format, a wrong n-gram length and a count under the floor.
{
	const good = {
		format: Analysis.COUNT_TABLE_FORMAT,
		version: Analysis.COUNT_TABLE_VERSION,
		counted_as: 'text',
		pruned_below: { chars: 2, bigrams: 1, trigrams: 1 },
		prune_check: { layouts: ['qwerty'], max_metric_change: 0, at: '' },
		chars: { a: 3 },
		bigrams: { ab: 1 },
		trigrams: { abc: 1 },
		words: { abc: 2, ab: 1 }
	};
	Analysis.countTableCounts(JSON.stringify(good), 'good');
	// Distinct three-letter words: 26³ is more than the bound.
	const word = (i) =>
		Array.from({ length: 3 }, (_, k) =>
			String.fromCharCode(97 + (Math.floor(i / 26 ** k) % 26))
		).join('');
	const tooMany = Object.fromEntries(
		Array.from({ length: Analysis.COUNT_TABLE_MAX_WORDS + 1 }, (_, i) => [word(i), 1])
	);
	for (const [label, change] of [
		['format', { format: 'other' }],
		['field', { extra: 1 }],
		['length', { bigrams: { abc: 1 } }],
		['floor', { chars: { a: 1 } }],
		['pruned_below', { pruned_below: { chars: 1 } }],
		['counted_as', { counted_as: 'words' }],
		['prune_check', { prune_check: { layouts: [], max_metric_change: 0, at: '' } }],
		['prune_check change', { prune_check: { layouts: ['qwerty'], max_metric_change: -1, at: '' } }],
		['version', { version: 1 }],
		['no words', { words: undefined }],
		['empty words', { words: {} }],
		['too many words', { words: tooMany }],
		['unsorted words', { words: { ab: 1, abc: 2 } }],
		['one-letter word', { words: { a: 2 } }],
		['capital word', { words: { Abc: 2 } }],
		['word with a digit', { words: { ab1: 2 } }]
	])
		assert.throws(
			() => Analysis.countTableCounts(JSON.stringify({ ...good, ...change }), label),
			/corpora\.json/,
			label
		);
	checks++;
}

// Pruning a real text: a light floor keeps every check-layout metric within
// the tolerance although it drops n-grams; a harsh one is caught.
{
	const engine = Import.engineWithLibrary();
	const text = fs.readFileSync(
		path.join(CORPUS, 'original', 'fr', 'corpus_nemolivier.txt'),
		'utf8'
	);
	const counts = plain(engine.ngramsFromText(text));
	const light = Import.prune(counts, 1e-6).tables;
	assert(
		light.trigrams.length < Object.keys(counts.trigrams).length,
		'the light floor drops trigrams'
	);
	const kept = Import.pruneDeviation(engine, counts, light);
	assert(kept.max_metric_change <= Import.PRUNE_TOLERANCE, `light pruning changed ${kept.at}`);
	const harsh = Import.pruneDeviation(engine, counts, Import.prune(counts, 1e-4).tables);
	assert(harsh.max_metric_change > Import.PRUNE_TOLERANCE, 'a harsh floor is caught');
	checks++;
}

// The page shows the word-list caveat for every corpus counted from a word list.
{
	const sandbox = {};
	require('node:vm').createContext(sandbox);
	require('node:vm').runInContext(
		fs.readFileSync(
			path.join(
				REPO_ROOT,
				'static',
				'ergopti_plus',
				'_shared',
				'ui',
				'layout_analysis',
				'_generated',
				'analysis_data.js'
			),
			'utf8'
		),
		sandbox
	);
	const corpora = require('node:vm').runInContext('LAYOUT_ANALYSIS_DATA', sandbox).corpora;
	const byId = new Map(corpora.map((corpus) => [corpus.id, corpus]));
	assert.equal(byId.get('fr_lexique_words').word_list, true, 'the Lexique table is a word list');
	assert.equal(byId.get('fr_wikipedia_1m').word_list, false, 'the Wikipedia table is text');
	// Every count table ships its word table (the effort per word reads it) and
	// a localized name: its English title says neither its language nor its kind.
	for (const corpus of corpora.filter((entry) => entry.format === 'count_table')) {
		assert(corpus.words > 0, `${corpus.id}: no word table`);
		assert(
			corpus.title_key && corpus.title_key.startsWith(Analysis.CORPUS_TITLE_KEY_PREFIX),
			`${corpus.id}: no localized name`
		);
	}
	assert(
		corpora.filter((corpus) => corpus.format === 'word_frequencies').every((c) => c.word_list),
		'every word frequency list is a word list'
	);
	const page = fs.readFileSync(
		path.join(
			REPO_ROOT,
			'static',
			'ergopti_plus',
			'_shared',
			'ui',
			'layout_analysis',
			'comparer_page.js'
		),
		'utf8'
	);
	assert(page.includes('corpus.builtin.word_list'), 'the page reads word_list, not the format');
	checks++;
}

// The zip reader takes a stored and a deflated member, and names a missing one.
{
	const entries = [
		{ name: 'a/stored.txt', data: Buffer.from('stored text'), method: 0 },
		{ name: 'a/deflated.txt', data: Buffer.from('deflated text'.repeat(20)), method: 8 }
	];
	const locals = [];
	const centrals = [];
	let offset = 0;
	for (const entry of entries) {
		const body = entry.method === 8 ? zlib.deflateRawSync(entry.data) : entry.data;
		const name = Buffer.from(entry.name);
		const local = Buffer.alloc(30);
		local.writeUInt32LE(0x04034b50, 0);
		local.writeUInt16LE(entry.method, 8);
		local.writeUInt32LE(body.length, 18);
		local.writeUInt32LE(entry.data.length, 22);
		local.writeUInt16LE(name.length, 26);
		const central = Buffer.alloc(46);
		central.writeUInt32LE(0x02014b50, 0);
		central.writeUInt16LE(entry.method, 10);
		central.writeUInt32LE(body.length, 20);
		central.writeUInt32LE(entry.data.length, 24);
		central.writeUInt16LE(name.length, 28);
		central.writeUInt32LE(offset, 42);
		locals.push(local, name, body);
		centrals.push(central, name);
		offset += 30 + name.length + body.length;
	}
	const directory = Buffer.concat(centrals);
	const end = Buffer.alloc(22);
	end.writeUInt32LE(0x06054b50, 0);
	end.writeUInt16LE(entries.length, 10);
	end.writeUInt32LE(directory.length, 12);
	end.writeUInt32LE(offset, 16);
	const zip = Buffer.concat([...locals, directory, end]);
	assert.equal(Import.zipMember(zip, 'a/stored.txt').toString(), 'stored text');
	assert.equal(Import.zipMember(zip, 'a/deflated.txt').toString(), 'deflated text'.repeat(20));
	assert.throws(() => Import.zipMember(zip, 'a/missing.txt'), /has no a\/missing\.txt/);
	checks++;
}

// The tar reader takes a ustar member, a long-named one and names a missing one.
{
	const header = (name, size, type, prefix = '') => {
		const block = Buffer.alloc(512);
		block.write(name, 0, 100, 'utf8');
		block.write(`${size.toString(8).padStart(11, '0')}\0`, 124, 12, 'utf8');
		block.write(type, 156, 1, 'utf8');
		block.write('ustar\0', 257, 6, 'utf8');
		block.write(prefix, 345, 155, 'utf8');
		return block;
	};
	const body = (text) => {
		const data = Buffer.from(text);
		return Buffer.concat([data, Buffer.alloc((512 - (data.length % 512)) % 512)]);
	};
	const longName = `d/${'x'.repeat(120)}.txt`;
	const tar = Buffer.concat([
		header('dir/', 0, '5'),
		header('a-sentences.txt', 5, '0', 'dir'),
		body('1\tab\n'),
		header('././@LongLink', longName.length + 1, 'L'),
		body(`${longName}\0`),
		header(longName.slice(0, 100), 4, '0'),
		body('long'),
		Buffer.alloc(1024)
	]);
	assert.equal(Import.tarMember(tar, 'dir/a-sentences.txt').toString(), '1\tab\n');
	assert.equal(Import.tarMember(tar, longName).toString(), 'long');
	assert.throws(() => Import.tarMember(tar, 'dir/missing.txt'), /has no dir\/missing\.txt/);
	checks++;
}

// A Google Books 1-gram shard: the years outside the range, a tagged token, a
// token with a digit and one under min_count are left out; a kept token counts
// by the word-list rule, its words by the word rule; the hash is the gzip's.
async function booksShard() {
	const { Readable } = require('node:stream');
	const crypto = require('node:crypto');
	const shard = zlib.gzipSync(
		[
			'Le\t1949,100,1\t1950,3,1\t2019,2,1',
			'livre_NOUN\t1990,50,5',
			'l2\t1990,50,5',
			"l'\t2000,4,2",
			'rare\t2000,1,1'
		].join('\n') + '\n'
	);
	const engine = Analysis.loadEngine();
	const counts = { chars: {}, bigrams: {}, trigrams: {}, words: {} };
	const result = await Import.booksShardCounts(
		Readable.from([shard]),
		{ output: 'test', years: [1950, 2019], min_count: 2 },
		engine,
		counts
	);
	assert.equal(result.kept, 2, "Le (5 from 1950) and l' (4) are kept");
	assert.equal(result.sha256, crypto.createHash('sha256').update(shard).digest('hex'));
	const expected = Analysis.wordListCounts("Le 5\nl' 4", 'test');
	for (const name of ['chars', 'bigrams', 'trigrams'])
		assert.deepEqual(plain(counts[name]), plain(expected[name]), name);
	assert.deepEqual(plain(counts.words), { le: 5 }, 'the word rule folds case and drops « l »');
	assert(Import.BOOKS_WORD.test('peut-être') && !Import.BOOKS_WORD.test('-x'));
	// A cut download fails the shard (its caller counts it again), never a short count.
	await assert.rejects(
		Import.booksShardCounts(
			Readable.from([shard.subarray(0, shard.length - 8)]),
			{ output: 'test', years: [1950, 2019], min_count: 2 },
			engine,
			{ chars: {}, bigrams: {}, trigrams: {}, words: {} }
		),
		/unexpected end of file/
	);
	checks++;
}

booksShard().then(
	() =>
		console.log(
			`[OK] corpus count tables: ${checks} checks (committed tables, Leipzig, Lexique and Google Books rules, word tables, pruning, reader, zip, tar)`
		),
	(error) => {
		console.error(error);
		process.exit(1);
	}
);
