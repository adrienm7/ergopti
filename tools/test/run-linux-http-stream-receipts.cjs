// tools/test/run-linux-http-stream-receipts.cjs

/**
 * ==============================================================================
 * MODULE: Native Linux HTTP Streaming Receipt Gate
 * DESCRIPTION:
 * Runs the actual libuv/curl loopback fixture and its production Ollama owners.
 * Linux prerequisites and terminal failures block verification. Other hosts
 * explicitly defer this Linux adapter proof to its mandatory CI lane.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/linux');
const LUA_PATH = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;';

/** Runs the native transport or explicitly defers its proof to Linux CI. */
function run({
	platform = process.platform,
	spawn = spawnSync,
	log = console.log,
	error = console.error
} = {}) {
	if (platform !== 'linux') {
		log(
			'[DEFERRED] Native libuv/curl streaming receipts require Linux; mandatory CI runs the loopback fixture.'
		);
		return 0;
	}
	const env = { ...process.env, LUA_PATH };
	// Cloud unit suites may use Lua 5.4 modules. The native gate uses the
	// explicitly provisioned LuaJIT ABI rather than loading those into Lua 5.1.
	if (env.ERGOPTI_NATIVE_LUA_CPATH) env.LUA_CPATH = env.ERGOPTI_NATIVE_LUA_CPATH;
	let failed = 0;
	// Separate native processes retain independent cleanup owners. Both mandatory
	// proofs run even when one refuses; a failed child never becomes success.
	for (const fixture of ['run_http_stream_receipts.lua', 'run_local_api_auth.lua']) {
		const result = spawn('luajit', [`tests/hardware/${fixture}`], {
			cwd: DRIVER,
			stdio: 'inherit',
			env,
			timeout: 180000
		});
		if (result.error) {
			error(`[FAIL] Native Linux HTTP receipts could not run: ${result.error.message}`);
			failed ||= 1;
		} else if (result.status !== 0) failed ||= result.status ?? 1;
	}
	if (failed) return failed;
	log('[OK] Actual libuv/curl HTTP receipts and native owner settlement passed.');
	return 0;
}

if (require.main === module) process.exitCode = run();
module.exports = { run };
