// tools/test/test-structure-published-records.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Published Records
 * DESCRIPTION:
 * Some text describes an artifact that already exists outside the tree: the
 * v1.0.9 release still extracts _shared/core/config_schema/migrations.toml,
 * and a hardware receipt names the files of a run at a past commit. S01
 * respelled the prior release's extracted asset paths and its bundle reads
 * to the new layout, and Windows Install and launch failed on dev. Paths in
 * a published record (edits.cjs PUBLISHED_RECORDS) are never rewritten,
 * while the same file's live reads still follow the move.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');
const Edits = require('../audit/structure/edits.cjs');

const REPO = path.resolve(__dirname, '..', '..');

function run() {
	// Every record names something real, and each region still matches.
	for (const record of Edits.PUBLISHED_RECORDS) {
		assert.ok(record.why, JSON.stringify(record));
		if (record.prefix) {
			const dir = path.join(REPO, record.prefix);
			assert.ok(fs.readdirSync(dir).length > 0, `${record.prefix} holds no record`);
			continue;
		}
		const text = fs.readFileSync(path.join(REPO, record.file), 'utf8');
		if (record.region)
			assert.ok(new RegExp(record.region.source, record.region.flags).test(text), record.file);
		else assert.ok(Plan.neverRewritten(record.file), record.file);
	}
	assert.ok(
		Plan.neverRewritten('static/ergopti_plus/linux/tests/hardware/desktop/receipts/zz_probe.txt')
	);

	// A region holds the released payload while a live read in the same file
	// follows the move.
	const FILE = 'tools/test/test-compiled-save-upgrade.cjs';
	const asset = 'static/ergopti_plus/_shared/zz_probe/data/migrations.toml';
	const text = [
		'const RELEASE = {',
		'\t\textracted_assets: [',
		'\t\t\t{',
		`\t\t\t\tpath: '${asset}',`,
		'\t\t\t\tbytes: 1',
		'\t\t\t}',
		'\t\t]',
		'};',
		`const LIVE = path.join(ROOT, '${asset}');`,
		''
	].join('\n');
	const moved = 'static/ergopti_plus/_shared/zz_probe/settings/migrations.toml';
	const rows = [
		{
			file: FILE,
			kind: 'path',
			old: asset,
			new: moved,
			resolution: { form: 'repo', newRepo: moved }
		}
	];
	const out = Apply.rewriteText(text, rows, new Map(), FILE);
	assert.ok(out.includes(`\t\t\t\tpath: '${asset}',`), out);
	assert.ok(out.includes(`path.join(ROOT, '${moved}')`), out);
	console.log('[OK] a published record keeps the paths of the artifact it describes.');
}

run();
