// tools/test/test-apple-shortcuts-cold-cli-probe.cjs

/**
 * ==============================================================================
 * MODULE: Apple Shortcuts Cold CLI Diagnostic Controls
 * DESCRIPTION:
 * Run portable ownership controls for one literal CLI catalogue request.
 * Neither source checks nor recording process ports qualify a macOS provider.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const source = fs.readFileSync(
	path.join(root, 'tools/diagnostics/apple_shortcuts_cold_cli_probe.py'),
	'utf8'
);
assert.ok(source.length > 0);
assert.match(source, /COMMAND = \("\/usr\/bin\/shortcuts", "list", "--show-identifiers"\)/);
assert.match(source, /LIMIT = 65536\nDEADLINE_SECONDS = 20/);
assert.match(source, /macos_owned_process\.py/);
assert.match(source, /ownership\.NativeProcessGroups\(\)/);
assert.match(source, /self\.ownership\.acquire_owned\(/);
assert.match(source, /"feature_qualified": False/);
assert.doesNotMatch(source, /osascript|ShortcutsEvents|app\.shortcuts|permission_grant/);
const controls = spawnSync(
	process.platform === 'win32' ? 'python' : 'python3',
	[
		'-m',
		'unittest',
		'discover',
		'-s',
		'tools/diagnostics',
		'-p',
		'apple_shortcuts_cold_cli_probe_test.py',
		'-v'
	],
	{
		cwd: root,
		encoding: 'utf8',
		env: { ...process.env, PYTHONDONTWRITEBYTECODE: '1' }
	}
);
assert.ifError(controls.error);
assert.equal(controls.signal, null);
assert.equal(controls.status, 0, controls.stdout + controls.stderr);
assert.match(controls.stderr, /Ran 25 tests in /);
assert.match(controls.stderr, /\nOK\s*$/);
assert.doesNotMatch(controls.stderr, /skipped=/);
process.stdout.write('Cold CLI portable controls: 25 passed; native macOS pending\n');
