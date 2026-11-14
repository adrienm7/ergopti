// tools/test/test-structure-shell-paths.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Shell Paths On An Unbraced Variable
 * DESCRIPTION:
 * A driver's shell script joins a path onto its own folder as
 * "$SCRIPT_DIR/ui/dialog_host.lua". The braced ${SCRIPT_DIR}/x is a path
 * token as written; the unbraced form is not, because the variable's last
 * letter touches the path. S12 moved the dialog host and left uninstall.sh
 * testing and running the old path, so a failed uninstall showed no dialog.
 * A path on an unbraced variable now follows its file.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const HOST = 'linux/ui/dialog_host.lua';
const FILE = 'static/ergopti_plus/linux/zz_probe.sh';

function run() {
	if (!fs.existsSync(path.join(REPO, 'static/ergopti_plus', HOST))) {
		console.log('[OK] shell paths on an unbraced variable: the step has landed.');
		return;
	}
	const { map } = Plan.moveMap();
	const step = Plan.steps(map).find((s) => s.moves.some(([o]) => o === HOST));
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const fresh = map.get(HOST).slice('linux/'.length);
	const text =
		'[ -f "$SCRIPT_DIR/ui/dialog_host.lua" ] && "$lua" "${SCRIPT_DIR}/ui/dialog_host.lua"\n';
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(stepMap));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	const out = Apply.rewriteText(text, rows, new Map(), FILE);
	assert.ok(out.includes(`"$SCRIPT_DIR/${fresh}"`), out);
	assert.ok(out.includes(`"\${SCRIPT_DIR}/${fresh}"`), out);
	// A path no driver file holds stays as written.
	const other = '[ -f "$HOME/.config/zz_probe/x.lua" ]\n';
	const otherRows = Plan.scanFile(FILE, other, Plan.referenceContext(stepMap));
	assert.equal(Apply.rewriteText(other, otherRows, new Map(), FILE), other);
	console.log(`[OK] a shell path on an unbraced variable follows the file ${step.id} moves.`);
}

run();
