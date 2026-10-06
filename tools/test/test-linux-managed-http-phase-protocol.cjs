// tools/test/test-linux-managed-http-phase-protocol.cjs

/**
 * ==============================================================================
 * MODULE: Managed HTTP Native Phase Protocol Models
 * DESCRIPTION:
 * Registers the original sixteen modeled owner/sink controls in the JS suite.
 * Native output18/public30 require their separate actual Linux qualification.
 * ==============================================================================
 */
'use strict';
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const result = spawnSync(
	process.execPath,
	[
		path.join(ROOT, 'tools/test/fixtures/linux-managed-http-phase-protocol.cjs'),
		path.join(ROOT, 'tools/test/run-linux-managed-http-native.cjs')
	],
	{ cwd: ROOT, encoding: 'utf8', maxBuffer: 65536, timeout: 5000 }
);
const witness = 'Owned phase protocol models: 16 passed; native execution UNRUN.';
if (
	result.error ||
	result.signal ||
	result.status !== 0 ||
	result.stderr !== '' ||
	typeof result.stdout !== 'string' ||
	result.stdout.split('\n').filter((line) => line === witness).length !== 1
) {
	console.error('[FAIL] Managed HTTP phase protocol model receipt refused.');
	process.exitCode = 1;
} else {
	process.stdout.write(result.stdout);
}
