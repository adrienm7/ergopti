// tools/test/test-keylogger-timings-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Keylogger Timing Constants Single-Source Guard
 * DESCRIPTION:
 * Three keylogger polling intervals are declared both as AHK class constants and
 * as keys in the shared timing registry (_shared/modules/timings/constants.toml):
 *   keylogger_hook.ahk            CONTEXT_TTL_MS  <-> hook_context_ttl_ms
 *   keylogger_mouse.ahk           PARK_CHECK_MS   <-> mouse_park_check_ms
 *   keylogger_window_topology.ahk TOPO_TICK_MS    <-> topo_tick_ms
 * The registry values had silently drifted from the shipped AHK constants (500 vs
 * 1000, 100 vs 250, 500 vs 1500), so the registry — the documented single source —
 * described timings the driver did not actually use. This gate pins the two copies
 * together so the registry can never again disagree with the constant it maps to.
 *
 * NOTE: the AHK constants are not yet READ from the registry at runtime (TimingsGet
 * has no production consumers, and wiring the keylogger consts needs a live boot to
 * verify load order). Until that lands, this drift gate is the single-source
 * guarantee — duplication is tolerated only because a gate locks it to the source.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static/ergopti_plus');
function read(rel) { return fs.readFileSync(path.join(SP, rel), 'utf8'); }

/** Extracts an integer registry value: `key = 123`. */
function registryInt(src, key) {
	const m = src.match(new RegExp('^' + key + '\\s*=\\s*(\\d+)', 'm'));
	if (!m) throw new Error('registry key not found: ' + key);
	return parseInt(m[1], 10);
}

/** Extracts an AHK class constant: `static NAME := 123`. */
function ahkConst(src, name, file) {
	const m = src.match(new RegExp('static\\s+' + name + '\\s*:=\\s*(\\d+)'));
	if (!m) throw new Error('AHK constant not found: ' + name + ' in ' + file);
	return parseInt(m[1], 10);
}

const errors = [];
try {
	const registry = read('_shared/modules/timings/constants.toml');
	const pairs = [
		{
			label: 'context TTL',
			regKey: 'hook_context_ttl_ms',
			file: 'windows/modules/keylogger/keylogger_hook.ahk',
			constName: 'CONTEXT_TTL_MS',
		},
		{
			label: 'mouse park check',
			regKey: 'mouse_park_check_ms',
			file: 'windows/modules/keylogger/keylogger_mouse.ahk',
			constName: 'PARK_CHECK_MS',
		},
		{
			label: 'window topology tick',
			regKey: 'topo_tick_ms',
			file: 'windows/modules/keylogger/keylogger_window_topology.ahk',
			constName: 'TOPO_TICK_MS',
		},
	];

	for (const p of pairs) {
		const regVal = registryInt(registry, p.regKey);
		const constVal = ahkConst(read(p.file), p.constName, p.file);
		if (regVal !== constVal) {
			errors.push(
				`${p.label}: registry [timings].${p.regKey} = ${regVal} but ` +
				`${p.file} ${p.constName} = ${constVal}. ` +
				`Fix: set ${p.regKey} = ${constVal} in _shared/modules/timings/constants.toml ` +
				`(the AHK constant is the shipped, canonical value).`
			);
		}
	}
} catch (e) {
	errors.push(e.message);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] Keylogger timing constants are not single-sourced:\x1b[0m');
	for (const e of errors) console.error('    ' + e);
	process.exit(1);
}

console.log('\x1b[32m[OK] Keylogger timing constants — CONTEXT_TTL_MS / PARK_CHECK_MS / TOPO_TICK_MS match the shared timing registry.\x1b[0m');
