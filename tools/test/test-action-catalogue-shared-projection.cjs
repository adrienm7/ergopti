// tools/test/test-action-catalogue-shared-projection.cjs

/**
 * ==============================================================================
 * MODULE: Shared Lua Action Catalogue Loads Each Driver's Own Catalogue
 * DESCRIPTION:
 * The macOS and Linux drivers load one shared catalogue
 * (_shared/lua/actions/catalogue_data.lua) filtered at load by
 * _shared/lua/actions/catalogue.lua, instead of a full generated copy each.
 * This test loads every driver's _generated/action_catalogue.lua in a real Lua
 * interpreter and compares the table it returns with the generator's model of
 * that driver (buildModel, the one the per-driver copies used to print), so
 * the data a driver sees stays exactly what it was.
 *
 * FEATURES & RATIONALE:
 * 1. Load and compare: the actual Lua files run, through the actual require
 *    paths; a projection that drops, reorders or invents an entry fails.
 * 2. Fresh tables: editing one loaded catalogue must not reach another load.
 * 3. Fail fast: an unknown driver or an extra replacing a shared field raises.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const Generator = require('../codegen/codegen-action-catalogue.cjs');

const LUA = process.env.LUA || 'lua';
const DRIVER_ROOTS = { hs: 'macos', linux: 'linux' };

// Canonical JSON from Lua: sorted keys, a sequence as an array, an empty table
// as an empty array (no catalogue field is an empty map).
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
 * Runs a Lua chunk with a driver's require paths and returns its stdout.
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

/** A value with every object's keys sorted, as the Lua serializer writes them. */
function canonical(value) {
	if (Array.isArray(value)) return value.map(canonical);
	if (value && typeof value === 'object') {
		const out = {};
		for (const key of Object.keys(value).sort()) out[key] = canonical(value[key]);
		return out;
	}
	return value;
}

/** The table a driver's catalogue held, from the generator's model of it. */
function expectedCatalogue(model) {
	const catalogue = {
		platform: model.platform,
		sg_items: model.sgItems.map((item) =>
			item.kind === 'action'
				? { kind: 'action', id: item.id }
				: item.kind === 'heading'
					? { kind: 'heading', level: item.level, key: item.key }
					: { kind: 'modifier_chords', level: item.level, group_key: item.groupKey }
		),
		ax_items: [...model.axItems],
		actions: {}
	};
	for (const [id, action] of Object.entries(model.actions)) {
		const entry = { family: action.family, label_key: action.labelKey };
		if (action.parameter) entry.parameter = action.parameter;
		if (action.confirm) entry.confirm = true;
		if (action.requires) entry.requires = [...action.requires];
		catalogue.actions[id] = entry;
	}
	if (model.karabinerAliases) catalogue.karabiner_aliases = { ...model.karabinerAliases };
	if (model.slots)
		catalogue.slots = { single: [...model.slots.single], axis: [...model.slots.axis] };
	return canonical(catalogue);
}

const registry = Generator.parseRegistry(
	fs.readFileSync(path.join(SP, '_shared', 'modules', 'actions', 'actions.toml'), 'utf8')
);
let checks = 0;

for (const platform of Generator.LUA_PLATFORMS) {
	const driverRoot = DRIVER_ROOTS[platform];
	const loaded = runLua(
		driverRoot,
		'io.write(encode(dofile("_generated/action_catalogue.lua")))\n'
	);
	assert.equal(loaded.status, 0, `${driverRoot}: the catalogue does not load:\n${loaded.stderr}`);
	const expected = expectedCatalogue(Generator.buildModel(registry, platform));
	assert.deepEqual(
		JSON.parse(loaded.stdout),
		expected,
		`${driverRoot}: the loaded catalogue differs from the generator's ${platform} model`
	);
	assert.ok(
		expected.sg_items.length > 150 && Object.keys(expected.actions).length > 100,
		`${driverRoot}: the compared catalogue is too small to prove anything`
	);
	checks += 1;

	const fresh = runLua(
		driverRoot,
		`local Catalogue = require("actions.catalogue")
		local first = Catalogue.for_platform(${JSON.stringify(platform)})
		first.sg_items[1].id = "edited"; first.actions.none = nil
		local second = Catalogue.for_platform(${JSON.stringify(platform)})
		io.write(tostring(second.sg_items[1].id == "none" and second.actions.none ~= nil))`
	);
	assert.equal(fresh.stdout, 'true', `${driverRoot}: one load edited the shared data`);
	checks += 1;
}

for (const [label, call, message] of [
	['an unknown driver', 'Catalogue.for_platform("ahk")', 'unknown driver ahk'],
	[
		'an extra replacing a shared field',
		'Catalogue.for_platform("hs", { actions = {} })',
		'may not replace actions'
	]
]) {
	const refused = runLua(
		'macos',
		`local Catalogue = require("actions.catalogue")
		local ok, err = pcall(function() return ${call} end)
		io.write(tostring(not ok and tostring(err):find(${JSON.stringify(message)}, 1, true) ~= nil))`
	);
	assert.equal(refused.stdout, 'true', `${label} must be refused:\n${refused.stderr}`);
	checks += 1;
}

console.log(
	`[OK] the shared Lua action catalogue loads exactly each driver's catalogue (${checks} checks).`
);
