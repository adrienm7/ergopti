// tools/test/test-structure-regex-tail-paths.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Regex-Escaped Tool Paths
 * DESCRIPTION:
 * A tool checks a source with a JavaScript regular expression that spells a
 * path relative to a folder it never names: 'infra\/openssl_digest\.lua'
 * under the Linux driver, unit\/infra\/lifecycle\/x\.ahk under windows/tests.
 * The plan left escaped tokens to rules that need a spelled base, so S06 and
 * S08 kept both expressions on the old paths and the updater registration
 * and release packaging checks failed. A tail exactly one file ends with now
 * follows that file, escaped the same way.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const DIGEST = 'linux/infra/openssl_digest.lua';
const FILE = 'tools/test/test-zz-probe.cjs';

function run() {
	// Once the step that moves the digest has landed, the case is gone.
	if (!fs.existsSync(path.join(REPO, 'static/ergopti_plus', DIGEST))) {
		console.log('[OK] regex-escaped tool paths: the digest step has landed.');
		return;
	}
	const { map } = Plan.moveMap();
	const step = Plan.steps(map).find((s) => s.moves.some(([o]) => o === DIGEST));
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const fresh = map.get(DIGEST).slice('linux/'.length);
	const escape = (p) => p.replace(/\./g, '\\.').replace(/\//g, '\\/');
	const text = `assert.match(src, /path\\.join\\(driver, '${escape('infra/openssl_digest.lua')}'\\)/);\n`;
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(stepMap));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	const out = Apply.rewriteText(text, rows, new Map(), FILE);
	assert.ok(out.includes(`'${escape(fresh)}'`), out);
	// A tail no file ends with, or that several files end with, stays.
	const loose = "assert.match(src, /'zz_probe\\/nothing\\.lua'|'init\\.lua'/);\n";
	const looseRows = Plan.scanFile(FILE, loose, Plan.referenceContext(stepMap));
	assert.equal(Apply.rewriteText(loose, looseRows, new Map(), FILE), loose);
	console.log(`[OK] a regex-escaped tool path follows the file ${step.id} moves.`);
}

run();
