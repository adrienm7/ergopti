// tools/test/test-priority-parity.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Priority Parity Gate
 * DESCRIPTION:
 * Cross-driver freshness gate locking the hotstring collision-priority SOURCE
 * defaults to a single source of truth: _shared/hotstrings/priority.json. The two
 * drivers necessarily declare the constants in their own language (AHK
 * HSE_PRIORITY_*, Lua PRIORITY_*) because they are read on the hot registration
 * path, but they must never DIVERGE from the shared JSON or from each other.
 *
 * This text-scans both driver sources (no runtime needed, runs in CI on any OS)
 * and fails if either driver's value differs from the shared source — so a future
 * edit that bumps a priority in one place is caught here until all three agree
 * (project rule 5.9: the regression can never silently ship).
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.join(__dirname, '../../static/ergopti_plus');

const PASS = '✓';
const FAIL = '✗';
let pass = 0;
let fail = 0;

const src = JSON.parse(fs.readFileSync(path.join(ROOT, '_shared/hotstrings/priority.json'), 'utf8'));
const expected = { common: src.common, package: src.package, personal: src.personal };

const AHK = fs.readFileSync(path.join(ROOT, 'windows/lib/hotstrings/hotstring_engine_main.ahk'), 'utf8');
const LUA = fs.readFileSync(path.join(ROOT, 'macos/modules/keymap/registry.lua'), 'utf8');

// AHK: `global HSE_PRIORITY_COMMON := 10`. Lua: `local PRIORITY_COMMON = 10`.
function ahkConst(key) {
	const m = AHK.match(new RegExp('HSE_PRIORITY_' + key.toUpperCase() + '\\s*:=\\s*(\\d+)'));
	return m ? Number(m[1]) : null;
}
function luaConst(key) {
	const m = LUA.match(new RegExp('local\\s+PRIORITY_' + key.toUpperCase() + '\\s*=\\s*(\\d+)'));
	return m ? Number(m[1]) : null;
}




// ==================================================
// ==================================================
// ======= 1/ Compare each source default ===========
// ==================================================
// ==================================================

console.log('\nHotstring priority parity (shared source <-> AHK + Lua)');
console.log('='.repeat(54));

for (const key of ['common', 'package', 'personal']) {
	const want = expected[key];
	const ahk = ahkConst(key);
	const lua = luaConst(key);
	if (typeof want === 'number' && ahk === want && lua === want) {
		console.log(`  ${PASS}  ${key}: shared=${want} | AHK=${ahk} | Lua=${lua}`);
		pass++;
	} else {
		console.log(`  ${FAIL}  ${key}: shared=${want} | AHK=${ahk} | Lua=${lua}`);
		console.log('       - all three must equal _shared/hotstrings/priority.json');
		fail++;
	}
}

console.log('');
console.log(`Total: ${pass + fail} check(s) - ${pass} passed, ${fail} failed`);
console.log('');

process.exit(fail > 0 ? 1 : 0);
