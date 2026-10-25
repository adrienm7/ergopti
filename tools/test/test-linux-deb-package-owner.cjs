// tools/test/test-linux-deb-package-owner.cjs

/**
 * MODULE: Rootless Debian Package Attributes Regression
 * Builds the real bundle and DEB archive as an ordinary user, then asks the
 * native archive tools for every payload owner and permission. Both public
 * package attributes and untouched private source/config modes are checked.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const bundle = path.join(ROOT, 'build/linux');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-deb-owner-'));
const dataName = 'package-permission-data-probe';
const executableName = 'package-permission-executable-probe';
const linkName = 'package-permission-private-link';
const failures = [];

function run(script, args, env) {
	return spawnSync(bashExecutable(), ['-c', script, 'deb-owner', ...args], {
		env,
		encoding: 'utf8',
		maxBuffer: 4 * 1024 * 1024,
		timeout: 120000
	});
}

function archiveRows(archive, env) {
	const listed = run(
		'set -euo pipefail; dpkg-deb --fsys-tarfile "$1" | tar --numeric-owner -tvf -',
		[archive],
		env
	);
	assert.equal(listed.status, 0, listed.stderr || listed.error?.message);
	return listed.stdout
		.trim()
		.split('\n')
		.map((line) => {
			const match = /^(\S+)\s+(\d+)\/(\d+)\s+\d+\s+\S+\s+\S+\s+(.*)$/.exec(line);
			assert.ok(match, `unparsed native tar receipt: ${line}`);
			return { mode: match[1], uid: Number(match[2]), gid: Number(match[3]), name: match[4] };
		});
}

try {
	assert.equal(process.platform, 'linux', 'native DEB attributes require Linux');
	assert.notEqual(process.getuid(), 0, 'root would hide leaked caller ownership');
	for (const mask of ['022', '077']) {
		try {
			const env = {
				...process.env,
				ERGOPTI_BUILD_VERSION: '1.0.3',
				DPKG_DEB_COMPRESSOR_TYPE: 'none'
			};
			const assembled = run(
				'set -euo pipefail; umask "$1"; bash "$2"',
				[mask, path.join(ROOT, 'tools/build/build-linux-driver.sh')],
				env
			);
			assert.equal(
				assembled.status,
				0,
				assembled.stderr || assembled.stdout || assembled.error?.message
			);
			const driver = path.join(bundle, 'linux');
			const privateConfig = path.join(scratch, `config-${mask}.toml`);
			fs.writeFileSync(privateConfig, 'private-fixture = true\n', { mode: 0o600 });
			const data = path.join(driver, dataName);
			const executable = path.join(driver, executableName);
			fs.writeFileSync(data, 'data must remain nonexecutable\n');
			fs.chmodSync(data, 0o660);
			fs.writeFileSync(executable, '#!/bin/sh\nexit 0\n');
			fs.chmodSync(executable, 0o770);
			fs.symlinkSync(privateConfig, path.join(driver, linkName));
			const packaged = run(
				'set -euo pipefail; umask "$1"; bash "$2"',
				[mask, path.join(ROOT, 'tools/build/build-linux-deb.sh')],
				env
			);
			assert.equal(
				packaged.status,
				0,
				`umask ${mask}: ${packaged.stderr || packaged.stdout || packaged.error?.message}`
			);
			const artifacts = fs.readdirSync(bundle).filter((name) => name.endsWith('.deb'));
			assert.equal(artifacts.length, 1, 'the real producer must create one DEB');
			const archive = path.join(bundle, artifacts[0]);
			const rows = archiveRows(archive, env);
			const byName = new Map(rows.map((row) => [row.name, row]));
			for (const name of [
				'./usr/bin/ergopti',
				'./usr/lib/ergopti/ergopti_hotstrings.lua',
				'./usr/lib/ergopti/bin/libergopti_archive_publication.so',
				'./usr/lib/ergopti/install/setup_permissions.sh'
			])
				assert.ok(byName.has(name), `missing real package payload: ${name}`);
			const wrongOwners = rows.filter((row) => row.uid !== 0 || row.gid !== 0);
			const wrongModes = rows.filter((row) => {
				if (row.mode[0] === 'l') return false;
				if (
					row.mode[1] !== 'r' ||
					row.mode[4] !== 'r' ||
					row.mode[7] !== 'r' ||
					row.mode[5] === 'w' ||
					row.mode[8] === 'w'
				)
					return true;
				return row.mode[0] === 'd' && [3, 6, 9].some((index) => row.mode[index] !== 'x');
			});
			console.log(
				`DEB_NATIVE_ATTRIBUTES umask=${mask} entries=${rows.length} bad_owners=${wrongOwners.length} bad_modes=${wrongModes.length}`
			);
			assert.deepEqual(
				{ owners: wrongOwners.length, modes: wrongModes.length },
				{ owners: 0, modes: 0 },
				'public package attributes must not inherit private build attributes'
			);
			assert.equal(
				byName.get(`./usr/lib/ergopti/${dataName}`).mode,
				'-rw-r--r--',
				'data must not gain executable bits'
			);
			assert.equal(
				byName.get(`./usr/lib/ergopti/${executableName}`).mode,
				'-rwxr-xr-x',
				'executable intent must survive private source modes'
			);
			assert.equal(fs.statSync(data).mode & 0o777, 0o660, 'source data modes remain private');
			assert.equal(
				fs.statSync(executable).mode & 0o777,
				0o770,
				'source executable modes remain unchanged'
			);
			assert.equal(
				fs.statSync(privateConfig).mode & 0o777,
				0o600,
				'normalization must not follow a payload symlink to private config'
			);
			assert.equal(
				fs.statSync(path.join(bundle, 'deb/usr/lib/ergopti')).uid,
				process.getuid(),
				'root ownership belongs to archive metadata, not a privileged staging mutation'
			);
			fs.unlinkSync(archive);
			const stagedOnly = run(
				'set -euo pipefail; umask "$1"; bash "$2" --skip-deb',
				[mask, path.join(ROOT, 'tools/build/build-linux-deb.sh')],
				env
			);
			assert.equal(stagedOnly.status, 0, stagedOnly.stderr);
			const manualCommand = stagedOnly.stdout.match(/^To package: (.+)$/m);
			assert.ok(
				manualCommand,
				'structure-only mode must print its complete native producer recipe'
			);
			const manual = run('set -euo pipefail; ' + manualCommand[1], [], env);
			assert.equal(manual.status, 0, manual.stderr);
			const manualRows = archiveRows(archive, env);
			assert.equal(
				manualRows.length,
				rows.length,
				'the advertised recipe must package the same payload'
			);
			assert.ok(
				manualRows.every((row) => row.uid === 0 && row.gid === 0),
				'the advertised manual producer must also publish root ownership'
			);
			fs.unlinkSync(archive);
			console.log(`PASS deb-rootless-public-attributes-umask-${mask}`);
		} catch (error) {
			failures.push(mask);
			console.error(`FAIL deb-rootless-public-attributes-umask-${mask}: ${error.message}`);
		}
	}
} finally {
	for (const name of [dataName, executableName, linkName])
		fs.rmSync(path.join(bundle, 'linux', name), { force: true });
	fs.rmSync(scratch, { recursive: true, force: true });
}
assert.equal(failures.length, 0, `native DEB attribute failures: ${failures.join(', ')}`);
