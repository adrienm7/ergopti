// tools/test/run-linux-lua.cjs

/**
 * ==============================================================================
 * MODULE: Linux Driver Lua Suite Runner
 * DESCRIPTION:
 * Runs one Linux driver Lua entry point (the unit suite or the E2E suite) from
 * the driver root with the first Lua runtime on PATH, for the npm gates that
 * verify-change executes.
 *
 * WHY NOT A SHELL ONE-LINER:
 * The npm scripts used to pick the runtime inside `bash -c '...'`. npm runs a
 * script through cmd.exe on Windows, where the first bash on PATH is WSL's
 * launcher: from PowerShell the gate ran inside a Linux distribution, never
 * reached the driver's Windows test mode, and failed on a host whose WSL has no
 * Lua. Node spawns the runtime itself, so the same gate runs the same suite
 * from PowerShell, cmd, Git Bash, and a Linux or macOS shell.
 *
 * FEATURES & RATIONALE:
 * 1. Runtime order is the one the shell one-liner used: luajit (the driver's
 *    target), then lua5.4, then lua. A runtime that is absent is skipped; one
 *    that is present but cannot report its version fails the gate.
 * 2. No runtime at all fails the gate, as it did before.
 * 3. The suite's exit status is the gate's; a suite killed by a signal fails.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const LINUX_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const RUNTIMES = ['luajit', 'lua5.4', 'lua'];

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
 * Runs one Lua entry point from the Linux driver root.
 * @param {string[]} argv The entry point relative to the driver root, then its arguments.
 * @returns {number} Process exit code.
 */
function run(argv) {
	if (argv.length === 0) {
		console.error(
			'usage: node tools/test/run-linux-lua.cjs <entry.lua relative to static/ergopti_plus/linux> [args...]'
		);
		return 2;
	}
	const runtime = findRuntime();
	if (!runtime) {
		console.error(`No Lua runtime found (${RUNTIMES.join(', ')}).`);
		return 1;
	}
	console.error(
		`[run-linux-lua] ${runtime} ${argv.join(' ')} (in ${path.relative(ROOT, LINUX_ROOT)})`
	);
	const result = spawnSync(runtime, argv, { cwd: LINUX_ROOT, stdio: 'inherit' });
	if (result.error) {
		console.error(`[run-linux-lua] ${runtime} could not start: ${result.error.message}`);
		return 1;
	}
	if (result.status === null) {
		console.error(`[run-linux-lua] ${runtime} was killed by ${result.signal}`);
		return 1;
	}
	return result.status;
}

if (require.main === module) process.exitCode = run(process.argv.slice(2));

module.exports = { RUNTIMES, findRuntime, run };
