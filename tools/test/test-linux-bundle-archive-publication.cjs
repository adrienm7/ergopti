'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const root = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-bundle-publication-'));
try {
	const scripts = path.join(scratch, 'scripts');
	const build = path.join(scratch, 'build');
	fs.mkdirSync(scripts);
	fs.mkdirSync(build);
	fs.copyFileSync(path.join(root, 'tools/build/build-linux-bundle-archive.sh'), path.join(scripts, 'bundle.sh'));
	fs.writeFileSync(path.join(scripts, 'write_build_stamp.sh'), '#!/bin/bash\nexit 0\n');
	fs.writeFileSync(path.join(scripts, 'stage-linux-private-runtime.sh'), '#!/bin/bash\nmkdir -p -- "$2"\n');
	for (const directory of ['linux', '_shared', 'bin', 'AppDir/usr/lib/ergopti'])
		fs.mkdirSync(path.join(build, directory), { recursive: true });
	fs.writeFileSync(path.join(build, 'install.sh'), 'installer\n');
	fs.writeFileSync(path.join(build, 'AppDir/usr/lib/ergopti/network-runtime-env.sh'), 'runtime\n');
	for (const suffix of ['', '.sha256']) {
		const original = path.join(scratch, `user-data${suffix || '-archive'}`);
		fs.writeFileSync(original, 'user data remains intact\n');
		fs.linkSync(original, path.join(build, `bundle.tar.gz${suffix}`));
	}
	const result = spawnSync('/bin/bash', [path.join(scripts, 'bundle.sh'), 'bundle.tar.gz'], {
		encoding: 'utf8', timeout: 15000, env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: build }
	});
	assert.equal(result.status, 0, result.stderr || result.stdout);
	for (const suffix of ['', '.sha256'])
		assert.equal(fs.readFileSync(path.join(scratch, `user-data${suffix || '-archive'}`), 'utf8'), 'user data remains intact\n');
	assert.ok(fs.statSync(path.join(build, 'bundle.tar.gz')).size > 0);
	console.log('Linux archive publication preserves hardlinked files.');
} finally { fs.rmSync(scratch, { recursive: true, force: true }); }
