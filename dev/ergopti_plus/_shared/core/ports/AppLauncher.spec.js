// static/ergopti_plus/_shared/core/ports/AppLauncher.spec.js

/**
 * ==============================================================================
 * PORT: AppLauncher
 * DESCRIPTION:
 * Contract for launching applications and querying process existence so
 * shortcut modules can start programs and check their running state without
 * coupling to any OS-specific API (AHK Run/ProcessExist, HS application
 * objects, etc.).
 *
 * FEATURES & RATIONALE:
 * 1. Argument-aware launch: launchWithArgs separates the executable path
 *    from its arguments so adapters can quote or escape them correctly for
 *    the target platform rather than forcing callers to build raw command
 *    strings.
 * 2. Boolean process check: isRunning returns a boolean so callers can
 *    branch on process existence without parsing PID integers or catching
 *    exceptions.
 * 3. Fire-and-forget semantics: launch and launchWithArgs do not block
 *    waiting for the process to finish. They return as soon as the OS has
 *    accepted the launch request.
 * ==============================================================================
 */

'use strict';

// ================================================
// ================================================
// ======= 1/ Port Contract Definition ===========
// ================================================
// ================================================

/**
 * The AppLauncher port contract.
 * @type {object}
 */
const portContract = {
	name: 'AppLauncher',
	version: '1.0.0',

	/**
	 * launch(appPath) — Launch an application by its executable path.
	 *   @param {string} appPath  Absolute or relative path to the executable,
	 *     or a protocol/URI string accepted by the OS shell.
	 *   @returns {void}
	 *   @error_behavior "silent" — failure is OS-level; callers should check
	 *     isRunning afterwards if confirmation is needed.
	 *
	 * launchWithArgs(appPath, args) — Launch an application with command-line
	 *   arguments.
	 *   @param {string} appPath  Absolute or relative path to the executable.
	 *   @param {string} args     Command-line argument string to append.
	 *   @returns {void}
	 *   @error_behavior "silent".
	 *
	 * isRunning(processName) — Returns true when at least one process with
	 *   the given name is currently running.
	 *   @param {string} processName  Process name as shown by the OS task list
	 *     (e.g. "notepad.exe", "Finder").
	 *   @returns {boolean} true if the process exists, false otherwise.
	 *   @error_behavior "return_false".
	 */
	methods: {
		launch: { arity: 1, required: true },
		launchWithArgs: { arity: 2, required: true },
		isRunning: { arity: 1, required: true }
	}
};

// ================================================
// ================================================
// ======= 2/ Adapter Structural Validator =======
// ================================================
// ================================================

/**
 * Checks structural compliance of an AppLauncher adapter.
 * @param {object} adapter
 * @returns {string[]} Violations. Empty = compliant.
 */
function validateAdapter(adapter) {
	const violations = [];
	if (!adapter || typeof adapter !== 'object') {
		return ['adapter must be a non-null object'];
	}
	for (const [name, spec] of Object.entries(portContract.methods)) {
		if (!spec.required) continue;
		if (typeof adapter[name] !== 'function') {
			violations.push(`missing method: ${name}`);
		} else if (adapter[name].length !== spec.arity) {
			violations.push(`method ${name}: expected arity ${spec.arity}, got ${adapter[name].length}`);
		}
	}
	return violations;
}

// ================================================
// ================================================
// ======= 3/ Compliance Test Vectors ============
// ================================================
// ================================================

/**
 * Returns test vectors for AppLauncher compliance.
 * Each vector exercises one method and asserts the return-value contract.
 * launch and launchWithArgs are fire-and-forget — vectors verify they
 * do not throw rather than checking a return value.
 * @returns {Array<object>}
 */
function contractTestVectors() {
	return [
		{
			id: 'is_running_unknown_process_returns_false',
			description: 'isRunning() with a nonexistent process name returns false.',
			steps: [
				{ call: 'isRunning', args: ['ergopti_nonexistent_proc_xyz.exe'] },
				{ assert: 'return_false' }
			]
		},
		{
			id: 'is_running_returns_boolean',
			description: 'isRunning() returns a boolean, never throws.',
			steps: [
				{ call: 'isRunning', args: ['explorer.exe'] },
				{ assert: 'return_type_one_of', expected: ['boolean'] }
			]
		},
		{
			id: 'launch_does_not_throw',
			description: 'launch() with a valid path does not throw.',
			steps: [{ call: 'launch', args: ['notepad.exe'] }, { assert: 'no_throw' }]
		},
		{
			id: 'launch_with_args_does_not_throw',
			description: 'launchWithArgs() with a valid path and args does not throw.',
			steps: [
				{ call: 'launchWithArgs', args: ['notepad.exe', 'C:\\test.txt'] },
				{ assert: 'no_throw' }
			]
		}
	];
}

module.exports = { portContract, validateAdapter, contractTestVectors };
