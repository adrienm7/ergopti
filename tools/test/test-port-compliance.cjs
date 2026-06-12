// tools/test/test-port-compliance.cjs

/**
 * ==============================================================================
 * MODULE: Port Contract Single-Source Compliance Tests
 * DESCRIPTION:
 * Enforces that the generated shared/ports/contracts.json is the one and only
 * source of truth for the port method/arity surface, and that the AHK driver's
 * hand-written ADAPTER_* dispatch maps stay in sync with it.
 *
 * Previously this script validated a hand-typed table of JS adapter stubs
 * (HS_ADAPTERS) — itself a fourth mirror of the contract that had to be kept in
 * sync by hand. That mirror is gone: contracts.json is now projected directly
 * from the spec.js files by tools/codegen/codegen-contracts-json.cjs, and the
 * macOS + Linux drivers validate their real adapters against that JSON at
 * runtime in their own Lua suites.
 *
 * FEATURES & RATIONALE:
 * 1. Freshness gate: re-projects the contracts from the spec.js files and diffs
 *    against the committed contracts.json. A spec change that forgets to run
 *    `npm run codegen:contracts` fails CI loudly instead of letting the JSON go
 *    stale (which would silently weaken every downstream compliance check).
 * 2. AHK ADAPTER_* parity: the AHK adapters expose `global ADAPTER_<NAME> :=
 *    Map("method", Func, …)` dispatch maps. We text-parse each adapter file and
 *    assert every map key is a declared contract method, and that no required
 *    method is missing — catching renames/typos/drift against the single source
 *    without needing an AHK runtime.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { buildContracts, serialise } = require('../codegen/codegen-contracts-json.cjs');

const ROOT = path.join(__dirname, '../..');
const CONTRACTS_PATH = path.join(ROOT, 'static/ergopti_plus/shared/ports/contracts.json');
const AHK_ADAPTERS_DIR = path.join(ROOT, 'static/ergopti_plus/windows/adapters');

const PASS = '✓';
const FAIL = '✗';

let totalPass = 0;
let totalFail = 0;

function pass(msg) {
	console.log(`  ${PASS}  ${msg}`);
	totalPass++;
}
function fail(msg, detail) {
	console.log(`  ${FAIL}  ${msg}`);
	if (detail) for (const d of detail) console.log(`       - ${d}`);
	totalFail++;
}




// ==================================================
// ==================================================
// ======= 1/ Freshness Gate ========================
// ==================================================
// ==================================================

console.log('\nPort contract single-source compliance');
console.log('='.repeat(50));

// Compare line-ending-normalised so the gate is robust to git autocrlf:
// contracts.json has no explicit .gitattributes eol rule, so it is checked out
// CRLF on Windows while the codegen always emits LF — a raw compare would then
// report a false "stale" on Windows checkouts.
const normalizeEol = (s) => s.replace(/\r\n/g, '\n');
const committed = fs.existsSync(CONTRACTS_PATH) ? fs.readFileSync(CONTRACTS_PATH, 'utf8') : null;
const regenerated = serialise(buildContracts());

if (committed === null) {
	fail('contracts.json exists', ['file not found — run `npm run codegen:contracts`']);
} else if (normalizeEol(committed) !== normalizeEol(regenerated)) {
	fail('contracts.json is up to date with shared/ports/*.spec.js', [
		'contracts.json is STALE — run `npm run codegen:contracts` and commit the result'
	]);
} else {
	pass('contracts.json is up to date with the spec.js single source');
}

// Parse whichever contracts we trust as the source for the parity check below:
// the regenerated projection (so the check is meaningful even if the committed
// file is stale).
const contracts = JSON.parse(regenerated).ports;




// ==================================================
// ==================================================
// ======= 2/ Port → ADAPTER_ Name Mapping ==========
// ==================================================
// ==================================================

/**
 * Converts a PascalCase port name to the UPPER_SNAKE suffix used by the AHK
 * ADAPTER_* globals (e.g. "HttpClient" → "HTTP_CLIENT", "KeyState" →
 * "KEY_STATE").
 * @param {string} pascal
 * @returns {string}
 */
function pascalToUpperSnake(pascal) {
	return pascal
		.replace(/([a-z0-9])([A-Z])/g, '$1_$2')
		.replace(/([A-Z]+)([A-Z][a-z])/g, '$1_$2')
		.toUpperCase();
}

// Build UPPER_SNAKE → portName lookup for every known port.
const snakeToPort = {};
for (const portName of Object.keys(contracts)) {
	snakeToPort[pascalToUpperSnake(portName)] = portName;
}




// ==================================================
// ==================================================
// ======= 3/ AHK ADAPTER_* Parity ==================
// ==================================================
// ==================================================

/**
 * Extracts every `global ADAPTER_<NAME> := Map( … )` block from an AHK source
 * file and returns { NAME: [methodKeys] }.
 * @param {string} src
 * @returns {Object<string,string[]>}
 */
function parseAdapterMaps(src) {
	const maps = {};
	const re = /global\s+ADAPTER_([A-Z_]+)\s*:=\s*Map\(([\s\S]*?)\)/g;
	let m;
	while ((m = re.exec(src)) !== null) {
		const name = m[1];
		const body = m[2];
		// Map keys are the double-quoted tokens; values are bare Func identifiers.
		const keys = [];
		const keyRe = /"([^"]+)"/g;
		let k;
		while ((k = keyRe.exec(body)) !== null) keys.push(k[1]);
		maps[name] = keys;
	}
	return maps;
}

const ahkFiles = fs
	.readdirSync(AHK_ADAPTERS_DIR)
	.filter((f) => f.endsWith('.ahk'))
	.map((f) => path.join(AHK_ADAPTERS_DIR, f));

let adapterMapCount = 0;
for (const file of ahkFiles) {
	const src = fs.readFileSync(file, 'utf8');
	const maps = parseAdapterMaps(src);
	for (const [name, keys] of Object.entries(maps)) {
		adapterMapCount++;
		const portName = snakeToPort[name];
		if (!portName) {
			fail(`ADAPTER_${name}: maps to a known port`, [
				`no port contract matches ADAPTER_${name} (expected one of ${Object.keys(snakeToPort).join(', ')})`
			]);
			continue;
		}
		const contractMethods = Object.keys(contracts[portName].methods);
		const requiredMethods = contractMethods.filter(
			(mth) => contracts[portName].methods[mth].required
		);

		const violations = [];
		// Every map key must be a declared contract method (no drift/typos).
		for (const key of keys) {
			if (!contractMethods.includes(key)) {
				violations.push(`unknown method "${key}" not in ${portName} contract`);
			}
		}
		// Every required method must be present in the dispatch map.
		for (const req of requiredMethods) {
			if (!keys.includes(req)) {
				violations.push(`missing required method "${req}"`);
			}
		}

		if (violations.length === 0) {
			pass(`ADAPTER_${name} ⇄ ${portName} (${keys.length} method(s))`);
		} else {
			fail(`ADAPTER_${name} ⇄ ${portName}`, violations);
		}
	}
}

if (adapterMapCount === 0) {
	fail('AHK ADAPTER_* maps found', ['no ADAPTER_* Map() definitions parsed — parser or layout drift']);
}




// ==================================================
// ==================================================
// ======= 4/ Summary ===============================
// ==================================================
// ==================================================

console.log('');
console.log(`Total: ${totalPass + totalFail} check(s) — ${totalPass} passed, ${totalFail} failed`);
console.log('');

process.exit(totalFail > 0 ? 1 : 0);
