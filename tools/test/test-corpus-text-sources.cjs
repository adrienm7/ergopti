// tools/test/test-corpus-text-sources.cjs

/**
 * ==============================================================================
 * MODULE: Corpus Text Sources Test
 * DESCRIPTION:
 * Pins the Project Gutenberg texts of static/corpus/original and their importer,
 * tools/build/import-corpus-texts.cjs: every register entry sourced from a
 * Project Gutenberg ebook page has a pinned source (or is one of the recorded
 * exceptions), each source traces to its register entry and a shipped corpus,
 * the text on disk keeps no Project Gutenberg header, footer or name, and the
 * stripping rule gives hand-written results on small ebooks.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { REPO_ROOT } = require('../lib/paths.cjs');
const Import = require('../build/import-corpus-texts.cjs');

const CORPUS = path.join(REPO_ROOT, 'static', 'corpus');
const CORPORA = path.join(
	REPO_ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'layouts',
	'data',
	'analysis',
	'corpora.json'
);
// Gutenberg ebooks the importer does not rebuild: the English Don Quixote is
// Ergo-L's own conversion of ebook 996 (its register note says so).
const NOT_IMPORTED = new Set(['original/en/don_quixote_ormsby.txt']);
let checks = 0;

// Every Gutenberg-sourced text has its pin, register entry and shipped corpus.
{
	const sources = JSON.parse(fs.readFileSync(path.join(CORPUS, 'text_sources.json'), 'utf8'));
	const register = JSON.parse(fs.readFileSync(path.join(CORPUS, 'register.json'), 'utf8')).files;
	const shipped = new Set(
		JSON.parse(fs.readFileSync(CORPORA, 'utf8')).corpora.map((corpus) => corpus.file)
	);
	const outputs = new Set();
	for (const source of sources.texts) {
		assert(!outputs.has(source.output), `${source.output} is listed once`);
		outputs.add(source.output);
		assert(Number.isSafeInteger(source.gutenberg_id), `${source.output}: an ebook number`);
		assert(/^[0-9a-f]{64}$/.test(source.sha256), `${source.output}: its ebook is pinned`);
		const entry = register[source.output];
		assert(entry, `${source.output} has a register entry`);
		assert.equal(
			entry.url,
			Import.ebookPage(source.gutenberg_id),
			`${source.output}: register URL`
		);
		assert.equal(entry.status, 'ship', `${source.output} ships`);
		assert(shipped.has(`static/corpus/${source.output}`), `${source.output} is a corpus`);
		const text = fs.readFileSync(path.join(CORPUS, source.output), 'utf8');
		assert(
			!/Project Gutenberg|\*\*\* (?:START|END) OF/i.test(text),
			`${source.output}: no PG text`
		);
		assert(!text.includes('\r'), `${source.output}: LF line ends`);
		assert(text.endsWith('\n') && !text.endsWith('\n\n'), `${source.output}: one final newline`);
	}
	for (const [file, entry] of Object.entries(register))
		if (
			/^https:\/\/www\.gutenberg\.org\/ebooks\/\d+$/.test(entry.url || '') &&
			!NOT_IMPORTED.has(file)
		)
			assert(
				outputs.has(file),
				`${file} comes from a Gutenberg ebook: pin it in text_sources.json`
			);
	for (const language of ['de', 'es', 'it'])
		assert(
			sources.texts.some((source) => source.output.startsWith(`original/${language}/`)),
			`a ${language} text is imported`
		);
	checks++;
}

// The stripping rule: the work between the markers, LF, trimmed edges, kept indentation.
{
	const ebook = [
		'﻿The Project Gutenberg eBook of Test',
		'*** START OF THE PROJECT GUTENBERG EBOOK TEST ***',
		'',
		'',
		'    An indented title   ',
		'',
		'A line.',
		'',
		"End of Project Gutenberg's Test, by Nobody",
		'',
		'*** END OF THE PROJECT GUTENBERG EBOOK TEST ***',
		'Licence footer.'
	].join('\r\n');
	assert.equal(Import.gutenbergText(ebook), '    An indented title\n\nA line.\n');
	assert.equal(
		Import.gutenbergText(
			'*** START OF X ***\nkept\nEnd of the Project Gutenberg EBook\n*** END OF X ***'
		),
		'kept\n'
	);
	assert.throws(() => Import.gutenbergText('no markers'), /no START and END markers/);
	assert.throws(
		() => Import.gutenbergText('*** START OF X ***\n\n\n*** END OF X ***'),
		/no text between its markers/
	);
	assert.equal(Import.ebookText(5711), 'https://www.gutenberg.org/cache/epub/5711/pg5711.txt');
	checks++;
}

console.log(
	`[OK] corpus text sources: ${checks} checks (pins, register, shipped corpora, stripping rule)`
);
