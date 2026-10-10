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
	LUA_LOCATOR_OUTPUT,
	render,
	generate
} = require('../codegen/codegen-managed-python-release.cjs');

const root = path.resolve(__dirname, '../..');
const data = JSON.parse(fs.readFileSync(path.join(root, SOURCE), 'utf8'));
const key = 'cpython-3.11.16-darwin-aarch64-none';
const url =
	'https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.11.16%2B20260929-aarch64-apple-darwin-install_only_stripped.tar.gz';
const digest = '53141f31b7cfb2bccf89c2a877827128657dbb8650db06a9a08c7886c28a45ed';
const intelKey = 'cpython-3.11.16-darwin-x86_64-none';
const intelURL =
	'https://github.com/astral-sh/python-build-standalone/releases/download/20260929/cpython-3.11.16%2B20260929-x86_64-apple-darwin-install_only_stripped.tar.gz';
const intelDigest = 'd1143a947050fbbd17edc0d66ff3f7a63205c8364ef108bddfeece5f360096f8';
assert.equal(data.uv_release, '0.12.21');
assert.equal(
	data.source.sha256,
	'6167f194053b58a461b6b440bbfff121f0971bd6757fce95cfec90b19ee080df'
);
assert.equal(data.source.bytes, 3176495);
assert.deepEqual(Object.keys(data.downloads), [key, intelKey]);
assert.equal(data.downloads[key].url, url);
assert.equal(data.downloads[key].sha256, digest);
assert.equal(data.downloads[intelKey].url, intelURL);
assert.equal(data.downloads[intelKey].sha256, intelDigest);
assert.equal(data.downloads[intelKey].arch.family, 'x86_64');
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
assert.ok(output[SHELL_OUTPUT].includes(`MANAGED_PYTHON_URL="${intelURL}"\n`));
assert.ok(output[SHELL_OUTPUT].includes(`MANAGED_PYTHON_SHA256="${intelDigest}"\n`));
assert.ok(
	output[SHELL_OUTPUT].includes(
		'MANAGED_PYTHON_CACHE_BASENAME="d1143a947-cpython-3.11.16-20260929-x86_64-apple-darwin-install_only_stripped.tar.gz"\n'
	)
);
assert.ok(
	output[SHELL_OUTPUT].includes('MANAGED_PYTHON_REQUEST="cpython-3.11.16-macos-x86_64-none"\n')
);
assert.deepEqual(JSON.parse(output[METADATA_OUTPUT]), data.downloads);
assert.equal(
	LUA_LOCATOR_OUTPUT,
	'static/ergopti_plus/_shared/lua/core/llm/managed_python_locator.lua'
);
assert.match(
	output[LUA_LOCATOR_OUTPUT],
	/arm64 = "cpython-3\.11\.16-macos-aarch64-none\/bin\/python3\.11",/
);
assert.match(
	output[LUA_LOCATOR_OUTPUT],
	/x86_64 = "cpython-3\.11\.16-macos-x86_64-none\/bin\/python3\.11",/
);
assert.ok(
	Buffer.byteLength(output[LUA_LOCATOR_OUTPUT]) < 1024,
	'the UI locator has bounded reviewed shape'
);
assert.doesNotMatch(
	output[LUA_LOCATOR_OUTPUT].replace(/^---[^\n]*$/gm, ''),
	/https?:|[.]json|[.]read|io[.]open/,
	'locator data cannot perform runtime IO'
);

assert.ok(Object.values(output).every((contents) => !contents.includes('\r')));
// A valid later patch selection must own locator data; no runtime version guess.
const later = structuredClone(data);
for (const [family, oldKey] of [
	['aarch64', key],
	['x86_64', intelKey]
]) {
	const entry = later.downloads[oldKey];
	delete later.downloads[oldKey];
	entry.patch = 17;
	entry.url = entry.url.replace('3.11.16', '3.11.17');
	later.downloads[`cpython-3.11.17-darwin-${family}-none`] = entry;
}
const laterLocator = render(later)[LUA_LOCATOR_OUTPUT];
assert.match(laterLocator, /cpython-3\.11\.17-macos-aarch64-none\/bin\/python3\.11/);
assert.match(laterLocator, /cpython-3\.11\.17-macos-x86_64-none\/bin\/python3\.11/);
assert.doesNotMatch(laterLocator, /3\.11\.16/);

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
	},
	(value) => {
		delete value.downloads[intelKey];
	},
	(value) => {
		delete value.downloads[key];
	},
	(value) => {
		value.downloads[intelKey].arch.variant = 'v3';
	},
	(value) => {
		value.downloads[intelKey].url = url;
	},
	(value) => {
		value.downloads[intelKey].sha256 = intelDigest.toUpperCase();
	},
	(value) => {
		const moved = value.downloads[intelKey];
		moved.build = '20260930';
		moved.url = moved.url.replaceAll('20260929', '20260930');
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
	assert.equal(generate(temporary).length, 3);
	assert.equal(generate(temporary, { check: true }).length, 3);

	const luaLocator = path.join(temporary, LUA_LOCATOR_OUTPUT);
	const literalLocator = fs.readFileSync(luaLocator, 'utf8');
	fs.appendFileSync(luaLocator, '\n-- Independent locator drift witness.\n');
	const locatorDrift = fs.readFileSync(luaLocator);
	assert.throws(() => generate(temporary, { check: true }), /projection drift/);
	assert.ok(
		fs.readFileSync(luaLocator).equals(locatorDrift),
		'check mode preserves edited locator data'
	);
	generate(temporary);
	assert.equal(fs.readFileSync(luaLocator, 'utf8'), literalLocator);
	const shell = path.join(temporary, SHELL_OUTPUT);
	const parser = spawnSync(bashExecutable(), ['-n', shell.replace(/\\/g, '/')], {
		encoding: 'utf8',
		timeout: 10000
	});
	assert.equal(parser.error, undefined);
	assert.equal(parser.status, 0, parser.stderr);
	for (const [nativeArchitecture, expected] of [
		[
			'arm64',
			[
				'cpython-3.11.16-macos-aarch64-none',
				url,
				digest,
				'53141f31b-cpython-3.11.16-20260929-aarch64-apple-darwin-install_only_stripped.tar.gz'
			]
		],
		[
			'x86_64',
			[
				'cpython-3.11.16-macos-x86_64-none',
				intelURL,
				intelDigest,
				'd1143a947-cpython-3.11.16-20260929-x86_64-apple-darwin-install_only_stripped.tar.gz'
			]
		]
	]) {
		const selected = spawnSync(
			bashExecutable(),
			[
				'-c',
				'source "$1" || exit $?; printf "%s\\n" "$MANAGED_PYTHON_REQUEST" "$MANAGED_PYTHON_URL" "$MANAGED_PYTHON_SHA256" "$MANAGED_PYTHON_CACHE_BASENAME" "$MANAGED_PYTHON_UV_RELEASE" "$MANAGED_PYTHON_DOWNLOADS_BASENAME"',
				'ergopti-native-python-selection',
				shell.replace(/\\/g, '/')
			],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_NATIVE_ARCH: nativeArchitecture }
			}
		);
		assert.equal(selected.error, undefined);
		assert.equal(selected.status, 0, selected.stderr);
		assert.deepEqual(selected.stdout.trimEnd().split('\n'), [
			...expected,
			'0.12.21',
			'managed-python-downloads.json'
		]);
	}
	for (const unsupported of ['i386', 'aarch64', 'arm64; echo unqualified']) {
		const refused = spawnSync(
			bashExecutable(),
			[
				'-c',
				'source "$1" || exit $?; echo unqualified',
				'ergopti-native-python-refusal',
				shell.replace(/\\/g, '/')
			],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, ERGOPTI_NATIVE_ARCH: unsupported }
			}
		);
		assert.equal(refused.error, undefined);
		assert.equal(refused.status, 78);
		assert.equal(refused.stdout, '');
	}
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
	'PASS managed Python arm64/Intel pins, sixteen refusal vectors, actual native-architecture shell selections and nonmutating drift checks. Native archive extraction/execution remains separate.'
);
