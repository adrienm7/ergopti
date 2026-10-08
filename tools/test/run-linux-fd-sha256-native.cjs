// tools/test/run-linux-fd-sha256-native.cjs

/**
 * ==============================================================================
 * MODULE: Mandatory Native Retained FD SHA-256 Gate
 * DESCRIPTION:
 * Runs the unchanged twelve native NIST/FD checks under the existing sole
 * subreaper. Completed native receipts and exact sink closure admit credit.
 * This gate does not qualify archive publication, updater or installation.
 * ==============================================================================
 */
'use strict';
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const SUBJECT = 'PASS native retained FD SHA-256: 12 checks; 0 failed; 0 skipped.';
const LABELS = [
	'PASS vector 1 native input bytes',
	'PASS vector 1 pathname absent before digest',
	'PASS vector 1 independent NIST SHA256',
	'PASS vector 1 read context timer retirement',
	'PASS vector 1 exact parent FD close',
	'PASS vector 1 no retained IO timer debt',
	'PASS vector 2 native input bytes',
	'PASS vector 2 pathname absent before digest',
	'PASS vector 2 independent NIST SHA256',
	'PASS vector 2 read context timer retirement',
	'PASS vector 2 exact parent FD close',
	'PASS vector 2 no retained IO timer debt'
];

/** Exact native result; partial runs, rescue and omitted closure earn no credit. */
function receipt(result) {
	if (
		!result ||
		result.error ||
		result.status !== 0 ||
		result.signal !== null ||
		result.sinks_closed !== true ||
		typeof result.stdout !== 'string' ||
		result.stderr !== ''
	)
		return false;
	const lines = result.stdout.split('\n');
	if (lines.length !== 16 || lines[15] !== '') return false;
	if (LABELS.some((label, index) => lines[index] !== label)) return false;
	if (
		lines[12] !== '12 PASS, 0 FAIL, 0 SKIP' ||
		lines[13] !== 'Native subreaper: 0 adopted descendants physically reaped' ||
		lines[14] !== 'Native subreaper closure: {"adopted": 0, "pending": 0, "rescue": 0}'
	)
		return false;
	try {
		const closure = JSON.parse(lines[14].slice('Native subreaper closure: '.length));
		return (
			closure !== null &&
			!Array.isArray(closure) &&
			Object.keys(closure).sort().join(',') === 'adopted,pending,rescue' &&
			closure.adopted === 0 &&
			closure.pending === 0 &&
			closure.rescue === 0
		);
	} catch {
		return false;
	}
}

/** The CI subject comes only from the sole native wrapper success witness. */
function readCount(text) {
	if (text !== SUBJECT + '\n') throw new Error('Native FD digest evidence refused.');
	return 12;
}

/** Native streams remain private even when a prerequisite or assertion refuses. */
function execute(command, args, options) {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-fd-digest-native-'));
	fs.chmodSync(directory, 0o700);
	const stdout = path.join(directory, 'stdout.private');
	const stderr = path.join(directory, 'stderr.private');
	const owned = [];
	let result,
		closed = true;
	try {
		owned.push(fs.openSync(stdout, 'wx', 0o600));
		owned.push(fs.openSync(stderr, 'wx', 0o600));
		// Sole maintained guardian owns its child and its 40s/5s teardown.
		// An outer timeout or maxBuffer would kill that owner before draining it.
		result = spawnSync(command, args, { ...options, stdio: ['ignore', ...owned] });
	} catch {
		result = { error: true, status: null, signal: null };
	} finally {
		// Every acquired sink gets one close attempt; an ambiguous close is not
		// retried using a possibly reused descriptor or promoted to closure.
		for (const descriptor of owned) {
			try {
				fs.closeSync(descriptor);
			} catch {
				closed = false;
			}
		}
	}
	if (!closed || owned.length !== 2)
		return { error: true, status: null, signal: null, sinks_closed: false };
	try {
		for (const filename of [stdout, stderr]) {
			const fact = fs.lstatSync(filename);
			if (!fact.isFile() || fact.isSymbolicLink() || fact.size > 65536)
				throw new Error('Private receipt refused');
		}
		return {
			...result,
			stdout: fs.readFileSync(stdout, 'utf8'),
			stderr: fs.readFileSync(stderr, 'utf8'),
			sinks_closed: true
		};
	} catch {
		return { error: true, status: null, signal: null, sinks_closed: true };
	}
	// Keep the owned namespace on success or failure; no private transcript is
	// printed, recursively removed or inferred to be another owner's artifact.
}

/** Linux requires real LuaJIT/libuv/OpenSSL; another host explicitly defers. */
function run({
	platform = process.platform,
	executeChild = execute,
	environment = process.env,
	root = ROOT,
	log = console.log,
	error = console.error
} = {}) {
	if (platform !== 'linux') {
		log('[DEFERRED] Native retained FD SHA-256 requires the Linux lane; no native credit.');
		return 0;
	}
	const driver = path.join(root, 'static/ergopti_plus/linux');
	const hardware = path.join(driver, 'tests/hardware');
	const env = {
		...environment,
		LUA_PATH:
			driver +
			'/?.lua;' +
			driver +
			'/?/init.lua;' +
			path.join(driver, '../_shared/lua/?.lua') +
			';' +
			path.join(driver, '../_shared/lua/?/init.lua')
	};
	for (const key of Object.keys(env)) if (/^LUA_INIT(?:_|$)/.test(key)) delete env[key];
	if (environment.ERGOPTI_NATIVE_LUA_CPATH) env.LUA_CPATH = environment.ERGOPTI_NATIVE_LUA_CPATH;
	let result;
	try {
		result = executeChild(
			environment.PYTHON || 'python3',
			[
				path.join(hardware, 'run_native_subreaper.py'),
				'luajit',
				path.join(hardware, 'run_fd_sha256_native.lua')
			],
			{ cwd: driver, env }
		);
	} catch {
		result = null;
	}
	if (!receipt(result)) {
		error(
			'[FAIL] Native retained FD SHA-256: prerequisite, control or physical closure receipt refused.'
		);
		return 1;
	}
	log(SUBJECT);
	return 0;
}

if (require.main === module) {
	if (process.argv.length === 2) process.exitCode = run();
	else if (process.argv.length === 4 && process.argv[2] === '--evidence') {
		try {
			const fact = fs.lstatSync(process.argv[3]);
			if (!fact.isFile() || fact.isSymbolicLink() || fact.size > 65536)
				throw new Error('Evidence refused');
			console.log(readCount(fs.readFileSync(process.argv[3], 'utf8')));
		} catch {
			console.error('[FAIL] Native retained FD SHA-256: evidence receipt refused.');
			process.exitCode = 1;
		}
	} else {
		console.error('[FAIL] Native retained FD SHA-256: runner arguments refused.');
		process.exitCode = 1;
	}
}
module.exports = { run, receipt, readCount };
