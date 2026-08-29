// tools/test/test-ollama-bootstrap-network-hardening.cjs

/**
 * ============================================================================
 * MODULE: Ollama Bootstrap Network Hardening - Behavioral Guard
 * DESCRIPTION:
 * Executes the production macOS bootstrap in a hermetic HOME with faithful
 * curl/checksum/archive doubles. It proves retry/timeout ownership, pinned
 * integrity, and fail-closed publication without network or elevated writes.
 * ============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

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

function resolveBash() {
	const candidates = [];
	if (process.platform === 'win32') {
		const git = spawnSync('git', ['--exec-path'], { encoding: 'utf8' });
		if (!git.error && git.status === 0) {
			candidates.push(path.resolve(git.stdout.trim(), '..', '..', '..', 'bin', 'bash.exe'));
		}
		candidates.push('C:\\Program Files\\Git\\bin\\bash.exe');
	} else {
		candidates.push('/bin/bash', 'bash');
	}
	for (const candidate of candidates) {
		const probe = spawnSync(candidate, ['--version'], { encoding: 'utf8' });
		if (!probe.error && probe.status === 0) return candidate;
	}
	return null;
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
		stderr: run.stderr,
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
		[SOURCE_RELEASE, 'ollama-release.sh'],
	]) {
		if (fs.existsSync(source)) fs.copyFileSync(source, path.join(scriptDir, name));
	}
	fs.writeFileSync(path.join(homeDir, 'curl-mode'), mode, 'utf8');
	fs.writeFileSync(path.join(homeDir, 'checksum-mode'), checksumMode, 'utf8');

	writeExecutable(path.join(fakeBin, 'curl'), `#!/usr/bin/env bash
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
`);

	writeExecutable(path.join(fakeBin, 'shasum'), `#!/usr/bin/env bash
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
`);

	writeExecutable(path.join(fakeBin, 'tar'), `#!/usr/bin/env bash
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
`);

	writeExecutable(path.join(fakeBin, 'sleep'), '#!/usr/bin/env bash\nexit 0\n');

	return {
		fixtureRoot,
		homeDir,
		scriptPath,
		installedPath: path.join(fakeBin, 'ollama'),
		curlCountPath: path.join(homeDir, 'curl-count'),
		tarCountPath: path.join(homeDir, 'tar-count'),
		curlArgsPath: path.join(homeDir, 'curl-args'),
	};
}

function runFixture(bash, fixture, args = []) {
	return spawnSync(bash, [toBashPath(fixture.scriptPath), ...args.map(toBashPath)], {
		cwd: fixture.fixtureRoot,
		encoding: 'utf8',
		maxBuffer: 16 * 1024 * 1024,
		env: {
			...process.env,
			HOME: toBashPath(fixture.homeDir),
			PATH: '/usr/bin:/bin',
			ERGOPTI_FIXTURE_ROOT: toBashPath(fixture.fixtureRoot),
		},
	});
}

function cleanupFixture(fixture) {
	const tempRoot = path.resolve(os.tmpdir()) + path.sep;
	if (path.resolve(fixture.fixtureRoot).startsWith(tempRoot)) {
		fs.rmSync(fixture.fixtureRoot, { recursive: true, force: true });
	}
}

const bash = resolveBash();
if (!bash) {
	console.error('No usable Bash interpreter found.');
	process.exit(1);
}

const flaky = createFixture('flaky', 'good');
try {
	const run = runFixture(bash, flaky);
	test('a transient TLS failure is retried to a successful exact install',
		run.status === 0 && readCount(flaky.curlCountPath) === 3,
		runDetail(run));
	test('the pinned archive is published as one executable user-local binary',
		fs.existsSync(flaky.installedPath)
			&& readCount(flaky.tarCountPath) === 1);
	const curlArgs = fs.existsSync(flaky.curlArgsPath)
		? fs.readFileSync(flaky.curlArgsPath, 'utf8') : '';
	test('every download attempt carries the shared bounded curl policy',
		curlArgs.includes('--connect-timeout 30')
			&& curlArgs.includes('--max-time 600')
			&& curlArgs.includes('--retry 5')
			&& curlArgs.includes('--retry-all-errors'), curlArgs);
	const beforeFastPath = readCount(flaky.curlCountPath);
	const fastPath = runFixture(bash, flaky, [flaky.installedPath]);
	test('an exact resolved executable keeps the zero-network fast path',
		fastPath.status === 0 && readCount(flaky.curlCountPath) === beforeFastPath,
		runDetail(fastPath));
} finally {
	cleanupFixture(flaky);
}

const hostile = createFixture('success', 'bad');
try {
	const run = runFixture(bash, hostile);
	test('a checksum mismatch fails before extraction or publication',
		run.status !== 0 && !fs.existsSync(hostile.installedPath)
			&& readCount(hostile.tarCountPath) === 0
			&& /checksum|SHA-256/i.test(run.stderr), runDetail(run));
} finally {
	cleanupFixture(hostile);
}

const offline = createFixture('always_fail', 'good');
try {
	const run = runFixture(bash, offline);
	test('a permanent outage exhausts the shared bounded retry budget',
		run.status !== 0 && readCount(offline.curlCountPath) === 6
			&& !fs.existsSync(offline.installedPath), runDetail(run));
} finally {
	cleanupFixture(offline);
}

const unreadable = createFixture('success', 'fail');
try {
	const run = runFixture(bash, unreadable);
	test('a checksum-tool failure is loud and non-publishing',
		run.status !== 0 && !fs.existsSync(unreadable.installedPath)
			&& readCount(unreadable.tarCountPath) === 0
			&& /checksum/i.test(run.stderr), runDetail(run));
} finally {
	cleanupFixture(unreadable);
}

const networkSource = fs.existsSync(SOURCE_NETWORK) ? fs.readFileSync(SOURCE_NETWORK, 'utf8') : '';
const releaseSource = fs.existsSync(SOURCE_RELEASE) ? fs.readFileSync(SOURCE_RELEASE, 'utf8') : '';
const ollamaSource = fs.readFileSync(SOURCE_SCRIPT, 'utf8');
const mlxSource = fs.readFileSync(MLX_SCRIPT, 'utf8');
const buildSource = fs.readFileSync(BUILD_SCRIPT, 'utf8');
test('MLX and Ollama source one retry and curl policy',
	networkSource.includes('retry_network()')
		&& networkSource.includes('curl_resilient()')
		&& ollamaSource.includes('network-retry.sh')
		&& mlxSource.includes('network-retry.sh'));
test('runtime and bundle build source one pinned Ollama release',
	releaseSource.includes('OLLAMA_RELEASE_VERSION="0.24.0"')
		&& releaseSource.includes('OLLAMA_DARWIN_TGZ_SHA256=')
		&& ollamaSource.includes('ollama-release.sh')
		&& buildSource.includes('ollama-release.sh'));
test('the runtime never pipes remote code into a shell or delegates to Homebrew',
	!ollamaSource.includes('| sh') && !/\bbrew\s+install\b/.test(ollamaSource));

report();
