// tools/build/import-corpus-texts.cjs

/**
 * ==============================================================================
 * MODULE: Corpus Text Import
 * DESCRIPTION:
 * Writes the Project Gutenberg and Wikisource texts of static/corpus/original
 * from the pinned sources of static/corpus/text_sources.json: an ebook between
 * its START and END markers, without the Project Gutenberg header, licence
 * footer or name; a Wikisource work as the paragraphs of its listed page
 * revisions. The layout analysis codegen counts them like any built-in text.
 * USAGE: node tools/build/import-corpus-texts.cjs [--only <output>] [--archive-dir <dir>]
 *
 * FEATURES & RATIONALE:
 * 1. Pinned input: a download whose SHA-256 is not the pin's is refused before
 *    it is read; --archive-dir takes files already downloaded (pg<id>.txt),
 *    otherwise curl downloads them (the maintainer's tool, never run by CI,
 *    which has no network).
 * 2. One stripping rule (gutenbergText) for every book, the committed ones
 *    included: line ends become LF, blank lines around the text and a closing
 *    « End of (the) Project Gutenberg… » line go, trailing spaces go, and the
 *    indentation of each line is kept.
 * 3. The register (static/corpus/register.json) owns licences: a text is
 *    written only for an ebook or work the register already lists by its
 *    page URL.
 * 4. Wikisource works (wikisource_texts) are read page revision by page
 *    revision (action=parse&oldid, one request per WIKISOURCE_PAUSE_MS, as
 *    Wikimedia's API etiquette asks); --archive-dir takes the parse outputs
 *    already downloaded (<revid>.json). The parser's HTML carries render ids
 *    and follows MediaWiki's markup changes, so the pin is the SHA-256 of the
 *    text written: a text that differs from it is refused, never written.
 * 5. One extraction rule (wikisourceText): only the work's paragraphs (<p>)
 *    are kept, so the header and navigation templates, image captions and
 *    footnotes go; footnote calls, page-number anchors, soft hyphens and zero-width characters
 *    go; entities are decoded, runs of spaces and line breaks become one
 *    space, and non-breaking spaces stay, as French typography types them.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { REPO_ROOT } = require('../lib/paths.cjs');

const CORPUS_DIR = path.join(REPO_ROOT, 'static', 'corpus');
const SOURCES_PATH = path.join(CORPUS_DIR, 'text_sources.json');
const REGISTER_PATH = path.join(CORPUS_DIR, 'register.json');
const START_MARKER = '*** START OF';
const END_MARKER = '*** END OF';
const CLOSING_LINE = /^End of (?:the )?Project Gutenberg/i;
// The pause between two Wikisource API requests: its servers answer HTTP 429
// to a client that asks faster.
const WIKISOURCE_PAUSE_MS = 1500;
const WIKISOURCE_WIKI = 'fr.wikisource.org';
// The named entities MediaWiki's parser writes in running text; it writes
// every other character as itself or as a numeric reference.
const NAMED_ENTITIES = { amp: '&', lt: '<', gt: '>', quot: '"', apos: "'", nbsp: '\u00a0' };

/** Exits with a reason. */
function fail(message) {
	console.error(`import-corpus-texts: ${message}`);
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

/** The ebook page the register names, and the plain-text file it serves. */
const ebookPage = (id) => `https://www.gutenberg.org/ebooks/${id}`;
const ebookText = (id) => `https://www.gutenberg.org/cache/epub/${id}/pg${id}.txt`;

/**
 * The text of a Project Gutenberg ebook, without its header and footer.
 * @param {string} ebook - The plain-text ebook.
 * @returns {string} The work, LF line ends, one final newline.
 * @throws {Error} When a marker is missing or the text is empty.
 */
function gutenbergText(ebook) {
	const text = ebook.replace(/^﻿/, '').replace(/\r\n/g, '\n');
	const start = text.indexOf(START_MARKER);
	const end = text.indexOf(END_MARKER);
	if (start < 0 || end < 0 || end < start)
		throw new Error('the ebook has no START and END markers');
	const lines = text.slice(text.indexOf('\n', start) + 1, end).split('\n');
	while (lines.length > 0 && lines[0].trim() === '') lines.shift();
	while (
		lines.length > 0 &&
		(lines[lines.length - 1].trim() === '' || CLOSING_LINE.test(lines[lines.length - 1].trim()))
	)
		lines.pop();
	if (lines.length === 0) throw new Error('the ebook has no text between its markers');
	return `${lines.map((line) => line.trimEnd()).join('\n')}\n`;
}

/** The page URL the register names for a Wikisource work. */
const workPage = (work) =>
	`https://${WIKISOURCE_WIKI}/wiki/${encodeURIComponent(work.replace(/ /g, '_')).replace(/%2F/g, '/')}`;
/** The parse output of one page revision. */
const revisionParse = (revid) =>
	`https://${WIKISOURCE_WIKI}/w/api.php?action=parse&oldid=${revid}&prop=text&format=json&formatversion=2`;

/** Decodes the character references of HTML text. */
function decodeEntities(text) {
	return text.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (whole, name) => {
		if (name[0] !== '#') {
			if (!(name in NAMED_ENTITIES)) throw new Error(`unknown entity ${whole}`);
			return NAMED_ENTITIES[name];
		}
		const code =
			name[1] === 'x' || name[1] === 'X' ? parseInt(name.slice(2), 16) : Number(name.slice(1));
		return String.fromCodePoint(code);
	});
}

/**
 * The paragraphs of a Wikisource page's parse output.
 * @param {string} html - The parser's HTML.
 * @returns {string[]} Each paragraph's text, on one line, empty ones left out.
 */
function wikisourceText(html) {
	const paragraphs = [];
	// Template styles sit inside paragraphs: their CSS is no text of the work.
	const body = html.replace(/<(style|script)\b[\s\S]*?<\/\1>/g, '');
	for (const match of body.matchAll(/<p(?:\s[^>]*)?>([\s\S]*?)<\/p>/g)) {
		const text = decodeEntities(
			match[1]
				.replace(/<sup\b[^>]*class="[^"]*\breference\b[^"]*"[^>]*>[\s\S]*?<\/sup>/g, '')
				// Verse indents are hidden underscores (« ____ »), no text either.
				.replace(/<span\b[^>]*visibility:\s*hidden[^>]*>[^<]*<\/span>/g, '')
				.replace(/<br\s*\/?>/g, ' ')
				.replace(/<[^>]*>/g, '')
		)
			.replace(/[\u200b-\u200d\u00ad\ufeff]/g, '')
			.replace(/[ \t\r\n]+/g, ' ')
			.trim();
		if (text) paragraphs.push(text);
	}
	return paragraphs;
}

/** Waits, without a timer, between two requests to the same API. */
const pause = (ms) => Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);

/** The parse output of one revision: given in --archive-dir, else downloaded. */
function revisionHtml(revid, archiveDir, scratch) {
	const file = path.join(archiveDir || scratch, `${revid}.json`);
	if (!archiveDir) {
		pause(WIKISOURCE_PAUSE_MS);
		const run = spawnSync(
			'curl',
			[
				'-sSfL',
				'--retry',
				'6',
				'--retry-delay',
				'30',
				'-A',
				'corpus-import/1.0',
				'-o',
				file,
				revisionParse(revid)
			],
			{ encoding: 'utf8' }
		);
		if (run.error || run.status !== 0)
			throw new Error(`download of revision ${revid} failed: ${run.stderr}`);
	}
	const parse = JSON.parse(fs.readFileSync(file, 'utf8')).parse;
	if (!parse || parse.revid !== revid || typeof parse.text !== 'string')
		throw new Error(`${file} is not the parse output of revision ${revid}`);
	return parse.text;
}

/**
 * The text of a Wikisource work: its pages' paragraphs in the listed order,
 * one per line, checked against its pin.
 * @throws {Error} When a page has no paragraph or the text is not its pin.
 */
function wikisourceWork(source, archiveDir, scratch) {
	const lines = [];
	for (const page of source.pages) {
		const paragraphs = wikisourceText(revisionHtml(page.revid, archiveDir, scratch));
		if (paragraphs.length === 0) throw new Error(`${page.title} (${page.revid}) has no paragraph`);
		lines.push(...paragraphs);
	}
	const text = `${lines.join('\n')}\n`;
	if (sha256(Buffer.from(text, 'utf8')) !== source.sha256)
		throw new Error(`${source.output}: the text read is not its pin (SHA-256 differs)`);
	return text;
}

/** The ebook of a source: given in --archive-dir, else downloaded; checked. */
function ebookOf(source, archiveDir, scratch) {
	const name = `pg${source.gutenberg_id}.txt`;
	const file = path.join(archiveDir || scratch, name);
	if (!archiveDir) {
		const run = spawnSync('curl', ['-sSfL', '-o', file, ebookText(source.gutenberg_id)], {
			encoding: 'utf8'
		});
		if (run.error || run.status !== 0)
			throw new Error(`download of ebook ${source.gutenberg_id} failed: ${run.stderr}`);
	}
	const bytes = fs.readFileSync(file);
	if (sha256(bytes) !== source.sha256)
		throw new Error(`${file} is not the pinned ebook ${source.gutenberg_id} (SHA-256 differs)`);
	return bytes.toString('utf8');
}

function main() {
	const sources = JSON.parse(fs.readFileSync(SOURCES_PATH, 'utf8'));
	if (
		sources.schema_version !== 1 ||
		!Array.isArray(sources.texts) ||
		!Array.isArray(sources.wikisource_texts)
	)
		fail('text_sources.json is refused');
	const register = JSON.parse(fs.readFileSync(REGISTER_PATH, 'utf8')).files;
	const only = option('only');
	const archiveDir = option('archive-dir');
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-corpus-texts-'));
	try {
		for (const source of sources.texts) {
			if (only && source.output !== only) continue;
			const entry = register[source.output];
			if (!entry || entry.url !== ebookPage(source.gutenberg_id))
				fail(
					`${source.output}: static/corpus/register.json must list it with url ${ebookPage(source.gutenberg_id)}`
				);
			const text = gutenbergText(ebookOf(source, archiveDir, scratch));
			const target = path.join(CORPUS_DIR, source.output);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.writeFileSync(target, text);
			console.log(`import-corpus-texts: wrote ${source.output} (${text.length} characters)`);
		}
		for (const source of sources.wikisource_texts) {
			if (only && source.output !== only) continue;
			const entry = register[source.output];
			if (!entry || entry.url !== workPage(source.work))
				fail(
					`${source.output}: static/corpus/register.json must list it with url ${workPage(source.work)}`
				);
			const text = wikisourceWork(source, archiveDir, scratch);
			const target = path.join(CORPUS_DIR, source.output);
			fs.mkdirSync(path.dirname(target), { recursive: true });
			fs.writeFileSync(target, text);
			console.log(`import-corpus-texts: wrote ${source.output} (${text.length} characters)`);
		}
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

if (require.main === module) main();

module.exports = { gutenbergText, ebookPage, ebookText, wikisourceText, workPage, revisionParse };
