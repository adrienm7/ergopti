// tools/diagnostics/native_logger_numeric_xctest_evidence.cjs
'use strict';

/** Independent numeric-boundary tests; no original-42 or full-package credit. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { cleanTranscript, evaluate: fullEvaluate } = require('./swift_xctest_evidence.cjs');
const { readBoundedRegular } = require('./native_pac_source_evidence.cjs');
const { sourceReceipt: trackedSourceReceipt } = require('./item36_xctest_evidence.cjs');
const { context } = require('./native_daemon_log_xctest_evidence.cjs');
const { parseClosedJson } = require('../ci/dev-release-qualification.cjs');
const CLASS = 'LoggerDatagramNumericTests';
const METHODS = Object.freeze([
	'testUnrepresentableEnvelopeNumbersRefuseWithoutCrashingOrConfiguring',
	'testUnrepresentableConfigureNumbersCannotCreateAConfiguredDirectory',
	'testUnrepresentableRecordAndBatchSequencesCannotWriteOrAdvance'
]);
const NAMES = Object.freeze(METHODS.map((method) => `-[ErgoptiPlusTests.${CLASS} ${method}]`));
const FILTER = "--filter '(^|[.])LoggerDatagramNumericTests([/.]|$)'";

function evaluate(text, swiftStatus, captureStatus) {
	const clean = cleanTranscript(text);
	const normalized = clean.replace(
		/^Test Suite 'Selected tests' (started|passed|failed) at /gm,
		"Test Suite 'All tests' $1 at "
	);
	const base = fullEvaluate(normalized, swiftStatus, captureStatus);
	let phase = 0,
		active = null,
		next = 0,
		invalid = false;
	const starts = new Set(),
		finishes = new Set();
	for (const line of clean.split('\n')) {
		if (!line.trim()) continue;
		const open = /^Test Suite '([^']+)' started at /.exec(line);
		const close = /^Test Suite '([^']+)' (passed|failed) at /.exec(line);
		const start = /^Test Case '([^']+)' started\.$/.exec(line);
		const finish =
			/^Test Case '([^']+)' (passed|failed|skipped) \([0-9]+(?:\.[0-9]+)? seconds?\)\.$/.exec(line);
		if (open) {
			const expected = ['Selected tests', 'ErgoptiPlusPackageTests.xctest', CLASS][phase];
			if (phase > 2 || open[1] !== expected || active !== null) invalid = true;
			phase++;
		} else if (start) {
			if (phase !== 3 || active !== null || !NAMES.includes(start[1]) || starts.has(start[1]))
				invalid = true;
			starts.add(start[1]);
			active = start[1];
		} else if (finish) {
			if (phase !== 3 || active !== finish[1] || finish[2] !== 'passed' || finishes.has(finish[1]))
				invalid = true;
			finishes.add(finish[1]);
			active = null;
		} else if (close) {
			const expected = [CLASS, 'ErgoptiPlusPackageTests.xctest', 'Selected tests'][next];
			if (
				phase !== 3 + next * 2 ||
				close[1] !== expected ||
				close[2] !== 'passed' ||
				active !== null
			)
				invalid = true;
			phase++;
		} else if (/^\s*Executed /.test(line)) {
			if (
				phase !== 4 + next * 2 ||
				!/^\s*Executed 3 tests, with 0 failures \(0 unexpected\) in [0-9]+(?:\.[0-9]+)?(?: \([0-9]+(?:\.[0-9]+)?\))? seconds$/.test(
					line
				)
			)
				invalid = true;
			phase++;
			next++;
		} else if (/^Test (Suite|Case) /.test(line)) invalid = true;
	}
	const inventory =
		starts.size === 3 &&
		finishes.size === 3 &&
		NAMES.every((name) => starts.has(name) && finishes.has(name));
	const complete =
		!invalid &&
		phase === 9 &&
		next === 3 &&
		active === null &&
		inventory &&
		base.complete &&
		base.failures.length === 0 &&
		base.script_status === 0 &&
		base.tee_status === 0;
	return {
		schema: 1,
		scope: 'native-logger-numeric-three',
		expected: 3,
		observed: finishes.size,
		complete,
		swift_status: base.script_status,
		capture_status: base.tee_status,
		packaged_ollama_qualified: false,
		full_package_qualified: false,
		exit_status: base.script_status || base.tee_status || (complete ? 0 : 1)
	};
}
/** Binds all compiler inputs and the independently frozen three-case inventory. */
const INPUTS = Object.freeze([
	'.github/workflows/ci-macos.yml',
	'.github/workflows/ci-macos-e2e.yml',
	'.github/ci/dev_release_qualification_exceptions.json',
	'.github/ci/stable_release_qualification_exception.json',
	'tools/diagnostics/native_logger_numeric_xctest_evidence.cjs',
	'tools/diagnostics/run_logger_numeric_native.sh',
	'tools/diagnostics/native_daemon_log_xctest_evidence.cjs',
	'tools/diagnostics/swift_xctest_evidence.cjs',
	'tools/diagnostics/native_pac_source_evidence.cjs',
	'tools/diagnostics/item36_xctest_evidence.cjs',
	'tools/ci/dev-release-qualification.cjs',
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/LoggerDatagramWorker.swift',
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/LoggerDatagramNumericTests.swift'
]);
function sourceReceipt(repository, epoch) {
	const admitted = context(epoch.candidate, epoch.run_id, epoch.run_attempt, epoch.architecture);
	const sources = { ...trackedSourceReceipt(repository, admitted.candidate).sources };
	for (const relative of INPUTS) {
		execFileSync('git', ['ls-files', '--error-unmatch', '--', relative], {
			cwd: repository,
			stdio: 'pipe'
		});
		const file = path.join(repository, relative);
		if (!fs.lstatSync(file).isFile()) throw new Error('Numeric logger source refused.');
		sources[relative] = crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
	}
	const relative = `static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${CLASS}.swift`;
	if (!Object.hasOwn(sources, relative)) throw new Error('Numeric logger tests unavailable.');
	const actual = [
		...fs.readFileSync(path.join(repository, relative), 'utf8').matchAll(/\bfunc (test\w+)\(/g)
	]
		.map((row) => row[1])
		.sort();
	if (JSON.stringify(actual) !== JSON.stringify([...METHODS].sort()))
		throw new Error('Numeric logger inventory changed.');
	return { schema: 1, scope: 'native-logger-numeric-three', ...admitted, sources };
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
				throw new Error('Numeric logger source epoch changed.');
			const result = {
				...evaluate(readBoundedRegular(args[1], 16777216), args[2], args[3]),
				source: after
			};
			fs.writeFileSync(args[9], JSON.stringify(result, null, 2) + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			console.log(
				`LOGGER_NUMERIC_XCTEST complete=${result.complete} cases=${result.observed}/3 packaged_ollama_qualified=false`
			);
			return result.exit_status;
		}
		throw new Error('Numeric logger evidence arguments refused.');
	} catch {
		console.error(
			'LOGGER_NUMERIC_XCTEST refused; original logger and full suite remain unqualified.'
		);
		return 1;
	}
}
module.exports = { CLASS, METHODS, NAMES, FILTER, INPUTS, evaluate, context, sourceReceipt, main };
if (require.main === module) process.exitCode = main(process.argv.slice(2));
