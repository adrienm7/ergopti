// tools/test/test-structure-scope-overlap.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Overlapping Scope Expansions
 * DESCRIPTION:
 * A list of scan roots names folders a step scatters, and each scattered
 * element is respelled as one element per new home. Two elements of one list
 * can gain homes that hold each other: after S08 the convention lint scanned
 * macos/core/network (gained by ui) and macos/core/network/adapters (gained
 * by adapters and by platform), so its recursive walk read those files two
 * and three times and the banner-marker check counted 40 Lua files for 36.
 * An added element the list already scans, itself or through a parent, is
 * dropped.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Apply = require('../audit/structure/apply-step.cjs');

const FILE = 'tools/lint/zz_probe.js';
const line = (folder) => `\tjoin(REPO_ROOT, 'static/ergopti_plus/macos/${folder}'),`;

function run() {
	const text = ['const roots = [', line('adapters'), line('ui'), line('platform'), '];', ''].join(
		'\n'
	);
	const rows = [
		{
			kind: 'scope-split',
			old: line('adapters'),
			new: [line('adapters'), line('core/network/adapters')].join('\n')
		},
		{
			kind: 'scope-split',
			old: line('ui'),
			new: [line('ui'), line('core/network')].join('\n')
		},
		{
			kind: 'scope-split',
			old: line('platform'),
			new: [line('platform'), line('core/network/adapters')].join('\n')
		}
	];
	const out = Apply.rewriteText(text, rows, new Map(), FILE);
	assert.equal(out.split(line('core/network')).length, 2, out);
	assert.ok(!out.includes(line('core/network/adapters')), out);
	for (const kept of ['adapters', 'ui', 'platform']) assert.ok(out.includes(line(kept)), out);
	// Folders that only share a name prefix are not nested: both stay.
	const prefix = Apply.rewriteText(
		['const roots = [', line('ui'), '];', ''].join('\n'),
		[
			{
				kind: 'scope-split',
				old: line('ui'),
				new: [line('ui'), line('core/net'), line('core/network')].join('\n')
			}
		],
		new Map(),
		FILE
	);
	assert.ok(prefix.includes(line('core/net')) && prefix.includes(line('core/network')), prefix);
	console.log('[OK] a scope list gains each new home once, never under another.');
}

run();
