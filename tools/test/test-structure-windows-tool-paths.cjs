// tools/test/test-structure-windows-tool-paths.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Windows Paths Of A Tool
 * DESCRIPTION:
 * A tool that sets DRIVER = path.join(ROOT, 'static', 'ergopti_plus',
 * 'windows') reads AutoHotkey sources by driver-relative path:
 * read('infra/lifecycle.ahk'). The plan resolved such bare paths only for a
 * tool naming one Lua driver, so S06 moved infra/lifecycle.ahk and the
 * timer inventory, the rewrite prompt wiring, the child handle audit and the
 * source-run owner check all read files that no longer existed. An .ahk path
 * in a tool that names the Windows driver now follows its file, even when
 * the tool names the Lua drivers too.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const FILE = 'tools/test/test-zz-probe-tool.cjs';
const MAP = new Map([
	['windows/infra/lifecycle.ahk', 'windows/core/lifecycle/engine/lifecycle.ahk'],
	['windows/infra/uninstall.ahk', 'windows/core/lifecycle/engine/shutdown/uninstall.ahk'],
	['macos/infra/paths.lua', 'macos/infra/paths.lua']
]);

/** Scans `text` as the probe tool under MAP and applies its rows. */
function rewrite(text) {
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(MAP));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	return Apply.rewriteText(text, rows, new Map(), FILE);
}

function run() {
	const head = "const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'windows');\n";
	{
		const out = rewrite(`${head}read('infra/lifecycle.ahk');\n`);
		assert.ok(out.includes("read('core/lifecycle/engine/lifecycle.ahk')"), out);
	}
	// The tool names the Lua drivers too: an .ahk path is still Windows'.
	{
		const out = rewrite(
			`${head}const MAC = path.join(ROOT, 'macos');\n` +
				"const owners = [['infra/uninstall.ahk', 'Show'], ['infra/paths.lua', 'x']];\n"
		);
		assert.ok(out.includes("'core/lifecycle/engine/shutdown/uninstall.ahk'"), out);
		assert.ok(out.includes("'infra/paths.lua'"), out);
	}
	// A tool that never names the Windows driver keeps a bare .ahk path.
	{
		const text = "read('infra/lifecycle.ahk');\n";
		assert.equal(rewrite(text), text);
	}
	console.log('[OK] a tool naming the Windows driver follows its AutoHotkey paths.');
}

run();
