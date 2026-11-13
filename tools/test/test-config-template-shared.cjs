// tools/test/test-config-template-shared.cjs

/**
 * ==============================================================================
 * MODULE: One Shared Config Template Projects To Each Driver's Template
 * DESCRIPTION:
 * The default config of the three drivers is generated once, in
 * _shared/_generated/config_template.toml; each driver's
 * _generated/config_template.toml is its projection (the Linux packages copy
 * it to /etc/ergopti/config.toml, every macOS .app carries it, the Windows
 * startup smoke test seeds its neutral run with it). This test proves the
 * projection changes no driver's defaults.
 *
 * FEATURES & RATIONALE:
 * 1. Bytes: the projection of the shared file is byte for byte the committed
 *    driver template, which packaging hands to users unchanged.
 * 2. No lossy merge: the projection is also byte for byte the template rendered
 *    for that driver straight from the manifest, the path every driver template
 *    took before the shared file existed.
 * 3. Decoded values: smol-toml and the drivers' own Lua codec
 *    (_shared/core/text/engine/toml_codec) decode the shared file, project it with the
 *    dotted platform.<driver> keys, and find exactly the values of the driver
 *    template, table by table.
 * 4. Written once: a key every driver of a table shares with one value is a
 *    plain line, never repeated per driver.
 * 5. Fail fast: an unlisted table, an unknown driver or a repeated table throws.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { parse: parseToml } = require('smol-toml');
const paths = require('../lib/paths.cjs');
const Projection = require('../lib/config-template-projection.cjs');
const Generator = require('../build/build-features-manifest.js');

const LUA = process.env.LUA || 'lua';
const DRIVER_DIRS = { ahk: 'windows', hs: 'macos', linux: 'linux' };
const SHARED_FILE = paths.shared('_generated', 'config_template.toml');
const shared = fs.readFileSync(SHARED_FILE, 'utf8');

/** @returns {boolean} Whether a decoded value is a key's value, not a sub-table. */
function isLeaf(value) {
	return Array.isArray(value) || value === null || typeof value !== 'object';
}

/** Every table of a decoded document with its leaf keys, by dotted header. */
function leafTables(node, prefix = '', out = {}) {
	const leaves = {};
	for (const [key, value] of Object.entries(node)) {
		if (isLeaf(value)) leaves[key] = value;
		else leafTables(value, prefix === '' ? key : `${prefix}.${key}`, out);
	}
	if (prefix !== '' && Object.keys(leaves).length > 0) out[prefix] = leaves;
	return out;
}

/** One driver's tables from the decoded shared document. */
function decodedView(document, platform) {
	const out = {};
	for (const header of document.platform[platform].sections) {
		const node = header.split('.').reduce((table, segment) => table[segment], document);
		const leaves = {};
		for (const [key, value] of Object.entries(node)) if (isLeaf(value)) leaves[key] = value;
		Object.assign(leaves, node.platform?.[platform] ?? {});
		if (Object.keys(leaves).length > 0) out[header] = leaves;
	}
	return out;
}

let checks = 0;
const document = parseToml(shared);
const direct = Generator.directDriverConfigTemplates();

for (const [platform, driverDir] of Object.entries(DRIVER_DIRS)) {
	const file = paths.shared('..', driverDir, '_generated', 'config_template.toml');
	const committed = fs.readFileSync(file);
	const projected = Projection.projectDriverTemplate(shared, platform);

	// 1. The bytes packaging copies to users.
	assert.ok(
		Buffer.from(projected, 'utf8').equals(committed),
		`${driverDir}: the shared template does not project to the committed template; run npm run build:manifest`
	);
	// 2. The template rendered for this driver straight from the manifest.
	assert.equal(
		projected,
		direct[platform],
		`${driverDir}: the shared template lost or moved a row`
	);

	// 3. The decoded values, table by table.
	const expected = leafTables(parseToml(committed.toString('utf8')));
	assert.ok(Object.keys(expected).length > 30, `${driverDir}: too few tables to prove anything`);
	assert.deepEqual(
		decodedView(document, platform),
		expected,
		`${driverDir}: decoded defaults differ`
	);
	checks += 3;
}

// 3. The drivers' own Lua codec reads the shape and projects the same views.
const LUA_VIEW = `
package.path = "../_shared/?.lua;../_shared/?/init.lua;" .. package.path
local Codec = require("core.text.engine.toml_codec")
local function read(file)
	local handle = assert(io.open(file, "rb"))
	local text = handle:read("*a")
	handle:close()
	return text
end
local function is_leaf(value)
	if type(value) ~= "table" then return true end
	local count = 0
	for _ in pairs(value) do count = count + 1 end
	return count == #value
end
local function encode(value)
	local kind = type(value)
	if kind == "string" then return '"' .. value:gsub('[\\\\"]', '\\\\%0') .. '"' end
	if kind == "boolean" then return tostring(value) end
	if kind == "number" then
		if math.type and math.type(value) == "integer" then return tostring(value) end
		if value == math.floor(value) then return string.format("%d", value) end
		return string.format("%.17g", value)
	end
	local parts = {}
	if is_leaf(value) then
		for index = 1, #value do parts[index] = encode(value[index]) end
		return "[" .. table.concat(parts, ",") .. "]"
	end
	local keys = {}
	for key in pairs(value) do keys[#keys + 1] = key end
	table.sort(keys)
	for _, key in ipairs(keys) do parts[#parts + 1] = encode(key) .. ":" .. encode(value[key]) end
	return "{" .. table.concat(parts, ",") .. "}"
end
local platform, driver_file = ...
local document = assert(Codec.decode(read("_generated/config_template.toml")))
local view = {}
for _, header in ipairs(document.platform[platform].sections) do
	local node = document
	for segment in header:gmatch("[^.]+") do node = node[segment] end
	local leaves, any = {}, false
	for key, value in pairs(node) do
		if is_leaf(value) then leaves[key], any = value, true end
	end
	for key, value in pairs((node.platform or {})[platform] or {}) do leaves[key], any = value, true end
	if any then view[header] = leaves end
end
local expected = {}
local function walk(node, prefix)
	local leaves, any = {}, false
	for key, value in pairs(node) do
		if is_leaf(value) then leaves[key], any = value, true
		else walk(value, prefix == "" and key or prefix .. "." .. key) end
	end
	if prefix ~= "" and any then expected[prefix] = leaves end
end
walk(assert(Codec.decode(read(driver_file))), "")
io.write(encode(view), "\\n", encode(expected), "\\n")
`;

for (const [platform, driverDir] of Object.entries(DRIVER_DIRS)) {
	const result = spawnSync(
		LUA,
		['-', platform, `../${driverDir}/_generated/config_template.toml`],
		{
			cwd: path.dirname(path.dirname(SHARED_FILE)),
			input: LUA_VIEW,
			encoding: 'utf8',
			timeout: 20000
		}
	);
	if (result.error) throw new Error(`${LUA} could not run: ${result.error.message}`);
	assert.equal(
		result.status,
		0,
		`${driverDir}: the Lua codec does not read the shared template:\n${result.stderr}`
	);
	const [view, expected] = result.stdout.trimEnd().split('\n');
	assert.ok(
		expected.length > 2000,
		`${driverDir}: the Lua codec decoded too little to prove anything`
	);
	assert.equal(view, expected, `${driverDir}: the Lua codec projects other defaults`);
	checks += 1;
}

// 4. A key every driver of its table shares with one value is written once.
const listing = Object.fromEntries(
	Projection.DRIVERS.map((platform) => [platform, new Set(document.platform[platform].sections)])
);
let plainRows = 0;
for (const [header, rows] of Projection.parseSharedTemplate(shared).tables) {
	const drivers = Projection.DRIVERS.filter((platform) => listing[platform].has(header));
	const scoped = new Map();
	for (const row of rows) {
		if (row.driver === null) plainRows += 1;
		else scoped.set(row.key, { ...(scoped.get(row.key) ?? {}), [row.driver]: row.literal });
	}
	for (const [key, literals] of scoped) {
		const values = drivers.map((platform) => literals[platform]);
		assert.ok(
			!values.every((value) => value !== undefined && value === values[0]),
			`[${header}] ${key} is written per driver although every driver shares ${values[0]}`
		);
	}
}
assert.equal((shared.match(/^trigger_char = /gm) ?? []).length, 1, 'a shared key is written once');
assert.ok(plainRows > 150, `only ${plainRows} shared rows: the template is not collapsed`);
checks += 2;

// 5. Fail fast on a shape the projection cannot honour.
const unlisted = shared.replace(/\t"script",\n/g, '');
assert.throws(() => Projection.projectDriverTemplate(unlisted, 'hs'), /no driver lists \[script\]/);
assert.throws(() => Projection.projectDriverTemplate(shared, 'web'), /unknown driver web/);
assert.throws(
	() =>
		Projection.projectDriverTemplate(
			shared.replace('platform.ahk.alt_gr_is_kana_remap', 'platform.web.alt_gr_is_kana_remap'),
			'ahk'
		),
	/unknown driver web/
);
assert.throws(
	() => Projection.projectDriverTemplate(`${shared}\n[script]\nlocale = "en"\n`, 'linux'),
	/\[script\] appears twice/
);
checks += 4;

console.log(`config template shared projection: ${checks} checks ok`);
