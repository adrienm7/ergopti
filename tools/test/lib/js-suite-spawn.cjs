// tools/test/lib/js-suite-spawn.cjs

/**
 * ==============================================================================
 * MODULE: JS Suite Spawn Plan
 * DESCRIPTION:
 * Maps one inventory check to the program, arguments and shell mode the JS
 * suite runner hands to spawnSync.
 *
 * FEATURES & RATIONALE:
 * 1. "$NODE_EXECUTABLE" runs the current Node binary directly, without a
 *    shell. A shell joins the program and its arguments unquoted, so a Node
 *    installed under "C:\Program Files" became the command "C:\Program" and
 *    every such check failed before it started.
 * 2. "npm" and "node" keep the shell: npm is a .cmd shim on Windows, which Node
 *    refuses to start without one, and both names resolve through PATH.
 * ==============================================================================
 */

'use strict';

const SHELL_COMMANDS = new Set(['node', 'npm']);

/**
 * Return the spawnSync program, arguments and shell flag for one check.
 * @param {{cmd: string, args: string[]}} check Inventory check.
 * @param {string} nodeExecutable Absolute path of the running Node binary.
 * @returns {{command: string, args: string[], shell: boolean}}
 */
function spawnPlan(check, nodeExecutable) {
	if (typeof nodeExecutable !== 'string' || nodeExecutable.length === 0)
		throw new Error('A nonempty Node executable path is required.');
	if (!Array.isArray(check.args) || check.args.some((argument) => typeof argument !== 'string'))
		throw new Error(`Check ${check.id} needs a string argument list.`);
	if (check.cmd === '$NODE_EXECUTABLE')
		return { command: nodeExecutable, args: check.args, shell: false };
	if (SHELL_COMMANDS.has(check.cmd)) return { command: check.cmd, args: check.args, shell: true };
	throw new Error(`Check ${check.id} names an unsupported command: ${check.cmd}`);
}

module.exports = { spawnPlan };
