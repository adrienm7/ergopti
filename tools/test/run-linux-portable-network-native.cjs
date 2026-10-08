// tools/test/run-linux-portable-network-native.cjs

/**
 * ==============================================================================
 * MODULE: Native Portable Linux Network Qualification
 * DESCRIPTION:
 * Requires the unchanged staged AppDir and actual kernel ownership receipts.
 * The Python stage owner retains its own finite clocks and physical child
 * retirement. This runner never substitutes format installation or networking
 * session acceptance for the narrower installed native runtime admission.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const WITNESSES = [
	'PASS actual staged AppDir network runtime: 7 native groups; real AppImage/Flatpak delivery unqualified.',
	'Actual PPID census controls: 2 passed; 0 skipped; native-7 credit unchanged.'
];

/** Runs the actual Linux producer; other platforms defer to its native lane. */
function run({
	platform = process.platform,
	spawn = spawnSync,
	log = console.log,
	error = console.error,
	write = (value) => process.stdout.write(value),
	writeError = (value) => process.stderr.write(value)
} = {}) {
	if (platform !== 'linux') {
		log('[DEFERRED] Portable Linux network runtime requires the mandatory native Linux lane.');
		return 0;
	}
	const result = spawn(
		process.execPath,
		[path.join(ROOT, 'tools/test/test-linux-portable-network-runtime.cjs'), '--native'],
		{ cwd: ROOT, env: process.env, encoding: 'utf8', maxBuffer: 8 * 1024 * 1024 }
	);
	const stdout = String(result.stdout || '');
	if (stdout) write(stdout);
	if (result.stderr) writeError(result.stderr);
	const lines = stdout.split(/\r?\n/);
	if (
		result.error ||
		result.status !== 0 ||
		WITNESSES.some((witness) => lines.filter((line) => line === witness).length !== 1) ||
		lines.some((line) => /^\s*(?:\[SKIP\]|SKIP\b)/.test(line))
	) {
		error('[FAIL] Native portable network qualification lacks completed owned receipts.');
		return Number.isInteger(result.status) && result.status > 0 ? result.status : 1;
	}
	return 0;
}

if (require.main === module) process.exitCode = run();
module.exports = { run };
