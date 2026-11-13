// tools/test/test-structure-shared-root-switch.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Shared Lua Root Switch
 * DESCRIPTION:
 * The structure plan moves every shared Lua module out of _shared/lua into
 * _shared/<feature>/engine/, and the shared Lua root becomes _shared itself.
 * The first real application of S01 moved the files but left 349 references
 * to the old root: the LUA_PATH lines of ci-linux.yml, both runners'
 * `drivers_root .. "/_shared/lua"`, the bytecode package's
 * `shared .. "/lua/"`, the installers' SHARED_LUA, and three generated data
 * modules that no rule gave a home. The Linux runner died on its first
 * require. The step that empties _shared/lua now carries the switch: every
 * spelling of the old root is rewritten in the same commit, and the plan
 * refuses a map that leaves a file under _shared/lua.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

function run() {
	const cases = [
		[
			'local shared_lua = drivers_root .. "/_shared/lua"',
			'local shared_lua = drivers_root .. "/_shared"'
		],
		[
			"LUA_PATH: './?.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;'",
			"LUA_PATH: './?.lua;../_shared/?.lua;../_shared/?/init.lua;;'"
		],
		['SHARED_LUA="$DRIVER_ROOT/_shared/lua"', 'SHARED_LUA="$DRIVER_ROOT/_shared"'],
		['local _shared = logger_shared_root .. "/lua"', 'local _shared = logger_shared_root'],
		[
			'package.path = shared .. "/lua/?.lua;" .. SHARED .. "lua/?/init.lua;"',
			'package.path = shared .. "/?.lua;" .. SHARED .. "?/init.lua;"'
		],
		['return shared and shared .. "/lua/" or nil', 'return shared and shared .. "/" or nil'],
		['(shared / "lua").mkdir()', '(shared).mkdir()'],
		["[SHARED_ROOT + '/lua', DRIVER_ROOT]", '[SHARED_ROOT, DRIVER_ROOT]'],
		['`${macos}/?.lua;${shared}/lua/?.lua;`', '`${macos}/?.lua;${shared}/?.lua;`'],
		['local root = Paths.shared("lua")', 'local root = Paths.shared_root()'],
		['package.path = arg[1] .. "/lua/?.lua;" .. p', 'package.path = arg[1] .. "/?.lua;" .. p'],
		["read(shared('lua', page.Lua.modulePath(name)))", 'read(shared(page.Lua.modulePath(name)))'],
		["local shared_lua = '_shared' .. sep .. 'lua'", "local shared_lua = '_shared'"],
		// The shared test folder as a whole is now the shared test tree.
		['{ driver .. "/_shared/lua/test/" }', '{ driver .. "/_shared/tests/" }']
	];
	for (const [before, after] of cases)
		assert.equal(Plan.sharedRootRewrite(before), after, `the switch rewrites: ${before}`);
	// Names that only start like the root are not the root.
	for (const keep of [
		'x/_shared/lua_extra',
		'y/_shared/lua.md',
		'my_shared/lua',
		'shared .. "/luac"',
		"SHARED_ROOT + '/lua_extra'",
		'`${shared}/luac`'
	])
		assert.equal(Plan.sharedRootRewrite(keep), keep, `not the root: ${keep}`);

	// The step that empties _shared/lua carries the switch; no other does.
	const empties = new Map([
		['_shared/lua/json.lua', '_shared/core/text/engine/json.lua'],
		['linux/infra/x.lua', 'linux/infra/x.lua']
	]);
	assert.equal(Plan.switchesSharedRoot(empties), true);
	assert.equal(
		Plan.switchesSharedRoot(new Map([['linux/infra/x.lua', 'linux/core/x.lua']])),
		false,
		'a step that moves no shared file does not switch the root'
	);
	assert.equal(
		Plan.switchesSharedRoot(
			new Map([...empties, ['_shared/lua/left.lua', '_shared/lua/left.lua']])
		),
		false,
		'a step that leaves a shared file behind cannot switch the root'
	);

	// A map that leaves a file under _shared/lua is refused, not half applied.
	assert.throws(
		() => Plan.moveMap(['_shared/lua/zz_a.lua', '_shared/lua/zz_b.lua', '_shared/lua/zz_c.lua']),
		/stay under _shared\/lua\//
	);
	// The three generated data modules S01 left behind have a home.
	const { map } = Plan.moveMap([
		'_shared/lua/secure_apps.lua',
		'_shared/lua/secure_apps_data.lua',
		'_shared/lua/linux_app_identities_data.lua',
		'_shared/lua/app_parameter.lua'
	]);
	for (const [old, target] of map)
		assert.ok(target && !target.startsWith('_shared/lua/'), `${old} leaves _shared/lua`);

	// The applier rewrites a file's paths first and switches the root last.
	const text = 'p = "static/ergopti_plus/_shared/lua/json.lua"; q = root .. "/_shared/lua/?.lua"';
	const out = Apply.rewriteText(
		text,
		[
			{ kind: 'shared-root', old: '_shared/lua', new: '_shared' },
			{
				kind: 'path',
				old: 'static/ergopti_plus/_shared/lua/json.lua',
				new: 'static/ergopti_plus/_shared/core/text/engine/json.lua',
				file: 'static/ergopti_plus/linux/x.lua',
				resolution: {
					form: 'repo',
					lead: '',
					newRepo: 'static/ergopti_plus/_shared/core/text/engine/json.lua'
				}
			}
		],
		new Map(),
		'static/ergopti_plus/linux/x.lua'
	);
	assert.equal(
		out,
		'p = "static/ergopti_plus/_shared/core/text/engine/json.lua"; q = root .. "/_shared/?.lua"'
	);
	// shared('lua', name) is a join onto the old root, not a split folder: the
	// switch drops the piece, and the step is not refused for it.
	const root = 'static/ergopti_plus/_shared/lua';
	const had = Plan.EXISTING.has(root);
	Plan.EXISTING.add(root);
	try {
		const ctx = Plan.referenceContext(empties);
		const line = "const src = read(shared('lua', page.Lua.modulePath(name)));\n";
		const rows = Plan.scanFile('tools/test/z.cjs', line, ctx);
		assert.deepEqual(
			rows.map((r) => r.kind),
			['shared-root'],
			'a join onto the old root leaves the respelling to the switch'
		);
		assert.equal(
			Apply.rewriteText(line, rows, new Map(), 'tools/test/z.cjs'),
			'const src = read(shared(page.Lua.modulePath(name)));\n'
		);
	} finally {
		if (!had) Plan.EXISTING.delete(root);
	}
	console.log(
		'[OK] the step that empties _shared/lua switches every spelling of the shared Lua root.'
	);
}

run();
