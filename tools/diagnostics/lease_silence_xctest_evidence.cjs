// tools/diagnostics/lease_silence_xctest_evidence.cjs
'use strict';

/** Receives one actual paired-process silence control; no real Karabiner or user fix proof. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { cleanTranscript } = require('./swift_xctest_evidence.cjs');
const { parseClosedJson } = require('../ci/dev-release-qualification.cjs');
const { readBoundedRegular } = require('./native_pac_source_evidence.cjs');
const SUITE = 'KarabinerLeaseWorkerTests';
const METHOD = 'testRealInnerSilenceExitZeroBecomesOuterFailureAfterReady';
const NAME = `-[ErgoptiPlusTests.${SUITE} ${METHOD}]`;
const FILTER = `(^|[.])${SUITE}[/.]${METHOD}$`;
const LAUNCHER = 'static/ergopti_plus/macos/launcher';
const EXTRA_INPUTS = Object.freeze([
	'.github/workflows/ci-macos.yml',
	'tools/diagnostics/lease_silence_xctest_evidence.cjs',
	'tools/diagnostics/run_lease_silence_native.sh',
	'tools/diagnostics/lease_silence_swift_child.sh',
	'tools/test/test-lease-silence-xctest-evidence.cjs',
	'tools/diagnostics/swift_xctest_evidence.cjs',
	'tools/diagnostics/native_pac_source_evidence.cjs',
	'tools/ci/dev-release-qualification.cjs'
]);
const METHOD_SHA = '0e8145115807b7c94c8ba4d6a91a16e8826894b73ae2232074da94571d2c8c32';
const ROLE_SHA = '3504a31d99ddefcc411e3772e0f747f441727f2d02f9c7e844ce3029dd05caf8';
const hash = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/** Admits only canonical original process exit statuses. */
function status(value) {
	if (!/^(?:0|[1-9][0-9]{0,2})$/.test(String(value)) || Number(value) > 255)
		throw new Error('Lease silence pipeline status refused.');
	return Number(value);
}

/** Requires one serial selected native case, every terminal summary, and original exits. */
function evaluate(text, swiftStatus, captureStatus) {
	const swift = status(swiftStatus),
		capture = status(captureStatus);
	const errors = [];
	const reject = (label) => {
		if (!errors.includes(label)) errors.push(label);
	};
	const frames = [
		"Test Suite 'Selected tests' started at ",
		"Test Suite 'ErgoptiPlusPackageTests.xctest' started at ",
		`Test Suite '${SUITE}' started at `,
		`Test Case '${NAME}' started.`,
		`Test Case '${NAME}' passed (`,
		`Test Suite '${SUITE}' passed at `,
		'summary',
		"Test Suite 'ErgoptiPlusPackageTests.xctest' passed at ",
		'summary',
		"Test Suite 'Selected tests' passed at ",
		'summary'
	];
	let next = 0,
		duration = null,
		terminals = 0;
	for (const line of cleanTranscript(text).split('\n')) {
		if (!line.trim()) continue;
		if (/^Test (Suite|Case) |^\s*Executed /.test(line)) {
			const expected = frames[next];
			if (expected === 'summary') {
				if (
					!/^\s*Executed 1 tests?, with 0 failures \(0 unexpected\) in [0-9]+(?:\.[0-9]+)?(?: \([0-9]+(?:\.[0-9]+)?\))? seconds$/.test(
						line
					)
				)
					reject('summary');
			} else if (!expected || !line.startsWith(expected)) reject('test-frame');
			if (next === 3 && line !== frames[3]) reject('start');
			if (next === 4) {
				const match = /^Test Case '.+' passed \(([0-9]+(?:\.[0-9]+)?) seconds?\)\.$/.exec(line);
				duration = match ? Number(match[1]) : null;
				if (duration === null || duration < 6.75 || duration > 60) reject('native-duration');
				if (line.startsWith(frames[4]) && match) terminals++;
			}
			next++;
		} else if (/(?:^|: )(?:fatal )?error: |\btests? skipped\b/.test(line))
			reject('native-diagnostic');
	}
	if (next !== frames.length || terminals !== 1) reject('incomplete');
	if (swift !== 0 || capture !== 0) reject('pipeline');
	return {
		schema: 1,
		scope: 'native-paired-lease-silence-only',
		complete: errors.length === 0,
		method: METHOD,
		observed: terminals === 1 ? 1 : 0,
		case_duration_seconds: duration !== null && duration >= 0 && duration <= 60 ? duration : null,
		script_status: swift,
		capture_status: capture,
		errors,
		native_karabiner_qualified: false,
		hammerspoon_scheduling_qualified: false,
		user_exit73_resolved: false,
		full_suite_qualified: false
	};
}

/** Requires the direct Swift result independently of PTY and capture wrappers. */
function evaluateDirect(text, swiftStatus, scriptStatus, captureStatus) {
	const swift = status(swiftStatus);
	const result = { ...evaluate(text, scriptStatus, captureStatus), swift_status: swift };
	if (swift !== 0) {
		result.complete = false;
		if (!result.errors.includes('pipeline')) result.errors.push('pipeline');
	}
	return result;
}

/** Admits only one canonical status written by the held direct-child descriptor. */
function parseChildStatus(text) {
	if (typeof text !== 'string' || !/^(?:0|[1-9][0-9]{0,2})\n$/.test(text))
		throw new Error('Lease silence direct child status refused.');
	return status(text.slice(0, -1));
}

/** Accepts only the exact candidate, run attempt and advertised native architecture. */
function context(candidate, runID, attempt, architecture) {
	if (
		!/^[0-9a-f]{40}$/.test(candidate) ||
		!/^[1-9][0-9]{0,19}$/.test(runID) ||
		!/^[1-9][0-9]{0,5}$/.test(attempt) ||
		!['arm64', 'amd64'].includes(architecture)
	)
		throw new Error('Lease silence source epoch refused.');
	return { candidate, run_id: runID, run_attempt: attempt, architecture };
}

/** Hashes exact regular compiler input bytes without following links or unbounded reads. */
function inputHash(file) {
	const fd = fs.openSync(
		file,
		fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK
	);
	try {
		const before = fs.fstatSync(fd),
			named = fs.lstatSync(file);
		if (
			!before.isFile() ||
			before.size > 1048576 ||
			before.dev !== named.dev ||
			before.ino !== named.ino
		)
			throw new Error('Lease silence compiler input refused.');
		const bytes = Buffer.alloc(before.size + 1);
		let length = 0;
		while (length < bytes.length) {
			const count = fs.readSync(fd, bytes, length, bytes.length - length, null);
			if (count === 0) break;
			length += count;
		}
		const after = fs.fstatSync(fd),
			final = fs.lstatSync(file);
		if (
			length !== before.size ||
			after.size !== before.size ||
			after.mtimeMs !== before.mtimeMs ||
			after.dev !== final.dev ||
			after.ino !== final.ino
		)
			throw new Error('Lease silence compiler input changed.');
		return hash(bytes.subarray(0, length));
	} finally {
		fs.closeSync(fd);
	}
}

/** Keeps the selected method and no-effect helper coupled to their independently frozen native bodies. */
function validateNativeSources(test, worker) {
	const declaration = `\tfunc ${METHOD}(`;
	if (test.split(declaration).length !== 2) throw new Error('Lease silence method unavailable.');
	const start = test.indexOf(declaration),
		end = test.indexOf('\n\t#endif', start);
	if (end < 0 || hash(test.slice(start, end)) !== METHOD_SHA)
		throw new Error('Lease silence method changed.');
	const marker = '\tcase "lease-inner-silence":';
	if (worker.split(marker).length !== 2)
		throw new Error('Lease silence test-only role unavailable.');
	const role = worker.indexOf(marker),
		roleEnd = worker.indexOf('\n\tcase ', role + 1);
	if (roleEnd < 0 || hash(worker.slice(role, roleEnd)) !== ROLE_SHA)
		throw new Error('Lease silence test-only role changed.');
}

/** Binds every native compiler input and the owning runner before and after execution. */
function sourceReceipt(repository, epoch) {
	const admitted = context(epoch.candidate, epoch.run_id, epoch.run_attempt, epoch.architecture);
	const machine = admitted.architecture === 'arm64' ? 'arm64' : 'x64';
	const runner = admitted.architecture === 'arm64' ? 'ARM64' : 'X64';
	if (
		process.platform !== 'darwin' ||
		process.arch !== machine ||
		process.env.RUNNER_ARCH !== runner ||
		process.env.GITHUB_ACTIONS !== 'true' ||
		process.env.GITHUB_EVENT_NAME !== 'workflow_dispatch' ||
		process.env.ERGOPTI_DEV_RELEASE_RELEASE !== 'false' ||
		process.env.GITHUB_SHA !== admitted.candidate ||
		process.env.GITHUB_RUN_ID !== admitted.run_id ||
		process.env.GITHUB_RUN_ATTEMPT !== admitted.run_attempt
	)
		throw new Error('Lease silence native host epoch refused.');
	const git = (args) =>
		execFileSync('git', args, { cwd: repository, encoding: 'utf8', stdio: 'pipe' });
	if (git(['rev-parse', 'HEAD']).trim() !== admitted.candidate)
		throw new Error('Lease silence HEAD changed.');
	git(['diff', '--exit-code', 'HEAD', '--']);
	const extras = git([
		'ls-files',
		'--others',
		'-z',
		'--',
		`${LAUNCHER}/Sources`,
		`${LAUNCHER}/Tests`
	])
		.split('\0')
		.filter(Boolean);
	const manifests = git(['ls-files', '--others', '-z', '--', LAUNCHER])
		.split('\0')
		.filter((file) => /^Package(?:@swift-[0-9.]+)?\.swift$/.test(file.slice(LAUNCHER.length + 1)));
	if (extras.length || manifests.length) throw new Error('Lease silence unbound compiler input.');
	for (const relative of EXTRA_INPUTS) git(['ls-files', '--error-unmatch', '--', relative]);
	const files = [
		...new Set(
			git(['ls-files', '-z', '--', LAUNCHER, ...EXTRA_INPUTS])
				.split('\0')
				.filter(Boolean)
		)
	].sort();
	if (!files.length || files.length > 4096)
		throw new Error('Lease silence source inventory refused.');
	const sources = Object.fromEntries(
		files.map((relative) => [relative, inputHash(path.join(repository, relative))])
	);
	validateNativeSources(
		readBoundedRegular(
			path.join(repository, LAUNCHER, 'Tests/ErgoptiPlusTests/RemapLeaseWorkerTests.swift'),
			1048576
		),
		readBoundedRegular(
			path.join(repository, LAUNCHER, 'Sources/ErgoptiPlus/RemapLeaseWorker.swift'),
			1048576
		)
	);
	return { schema: 1, scope: 'native-paired-lease-silence-only', ...admitted, sources };
}

/** Writes only closed source facts and verdicts, never raw log snippets or private paths. */
function main(args, repository = path.resolve(__dirname, '../..')) {
	try {
		if (args.length === 6 && args[0] === 'begin') {
			fs.writeFileSync(
				args[5],
				JSON.stringify(sourceReceipt(repository, context(...args.slice(1, 5))), null, 2) + '\n',
				{ flag: 'wx', mode: 0o600 }
			);
			return 0;
		}
		if (args.length === 11 && args[0] === 'judge') {
			const epoch = context(...args.slice(5, 9));
			const before = parseClosedJson(readBoundedRegular(args[9], 1048576));
			const after = sourceReceipt(repository, epoch);
			if (JSON.stringify(before) !== JSON.stringify(after))
				throw new Error('Lease silence source epoch changed.');
			const result = {
				...evaluateDirect(
					readBoundedRegular(args[1], 16777216),
					parseChildStatus(readBoundedRegular(args[2], 4)),
					args[3],
					args[4]
				),
				source: after
			};
			fs.writeFileSync(args[10], JSON.stringify(result, null, 2) + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			console.log(
				`LEASE_SILENCE_XCTEST complete=${result.complete} cases=${result.observed}/1 user_exit73_resolved=false`
			);
			return result.complete ? 0 : 1;
		}
		throw new Error('Lease silence evidence arguments refused.');
	} catch {
		console.error(
			'LEASE_SILENCE_XCTEST refused; native Karabiner and user incident remain unqualified.'
		);
		return 1;
	}
}
module.exports = {
	SUITE,
	METHOD,
	NAME,
	FILTER,
	evaluate,
	evaluateDirect,
	parseChildStatus,
	context,
	validateNativeSources,
	sourceReceipt,
	main
};
if (require.main === module) process.exitCode = main(process.argv.slice(2));
