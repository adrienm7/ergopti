// tools/test/test-lua-undefined-globals.cjs

/**
 * ==============================================================================
 * MODULE: Lua Undefined Global Reads Gate
 * DESCRIPTION:
 * Static gate for reads of globals no production Lua defines. A module that
 * names another module without requiring it reads a nil global, and the first
 * index or call raises at run time: ui/menu/menu_llm/init.lua read TextUtils
 * without its require and crashed the model selector page on the Mac
 * (2026-10-28, fixed by ed95abafa1). A local function called above its
 * declaration is the same read, since the name is still global there.
 *
 * FEATURES & RATIONALE:
 * 1. The Lua 5.4 compiler (luac -p -l) is the parser: every global read is a
 *    GETTABUP of the _ENV upvalue naming a constant, with its source line, so
 *    scoping is exactly the language's and nothing is executed. LuaJIT code of
 *    the Linux driver compiles under it (the gate fails on a file it cannot
 *    parse rather than skipping it).
 * 2. A read is allowed when it names a base global of Lua 5.4 or LuaJIT (the
 *    shared modules run on both, and probe the other runtime's names such as
 *    jit or unpack), a host global of a driver (hs on macOS, arg for a Linux
 *    entry script), or a global that production Lua of the same tree assigns.
 * 3. Self-test: the shapes that shipped (a missing require, a local function
 *    called above its declaration) are flagged; locals, upvalues, base and
 *    host globals, and an assigned global are not.
 * 4. Production: every Lua file of macos/, linux/ and _shared/lua outside the
 *    test folders, every hit listed at once.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const BASE = path.join(ROOT, 'static', 'ergopti_plus');
const TREES = ['macos', 'linux', '_shared/lua'];
// Test folders stub host globals on purpose; only shipped Lua is read.
const TEST_FOLDER = /(^|\/)tests?(\/|$)/;
// luac lists a bounded number of files per call to stay under argv limits.
const FILES_PER_CALL = 80;

// Base library names of Lua 5.4 and of LuaJIT (Lua 5.1 plus its extensions).
const LUA_BASE = [
	'_G',
	'_VERSION',
	'assert',
	'collectgarbage',
	'coroutine',
	'debug',
	'dofile',
	'error',
	'getmetatable',
	'io',
	'ipairs',
	'load',
	'loadfile',
	'math',
	'next',
	'os',
	'package',
	'pairs',
	'pcall',
	'print',
	'rawequal',
	'rawget',
	'rawlen',
	'rawset',
	'require',
	'select',
	'setmetatable',
	'string',
	'table',
	'tonumber',
	'tostring',
	'type',
	'utf8',
	'warn',
	'xpcall'
];
const LUAJIT_BASE = [
	'bit',
	'gcinfo',
	'getfenv',
	'jit',
	'loadstring',
	'module',
	'newproxy',
	'setfenv',
	'unpack'
];
// Globals the hosts provide: Hammerspoon's hs, the standalone interpreter's
// arg for a Linux entry script.
const HOST = ['hs', 'arg'];
const ALLOWED = new Set([...LUA_BASE, ...LUAJIT_BASE, ...HOST]);

let failures = 0;
function check(condition, message) {
	if (condition) return;
	failures++;
	console.error(`FAIL: ${message}`);
}

/** The Lua 5.4 compiler, or a refusal naming what is missing. */
function findLuac() {
	for (const name of ['luac5.4', 'luac']) {
		const probe = spawnSync(name, ['-v'], { encoding: 'utf8' });
		if (!probe.error && /^Lua 5\.4\./.test((probe.stdout || '') + (probe.stderr || '')))
			return name;
	}
	return null;
}

/** Global reads and writes of each file, from the compiler's listing. */
function accesses(luac, files) {
	const result = new Map(files.map((file) => [file, { reads: [], writes: new Set() }]));
	for (let start = 0; start < files.length; start += FILES_PER_CALL) {
		const batch = files.slice(start, start + FILES_PER_CALL);
		const listing = spawnSync(luac, ['-p', '-l', ...batch], {
			encoding: 'utf8',
			maxBuffer: 1024 * 1024 * 1024
		});
		if (listing.error || listing.status !== 0)
			throw new Error(`luac refused a batch: ${listing.stderr || listing.error}`);
		let current = null;
		for (const line of listing.stdout.split('\n')) {
			const header = /^(?:main|function) <(.*):\d+,\d+> \(/.exec(line);
			if (header) {
				current = result.get(header[1]) || null;
				continue;
			}
			if (!current) continue;
			const access = /^\s*\d+\s+\[(\d+)\]\s+(GETTABUP|SETTABUP)\s.*; _ENV "([^"]*)"/.exec(line);
			if (!access) continue;
			if (access[2] === 'GETTABUP')
				current.reads.push({ line: Number(access[1]), name: access[3] });
			else current.writes.add(access[3]);
		}
	}
	return result;
}

/** Every read naming a global that is neither allowed nor assigned in its tree. */
function undefinedReads(luac, files) {
	const found = accesses(luac, files);
	const assigned = new Set();
	for (const { writes } of found.values()) for (const name of writes) assigned.add(name);
	const hits = [];
	for (const [file, { reads }] of found) {
		for (const read of reads) {
			if (ALLOWED.has(read.name) || assigned.has(read.name)) continue;
			hits.push({ file, ...read });
		}
	}
	return hits;
}

function listLua(directory) {
	const out = [];
	for (const entry of fs.readdirSync(directory, { withFileTypes: true })) {
		const full = path.join(directory, entry.name);
		const relative = path.relative(BASE, full).split(path.sep).join('/');
		if (TEST_FOLDER.test(relative)) continue;
		if (entry.isDirectory()) out.push(...listLua(full));
		else if (entry.name.endsWith('.lua')) out.push(full);
	}
	return out.sort();
}

const luac = findLuac();
if (!luac) {
	if (process.platform === 'win32') {
		console.log('[SKIP] No Lua 5.4 compiler (luac5.4 or luac) on this Windows host.');
		process.exit(0);
	}
	console.error('FAIL: the Lua 5.4 compiler (luac5.4 or luac) is required.');
	process.exit(1);
}

// ── 1. Self-test on the shapes that shipped ─────────────────────────────────

const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-lua-globals-'));
try {
	const fixtures = {
		'missing_require.lua': [
			'local M = {}',
			'function M.token_set()',
			'\treturn TextUtils.trim(hs.settings.get("token")) ~= ""',
			'end',
			'return M'
		],
		'forward_local.lua': [
			'local function ms() return math.floor(base_delay() * 1000) end',
			'local function base_delay() return 0.1 end',
			'return { ms = ms, base_delay = base_delay }'
		],
		'clean.lua': [
			'local Text = require("text_utils")',
			'local unpack_ = table.unpack or unpack',
			'local is_jit = jit ~= nil and type(arg) == "table"',
			'local function helper(value) return Text.trim(value) end',
			'Registry = Registry or {}',
			'return { helper = helper, unpack_ = unpack_, is_jit = is_jit, hs = hs, Registry = Registry }'
		]
	};
	const files = Object.entries(fixtures).map(([name, lines]) => {
		const file = path.join(scratch, name);
		fs.writeFileSync(file, lines.join('\n') + '\n');
		return file;
	});
	const seen = undefinedReads(luac, files)
		.map((hit) => `${path.basename(hit.file)}:${hit.line}:${hit.name}`)
		.sort();
	check(
		JSON.stringify(seen) ===
			JSON.stringify(['forward_local.lua:1:base_delay', 'missing_require.lua:3:TextUtils']),
		`self-test flags exactly the missing require and the forward local (saw ${JSON.stringify(seen)})`
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}

// ── 2. Production Lua of every Lua tree ─────────────────────────────────────

const production = TREES.flatMap((tree) => listLua(path.join(BASE, tree)));
check(
	production.length > 1000,
	`expected the whole Lua production set, found ${production.length}`
);
const hits = undefinedReads(luac, production);
for (const hit of hits) {
	const relative = path.relative(BASE, hit.file).split(path.sep).join('/');
	check(
		false,
		`${relative}:${hit.line} reads the undefined global "${hit.name}" (a missing require, a local declared below its use, or a typo)`
	);
}

if (failures) {
	console.error(`\n${failures} undefined global read(s) in production Lua.`);
	process.exit(1);
}
console.log(
	`[OK] Lua undefined global reads: ${production.length} production files, self-test 2 shapes, no hit.`
);
