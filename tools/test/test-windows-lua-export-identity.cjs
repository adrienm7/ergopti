// tools/test/test-windows-lua-export-identity.cjs

/**
 * ==============================================================================
 * MODULE: Windows Lua Export Host Identity Test
 * DESCRIPTION:
 * Pins the committed export step host of the Windows layout editor window
 * (windows/vendor/ergopti_lua_export.exe and its identity JSON, built by
 * tools/build/build_windows_lua_export.ps1) to the sources it claims: its
 * source fingerprint is the pin's rule over the committed host source, its
 * archive and licence digests are the pin's, and its exe_sha256 is the file's.
 * Before the executable is committed, the bundle requires neither file, so a
 * half-committed host (an identity without its executable, or the reverse)
 * fails here instead of in a user's window.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const { REPO_ROOT } = require('../lib/paths.cjs');
const { sourceFingerprint } = require('../build/build-lua-export-host.cjs');

const VENDOR = path.join(REPO_ROOT, 'static', 'ergopti_plus', 'windows', 'vendor');
const PIN = path.join(
	REPO_ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'native',
	'ergopti_lua_export.pin.json'
);
const IDENTITY = path.join(VENDOR, 'ergopti_lua_export.json');
const EXE = path.join(VENDOR, 'ergopti_lua_export.exe');
const MANIFEST = path.join(REPO_ROOT, 'tools', 'build', 'windows_bundle_manifest.json');

const sha256 = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
const pin = JSON.parse(fs.readFileSync(PIN, 'utf8'));
// The bundle's required files: a listed one that is absent fails the build.
const required = new Set(
	JSON.parse(fs.readFileSync(MANIFEST, 'utf8')).required.map((entry) => entry.dest)
);

assert.equal(
	fs.existsSync(IDENTITY),
	fs.existsSync(EXE),
	'the export step host and its identity are committed together'
);
if (!fs.existsSync(IDENTITY)) {
	for (const name of ['ergopti_lua_export.exe', 'ergopti_lua_export.json'])
		assert(
			!required.has(`vendor/${name}`),
			`the bundle requires no ${name} before it is committed`
		);
	console.log(
		'[OK] Windows Lua export host: not committed yet; the bundle requires neither file and the editor keeps fengari.'
	);
} else {
	const identity = JSON.parse(fs.readFileSync(IDENTITY, 'utf8'));
	assert.equal(identity.schema_version, 1);
	assert.equal(identity.lua_release, pin.lua_release, 'built from the pinned Lua release');
	assert.equal(identity.lua_archive_sha256, pin.sha256, 'built from the pinned archive');
	assert.equal(
		identity.source_fingerprint,
		sourceFingerprint(pin),
		'the committed executable was built from the committed host source: rebuild it'
	);
	assert.equal(identity.license_sha256, sha256(path.join(REPO_ROOT, pin.license_file)));
	assert.equal(identity.exe_sha256, sha256(EXE), 'the identity names the committed executable');
	assert.deepEqual(identity.imports, ['kernel32.dll'], 'a static-runtime, kernel32-only closure');
	for (const name of ['ergopti_lua_export.exe', 'ergopti_lua_export.json'])
		assert(required.has(`vendor/${name}`), `the bundle requires ${name}`);
	console.log(
		`[OK] Windows Lua export host: ${identity.lua_release}, fingerprint ${identity.source_fingerprint}.`
	);
}
