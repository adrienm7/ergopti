// tools/test/test-app-cloner-families.cjs

/**
 * ==============================================================================
 * MODULE: App Cloner Shared Families
 * DESCRIPTION:
 * Holds the App Cloner family catalogue (_shared/data/app_cloner/families.json)
 * that the Windows and Linux App Cloners read to the detection the macOS
 * clone_app.sh writes out by hand: the Electron and VS Code executable names it
 * matches must be catalogue names, so a program cloned with its own profile on
 * macOS is cloned with its own profile on the other two. The catalogue itself
 * is checked for the shape both readers rely on.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const plus = path.resolve(__dirname, '../../static/ergopti_plus');
const catalogue = JSON.parse(
	fs.readFileSync(path.join(plus, '_shared/data/app_cloner/families.json'), 'utf8')
);
const cloneApp = fs.readFileSync(
	path.join(plus, 'macos/apps/App Cloner.app/Contents/Resources/clone_app.sh'),
	'utf8'
);

let failed = 0;
/** Runs one scenario and reports it. */
function scenario(name, body) {
	try {
		body();
		console.log(`ok App Cloner families ${name}`);
	} catch (error) {
		failed += 1;
		console.error(`FAIL App Cloner families ${name}: ${error.message}`);
	}
}

scenario('(app-cloner-families-shape) every family is detected, named and has arguments', () => {
	assert.deepEqual([...catalogue.detection_order].sort(), Object.keys(catalogue.families).sort());
	const seen = new Set();
	for (const [family, definition] of Object.entries(catalogue.families)) {
		assert.ok(definition.executables.length > 0, family + ' has no executable');
		for (const name of definition.executables) {
			assert.equal(name, name.toLowerCase(), name + ' must be lower-case');
			assert.ok(!name.endsWith('.exe'), name + ' must be named without .exe');
			assert.ok(!seen.has(name), name + ' belongs to two families');
			seen.add(name);
		}
		assert.ok(
			definition.arguments.some((argument) => argument.value.includes('{profile}')),
			family + ' passes no profile'
		);
		for (const argument of definition.arguments) {
			for (const placeholder of argument.value.match(/\{[a-z_]+\}/g) || []) {
				assert.ok(
					['{profile}', '{window_class}', '{home}'].includes(placeholder),
					'unknown placeholder ' + placeholder
				);
			}
			for (const platform of argument.platforms || []) {
				assert.ok(['windows', 'linux'].includes(platform), 'unknown platform ' + platform);
			}
		}
	}
	assert.ok(catalogue.families.chromium.web_app.includes('{url}'));
});

scenario(
	'(app-cloner-macos-electron-names) clone_app.sh matches only catalogue Electron names',
	() => {
		const match = cloneApp.match(/case "\$SRC_EXE_NAME" in\n\s*([^)]+)\)\n\s*APP_FAMILY=electron/);
		assert.ok(match, 'the Electron executable case of clone_app.sh moved');
		const names = match[1].split('|').map((name) => name.replace(/"/g, '').toLowerCase());
		assert.deepEqual(names.sort(), [...catalogue.families.electron.executables].sort());
	}
);

scenario('(app-cloner-macos-vscode-names) clone_app.sh VS Code names are catalogue names', () => {
	const names = [...cloneApp.matchAll(/\$SRC_EXE_NAME" == "([^"]+)"/g)].map((m) =>
		m[1].toLowerCase()
	);
	assert.ok(names.length >= 2, 'the VS Code executable tests of clone_app.sh moved');
	for (const name of names) assert.ok(catalogue.families.vscode.executables.includes(name), name);
	assert.ok(cloneApp.includes('--user-data-dir'), 'the macOS clone no longer isolates its profile');
});

if (failed > 0) {
	console.error(`${failed} App Cloner family check(s) failed.`);
	process.exit(1);
}
console.log('All App Cloner family checks passed.');
