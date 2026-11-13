// tools/test/test-structure-shared-driver-paths.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Driver Paths In Shared Files
 * DESCRIPTION:
 * The shared config migration checks that its file-system port comes from the
 * driver's own adapter, by spelling that adapter's place under the driver root
 * (folder .. "/adapters/file_system.lua", "adapters/file_system.lua"). S04
 * moved the adapter to core/fs/adapters in both drivers and left both
 * spellings behind, so every macOS and Linux config migration refused with
 * "native configuration initializer is unavailable". A shared file's path
 * under a driver root now follows the file where every driver that holds it
 * moves it alike.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const ADAPTERS = [
	'static/ergopti_plus/macos/adapters/file_system.lua',
	'static/ergopti_plus/linux/adapters/file_system.lua'
];
const PROBE = 'static/ergopti_plus/_shared/zz_probe_migrate.lua';

function run() {
	// Once S04 has landed, the adapters are gone and so is the case.
	if (!ADAPTERS.every((f) => fs.existsSync(path.join(REPO, f)))) {
		console.log('[OK] driver paths in shared files: S04 has landed, nothing to check.');
		return;
	}
	const { map } = Plan.moveMap();
	const plan = Plan.steps(map);
	const step = plan.find((s) => s.moves.some(([o]) => `static/ergopti_plus/${o}` === ADAPTERS[0]));
	const stepMap = new Map(
		[...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o])
	);
	const fresh = map.get(ADAPTERS[0].slice('static/ergopti_plus/'.length));
	const rel = fresh.slice('macos/'.length);
	const text =
		'for _, suffix in ipairs({ folder .. "/adapters/file_system.lua", "adapters/file_system.lua" }) do\n';
	const rows = Plan.scanFile(PROBE, text, Plan.referenceContext(stepMap));
	assert.ok(
		!rows.some((r) => Plan.REFUSED_KINDS.has(r.kind)),
		JSON.stringify(rows.filter((r) => Plan.REFUSED_KINDS.has(r.kind)))
	);
	const out = Apply.rewriteText(text, rows, new Map(), PROBE);
	assert.ok(out.includes(`folder .. "/${rel}"`), out);
	assert.ok(out.includes(`, "${rel}" }`), out);
	console.log(`[OK] a shared file's path under a driver root follows the file (${rel}).`);
}

run();
