// tools/test/test-config-keys-codegen.cjs

/**
 * ==============================================================================
 * MODULE: Config-Key Constants Codegen Guard
 * DESCRIPTION:
 * Pins tools/codegen/codegen-config-keys.cjs to its two sources and to the
 * three committed outputs:
 *
 * 1. Every schema property path and every menu `path` is a KEY, every leaf
 *    segment is a LEAF, every dispatchable menu row id is a COMMAND.
 * 2. Two values that fold to one constant name are refused, not overwritten.
 * 3. The committed Lua, JS and AHK files are byte-identical to a fresh run.
 * 4. The JS table refuses an unknown name (the Lua side is proven by the Linux
 *    unit test test_config_keys.lua, which runs the module itself).
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Codegen = require('../codegen/codegen-config-keys.cjs');
const { loadCjsModule } = require('../lib/load-cjs-module.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

const tables = Codegen.collect();
const values = (name) => new Set(tables[name].map(([, value]) => value));

// ── 1. Coverage of both sources ─────────────────────────────────────────────

const keys = values('KEY');
for (const required of [
	'metrics.private_filter_enabled',
	'hotstrings.dynamic.date_fr.time_activation_seconds',
	'llm.trigger.secure_filter_enabled',
	'metrics'
])
	assert.ok(keys.has(required), `KEY lost ${required}`);
const leaves = values('LEAF');
for (const key of keys) assert.ok(leaves.has(key.split('.').pop()), `LEAF lost the leaf of ${key}`);

const manifest = JSON.parse(fs.readFileSync(path.join(ROOT, Codegen.MENU_MANIFEST), 'utf8'));
const menuPaths = [];
const dispatchable = [];
(function walk(node) {
	if (Array.isArray(node)) return node.forEach(walk);
	if (!node || typeof node !== 'object') return;
	if (typeof node.path === 'string') menuPaths.push(node.path);
	if (typeof node.id === 'string' && ['command', 'check', 'toggle', 'choice'].includes(node.type))
		dispatchable.push(node.id);
	for (const [k, v] of Object.entries(node)) if (!k.startsWith('_')) walk(v);
})(manifest);
assert.ok(dispatchable.length > 100, 'the menu manifest walk found almost no command rows');
for (const p of menuPaths) assert.ok(keys.has(p), `KEY lost the menu path ${p}`);
const commands = values('COMMAND');
for (const id of dispatchable) assert.ok(commands.has(id), `COMMAND lost ${id}`);
assert.ok(commands.has('filter_private') && commands.has('scope_restore'));

// ── 2. Name clashes are refused ─────────────────────────────────────────────

assert.throws(
	() => Codegen.table('KEY', ['a.b_c', 'a_b.c']),
	/both fold to A_B_C/,
	'two keys folding to one name must fail instead of one overwriting the other'
);
assert.throws(() => Codegen.table('KEY', ['Metrics.Enabled']), /not a dotted lower-case/);
assert.deepEqual(Codegen.table('KEY', ['b', 'a', 'b']), [
	['A', 'a'],
	['B', 'b']
]);

// ── 3. No drift, and the generator writes exactly its declared outputs ──────

const privateRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-config-keys-'));
try {
	for (const rel of [Codegen.SCHEMA, Codegen.MENU_MANIFEST]) {
		fs.mkdirSync(path.dirname(path.join(privateRoot, rel)), { recursive: true });
		fs.copyFileSync(path.join(ROOT, rel), path.join(privateRoot, rel));
	}
	Codegen.main(privateRoot);
	for (const rel of [Codegen.LUA_OUTPUT, Codegen.JS_OUTPUT, Codegen.AHK_OUTPUT]) {
		const fresh = fs.readFileSync(path.join(privateRoot, rel), 'utf8');
		const committed = fs.readFileSync(path.join(ROOT, rel), 'utf8');
		assert.ok(!fresh.includes('\r'), `${rel} must be LF`);
		assert.equal(committed, fresh, `${rel} is stale: run npm run codegen:config-keys`);
	}
	assert.ok(
		fs.readFileSync(path.join(privateRoot, Codegen.AHK_OUTPUT), 'utf8').startsWith('﻿; '),
		'the AutoHotkey output keeps its UTF-8 BOM'
	);
	const { GENERATORS } = require('../build/generators.cjs');
	const entry = GENERATORS.find((g) => g.script === 'codegen/codegen-config-keys.cjs');
	assert.ok(entry, 'codegen-config-keys.cjs is not in tools/build/generators.cjs');
	assert.deepEqual(entry.outputs, [Codegen.LUA_OUTPUT, Codegen.JS_OUTPUT, Codegen.AHK_OUTPUT]);
	const menuBuild = GENERATORS.findIndex((g) => g.script === 'build/build-menu-manifest.js');
	assert.ok(
		GENERATORS.indexOf(entry) > menuBuild,
		'the constants are read from menu_manifest.json, so they must be generated after it'
	);
} finally {
	fs.rmSync(privateRoot, { recursive: true, force: true });
}

// ── 4. The JS table is sealed ───────────────────────────────────────────────

const Js = loadCjsModule(path.join(ROOT, Codegen.JS_OUTPUT));
assert.equal(Js.KEY.METRICS_PRIVATE_FILTER_ENABLED, 'metrics.private_filter_enabled');
assert.equal(Js.LEAF.TIME_ACTIVATION_SECONDS, 'time_activation_seconds');
assert.equal(Js.COMMAND.FILTER_PRIVATE, 'filter_private');
assert.throws(() => Js.KEY.METRICS_PRIVATE_FILTER_ENABLD, /has no constant/);
assert.throws(() => {
	'use strict';
	Js.KEY.METRICS_PRIVATE_FILTER_ENABLED = 'x';
}, TypeError);

console.log(
	`[OK] config-key constants: ${tables.KEY.length} key(s), ${tables.LEAF.length} leaf name(s), ` +
		`${tables.COMMAND.length} command id(s), three outputs in sync and sealed.`
);
