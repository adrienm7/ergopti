// tools/test/run-linux-runtime-native.cjs

/**
 * ==============================================================================
 * MODULE: Mandatory Native Linux Runtime Prerequisites
 * DESCRIPTION:
 * Runs the frozen process/file probes on both required Linux Lua ABIs. The
 * existing child subreaper owns physical retirement; this runner verifies exact
 * completed receipts without adding another cleanup policy. Tiny archives do
 * not establish official runtime, HTTPS, server/model or physical input readiness.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { findRuntime } = require('./run-linux-lua.cjs');

const ROOT = path.resolve(__dirname, '../..');
const LUA_PATH = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;';
const ABIS = ['luajit', 'lua5.4'];
const PROBES = [
	['run_owned_process_native.lua', 10, 'Actual owned processes: 10 passed, 0 failed'],
	['run_finite_process_port_native.lua', 4, 'Finite shared process native: 4 passed, 0 failed.'],
	['run_service_process_port_native.lua', 4, 'Service shared process native: 4 passed, 0 failed.'],
	['run_service_running_native.lua', 2, 'Actual service running controls: 2 passed, 0 failed.']
];

/** Requires one actual completed receipt and, where applicable, physical reaping. */
function receipt(result, witness, reaped) {
	if (result.error || result.status !== 0) return false;
	const stdout = String(result.stdout || '');
	const stderr = String(result.stderr || '');
	if (/\bSKIP(?:PED)?\b/i.test(stdout + stderr)) return false;
	if (stdout.split(/\r?\n/).filter((line) => line === witness).length !== 1) return false;
	if (reaped === 2) {
		for (const count of [4, 5]) {
			const paired = `Actual owned POST: ${count} passed, 0 failed; exact native cleanup complete.`;
			if (stdout.split(/\r?\n/).filter((line) => line === paired).length !== 1) return false;
		}
	}
	return (
		!reaped ||
		(stdout.match(/^Native subreaper: \d+ adopted descendants physically reaped$/gm) || [])
			.length === (reaped === 2 ? 2 : 1)
	);
}

/** Executes one serial native gate; other hosts explicitly defer to Linux CI. */
function run({
	platform = process.platform,
	spawn = spawnSync,
	environment = process.env,
	root = ROOT,
	log = console.log,
	error = console.error
} = {}) {
	if (platform !== 'linux') {
		log(
			'[DEFERRED] Native Linux runtime prerequisites require Linux; mandatory Linux CI owns this proof.'
		);
		return 0;
	}
	const driver = path.join(root, 'static/ergopti_plus/linux');
	const hardware = path.join(driver, 'tests/hardware');
	const env = { ...environment, LUA_PATH: LUA_PATH + (environment.LUA_PATH || '') };
	const python = environment.PYTHON || 'python3';
	try {
		if (
			findRuntime((program, argv, options) =>
				spawn(program, argv, { ...options, cwd: driver, env, timeout: 30000 })
			) !== 'luajit'
		)
			throw new Error('Both Linux LuaJIT and Lua 5.4 are required.');
	} catch (cause) {
		error(`[FAIL] Native Linux runtime prerequisites: ${cause.message}`);
		return 1;
	}
	for (const abi of ABIS) {
		const version = abi === 'luajit' ? 'Lua 5.1' : 'Lua 5.4';
		const witness = `Linux native ABI ready: ${abi}`;
		const jitIdentity =
			abi === 'luajit'
				? 'assert(type(jit) == "table" and type(jit.version) == "string" ' +
					'and jit.version:match("^LuaJIT %d") and jit.os == "Linux"); '
				: '';
		const source =
			`assert(_VERSION == ${JSON.stringify(version)}); ` +
			jitIdentity +
			'assert(require("luv").os_uname().sysname == "Linux"); ' +
			`io.write(${JSON.stringify(witness + '\n')})`;
		const result = spawn(abi, ['-e', source], {
			cwd: driver,
			env,
			encoding: 'utf8',
			timeout: 30000
		});
		if (!receipt(result, witness, false)) {
			error(
				`[FAIL] Required actual ${abi}/luv admission: ${result.error?.message || result.stderr || `exit ${result.status}`}`
			);
			return result.status && result.status > 0 ? result.status : 1;
		}
	}
	let failed = 0,
		completed = 0,
		ownedPostCompleted = 0;
	function execute(args, witness, count, reaped) {
		const result = spawn(python, args, {
			cwd: driver,
			env,
			encoding: 'utf8',
			timeout: 120000,
			maxBuffer: 16 * 1024 * 1024
		});
		if (result.stdout) log(result.stdout);
		if (result.stderr) error(result.stderr);
		if (!receipt(result, witness, reaped)) {
			error(
				`[FAIL] Native prerequisite ${path.basename(args[0])}: ${result.error?.message || `exit ${result.status}; incomplete receipt`}`
			);
			failed ||= result.status && result.status > 0 ? result.status : 1;
		} else {
			completed += count;
			if (reaped === 2) ownedPostCompleted += count;
		}
	}
	for (const abi of ABIS) {
		for (const [script, count, witness] of PROBES)
			execute(
				[path.join(hardware, 'run_native_subreaper.py'), abi, path.join(hardware, script)],
				witness,
				count,
				true
			);
		// The unchanged builder invokes that same subreaper internally. Wrapping
		// it here again would create a competing physical cleanup owner.
		execute(
			[path.join(hardware, 'run_ollama_install_files_native.py'), driver, '--lua', abi],
			'Install native filesystem receipts: 11 passed, 0 failed.',
			11,
			true
		);
		// Both modes retain their own exact sibling subreaper and actual receipts.
		execute(
			[
				path.join(hardware, 'run_http_owned_post_native.py'),
				driver,
				'--shared-lua',
				path.join(driver, '../_shared/lua'),
				'--lua',
				abi
			],
			'Actual owned POST paired receipts: 9 passed, 0 failed.',
			9,
			2
		);
	}
	execute(
		[path.join(hardware, 'run_native_subreaper_teardown.py')],
		'Native wrapper failure teardown: 2 passed, 0 failed',
		2,
		false
	);
	if (failed) return failed;
	if (completed !== 82 || completed - ownedPostCompleted !== 64 || ownedPostCompleted !== 18) {
		error('[FAIL] Native runtime prerequisite inventory incomplete.');
		return 1;
	}
	log('PASS native Linux runtime prerequisites: 82 checks (64 original, 18 owned POST)');
	return 0;
}

if (require.main === module) process.exitCode = run();
module.exports = { run };
