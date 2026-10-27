// tools/test/test-keylayout-canonical-parity.cjs

/**
 * ==============================================================================
 * MODULE: Keylayout Canonical Parity
 * DESCRIPTION:
 * The shared Lua parser (_shared/lua/layouts/keylayout.lua) and the Linux
 * converter's Python parser (keylayout_to_xkb.py) must read every shipped
 * .keylayout into the same canonical form, and the converter must produce the
 * same XKB and XCompose files from the Lua parser's form as from the file.
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

	// The converter reads the Lua parser's form and writes what it writes from the file.
	const index = JSON.parse(fs.readFileSync(path.join(REGISTRY, 'index.json'), 'utf8'));
	for (const entry of index.layouts) {
		const label = `conversion of ${entry.id}`;
		try {
			const file = path.join(REGISTRY, entry.file);
			const canonical = path.join(tmp, `${entry.id}.json`);
			// The text the Linux layout manager writes: the shared JSON codec's.
			fs.writeFileSync(canonical, run(lua, [LUA_DUMP, SHARED, file, 'shared-json']));
			const common = [
				'--keycodes',
				KEYCODES,
				'--convention',
				entry.keycode_convention,
				'--layout-id',
				entry.id,
				'--display-name',
				entry.name,
				'--index',
				path.join(REGISTRY, 'index.json')
			];
			const converter = path.join(GENERATION, 'keylayout_to_xkb.py');
			run('python3', [
				'-I',
				converter,
				'--keylayout',
				file,
				'--out',
				path.join(tmp, 'direct', entry.id),
				...common
			]);
			run('python3', [
				'-I',
				converter,
				'--canonical',
				canonical,
				'--out',
				path.join(tmp, 'canonical', entry.id),
				...common
			]);
			for (const name of [`${entry.id}.xkb`, `${entry.id}.XCompose`]) {
				const direct = fs.readFileSync(path.join(tmp, 'direct', entry.id, name), 'utf8');
				const viaLua = fs.readFileSync(path.join(tmp, 'canonical', entry.id, name), 'utf8');
				assert.strictEqual(viaLua, direct, `${name} differs`);
			}
			console.log(`  ok   ${label}`);
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
console.log('\nKeylayout canonical parity: every shipped layout reads the same in Lua and Python.');
