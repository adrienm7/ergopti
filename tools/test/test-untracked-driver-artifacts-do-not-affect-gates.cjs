// tools/test/test-untracked-driver-artifacts-do-not-affect-gates.cjs

/**
 * ==============================================================================
 * MODULE: Untracked Driver Artifact Isolation Regression
 * DESCRIPTION:
 * Proves architecture gates measure the staged commit candidate rather than
 * local runtime or personal files that happen to live below a driver root.
 *
 * ROOT CAUSE ENCODED:
 * Three gates walked the raw filesystem. A personal Hammerspoon configuration
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
	'tools/test/test-shared-sources-are-lf.cjs'
];

const probeRoot = fs.mkdtempSync(path.join(MACOS_ROOT, 'untracked-gate-probe-'));
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
}

if (failures.length > 0) {
	console.error('\x1b[31m[ERROR] untracked driver artifacts contaminated commit-candidate gates:\x1b[0m');
	for (const failure of failures) console.error(failure);
	process.exit(1);
}

console.log(`\x1b[32m[OK] all ${GATES.length} commit-candidate gates ignore untracked driver artifacts.\x1b[0m`);
