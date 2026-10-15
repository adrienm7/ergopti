// tools/test/run-windows-replay-route-core.cjs

/**
 * ==============================================================================
 * MODULE: Windows Replay Route Core Portable Runner
 * DESCRIPTION:
 * Compiles the pure C routing core and its independent event-time vectors on
 * the current host. No Windows hook, DLL, injection or native glyph composition
 * is executed or qualified. Temporary binaries never replace shipped artifacts.
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { compilePortable } = require('./lib/portable-c-compiler.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SOURCE = path.join(ROOT, 'static/ergopti_plus/windows/native/nav_event_owner');

/**
 * Runs a raw child and preserves its exit status and diagnostics.
 * @param {string} command Compiler or compiled regression executable.
 * @param {string[]} args Literal arguments without shell reconstruction.
 * @returns {void}
 */
function execute(command, args) {
	const result = spawnSync(command, args, {
		cwd: ROOT,
		stdio: 'inherit',
		timeout: 30000
	});
	if (result.error) throw result.error;
	assert.equal(result.signal, null, `${command} terminated by ${result.signal}.`);
	assert.equal(result.status, 0, `${command} exited with ${result.status}.`);
}

/**
 * Requires a host C compiler; optional sanitizers strengthen memory validation.
 * @param {string[]} args Either no argument or --sanitize.
 * @returns {void}
 */
function run(args) {
	assert.ok(args.length === 0 || (args.length === 1 && args[0] === '--sanitize'));
	const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-replay-route-'));
	try {
		const binary = path.join(
			temporary,
			process.platform === 'win32' ? 'route-test.exe' : 'route-test'
		);
		compilePortable({
			sources: [
				path.join(SOURCE, 'replay_route_core.c'),
				path.join(SOURCE, 'replay_route_core_test.c')
			],
			binary,
			sanitize: args.length !== 0,
			cwd: ROOT
		});
		execute(binary, []);
		console.log(`Portable replay-route execution target: ${process.platform}/${process.arch}.`);
		console.log('Production hook/FIFO registration adapters are not activated by this runner.');
	} finally {
		fs.rmSync(temporary, { recursive: true, force: true });
	}
}

if (require.main === module) {
	try {
		run(process.argv.slice(2));
	} catch (error) {
		console.error(`FAIL portable replay-route core: ${error.message}`);
		process.exitCode = 1;
	}
}

module.exports = { run };
