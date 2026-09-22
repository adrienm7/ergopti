// tools/test/test-diagnostic-snapshot-parity.cjs

/**
 * ==============================================================================
 * MODULE: Diagnostic Snapshot Cross-Driver Parity Guard
 * DESCRIPTION:
 * Every driver logs one boot "Diagnostic snapshot (...)" line whose field names,
 * order and rendering rules come from
 * _shared/modules/logger/diagnostic_snapshot.json. Each driver suite replays the
 * shared vectors through its own formatter; this guard pins what those suites
 * cannot see from inside one driver:
 *
 * 1. The contract itself is coherent: unique fields, and every vector renders
 *    under the documented rules (a reference formatter replays them here).
 * 2. The AutoHotkey and Lua field lists are the contract, in order.
 * 3. Every driver's collector assigns every field, so no column silently falls
 *    back to "unknown" because a collector forgot it.
 * 4. Every driver emits the snapshot from its post-boot site.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVERS = path.join(ROOT, 'static/ergopti_plus');

function read(rel) {
	return fs.readFileSync(path.join(DRIVERS, rel), 'utf8').replace(/^﻿/, '');
}

const errors = [];
const contract = JSON.parse(read('_shared/modules/logger/diagnostic_snapshot.json'));
const fields = contract.fields;

// 1. Contract coherence ------------------------------------------------------
if (!Array.isArray(fields) || fields.length < 10) {
	errors.push(`the contract must list its fields (found ${fields && fields.length})`);
}
if (new Set(fields).size !== fields.length) errors.push('the contract lists a field twice');

function renderValue(value) {
	if (value === undefined || value === null) return contract.unknown;
	let text = String(value).replace(/[\r\n\t]/g, ' ').replace(/"/g, "'");
	if (text === '') return contract.unknown;
	if (text.includes(' ')) text = `"${text}"`;
	return text;
}
function format(values) {
	return `Diagnostic snapshot (${fields.map((name) => `${name}=${renderValue(values[name])}`).join(' ')}).`;
}
if (!Array.isArray(contract.vectors) || contract.vectors.length < 3) {
	errors.push('the contract must carry at least three vectors');
}
for (const vector of contract.vectors || []) {
	const rendered = format(vector.values);
	if (rendered !== vector.expected) {
		errors.push(`vector ${vector.id} does not follow the documented rules:\n  expected ${vector.expected}\n  rendered ${rendered}`);
	}
}

// 2. Driver field lists --------------------------------------------------------
function compareList(label, list) {
	if (JSON.stringify(list) !== JSON.stringify(fields)) {
		errors.push(`${label} field list drifted from the contract:\n  contract ${fields.join(',')}\n  ${label} ${list.join(',')}`);
	}
}
const luaSnapshot = read('_shared/lua/diagnostics/snapshot.lua');
const luaBlock = luaSnapshot.match(/M\.FIELDS\s*=\s*\{([\s\S]*?)\}/);
if (!luaBlock) errors.push('_shared/lua/diagnostics/snapshot.lua no longer declares M.FIELDS');
else compareList('Lua', [...luaBlock[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]));
if (!luaSnapshot.includes(`M.MODULE = "${contract.module}"`)) errors.push('the Lua log tag drifted from the contract');

const ahkSnapshot = read('windows/infra/diagnostic_snapshot.ahk');
const ahkBlock = ahkSnapshot.match(/static Fields := \[([\s\S]*?)\]/);
if (!ahkBlock) errors.push('windows/infra/diagnostic_snapshot.ahk no longer declares its field list');
else compareList('AutoHotkey', [...ahkBlock[1].matchAll(/"([a-z_]+)"/g)].map((m) => m[1]));
if (!ahkSnapshot.includes(`return "${contract.module}"`)) errors.push('the AutoHotkey log tag drifted from the contract');

// 3. Every collector assigns every field ---------------------------------------
const collectors = {
	'linux/infra/diagnostic_snapshot.lua': (name) => new RegExp(`\\b${name}\\s*=`),
	'macos/infra/diagnostic_snapshot.lua': (name) => new RegExp(`\\b${name}\\s*=`),
	'windows/infra/diagnostic_snapshot.ahk': (name) => new RegExp(`(Values\\["${name}"\\]\\s*:=|"${name}",)`),
};
// Only the collecting function is searched: the field list itself names every
// field, and a scan of the whole file would pass without a single assignment.
const collectorBodies = {
	'linux/infra/diagnostic_snapshot.lua': /function M\.collect\([\s\S]*?\nend\n/,
	'macos/infra/diagnostic_snapshot.lua': /function M\.collect\([\s\S]*?\nend\n/,
	'windows/infra/diagnostic_snapshot.ahk': /DiagSnapshot_Collect\(BootMs\) \{[\s\S]*?\n\}\n/,
};
for (const [rel, pattern] of Object.entries(collectors)) {
	const body = read(rel).match(collectorBodies[rel]);
	if (!body) {
		errors.push(`${rel}: the collecting function was not found — this scan would check nothing`);
		continue;
	}
	const src = body[0];
	for (const name of fields) {
		if (!pattern(name).test(src)) errors.push(`${rel} never assigns the '${name}' field`);
	}
}

// 4. Every driver emits it after boot ------------------------------------------
const entry = read('windows/ErgoptiPlus.ahk');
const winReady = entry.indexOf('"Driver fully initialised — ready."');
const winEmit = entry.indexOf('DiagSnapshot_Emit(');
if (winReady < 0 || winEmit < 0 || winEmit < winReady) errors.push('Windows must emit the snapshot after its ready line');
const daemon = read('linux/ergopti_hotstrings.lua');
const linuxReady = daemon.indexOf('"Daemon ready (');
const linuxEmit = daemon.indexOf('\temit_diagnostic_snapshot(boot_ms, opts,');
if (linuxReady < 0 || linuxEmit < 0 || linuxEmit < linuxReady) errors.push('Linux must emit the snapshot after its ready line');
const menu = read('macos/ui/menu/init.lua');
if (!menu.includes('DiagnosticSnapshot.emit_once(')) errors.push('macOS must emit the snapshot from the post-boot menu prime');

if (errors.length) {
	console.error(`diagnostic snapshot parity: ${errors.length} problem(s)`);
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log(`diagnostic snapshot parity: OK (${fields.length} fields, ${contract.vectors.length} vectors, 3 drivers)`);
