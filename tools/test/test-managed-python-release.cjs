// tools/test/test-managed-python-release.cjs

/** Independent native bootstrap pin, drift and shell-admission controls. */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const os = require('node:os');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const {
	SOURCE,
	SHELL_OUTPUT,
	METADATA_OUTPUT,
	render,
	generate
} = require('../codegen/codegen-managed-python-release.cjs');

const root = path.resolve(__dirname, '../..');
const data = JSON.parse(fs.readFileSync(path.join(root, SOURCE), 'utf8'));
const key = 'cpython-3.11.16-darwin-aarch64-none';
const url =
	'https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.11.16%2B20260929-aarch64-apple-darwin-install_only_stripped.tar.gz';
const digest = '53141f31b7cfb2bccf89c2a877827128657dbb8650db06a9a08c7886c28a45ed';
assert.equal(data.uv_release, '0.12.21');
assert.equal(
	data.source.sha256,
	'6167f194053b58a461b6b440bbfff121f0971bd6757fce95cfec90b19ee080df'
);
assert.equal(data.source.bytes, 3176495);
assert.deepEqual(Object.keys(data.downloads), [key]);
assert.equal(data.downloads[key].url, url);
assert.equal(data.downloads[key].sha256, digest);
const output = render(data);
assert.ok(output[SHELL_OUTPUT].includes(`MANAGED_PYTHON_URL="${url}"\n`));
assert.ok(output[SHELL_OUTPUT].includes(`MANAGED_PYTHON_SHA256="${digest}"\n`));
assert.ok(
	output[SHELL_OUTPUT].includes(
		'MANAGED_PYTHON_CACHE_BASENAME="53141f31b-cpython-3.11.16-20260929-aarch64-apple-darwin-install_only_stripped.tar.gz"\n'
	)
);
assert.ok(
	output[SHELL_OUTPUT].includes('MANAGED_PYTHON_REQUEST="cpython-3.11.16-macos-aarch64-none"\n')
);
assert.deepEqual(JSON.parse(output[METADATA_OUTPUT]), data.downloads);
assert.ok(Object.values(output).every((contents) => !contents.includes('\r')));

for (const mutate of [
	(value) => {
		value.schema_version = true;
	},
	(value) => {
		value.source.bytes = '3176495';
	},
	(value) => {
		value.uv_release = '0.12.21"; echo private';
	},
	(value) => {
		value.source.url += '?unqualified';
	},
	(value) => {
		value.downloads[key].url += '?other';
	},
	(value) => {
		value.downloads[key].arch.family = 'x86_64';
	},
	(value) => {
		value.downloads[key].sha256 = digest.toUpperCase();
	},
	(value) => {
		value.downloads[key].patch = true;
	},
	(value) => {
		value.downloads.other = structuredClone(value.downloads[key]);
	},
	(value) => {
		value.downloads[key].unknown = 1;
	}
]) {
	const candidate = structuredClone(data);
	mutate(candidate);
	assert.throws(() => render(candidate));
}

const temporary = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-managed-python-projection-'));
try {
	for (const relative of [SOURCE, 'static/ergopti_plus/macos/modules/llm/uv-release.sh']) {
		const target = path.join(temporary, relative);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		fs.copyFileSync(path.join(root, relative), target);
	}
	assert.throws(() => generate(temporary, { check: true }), /projection drift/);
	assert.equal(generate(temporary).length, 2);
	assert.equal(generate(temporary, { check: true }).length, 2);
	const shell = path.join(temporary, SHELL_OUTPUT);
	const parser = spawnSync(bashExecutable(), ['-n', shell.replace(/\\/g, '/')], {
		encoding: 'utf8',
		timeout: 10000
	});
	assert.equal(parser.error, undefined);
	assert.equal(parser.status, 0, parser.stderr);
	fs.appendFileSync(shell, '\n# Independent drift witness.\n');
	const drifted = fs.readFileSync(shell);
	assert.throws(() => generate(temporary, { check: true }), /projection drift/);
	assert.ok(fs.readFileSync(shell).equals(drifted), 'check mode preserves the edited projection');
	generate(temporary);
	const uv = path.join(temporary, 'static/ergopti_plus/macos/modules/llm/uv-release.sh');
	fs.writeFileSync(uv, 'UV_RELEASE_VERSION="0.12.20"\n');
	assert.throws(() => generate(temporary), /installed uv release/);
} finally {
	fs.rmSync(temporary, { recursive: true, force: true });
}
generate(root, { check: true });
console.log(
	'PASS managed Python pins, ten refusal vectors, actual shell syntax and nonmutating drift checks. Native extraction remains separate.'
);
