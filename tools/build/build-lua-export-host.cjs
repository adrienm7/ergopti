// tools/build/build-lua-export-host.cjs

/**
 * ==============================================================================
 * MODULE: Lua Export Host POSIX Build and Proof
 * DESCRIPTION:
 * Builds the Windows driver's Lua export host (static/ergopti_plus/windows/
 * native/ergopti_lua_export.c) with a POSIX C compiler from the pinned Lua
 * archive (ergopti_lua_export.pin.json), runs its self-test, and runs the layout
 * editor's export byte-equality test through it, so the host's restriction and
 * its results are proven on any machine before the Windows build ships the
 * executable (tools/build/build_windows_lua_export.ps1).
 * USAGE: node tools/build/build-lua-export-host.cjs --archive <lua-5.4.x.tar.gz>
 *          --out <new empty folder> [--cc gcc]
 *
 * FEATURES & RATIONALE:
 * 1. The same inputs as the Windows build: the archive must have the pinned
 *    SHA-256 and its lua.h the committed licence notice; only the pinned source
 *    files are compiled, so io, os, debug, package and coroutine are absent.
 * 2. No network: the caller passes the archive (CI never downloads).
 * 3. Fail fast: every refused input or failed step exits non-zero with why.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { REPO_ROOT, shared } = require('../lib/paths.cjs');

const NATIVE = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'native');
const PIN_PATH = path.join(NATIVE, 'ergopti_lua_export.pin.json');
const HOST_SOURCE = path.join(NATIVE, 'ergopti_lua_export.c');
const TEST_SOURCE = path.join(NATIVE, 'ergopti_lua_export_test.c');
const C_FLAGS = ['-std=c99', '-O2'];
const STRICT_FLAGS = ['-Wall', '-Wextra', '-Werror'];

/** Exits with a reason. */
function fail(message) {
	console.error(`build-lua-export-host: ${message}`);
	process.exit(1);
}

/** Runs a command and fails on any error, showing its output. */
function run(command, args, options = {}) {
	const result = spawnSync(command, args, { encoding: 'utf8', ...options });
	if (result.error) fail(`${command}: ${result.error.message}`);
	if (result.status !== 0)
		fail(`${command} ${args.join(' ')} exited ${result.status}\n${result.stdout}${result.stderr}`);
	return result;
}

/** The value after a --name argument. */
function option(name, fallback) {
	const index = process.argv.indexOf(`--${name}`);
	if (index === -1) {
		if (fallback === undefined) fail(`--${name} is required`);
		return fallback;
	}
	const value = process.argv[index + 1];
	if (!value || value.startsWith('--')) fail(`--${name} needs a value`);
	return value;
}

const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

/**
 * The host's source fingerprint: SHA-256 of '<archive sha256>\n<host source sha256>\n'
 * (the rule of ergopti_lua_export.pin.json, which the PowerShell build applies too).
 */
function sourceFingerprint(pin) {
	return sha256(`${pin.sha256}\n${sha256(fs.readFileSync(HOST_SOURCE))}\n`);
}

/** True when lua.h carries every line of the committed notice, in order. */
function noticeMatches(luaHeader, license) {
	const notice = license.split('\n').slice(license.split('\n').indexOf('') + 1);
	const header = luaHeader.split('\n').map((line) => line.replace(/^\* ?/, '').trimEnd());
	let at = header.indexOf(notice[0]);
	if (at === -1) return false;
	for (const line of notice) {
		if (line === '') {
			if (header[at] !== '') return false;
		} else if (header[at] !== line) return false;
		at++;
	}
	return true;
}

function main() {
	const archive = path.resolve(option('archive'));
	const out = path.resolve(option('out'));
	const cc = option('cc', 'gcc');
	const pin = JSON.parse(fs.readFileSync(PIN_PATH, 'utf8'));
	if (pin.schema_version !== 1 || !/^[0-9a-f]{64}$/.test(pin.sha256)) fail('the pin is refused');
	if (sha256(fs.readFileSync(archive)) !== pin.sha256)
		fail(`${archive} is not the pinned ${pin.lua_release} archive`);
	if (fs.existsSync(out) && fs.readdirSync(out).length) fail(`${out} is not empty`);
	fs.mkdirSync(path.join(out, 'objects'), { recursive: true });
	run('tar', ['-xzf', archive, '-C', out]);
	const src = path.join(out, pin.archive_root, 'src');
	const license = fs.readFileSync(path.join(REPO_ROOT, pin.license_file), 'utf8').trimEnd();
	if (!noticeMatches(fs.readFileSync(path.join(src, 'lua.h'), 'utf8'), license))
		fail('the archive lua.h does not carry the committed licence notice');

	// The pinned Lua files only: a library left out cannot be reached at all.
	const objects = pin.sources.map((file) => {
		const object = path.join(out, 'objects', file.replace(/\.c$/, '.o'));
		run(cc, [...C_FLAGS, '-w', '-DLUA_USE_POSIX', '-c', path.join(src, file), '-o', object]);
		return object;
	});
	const fingerprint = sourceFingerprint(pin);
	const define = `-DERGOPTI_LUA_EXPORT_FINGERPRINT=${fingerprint}`;
	const host = path.join(out, 'ergopti_lua_export');
	const test = path.join(out, 'ergopti_lua_export_test');
	run(cc, [
		...C_FLAGS,
		...STRICT_FLAGS,
		define,
		`-I${src}`,
		HOST_SOURCE,
		...objects,
		'-lm',
		'-o',
		host
	]);
	run(cc, [
		...C_FLAGS,
		...STRICT_FLAGS,
		define,
		`-I${src}`,
		`-I${NATIVE}`,
		TEST_SOURCE,
		...objects,
		'-lm',
		'-o',
		test
	]);
	const scratch = path.join(out, 'scratch');
	fs.mkdirSync(scratch);
	process.stdout.write(run(test, [shared(), scratch]).stdout);

	const identity = JSON.parse(run(host, ['--identity']).stdout);
	if (identity.lua_release !== pin.lua_release || identity.source_fingerprint !== fingerprint)
		fail(`the built identity is refused: ${JSON.stringify(identity)}`);

	// The page's XKB and KLC files built through this host are the site's bytes.
	process.stdout.write(
		run(
			process.execPath,
			[path.join(REPO_ROOT, 'tools', 'test', 'test-layout-editor-target-exports.cjs')],
			{
				env: { ...process.env, ERGOPTI_LUA_EXPORT_HOST: host }
			}
		).stdout
	);
	console.log(`build-lua-export-host: ${host} (${pin.lua_release}, fingerprint ${fingerprint})`);
}

if (require.main === module) main();

module.exports = { sourceFingerprint, noticeMatches };
