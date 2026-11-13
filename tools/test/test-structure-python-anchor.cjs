// tools/test/test-structure-python-anchor.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Python Root Anchors
 * DESCRIPTION:
 * A Python file names a folder above it with a bare climb:
 * root = Path(__file__).absolute().parents[2]. The plan recounted a climb
 * only when a path literal was joined to it, so S08 moved native_http.py from
 * platform/network to core/network/adapters with parents[2] intact: it then
 * named core instead of the macOS driver root, and the developer app's
 * receiver refused every request. A bare climb in a moving file is now
 * recounted to name the same folder from the file's new place.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const FILE = 'static/ergopti_plus/macos/platform/zz_probe/zz_probe.py';
const MAP = new Map([
	['macos/platform/zz_probe/zz_probe.py', 'macos/core/zz/adapters/zz_probe.py']
]);

/** Scans `text` as the probe file under `map` and applies its rows. */
function rewrite(text, map = MAP) {
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(map));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	return Apply.rewriteText(text, rows, new Map(), FILE);
}

function run() {
	// The driver root, two folders up before and three after the move.
	{
		const out = rewrite('root = Path(__file__).absolute().parents[2]\n');
		assert.ok(out.includes('Path(__file__).absolute().parents[3]'), out);
	}
	// The same climb spelled with .parent: one more .parent.
	{
		const out = rewrite('root = Path(__file__).resolve().parent.parent.parent\n');
		assert.ok(out.includes('Path(__file__).resolve().parent.parent.parent.parent\n'), out);
	}
	// A file that stays keeps its climb.
	{
		const text = 'root = Path(__file__).absolute().parents[2]\n';
		const stays = new Map([[[...MAP.keys()][0], [...MAP.keys()][0]]]);
		assert.equal(rewrite(text, stays), text);
	}
	console.log('[OK] a bare Python climb in a moving file names the same folder.');
}

run();
