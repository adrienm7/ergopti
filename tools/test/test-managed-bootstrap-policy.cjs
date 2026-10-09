// tools/test/test-managed-bootstrap-policy.cjs
// Independent canonical-policy and generated-image drift controls.

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { render } = require('../codegen/codegen-managed-bootstrap.cjs');
const root = path.resolve(__dirname, '../..');
const shared = path.join(root, 'static/ergopti_plus/_shared/modules');
const bootstrap = fs.readFileSync(path.join(shared, 'llm/managed_ollama_bootstrap.json'));
const proxy = fs.readFileSync(path.join(shared, 'network/proxy_policy.json'));
const generated = fs.readFileSync(
	path.join(
		root,
		'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/ManagedBootstrapPolicy.generated.swift'
	),
	'utf8'
);
assert.equal(render(bootstrap, proxy), generated);
const policy = JSON.parse(bootstrap);
assert.equal(policy.hmac_domain, 'ERGOPTI_NATIVE_NETWORK_BOOTSTRAP_V1\n');
assert.deepEqual(policy.trust_environment, ['SSL_CERT_FILE', 'SSL_CERT_DIR']);
assert.equal(policy.maximum_metadata_bytes, 1048576);
assert.equal(policy.maximum_certificate_bytes, 16777216);
assert.equal(policy.maximum_certificate_files, 1024);
let controls = 6;
for (const [key, value] of [
	['schema_version', true],
	['schema_version', 2],
	['maximum_metadata_bytes', 0],
	['maximum_metadata_bytes', 1.5],
	['maximum_certificate_bytes', null],
	['maximum_certificate_files', -1],
	['hmac_domain', 'missing-boundary'],
	['trust_environment', []],
	['trust_environment', ['one']],
	['trust_environment', ['one', 'one']],
	['trust_environment', ['SSL_CERT_FILE', 'invalid=value']],
	['trust_environment', ['SSL_CERT_FILE', 'https_proxy']],
	['foreign', 1]
]) {
	assert.throws(() => render(Buffer.from(JSON.stringify({ ...policy, [key]: value })), proxy));
	controls++;
}
assert.throws(() =>
	render(
		Buffer.from(
			bootstrap
				.toString()
				.replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1')
		),
		proxy
	)
);
controls++;
assert.throws(() =>
	render(
		bootstrap,
		Buffer.from(
			proxy.toString().replace('"schema_version": 1', '"schema_version": 1, "schema_version": 1')
		)
	)
);
controls++;
assert.throws(() => render(Buffer.concat([bootstrap, Buffer.from([255])]), proxy));
controls++;
for (const key of ['system_lookup_environment_exclusions', 'environment_bypass_precedence']) {
	const original = JSON.parse(proxy);
	for (const value of [[], ['same', 'same'], ['wrong name'], null]) {
		assert.throws(() =>
			render(bootstrap, Buffer.from(JSON.stringify({ ...original, [key]: value })))
		);
		controls++;
	}
}
const changed = Buffer.from(JSON.stringify({ ...policy, maximum_metadata_bytes: 1048577 }));
assert.notEqual(render(changed, proxy), generated);
controls++;
assert.notEqual(
	generated.replace('maximumMetadataBytes = 1048576', 'maximumMetadataBytes = 1'),
	render(bootstrap, proxy)
);
controls++;
console.log(`Managed bootstrap policy: ${controls} controls passed; native SDK not executed.`);
