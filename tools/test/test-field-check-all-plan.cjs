// tools/test/test-field-check-all-plan.cjs

/**
 * ==============================================================================
 * MODULE: « Test Everything » Plan Tests
 * DESCRIPTION:
 * Pins static/ergopti_plus/_shared/diagnostics/data/field_check_all.json, the
 * plan of the Debug menu's « Test everything » on each driver:
 * 1. the declaration names the three drivers and nothing else;
 * 2. every step it runs is a field_check step of that driver's developer field
 *    run declaration, listed once, and every row it names is a Tests row that
 *    driver offers;
 * 3. every Tests command row a driver offers is « Test everything » itself, a
 *    row whose check the plan runs, or a row it lists as « run separately »,
 *    so a new Tests row cannot be forgotten by the combined report;
 * 4. the field report row stands just before Tests on every driver, and
 *    each driver routes it (AutoHotkey cannot run here, so its wiring is read from source).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '../..');
const BASE = path.join(ROOT, 'static/ergopti_plus');
const PLAN = '_shared/diagnostics/data/field_check_all.json';
const MANIFEST = '_shared/menu/data/menu_manifest.json';
const ALL_ROW = 'field_report';
// Each driver's developer field run declaration, which owns its steps' checks and deadlines
const STEPS_FILES = {
	ahk: 'windows/diagnostics/data/field_run_steps.json',
	hs: 'macos/diagnostics/data/field_run.json',
	linux: 'linux/diagnostics/data/field_run_steps.json'
};
// The source line that routes the row on each driver
const ROUTES = {
	ahk: [
		'windows/menu/ui/builder/menu_init.ahk',
		'MenuCommand.FIELD_REPORT, (*) => FieldCheckAll_Command(),'
	],
	hs: [
		'macos/menu/ui/builder/builder.lua',
		'[COMMAND.FIELD_REPORT] = function() require("diagnostics.ui.field_check").run_all() end,'
	],
	linux: [
		'linux/diagnostics/ui/menu_debug.lua',
		'[COMMAND.FIELD_REPORT] = function() require("diagnostics.ui.field_check.run_all").run() end,'
	]
};

const readText = (relative) => fs.readFileSync(path.join(BASE, relative), 'utf8');
const read = (relative) => JSON.parse(readText(relative));
const plan = read(PLAN);
const tests = read(MANIFEST).debug_tests_menu;
let checks = 0;

/** Runs one named check. */
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

/** The Tests command rows a driver offers, by id. */
function offeredRows(platform) {
	const rows = new Map();
	for (const row of tests)
		if (row.type === 'command' && (!row.platforms || row.platforms.includes(platform)))
			rows.set(row.id, row);
	return rows;
}

check('the plan names the three drivers and nothing else', () => {
	assert.equal(plan.schema, 1);
	assert.deepEqual(Object.keys(plan.platforms).sort(), Object.keys(STEPS_FILES).sort());
	for (const [platform, own] of Object.entries(plan.platforms)) {
		assert.deepEqual(Object.keys(own).sort(), ['run', 'separate'], `${platform} plan keys`);
		assert(own.run.length > 0, `${platform} runs at least one check`);
	}
});

check(
	'every run step is a field check of the driver field run, once, and every row is offered',
	() => {
		for (const [platform, own] of Object.entries(plan.platforms)) {
			const steps = new Map(read(STEPS_FILES[platform]).steps.map((step) => [step.id, step]));
			const offered = offeredRows(platform);
			const seen = new Set();
			for (const entry of own.run) {
				const step = steps.get(entry.step);
				assert(step, `${platform}: ${entry.step} is not a field run step`);
				assert.equal(step.kind, 'field_check', `${platform}: ${entry.step} is not a field check`);
				assert(!seen.has(entry.step), `${platform}: ${entry.step} runs twice`);
				seen.add(entry.step);
				if (entry.row !== undefined)
					assert(offered.has(entry.row), `${platform}: ${entry.row} is not offered`);
			}
			for (const entry of own.separate) {
				assert(offered.has(entry.row), `${platform}: separate row ${entry.row} is not offered`);
				if (entry.step !== undefined)
					assert(steps.has(entry.step), `${platform}: ${entry.step} is not a field run step`);
			}
		}
	}
);

check('every Tests row a driver offers is run, listed as separate, or « Test everything »', () => {
	for (const [platform, own] of Object.entries(plan.platforms)) {
		const classified = new Set([ALL_ROW]);
		for (const entry of [...own.run, ...own.separate]) if (entry.row) classified.add(entry.row);
		for (const id of offeredRows(platform).keys())
			assert(classified.has(id), `${platform}: Tests row ${id} is neither run nor listed`);
	}
});

check(
	'the field report row stands just before Tests on every driver and each driver routes it',
	() => {
		const debug = read(MANIFEST).debug_menu;
		const at = debug.findIndex((row) => row.id === ALL_ROW);
		assert(at >= 0, 'the Debug menu declares the field report row');
		assert.equal(debug[at + 1].id, 'debug_tests', 'it stands just before Tests');
		assert.equal(debug[at].platforms, undefined, 'every driver offers it');
		assert(!tests.some((row) => row.id === ALL_ROW), 'it is not inside Tests');
		for (const [platform, [file, line]] of Object.entries(ROUTES))
			assert(readText(file).includes(line), `${platform}: ${file} does not route ${ALL_ROW}`);
		assert(
			/^#Include diagnostics\/ui\/field_check\/run_all\.ahk$/m.test(
				readText('windows/ErgoptiPlus.ahk')
			),
			'the Windows driver includes its run'
		);
		const runner = readText('windows/tests/run_all.ahk');
		assert(
			/^#Include \.\.\/diagnostics\/ui\/field_check\/run_all\.ahk$/m.test(runner),
			'the AHK suite loads it'
		);
		assert(
			/^#Include unit\/diagnostics\/ui\/test_field_check_all\.ahk$/m.test(runner),
			'the AHK suite runs its tests'
		);
	}
);

console.log(`[OK] « Test everything » plan (${checks} checks).`);
