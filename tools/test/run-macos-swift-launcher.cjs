// tools/test/run-macos-swift-launcher.cjs

/**
 * ==============================================================================
 * MODULE: Local macOS Swift Launcher Verification
 * DESCRIPTION:
 * Compiles the release launcher, lints its bundled LaunchAgent, and runs the
 * process-level XCTest suite whenever verify-change executes on macOS.
 *
 * FEATURES & RATIONALE:
 * 1. Honest platform boundary: Windows/Linux print an explicit deferred result;
 *    they never claim that native Swift compiled.
 * 2. CI parity: the same release product and serial XCTest commands used by the
 *    gating macOS workflow run locally on a Mac.
 * 3. Packaging syntax: plutil validates the exact plist consumed by SMAppService.
 * ==============================================================================
 */

'use strict';

const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const PACKAGE_PATH = path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'launcher');
const PLIST_PATH = path.join(
	PACKAGE_PATH,
	'com.ergoptiplus.remap-guardian.plist'
);

/** Returns the exact ordered native verification command plan. */
function commandPlan() {
	return [
		['plutil', ['-lint', PLIST_PATH]],
		['swift', ['build', '-c', 'release', '--product', 'ErgoptiPlus', '--package-path', PACKAGE_PATH]],
		['swift', ['test', '--package-path', PACKAGE_PATH]],
	];
}

/** Executes the native plan on Darwin or reports an honest platform deferral. */
function run({
	platform = process.platform,
	spawn = spawnSync,
	log = console.log,
	error = console.error,
} = {}) {
	if (platform !== 'darwin') {
		log('[DEFERRED] Swift launcher compilation requires macOS; gating CI runs it on macos-latest.');
		return 0;
	}

	for (const [command, arguments_] of commandPlan()) {
		const result = spawn(command, arguments_, {
			cwd: ROOT,
			stdio: 'inherit',
		});
		if (result.error) {
			error(`[FAIL] ${command} could not start: ${result.error.message}`);
			return 1;
		}
		if (result.status !== 0) return result.status ?? 1;
	}

	log('[OK] macOS Swift launcher release build, plist lint, and XCTest passed.');
	return 0;
}

if (require.main === module) process.exitCode = run();

module.exports = { commandPlan, run };
