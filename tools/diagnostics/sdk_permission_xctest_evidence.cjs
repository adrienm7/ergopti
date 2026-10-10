// tools/diagnostics/sdk_permission_xctest_evidence.cjs
'use strict';

/** Judges one real SDK metadata observation; never qualifies another caller or a catalogue. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { cleanTranscript } = require('./swift_xctest_evidence.cjs');
const item36 = require('./item36_xctest_evidence.cjs');

const METHOD = 'testActualNoPromptPermissionAPIOnlyPublishesRetiredMetadata';
const SUITE = 'OwnedAutomationQueryWorkerTests';
const NAME = `-[ErgoptiPlusTests.${SUITE} ${METHOD}]`;
const FILTER = `${SUITE}.${METHOD}`;
const STEP = 'Observe the actual no-prompt SDK permission API independently';
const MARKER =
	'SDK_PERMISSION_OBSERVATION caller=native-test-product target=shortcuts-events' +
	' event_class=core event_id=getd ask_user=0 nonce=19 osstatus=';

/** Accepts original process exit statuses without coercing partial or signaled runs. */
function status(value) {
	if (!/^(?:0|[1-9][0-9]{0,2})$/.test(String(value)) || Number(value) > 255)
		throw new Error('Unadmitted SDK observation pipeline status.');
	return Number(value);
}

/** Accepts exactly one serial selected XCTest and one in-case canonical SDK result. */
function evaluate(text, scriptStatus, teeStatus) {
	const script = status(scriptStatus),
		tee = status(teeStatus);
	const errors = [];
	const reject = (reason) => {
		if (!errors.includes(reason)) errors.push(reason);
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
		observations = 0,
		code = null;
	for (const line of cleanTranscript(text).split('\n')) {
		if (!line.trim()) continue;
		if (line.includes('SDK_PERMISSION_OBSERVATION')) {
			observations++;
			const raw = line.startsWith(MARKER) ? line.slice(MARKER.length) : '';
			const numeric = Number(raw);
			if (
				next !== 4 ||
				observations !== 1 ||
				!/^-?(?:0|[1-9][0-9]*)$/.test(raw) ||
				!Number.isInteger(numeric) ||
				numeric < -2147483648 ||
				numeric > 2147483647 ||
				String(numeric) !== raw
			)
				reject('unadmitted-sdk-marker');
			else code = numeric;
			continue;
		}
		if (/^Test (Suite|Case) |^\s*Executed /.test(line)) {
			const expected = frames[next];
			if (expected === 'summary') {
				if (!/^\s*Executed 1 tests?, with 0 failures? \(0 unexpected\) in /.test(line))
					reject('summary');
			} else if (!expected || !line.startsWith(expected)) reject('test-frame');
			if (next === 4 && !/^Test Case '.+' passed \([0-9]+(?:\.[0-9]+)? seconds?\)\.$/.test(line))
				reject('terminal');
			next++;
		} else if (/(?:^|: )(?:fatal )?error: |\btests? skipped\b/.test(line))
			reject('native-diagnostic');
	}
	if (next !== frames.length || observations !== 1 || code === null) reject('incomplete');
	if (script !== 0 || tee !== 0) reject('pipeline');
	return {
		schema: 1,
		scope: 'native-test-product-sdk-permission-metadata-only',
		complete: errors.length === 0,
		method: METHOD,
		osstatus: code,
		caller: 'native-test-product',
		catalogue_qualified: false,
		signed_application_qualified: false,
		osascript_principal_qualified: false,
		script_status: script,
		capture_status: tee,
		errors
	};
}

/** Reads only stable bounded regular files through their original descriptor. */
function readBoundedRegular(file, maximum) {
	const descriptor = fs.openSync(
		file,
		fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK
	);
	try {
		const before = fs.fstatSync(descriptor),
			named = fs.lstatSync(file);
		if (
			!before.isFile() ||
			before.size > maximum ||
			before.dev !== named.dev ||
			before.ino !== named.ino
		)
			throw new Error('Unadmitted SDK observation capture.');
		const bytes = fs.readFileSync(descriptor);
		const after = fs.fstatSync(descriptor),
			final = fs.lstatSync(file);
		if (
			bytes.length !== before.size ||
			after.size !== before.size ||
			after.mtimeMs !== before.mtimeMs ||
			after.dev !== final.dev ||
			after.ino !== final.ino
		)
			throw new Error('SDK observation capture changed.');
		return new TextDecoder('utf-8', { fatal: true }).decode(bytes);
	} finally {
		fs.closeSync(descriptor);
	}
}

/** Keeps the source-bound marker coupled to the production API and exact native retirement. */
function validateNativeSources(source, worker) {
	const declaration = `func ${METHOD}(`;
	if (source.split(declaration).length !== 2)
		throw new Error('SDK observation method unavailable.');
	const start = source.indexOf(declaration);
	const boundary = source.indexOf('\n\tfunc ', start);
	if (boundary < 0) throw new Error('SDK observation method boundary unavailable.');
	const body = source.slice(start, boundary);
	for (const required of [
		'operation: OwnedAutomationQueryWorker.permissionObservationOperation',
		'try session.activate()',
		'try session.finish()',
		'OwnedAutomationQueryWorker.bridgePacketMatches(raw, arguments: arguments)',
		'session.markers == ["Q1 HELD", data, "Q1 RETIRED 0"]',
		'session.process.terminationReason == .exit, session.process.terminationStatus == 0',
		'session.stderr.isEmpty, session.decoder.buffered.isEmpty',
		'guard packet["observation"] as? String == "native-returned"',
		'let code = try XCTUnwrap(Int32(exactly: status.int64Value))',
		'SDK_PERMISSION_OBSERVATION caller=native-test-product',
		'let observation = "SDK_PERMISSION_OBSERVATION caller=native-test-product',
		'nonce=19 osstatus=\\(code)\\n"',
		'try FileHandle.standardError.write(contentsOf: Data(observation.utf8))'
	])
		if (!body.includes(required)) throw new Error('SDK observation source contract refused.');
	if (body.includes('permissionObservationPacket(') || body.includes('XCTSkip'))
		throw new Error('Constructed packets cannot qualify SDK execution.');
	if (
		!worker.includes(
			'if operation == permissionObservationOperation { return permissionObservationRole(nonce: nonce) }'
		)
	)
		throw new Error('SDK production dispatch unavailable.');
	const role = worker.slice(worker.indexOf('private static func permissionObservationRole'));
	if (
		!role.includes('Array("com.apple.shortcuts.events".utf8)') ||
		!role.includes(
			'AEDeterminePermissionToAutomateTarget(&target, kAECoreSuite, kAEGetData, false)'
		) ||
		role.includes('SBApplication')
	)
		throw new Error('Real no-prompt SDK operation unavailable.');
}

/** Binds all original native inputs plus the observation's owning pipeline and guards. */
function sourceReceipt(repository, candidate) {
	const original = item36.sourceReceipt(repository, candidate);
	const run =
		process.env.GITHUB_ACTIONS === 'true'
			? { id: process.env.GITHUB_RUN_ID, attempt: process.env.GITHUB_RUN_ATTEMPT }
			: null;
	if (run && (!/^[1-9][0-9]*$/.test(run.id || '') || !/^[1-9][0-9]*$/.test(run.attempt || '')))
		throw new Error('SDK observation run identity unavailable.');
	const sources = { ...original.sources };
	for (const relative of [
		'.github/workflows/ci-macos.yml',
		'tools/test/test-macos-swift-launcher-ci.cjs',
		'tools/test/test-macos-dev-qualification-deferral.cjs'
	]) {
		execFileSync('git', ['ls-files', '--error-unmatch', '--', relative], {
			cwd: repository,
			stdio: 'pipe'
		});
		const bytes = readBoundedRegular(path.join(repository, relative), 1048576);
		sources[relative] = crypto.createHash('sha256').update(bytes).digest('hex');
	}
	const relative = `static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/${SUITE}.swift`;
	if (
		!Object.hasOwn(sources, relative) ||
		!Object.hasOwn(sources, 'tools/diagnostics/sdk_permission_xctest_evidence.cjs')
	)
		throw new Error('SDK observation source unavailable.');
	const worker =
		'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/OwnedAutomationQueryWorker.swift';
	if (!Object.hasOwn(sources, worker)) throw new Error('SDK worker source unavailable.');
	validateNativeSources(
		readBoundedRegular(path.join(repository, relative), 1048576),
		readBoundedRegular(path.join(repository, worker), 1048576)
	);
	return {
		schema: 1,
		scope: 'native-test-product-sdk-permission-metadata-only',
		candidate,
		run,
		sources
	};
}

/** Refuses forged or stale begin receipts before admitting captured metadata. */
function judge(repository, candidate, before, text, scriptStatus, teeStatus) {
	const after = sourceReceipt(repository, candidate);
	if (JSON.stringify(before) !== JSON.stringify(after))
		throw new Error('SDK observation source changed.');
	return { ...evaluate(text, scriptStatus, teeStatus), source: after };
}

/** Keeps begin/judge source admission independent of the earlier archive cohort's result. */
function main(args, repository = path.resolve(__dirname, '../..')) {
	try {
		if (process.platform !== 'darwin') throw new Error('Real macOS SDK receiving is required.');
		if (
			process.env.GITHUB_ACTIONS !== 'true' ||
			(args[0] === 'begin' ? args[1] : args[4]) !== process.env.GITHUB_SHA
		)
			throw new Error('The actual native workflow candidate is required.');
		if (args.length === 3 && args[0] === 'begin') {
			const receipt = sourceReceipt(repository, args[1]);
			fs.writeFileSync(args[2], JSON.stringify(receipt, null, '\t') + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			return 0;
		}
		if (args.length !== 7 || args[0] !== 'judge')
			throw new Error('SDK observation evidence arguments refused.');
		const before = JSON.parse(readBoundedRegular(args[5], 1048576));
		const receipt = judge(
			repository,
			args[4],
			before,
			readBoundedRegular(args[1], 16777216),
			args[2],
			args[3]
		);
		fs.writeFileSync(args[6], JSON.stringify(receipt, null, '\t') + '\n', {
			flag: 'wx',
			mode: 0o600
		});
		console.log(
			`::notice title=SDK permission metadata::complete=${receipt.complete} caller=native-test-product catalogue_qualified=false candidate=${receipt.source.candidate}` +
				` script_status=${receipt.script_status} capture_status=${receipt.capture_status}` +
				` osstatus=${receipt.osstatus === null ? 'unavailable' : receipt.osstatus}` +
				` errors=${receipt.errors.length === 0 ? 'none' : receipt.errors.join(',')}`
		);
		return receipt.complete ? 0 : 1;
	} catch {
		console.error(
			'::error::SDK permission observation refused; no catalogue or other principal is qualified.'
		);
		return 1;
	}
}

module.exports = {
	METHOD,
	SUITE,
	NAME,
	FILTER,
	STEP,
	MARKER,
	evaluate,
	sourceReceipt,
	readBoundedRegular,
	validateNativeSources,
	judge,
	main
};
if (require.main === module) process.exitCode = main(process.argv.slice(2));
