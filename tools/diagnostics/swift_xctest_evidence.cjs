// tools/diagnostics/swift_xctest_evidence.cjs

/**
 * Owns the verdict and failure annotations of the captured native XCTest run.
 * A PTY exit, a trailing Swift Testing summary or a partial suite cannot replace
 * completed XCTest evidence. The original script/tee exit status stays decisive.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

const pacAdmissions = new WeakSet();

/** Reuses the actual PAC method owner; the selected family is never a guessed regex. */
function pacClasses() {
	return Object.keys(require('./managed_http_pac_xctest_evidence.cjs').METHODS);
}

/** Admits only the same existing PAC scope and current source/context/expiry. */
function pacQualification(receipt, env = process.env, now = new Date()) {
	const q = require('../ci/dev-release-qualification.cjs');
	const mode = q.scopeDisposition(
		receipt,
		'macos-native-pac',
		env.GITHUB_SHA,
		q.environmentContext(env),
		now
	);
	const admission = Object.freeze({
		mode,
		source_sha: env.GITHUB_SHA,
		profile_id: receipt.profile_id
	});
	pacAdmissions.add(admission);
	return admission;
}

function readPacQualification(file) {
	const q = require('../ci/dev-release-qualification.cjs');
	return pacQualification(q.parseClosedJson(fs.readFileSync(file, 'utf8')));
}

function rootPattern(admission) {
	if (admission === null) return 'All tests';
	if (!pacAdmissions.has(admission)) throw new TypeError('Unadmitted PAC qualification.');
	return admission.mode === 'deferred' ? 'Selected tests' : 'All tests';
}

function pacSkipPattern(admission) {
	rootPattern(admission);
	if (admission === null || admission.mode !== 'deferred')
		throw new Error('PAC execution may only be omitted under its active scope.');
	return '^ErgoptiPlusTests[.](?:' + pacClasses().join('|') + ')/';
}

function isDeferredPacCase(name, admission) {
	return (
		admission !== null &&
		admission.mode === 'deferred' &&
		pacClasses().some(
			(suite) =>
				name.startsWith('-[ErgoptiPlusTests.' + suite + ' ') ||
				name.startsWith('ErgoptiPlusTests.' + suite + '.') ||
				name.startsWith('ErgoptiPlusTests.' + suite + '/')
		)
	);
}

/** Removes PTY styling and normalizes line endings without changing Unicode. */
function cleanTranscript(text) {
	return text
		.replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, '')
		.replace(/\x1b\[[0-?]*[ -/]*[@-~]/g, '')
		.replace(/\r\n?/g, '\n');
}

/** Escapes workflow command data, including literal annotation-looking text. */
function escapeData(text) {
	return String(text).replaceAll('%', '%25').replaceAll('\r', '%0D').replaceAll('\n', '%0A');
}

/** Makes one failure readable on the check run without executing its content. */
function annotation(failure) {
	const fields = ['title=Swift XCTest failure'];
	if (failure.file)
		fields.push('file=' + escapeData(failure.file).replaceAll(',', '%2C').replaceAll(':', '%3A'));
	if (failure.line) fields.push('line=' + failure.line);
	return '::error ' + fields.join(',') + '::' + escapeData(failure.message);
}

/** Accepts only actual process exit statuses supplied by the owning pipeline. */
function exitStatus(value) {
	if (!/^(?:0|[1-9]\d{0,2})$/.test(String(value)) || Number(value) > 255)
		throw new TypeError('Swift transcript pipeline statuses must be integers from 0 through 255.');
	return Number(value);
}

/** Judges the serial, unfiltered XCTest transcript independently of process zero. */
function evaluate(
	text,
	scriptStatus,
	teeStatus,
	repository = path.resolve(__dirname, '../..'),
	admission = null
) {
	const root = rootPattern(admission);
	const rootStart = new RegExp("^Test Suite '" + root + "' started at ");
	const rootFinish = new RegExp("^Test Suite '" + root + "' (passed|failed) at ");
	const rootPass = new RegExp("^Test Suite '" + root + "' passed at ");
	const script = exitStatus(scriptStatus);
	const tee = exitStatus(teeStatus);
	const lines = cleanTranscript(text).split('\n');
	const failures = [];
	const completed = [];
	let rootStarts = 0;
	let rootFinishes = 0;
	const started = new Set();
	let rootPassed = false;
	let rootSummary = null;
	let awaitingSummary = false;
	for (const line of lines) {
		if (rootStart.test(line)) rootStarts++;
		if (rootFinish.test(line)) {
			rootFinishes++;
			rootPassed = rootPass.test(line);
			awaitingSummary = true;
			if (!rootPassed) failures.push({ message: 'The complete XCTest suite reported failure.' });
			continue;
		}
		if (awaitingSummary && line.trim()) {
			const count = /^\s*Executed (\d+) tests?, with (\d+) failures? \((\d+) unexpected\) in /.exec(
				line
			);
			rootSummary = count
				? { tests: Number(count[1]), failures: Number(count[2]), unexpected: Number(count[3]) }
				: null;
			awaitingSummary = false;
		}
		const diagnostic = /^(.+\.swift):(\d+)(?::\d+)?: (?:fatal )?error: (.+)$/.exec(line);
		if (diagnostic) {
			const absolute = path.resolve(diagnostic[1]);
			const relative = path.relative(repository, absolute);
			failures.push({
				file:
					relative.startsWith('..' + path.sep) || path.isAbsolute(relative)
						? undefined
						: relative.replaceAll('\\', '/'),
				line: Number(diagnostic[2]),
				message: diagnostic[3]
			});
		}
		if (/^error: /.test(line)) failures.push({ message: line.slice(7) });
		const starting = /^Test Case '(.+)' started\.$/.exec(line);
		if (starting) started.add(starting[1]);
		const testcase = /^Test Case '(.+)' (passed|failed|skipped) \(/.exec(line);
		if (testcase) {
			completed.push({ name: testcase[1], result: testcase[2] });
			if (testcase[2] === 'failed')
				failures.push({ message: 'Failed XCTest case: ' + testcase[1] });
			if (testcase[2] === 'skipped')
				failures.push({ message: 'Skipped XCTest case: ' + testcase[1] });
		}
	}
	for (const name of started)
		if (!completed.some((test) => test.name === name))
			failures.push({ message: 'XCTest case did not complete: ' + name });
	for (const name of started)
		if (isDeferredPacCase(name, admission))
			failures.push({ message: 'A deferred PAC case was unexpectedly executed.' });
	const complete =
		rootStarts === 1 &&
		rootFinishes === 1 &&
		rootPassed &&
		rootSummary !== null &&
		rootSummary.tests > 0 &&
		rootSummary.failures === 0 &&
		rootSummary.unexpected === 0 &&
		completed.length === rootSummary.tests &&
		started.size === rootSummary.tests &&
		completed.every((test) => test.result === 'passed' && started.has(test.name)) &&
		new Set(completed.map((test) => test.name)).size === completed.length;
	if (!complete)
		failures.push({
			message:
				'The XCTest process ended without its complete successful suite summary and every test-case receipt.'
		});
	if (script !== 0)
		failures.push({ message: `The native Swift/PTY command exited with status ${script}.` });
	if (tee !== 0) failures.push({ message: `XCTest transcript capture exited with status ${tee}.` });
	return {
		...(admission !== null && admission.mode === 'deferred'
			? {
					qualification: {
						scope: 'macos-native-pac',
						status: 'deferred',
						qualified: false,
						classes: pacClasses(),
						source_sha: admission.source_sha,
						profile_id: admission.profile_id
					}
				}
			: {}),
		schema_version: 1,
		script_status: script,
		tee_status: tee,
		complete,
		summary: rootSummary,
		completed_tests: completed,
		failures,
		exit_status: script || tee || (failures.length ? 1 : 0)
	};
}

/** Fixed native archive cases; arbitrary child text never becomes a notice field. */
const archiveCases = Object.freeze([
	[
		'brew',
		'-[ErgoptiPlusTests.HomebrewArchiveAcceptanceTests testRealBrewZIPInstallXZUpgradeAndRefusalsPreserveInstalledState]'
	],
	[
		'sparkle',
		'-[ErgoptiPlusTests.SparkleArchiveUpdateAcceptanceTests testActualSparkleTarXZUpdateRefusesWrongKeyPreservesOldAppAndRetriesThroughRelaunch]'
	]
]);

/** Projects authentic case completion independently of another case's failure. */
function archiveOutcomes(text, scriptStatus, teeStatus, admission = null) {
	const root = rootPattern(admission);
	const rootStart = new RegExp("^Test Suite '" + root + "' started at ");
	const rootFinish = new RegExp("^Test Suite '" + root + "' (passed|failed) at ");
	const script = exitStatus(scriptStatus);
	const tee = exitStatus(teeStatus);
	const unavailable = () =>
		archiveCases.map(([label]) => ({
			schema: 1,
			case: label,
			outcome: 'UNAVAILABLE',
			basis: 'unavailable',
			script_status: script,
			capture_status: tee
		}));
	if (tee !== 0) return unavailable();
	let state = 'before';
	let active = null;
	let rootResult = null;
	let summary = null;
	let invalid = false;
	const starts = new Set();
	const terminals = new Map();
	for (const line of cleanTranscript(text).split('\n')) {
		if (rootStart.test(line)) {
			if (state !== 'before') invalid = true;
			state = 'running';
			continue;
		}
		const finish = rootFinish.exec(line);
		if (finish) {
			if (state !== 'running' || active !== null) invalid = true;
			rootResult = finish[1];
			state = 'summary';
			continue;
		}
		if (state === 'summary' && line.trim()) {
			const count =
				/^\s*Executed (\d+) tests?, with (?:(\d+) tests? skipped and )?(\d+) failures? \((\d+) unexpected\) in /.exec(
					line
				);
			if (!count) invalid = true;
			else {
				summary = {
					tests: Number(count[1]),
					skipped: Number(count[2] || 0),
					failures: Number(count[3]),
					unexpected: Number(count[4])
				};
				if (
					!Object.values(summary).every((value) => Number.isSafeInteger(value) && value <= 1000000)
				)
					invalid = true;
			}
			state = 'after';
		}
		const start = /^Test Case '(.+)' started\.$/.exec(line);
		const terminal = /^Test Case '(.+)' (passed|failed|skipped) \(\d+(?:\.\d+)? seconds?\)\.$/.exec(
			line
		);
		if (start) {
			if (isDeferredPacCase(start[1], admission)) invalid = true;
			if (state !== 'running' || active !== null || starts.has(start[1])) invalid = true;
			starts.add(start[1]);
			active = start[1];
		} else if (terminal) {
			if (state !== 'running' || active !== terminal[1] || terminals.has(terminal[1]))
				invalid = true;
			terminals.set(terminal[1], terminal[2]);
			active = null;
		} else if (/^Test Case /.test(line)) invalid = true;
	}
	const failed = [...terminals.values()].filter((value) => value === 'failed').length;
	const skipped = [...terminals.values()].filter((value) => value === 'skipped').length;
	if (
		invalid ||
		state !== 'after' ||
		active !== null ||
		summary === null ||
		summary.tests === 0 ||
		starts.size !== summary.tests ||
		terminals.size !== summary.tests ||
		[...starts].some((name) => !terminals.has(name)) ||
		summary.skipped !== skipped ||
		summary.failures < failed ||
		summary.unexpected > summary.failures ||
		(rootResult === 'passed' && (summary.failures !== 0 || failed !== 0 || script !== 0)) ||
		(rootResult === 'failed' && summary.failures === 0)
	)
		return unavailable();
	const outcomes = { passed: 'PASS', failed: 'FAIL', skipped: 'SKIP' };
	return archiveCases.map(([label, name]) => ({
		schema: 1,
		case: label,
		outcome: outcomes[terminals.get(name)] || 'UNAVAILABLE',
		basis: terminals.has(name) ? 'exact-xctest-completion' : 'unavailable',
		script_status: script,
		capture_status: tee
	}));
}

/** Only closed labels/statuses cross the check API; no native diagnostic bytes. */
function archiveAnnotation(receipt) {
	if (
		receipt.schema !== 1 ||
		!archiveCases.some(([label]) => label === receipt.case) ||
		!['PASS', 'FAIL', 'SKIP', 'UNAVAILABLE'].includes(receipt.outcome) ||
		receipt.basis !==
			(receipt.outcome === 'UNAVAILABLE' ? 'unavailable' : 'exact-xctest-completion')
	)
		throw new TypeError('Invalid native archive XCTest receipt.');
	return (
		'::notice title=Native archive XCTest outcome::' +
		JSON.stringify({
			schema: 1,
			case: receipt.case,
			outcome: receipt.outcome,
			basis: receipt.basis,
			script_status: exitStatus(receipt.script_status),
			capture_status: exitStatus(receipt.capture_status)
		})
	);
}

/** Emits exact causes and persists the verdict beside the uploaded transcript. */
function main(args = process.argv.slice(2), log = console.log) {
	let script = 0;
	let tee = 0;
	try {
		if (args.length !== 4 && !(args.length === 6 && args[4] === '--pac-qualification-receipt'))
			throw new Error('Expected transcript path, script status, tee status and verdict path.');
		script = exitStatus(args[1]);
		tee = exitStatus(args[2]);
		const transcript = fs.readFileSync(args[0], 'utf8');
		const admission = args.length === 6 ? readPacQualification(args[5]) : null;
		const result = evaluate(transcript, script, tee, undefined, admission);
		result.archive_outcomes = archiveOutcomes(transcript, script, tee, admission);
		fs.writeFileSync(args[3], JSON.stringify(result, null, '\t') + '\n');
		for (const receipt of result.archive_outcomes) log(archiveAnnotation(receipt));
		for (const failure of result.failures) log(annotation(failure));
		log(
			`[Swift XCTest] ${result.completed_tests.length} completed test(s); script=${script}; capture=${tee}; verdict=${result.exit_status}.`
		);
		return result.exit_status;
	} catch (error) {
		for (const receipt of archiveOutcomes('', script, tee)) log(archiveAnnotation(receipt));
		log(annotation({ message: 'Swift XCTest evidence could not be judged: ' + error.message }));
		return script || tee || 1;
	}
}

module.exports = {
	pacQualification,
	readPacQualification,
	pacSkipPattern,
	annotation,
	archiveAnnotation,
	archiveOutcomes,
	cleanTranscript,
	evaluate,
	main
};
if (require.main === module) {
	const args = process.argv.slice(2);
	if (args.length === 2 && args[0] === '--pac-skip-pattern') {
		process.stdout.write(pacSkipPattern(readPacQualification(args[1])));
	} else process.exitCode = main();
}
