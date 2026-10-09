// tools/test/test-macos-native-pac-qualification.cjs
'use strict';

/** Constructed transcript and actual CLI controls; native Darwin remains unexecuted. */
module.exports = function run({ workflow, admitNativePacSelector, PAC_FILTER }) {
	const assert = require('node:assert/strict');
	const fs = require('node:fs');
	const os = require('node:os');
	const path = require('node:path');
	const { spawnSync } = require('node:child_process');
	const reader = require('../diagnostics/managed_http_pac_xctest_evidence.cjs');
	const full = require('../diagnostics/swift_xctest_evidence.cjs');
	const repository = path.resolve(__dirname, '../..');
	const classes = ['ManagedHTTPWorkerTests', 'ManagedHTTPWireTests', 'ManagedHTTPWPADWireTests'];
	const counts = [12, 1, 1];
	let passed = 0;
	const check = (label, action) => {
		action();
		passed++;
	};
	// The source definitions are the independent method oracle; the
	// newly authored reader's method table never generates its expected receipts.
	const definitions = classes.map((suite, index) => {
		const file = path.join(
			repository,
			'static',
			'ergopti_plus',
			'macos',
			'launcher',
			'Tests',
			'ErgoptiPlusTests',
			suite + '.swift'
		);
		const methods = [...fs.readFileSync(file, 'utf8').matchAll(/\bfunc (test\w+)\(/g)].map(
			(match) => match[1]
		);
		assert.equal(methods.length, counts[index]);
		return { suite, methods };
	});
	const summary = (count) =>
		` Executed ${count} tests, with 0 failures (0 unexpected) in 1.0 seconds`;
	const lines = [
		"Test Suite 'Selected tests' started at 2026-10-09 00:00:00.",
		"Test Suite 'ErgoptiPlusPackageTests.xctest' started at 2026-10-09 00:00:00."
	];
	for (const { suite, methods } of definitions) {
		lines.push(`Test Suite '${suite}' started at 2026-10-09 00:00:00.`);
		for (const method of methods) {
			lines.push(`Test Case '-[ErgoptiPlusTests.${suite} ${method}]' started.`);
			if (method === 'testActualCFNetworkHTTPPACArgumentShapeObservation')
				lines.push('PAC_ARGUMENT_SHAPE purpose=http port=20000');
			if (method === 'testActualCFNetworkHTTPSPACArgumentShapeObservation')
				lines.push('PAC_ARGUMENT_SHAPE purpose=https port=20000');
			lines.push(`Test Case '-[ErgoptiPlusTests.${suite} ${method}]' passed (0.001 seconds).`);
		}
		lines.push(`Test Suite '${suite}' passed at 2026-10-09 00:00:01.`, summary(methods.length));
	}
	lines.push(
		"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at 2026-10-09 00:00:01.",
		summary(14),
		"Test Suite 'Selected tests' passed at 2026-10-09 00:00:01.",
		summary(14)
	);
	const valid = lines.join('\n') + '\n';
	check('exact-original-twelve-and-two-observations', () =>
		assert.equal(reader.evaluate(valid, 0, 0).complete, true)
	);
	check('PTY-normalization', () =>
		assert.equal(
			reader.evaluate('\x1b[32m' + valid.replaceAll('\n', '\r\n') + '\x1b[0m', 0, 0).complete,
			true
		)
	);
	check('full-reader-refuses-selected', () =>
		assert.notEqual(full.evaluate(valid, 0, 0).exit_status, 0)
	);
	check('literal-full-url-control', () =>
		assert.ok(
			definitions[0].methods.includes('testActualCFNetworkPACReceivesDistinctHTTPSPathsAndQueries')
		)
	);
	const observations = [
		'testActualCFNetworkHTTPPACArgumentShapeObservation',
		'testActualCFNetworkHTTPSPACArgumentShapeObservation'
	];
	check('two-explicit-observations-preserve-original-twelve', () => {
		assert.equal(
			definitions[0].methods.filter((method) => !observations.includes(method)).length,
			10
		);
		for (const method of observations)
			assert.equal(definitions[0].methods.filter((actual) => actual === method).length, 1);
	});
	let originalOnly = valid;
	for (const method of observations) {
		const name = `-[ErgoptiPlusTests.ManagedHTTPWorkerTests ${method}]`;
		const purpose =
			method === 'testActualCFNetworkHTTPPACArgumentShapeObservation' ? 'http' : 'https';
		const observationPair = `Test Case '${name}' started.\nPAC_ARGUMENT_SHAPE purpose=${purpose} port=20000\nTest Case '${name}' passed (0.001 seconds).\n`;
		assert.ok(valid.includes(observationPair));
		check('missing-observation-' + method, () =>
			assert.equal(reader.evaluate(valid.replace(observationPair, ''), 0, 0).complete, false)
		);
		check('failed-observation-' + method, () =>
			assert.equal(
				reader.evaluate(
					valid.replace(`Test Case '${name}' passed`, `Test Case '${name}' failed`),
					0,
					0
				).complete,
				false
			)
		);
		check('skipped-observation-' + method, () =>
			assert.equal(
				reader.evaluate(
					valid.replace(`Test Case '${name}' passed`, `Test Case '${name}' skipped`),
					0,
					0
				).complete,
				false
			)
		);
		originalOnly = originalOnly.replace(observationPair, '');
	}
	originalOnly = originalOnly
		.replace(summary(12), summary(10))
		.replaceAll(summary(14), summary(12));
	check('original-twelve-alone-cannot-qualify-fourteen', () => {
		const verdict = reader.evaluate(originalOnly, 0, 0);
		assert.equal(verdict.complete, false);
		assert.equal(verdict.observed, 12);
		assert.equal(verdict.expected, 14);
	});
	const httpReceipt = 'PAC_ARGUMENT_SHAPE purpose=http port=20000\n';
	const httpsReceipt = 'PAC_ARGUMENT_SHAPE purpose=https port=20000\n';
	check('fixed-receipt-ports', () =>
		assert.deepEqual(reader.evaluate(valid, 0, 0).argument_observations, {
			http: 20000,
			https: 20000
		})
	);
	check('other-closed-shape-does-not-waive-original-tests', () =>
		assert.equal(reader.evaluate(valid.replaceAll('port=20000', 'port=20075'), 0, 0).complete, true)
	);
	check('buffered-receipts-do-not-invent-delivery-order', () =>
		assert.equal(
			reader.evaluate(
				valid.replace(httpReceipt, '').replace(httpsReceipt, '') + httpsReceipt + httpReceipt,
				0,
				0
			).complete,
			true
		)
	);
	for (const [label, bad] of [
		['missing-http-receipt', valid.replace(httpReceipt, '')],
		['missing-https-receipt', valid.replace(httpsReceipt, '')],
		['duplicate-receipt', valid + httpReceipt],
		['foreign-purpose', valid.replace('purpose=http ', 'purpose=ftp ')],
		['unused-codebook-slot', valid.replace('port=20000', 'port=20009')],
		[
			'trailing-receipt-data',
			valid.replace('purpose=http port=20000', 'purpose=http port=20000 extra=unadmitted')
		],
		[
			'raw-value-receipt',
			valid.replace('purpose=http port=20000', 'purpose=http port=http://same.example/a')
		]
	])
		check(label, () => assert.equal(reader.evaluate(bad, 0, 0).complete, false));
	for (const method of [
		'testActualCFNetworkPACReceivesDistinctHTTPSPathsAndQueries',
		'testActualCFNetworkPACPreservesHTTPPathAndOrderedNativeChoices'
	])
		check('original-full-url-failure-remains-failure-' + method, () =>
			assert.equal(
				reader.evaluate(
					valid.replace(
						`Test Case '-[ErgoptiPlusTests.ManagedHTTPWorkerTests ${method}]' passed`,
						`Test Case '-[ErgoptiPlusTests.ManagedHTTPWorkerTests ${method}]' failed`
					),
					0,
					0
				).complete,
				false
			)
		);
	const narrative = valid.replace(httpReceipt, '').replace(httpsReceipt, '');
	const narrativeLines = narrative.trimEnd().split('\n');
	const summaryPositions = narrativeLines.flatMap((line, index) =>
		/^\s*Executed /.test(line) ? [index] : []
	);
	assert.equal(summaryPositions.length, 5);
	for (const position of summaryPositions) {
		const placed = [...narrativeLines];
		placed.splice(position, 0, httpReceipt.trimEnd(), httpsReceipt.trimEnd());
		check('observations-before-summary-' + position, () =>
			assert.equal(reader.evaluate(placed.join('\n') + '\n', 0, 0).complete, true)
		);
	}
	for (const [label, placed] of [
		['before-root', httpReceipt + httpsReceipt + narrative],
		['after-root', narrative + httpReceipt + httpsReceipt],
		[
			'between-cases',
			narrative.replace(
				'passed (0.001 seconds).\n',
				'passed (0.001 seconds).\n' + httpReceipt + httpsReceipt
			)
		]
	])
		check('observations-' + label, () =>
			assert.equal(reader.evaluate(placed, 0, 0).complete, true)
		);
	check('foreign-prefix-observation-refused', () =>
		assert.equal(reader.evaluate(valid + 'FOREIGN ' + httpReceipt, 0, 0).complete, false)
	);
	const first = `-[ErgoptiPlusTests.${definitions[0].suite} ${definitions[0].methods[0]}]`;
	const second = `-[ErgoptiPlusTests.${definitions[0].suite} ${definitions[0].methods[1]}]`;
	const pair = `Test Case '${first}' started.\nTest Case '${first}' passed (0.001 seconds).\n`;
	for (const [label, bad] of [
		['partial', valid.slice(0, valid.lastIndexOf("Test Suite 'Selected tests' passed"))],
		['missing', valid.replace(pair, '')],
		[
			'foreign-same-count',
			valid.replaceAll(first, '-[ErgoptiPlusTests.ManagedHTTPWorkerTests testForeign]')
		],
		[
			'duplicate-start',
			valid.replace(
				`Test Case '${first}' started.`,
				`Test Case '${first}' started.\nTest Case '${first}' started.`
			)
		],
		[
			'overlapping-start',
			valid
				.replace(
					`Test Case '${first}' started.`,
					`Test Case '${first}' started.\nTest Case '${second}' started.`
				)
				.replace(
					`Test Case '${second}' started.\nTest Case '${second}' passed`,
					`Test Case '${second}' passed`
				)
		],
		['failed', valid.replace(`Test Case '${first}' passed`, `Test Case '${first}' failed`)],
		['skipped', valid.replace(`Test Case '${first}' passed`, `Test Case '${first}' skipped`)],
		['wrong-class-count', valid.replace(summary(12), summary(11))],
		['wrong-bundle-count', valid.replace(summary(14), summary(13))],
		['wrong-root-count', valid.slice(0, valid.lastIndexOf(summary(14))) + summary(13) + '\n'],
		['wrong-root', valid.replaceAll("'Selected tests'", "'All tests'")],
		['duplicate-root', valid + valid],
		['extra-summary', valid + summary(14) + '\n'],
		['noncanonical-count', valid.replace('Executed 12 tests', 'Executed 012 tests')],
		['foreign-bundle', valid.replaceAll('ErgoptiPlusPackageTests.xctest', 'Foreign.xctest')],
		[
			'wrong-suite',
			valid.replace(
				"Test Suite 'ManagedHTTPWireTests' passed",
				"Test Suite 'ManagedHTTPWireTests' failed"
			)
		],
		['malformed-terminal', valid.replace('passed (0.001 seconds).', 'passed (private).')],
		['compile-error', 'error: compilation failed\n' + valid],
		[
			'summary-skip',
			valid.replace(
				summary(12),
				' Executed 12 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 seconds'
			)
		],
		['before-root', pair + valid.replace(pair, '')],
		['after-root', valid.replace(pair, '') + pair]
	])
		check(label, () => assert.equal(reader.evaluate(bad, 0, 0).complete, false));
	check('swift-status-preserved', () => {
		const r = reader.evaluate(valid, 73, 0);
		assert.equal(r.complete, false);
		assert.equal(r.exit_status, 73);
	});
	check('tee-status-preserved', () => {
		const r = reader.evaluate(valid, 0, 9);
		assert.equal(r.complete, false);
		assert.equal(r.exit_status, 9);
	});
	check('status-lexical', () => assert.throws(() => reader.evaluate(valid, '00', 0)));
	check('status-range', () => assert.throws(() => reader.evaluate(valid, 256, 0)));
	check('exact-selector-admitted', () => assert.ok(admitNativePacSelector(workflow)));
	for (const [label, token, replacement] of [
		['wrong-filter', PAC_FILTER, "--filter 'ManagedHTTPWorkerTests'"],
		['foreign-job', '  managed-ollama-native:\n', '  unrelated-native:\n'],
		[
			'foreign-step',
			'      - name: Qualify actual native PAC and WPAD XCTest controls\n',
			'      - name: Foreign controls\n'
		],
		[
			'implicit-success-gate',
			'      - name: Qualify actual native PAC and WPAD XCTest controls\n        if: ${{ !cancelled() }}\n',
			'      - name: Qualify actual native PAC and WPAD XCTest controls\n'
		],
		[
			'forgiven-step',
			'      - name: Qualify actual native PAC and WPAD XCTest controls\n',
			'      - name: Qualify actual native PAC and WPAD XCTest controls\n        continue-on-error: true\n'
		],
		['lost-swift-status', '"${pac_statuses[0]}"', '"0"'],
		['lost-tee-status', '"${pac_statuses[1]}"', '"0"'],
		['not-actual-owner', 'pac_statuses=("${PIPESTATUS[@]}")', 'pac_statuses=(0 0)'],
		['wrong-reader', 'managed_http_pac_xctest_evidence.cjs', 'swift_xctest_evidence.cjs'],
		[
			'changed-deadline',
			'native-pac-verdict.json"\n        timeout-minutes: 10',
			'native-pac-verdict.json"\n        timeout-minutes: 20'
		]
	])
		check(label, () => {
			assert.ok(workflow.includes(token));
			assert.equal(admitNativePacSelector(workflow.replace(token, replacement)), null);
		});
	const nativeStep = workflow.match(
		/^      - name: Qualify actual native PAC and WPAD XCTest controls\n[\s\S]*?(?=^      - )/m
	)[0];
	check('before-sdk-refused', () => {
		const changed = workflow
			.replace(nativeStep, '')
			.replace(
				'      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n',
				nativeStep +
					'      - name: Qualify actual SDK accepted-owner and deadline XCTest controls\n'
			);
		assert.equal(admitNativePacSelector(changed), null);
	});
	check('duplicate-selector-refused', () =>
		assert.equal(admitNativePacSelector(workflow + nativeStep), null)
	);
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-pac-reader-'));
	try {
		const transcript = path.join(temporary, 'transcript.log'),
			verdict = path.join(temporary, 'verdict.json');
		const script = path.resolve(__dirname, '../diagnostics/managed_http_pac_xctest_evidence.cjs');
		fs.writeFileSync(transcript, valid);
		for (const [label, swift, tee, expected] of [
			['CLI-success', '0', '0', 0],
			['CLI-swift', '73', '0', 73],
			['CLI-capture', '0', '9', 9]
		])
			check(label, () => {
				const actual = spawnSync(process.execPath, [script, transcript, swift, tee, verdict], {
					encoding: 'utf8'
				});
				assert.equal(actual.status, expected);
				const result = JSON.parse(fs.readFileSync(verdict, 'utf8'));
				assert.equal(result.exit_status, expected);
				assert.equal(result.complete, expected === 0);
				assert.deepEqual(Object.keys(result), [
					'schema',
					'cohort',
					'expected',
					'argument_observations',
					'observed',
					'complete',
					'swift_status',
					'capture_status',
					'errors',
					'exit_status'
				]);
			});
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
	assert.equal(passed, 74);
	console.log(
		'PASS: native PAC/WPAD selected-cohort portable controls=74; actual Darwin/native14 execution UNRUN.'
	);
};
// A normal suite entry executes the complete owning source guard, which invokes
// this module after defining its exact selector. There is no import-only waiver.
if (require.main === module) require('./test-macos-dev-qualification-deferral.cjs');
