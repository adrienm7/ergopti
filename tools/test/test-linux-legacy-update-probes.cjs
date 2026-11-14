// tools/test/test-linux-legacy-update-probes.cjs

/**
 * Installed Linux updaters released before the structure move (v1.0.9 ...
 * v1.0.10-dev.175) must still accept the tarball this checkout publishes.
 * The real tarball packer runs over a minimal build tree with the real probe
 * step, and a frozen port of those updaters' staged-tree checks reads the
 * unpacked result. A packer without the probe step is refused by the same
 * port, so the check can fail. The port is frozen on purpose: it describes
 * shipped code that never changes. The ownership step is also run for real:
 * each release's own ownership.sh, frozen from its tag in
 * fixtures/linux-pre-move-ownership, records the tarball or refuses it.
 */
'use strict';
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
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

/**
 * The ownership helper each pre-move release installed, frozen byte for byte from
 * its tag (static/ergopti_plus/linux/install/ownership.sh and ownership_schema.sh).
 * The updater runs the installed copy against the new payload, so these are the
 * scripts that read every tarball this checkout publishes.
 */
const FROZEN_OWNERSHIP = path.join(__dirname, 'fixtures/linux-pre-move-ownership');
const FROZEN_SHA256 = Object.freeze({
	'v1.0.9': {
		'ownership.sh': 'ea644772b7596c9ce90c83538ef71a71e0d6e60cb077f4494cd75f4ffbd2eb09',
		'ownership_schema.sh': '0c2d5c1d0982ec0cf2f124686d07d052ec4f79b37d24a6a6bdff697ea431d23e'
	},
	'v1.0.10-dev.175': {
		'ownership.sh': '9b957c6b815a0b1d974239a5bd7debcce4cc2244c306c391ac23e1b08d67a9cf',
		'ownership_schema.sh': '0c2d5c1d0982ec0cf2f124686d07d052ec4f79b37d24a6a6bdff697ea431d23e'
	}
});

/**
 * Runs a released pre-move ownership helper over an unpacked tarball, as that
 * release's updater does (installer.lua record_ownership).
 * @param {string} scratch Private folder.
 * @param {string} release Frozen release tag.
 * @param {string} work Unpacked tarball root.
 * @returns {{status: number, stderr: string}}
 */
function releasedOwnership(scratch, release, work) {
	const owner = path.join(scratch, 'owner-' + release);
	fs.mkdirSync(owner);
	for (const [name, expected] of Object.entries(FROZEN_SHA256[release])) {
		const bytes = fs.readFileSync(path.join(FROZEN_OWNERSHIP, release, name + '.frozen'));
		const actual = crypto.createHash('sha256').update(bytes).digest('hex');
		assert.equal(actual, expected, `${release} ${name} is the published record`);
		fs.writeFileSync(path.join(owner, name), bytes);
	}
	const run = spawnSync(
		'/bin/bash',
		[path.join(owner, 'ownership.sh'), path.join(work, 'linux'), path.join(work, '_shared'), work],
		{ encoding: 'utf8', timeout: 30000 }
	);
	return { status: run.status, stderr: run.stderr };
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

for (const release of Object.keys(FROZEN_SHA256)) {
	check(`the released ${release} ownership helper records the published tarball`, (scratch) => {
		const work = packAndUnpack(scratch, true);
		const run = releasedOwnership(scratch, release, work);
		assert.equal(run.status, 0, run.stderr);
		const manifest = fs.readFileSync(path.join(work, '.ergopti-owned-files'), 'utf8');
		assert.match(manifest, /\t_shared\/data\/locales\/en\.json\n/);
		assert.match(manifest, /\t_shared\/core\/i18n\/data\/locales\/en\.json\n/);
	});
	check(`the released ${release} ownership helper refuses it without the probe step`, (scratch) => {
		const run = releasedOwnership(scratch, release, packAndUnpack(scratch, false));
		assert.equal(run.status, 1);
		assert.equal(run.stderr, '[ownership] code=invalid_source\n');
	});
}

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

assert.equal(checks, 9, 'legacy updater probe check floor changed');
console.log('[OK] Linux legacy updater probes: 9 checks passed.');
