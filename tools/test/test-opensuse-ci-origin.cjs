// tools/test/test-opensuse-ci-origin.cjs

/**
 * Guard openSUSE container preparation against redirector mirror skew.
 * Tumbleweed metadata and its referenced objects must come from the same
 * origin; otherwise a freshly pulled image can resolve a current index through
 * download.opensuse.org and receive a stale mirror whose payload is incomplete.
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const pipeline = require('./ci-pipeline.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
// Each source that installs packages in an openSUSE container. The Linux box is
// read through the loader, which throws when its distro job is missing.
const sources = [
	['.github/workflows/ci-linux.yml (job install-linux)', pipeline.job('install-linux')],
	[
		'.github/workflows/linux-layout.yml',
		fs.readFileSync(path.join(ROOT, '.github/workflows/linux-layout.yml'), 'utf8')
	]
];
const originRewrite =
	"sed -i 's|http://download.opensuse.org|https://downloadcontent.opensuse.org|g' " +
	'/etc/zypp/repos.d/*.repo && zypper --non-interactive install';

for (const [workflow, source] of sources) {
	const tumbleweed = source.match(/image: opensuse\/tumbleweed:latest\r?\n\s+prep: ([^\r\n]+)/);
	assert(tumbleweed, `${workflow} must retain its openSUSE Tumbleweed matrix entry`);
	assert(
		tumbleweed[1].startsWith(originRewrite),
		`${workflow} must bypass download.opensuse.org mirror redirects before zypper install`
	);
}

console.log('[OK] openSUSE CI package installs use the coherent download origin.');

// Execute only the real tooling phase: the following user/installer boundary
// must exist uniquely, so this controlled fixture cannot mutate the host.
const os = require('os');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const toolingHarness = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/linux/tests/distro/e2e_install.sh'),
	'utf8'
);
const userBoundary =
	"# An ordinary user with passwordless sudo: the installer's documented audience.";
assert.strictEqual(
	toolingHarness.split(userBoundary).length,
	2,
	'the real installer boundary is unique'
);
const toolingPhase = toolingHarness.slice(0, toolingHarness.indexOf(userBoundary));
const outerRefusal =
	'prepare_test_tooling || { echo "ENVIRONMENT: could not install the test tooling" >&2; exit 2; }';
assert(
	toolingPhase.includes(outerRefusal),
	'tooling refusal must precede all product installation'
);
const setupBoundary = 'section "Test tooling"';
assert.strictEqual(
	toolingPhase.split(setupBoundary).length,
	2,
	'the real tooling call exists uniquely'
);
const toolingFunctions = toolingPhase.slice(0, toolingPhase.indexOf(setupBoundary));

function bashPath(value) {
	const normalized = value.replaceAll('\\', '/');
	return process.platform === 'win32'
		? normalized.replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`)
		: normalized;
}

const expectedArguments = [
	'--non-interactive',
	'install',
	'-y',
	'sudo',
	'curl',
	'python3',
	'python3-gobject',
	'typelib-1_0-Gio-2_0',
	'dbus-1',
	'dbus-1-daemon',
	'xorg-x11-server-Xvfb',
	'procps',
	'shadow'
];
const privateMarker = 'PRIVATE_TOOLING_FIXTURE_6e4f';
const privatePayload = `${privateMarker} https://private.example/token /private/config ::error::foreign\n`;
const scenarios = [
	{
		name: 'solver stdout',
		exit: 4,
		stdout: 'Problem: nothing provides a package\n',
		flags: '1 0 0 0'
	},
	{
		name: 'download stderr',
		exit: 8,
		stderr: 'Download (curl) error: transfer failed\n',
		flags: '0 1 0 0'
	},
	{
		name: 'TLS stdout',
		exit: 8,
		stdout: 'SSL certificate problem: certificate verify failed\n',
		flags: '0 0 1 0'
	},
	{ name: 'unknown localized refusal', exit: 17, stdout: 'Échec inconnu\n', flags: '0 0 0 1' },
	{
		name: 'maximum native exit',
		exit: 255,
		stderr: 'Unrecognized native refusal\n',
		flags: '0 0 0 1'
	},
	{
		name: 'bounded split-token drain',
		exit: 7,
		stdout: `${'x'.repeat(4089)}Problem: nothing provides a package\n${'x'.repeat(1024 * 1024)}\n`,
		stderr: 'Download (curl) error: SSL certificate problem: invalid certificate\n',
		flags: '1 1 1 0'
	},
	{
		name: 'newline separated tokens',
		exit: 19,
		stdout: `${'x'.repeat(256)}Pro\nblem: separated words\n`,
		flags: '0 0 0 1'
	},
	{ name: 'successful private output', exit: 0, stdout: 'Installation completed\n', flags: null }
];

for (const scenario of scenarios) {
	const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-zypper-tooling-'));
	try {
		const files = Object.fromEntries(
			['calls', 'arguments', 'stdout', 'stderr', 'environment', 'phase', 'functions'].map(
				(name) => [name, path.join(sandbox, name)]
			)
		);
		fs.writeFileSync(files.stdout, (scenario.stdout || '') + privatePayload);
		fs.writeFileSync(files.stderr, (scenario.stderr || '') + privatePayload);
		fs.writeFileSync(files.phase, toolingPhase);
		fs.writeFileSync(files.functions, toolingFunctions + '\nprepare_test_tooling\nexit "$?"\n');
		fs.writeFileSync(
			files.environment,
			[
				'PATH="$TOOLING_STUBS:/usr/bin:/bin"',
				'export PATH',
				'command() {',
				'  if [ "$1" = "-v" ]; then',
				'    case "$2" in apt-get) return 1;; zypper) return 0;; esac',
				'  fi',
				'  builtin command "$@"',
				'}',
				''
			].join('\n')
		);
		const fake = path.join(sandbox, 'zypper');
		fs.writeFileSync(
			fake,
			[
				'#!/usr/bin/env bash',
				'printf "call\\n" >> "$TOOLING_CALLS"',
				'printf "%s\\n" "$@" > "$TOOLING_ARGUMENTS"',
				'cat "$TOOLING_STDOUT"',
				'cat "$TOOLING_STDERR" >&2',
				'exit "$TOOLING_EXIT"',
				''
			].join('\n')
		);
		fs.chmodSync(fake, 0o755);
		const env = {
			...process.env,
			BASH_ENV: bashPath(files.environment),
			TOOLING_STUBS: bashPath(sandbox),
			TOOLING_CALLS: bashPath(files.calls),
			TOOLING_ARGUMENTS: bashPath(files.arguments),
			TOOLING_STDOUT: bashPath(files.stdout),
			TOOLING_STDERR: bashPath(files.stderr),
			TOOLING_EXIT: String(scenario.exit),
			ERGOPTI_E2E_PREP: '',
			ERGOPTI_E2E_EXTRA_CA: '',
			LC_ALL: 'C'
		};
		const run = (file) =>
			spawnSync(bashExecutable(), [bashPath(file)], {
				env,
				encoding: 'utf8',
				timeout: 20000,
				maxBuffer: 4096
			});
		const result = run(files.phase);
		assert.ifError(result.error);
		assert.strictEqual(result.status, scenario.exit === 0 ? 0 : 2, `${scenario.name}: outer exit`);
		const output = result.stdout + result.stderr;
		if (scenario.exit !== 0) {
			const [solver, download, tls, unknown] = scenario.flags.split(' ');
			const receipt = `TOOLING: zypper solver=${solver} download=${download} tls=${tls} unknown=${unknown} native_exit=${scenario.exit}`;
			assert(
				output.includes(receipt),
				`${scenario.name}: exact native exit and closed flags must survive`
			);
			assert(output.includes('ENVIRONMENT: could not install the test tooling'));
			assert(
				!output.includes('are available for the checks'),
				'refusal cannot acknowledge tooling'
			);
		} else {
			assert(
				output.includes('are available for the checks'),
				'success retains the actual tooling acknowledgment'
			);
			assert(!output.includes('TOOLING:'), 'successful native output stays quiet');
		}
		assert(!output.includes(privateMarker), `${scenario.name}: private payload must not escape`);
		assert(
			!output.includes('private.example') &&
				!output.includes('/private/config') &&
				!output.includes('::error::')
		);
		assert(output.length < 1024, `${scenario.name}: emitted diagnostics are bounded`);
		assert.strictEqual(fs.readFileSync(files.calls, 'utf8'), 'call\n', 'no native retry');
		assert.deepStrictEqual(
			fs.readFileSync(files.arguments, 'utf8').trimEnd().split('\n'),
			expectedArguments
		);
		// The public wrapper's native return is independent of the outer exit 2.
		fs.writeFileSync(files.calls, '');
		const native = run(files.functions);
		assert.ifError(native.error);
		assert.strictEqual(native.status, scenario.exit, `${scenario.name}: exact native return`);
		assert.strictEqual(fs.readFileSync(files.calls, 'utf8'), 'call\n');
	} finally {
		fs.rmSync(sandbox, { recursive: true, force: true });
	}
}
console.log(
	'[OK] zypper tooling retains eight bounded native receipts without payloads or retries.'
);
