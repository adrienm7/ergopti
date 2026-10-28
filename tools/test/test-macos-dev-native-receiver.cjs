// tools/test/test-macos-dev-native-receiver.cjs

/**
 * ==============================================================================
 * MODULE: macOS Developer App Native Receiver Tests
 * DESCRIPTION:
 * The bundled native network receiver (platform/network/native_http.py)
 * derived its launcher from its own path inside the app payload. A developer
 * app runs the clone, so MLX and Ollama downloads stopped with "The bundled
 * native network receiver is unavailable" (field report 2026-10-27). These
 * checks run the real _resolve_worker from fixture trees: a clone is admitted
 * only when the exported launcher's sealed Info.plist records exactly that
 * clone and the launcher's device and inode match, and the packaged path is
 * unchanged.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const RECEIVER = 'static/ergopti_plus/macos/platform/network/native_http.py';
const IDENTIFIERS = 'static/ergopti_plus/_shared/data/identifiers.py';
const DEV = JSON.parse(
	fs.readFileSync(path.join(ROOT, 'static/ergopti_plus/_shared/data/identifiers.json'), 'utf8')
).dev_source;

if (process.platform === 'win32') {
	console.log(
		'[SKIP] The macOS native receiver identity proof uses POSIX device and inode numbers.'
	);
	process.exit(0);
}

let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-dev-receiver-')));

/** Copies a repository file into a fixture tree. */
function place(base, relative, target = relative) {
	const destination = path.join(base, target);
	fs.mkdirSync(path.dirname(destination), { recursive: true });
	fs.copyFileSync(path.join(ROOT, relative), destination);
	return destination;
}

/** Builds a launcher bundle whose Info.plist records the given dict. */
function application(name, dict) {
	const app = path.join(scratch, name, 'ErgoptiPlus.app');
	const launcher = path.join(app, 'Contents/MacOS/ErgoptiPlus');
	fs.mkdirSync(path.dirname(launcher), { recursive: true });
	fs.writeFileSync(launcher, '#!/bin/sh\n', { mode: 0o755 });
	const entries = Object.entries(dict)
		.map(([key, value]) => `<key>${key}</key><string>${value}</string>`)
		.join('');
	fs.writeFileSync(
		path.join(app, 'Contents/Info.plist'),
		`<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>${entries}</dict></plist>\n`
	);
	return { app, launcher };
}

/** Runs the real _resolve_worker of one placed receiver. */
function resolve(receiver, launcher, environment = {}) {
	const identity = fs.statSync(launcher, { bigint: true });
	const result = spawnSync(
		'python3',
		[
			'-I',
			'-c',
			'import importlib.util,sys\n' +
				"s=importlib.util.spec_from_file_location('r',sys.argv[1]); m=importlib.util.module_from_spec(s); s.loader.exec_module(m)\n" +
				'try:\n    print(m._resolve_worker())\nexcept m.NativeHTTPError as e:\n    print("refused", e)',
			receiver
		],
		{
			encoding: 'utf8',
			env: {
				PATH: process.env.PATH,
				ERGOPTI_LAUNCHER_EXECUTABLE: launcher,
				ERGOPTI_LAUNCHER_DEVICE: String(identity.dev),
				ERGOPTI_LAUNCHER_INODE: String(identity.ino),
				...environment
			}
		}
	);
	assert.equal(result.status, 0, result.stderr);
	return result.stdout.trim();
}

try {
	const clone = path.join(scratch, 'clone with space');
	const receiver = place(clone, RECEIVER);
	place(clone, IDENTIFIERS);
	const developer = application('developer', { [DEV.plist_key]: clone });
	const dev = { [DEV.environment]: clone };

	check('a developer app running this clone admits its exact launcher', () => {
		assert.equal(resolve(receiver, developer.launcher, dev), developer.launcher);
	});

	check('a launcher whose sealed plist records another clone is refused', () => {
		const other = application('other', { [DEV.plist_key]: path.join(scratch, 'elsewhere') });
		assert.match(resolve(receiver, other.launcher, dev), /^refused/);
		const packaged = application('packaged', { CFBundleName: 'ErgoptiPlus' });
		assert.match(resolve(receiver, packaged.launcher, dev), /^refused/);
	});

	check('a clone without the launcher root, or naming another tree, is refused', () => {
		assert.match(resolve(receiver, developer.launcher), /^refused/);
		assert.match(
			resolve(receiver, developer.launcher, { [DEV.environment]: path.join(scratch, 'elsewhere') }),
			/^refused/
		);
	});

	check('the device and inode proof still applies to a developer launcher', () => {
		assert.match(
			resolve(receiver, developer.launcher, { ...dev, ERGOPTI_LAUNCHER_INODE: '1' }),
			/^refused/
		);
	});

	check('the packaged payload path is unchanged and needs no developer names', () => {
		const packaged = application('payload', { CFBundleName: 'ErgoptiPlus' });
		const bundled = place(
			packaged.app,
			RECEIVER,
			'Contents/Resources/static/ergopti_plus/macos/platform/network/native_http.py'
		);
		assert.equal(resolve(bundled, packaged.launcher), packaged.launcher);
		assert.equal(resolve(bundled, packaged.launcher, dev), packaged.launcher);
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
console.log(`[OK] macOS developer app native receiver identity (${checks} checks).`);
