// tools/test/test-port-vector-traceability-ledger.cjs

/**
 * ==============================================================================
 * MODULE: Port Vector Traceability Ledger
 * DESCRIPTION:
 * Runs the real tools/test/test-port-vector-traceability.cjs on a copy of its
 * inputs in which the macOS mirror stops naming one traced vector and names an
 * untraced one instead. The gate used to compare the number of traced vectors
 * with a recorded number, so that swap kept the count and passed; the ledger names each
 * vector, so the swap fails, names both, and --record-traced refuses it.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const GATE = 'tools/test/test-port-vector-traceability.cjs';
const LEDGER = 'tools/test/port-vector-traceability-baseline.json';
const MIRROR_DIR = 'static/ergopti_plus/macos/tests/unit/core/lifecycle/adapters';
const MIRROR = `${MIRROR_DIR}/test_adapter_contract_vectors_input_and_system.lua`;
const INPUTS = [
	GATE,
	LEDGER,
	'tools/lib/load-cjs-module.cjs',
	'static/ergopti_plus/_shared/core/ports',
	MIRROR_DIR,
	'static/ergopti_plus/windows/tests/unit/platform/system/test_adapter_contract_vectors_system.ahk',
	'static/ergopti_plus/windows/tests/unit/platform/system/test_adapter_contract_vectors.ahk',
	'static/ergopti_plus/linux/tests/unit/platform/focus/atspi/test_secure_field_detector.lua',
	'static/ergopti_plus/linux/tests/unit/platform/system/test_tray_menu_adapter.lua'
];
// A vector the mirror traces, and one of a port it does not trace at all.
const TRACED = 'is_running_returns_boolean';
const UNTRACED = 'bind_returns_handle';

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-vector-ledger-'));
const gate = (args = []) =>
	spawnSync(process.execPath, [path.join(fixture, GATE), ...args], {
		cwd: fixture,
		encoding: 'utf8'
	});

try {
	for (const input of INPUTS) {
		const target = path.join(fixture, input);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.cpSync(path.join(ROOT, input), target, { recursive: true });
	}
	const clean = gate();
	assert.equal(clean.status, 0, `the copied inputs pass\n${clean.stdout}${clean.stderr}`);
	const tracedCount = () => Number(gate(['--measure']).stdout.match(/TOTAL (\d+)\//)[1]);
	const countBefore = tracedCount();

	const mirror = path.join(fixture, MIRROR);
	const text = fs.readFileSync(mirror, 'utf8');
	assert.equal(text.split(TRACED).length, 2, `${TRACED} is named once in the mirror`);
	assert.ok(!text.includes(UNTRACED), `${UNTRACED} is not traced yet`);
	fs.writeFileSync(mirror, text.replace(TRACED, UNTRACED));

	const swapped = gate();
	assert.equal(swapped.status, 1, 'a lost vector fails even when another one was gained');
	assert.match(swapped.stderr, /AppLauncher:is_running_returns_boolean is no longer referenced/);
	assert.match(swapped.stderr, /HotkeyRegistrar:bind_returns_handle is now traced/);
	assert.equal(tracedCount(), countBefore, 'the swap keeps the count the gate used to compare');

	const refused = gate(['--record-traced']);
	assert.equal(refused.status, 1, 'a lost vector is never recorded');
	assert.deepEqual(
		JSON.parse(fs.readFileSync(path.join(fixture, LEDGER), 'utf8')),
		JSON.parse(fs.readFileSync(path.join(ROOT, LEDGER), 'utf8')),
		'a refused record writes nothing'
	);

	fs.writeFileSync(mirror, `${text}\n-- ${UNTRACED}\n`);
	const gained = gate();
	assert.equal(gained.status, 1, 'a newly traced vector waits for its ledger entry');
	const recorded = gate(['--record-traced']);
	assert.equal(recorded.status, 0, recorded.stderr);
	assert.match(recorded.stdout, /\[RECORD\] HotkeyRegistrar:bind_returns_handle/);
	assert.equal(gate().status, 0, 'the recorded vector passes');
} finally {
	fs.rmSync(fixture, { recursive: true, force: true });
}

console.log(
	'\x1b[32m[OK] the port vector traceability ledger names a lost vector even when the count holds, ' +
		'and records only gains.\x1b[0m'
);
