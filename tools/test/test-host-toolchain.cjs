// tools/test/test-host-toolchain.cjs

/**
 * ==============================================================================
 * MODULE: Host Toolchain Guard Test
 * DESCRIPTION:
 * Pins the rules that keep a local test run on a CI-equivalent host: exact
 * pinned Node, Lua 5.4 as lua, a non-root user and PowerShell on Linux and macOS.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { evaluateHost, pinnedNodeVersion } = require('./lib/host-toolchain.cjs');

const ROOT = path.resolve(__dirname, '..', '..');

const CI_LINUX = {
	nodeVersion: '22.22.2',
	pinnedNode: '22.22.2',
	platform: 'linux',
	uid: 1001,
	luaVersionText: 'Lua 5.4.6  Copyright (C) 1994-2023 Lua.org, PUC-Rio',
	pwshVersionText: '7.4.6',
	accountVariables: []
};

assert.equal(pinnedNodeVersion(), fs.readFileSync(path.join(ROOT, '.node-version'), 'utf8').trim());
assert.deepEqual(evaluateHost(CI_LINUX), [], 'a CI-equivalent Linux host passes');
assert.deepEqual(
	evaluateHost({ ...CI_LINUX, platform: 'darwin' }),
	[],
	'a CI-equivalent macOS host passes'
);

const cases = [
	[{ nodeVersion: '22.22.0' }, /Node 22\.22\.0 runs, \.node-version pins 22\.22\.2/],
	[{ uid: 0 }, /the run is root/],
	[
		{ luaVersionText: 'Lua 5.1.5  Copyright (C) 1994-2012 Lua.org, PUC-Rio' },
		/lua is "Lua 5\.1\.5/
	],
	[{ luaVersionText: 'Lua 5.40.0' }, /lua is "Lua 5\.40\.0"/],
	[{ luaVersionText: null }, /no lua command/],
	[{ pwshVersionText: null }, /no pwsh on PATH/],
	[{ accountVariables: ['USER', 'LOGNAME'] }, /USER and LOGNAME unset/]
];
for (const [override, expected] of cases) {
	const problems = evaluateHost({ ...CI_LINUX, ...override });
	assert.equal(problems.length, 1, `one problem for ${JSON.stringify(override)}`);
	assert.match(problems[0], expected);
}

const windows = {
	...CI_LINUX,
	platform: 'win32',
	uid: null,
	luaVersionText: null,
	pwshVersionText: null,
	accountVariables: ['USER']
};
assert.deepEqual(evaluateHost(windows), [], 'Windows checks only the Node pin');
assert.equal(evaluateHost({ ...windows, nodeVersion: '22.21.0' }).length, 1);

console.log(
	'[OK] host toolchain guard: pinned Node, Lua 5.4, non-root user, pwsh and account variables'
);
