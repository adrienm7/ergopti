// tools/test/test-structure-gain-scope.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Folder Gains Stay In Their Driver
 * DESCRIPTION:
 * A list naming two sibling folders of a step's moved folder gains the
 * folder it moves into. The plan compared every driver's folders with every
 * file, so S12 took windows/tests/unit (which holds updater/ and ui/) as the
 * siblings of the macOS preferences' config SECTIONS list and added "core"
 * to it, a section that does not exist; the source-tree scan coverage check
 * then flagged the list. A file inside a driver now gains only from its own
 * driver's folders; shared files and tools keep every driver's gains.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const FILE = 'static/ergopti_plus/macos/infra/zz_probe_sections.lua';

function run() {
	const { map } = Plan.moveMap();
	// The step that moves the Windows suite's ui/ tests into core/.
	const step = Plan.steps(map).find((s) =>
		s.moves.some(
			([o, t]) =>
				t && o.startsWith('windows/tests/unit/ui/') && t.startsWith('windows/tests/unit/core/')
		)
	);
	const leaving = step && step.moves.find(([o]) => o.startsWith('windows/tests/unit/ui/'));
	if (!leaving || !fs.existsSync(path.join(REPO, 'static/ergopti_plus', leaving[0]))) {
		console.log('[OK] folder gains stay in their driver: the ui step has landed.');
		return;
	}
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const text = 'local SECTIONS = { "gestures", "hotstrings", "updater", "ui" }\n';
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(stepMap));
	assert.equal(Apply.rewriteText(text, rows, new Map(), FILE), text);
	// The same names in a tool still read the Windows suite's folders.
	const tool = 'tools/test/test-zz-probe.cjs';
	const toolText = "const UNIT = ['updater', 'ui'];\n";
	const toolRows = Plan.scanFile(tool, toolText, Plan.referenceContext(stepMap));
	assert.ok(
		Apply.rewriteText(toolText, toolRows, new Map(), tool).includes("'core'"),
		JSON.stringify(toolRows)
	);
	console.log(`[OK] a macOS list gains no folder from the Windows suite at ${step.id}.`);
}

run();
