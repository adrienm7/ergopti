// tools/diagnostics/native_logger_regression_xctest_evidence.cjs
'use strict';

/** Exact unchanged original logger29+directory13; no daemon or full-package qualification. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { cleanTranscript, evaluate: fullEvaluate } = require('./swift_xctest_evidence.cjs');
const { readBoundedRegular } = require('./native_pac_source_evidence.cjs');
const { sourceReceipt: trackedSourceReceipt } = require('./item36_xctest_evidence.cjs');
const { context } = require('./native_daemon_log_xctest_evidence.cjs');
const { parseClosedJson } = require('../ci/dev-release-qualification.cjs');
const METHODS = Object.freeze({
	LoggerDatagramWorkerTests: Object.freeze([
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
	]),
	OwnedLogDirectoryTests: Object.freeze([
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
	])
});
const NAMES = Object.freeze(
	Object.entries(METHODS).flatMap(([suite, methods]) =>
		methods.map((method) => `-[ErgoptiPlusTests.${suite} ${method}]`)
	)
);
const FILTER = "--filter '(^|[.])(LoggerDatagramWorkerTests|OwnedLogDirectoryTests)([/.]|$)'";
const INPUTS = Object.freeze([
	'.github/workflows/ci-macos.yml',
	'.github/ci/dev_release_qualification_exceptions.json',
	'.github/ci/stable_release_qualification_exception.json',
	'tools/diagnostics/native_logger_regression_xctest_evidence.cjs',
	'tools/diagnostics/native_daemon_log_xctest_evidence.cjs',
	'tools/diagnostics/swift_xctest_evidence.cjs',
	'tools/diagnostics/native_pac_source_evidence.cjs',
	'tools/diagnostics/item36_xctest_evidence.cjs',
	'tools/ci/dev-release-qualification.cjs',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/LoggerDatagramWorker.swift',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedLogDirectory.swift',
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/LoggerDatagramWorkerTests.swift',
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/OwnedLogDirectoryTests.swift'
]);

function evaluate(text, swiftStatus, captureStatus) {
	const clean = cleanTranscript(text);
	const normalized = clean.replace(
		/^Test Suite 'Selected tests' (started|passed|failed) at /gm,
		"Test Suite 'All tests' $1 at "
	);
	const base = fullEvaluate(normalized, swiftStatus, captureStatus);
	const starts = new Set(),
		terminals = new Set(),
		suites = new Set();
	let root = 'before',
		bundle = 'before',
		suite = null,
		active = null,
		summary = null,
		invalid = false;
	for (const line of clean.split('\n')) {
		if (!line.trim()) continue;
		if (summary !== null) {
			const count =
				/^\s*Executed (0|[1-9][0-9]*) tests, with 0 failures \(0 unexpected\) in [0-9]+(?:\.[0-9]+)?(?: \([0-9]+(?:\.[0-9]+)?\))? seconds$/.exec(
					line
				);
			const expected = summary === 'root' || summary === 'bundle' ? 42 : METHODS[summary].length;
			if (!count || Number(count[1]) !== expected) invalid = true;
			if (summary === 'root') root = 'after';
			if (summary === 'bundle') bundle = 'after';
			summary = null;
			continue;
		}
		const opening = /^Test Suite '([^']+)' started at /.exec(line);
		const closing = /^Test Suite '([^']+)' (passed|failed) at /.exec(line);
		const start = /^Test Case '([^']+)' started\.$/.exec(line);
		const finish =
			/^Test Case '([^']+)' (passed|failed|skipped) \([0-9]+(?:\.[0-9]+)? seconds?\)\.$/.exec(line);
		if (opening) {
			if (opening[1] === 'Selected tests') {
				if (root !== 'before' || bundle !== 'before' || suite !== null || active !== null)
					invalid = true;
				root = 'running';
			} else if (opening[1] === 'ErgoptiPlusPackageTests.xctest') {
				if (root !== 'running' || bundle !== 'before' || suite !== null || active !== null)
					invalid = true;
				bundle = 'running';
			} else if (Object.hasOwn(METHODS, opening[1])) {
				if (
					root !== 'running' ||
					bundle !== 'running' ||
					suite !== null ||
					active !== null ||
					suites.has(opening[1])
				)
					invalid = true;
				suite = opening[1];
				suites.add(suite);
			} else invalid = true;
		} else if (closing) {
			if (closing[2] !== 'passed') invalid = true;
			if (closing[1] === 'Selected tests') {
				if (root !== 'running' || bundle !== 'after' || suite !== null || active !== null)
					invalid = true;
				root = 'summary';
				summary = 'root';
			} else if (closing[1] === 'ErgoptiPlusPackageTests.xctest') {
				if (root !== 'running' || bundle !== 'running' || suite !== null || active !== null)
					invalid = true;
				bundle = 'summary';
				summary = 'bundle';
			} else if (suite === closing[1]) {
				if (root !== 'running' || bundle !== 'running' || active !== null) invalid = true;
				summary = suite;
				suite = null;
			} else invalid = true;
		} else if (start) {
			if (
				root !== 'running' ||
				bundle !== 'running' ||
				active !== null ||
				!NAMES.includes(start[1]) ||
				starts.has(start[1]) ||
				!start[1].startsWith(`-[ErgoptiPlusTests.${suite} `)
			)
				invalid = true;
			starts.add(start[1]);
			active = start[1];
		} else if (finish) {
			if (
				root !== 'running' ||
				bundle !== 'running' ||
				active !== finish[1] ||
				finish[2] !== 'passed' ||
				terminals.has(finish[1])
			)
				invalid = true;
			terminals.add(finish[1]);
			active = null;
		} else if (/^Test (Suite|Case) |^\s*Executed /.test(line)) invalid = true;
	}
	const complete =
		!invalid &&
		root === 'after' &&
		bundle === 'after' &&
		suite === null &&
		active === null &&
		summary === null &&
		suites.size === 2 &&
		starts.size === 42 &&
		terminals.size === 42 &&
		NAMES.every((name) => starts.has(name) && terminals.has(name)) &&
		base.complete &&
		base.failures.length === 0 &&
		base.script_status === 0 &&
		base.tee_status === 0;
	return {
		schema: 1,
		scope: 'native-logger-original-forty-two',
		expected: 42,
		observed: terminals.size,
		complete,
		swift_status: base.script_status,
		capture_status: base.tee_status,
		packaged_ollama_qualified: false,
		full_package_qualified: false,
		exit_status: base.script_status || base.tee_status || (complete ? 0 : 1)
	};
}

function sourceReceipt(repository, epoch) {
	const admitted = context(epoch.candidate, epoch.run_id, epoch.run_attempt, epoch.architecture);
	const original = trackedSourceReceipt(repository, admitted.candidate);
	const sources = { ...original.sources };
	for (const relative of INPUTS) {
		execFileSync('git', ['ls-files', '--error-unmatch', '--', relative], {
			cwd: repository,
			stdio: 'pipe'
		});
		const file = path.join(repository, relative);
		if (!fs.lstatSync(file).isFile()) throw new Error('Original logger source refused.');
		sources[relative] = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
	}
	for (const [suite, methods] of Object.entries(METHODS)) {
		const relative = `static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${suite}.swift`;
		if (!Object.hasOwn(sources, relative)) throw new Error('Original logger tests unavailable.');
		const actual = [
			...fs.readFileSync(path.join(repository, relative), 'utf8').matchAll(/\bfunc (test\w+)\(/g)
		]
			.map((row) => row[1])
			.sort();
		if (JSON.stringify(actual) !== JSON.stringify([...methods].sort()))
			throw new Error('Original logger independent inventory changed.');
	}
	return { schema: 1, scope: 'native-logger-original-forty-two', ...admitted, sources };
}

function main(args, repository = path.resolve(__dirname, '../..')) {
	try {
		if (args.length === 6 && args[0] === 'begin') {
			const epoch = context(args[1], args[2], args[3], args[4]);
			fs.writeFileSync(args[5], JSON.stringify(sourceReceipt(repository, epoch), null, 2) + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			return 0;
		}
		if (args.length === 10 && args[0] === 'judge') {
			const epoch = context(args[4], args[5], args[6], args[7]);
			const before = parseClosedJson(readBoundedRegular(args[8], 1048576));
			const after = sourceReceipt(repository, epoch);
			if (JSON.stringify(before) !== JSON.stringify(after))
				throw new Error('Original logger source epoch changed.');
			const result = {
				...evaluate(readBoundedRegular(args[1], 16777216), args[2], args[3]),
				source: after
			};
			fs.writeFileSync(args[9], JSON.stringify(result, null, 2) + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			console.log(
				`LOGGER_ORIGINAL_XCTEST complete=${result.complete} cases=${result.observed}/42 packaged_ollama_qualified=false`
			);
			return result.exit_status;
		}
		throw new Error('Original logger evidence arguments refused.');
	} catch {
		console.error('LOGGER_ORIGINAL_XCTEST refused; daemon and full suite remain unqualified.');
		return 1;
	}
}
module.exports = { METHODS, NAMES, FILTER, INPUTS, evaluate, context, sourceReceipt, main };
if (require.main === module) process.exitCode = main(process.argv.slice(2));
