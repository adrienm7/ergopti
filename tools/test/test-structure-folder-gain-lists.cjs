// tools/test/test-structure-folder-gain-lists.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Folder Gains In Per-Line Lists
 * DESCRIPTION:
 * A list of a driver's sibling folders that names the folder a step's file
 * leaves also names the folder it moves into. The rule read { "ui", "adapters" }
 * and (ui|adapters), not a list written one element per line as
 * DRIVER_ROOT .. "adapters",. After S03 moved the macOS event clock from
 * adapters/ to core/, the hs.fs.dir source guard scanned no core/ file, found
 * no reference at all and refused as a broken scan. That form now gains the
 * new folder as one more line of the same shape.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const FILE = 'static/ergopti_plus/macos/tests/meta/zz_probe_roots.lua';

function run() {
	const { map } = Plan.moveMap();
	const plan = Plan.steps(map);
	// The first step that moves a macOS adapter into core/.
	const step = plan.find((s) =>
		s.moves.some(([o, t]) => t && o.startsWith('macos/adapters/') && t.startsWith('macos/core/'))
	);
	const leaving = step && step.moves.find(([o, t]) => t && o.startsWith('macos/adapters/'));
	// Once that step has landed, its adapters are gone and so is the case.
	if (!leaving || !fs.existsSync(path.join(REPO, 'static/ergopti_plus', leaving[0]))) {
		console.log('[OK] folder gains in per-line lists: the adapters step has landed.');
		return;
	}
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const text = [
		'local SOURCE_ROOTS = {',
		'\tDRIVER_ROOT .. "ui",',
		'\tDRIVER_ROOT .. "modules",',
		'\tDRIVER_ROOT .. "infra",',
		'\tDRIVER_ROOT .. "adapters",',
		'\thelpers.shared(""),',
		'}',
		''
	].join('\n');
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(stepMap));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	const out = Apply.rewriteText(text, rows, new Map(), FILE);
	assert.ok(
		out.includes('\tDRIVER_ROOT .. "adapters",\n\tDRIVER_ROOT .. "core",\n\thelpers.shared(""),'),
		out
	);
	// A single element is no list of siblings: it gains nothing.
	const lone = 'local ROOTS = {\n\tDRIVER_ROOT .. "adapters",\n}\n';
	const loneRows = Plan.scanFile(FILE, lone, Plan.referenceContext(stepMap));
	assert.ok(!loneRows.some((r) => r.kind === 'tree-list'), JSON.stringify(loneRows));
	console.log(`[OK] a per-line list of driver folders gains the folder ${step.id} moves into.`);
}

run();
