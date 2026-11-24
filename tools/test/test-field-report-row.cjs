// tools/test/test-field-report-row.cjs

/**
 * ==============================================================================
 * MODULE: Field Report Row Tests
 * DESCRIPTION:
 * Pins Débogage's « Lancer le field report (tous les tests) » on every driver
 * (maintainer decisions, 2026-11-24):
 * 1. the row stands in the Debug menu just before the « Tests » submenu, is
 *    offered on every driver and is not a row of Tests;
 * 2. each driver routes it to its in-app field report, which hands the
 *    driver's own field run session its steps (no second runner: no plan file
 *    lists steps);
 * 3. the Windows driver includes its report and the AHK suite runs its tests
 *    (AutoHotkey cannot run here, so its wiring is read from source).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const BASE = path.join(ROOT, 'static/ergopti_plus');
const ROW = 'field_report';
// The source line that routes the row on each driver
const ROUTES = {
	ahk: [
		'windows/menu/ui/builder/menu_init.ahk',
		'MenuCommand.FIELD_REPORT, (*) => FieldReport_Command(),'
	],
	hs: [
		'macos/menu/ui/builder/builder.lua',
		'[COMMAND.FIELD_REPORT] = function() require("diagnostics.ui.field_check").run_field_report() end,'
	],
	linux: [
		'linux/diagnostics/ui/menu_debug.lua',
		'[COMMAND.FIELD_REPORT] = function() require("diagnostics.ui.field_check.field_report").run() end,'
	]
};
// Each driver's in-app submit on its field run session
const SUBMITS = {
	ahk: [
		'windows/diagnostics/ui/field_check/field_report.ahk',
		'Session.SubmitInApp(Observer, &Reason)'
	],
	hs: ['macos/diagnostics/ui/field_check/init.lua', 'session:submit_in_app({'],
	linux: ['linux/diagnostics/ui/field_check/field_report.lua', 'session:submit_in_app({']
};

const readText = (relative) => fs.readFileSync(path.join(BASE, relative), 'utf8');
const manifest = JSON.parse(readText('_shared/menu/data/menu_manifest.json'));
let checks = 0;

/** Runs one named check. */
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

check('the row stands just before Tests on every driver and is not a row of Tests', () => {
	const debug = manifest.debug_menu;
	const at = debug.findIndex((row) => row.id === ROW);
	assert(at >= 0, 'the Debug menu declares the field report row');
	assert.equal(debug[at].type, 'command');
	assert.equal(debug[at + 1].id, 'debug_tests', 'it stands just before Tests');
	assert.equal(debug[at].platforms, undefined, 'every driver offers it');
	assert(!manifest.debug_tests_menu.some((row) => row.id === ROW), 'it is not inside Tests');
});

check('each driver routes the row to its in-app run on its own field run session', () => {
	for (const [platform, [file, line]] of Object.entries(ROUTES))
		assert(readText(file).includes(line), `${platform}: ${file} does not route ${ROW}`);
	for (const [platform, [file, line]] of Object.entries(SUBMITS))
		assert(
			readText(file).includes(line),
			`${platform}: ${file} does not hand the session its steps`
		);
	assert(
		!fs.existsSync(path.join(BASE, '_shared/diagnostics/data/field_check_all.json')),
		'no plan file lists the steps a second time'
	);
});

check('the Windows driver includes its report and the AHK suite runs its tests', () => {
	assert(
		/^#Include diagnostics\/ui\/field_check\/field_report\.ahk$/m.test(
			readText('windows/ErgoptiPlus.ahk')
		),
		'the Windows driver includes its report'
	);
	const runner = readText('windows/tests/run_all.ahk');
	assert(
		/^#Include \.\.\/diagnostics\/ui\/field_check\/field_report\.ahk$/m.test(runner),
		'the AHK suite loads it'
	);
	assert(
		/^#Include unit\/diagnostics\/ui\/test_field_report\.ahk$/m.test(runner),
		'the AHK suite runs its tests'
	);
});

console.log(`[OK] field report row (${checks} checks).`);
