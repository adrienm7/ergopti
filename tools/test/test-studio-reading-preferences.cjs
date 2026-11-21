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
 * carries it into the app. theme.css styles every preference, and every
 * reading font the script names sits in _shared/ui/fonts/, beside the pages:
 * the site serves it from there, and the Windows bundle (asked of its builder,
 * build_static_bundle.py --list) ships each of its files, as the Linux and
 * macOS packages ship the whole folder. The fonts lived in static/fonts/,
 * which only the site served, so no app window could load them.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { scriptElements, startTags } = require('./lib/html-scan.cjs');

const REPO_ROOT = path.resolve(__dirname, '..', '..');
const UI = path.join(REPO_ROOT, 'static', 'ergopti_plus', '_shared', 'ui');
// The Studio's pages: the four the site frames, the app's Studio window and
// the layout manager window it opens.
const PAGES = Object.freeze([
	'layout_analysis/index.html',
	'layout_editor/index.html',
	'layout_optimizer/index.html',
	'layout_try/index.html',
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

/** The files the compiled Windows app embeds, from its bundle builder. */
function windowsBundleFiles() {
	const builder = path.join(REPO_ROOT, 'tools', 'build', 'build_static_bundle.py');
	for (const [command, prefix] of [
		['python3', []],
		['py', ['-3']],
		['python', []]
	]) {
		// The Windows Store stub of python3 exists and fails: probe first.
		if (spawnSync(command, [...prefix, '--version'], { encoding: 'utf8' }).status !== 0) continue;
		const run = spawnSync(command, [...prefix, builder, '--list'], {
			cwd: REPO_ROOT,
			encoding: 'utf8',
			maxBuffer: 64 * 1024 * 1024
		});
		assert.equal(run.status, 0, `build_static_bundle.py --list: ${run.stderr}`);
		return new Set(JSON.parse(run.stdout).files.map((file) => file.source.replace(/\\/g, '/')));
	}
	throw new Error('no Python interpreter runs build_static_bundle.py');
}

const prefsSource = fs.readFileSync(path.join(UI, 'a11y_prefs.js'), 'utf8');
const folders = /FONT_FOLDERS = \{([^}]*)\}/.exec(prefsSource);
assert.ok(folders, 'a11y_prefs.js names its font folders');
const fontFolders = [...folders[1].matchAll(/'([^']+)'/g)].map((match) => match[1]);
assert.deepEqual(fontFolders, ['atkinson-hyperlegible', 'opendyslexic']);
assert.match(
	prefsSource,
	/new URL\('fonts\/' \+ FONT_FOLDERS\[font\] \+ '\/font\.css', SCRIPT_SRC\)/,
	'a11y_prefs.js links the font beside itself'
);
const shipped = windowsBundleFiles();
for (const folder of fontFolders) {
	const relative = `static/ergopti_plus/_shared/ui/fonts/${folder}`;
	const css = fs.readFileSync(path.join(REPO_ROOT, relative, 'font.css'), 'utf8');
	const files = ['font.css', 'OFL.txt', ...[...css.matchAll(/url\('([^']+)'\)/g)].map((m) => m[1])];
	assert.ok(files.length > 2, `${folder}: font.css names its files`);
	for (const file of files) {
		assert.ok(fs.existsSync(path.join(REPO_ROOT, relative, file)), `${relative}/${file} exists`);
		assert.ok(shipped.has(`${relative}/${file}`), `the Windows app ships ${relative}/${file}`);
	}
}

console.log(`PASS test-studio-reading-preferences (${PAGES.length} pages)`);
