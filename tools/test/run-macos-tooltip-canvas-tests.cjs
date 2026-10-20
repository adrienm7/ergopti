// tools/test/run-macos-tooltip-canvas-tests.cjs

/**
 * ==============================================================================
 * MODULE: macOS Tooltip Canvas Pure Test Gate
 * DESCRIPTION:
 * Runs the independent canvas and WebView binding controls with the selected local
 * Python interpreter and the canonical host Lua resolver. Missing dependencies,
 * incomplete discovery, skipped cases or failed processes refuse the gate. These are pure
 * controls; native Hammerspoon pixels remain a separate mandatory macOS CI job.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { findRuntime } = require('./run-linux-lua.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

/** Requires complete Python and Lua observer controls without admitting skips. */
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
		['macos_action_picker_pool_test.py', 19],
		['macos_layout_manager_pool_test.py', 22],
		['macos_permission_dialog_pool_test.py', 23],
		['macos_metrics_apps_page_test.py', 23]
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
		if (
			!count ||
			Number(count[1]) < minimum ||
			!/^OK$/m.test(output) ||
			((pattern === 'macos_layout_manager_pool_test.py' ||
				pattern === 'macos_permission_dialog_pool_test.py' ||
				pattern === 'macos_metrics_apps_page_test.py') &&
				(count[1] !== String(minimum) ||
					(output.match(/^Ran /gm) || []).length !== 1 ||
					(output.match(/^OK$/gm) || []).length !== 1 ||
					/^(?:FAILED|ERROR|FAIL)(?:\b|:)/m.test(output) ||
					/\bskipped\b/i.test(output) ||
					typeof result.stdout !== 'string' ||
					typeof result.stderr !== 'string' ||
					result.signal))
		) {
			error(`${pattern} did not complete all ${minimum} pure controls without skips`);
			return 1;
		}
		log(`${pattern}: ${count[1]} pure controls passed; native execution remains separate`);
	}
	let lua;
	try {
		lua = findRuntime((command, args, options) => spawn(command, args, { ...options, env }));
	} catch (failure) {
		error(failure.message);
		return 1;
	}
	if (!lua) {
		error('Lua observer controls require the canonical host runtime');
		return 1;
	}
	for (const script of [
		'macos_layout_manager_pool_observer_test.lua',
		'macos_permission_dialog_pool_observer_test.lua'
	]) {
		for (const order of ['forward', 'reverse']) {
			const result = spawn(
				lua,
				[
					// Lua diagnostic source locators use forward slashes on every host.
					path.join(ROOT, 'tools', 'diagnostics', script).replaceAll('\\', '/'),
					order,
					path.join(ROOT, 'static', 'ergopti_plus')
				],
				{ cwd: ROOT, env, encoding: 'utf8' }
			);
			if (typeof result.stdout === 'string' && result.stdout) log(result.stdout);
			if (typeof result.stderr === 'string' && result.stderr) log(result.stderr);
			if (
				result.error ||
				result.status !== 0 ||
				result.signal ||
				typeof result.stdout !== 'string' ||
				typeof result.stderr !== 'string' ||
				result.stderr.trim()
			) {
				error(`${script} ${order} observer process failed`);
				return 1;
			}
			const lines = result.stdout.trim().split(/\r?\n/);
			const passes = lines.slice(0, -1);
			if (
				passes.length !== 14 ||
				passes.some((line) => !/^PASS_PURE_OBSERVER\t[^\r\n]+$/.test(line)) ||
				new Set(passes).size !== 14 ||
				lines.at(-1) !== 'PURE_OBSERVER_ONLY\t14'
			) {
				error(`${script} ${order} did not complete exactly 14 pure observer controls`);
				return 1;
			}
		}
	}
	return 0;
}

module.exports = { run };
if (require.main === module) process.exitCode = run();
