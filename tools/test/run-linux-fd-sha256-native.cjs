// tools/test/run-linux-fd-sha256-native.cjs

/**
 * ==============================================================================
 * MODULE: Mandatory Native Retained FD SHA-256 Gate
 * DESCRIPTION:
 * Runs the unchanged twelve native NIST/FD checks under the existing sole
 * subreaper. Completed native receipts and exact sink closure admit credit.
 * Ancillary standalone path controls first remove inherited Lua search paths;
 * their private witnesses do not change the twelve-check CI subject.
 * This gate does not qualify archive publication, updater or installation.
 * ==============================================================================
 */
'use strict';
const fs = require('node:fs');
const crypto = require('node:crypto');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const ROOT = path.resolve(__dirname, '../..');
const PRIVATE_DIRECTORY_MODE = 0o700;
const PRIVATE_FILE_MODE = 0o600;
const FILE_MODE_MASK = 0o7777;
const PYTHON_PROGRAM = 'python3';
// Independent floor: withdrawing a path case must refuse native admission.
const STANDALONE_PATH_CONTROL_COUNT = 3;
const STANDALONE_PATH_CASES = [
	['ordinary', 'ordinary'],
	['literal-backslash', 'literal\\checkout'],
	['newline', 'line\ncheckout']
];
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
	fs.chmodSync(directory, PRIVATE_DIRECTORY_MODE);
	const stdout = path.join(directory, 'stdout.private');
	const stderr = path.join(directory, 'stderr.private');
	const owned = [];
	let result,
		closed = true;
	try {
		owned.push(fs.openSync(stdout, 'wx', PRIVATE_FILE_MODE));
		owned.push(fs.openSync(stderr, 'wx', PRIVATE_FILE_MODE));
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
		return {
			error: true,
			status: null,
			signal: null,
			sinks_closed: false,
			private_directory: directory
		};
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
			sinks_closed: true,
			private_directory: directory
		};
	} catch {
		return {
			error: true,
			status: null,
			signal: null,
			sinks_closed: true,
			private_directory: directory
		};
	}
	// Keep the owned namespace on success or failure; no private transcript is
	// printed, recursively removed or inferred to be another owner's artifact.
}

/** Native prerequisites retain one environment policy in both invocation routes. */
function nativeEnvironment(environment) {
	const env = { ...environment };
	for (const key of Object.keys(env)) if (/^LUA_INIT(?:_|$)/.test(key)) delete env[key];
	if (environment.ERGOPTI_NATIVE_LUA_CPATH) env.LUA_CPATH = environment.ERGOPTI_NATIVE_LUA_CPATH;
	return env;
}

/** Copies native source bytes and complete file modes, never a path alias. */
function copySourceFile(source, target, inventory, relative) {
	const fact = fs.lstatSync(source);
	if (!fact.isFile() || fact.isSymbolicLink()) throw new Error('Native source file refused.');
	fs.mkdirSync(path.dirname(target), { recursive: true, mode: PRIVATE_DIRECTORY_MODE });
	fs.copyFileSync(source, target, fs.constants.COPYFILE_EXCL);
	fs.chmodSync(target, fact.mode & FILE_MODE_MASK);
	const input = fs.readFileSync(source),
		output = fs.readFileSync(target),
		actual = fs.lstatSync(target);
	if (!input.equals(output) || (actual.mode & FILE_MODE_MASK) !== (fact.mode & FILE_MODE_MASK))
		throw new Error('Native source copy did not preserve bytes and mode.');
	inventory.push({
		path: relative,
		mode: actual.mode & FILE_MODE_MASK,
		bytes: output.length,
		sha256: crypto.createHash('sha256').update(output).digest('hex')
	});
}

/** Runtime modules retain their canonical generated projections in each source tree. */
function copyLuaTree(source, target, inventory, relative) {
	const fact = fs.lstatSync(source);
	if (!fact.isDirectory() || fact.isSymbolicLink())
		throw new Error('Native source directory refused.');
	fs.mkdirSync(target, { recursive: true, mode: fact.mode & FILE_MODE_MASK });
	fs.chmodSync(target, fact.mode & FILE_MODE_MASK);
	for (const entry of fs.readdirSync(source, { withFileTypes: true })) {
		if (entry.isSymbolicLink()) throw new Error('Native source alias refused.');
		const input = path.join(source, entry.name),
			output = path.join(target, entry.name),
			name = path.posix.join(relative, entry.name);
		if (entry.isDirectory()) copyLuaTree(input, output, inventory, name);
		else if (entry.isFile() && entry.name.endsWith('.lua'))
			copySourceFile(input, output, inventory, name);
	}
}

/**
 * Replays the actual standalone bootstrap before the canonical wrapper can
 * rescue it with LUA_PATH. These ancillary path controls retain their own raw
 * witnesses; the original twelve-check subject below remains the sole CI credit.
 */
function qualifyStandalonePaths() {
	const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-fd-digest-paths-'));
	fs.chmodSync(directory, PRIVATE_DIRECTORY_MODE);
	const unrelated = path.join(directory, 'cwd');
	fs.mkdirSync(unrelated, { mode: PRIVATE_DIRECTORY_MODE });
	const env = nativeEnvironment(process.env);
	for (const key of Object.keys(env)) if (/^LUA_PATH(?:_|$)/.test(key)) delete env[key];
	const controls = [];
	let passed = true;
	try {
		for (const [label, component] of STANDALONE_PATH_CASES) {
			const root = path.join(directory, component),
				inventory = [];
			fs.mkdirSync(root, { mode: PRIVATE_DIRECTORY_MODE });
			for (const relative of [
				'static/ergopti_plus/linux/infra',
				'static/ergopti_plus/linux/_generated',
				'static/ergopti_plus/_shared/lua'
			])
				copyLuaTree(path.join(ROOT, relative), path.join(root, relative), inventory, relative);
			for (const relative of [
				'static/ergopti_plus/linux/tests/runner_root.lua',
				'static/ergopti_plus/linux/tests/hardware/run_native_subreaper.py',
				'static/ergopti_plus/linux/tests/hardware/run_fd_sha256_native.lua'
			])
				copySourceFile(path.join(ROOT, relative), path.join(root, relative), inventory, relative);
			const hardware = path.join(root, 'static/ergopti_plus/linux/tests/hardware');
			const result = execute(
				process.env.PYTHON || PYTHON_PROGRAM,
				[
					path.join(hardware, 'run_native_subreaper.py'),
					'luajit',
					path.join(hardware, 'run_fd_sha256_native.lua')
				],
				{ cwd: unrelated, env }
			);
			const admitted = receipt(result);
			controls.push({
				label,
				admitted,
				root: fs.realpathSync.native(root),
				inventory,
				status: result.status ?? null,
				signal: result.signal ?? null,
				error: result.error ? String(result.error) : null,
				sinks_closed: result.sinks_closed,
				private_directory: result.private_directory
			});
			if (!admitted) passed = false;
		}
	} catch (error) {
		passed = false;
		controls.push({ refused: String(error) });
	}
	if (controls.length !== STANDALONE_PATH_CONTROL_COUNT) passed = false;
	fs.writeFileSync(
		path.join(directory, 'controls.private.json'),
		JSON.stringify(controls, null, 2) + '\n',
		{
			flag: 'wx',
			mode: PRIVATE_FILE_MODE
		}
	);
	if (!passed) {
		console.error('[FAIL] Native retained FD SHA-256 standalone path controls refused.');
		return false;
	}
	// stderr deliberately keeps the original stdout/evidence subject byte-exact.
	console.error(
		`PASS native retained FD SHA-256 standalone path controls: ${controls.length} paths; 0 failed; 0 skipped.`
	);
	return true;
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
		...nativeEnvironment(environment),
		LUA_PATH:
			driver +
			'/?.lua;' +
			driver +
			'/?/init.lua;' +
			path.join(driver, '../_shared/lua/?.lua') +
			';' +
			path.join(driver, '../_shared/lua/?/init.lua')
	};
	let result;
	try {
		result = executeChild(
			environment.PYTHON || PYTHON_PROGRAM,
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
	if (process.argv.length === 2) {
		try {
			process.exitCode = process.platform === 'linux' && !qualifyStandalonePaths() ? 1 : run();
		} catch {
			console.error('[FAIL] Native retained FD SHA-256 path control namespace refused.');
			process.exitCode = 1;
		}
	} else if (process.argv.length === 4 && process.argv[2] === '--evidence') {
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
