// tools/test/test-untracked-driver-artifacts-do-not-affect-gates.cjs

/**
 * ==============================================================================
 * MODULE: Untracked Driver Artifact Isolation Regression
 * DESCRIPTION:
 * Proves architecture gates measure the staged commit candidate rather than
 * local runtime or personal files that happen to live below a driver root.
 *
 * ROOT CAUSE ENCODED:
 * Architecture gates walked the raw filesystem. A personal Hammerspoon configuration
 * and an empty scratch directory therefore changed driver-tree parity and
 * source-tree coverage, while a personal CRLF Lua file failed the shared LF
 * guard even though none of those artifacts could ship in the commit.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const GATES = [
	'tools/test/test-driver-tree-parity.cjs',
	'tools/test/test-source-trees-are-scanned.cjs',
	'tools/test/test-shared-sources-are-lf.cjs',
	'tools/test/test-convention-p-platform-only.cjs'
];

const probeRoot = fs.mkdtempSync(path.join(MACOS_ROOT, 'untracked-gate-probe-'));
const platformProbe = fs.mkdtempSync(path.join(MACOS_ROOT, 'platform', 'untracked-gate-probe-'));
const driverProbe = fs.mkdtempSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'untracked-driver-probe-')
);
fs.mkdirSync(path.join(driverProbe, 'adapters'));
const nested = path.join(probeRoot, 'nested');
fs.mkdirSync(nested);
fs.writeFileSync(path.join(nested, 'personal.lua'), 'local enabled = true\r\nreturn enabled\r\n');

const failures = [];
try {
	for (const gate of GATES) {
		const result = spawnSync(process.execPath, [path.join(ROOT, gate)], {
			cwd: ROOT,
			encoding: 'utf8'
		});
		if (result.status !== 0) {
			failures.push(`${gate}\n${result.stdout}${result.stderr}`);
		}
	}
} finally {
	fs.rmSync(probeRoot, { recursive: true, force: true });
	fs.rmSync(platformProbe, { recursive: true, force: true });
	fs.rmSync(driverProbe, { recursive: true, force: true });
}

// A real source partition withdrawn from the staged inventory must still fail,
// even while its directory remains on disk in this checkout.
const withdrawal = spawnSync(
	process.execPath,
	[
		'-e',
		`
const assert = require('node:assert/strict');
const child = require('node:child_process');
const original = child.execSync;
child.execSync = function (...args) {
	const output = original.apply(this, args);
	const changed = output.split('\\n').filter((file) =>
		!file.startsWith('static/ergopti_plus/linux/platform/remap/')).join('\\n');
	assert.notEqual(changed, output, 'the real remap source partition must exist');
	return changed;
};
require('./tools/test/test-convention-p-platform-only.cjs');
`
	],
	{ cwd: ROOT, encoding: 'utf8' }
);
if (withdrawal.status !== 1 || !withdrawal.stderr.includes('linux/platform/remap')) {
	failures.push(
		`a withdrawn tracked platform partition escaped the gate\n${withdrawal.stdout}${withdrawal.stderr}`
	);
}

if (failures.length > 0) {
	console.error(
		'\x1b[31m[ERROR] untracked driver artifacts contaminated commit-candidate gates:\x1b[0m'
	);
	for (const failure of failures) console.error(failure);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] all ${GATES.length} commit-candidate gates ignore untracked driver artifacts.\x1b[0m`
);
