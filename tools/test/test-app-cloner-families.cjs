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

scenario(
	'(bap-002-macos-browser-profile) clone_app.sh gives catalogue browsers their own profile',
	() => {
		const match = cloneApp.match(
			/case "\$\{SRC_EXE_NAME:l\}" in\n\s*([^)]+)\)\n\s*APP_FAMILY=chromium ;;\n\s*([^)]+)\)\n\s*APP_FAMILY=firefox ;;/
		);
		assert.ok(match, 'the browser executable case of clone_app.sh moved');
		for (const [family, list] of [
			['chromium', match[1]],
			['firefox', match[2]]
		]) {
			for (const name of list.split('|').map((n) => n.replace(/"/g, '').trim())) {
				assert.ok(
					catalogue.families[family].executables.includes(name),
					`${name} is a ${family} name`
				);
			}
		}
		assert.match(
			cloneApp,
			/electron\|chromium\)\n\s*ARGS=\(--user-data-dir "\$USER_DATA_DIR"\) ;;/
		);
		assert.match(cloneApp, /firefox\)\n\s*ARGS=\(--no-remote --profile "\$USER_DATA_DIR"\) ;;/);
		assert.match(cloneApp, /chromium\|firefox\) ARGS\+=\("\$OPEN_ARG"\); OPEN_ARG="" ;;/);
		assert.ok(
			catalogue.families.chromium.web_app.startsWith('--app='),
			'the web-app argument is --app'
		);
	}
);

scenario(
	'(bap-004-vscode-variants) clone_app.sh uses the catalogue folders of each VS Code variant',
	() => {
		const folders = catalogue.families.vscode.user_folders;
		assert.ok(folders && folders.code, 'the vscode family names its user folders');
		for (const name of Object.keys(folders)) {
			assert.ok(
				catalogue.families.vscode.executables.includes(name),
				`${name} is a vscode executable`
			);
		}
		assert.ok(
			catalogue.families.vscode.arguments.some(
				(argument) =>
					argument.user_folder === 'extensions' && argument.value.startsWith('--extensions-dir=')
			),
			'the extensions argument is marked'
		);
		const block = cloneApp.match(/case "\$\{VSCODE_CLI:-\$\{SRC_EXE_NAME:l\}\}" in\n([^]*?)\nesac/);
		assert.ok(block, 'the VS Code variant case of clone_app.sh moved');
		const arms = [
			...block[1].matchAll(
				/\t(.+)\)\n\t\tVSCODE_SETTINGS="([^"]+)"; VSCODE_EXTENSIONS="([^"]+)" ;;/g
			)
		];
		assert.equal(arms.length, 3, 'three variant arms');
		for (const [, patterns, settings, extensions] of arms) {
			const names =
				patterns === '*' ? ['code'] : patterns.split('|').map((n) => n.replace(/"/g, ''));
			for (const name of names) {
				assert.deepEqual(folders[name], { settings, extensions }, `${name} folders`);
			}
		}
		assert.ok(cloneApp.includes('SHARED_EXT_DIR="$HOME/$VSCODE_EXTENSIONS/extensions"'));
		assert.ok(
			cloneApp.includes('MAIN_VSCODE_DATA="$HOME/Library/Application Support/$VSCODE_SETTINGS"')
		);
	}
);

if (failed > 0) {
	console.error(`${failed} App Cloner family check(s) failed.`);
	process.exit(1);
}
console.log('All App Cloner family checks passed.');
