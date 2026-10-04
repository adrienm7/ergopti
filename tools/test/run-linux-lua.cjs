// tools/test/run-linux-lua.cjs

/**
 * ==============================================================================
 * MODULE: Linux Driver Lua Suite Runner
 * DESCRIPTION:
 * Runs the Linux unit and E2E gates on their native POSIX target. Windows uses
 * WSL bound to the current checkout; other hosts select their direct runtime.
 *
 * TARGET OWNERSHIP:
 * Linux gates execute the Linux driver, including real POSIX exit status,
 * byte-preserving files and child interpreters. Windows-host Lua cannot prove
 * those observations. On Windows the runner requires Linux LuaJIT in the
 * default WSL distribution and binds its cwd to the current checkout. Other
 * hosts retain direct runtime selection. No shell reconstructs the arguments.
 *
 * The exported findRuntime remains a host-runtime locator for diagnostics that
 * deliberately test Windows Lua. A missing or wrong WSL target fails the gate;
 * it never falls back to that diagnostic interpreter.
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const LINUX_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const RUNTIMES = ['luajit', 'lua5.4', 'lua'];
// A broken WSL startup must fail preparation instead of holding the gate forever.
const TARGET_PROBE_TIMEOUT_MS = 30000;
const TARGET_PROBE =
	'assert(jit and jit.os == "Linux", "Linux LuaJIT is required"); ' +
	'io.write(jit.version, "\\n", jit.os, "\\n")';

/**
 * The first Lua runtime on PATH, in the driver's preference order.
 * @param {Function} spawn spawnSync-compatible function.
 * @returns {string|null} The runtime name, or null when none is installed.
 * @throws {Error} When a runtime is present but cannot report its version.
 */
function findRuntime(spawn = spawnSync) {
	for (const runtime of RUNTIMES) {
		const probe = spawn(runtime, ['-v'], { encoding: 'utf8' });
		if (probe.error && probe.error.code === 'ENOENT') continue;
		if (probe.error || probe.status !== 0) {
			throw new Error(
				`${runtime} is on PATH but "${runtime} -v" failed: ${probe.error ? probe.error.message : probe.stderr}`
			);
		}
		return runtime;
	}
	return null;
}

/**
 * Requires the actual Linux LuaJIT target before admitting a Windows-host gate.
 * @param {Function} spawn spawnSync-compatible function.
 * @returns {string} Acknowledged Linux LuaJIT version.
 * @throws {Error} When WSL, its runtime or its target receipt is unavailable.
 */
function requireWslTarget(spawn) {
	const probe = spawn('wsl.exe', ['--exec', RUNTIMES[0], '-e', TARGET_PROBE], {
		encoding: 'utf8',
		timeout: TARGET_PROBE_TIMEOUT_MS,
		windowsHide: true
	});
	if (probe.error || probe.status !== 0) {
		throw new Error(
			'Windows Linux gates require Linux LuaJIT in the default WSL distribution: ' +
				(probe.error ? probe.error.message : probe.stderr || `exit ${probe.status}`)
		);
	}
	const receipt = String(probe.stdout || '')
		.trim()
		.split(/\r?\n/);
	if (receipt.length !== 2 || !/^LuaJIT \d/.test(receipt[0]) || receipt[1] !== 'Linux') {
		throw new Error('WSL did not acknowledge a Linux LuaJIT target and version.');
	}
	return receipt[0];
}

/**
 * Runs one Lua entry point from the actual driver target.
 * @param {string[]} argv The entry point relative to the driver root, then its arguments.
 * @param {object} options Isolated process, platform, cwd and diagnostic seams.
 * @returns {number} Process exit code.
 */
function run(argv, options = {}) {
	const spawn = options.spawn || spawnSync;
	const platform = options.platform || process.platform;
	const linuxRoot = options.linuxRoot || LINUX_ROOT;
	const report = options.report || console.error;
	if (argv.length === 0) {
		report(
			'usage: node tools/test/run-linux-lua.cjs <entry.lua relative to static/ergopti_plus/linux> [args...]'
		);
		return 2;
	}
	let runtime, args;
	try {
		if (platform === 'win32') {
			const version = requireWslTarget(spawn);
			runtime = 'wsl.exe';
			args = ['--cd', linuxRoot, '--exec', RUNTIMES[0], ...argv];
			report(`[run-linux-lua] ${version} (Linux via WSL) ${argv.join(' ')} (in ${linuxRoot})`);
		} else {
			runtime = findRuntime(spawn);
			if (!runtime) {
				report(`No Lua runtime found (${RUNTIMES.join(', ')}).`);
				return 1;
			}
			args = argv;
			report(`[run-linux-lua] ${runtime} ${argv.join(' ')} (in ${linuxRoot})`);
		}
	} catch (error) {
		report(`[run-linux-lua] ${error.message}`);
		return 1;
	}
	const result = spawn(runtime, args, { cwd: linuxRoot, stdio: 'inherit', windowsHide: true });
	if (result.error) {
		report(`[run-linux-lua] ${runtime} could not start: ${result.error.message}`);
		return 1;
	}
	if (result.status === null) {
		report(`[run-linux-lua] ${runtime} was killed by ${result.signal}`);
		return 1;
	}
	return result.status;
}

if (require.main === module) process.exitCode = run(process.argv.slice(2));

module.exports = { RUNTIMES, findRuntime, run };
