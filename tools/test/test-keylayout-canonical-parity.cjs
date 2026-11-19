// tools/test/test-keylayout-canonical-parity.cjs

/**
 * ==============================================================================
 * MODULE: Keylayout Canonical Parity
 * DESCRIPTION:
 * The shared Lua parser (_shared/layouts/engine/composer/keylayout.lua) and the Linux
 * converter's Python parser (keylayout_to_xkb.py) must read every shipped
 * .keylayout into the same canonical form, and the shared Lua converter
 * (layouts/xkb_converter.lua) must write the same XKB and XCompose files as the
 * Python converter, byte for byte.
 * The Lua suites replay the shared corpus for the fixtures; this gate covers
 * every real layout: the registry, the Ergopti bundles, the Kalamine archive
 * and the composer corpus. Both converters also read the same keys from the
 * shared keycode table (mac_keycodes.json, its JIS and ABNT extra_keys
 * included) for every convention, and write the same files for a layout that
 * types on those keys, which no shipped layout does.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const GENERATION = path.join(ROOT, 'static', 'ergopti', 'linux', 'xkb_generation');
const REGISTRY = path.join(ROOT, 'static', 'layouts', 'registry');
const KEYCODES = path.join(SHARED, 'layouts', 'data', 'mac_keycodes.json');

const LUA_DUMP = path.join(__dirname, 'fixtures', 'keylayout-canonical-dump.lua');
const CONVERT_PROBE = path.join(__dirname, 'fixtures', 'keylayout-xkb-convert.lua');

const PY_DUMP = `
import json, sys
sys.path.insert(0, sys.argv[1])
import keylayout_to_xkb as k
text = open(sys.argv[2], encoding="utf-8").read()
sys.stdout.write(json.dumps(k.parse_keylayout(text).to_canonical(), ensure_ascii=False))
`;

// [xkb, mac, optional] of every key the converter reads, in its order.
const PY_KEYCODES = `
import json, sys
sys.path.insert(0, sys.argv[1])
import keylayout_to_xkb as k
sys.stdout.write(json.dumps([list(key) for key in k.load_keycodes(sys.argv[2], sys.argv[3])]))
`;
const LUA_KEYCODES = `
package.path = arg[1] .. "/?.lua;" .. arg[1] .. "/?/init.lua;" .. package.path
local Json = require("core.text.engine.json")
local Converter = require("layouts.engine.composer.xkb_converter")
local handle = assert(io.open(arg[2], "rb"))
local keycodes = assert(Converter.keycodes(assert(Json.decode(handle:read("*a"))), arg[3]))
handle:close()
local parts = {}
for _, key in ipairs(keycodes) do
	parts[#parts + 1] = string.format("[%q,%d,%s]", key[1], key[2], key[3] == true and "true" or "false")
end
io.write("[" .. table.concat(parts, ",") .. "]")
`;

function run(cmd, args) {
	const result = spawnSync(cmd, args, { encoding: 'utf8', maxBuffer: 64 * 1024 * 1024 });
	assert.strictEqual(result.status, 0, `${cmd} ${args.join(' ')}: ${result.stderr}`);
	return result.stdout;
}

function luaRuntime() {
	for (const name of ['luajit', 'lua5.4', 'lua']) {
		if (spawnSync(name, ['-v'], { encoding: 'utf8' }).status === 0) return name;
	}
	throw new Error('no Lua runtime on PATH');
}

/** Every real .keylayout the repository ships or archives. */
function realLayouts() {
	const found = [];
	const walk = (dir) => {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (entry.name === 'node_modules' || entry.name === 'zipped_bundles') continue;
				walk(full);
			} else if (entry.name.endsWith('.keylayout')) found.push(full);
		}
	};
	walk(REGISTRY);
	walk(path.join(ROOT, 'static', 'ergopti', 'macos', 'bundles'));
	walk(path.join(ROOT, 'static', 'ergopti_plus', 'old', 'kalamine'));
	found.push(path.join(SHARED, 'tests', 'corpus', 'layouts', 'composer', 'composed.keylayout'));
	return found.sort();
}

const lua = luaRuntime();
const python = pythonExecutable();
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'keylayout-canonical-'));
let failures = 0;
const layouts = realLayouts();
assert.ok(layouts.length >= 20, `expected the shipped layouts, found ${layouts.length}`);
const converter = path.join(GENERATION, 'keylayout_to_xkb.py');
const indexPath = path.join(REGISTRY, 'index.json');

/**
 * Converts one .keylayout with both converters and asserts the same outcome and,
 * when both convert it, the same XKB and XCompose bytes.
 * @param {string} file The .keylayout.
 * @param {string} convention Its keycode convention.
 * @param {string|null} registryId The registry entry whose XKB hints apply.
 * @returns {{converted: boolean, xkb: string}} Whether both converted it, and the
 *   XKB symbols they wrote ("" when both refused it).
 */
function convertBoth(file, convention, registryId) {
	const layoutId = path.basename(file, '.keylayout').replace(/[^A-Za-z0-9_]/g, '_');
	const common = [
		'--keycodes',
		KEYCODES,
		'--convention',
		convention,
		'--layout-id',
		layoutId,
		'--display-name',
		'Probe Name'
	];
	if (registryId) common.push('--index', indexPath, '--registry-id', registryId);
	const luaOut = path.join(tmp, 'lua', layoutId);
	const pyOut = path.join(tmp, 'py', layoutId);
	fs.mkdirSync(luaOut, { recursive: true });
	const luaArgs = [
		CONVERT_PROBE,
		SHARED,
		path.join(GENERATION, 'data'),
		file,
		KEYCODES,
		convention,
		layoutId,
		'Probe Name',
		luaOut
	];
	if (registryId) luaArgs.push(indexPath, registryId);
	const fromLua = spawnSync(lua, luaArgs, { encoding: 'utf8' });
	const fromPython = spawnSync(
		python,
		['-I', converter, '--keylayout', file, '--out', pyOut, ...common],
		{ encoding: 'utf8' }
	);
	assert.strictEqual(
		fromLua.status === 0,
		fromPython.status === 0,
		`outcomes differ: lua ${fromLua.status} (${fromLua.stderr.trim()}) python ${fromPython.status} (${fromPython.stderr.trim()})`
	);
	if (fromLua.status !== 0) return { converted: false, xkb: '' };
	for (const name of [`${layoutId}.xkb`, `${layoutId}.XCompose`]) {
		assert.strictEqual(
			fs.readFileSync(path.join(luaOut, name), 'utf8'),
			fs.readFileSync(path.join(pyOut, name), 'utf8'),
			`${name} differs`
		);
	}
	return { converted: true, xkb: fs.readFileSync(path.join(pyOut, `${layoutId}.xkb`), 'utf8') };
}

try {
	for (const file of layouts) {
		const label = path.relative(ROOT, file);
		try {
			const fromLua = JSON.parse(run(lua, [LUA_DUMP, SHARED, file]));
			const fromPython = JSON.parse(
				run(python, ['-I', '-X', 'utf8', '-c', PY_DUMP, GENERATION, file])
			);
			assert.deepStrictEqual(fromLua, fromPython);
			console.log(`  ok   ${label}`);
		} catch (error) {
			failures += 1;
			console.error(`  FAIL ${label}\n       ${String(error.message).split('\n')[0]}`);
		}
	}

	// Both converters read every key of the keycode table, the JIS and ABNT
	// extra_keys included and marked optional, with the same macOS code.
	const table = JSON.parse(fs.readFileSync(KEYCODES, 'utf8'));
	const luaKeycodes = path.join(tmp, 'keycodes.lua');
	fs.writeFileSync(luaKeycodes, LUA_KEYCODES);
	for (const convention of table.conventions) {
		const label = `keycode table, ${convention} convention`;
		try {
			const fromLua = JSON.parse(run(lua, [luaKeycodes, SHARED, KEYCODES, convention]));
			const fromPython = JSON.parse(
				run(python, ['-I', '-c', PY_KEYCODES, GENERATION, KEYCODES, convention])
			);
			assert.deepStrictEqual(fromPython, fromLua);
			assert.strictEqual(
				fromLua.length,
				table.keys.length + table.extra_keys.length,
				'every key and extra key is read'
			);
			for (const extra of table.extra_keys)
				assert.ok(
					fromLua.some(
						([xkb, mac, optional]) => xkb === extra.xkb && mac === extra.mac && optional
					),
					`<${extra.xkb}> (macOS ${extra.mac}) is read as an optional key`
				);
			console.log(`  ok   ${label}`);
		} catch (error) {
			failures += 1;
			console.error(`  FAIL ${label}\n       ${String(error.message).split('\n')[0]}`);
		}
	}

	// The shared Lua converter writes what the Python converter writes, byte for byte,
	// or both refuse the layout. Registry layouts use their own convention and XKB
	// hints; the Ergopti bundles use Ergopti's (ISO, the "ergopti" entry's hints); the
	// archive and the composer corpus use ISO without hints.
	const index = JSON.parse(fs.readFileSync(indexPath, 'utf8'));
	const byFile = new Map(index.layouts.map((entry) => [path.join(REGISTRY, entry.file), entry]));
	for (const file of layouts) {
		const label = `conversion of ${path.relative(ROOT, file)}`;
		try {
			const entry = byFile.get(file);
			const registryId = entry
				? entry.id
				: file.includes(`${path.sep}bundles${path.sep}`)
					? 'ergopti'
					: null;
			const convention = entry ? entry.keycode_convention : 'iso';
			const { converted } = convertBoth(file, convention, registryId);
			console.log(`  ok   ${label}${converted ? '' : ' (refused by both)'}`);
		} catch (error) {
			failures += 1;
			console.error(`  FAIL ${label}\n       ${String(error.message).split('\n')[0]}`);
		}
	}

	// No shipped layout types on the JIS and ABNT keys: Ergo-L with Yen (93), Ro
	// (94) and the keypad comma (95) added must reach <AE13>, <AB11> and <KPPT>
	// the same way in both converters.
	const label = 'conversion of Ergo-L with the JIS and ABNT keys';
	try {
		const ergol = index.layouts.find((entry) => entry.id === 'ergol');
		const text = fs.readFileSync(path.join(REGISTRY, ergol.file), 'utf8');
		const open = '<keyMap index="0">';
		assert.ok(text.includes(open), 'Ergo-L has a first keyMap');
		const probe = path.join(tmp, 'ergol_jis_abnt.keylayout');
		fs.writeFileSync(
			probe,
			text.replace(
				open,
				`${open}<key code="93" output="&#x00A5;"/><key code="94" output="_"/><key code="95" output=","/>`
			)
		);
		const { converted, xkb } = convertBoth(probe, ergol.keycode_convention, 'ergol');
		assert.ok(converted, 'both converters convert it');
		for (const name of ['AE13', 'AB11', 'KPPT'])
			assert.ok(xkb.includes(`key <${name}> {`), `<${name}> is written`);
		console.log(`  ok   ${label}`);
	} catch (error) {
		failures += 1;
		console.error(`  FAIL ${label}\n       ${String(error.message).split('\n')[0]}`);
	}
} finally {
	fs.rmSync(tmp, { recursive: true, force: true });
}

if (failures > 0) {
	console.error(`\n${failures} check(s) failed.`);
	process.exit(1);
}
console.log(
	'\nKeylayout canonical parity: every shipped layout reads and converts the same in Lua and Python.'
);
