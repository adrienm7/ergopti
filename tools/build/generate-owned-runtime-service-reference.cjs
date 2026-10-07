// tools/build/generate-owned-runtime-service-reference.cjs

/**
 * ==============================================================================
 * MODULE: Owned Runtime Service Reference Generator
 * DESCRIPTION:
 * Runs the canonical Python projection through the ordinary Node generator path.
 * --check refuses stale reference bytes without rewriting the generated output.
 * This build provenance grants no signer, native custody or service authority.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const python = process.env.PYTHON || (process.platform === 'win32' ? 'python' : 'python3');
const result = spawnSync(
	python,
	[path.join(__dirname, 'generate_owned_runtime_service_reference.py'), ...process.argv.slice(2)],
	{ cwd: ROOT, stdio: 'inherit', timeout: 30_000 }
);

if (result.error || result.signal || result.status === null) {
	console.error('Owned runtime service reference generator unavailable');
	process.exitCode = 1;
} else {
	process.exitCode = result.status;
}
