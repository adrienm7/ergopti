// tools/test/test-structure-mkdir-ladder.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Fixture Folder Ladders
 * DESCRIPTION:
 * A fixture builds its tree with a ladder of mkdir calls, then writes files
 * under it. The repair kept each ladder entry's parents, but a written path
 * the step respelled into new folders gained none: after S04 the Linux shared
 * loader fixture wrote driver .. "/core/fs/engine/paths.lua" while its ladder
 * still created only driver .. "/infra", and all 35 cases failed on a missing
 * folder. A respelled path written under a ladder's base now adds its folders.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Apply = require('../audit/structure/apply-step.cjs');

function run() {
	const before = [
		'for _, dir in ipairs({ driver, driver .. "/infra", driver .. "/_shared" }) do',
		'\tassert(uv.fs_mkdir(dir, 448))',
		'end',
		'write(driver .. "/infra/paths.lua", source)',
		'local real = read(root .. "/../_shared/x/y.json")',
		''
	].join('\n');
	const after = before
		.replace('"/infra/paths.lua"', '"/core/fs/engine/paths.lua"')
		.replace('"/../_shared/x/y.json"', '"/../_shared/z/data/y.json"');
	const out = Apply.repairCoupled(before, after);
	assert.ok(
		out.includes(
			'{ driver, driver .. "/infra", driver .. "/_shared", driver .. "/core", driver .. "/core/fs", driver .. "/core/fs/engine" }'
		),
		out
	);
	// A read that climbs out of the base, or a base the ladder never creates,
	// adds nothing.
	assert.ok(!out.includes('"/.."'), out);
	assert.ok(!out.includes('root ..'.concat(' "/z')), out);
	// Nothing respelled: the ladder stays as written.
	assert.equal(Apply.repairCoupled(before, before), before);
	console.log('[OK] a fixture ladder gains the folders of a path the step respelled under it.');
}

run();
