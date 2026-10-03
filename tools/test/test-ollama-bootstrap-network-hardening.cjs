// tools/test/test-ollama-bootstrap-network-hardening.cjs

/**
 * ============================================================================
 * MODULE: Ollama Bootstrap Network Hardening - Behavioral Guard
 * DESCRIPTION:
 * Executes the production macOS bootstrap in a hermetic HOME with faithful
 * curl/checksum/archive/xattr doubles. It proves retry/timeout ownership,
 * pinned integrity, localized failure markers, download progress, quarantine
 * removal only after verification, and fail-closed publication into the
 * Application Support folder the Lua resolver searches, without network or
 * elevated writes.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const LLM_ROOT = path.join(MACOS_ROOT, 'modules', 'llm');
const SOURCE_SCRIPT = path.join(LLM_ROOT, 'ensure-ollama-deps.sh');
const SOURCE_NETWORK = path.join(LLM_ROOT, 'network-retry.sh');
const SOURCE_RELEASE = path.join(LLM_ROOT, 'ollama-release.sh');
const MLX_SCRIPT = path.join(LLM_ROOT, 'ensure-mlx-deps.sh');
const BUILD_SCRIPT = path.join(ROOT, 'tools', 'build', 'build_macos_app.sh');

let passed = 0;
let failed = 0;
const results = [];

function test(name, ok, detail = '') {
	passed += ok ? 1 : 0;
	failed += ok ? 0 : 1;
	results.push({ name, ok, detail });
}

function report() {
	console.log('TAP version 14');
	console.log(`1..${results.length}`);
	results.forEach((result, index) => {
		console.log(`${result.ok ? 'ok' : 'not ok'} ${index + 1} - ${result.name}`);
		if (!result.ok && result.detail) console.log(`  # ${result.detail}`);
	});
	console.log(`# passed: ${passed}/${results.length}`);
	if (failed > 0) process.exit(1);
}

function toBashPath(filePath) {
	const normalized = path.resolve(filePath).replace(/\\/g, '/');
	if (process.platform !== 'win32') return normalized;
	const match = normalized.match(/^([A-Za-z]):(\/.*)$/);
	if (!match) throw new Error(`cannot convert path for Git Bash: ${filePath}`);
	return `/${match[1].toLowerCase()}${match[2]}`;
}

function writeExecutable(filePath, source) {
	fs.mkdirSync(path.dirname(filePath), { recursive: true });
	fs.writeFileSync(filePath, source, { encoding: 'utf8', mode: 0o755 });
	fs.chmodSync(filePath, 0o755);
}

function readCount(filePath) {
	if (!fs.existsSync(filePath)) return 0;
	return Number.parseInt(fs.readFileSync(filePath, 'utf8').trim(), 10);
}

function runDetail(run) {
	return JSON.stringify({
		status: run.status,
		error: run.error && run.error.message,
		stdout: run.stdout,
		stderr: run.stderr
	});
}

function createFixture(mode, checksumMode) {
	const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-ollama-net-'));
	const scriptDir = path.join(fixtureRoot, 'macos', 'modules', 'llm');
	const scriptPath = path.join(scriptDir, 'ensure-ollama-deps.sh');
	const homeDir = path.join(fixtureRoot, 'home');
	const fakeBin = path.join(homeDir, '.local', 'bin');
	fs.mkdirSync(scriptDir, { recursive: true });
	fs.mkdirSync(fakeBin, { recursive: true });
	fs.copyFileSync(SOURCE_SCRIPT, scriptPath);
	fs.chmodSync(scriptPath, 0o755);
	for (const [source, name] of [
		[SOURCE_NETWORK, 'network-retry.sh'],
		[SOURCE_RELEASE, 'ollama-release.sh']
	]) {
		if (fs.existsSync(source)) fs.copyFileSync(source, path.join(scriptDir, name));
	}
	fs.writeFileSync(path.join(homeDir, 'curl-mode'), mode, 'utf8');
	fs.writeFileSync(path.join(homeDir, 'checksum-mode'), checksumMode, 'utf8');

	writeExecutable(
		path.join(fakeBin, 'curl'),
		`#!/usr/bin/env bash
set -eu
count_file="$HOME/curl-count"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
count=$((count + 1))
printf '%s' "$count" > "$count_file"
printf '%s\\n' "$*" >> "$HOME/curl-args"
mode="$(cat "$HOME/curl-mode")"
if [ "$mode" = 'always_fail' ] || { [ "$mode" = 'flaky' ] && [ "$count" -lt 3 ]; }; then
  exit 56
fi
output=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-o' ]; then
    shift
    output="\${1:?missing curl output}"
  fi
  shift
done
if [ "$mode" = 'resume' ] && [ -n "$output" ]; then
  if [ "$count" -eq 1 ]; then
    printf '%s' 'fixture ' > "$output"
    exit 28
  fi
  printf 'resumed-from=%s\\n' "$(wc -c < "$output" | tr -d ' ')" >> "$HOME/curl-resume"
  printf '%s\\n' 'archive' >> "$output"
  exit 0
fi
if [ -n "$output" ]; then
  printf '%s\\n' 'fixture archive' > "$output"
else
  cat <<'INSTALLER'
#!/bin/sh
mkdir -p "$HOME/.local/bin"
printf '#!/bin/sh\\nexit 0\\n' > "$HOME/.local/bin/ollama"
chmod +x "$HOME/.local/bin/ollama"
INSTALLER
fi
`
	);

	writeExecutable(
		path.join(fakeBin, 'shasum'),
		`#!/usr/bin/env bash
set -eu
[ "\${1:-}" = '-a' ]
[ "\${2:-}" = '256' ]
release_file="$ERGOPTI_FIXTURE_ROOT/macos/modules/llm/ollama-release.sh"
expected="$(sed -n 's/^OLLAMA_DARWIN_TGZ_SHA256="\\([0-9a-f]*\\)"$/\\1/p' "$release_file")"
checksum_mode="$(cat "$HOME/checksum-mode")"
if [ "$checksum_mode" = 'fail' ]; then exit 75; fi
if [ "$checksum_mode" = 'bad' ]; then
  expected='0000000000000000000000000000000000000000000000000000000000000000'
fi
printf '%s  %s\\n' "$expected" "\${3:?missing checksum input}"
`
	);

	writeExecutable(
		path.join(fakeBin, 'tar'),
		`#!/usr/bin/env bash
set -eu
count_file="$HOME/tar-count"
count=0
[ ! -f "$count_file" ] || count="$(cat "$count_file")"
printf '%s' "$((count + 1))" > "$count_file"
destination=''
while [ "$#" -gt 0 ]; do
  if [ "$1" = '-C' ]; then shift; destination="\${1:?missing extraction path}"; fi
  shift
done
[ -n "$destination" ]
mkdir -p "$destination"
printf '#!/bin/sh\\nexit 0\\n' > "$destination/ollama"
chmod +x "$destination/ollama"
`
	);

	writeExecutable(path.join(fakeBin, 'sleep'), '#!/usr/bin/env bash\nexit 0\n');
	writeExecutable(
		path.join(fakeBin, 'xattr'),
		`#!/usr/bin/env bash
printf '%s\\n' "$*" >> "$HOME/xattr-args"
exit 0
`
	);

	const installDir = path.join(homeDir, 'Library', 'Application Support', 'Ergopti', 'ollama');

	return {
		fixtureRoot,
		homeDir,
		scriptPath,
		fakeBin,
		installDir,
		installedPath: path.join(installDir, 'ollama'),
		xattrArgsPath: path.join(homeDir, 'xattr-args'),
		curlCountPath: path.join(homeDir, 'curl-count'),
		tarCountPath: path.join(homeDir, 'tar-count'),
		curlArgsPath: path.join(homeDir, 'curl-args')
	};
}

function runFixture(bash, fixture, args = ['', fixture.installDir]) {
	const bashArgs = args.map((arg) => (arg === '' ? '' : toBashPath(arg)));
	const fixturePath = `${toBashPath(fixture.fakeBin)}:/usr/bin:/bin`;
	// Git's bin/bash wrapper prepends real system tools to inherited PATH.
	// Set the private transport path after that wrapper has finished startup.
	return spawnSync(bash, ['-s', '--', fixturePath, toBashPath(fixture.scriptPath), ...bashArgs], {
		input:
			'export PATH="$1"; shift\n' +
			'expected="${PATH%%:*}/curl"\n' +
			'if [ "$(command -v curl)" != "$expected" ]; then echo "Private curl transport is missing." >&2; exit 78; fi\n' +
			'exec bash "$@"\n',
		cwd: fixture.fixtureRoot,
		encoding: 'utf8',
		timeout: 30000,
		maxBuffer: 16 * 1024 * 1024,
		env: {
			...process.env,
			HOME: toBashPath(fixture.homeDir),
			PATH: `${toBashPath(fixture.fakeBin)}:/usr/bin:/bin`,
			ERGOPTI_FIXTURE_ROOT: toBashPath(fixture.fixtureRoot)
		}
	});
}

function cleanupFixture(fixture) {
	const tempRoot = path.resolve(os.tmpdir()) + path.sep;
	if (path.resolve(fixture.fixtureRoot).startsWith(tempRoot)) {
		fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true });
	}
}

const bash = bashExecutable();

const missingTransport = createFixture('flaky', 'good');
try {
	fs.unlinkSync(path.join(missingTransport.fakeBin, 'curl'));
	const run = runFixture(bash, missingTransport);
	test(
		'a missing private transport fails before any real network command',
		run.status === 78 &&
			/Private curl transport is missing/.test(run.stderr) &&
			readCount(missingTransport.curlCountPath) === 0,
		runDetail(run)
	);
} finally {
	cleanupFixture(missingTransport);
}

const flaky = createFixture('flaky', 'good');
try {
	const run = runFixture(bash, flaky);
	test(
		'a transient TLS failure is retried to a successful exact install',
		run.status === 0 && readCount(flaky.curlCountPath) === 3,
		runDetail(run)
	);
	test(
		'the pinned archive is published into the Application Support folder the resolver searches',
		fs.existsSync(flaky.installedPath) && readCount(flaky.tarCountPath) === 1
	);
	test(
		'the download reports progress markers to the shared window',
		/^OLLAMA_DOWNLOAD_PROGRESS \d+$/m.test(run.stdout) && /^OLLAMA_VERIFIED$/m.test(run.stdout),
		runDetail(run)
	);
	const xattrArgs = fs.existsSync(flaky.xattrArgsPath)
		? fs.readFileSync(flaky.xattrArgsPath, 'utf8')
		: '';
	test(
		'quarantine is removed from the verified staged files only',
		/-dr com\.apple\.quarantine .*\.ollama\.ergopti\./.test(xattrArgs),
		xattrArgs
	);
	const curlArgs = fs.existsSync(flaky.curlArgsPath)
		? fs.readFileSync(flaky.curlArgsPath, 'utf8')
		: '';
	test(
		'every download attempt carries the shared stall-bounded, resumable curl policy',
		curlArgs.includes('--connect-timeout 30') &&
			curlArgs.includes('--speed-limit 1024') &&
			curlArgs.includes('--speed-time 60') &&
			curlArgs.includes('--continue-at -') &&
			curlArgs.includes('--retry 5') &&
			curlArgs.includes('--retry-all-errors') &&
			!curlArgs.includes('--max-time'),
		curlArgs
	);
	const beforeFastPath = readCount(flaky.curlCountPath);
	const fastPath = runFixture(bash, flaky, [flaky.installedPath, flaky.installDir]);
	test(
		'an exact resolved executable keeps the zero-network fast path',
		fastPath.status === 0 && readCount(flaky.curlCountPath) === beforeFastPath,
		runDetail(fastPath)
	);
} finally {
	cleanupFixture(flaky);
}

const slowLink = createFixture('resume', 'good');
try {
	const run = runFixture(bash, slowLink);
	const resumeLog = fs.existsSync(path.join(slowLink.homeDir, 'curl-resume'))
		? fs.readFileSync(path.join(slowLink.homeDir, 'curl-resume'), 'utf8')
		: '';
	test(
		'an attempt cut off part way resumes its bytes instead of restarting from zero',
		run.status === 0 &&
			readCount(slowLink.curlCountPath) === 2 &&
			resumeLog.trim() === 'resumed-from=8' &&
			fs.existsSync(slowLink.installedPath),
		`${resumeLog} ${runDetail(run)}`
	);
} finally {
	cleanupFixture(slowLink);
}

const hostile = createFixture('success', 'bad');
try {
	const run = runFixture(bash, hostile);
	test(
		'a checksum mismatch fails before extraction or publication',
		run.status !== 0 &&
			!fs.existsSync(hostile.installedPath) &&
			readCount(hostile.tarCountPath) === 0 &&
			/checksum|SHA-256/i.test(run.stderr),
		runDetail(run)
	);
	test(
		'a checksum mismatch prints the localized-failure marker and never lifts quarantine',
		/^OLLAMA_ERROR_CHECKSUM$/m.test(run.stdout) && !fs.existsSync(hostile.xattrArgsPath),
		runDetail(run)
	);
} finally {
	cleanupFixture(hostile);
}

const offline = createFixture('always_fail', 'good');
try {
	const run = runFixture(bash, offline);
	test(
		'a permanent outage exhausts the shared bounded retry budget',
		run.status !== 0 &&
			readCount(offline.curlCountPath) === 6 &&
			!fs.existsSync(offline.installedPath),
		runDetail(run)
	);
	test(
		'a network failure prints the localized-failure marker',
		/^OLLAMA_ERROR_NETWORK$/m.test(run.stdout),
		runDetail(run)
	);
} finally {
	cleanupFixture(offline);
}

const unnamed = createFixture('success', 'good');
try {
	const run = runFixture(bash, unnamed, ['', '']);
	test(
		'without a resolver-named install folder nothing is downloaded',
		run.status !== 0 && readCount(unnamed.curlCountPath) === 0,
		runDetail(run)
	);
} finally {
	cleanupFixture(unnamed);
}

const unreadable = createFixture('success', 'fail');
try {
	const run = runFixture(bash, unreadable);
	test(
		'a checksum-tool failure is loud and non-publishing',
		run.status !== 0 &&
			!fs.existsSync(unreadable.installedPath) &&
			readCount(unreadable.tarCountPath) === 0 &&
			/checksum/i.test(run.stderr),
		runDetail(run)
	);
} finally {
	cleanupFixture(unreadable);
}

const networkSource = fs.existsSync(SOURCE_NETWORK) ? fs.readFileSync(SOURCE_NETWORK, 'utf8') : '';
const releaseSource = fs.existsSync(SOURCE_RELEASE) ? fs.readFileSync(SOURCE_RELEASE, 'utf8') : '';
const ollamaSource = fs.readFileSync(SOURCE_SCRIPT, 'utf8');
const mlxSource = fs.readFileSync(MLX_SCRIPT, 'utf8');
const buildSource = fs.readFileSync(BUILD_SCRIPT, 'utf8');
test(
	'MLX and Ollama source one retry and curl policy',
	networkSource.includes('retry_network()') &&
		networkSource.includes('curl_resilient()') &&
		ollamaSource.includes('network-retry.sh') &&
		mlxSource.includes('network-retry.sh')
);
test(
	'only the on-demand install sources the pinned Ollama release; the app build no longer bundles it',
	releaseSource.includes('OLLAMA_RELEASE_VERSION="0.24.0"') &&
		releaseSource.includes('OLLAMA_DARWIN_TGZ_SHA256=') &&
		releaseSource.includes('OLLAMA_DARWIN_TGZ_BYTES=') &&
		ollamaSource.includes('ollama-release.sh') &&
		!buildSource.includes('ollama-release.sh') &&
		!buildSource.includes('Tools/Ollama')
);
test(
	'the install script leaves detection to the Lua resolver',
	!/command -v ollama/.test(ollamaSource) && !ollamaSource.includes('.local/bin')
);
test(
	'the runtime never pipes remote code into a shell or delegates to Homebrew',
	!ollamaSource.includes('| sh') && !/\bbrew\s+install\b/.test(ollamaSource)
);

report();
