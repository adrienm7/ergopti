// tools/test/test-structure-scope-ancestor.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Scope Ancestors
 * DESCRIPTION:
 * A folder the plan scatters used to be respelled, in live code, as the
 * nearest folder holding all its new places. When that folder is above the
 * old one (tests/unit for tests/unit/infra), the respelling widens what the
 * code scans: S04 turned the Linux and macOS CI shard groups' "core" and
 * "infra" prefixes into "tests/unit/", so "core" swallowed every unit test
 * and "infra" ran none. Such a site now names each real new home, keeps its
 * name while the folder still holds files, or refuses the step.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const GROUPS = [
	'static/ergopti_plus/linux/tests/support/module_groups.lua',
	'static/ergopti_plus/macos/tests/support/module_groups.lua'
];

/** The repository map with only `id`'s moves applied, as the runner builds it. */
function stepMap(map, plan, id) {
	const step = plan.find((s) => s.id === id);
	return new Map([...map].map(([o, t]) => [o, step.moves.some(([so]) => so === o) ? t : o]));
}

function run() {
	const { map } = Plan.moveMap();
	const plan = Plan.steps(map);
	let checked = 0;
	for (const id of ['S04', 'S05']) {
		if (!plan.some((s) => s.id === id)) continue;
		const ctx = Plan.referenceContext(stepMap(map, plan, id));
		for (const file of GROUPS) {
			const full = path.join(REPO, file);
			// Once the step has landed, its folders are gone and so is the case.
			if (!fs.existsSync(full)) continue;
			const text = fs.readFileSync(full, 'utf8');
			if (!/tests\/unit\/(?:infra|adapters)\//.test(text)) continue;
			const rows = Plan.scanFile(file, text, ctx).filter((r) =>
				/^tests\/unit\/(?:infra|adapters)\/?$/.test(r.old)
			);
			for (const r of rows) {
				checked++;
				const above = r.resolution?.oldRepo?.startsWith(`${r.new}/`);
				assert.ok(
					!(r.kind === 'dir-successor' && above),
					`${id} ${file}: ${r.old} widened to ${r.new}`
				);
				assert.ok(
					['dir-kept', 'dir-split', 'scope-split', 'dir'].includes(r.kind),
					`${id} ${file}: ${r.old} as ${r.kind}`
				);
			}
		}
	}
	console.log(
		`[OK] a scattered folder never widens a live scope to a folder above it (${checked} site(s)).`
	);
}

run();
