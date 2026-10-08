// tools/test/test-physical-source-selectors.cjs

/**
 * ==============================================================================
 * MODULE: Physical Source Selector Declarations
 * DESCRIPTION:
 * Exercises the real generated defaults, migration engine and native setting
 * registry without granting runtime installation or menu callback authority.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { parse } = require('smol-toml');
const { findRuntime } = require('./run-linux-lua.cjs');

const root = path.resolve(__dirname, '../..');
const shared = path.join(root, 'static/ergopti_plus/_shared');
const manifestPath = path.join(shared, 'modules/features/manifest.toml');
const menuPath = path.join(shared, 'modules/menu/menu_manifest.json');
const nativePath = path.join(shared, 'platform/remap/runtime_setting.json');
const checks = [];

/** Runs each independent control even when another prerequisite is absent. */
function check(name, run) {
	try {
		run();
		checks.push({ name, passed: true });
	} catch (error) {
		checks.push({ name, passed: false, error: error.message });
	}
}

check('main enum schema refuses invalid values and has no native-file alias', () => {
	const schema = JSON.parse(
		fs.readFileSync(path.join(shared, 'core/config_schema/config.schema.json'))
	);
	assert.deepEqual(schema.$defs.metrics.properties.physical_source, {
		type: 'string',
		enum: ['ledger', 'stream']
	});
	assert.equal(Object.hasOwn(schema.properties, 'karabiner'), false);
	const manifest = parse(fs.readFileSync(manifestPath, 'utf8'));
	const feature = manifest.features.metrics.find((entry) => entry.id === 'physical_source');
	assert.ok(feature, 'the physical source must be a real declared feature');
	assert.equal(feature.default, 'ledger');
	assert.equal(feature.recommended, 'ledger');
	assert.deepEqual(feature.enum_values, ['ledger', 'stream']);
	assert.deepEqual(feature.platforms, ['hs']);
	assert.equal(feature.input_altering, false);
	assert.equal(feature.reason_key, 'platform_reason.physical_stream_macos_only');
});

check('actual Lua projection supplies ledger and migrations retain selector bytes', () => {
	const program = String.raw`
local shared = assert(arg[1], 'actual absolute shared source path is required')
package.path = shared .. '/lua/?.lua;' .. shared .. '/lua/?/init.lua;' .. package.path
local manifest = assert(loadfile('static/ergopti_plus/macos/_generated/features_manifest.lua'))()
local entry
for _, feature in ipairs(manifest.features) do
  if feature.path == 'metrics.physical_source' then entry = feature end
end
assert(entry, 'missing generated physical source')
assert(entry.default == 'ledger' and entry.recommended == 'ledger')
assert(entry.enum_values[1] == 'ledger' and entry.enum_values[2] == 'stream' and #entry.enum_values == 2)
local linux = assert(loadfile('static/ergopti_plus/linux/_generated/features_manifest.lua'))()
for _, feature in ipairs(linux.features) do
  assert(feature.path ~= 'metrics.physical_source', 'Linux must not advertise a producer')
end
local codec, migration = require('toml_codec'), require('config_migrate')
local file = assert(io.open(shared .. '/core/config_schema/migrations.toml', 'rb'))
local registry = assert(migration.validate_registry(codec.decode(file:read('*a')))); file:close()
for _, source in ipairs({
  '[_meta]\nschema_version = 10\n[metrics]\n# retain\nphysical_source = "stream"\nneighbor = "keep"\n',
  '[_meta]\nschema_version = 10\n[metrics]\n# retain\nphysical_source = "invalid"\nneighbor = "keep"\n',
  '[_meta]\nschema_version = 10\n[metrics]\nneighbor = "keep"\n'
}) do
  local plan = migration.plan(source, registry, 'hs')
  assert(plan.outcome == 'migrated', plan.detail or plan.outcome)
  local before, after = codec.decode(source), codec.decode(plan.candidate)
  assert(before.metrics.physical_source == after.metrics.physical_source)
  assert(after.metrics.neighbor == 'keep')
  if before.metrics.physical_source ~= nil then
    assert(plan.candidate:find('# retain\nphysical_source = "' .. before.metrics.physical_source .. '"\n', 1, true))
  end
end
print('generated default and 3 actual migration controls passed')
`;
	const runtime = findRuntime();
	assert.ok(runtime, 'an actual Lua runtime is required');
	const result = spawnSync(runtime, ['-', shared], { cwd: root, input: program, encoding: 'utf8' });
	assert.equal(result.status, 0, result.stderr || result.error?.message);
	assert.match(result.stdout, /3 actual migration controls passed/);
	for (const driver of ['windows', 'macos', 'linux']) {
		const template = parse(
			fs.readFileSync(
				path.join(root, `static/ergopti_plus/${driver}/_generated/config_template.toml`),
				'utf8'
			)
		);
		assert.equal(template.metrics.physical_source, driver === 'macos' ? 'ledger' : undefined);
		assert.equal(
			template.karabiner,
			undefined,
			`${driver}: native settings must never enter main config`
		);
	}
});

check('native registry retains exact file/owner/default and refuses malformed declarations', () => {
	const { validateRuntimeSetting } = require('../lib/karabiner-runtime-setting.cjs');
	const setting = validateRuntimeSetting(JSON.parse(fs.readFileSync(nativePath)));
	assert.equal(setting.path, 'karabiner.runtime');
	assert.equal(setting.file, 'config_karabiner.toml');
	assert.equal(setting.owner, 'platform.remap.config');
	assert.deepEqual(setting.platforms, ['hs']);
	assert.equal(setting.default, 'shared');
	assert.equal(setting.recommended, 'shared');
	assert.deepEqual(setting.enum_values, ['shared', 'owned']);
	for (const bad of [
		{ ...setting, file: 'config.toml' },
		{ ...setting, owner: 'infra.preferences' },
		{ ...setting, platforms: ['hs', 'linux'] },
		{ ...setting, enum_values: ['shared', 'shared'] },
		{ ...setting, default: 'invalid' },
		{ ...setting, runtime_authority: true }
	])
		assert.throws(() => validateRuntimeSetting(bad));
	for (const value of [undefined, 'shared', 'owned', 'invalid', true, {}, []]) {
		const resolved = value === undefined ? setting.default : value;
		assert.equal(
			setting.enum_values.includes(resolved),
			value === undefined || value === 'shared' || value === 'owned'
		);
	}
});

check('real choice compiler projects native values without mutating the live menu tree', () => {
	const original = fs.readFileSync(manifestPath);
	const menu = fs.readFileSync(menuPath);
	const fixture =
		'\n[[menu.selector_test_rows]]\ntype = "choice"\nid = "karabiner_runtime"\npath = "karabiner.runtime"\ni18n = "menu.global.karabiner_runtime"\nchoice_registry = "karabiner.runtime"\nplatforms = ["hs"]\nunavailable = "hide"\n';
	try {
		fs.writeFileSync(manifestPath, Buffer.concat([original, Buffer.from(fixture)]));
		const result = spawnSync(process.execPath, ['tools/build/build-menu-manifest.js'], {
			cwd: root,
			encoding: 'utf8'
		});
		assert.equal(result.status, 0, result.stderr);
		const projected = JSON.parse(fs.readFileSync(menuPath));
		assert.deepEqual(projected.selector_test_rows[0].choices, [
			{ value: 'shared', i18n: 'menu.global.karabiner_runtime.shared' },
			{ value: 'owned', i18n: 'menu.global.karabiner_runtime.owned' }
		]);
		delete projected.selector_test_rows;
		assert.deepEqual(projected, JSON.parse(menu));
		fs.writeFileSync(
			manifestPath,
			Buffer.concat([
				original,
				Buffer.from(fixture.replace('platforms = ["hs"]', 'platforms = ["hs", "linux"]'))
			])
		);
		const rejected = spawnSync(process.execPath, ['tools/build/build-menu-manifest.js'], {
			cwd: root,
			encoding: 'utf8'
		});
		assert.notEqual(rejected.status, 0, 'a native choice cannot be offered by another driver');
		assert.match(rejected.stderr, /shown on linux/);
	} finally {
		fs.writeFileSync(manifestPath, original);
		fs.writeFileSync(menuPath, menu);
	}
});

check('all 21 locales contain the complete genuine selector and unavailable captions', () => {
	const keys = [
		'menu.metrics.physical_source',
		'menu.metrics.physical_source.ledger',
		'menu.metrics.physical_source.stream',
		'menu.metrics.physical_source_unavailable',
		'platform_reason.physical_stream_macos_only',
		'menu.global.karabiner_runtime',
		'menu.global.karabiner_runtime.shared',
		'menu.global.karabiner_runtime.owned',
		'menu.global.karabiner_runtime_unavailable'
	];
	const files = fs
		.readdirSync(path.join(shared, 'data/locales'))
		.filter((name) => name.endsWith('.json'));
	assert.equal(files.length, 21);
	for (const name of files) {
		const locale = JSON.parse(fs.readFileSync(path.join(shared, 'data/locales', name)));
		for (const key of keys)
			assert.ok(typeof locale[key] === 'string' && locale[key].trim(), `${name}: ${key}`);
	}
});

check('actual metrics/global restore and clear preserve stream and invalid source intent', () => {
	const program = String.raw`local shared = assert(arg[1], 'actual absolute shared source path is required')
package.path = shared .. '/lua/?.lua;' .. shared .. '/lua/?/init.lua;' .. package.path
local manifest = assert(loadfile('static/ergopti_plus/macos/_generated/features_manifest.lua'))()
local defaults = require('config_defaults').new(manifest)
assert(defaults.has_default('metrics.physical_source'), 'the scope control needs the genuine declared selector')
local writer, codec = require('toml_codec.writer'), require('toml_codec')
local count = 0
for _, selected in ipairs({'stream', 'invalid'}) do
  for _, scope in ipairs({'metrics', 'global'}) do
    for _, mode in ipairs({'recommended', 'clear'}) do
      local plan = defaults.scope_plan(scope, mode)
      assert(#plan.operations >= 10, 'the genuine scope planner must produce unrelated work')
      for _, operation in ipairs(plan.operations) do
        assert(not (operation.section == 'metrics' and operation.key == 'physical_source'),
          scope .. '/' .. mode .. ' must not own the physical source selector')
      end
      local source = '[metrics]\nphysical_source = "' .. selected .. '"\nneighbor = "keep"\nencrypt = true\n'
      local destination = os.tmpname()
      local file = assert(io.open(destination, 'wb')); file:write(source); file:close()
      local files = { read_with_status = function(path)
        local input = assert(io.open(path, 'rb')); local bytes = input:read('*a'); input:close()
        return bytes, 'ok'
      end }
      local prepared, detail, candidate, retained = writer.prepare_batch(destination, plan.operations, files,
        { status = 'ok', content = source })
      assert(os.remove(destination))
      assert(prepared == true, detail)
      assert(type(candidate) == 'string' and retained.status == 'ok' and retained.content == source)
      local result = codec.decode(candidate)
      assert(result.metrics.physical_source == selected)
      assert(result.metrics.neighbor == 'keep')
      assert(candidate:find('physical_source = "' .. selected .. '"\nneighbor = "keep"\n', 1, true))
      count = count + 1
    end
  end
end
assert(count == 8)
print('8 actual metrics/global restore/clear retained-source controls passed')
`;
	const runtime = findRuntime();
	assert.ok(runtime, 'an actual Lua runtime is required');
	const result = spawnSync(runtime, ['-', shared], { cwd: root, input: program, encoding: 'utf8' });
	assert.equal(result.status, 0, result.stderr || result.error?.message);
	assert.match(
		result.stdout,
		/8 actual metrics\/global restore\/clear retained-source controls passed/
	);
});

for (const item of checks)
	console.log(
		`${item.passed ? 'PASS' : 'FAIL'} ${item.name}${item.error ? `: ${item.error}` : ''}`
	);
assert.equal(checks.length, 6);
process.exitCode = checks.every((item) => item.passed) ? 0 : 1;
