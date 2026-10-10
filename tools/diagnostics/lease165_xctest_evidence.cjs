// tools/diagnostics/lease165_xctest_evidence.cjs
'use strict';

/** Only the two historical lease cohorts; never full-package qualification. */
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { execFileSync } = require('node:child_process');
const { cleanTranscript } = require('./swift_xctest_evidence.cjs');
const CORPUS = require('../test/fixtures/lease165-native-xctest-corpus.json');
const COHORTS = Object.freeze(
	CORPUS.cohorts.map((cohort) =>
		Object.freeze({
			className: cohort.class_name,
			source: cohort.source,
			names: Object.freeze([...cohort.names])
		})
	)
);
const NAMES = Object.freeze(COHORTS.flatMap((cohort) => cohort.names));
const EXPECTED = 165;
if (
	CORPUS.expected_count !== EXPECTED ||
	COHORTS.length !== 2 ||
	NAMES.length !== EXPECTED ||
	new Set(NAMES).size !== EXPECTED ||
	COHORTS[0].className !== 'KarabinerLeaseWorkerTests' ||
	COHORTS[0].names.length !== 146 ||
	COHORTS[1].className !== 'LeaseDiagnosticNextObservationTests' ||
	COHORTS[1].names.length !== 19
)
	throw new Error('Lease cohort inventory refused.');

function status(value) {
	if (!/^(?:0|[1-9][0-9]{0,2})$/.test(String(value)) || Number(value) > 255)
		throw new Error('Lease pipeline status refused.');
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
					suites.size !== 2
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
					suites.size !== 2
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
		suites.size !== 2 ||
		starts.size !== EXPECTED ||
		terminals.size !== EXPECTED ||
		passed.size !== EXPECTED ||
		NAMES.some((name) => !starts.has(name) || !passed.has(name))
	)
		reject('incomplete');
	if (swift !== 0 || tee !== 0) reject('pipeline');
	return {
		schema: 1,
		scope: 'lease165-native-only',
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
			throw new Error('Lease capture refused.');
		const bytes = Buffer.alloc(Number(before.size));
		let offset = 0;
		while (offset < bytes.length) {
			const count = fs.readSync(fd, bytes, offset, bytes.length - offset, null);
			if (count <= 0) throw new Error('Lease capture incomplete.');
			offset += count;
		}
		if (
			!same(before, fs.fstatSync(fd, { bigint: true })) ||
			!same(before, fs.lstatSync(file, { bigint: true }))
		)
			throw new Error('Lease capture changed.');
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
		throw new Error('Lease child status ownership refused.');
	const raw = readBoundedRegular(file, 4);
	const after = fs.lstatSync(file, { bigint: true });
	if (
		!['dev', 'ino', 'mode', 'uid', 'gid', 'nlink', 'size', 'mtimeNs', 'ctimeNs'].every(
			(key) => before[key] === after[key]
		)
	)
		throw new Error('Lease child status changed.');
	const text = new TextDecoder('utf-8', { fatal: true }).decode(raw);
	const parsed = /^(?:0|[1-9][0-9]{0,2})\n$/.exec(text);
	if (!parsed || parsed[0] !== text || Number(text) > 255)
		throw new Error('Lease child status encoding refused.');
	return Number(text);
}

/** Bind actual checkout, native architecture and all implicit launcher inputs. */
function sourceReceipt(repository, candidate, expectedArch, actualArch) {
	if (
		!/^[0-9a-f]{40}$/.test(candidate) ||
		!['arm64', 'x86_64'].includes(expectedArch) ||
		actualArch !== expectedArch ||
		{ arm64: 'arm64', x86_64: 'x64' }[actualArch] !== process.arch
	)
		throw new Error('Lease source or architecture refused.');
	const git = (args) =>
		execFileSync('git', args, {
			cwd: repository,
			encoding: 'utf8',
			stdio: ['ignore', 'pipe', 'pipe']
		});
	if (git(['rev-parse', 'HEAD']).trim() !== candidate) throw new Error('Lease candidate changed.');
	git(['diff', '--exit-code', 'HEAD', '--']);
	const launcher = 'static/ergopti_plus/macos/launcher';
	const implicit = git([
		'ls-files',
		'--others',
		'-z',
		'--',
		`${launcher}/Sources`,
		`${launcher}/Tests`
	])
		.split('\0')
		.filter(Boolean);
	const alternate = git(['ls-files', '--others', '-z', '--', launcher])
		.split('\0')
		.filter((file) => /^Package(?:@swift-[0-9.]+)?\.swift$/.test(file.slice(launcher.length + 1)));
	if (implicit.length || alternate.length) throw new Error('Unbound lease compiler input.');
	const files = git([
		'ls-files',
		'-z',
		'--',
		launcher,
		'tools/diagnostics',
		'tools/test/fixtures/lease165-native-xctest-corpus.json'
	])
		.split('\0')
		.filter(Boolean)
		.sort();
	if (!files.length) throw new Error('Lease inventory unavailable.');
	const sources = {};
	for (const relative of files)
		sources[relative] = crypto
			.createHash('sha256')
			.update(readBoundedRegular(path.join(repository, relative), 16777216))
			.digest('hex');
	for (const cohort of COHORTS) {
		if (!Object.hasOwn(sources, cohort.source)) throw new Error('Lease test source missing.');
		const actual = [
			...new TextDecoder('utf-8', { fatal: true })
				.decode(readBoundedRegular(path.join(repository, cohort.source), 16777216))
				.matchAll(/\bfunc (test\w+)\(/g)
		].map((match) => `-[ErgoptiPlusTests.${cohort.className} ${match[1]}]`);
		if (JSON.stringify(actual.sort()) !== JSON.stringify([...cohort.names].sort()))
			throw new Error('Lease method inventory differs.');
	}
	return { schema: 1, scope: 'lease165-native-only', candidate, architecture: actualArch, sources };
}

function main(args, repository = path.resolve(__dirname, '../..')) {
	try {
		if (args.length === 5 && args[0] === 'begin') {
			const childStatusFile = path.join(path.dirname(args[4]), 'lease165-swift-child-status.txt');
			try {
				fs.lstatSync(childStatusFile);
				throw new Error('Lease child status already exists.');
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
		if (args.length !== 9 || args[0] !== 'judge') throw new Error('Lease arguments refused.');
		const before = JSON.parse(
			new TextDecoder('utf-8', { fatal: true }).decode(readBoundedRegular(args[7], 1048576))
		);
		const after = sourceReceipt(repository, args[4], args[5], args[6]);
		if (JSON.stringify(before) !== JSON.stringify(after)) throw new Error('Lease source changed.');
		const wrapperStatus = status(args[2]);
		const childStatus = readChildStatus(
			path.join(path.dirname(args[7]), 'lease165-swift-child-status.txt')
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
			`::notice title=Scoped lease native receiving::complete=${receipt.complete} passed=${receipt.passed} expected=165 full_package_qualified=false swift_status=${receipt.swift_status} wrapper_status=${receipt.wrapper_status} capture_status=${receipt.capture_status} candidate=${after.candidate} architecture=${after.architecture}`
		);
		return receipt.complete ? 0 : 1;
	} catch {
		console.error(
			'::error::Scoped lease native receiving refused; full package remains unqualified.'
		);
		return 1;
	}
}
module.exports = { COHORTS, NAMES, evaluate, readBoundedRegular, sourceReceipt, main };
if (require.main === module) process.exitCode = main(process.argv.slice(2));
