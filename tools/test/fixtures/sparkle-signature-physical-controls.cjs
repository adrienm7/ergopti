// tools/test/fixtures/sparkle-signature-physical-controls.cjs
// Portable independent Ed25519 binding controls for the native fixture.
'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');

const P = (1n << 255n) - 19n;
const L = (1n << 252n) + 27742317777372353535851937790883648493n;
function mod(x, n = P) {
	return ((x % n) + n) % n;
}
function pow(x, n) {
	let out = 1n;
	for (; n; n >>= 1n, x = mod(x * x)) if (n & 1n) out = mod(out * x);
	return out;
}
const D = mod(-121665n * pow(121666n, P - 2n));
const B = [
	15112221349535400772501151409588531511454012693041857206046113283949847762202n,
	46316835694926478169428394003475163141307993866256225615783033603165251855960n
];
function add(a, b) {
	const t = mod(D * a[0] * a[1] * b[0] * b[1]);
	return [
		mod((a[0] * b[1] + a[1] * b[0]) * pow(mod(1n + t), P - 2n)),
		mod((a[1] * b[1] + a[0] * b[0]) * pow(mod(1n - t), P - 2n))
	];
}
function multiply(n) {
	let out = [0n, 1n],
		base = B;
	for (; n; n >>= 1n, base = add(base, base)) if (n & 1n) out = add(out, base);
	return out;
}
function integer(bytes) {
	let result = 0n;
	for (let i = bytes.length - 1; i >= 0; i--) result = (result << 8n) + BigInt(bytes[i]);
	return result;
}
function bytes(n) {
	const result = Buffer.alloc(32);
	for (let i = 0; i < 32; i++, n >>= 8n) result[i] = Number(n & 255n);
	return result;
}
function encoded(point) {
	return bytes(point[1] | ((point[0] & 1n) << 255n));
}
function digest(value) {
	return crypto.createHash('sha512').update(value).digest();
}

// Fixed public test-vector noise demonstrates signature non-uniqueness; no keys
// or code from corecrypto are shipped or used by the product.
function signature(seed, message, publicKey, noise = null) {
	const expanded = digest(seed);
	expanded[0] &= 248;
	expanded[31] &= 63;
	expanded[31] |= 64;
	const prefix = noise
		? Buffer.concat([noise, Buffer.alloc(64), expanded.subarray(32)])
		: expanded.subarray(32);
	const r = mod(integer(digest(Buffer.concat([prefix, message]))), L);
	const R = encoded(multiply(r));
	const h = mod(integer(digest(Buffer.concat([R, publicKey, message]))), L);
	return Buffer.concat([R, bytes(mod(r + h * integer(expanded.subarray(0, 32)), L))]);
}
function key(publicBytes) {
	return crypto.createPublicKey({
		key: Buffer.concat([Buffer.from('302a300506032b6570032100', 'hex'), publicBytes]),
		type: 'spki',
		format: 'der'
	});
}
function verifies(publicKey, signed, message) {
	return crypto.verify(null, message, key(publicKey), signed);
}
function bound(signed, message, foreign, installed) {
	return (
		signed.length === 64 &&
		verifies(foreign, signed, message) &&
		!verifies(installed, signed, message)
	);
}

function runSignatureControls({ fixture }) {
	assert.equal(typeof fixture, 'string');
	const seed = Buffer.from(
		'9d61b19deffd5a60ba844af492ec2cc44449c5697b326919703bac031cae7f60',
		'hex'
	);
	const publicKey = Buffer.from(
		'd75a980182b10ab7d54bfed3c964073a0ee172f3daa62325af021a68f707511a',
		'hex'
	);
	const message = Buffer.alloc(0);
	const deterministic = signature(seed, message, publicKey);
	assert.equal(
		deterministic.toString('hex'),
		'e5564300c360ac729086e2cc806e828a84877f1eb8e5d974d873e065224901555fb8821590a33bacc61e39701cf9b46bd25bf5f0595bbe24655141438e7a100b',
		'RFC8032 literal signature must prove the independent arithmetic'
	);
	const noisy = signature(seed, message, publicKey, Buffer.alloc(32, 7));
	assert.ok(!deterministic.equals(noisy), 'Independent nonce forms must differ');
	assert.ok(verifies(publicKey, deterministic, message));
	assert.ok(verifies(publicKey, noisy, message));
	const installed = crypto
		.generateKeyPairSync('ed25519')
		.publicKey.export({ format: 'der', type: 'spki' })
		.subarray(-32);
	assert.ok(bound(deterministic, message, publicKey, installed));
	assert.ok(bound(noisy, message, publicKey, installed));
	assert.equal(bound(noisy, Buffer.from('changed'), publicKey, installed), false);
	assert.equal(bound(Buffer.alloc(64), message, publicKey, installed), false);
	assert.equal(bound(noisy, message, publicKey, publicKey), false);
	const nativeBinding = fixture.slice(
		fixture.indexOf('private static func foreignSignatureIsBound'),
		fixture.indexOf('func testForeignSignatureBindingRejectsInstalledKeyAndChangedPayload')
	);
	assert.ok(nativeBinding.length > 100, 'The actual native verifier body must be present');
	assert.match(
		nativeBinding,
		/return signature\.count == 64 && foreign\.isValidSignature\(signature, for: payload\)\s*&& !installed\.isValidSignature\(signature, for: payload\)/,
		'Native foreign verifier must preserve exact public-key and message binding'
	);
	assert.match(
		fixture,
		/Self\.foreignSignatureIsBound\(foreignSignatureBytes, payload: payload,\s*foreign: foreignKey\.publicKey, installed: key\.publicKey\)/,
		'Actual official output must use that verifier'
	);
	assert.doesNotMatch(
		fixture,
		/Data\(base64Encoded: foreignSignature\) == wrongSignature/,
		'Independent signatures have no byte equality admission contract'
	);
	assert.match(
		fixture,
		/XCTAssertTrue\(foreignKey\.publicKey\.isValidSignature\(wrongSignature, for: payload\)\)/
	);
	assert.match(
		fixture,
		/XCTAssertFalse\(key\.publicKey\.isValidSignature\(wrongSignature, for: payload\)\)/
	);
	assert.match(fixture, /intValue == 3001/);
	assert.match(fixture, /application\.finish\(15\)/);
	console.log(
		'Sparkle signature controls: independent OpenSSL binding; native CryptoKit execution pending.'
	);
}

module.exports = { runSignatureControls };
