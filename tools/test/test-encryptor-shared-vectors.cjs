// tools/test/test-encryptor-shared-vectors.cjs

/**
 * ==============================================================================
 * MODULE: Encryptor Shared Vectors
 * DESCRIPTION:
 * Pins the Encryptor container that every driver reads and writes
 * (_shared/data/encryptor/format.json) to its vectors
 * (_shared/tests/corpus/encryptor/vectors.json). Node's own crypto derives the
 * key, decrypts each container and, with the same salt, encrypts it back byte
 * for byte, so the vectors are checked by an implementation that is none of
 * the drivers'. The macOS conversion helper then decrypts every vector with the
 * system OpenSSL, and each driver's source is held to the format's constants:
 * a driver that changed its iteration count or cipher would write files the
 * other two cannot open.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');

const root = path.resolve(__dirname, '../..');
const plus = path.join(root, 'static/ergopti_plus');
const format = JSON.parse(
	fs.readFileSync(path.join(plus, '_shared/data/encryptor/format.json'), 'utf8')
);
const vectors = JSON.parse(
	fs.readFileSync(path.join(plus, '_shared/tests/corpus/encryptor/vectors.json'), 'utf8')
);
const macosHelper = path.join(
	plus,
	'macos/apps/Encryptor.app/Contents/Resources/encryptor_convert.sh'
);
const macosScript = path.join(
	plus,
	'macos/apps/Encryptor.app/Contents/Resources/Scripts/main.applescript'
);

let failed = 0;
/** Runs one scenario and reports it. */
function scenario(name, body) {
	try {
		body();
		console.log(`ok Encryptor vectors ${name}`);
	} catch (error) {
		failed += 1;
		console.error(`FAIL Encryptor vectors ${name}: ${error.message}`);
	}
}

/** Derives key and IV as the format declares. */
function derive(password, salt) {
	const material = crypto.pbkdf2Sync(
		Buffer.from(password, format.password_encoding === 'utf-8' ? 'utf8' : undefined),
		salt,
		format.iterations,
		format.key_bytes + format.iv_bytes,
		format.kdf_digest
	);
	return { key: material.subarray(0, format.key_bytes), iv: material.subarray(format.key_bytes) };
}

/** Splits a container into its salt and ciphertext, refusing a foreign header. */
function split(container) {
	const magic = Buffer.from(format.magic, 'latin1');
	assert.ok(
		container.subarray(0, magic.length).equals(magic),
		'container header is not the format magic'
	);
	const salt = container.subarray(magic.length, magic.length + format.salt_bytes);
	return { salt, body: container.subarray(magic.length + format.salt_bytes) };
}

/** Decrypts a container with Node's crypto. */
function decrypt(container, password) {
	const { salt, body } = split(container);
	const { key, iv } = derive(password, salt);
	const decipher = crypto.createDecipheriv(format.cipher, key, iv);
	return Buffer.concat([decipher.update(body), decipher.final()]);
}

/** Encrypts with a fixed salt, the way a random-salt run lays out its output. */
function encrypt(plaintext, password, salt) {
	const { key, iv } = derive(password, salt);
	const cipher = crypto.createCipheriv(format.cipher, key, iv);
	return Buffer.concat([
		Buffer.from(format.magic, 'latin1'),
		salt,
		cipher.update(plaintext),
		cipher.final()
	]);
}

/**
 * The destination rule of main.applescript, written once here as the oracle
 * the name vectors are checked against (AppleScript's `ends with` ignores case).
 */
function destination(source) {
	const ext = format.encrypted_extension;
	if (!source.toLowerCase().endsWith(ext)) return { mode: 'encrypt', destination: source + ext };
	const stripped = source.slice(0, -ext.length);
	if (stripped === '' || stripped.endsWith('/') || stripped.endsWith('\\')) {
		return { mode: 'decrypt', destination: source + format.decrypted_fallback_suffix };
	}
	return { mode: 'decrypt', destination: stripped };
}

scenario('(encryptor-format-is-openssl-enc) the format names the OpenSSL enc envelope', () => {
	assert.equal(format.magic, 'Salted__');
	assert.equal(format.salt_bytes, 8);
	assert.equal(format.cipher, 'aes-256-cbc');
	assert.equal(format.key_bytes, 32);
	assert.equal(format.iv_bytes, 16);
	assert.ok(Number.isInteger(format.iterations) && format.iterations >= 600000);
	assert.ok(vectors.containers.length >= 4, 'too few container vectors');
});

for (const vector of vectors.containers) {
	scenario(
		`(encryptor-vector-${vector.id}) Node crypto decrypts and re-encrypts it byte for byte`,
		() => {
			const container = Buffer.from(vector.container_hex, 'hex');
			assert.equal(decrypt(container, vector.password).toString('hex'), vector.plaintext_hex);
			const again = encrypt(
				Buffer.from(vector.plaintext_hex, 'hex'),
				vector.password,
				Buffer.from(vector.salt_hex, 'hex')
			);
			assert.equal(again.toString('hex'), vector.container_hex);
		}
	);
}

scenario(
	'(encryptor-wrong-password-fails) a wrong password is refused, not decoded to garbage',
	() => {
		const container = Buffer.from(vectors.containers[0].container_hex, 'hex');
		assert.throws(() => decrypt(container, vectors.wrong_password));
	}
);

scenario('(encryptor-destination-names) the name vectors follow the AppleScript rule', () => {
	for (const name of vectors.names) {
		assert.deepEqual(
			destination(name.source),
			{ mode: name.mode, destination: name.destination },
			name.source
		);
	}
	const code = fs.readFileSync(macosScript, 'utf8');
	assert.match(code, /set is_decrypt to \(file_path ends with "\.enc"\)/);
	assert.match(code, /set dest_path to file_path & "\.enc"/);
	assert.match(code, /set dest_path to file_path & "_decrypted"/);
});

scenario(
	'(encryptor-macos-helper-follows-format) encryptor_convert.sh runs the declared cipher and iterations',
	() => {
		const code = fs.readFileSync(macosHelper, 'utf8');
		assert.ok(
			code.includes(`-${format.cipher} -${format.kdf} -iter ${format.iterations}`),
			'the macOS helper no longer runs the shared cipher, KDF and iteration count'
		);
	}
);

const openssl = spawnSync('/bin/sh', ['-c', 'command -v openssl'], { encoding: 'utf8' });
if (process.platform !== 'win32' && openssl.status === 0) {
	const work = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-encryptor-vectors-'));
	try {
		for (const vector of vectors.containers) {
			scenario(
				`(encryptor-macos-decrypts-${vector.id}) the macOS helper opens the shared container`,
				() => {
					const input = path.join(work, `${vector.id}.enc`);
					const output = path.join(work, `${vector.id}.out`);
					const password = path.join(work, `${vector.id}.pw`);
					fs.writeFileSync(input, Buffer.from(vector.container_hex, 'hex'));
					fs.writeFileSync(password, vector.password, { mode: 0o600 });
					const run = spawnSync('/bin/sh', [macosHelper, 'decrypt', input, output, password], {
						encoding: 'utf8'
					});
					assert.equal(run.status, 0, run.stderr);
					assert.equal(fs.readFileSync(output).toString('hex'), vector.plaintext_hex);
				}
			);
		}
	} finally {
		fs.rmSync(work, { recursive: true, force: true });
	}
} else {
	console.log('skip Encryptor vectors macOS helper run: no POSIX openssl on this host');
}

if (failed > 0) {
	console.error(`${failed} Encryptor vector check(s) failed.`);
	process.exit(1);
}
console.log('All Encryptor vector checks passed.');
