// tools/diagnostics/wp7_timer_xctest_evidence.cjs
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const Legacy = require('./lease165_xctest_evidence.cjs');
const { cleanTranscript } = require('./swift_xctest_evidence.cjs');
const COHORTS = Object.freeze([
	Object.freeze({
		className: 'HS274NativePolicyQualificationTests',
		names: Object.freeze([
			'-[ErgoptiPlusTests.HS274NativePolicyQualificationTests testActualPinnedDispatcherCancellationUsesGenuineOfflineLibrary]'
		])
	})
]);
const NAMES = COHORTS[0].names;
const EXPECTED = 1;
function status(value) {
	if (
		!/^(?:0|[1-9][0-9]{0,2})$/.test(String(value)) ||
		String(value).trim() !== String(value) ||
		Number(value) > 255
	)
		throw new Error('WP7 pipeline status refused.');
	return Number(value);
}

/** One serial Selected tests root with both complete, originally named cohorts. */
function evaluate(text, swiftStatus, teeStatus) {
	const swift = status(swiftStatus),
		tee = status(teeStatus);
	const errors = [];
	const reject = (label) => {
		if (!errors.includes(label)) errors.push(label);
	};
	let root = 'before',
		bundle = 'before',
		suite = null,
		active = null,
		summary = null;
	const suites = new Set(),
		starts = new Set(),
		terminals = new Set(),
		passed = new Set();
	const cohorts = new Map(COHORTS.map((cohort) => [cohort.className, cohort]));
	for (const line of cleanTranscript(text).split('\n')) {
		if (!line.trim()) continue;
		if (summary !== null) {
			const count =
				/^\s*Executed (0|[1-9][0-9]*) tests?, with (0|[1-9][0-9]*) failures? \((0|[1-9][0-9]*) unexpected\) in (?:0|[1-9][0-9]*)(?:\.[0-9]+)? \((?:0|[1-9][0-9]*)(?:\.[0-9]+)?\) seconds?\s*$/.exec(
					line
				);
			const expected = cohorts.has(summary) ? cohorts.get(summary).names.length : EXPECTED;
			if (!count || Number(count[1]) !== expected || count[2] !== '0' || count[3] !== '0')
				reject('summary');
			if (summary === 'root') root = 'after';
			if (summary === 'bundle') bundle = 'after';
			summary = null;
			continue;
		}
		const opening =
			/^Test Suite '([^']+)' started at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\.$/.exec(
				line
			);
		const closing =
			/^Test Suite '([^']+)' (passed|failed) at [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}\.[0-9]{3}\.$/.exec(
				line
			);
		const starting = /^Test Case '([^']+)' started\.$/.exec(line);
		const terminal =
			/^Test Case '([^']+)' (passed|failed|skipped) \((?:0|[1-9][0-9]*)(?:\.[0-9]+)? seconds?\)\.$/.exec(
				line
			);
		if (opening) {
			if (opening[1] === 'Selected tests') {
				if (root !== 'before' || bundle !== 'before' || suite !== null || active !== null)
					reject('root');
				root = 'running';
			} else if (opening[1] === 'ErgoptiPlusPackageTests.xctest') {
				if (root !== 'running' || bundle !== 'before' || suite !== null || active !== null)
					reject('bundle');
				bundle = 'running';
			} else if (cohorts.has(opening[1])) {
				if (
					root !== 'running' ||
					bundle !== 'running' ||
					suite !== null ||
					active !== null ||
					suites.has(opening[1])
				)
					reject('suite');
				suite = opening[1];
				suites.add(suite);
			} else reject('foreign-suite');
		} else if (closing) {
			if (closing[2] !== 'passed') reject('failed-suite');
			if (closing[1] === 'Selected tests') {
				if (
					root !== 'running' ||
					bundle !== 'after' ||
					suite !== null ||
					active !== null ||
					suites.size !== 1
				)
					reject('root');
				root = 'summary';
				summary = 'root';
			} else if (closing[1] === 'ErgoptiPlusPackageTests.xctest') {
				if (
					root !== 'running' ||
					bundle !== 'running' ||
					suite !== null ||
					active !== null ||
					suites.size !== 1
				)
					reject('bundle');
				bundle = 'summary';
				summary = 'bundle';
			} else if (suite === closing[1]) {
				if (root !== 'running' || bundle !== 'running' || active !== null) reject('suite');
				const names = cohorts.get(suite).names;
				if (names.some((name) => !starts.has(name) || !passed.has(name)))
					reject('incomplete-suite');
				summary = suite;
				suite = null;
			} else reject('foreign-suite');
		} else if (starting) {
			if (
				root !== 'running' ||
				bundle !== 'running' ||
				suite === null ||
				active !== null ||
				!cohorts.get(suite)?.names.includes(starting[1]) ||
				starts.has(starting[1])
			)
				reject('start');
			starts.add(starting[1]);
			active = starting[1];
		} else if (terminal) {
			if (
				root !== 'running' ||
				bundle !== 'running' ||
				suite === null ||
				active !== terminal[1] ||
				!cohorts.get(suite)?.names.includes(terminal[1]) ||
				terminals.has(terminal[1])
			)
				reject('terminal');
			if (terminal[2] !== 'passed') reject('failed-or-skipped-case');
			else passed.add(terminal[1]);
			terminals.add(terminal[1]);
			active = null;
		} else if (/^\s*Test (Suite|Case) |^\s*Executed |(?:^|: )(?:fatal )?error: /.test(line))
			reject('unadmitted-test-frame');
	}
	if (
		root !== 'after' ||
		bundle !== 'after' ||
		suite !== null ||
		active !== null ||
		summary !== null ||
		suites.size !== 1 ||
		starts.size !== EXPECTED ||
		terminals.size !== EXPECTED ||
		passed.size !== EXPECTED ||
		NAMES.some((name) => !starts.has(name) || !passed.has(name))
	)
		reject('incomplete');
	if (swift !== 0 || tee !== 0) reject('pipeline');
	return {
		schema: 1,
		scope: 'wp7-dispatcher-native-only',
		complete: errors.length === 0,
		full_package_qualified: false,
		expected: EXPECTED,
		completed: NAMES.filter((name) => terminals.has(name)).length,
		passed: NAMES.filter((name) => passed.has(name)).length,
		swift_status: swift,
		capture_status: tee,
		errors
	};
}

/** Finite held regular-file bytes, excluding atime from the currentness cut. */
function readBoundedRegular(file, maximum) {
	const fd = fs.openSync(
		file,
		fs.constants.O_RDONLY | fs.constants.O_NOFOLLOW | fs.constants.O_NONBLOCK
	);
	try {
		const before = fs.fstatSync(fd, { bigint: true }),
			named = fs.lstatSync(file, { bigint: true });
		const same = (a, b) =>
			['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].every(
				(key) => a[key] === b[key]
			);
		if (
			!before.isFile() ||
			before.size > BigInt(maximum) ||
			before.nlink !== 1n ||
			!same(before, named)
		)
			throw new Error('WP7 capture refused.');
		const bytes = Buffer.alloc(Number(before.size));
		let offset = 0;
		while (offset < bytes.length) {
			const count = fs.readSync(fd, bytes, offset, bytes.length - offset, null);
			if (count <= 0) throw new Error('WP7 capture incomplete.');
			offset += count;
		}
		if (
			!same(before, fs.fstatSync(fd, { bigint: true })) ||
			!same(before, fs.lstatSync(file, { bigint: true }))
		)
			throw new Error('WP7 capture changed.');
		return bytes;
	} finally {
		fs.closeSync(fd);
	}
}

/** Only the exact owned shell's canonical direct child status, never a default. */
function readChildStatus(file) {
	const before = fs.lstatSync(file, { bigint: true });
	if (
		!before.isFile() ||
		before.uid !== BigInt(process.getuid()) ||
		(before.mode & 0o7777n) !== 0o600n ||
		before.nlink !== 1n ||
		before.size < 2n ||
		before.size > 4n
	)
		throw new Error('WP7 child status ownership refused.');
	const raw = readBoundedRegular(file, 4);
	const after = fs.lstatSync(file, { bigint: true });
	if (
		!['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].every(
			(key) => before[key] === after[key]
		)
	)
		throw new Error('WP7 child status changed.');
	const text = new TextDecoder('utf-8', { fatal: true }).decode(raw);
	const parsed = /^(?:0|[1-9][0-9]{0,2})\n$/.exec(text);
	if (!parsed || parsed[0] !== text || Number(text) > 255)
		throw new Error('WP7 child status encoding refused.');
	return Number(text);
}

const INPUT_PINS = Object.freeze({
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274OwnedTimerSemanticsTests.swift':
		'4c41cf333394599149246a4f1d1f2622422eb96e39ed9e79543fabe1a4f24ed8',
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/HS274NativePolicyQualificationTests.swift':
		'91918c1a7e4bdd83bf24bdc3b362b0b0cfb8683cca3f1ff72d56b5a8ed28b0a0',
	'static/ergopti_plus/macos/launcher/Tests/ErgoptiPlusTests/NativeFixtureChildEnvironmentTests.swift':
		'0cd2514bed05027c59f5f902b95dcd891bc4b80ab4d912d1acc9ddf0a13b4103',
	'static/ergopti_plus/macos/launcher/Package.swift':
		'8d9afd570f345e43fe1b8a1507bfb13d53ac743970f4f0a9d1e5bfadb934a552',
	'tools/build/remap_runtime_timer_semantics_test.py':
		'35529be11e2bfe221cf7915b1a048841da441c397d660096139e3dd81c9c4f36',
	'tools/build/remap_runtime_timer_semantics_control.cpp':
		'8205ca8cceb1cd72f964b5d2427aed7c444c5fdb17b5cba8aa26f1e6bea54538',
	'tools/build/remap_runtime_inventory_fixture.py':
		'4480b5fe7013e6f8d0b1064c6694d88f77faaac1150844f20b47f6c573bfecfe',
	'tools/build/remap_runtime_vhd_fixture.py':
		'a4d62ba7da04436f438248b998a702b89d3b8475de7a2de947270cfbfb088c02',
	'tools/build/fixtures/remap_runtime_vhd_pristine_manifest.json':
		'b7ac1a92ca736a957116d032774a3182e32303bcef055e37863a366195026869',
	'tools/build/fixtures/remap_runtime_vhd_pristine.tar.gz':
		'6389c53e3adb6cdfd13a80e0580758ac6cff4c985a26ff18dcec204be2aa5877',
	'tools/diagnostics/macos_owned_process.py':
		'9b985af7e8bf549cb843b289885a2bea38a67ea3ce44defaf389dab1001fef98'
});

/** Bind the genuine launcher plus the complete tracked offline build closure. */
function sourceReceipt(repository, candidate, expectedArch, actualArch) {
	const receipt = Legacy.sourceReceipt(repository, candidate, expectedArch, actualArch);
	const git = (args) =>
		execFileSync('git', args, {
			cwd: repository,
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe']
		});
	const files = git(['ls-files', '-z', '--', 'tools/build']).split('\0').filter(Boolean).sort();
	const untracked = git(['ls-files', '--others', '-z', '--', 'tools/build'])
		.split('\0')
		.filter((p) => /\.(?:py|cpp|hpp|json|gz)$/.test(p));
	if (!files.length || untracked.length) throw new Error('WP7 build inputs refused.');
	for (const relative of files) {
		const held = readBoundedRegular(path.join(repository, relative), 16777216);
		const expected = execFileSync('git', ['show', candidate + ':' + relative], {
			cwd: repository,
			stdio: ['ignore', 'pipe', 'pipe'],
			maxBuffer: 16777216
		});
		if (!held.equals(expected)) throw new Error('WP7 build source changed.');
		receipt.sources[relative] = crypto.createHash('sha256').update(held).digest('hex');
	}
	for (const [relative, digest] of Object.entries(INPUT_PINS))
		if (receipt.sources[relative] !== digest)
			throw new Error('WP7 pinned assertion/input changed.');
	receipt.scope = 'wp7-dispatcher-native-only';
	return receipt;
}
function main(args, repository = path.resolve(__dirname, '../..')) {
	try {
		if (args.length === 5 && args[0] === 'begin') {
			const childStatusFile = path.join(path.dirname(args[4]), 'wp7-timer-swift-child-status.txt');
			try {
				fs.lstatSync(childStatusFile);
				throw new Error('WP7 child status already exists.');
			} catch (error) {
				if (error.code !== 'ENOENT') throw error;
			}
			const receipt = sourceReceipt(repository, args[1], args[2], args[3]);
			fs.writeFileSync(args[4], JSON.stringify(receipt, null, '\t') + '\n', {
				flag: 'wx',
				mode: 0o600
			});
			return 0;
		}
		if (args.length !== 9 || args[0] !== 'judge') throw new Error('WP7 arguments refused.');
		const before = JSON.parse(
			new TextDecoder('utf-8', { fatal: true }).decode(readBoundedRegular(args[7], 1048576))
		);
		const after = sourceReceipt(repository, args[4], args[5], args[6]);
		if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error('WP7 source changed.');
		const wrapperStatus = status(args[2]);
		const childStatus = readChildStatus(
			path.join(path.dirname(args[7]), 'wp7-timer-swift-child-status.txt')
		);
		const receipt = {
			...evaluate(
				new TextDecoder('utf-8', { fatal: true }).decode(readBoundedRegular(args[1], 16777216)),
				childStatus,
				args[3]
			),
			wrapper_status: wrapperStatus,
			source: after
		};
		if (wrapperStatus !== 0) {
			receipt.complete = false;
			receipt.errors.push('wrapper-pipeline');
		}
		fs.writeFileSync(args[8], JSON.stringify(receipt, null, '\t') + '\n', {
			flag: 'wx',
			mode: 0o600
		});
		console.log(
			`::notice title=Pinned dispatcher native receiving::complete=${receipt.complete} passed=${receipt.passed} expected=1 inner_cases=7 native_engine=unexecuted full_package_qualified=false swift_status=${receipt.swift_status} wrapper_status=${receipt.wrapper_status} capture_status=${receipt.capture_status} candidate=${after.candidate} architecture=${after.architecture}`
		);
		return receipt.complete ? 0 : 1;
	} catch {
		console.error(
			'::error::Pinned dispatcher native receiving refused; full package remains unqualified.'
		);
		return 1;
	}
}
module.exports = { COHORTS, NAMES, evaluate, readBoundedRegular, sourceReceipt, main };
if (require.main === module) process.exitCode = main(process.argv.slice(2));
