// tools/diagnostics/native_pac_source_evidence.cjs
'use strict';

/** Exact source-acquisition cohort; no full-package or runtime activation claim. */
const fs = require('node:fs');
const { cleanTranscript, evaluate: fullEvaluate } = require('./swift_xctest_evidence.cjs');
const METHODS = Object.freeze({
	ManagedPACSourceTests: Object.freeze([
		'testStrictUTF8AndBOMAdmission',
		'testStrictUTF16RejectsMalformedSurrogatesAndNUL',
		'testAuthorityScopeIncludesCanonicalSchemeHostEffectivePort',
		'testBindingEscapesRequestDataAndRefusesInvalidSource',
		'testRealPACSourceDecodersRetireEverySession',
		'testRealPACSourceStatusSizeAndEncodingRefusalsRetire',
		'testRealPACSourceRedirectsHaveFreshCredentialFreeOwners',
		'testRealPACSourceTrustAnchorsPreserveHostnameAndDowngradeRefusal',
		'testRealPACSourceDeadlineRefusesAndRetiresBeforeReplacement',
		'testOriginalLookupBudgetIncludesSettingsPreparation'
	])
});
const NAMES = Object.freeze(
	METHODS.ManagedPACSourceTests.map(
		(method) => `-[ErgoptiPlusTests.ManagedPACSourceTests ${method}]`
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
			const expected = summary === 'root' || summary === 'bundle' ? 10 : METHODS[summary].length;
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
		opened.size === 1 &&
		started.size === 10
	);
}

function evaluate(text, swiftStatus, captureStatus) {
	const clean = cleanTranscript(text);
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
		names.length === 10 &&
		NAMES.length === 10 &&
		NAMES.every((name) => names.filter((actual) => actual === name).length === 1);
	const errors = [];
	if (!selected) errors.push('selected-root');
	if (!base.complete || base.failures.length) errors.push('incomplete-failed-or-skipped');
	if (!inventory) errors.push('exact-ten-source-inventory');
	if (!serialCohort(clean)) errors.push('serial-native-cohort');
	if (base.script_status || base.tee_status) errors.push('pipeline-status');
	const complete = errors.length === 0;
	return {
		schema: 1,
		cohort: 'native-pac-source',
		expected: 10,
		complete,
		observed: Math.min(names.length, 65535),
		swift_status: base.script_status,
		capture_status: base.tee_status,
		errors,
		exit_status: base.script_status || base.tee_status || (complete ? 0 : 1)
	};
}

const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { sourceReceipt: trackedSourceReceipt } = require('./item36_xctest_evidence.cjs');
const EXTRA_SOURCE_INPUTS = Object.freeze([
	'static/ergopti_plus/_shared/modules/network/proxy_policy.json',
	'static/ergopti_plus/macos/tests/support/native_pac_source_fixture.py',
	'tools/diagnostics/native_pac_source_evidence.cjs',
	'tools/diagnostics/swift_xctest_evidence.cjs'
]);
function context(candidate, runID, attempt, architecture) {
	if (
		!/^[0-9a-f]{40}$/.test(candidate) ||
		!/^[1-9][0-9]{0,19}$/.test(runID) ||
		!/^[1-9][0-9]{0,5}$/.test(attempt) ||
		!['arm64', 'amd64'].includes(architecture)
	)
		throw new Error('Native PAC source context refused.');
	return { candidate, run_id: runID, run_attempt: attempt, architecture };
}
function sourceReceipt(repository, epoch) {
	const admitted = context(epoch.candidate, epoch.run_id, epoch.run_attempt, epoch.architecture);
	const tracked = trackedSourceReceipt(repository, admitted.candidate);
	const sources = { ...tracked.sources };
	for (const relative of EXTRA_SOURCE_INPUTS) {
		execFileSync('git', ['ls-files', '--error-unmatch', '--', relative], {
			cwd: repository,
			stdio: 'pipe'
		});
		const file = path.join(repository, relative);
		if (!fs.lstatSync(file).isFile()) throw new Error('Native PAC source input refused.');
		sources[relative] = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
	}
	const relative =
		'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/ManagedPACSourceTests.swift';
	if (!Object.hasOwn(sources, relative)) throw new Error('Native PAC source cohort unavailable.');
	const actual = [
		...fs.readFileSync(path.join(repository, relative), 'utf8').matchAll(/\bfunc (test\w+)\(/g)
	]
		.map((match) => match[1])
		.sort();
	if (JSON.stringify(actual) !== JSON.stringify([...METHODS.ManagedPACSourceTests].sort()))
		throw new Error('Native PAC source independent inventory changed.');
	return { schema: 1, scope: 'native-pac-source-only', ...admitted, sources };
}
function readBoundedRegular(file, maximum) {
	const fd = fs.openSync(
		file,
		fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK
	);
	try {
		const before = fs.fstatSync(fd),
			named = fs.lstatSync(file);
		if (
			!before.isFile() ||
			before.size > maximum ||
			before.dev !== named.dev ||
			before.ino !== named.ino
		)
			throw new Error('Native PAC source capture refused.');
		const bytes = Buffer.alloc(before.size + 1);
		let length = 0;
		while (length < bytes.length) {
			const count = fs.readSync(fd, bytes, length, bytes.length - length, null);
			if (count === 0) break;
			length += count;
		}
		const after = fs.fstatSync(fd),
			finalName = fs.lstatSync(file);
		if (
			length !== before.size ||
			after.size !== before.size ||
			after.mtimeMs !== before.mtimeMs ||
			after.dev !== finalName.dev ||
			after.ino !== finalName.ino
		)
			throw new Error('Native PAC source capture changed.');
		return new TextDecoder('utf-8', { fatal: true }).decode(bytes.subarray(0, length));
	} finally {
		fs.closeSync(fd);
	}
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
			const before = JSON.parse(readBoundedRegular(args[8], 1048576));
			const after = sourceReceipt(repository, epoch);
			if (JSON.stringify(before) !== JSON.stringify(after))
				throw new Error('Native PAC source epoch changed.');
			const verdict = {
				...evaluate(readBoundedRegular(args[1], 16777216), args[2], args[3]),
				source: after
			};
			fs.writeFileSync(args[9], JSON.stringify(verdict, null, 2) + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			console.log(
				`PAC_SOURCE_XCTEST qualified=${verdict.complete} cases=${verdict.observed}/10 candidate=${epoch.candidate} run=${epoch.run_id} attempt=${epoch.run_attempt} arch=${epoch.architecture}`
			);
			return verdict.exit_status;
		}
		// Preserve the original transcript-only interface without source proof.
		if (args.length === 4) {
			const result = evaluate(readBoundedRegular(args[0], 16777216), args[1], args[2]);
			fs.writeFileSync(args[3], JSON.stringify(result, null, 2) + '\n');
			console.log(
				`PAC_SOURCE_XCTEST qualified=${result.complete} cases=${result.observed}/10 swift=${result.swift_status} capture=${result.capture_status}`
			);
			return result.exit_status;
		}
		throw new Error('Native PAC source evidence arguments refused.');
	} catch {
		console.error('PAC_SOURCE_XCTEST refused; full package and installation remain unqualified.');
		return 1;
	}
}
module.exports = { METHODS, NAMES, evaluate, context, sourceReceipt, readBoundedRegular, main };
if (require.main === module) process.exitCode = main(process.argv.slice(2));
