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
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

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
	console.log('[OK] AutoHotkey fixtures keep their created folders and their climbs.');
}

run();
