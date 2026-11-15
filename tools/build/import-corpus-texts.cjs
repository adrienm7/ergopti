// tools/build/import-corpus-texts.cjs

/**
 * ==============================================================================
 * MODULE: Corpus Text Import
 * DESCRIPTION:
 * Writes the Project Gutenberg texts of static/corpus/original from the pinned
 * ebooks of static/corpus/text_sources.json: the ebook between its START and
 * END markers, without the Project Gutenberg header, licence footer or name.
 * The layout analysis codegen counts them like any built-in text.
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
 *    written only for an ebook the register already lists by its page URL.
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
	if (sources.schema_version !== 1 || !Array.isArray(sources.texts))
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
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

if (require.main === module) main();

module.exports = { gutenbergText, ebookPage, ebookText };
