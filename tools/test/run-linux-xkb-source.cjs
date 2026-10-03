// tools/test/run-linux-xkb-source.cjs

/**
 * ==============================================================================
 * MODULE: Native Linux Physical Source Verification
 * DESCRIPTION:
 * Runs the actual X11 group/keymap qualification fixture on its owned Xvfb
 * server. Native Wayland seat and physical keyboard input remain outside this
 * fixture's evidence. Missing Linux prerequisites are blocking failures.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const DRIVER = path.join(ROOT, 'static/ergopti_plus/linux');
const LUA_PATH = './?.lua;./?/init.lua;../_shared/lua/?.lua;../_shared/lua/?/init.lua;;';

/** Runs the native fixture or explicitly defers it to gating Linux CI. */
function run({
	platform = process.platform,
	spawn = spawnSync,
	log = console.log,
	error = console.error
} = {}) {
	if (platform !== 'linux') {
		log(
			'[DEFERRED] Native X11 source qualification requires Linux; gating CI runs its owned Xvfb fixture.'
		);
		return 0;
	}
	const result = spawn('luajit', ['tests/hardware/run_xkb_source_qualification.lua'], {
		cwd: DRIVER,
		stdio: 'inherit',
		env: { ...process.env, LUA_PATH },
		timeout: 180000
	});
	if (result.error) {
		error(`[FAIL] Native Linux source qualification could not run: ${result.error.message}`);
		return 1;
	}
	if (result.status !== 0) return result.status ?? 1;
	log('[OK] Actual X11 group/keymap source qualification passed.');
	return 0;
}

if (require.main === module) process.exitCode = run();
module.exports = { run };
