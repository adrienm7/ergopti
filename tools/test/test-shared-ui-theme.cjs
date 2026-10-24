// tools/test/test-shared-ui-theme.cjs

/**
 * ==============================================================================
 * MODULE: Shared UI Theme Guard
 * DESCRIPTION:
 * Holds the shared pages to `_shared/ui/theme.css`, the one place their
 * recurring colours are written.
 *
 * ROOT CAUSE ENCODED:
 * Every page typed its own palette: the accent was declared 19 times with five
 * values, the system red appeared in fourteen files, and the three dialog
 * pages carried the same eleven colours each. A colour tuned in one page
 * silently drifted from its siblings. The theme fixes the values once; this
 * guard keeps them fixed:
 * 1. A palette colour typed as a literal in a page is a second copy of it.
 * 2. A token a page uses but the theme does not declare resolves to nothing,
 *    and the browser paints the property's initial value with no error.
 * 3. A page that uses a token without linking the theme gets the same silent
 *    fallback. The link must keep the spelling the macOS and Linux builders
 *    inline (`<link rel="stylesheet" href="…" />`), or those drivers drop it.
 * 4. A page redeclaring a theme token forks the theme for itself.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { shared } = require('../lib/paths.cjs');

const UI = shared('ui');
const THEME = path.join(UI, 'theme.css');
const THEME_LINK = '<link rel="stylesheet" href="../theme.css" />';

/** Text without CSS block comments. */
function code(css) {
	return css.replace(/\/\*[\s\S]*?\*\//g, '');
}

/** Lists the shared stylesheets other than the theme, as paths under ui/. */
function pageStylesheets() {
	const out = [];
	for (const entry of fs.readdirSync(UI, { withFileTypes: true })) {
		if (!entry.isDirectory() || entry.name === 'vendor') continue;
		for (const file of fs.readdirSync(path.join(UI, entry.name))) {
			if (file.endsWith('.css')) out.push(`${entry.name}/${file}`);
		}
	}
	return out.sort();
}

const themeCss = code(fs.readFileSync(THEME, 'utf8'));
const declared = new Set([...themeCss.matchAll(/(--theme-[\w-]+)\s*:/g)].map((m) => m[1]));
assert.ok(declared.size > 0, 'theme.css declares no --theme- token');

// The palette: every token whose light value is a bare hex literal.
const palette = new Map();
const firstRoot = /:root\s*\{([^}]*)\}/.exec(themeCss);
assert.ok(firstRoot, 'theme.css has no palette block');
for (const match of firstRoot[1].matchAll(/(--theme-[\w-]+)\s*:\s*(#[0-9a-fA-F]{3,8})\s*;/g)) {
	palette.set(match[2].toLowerCase(), match[1]);
}
assert.ok(palette.size >= 5, `the palette holds ${palette.size} colour(s); its block was not read`);

const stylesheets = pageStylesheets();
assert.ok(stylesheets.length > 10, `only ${stylesheets.length} shared stylesheet(s) found`);

const failures = [];
const used = new Set();
const tokenSheets = new Set();
const HEX = /(?<![&\w])#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{3})(?![\w-])/g;

for (const sheet of stylesheets) {
	const css = code(fs.readFileSync(path.join(UI, sheet), 'utf8'));
	for (const match of css.matchAll(/var\((--theme-[\w-]+)/g)) {
		used.add(match[1]);
		tokenSheets.add(sheet);
		if (!declared.has(match[1]))
			failures.push(`${sheet}: uses ${match[1]}, which theme.css does not declare`);
	}
	for (const match of css.matchAll(/(--theme-[\w-]+)\s*:/g)) {
		failures.push(`${sheet}: redeclares the theme token ${match[1]}`);
	}
	for (const match of css.matchAll(HEX)) {
		const token = palette.get(match[0].toLowerCase());
		if (token) failures.push(`${sheet}: types ${match[0]}, which is the theme's ${token}`);
	}
}

// The theme's own tokens may build on each other.
for (const match of themeCss.matchAll(/var\((--theme-[\w-]+)/g)) used.add(match[1]);
for (const token of declared) {
	if (!used.has(token)) failures.push(`theme.css: ${token} is used by no page`);
}

// Every page whose stylesheets use a token links the theme, before them.
let linked = 0;
for (const entry of fs.readdirSync(UI, { withFileTypes: true })) {
	const page = path.join(UI, entry.name, 'index.html');
	if (!entry.isDirectory() || !fs.existsSync(page)) continue;
	const html = fs.readFileSync(page, 'utf8');
	const links = [...html.matchAll(/<link\b[^>]*rel="stylesheet"[^>]*>/g)].map((m) => m[0]);
	const sheets = links
		.map((tag) => /href="([^"?#]+)/.exec(tag))
		.filter(Boolean)
		.map((m) => path.posix.normalize(path.posix.join(entry.name, m[1])));
	const needsTheme = sheets.some((sheet) => tokenSheets.has(sheet));
	const themeAt = links.indexOf(THEME_LINK);
	if (needsTheme && themeAt === -1) {
		failures.push(`${entry.name}/index.html: uses theme tokens but does not link ${THEME_LINK}`);
	} else if (themeAt > 0) {
		failures.push(`${entry.name}/index.html: links the theme after another stylesheet`);
	}
	if (themeAt !== -1) linked += 1;
}
assert.ok(linked > 0, 'no shared page links the theme');

if (failures.length > 0) {
	console.error('\x1b[31m[FAIL] the shared pages and theme.css disagree:\x1b[0m');
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] shared UI theme: ${declared.size} token(s), ${tokenSheets.size} stylesheet(s) use them, ` +
		`${linked} page(s) link the theme; no palette colour is retyped.\x1b[0m`
);
