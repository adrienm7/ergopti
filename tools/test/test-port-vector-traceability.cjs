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
 * The baseline records where the link stands; adding a vector id to a Lua test
 * is a one-line change, so the number can only improve, and it must never fall.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

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

// Measured 2026-08-01. Raise as ids are added to the Lua tests; never lower.
const BASELINE_TRACEABLE = 61;

const errors = [];

if (!fs.existsSync(MIRROR)) {
	console.error(`\x1b[31m[ERROR] mirror missing: ${MIRROR}\x1b[0m`);
	process.exit(1);
}
const mirror = MIRROR_FILES.map((f) => fs.readFileSync(f, 'utf8')).join('\n');

const perPort = [];
let total = 0;
let traceable = 0;

for (const file of fs.readdirSync(PORTS).filter((f) => f.endsWith('.spec.js'))) {
	const src = fs.readFileSync(path.join(PORTS, file), 'utf8');
	const ids = [...src.matchAll(/id:\s*'([^']+)'/g)].map((m) => m[1]);
	if (ids.length === 0) continue;
	const hit = ids.filter((id) => mirror.includes(id));
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

if (traceable < BASELINE_TRACEABLE) {
	const worst = perPort
		.filter((p) => p.hit < p.n)
		.sort((a, b) => b.n - b.hit - (a.n - a.hit))
		.slice(0, 5)
		.map((p) => `${p.port} ${p.hit}/${p.n}`)
		.join(', ');
	errors.push(
		`only ${traceable} of ${total} contract vector(s) are referenced by id in the macOS mirror, ` +
			`below the recorded ${BASELINE_TRACEABLE}. A vector with no id in the mirror can change on ` +
			`the JS side while the Lua test keeps passing against the old expectation. Largest gaps: ${worst}.`
	);
}

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
	console.log(`\nTOTAL ${traceable}/${total} (baseline ${BASELINE_TRACEABLE})`);
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
		`(baseline ${BASELINE_TRACEABLE}).\x1b[0m`
);
