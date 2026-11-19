// tools/test/test-studio-reading-preferences.cjs

/**
 * ==============================================================================
 * MODULE: Studio Reading Preferences
 * DESCRIPTION:
 * Every Ergopti Studio page, on the site and in the app's windows, honours the
 * visitor's reading preferences (hyperlegible font, larger text, WCAG 1.4.12
 * spacing, reduced motion, high contrast): each one loads the shared theme and
 * then the one owner of those preferences, _shared/ui/a11y_prefs.js, as a
 * plain synchronous script in its head, so they apply before the first paint
 * and the macOS builder, which inlines only the exact `<script src>` form,
 * carries it into the app. The font the preference names is bundled with the
 * site (static/fonts/atkinson-hyperlegible) and theme.css styles every
 * preference.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { scriptElements, startTags } = require('./lib/html-scan.cjs');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const UI = path.join(REPO_ROOT, 'static', 'ergopti_plus', '_shared', 'ui');
// The Studio's pages: the three the site frames, the app's Studio window and
// the layout manager window it opens.
const PAGES = Object.freeze([
	'layout_analysis/index.html',
	'layout_editor/index.html',
	'layout_optimizer/index.html',
	'layout_editor_window/index.html',
	'layout_manager/index.html'
]);
const PREFS_SCRIPT = '../a11y_prefs.js';
const THEME = '../theme.css';

for (const page of PAGES) {
	const html = fs.readFileSync(path.join(UI, page), 'utf8');
	const head = html.slice(0, html.search(/<body[\s>]/i));
	assert.ok(head.length > 0 && head.length < html.length, `${page}: has a head and a body`);
	const scripts = scriptElements(head).map((script) => {
		const src = /\ssrc="([^"]+)"/.exec(script.attributes);
		return { src: src ? src[1] : '', attributes: script.attributes };
	});
	const prefs = scripts.find((script) => script.src === PREFS_SCRIPT);
	assert.ok(prefs, `${page}: loads ${PREFS_SCRIPT} in its head`);
	assert.doesNotMatch(prefs.attributes, /\s(?:async|defer|type=)/, `${page}: as a plain script`);
	const links = startTags(head, ['link']).map(
		(link) => (/\shref="([^"]+)"/.exec(link.tag) || [])[1]
	);
	assert.ok(links.includes(THEME), `${page}: links ${THEME}`);
	assert.ok(
		head.indexOf(`href="${THEME}"`) < head.indexOf(`src="${PREFS_SCRIPT}"`),
		`${page}: the theme comes before the preferences script`
	);
}

const theme = fs.readFileSync(path.join(UI, 'theme.css'), 'utf8');
for (const attribute of [
	"data-a11y-font='hyperlegible'",
	"data-a11y-spacing='wide'",
	"data-a11y-motion='reduce'",
	"data-a11y-text='200'",
	"data-a11y-contrast='high'"
])
	assert.ok(theme.includes(attribute), `theme.css styles ${attribute}`);
assert.ok(
	fs.existsSync(path.join(REPO_ROOT, 'static', 'fonts', 'atkinson-hyperlegible', 'font.css')),
	'the hyperlegible font is bundled'
);

console.log(`PASS test-studio-reading-preferences (${PAGES.length} pages)`);
