// tools/test/test-page-direction.cjs

/**
 * ==============================================================================
 * MODULE: Shared Page Writing Direction Gate (PCK-22)
 * DESCRIPTION:
 * No app window set dir for Arabic or Hebrew: the text was translated and the
 * layout stayed left to right on the three drivers. _shared/ui/page_locale.js
 * now owns the root lang and dir. This gate checks that:
 * 1. every shared page loads ../page_locale.js in its head, right after
 *    a11y_prefs.js and so before its own scripts and i18n.js: the direction
 *    is set before the body draws;
 * 2. the script, run with each shipped locale seeded, sets lang to the locale
 *    and dir to rtl exactly for the locales whose native name is written in a
 *    right-to-left script (locale_names.json), ltr for the others;
 * 3. no other shared script writes the root lang or dir itself, and the pages
 *    that change language after load (i18n.js, onboarding, physical
 *    shortcuts) go through window.setPageLocale;
 * 4. no app window rule names a physical left or right margin, padding,
 *    border or text alignment, which dir cannot mirror.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const UI = path.resolve(__dirname, '../../static/ergopti_plus/_shared/ui');
const I18N_DATA = path.resolve(__dirname, '../../static/ergopti_plus/_shared/core/i18n/data');
const SCRIPT = path.join(UI, 'page_locale.js');

// Hebrew, Arabic, Syriac, Thaana, NKo and their presentation forms.
const RTL_SCRIPT = /[֐-ࣿיִ-﷿ﹰ-﻿]/u;

/** Runs page_locale.js against a minimal root, with a seeded locale. */
function run(seed) {
	const root = { lang: 'fr', dir: '' };
	const context = vm.createContext({ document: { documentElement: root } });
	context.window = context;
	if (seed !== undefined) context._i18n_locale = seed;
	vm.runInContext(fs.readFileSync(SCRIPT, 'utf8'), context);
	return { root, context };
}

// 1. Every page loads the owner first.
const pages = fs
	.readdirSync(UI, { withFileTypes: true })
	.filter((entry) => entry.isDirectory() && fs.existsSync(path.join(UI, entry.name, 'index.html')))
	.map((entry) => entry.name);
assert.ok(pages.length >= 20, `only ${pages.length} shared pages found: the scan moved`);
const missing = [];
for (const page of pages) {
	const html = fs.readFileSync(path.join(UI, page, 'index.html'), 'utf8');
	const head = html.slice(0, html.indexOf('</head>'));
	const scripts = [...head.matchAll(/<script\b[^>]*\bsrc="([^"]+)"/g)].map((m) => m[1]);
	const prefs = scripts.indexOf('../a11y_prefs.js');
	if (prefs === -1 || scripts[prefs + 1] !== '../page_locale.js') missing.push(page);
}
assert.deepEqual(
	missing,
	[],
	'pck-22: these pages do not load ../page_locale.js right after a11y_prefs.js in their head'
);

// 2. The direction follows the locale, for every shipped locale.
const order = JSON.parse(fs.readFileSync(path.join(I18N_DATA, 'locale_order.json'), 'utf8')).order;
const names = JSON.parse(
	fs.readFileSync(path.join(I18N_DATA, 'locale_names.json'), 'utf8')
).locales;
const rtl = order.filter((code) => RTL_SCRIPT.test(names[code].name));
assert.deepEqual(rtl.sort(), ['ar', 'he'], 'the shipped right-to-left locales');
for (const code of order) {
	const { root } = run(code);
	assert.equal(root.lang, code, `${code}: the root names the locale`);
	assert.equal(
		root.dir,
		rtl.includes(code) ? 'rtl' : 'ltr',
		`pck-22: ${code} lays out in its direction`
	);
}
for (const [code, dir] of [
	['AR', 'rtl'],
	['he-IL', 'rtl'],
	['pt-BR', 'ltr']
]) {
	assert.equal(
		run(code).root.dir,
		dir,
		`${code}: a region or a case keeps the language's direction`
	);
}
const unseeded = run(undefined);
assert.equal(unseeded.root.dir, '', 'an unseeded page keeps its markup until a locale is known');
unseeded.context.setPageLocale('ar');
assert.equal(unseeded.root.dir, 'rtl', 'a later setPageLocale sets the direction');
assert.throws(
	() => unseeded.context.setPageLocale(''),
	/a locale code is required/,
	'an empty code is a host defect'
);

// 3. One owner of the root lang and dir.
const writers = [];
function scan(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (!['vendor', 'fonts'].includes(entry.name)) scan(full);
		} else if (/\.(js|html)$/.test(entry.name) && full !== SCRIPT) {
			const text = fs.readFileSync(full, 'utf8');
			if (
				/documentElement\.(lang|dir)\s*=(?!=)|documentElement\.setAttribute\(\s*['"](lang|dir)['"]/.test(
					text
				)
			)
				writers.push(path.relative(UI, full));
		}
	}
}
scan(UI);
assert.deepEqual(writers, [], 'pck-22: only page_locale.js writes the root lang and dir');
for (const file of ['i18n.js', 'onboarding/script.js', 'physical_shortcuts/script.js']) {
	assert.ok(
		fs.readFileSync(path.join(UI, file), 'utf8').includes('window.setPageLocale('),
		`${file} sets its locale through page_locale.js`
	);
}

// 4. The app windows lay out by the logical start and end, so dir mirrors
// them: a physical left or right margin, padding, border or text alignment
// stays on the same side in Arabic and Hebrew. Studio pages draw keyboards,
// whose geometry is physical, and belong to the Studio campaign.
const STUDIO = new Set([
	'layout_analysis',
	'layout_editor',
	'layout_editor_window',
	'layout_manager',
	'layout_optimizer'
]);
const PHYSICAL = [
	/(?<![-\w])(margin|padding|border)-(left|right)(-\w+)?\s*:/,
	/text-align:\s*(left|right)\b/,
	/\.style\.(margin|padding)(Left|Right)\b/,
	/\.style\.textAlign\s*=\s*['"](left|right)['"]/
];
const physical = [];
function scanStyles(dir) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		const rel = path.relative(UI, full).split(path.sep);
		if (entry.isDirectory()) {
			if (!['vendor', 'fonts', '_generated'].includes(entry.name) && !STUDIO.has(rel[0]))
				scanStyles(full);
		} else if (/\.(css|js|html)$/.test(entry.name)) {
			fs.readFileSync(full, 'utf8')
				.split('\n')
				.forEach((line, index) => {
					if (PHYSICAL.some((re) => re.test(line))) physical.push(`${rel.join('/')}:${index + 1}`);
				});
		}
	}
}
scanStyles(UI);
assert.deepEqual(
	physical,
	[],
	'pck-22: these app window rules do not follow the writing direction'
);

console.log(`\x1b[32m[OK] ${pages.length} shared pages set lang and dir from the locale.\x1b[0m`);
