// tools/test/test-reading-preferences-seed.cjs

/**
 * ==============================================================================
 * MODULE: Reading Preferences Reach Every App Window
 * DESCRIPTION:
 * The reader's font and spacing (`script.reading_font`, `script.reading_spacing`,
 * Configuration menu) must reach every WebView window of the three drivers
 * through the seed _shared/ui/a11y_prefs.js reads, window.__ergopti_reading.
 * This gate reads the sources, without a browser or a driver:
 * 1. the two features carry a11y_prefs.js's own value lists, default first,
 *    on Windows, macOS and Linux, and the Configuration menu offers both as
 *    choice rows on the three;
 * 2. every Windows source that seeds a page's locale (`_i18n_locale=`) seeds
 *    the reading choices as often (ReadingPrefs_SeedScript), so no window is
 *    left out;
 * 3. the macOS and Linux page builders, the only places those drivers seed
 *    a page, add the shared reading fragment, and both script scopes bind
 *    the two choices to their shared owners.
 * Each check runs again on a mutated source and must then fail.
 * The behaviour itself is pinned by the drivers' unit tests
 * (test_reading_preferences.ahk, reading_preferences_contract.lua).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { parse: parseToml } = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const PLUS = path.join(ROOT, 'static', 'ergopti_plus');
const PATHS = { font: 'script.reading_font', spacing: 'script.reading_spacing' };
const LUA_BUILDERS = ['macos/core/ui/ui/builder.lua', 'linux/core/ui/ui/webkit_host.lua'];
const LUA_SCOPES = [
	'macos/settings/engine/scope/script_scope.lua',
	'linux/settings/engine/scope/script_scope.lua'
];

const read = (relative) => fs.readFileSync(path.join(PLUS, relative), 'utf8');

/** The value list of each a11y_prefs.js preference. */
function scriptValues(source) {
	const values = {};
	for (const name of Object.keys(PATHS)) {
		const match = new RegExp(`${name}: \\{ attribute: '[^']+', values: \\[([^\\]]+)\\]`).exec(
			source
		);
		assert.ok(match, `a11y_prefs.js declares ${name}`);
		values[name] = [...match[1].matchAll(/'([^']+)'/g)].map((m) => m[1]);
	}
	return values;
}

/** Problems of the features and menu rows. */
function declarationProblems(features, menu, values) {
	const problems = [];
	for (const [name, featurePath] of Object.entries(PATHS)) {
		const entry = features.find((feature) => feature.path === featurePath);
		if (!entry) {
			problems.push(`${featurePath} is not a feature`);
			continue;
		}
		if (JSON.stringify(entry.enum_values) !== JSON.stringify(values[name]))
			problems.push(
				`${featurePath} values ${entry.enum_values} are not a11y_prefs.js's ${values[name]}`
			);
		if (entry.default !== values[name][0])
			problems.push(`${featurePath} does not default to ${values[name][0]}`);
		if (JSON.stringify([...entry.platforms].sort()) !== JSON.stringify(['ahk', 'hs', 'linux']))
			problems.push(`${featurePath} is not on the three drivers`);
		const row = menu.configuration_menu.find(
			(item) => item.type === 'choice' && item.path === featurePath
		);
		if (!row) problems.push(`the Configuration menu has no choice row for ${featurePath}`);
		else if (row.platforms)
			problems.push(`the ${featurePath} row is restricted to ${row.platforms}`);
	}
	return problems;
}

/** Problems of the Windows seeds: every locale seed also seeds the reading choices. */
function windowsProblems(files) {
	const problems = [];
	for (const [file, source] of files) {
		const locales = source.split('_i18n_locale=').length - 1;
		// Calls only: the function's own definition is no seed.
		const readings = (source.match(/ReadingPrefs_SeedScript\(\)(?!\s*\{)/g) || []).length;
		if (locales !== readings)
			problems.push(`${file}: ${locales} locale seed(s), ${readings} reading seed(s)`);
	}
	return problems;
}

/** Problems of the Lua builders and scopes. */
function luaProblems(builders, scopes) {
	const problems = [];
	for (const [file, source] of builders) {
		if (!source.includes('require("core.ui.engine.webview.reading_preferences")'))
			problems.push(`${file} does not load the shared reading preferences`);
		if (!/Reading\.head_fragment\(/.test(source))
			problems.push(`${file} does not add the reading fragment`);
		if (!/Reading\.current\(\)/.test(source))
			problems.push(`${file} does not read the current choices`);
	}
	for (const [file, source] of scopes)
		for (const [key, owner] of [
			['SCRIPT_READING_FONT', 'core.ui.engine.webview.reading_font'],
			['SCRIPT_READING_SPACING', 'core.ui.engine.webview.reading_spacing']
		])
			if (!source.includes(`[ConfigKeys.KEY.${key}] = "${owner}"`))
				problems.push(`${file} does not bind ${key} to ${owner}`);
	return problems;
}

/** Every Windows source outside the tests, with its text. */
function windowsSources() {
	const files = [];
	const walk = (directory) => {
		for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
			const full = path.join(directory, entry.name);
			const relative = path.relative(PLUS, full).replace(/\\/g, '/');
			if (entry.isDirectory()) {
				if (!['windows/tests', 'windows/vendor'].includes(relative)) walk(full);
			} else if (entry.name.endsWith('.ahk')) files.push([relative, fs.readFileSync(full, 'utf8')]);
		}
	};
	walk(path.join(PLUS, 'windows'));
	return files;
}

const values = scriptValues(read('_shared/ui/a11y_prefs.js'));
const manifest = parseToml(read('_shared/settings/data/features/manifest.toml'));
const featureList = (manifest.features.script || []).map((entry) => ({
	...entry,
	path: `script.${entry.id}`
}));
const menu = JSON.parse(read('_shared/menu/data/menu_manifest.json'));
const windows = windowsSources();
const builders = LUA_BUILDERS.map((file) => [file, read(file)]);
const scopes = LUA_SCOPES.map((file) => [file, read(file)]);

assert.ok(
	windows.filter(([, source]) => source.includes('_i18n_locale=')).length >= 10,
	'the Windows seeds are found'
);
assert.deepEqual(declarationProblems(featureList, menu, values), []);
assert.deepEqual(windowsProblems(windows), []);
assert.deepEqual(luaProblems(builders, scopes), []);

// Each check fails on the shape it forbids.
const withoutRow = {
	...menu,
	configuration_menu: menu.configuration_menu.filter((row) => row.id !== 'reading_font')
};
assert.equal(
	declarationProblems(featureList, withoutRow, values).length,
	1,
	'a missing menu row is found'
);
assert.equal(
	declarationProblems(featureList, menu, { ...values, spacing: ['default', 'wider'] }).length,
	1,
	'a value list drifting from a11y_prefs.js is found'
);
const seeded = windows.find(([, source]) => source.includes('ReadingPrefs_SeedScript()'));
assert.equal(
	windowsProblems([[seeded[0], seeded[1].replace('ReadingPrefs_SeedScript()', '""')]]).length,
	1,
	'a Windows window that stops seeding the choices is found'
);
assert.equal(
	luaProblems([[builders[0][0], builders[0][1].replace(/Reading\.head_fragment\(/g, 'Other(')]], [])
		.length,
	1,
	'a Lua builder without the fragment is found'
);
assert.equal(
	luaProblems([], [[scopes[1][0], scopes[1][1].replace('reading_spacing"', 'other"')]]).length,
	1,
	'a scope that does not bind a choice is found'
);

console.log(
	`PASS test-reading-preferences-seed (${windows.filter(([, s]) => s.includes('_i18n_locale=')).length} Windows seeds, 2 Lua builders)`
);
