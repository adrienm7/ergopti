// tools/test/test-item36-native-qualification.cjs
'use strict';

/** Independent constructed transcript and real Git/file controls; no Darwin credit. */
module.exports = function run({ workflow, admitItem36Selector, ITEM36_FILTER }) {
	const assert = require('node:assert/strict');
	const fs = require('node:fs');
	const os = require('node:os');
	const path = require('node:path');
	const { execFileSync } = require('node:child_process');
	const reader = require('../diagnostics/item36_xctest_evidence.cjs');
	const full = require('../diagnostics/swift_xctest_evidence.cjs');
	const repository = path.resolve(__dirname, '../..');
	const classes = [
		'ReleaseArchiveStagingTests',
		'SparkleArchiveUpdateAcceptanceTests',
		'HomebrewArchiveAcceptanceTests',
		'HomebrewAutomationConsentTests'
	];
	const counts = [8, 15, 1, 1];
	let passed = 0;
	const check = (label, action) => {
		action();
		passed++;
	};
	// The oracle is the unchanged independent existing Swift test definitions,
	// with fixed class/census boundaries, never the new reader's method table.
	const definitions = classes.map((suite, index) => {
		const relative = `static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${suite}.swift`;
		const bytes = fs.readFileSync(path.join(repository, relative));
		const methods = [...bytes.toString('utf8').matchAll(/\bfunc (test\w+)\(/g)].map(
			(match) => match[1]
		);
		assert.equal(methods.length, counts[index]);
		return { suite, relative, bytes, methods };
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
			lines.push(`Test Case '-[ErgoptiPlusTests.${suite} ${method}]' passed (0.001 seconds).`);
		}
		lines.push(`Test Suite '${suite}' passed at 2026-10-09 00:00:01.`, summary(methods.length));
	}
	lines.push(
		"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at 2026-10-09 00:00:01.",
		summary(25),
		"Test Suite 'Selected tests' passed at 2026-10-09 00:00:01.",
		summary(25)
	);
	const valid = lines.join('\n') + '\n';
	check('exact-independent-25', () => assert.equal(reader.evaluate(valid, 0, 0).complete, true));
	check('PTY-normalization', () =>
		assert.equal(
			reader.evaluate('\x1b[32m' + valid.replaceAll('\n', '\r\n') + '\x1b[0m', 0, 0).complete,
			true
		)
	);
	check('full-reporter-still-refuses-filtered', () =>
		assert.notEqual(full.evaluate(valid, 0, 0).exit_status, 0)
	);
	const signalMethod = 'testSignaledOwnedChildProvidesTerminalCapturesWithoutAdmittingFinish';
	const signalName = `-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests ${signalMethod}]`;
	const signalOpening = `Test Case '${signalName}' started.`;
	const signalTerminal = `Test Case '${signalName}' passed (0.001 seconds).`;
	check('independent-new-signal-identity', () =>
		assert.equal(definitions[1].methods.filter((method) => method === signalMethod).length, 1)
	);
	const stale = valid
		.replace(`${signalOpening}\n${signalTerminal}\n`, '')
		.replace(summary(15), summary(14))
		.replaceAll(summary(25), summary(24));
	for (const [label, bad] of [
		['stale-independent-24', stale],
		['new-signal-missing', valid.replace(`${signalOpening}\n${signalTerminal}\n`, '')],
		['new-signal-duplicate', valid.replace(signalOpening, `${signalOpening}\n${signalOpening}`)],
		[
			'new-signal-failed',
			valid.replace(signalTerminal, signalTerminal.replace(' passed ', ' failed '))
		],
		[
			'new-signal-skipped',
			valid.replace(signalTerminal, signalTerminal.replace(' passed ', ' skipped '))
		],
		[
			'new-signal-foreign-same-count',
			valid.replaceAll(
				signalName,
				'-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testForeignSignal]'
			)
		]
	])
		check(label, () => assert.equal(reader.evaluate(bad, 0, 0).complete, false));
	const firstName = `-[ErgoptiPlusTests.${definitions[0].suite} ${definitions[0].methods[0]}]`;
	for (const [label, bad] of [
		['partial', valid.slice(0, valid.lastIndexOf("Test Suite 'Selected tests' passed"))],
		[
			'missing-method',
			valid.replace(
				`Test Case '${firstName}' started.\nTest Case '${firstName}' passed (0.001 seconds).\n`,
				''
			)
		],
		[
			'duplicate-method',
			valid.replace(
				`Test Case '${firstName}' started.`,
				`Test Case '${firstName}' started.\nTest Case '${firstName}' started.`
			)
		],
		[
			'foreign-same-count',
			valid.replaceAll(firstName, '-[ErgoptiPlusTests.ReleaseArchiveStagingTests testForeign]')
		],
		['wrong-case', valid.replaceAll(firstName, firstName.replace('testBoth', 'testboth'))],
		[
			'failed-case',
			valid.replace(`Test Case '${firstName}' passed`, `Test Case '${firstName}' failed`)
		],
		[
			'skipped-case',
			valid.replace(`Test Case '${firstName}' passed`, `Test Case '${firstName}' skipped`)
		],
		['wrong-class-census', valid.replace(summary(8), summary(7))],
		['wrong-bundle-census', valid.replace(summary(25), summary(24))],
		['wrong-root-census', valid.slice(0, valid.lastIndexOf(summary(25))) + summary(24) + '\n'],
		['wrong-root', valid.replaceAll("'Selected tests'", "'All tests'")],
		['foreign-bundle', valid.replaceAll('ErgoptiPlusPackageTests.xctest', 'Foreign.xctest')],
		[
			'missing-bundle',
			valid
				.split('\n')
				.filter((line) => !line.includes('ErgoptiPlusPackageTests.xctest'))
				.join('\n')
		],
		['duplicate-root', valid + valid],
		[
			'class-not-passed',
			valid.replace(
				"Test Suite 'HomebrewArchiveAcceptanceTests' passed",
				"Test Suite 'HomebrewArchiveAcceptanceTests' failed"
			)
		],
		['malformed-terminal', valid.replace('passed (0.001 seconds).', 'passed (private).')],
		['actual-error-diagnostic', 'error: source compile failed\n' + valid],
		[
			'summary-skip',
			valid.replace(
				summary(8),
				' Executed 8 tests, with 1 test skipped and 0 failures (0 unexpected) in 1.0 seconds'
			)
		]
	])
		check(label, () => assert.equal(reader.evaluate(bad, 0, 0).complete, false));
	check('script-refused', () => assert.equal(reader.evaluate(valid, 1, 0).complete, false));
	check('tee-refused', () => assert.equal(reader.evaluate(valid, 0, 1).complete, false));
	check('status-lexical', () => assert.throws(() => reader.evaluate(valid, '00', 0)));
	check('status-range', () => assert.throws(() => reader.evaluate(valid, 256, 0)));
	check('scoped-filter-admitted', () => assert.ok(admitItem36Selector(workflow)));
	for (const [label, token, replacement] of [
		['wrong-filter', ITEM36_FILTER, "--filter 'HomebrewArchiveAcceptanceTests'"],
		['foreign-job', '  item36-native:\n', '  unrelated-native:\n'],
		[
			'foreign-step',
			'      - name: Qualify scoped item 36 native archive XCTest controls\n',
			'      - name: Unrelated native tests\n'
		],
		['coupled-job', '  item36-native:\n', '  item36-native:\n    needs: package-macos\n'],
		[
			'release-admission',
			"    if: ${{ github.event_name == 'workflow_dispatch' && !inputs.release }}",
			'    if: always()'
		],
		['forgiven-job', '  item36-native:\n', '  item36-native:\n    continue-on-error: true\n'],
		[
			'publish-output',
			'  item36-native:\n',
			'  item36-native:\n    outputs:\n      assets: foreign\n'
		],
		['lost-source-begin', 'item36_xctest_evidence.cjs begin', 'item36_xctest_evidence.cjs fake'],
		['lost-tee-status', '"${item36_statuses[1]}"', '"0"'],
		['reset-source', 'begin "$GITHUB_SHA"', 'begin "fake"'],
		[
			'lost-consent',
			"ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI: '1'",
			"ERGOPTI_BREW_ALLOW_OWNED_CONSENT_UI: '0'"
		],
		[
			'filtered-package',
			'--scratch-path "$RUNNER_TEMP/swift-launcher-ci" 2>&1 | tee "$xctest_log"',
			'--scratch-path "$RUNNER_TEMP/swift-launcher-ci" --filter Other 2>&1 | tee "$xctest_log"'
		]
	])
		check(label, () => {
			assert.ok(workflow.includes(token));
			assert.equal(admitItem36Selector(workflow.replace(token, replacement)), null);
		});
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-item36-reader-'));
	try {
		const git = (args) =>
			execFileSync('git', args, {
				cwd: temporary,
				encoding: 'utf8',
				stdio: ['ignore', 'pipe', 'pipe']
			});
		for (const { relative, bytes } of definitions) {
			const file = path.join(temporary, relative);
			fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(file, bytes);
		}
		git(['init', '--quiet']);
		git(['add', '--', 'static/ergopti_plus/macos/launcher']);
		git([
			'-c',
			'user.name=Item36 control',
			'-c',
			'user.email=item36-control@example.invalid',
			'commit',
			'--quiet',
			'-m',
			'Independent source receipt control'
		]);
		const candidate = git(['rev-parse', 'HEAD']).trim();
		let before;
		check('real-Git-source-binding', () => {
			before = reader.sourceReceipt(temporary, candidate);
			assert.equal(before.candidate, candidate);
			assert.equal(Object.keys(before.sources).length, 4);
		});
		check('foreign-candidate-refused', () =>
			assert.throws(() => reader.sourceReceipt(temporary, '0'.repeat(40)))
		);
		const changed = path.join(temporary, definitions[0].relative);
		fs.appendFileSync(changed, '\n// foreign edit\n');
		check('real-tracked-source-change-refused', () =>
			assert.throws(() => reader.sourceReceipt(temporary, candidate))
		);
		fs.writeFileSync(changed, definitions[0].bytes);
		check('same-original-source-restored', () =>
			assert.deepEqual(reader.sourceReceipt(temporary, candidate), before)
		);
		const launcher = 'static/ergopti_plus/macos/launcher';
		for (const [label, relative, ignored] of [
			['untracked-Swift-source-refused', `${launcher}/Sources/ErgoptiPlus/Unbound.swift`, false],
			['ignored-Swift-source-refused', `${launcher}/Sources/ErgoptiPlus/Ignored.swift`, true],
			[
				'untracked-C-header-refused',
				`${launcher}/Sources/CPOSIXCompatibility/include/unbound.h`,
				false
			],
			['ignored-C-source-refused', `${launcher}/Sources/CPOSIXCompatibility/ignored.c`, true],
			['ignored-Swift-test-refused', `${launcher}/Tests/ErgoptiPlusTests/IgnoredTests.swift`, true],
			['untracked-alternate-manifest-refused', `${launcher}/Package@swift-6.0.swift`, false],
			['ignored-alternate-manifest-refused', `${launcher}/Package@swift-6.1.swift`, true]
		])
			check(label, () => {
				const file = path.join(temporary, relative);
				fs.mkdirSync(path.dirname(file), { recursive: true });
				fs.writeFileSync(file, '// Independent unbound compile input.\n');
				if (ignored) {
					fs.appendFileSync(path.join(temporary, '.git/info/exclude'), `/${relative}\n`);
					assert.equal(git(['check-ignore', '--', relative]).trim(), relative);
				}
				try {
					assert.throws(() => reader.sourceReceipt(temporary, candidate), /unbound compiler input/);
				} finally {
					fs.unlinkSync(file);
				}
				assert.deepEqual(reader.sourceReceipt(temporary, candidate), before);
			});
		check('ignored-interpreter-and-external-cache-permitted', () => {
			const caches = [
				'tools/diagnostics/__pycache__/owned.cpython-313.pyc',
				'runner-temp/swift-launcher-ci/cache.o'
			];
			for (const relative of caches) {
				fs.appendFileSync(path.join(temporary, '.git/info/exclude'), `/${relative}\n`);
				const file = path.join(temporary, relative);
				fs.mkdirSync(path.dirname(file), { recursive: true });
				fs.writeFileSync(file, 'Independent harmless cache\n');
				assert.equal(git(['check-ignore', '--', relative]).trim(), relative);
			}
			assert.deepEqual(reader.sourceReceipt(temporary, candidate), before);
		});
		const capture = path.join(temporary, 'capture.log');
		fs.writeFileSync(capture, valid);
		const source = path.join(temporary, 'before.json'),
			verdict = path.join(temporary, 'verdict.json');
		const originalLog = console.log,
			originalError = console.error;
		console.log = () => {};
		console.error = () => {};
		try {
			check('real-CLI-source-begin', () =>
				assert.equal(reader.main(['begin', candidate, source], temporary), 0)
			);
			check('real-CLI-existing-source-refused', () =>
				assert.equal(reader.main(['begin', candidate, source], temporary), 1)
			);
			check('real-CLI-constructed-scoped-result', () => {
				assert.equal(
					reader.main(['judge', capture, '0', '0', candidate, source, verdict], temporary),
					0
				);
				const receipt = JSON.parse(fs.readFileSync(verdict, 'utf8'));
				assert.equal(receipt.complete, true);
				assert.equal(receipt.full_package_qualified, false);
			});
			check('real-CLI-nonzero-capture-refused', () =>
				assert.equal(
					reader.main(
						['judge', capture, '0', '1', candidate, source, path.join(temporary, 'bad.json')],
						temporary
					),
					1
				)
			);
			check('real-CLI-foreign-candidate-refused', () =>
				assert.equal(
					reader.main(
						[
							'judge',
							capture,
							'0',
							'0',
							'0'.repeat(40),
							source,
							path.join(temporary, 'foreign.json')
						],
						temporary
					),
					1
				)
			);
			fs.writeFileSync(source, JSON.stringify({ ...before, scope: 'full-package' }));
			check('real-CLI-foreign-source-scope-refused', () =>
				assert.equal(
					reader.main(
						['judge', capture, '0', '0', candidate, source, path.join(temporary, 'scope.json')],
						temporary
					),
					1
				)
			);
			fs.writeFileSync(source, JSON.stringify(before));
			const link = path.join(temporary, 'capture-link');
			fs.symlinkSync(capture, link);
			check('real-CLI-symlink-capture-refused', () =>
				assert.equal(
					reader.main(
						['judge', link, '0', '0', candidate, source, path.join(temporary, 'link.json')],
						temporary
					),
					1
				)
			);
			fs.writeFileSync(capture, Buffer.from([0xff]));
			check('real-CLI-invalid-UTF8-refused', () =>
				assert.equal(
					reader.main(
						['judge', capture, '0', '0', candidate, source, path.join(temporary, 'utf8.json')],
						temporary
					),
					1
				)
			);
		} finally {
			console.log = originalLog;
			console.error = originalError;
		}
	} finally {
		fs.rmSync(temporary, { recursive: true });
	}
	console.log(
		`PASS: item36 scoped constructed/source controls=${passed}; Darwin/native execution UNRUN; full_package_qualified=false.`
	);
};

// The registered CLI loads the existing qualification owner, which receives
// this cached export and runs every scoped control exactly once.
if (require.main === module) require('./test-macos-dev-qualification-deferral.cjs');
