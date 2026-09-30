// tools/test/test-restore-recommended-no-confirm.cjs

/**
 * ==============================================================================
 * MODULE: Restoring the Recommended Values Asks Nothing, on Every Driver
 * DESCRIPTION:
 * Regression restore-recommended-no-confirm. Every « ↺ Restaurer les valeurs
 * conseillées » row used to open a default-No question before it applied: the
 * macOS scope owners and the tap-hold row asked through block_alert, the Linux
 * rows through zenity, each with the restore label as its text. The maintainer
 * retired that step. A restore is recoverable through the backup its owner
 * writes first; only a clear, which removes a section's settings, still asks.
 *
 * WHAT THIS HOLDS, across the three drivers and the shared pages:
 *   1. The registry: every manifest row labelled common.restore_recommended is
 *      registered by each driver that shows it, so the scans below have
 *      subjects. Each driver's suite clicks the rows themselves
 *      (test_restore_recommended_no_confirm.lua, .ahk).
 *   2. No function that asks a question names the restore label: the label is
 *      a row, never the text of a question.
 *   3. A function that receives a scope mode and asks a question asks it under
 *      a `mode == "clear"` condition, so a question moved to the shared path
 *      would ask before a restore again.
 *   4. No shared page function that restores the recommended values asks.
 *
 * A source scan is the right tool at this boundary: it is the one place that
 * sees every driver and every page against the one row declaration. Functions
 * are delimited by indentation, which the strict convention lint holds.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { stripComments } = require('../lib/script-source.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const RESTORE_KEY = 'common.restore_recommended';

const DRIVERS = [
	{ platform: 'hs', dir: 'macos', ext: '.lua' },
	{ platform: 'linux', dir: 'linux', ext: '.lua' },
	{ platform: 'ahk', dir: 'windows', ext: '.ahk' }
];

// The calls that put a question in front of the user, per language. An AHK
// MsgBox is a question only when its options offer a choice.
const QUESTION_CALLS = {
	'.lua':
		/\b(?:block_alert|blockAlert|ask_yes_no|confirm_clear)\s*\(|\.confirm\s*\(|zenity --question/,
	'.ahk': /\.Ask\s*\(|\bMsgBox\s*\((?=[^\n]*(?:YesNo|OKCancel|RetryCancel|"\s*[1-6]\b))/,
	'.js': /\b(?:window\.)?confirm\s*\(|\bshowConfirm\s*\(|\brunConfirm\s*\(/
};

// A function that receives or reads a scope mode.
const MODE_NAME = /\b(?:mode|Mode|selected_mode)\b/;
const CLEAR_GUARD = /\b(?:mode|Mode)\s*==\s*"clear"/;
const JS_RESTORE = /restoreRecommended|common\.restore_recommended|btn-restore/;

const errors = [];

// ==================================================
// ==================================================
// ======= 1/ Function spans ========================
// ==================================================
// ==================================================

/**
 * Leading indentation width, tabs and spaces alike.
 * @param {string} line
 * @returns {number}
 */
function indentOf(line) {
	return line.match(/^[\t ]*/)[0].length;
}

/**
 * Every function of a source as a line span, delimited by the closing line at
 * the opening line's indentation. A function opened and closed on one line
 * spans that line.
 * @param {string[]} lines Comment-stripped source lines.
 * @param {string} ext '.lua', '.ahk' or '.js'.
 * @returns {{start: number, end: number}[]}
 */
function functionSpans(lines, ext) {
	const spans = [];
	const keywords = /^\s*(?:if|else|while|for|loop|switch|catch|try|until|return|class)\b/i;
	lines.forEach((line, start) => {
		let opens = false;
		let closer;
		if (ext === '.lua') {
			if (!/\bfunction\b/.test(line)) return;
			if (/\bfunction\b.*\bend\b/.test(line)) {
				spans.push({ start, end: start });
				return;
			}
			opens = true;
			closer = /^\s*end\b/;
		} else {
			opens =
				(ext === '.ahk' && !keywords.test(line) && /^\s*[A-Za-z_]\w*\(.*\)\s*\{\s*$/.test(line)) ||
				(ext === '.js' &&
					(/\bfunction\b[^{]*\{\s*$/.test(line) ||
						/=>\s*\{\s*$/.test(line) ||
						(!keywords.test(line) && /^\s*[A-Za-z_]\w*\s*\([^)]*\)\s*\{\s*$/.test(line))));
			closer = /^\s*\}/;
		}
		if (!opens) return;
		const indent = indentOf(line);
		for (let end = start + 1; end < lines.length; end += 1) {
			if (indentOf(lines[end]) === indent && closer.test(lines[end])) {
				spans.push({ start, end });
				return;
			}
		}
	});
	return spans;
}

/**
 * The innermost function span holding one line, or the line alone at file level.
 * @param {{start: number, end: number}[]} spans
 * @param {number} at Line index.
 * @returns {{start: number, end: number}}
 */
function enclosing(spans, at) {
	let best = { start: at, end: at };
	for (const span of spans) {
		if (span.start <= at && span.end >= at && (best.start === best.end || span.start > best.start))
			best = span;
	}
	return best;
}

/**
 * Whether a question at one line sits under a clear-only condition: on the line
 * itself, or on an enclosing `if` between it and its function's first line.
 * @param {string[]} lines
 * @param {{start: number}} span
 * @param {number} at Question line index.
 * @returns {boolean}
 */
function guardedByClear(lines, span, at) {
	if (CLEAR_GUARD.test(lines[at])) return true;
	let depth = indentOf(lines[at]);
	for (let line = at - 1; line >= span.start; line -= 1) {
		const indent = indentOf(lines[line]);
		if (lines[line].trim() === '' || indent >= depth) continue;
		depth = indent;
		if (/^\s*(?:else)?if\b/i.test(lines[line]) && CLEAR_GUARD.test(lines[line])) return true;
	}
	return false;
}

/**
 * Checks every question of one file against rules 2 and 3.
 * @param {string} rel Path shown in a failure.
 * @param {string} source Comment-stripped source.
 * @param {string} ext
 * @returns {number} Questions found.
 */
function checkQuestions(rel, source, ext) {
	const lines = source.split('\n');
	const spans = functionSpans(lines, ext);
	let questions = 0;
	lines.forEach((line, at) => {
		if (!QUESTION_CALLS[ext].test(line)) return;
		questions += 1;
		const span = enclosing(spans, at);
		const body = lines.slice(span.start, span.end + 1).join('\n');
		if (body.includes(RESTORE_KEY) || (ext === '.js' && JS_RESTORE.test(body))) {
			errors.push(
				`${rel}:${at + 1} asks a question in a function that restores the recommended values.`
			);
		}
		if (ext !== '.js' && MODE_NAME.test(body) && !guardedByClear(lines, span, at)) {
			errors.push(`${rel}:${at + 1} asks a question for every scope mode; only a clear may ask.`);
		}
	});
	return questions;
}

/**
 * Every source file of one tree, tests and vendored code excluded.
 * @param {string} dir
 * @param {string} ext
 * @returns {string[]}
 */
function sourceFiles(dir, ext) {
	const files = [];
	(function walk(current) {
		for (const entry of fs.readdirSync(current, { withFileTypes: true })) {
			const full = path.join(current, entry.name);
			if (entry.isDirectory()) {
				if (!['tests', 'test', 'vendor', 'node_modules', '_generated'].includes(entry.name))
					walk(full);
			} else if (full.endsWith(ext)) {
				files.push(full);
			}
		}
	})(dir);
	return files;
}

/**
 * Removes JavaScript comments that start a line or follow whitespace, which is
 * how this tree writes them; a URL inside a string is left alone.
 * @param {string} source
 * @returns {string}
 */
function stripJsComments(source) {
	return source
		.replace(/\/\*[\s\S]*?\*\//g, (block) => block.replace(/[^\n]/g, ' '))
		.replace(/(^|[\t ])\/\/.*$/gm, '$1');
}

// The span finder and both rules, on the shapes they must tell apart.
{
	const shape = (text, ext) => {
		errors.length = 0;
		checkQuestions('fixture', text, ext);
		return errors.slice();
	};
	const oldLua =
		'local function apply(mode)\n' +
		'\tlocal label = i18n.get(mode == "clear" and "common.clear_to_system" or "common.restore_recommended")\n' +
		'\tif ask_yes_no(title, label) ~= true then return false end\n' +
		'end\n';
	assert.equal(shape(oldLua, '.lua').length, 2, 'the retired Linux shape breaks both rules');
	const everyMode =
		'function owner.apply(mode)\n\tif options.confirm(mode) ~= true then return false end\nend\n';
	assert.equal(shape(everyMode, '.lua').length, 1, 'a question before every mode is caught');
	const clearOnly =
		'function owner.apply(mode)\n\tif mode == "clear" then\n\t\tif options.confirm(mode) ~= true then return false end\n\tend\nend\n';
	assert.deepEqual(shape(clearOnly, '.lua'), [], 'a question under a clear condition passes');
	const sameLine =
		'local function apply(mode)\n\tif mode == "clear" and not confirm_clear(title) then return false end\nend\n';
	assert.deepEqual(shape(sameLine, '.lua'), []);
	const ahkRestore =
		'Restore(Mode) {\n\tif MsgBox(t("common.restore_recommended"), "", "YesNo") != "Yes"\n\t\treturn\n}\n';
	assert.equal(shape(ahkRestore, '.ahk').length, 2, 'an AHK question before a restore is caught');
	const ahkNotice = 'Report(Mode) {\n\tMsgBox(t("dialog.failed"), "", "Iconx")\n}\n';
	assert.deepEqual(shape(ahkNotice, '.ahk'), [], 'an error notice is not a question');
	const jsRestore = 'function restoreRecommended() {\n\tif (!confirm(text)) return;\n}\n';
	assert.equal(shape(jsRestore, '.js').length, 1, 'a page question before a restore is caught');
	errors.length = 0;
}

// ==================================================
// ==================================================
// ======= 2/ The registry ==========================
// ==================================================
// ==================================================

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
const restoreRows = [];
for (const [menu, rows] of Object.entries(manifest)) {
	if (!Array.isArray(rows)) continue;
	for (const row of rows) {
		if (row && row.type === 'command' && row.i18n === RESTORE_KEY)
			restoreRows.push({ menu, id: row.id, platforms: row.platforms });
	}
}
if (restoreRows.length < 6)
	errors.push(`the manifest declares ${restoreRows.length} restore row(s), expected at least 6.`);

const driverSources = {};
for (const driver of DRIVERS) {
	driverSources[driver.dir] = sourceFiles(path.join(SP, driver.dir), driver.ext).map((file) => ({
		rel: path.relative(SP, file).split(path.sep).join('/'),
		text: stripComments(fs.readFileSync(file, 'utf8'), driver.ext)
	}));
}
for (const row of restoreRows) {
	for (const driver of DRIVERS) {
		if (Array.isArray(row.platforms) && !row.platforms.includes(driver.platform)) continue;
		const registered = driverSources[driver.dir].some(
			({ text }) => text.includes(`"${row.id}"`) || new RegExp(`[{,]\\s*${row.id}\\s*=`).test(text)
		);
		if (!registered)
			errors.push(`${driver.dir} shows ${row.menu}.${row.id} but registers no command for it.`);
	}
}

// ==================================================
// ==================================================
// ======= 3/ The questions =========================
// ==================================================
// ==================================================

// Floors a little under the counts measured on 2026-09-30: a scan that stops
// matching the helpers would otherwise pass over nothing.
const floors = { macos: 25, linux: 15, windows: 6 };
const counts = {};
for (const driver of DRIVERS) {
	let questions = 0;
	for (const { rel, text } of driverSources[driver.dir])
		questions += checkQuestions(rel, text, driver.ext);
	counts[driver.dir] = questions;
	if (questions < floors[driver.dir])
		errors.push(
			`${driver.dir}: found ${questions} question(s), expected at least ${floors[driver.dir]}.`
		);
}
let sharedLua = 0;
for (const file of sourceFiles(path.join(SP, '_shared', 'lua'), '.lua')) {
	const rel = path.relative(SP, file).split(path.sep).join('/');
	sharedLua += checkQuestions(rel, stripComments(fs.readFileSync(file, 'utf8'), '.lua'), '.lua');
}

let pages = 0;
let restorePages = 0;
for (const file of sourceFiles(path.join(SP, '_shared', 'ui'), '.js')) {
	const rel = path.relative(SP, file).split(path.sep).join('/');
	const text = stripJsComments(fs.readFileSync(file, 'utf8'));
	if (JS_RESTORE.test(text)) restorePages += 1;
	pages += checkQuestions(rel, text, '.js');
}
if (restorePages < 1)
	errors.push('no shared page restores the recommended values — the page scan read nothing.');
if (pages < 1) errors.push('found no question on any shared page — the page scan is broken.');

// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Restoring the recommended values must not ask a question:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

const perDriver = DRIVERS.map((driver) => `${driver.dir} ${counts[driver.dir]}`).join(', ');
console.log(
	`\x1b[32m[OK] ${restoreRows.length} restore row(s) apply at once; no question ` +
		`(${perDriver}, shared Lua ${sharedLua}, pages ${pages}) asks before a restore.\x1b[0m`
);
