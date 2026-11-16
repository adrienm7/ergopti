// tools/test/test-windows-proxy-relay-bundle.cjs

/**
 * ==============================================================================
 * MODULE: Windows Proxy Relay Bundle Identity
 * DESCRIPTION:
 * The committed ergopti-proxy-relay.exe must be the one its sources build: its
 * digest and source fingerprint in the manifest are recomputed here, so editing the
 * relay's Go without tools/build/build_windows_proxy_relay.ps1 -Publish fails on
 * every OS, and the bundle ships both files. Needs no Go: the Windows CI package
 * job proves the rebuild itself (-Verify). The launcher's check of this digest is
 * proven live by test-windows-proxy-relay-e2e.cjs.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const VENDOR = path.join(ROOT, 'static/ergopti_plus/windows/vendor');
const MODULE = path.join(ROOT, 'static/ergopti_plus/_shared/core/network/native/go/native_http');
const sha256 = (bytes) => crypto.createHash('sha256').update(bytes).digest('hex');

const manifest = JSON.parse(fs.readFileSync(path.join(VENDOR, 'ergopti-proxy-relay.json'), 'utf8'));
const pin = JSON.parse(
	fs.readFileSync(
		path.join(ROOT, 'static/ergopti_plus/_shared/ai/data/managed_ollama_runtime.json'),
		'utf8'
	)
).go_version;
assert.deepEqual(Object.keys(manifest), [
	'schema_version',
	'go_version',
	'goos',
	'goarch',
	'source_fingerprint',
	'exe_sha256'
]);
assert.equal(manifest.schema_version, 1);
assert.equal(manifest.go_version, pin, 'the relay is built with the repository Go pin');
assert.equal(manifest.goos, 'windows');
assert.equal(manifest.goarch, 'amd64');

const executable = fs.readFileSync(path.join(VENDOR, 'ergopti-proxy-relay.exe'));
assert.equal(sha256(executable), manifest.exe_sha256, 'the manifest names the committed binary');
assert.equal(executable.readUInt16LE(0), 0x5a4d, 'the relay is a PE image');

// The same identity as the builder: pin, then each source by sorted relative path.
const sources = ['go.mod'];
for (const directory of ['proxyrelay', 'cmd/ergopti-proxy-relay'])
	for (const name of fs.readdirSync(path.join(MODULE, directory)))
		if (name.endsWith('.go') && !name.endsWith('_test.go')) sources.push(`${directory}/${name}`);
assert.ok(sources.length > 5, 'the relay sources were read');
let identity = `${pin}\n`;
for (const relative of sources.sort((a, b) => (a < b ? -1 : a > b ? 1 : 0)))
	identity += `${relative}\n${sha256(fs.readFileSync(path.join(MODULE, relative)))}\n`;
assert.equal(
	sha256(Buffer.from(identity, 'utf8')),
	manifest.source_fingerprint,
	'the relay sources changed: run tools/build/build_windows_proxy_relay.ps1 -Publish'
);

const bundle = JSON.parse(
	fs.readFileSync(path.join(ROOT, 'tools/build/windows_bundle_manifest.json'), 'utf8')
);
const shipped = JSON.stringify(bundle);
for (const name of ['ergopti-proxy-relay.exe', 'ergopti-proxy-relay.json'])
	assert.ok(shipped.includes(`vendor/${name}`), `the bundle ships ${name}`);

const bootstrap = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/windows/ai/engine/ollama/managed_bootstrap.ahk'),
	'utf8'
);
assert.match(bootstrap, /LLM_OLLAMA_PROXY_RELAY_MANIFEST := "ergopti-proxy-relay\.json"/);
assert.doesNotMatch(
	bootstrap,
	/ProxyRelaySha256"\] := this\._Hash/,
	'the expected digest is the manifest, not the file'
);

console.log(
	`[OK] Windows proxy relay: binary ${manifest.exe_sha256.slice(0, 12)} matches its manifest and sources.`
);
