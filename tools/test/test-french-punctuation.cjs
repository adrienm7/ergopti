// tools/test/test-french-punctuation.cjs

/**
 * ==============================================================================
 * MODULE: French High Punctuation
 * DESCRIPTION:
 * French keeps a space before `:`, `?`, `!` and `;`. A catalogue string that
 * glues one to its word reads wrong, and so does a label a driver joins to its
 * value with a hardcoded colon, which no locale can respell.
 *
 * WHAT THIS PINS:
 *   1. No string of fr.json glues high punctuation to a word, URL schemes aside.
 *   2. common.label_value exists in every locale with {1} and {2} exactly once,
 *      and French spaces its colon.
 *   3. No driver source joins two texts with a hardcoded " : ": it goes through
 *      LabelValue (AHK) or locale.label_value (Lua).
 * The rendered rows are held in French by test-ahk-tray-rows-read-as-text.cjs
 * and the two Lua tray walks, through the same rule.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { frenchPunctuationDefect } = require('./lib/menu-row-text.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const ERGOPTI = path.join(ROOT, 'static', 'ergopti_plus');
const LOCALES = path.join(ERGOPTI, '_shared', 'core', 'i18n', 'data', 'locales');
const KEY = 'common.label_value';
const LOCALE_COUNT = 21;
const DRIVERS = ['_shared', 'windows', 'macos', 'linux'];
const SKIPPED_DIRECTORIES = new Set(['tests', 'test', '_generated', 'vendor', 'node_modules']);
// A concatenated " : ", in Lua (..) or AHK (.); an AHK ternary has no such dot.
const HARDCODED_JOIN = /(\.\.|\s\.=?)\s*" : "|" : "\s*(\.\.|\.\s)/;
const MIN_SOURCES = 500;

/**
 * Lists a driver's Lua and AHK sources, tests and generated code aside.
 * @param {string} directory Directory to walk.
 * @returns {string[]} Source paths.
 */
function sources(directory) {
	return fs.readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) return SKIPPED_DIRECTORIES.has(entry.name) ? [] : sources(full);
		return /\.(lua|ahk)$/.test(entry.name) ? [full] : [];
	});
}

// The rule itself must keep refusing what it exists to refuse.
assert.equal(frenchPunctuationDefect('Sans effet: rien'), 'effet:');
assert.equal(frenchPunctuationDefect('Vraiment?'), 'Vraiment?');
assert.equal(frenchPunctuationDefect('Attention! Oui'), 'Attention!');
assert.equal(frenchPunctuationDefect('un; deux'), 'un;');
assert.equal(frenchPunctuationDefect('Délai : 100 ; fin ?'), '');
assert.equal(frenchPunctuationDefect('« msteams: » ou « https: »'), '');
assert.equal(frenchPunctuationDefect('https://ergopti.fr'), '');
assert.equal(frenchPunctuationDefect('#! ➜ :='), '');

const french = JSON.parse(fs.readFileSync(path.join(LOCALES, 'fr.json'), 'utf8'));
const glued = Object.entries(french).flatMap(([key, text]) => {
	const defect = frenchPunctuationDefect(text);
	return defect ? [`${key}: "${defect}"`] : [];
});
assert.deepEqual(glued, [], 'French strings gluing high punctuation to a word');

const files = fs.readdirSync(LOCALES).filter((name) => name.endsWith('.json'));
assert.equal(files.length, LOCALE_COUNT);
for (const name of files) {
	const text = JSON.parse(fs.readFileSync(path.join(LOCALES, name), 'utf8'))[KEY];
	assert.equal(typeof text, 'string', `${name} has no ${KEY}`);
	assert.equal(text.split('{1}').length, 2, `${name}: ${KEY} needs {1} once`);
	assert.equal(text.split('{2}').length, 2, `${name}: ${KEY} needs {2} once`);
}
assert.equal(french[KEY], '{1} : {2}');

const scanned = DRIVERS.flatMap((driver) => sources(path.join(ERGOPTI, driver)));
assert.ok(scanned.length >= MIN_SOURCES, `only ${scanned.length} sources scanned`);
const joins = scanned.flatMap((file) =>
	fs
		.readFileSync(file, 'utf8')
		.split('\n')
		.flatMap((line, index) =>
			HARDCODED_JOIN.test(line) ? [`${path.relative(ROOT, file)}:${index + 1}`] : []
		)
);
assert.deepEqual(joins, [], 'hardcoded " : " joins; use LabelValue or locale.label_value');

console.log(
	`\x1b[32m[OK] French punctuation: ${Object.keys(french).length} strings, ` +
		`${files.length} locales, ${scanned.length} sources.\x1b[0m`
);
