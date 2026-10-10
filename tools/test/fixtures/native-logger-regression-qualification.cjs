// tools/test/fixtures/native-logger-regression-qualification.cjs
'use strict';

/** Constructed receipt and genuine isolated Git/CLI controls; no native Darwin credit. */
module.exports = function run({
	workflow,
	admitNativeSdkSelector,
	LOGGER_42_FILTER,
	LOGGER_42_BLOCK,
	nativeSevenTranscript
}) {
	const assert = require('node:assert/strict');
	const fs = require('node:fs');
	const os = require('node:os');
	const path = require('node:path');
	const { execFileSync, spawnSync } = require('node:child_process');
	const repository = path.resolve(__dirname, '../../..');
	const reader = require('../../diagnostics/native_logger_regression_xctest_evidence.cjs');
	const seven = require('../../diagnostics/native_daemon_log_xctest_evidence.cjs');
	const expected = {
		LoggerDatagramWorkerTests: [
			'testAcceptedRecordFansOutOnceAndDuplicateOnlyAcknowledges',
			'testBatchValidatesEveryRecordBeforeWritingAndAcknowledgesTheFinalSequence',
			'testBatchRetrySkipsTheDurablePrefixAndResumesAtExpectedSequence',
			'testBatchBoundsAndContiguityRejectBeforeAnyWrite',
			'testGapAndStaleSessionCannotWriteWhileNewSessionRestartsAtOne',
			'testDelayedOldConfigureCannotRollBackTheActiveReloadSession',
			'testFreshLauncherAcceptsPersistedPreviousSessionFromPriorProcess',
			'testWrongTokenAndNonLoopbackSourceReceiveNoProtocolOracle',
			'testConfigureRefusalEchoesTheAuthenticatedRequestSession',
			'testMalformedDateAndTopicCannotEscapeOrMutateAnySink',
			'testNULInDiagnosticIsEscapedWithoutBlockingTheSequenceQueue',
			'testRetryAfterPartialFanoutDoesNotDuplicateCompletedFiles',
			'testShortWriteRollbackLeavesOneRecordInEverySink',
			'testFailedShortWriteRollbackRetainsDebtBeforeRetry',
			'testFailedRollbackSynchronizationRetainsDebtBeforeRetry',
			'testReloadSessionAppendsToTodaysTopicalViewInsteadOfTruncatingIt',
			'testFreshLauncherPreservesAnExistingSameDayTopicalView',
			'testFirstRecordAfterMidnightReplacesThePriorDayTopicalView',
			'testObservedCalendarTransitionRotatesTopicalEvenWhenOldRecordHasNewDayMtime',
			'testSameDirectoryReconfigureRetainsObservedTopicalCalendarTransition',
			'testReplacedDirectoryAtSamePathDoesNotReuseTopicalInitializationState',
			'testTopicalRotationUsesMetadataObservedAfterWaitingForTheWriteLock',
			'testDrainReceiveLoopBoundsZeroLengthDatagrams',
			'testBoundLoopbackWorkerAcknowledgesPersistedRecord',
			'testConfigurePurgesExpiredDailyAndStaleTopicalFiles',
			'testFirstRecordOnNewWallClockDayRearmsRetentionWithoutReconfigure',
			'testSinkReusesADescriptorAcrossAppendsAndReopensAfterUnlink',
			'testSlowDatagramIsReportedWithItsCostBreakdown',
			'testFastDatagramIsNotReported'
		],
		OwnedLogDirectoryTests: [
			'testSymlinkedLogsFolderIsAcceptedAndWrittenThrough',
			'testSymlinkedConfigRootCreatesTheMissingLogsFolderInsideTheTarget',
			'testSymlinkedDriverFolderIsAccepted',
			'testOnlyTheApplicationFolderIsRestrictedToItsOwner',
			'testPreexistingSourceRunLogsAreReused',
			'testDanglingLogsLinkIsRefusedAndItsTargetIsNeverCreated',
			'testDanglingAncestorLinkNamesTheAncestor',
			'testRegularFileInPlaceOfTheFolderIsNotADirectory',
			'testRelativePathIsInvalid',
			'testNoFollowAnyRefusesAnIntermediateLink',
			'testProcessorNamesTheRefusalInTheNackAndReportsIt',
			'testEveryRefusalHasALocalizedAlertInTheSharedCatalog',
			'testLocaleChoiceFollowsTheDriverThenTheSystemThenEnglish'
		]
	};
	for (const [suite, names] of Object.entries(expected)) {
		const file = path.join(
			repository,
			`static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${suite}.swift`
		);
		const actual = [...fs.readFileSync(file, 'utf8').matchAll(/\bfunc (test\w+)\(/g)]
			.map((match) => match[1])
			.sort();
		assert.deepEqual(actual, [...names].sort(), 'unchanged historical original logger definitions');
	}
	const summary = (count) =>
		`Executed ${count} tests, with 0 failures (0 unexpected) in 0.042 (0.043) seconds`;
	const rows = [
		"Test Suite 'Selected tests' started at fixed",
		"Test Suite 'ErgoptiPlusPackageTests.xctest' started at fixed"
	];
	for (const [suite, names] of Object.entries(expected)) {
		rows.push(`Test Suite '${suite}' started at fixed`);
		for (const method of names) {
			const name = `-[ErgoptiPlusTests.${suite} ${method}]`;
			rows.push(`Test Case '${name}' started.`, `Test Case '${name}' passed (0.001 seconds).`);
		}
		rows.push(`Test Suite '${suite}' passed at fixed`, summary(names.length));
	}
	rows.push(
		"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at fixed",
		summary(42),
		"Test Suite 'Selected tests' passed at fixed",
		summary(42)
	);
	const valid = rows.join('\n') + '\n';
	// Constructed foreign SDK49 summary: exclusion witness only, never SDK credit.
	const foreign49 =
		[
			"Test Suite 'Selected tests' started at fixed",
			"Test Suite 'ErgoptiPlusPackageTests.xctest' started at fixed",
			"Test Suite 'OwnedSuspendedImageTests' started at fixed",
			"Test Case '-[ErgoptiPlusTests.OwnedSuspendedImageTests testForeignOriginalSDKCase]' started.",
			"Test Case '-[ErgoptiPlusTests.OwnedSuspendedImageTests testForeignOriginalSDKCase]' passed (0.001 seconds).",
			"Test Suite 'OwnedSuspendedImageTests' passed at fixed",
			summary(49),
			"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at fixed",
			summary(49),
			"Test Suite 'Selected tests' passed at fixed",
			summary(49)
		].join('\n') + '\n';
	let parserControls = 0;
	const parseCheck = (callback) => {
		callback();
		parserControls++;
	};
	parseCheck(() => assert.equal(reader.evaluate(valid, 0, 0).exit_status, 0));
	for (const [from, to] of [
		["Test Suite 'Selected tests'", "Test Suite 'All tests'"],
		['LoggerDatagramWorkerTests', 'OwnedSuspendedImageTests'],
		['OwnedLogDirectoryTests', 'SuspendedImageLogCaptureTests'],
		['Executed 29 tests', 'Executed 49 tests'],
		['Executed 13 tests', 'Executed 7 tests'],
		['Executed 42 tests', 'Executed 49 tests'],
		['Executed 42 tests', 'Executed 7 tests'],
		['Executed 42 tests', 'Executed 0 tests'],
		['testAcceptedRecordFansOutOnceAndDuplicateOnlyAcknowledges', 'testForeignLoggerCase'],
		['passed (0.001 seconds).', 'skipped (0.001 seconds).'],
		['passed (0.001 seconds).', 'failed (0.001 seconds).'],
		['0 failures (0 unexpected)', '1 failures (0 unexpected)'],
		["Test Suite 'OwnedLogDirectoryTests' passed", "Test Suite 'OwnedLogDirectoryTests' failed"],
		["Test Suite 'Selected tests' passed", "Test Suite 'Selected tests' failed"]
	])
		parseCheck(() => {
			assert.ok(valid.includes(from));
			const changed = valid.replaceAll(from, to);
			assert.notEqual(changed, valid);
			assert.notEqual(reader.evaluate(changed, 0, 0).exit_status, 0);
		});
	const firstStart = rows[3],
		firstFinish = rows[4];
	for (const changed of [
		valid.replace(firstStart + '\n', ''),
		valid.replace(firstFinish + '\n', ''),
		valid.replace(firstStart, firstStart + '\n' + firstStart),
		valid.replace(firstFinish, firstFinish + '\n' + firstFinish),
		valid + firstStart + '\n',
		valid.replace(firstStart + '\n' + firstFinish, firstFinish + '\n' + firstStart),
		valid.slice(0, valid.lastIndexOf("Test Suite 'Selected tests' passed")),
		valid + nativeSevenTranscript,
		nativeSevenTranscript + valid,
		valid + foreign49,
		foreign49 + valid,
		'',
		valid.replace(summary(29) + '\n', ''),
		valid.replace(
			"Test Suite 'OwnedLogDirectoryTests' started at fixed",
			"Test Suite 'ForeignTests' started at fixed"
		)
	])
		parseCheck(() => assert.notEqual(reader.evaluate(changed, 0, 0).exit_status, 0));
	parseCheck(() => assert.equal(reader.evaluate(valid, 42, 0).exit_status, 42));
	parseCheck(() => assert.equal(reader.evaluate(valid, 0, 17).exit_status, 17));
	assert.equal(parserControls, 31);
	let selectorControls = 0;
	for (const [from, to] of [
		[LOGGER_42_BLOCK, ''],
		[LOGGER_42_FILTER, "--filter 'LoggerDatagramWorkerTests'"],
		[
			LOGGER_42_FILTER,
			"--filter 'LoggerDatagramWorkerTests|OwnedLogDirectoryTests|SuspendedImageLogCaptureTests'"
		],
		['tee "$logger_transcript"', 'tee "$log_transcript"'],
		['"${logger_statuses[0]}"', '"0"'],
		['"${logger_statuses[1]}"', '"0"'],
		['test "${#logger_statuses[@]}" -eq 2', 'true'],
		['logger-original-42-source.json', 'daily-log-native-source.json'],
		[
			'native_logger_regression_xctest_evidence.cjs begin',
			'native_logger_regression_xctest_evidence.cjs omitted'
		],
		['native_logger_regression_xctest_evidence.cjs judge', 'true'],
		['"$GITHUB_RUN_ID"', '"1"'],
		['"$GITHUB_RUN_ATTEMPT"', '"1"'],
		['"$GITHUB_SHA"', '"foreign"'],
		['"$ERGOPTI_OLLAMA_EXPECTED_ARCHITECTURE"', '"arm64"']
	]) {
		assert.ok(LOGGER_42_BLOCK.includes(from) || from === LOGGER_42_BLOCK);
		const changed = workflow.replace(LOGGER_42_BLOCK, LOGGER_42_BLOCK.replace(from, to));
		assert.notEqual(changed, workflow);
		assert.equal(admitNativeSdkSelector(changed), null);
		selectorControls++;
	}
	for (const changed of [
		workflow + '\n# ' + LOGGER_42_FILTER + '\n',
		workflow.replace(LOGGER_42_BLOCK, LOGGER_42_BLOCK + LOGGER_42_BLOCK)
	]) {
		assert.equal(admitNativeSdkSelector(changed), null);
		selectorControls++;
	}
	assert.notEqual(admitNativeSdkSelector(workflow), null);
	assert.equal(/--filter|--skip|XCTSkip/.test(admitNativeSdkSelector(workflow)), false);
	assert.equal(selectorControls, 16);

	// Both actual judge CLIs run in their own real Git-owned complete fixture.
	// Definitions and helpers are physically copied from this source-bound stage;
	// no __dirname/__file__ patch, sourceReceipt mock or Swift/native invocation.
	const fixtureInputs = [
		'.github/workflows/ci-macos.yml',
		'.github/ci/dev_release_qualification_exceptions.json',
		'.github/ci/stable_release_qualification_exception.json',
		'tools/ci/dev-release-qualification.cjs',
		'tools/diagnostics/native_logger_regression_xctest_evidence.cjs',
		'tools/diagnostics/native_daemon_log_xctest_evidence.cjs',
		'tools/diagnostics/swift_xctest_evidence.cjs',
		'tools/diagnostics/native_pac_source_evidence.cjs',
		'tools/diagnostics/item36_xctest_evidence.cjs',
		'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/LoggerDatagramWorker.swift',
		'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedLogDirectory.swift',
		...[
			'ReleaseArchiveStagingTests',
			'SparkleArchiveUpdateAcceptanceTests',
			'HomebrewArchiveAcceptanceTests',
			'HomebrewAutomationConsentTests',
			'OwnedSuspendedImageTests',
			'LoggerDatagramWorkerTests',
			'OwnedLogDirectoryTests'
		].map((name) => `static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${name}.swift`)
	];
	// Both actual Git and Node judge children share the same private Git view.
	// Drop inherited repository/index/config authority before any acquisition.
	const isolatedGitEnvironment = (inherited) => ({
		...Object.fromEntries(Object.entries(inherited).filter(([key]) => !/^GIT_/i.test(key))),
		GIT_CONFIG_NOSYSTEM: '1',
		GIT_CONFIG_GLOBAL: '/dev/null'
	});
	let sourceControls = 0;
	const sourceCheck = (callback) => {
		callback();
		sourceControls++;
	};
	for (const [judge, transcript, scope, critical] of [
		[
			'native_daemon_log_xctest_evidence.cjs',
			nativeSevenTranscript,
			'native-daemon-log-seven',
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/OwnedSuspendedImageTests.swift'
		],
		[
			'native_logger_regression_xctest_evidence.cjs',
			valid,
			'native-logger-original-forty-two',
			'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/LoggerDatagramWorkerTests.swift'
		]
	]) {
		const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-logger-Git-source-'));
		fs.chmodSync(fixture, 0o700);
		const originals = new Map();
		const foreignView = path.join(fixture, 'foreign-git-view');
		const controlledEnv = isolatedGitEnvironment({
			...process.env,
			GIT_DIR: path.join(foreignView, '.git'),
			GIT_WORK_TREE: foreignView,
			GIT_INDEX_FILE: path.join(foreignView, 'index'),
			GIT_CONFIG_COUNT: '1',
			GIT_CONFIG_KEY_0: 'core.worktree',
			GIT_CONFIG_VALUE_0: foreignView
		});
		const git = (args) =>
			execFileSync('git', args, {
				cwd: fixture,
				env: controlledEnv,
				encoding: 'utf8',
				stdio: ['ignore', 'pipe', 'pipe']
			});
		const commit = () => {
			git([
				'-c',
				'user.name=Logger source control',
				'-c',
				'user.email=logger-control@example.invalid',
				'commit',
				'--quiet',
				'-m',
				'Independent logger source fixture'
			]);
			return git(['rev-parse', 'HEAD']).trim();
		};
		try {
			for (const relative of fixtureInputs) {
				const bytes = fs.readFileSync(path.join(repository, relative));
				originals.set(relative, bytes);
				const destination = path.join(fixture, relative);
				fs.mkdirSync(path.dirname(destination), { recursive: true, mode: 0o700 });
				fs.writeFileSync(destination, bytes, { flag: 'wx', mode: 0o600 });
			}
			git(['init', '--quiet']);
			git(['add', '--', '.github', 'tools', 'static']);
			let candidate = commit();
			const evidence = path.join(fixture, 'evidence');
			fs.mkdirSync(evidence, { mode: 0o700 });
			const captured = path.join(evidence, 'transcript.log');
			fs.writeFileSync(captured, transcript, { flag: 'wx', mode: 0o600 });
			const script = path.join(fixture, 'tools/diagnostics', judge);
			let serial = 0;
			const fresh = (label) => path.join(evidence, `${label}-${++serial}.json`);
			const cli = (args) => {
				const result = spawnSync(process.execPath, [script, ...args], {
					cwd: fixture,
					env: controlledEnv,
					encoding: 'utf8',
					maxBuffer: 1048576
				});
				assert.equal(result.error, undefined);
				assert.equal(result.signal, null);
				return result;
			};
			const begin = (out, hash = candidate, run = '12345', attempt = '2', architecture = 'arm64') =>
				cli(['begin', hash, run, attempt, architecture, out]);
			const before = fresh('source');
			sourceCheck(() => {
				const result = begin(before);
				assert.equal(result.status, 0);
				assert.equal(result.stderr, '');
				const receipt = JSON.parse(fs.readFileSync(before));
				assert.equal(receipt.scope, scope);
				assert.equal(receipt.candidate, candidate);
				assert.equal(receipt.run_id, '12345');
				assert.equal(receipt.run_attempt, '2');
				assert.equal(receipt.architecture, 'arm64');
			});
			const judgeArgs = (
				out,
				hash = candidate,
				run = '12345',
				attempt = '2',
				architecture = 'arm64',
				processStatus = '0',
				captureStatus = '0',
				capture = captured,
				source = before
			) => [
				'judge',
				capture,
				processStatus,
				captureStatus,
				hash,
				run,
				attempt,
				architecture,
				source,
				out
			];
			sourceCheck(() => {
				const result = cli(judgeArgs(fresh('good')));
				assert.equal(result.status, 0);
				assert.equal(result.stderr, '');
			});
			sourceCheck(() => assert.equal(begin(before).status, 1));
			sourceCheck(() => {
				const output = fresh('receipt');
				assert.equal(cli(judgeArgs(output)).status, 0);
				const receipt = JSON.parse(fs.readFileSync(output));
				assert.equal(receipt.complete, true);
				assert.equal(receipt.packaged_ollama_qualified, false);
				assert.equal(receipt.full_package_qualified, false);
				assert.equal(receipt.source.scope, scope);
			});
			sourceCheck(() =>
				assert.equal(
					cli(judgeArgs(fresh('process'), candidate, '12345', '2', 'arm64', '42')).status,
					42
				)
			);
			sourceCheck(() =>
				assert.equal(
					cli(judgeArgs(fresh('capture'), candidate, '12345', '2', 'arm64', '0', '17')).status,
					17
				)
			);
			for (const altered of [
				judgeArgs(fresh('candidate'), '0'.repeat(40)),
				judgeArgs(fresh('run'), candidate, '12346'),
				judgeArgs(fresh('attempt'), candidate, '12345', '3'),
				judgeArgs(fresh('architecture'), candidate, '12345', '2', 'amd64')
			])
				sourceCheck(() => assert.equal(cli(altered).status, 1));
			const sourceBytes = fs.readFileSync(before);
			sourceCheck(() => {
				const parsed = JSON.parse(sourceBytes);
				parsed.scope = 'full-package';
				fs.writeFileSync(before, JSON.stringify(parsed));
				assert.equal(cli(judgeArgs(fresh('foreign-scope'))).status, 1);
				fs.writeFileSync(before, sourceBytes);
			});
			sourceCheck(() => {
				const parsed = JSON.parse(sourceBytes);
				parsed.sources[critical] = '0'.repeat(64);
				fs.writeFileSync(before, JSON.stringify(parsed));
				assert.equal(cli(judgeArgs(fresh('foreign-source'))).status, 1);
				fs.writeFileSync(before, sourceBytes);
			});
			const criticalPath = path.join(fixture, critical),
				original = originals.get(critical);
			sourceCheck(() => {
				fs.appendFileSync(criticalPath, '\n// private changed-source control\n');
				assert.equal(begin(fresh('dirty')).status, 1);
				assert.equal(cli(judgeArgs(fresh('dirty-judge'))).status, 1);
				fs.writeFileSync(criticalPath, original);
			});
			sourceCheck(() => {
				fs.unlinkSync(criticalPath);
				assert.equal(begin(fresh('missing')).status, 1);
				assert.equal(cli(judgeArgs(fresh('missing-judge'))).status, 1);
				fs.writeFileSync(criticalPath, original, { flag: 'wx', mode: 0o600 });
			});
			sourceCheck(() => {
				git(['rm', '--cached', '--', critical]);
				candidate = commit();
				assert.equal(begin(fresh('untracked')).status, 1);
				git(['add', '--', critical]);
				candidate = commit();
			});
			const originalCandidate = candidate;
			sourceCheck(() => {
				fs.appendFileSync(criticalPath, '\n// actual committed-source change\n');
				git(['add', '--', critical]);
				candidate = commit();
				assert.equal(begin(fresh('changed-epoch'), originalCandidate).status, 1);
				assert.equal(cli(judgeArgs(fresh('changed-judge'), originalCandidate)).status, 1);
				fs.writeFileSync(criticalPath, original);
				git(['add', '--', critical]);
				candidate = commit();
			});
			sourceCheck(() => {
				fs.appendFileSync(criticalPath, '\nfunc testForeignLoggerAuthority() {}\n');
				git(['add', '--', critical]);
				candidate = commit();
				assert.equal(begin(fresh('foreign-inventory')).status, 1);
				fs.writeFileSync(criticalPath, original);
				git(['add', '--', critical]);
				candidate = commit();
			});
			sourceCheck(() => {
				const hidden = path.join(
					fixture,
					'static/ergopti_plus/macos/launcher/Sources/ignored-source.swift'
				);
				fs.writeFileSync(hidden, '// unchanged ownership refusal\n', { flag: 'wx', mode: 0o600 });
				fs.appendFileSync(
					path.join(fixture, '.git/info/exclude'),
					'/static/ergopti_plus/macos/launcher/Sources/ignored-source.swift\n'
				);
				assert.equal(begin(fresh('implicit-source')).status, 1);
				fs.unlinkSync(hidden);
			});
			const currentBefore = fresh('current-source');
			assert.equal(begin(currentBefore).status, 0);
			sourceCheck(() => {
				assert.deepEqual(
					Object.keys(controlledEnv)
						.filter((key) => /^GIT_/i.test(key))
						.sort(),
					['GIT_CONFIG_GLOBAL', 'GIT_CONFIG_NOSYSTEM']
				);
				assert.equal(fs.existsSync(foreignView), false);
				assert.equal(git(['rev-parse', '--show-toplevel']).trim(), fs.realpathSync(fixture));
			});
			sourceCheck(() => {
				const link = path.join(evidence, 'capture-link');
				fs.symlinkSync(captured, link);
				assert.equal(
					cli(
						judgeArgs(
							fresh('link'),
							candidate,
							'12345',
							'2',
							'arm64',
							'0',
							'0',
							link,
							currentBefore
						)
					).status,
					1
				);
			});
			sourceCheck(() => {
				const invalid = path.join(evidence, 'invalid.log');
				fs.writeFileSync(invalid, Buffer.from([0xff]), { flag: 'wx', mode: 0o600 });
				assert.equal(
					cli(
						judgeArgs(
							fresh('invalid'),
							candidate,
							'12345',
							'2',
							'arm64',
							'0',
							'0',
							invalid,
							currentBefore
						)
					).status,
					1
				);
			});
			sourceCheck(() => {
				const mixed = path.join(evidence, 'mixed.log');
				fs.writeFileSync(
					mixed,
					transcript + (scope === 'native-daemon-log-seven' ? valid : nativeSevenTranscript),
					{ flag: 'wx', mode: 0o600 }
				);
				assert.equal(
					cli(
						judgeArgs(
							fresh('mixed'),
							candidate,
							'12345',
							'2',
							'arm64',
							'0',
							'0',
							mixed,
							currentBefore
						)
					).status,
					1
				);
			});
			sourceCheck(() => {
				const mixed = path.join(evidence, 'mixed-sdk49.log');
				fs.writeFileSync(mixed, transcript + foreign49, { flag: 'wx', mode: 0o600 });
				assert.equal(
					cli(
						judgeArgs(
							fresh('mixed-sdk49'),
							candidate,
							'12345',
							'2',
							'arm64',
							'0',
							'0',
							mixed,
							currentBefore
						)
					).status,
					1
				);
			});
			sourceCheck(() => {
				const malformed = path.join(evidence, 'malformed.json');
				fs.writeFileSync(malformed, '{"schema":1,"schema":2}', { flag: 'wx', mode: 0o600 });
				assert.equal(
					cli(
						judgeArgs(
							fresh('malformed'),
							candidate,
							'12345',
							'2',
							'arm64',
							'0',
							'0',
							captured,
							malformed
						)
					).status,
					1
				);
			});
		} finally {
			fs.rmSync(fixture, { recursive: true });
		}
	}
	assert.equal(sourceControls, 48);
	console.log(
		`PASS: unchanged logger42 parser-controls=${parserControls} selector-controls=${selectorControls} real-Git/CLI-controls=${sourceControls}; native42/native7 UNRUN.`
	);
};
