// tools/diagnostics/swift_xctest_evidence.cjs

/**
 * Owns the verdict and failure annotations of the captured native XCTest run.
 * A PTY exit, a trailing Swift Testing summary or a partial suite cannot replace
 * completed XCTest evidence. The original script/tee exit status stays decisive.
 */
'use strict';

const fs = require('node:fs');
const path = require('node:path');

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

// Independent closed vocabulary. Native identities/properties are deliberately
// absent: a phase is an observation boundary, never a diagnosis or completion.
const observationPhases = [
	'original.capture',
	'target.inventory',
	'body.before',
	'body.after',
	'translation.snapshot',
	'event.before',
	'event.after',
	'probe.before',
	'probe.after',
	'probe.snapshot',
	'probe.refused.invalidArguments',
	'probe.refused.sourceChanged',
	'probe.refused.unavailableLayout',
	'probe.refused.translationFailed',
	'probe.refused.invalidUnicode',
	'probe.refused.unclassified',
	...['enable', 'disable', 'select', 'restore.inner', 'restore.outer'].flatMap((phase) => [
		phase + '.before',
		phase + '.after'
	])
];
const witnessPhases = new Set([
	...observationPhases.flatMap((phase) => [
		phase + '.observe.entered',
		phase + '.observe.completed'
	]),
	...[
		'enable',
		'disable',
		'select',
		'restore.inner',
		'restore.outer',
		'probe',
		'original.capture',
		'target.list',
		'target.enabledProperty'
	].flatMap((phase) => [phase + '.call.entered', phase + '.call.returned']),
	'probe.call.refused',
	'probe.terminalID.returned',
	'unclassified',
	'overflow'
]);

/** Retains three closed scalar witnesses, never arbitrary native JSON/text. */
function keyboardPhases(lines) {
	const result = { accepted: 0, refused: 0, count_saturated: false, last: [] };
	const count = (key) => {
		if (result[key] < 1_000_000) result[key]++;
		else result.count_saturated = true;
	};
	for (const line of lines) {
		if (!line.startsWith('TIS_TEST_PHASE ')) continue;
		const payload = line.slice('TIS_TEST_PHASE '.length);
		let record;
		try {
			if (Buffer.byteLength(payload, 'utf8') > 256) throw new Error('bounded');
			record = JSON.parse(payload);
			if (
				!record ||
				Array.isArray(record) ||
				typeof record !== 'object' ||
				Object.keys(record).sort().join(',') !== 'phase,sequence,version' ||
				['phase', 'sequence', 'version'].some(
					(key) => (payload.match(new RegExp('"' + key + '"\\s*:', 'g')) || []).length !== 1
				) ||
				record.version !== 1 ||
				!Number.isInteger(record.sequence) ||
				record.sequence < 1 ||
				record.sequence > 129 ||
				typeof record.phase !== 'string' ||
				!witnessPhases.has(record.phase)
			)
				throw new Error('closed');
		} catch {
			count('refused');
			continue;
		}
		count('accepted');
		result.last.push(record.phase);
		if (result.last.length > 3) result.last.shift();
	}
	return result;
}

/** One accessible failure-only notice; every displayed value is allowlisted. */
function phaseAnnotation(evidence) {
	const message =
		'Keyboard diagnostic boundaries observed; cause remains unqualified. ' +
		`accepted=${evidence.accepted}; refused=${evidence.refused}; ` +
		`countSaturated=${evidence.count_saturated}; last=` +
		(evidence.last.length ? evidence.last.join(', ') : 'unobserved');
	return '::notice title=Native keyboard phase witness::' + escapeData(message);
}

/** Judges the serial, unfiltered XCTest transcript independently of process zero. */
function evaluate(text, scriptStatus, teeStatus, repository = path.resolve(__dirname, '../..')) {
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
		if (/^Test Suite 'All tests' started at /.test(line)) rootStarts++;
		if (/^Test Suite 'All tests' (passed|failed) at /.test(line)) {
			rootFinishes++;
			rootPassed = /^Test Suite 'All tests' passed at /.test(line);
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
		schema_version: 1,
		script_status: script,
		tee_status: tee,
		complete,
		summary: rootSummary,
		completed_tests: completed,
		failures,
		keyboard_phase_witnesses: keyboardPhases(lines),
		exit_status: script || tee || (failures.length ? 1 : 0)
	};
}

/** Emits exact causes and persists the verdict beside the uploaded transcript. */
function main(args = process.argv.slice(2), log = console.log) {
	let script = 0;
	let tee = 0;
	try {
		if (args.length !== 4)
			throw new Error('Expected transcript path, script status, tee status and verdict path.');
		script = exitStatus(args[1]);
		tee = exitStatus(args[2]);
		const result = evaluate(fs.readFileSync(args[0], 'utf8'), script, tee);
		fs.writeFileSync(args[3], JSON.stringify(result, null, '\t') + '\n');
		for (const failure of result.failures) log(annotation(failure));
		if (result.exit_status !== 0) log(phaseAnnotation(result.keyboard_phase_witnesses));
		log(
			`[Swift XCTest] ${result.completed_tests.length} completed test(s); script=${script}; capture=${tee}; verdict=${result.exit_status}.`
		);
		return result.exit_status;
	} catch (error) {
		log(annotation({ message: 'Swift XCTest evidence could not be judged: ' + error.message }));
		return script || tee || 1;
	}
}

module.exports = { annotation, cleanTranscript, evaluate, keyboardPhases, phaseAnnotation, main };
if (require.main === module) process.exitCode = main();
