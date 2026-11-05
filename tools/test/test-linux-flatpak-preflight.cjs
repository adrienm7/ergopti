'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const root = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-flatpak-preflight-'));
try {
	const build = path.join(scratch, 'build');
	const staging = path.join(build, 'flatpak');
	fs.mkdirSync(staging, { recursive: true });
	const sentinel = path.join(staging, 'sentinel');
	fs.writeFileSync(sentinel, 'previous state\n');
	const missing = path.join(scratch, 'missing.sh');
	fs.writeFileSync(missing, 'command() { if [ "$1" = -v ] && [ "$2" = "$MISSING_PROGRAM" ]; then return 1; fi; if [ "$1" = -v ] && { [ "$2" = flatpak ] || [ "$2" = flatpak-builder ]; }; then return 0; fi; builtin command "$@"; }\n');
	for (const program of ['flatpak-builder', 'flatpak']) {
		const env = { ...process.env, BASH_ENV: missing, MISSING_PROGRAM: program, ERGOPTI_LINUX_BUILD_DIR: build };
		const launch = (args) => spawnSync(bashExecutable(), [path.join(root, 'tools/build/build-linux-flatpak.sh'), ...args], { encoding: 'utf8', timeout: 10000, env });
		const refused = launch([]);
		assert.equal(refused.status, 69, refused.stderr);
		assert.match(refused.stderr, new RegExp(program));
		assert.equal(fs.readFileSync(sentinel, 'utf8'), 'previous state\n');
		const stagingOnly = launch(['--skip-flatpak']);
		assert.notEqual(stagingOnly.status, 69);
		assert.match(stagingOnly.stdout, /Driver bundle not found/);
	}
	console.log('Flatpak build checks its producer before staging.');
} finally { fs.rmSync(scratch, { recursive: true, force: true }); }
