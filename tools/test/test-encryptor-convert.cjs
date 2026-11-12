// tools/test/test-encryptor-convert.cjs

/**
 * ==============================================================================
 * MODULE: Encryptor Conversion Receipts
 * DESCRIPTION:
 * Runs the Encryptor's actual conversion helper with the system OpenSSL over
 * private temporary files, behind a recording openssl shim that keeps every
 * argument it receives. The AppleScript that calls the helper cannot run off
 * macOS, so its password transport is checked on its source.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const resources = path.join(
	root,
	'static/ergopti_plus/macos/apps/Encryptor.app/Contents/Resources'
);
const helper = path.join(resources, 'encryptor_convert.sh');
const applescript = path.join(resources, 'Scripts/main.applescript');
const SENTINEL = "s3ntinel-'pw $HOME é";

/** Resolves the real openssl before the recording shim shadows it. */
function realOpenssl() {
	const found = spawnSync('/bin/sh', ['-c', 'command -v openssl'], { encoding: 'utf8' });
	assert.equal(found.status, 0, 'the system openssl is required by this check');
	return found.stdout.trim();
}

const openssl = realOpenssl();
const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-encryptor-convert-'));
const shimDir = path.join(work, 'bin');
const argvLog = path.join(work, 'openssl-argv.log');
fs.mkdirSync(shimDir);
fs.writeFileSync(
	path.join(shimDir, 'openssl'),
	`#!/bin/sh\nprintf '%s\\n' "$@" >> '${argvLog}'\nexec '${openssl}' "$@"\n`,
	{ mode: 0o755 }
);

/** Writes the password file the AppleScript would write: no trailing newline. */
function passwordFile(name, secret) {
	const file = path.join(work, name);
	fs.writeFileSync(file, secret, { mode: 0o600 });
	return file;
}

/** Runs the helper through the recording shim. */
function convert(mode, input, output, password) {
	return spawnSync('/bin/sh', [helper, mode, input, output, password], {
		encoding: 'utf8',
		env: { ...process.env, PATH: `${shimDir}:${process.env.PATH}` }
	});
}

let failed = 0;
/** Runs one scenario and reports it. */
function scenario(name, body) {
	try {
		body();
		console.log(`ok Encryptor ${name}`);
	} catch (error) {
		failed += 1;
		console.error(`FAIL Encryptor ${name}: ${error.message}`);
	}
}

try {
	scenario(
		'(encryptor-password-not-in-argv) the AppleScript never puts the password in a shell command',
		() => {
			const code = fs
				.readFileSync(applescript, 'utf8')
				.split('\n')
				.filter((line) => !/^\s*--/.test(line));
			assert.ok(code.length > 0, 'the AppleScript source is read');
			assert.deepEqual(
				code.filter((line) => line.includes('pass:')),
				[],
				'no OpenSSL "pass:" argument is built'
			);
			assert.deepEqual(
				code.filter((line) => /\bthe_password\b/.test(line) && line.includes('&')),
				[],
				'the password is never concatenated into a string'
			);
			assert.ok(
				code.some((line) => line.includes('path to resource "encryptor_convert.sh"')),
				'the conversion runs through the bundled helper'
			);
		}
	);

	scenario(
		'(encryptor-password-not-in-argv) encrypt and decrypt round-trip with the password read from a file',
		() => {
			const clear = path.join(work, 'report.txt');
			const sealed = `${clear}.enc`;
			const restored = path.join(work, 'restored.txt');
			fs.writeFileSync(clear, 'confidential bytes\n');
			const secret = passwordFile('round.pw', SENTINEL);
			fs.rmSync(argvLog, { force: true });
			const encrypted = convert('encrypt', clear, sealed, secret);
			assert.equal(encrypted.status, 0, encrypted.stderr);
			const decrypted = convert('decrypt', sealed, restored, secret);
			assert.equal(decrypted.status, 0, decrypted.stderr);
			assert.equal(fs.readFileSync(restored, 'utf8'), 'confidential bytes\n');
			const recorded = fs.readFileSync(argvLog, 'utf8');
			assert.ok(recorded.includes(`file:${secret}`), 'OpenSSL reads the password file');
			assert.ok(!recorded.includes('s3ntinel'), 'the password never reaches an OpenSSL argument');
		}
	);

	scenario(
		'(encryptor-password-not-in-argv) files sealed by the former "pass:" command still decrypt',
		() => {
			const clear = path.join(work, 'legacy.txt');
			const sealed = `${clear}.enc`;
			const restored = path.join(work, 'legacy-restored.txt');
			fs.writeFileSync(clear, 'sealed before the change\n');
			const legacy = spawnSync(openssl, [
				'enc',
				'-aes-256-cbc',
				'-pbkdf2',
				'-iter',
				'600000',
				'-in',
				clear,
				'-out',
				sealed,
				'-pass',
				`pass:${SENTINEL}`
			]);
			assert.equal(legacy.status, 0, String(legacy.stderr));
			const decrypted = convert('decrypt', sealed, restored, passwordFile('legacy.pw', SENTINEL));
			assert.equal(decrypted.status, 0, decrypted.stderr);
			assert.equal(fs.readFileSync(restored, 'utf8'), 'sealed before the change\n');
		}
	);

	scenario('a wrong password is refused', () => {
		const clear = path.join(work, 'wrong.txt');
		const sealed = `${clear}.enc`;
		fs.writeFileSync(clear, 'x'.repeat(64));
		assert.equal(convert('encrypt', clear, sealed, passwordFile('right.pw', SENTINEL)).status, 0);
		const refused = convert(
			'decrypt',
			sealed,
			path.join(work, 'wrong-out.txt'),
			passwordFile('wrong.pw', 'nope')
		);
		assert.notEqual(refused.status, 0, 'OpenSSL reports the bad decrypt');
	});

	scenario('(bap-001-folder-destination) a folder destination is refused, not filled', () => {
		const folder = fs.mkdtempSync(path.join(work, 'folder-'));
		const clear = path.join(folder, 'notes.txt');
		const sealed = `${clear}.enc`;
		fs.writeFileSync(clear, 'sealed\n');
		assert.equal(convert('encrypt', clear, sealed, passwordFile('f.pw', SENTINEL)).status, 0);
		const target = path.join(folder, 'notes');
		fs.mkdirSync(target);
		const refused = convert('decrypt', sealed, target, passwordFile('f2.pw', SENTINEL));
		assert.notEqual(refused.status, 0, 'a folder destination is reported as a failure');
		assert.deepEqual(fs.readdirSync(target), [], 'no stage is moved into the folder');
	});

	scenario(
		'(encryptor-failed-conversion-keeps-destination) a refused decrypt leaves the approved overwrite target intact',
		() => {
			const folder = fs.mkdtempSync(path.join(work, 'keep-'));
			const clear = path.join(folder, 'notes.txt');
			const sealed = `${clear}.enc`;
			fs.writeFileSync(clear, 'what was sealed\n');
			assert.equal(convert('encrypt', clear, sealed, passwordFile('keep.pw', SENTINEL)).status, 0);
			// The user edited the clear file since: overwriting it was approved
			const valuable = Buffer.from('newer valuable edits\n\u0000\u00ff', 'latin1');
			fs.writeFileSync(clear, valuable);
			const refused = convert('decrypt', sealed, clear, passwordFile('typo.pw', 'typo'));
			assert.notEqual(refused.status, 0, 'the wrong password is reported');
			assert.deepEqual(fs.readFileSync(clear), valuable, 'the destination is kept byte for byte');
			assert.deepEqual(
				fs.readdirSync(folder).sort(),
				['notes.txt', 'notes.txt.enc'],
				'the failed stage is removed and nothing else'
			);
			const corrupt = path.join(folder, 'corrupt.txt.enc');
			fs.writeFileSync(corrupt, 'Salted__ not a ciphertext');
			const target = path.join(folder, 'corrupt.txt');
			fs.writeFileSync(target, valuable);
			assert.notEqual(
				convert('decrypt', corrupt, target, passwordFile('c.pw', SENTINEL)).status,
				0
			);
			assert.deepEqual(
				fs.readFileSync(target),
				valuable,
				'a corrupted input keeps the destination too'
			);
		}
	);

	scenario(
		'(encryptor-failed-conversion-keeps-destination) a successful conversion replaces the target with a new-file mode',
		() => {
			const folder = fs.mkdtempSync(path.join(work, 'replace-'));
			const clear = path.join(folder, 'plan.txt');
			const sealed = `${clear}.enc`;
			fs.writeFileSync(clear, 'the plan\n');
			const secret = passwordFile('replace.pw', SENTINEL);
			assert.equal(convert('encrypt', clear, sealed, secret).status, 0);
			fs.writeFileSync(clear, 'older copy\n');
			const decrypted = convert('decrypt', sealed, clear, secret);
			assert.equal(decrypted.status, 0, decrypted.stderr);
			assert.equal(fs.readFileSync(clear, 'utf8'), 'the plan\n');
			assert.deepEqual(
				fs.readdirSync(folder).sort(),
				['plan.txt', 'plan.txt.enc'],
				'no stage is left'
			);
			const umask = process.umask();
			assert.equal(fs.statSync(clear).mode & 0o777, 0o666 & ~umask, 'the output is not left 0600');
		}
	);

	scenario('an unknown mode or a missing password file is refused before OpenSSL runs', () => {
		fs.rmSync(argvLog, { force: true });
		const clear = path.join(work, 'mode.txt');
		fs.writeFileSync(clear, 'mode');
		assert.equal(
			convert('rot13', clear, `${clear}.out`, passwordFile('mode.pw', SENTINEL)).status,
			64
		);
		assert.equal(
			convert('encrypt', clear, `${clear}.out`, path.join(work, 'absent.pw')).status,
			66
		);
		assert.equal(fs.existsSync(argvLog), false, 'OpenSSL never started');
	});
} finally {
	fs.rmSync(work, { recursive: true, force: true });
}
assert.equal(failed, 0, 'Encryptor conversion scenarios failed');
