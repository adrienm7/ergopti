// tools/test/test-ergopti-plus-languages.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page Languages Gate
 * DESCRIPTION:
 * The Ergopti+ pages can be read in English: the layout then sets
 * `lang="en"` on the document (WCAG 3.1.1). Their sections used to be written
 * in French only and said so with `lang="fr"`; the maintainer decided on
 * 2026-11-21 to translate them, together with the accessibility statement
 * and its settings dialog, through the Ergopti+ `t()` dictionary. This gate
 * keeps a French-only section from coming back under the English page.
 *
 * WHAT IS CHECKED:
 * 1. Every component of src/routes/ergopti-plus translates its text: it
 *    imports i18n.svelte.js, unless it shows no prose of its own (the list
 *    below says why for each). No root element says `lang="fr"`: a whole
 *    French section is what the translation removed.
 * 2. No translated file (those components, the accessibility statement and
 *    the settings dialog) writes French text in its markup outside `t()`,
 *    even inside an element that says `lang="fr"`: text with a letter
 *    English does not use (é, è, à, ç…) is taken as French. French example
 *    words built by expressions stay allowed in a `lang="fr"` element.
 * 3. Every literal `t()` key of those files has an English entry or is a
 *    word spelled the same in English (listed below).
 * 4. The checks can fail: each one is run on a French-only section.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.join(__dirname, '..', '..');
const DIR = path.join(ROOT, 'src', 'routes', 'ergopti-plus');
// Files outside the Ergopti+ pages that read in their language too.
const OTHER_TRANSLATED = [
	path.join(ROOT, 'src', 'routes', 'accessibilite', '+page.svelte'),
	path.join(ROOT, 'src', 'lib', 'components', 'A11ySettings.svelte')
];
// Components that show no prose of their own, so need no translation.
const NO_PROSE = {
	'DriverFrame.svelte': 'a window frame: a file path, sizes and an iframe with its own language',
	'WindowChrome.svelte': 'a window title bar: a file name and window buttons',
	'KpiStrip.svelte': 'numbers and labels its parent translates'
};
// Keys spelled the same in French and English (the French text is right in English).
const SAME_IN_ENGLISH = new Set([
	'Configuration',
	'FAQ',
	'Hotstrings',
	'Installation',
	'Auditable'
]);
const I18N_IMPORT = /i18n\.svelte\.js/;

/** The markup of a component without its script, style, head and comments. */
function markup(source) {
	return source
		.replace(/<script[\s\S]*?<\/script>/g, '')
		.replace(/<style[\s\S]*?<\/style>/g, '')
		.replace(/<svelte:head>[\s\S]*?<\/svelte:head>/g, '')
		.replace(/<!--[\s\S]*?-->/g, '');
}

/** The opening tags at depth 0 of a component's markup. */
function rootTags(source) {
	const roots = [];
	let depth = 0;
	const tag = /<(\/?)([a-zA-Z][\w:.-]*)((?:[^>"'{]|"[^"]*"|'[^']*'|\{[^}]*\})*?)(\/?)>/g;
	for (const m of markup(source).matchAll(tag)) {
		const isVoid = m[4] === '/' || /^(br|hr|img|input|link|meta|source)$/i.test(m[2]);
		if (m[1]) depth--;
		else {
			if (depth === 0) roots.push(m[0]);
			if (!isVoid) depth++;
		}
	}
	return roots;
}

/**
 * The French-only components among some Svelte sources.
 * @param {Array<[string, string]>} sources [name, source] pairs.
 * @returns {string[]} One entry per refusal.
 */
function frenchOnlyComponents(sources) {
	const refused = [];
	for (const [name, source] of sources) {
		if (name.startsWith('+') || NO_PROSE[name]) continue;
		const roots = rootTags(source);
		assert.ok(roots.length > 0, name + ': no markup found');
		if (!I18N_IMPORT.test(source)) refused.push(name + ': does not translate (no i18n.svelte.js)');
		for (const root of roots)
			if (/\slang="fr"/.test(root)) refused.push(name + ': French root ' + root.slice(0, 60));
	}
	return refused;
}

const FRENCH = /[àâçéèêëîïôœùû]/i;
// Proper names with such letters, right in any language.
const NAMES = /Bépo|BÉPO/g;

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
		if (depth === 0) out += '{}';
	}
	return out;
}

/**
 * French text written outside t() in a source, whatever language its
 * elements declare.
 * @param {string} name
 * @param {string} source
 * @returns {string[]}
 */
function untranslatedFrench(name, source) {
	const found = [];
	const text = /(?:^|>)([^<]+)/g;
	for (const m of withoutExpressions(markup(source)).matchAll(text)) {
		const run = m[1].replace(NAMES, '');
		if (FRENCH.test(run)) found.push(name + ': ' + run.trim().slice(0, 60));
	}
	// Names a screen reader says count as text too.
	const label = /\s(?:aria-label|title|alt|placeholder)="([^"]*)"/g;
	for (const m of markup(source).matchAll(label)) {
		const run = m[1].replace(NAMES, '');
		if (FRENCH.test(run)) found.push(name + ': ' + run.trim().slice(0, 60));
	}
	return found;
}

// 4/ The checks can fail on a French-only section.
const FRENCH_SECTION = '<section lang="fr"><h2>Une section en français</h2></section>';
assert.deepEqual(frenchOnlyComponents([['Sample.svelte', FRENCH_SECTION]]), [
	'Sample.svelte: does not translate (no i18n.svelte.js)',
	'Sample.svelte: French root <section lang="fr">'
]);
assert.deepEqual(
	frenchOnlyComponents([
		['Sample.svelte', "<script>import { t } from './i18n.svelte.js';</script><p>{t('Mot')}</p>"]
	]),
	[]
);
assert.deepEqual(untranslatedFrench('Sample.svelte', FRENCH_SECTION), [
	'Sample.svelte: Une section en français'
]);
assert.deepEqual(untranslatedFrench('Sample.svelte', '<ul lang="fr"><li>{word}</li></ul>'), []);
assert.deepEqual(
	untranslatedFrench('Sample.svelte', '<button aria-label="Fermer la fenêtre"></button>'),
	['Sample.svelte: Fermer la fenêtre']
);

// 1/ Every Ergopti+ component translates.
const components = fs.readdirSync(DIR).filter((name) => name.endsWith('.svelte'));
assert.ok(components.length > 15, 'The Ergopti+ components are found');
const sources = components.map((name) => [name, fs.readFileSync(path.join(DIR, name), 'utf8')]);
assert.deepEqual(
	frenchOnlyComponents(sources),
	[],
	'A French-only section is back under the English page: translate it through t() and locales/en.js'
);
for (const name of Object.keys(NO_PROSE))
	assert.ok(components.includes(name), 'NO_PROSE names a missing component: ' + name);
for (const file of OTHER_TRANSLATED)
	assert.match(
		fs.readFileSync(file, 'utf8'),
		I18N_IMPORT,
		path.relative(ROOT, file).split(path.sep).join('/') + ' must translate through the Ergopti+ t()'
	);

// 2/ No French text outside t() in a translated file.
/** Every Svelte file under a directory. */
function svelteFiles(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const file = path.join(dir, entry.name);
		if (entry.isDirectory()) svelteFiles(file, out);
		else if (entry.name.endsWith('.svelte')) out.push(file);
	}
	return out;
}
const translated = svelteFiles(DIR)
	.filter((file) => I18N_IMPORT.test(fs.readFileSync(file, 'utf8')))
	.concat(OTHER_TRANSLATED);
const untagged = [];
for (const file of translated)
	untagged.push(
		...untranslatedFrench(
			path.relative(ROOT, file).split(path.sep).join('/'),
			fs.readFileSync(file, 'utf8')
		)
	);
assert.deepEqual(untagged, [], 'French text outside t() is French under the English page too');

// 3/ Every literal t() key has its English entry.
(async () => {
	const { pathToFileURL } = require('node:url');
	const en = (await import(pathToFileURL(path.join(DIR, 'locales', 'en.js')).href)).default;
	const missing = [];
	for (const file of svelteFiles(DIR).concat(OTHER_TRANSLATED))
		for (const m of fs.readFileSync(file, 'utf8').matchAll(/\bt\(\s*'((?:\\.|[^'\\])*)'/g)) {
			const key = m[1].replace(/\\'/g, "'");
			if (!(key in en) && !SAME_IN_ENGLISH.has(key))
				missing.push(path.relative(ROOT, file).split(path.sep).join('/') + ': ' + key);
		}
	assert.deepEqual(
		missing,
		[],
		'A t() key with no English entry falls back to French under lang="en"'
	);
	console.log(
		`test-ergopti-plus-languages: OK (${components.length} components and ${OTHER_TRANSLATED.length} other files translated, no French-only section)`
	);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
