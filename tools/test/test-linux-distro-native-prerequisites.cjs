// tools/test/test-linux-distro-native-prerequisites.cjs

/** Executes distro preparation through its actual first package-manager boundary. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const ROOT = path.resolve(__dirname, '../..');
const helper = path.join(ROOT, 'tools/test/prepare-linux-distro-unit.sh');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-unit-prerequisites-'));
const bashPath = (value) =>
	value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);
// These are runtime ABI/CLI package providers, not desktop networking backends.
// Genuine distro qualification separately executes GVariant and SQLite fixtures.
const providers = [
	['debian', 'apt-get', 'libglib2.0-0t64', 'sqlite3'],
	['fedora', 'dnf', 'glib2', 'sqlite'],
	['arch', 'pacman', 'glib2', 'sqlite'],
	['alpine', 'apk', 'glib', 'sqlite'],
	['opensuse', 'zypper', 'libglib-2_0-0', 'sqlite3']
];
try {
	const bin = path.join(scratch, 'bin');
	fs.mkdirSync(bin);
	const recorded = path.join(scratch, 'package-argv');
	for (const command of providers.map((entry) => entry[1])) {
		fs.writeFileSync(
			path.join(bin, command),
			'#!/bin/bash\nprintf "%s\\0" "${0##*/}" "$@" > "$ERGOPTI_TEST_PACKAGE_ARGS"\nexit 73\n',
			{ mode: 0o755 }
		);
	}
	// A broken fail-fast boundary must never create an account on the test host.
	for (const command of ['useradd', 'adduser', 'luajit']) {
		fs.writeFileSync(path.join(bin, command), '#!/bin/bash\nexit 99\n', { mode: 0o755 });
	}
	const invoke = (distro, suite) =>
		spawnSync(bashExecutable(), [bashPath(helper), distro, bashPath(ROOT), suite], {
			encoding: 'utf8',
			timeout: 5000,
			env: {
				...process.env,
				PATH: `${bashPath(bin)}:/usr/bin:/bin`,
				ERGOPTI_TEST_PACKAGE_ARGS: bashPath(recorded)
			}
		});
	let checks = 0;
	for (const [distro, manager, glib, sqlite] of providers) {
		for (const suite of ['unit', 'integration']) {
			fs.rmSync(recorded, { force: true });
			const result = invoke(distro, suite);
			assert.equal(result.error, undefined, `${distro}/${suite}: helper must finish`);
			assert.equal(
				result.status,
				73,
				`${distro}/${suite}: package refusal must propagate before user/native setup: ${result.stderr}`
			);
			const [actualManager, ...args] = fs
				.readFileSync(recorded, 'utf8')
				.split('\0')
				.filter(Boolean);
			assert.equal(actualManager, manager, `${distro}: the actual authored backend must execute`);
			assert.ok(args.includes(glib), `${distro}: native GVariant requires declared ${glib}`);
			assert.ok(
				args.includes(sqlite),
				`${distro}: native metric reset requires declared ${sqlite}`
			);
			checks++;
		}
	}
	for (const [distro, suite] of [
		['unknown', 'unit'],
		['debian', 'unknown']
	]) {
		fs.rmSync(recorded, { force: true });
		const result = invoke(distro, suite);
		assert.equal(result.error, undefined);
		assert.notEqual(result.status, 0);
		assert.notEqual(result.status, 73, 'invalid preparation must refuse before any package action');
		assert.equal(fs.existsSync(recorded), false);
		checks++;
	}
	console.log(
		`Linux native unit prerequisites: ${checks} executed dispatch/refusal controls; 0 skipped.`
	);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
