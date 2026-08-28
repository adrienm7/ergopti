// tools/test/test-mlx-deps-lock-fingerprint.cjs

/**
 * ============================================================================
 * MODULE: MLX Dependency Lock Fingerprint - Behavioral Guard
 * DESCRIPTION:
 * Executes the production dependency bootstrap in a hermetic project mirror.
 * It proves that pyproject.toml and uv.lock jointly own the fast path, and that
 * a development-mode uv sync which rewrites uv.lock publishes the post-sync
 * fingerprint rather than forcing a redundant rebuild on the next launch.
 * ============================================================================
 */

'use strict';

const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const SOURCE_SCRIPT = path.join(MACOS_ROOT, 'modules', 'llm', 'ensure-mlx-deps.sh');
const SOURCE_PYPROJECT = path.join(MACOS_ROOT, 'pyproject.toml');
const SOURCE_LOCK = path.join(MACOS_ROOT, 'uv.lock');
const SYNC_MARKER = 'VENV_SYNC_RAN';

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

function sha256(filePath) {
	return crypto.createHash('sha256').update(fs.readFileSync(filePath)).digest('hex');
}

function combinedFingerprint(pyprojectPath, lockPath) {
	return `${sha256(pyprojectPath)}:${sha256(lockPath)}`;
}

function syncCount(countPath) {
	if (!fs.existsSync(countPath)) return 0;
	return Number.parseInt(fs.readFileSync(countPath, 'utf8').trim(), 10);
}

function runBootstrap(bash, scriptPath, fixtureRoot) {
	return spawnSync(bash, [toBashPath(scriptPath)], {
		cwd: fixtureRoot,
		encoding: 'utf8',
		maxBuffer: 16 * 1024 * 1024,
		env: {
			...process.env,
			HOME: toBashPath(fixtureRoot),
			ERGOPTI_CONFIG_DIR: '',
		},
	});
}

function runDetail(run) {
	return JSON.stringify({
		status: run.status,
		error: run.error && run.error.message,
		stdout: run.stdout,
		stderr: run.stderr,
	});
}

function writeFakeUv(fakeUvPath) {
	const source = `#!/usr/bin/env bash
set -eu

case "\${1:-}" in
  --version)
    printf '%s\\n' 'uv 0.0.0-fixture'
    ;;
  python)
    [ "\${2:-}" = 'find' ]
    ;;
  venv)
    target="\${2:?missing venv target}"
    mkdir -p "$target/bin" "$target/lib/python3.11/site-packages"
    printf '%s\\n' '#!/usr/bin/env bash' 'exit 0' > "$target/bin/python"
    chmod +x "$target/bin/python"
    ;;
  sync)
    count_file="$HOME/uv-sync-count"
    count=0
    if [ -f "$count_file" ]; then count="$(cat "$count_file")"; fi
    count=$((count + 1))
    printf '%s' "$count" > "$count_file"
    project=''
    while [ "$#" -gt 0 ]; do
      if [ "$1" = '--project' ]; then
        shift
        project="\${1:?missing project path}"
      fi
      shift
    done
    sp="$UV_PROJECT_ENVIRONMENT/lib/python3.11/site-packages"
    mkdir -p "$sp/mlx_lm" "$sp/huggingface_hub" "$sp/jinja2" \\
      "$sp/safetensors" "$sp/truststore"
    if [ "$count" -eq 1 ]; then
      printf '%s\\n' '# resolved by fake uv' >> "$project/uv.lock"
    fi
    ;;
  *)
    printf 'unexpected fake uv command: %s\\n' "$*" >&2
    exit 97
    ;;
esac
`;
	fs.mkdirSync(path.dirname(fakeUvPath), { recursive: true });
	fs.writeFileSync(fakeUvPath, source, { encoding: 'utf8', mode: 0o755 });
	fs.chmodSync(fakeUvPath, 0o755);
}

function writeShasumFacade(shasumPath) {
	const source = `#!/usr/bin/env bash
set -eu
[ "\${1:-}" = '-a' ]
[ "\${2:-}" = '256' ]
sha256sum "\${3:?missing input path}"
`;
	fs.writeFileSync(shasumPath, source, { encoding: 'utf8', mode: 0o755 });
	fs.chmodSync(shasumPath, 0o755);
}

const bash = resolveBash();
if (!bash) {
	console.error('No usable Bash interpreter found.');
	process.exit(1);
}

const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-mlx-lock-'));
const macosRoot = path.join(fixtureRoot, 'macos');
const scriptPath = path.join(macosRoot, 'modules', 'llm', 'ensure-mlx-deps.sh');
const pyprojectPath = path.join(macosRoot, 'pyproject.toml');
const lockPath = path.join(macosRoot, 'uv.lock');
const markerPath = path.join(macosRoot, '.venv', '.last_sync_hash');
const countPath = path.join(fixtureRoot, 'uv-sync-count');
const fakeUvPath = path.join(fixtureRoot, '.local', 'bin', 'uv');
const shasumPath = path.join(fixtureRoot, '.local', 'bin', 'shasum');

try {
	fs.mkdirSync(path.dirname(scriptPath), { recursive: true });
	fs.copyFileSync(SOURCE_SCRIPT, scriptPath);
	fs.copyFileSync(SOURCE_PYPROJECT, pyprojectPath);
	fs.copyFileSync(SOURCE_LOCK, lockPath);
	fs.chmodSync(scriptPath, 0o755);
	writeFakeUv(fakeUvPath);
	writeShasumFacade(shasumPath);

	const originalPyproject = fs.readFileSync(pyprojectPath);
	const originalLock = fs.readFileSync(lockPath);

	const cold = runBootstrap(bash, scriptPath, fixtureRoot);
	test('cold bootstrap executes exactly one dependency sync',
		cold.status === 0 && cold.stdout.includes(SYNC_MARKER) && syncCount(countPath) === 1,
		runDetail(cold));
	test('development sync is allowed to update only uv.lock',
		fs.readFileSync(pyprojectPath).equals(originalPyproject)
			&& !fs.readFileSync(lockPath).equals(originalLock));
	test('cold bootstrap stores the post-sync combined fingerprint',
		fs.existsSync(markerPath)
			&& fs.readFileSync(markerPath, 'utf8') === combinedFingerprint(pyprojectPath, lockPath),
		fs.existsSync(markerPath) ? fs.readFileSync(markerPath, 'utf8') : 'marker missing');

	const unchanged = runBootstrap(bash, scriptPath, fixtureRoot);
	test('unchanged dependency sources take the silent fast path',
		unchanged.status === 0 && !unchanged.stdout.includes(SYNC_MARKER)
			&& syncCount(countPath) === 1,
		runDetail(unchanged));

	fs.appendFileSync(lockPath, '\n# external lock-only update\n', 'utf8');
	const lockOnly = runBootstrap(bash, scriptPath, fixtureRoot);
	test('a lock-only update forces a second dependency sync',
		lockOnly.status === 0 && lockOnly.stdout.includes(SYNC_MARKER)
			&& syncCount(countPath) === 2,
		runDetail(lockOnly));
	test('lock-only invalidation does not require a pyproject edit',
		fs.readFileSync(pyprojectPath).equals(originalPyproject));

	const settled = runBootstrap(bash, scriptPath, fixtureRoot);
	test('the updated lock fingerprint restores the silent fast path',
		settled.status === 0 && !settled.stdout.includes(SYNC_MARKER)
			&& syncCount(countPath) === 2,
		runDetail(settled));
} finally {
	const tempRoot = path.resolve(os.tmpdir()) + path.sep;
	if (path.resolve(fixtureRoot).startsWith(tempRoot)) {
		fs.rmSync(fixtureRoot, { recursive: true, force: true });
	}
}

report();
