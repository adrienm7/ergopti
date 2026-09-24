// tools/test/test-text-case-vectors-shared.cjs

/**
 * ==============================================================================
 * MODULE: Shared Text-Case Corpus Gate
 * DESCRIPTION:
 * Checks the corpus of the selection case actions,
 * _shared/tests/corpus/text_case/vectors.json, and that each driver suite
 * replays it.
 *
 * WHY:
 * The three drivers converted case three ways: macOS with byte-level
 * string.upper (é, à and ç unchanged), Windows with Format("{:T}") (a capital
 * after every apostrophe), Linux with a Unicode table but no hyphen rule. The
 * corpus now states the one behaviour, and every suite replays it. This gate
 * keeps the corpus honest (its upper/lower columns are Unicode default case
 * conversion, its title and toggle columns follow the documented rule) and
 * fails when a suite stops replaying it, since a corpus nobody reads pins
 * nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const CORPUS = path.join(SP, '_shared', 'tests', 'corpus', 'text_case', 'vectors.json');
const DRIVERS = ['hs', 'linux', 'ahk'];
const FIELDS = ['upper', 'lower', 'title', 'toggle_upper', 'toggle_title'];

const errors = [];
let checks = 0;
const check = (ok, message) => {
	checks += 1;
	if (!ok) errors.push(message);
};

/**
 * The corpus title rule, as a reference: a word starts at the text start and
 * after whitespace or a dash; other punctuation before a word is kept.
 * @param {string} text
 * @returns {string}
 */
function referenceTitle(text) {
	let atWordStart = true;
	let out = '';
	for (const ch of text.toLowerCase()) {
		if (/^[\p{White_Space}\p{Pd}]$/u.test(ch)) {
			atWordStart = true;
			out += ch;
		} else if (!atWordStart || /^\p{P}$/u.test(ch)) {
			out += ch;
		} else {
			atWordStart = false;
			out += titleOf(ch);
		}
	}
	return out;
}

/** Title-case form of one lowercase character (Lt when one exists). */
function titleOf(ch) {
	const upper = ch.toUpperCase();
	if (upper.length > 1 || [...upper].length > 1) {
		const chars = [...upper];
		return chars[0] + chars.slice(1).join('').toLowerCase();
	}
	const TITLE_DIGRAPHS = { 'ǆ': 'ǅ', 'ǉ': 'ǈ', 'ǌ': 'ǋ', 'ǳ': 'ǲ' };
	return TITLE_DIGRAPHS[ch] || upper;
}

const corpus = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
check(Array.isArray(corpus.vectors) && corpus.vectors.length >= 12,
	`the corpus must hold at least 12 vectors, found ${(corpus.vectors || []).length}`);
for (const key of ['title_rule', 'toggle_rule', 'drivers_rule']) {
	check(typeof corpus[key] === 'string' && corpus[key].length > 40, `the corpus must document its ${key}`);
}

const ids = new Set();
const perDriver = { hs: 0, linux: 0, ahk: 0 };
for (const vector of corpus.vectors || []) {
	const id = vector.id;
	check(typeof id === 'string' && /^[a-z0-9_]+$/.test(id), `invalid vector id ${JSON.stringify(id)}`);
	check(!ids.has(id), `duplicate vector id ${id}`);
	ids.add(id);
	check(typeof vector.input === 'string', `${id}: input must be a string`);
	for (const field of FIELDS) check(typeof vector[field] === 'string', `${id}: ${field} must be a string`);
	const drivers = vector.drivers || DRIVERS;
	for (const driver of drivers) {
		check(DRIVERS.includes(driver), `${id}: unknown driver ${driver}`);
		if (perDriver[driver] !== undefined) perDriver[driver] += 1;
	}
	const input = vector.input;
	check(vector.upper === input.toUpperCase(), `${id}: upper is not the Unicode uppercase of the input`);
	check(vector.lower === input.toLowerCase(), `${id}: lower is not the Unicode lowercase of the input`);
	check(vector.title === referenceTitle(input), `${id}: title does not follow the documented rule (${referenceTitle(input)})`);
	const hasLowercase = [...input].some((ch) => ch.toUpperCase() !== ch);
	check(vector.toggle_upper === (hasLowercase ? vector.upper : vector.lower), `${id}: toggle_upper breaks the toggle rule`);
	check(vector.toggle_title === (vector.title === input ? vector.lower : vector.title), `${id}: toggle_title breaks the toggle rule`);
}
for (const driver of DRIVERS) {
	check(perDriver[driver] >= 10, `only ${perDriver[driver]} vector(s) apply to ${driver}`);
}
for (const needed of ['élève', "l'", '-', 'ß', 'Σ']) {
	check((corpus.vectors || []).some((v) => v.input.includes(needed) || v.input.includes(needed.toUpperCase())),
		`the corpus must exercise ${needed}`);
}

// Each suite replays the corpus, and each replay is wired into its runner.
const CONSUMERS = [
	{ file: 'macos/tests/unit/modules/shortcuts/test_text_case_vectors.lua', path: 'tests/corpus/text_case/vectors.json' },
	{ file: 'linux/tests/unit/modules/shortcuts/test_text_case_vectors.lua', path: '_shared/tests/corpus/text_case/vectors.json' },
	{ file: 'windows/tests/unit/test_text_case_vectors.ahk', path: '\\tests\\corpus\\text_case\\vectors.json' }
];
for (const consumer of CONSUMERS) {
	const abs = path.join(SP, consumer.file);
	const source = fs.existsSync(abs) ? fs.readFileSync(abs, 'utf8') : '';
	check(source.includes(consumer.path), `${consumer.file} must read the shared text-case corpus`);
}
const linuxManifest = fs.readFileSync(path.join(SP, 'linux', 'tests', 'test_manifest.lua'), 'utf8');
check(linuxManifest.includes('"tests.unit.modules.shortcuts.test_text_case_vectors"'),
	'the Linux test manifest must list test_text_case_vectors');
const ahkRunner = fs.readFileSync(path.join(SP, 'windows', 'tests', 'run_all.ahk'), 'utf8');
check(/^#Include unit\/test_text_case_vectors\.ahk$/m.test(ahkRunner),
	'windows/tests/run_all.ahk must #Include unit/test_text_case_vectors.ahk');

if (errors.length > 0) {
	for (const error of errors) console.error(`[FAIL] ${error}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] shared text-case corpus: ${checks} check(s) passed (${corpus.vectors.length} vectors).\x1b[0m`);
