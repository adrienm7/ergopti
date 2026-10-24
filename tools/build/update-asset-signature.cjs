// tools/build/update-asset-signature.cjs

/**
 * ==============================================================================
 * MODULE: Update Asset Signatures
 * DESCRIPTION:
 * Signs and verifies the detached signatures of the Windows and Linux update
 * assets (policy: _shared/modules/updater/asset_signing.json). Release CI calls
 * `sign` on the packaged assets and publishes each <asset>.sig beside them; the
 * updaters verify the same record with their OS-native crypto (CNG on Windows,
 * OpenSSL on Linux). This file is the reference implementation the vectors are
 * made with.
 *
 * USAGE:
 *   UPDATE_SIGNING_KEY="$(cat key.pem)" node tools/build/update-asset-signature.cjs sign <asset>...
 *   node tools/build/update-asset-signature.cjs verify <public-key-spki-base64> <asset>...
 *   node tools/build/update-asset-signature.cjs keygen        (prints a new key pair)
 *
 * FEATURES & RATIONALE:
 * 1. The private key comes from the environment only, never from an argument
 *    or a file the workflow would have to write, and is never printed.
 * 2. The signed record binds the asset name, its size and its SHA-256, so a
 *    signature cannot be moved to another asset or another size.
 * 3. Every refusal is an exception; the CLI exits non-zero and writes no
 *    partial signature.
 * ==============================================================================
 */

'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const POLICY_PATH = path.resolve(
	__dirname,
	'..',
	'..',
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'updater',
	'asset_signing.json'
);

/** The shared signing policy. */
function loadPolicy() {
	const policy = JSON.parse(fs.readFileSync(POLICY_PATH, 'utf8'));
	if (policy.schema_version !== 1 || policy.algorithm !== 'ecdsa-p256-sha256') {
		throw new Error('The update signing policy is not the version this tool implements.');
	}
	return policy;
}

/**
 * The canonical record that is signed.
 * @param {string} header Policy record_header.
 * @param {string} name Asset file name.
 * @param {number} size Size in bytes.
 * @param {string} sha256 Lowercase hex digest.
 * @returns {string}
 */
function canonicalRecord(header, name, size, sha256) {
	if (!/^[A-Za-z0-9._-]{1,128}$/.test(name))
		throw new Error('The asset name is not a plain file name.');
	if (!Number.isInteger(size) || size < 0)
		throw new Error('The asset size is not a count of bytes.');
	if (!/^[0-9a-f]{64}$/.test(sha256))
		throw new Error('The asset digest is not lowercase SHA-256 hex.');
	return `${header}\n${name}\n${size}\n${sha256}\n`;
}

/** Record of a file on disk. */
function recordOfFile(policy, file) {
	const bytes = fs.readFileSync(file);
	return canonicalRecord(
		policy.record_header,
		path.basename(file),
		bytes.length,
		crypto.createHash('sha256').update(bytes).digest('hex')
	);
}

/**
 * Signs a record.
 * @param {string} privateKeyPem PKCS#8 or SEC1 PEM of a P-256 key.
 * @param {string} record
 * @returns {string} Base64 of the raw 64-byte r||s.
 */
function signRecord(privateKeyPem, record) {
	const key = crypto.createPrivateKey(privateKeyPem);
	if (key.asymmetricKeyType !== 'ec' || key.asymmetricKeyDetails.namedCurve !== 'prime256v1') {
		throw new Error('The signing key is not an ECDSA P-256 key.');
	}
	const signature = crypto.sign('sha256', Buffer.from(record, 'utf8'), {
		key,
		dsaEncoding: 'ieee-p1363'
	});
	return signature.toString('base64');
}

/**
 * Verifies a record's signature.
 * @param {string} spkiBase64 DER SubjectPublicKeyInfo, base64.
 * @param {string} record
 * @param {string} signatureBase64
 * @returns {boolean}
 */
function verifyRecord(spkiBase64, record, signatureBase64) {
	const signature = Buffer.from(signatureBase64, 'base64');
	if (signature.length !== 64 || signature.toString('base64') !== signatureBase64) return false;
	const key = crypto.createPublicKey({
		key: Buffer.from(spkiBase64, 'base64'),
		format: 'der',
		type: 'spki'
	});
	return crypto.verify(
		'sha256',
		Buffer.from(record, 'utf8'),
		{ key, dsaEncoding: 'ieee-p1363' },
		signature
	);
}

/** Generates a key pair: PEM private key and base64 SPKI public key. */
function generateKeyPair() {
	const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
	return {
		privateKeyPem: privateKey.export({ type: 'pkcs8', format: 'pem' }),
		publicKeySpkiBase64: publicKey.export({ type: 'spki', format: 'der' }).toString('base64')
	};
}

/** CLI. */
function main(argv, env) {
	const [command, ...rest] = argv;
	const policy = loadPolicy();
	if (command === 'keygen') {
		const pair = generateKeyPair();
		process.stdout.write(
			`PUBLIC (asset_signing.json public_key_spki_base64):\n${pair.publicKeySpkiBase64}\n` +
				`PRIVATE (the UPDATE_SIGNING_KEY secret):\n${pair.privateKeyPem}`
		);
		return 0;
	}
	if (command === 'sign') {
		const pem = env.UPDATE_SIGNING_KEY;
		if (typeof pem !== 'string' || pem === '') {
			throw new Error('UPDATE_SIGNING_KEY is not set: a release build needs the signing secret.');
		}
		if (rest.length === 0) throw new Error('No asset to sign.');
		const outputs = rest.map((file) => {
			const signature = signRecord(pem, recordOfFile(policy, file));
			return [file + policy.signature_suffix, signature + '\n'];
		});
		for (const [target, text] of outputs) {
			fs.writeFileSync(target, text, { flag: 'wx' });
			console.log(`signed ${path.basename(target)}`);
		}
		return 0;
	}
	if (command === 'verify') {
		const [spki, ...files] = rest;
		if (!spki || files.length === 0) throw new Error('verify needs a public key and assets.');
		for (const file of files) {
			const signature = fs.readFileSync(file + policy.signature_suffix, 'utf8').trim();
			if (!verifyRecord(spki, recordOfFile(policy, file), signature)) {
				throw new Error(`The signature of ${path.basename(file)} does not verify.`);
			}
			console.log(`verified ${path.basename(file)}`);
		}
		return 0;
	}
	throw new Error('Usage: sign <asset>... | verify <public-key-spki-base64> <asset>... | keygen');
}

if (require.main === module) {
	try {
		process.exitCode = main(process.argv.slice(2), process.env);
	} catch (error) {
		console.error(`[ERROR] ${error.message}`);
		process.exitCode = 1;
	}
}

module.exports = {
	canonicalRecord,
	recordOfFile,
	signRecord,
	verifyRecord,
	generateKeyPair,
	loadPolicy,
	main
};
