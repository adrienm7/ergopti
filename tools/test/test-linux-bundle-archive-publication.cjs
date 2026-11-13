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
	fs.copyFileSync(
		path.join(root, 'tools/build/build-linux-bundle-archive.sh'),
		path.join(scripts, 'bundle.sh')
	);
	fs.writeFileSync(path.join(scripts, 'write_build_stamp.sh'), '#!/bin/bash\nexit 0\n');
	fs.writeFileSync(
		path.join(scripts, 'add-linux-legacy-update-probes.sh'),
		'#!/bin/bash\nexit 0\n'
	);
	fs.writeFileSync(
		path.join(scripts, 'stage-linux-private-runtime.sh'),
		'#!/bin/bash\nmkdir -p -- "$2"\n'
	);
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
		encoding: 'utf8',
		timeout: 15000,
		env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: build }
	});
	assert.equal(result.status, 0, result.stderr || result.stdout);
	for (const suffix of ['', '.sha256'])
		assert.equal(
			fs.readFileSync(path.join(scratch, `user-data${suffix || '-archive'}`), 'utf8'),
			'user data remains intact\n'
		);
	assert.ok(fs.statSync(path.join(build, 'bundle.tar.gz')).size > 0);
	// A failed checksum publication must leave the previously published pair intact.
	fs.writeFileSync(path.join(build, 'bundle.tar.gz'), 'previous archive\n');
	fs.writeFileSync(path.join(build, 'bundle.tar.gz.sha256'), 'previous checksum\n');
	const oldArchive = fs.readFileSync(path.join(build, 'bundle.tar.gz'));
	const oldChecksum = fs.readFileSync(path.join(build, 'bundle.tar.gz.sha256'));
	const previousStat = fs.statSync(path.join(build, 'bundle.tar.gz'));
	const alias = path.join(scratch, 'previous-archive-link');
	fs.linkSync(path.join(build, 'bundle.tar.gz'), alias);
	const bin = path.join(scratch, 'bin');
	fs.mkdirSync(bin);
	fs.writeFileSync(
		path.join(bin, 'mv'),
		`#!/bin/bash
for arg in "$@"; do
  case "$arg" in
    */.bundle-archive.*/bundle.tar.gz.sha256)
      if [ "\${CHANGE_OUTPUT:-}" = write ]; then
        printf 'concurrent bytes\\n' > "$ERGOPTI_LINUX_BUILD_DIR/bundle.tar.gz"
      elif [ "\${CHANGE_OUTPUT:-}" = symlink ]; then
        /usr/bin/mv "$ERGOPTI_LINUX_BUILD_DIR/bundle.tar.gz" "$ERGOPTI_LINUX_BUILD_DIR/foreign-image"
        /usr/bin/ln -s "$ERGOPTI_LINUX_BUILD_DIR/foreign-image" "$ERGOPTI_LINUX_BUILD_DIR/bundle.tar.gz"
      fi
      exit 42 ;;
    */.bundle-rollback.*/old-archive) [ "\${FAIL_RECOVERY:-0}" = 1 ] && exit 43 ;;
  esac
done
exec /usr/bin/mv "$@"
`,
		{ mode: 0o755 }
	);
	const failed = spawnSync('/bin/bash', [path.join(scripts, 'bundle.sh'), 'bundle.tar.gz'], {
		encoding: 'utf8',
		timeout: 15000,
		env: { ...process.env, PATH: `${bin}:/usr/bin:/bin`, ERGOPTI_LINUX_BUILD_DIR: build }
	});
	assert.notEqual(failed.status, 0, 'checksum publication refusal fails the build');
	assert.deepEqual(
		fs.readFileSync(path.join(build, 'bundle.tar.gz')),
		oldArchive,
		'restore previous archive'
	);
	assert.deepEqual(
		fs.readFileSync(path.join(build, 'bundle.tar.gz.sha256')),
		oldChecksum,
		'preserve previous checksum'
	);
	assert.equal(
		fs.statSync(path.join(build, 'bundle.tar.gz')).ino,
		previousStat.ino,
		'restore original inode and its metadata'
	);
	assert.equal(fs.statSync(alias).ino, previousStat.ino, 'preserve original hard links');
	assert.ok(
		!fs.readdirSync(build).some((name) => name.startsWith('.bundle-rollback.')),
		'successful rollback cleans its recovery files'
	);
	fs.unlinkSync(path.join(build, 'bundle.tar.gz'));
	fs.unlinkSync(path.join(build, 'bundle.tar.gz.sha256'));
	const absent = spawnSync('/bin/bash', [path.join(scripts, 'bundle.sh'), 'bundle.tar.gz'], {
		encoding: 'utf8',
		timeout: 15000,
		env: { ...process.env, PATH: `${bin}:/usr/bin:/bin`, ERGOPTI_LINUX_BUILD_DIR: build }
	});
	assert.notEqual(absent.status, 0);
	assert.equal(
		fs.existsSync(path.join(build, 'bundle.tar.gz')),
		false,
		'remove the newly published archive after refusal'
	);
	assert.equal(fs.existsSync(path.join(build, 'bundle.tar.gz.sha256')), false);
	for (const change of ['write', 'symlink']) {
		fs.writeFileSync(path.join(build, 'bundle.tar.gz'), oldArchive);
		fs.writeFileSync(path.join(build, 'bundle.tar.gz.sha256'), oldChecksum);
		const concurrent = spawnSync('/bin/bash', [path.join(scripts, 'bundle.sh'), 'bundle.tar.gz'], {
			encoding: 'utf8',
			timeout: 15000,
			env: {
				...process.env,
				PATH: `${bin}:/usr/bin:/bin`,
				ERGOPTI_LINUX_BUILD_DIR: build,
				CHANGE_OUTPUT: change
			}
		});
		assert.notEqual(concurrent.status, 0);
		assert.match(concurrent.stderr, /recovery files retained/);
		if (change === 'write')
			assert.equal(
				fs.readFileSync(path.join(build, 'bundle.tar.gz'), 'utf8'),
				'concurrent bytes\n'
			);
		else assert.ok(fs.lstatSync(path.join(build, 'bundle.tar.gz')).isSymbolicLink());
		const saved = fs.readdirSync(build).find((name) => name.startsWith('.bundle-rollback.'));
		assert.ok(saved);
		assert.deepEqual(fs.readFileSync(path.join(build, saved, 'old-archive')), oldArchive);
		fs.unlinkSync(path.join(build, 'bundle.tar.gz'));
		fs.unlinkSync(path.join(build, 'bundle.tar.gz.sha256'));
		if (change === 'symlink') fs.unlinkSync(path.join(build, 'foreign-image'));
		fs.rmSync(path.join(build, saved), { recursive: true });
	}
	// Replace the path after its stat but immediately before dd opens it.
	fs.writeFileSync(
		path.join(bin, 'dd'),
		`#!/bin/bash
for arg in "$@"; do
  if [ "$arg" = "if=$ERGOPTI_LINUX_BUILD_DIR/bundle.tar.gz" ]; then
    /usr/bin/mv "$ERGOPTI_LINUX_BUILD_DIR/bundle.tar.gz" "$ERGOPTI_LINUX_BUILD_DIR/foreign-image"
    /usr/bin/mkfifo "$ERGOPTI_LINUX_BUILD_DIR/bundle.tar.gz"
  fi
done
exec /usr/bin/dd "$@"
`,
		{ mode: 0o755 }
	);
	fs.writeFileSync(path.join(build, 'bundle.tar.gz'), oldArchive);
	fs.writeFileSync(path.join(build, 'bundle.tar.gz.sha256'), oldChecksum);
	const fifo = spawnSync(
		'/usr/bin/timeout',
		['--kill-after=1', '3', '/bin/bash', path.join(scripts, 'bundle.sh'), 'bundle.tar.gz'],
		{
			encoding: 'utf8',
			timeout: 6000,
			env: { ...process.env, PATH: `${bin}:/usr/bin:/bin`, ERGOPTI_LINUX_BUILD_DIR: build }
		}
	);
	assert.notEqual(fifo.status, 0);
	assert.notEqual(fifo.status, 124, 'substituted FIFO must not block the hash');
	assert.notEqual(fifo.status, 137, 'FIFO hash must not require timeout escalation');
	assert.ifError(fifo.error);
	assert.ok(fs.lstatSync(path.join(build, 'bundle.tar.gz')).isFIFO());
	assert.match(fifo.stderr, /recovery files retained/);
	const fifoBackup = fs.readdirSync(build).find((name) => name.startsWith('.bundle-rollback.'));
	assert.deepEqual(fs.readFileSync(path.join(build, fifoBackup, 'old-archive')), oldArchive);
	fs.unlinkSync(path.join(build, 'bundle.tar.gz'));
	fs.unlinkSync(path.join(build, 'bundle.tar.gz.sha256'));
	fs.unlinkSync(path.join(build, 'foreign-image'));
	fs.unlinkSync(path.join(bin, 'dd'));
	fs.rmSync(path.join(build, fifoBackup), { recursive: true });
	fs.writeFileSync(path.join(build, 'bundle.tar.gz'), oldArchive);
	fs.writeFileSync(path.join(build, 'bundle.tar.gz.sha256'), oldChecksum);
	const recoveryFailure = spawnSync(
		'/bin/bash',
		[path.join(scripts, 'bundle.sh'), 'bundle.tar.gz'],
		{
			encoding: 'utf8',
			timeout: 15000,
			env: {
				...process.env,
				PATH: `${bin}:/usr/bin:/bin`,
				ERGOPTI_LINUX_BUILD_DIR: build,
				FAIL_RECOVERY: '1'
			}
		}
	);
	assert.notEqual(recoveryFailure.status, 0);
	assert.match(recoveryFailure.stderr, /recovery files retained/);
	const retained = fs.readdirSync(build).find((name) => name.startsWith('.bundle-rollback.'));
	assert.ok(retained, 'failed rollback retains the recovery directory');
	assert.deepEqual(fs.readFileSync(path.join(build, retained, 'old-archive')), oldArchive);

	console.log('Linux archive publication preserves hardlinked files.');
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
