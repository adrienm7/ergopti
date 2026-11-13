// tools/test/test-structure-ahk-scriptdir.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan AutoHotkey Script-Directory Climbs
 * DESCRIPTION:
 * A Windows test that run_all.ahk includes runs with A_ScriptDir set to
 * windows/tests, so A_ScriptDir . "\..\adapters\file_system.ahk" names the
 * driver's adapter whatever folder the test lives in. The plan read such a
 * climb from the test's own folder, found nothing there and left it: after
 * S04 the keystats reaper child included an adapter that no longer existed
 * and never finished. The climb now starts at windows/tests for included
 * tests; a standalone fixture keeps reading from its own folder.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const ADAPTER = 'windows/adapters/file_system.ahk';

function run() {
	// Once the step that moves the adapter has landed, the case is gone.
	if (!fs.existsSync(path.join(REPO, 'static/ergopti_plus', ADAPTER))) {
		console.log('[OK] AutoHotkey script-directory climbs: the adapter step has landed.');
		return;
	}
	const { map } = Plan.moveMap();
	const step = Plan.steps(map).find((s) => s.moves.some(([o]) => o === ADAPTER));
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const fresh = map.get(ADAPTER).slice('windows/'.length).replace(/\//g, '\\');
	const text = "\t. '#Include ' . A_ScriptDir . '\\..\\adapters\\file_system.ahk' . \"`n\"\n";

	const included = 'static/ergopti_plus/windows/tests/unit/zz_probe/test_zz_probe.ahk';
	const rows = Plan.scanFile(included, text, Plan.referenceContext(stepMap));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	const out = Apply.rewriteText(text, rows, new Map(), included);
	assert.ok(out.includes(`A_ScriptDir . '\\..\\${fresh}'`), out);

	// A standalone fixture runs from its own folder: the same climb names
	// nothing of the driver from there, and stays as written.
	const fixture = 'static/ergopti_plus/windows/tests/fixtures/zz_probe_fixture.ahk';
	const fixtureRows = Plan.scanFile(fixture, text, Plan.referenceContext(stepMap));
	assert.equal(Apply.rewriteText(text, fixtureRows, new Map(), fixture), text);
	console.log(`[OK] an included test's A_ScriptDir climb follows the file ${step.id} moves.`);
}

run();
