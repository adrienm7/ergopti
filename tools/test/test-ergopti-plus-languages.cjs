// tools/test/test-ergopti-plus-languages.cjs

/**
 * ==============================================================================
 * MODULE: Ergopti+ Page Languages Gate
 * DESCRIPTION:
 * The Ergopti+ pages can be read in English: the layout then sets
 * `lang="en"` on the document (WCAG 3.1.1). Their sections written in French
 * only (no `t()` call, no English dictionary entry) kept no language of
 * their own, so a screen reader read their French with English rules.
 *
 * WHAT IS CHECKED:
 * 1. Every component of src/routes/ergopti-plus that does not translate its
 *    text (no import of i18n.svelte.js) declares `lang="fr"` on each of its
 *    root elements (WCAG 3.1.2), unless it shows no prose of its own (the
 *    list below says why for each).
 * 2. A component that does translate writes no French text in its markup
 *    outside `t()` unless an enclosing element declares its language (the
 *    installation page kept five French blocks this way): text with a letter
 *    English does not use (é, è, à, ç…) is taken as French.
 * 3. Every literal `t()` key of the page has an English entry or is a word
 *    spelled the same in English (listed below).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const DIR = path.join(__dirname, '..', '..', 'src', 'routes', 'ergopti-plus');
// Components that show no prose of their own, so need no language.
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

/** The markup of a component without its script, style and comments. */
function markup(source) {
	return source
		.replace(/<script[\s\S]*?<\/script>/g, '')
		.replace(/<style[\s\S]*?<\/style>/g, '')
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

const components = fs.readdirSync(DIR).filter((name) => name.endsWith('.svelte'));
assert.ok(components.length > 15, 'The Ergopti+ components are found');
const unnamed = [];
for (const name of components) {
	const source = fs.readFileSync(path.join(DIR, name), 'utf8');
	if (/i18n\.svelte\.js/.test(source) || name.startsWith('+')) continue;
	if (NO_PROSE[name]) continue;
	const roots = rootTags(source);
	assert.ok(roots.length > 0, name + ': no markup found');
	for (const root of roots)
		if (!/\slang="fr"/.test(root)) unnamed.push(name + ': ' + root.slice(0, 60));
}
assert.deepEqual(unnamed, [], 'A French-only section must say it is French (lang="fr")');
for (const name of Object.keys(NO_PROSE))
	assert.ok(components.includes(name), 'NO_PROSE names a missing component: ' + name);

// 2/ No French text outside t() in a translated component, unless declared.
const FRENCH = /[àâçéèêëîïôœùû]/i;
// Proper names with such letters, right in any language.
const NAMES = /Bépo/g;
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

const untagged = [];
for (const name of components) {
	const source = fs.readFileSync(path.join(DIR, name), 'utf8');
	if (!/i18n\.svelte\.js/.test(source)) continue;
	// One entry per open element: whether it or an ancestor declares a language.
	const stack = [false];
	const token = /<(\/?)([a-zA-Z][\w:.-]*)((?:[^>"']|"[^"]*"|'[^']*')*?)(\/?)>|([^<]+)/g;
	for (const m of withoutExpressions(markup(source)).matchAll(token)) {
		if (m[5] !== undefined) {
			const text = m[5].replace(NAMES, '');
			if (!stack[stack.length - 1] && FRENCH.test(text))
				untagged.push(name + ': ' + text.trim().slice(0, 60));
			continue;
		}
		const isVoid = m[4] === '/' || /^(br|hr|img|input|link|meta|source)$/i.test(m[2]);
		if (m[1]) stack.pop();
		else if (!isVoid) stack.push(stack[stack.length - 1] || /\slang=/.test(m[3]));
	}
}
assert.deepEqual(
	untagged,
	[],
	'French text outside t() must sit in an element that says lang="fr"'
);

// 3/ Every literal t() key has its English entry.
(async () => {
	const { pathToFileURL } = require('node:url');
	const en = (await import(pathToFileURL(path.join(DIR, 'locales', 'en.js')).href)).default;
	const missing = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const file = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (entry.name !== 'locales') walk(file);
			} else if (entry.name.endsWith('.svelte')) {
				for (const m of fs.readFileSync(file, 'utf8').matchAll(/\bt\(\s*'((?:\\.|[^'\\])*)'/g)) {
					const key = m[1].replace(/\\'/g, "'");
					if (!(key in en) && !SAME_IN_ENGLISH.has(key)) missing.push(entry.name + ': ' + key);
				}
			}
		}
	};
	walk(DIR);
	assert.deepEqual(
		missing,
		[],
		'A t() key with no English entry falls back to French under lang="en"'
	);
	console.log(
		`test-ergopti-plus-languages: OK (${components.length} components, French-only sections marked)`
	);
})().catch((error) => {
	console.error(error);
	process.exit(1);
});
