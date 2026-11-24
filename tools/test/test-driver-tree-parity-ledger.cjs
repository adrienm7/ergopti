// tools/test/test-driver-tree-parity-ledger.cjs

/**
 * ==============================================================================
 * MODULE: Driver Tree Parity Ledger
 * DESCRIPTION:
 * Runs the real tools/test/test-driver-tree-parity.cjs in an isolated Git
 * repository whose staged driver trees the test chooses, against a ledger it
 * writes. The gate used to compare five counts; a new one-driver directory and
 * an unrelated removed one-driver directory kept the union at its recorded
 * size, so the regression passed unseen. The ledger names every path, so that
 * pair fails and names the new path.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { execFileSync, spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const GATE = 'tools/test/test-driver-tree-parity.cjs';
const LEDGER = 'tools/test/driver-tree-parity-baseline.json';
const FEATURES = 'static/ergopti_plus/_shared/core/features.json';

const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tree-parity-ledger-'));
const git = (...args) => execFileSync('git', args, { cwd: fixture, encoding: 'utf8' });

/** Writes and stages one driver source file. */
function stage(relative) {
	const target = path.join(fixture, relative);
	fs.mkdirSync(path.dirname(target), { recursive: true });
	fs.writeFileSync(target, '-- fixture\n');
	git('add', '--', relative);
}

/** Removes one staged file from the candidate. */
function unstage(relative) {
	git('rm', '-q', '--cached', '--', relative);
	fs.rmSync(path.join(fixture, relative));
}

/** Runs the gate inside the fixture. */
function gate(args = [], env = {}) {
	return spawnSync(process.execPath, [path.join(fixture, GATE), ...args], {
		cwd: fixture,
		encoding: 'utf8',
		env: { ...process.env, ERGOPTI_STRUCTURE_PHASE: '', ...env }
	});
}

const readLedger = () => JSON.parse(fs.readFileSync(path.join(fixture, LEDGER), 'utf8'));

try {
	git('init', '-q');
	fs.mkdirSync(path.join(fixture, 'tools/test'), { recursive: true });
	fs.copyFileSync(path.join(ROOT, GATE), path.join(fixture, GATE));
	fs.mkdirSync(path.dirname(path.join(fixture, FEATURES)), { recursive: true });
	fs.writeFileSync(
		path.join(fixture, FEATURES),
		JSON.stringify({ features: [{ name: 'gestures', tree: 'modules', role: 'fixture' }] })
	);
	for (const driver of ['macos', 'windows', 'linux']) {
		stage(`static/ergopti_plus/${driver}/modules/gestures/init.lua`);
		stage(`static/ergopti_plus/${driver}/tests/unit/test_gestures.lua`);
	}
	stage('static/ergopti_plus/linux/platform/tray/init.lua');
	fs.writeFileSync(path.join(fixture, LEDGER), '{}\n');

	const seeded = gate(['--update-baseline', '--allow-rise'], { ERGOPTI_STRUCTURE_PHASE: '2' });
	assert.equal(seeded.status, 0, seeded.stderr);
	assert.equal(readLedger()['tree:platform/tray'], 'linux');
	assert.equal(readLedger()['tree:modules/gestures'], 'linux+macos+windows');
	assert.equal(readLedger()['canonical:modules/gestures'], 'linux+macos+windows');
	const clean = gate();
	assert.equal(clean.status, 0, `the recorded tree passes\n${clean.stdout}${clean.stderr}`);

	// The pair a count could not see: the union keeps its size.
	unstage('static/ergopti_plus/linux/platform/tray/init.lua');
	stage('static/ergopti_plus/macos/platform/remap/init.lua');
	const swapped = gate();
	assert.equal(swapped.status, 1, 'a new one-driver path fails even when another one left');
	assert.match(
		swapped.stderr,
		/tree:platform\/remap: recorded absent, measured macos: a driver diverged/
	);
	assert.match(
		swapped.stderr,
		/tree:platform\/tray: recorded linux, measured absent: the drivers converged/
	);

	const refused = gate(['--record-convergence']);
	assert.equal(refused.status, 1, 'a divergence is never recorded as convergence');
	assert.equal(readLedger()['tree:platform/tray'], 'linux', 'a refused record writes nothing');
	const outside = gate(['--update-baseline', '--allow-rise']);
	assert.equal(outside.status, 1, 'outside the phase 2 runner a divergence is never recorded');

	unstage('static/ergopti_plus/macos/platform/remap/init.lua');
	const converged = gate(['--record-convergence']);
	assert.equal(converged.status, 0, converged.stderr);
	assert.match(
		converged.stdout,
		/\[RECORD\] I1 tree:platform\/tray: recorded linux, measured absent/
	);
	assert.equal(readLedger()['tree:platform/tray'], undefined, 'the fixed path leaves the ledger');
	assert.equal(gate().status, 0, 'the recorded convergence passes');

	// A shared path that loses one driver is a divergence, named by holders.
	unstage('static/ergopti_plus/windows/tests/unit/test_gestures.lua');
	const lost = gate();
	assert.equal(lost.status, 1);
	assert.match(lost.stderr, /tests:unit: recorded linux\+macos\+windows, measured linux\+macos/);
	const rise = gate(['--update-baseline', '--allow-rise'], { ERGOPTI_STRUCTURE_PHASE: '2' });
	assert.equal(rise.status, 0, rise.stderr);
	assert.match(rise.stdout, /\[RISE\] I1 tests:unit: recorded linux\+macos\+windows/);
} finally {
	fs.rmSync(fixture, { recursive: true, force: true });
}

console.log(
	'\x1b[32m[OK] the driver tree parity ledger names a diverging path, records convergence only, ' +
		'and leaves divergence to the phase 2 runner.\x1b[0m'
);
