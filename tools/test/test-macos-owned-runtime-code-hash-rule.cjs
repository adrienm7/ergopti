// tools/test/test-macos-owned-runtime-code-hash-rule.cjs

/**
 * ==============================================================================
 * MODULE: macOS Owned Runtime Code Hash Rule
 * DESCRIPTION:
 * The published installer helper carries one SHA-256 code directory per slice.
 * OwnedRuntimeInstallMainOperation.codeDirectoryHashes admits one or two
 * distinct hashes; every launcher source that reads a code's directory hashes
 * must go through it, so the install path and the helper's own report path
 * cannot drift apart again.
 *
 * ROOT CAUSE ENCODED:
 * Field report 2026-11-05: the launcher's install check was relaxed to one
 * hash, but OwnedVirtualHIDDaemonReportStageOwner.admitImage, compiled into
 * the helper, still read kSecCodeInfoCdHashes itself and required exactly
 * two, so the helper's report path refused the published helper.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const SOURCES = 'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus';
const OWNER = 'OwnedRuntimeInstallMainOperation.swift';
let checks = 0;

function check(name, run) {
	run();
	checks += 1;
	console.log(`ok ${checks} - ${name}`);
}

const sources = fs
	.readdirSync(path.join(ROOT, SOURCES))
	.filter((name) => name.endsWith('.swift'))
	.map((name) => ({ name, text: fs.readFileSync(path.join(ROOT, SOURCES, name), 'utf8') }));

check('the launcher sources are present', () => {
	assert.ok(sources.length > 20, 'the Swift source inventory must not be empty');
	assert.ok(sources.some((source) => source.name === OWNER));
});

check('only the admission rule reads the code directory hashes', () => {
	const readers = sources
		.filter((source) => source.text.includes('kSecCodeInfoCdHashes'))
		.map((source) => source.name);
	assert.deepEqual(readers, [OWNER]);
});

check('the admission rule accepts one or two hashes', () => {
	const owner = sources.find((source) => source.name === OWNER).text;
	assert.match(owner, /static func codeDirectoryHashes\(_ fields: \[String: Any\]\) -> \[Data\]\?/);
	assert.match(owner, /\(1\.\.\.2\)\.contains\(hashes\.count\)/);
});

check("the helper's report path admits its image through the same rule", () => {
	const stage = sources.find(
		(source) => source.name === 'OwnedVirtualHIDDaemonReportStageOwner.swift'
	);
	assert.ok(stage, 'the report stage owner must exist');
	const start = stage.text.indexOf('private func admitImage() -> Bool {');
	assert.ok(start >= 0, 'admitImage must exist');
	const body = stage.text.slice(start, stage.text.indexOf('\n\t}\n', start));
	assert.match(body, /OwnedRuntimeInstallMainOperation\.codeDirectoryHashes\(info\)/);
	assert.doesNotMatch(body, /hashes\.count == 2/);
});

console.log(`# passed: ${checks}/${checks}`);
