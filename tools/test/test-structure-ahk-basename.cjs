// tools/test/test-structure-ahk-basename.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan AutoHotkey Base-Name Lookups
 * DESCRIPTION:
 * Windows tests read a production file by its base name through
 * _DriverFileSource, often behind a reader of their own:
 * _VpnRet_ReadSource("network_info.ahk"). S08 renamed that file to
 * core/network/adapters/info.ahk and left the lookups on the old name, so
 * four network info cases failed on CI. A quoted base name of a production
 * file the step renames now follows it; a new name another production file
 * shares would find neither, so the step is refused.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const RENAMED = 'windows/adapters/network_info.ahk';
const FILE = 'static/ergopti_plus/windows/tests/meta/zz_probe/test_zz_probe.ahk';

function run() {
	if (!fs.existsSync(path.join(REPO, 'static/ergopti_plus', RENAMED))) {
		console.log('[OK] AutoHotkey base-name lookups: the network step has landed.');
		return;
	}
	const { map } = Plan.moveMap();
	const step = Plan.steps(map).find((s) => s.moves.some(([o]) => o === RENAMED));
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const fresh = map.get(RENAMED).split('/').pop();
	const text = '\tSrc := _VpnRet_ReadSource("network_info.ahk")\n';
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(stepMap));
	assert.ok(!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)), JSON.stringify(rows));
	const out = Apply.rewriteText(text, rows, new Map(), FILE);
	assert.ok(out.includes(`_VpnRet_ReadSource("${fresh}")`), out);
	// A new base name another production file shares is refused.
	const shared = new Map(stepMap);
	shared.set('windows/adapters/zz_probe_other.ahk', `windows/core/zz_probe/${fresh}`);
	const refused = Plan.scanFile(FILE, text, Plan.referenceContext(shared));
	assert.ok(
		refused.some((r) => r.kind === 'dir-split'),
		JSON.stringify(refused)
	);
	console.log(`[OK] a Windows base-name lookup follows the file ${step.id} renames.`);
}

run();
