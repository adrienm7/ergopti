// tools/test/test-port-vector-traceability.cjs

/**
 * ==============================================================================
 * MODULE: Port Contract Vector Traceability
 * DESCRIPTION:
 * Every `contractTestVectors()` scenario in _shared/core/ports/*.spec.js should
 * be traceable, by id, to the macOS mirror that replays it. This ratchets the
 * proportion that is, and refuses to let it fall.
 *
 * ROOT CAUSE ENCODED:
 * test_adapter_contract_vectors_*.lua hard-code the vectors in Lua and their
 * docstring promised: "When the JS vectors are updated the Lua mirrors must be
 * updated to match — the tests will fail until they are synchronised, making
 * drift immediately visible."
 *
 * Nothing made that true. The file reads no .spec.js, so a vector changed on the
 * JS side leaves the Lua mirror passing against the old expectation, silently.
 * Measured at the time this gate was written: **138 vectors across 20 ports, 61
 * of them referenced by id in the mirror** — so 77 could drift with nothing to
 * notice. Two ports (Notifier, TimerScheduler, TooltipRenderer) had zero
 * traceable vectors while their sections looked fully populated.
 *
 * The mirror is NOT a reimplementation, which is worth saying because the
 * backlog described it as one: it calls the real adapters through
 * load_with_stubs and asserts on their behaviour. The defect is narrower and
 * entirely about traceability — good tests, no link to the contract they claim
 * to mirror.
 *
 * WHY A RATCHET RATHER THAN A REQUIREMENT:
 * Demanding all 138 today would fail on arrival and be deleted within a week.
 * The ledger (port-vector-traceability-baseline.json) records which vectors
 * the mirror names; adding a vector id to a Lua test is a one-line change, so
 * the ledger can only grow. It names each id rather than counting them: a count
 * (73 until 2026-11-24) let a vector that lost its mirror and an unrelated one
 * that gained it cancel out unseen.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { loadCjsModule } = require('../lib/load-cjs-module.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const PORTS = path.join(ROOT, 'static/ergopti_plus/_shared/core/ports');
// The Lua mirror is split by port family into test_adapter_contract_vectors_*.lua.
const MIRROR_DIR = path.join(ROOT, 'static/ergopti_plus/macos/tests/unit/core/lifecycle/adapters');
const MIRROR_FILES = fs.existsSync(MIRROR_DIR)
	? fs
			.readdirSync(MIRROR_DIR)
			.filter((f) => /^test_adapter_contract_vectors_\w+\.lua$/.test(f))
			.map((f) => path.join(MIRROR_DIR, f))
	: [];
const MIRROR =
	MIRROR_FILES.length > 0
		? MIRROR_FILES[0]
		: path.join(MIRROR_DIR, 'test_adapter_contract_vectors_*.lua');

// Every traced vector as `<port>:<id>` (two ports may share an id). A traced
// vector missing from the ledger is recorded with --record-traced, which
// refuses while any recorded vector has lost its mirror.
const LEDGER_PATH = path.join(__dirname, 'port-vector-traceability-baseline.json');

const errors = [];

if (!fs.existsSync(MIRROR)) {
	console.error(`\x1b[31m[ERROR] mirror missing: ${MIRROR}\x1b[0m`);
	process.exit(1);
}
const mirror = MIRROR_FILES.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

const perPort = [];
const traced = new Set();
let total = 0;
let traceable = 0;

for (const file of fs.readdirSync(PORTS).filter((f) => f.endsWith('.spec.js'))) {
	const src = fs.readFileSync(path.join(PORTS, file), 'utf8');
	const ids = [...src.matchAll(/id:\s*'([^']+)'/g)].map((m) => m[1]);
	if (ids.length === 0) continue;
	const hit = ids.filter((id) => mirror.includes(id));
	for (const id of hit) traced.add(`${file.replace('.spec.js', '')}:${id}`);
	perPort.push({ port: file.replace('.spec.js', ''), n: ids.length, hit: hit.length });
	total += ids.length;
	traceable += hit.length;
}

if (total < 100) {
	errors.push(
		`found only ${total} contract vector(s) across the port specs — the scan is broken, and a ` +
			'ratchet over nothing only ever improves'
	);
}

// SFC-03: the secure-field port says fail closed, as the three adapters do, and
// its fail-closed vector is replayed on all three drivers, not on macOS alone:
// the spec used to promise « not secure » on a failure that no driver returned.
const SECURE_SPEC = fs.readFileSync(path.join(PORTS, 'SecureFieldDetector.spec.js'), 'utf8');
const FAIL_CLOSED_VECTOR = 'isSecureField_unclassified_returns_true';
if (!/isSecureField\(\)[\s\S]*?@error_behavior "return_true"/.test(SECURE_SPEC))
	errors.push('SecureFieldDetector.spec.js must declare isSecureField() fail-closed (return_true)');
if (!SECURE_SPEC.includes(`id: '${FAIL_CLOSED_VECTOR}'`))
	errors.push(`SecureFieldDetector.spec.js must carry the ${FAIL_CLOSED_VECTOR} vector`);
for (const mirror of [
	'static/ergopti_plus/macos/tests/unit/core/lifecycle/adapters/test_adapter_contract_vectors_input_and_system.lua',
	'static/ergopti_plus/windows/tests/unit/platform/system/test_adapter_contract_vectors_system.ahk',
	'static/ergopti_plus/linux/tests/unit/platform/focus/atspi/test_secure_field_detector.lua'
]) {
	if (!fs.readFileSync(path.join(ROOT, mirror), 'utf8').includes(FAIL_CLOSED_VECTOR))
		errors.push(`${mirror} must replay the ${FAIL_CLOSED_VECTOR} vector`);
}

// TRAY-04: the tray port used to declare setIcon(state) over three states no
// adapter took, with vectors that only asked for no exception, so a setIcon
// that ignored its argument passed. Its setIcon vectors read the result, and
// the three drivers replay them against their real adapters.
const TRAY_SPEC = fs.readFileSync(path.join(PORTS, 'TrayMenu.spec.js'), 'utf8');
const trayPort = loadCjsModule(path.join(PORTS, 'TrayMenu.spec.js'));
if ('ICON_STATES' in trayPort.portContract)
	errors.push(
		'TrayMenu.spec.js must not declare icon states: setIcon takes an option map with an image'
	);
for (const vector of trayPort.contractTestVectors().filter((v) => /^set_icon_/.test(v.id))) {
	if (!vector.assert || !('returns' in vector.assert))
		errors.push(
			`TrayMenu.spec.js ${vector.id} must assert what setIcon returns, not only that it does not throw`
		);
}
const TRAY_VECTORS = [
	'set_icon_draws_the_image',
	'set_icon_refuses_a_missing_file',
	'set_icon_refuses_a_state_name'
];
for (const mirror of [
	'static/ergopti_plus/macos/tests/unit/core/lifecycle/adapters/test_adapter_contract_vectors_input_and_system.lua',
	'static/ergopti_plus/windows/tests/unit/platform/system/test_adapter_contract_vectors.ahk',
	'static/ergopti_plus/linux/tests/unit/platform/system/test_tray_menu_adapter.lua'
]) {
	const text = fs.readFileSync(path.join(ROOT, mirror), 'utf8');
	for (const id of TRAY_VECTORS) {
		if (!TRAY_SPEC.includes(`id: '${id}'`))
			errors.push(`TrayMenu.spec.js must carry the ${id} vector`);
		if (!text.includes(id)) errors.push(`${mirror} must replay the ${id} vector`);
	}
}

let ledger;
try {
	ledger = JSON.parse(fs.readFileSync(LEDGER_PATH, 'utf8'));
} catch (error) {
	console.error(`[ERROR] ${path.relative(ROOT, LEDGER_PATH)} is unreadable: ${error.message}`);
	process.exit(1);
}
if (!Array.isArray(ledger)) {
	console.error(`[ERROR] ${path.relative(ROOT, LEDGER_PATH)} must be an array of <port>:<id>`);
	process.exit(1);
}
const recorded = new Set(ledger);
const lost = [...recorded].filter((vector) => !traced.has(vector)).sort();
const gained = [...traced].filter((vector) => !recorded.has(vector)).sort();

if (process.argv.includes('--record-traced')) {
	if (lost.length > 0) {
		console.error('[ERROR] --record-traced refuses while recorded vectors lost their mirror:');
		for (const vector of lost) console.error(`    - ${vector}`);
		process.exit(1);
	}
	fs.writeFileSync(LEDGER_PATH, JSON.stringify([...traced].sort(), null, '\t') + '\n');
	for (const vector of gained) console.log(`[RECORD] ${vector} is traced by the macOS mirror`);
	process.exit(0);
}

for (const vector of lost) {
	errors.push(
		`${vector} is no longer referenced by id in the macOS mirror. A vector with no id in the ` +
			'mirror can change on the JS side while the Lua test keeps passing against the old ' +
			'expectation: name it in its Lua test again.'
	);
}
for (const vector of gained)
	errors.push(`${vector} is now traced by the macOS mirror: record it with --record-traced.`);

if (process.argv.includes('--measure')) {
	console.log('port'.padEnd(22) + 'vectors  traceable');
	for (const p of perPort) {
		console.log(
			p.port.padEnd(22) +
				String(p.n).padStart(7) +
				String(p.hit).padStart(11) +
				(p.hit < p.n ? '  <-- gap' : '')
		);
	}
	console.log(`\nTOTAL ${traceable}/${total} (ledger ${recorded.size})`);
	process.exit(0);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] port contract vector traceability:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	console.error('    Run with --measure for the per-port breakdown.');
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] ${traceable}/${total} port contract vector(s) traceable by id in the macOS mirror ` +
		`(every one in the ledger).\x1b[0m`
);
