// tools/test/test-linux-legacy-update-probes.cjs

/**
 * Installed Linux updaters released before the structure move (v1.0.9 ...
 * v1.0.10-dev.175) must still accept the tarball this checkout publishes.
 * The real tarball packer runs over a minimal build tree with the real probe
 * step, and a frozen port of those updaters' staged-tree checks reads the
 * unpacked result. A packer without the probe step is refused by the same
 * port, so the check can fail. The port is frozen on purpose: it describes
 * shipped code that never changes.
 */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '../..');
const PROBES = path.join(ROOT, 'tools/build/add-linux-legacy-update-probes.sh');

/**
 * The staged-tree checks of v1.0.9 (modules/updater/installer.lua
 * validate_candidate, infra/paths.lua shared_root_from, install/ownership.sh)
 * and of v1.0.10-dev.175, which dropped only the _shared/lua requirement.
 * @param {string} work Unpacked tarball root.
 * @returns {string|null} The refusal those updaters print, or null when admitted.
 */
function legacyVerdict(work) {
	const isFile = (p) => fs.existsSync(p) && fs.lstatSync(p).isFile();
	const isDir = (p) => fs.existsSync(p) && fs.lstatSync(p).isDirectory();
	const probe = 'data/locales/en.json';
	const driver = path.join(work, 'linux');
	const shared = [path.join(driver, '../_shared'), path.join(driver, '_shared')].find((c) =>
		isFile(path.join(c, probe))
	);
	for (const relative of [
		'linux/ergopti_hotstrings.lua',
		'linux/infra/version.lua',
		'bin/ergopti-hotstrings',
		'install.sh'
	])
		if (!isFile(path.join(work, relative))) return 'staged archive is missing ' + relative;
	if (!shared || !isDir(path.join(shared, 'lua')))
		return 'staged archive is missing the shared Lua tree';
	const stamp = fs.readFileSync(path.join(shared, 'build_stamp.txt'), 'utf8');
	if (!/^version=\d+\.\d+\.\d+(-[\w.-]+)?$/m.test(stamp))
		return 'build stamp has no release version';
	// install/ownership.sh: [ -f "$DRIVER/ergopti_hotstrings.lua" ] && [ -f "$SHARED/data/locales/en.json" ]
	if (!isFile(path.join(driver, 'ergopti_hotstrings.lua')) || !isFile(path.join(shared, probe)))
		return '[ownership] code=invalid_source';
	return null;
}

/**
 * Packs a minimal post-move build tree with the real packer.
 * @param {string} scratch Private folder.
 * @param {boolean} withProbes Whether the real probe step runs.
 * @returns {string} Unpacked tarball root.
 */
function packAndUnpack(scratch, withProbes) {
	const scripts = path.join(scratch, 'scripts');
	const build = path.join(scratch, 'build');
	fs.mkdirSync(scripts);
	for (const directory of [
		'linux/infra',
		'_shared/core/i18n/data/locales',
		'_shared/data',
		'bin',
		'AppDir/usr/lib/ergopti'
	])
		fs.mkdirSync(path.join(build, directory), { recursive: true });
	fs.copyFileSync(
		path.join(ROOT, 'tools/build/build-linux-bundle-archive.sh'),
		path.join(scripts, 'bundle.sh')
	);
	if (withProbes) fs.copyFileSync(PROBES, path.join(scripts, 'add-linux-legacy-update-probes.sh'));
	else
		fs.writeFileSync(
			path.join(scripts, 'add-linux-legacy-update-probes.sh'),
			'#!/bin/bash\nexit 0\n'
		);
	fs.writeFileSync(path.join(scripts, 'write_build_stamp.sh'), '#!/bin/bash\nexit 0\n');
	fs.writeFileSync(
		path.join(scripts, 'stage-linux-private-runtime.sh'),
		'#!/bin/bash\nmkdir -p -- "$2"\n'
	);
	fs.writeFileSync(path.join(build, 'linux/ergopti_hotstrings.lua'), '-- driver\n');
	fs.writeFileSync(path.join(build, 'linux/infra/version.lua'), '-- version\n');
	fs.writeFileSync(path.join(build, 'bin/ergopti-hotstrings'), '#!/bin/sh\n');
	fs.writeFileSync(path.join(build, 'install.sh'), 'installer\n');
	fs.writeFileSync(
		path.join(build, '_shared/build_stamp.txt'),
		`commit=${'a'.repeat(40)}\nversion=1.0.10\n`
	);
	fs.writeFileSync(
		path.join(build, '_shared/core/i18n/data/locales/en.json'),
		'{"menu":"English"}\n'
	);
	fs.writeFileSync(path.join(build, 'AppDir/usr/lib/ergopti/network-runtime-env.sh'), 'runtime\n');
	const packed = spawnSync('/bin/bash', [path.join(scripts, 'bundle.sh'), 'bundle.tar.gz'], {
		encoding: 'utf8',
		timeout: 30000,
		env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: build }
	});
	assert.equal(packed.status, 0, packed.stderr || packed.stdout);
	const work = path.join(scratch, 'unpacked');
	fs.mkdirSync(work);
	const unpacked = spawnSync('tar', ['-xzf', path.join(build, 'bundle.tar.gz'), '-C', work], {
		encoding: 'utf8'
	});
	assert.equal(unpacked.status, 0, unpacked.stderr);
	return work;
}

let checks = 0;
function check(name, body) {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-legacy-probes-'));
	try {
		body(scratch);
		checks++;
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

check('a pre-move updater admits the published tarball', (scratch) => {
	const work = packAndUnpack(scratch, true);
	assert.equal(legacyVerdict(work), null);
	assert.equal(
		fs.readFileSync(path.join(work, '_shared/data/locales/en.json'), 'utf8'),
		fs.readFileSync(path.join(work, '_shared/core/i18n/data/locales/en.json'), 'utf8'),
		'the legacy locale is generated from the moved one'
	);
});

check('without the probe step the same updater refuses it', (scratch) => {
	assert.equal(
		legacyVerdict(packAndUnpack(scratch, false)),
		'staged archive is missing the shared Lua tree'
	);
});

check('the probe step refuses a layout that already holds a probe path', (scratch) => {
	fs.mkdirSync(path.join(scratch, 'linux/infra'), { recursive: true });
	fs.writeFileSync(path.join(scratch, 'linux/infra/version.lua'), '-- version\n');
	const shared = path.join(scratch, '_shared');
	fs.mkdirSync(path.join(shared, 'core/i18n/data/locales'), { recursive: true });
	fs.mkdirSync(path.join(shared, 'lua'));
	fs.writeFileSync(path.join(shared, 'core/i18n/data/locales/en.json'), '{}\n');
	const result = spawnSync('/bin/bash', [PROBES, scratch], { encoding: 'utf8' });
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /Legacy updater probe already exists/);
});

check('the probe step refuses a tree without the moved locale', (scratch) => {
	fs.mkdirSync(path.join(scratch, 'linux/infra'), { recursive: true });
	fs.writeFileSync(path.join(scratch, 'linux/infra/version.lua'), '-- version\n');
	const result = spawnSync('/bin/bash', [PROBES, scratch], { encoding: 'utf8' });
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /moved English locale is missing/);
});

check('the probe step fails a build that moved the driver version file', (scratch) => {
	const result = spawnSync('/bin/bash', [PROBES, scratch], { encoding: 'utf8' });
	assert.notEqual(result.status, 0);
	assert.match(result.stderr, /require .*linux\/infra\/version\.lua/);
});

assert.equal(checks, 5, 'legacy updater probe check floor changed');
console.log('[OK] Linux legacy updater probes: 5 checks passed.');
