// tools/test/test-macos-managed-ollama-catalogue.cjs

/** Receive portable catalogue input admission; native production has its own profile. */
'use strict';

const assert = require('node:assert/strict');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { pythonExecutable } = require('../lib/python.cjs');

const result = spawnSync(
	pythonExecutable(),
	['tools/test/macos_managed_ollama_catalogue_test.py'],
	{
		cwd: path.resolve(__dirname, '../..'),
		encoding: 'utf8',
		timeout: 60000
	}
);
assert.equal(result.error, undefined, 'the catalogue receiver must start');
assert.equal(result.signal, null, 'the catalogue receiver must close within its bound');
assert.equal(result.status, 0, result.stderr || result.stdout);
assert.match(result.stderr, /Ran 24 tests in/);
assert.match(result.stderr, /\bOK\b/);
assert.doesNotMatch(result.stderr, /skipped=/);
assert.match(result.stdout, /actual native producer receiving was not requested/);
process.stdout.write(result.stdout);
process.stdout.write(result.stderr);

const publication = spawnSync(
	pythonExecutable(),
	['tools/test/macos_managed_ollama_publication_test.py'],
	{ cwd: path.resolve(__dirname, '../..'), encoding: 'utf8', timeout: 60000 }
);
assert.equal(publication.error, undefined, 'the native publication boundary must start');
assert.equal(
	publication.signal,
	null,
	'the native publication boundary must close within its bound'
);
assert.equal(publication.status, 0, publication.stderr || publication.stdout);
assert.match(publication.stderr, /Ran 24 tests in/);
assert.match(publication.stderr, /\bOK\b/);
assert.doesNotMatch(publication.stderr, /skipped=/);
process.stdout.write(publication.stdout);
process.stdout.write(publication.stderr);

// Source wiring is separate from the actual Python admission controls above.
const pipeline = require('./ci-pipeline.cjs');
const preflight = pipeline.step(
	pipeline.job('release'),
	'Refuse to publish an incomplete or already-taken release'
);
const script = pipeline
	.runOf(preflight)
	.filter((line) => !line.trimStart().startsWith('#'))
	.join('\n');
function publicationHook(script) {
	const block = script.match(/if \[ "\$create_release" = true \]; then\n([\s\S]*?)^fi$/m);
	return Boolean(
		block &&
			/python3 tools\/build\/verify-macos-managed-ollama-publication\.py \\\n\s+--assets release-assets --tag "\$TAG" \\\n\s+--version "\$\{TAG#v\}" --channel "\$CHANNEL"/.test(
				block[1]
			)
	);
}
assert.equal(
	publicationHook(script),
	true,
	'fresh publication must admit both actual assets before any release side effect'
);
for (const altered of [
	script.replace('verify-macos-managed-ollama-publication.py', 'omitted-native-owner.py'),
	script.replace('--tag "$TAG"', '--tag "v0.0.0-placeholder"'),
	script.replace('--version "${TAG#v}"', '--version "0.0.0-placeholder"'),
	script.replace('--channel "$CHANNEL"', '--channel "main"')
]) {
	assert.notEqual(altered, script, 'the publication bypass mutant must alter a live command');
	assert.equal(publicationHook(altered), false, 'native publication bypass must refuse');
}
