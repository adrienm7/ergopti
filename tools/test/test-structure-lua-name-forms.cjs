// tools/test/test-structure-lua-name-forms.cjs

/**
 * ==============================================================================
 * MODULE: Structure Plan Lua Module Name Forms
 * DESCRIPTION:
 * A Lua module name is spelled in more forms than a quoted require argument.
 * After S01 the Linux and macOS suites failed on each form the plan missed:
 * - the shared test modules (test.assertions) had no new name at all, so
 *   493 references were left for review by hand;
 * - a name escaped for a Lua pattern, src:find('require%("test%.x"%)');
 * - dotted names inside a longer string, "infra.monotonic,keystats.x";
 * - a table of module names holding one-word entries ({ "keymap.x", "json" }),
 *   which the one-word load-site rule leaves alone by design;
 * - package.loaded.logger, a module key spelled as a field;
 * - helpers.load_module("unicode_case") and rawget(package.loaded, "x"), load
 *   sites under other names, and tables of one-word names handed to a module
 *   helper or iterated to purge package.loaded;
 * - and, the other way, a config key that spells a module name
 *   ("llm.app_profile_overrides"), rewritten in stored settings and in the
 *   generated config_keys.lua: a config key moves only where it is loaded.
 * Each is now an explicit rule; ordinary one-word strings still never move.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const Plan = require('../audit/structure/plan.cjs');
const Apply = require('../audit/structure/apply-step.cjs');

const FILE = 'static/ergopti_plus/linux/tests/unit/test_probe.lua';
const MAP = new Map([
	['_shared/lua/test/assertions.lua', '_shared/tests/lua/assertions.lua'],
	['_shared/lua/test/runner_home.lua', '_shared/tests/lua/core/runner_home.lua'],
	['_shared/lua/json.lua', '_shared/core/text/engine/json.lua'],
	['_shared/lua/crypto/init.lua', '_shared/core/crypto/engine/core.lua'],
	['_shared/lua/logger/init.lua', '_shared/core/logger/engine/core.lua'],
	['_shared/lua/keystats/session_events.lua', '_shared/metrics/engine/session_events.lua'],
	['_shared/lua/keymap/terminators.lua', '_shared/layouts/engine/terminators.lua'],
	['_shared/lua/unicode_case/init.lua', '_shared/core/text/engine/unicode_case/core.lua'],
	[
		'_shared/lua/llm/app_profile_overrides.lua',
		'_shared/ai/engine/policy/app_profile_overrides.lua'
	],
	['linux/infra/monotonic.lua', 'linux/infra/monotonic.lua'],
	['linux/tests/unit/test_probe.lua', 'linux/tests/unit/test_probe.lua']
]);

/** Scans `text` as the probe file and applies its rows. */
function rewrite(text) {
	const rows = Plan.scanFile(FILE, text, Plan.referenceContext(MAP));
	return Apply.rewriteText(text, rows, new Map(), FILE);
}

function run() {
	assert.equal(
		Plan.luaModuleName('_shared/tests/lua/core/runner_home.lua', true),
		'tests.lua.core.runner_home'
	);
	assert.equal(Plan.luaModuleName('_shared/lua/test/runner_home.lua'), 'test.runner_home');
	assert.equal(
		Plan.luaModuleName('_shared/tests/corpus/x.lua', true),
		null,
		'only tests/lua is a module root'
	);

	const cases = [
		['local A = require("test.assertions")', 'local A = require("tests.lua.assertions")'],
		[
			'src:find(\'\\nrequire%("test%.runner_home"%)%.isolate%(%)\')',
			'src:find(\'\\nrequire%("tests%.lua%.core%.runner_home"%)%.isolate%(%)\')'
		],
		[
			'assert_eq(x, "infra.monotonic,keystats.session_events")',
			'assert_eq(x, "infra.monotonic,metrics.engine.session_events")'
		],
		[
			'local mods = { "keymap.terminators", "json", "infra.monotonic" }',
			'local mods = { "layouts.engine.terminators", "core.text.engine.json", "infra.monotonic" }'
		],
		[
			'assert(package.loaded.logger == logger)',
			'assert(package.loaded["core.logger.engine.core"] == logger)'
		],
		[
			'local O = require("llm.app_profile_overrides"); local v = storage.get("llm.app_profile_overrides")',
			'local O = require("ai.engine.policy.app_profile_overrides"); local v = storage.get("llm.app_profile_overrides")'
		],
		[
			'assert_contains(src, "f[require(\\"unicode_case\\").X]")',
			'assert_contains(src, "f[require(\\"core.text.engine.unicode_case.core\\").X]")'
		],
		[
			'local Modules = package.loaded\nlocal J = rawget(Modules, "json")',
			'local Modules = package.loaded\nlocal J = rawget(Modules, "core.text.engine.json")'
		],
		[
			'local env = { require = function(name)\n\tif name == "json" then return require(name) end\nend }',
			'local env = { require = function(name)\n\tif name == "core.text.engine.json" then return require(name) end\nend }'
		],
		[
			'for key in pairs(package.loaded) do if key ~= "crypto" then package.loaded[key] = nil end end',
			'for key in pairs(package.loaded) do if key ~= "core.crypto.engine.core" then package.loaded[key] = nil end end'
		],
		[
			'local ports = {\n\t["tests.helpers"] = reporter,\n\t["json"] = { decode = d },\n}',
			'local ports = {\n\t["tests.helpers"] = reporter,\n\t["core.text.engine.json"] = { decode = d },\n}'
		],
		[
			'local NAMES = {\n\t"infra.monotonic",\n\t-- The shared owner.\n\t"json",\n}',
			'local NAMES = {\n\t"infra.monotonic",\n\t-- The shared owner.\n\t"core.text.engine.json",\n}'
		],
		[
			'local p = package.searchpath("json", package.path)',
			'local p = package.searchpath("core.text.engine.json", package.path)'
		],
		[
			"text = text:gsub('require%(\"unicode_case\"%)%.KEY', 'x')",
			"text = text:gsub('require%(\"core.text.engine.unicode_case.core\"%)%.KEY', 'x')"
		],
		[
			'local E = helpers.load_with_stubs("json")',
			'local E = helpers.load_with_stubs("core.text.engine.json")'
		],
		[
			'local P = rawget(package.loaded, "unicode_case")',
			'local P = rawget(package.loaded, "core.text.engine.unicode_case.core")'
		],
		[
			'helpers.with_fresh_modules({ "json", "unicode_case" }, f)',
			'helpers.with_fresh_modules({ "core.text.engine.json", "core.text.engine.unicode_case.core" }, f)'
		],
		[
			'for _, n in ipairs({ "json", "crypto" }) do package.loaded[n] = nil end',
			'for _, n in ipairs({ "core.text.engine.json", "core.crypto.engine.core" }) do package.loaded[n] = nil end'
		],
		[
			'local U = helpers.load_module("unicode_case")',
			'local U = helpers.load_module("core.text.engine.unicode_case.core")'
		],
		// A load site matched by a Lua pattern inside a string.
		[
			'local _, calls = code:gsub("require%(\\"json\\"%)%.decode%(", "")',
			'local _, calls = code:gsub("require%(\\"core.text.engine.json\\"%)%.decode%(", "")'
		],
		// A local function that hands its parameter to require loads its argument.
		[
			'local function dependency(name)\n\tlocal ok, owner = pcall(require, name)\n\treturn ok and owner\nend\nlocal J = dependency("json")\nlocal label = describe("json")',
			'local function dependency(name)\n\tlocal ok, owner = pcall(require, name)\n\treturn ok and owner\nend\nlocal J = dependency("core.text.engine.json")\nlocal label = describe("json")'
		]
	];
	for (const [before, after] of cases) assert.equal(rewrite(before), after, before);

	// Lua run from a tool: its require sites move, the tool's own requires stay.
	const tool = 'tools/test/test-probe.cjs';
	const js = "const crypto = require('crypto');\nconst lua = `local json=require('json')`;";
	assert.equal(
		Apply.rewriteText(js, Plan.scanFile(tool, js, Plan.referenceContext(MAP)), new Map(), tool),
		"const crypto = require('crypto');\nconst lua = `local json=require('core.text.engine.json')`;"
	);

	const pin = "if (!src.includes('keymap.terminators')) fail('menu.llm.app_profile_overrides');";
	assert.equal(
		Apply.rewriteText(pin, Plan.scanFile(tool, pin, Plan.referenceContext(MAP)), new Map(), tool),
		"if (!src.includes('layouts.engine.terminators')) fail('menu.llm.app_profile_overrides');",
		'a tool pins a source to a dotted module name; a locale key stays'
	);

	// A loop that builds names ('require("modules.' .. name) is a runtime site,
	// not a table of module names.
	const built =
		'for _, name in ipairs({ "json", "crypto" }) do\n\tsrc:find(\'require("modules.\' .. name)\nend';
	assert.equal(rewrite(built), built);

	const registry = "const REGISTRIES = { 'keymap.terminators': { path: KEY.X } };";
	assert.equal(
		Apply.rewriteText(
			registry,
			Plan.scanFile(tool, registry, Plan.referenceContext(MAP)),
			new Map(),
			tool
		),
		registry,
		'a registry key that shares a module spelling in a tool stays'
	);

	// Words that share a module's spelling stay words.
	for (const keep of [
		'local kinds = { "json", "toml" }',
		'if kind == "json" then end',
		'local value = keystats.session_events',
		'Timings.count("logger", "retention_days")'
	])
		assert.equal(rewrite(keep), keep, `not a module name: ${keep}`);
	console.log(
		'[OK] every spelling of a moved Lua module name follows it, and same-spelled words stay.'
	);
}

run();
