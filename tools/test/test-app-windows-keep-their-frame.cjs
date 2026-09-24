// tools/test/test-app-windows-keep-their-frame.cjs

/**
 * ==============================================================================
 * MODULE: App Windows Keep Their Frame
 * DESCRIPTION:
 * The system diagnostics window on macOS could not be told apart from a white
 * web page behind it: it cast no shadow, because it built its own chrome instead
 * of going through the one function every other window uses. The user asked
 * that every window share the same frame and that CI check each one.
 *
 * FEATURES & RATIONALE:
 * 1. macOS: every file creating an hs.webview must apply
 *    ui_builder.window_chrome_steps (title bar, drop shadow, level). The Lua
 *    suite pins the steps themselves; this checks no window escapes them.
 * 2. Windows: an AutoHotkey window without a caption has no frame and no shadow.
 *    Only the windows listed in FRAMELESS_BY_DESIGN may drop it.
 * 3. Linux: a GTK window with set_decorated(false) has no frame; same rule.
 * The allow-lists are the tooltips and overlay widgets, which float over text
 * and must not look like windows. Anything else there is an app window missing
 * its frame.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static', 'ergopti_plus');

// Files allowed to create frameless windows, per driver, with the reason.
const FRAMELESS_BY_DESIGN = {
	windows: {
		'ui/tooltip/helpers.ahk': 'typing tooltip and its border overlay',
		'ui/tooltip/llm.ahk': 'LLM suggestion tooltip',
		'ui/wpm/wpm_widget.ahk': 'floating WPM widget and graph',
	},
	linux: {
		'adapters/graphics_renderer.lua': 'preview tooltip',
		'adapters/wpm_surface.lua': 'floating WPM widget and graph',
	},
};

// Floors: a walk returning fewer files means the enumeration broke.
const MIN_FILES = { macos: 100, windows: 300, linux: 100 };

/**
 * Lists driver source files with the given extension, tests and vendor excluded.
 * @param {string} dir
 * @param {string} ext
 * @returns {string[]} Paths relative to dir, with forward slashes.
 */
function listSources(dir, ext) {
	const out = [];
	const walk = (sub) => {
		for (const entry of fs.readdirSync(path.join(dir, sub), { withFileTypes: true })) {
			const rel = sub ? `${sub}/${entry.name}` : entry.name;
			if (entry.isDirectory()) {
				if (['tests', 'vendor', 'node_modules', '_generated'].includes(entry.name)) continue;
				walk(rel);
			} else if (entry.name.endsWith(ext)) {
				out.push(rel);
			}
		}
	};
	walk('');
	return out;
}

/**
 * Removes line comments so prose never creates or satisfies a match.
 * @param {string} src
 * @param {string} marker Line-comment marker of the language.
 * @returns {string}
 */
function stripComments(src, marker) {
	return src
		.split(/\r?\n/)
		.map((line) => {
			const at = line.indexOf(marker);
			return at >= 0 ? line.slice(0, at) : line;
		})
		.join('\n');
}

const errors = [];

/**
 * Checks one driver's files against a frameless pattern and its allow-list.
 * @param {string} driver
 * @param {string} ext
 * @param {string} marker
 * @param {(src: string) => boolean} isOffending
 */
function checkDriver(driver, ext, marker, isOffending) {
	const dir = path.join(DRIVERS, driver);
	const files = listSources(dir, ext);
	if (files.length < MIN_FILES[driver]) {
		errors.push(`${driver}: only ${files.length} source file(s) found (floor ${MIN_FILES[driver]}); the walk is broken`);
		return;
	}
	const allowed = FRAMELESS_BY_DESIGN[driver] || {};
	for (const rel of files) {
		const src = stripComments(fs.readFileSync(path.join(dir, rel), 'utf8'), marker);
		if (isOffending(src) && !allowed[rel]) {
			errors.push(`${driver}/${rel} creates a window without the shared frame`);
		}
	}
	for (const rel of Object.keys(allowed)) {
		if (!files.includes(rel)) {
			errors.push(`${driver}: allow-listed file ${rel} no longer exists; drop it from FRAMELESS_BY_DESIGN`);
		}
	}
}

checkDriver('macos', '.lua', '--',
	(src) => src.includes('hs.webview.new') && !src.includes('window_chrome_steps('));
checkDriver('windows', '.ahk', ';',
	(src) => /\bGui\(\s*"[^"]*-Caption\b/.test(src));
checkDriver('linux', '.lua', '--',
	(src) => /set_decorated\(\s*false\s*\)/.test(src));

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] app windows must keep their frame:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log('\x1b[32m[OK] every app window on macOS, Windows and Linux keeps the shared frame.\x1b[0m');
