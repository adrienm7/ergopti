// tools/test/run-macos-tooltip-canvas-tests.cjs

/**
 * ==============================================================================
 * MODULE: macOS Tooltip Canvas Pure Test Gate
 * DESCRIPTION:
 * Runs the independent canvas and WebView binding controls with the selected local
 * Python interpreter. A missing dependency, incomplete discovery, skipped case
 * or failed process cannot become a successful developer gate. These are pure
 * controls; native Hammerspoon pixels remain a separate mandatory macOS CI job.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');

/** Requires completed Python controls without treating skipped tests as passes. */
function run({
	spawn = spawnSync,
	env = process.env,
	log = console.log,
	error = console.error
} = {}) {
	const python = env.PYTHON || 'python3';
	for (const [pattern, minimum] of [
		['macos_tooltip_canvas_test.py', 54],
		['macos_webview_binding_test.py', 34],
		['macos_physical_shortcuts_close_test.py', 23],
		['macos_action_picker_pool_test.py', 19]
	]) {
		const result = spawn(
			python,
			['-m', 'unittest', 'discover', '-s', 'tools/diagnostics', '-p', pattern, '-v'],
			{ cwd: ROOT, env, encoding: 'utf8' }
		);
		if (result.stdout) log(result.stdout);
		if (result.stderr) log(result.stderr);
		if (result.error || result.status !== 0) {
			error(`${pattern} pure controls failed: ${result.error?.message || `exit ${result.status}`}`);
			return 1;
		}
		const output = `${result.stdout || ''}\n${result.stderr || ''}`;
		const count = /^Ran (\d+) tests? in .+$/m.exec(output);
		if (!count || Number(count[1]) < minimum || !/^OK$/m.test(output)) {
			error(`${pattern} did not complete all ${minimum} pure controls without skips`);
			return 1;
		}
		log(`${pattern}: ${count[1]} pure controls passed; native execution remains separate`);
	}
	return 0;
}

module.exports = { run };
if (require.main === module) process.exitCode = run();
