// tools/test/test-lua-features-manifest-projection.cjs

/**
 * ==============================================================================
 * MODULE: Shared Lua Features Manifest Loads Each Driver's Own Manifest
 * DESCRIPTION:
 * The macOS and Linux drivers load one shared manifest table
 * (_shared/lua/features/manifest_data.lua) projected at load by
 * _shared/lua/features/manifest.lua, instead of a full generated copy each.
 * This test loads every driver's _generated/features_manifest.lua in a real Lua
 * interpreter and compares the table it returns with the generator's model of
 * that driver (luaDriverManifest, the one the per-driver copies used to print),
 * so the manifest a driver sees stays exactly what it was.
 *
 * FEATURES & RATIONALE:
 * 1. Load and compare: the actual Lua files run, through the actual require
 *    paths; a projection that drops, reorders or invents a row, or resolves a
 *    default or recommendation for the wrong driver, fails.
 * 2. The driver file declares nothing: it is one projection call, so a value
 *    typed into it by hand cannot hide from the comparison above.
 * 3. Fresh tables: editing one loaded manifest must not reach another load.
 * 4. Fail fast: an unknown driver raises.
 * 5. Self-check: the comparison is fed a changed model first, so it cannot
 *    pass because it stopped comparing.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const Generator = require('../build/build-features-manifest.js');

const LUA = process.env.LUA || 'lua';
const DRIVER_ROOTS = { hs: 'macos', linux: 'linux' };

// Canonical JSON from Lua: sorted keys, a sequence as an array, an empty table
// as an empty array (no manifest field is an empty map).
const SERIALIZER = `
local function encode(value)
	local kind = type(value)
	if kind == "string" then return '"' .. value:gsub('[\\\\"]', '\\\\%0') .. '"' end
	if kind == "number" or kind == "boolean" then return tostring(value) end
	if kind ~= "table" then error("cannot encode " .. kind) end
	local count = 0
	for _ in pairs(value) do count = count + 1 end
	if count == #value then
		local parts = {}
		for index = 1, #value do parts[index] = encode(value[index]) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys)
	local parts = {}
	for _, key in ipairs(keys) do parts[#parts + 1] = encode(key) .. ":" .. encode(value[key]) end
	return "{" .. table.concat(parts, ",") .. "}"
end
`;

/**
 * Runs a Lua chunk with a driver's require paths.
 * @param {string} driverRoot Driver directory under static/ergopti_plus.
 * @param {string} body Lua source run after the serializer.
 * @returns {{status: number, stdout: string, stderr: string}}
 */
function runLua(driverRoot, body) {
	const source =
		`package.path = "./?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;" .. package.path\n` +
		SERIALIZER +
		body;
	const result = spawnSync(LUA, ['-'], {
		cwd: path.join(SP, driverRoot),
		input: source,
		encoding: 'utf8',
		timeout: 20000
	});
	if (result.error) throw new Error(`${LUA} could not run: ${result.error.message}`);
	return result;
}

/** A value with every object's keys sorted and every empty table an empty array. */
function canonical(value) {
	if (Array.isArray(value)) return value.map(canonical);
	if (value && typeof value === 'object') {
		const keys = Object.keys(value).sort();
		if (keys.length === 0) return [];
		const out = {};
		for (const key of keys) out[key] = canonical(value[key]);
		return out;
	}
	return value;
}

/** The table a driver's manifest held, from the generator's model of it. */
function expectedManifest(model) {
	const sections = {};
	for (const { path: sectionPath, ...meta } of model.sections) sections[sectionPath] = meta;
	return canonical({ ...model, sections });
}

let checks = 0;

for (const platform of Object.keys(DRIVER_ROOTS)) {
	const driverRoot = DRIVER_ROOTS[platform];
	const file = path.join(SP, driverRoot, '_generated', 'features_manifest.lua');

	// 2. The driver file is one projection call and nothing else.
	const body = fs
		.readFileSync(file, 'utf8')
		.split('\n')
		.filter((line) => line !== '' && !line.startsWith('---'));
	assert.deepEqual(
		body,
		[`return require("features.manifest").for_platform("${platform}")`],
		`${driverRoot}: the driver manifest declares something besides its projection`
	);
	checks += 1;

	// 1. What the real Lua files load is what the generator's model says.
	const loaded = runLua(
		driverRoot,
		'io.write(encode(dofile("_generated/features_manifest.lua")))\n'
	);
	assert.equal(loaded.status, 0, `${driverRoot}: the manifest does not load:\n${loaded.stderr}`);
	const { model } = Generator.luaDriverManifest(platform);
	const expected = expectedManifest(model);
	assert.deepEqual(
		JSON.parse(loaded.stdout),
		expected,
		`${driverRoot}: the loaded manifest differs from the generator's ${platform} model`
	);
	assert.ok(
		expected.features.length > 150 && expected.unavailable.length > 50,
		`${driverRoot}: the compared manifest is too small to prove anything`
	);
	checks += 1;

	// 1b. Row order is part of the manifest: sequences compare element by element
	// above, and the row paths are unique, so one extra check names the first
	// divergence if the order ever changes.
	const paths = JSON.parse(loaded.stdout).features.map((row) => row.path);
	assert.deepEqual(
		paths,
		model.features.map((row) => row.path),
		`${driverRoot}: row order`
	);
	checks += 1;

	// 5. The comparison can fail: a model with one default changed no longer matches.
	const changed = structuredClone(model);
	const flip = changed.features.find((row) => typeof row.default === 'boolean');
	flip.default = !flip.default;
	assert.notDeepEqual(
		JSON.parse(loaded.stdout),
		expectedManifest(changed),
		`${driverRoot}: the comparison ignores a changed default`
	);
	checks += 1;

	// 3. Fresh tables.
	const fresh = runLua(
		driverRoot,
		`local Manifest = require("features.manifest")
		local first = Manifest.for_platform(${JSON.stringify(platform)})
		local path = first.features[1].path
		first.features[1].path = "edited"; first.sections.script.platforms[1] = "edited"
		first.scopes.tap_holds.prefixes[1] = "edited"
		local second = Manifest.for_platform(${JSON.stringify(platform)})
		io.write(tostring(second.features[1].path == path
			and second.sections.script.platforms[1] ~= "edited"
			and second.scopes.tap_holds.prefixes[1] ~= "edited"))`
	);
	assert.equal(
		fresh.stdout,
		'true',
		`${driverRoot}: one load edited the shared data:\n${fresh.stderr}`
	);
	checks += 1;
}

// 4. An unknown driver is refused.
const refused = runLua(
	'macos',
	`local Manifest = require("features.manifest")
	local ok, err = pcall(function() return Manifest.for_platform("ahk") end)
	io.write(tostring(not ok and tostring(err):find("unknown driver ahk", 1, true) ~= nil))`
);
assert.equal(refused.stdout, 'true', `an unknown driver must be refused:\n${refused.stderr}`);
checks += 1;

console.log(
	`[OK] the shared Lua features manifest loads exactly each driver's manifest (${checks} checks).`
);
