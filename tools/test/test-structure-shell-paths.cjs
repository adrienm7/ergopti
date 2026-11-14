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

/** A folder joined onto an unbraced variable that holds the driver root. */
function folderCase() {
	const { map } = Plan.moveMap();
	// It follows the folder; a scratch folder's name is no driver folder.
	const FOCUS = 'linux/desktop_focus/gnome/metadata.json';
	if (fs.existsSync(path.join(REPO, 'static/ergopti_plus', FOCUS))) {
		const focusStep = Plan.steps(map).find((s) => s.moves.some(([o]) => o === FOCUS));
		const focusMap = new Map(
			[...map].map(([o, t]) => [o, focusStep.moves.some(([so]) => so === o) ? t : o])
		);
		const sh = 'static/ergopti_plus/linux/install/zz_probe_focus.sh';
		const body =
			'[ -d "$driver_root/desktop_focus" ] || exit 2\n' +
			'local source="$1/desktop_focus/gnome"\n' +
			'dir=$(mktemp -d)\nmkdir "$dir/desktop_focus"\n';
		const shRows = Plan.scanFile(sh, body, Plan.referenceContext(focusMap));
		const shOut = Apply.rewriteText(body, shRows, new Map(), sh);
		const home = path.posix.dirname(map.get('linux/desktop_focus/gnome/metadata.json'));
		const folder = path.posix.dirname(home).slice('linux/'.length);
		assert.ok(shOut.includes(`"$driver_root/${folder}"`), shOut);
		assert.ok(shOut.includes(`"$1/${folder}/gnome"`), shOut);
		assert.ok(shOut.includes('mkdir "$dir/desktop_focus"'), shOut);
	}
}

function run() {
	folderCase();
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
	// A tool's shell command joins a driver path onto a positional argument
	// that holds the root of the driver the tool names.
	const PROBE = 'linux/platform/network/runtime_probe.lua';
	if (fs.existsSync(path.join(REPO, 'static/ergopti_plus', PROBE))) {
		const probeStep = Plan.steps(map).find((s) => s.moves.some(([o]) => o === PROBE));
		const probeMap = new Map(
			[...map].map(([o, t]) => [o, probeStep.moves.some(([so]) => so === o) ? t : o])
		);
		const tool = 'tools/build/zz_probe.py';
		const command =
			'driver = prefix / "lib/ergopti"  # static/ergopti_plus/linux\n' +
			'cmd = \'exec "$2/bin/luajit" "$3/platform/network/runtime_probe.lua" "$3/_shared"\'\n';
		const toolRows = Plan.scanFile(tool, command, Plan.referenceContext(probeMap));
		const toolOut = Apply.rewriteText(command, toolRows, new Map(), tool);
		const probe = map.get(PROBE).slice('linux/'.length);
		assert.ok(toolOut.includes(`"$3/${probe}" "$3/_shared"`), toolOut);
	}
	console.log(`[OK] a shell path on an unbraced variable follows the file ${step.id} moves.`);
}

run();
