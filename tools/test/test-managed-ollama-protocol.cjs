// tools/test/test-managed-ollama-protocol.cjs

/** Receive portable source admission and operation closure without native credit. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const cases = [
	['tools/test/managed_ollama_runtime_policy_test.py', 7],
	['tools/test/managed_ollama_pull_test.py', 8]
];
if (process.platform !== 'win32') {
	cases.push(['tools/test/macos_native_ollama_api_test.py', 8]);
	cases.push(['tools/test/macos_managed_ollama_explicit_stream_test.py', 6]);
	cases.push(['tools/diagnostics/macos_managed_ollama_receiving_test.py', 16]);
	cases.push(['tools/test/managed_ollama_sessions_test.py', 8]);
	cases.push(['tools/test/macos_managed_ollama_pull_caller_test.py', 11]);
	cases.push(['tools/test/macos_managed_ollama_cleanup_test.py', 36]);
	cases.push(['tools/test/managed_source_alias_test.py', 23]);
	cases.push(['tools/diagnostics/macos_owned_image_alias_test.py', 20]);
	cases.push(['tools/test/macos_native_ollama_alias_api_test.py', 5]);
	cases.push(['tools/diagnostics/macos_source_alias_owner_test.py', 19]);
	cases.push(['tools/diagnostics/macos_listener_path_identity_test.py', 12]);
	cases.push(['tools/test/owned_suspended_image_portable_test.py', 3]);
	cases.push(['tools/diagnostics/macos_suspended_image_owner_test.py', 22]);
	cases.push(['tools/diagnostics/macos_ollama_bootstrap_owner_test.py', 22]);
	cases.push(['tools/diagnostics/macos_trusted_native_guardian_test.py', 10]);
	cases.push(['tools/diagnostics/macos_guardian_retirement_order_test.py', 6]);
	cases.push(['tools/diagnostics/macos_ollama_daemon_authority_test.py', 14]);
	cases.push(['tools/diagnostics/macos_managed_ollama_serve_test.py', 14]);
	cases.push(['tools/diagnostics/macos_ollama_daemon_authority_reader_test.py', 13]);
	cases.push(['tools/diagnostics/macos_native_wire_swift_dependencies_test.py', 7]);
	cases.push(['tools/test/managed_ollama_go_evidence_test.py', 31]);
} else {
	process.stdout.write(
		'SKIP actual POSIX process peers on Windows; Apple SDK receiving is separate.\n'
	);
}
for (const [script, expected] of cases) {
	const result = spawnSync(pythonExecutable(), [script], {
		cwd: path.resolve(__dirname, '../..'),
		encoding: 'utf8',
		timeout: 60000
	});
	assert.equal(result.error, undefined, 'the portable receiver must start');
	assert.equal(result.signal, null, 'the portable receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(result.stderr, new RegExp(`Ran ${expected} tests in`));
	assert.match(result.stderr, /\bOK\b/);
	assert.doesNotMatch(result.stderr, /skipped=/);
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
// These injected ports are portable receiving controls, not native process
// evidence. Keep their literal corpora registered alongside the Python owner.
// Hammerspoon owns these ports on Lua 5.4. LuaJIT cannot observe the fourth
// generic-for value closing a native directory, so it cannot qualify this owner.
const runtime = 'lua5.4';
const admission = spawnSync(runtime, ['-e', 'assert(_VERSION == "Lua 5.4")'], {
	encoding: 'utf8',
	timeout: 60000
});
assert.equal(admission.error, undefined, 'the macOS portable receiver requires Lua 5.4');
assert.equal(admission.signal, null, 'the Lua 5.4 admission must retire');
assert.equal(admission.status, 0, admission.stderr || admission.stdout);
for (const [script, expected] of [
	['tools/test/managed_ollama_pull_receipt_test.lua', 41],
	['tools/test/managed_ollama_pull_adapter_test.lua', 46],
	['tools/test/managed_native_python_test.lua', 8],
	['tools/test/managed_ollama_cleanup_receipt_test.lua', 102]
]) {
	const result = spawnSync(
		runtime,
		[path.resolve(__dirname, '../..', script), path.resolve(__dirname, '../..')],
		{
			cwd: path.resolve(__dirname, '../..'),
			encoding: 'utf8',
			timeout: 60000
		}
	);
	assert.equal(result.error, undefined, 'the injected Lua receiver must start');
	assert.equal(result.signal, null, 'the injected Lua receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(result.stdout, new RegExp(`controls passed: ${expected}\\s*$`));
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
// Keep real owner phase controls registered; their ports do not grant SDK credit.
for (const [script, expectedCases, expectedAssertions] of [
	['tools/test/managed_ollama_cleanup_owner_test.lua', 58, 780],
	['tools/test/managed_ollama_legacy_cleanup_test.lua', 8, 45]
]) {
	const result = spawnSync(
		runtime,
		[path.resolve(__dirname, '../..', script), path.resolve(__dirname, '../..')],
		{
			cwd: path.resolve(__dirname, '../..'),
			encoding: 'utf8',
			timeout: 60000
		}
	);
	assert.equal(result.error, undefined, 'the owned deletion receiver must start');
	assert.equal(result.signal, null, 'the owned deletion receiver must retire');
	assert.equal(result.status, 0, result.stderr || result.stdout);
	assert.match(
		result.stdout,
		new RegExp(`controls passed: ${expectedCases} cases / ${expectedAssertions} assertions\\s*$`)
	);
	process.stdout.write(result.stdout);
	process.stdout.write(result.stderr);
}
process.stdout.write(
	'Native Go/macOS build, signing, model exchange and SDK admission were not executed.\n'
);
