// tools/test/test-structure-widened-join.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Joins Onto A Scattered Folder
 * DESCRIPTION:
 * path.join(plus, 'linux/ui') names a folder S08 scatters: one file leaves
 * for core/network while the others stay. The folder rule keeps such a name,
 * but the join rule followed the folder's nearest common new home, the
 * driver root, so the post-ready check scanned linux/ instead of linux/ui and
 * found no bridge. A join onto a scattered folder whose new home is above it
 * now keeps its name while the folder keeps files.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const LEAVER = 'linux/ui/proxy_override.lua';
const FILE = 'tools/test/test-zz-probe.cjs';
const TEXT =
	"const plus = path.resolve(__dirname, '../../static/ergopti_plus');\n" +
	"const linuxUi = path.join(plus, 'linux/ui');\n";

function run() {
	// Once the step that moves the leaver has landed, the case is gone.
	if (!fs.existsSync(path.join(REPO, 'static/ergopti_plus', LEAVER))) {
		console.log('[OK] joins onto a scattered folder: the step has landed.');
		return;
	}
	const { map } = Plan.moveMap();
	const step = Plan.steps(map).find((s) => s.moves.some(([o]) => o === LEAVER));
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const rows = Plan.scanFile(FILE, TEXT, Plan.referenceContext(stepMap));
	assert.ok(
		!rows.some((r) => r.old.startsWith('path.join(plus') && r.new !== r.old),
		JSON.stringify(rows)
	);
	console.log(`[OK] a join onto a folder ${step.id} scatters keeps its name.`);
}

run();
