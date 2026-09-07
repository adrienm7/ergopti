/**
 * tools/test/test-metrics-apps-publication-order.cjs
 * ==============================================================================
 * MODULE: Metrics Apps Publication Ordering
 * DESCRIPTION:
 * Runs the actual dashboard bridge and observes its private applied state.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { spawnSync } = require('node:child_process');

const source = fs.readFileSync(path.resolve(__dirname,
	'../../static/ergopti_plus/_shared/ui/metrics_apps/script.js'), 'utf8');
let passed = 0;
let failed = 0;

function fixture() {
	const context = vm.createContext({ window: {}, document: { addEventListener() {} }, console });
	vm.runInContext(fs.readFileSync(path.resolve(__dirname,
		'../../static/ergopti_plus/_shared/ui/host_bridge.js'), 'utf8'), context);
	vm.runInContext(source, context);
	vm.runInContext('initDashboard = function() {}; renderDashboard = function() {};', context);
	return {
		context,
		bootstrap: context.window.publishMetricsAppsData,
		categories: context.window.publishMetricsAppsCategories,
		state: () => JSON.parse(vm.runInContext('JSON.stringify([manifestData, userCategories, appIcons])', context))
	};
}

function test(name, callback) {
	try {
		callback();
		passed++;
		console.log(`ok ${name}`);
	} catch (error) {
		failed++;
		console.error(`FAIL ${name}: ${error.message}`);
	}
}

const revision = (manifest, categories) => ({ manifest_revision: manifest, categories_revision: categories });

test('cache can paint a fresh page and page watermarks are isolated', () => {
	const first = fixture();
	first.bootstrap({ first: 1 }, { first: 1 }, { first: 1 }, revision(9, 9));
	const second = fixture();
	second.bootstrap({ cache: 1 }, { cache: 1 }, { cache: 1 }, revision(0, 0));
	assert.deepEqual(second.state(), [{ cache: 1 }, { cache: 1 }, { cache: 1 }]);
	assert.deepEqual(first.state(), [{ first: 1 }, { first: 1 }, { first: 1 }]);
});

test('a submitted but unexecuted fresh publication cannot suppress cache paint', () => {
	const f = fixture();
	const submitted = () => f.bootstrap({ fresh: 1 }, { fresh: 1 }, { fresh: 1 }, revision(1, 1));
	f.bootstrap({ cache: 1 }, { cache: 1 }, { cache: 1 }, revision(0, 0));
	assert.deepEqual(f.state(), [{ cache: 1 }, { cache: 1 }, { cache: 1 }]);
	submitted();
	assert.deepEqual(f.state(), [{ fresh: 1 }, { fresh: 1 }, { fresh: 1 }]);
});

test('late cache cannot roll back either fresh component', () => {
	const f = fixture();
	assert.equal(f.bootstrap({ fresh: 1 }, { edited: 1 }, { fresh: 1 }, revision(2, 2)), true);
	assert.equal(f.bootstrap({ cache: 1 }, { cache: 1 }, { cache: 1 }, revision(0, 0)), false);
	assert.deepEqual(f.state(), [{ fresh: 1 }, { edited: 1 }, { fresh: 1 }]);
});

test('manifest and category revisions advance independently', () => {
	const f = fixture();
	assert.equal(f.categories({ edited: 1 }, 5), true);
	assert.equal(f.bootstrap({ fresh: 1 }, { stale: 1 }, { icon: 1 }, revision(2, 1)), true);
	assert.deepEqual(f.state(), [{ fresh: 1 }, { edited: 1 }, { icon: 1 }]);
	assert.equal(f.bootstrap({ stale: 1 }, { newest: 1 }, { stale: 1 }, revision(1, 6)), true);
	assert.deepEqual(f.state(), [{ fresh: 1 }, { newest: 1 }, { icon: 1 }]);
});

test('duplicate and reordered category callbacks cannot replace the applied edit', () => {
	const f = fixture();
	assert.equal(f.categories({ newest: 1 }, 3), true);
	assert.equal(f.categories({ duplicate: 1 }, 3), false);
	assert.equal(f.categories({ older: 1 }, 2), false);
	assert.deepEqual(f.state()[1], { newest: 1 });
});

for (const value of [undefined, null, -1, 1.5, Infinity, Number.MAX_SAFE_INTEGER + 1]) {
	test(`invalid category revision preserves state: ${String(value)}`, () => {
		const f = fixture();
		f.context.window.updateUserCategories({ initial: 1 });
		assert.throws(() => f.categories({ invalid: 1 }, value), /revision/i);
		assert.deepEqual(f.state()[1], { initial: 1 });
		f.categories({ accepted: 1 }, 0);
		assert.deepEqual(f.state()[1], { accepted: 1 });
	});
}

for (const metadata of [undefined, null, {}, revision(-1, 0), revision(1, NaN), revision(1, Infinity),
	revision(Number.MAX_SAFE_INTEGER + 1, 1), revision(1, 1.5)]) {
	test(`invalid metadata refuses every component: ${JSON.stringify(metadata)}`, () => {
		const f = fixture();
		f.context.window.bootstrapMetricsAppsData({ valid: 1 }, { valid: 1 }, { valid: 1 });
		assert.throws(() => f.bootstrap({ invalid: 1 }, { invalid: 1 }, { invalid: 1 }, metadata), /revision/i);
		assert.deepEqual(f.state(), [{ valid: 1 }, { valid: 1 }, { valid: 1 }]);
		f.bootstrap({ accepted: 1 }, { accepted: 1 }, { accepted: 1 }, revision(0, 0));
		assert.deepEqual(f.state(), [{ accepted: 1 }, { accepted: 1 }, { accepted: 1 }]);
	});
}

test('render failure cannot undo an already applied revision', () => {
	const f = fixture();
	vm.runInContext('initDashboard = function() { throw new Error("synthetic render refusal"); };', f.context);
	assert.throws(() => f.bootstrap({ fresh: 1 }, { fresh: 1 }, { fresh: 1 }, revision(2, 2)),
		/synthetic render refusal/);
	assert.deepEqual(f.state(), [{ fresh: 1 }, { fresh: 1 }, { fresh: 1 }]);
	vm.runInContext('initDashboard = function() {};', f.context);
	f.bootstrap({ stale: 1 }, { stale: 1 }, { stale: 1 }, revision(1, 1));
	assert.deepEqual(f.state(), [{ fresh: 1 }, { fresh: 1 }, { fresh: 1 }]);
});

test('a reentrant render applies a newer category without later rollback', () => {
	const f = fixture();
	f.context.newerCategory = () => f.categories({ newest: 1 }, 3);
	vm.runInContext('renderDashboard = function() { renderDashboard = function() {}; newerCategory(); };', f.context);
	f.categories({ first: 1 }, 1);
	f.categories({ older: 1 }, 2);
	assert.deepEqual(f.state()[1], { newest: 1 });
});

test('untagged Windows and Linux calls retain their replacement behavior', () => {
	const f = fixture();
	f.context.window.bootstrapMetricsAppsData({ first: 1 }, { first: 1 }, { first: 1 });
	f.context.window.bootstrapMetricsAppsData({ second: 1 }, { second: 1 }, { second: 1 });
	f.context.window.updateUserCategories({ edited: 1 });
	assert.deepEqual(f.state(), [{ second: 1 }, { edited: 1 }, { second: 1 }]);
});

test('actual Lua fresh then cache JavaScript executes without rolling back state', () => {
	const luaInput = `package.path='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;'..package.path
local json=require('json')
require('tests.support.metrics_delivery_fixture')(true,function(dashboard,state,evaluations,errors,successes,pending)
 evaluations[1].done('function')
 local cached=evaluations[2].code
 package.loaded['hs.json'].encode=json.encode
 dashboard._app_icon_cache={Editor=false}
 package.loaded['modules.keylogger.sqlite_reader'].read_manifest=function()
  return {['2026-01-01']={Editor={app_time_ms=10}}}
 end
 assert(dashboard.push_live_update())
 pending[#pending]()
 evaluations[#evaluations].done('function')
 print('PUBLICATIONS='..json.encode({cached,evaluations[#evaluations].code}))
 local results=os.getenv('ERGOPTI_METRICS_TEST_RESULTS')
 if results then
  results=json.decode(results)
  local discarded=0
  package.loaded['infra.logger'].debug=function() discarded=discarded+1 end
  evaluations[#evaluations].done(results[1])
  evaluations[2].done(results[2])
  assert(#errors==0, 'valid JavaScript results must not report failure')
  assert(#successes==1, 'only the applied fresh publication reports success')
  assert(discarded==1, 'the stale publication reports one debug discard')
  print('COMPLETIONS=verified')
 end
end)
	`;
	const options = {
		cwd: path.resolve(__dirname, '../../static/ergopti_plus/macos'),
		encoding: 'utf8',
		input: luaInput
	};
	const lua = spawnSync('lua', ['-'], options);
	assert.equal(lua.status, 0, lua.stderr + lua.stdout);
	const line = lua.stdout.split(/\r?\n/).find((value) => value.startsWith('PUBLICATIONS='));
	assert.ok(line, 'the actual Lua controller must emit both publications');
	const [cached, fresh] = JSON.parse(line.slice('PUBLICATIONS='.length));
	const pendingFresh = fixture();
	// Both native calls were submitted above, but only this cached script executes.
	assert.equal(vm.runInContext(cached, pendingFresh.context), true);
	assert.deepEqual(pendingFresh.state()[0], {});
	assert.equal(vm.runInContext(fresh, pendingFresh.context), true);
	assert.deepEqual(pendingFresh.state()[0], { '2026-01-01': { Editor: { app_time_ms: 10 } } });
	const f = fixture();
	const freshResult = vm.runInContext(fresh, f.context);
	assert.equal(freshResult, true);
	assert.deepEqual(f.state()[0], { '2026-01-01': { Editor: { app_time_ms: 10 } } });
	const cacheResult = vm.runInContext(cached, f.context);
	assert.equal(cacheResult, false);
	assert.deepEqual(f.state()[0], { '2026-01-01': { Editor: { app_time_ms: 10 } } });
	const completed = spawnSync('lua', ['-'], {
		...options,
		env: { ...process.env, ERGOPTI_METRICS_TEST_RESULTS: JSON.stringify([freshResult, cacheResult]) }
	});
	assert.equal(completed.status, 0, completed.stderr + completed.stdout);
	assert.ok(completed.stdout.includes('COMPLETIONS=verified'));
});

test('actual Lua category edit survives an older bootstrap and fresh responses stay ordered', () => {
	const lua = spawnSync('lua', ['-'], {
		cwd: path.resolve(__dirname, '../../static/ergopti_plus/macos'),
		encoding: 'utf8',
		input: `package.path='./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;'..package.path
local json=require('json')
require('tests.support.metrics_delivery_fixture')(true,function(dashboard,state,evaluations,errors,successes,pending)
 package.loaded['hs.json'].encode=json.encode
 dashboard._app_icon_cache={Editor=false}
 local duration=10
 package.loaded['modules.keylogger.sqlite_reader'].read_manifest=function()
  return {['2026-01-01']={Editor={app_time_ms=duration}}}
 end
 package.loaded['modules.keylogger.log_manager'].get_db_rev=function() return duration end
 local function fresh()
  assert(dashboard.push_live_update())
  pending[#pending]()
  evaluations[#evaluations].done('function')
  return evaluations[#evaluations].code
 end
 local older=fresh()
 local choose
 hs.chooser={new=function(callback)
  choose=callback
  local chooser={}
  for _,method in ipairs({'placeholderText','choices','searchSubText','show','delete'}) do
   chooser[method]=function(self) return self end
  end
  return chooser
 end}
 package.loaded['infra.dialog_util'].text_prompt=function() return 'button.ok','1' end
 local saved='{}'
 package.loaded['hs.json'].decode=json.decode
 package.loaded['adapters.file_system'].read_with_status=function() return saved,'ok' end
 package.loaded['adapters.file_system'].write_if_unchanged=function(_,content)
  saved=content
  return true
 end
 assert(dashboard.prompt_category('Editor','Old',0))
 choose({_kind='pick',_value='Edited'})
 local category=evaluations[#evaluations].code
 duration=20
 local newer=fresh()
 print('PUBLICATIONS='..json.encode({older,category,newer}))
end)
`
	});
	assert.equal(lua.status, 0, lua.stderr + lua.stdout);
	const line = lua.stdout.split(/\r?\n/).find((value) => value.startsWith('PUBLICATIONS='));
	assert.ok(line, 'the actual category producer must emit its publication');
	const [older, category, newer] = JSON.parse(line.slice('PUBLICATIONS='.length));
	const f = fixture();
	assert.equal(vm.runInContext(category, f.context), true);
	assert.deepEqual(f.state()[1], { Editor: { type: 'Edited', score: 1 } });
	assert.equal(vm.runInContext(older, f.context), true);
	assert.deepEqual(f.state()[0], { '2026-01-01': { Editor: { app_time_ms: 10 } } });
	assert.deepEqual(f.state()[1], { Editor: { type: 'Edited', score: 1 } });
	const reordered = fixture();
	assert.equal(vm.runInContext(newer, reordered.context), true);
	assert.equal(vm.runInContext(older, reordered.context), false);
	assert.deepEqual(reordered.state()[0], { '2026-01-01': { Editor: { app_time_ms: 20 } } });
});

console.log(`metrics publication ordering: ${passed} passed, ${failed} failed`);
process.exitCode = failed ? 1 : 0;
