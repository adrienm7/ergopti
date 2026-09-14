// tools/test/test-karabiner-package-manifest.cjs

/** Runs package identity and cache rejection behavior on every build host. */
'use strict';

const { spawnSync } = require('node:child_process');
const path = require('node:path');
const root = path.resolve(__dirname, '../..');
const candidates = process.platform === 'win32' ? ['python', 'python3'] : ['python3'];
const python = candidates.find(command => spawnSync(command, ['--version'], {
	encoding: 'utf8', timeout: 10000
}).status === 0);
if (!python) throw new Error('Python is required to verify Karabiner package identity');
const result = spawnSync(python, ['-m', 'unittest', 'discover', '-s', 'tools/build', '-p', 'karabiner_*_test.py'], {
	cwd: root, stdio: 'inherit', timeout: 30000
});
if (result.error) throw result.error;
if (result.status === null) throw new Error('Karabiner package tests did not settle');
process.exit(result.status);
