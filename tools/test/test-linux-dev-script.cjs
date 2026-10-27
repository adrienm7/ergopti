// tools/test/test-linux-dev-script.cjs

/**
 * ==============================================================================
 * MODULE: Linux Developer Daemon Runner Tests
 * DESCRIPTION:
 * Runs the real tools/dev/run-linux-dev.sh from a fixture clone whose native
 * build script, install/launch.sh, uname, luajit and systemctl are recording
 * shims. Proves it starts the packages' entry point with --service and the
 * tray, names the clone in the developer variable the daemon checks, puts the
 * clone first on LUA_PATH, stops an active installed unit first, builds the
 * native archive backend only when it is missing or older than its sources,
 * keeps a Reload's relayed --tray single, and refuses off Linux or without luv.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const SCRIPT = 'tools/dev/run-linux-dev.sh';
const IDENTIFIERS = 'static/ergopti_plus/_shared/data/identifiers.sh';
const DRIVER = 'static/ergopti_plus/linux';
const LIBRARY = `${DRIVER}/bin/libergopti_archive_publication.so`;

if (process.platform === 'win32') {
	console.log('[SKIP] The Linux developer runner is a Linux shell tool; not run on Windows.');
	process.exit(0);
}

let checks = 0;
const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-linux-dev-')));

/** Writes one executable shim. */
function shim(bin, name, body) {
	fs.writeFileSync(path.join(bin, name), `#!/bin/sh\n${body}\n`, { mode: 0o755 });
}

/** Builds a fixture clone; returns its paths. */
function fixture(name) {
	const clone = path.join(scratch, name, 'clone with space');
	const bin = path.join(scratch, name, 'bin');
	const log = path.join(scratch, name, 'calls.log');
	for (const relative of [SCRIPT, IDENTIFIERS]) {
		fs.mkdirSync(path.dirname(path.join(clone, relative)), { recursive: true });
		fs.copyFileSync(path.join(ROOT, relative), path.join(clone, relative));
	}
	for (const folder of ['bin', 'install', 'native/archive_output']) {
		fs.mkdirSync(path.join(clone, DRIVER, folder), { recursive: true });
	}
	fs.writeFileSync(path.join(clone, DRIVER, 'ergopti_hotstrings.lua'), '-- driver\n');
	for (const source of ['archive_publication.c', 'archive_publication.h']) {
		fs.writeFileSync(path.join(clone, DRIVER, 'native/archive_output', source), '/* c */\n');
	}
	fs.writeFileSync(
		path.join(clone, DRIVER, 'install/launch.sh'),
		`echo "launch $* root=$ERGOPTI_DEV_SOURCE_ROOT path=$LUA_PATH" >> "${log}"\n`
	);
	fs.mkdirSync(path.join(clone, 'tools/build'), { recursive: true });
	fs.writeFileSync(
		path.join(clone, 'tools/build/build-linux-native-output.sh'),
		`echo "native $*" >> "${log}"\n[ "\${FIXTURE_NATIVE_FAILS:-0}" = 1 ] && exit 1\nprintf so > "$4/libergopti_archive_publication.so"\n`
	);
	fs.mkdirSync(bin);
	shim(bin, 'uname', 'echo "${FIXTURE_UNAME:-Linux}"');
	shim(bin, 'luajit', '[ "${FIXTURE_NO_LUV:-0}" = 1 ] && exit 1\nexit 0');
	shim(
		bin,
		'systemctl',
		`echo "systemctl $*" >> "${log}"\n[ "$2" = is-active ] && [ "\${FIXTURE_UNIT_ACTIVE:-0}" = 1 ] && exit 0\n[ "$2" = is-active ] && exit 3\nexit 0`
	);
	return { clone, bin, log };
}

/** Runs the real runner inside a fixture. */
function run(paths, args = [], environment = {}) {
	return spawnSync(bashExecutable(), [path.join(paths.clone, SCRIPT), ...args], {
		encoding: 'utf8',
		timeout: 20000,
		env: {
			...process.env,
			PATH: `${paths.bin}${path.delimiter}${process.env.PATH}`,
			...environment
		}
	});
}
const calls = (paths) => (fs.existsSync(paths.log) ? fs.readFileSync(paths.log, 'utf8') : '');
const launches = (paths) =>
	calls(paths)
		.split('\n')
		.filter((line) => line.startsWith('launch '));

function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

try {
	check('starts launch.sh from the clone with --service, the tray and the developer root', () => {
		const paths = fixture('start');
		const result = run(paths, ['--verbose']);
		assert.equal(result.status, 0, result.stderr);
		const [launch] = launches(paths);
		assert.ok(launch.startsWith('launch --service --tray --verbose '), launch);
		assert.ok(launch.includes(` root=${paths.clone} `), launch);
		assert.ok(
			launch.includes(`path=${paths.clone}/${DRIVER}/?.lua;`),
			'the clone is first on LUA_PATH'
		);
		assert.match(result.stdout, /developer source mode/);
	});

	check('builds the native archive backend once, then only when a source is newer', () => {
		const paths = fixture('native');
		assert.equal(run(paths).status, 0);
		assert.equal(fs.readFileSync(path.join(paths.clone, LIBRARY), 'utf8'), 'so');
		assert.equal((calls(paths).match(/^native /gm) || []).length, 1);
		fs.rmSync(paths.log);
		const later = new Date(Date.now() + 60000);
		fs.utimesSync(path.join(paths.clone, LIBRARY), later, later);
		assert.equal(run(paths).status, 0);
		assert.doesNotMatch(calls(paths), /^native /m, 'an up-to-date backend is not rebuilt');
		const newest = new Date(Date.now() + 120000);
		fs.utimesSync(
			path.join(paths.clone, DRIVER, 'native/archive_output/archive_publication.c'),
			newest,
			newest
		);
		assert.equal(run(paths).status, 0);
		assert.match(calls(paths), /^native /m, 'a newer C source rebuilds the backend');
	});

	check('refuses to start when the native backend does not build', () => {
		const paths = fixture('native-fails');
		const result = run(paths, [], { FIXTURE_NATIVE_FAILS: '1' });
		assert.equal(result.status, 1);
		assert.match(result.stderr, /native archive backend did not build/);
		assert.equal(launches(paths).length, 0);
	});

	check('stops an active installed unit before starting', () => {
		const paths = fixture('unit');
		const result = run(paths, [], { FIXTURE_UNIT_ACTIVE: '1' });
		assert.equal(result.status, 0, result.stderr);
		const log = calls(paths);
		assert.match(log, /^systemctl --user stop ergopti-hotstrings\.service$/m);
		assert.ok(log.indexOf('systemctl --user stop') < log.indexOf('launch '), 'stop before launch');
	});

	check("keeps a Reload's relayed --tray single", () => {
		const paths = fixture('relay');
		assert.equal(run(paths, ['--tray']).status, 0);
		assert.ok(launches(paths)[0].startsWith('launch --service --tray root='), launches(paths)[0]);
	});

	check('refuses off Linux and without LuaJIT luv, before any start', () => {
		const paths = fixture('refusals');
		const mac = run(paths, [], { FIXTURE_UNAME: 'Darwin' });
		assert.equal(mac.status, 1);
		assert.match(mac.stderr, /Linux only/);
		const noLuv = run(paths, [], { FIXTURE_NO_LUV: '1' });
		assert.equal(noLuv.status, 1);
		assert.match(noLuv.stderr, /luv is missing/);
		assert.equal(launches(paths).length, 0);
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(`[OK] Linux developer daemon runner (${checks} checks).`);
