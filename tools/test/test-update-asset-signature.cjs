// tools/test/test-update-asset-signature.cjs

/**
 * ==============================================================================
 * MODULE: Update Asset Signature Reference Test
 * DESCRIPTION:
 * Pins the detached-signature scheme of the Windows and Linux update assets
 * (_shared/modules/updater/asset_signing.json): the reference tool signs and
 * verifies, the shared vectors (the ones the Linux OpenSSL and Windows CNG
 * verifiers also replay) accept the valid record and refuse each tampered one,
 * a signature cannot be moved to another asset, and the policy cannot claim
 * enforcement without a key.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const Tool = require('./../build/update-asset-signature.cjs');

const root = path.resolve(__dirname, '..', '..');
const vectors = JSON.parse(
	fs.readFileSync(
		path.join(
			root,
			'static/ergopti_plus/_shared/tests/corpus/updater/asset_signature_vectors.json'
		),
		'utf8'
	)
);
const policy = Tool.loadPolicy();

let passed = 0;
const check = (label, action) => {
	try {
		action();
	} catch (error) {
		error.message = `${label}: ${error.message}`;
		throw error;
	}
	passed++;
};

check('the vector header is the policy header', () => {
	assert.equal(vectors.record_header, policy.record_header);
	assert.equal(vectors.algorithm, policy.algorithm);
});

check('the valid vector verifies and is bound to its exact record', () => {
	const valid = vectors.valid;
	const record = Tool.canonicalRecord(policy.record_header, valid.name, valid.size, valid.sha256);
	assert.equal(
		Tool.verifyRecord(vectors.public_key_spki_base64, record, valid.signature_base64),
		true
	);
	assert.equal(Buffer.from(valid.signature_base64, 'base64').length, policy.signature_bytes);
});

check('every tampered record is refused with the valid signature', () => {
	assert.ok(vectors.tampered.length >= 3);
	for (const entry of vectors.tampered) {
		const record = Tool.canonicalRecord(policy.record_header, entry.name, entry.size, entry.sha256);
		assert.equal(
			Tool.verifyRecord(vectors.public_key_spki_base64, record, vectors.valid.signature_base64),
			false,
			entry.why
		);
	}
});

check('a malformed or truncated signature is refused, not thrown', () => {
	const valid = vectors.valid;
	const record = Tool.canonicalRecord(policy.record_header, valid.name, valid.size, valid.sha256);
	for (const bad of [
		'',
		'AAAA',
		valid.signature_base64.slice(0, -4),
		valid.signature_base64 + 'AA=='
	]) {
		assert.equal(Tool.verifyRecord(vectors.public_key_spki_base64, record, bad), false);
	}
});

check('the record refuses names, sizes and digests that are not canonical', () => {
	assert.throws(() => Tool.canonicalRecord(policy.record_header, '../x', 1, 'a'.repeat(64)));
	assert.throws(() => Tool.canonicalRecord(policy.record_header, 'x', -1, 'a'.repeat(64)));
	assert.throws(() => Tool.canonicalRecord(policy.record_header, 'x', 1, 'A'.repeat(64)));
});

check('the command line signs assets and verifies them, and refuses a changed asset', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-sign-'));
	try {
		const pair = Tool.generateKeyPair();
		const asset = path.join(dir, 'ergopti-plus-linux.tar.gz');
		fs.writeFileSync(asset, crypto.randomBytes(4096));
		const quiet = console.log;
		console.log = () => {};
		try {
			assert.equal(Tool.main(['sign', asset], { UPDATE_SIGNING_KEY: pair.privateKeyPem }), 0);
			assert.equal(Tool.main(['verify', pair.publicKeySpkiBase64, asset], {}), 0);
			fs.appendFileSync(asset, 'x');
			assert.throws(
				() => Tool.main(['verify', pair.publicKeySpkiBase64, asset], {}),
				/does not verify/
			);
			assert.throws(
				() => Tool.main(['sign', asset], { UPDATE_SIGNING_KEY: pair.privateKeyPem }),
				/EEXIST/
			);
		} finally {
			console.log = quiet;
		}
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

check('signing without the secret, or with a key of another curve, is refused', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-sign-'));
	try {
		const asset = path.join(dir, 'a.zip');
		fs.writeFileSync(asset, 'payload');
		assert.throws(() => Tool.main(['sign', asset], {}), /UPDATE_SIGNING_KEY is not set/);
		const other = crypto
			.generateKeyPairSync('ec', { namedCurve: 'secp384r1' })
			.privateKey.export({ type: 'pkcs8', format: 'pem' });
		assert.throws(
			() => Tool.main(['sign', asset], { UPDATE_SIGNING_KEY: other }),
			/not an ECDSA P-256 key/
		);
		assert.equal(fs.existsSync(asset + '.sig'), false, 'a refused signing leaves no signature');
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

check('the policy cannot require signatures without a verification key', () => {
	assert.ok(['off', 'required'].includes(policy.enforcement));
	if (policy.enforcement === 'required') {
		const key = crypto.createPublicKey({
			key: Buffer.from(policy.public_key_spki_base64, 'base64'),
			format: 'der',
			type: 'spki'
		});
		assert.equal(key.asymmetricKeyDetails.namedCurve, 'prime256v1');
	}
	assert.equal(policy.signature_bytes, 64);
});

check('release-sign fails fast without the secret once the policy expects signatures', () => {
	const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-sign-'));
	try {
		const asset = path.join(dir, 'ErgoptiPlus.exe');
		fs.writeFileSync(asset, crypto.randomBytes(2048));
		const pair = Tool.generateKeyPair();
		const provisioned = { ...policy, public_key_spki_base64: pair.publicKeySpkiBase64 };
		const required = { ...provisioned, enforcement: 'required' };
		for (const expecting of [provisioned, required]) {
			assert.equal(Tool.signaturesExpected(expecting), true);
			for (const env of [{}, { UPDATE_SIGNING_KEY: '' }]) {
				assert.throws(
					() => Tool.releaseSign(expecting, env, [asset], () => {}),
					/UPDATE_SIGNING_KEY is not set/
				);
			}
		}
		const unprovisioned = { ...policy, enforcement: 'off', public_key_spki_base64: '' };
		assert.equal(Tool.signaturesExpected(unprovisioned), false);
		const lines = [];
		Tool.releaseSign(unprovisioned, {}, [asset], (line) => lines.push(line));
		assert.equal(lines.length, 1);
		assert.match(lines[0], /^::warning::UPDATE_SIGNING_KEY is not set/);
		assert.equal(fs.existsSync(asset + '.sig'), false);
		assert.throws(() => Tool.releaseSign(unprovisioned, {}, [], () => {}), /No asset/);
	} finally {
		fs.rmSync(dir, { recursive: true, force: true });
	}
});

check(
	'release-sign signs with the provisioned key and refuses a secret that does not match it',
	() => {
		const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-sign-'));
		try {
			const asset = path.join(dir, 'ergopti-plus-linux.tar.gz');
			fs.writeFileSync(asset, crypto.randomBytes(4096));
			const pair = Tool.generateKeyPair();
			const stranger = Tool.generateKeyPair();
			const provisioned = { ...policy, public_key_spki_base64: pair.publicKeySpkiBase64 };
			assert.throws(
				() =>
					Tool.releaseSign(
						provisioned,
						{ UPDATE_SIGNING_KEY: stranger.privateKeyPem },
						[asset],
						() => {}
					),
				/does not match public_key_spki_base64/
			);
			assert.equal(fs.existsSync(asset + '.sig'), false, 'a mismatched key writes no signature');
			const lines = [];
			Tool.releaseSign(provisioned, { UPDATE_SIGNING_KEY: pair.privateKeyPem }, [asset], (line) =>
				lines.push(line)
			);
			assert.deepEqual(lines, ['signed ergopti-plus-linux.tar.gz.sig']);
			const signature = fs.readFileSync(asset + '.sig', 'utf8');
			assert.match(signature, /^[A-Za-z0-9+/]+=*\n$/);
			assert.equal(
				Tool.verifyRecord(
					pair.publicKeySpkiBase64,
					Tool.recordOfFile(policy, asset),
					signature.trim()
				),
				true
			);
			const unprovisioned = { ...policy, public_key_spki_base64: '' };
			fs.rmSync(asset + '.sig');
			const warned = [];
			Tool.releaseSign(unprovisioned, { UPDATE_SIGNING_KEY: pair.privateKeyPem }, [asset], (line) =>
				warned.push(line)
			);
			assert.equal(warned.length, 2);
			assert.match(warned[1], /^::warning::asset_signing.json names no verification key/);
		} finally {
			fs.rmSync(dir, { recursive: true, force: true });
		}
	}
);

check(
	'release CI signs both update assets through release-sign and gates the release on them',
	() => {
		const read = (name) => fs.readFileSync(path.join(root, '.github', 'workflows', name), 'utf8');
		for (const [name, target, uploaded] of [
			['ci-windows.yml', 'static/ergopti_plus/windows/ErgoptiPlus.exe', 'ErgoptiPlus.exe.sig'],
			[
				'ci-linux.yml',
				'"build/linux/$LINUX_BUNDLE_ASSET"',
				'build/linux/${{ env.LINUX_BUNDLE_ASSET }}.sig'
			]
		]) {
			const workflow = read(name);
			assert.ok(
				workflow.includes('node tools/build/update-asset-signature.cjs release-sign ' + target),
				name + ' does not sign ' + target + ' through release-sign'
			);
			assert.ok(
				!/update-asset-signature\.cjs sign /.test(workflow),
				name + ' bypasses the release-sign decision'
			);
			assert.ok(
				workflow.includes('UPDATE_SIGNING_KEY: ${{ secrets.UPDATE_SIGNING_KEY }}'),
				name + ' does not read the secret'
			);
			assert.ok(workflow.includes(uploaded), name + ' does not upload the signature');
		}
		const release = read('ci-release.yml');
		assert.ok(
			release.includes('ErgoptiPlus.exe.sig') && release.includes('$LINUX_BUNDLE_ASSET.sig')
		);
		assert.ok(
			release.includes('node tools/build/update-asset-signature.cjs expects-signatures'),
			'ci-release.yml does not ask the signing policy whether signatures are expected'
		);
	}
);

console.log(`[OK] update asset signatures: ${passed} check(s)`);
