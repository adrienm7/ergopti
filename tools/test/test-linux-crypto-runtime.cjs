// tools/test/test-linux-crypto-runtime.cjs

/** Independent descriptor/projection/one-of APT controls; not native crypto proof. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const generator = require('../codegen/codegen-linux-native-runtime.cjs');
const root = path.resolve(__dirname, '../..');
const read = (name) => fs.readFileSync(path.join(root, name), 'utf8');
const data = JSON.parse(read(generator.SOURCE));
let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log('PASS ' + name);
}
function shellFunction(text, name) {
	const observed = text.match(new RegExp('^' + name + '\\(\\) \\{[\\s\\S]*?^\\}', 'm'));
	assert.ok(observed, 'Actual production function required: ' + name);
	return observed[0];
}
const rendered = generator.render(data, read);
const installer = rendered['static/ergopti_plus/linux/install.sh'];
check('canonical OpenSSL3 identity and ordered one-of transition are literal', () => {
	assert.equal(data.archive_digest_runtime.soname, 'libcrypto.so.3');
	assert.deepEqual(data.archive_digest_runtime.deb_dependency_alternatives, [
		'libssl3t64',
		'libssl3'
	]);
	assert.deepEqual(data.archive_digest_runtime.portable_dlopen_roots, ['libcrypto.so.3']);
});
check('original identities/providers retained and Nix OpenSSL appears once', () => {
	assert.deepEqual(generator.KEYS, ['xkbcommon', 'xkbcommon_x11', 'x11', 'x11_xcb']);
	assert.equal(data.network_runtime.providers.dnf, null);
	assert.equal(data.network_runtime.providers.xbps, null);
	assert.equal(
		generator.requirements(data, 'nix_library_path').filter((x) => x === 'openssl').length,
		1
	);
});
check('Debian depends on one alternative expression and preserves old requirements', () => {
	const required = generator.requirements(data, 'deb');
	assert.equal(required.filter((x) => x === 'libssl3t64 | libssl3').length, 1);
	assert.equal(required.includes('libssl3t64'), false);
	assert.equal(required.includes('libssl3'), false);
	for (const old of ['luajit (>= 2.1)', 'curl', 'at-spi2-core']) assert.ok(required.includes(old));
});
for (const [format, sqlite] of [
	['deb', 'sqlite3'],
	['rpm', 'sqlite'],
	['arch', 'sqlite']
])
	check('metrics CLI providers are mandatory for ' + format + ' (metrics-cli-required)', () => {
		const required = generator.requirements(data, format);
		for (const provider of ['openssl', sqlite])
			assert.equal(
				required.filter((name) => name === provider).length,
				1,
				`${format} must provide ${provider} even when optional dependencies are disabled`
			);
	});
check(
	'source installation admits the OpenSSL executable separately from libcrypto (metrics-cli-required)',
	() => {
		assert.match(installer, /^_check_or_install openssl$/m);
	}
);
for (const manager of ['apt', 'dnf', 'zypper', 'pacman', 'xbps', 'apk']) {
	for (const state of ['present', 'install', 'no-command', 'refused']) {
		check(
			'actual OpenSSL source admission ' + manager + '/' + state + ' (metrics-cli-required)',
			() => {
				const script = [
					'set -eu',
					shellFunction(installer, '_required_dependency_package'),
					shellFunction(installer, '_check_or_install'),
					`available=${state === 'present' ? '1' : '0'}`,
					'command() { [ "$1" = -v ] && [ "$2" = openssl ] && [ "$available" = 1 ]; }',
					`_detect_pkg_manager() { echo ${manager}; }`,
					'_install_required_package() {',
					'  printf "INSTALL %s %s\\n" "$1" "$2"',
					state === 'refused' ? '  return 7' : state === 'install' ? '  available=1' : '  return 0',
					'}',
					'_check_or_install openssl'
				].join('\n');
				const result = spawnSync(bashExecutable(), ['-s'], {
					input: script,
					encoding: 'utf8',
					timeout: 5000
				});
				assert.ifError(result.error);
				assert.equal(result.signal, null);
				const expected =
					state === 'present' || state === 'install' ? 0 : state === 'refused' ? 7 : 1;
				assert.equal(result.status, expected, result.stdout + result.stderr);
				const installs = result.stdout.split('\n').filter((line) => line.startsWith('INSTALL '));
				assert.deepEqual(installs, state === 'present' ? [] : [`INSTALL ${manager} openssl`]);
			}
		);
	}
}
check('actual Lua projection supplies descriptor; no handwritten generated file input', () => {
	const result = rendered[generator.LUA_OUTPUT];
	assert.match(
		result,
		/archive_digest_runtime = \{\n\t\tschema_version = 1,\n\t\tsoname = "libcrypto\.so\.3",/
	);
	assert.match(installer, /ARCHIVE_DIGEST_SONAME="libcrypto\.so\.3"/);
});
for (const [name, change] of [
	['missing descriptor', (d) => delete d.archive_digest_runtime],
	['wrong native ABI', (d) => (d.archive_digest_runtime.soname = 'libcrypto.so.1.1')],
	['path injection', (d) => (d.archive_digest_runtime.soname = '/tmp/libcrypto.so.3')],
	['reversed alternatives', (d) => d.archive_digest_runtime.deb_dependency_alternatives.reverse()],
	['missing explicit root', (d) => (d.archive_digest_runtime.portable_dlopen_roots = [])],
	[
		'unreviewed repair provider',
		(d) => (d.archive_digest_runtime.package_alternatives.dnf = ['invented-provider'])
	]
])
	check(name + ' refuses before projection', () => {
		const invalid = structuredClone(data);
		change(invalid);
		assert.throws(() => generator.render(invalid, read), TypeError);
	});
check('known absent APT repair policy generates refusal while preserving native probe', () => {
	const absent = structuredClone(data);
	absent.archive_digest_runtime.package_alternatives.apt = null;
	assert.match(
		generator.render(absent, read)['static/ergopti_plus/linux/install.sh'],
		/apt:libcrypto\.so\.3\) return 1 ;;/
	);
});
const functions = [
	'_available_apt_runtime_package',
	'_required_dependency_package',
	'_archive_digest_runtime_available',
	'_ensure_archive_digest_runtime'
]
	.map((name) => shellFunction(installer, name))
	.join('\n');
const quote = (text) => "'" + text.replaceAll("'", "'\\''") + "'";
function run(options) {
	const policy = (name, contents, status) =>
		quote(name) + ") printf '%s' " + quote(contents) + '; return ' + status + ' ;;';
	const native = options.initial
		? '[ "$probes" -ge 1 ]'
		: options.provide
			? '[ "$probes" -gt 1 ]'
			: 'false';
	const script =
		'set -u\n' +
		functions +
		'\n' +
		'ARCHIVE_DIGEST_SONAME=libcrypto.so.3\nprobes=0\n_detect_pkg_manager() { echo apt; }\n' +
		'_archive_digest_runtime_available() { probes=$((probes+1)); ' +
		native +
		'; }\n' +
		'apt-cache() { [ "$1" = policy ] && [ "$2" = -- ] && [ "$#" = 3 ] || return 9; printf "QUERY %s\n" "$3" >&2; case "$3" in\n' +
		policy('libssl3t64', options.first, options.firstStatus || 0) +
		'\n' +
		policy('libssl3', options.second, 0) +
		'\n*) return 9 ;;\nesac\n}\n' +
		'_install_required_package() { printf "INSTALL %s %s\n" "$1" "$2"; return ' +
		(options.installStatus || 0) +
		'; }\n' +
		'_ensure_archive_digest_runtime\n';
	const result = spawnSync(bashExecutable(), ['-s'], {
		input: script,
		encoding: 'utf8',
		timeout: 5000
	});
	assert.ifError(result.error);
	assert.equal(result.signal, null);
	return { status: result.status, installs: result.stdout.trim(), queries: result.stderr.trim() };
}
const available =
	'libssl3t64:\n  Installed: (none)\n  Candidate: 3.0.13-0ubuntu3\n  Version table:\n';
const legacy = 'libssl3:\n  Installed: (none)\n  Candidate: 3.0.2-0ubuntu1\n  Version table:\n';
const unavailable = 'libssl3t64:\n  Installed: (none)\n  Candidate: (none)\n';
for (const [name, options, status, installs, queries] of [
	[
		'present native capability repairs nothing',
		{ initial: true, first: available, second: legacy },
		0,
		'',
		''
	],
	[
		'actual t64 candidate selects only t64',
		{ provide: true, first: available, second: legacy },
		0,
		'INSTALL apt libssl3t64',
		'QUERY libssl3t64'
	],
	[
		'none t64 selects legacy once',
		{ provide: true, first: unavailable, second: legacy },
		0,
		'INSTALL apt libssl3',
		'QUERY libssl3t64\nQUERY libssl3'
	],
	[
		'absent t64 metadata selects legacy once',
		{ provide: true, first: '', second: legacy },
		0,
		'INSTALL apt libssl3',
		'QUERY libssl3t64\nQUERY libssl3'
	],
	[
		'no actual candidates refuse repair',
		{ first: unavailable, second: unavailable },
		1,
		'',
		'QUERY libssl3t64\nQUERY libssl3'
	],
	[
		'metadata command failure cannot borrow fallback',
		{ first: available, firstStatus: 7, second: legacy },
		1,
		'',
		'QUERY libssl3t64'
	],
	[
		'duplicate candidate metadata refuses',
		{ first: 'Candidate: 3.0\nCandidate: 3.1\n', second: legacy },
		1,
		'',
		'QUERY libssl3t64'
	],
	[
		'malformed candidate refuses',
		{ first: 'Candidate: pretend-success\n', second: legacy },
		1,
		'',
		'QUERY libssl3t64'
	],
	[
		'repair refusal never installs second provider',
		{ first: available, second: legacy, installStatus: 1 },
		1,
		'INSTALL apt libssl3t64',
		'QUERY libssl3t64'
	],
	[
		'installed package without native symbols stays unavailable',
		{ first: available, second: legacy },
		1,
		'INSTALL apt libssl3t64',
		'QUERY libssl3t64'
	]
])
	check(name, () => {
		assert.deepEqual(run(options), { status, installs, queries });
	});
assert.equal(checks, 49, 'Independent fixed case floor');
console.log(checks + ' PASS, 0 FAIL, 0 SKIP; modeled repair/projection only');
