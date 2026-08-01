// tools/test/test-priority-parity.cjs

/**
 * ==============================================================================
 * MODULE: Hotstring Priority Parity Gate
 * DESCRIPTION:
 * Cross-driver freshness gate locking the hotstring collision-priority SOURCE
 * defaults to a single source of truth: _shared/modules/hotstrings/priority.json. The two
 * drivers necessarily declare the constants in their own language (AHK
 * HSE_PRIORITY_*, Lua PRIORITY_*) because they are read on the hot registration
 * path, but they must never DIVERGE from the shared JSON or from each other.
 *
 * This text-scans both driver sources (no runtime needed, runs in CI on any OS)
 * and fails if either driver's value differs from the shared source — so a future
 * edit that bumps a priority in one place is caught here until all three agree
 * (project rule 5.9: the regression can never silently ship).
 *
 * IT READ THREE DECLARATIONS, AND NOTHING ELSE:
 * Comparing the three constant declarations proves the constants agree. It does
 * not prove they are what the code uses. A fallback written as a bare `or 10`
 * instead of `or PRIORITY_COMMON` reads identically today, diverges the moment
 * the JSON changes, and was completely invisible to this gate. So was Linux —
 * not because Linux diverges, but because nothing asserted that it has no copy
 * at all, which is the only reason it cannot diverge.
 *
 * Three checks are added: no bare priority literal at a use site in any driver,
 * no divergent PRIORITY_* constant in Linux, and both resolvers testing the
 * cascade levels (individual > section > file > source) in that documented order.
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

const src = JSON.parse(fs.readFileSync(path.join(ROOT, '_shared/modules/hotstrings/priority.json'), 'utf8'));
const expected = { common: src.common, package: src.package, personal: src.personal };

const AHK = fs.readFileSync(path.join(ROOT, 'windows/infra/hotstrings/hotstring_engine_main.ahk'), 'utf8');
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
		console.log('       - all three must equal _shared/modules/hotstrings/priority.json');
		fail++;
	}
}





// ==================================================
// ==================================================
// ======= 2/ No bare literal at a use site =========
// ==================================================
// ==================================================

// The constants exist so that no other line has to know the number. A use site
// that spells the number instead reads correctly today and diverges silently on
// the next JSON edit — the exact failure this file exists to prevent, one level
// below where it was looking.
const VALUES = new Set(Object.values(expected));

/**
 * Every production Lua/AHK file under a driver.
 * @param {string} dir Absolute directory.
 * @param {string[]} acc Accumulator.
 * @returns {string[]} Absolute paths.
 */
function walk(dir, acc = []) {
	if (!fs.existsSync(dir)) return acc;
	for (const e of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, e.name);
		if (e.isDirectory()) {
			if (e.name !== 'tests') walk(full, acc);
		} else if (/\.(lua|ahk)$/.test(e.name)) {
			acc.push(full);
		}
	}
	return acc;
}

const DRIVER_DIRS = ['windows', 'macos', 'linux'].map((d) => path.join(ROOT, d));
const driverFiles = DRIVER_DIRS.flatMap((d) => walk(d));
if (driverFiles.length < 300) {
	console.log(`  ${FAIL}  walk found only ${driverFiles.length} driver source file(s) — the scan is broken`);
	fail++;
}

// A priority token assigned/compared to a literal: `Priority : 50`,
// `priority = 10`, `priority or 30`. Requiring the relationship — rather than
// just co-occurrence on a line — keeps GUI layout numbers out
// (`t("hs_config.label_priority")` next to a `w70 h20` option string).
// Comments are skipped: the cascade is documented in prose that cites the
// values, and prose cannot diverge from anything.
const PRIORITY_LITERAL_RE = /priority\w*["'\s)\]]*\s*(?::=|==|=|:|\bor\b|\?\?)\s*(\d+)/i;

// The one literal that cannot be a constant: an AHK v2 default-parameter
// expression cannot reference a global. It is pinned rather than ignored — the
// value must still equal the shared source default.
const PINNED = [
	{
		file: 'windows/infra/hotstrings/hotstring_builder.ahk',
		symbol: '_MakeHotstringMeta',
		want: () => expected.common,
		why: 'AHK v2 default-parameter expressions cannot reference a global'
	}
];

const bareLiterals = [];
for (const abs of driverFiles) {
	const rel = path.relative(ROOT, abs).replace(/\\/g, '/');
	const pin = PINNED.find((p2) => rel === p2.file);
	fs.readFileSync(abs, 'utf8')
		.split(/\r?\n/)
		.forEach((line, i) => {
			const t = line.trim();
			if (t.startsWith(';') || t.startsWith('--') || t.startsWith('#')) return;
			if (/PRIORITY_(COMMON|PACKAGE|PERSONAL)/.test(t)) return; // uses the constant
			const m = t.match(PRIORITY_LITERAL_RE);
			if (!m) return;
			const value = Number(m[1]);
			if (!VALUES.has(value)) return;
			if (pin && t.includes(pin.symbol)) {
				if (value !== pin.want()) {
					bareLiterals.push(
						`${rel}:${i + 1}: pinned default is ${value}, shared source default is ${pin.want()} — they must agree`
					);
				}
				return;
			}
			bareLiterals.push(`${rel}:${i + 1}: ${t.slice(0, 100)}`);
		});
}

if (bareLiterals.length === 0) {
	console.log(`  ${PASS}  no bare priority literal at any use site (${driverFiles.length} driver file(s) scanned)`);
	pass++;
} else {
	console.log(`  ${FAIL}  ${bareLiterals.length} bare priority literal(s) at a use site — use the named constant:`);
	for (const b of bareLiterals) console.log('       - ' + b);
	fail++;
}



// ==================================================
// ==================================================
// ======= 3/ Linux carries no divergent copy =======
// ==================================================
// ==================================================

// Linux does not implement hotstring collision priority. That is why it cannot
// diverge — but "cannot diverge" was an assumption, not a check. The day it
// grows a constant, this fails and the gate above must be extended to it.
const linuxConsts = [];
for (const abs of walk(path.join(ROOT, 'linux'))) {
	const src = fs.readFileSync(abs, 'utf8');
	for (const m of src.matchAll(/PRIORITY_(COMMON|PACKAGE|PERSONAL)\s*=\s*(\d+)/g)) {
		const key = m[1].toLowerCase();
		if (Number(m[2]) !== expected[key]) {
			linuxConsts.push(`${path.relative(ROOT, abs).replace(/\\/g, '/')}: PRIORITY_${m[1]}=${m[2]} != shared ${expected[key]}`);
		}
	}
}
if (linuxConsts.length === 0) {
	console.log(`  ${PASS}  linux: no divergent PRIORITY_* constant`);
	pass++;
} else {
	console.log(`  ${FAIL}  linux declares priority constants that disagree with the shared source:`);
	for (const c of linuxConsts) console.log('       - ' + c);
	fail++;
}



// ==================================================
// ==================================================
// ======= 4/ Both resolvers agree on the order =====
// ==================================================
// ==================================================

// priority.json documents the cascade as individual > section > file > source.
// Equal constants with a different resolution order still produce different
// winners on a collision, so the order is part of the contract.
const CASCADE = ['individual', 'section', 'file'];

/**
 * Positions of the cascade level names within a source snippet, in order of
 * appearance.
 * @param {string} text
 * @returns {number[]} Index of each level, -1 when absent.
 */
function cascadePositions(text) {
	return CASCADE.map((level) => text.indexOf(level));
}

const luaResolver = LUA.match(/local function resolve_priority[\s\S]*?\nend/);
if (!luaResolver) {
	console.log(`  ${FAIL}  macos/modules/keymap/registry.lua: resolve_priority() not found`);
	fail++;
} else {
	const pos = cascadePositions(luaResolver[0]);
	const ordered = pos.every((v, i) => v >= 0 && (i === 0 || v > pos[i - 1]));
	if (ordered) {
		console.log(`  ${PASS}  macos resolve_priority() tests ${CASCADE.join(' > ')} > source, in order`);
		pass++;
	} else {
		console.log(`  ${FAIL}  macos resolve_priority() does not test ${CASCADE.join(' > ')} in the documented order`);
		fail++;
	}
}

// AHK resolves the same cascade across the cache builder rather than in one
// function, so the contract is asserted where it is written down: the comment
// naming the order must still match the shared JSON's description.
const CACHE = fs.readFileSync(path.join(ROOT, 'windows/infra/hotstrings/hotstrings_cache.ahk'), 'utf8');
if (/individual\s*>\s*section\s*>\s*file\s*>\s*source/.test(CACHE)) {
	console.log(`  ${PASS}  windows cache builder documents the same cascade order`);
	pass++;
} else {
	console.log(`  ${FAIL}  windows/infra/hotstrings/hotstrings_cache.ahk no longer states the cascade individual > section > file > source`);
	fail++;
}

console.log('');
console.log(`Total: ${pass + fail} check(s) - ${pass} passed, ${fail} failed`);
console.log('');

process.exit(fail > 0 ? 1 : 0);
