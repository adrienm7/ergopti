// tools/test/test-studio-plain-language.cjs

/**
 * ==============================================================================
 * MODULE: Studio Plain Language
 * DESCRIPTION:
 * WCAG 3.1.5 (reading level) for the Studio's own words. The site's reading
 * gate counts sentences of 30 words or more in a page's running text but
 * leaves the Studio frames out, because their words are the 21 locales'
 * catalogue. This test reads that catalogue instead: every string of the
 * Studio's namespaces, in every locale, is cut into sentences by the reading
 * gate's rule, and a sentence of 30 words or more is a row. The rows left are
 * pinned per locale and key in studio-plain-language-baseline.json: a new row
 * fails, and so does a pinned row that is gone, so the baseline only shrinks.
 * A cut must keep a number tied to its word: an English or French Studio
 * string that writes a placeholder then a breaking space and a word, where
 * most locales tie that placeholder with a no-break space (U+00A0), is a
 * failure (the 2026-11-25 cut broke « {keys} busiest » that way, which the
 * studio-numbers browser case found).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const LOCALES_DIR = path.join(
	__dirname,
	'..',
	'..',
	'static',
	'ergopti_plus',
	'_shared',
	'core',
	'i18n',
	'data',
	'locales'
);
const BASELINE_PATH = path.join(__dirname, 'studio-plain-language-baseline.json');

// The Studio's frames (the Comparer, the editor, the Optimiser and the « Try »
// field) draw their words from these namespaces only.
const STUDIO_KEY = /^(layout_analysis|layout_editor|layout_optimizer|layout_try)\./;

// Formulas are written with symbols and are not running text.
const NOT_PROSE = /^layout_analysis\.formula\./;

// Japanese and Chinese put no space between words, so a word count cannot
// measure them; their review is part of the manual audit.
const UNSPACED_LOCALES = new Set(['ja', 'zh']);

// The site reading gate's threshold (site-reading.cjs MAX_SENTENCE_WORDS).
const MAX_SENTENCE_WORDS = 29;

/**
 * Cuts a catalogue string into sentences: after a full stop, a question or
 * exclamation mark, an ellipsis, a danda or an ideographic stop followed by a
 * space and a character that is not a lower-case letter. This is the reading
 * gate's rule, widened to scripts that have no capitals.
 * @param {string} text The catalogue string.
 * @returns {string[]} Its sentences.
 */
function sentencesOf(text) {
	return text
		.replace(/<[^>]+>/g, ' ')
		.replace(/\s+/g, ' ')
		.trim()
		.split(/(?<=[.!?…।。！？])\s+(?=[^\p{Ll}])/u);
}

/**
 * Counts the words of a sentence: the space-separated parts holding a letter
 * or a digit, as the reading gate counts them.
 * @param {string} sentence One sentence.
 * @returns {number} Its word count.
 */
function wordCount(sentence) {
	return sentence.split(' ').filter((word) => /[\p{L}\p{N}]/u.test(word)).length;
}

/**
 * Lists the long sentences of one locale's Studio strings.
 * @param {Record<string, unknown>} catalogue One locale's flat key map.
 * @returns {Map<string, number>} Key to its number of long sentences.
 */
function longSentences(catalogue) {
	const rows = new Map();
	for (const [key, value] of Object.entries(catalogue)) {
		if (!STUDIO_KEY.test(key) || NOT_PROSE.test(key) || typeof value !== 'string') continue;
		const long = sentencesOf(value).filter((s) => wordCount(s) > MAX_SENTENCE_WORDS).length;
		if (long > 0) rows.set(key, long);
	}
	return rows;
}

// The detector itself: one long sentence is a row, the same words cut in two
// are none, a string outside the Studio is never read, and an uncased script
// is cut at its stops.
const LONG = Array.from({ length: 30 }, (_, i) => `word${i}`).join(' ') + '.';
assert.deepEqual([...longSentences({ 'layout_editor.a': LONG })], [['layout_editor.a', 1]]);
assert.equal(
	longSentences({ 'layout_editor.a': LONG.replace('word15 ', 'word15. Word ') }).size,
	0,
	'a sentence cut in two is not a row'
);
assert.equal(longSentences({ 'menu.a': LONG }).size, 0, 'only Studio keys are read');
assert.equal(
	longSentences({ 'layout_analysis.formula.a': LONG }).size,
	0,
	'formulas are not prose'
);
assert.equal(
	sentencesOf('واحد اثنان. ثلاثة أربعة').length,
	2,
	'a script without capitals is cut after its full stop'
);

/**
 * The placeholders a Studio string ties to the next word with a no-break
 * space, or leaves with a breaking one.
 * @param {string} text The catalogue string.
 * @returns {{tied: Set<string>, broken: Set<string>}} Placeholder names.
 */
function placeholderSpaces(text) {
	const tied = new Set();
	const broken = new Set();
	for (const match of text.matchAll(/\{(\w+)\}([ \u00a0])(?=\p{L})/gu))
		(match[2] === ' ' ? broken : tied).add(match[1]);
	return { tied, broken };
}

/**
 * The English and French Studio strings that break a placeholder from its
 * word where most locales tie it.
 * @param {Record<string, Record<string, unknown>>} catalogues Locale to flat key map.
 * @returns {string[]} « locale | key | {name} » rows.
 */
function brokenTies(catalogues) {
	const rows = [];
	const locales = Object.keys(catalogues);
	for (const [key, english] of Object.entries(catalogues.en)) {
		if (!STUDIO_KEY.test(key) || typeof english !== 'string') continue;
		const spaces = locales
			.filter((locale) => typeof catalogues[locale][key] === 'string')
			.map((locale) => [locale, placeholderSpaces(catalogues[locale][key])]);
		for (const [locale, own] of spaces.filter(([locale]) => locale === 'en' || locale === 'fr'))
			for (const name of own.broken) {
				const tying = spaces.filter(([, other]) => other.tied.has(name)).length;
				const breaking = spaces.filter(([, other]) => other.broken.has(name)).length;
				if (tying > breaking) rows.push(`${locale} | ${key} | {${name}}`);
			}
	}
	return rows;
}

// The tie detector: a French string breaking what the others tie is a row,
// a placeholder every locale breaks alike is none.
assert.deepEqual(
	brokenTies({
		en: { 'layout_analysis.a': 'The {keys}\u00a0busiest', 'layout_analysis.b': '{name} wins' },
		fr: { 'layout_analysis.a': 'Les {keys} touches', 'layout_analysis.b': '{name} gagne' },
		de: { 'layout_analysis.a': 'Die {keys}\u00a0Tasten', 'layout_analysis.b': '{name} gewinnt' }
	}),
	['fr | layout_analysis.a | {keys}']
);

const found = {};
for (const file of fs
	.readdirSync(LOCALES_DIR)
	.filter((f) => f.endsWith('.json'))
	.sort()) {
	const locale = path.basename(file, '.json');
	if (UNSPACED_LOCALES.has(locale)) continue;
	const catalogue = JSON.parse(fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8'));
	for (const [key, count] of longSentences(catalogue)) found[`${locale} | ${key}`] = count;
}

const catalogues = {};
for (const file of fs.readdirSync(LOCALES_DIR).filter((f) => f.endsWith('.json')))
	catalogues[path.basename(file, '.json')] = JSON.parse(
		fs.readFileSync(path.join(LOCALES_DIR, file), 'utf8')
	);

const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
const failures = [];
for (const row of brokenTies(catalogues))
	failures.push(`a number cut from its word (tie it with U+00A0, as the other locales do): ${row}`);
for (const [row, count] of Object.entries(found)) {
	if (!(row in baseline)) failures.push(`new long sentence: ${row} (${count})`);
	else if (count > baseline[row])
		failures.push(`more long sentences: ${row} (${baseline[row]} → ${count})`);
}
for (const [row, count] of Object.entries(baseline)) {
	if (!(row in found)) failures.push(`gone, remove it from the baseline: ${row}`);
	else if (found[row] < count)
		failures.push(`fewer, lower the baseline: ${row} (${count} → ${found[row]})`);
}
for (const english of Object.keys(baseline).filter((row) => /^(en|fr) \| /.test(row)))
	failures.push(`the English and French sources are cut, not pinned: ${english}`);

if (failures.length > 0) {
	console.error(
		'Studio strings with a sentence of 30 words or more (WCAG 3.1.5), or a number cut from its word: fix them as each row says.\n  ' +
			failures.join('\n  ')
	);
	process.exit(1);
}
console.log(
	`test-studio-plain-language: OK — ${Object.keys(found).length} pinned rows left, no new long sentence.`
);
