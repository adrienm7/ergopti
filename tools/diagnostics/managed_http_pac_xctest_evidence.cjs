// tools/diagnostics/managed_http_pac_xctest_evidence.cjs
'use strict';

/** Exact twelve original PAC/WPAD cases and two bounded argument observations; never full-suite evidence. */
const fs = require('node:fs');
const { cleanTranscript, evaluate: fullEvaluate } = require('./swift_xctest_evidence.cjs');
const METHODS = Object.freeze({
	ManagedHTTPWorkerTests: Object.freeze([
		'testExactURLAndOptionalAbsoluteBudgetRemainSeparateFromReadIdleTimeout',
		'testInvalidRequestsRefuseBeforeAnyNativeDispatch',
		'testBinaryFrameLengthAndNULPayloadAreExact',
		'testNativeErrorsNeverReturnPrivateDiagnosticPayload',
		'testActualCFNetworkPACReceivesDistinctHTTPSPathsAndQueries',
		'testActualCFNetworkPACPreservesHTTPPathAndOrderedNativeChoices',
		'testWPADMetadataUsesDHCPOwnerOrNativeResolverWithoutSuffixConstruction',
		'testWPADNativeDNSAdmissionIncludesSingleLabelCompanyDomains',
		'testWPADUnresolvedNativeStateNeverFallsBackToInitialDirectOrFixedProxy',
		'testResolvedNativePACOwnsDiscoveryWithoutReadingForeignMetadata',
		'testActualCFNetworkHTTPPACArgumentShapeObservation',
		'testActualCFNetworkHTTPSPACArgumentShapeObservation'
	]),
	ManagedHTTPWireTests: Object.freeze([
		'testRealNativeTLSFullURLPACOrderedFallbackAndOwnedClosure'
	]),
	ManagedHTTPWPADWireTests: Object.freeze([
		'testDHCPMetadataOwnsRealPACURLRoutesAndRefusesInvalidDiscoveryBeforeNetwork'
	])
});
const NAMES = Object.freeze(
	Object.entries(METHODS).flatMap(([suite, methods]) =>
		methods.map((method) => `-[ErgoptiPlusTests.${suite} ${method}]`)
	)
);

/** Fixed serial XCTest envelope; totals never replace per-method completion. */
function serialCohort(clean) {
	let root = 'before',
		bundle = 'before',
		suite = null,
		active = null,
		summary = null;
	const opened = new Set(),
		started = new Set();
	let valid = true;
	const require = (value) => {
		if (!value) valid = false;
	};
	for (const line of clean.split('\n')) {
		if (!line.trim()) continue;
		if (summary !== null) {
			const count = /^\s*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\) in /.exec(
				line
			);
			const expected = summary === 'root' || summary === 'bundle' ? 14 : METHODS[summary].length;
			require(count && count[1] === String(expected) && count[2] === '0' && count[3] === '0');
			if (summary === 'root') root = 'after';
			if (summary === 'bundle') bundle = 'after';
			summary = null;
			continue;
		}
		const opening = /^Test Suite '([^']+)' started at /.exec(line);
		const closing = /^Test Suite '([^']+)' (passed|failed) at /.exec(line);
		const start = /^Test Case '([^']+)' started\.$/.exec(line);
		const finish =
			/^Test Case '([^']+)' (passed|failed|skipped) \(\d+(?:\.\d+)? seconds?\)\.$/.exec(line);
		if (opening) {
			if (opening[1] === 'Selected tests') {
				require(root === 'before' && suite === null && active === null);
				root = 'running';
			} else if (opening[1] === 'ErgoptiPlusPackageTests.xctest') {
				require(root === 'running' && bundle === 'before' && suite === null && active === null);
				bundle = 'running';
			} else if (Object.hasOwn(METHODS, opening[1])) {
				require(
					root === 'running' &&
						bundle === 'running' &&
						suite === null &&
						active === null &&
						!opened.has(opening[1])
				);
				suite = opening[1];
				opened.add(suite);
			} else valid = false;
		} else if (closing) {
			require(closing[2] === 'passed' && active === null);
			if (closing[1] === 'Selected tests') {
				require(root === 'running' && bundle === 'after' && suite === null);
				root = 'summary';
				summary = 'root';
			} else if (closing[1] === 'ErgoptiPlusPackageTests.xctest') {
				require(root === 'running' && bundle === 'running' && suite === null);
				bundle = 'summary';
				summary = 'bundle';
			} else if (Object.hasOwn(METHODS, closing[1]) && suite === closing[1]) {
				summary = suite;
				suite = null;
			} else valid = false;
		} else if (start) {
			require(
				root === 'running' &&
					bundle === 'running' &&
					active === null &&
					NAMES.includes(start[1]) &&
					!started.has(start[1]) &&
					start[1].startsWith(`-[ErgoptiPlusTests.${suite} `)
			);
			started.add(start[1]);
			active = start[1];
		} else if (finish) {
			require(root === 'running' && finish[1] === active && finish[2] === 'passed');
			active = null;
		} else if (/^Test (Suite|Case) /.test(line) || /^\s*Executed /.test(line)) valid = false;
	}
	return (
		valid &&
		root === 'after' &&
		bundle === 'after' &&
		summary === null &&
		suite === null &&
		active === null &&
		opened.size === 3 &&
		started.size === 14
	);
}

// Fixed observations need no invented stdout/XCTest delivery ordering.
function argumentObservations(clean) {
	const ports = { http: null, https: null };
	let valid = true;
	const lines = clean.split('\n');
	const admitted = new Set();
	for (const [index, line] of lines.entries()) {
		if (!line.includes('PAC_ARGUMENT_SHAPE')) continue;
		const match = /^PAC_ARGUMENT_SHAPE purpose=(http|https) port=(200[0-7][0-5])$/.exec(line);
		if (!match || ports[match[1]] !== null) {
			valid = false;
			continue;
		}
		ports[match[1]] = Number(match[2]);
		admitted.add(index);
	}
	return { complete: valid && ports.http !== null && ports.https !== null, ports, admitted };
}

function evaluate(text, swiftStatus, captureStatus) {
	const received = cleanTranscript(text);
	const observations = argumentObservations(received);
	// Validate the complete closed observation cohort first. Only those exact
	// admitted frames leave the otherwise unchanged XCTest narrative.
	const clean = observations.complete
		? received
				.split('\n')
				.filter((_, index) => !observations.admitted.has(index))
				.join('\n')
		: received;
	// Adapt only this strictly selected root to the shared complete-XCTest
	// reader. Its full-package caller and parser are never changed.
	const selected =
		(clean.match(/^Test Suite 'Selected tests' started at /gm) || []).length === 1 &&
		(clean.match(/^Test Suite 'Selected tests' (?:passed|failed) at /gm) || []).length === 1 &&
		!/^Test Suite 'All tests' /m.test(clean);
	const normalized = clean.replace(
		/^Test Suite 'Selected tests' (started|passed|failed) at /gm,
		"Test Suite 'All tests' $1 at "
	);
	const base = fullEvaluate(normalized, swiftStatus, captureStatus);
	const names = base.completed_tests.map((test) => test.name);
	const inventory =
		names.length === 14 &&
		NAMES.length === 14 &&
		NAMES.every((name) => names.filter((actual) => actual === name).length === 1);
	const suites = Object.keys(METHODS).every(
		(suite) =>
			(clean.match(new RegExp(`^Test Suite '${suite}' passed at `, 'gm')) || []).length === 1
	);
	const errors = [];
	if (!selected) errors.push('selected-root');
	if (!base.complete || base.failures.length) errors.push('incomplete-failed-or-skipped');
	if (!inventory) errors.push('exact-fourteen-inventory');
	if (!suites) errors.push('three-complete-native-suites');
	if (!serialCohort(clean)) errors.push('serial-native-cohort');
	if (!observations.complete) errors.push('bounded-argument-observations');
	if (base.script_status || base.tee_status) errors.push('pipeline-status');
	const complete = errors.length === 0;
	return {
		schema: 1,
		cohort: 'managed-http-pac-wpad',
		expected: 14,
		argument_observations: observations.ports,
		observed: Math.min(names.length, 65535),
		complete,
		swift_status: base.script_status,
		capture_status: base.tee_status,
		errors,
		exit_status: base.script_status || base.tee_status || (complete ? 0 : 1)
	};
}

module.exports = { METHODS, NAMES, evaluate };
if (require.main === module) {
	if (process.argv.length !== 6)
		throw new Error('Exact native PAC transcript and pipeline statuses required.');
	const result = evaluate(
		fs.readFileSync(process.argv[2], 'utf8'),
		process.argv[3],
		process.argv[4]
	);
	fs.writeFileSync(process.argv[5], JSON.stringify(result, null, 2) + '\n');
	console.log(
		`PAC_XCTEST qualified=${result.complete} cases=${result.observed}/14 swift=${result.swift_status} capture=${result.capture_status}`
	);
	process.exitCode = result.exit_status;
}
