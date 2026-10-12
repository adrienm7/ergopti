// tools/test/test-macos-managed-bootstrap-http.cjs

/** Receive actual pinned bootstrap publication and redirect controls. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

// Generated authority checks are portable, including Windows.
function receiveNativeHTTPFailureStages() {
	// tools/test/test-native-http-failure-stages.cjs
	// Independent closed protocol inventory and deterministic span repair.
	'use strict';
	const assert = require('node:assert/strict');
	const fs = require('node:fs');
	const path = require('node:path');
	const ROOT = path.resolve(__dirname, '../..');
	const { render, rewrite, OUTPUTS } = require('../codegen/codegen-native-http-failure-stages.cjs');
	const authority = fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/modules/network/native_http_failure_stages.json')
	);
	const expected = [
		['policyLoad', 'native_policy_load', ['unavailable']],
		['selectionBound', 'native_selection_bound', ['unavailable']],
		['proxyLookup', 'native_proxy_lookup', ['unavailable']],
		['proxyDictionary', 'native_proxy_dictionary', ['proxy']],
		['routeEmpty', 'native_route_empty', ['unavailable']],
		['certificateLoad', 'native_certificate_load', ['certificate']],
		['lookupDeadline', 'native_lookup_deadline', ['deadline']],
		['dispatchDeadline', 'native_dispatch_deadline', ['deadline']],
		[
			'sessionTerminal',
			'native_session_terminal',
			[
				'deadline',
				'cancelled',
				'offline',
				'certificate',
				'proxy',
				'connect',
				'unavailable',
				'protocol',
				'content_encoding'
			]
		]
	];
	let checks = 0;
	function check(name, callback) {
		callback();
		checks += 1;
		process.stdout.write(`PASS ${name}\n`);
	}
	check('one independent nine-stage vocabulary with exact reason pairs', () => {
		const rows = JSON.parse(authority).stages;
		assert.deepEqual(
			rows.map((row) => [row.symbol, row.code, row.reasons]),
			expected
		);
	});
	const rendered = render(authority);
	for (const [name, relative] of Object.entries(OUTPUTS)) {
		const actual = fs.readFileSync(path.join(ROOT, relative), 'utf8');
		check(`${name} actual generated span is current`, () => {
			assert.equal(rewrite(actual, name, rendered[name]), actual);
		});
		check(`${name} damaged stage repairs deterministically without changing owner body`, () => {
			const damaged = actual.replace('native_policy_load', 'native_unapproved_private_stage');
			assert.notEqual(damaged, actual);
			assert.equal(rewrite(damaged, name, rendered[name]), actual);
		});
		check(`${name} missing duplicated or reversed generation boundaries refuse`, () => {
			assert.throws(() =>
				rewrite('original source without generated stages', name, rendered[name])
			);
			const comment = name === 'python' ? '#' : '//';
			const begin = `${comment} BEGIN GENERATED NATIVE HTTP FAILURE STAGES\n`;
			const end = `${comment} END GENERATED NATIVE HTTP FAILURE STAGES\n`;
			assert.throws(() => rewrite(begin + actual, name, rendered[name]));
			assert.throws(() => rewrite(end + begin, name, rendered[name]));
		});
	}
	const mutate = (callback) => {
		const value = JSON.parse(authority);
		callback(value);
		return Buffer.from(JSON.stringify(value));
	};
	for (const [name, payload] of [
		[
			'duplicate top-level field',
			Buffer.from(
				authority
					.toString()
					.replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1')
			)
		],
		[
			'escaped duplicate field',
			Buffer.from(
				authority
					.toString()
					.replace('"schema_version": 1', '"schema_version": 1, "schema_versi\\u006fn": 1')
			)
		],
		['non-UTF8 input', Buffer.from([0xff])],
		['repeated stage', mutate((value) => value.stages.push(value.stages[0]))],
		[
			'successful reason in failed vocabulary',
			mutate((value) => (value.stages[0].reasons = ['complete']))
		],
		['non-string symbol', mutate((value) => (value.stages[0].symbol = true))],
		['unknown row field', mutate((value) => (value.stages[0].rawException = 'private-secret'))],
		[
			'repeated reason',
			mutate((value) => (value.stages[0].reasons = ['unavailable', 'unavailable']))
		]
	])
		check(`closed authority rejects ${name}`, () => assert.throws(() => render(payload)));
	process.stdout.write(`${checks} passed, 0 failed\n`);
}
receiveNativeHTTPFailureStages();

if (process.platform === 'win32') {
	console.log(
		'[DEFERRED] POSIX exclusive bootstrap publication runs in Core / js on Ubuntu and native macOS CI; not executed on Windows.'
	);
	process.exit(0);
}
const result = spawnSync(pythonExecutable(), ['tools/test/macos_managed_bootstrap_http_test.py'], {
	cwd: path.resolve(__dirname, '../..'),
	encoding: 'utf8',
	timeout: 60000
});
assert.equal(result.error, undefined, 'the bootstrap receiver must start');
assert.equal(result.signal, null, 'the bootstrap receiver must close within its bound');
assert.equal(result.status, 0, result.stderr || result.stdout);
assert.match(result.stderr, /Ran 25 tests in/);
assert.match(result.stderr, /\bOK\b/);
assert.doesNotMatch(result.stderr, /skipped=/);
process.stdout.write(result.stdout);
process.stdout.write(result.stderr);

const coldReceipt = spawnSync(
	pythonExecutable(),
	['tools/diagnostics/macos_cold_bootstrap_test.py'],
	{ cwd: path.resolve(__dirname, '../..'), encoding: 'utf8', timeout: 30000 }
);
assert.equal(coldReceipt.error, undefined, 'the independent cold receipt receiver must start');
assert.equal(coldReceipt.signal, null, 'the independent cold receipt receiver must retire');
assert.equal(coldReceipt.status, 0, coldReceipt.stderr || coldReceipt.stdout);
assert.match(coldReceipt.stderr, /Ran 12 tests in/);
assert.match(coldReceipt.stderr, /\bOK\b/);
assert.doesNotMatch(coldReceipt.stderr, /skipped=/);
process.stdout.write(coldReceipt.stdout);
process.stdout.write(coldReceipt.stderr);

const officialColdReceipt = spawnSync(
	pythonExecutable(),
	['tools/diagnostics/macos_cold_ollama_bootstrap_test.py'],
	{ cwd: path.resolve(__dirname, '../..'), encoding: 'utf8', timeout: 30000 }
);
assert.equal(officialColdReceipt.error, undefined, 'the official cold receipt receiver must start');
assert.equal(officialColdReceipt.signal, null, 'the official cold receipt receiver must retire');
assert.equal(
	officialColdReceipt.status,
	0,
	officialColdReceipt.stderr || officialColdReceipt.stdout
);
assert.match(officialColdReceipt.stderr, /Ran 35 tests in/);
assert.match(officialColdReceipt.stderr, /\bOK\b/);
assert.doesNotMatch(officialColdReceipt.stderr, /skipped=/);
process.stdout.write(officialColdReceipt.stdout);
process.stdout.write(officialColdReceipt.stderr);

const archiveModes = spawnSync(
	pythonExecutable(),
	['tools/test/macos_official_ollama_archive_modes_test.py'],
	{ cwd: path.resolve(__dirname, '../..'), encoding: 'utf8', timeout: 30000 }
);
assert.equal(archiveModes.error, undefined, 'the actual archive mode receiver must start');
assert.equal(archiveModes.signal, null, 'the actual archive mode receiver must retire');
assert.equal(archiveModes.status, 0, archiveModes.stderr || archiveModes.stdout);
assert.match(archiveModes.stderr, /Ran 4 tests in/);
assert.match(archiveModes.stderr, /\bOK\b/);
assert.doesNotMatch(archiveModes.stderr, /skipped=/);
process.stdout.write(archiveModes.stdout);
process.stdout.write(archiveModes.stderr);

const failureStages = spawnSync(
	pythonExecutable(),
	['tools/test/macos_native_http_failure_stage_test.py'],
	{ cwd: path.resolve(__dirname, '../..'), encoding: 'utf8', timeout: 30000 }
);
assert.equal(failureStages.error, undefined, 'the failed-frame stage receiver must start');
assert.equal(failureStages.signal, null, 'the failed-frame stage receiver must retire');
assert.equal(failureStages.status, 0, failureStages.stderr || failureStages.stdout);
assert.match(failureStages.stderr, /Ran 6 tests in/);
assert.match(failureStages.stderr, /\bOK\b/);
assert.doesNotMatch(failureStages.stderr, /skipped=/);
process.stdout.write(failureStages.stdout);
process.stdout.write(failureStages.stderr);
