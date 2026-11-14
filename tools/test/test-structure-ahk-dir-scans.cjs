// tools/test/test-structure-ahk-dir-scans.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan AutoHotkey Folder Scans
 * DESCRIPTION:
 * Windows meta tests scan a driver folder with _DriverDirConcat("infra").
 * S07 moved the logger out of infra/, which keeps other files, so the plan
 * kept the name and the logger dedup check scanned a folder that no longer
 * held what it asserts (proof 22, Windows unit meta). A scan of a folder the
 * step takes files out of now reads the folder while it keeps files and the
 * new homes of the files that left, through _DriverDirsConcat; homes nested
 * in another are read once.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const FILE = 'static/ergopti_plus/windows/tests/meta/zz_probe/test_zz_probe.ahk';

/** Scans `text` as the probe test under `map` and applies its rows. */
function rewrite(text, map) {
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(map));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	return Apply.rewriteText(text, rows, new Map(), FILE);
}

function run() {
	const map = new Map([
		['windows/zz_infra/logger.ahk', 'windows/core/zz_logger/engine/logger.ahk'],
		['windows/zz_infra/logger_sink.ahk', 'windows/core/zz_logger/engine/sink.ahk'],
		['windows/zz_infra/boot.ahk', 'windows/zz_infra/boot.ahk'],
		['windows/zz_ui/tooltip/a.ahk', 'windows/core/zz_ui/ui/tooltip/a.ahk'],
		['windows/zz_ui/tooltip/b.ahk', 'windows/core/zz_ui/ui/tooltip/b.ahk'],
		['windows/zz_ui/menu.ahk', 'windows/core/zz_ui/ui/menu.ahk'],
		['windows/zz_ui/wpm.ahk', 'windows/zz_ui/wpm.ahk']
	]);
	// A folder that keeps files: it and the new home.
	assert.equal(
		rewrite('Src := _DriverDirConcat("zz_infra")\n', map),
		'Src := _DriverDirsConcat("zz_infra", "core/zz_logger/engine")\n'
	);
	// A folder the step empties: its one new home.
	assert.equal(
		rewrite('Src := _DriverDirConcat("zz_ui/tooltip")\n', map),
		'Src := _DriverDirConcat("core/zz_ui/ui/tooltip")\n'
	);
	// A home nested in another is read once, through the outer one.
	assert.equal(
		rewrite('Src := _DriverDirConcat("zz_ui")\n', map),
		'Src := _DriverDirsConcat("zz_ui", "core/zz_ui/ui")\n'
	);
	// An earlier expansion expands again, argument by argument.
	const later = new Map([
		['windows/zz_infra/boot.ahk', 'windows/core/zz_lifecycle/engine/boot.ahk'],
		['windows/zz_infra/paths.ahk', 'windows/zz_infra/paths.ahk'],
		['windows/core/zz_logger/engine/logger.ahk', 'windows/core/zz_logger/engine/logger.ahk']
	]);
	assert.equal(
		rewrite('Src := _DriverDirsConcat("zz_infra", "core/zz_logger/engine")\n', later),
		'Src := _DriverDirsConcat("zz_infra", "core/zz_lifecycle/engine", "core/zz_logger/engine")\n'
	);
	// A folder the step leaves alone keeps its scan.
	const text = 'Src := _DriverDirConcat("zz_other")\n';
	assert.equal(rewrite(text, map), text);
	console.log('[OK] a Windows folder scan keeps reading every file it read before the step.');
}

run();
