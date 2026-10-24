// tools/test/lib/host-toolchain.cjs

/**
 * ==============================================================================
 * MODULE: Host Toolchain Guard
 * DESCRIPTION:
 * Refuses to start a local test run on a host whose toolchain differs from the
 * hosted CI runners, so a red caused by the host is never read as a red of the
 * change under test.
 *
 * FEATURES & RATIONALE:
 * 1. Node must be exactly the version pinned in .node-version: Unicode tables, test
 *    runner behaviour and generator output follow the Node release.
 * 2. On Linux and macOS the `lua` command must be Lua 5.4, as the CI lanes
 *    install it; a Lua 5.1 `lua` lacks table.pack and fails unrelated gates.
 * 3. On Linux and macOS the run must not be root: the hosted runners are a
 *    normal user, and gates that check uid, sudo or file modes take another
 *    path as root.
 * 4. On Linux and macOS PowerShell (pwsh) must be on PATH: the CI images ship
 *    it and several AHK and Windows tooling gates spawn it.
 * 5. On Linux and macOS USER and LOGNAME must be set, as on the runners: the
 *    driver log sinks refuse to open without the account identity they redact.
 * 6. evaluateHost is a pure function of the probed facts, so the rules are
 *    tested without changing the real host.
 * ==============================================================================
 */

'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const NODE_PIN = path.join(ROOT, '.node-version');
const REQUIRED_LUA_SERIES = '5.4';

/**
 * Read the pinned Node version from .node-version (the file setup-node reads).
 * @returns {string} Version without the leading "v".
 */
function pinnedNodeVersion() {
	const pinned = fs.readFileSync(NODE_PIN, 'utf8').trim().replace(/^v/, '');
	if (!/^\d+\.\d+\.\d+$/.test(pinned))
		throw new Error(`.node-version holds no exact version: "${pinned}"`);
	return pinned;
}

/**
 * Run a probe command and return its combined output, or null when it is absent.
 * @param {string} command
 * @param {string[]} args
 * @returns {string|null}
 */
function probeOutput(command, args) {
	const result = spawnSync(command, args, { encoding: 'utf8' });
	if (result.error && result.error.code === 'ENOENT') return null;
	if (result.error) throw result.error;
	return `${result.stdout || ''}${result.stderr || ''}`.trim();
}

/**
 * Probe the facts the rules need from the real host.
 * @returns {{nodeVersion: string, pinnedNode: string, platform: string, uid: number|null,
 *   luaVersionText: string|null, pwshVersionText: string|null, accountVariables: string[]}}
 */
function probeHost() {
	const posix = process.platform !== 'win32';
	return {
		nodeVersion: process.version.replace(/^v/, ''),
		pinnedNode: pinnedNodeVersion(),
		platform: process.platform,
		uid: typeof process.getuid === 'function' ? process.getuid() : null,
		accountVariables: ['USER', 'LOGNAME'].filter((name) => !process.env[name]),
		luaVersionText: posix ? probeOutput('lua', ['-v']) : null,
		pwshVersionText: posix
			? probeOutput('pwsh', ['-NoProfile', '-Command', '$PSVersionTable.PSVersion.ToString()'])
			: null
	};
}

/**
 * List every way the host differs from the CI runners.
 * @param {ReturnType<typeof probeHost>} facts
 * @returns {string[]} One problem per line, empty when the host matches.
 */
function evaluateHost(facts) {
	const problems = [];
	if (facts.nodeVersion !== facts.pinnedNode)
		problems.push(
			`Node ${facts.nodeVersion} runs, .node-version pins ${facts.pinnedNode}: install and select the pinned Node`
		);
	if (facts.platform === 'win32') return problems;
	if (facts.uid === 0)
		problems.push('the run is root, the CI runners are a normal user: run as a normal user');
	if (facts.luaVersionText === null)
		problems.push(`no lua command, CI installs Lua ${REQUIRED_LUA_SERIES} as lua: install it`);
	else if (
		!new RegExp(`^Lua ${REQUIRED_LUA_SERIES.replace('.', '\\.')}\\.`).test(facts.luaVersionText)
	)
		problems.push(
			`lua is "${facts.luaVersionText.split('\n')[0]}", CI has Lua ${REQUIRED_LUA_SERIES}: make lua resolve to lua${REQUIRED_LUA_SERIES}`
		);
	if (facts.accountVariables.length > 0)
		problems.push(
			`${facts.accountVariables.join(' and ')} unset, the CI runners set both: export them (the log sinks need the account identity)`
		);
	if (facts.pwshVersionText === null)
		problems.push('no pwsh on PATH, the CI images ship PowerShell: install it');
	return problems;
}

/**
 * Exit with status 2 when the host differs from CI; return quietly otherwise.
 * @param {string} entry Name of the runner that asks, printed in the refusal.
 */
function requireCiEquivalentHost(entry) {
	const problems = evaluateHost(probeHost());
	if (problems.length === 0) return;
	console.error(
		`${entry}: this host differs from the CI runners, so its reds would not be the change's reds:`
	);
	for (const problem of problems) console.error(`  - ${problem}`);
	process.exit(2);
}

module.exports = {
	evaluateHost,
	probeHost,
	pinnedNodeVersion,
	requireCiEquivalentHost,
	REQUIRED_LUA_SERIES
};
