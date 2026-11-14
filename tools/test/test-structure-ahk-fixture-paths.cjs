// tools/test/test-structure-ahk-fixture-paths.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan AutoHotkey Fixture Paths
 * DESCRIPTION:
 * Two AutoHotkey fixture spellings a step must keep consistent (proof 22,
 * Windows unit core). The startup source tests create their tree with
 * DirCreate(Driver . "\infra") and write Driver . "\infra\bundle.ahk"; S06
 * respelled the write into core\lifecycle\engine, a folder nothing created,
 * and FileAppend failed. The reload quiescence test climbs from its own
 * folder, TestDir . "/../../..", to the suite root; S06 moved it two folders
 * deeper and the climb landed in unit/. A respelled write now gains its
 * folder after the DirCreate that made the old one, and a climb in a moving
 * file is recounted to name the same folder.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');

function run() {
	// The write gains its folder, once per fixture that creates the old one.
	const fixture = (dir) =>
		[
			'Make() {',
			'\tDirCreate(Driver . "\\infra")',
			`\tFileAppend(Version, Driver . "\\${dir}\\bundle.ahk", "UTF-8")`,
			'}',
			''
		].join('\n');
	const before = fixture('infra') + fixture('infra');
	const after = fixture('core\\lifecycle\\engine') + fixture('core\\lifecycle\\engine');
	const out = Apply.repairCoupled(before, after);
	assert.equal(out.split('DirCreate(Driver . "\\core\\lifecycle\\engine")').length, 3, out);
	assert.equal(Apply.repairCoupled(before, before), before);

	// The climb from a moving file's own folder names the same folder.
	const FILE = 'static/ergopti_plus/windows/tests/unit/zz_infra/zz_probe/test_zz_probe.ahk';
	const map = new Map([
		[
			'windows/tests/unit/zz_infra/zz_probe/test_zz_probe.ahk',
			'windows/tests/unit/core/zz_lifecycle/engine/zz_probe/test_zz_probe.ahk'
		]
	]);
	const text =
		'\tSplitPath(A_LineFile, , &TestDir)\n\tTestsRoot := TestDir . "/../../.."\n' +
		'\tT := FileRead(TestDir . "/../../../support/x.ahk")\n';
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(map));
	const climbed = Apply.rewriteText(text, rows, new Map(), FILE);
	assert.ok(climbed.includes('TestsRoot := TestDir . "/../../../../.."'), climbed);
	assert.ok(climbed.includes('TestDir . "/../../../../../support/x.ahk"'), climbed);
	// A climb from the suite folder joined onto a variable that holds it
	// (TestsRoot . "/../infra/x.ahk") follows the driver file it names.
	const HANDOFF = 'windows/infra/reload_terminal_handoff.ahk';
	if (fs.existsSync(path.join(REPO, 'static/ergopti_plus', HANDOFF))) {
		const suiteFile = 'static/ergopti_plus/windows/tests/unit/zz_probe/test_zz_suite_climb.ahk';
		const handoffMap = new Map([
			[HANDOFF, 'windows/core/zz_lifecycle/engine/reload/terminal_handoff.ahk']
		]);
		const include =
			'Probe := StrReplace(Probe, "@@H@@", TestsRoot . "/../infra/reload_terminal_handoff.ahk")\n';
		const includeRows = Plan.scanFile(suiteFile, include, Plan.referenceContext(handoffMap));
		const includeOut = Apply.rewriteText(include, includeRows, new Map(), suiteFile);
		assert.ok(
			includeOut.includes('TestsRoot . "/../core/zz_lifecycle/engine/reload/terminal_handoff.ahk"'),
			includeOut
		);
	}
	console.log('[OK] AutoHotkey fixtures keep their created folders and their climbs.');
}

run();
