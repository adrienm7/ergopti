// tools/lint/hex-colours.cjs

/**
 * ==============================================================================
 * MODULE: Hex Colour Literal Scanner
 * DESCRIPTION:
 * Counts the hexadecimal colour literals (`#rgb`, `#rrggbb`, `#rrggbbaa`) that
 * the driver tree spells in its source, file by file.
 *
 * WHY:
 * The 2026-10-24 parity audit (row K5) found the same colours typed hundreds of
 * times across the shared pages and the three drivers: one accent declared 19
 * times with five values, one red in fourteen files, the hotstring palette in
 * three drivers. A count that nobody can reproduce cannot be driven down, so
 * the census below is the measurement every later step is checked against.
 *
 * WHAT COUNTS:
 * 1. Tracked files under the driver tree, minus tests (their colours are
 *    fixtures), the archived `old/` tree and third-party `vendor/` code.
 * 2. Source languages only. Markdown and SVG artwork are not code that renders
 *    a theme; an issue reference such as `#101` in prose is not a colour.
 * 3. Comments are removed first, so `see #123` in a comment is not counted.
 *    In TOML, Python and shell, where `#` opens a comment, only a quoted
 *    literal counts.
 * 4. An HTML entity (`&#039;`) and an identifier that merely starts with hex
 *    digits (`#add-button`) are not colours.
 *
 * USAGE:  node tools/lint/hex-colours.cjs --census
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');
const { REPO_ROOT, SHARED_REL } = require('../lib/paths.cjs');

// The driver tree is the parent of the shared tree; deriving it keeps the one
// spelling of that folder in paths.cjs.
const DRIVERS_REL = path.posix.dirname(SHARED_REL);

// A path matching one of these never counts: test fixtures (`tests/`, and the
// shared Lua contract suites under `test/`), the archived layouts and vendored
// third-party code.
const EXCLUDED_PATHS = [/(^|\/)tests?\//, new RegExp(`^${DRIVERS_REL}/old/`), /(^|\/)vendor\//];

// How each scanned extension hides its comments. `quoted` languages open a
// comment with `#` itself, so only a literal inside quotes can be a colour.
const LANGUAGE_BY_EXTENSION = new Map([
	['.css', 'css'],
	['.html', 'html'],
	['.js', 'js'],
	['.mjs', 'js'],
	['.cjs', 'js'],
	['.swift', 'js'],
	['.lua', 'lua'],
	['.ahk', 'ahk'],
	['.json', 'json'],
	['.toml', 'quoted'],
	['.py', 'quoted'],
	['.sh', 'quoted']
]);

// Eight, six or three hex digits, longest first. The lookbehind refuses an
// HTML entity and a `#` inside a word; the lookahead refuses a longer run of
// word characters, so `#add-button` and `#1234` (an issue number) do not match.
const HEX_LITERAL = /(?<![&\w])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![\w-])/g;
const QUOTED_HEX_LITERAL =
	/(?<=["'])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![\w-])(?=["'])/g;

// The audit's own measure: six digits, comments included. Kept so the census
// can be compared with the published numbers.
const AUDIT_SIX_DIGIT = /#[0-9a-fA-F]{6}\b/g;

/**
 * Replaces a match with as many newlines as it spans, so later line numbers
 * still point at the source line.
 * @param {string} match The removed text.
 * @returns {string} Only the newlines of the match.
 */
function keepLines(match) {
	return match.replace(/[^\n]/g, '');
}

/**
 * Removes the comments of one language.
 * @param {string} text Source text.
 * @param {string} language A value of LANGUAGE_BY_EXTENSION.
 * @returns {string} The text without its comments.
 */
function stripComments(text, language) {
	let out = text;
	if (language === 'html') out = out.replace(/<!--[\s\S]*?-->/g, keepLines);
	if (['css', 'html', 'js', 'ahk'].includes(language)) {
		out = out.replace(/\/\*[\s\S]*?\*\//g, keepLines);
	}
	// A `//` after a colon is a URL scheme, not a comment.
	if (['html', 'js'].includes(language)) out = out.replace(/(^|[^:\\])\/\/[^\n]*/g, '$1');
	if (language === 'lua') {
		out = out.replace(/--\[(=*)\[[\s\S]*?\]\1\]/g, keepLines).replace(/--[^\n]*/g, '');
	}
	if (language === 'ahk') out = out.replace(/(^|[ \t]);[^\n]*/gm, '$1');
	return out;
}

/**
 * Lists the colour literals of one source text.
 * @param {string} text Source text.
 * @param {string} extension File extension, with its dot.
 * @returns {{value: string, line: number}[]} The literals, lower-cased, in order.
 */
function scanText(text, extension) {
	const language = LANGUAGE_BY_EXTENSION.get(extension);
	if (!language) throw new Error(`hex-colours: no scanning rule for "${extension}" files.`);
	const code = stripComments(text.replace(/\r\n/g, '\n'), language);
	const pattern = language === 'quoted' ? QUOTED_HEX_LITERAL : HEX_LITERAL;
	const found = [];
	for (const match of code.matchAll(pattern)) {
		const line = code.slice(0, match.index).split('\n').length;
		found.push({ value: match[0].toLowerCase(), line });
	}
	return found;
}

/**
 * Lists the tracked files the scan covers.
 * @param {string} root Repository root.
 * @returns {string[]} Repo-relative, forward-slash paths, sorted.
 */
function scannedFiles(root) {
	const listed = execFileSync('git', ['ls-files', '-z', '--', DRIVERS_REL], {
		cwd: root,
		encoding: 'utf8',
		maxBuffer: 64 * 1024 * 1024
	});
	const files = listed
		.split('\0')
		.filter((file) => file !== '')
		.filter((file) => LANGUAGE_BY_EXTENSION.has(path.posix.extname(file)))
		.filter((file) => !EXCLUDED_PATHS.some((pattern) => pattern.test(file)))
		// A tracked file deleted in the working tree is not source any more.
		.filter((file) => fs.existsSync(path.join(root, file)))
		.sort();
	if (files.length === 0) {
		throw new Error(
			`hex-colours: no source file found under ${DRIVERS_REL}; the scan path is stale.`
		);
	}
	return files;
}

/**
 * Scans every covered file.
 * @param {string} root Repository root.
 * @returns {Map<string, {value: string, line: number}[]>} Literals by file,
 *   files without any omitted.
 */
function scanTree(root) {
	const byFile = new Map();
	for (const file of scannedFiles(root)) {
		const text = fs.readFileSync(path.join(root, file), 'utf8');
		const found = scanText(text, path.posix.extname(file));
		if (found.length > 0) byFile.set(file, found);
	}
	return byFile;
}

/**
 * Names the area a file belongs to in the census: a shared subtree or a driver.
 * @param {string} file Repo-relative path.
 * @returns {string} The area.
 */
function areaOf(file) {
	const parts = file.slice(DRIVERS_REL.length + 1).split('/');
	return parts[0] === path.posix.basename(SHARED_REL) ? `${parts[0]}/${parts[1]}` : parts[0];
}

/**
 * Measures the tree: the gate's count, the audit's six-digit count and the
 * `--accent` declarations of the stylesheets.
 * @param {string} root Repository root.
 * @returns {object} The census.
 */
function census(root) {
	const files = scannedFiles(root);
	const gate = { literals: 0, files: 0, distinct: new Set(), byArea: {} };
	const audit = { literals: 0, files: 0, distinct: new Set(), byArea: {} };
	const accents = [];
	for (const file of files) {
		const text = fs.readFileSync(path.join(root, file), 'utf8');
		const extension = path.posix.extname(file);
		const area = areaOf(file);
		const found = scanText(text, extension);
		if (found.length > 0) {
			gate.literals += found.length;
			gate.files += 1;
			gate.byArea[area] = (gate.byArea[area] || 0) + found.length;
			for (const { value } of found) gate.distinct.add(value);
		}
		const six = text.match(AUDIT_SIX_DIGIT) || [];
		if (six.length > 0) {
			audit.literals += six.length;
			audit.files += 1;
			audit.byArea[area] = (audit.byArea[area] || 0) + six.length;
			for (const value of six) audit.distinct.add(value.toLowerCase());
		}
		if (extension === '.css') {
			for (const match of stripComments(text, 'css').matchAll(/--accent\s*:\s*([^;}]+)/g)) {
				accents.push({ file, value: match[1].trim().toLowerCase() });
			}
		}
	}
	return { scannedFiles: files.length, gate, audit, accents };
}

/**
 * Formats a census for a reader.
 * @param {object} result The value census() returned.
 * @returns {string} The report.
 */
function formatCensus(result) {
	const areas = (byArea) =>
		Object.entries(byArea)
			.sort((a, b) => b[1] - a[1] || (a[0] < b[0] ? -1 : 1))
			.map(([area, count]) => `${area} ${count}`)
			.join(', ');
	const accentValues = [...new Set(result.accents.map((accent) => accent.value))].sort();
	return [
		`Hex colour census of ${DRIVERS_REL} (${result.scannedFiles} source files; tests, old/ and vendor/ excluded)`,
		`  six-digit, comments included (the audit's measure): ${result.audit.literals} literal(s) in ` +
			`${result.audit.files} file(s), ${result.audit.distinct.size} distinct`,
		`    ${areas(result.audit.byArea)}`,
		`  3-, 6- and 8-digit, comments excluded (the gate's measure): ${result.gate.literals} literal(s) in ` +
			`${result.gate.files} file(s), ${result.gate.distinct.size} distinct`,
		`    ${areas(result.gate.byArea)}`,
		`  --accent declarations: ${result.accents.length}, ${accentValues.length} value(s): ${accentValues.join(', ')}`
	].join('\n');
}

/** Runs the scanner as a command. */
function main() {
	if (process.argv.includes('--census')) {
		console.log(formatCensus(census(REPO_ROOT)));
		return;
	}
	console.error('usage: node tools/lint/hex-colours.cjs --census');
	process.exit(2);
}

if (require.main === module) main();

module.exports = {
	DRIVERS_REL,
	LANGUAGE_BY_EXTENSION,
	scanText,
	scannedFiles,
	scanTree,
	census,
	formatCensus
};
