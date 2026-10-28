// tools/test/test-keylayout-canonical-parity.cjs

/**
 * ==============================================================================
 * MODULE: Keylayout Canonical Parity
 * DESCRIPTION:
 * The shared Lua parser (_shared/lua/layouts/keylayout.lua) and the Linux
 * converter's Python parser (keylayout_to_xkb.py) must read every shipped
 * .keylayout into the same canonical form, and the shared Lua converter
 * (layouts/xkb_converter.lua) must write the same XKB and XCompose files as the
 * Python converter, byte for byte.
 * The Lua suites replay the shared corpus for the fixtures; this gate covers
 * every real layout: the registry, the Ergopti bundles, the Kalamine archive
 * and the composer corpus.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const SHARED = path.join(ROOT, 'static', 'ergopti_plus', '_shared');
const GENERATION = path.join(ROOT, 'static', 'ergopti', 'linux', 'xkb_generation');
const REGISTRY = path.join(ROOT, 'static', 'layouts', 'registry');
const KEYCODES = path.join(SHARED, 'modules', 'layouts', 'mac_keycodes.json');

const LUA_DUMP = path.join(__dirname, 'fixtures', 'keylayout-canonical-dump.lua');
const CONVERT_PROBE = path.join(__dirname, 'fixtures', 'keylayout-xkb-convert.lua');

const PY_DUMP = `
import json, sys
sys.path.insert(0, sys.argv[1])
import keylayout_to_xkb as k
text = open(sys.argv[2], encoding="utf-8").read()
sys.stdout.write(json.dumps(k.parse_keylayout(text).to_canonical(), ensure_ascii=False))
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
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'keylayout-canonical-'));
let failures = 0;
const layouts = realLayouts();
assert.ok(layouts.length >= 20, `expected the shipped layouts, found ${layouts.length}`);

try {
	for (const file of layouts) {
		const label = path.relative(ROOT, file);
		try {
			const fromLua = JSON.parse(run(lua, [LUA_DUMP, SHARED, file]));
			const fromPython = JSON.parse(run('python3', ['-I', '-c', PY_DUMP, GENERATION, file]));
			assert.deepStrictEqual(fromLua, fromPython);
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
	const index = JSON.parse(fs.readFileSync(path.join(REGISTRY, 'index.json'), 'utf8'));
	const byFile = new Map(index.layouts.map((entry) => [path.join(REGISTRY, entry.file), entry]));
	const converter = path.join(GENERATION, 'keylayout_to_xkb.py');
	const indexPath = path.join(REGISTRY, 'index.json');
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
				'python3',
				['-I', converter, '--keylayout', file, '--out', pyOut, ...common],
				{ encoding: 'utf8' }
			);
			assert.strictEqual(
				fromLua.status === 0,
				fromPython.status === 0,
				`outcomes differ: lua ${fromLua.status} (${fromLua.stderr.trim()}) python ${fromPython.status} (${fromPython.stderr.trim()})`
			);
			if (fromLua.status === 0) {
				for (const name of [`${layoutId}.xkb`, `${layoutId}.XCompose`]) {
					assert.strictEqual(
						fs.readFileSync(path.join(luaOut, name), 'utf8'),
						fs.readFileSync(path.join(pyOut, name), 'utf8'),
						`${name} differs`
					);
				}
			}
			console.log(`  ok   ${label}${fromLua.status === 0 ? '' : ' (refused by both)'}`);
		} catch (error) {
			failures += 1;
			console.error(`  FAIL ${label}\n       ${String(error.message).split('\n')[0]}`);
		}
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
