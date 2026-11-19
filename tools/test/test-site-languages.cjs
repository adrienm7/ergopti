// tools/test/test-site-languages.cjs

/**
 * ==============================================================================
 * MODULE: Site Foreign Passages Gate
 * DESCRIPTION:
 * The site is French; a screen reader reads an English quote, term or example
 * word in it with French rules unless an element around it says lang="en"
 * (WCAG 3.1.2). The Ergopti+ pages can also be read in English, which sets
 * lang="en" on the document, so the site's French chrome around them says
 * lang="fr" (TODO « Full accessibility », « Languages »).
 *
 * WHAT IS CHECKED:
 * 1. A detector lists, in the markup of every Svelte file under src/, the
 *    French text runs that hold English words: words at least
 *    ENGLISH_RATIO times more frequent in English than in French subtitles
 *    (static/corpus/frequency/opensubtitles_2018, tracked in the repository),
 *    outside an element that declares a language. The technical terms,
 *    key names and proper names that WCAG 3.1.2 exempts are listed in
 *    ACCEPTED_TERMS, reviewed by hand. What is left is ratcheted per file and
 *    word in site-foreign-passages-baseline.json: a new English passage
 *    without lang fails, and a removed one asks to lower the baseline
 *    (--update-baseline).
 * 2. The lang attributes added on 2026-11-19 stay (PINNED_PASSAGES): each
 *    pinned text sits inside an element of the stated language.
 * 3. The detector itself finds an English sentence, ignores French and
 *    accepted terms, and is silenced by lang="en".
 *
 * Text built by expressions ({…}) is out of its reach; the hand review of
 * the built pages covered it (docs/audits/accessibility/README.md).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SRC = path.join(ROOT, 'src');
const BASELINE_PATH = path.join(__dirname, 'site-foreign-passages-baseline.json');
const FREQUENCIES = path.join(ROOT, 'static', 'corpus', 'frequency', 'opensubtitles_2018');
// A word is English when its share of English subtitles is this many times
// its share of French ones, and it is common enough in English to judge.
const ENGLISH_RATIO = 20;
const ENGLISH_MIN_SHARE = 2e-6;

// Words WCAG 3.1.2 lets French text use without lang, each one met by the
// detector and reviewed on 2026-11-19: technical terms of the site (tap-hold,
// driver, layout, layer, bundle, ids…), names printed on keys (Shift, Enter,
// Home, End, Page Down, Delete, Control, Win), product and mode names
// (Windows, Kinesis Advantage, Sway, XKB Symbols and Rules, the Legacy
// method, Batch Avancé, « One-Shot »), and the
// anglicisms French readers say as French (open-source, open-weights,
// home-row, multi-touch).
const ACCEPTED_TERMS = new Set([
	'advantage',
	'batch',
	'bundle',
	'control',
	'delete',
	'down',
	'driver',
	'drivers',
	'end',
	'enter',
	'hold',
	'holds',
	'home',
	'ids',
	'layer',
	'layout',
	'legacy',
	'one',
	'open',
	'rules',
	'shift',
	'shot',
	'sway',
	'symbols',
	'tap',
	'taps',
	'touch',
	'weights',
	'win',
	'windows'
]);
// French words spelled like frequent English ones.
const FRENCH_HOMOGRAPHS = new Set(['natives', 'office', 'relatives', 'replace']);

// The lang attributes added on 2026-11-19: file, a text run inside the
// marked element, and its language.
const PINNED_PASSAGES = Object.freeze([
	['src/lib/components/SFB.svelte', 'Same Finger Bigram', 'en'],
	['src/routes/ergopti/informations/autocritiques.svelte', '1u Distance From Home', 'en'],
	['src/routes/ergopti/informations/autocritiques.svelte', 'people, does', 'en'],
	['src/routes/ergopti/informations/changelog.svelte', 'features', 'en'],
	['src/routes/ergopti/presentation/distance_doigts_touches.svelte', 'TYPEWRITER', 'en'],
	['src/routes/ergopti/presentation/minimisation_sfbs.svelte', 'Same Finger Bigrams', 'en'],
	['src/routes/ergopti/presentation/optimisation_roulements.svelte', 'rolls', 'en'],
	['src/routes/ergopti/presentation/optimisation_roulements.svelte', ', COU', 'en'],
	['src/routes/ergopti/presentation/optimisation_roulements.svelte', 'ALL', 'en'],
	['src/routes/ergopti/presentation/optimisation_roulements.svelte', 'MAN, ', 'en'],
	['src/routes/ergopti/presentation/optimisation_roulements.svelte', '-OU', 'en'],
	['src/routes/ergopti-plus-old/confort.svelte', '1u Distance From Home', 'en'],
	['src/routes/ergopti-plus-old/menu.svelte', 'features', 'en'],
	['src/routes/ergopti-plus-old/roulements.svelte', 'Data Scientists', 'en'],
	['src/routes/ergopti-plus-old/reduction_sfbs.svelte', 'does', 'en'],
	['src/routes/ergopti-plus-old/reduction_sfbs.svelte', 'people', 'en'],
	['src/routes/ergopti-plus/WindowChrome.svelte', '● live', 'en'],
	['src/routes/+layout.svelte', 'Aller au contenu', 'fr'],
	['src/routes/+layout.svelte', 'VERSION DE DEV', 'fr'],
	['src/routes/+layout.svelte', 'découvrez les nouveautés', 'fr'],
	['src/lib/components/Header.svelte', 'Optimisation de l’ergonomie clavier', 'fr'],
	['src/lib/components/Header.svelte', 'Contenu de la page', 'fr'],
	['src/lib/components/Footer.svelte', 'Repo GitHub', 'fr']
]);
// Labels drawn from English data ({p.name}: the model catalog's provider
// labels, « Other models » among them): the element itself says lang="en".
const PINNED_ATTRIBUTES = Object.freeze([
	['src/routes/ergopti-plus/AiSection.svelte', /<p class="provider-name" lang="en">\{p\.name\}/]
]);

/** A word list `word count` per line as a map of each word's share. */
function shares(file) {
	const counts = new Map();
	let total = 0;
	for (const line of fs.readFileSync(file, 'utf8').split('\n')) {
		const [word, count] = line.trim().split(' ');
		if (!word) continue;
		counts.set(word, Number(count));
		total += Number(count);
	}
	assert.ok(counts.size > 10000, 'Word list read: ' + file);
	for (const [word, count] of counts) counts.set(word, count / total);
	return counts;
}

const ENGLISH = shares(path.join(FREQUENCIES, 'en_50k.txt'));
const FRENCH = shares(path.join(FREQUENCIES, 'fr_50k.txt'));

/**
 * Whether a lower-case word reads as English rather than French. Two letters
 * are a bigram or a pair of keys here (TH, WH), of no language.
 */
function englishWord(word) {
	if (word.length < 3 || ACCEPTED_TERMS.has(word) || FRENCH_HOMOGRAPHS.has(word)) return false;
	const english = ENGLISH.get(word) || 0;
	return english > ENGLISH_MIN_SHARE && english > ENGLISH_RATIO * (FRENCH.get(word) || 0);
}

/** The markup of a component without its script, style and comments. */
function markup(source) {
	return source
		.replace(/<script[\s\S]*?<\/script>/g, '')
		.replace(/<style[\s\S]*?<\/style>/g, '')
		.replace(/<!--[\s\S]*?-->/g, '')
		.replace(/<svelte:head>[\s\S]*?<\/svelte:head>/g, '');
}

/** Markup with every Svelte expression `{…}` emptied (nested braces and strings included). */
function withoutExpressions(text) {
	let out = '';
	let depth = 0;
	let quote = null;
	for (let i = 0; i < text.length; i++) {
		const c = text[i];
		if (depth === 0) {
			if (c === '{') depth = 1;
			else out += c;
			continue;
		}
		if (quote) {
			if (c === '\\') i++;
			else if (c === quote) quote = null;
		} else if (c === "'" || c === '"' || c === '`') quote = c;
		else if (c === '{') depth++;
		else if (c === '}') depth--;
		if (depth === 0) out += ' ';
	}
	return out;
}

const VOID = /^(area|br|col|embed|hr|img|input|link|meta|source|track|wbr)$/i;

/**
 * The text runs of a component with the language declared around each one
 * (null when nothing in the file declares one: the page's French), and
 * whether the run is code (inside <code>, <pre> or <samp>: commands and
 * paths are no language's text).
 * @param {string} source
 * @returns {Array<{text: string, lang: string|null, code: boolean}>}
 */
function textRuns(source) {
	const runs = [];
	const stack = [{ lang: null, code: false }];
	const token = /<(\/?)([a-zA-Z][\w:.-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>|([^<]+)/g;
	for (const m of withoutExpressions(markup(source)).matchAll(token)) {
		const top = stack[stack.length - 1];
		if (m[5] !== undefined) {
			if (m[5].trim()) runs.push({ text: m[5], lang: top.lang, code: top.code });
			continue;
		}
		if (m[1]) {
			if (stack.length > 1) stack.pop();
		} else if (m[4] !== '/' && !VOID.test(m[2])) {
			const lang = /\slang="([^"]+)"/.exec(m[3]);
			stack.push({
				lang: lang ? lang[1] : top.lang,
				code: top.code || /^(code|pre|samp)$/i.test(m[2])
			});
		}
	}
	return runs;
}

/**
 * English words in the French runs of a component.
 * @returns {string[]} One entry per occurrence, lower case.
 */
function englishWordsOf(source) {
	const words = [];
	for (const run of textRuns(source)) {
		if (run.code || (run.lang !== null && run.lang !== 'fr')) continue;
		// Addresses and code identifiers (SERVER_NAME, KC_SPC) are no language's words.
		const text = run.text.replace(/\bhttps?:\/\/\S+/g, ' ');
		for (const word of text.toLowerCase().match(/[\p{L}\d_]+/gu) || [])
			if (!/[\d_]/.test(word) && englishWord(word)) words.push(word);
	}
	return words;
}

/** Every Svelte file under a directory, as paths relative to the repository. */
function svelteFiles(directory, out = []) {
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		if (entry.isDirectory()) svelteFiles(full, out);
		else if (entry.name.endsWith('.svelte'))
			out.push(path.relative(ROOT, full).split(path.sep).join('/'));
	}
	return out.sort();
}

/** The detector's counts over the site: `file | word` to occurrences. */
function measure() {
	const counts = {};
	for (const file of svelteFiles(SRC))
		for (const word of englishWordsOf(fs.readFileSync(path.join(ROOT, file), 'utf8'))) {
			const key = file + ' | ' + word;
			counts[key] = (counts[key] || 0) + 1;
		}
	return Object.fromEntries(Object.entries(counts).sort(([a], [b]) => a.localeCompare(b)));
}

// 3/ The detector sees an English sentence, not French or an accepted term.
assert.deepEqual(englishWordsOf('<p>Le clavier est rapide.</p>'), []);
assert.deepEqual(englishWordsOf('<p>Le tap-hold du driver Windows.</p>'), []);
assert.deepEqual(englishWordsOf('<p>Comme on dit, « the people who »</p>'), [
	'the',
	'people',
	'who'
]);
assert.deepEqual(
	englishWordsOf('<p>Comme on dit, « <span lang="en">the quick fox</span> »</p>'),
	[]
);
assert.deepEqual(englishWordsOf('<p>Un {"the quick fox"} calculé.</p>'), []);
assert.deepEqual(englishWordsOf('<div lang="fr"><p>« people »</p></div>'), ['people']);
assert.deepEqual(
	englishWordsOf('<p><code>people</code> https://people.example SERVER_PEOPLE</p>'),
	[]
);
assert.deepEqual(englishWordsOf('<p>TH, WH, il fait office de relatives</p>'), []);

// 1/ No new English passage without lang.
const current = measure();
if (process.argv.includes('--update-baseline')) {
	fs.writeFileSync(BASELINE_PATH, JSON.stringify(current, null, '\t') + '\n');
	console.log('test-site-languages: baseline written (' + Object.keys(current).length + ' rows)');
	process.exit(0);
}
const baseline = JSON.parse(fs.readFileSync(BASELINE_PATH, 'utf8'));
const added = [];
const lowered = [];
for (const [key, count] of Object.entries(current)) {
	const allowed = baseline[key] || 0;
	if (count > allowed) added.push(key + ': ' + count + ' (baseline ' + allowed + ')');
}
for (const [key, allowed] of Object.entries(baseline))
	if ((current[key] || 0) < allowed)
		lowered.push(key + ': ' + (current[key] || 0) + ' < ' + allowed);
assert.deepEqual(
	added,
	[],
	'English words in French text without lang="en": wrap the passage in an element with lang="en", or, for a technical term or name, add it to ACCEPTED_TERMS'
);
assert.deepEqual(
	lowered,
	[],
	'Fewer English passages than the baseline: lower it (node tools/test/test-site-languages.cjs --update-baseline)'
);

// 2/ The lang attributes added stay.
for (const [file, text, lang] of PINNED_PASSAGES) {
	const runs = textRuns(fs.readFileSync(path.join(ROOT, file), 'utf8'));
	const found = runs.filter((run) => run.text.replace(/\s+/g, ' ').includes(text));
	assert.ok(found.length > 0, file + ': pinned text not found: ' + text);
	assert.ok(
		found.every((run) => run.lang === lang),
		file + ': « ' + text + ' » must sit in an element with lang="' + lang + '"'
	);
}
for (const [file, pattern] of PINNED_ATTRIBUTES)
	assert.match(fs.readFileSync(path.join(ROOT, file), 'utf8'), pattern, file);

console.log(
	'test-site-languages: OK (' +
		svelteFiles(SRC).length +
		' components, ' +
		Object.keys(current).length +
		' accepted rows, ' +
		PINNED_PASSAGES.length +
		' pinned passages)'
);
