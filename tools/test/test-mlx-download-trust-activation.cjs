// tools/test/test-mlx-download-trust-activation.cjs

/**
 * ==============================================================================
 * MODULE: Actual Emitted MLX System Trust Admission
 * DESCRIPTION:
 * Executes the complete production-emitted Python with independent literal
 * vectors and exact session metadata. Required Lua/CPython absence fails the
 * normal JS gate; no network, native trust modification or source-only credit.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const ROOT = path.resolve(__dirname, '../..');
const MACOS = path.join(ROOT, 'static/ergopti_plus/macos');
const SHARED = path.join(ROOT, 'static/ergopti_plus/_shared');
const CORPUS = path.join(SHARED, 'tests/corpus/network/mlx_truststore_activation_vectors.json');
const RECEIVER = path.join(MACOS, 'tests/support/mlx_truststore_receiving.py');

/** Receive complete Python and owner metadata from the original Lua producer. */
function emittedPacket() {
	const macos = MACOS.replace(/\\/g, '/');
	const shared = SHARED.replace(/\\/g, '/');
	const lua = process.env.LUA || 'lua';
	const program = [
		`package.path = ${JSON.stringify(`${macos}/?.lua;${macos}/?/init.lua;${shared}/lua/?.lua;${shared}/lua/?/init.lua;${macos}/tests/stubs/?.lua;`)} .. package.path`,
		'local packet = require("tests.support.mlx_truststore_fixture").capture()',
		'io.write(require("json").encode(packet))'
	].join('; ');
	const result = spawnSync(lua, ['-e', program], {
		cwd: MACOS,
		encoding: 'utf8',
		timeout: 30000
	});
	assert.equal(result.error, undefined, 'actual Lua production generator must start');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const packet = JSON.parse(result.stdout);
	assert.equal(typeof packet.source, 'string');
	assert.equal(typeof packet.expected_exit_path, 'string');
	assert.equal(packet.expected_exit_path, `${packet.log_path}.exit`);
	return packet;
}

const vectors = JSON.parse(fs.readFileSync(CORPUS, 'utf8'));
assert.deepEqual(vectors, [
	{
		id: 'missing_truststore',
		truststore: 'missing',
		hub: 'available',
		status: 1,
		hub_imports: 0,
		snapshots: 0,
		watchers: 0
	},
	{
		id: 'activation_refused',
		truststore: 'refused',
		hub: 'available',
		status: 1,
		hub_imports: 0,
		snapshots: 0,
		watchers: 0
	},
	{
		id: 'activation_api_missing',
		truststore: 'api_missing',
		hub: 'available',
		status: 1,
		hub_imports: 0,
		snapshots: 0,
		watchers: 0
	},
	{
		id: 'hub_missing_after_activation',
		truststore: 'available',
		hub: 'missing',
		status: 1,
		hub_imports: 1,
		snapshots: 0,
		watchers: 0
	},
	{
		id: 'activation_before_download',
		truststore: 'available',
		hub: 'available',
		status: 0,
		hub_imports: 1,
		snapshots: 1,
		watchers: 1
	}
]);

const python = pythonExecutable();
const packet = emittedPacket();
const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-mlx-trust-'));
try {
	const emitted = path.join(temporary, 'actual-emitted.json');
	fs.writeFileSync(emitted, JSON.stringify(packet), 'utf8');
	const result = spawnSync(python, [RECEIVER, emitted, CORPUS], {
		cwd: ROOT,
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, PYTHONIOENCODING: 'utf-8', PYTHONDONTWRITEBYTECODE: '1' }
	});
	assert.equal(result.error, undefined, 'actual CPython receiving must start');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	const receipt = JSON.parse(result.stdout);
	assert.deepEqual(receipt, { passed: 5, failed: 0, ids: vectors.map((vector) => vector.id) });
	console.log('PASS actual emitted MLX trust admission: 5 independent vectors, exact exit owner.');
} finally {
	fs.rmSync(temporary, { recursive: true, force: true });
}
