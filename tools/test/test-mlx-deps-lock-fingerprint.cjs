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
const TOML = require('smol-toml');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const MACOS_ROOT = path.join(ROOT, 'static', 'ergopti_plus', 'macos');
const SOURCE_SCRIPT = path.join(MACOS_ROOT, 'modules', 'llm', 'ensure-mlx-deps.sh');
const SOURCE_PYPROJECT = path.join(MACOS_ROOT, 'pyproject.toml');
const SOURCE_LOCK = path.join(MACOS_ROOT, 'uv.lock');
const SOURCE_NETWORK = path.join(MACOS_ROOT, 'modules', 'llm', 'network-retry.sh');
const SOURCE_UV_RELEASE = path.join(MACOS_ROOT, 'modules', 'llm', 'uv-release.sh');
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
	const environment = {
		...process.env,
		HOME: toBashPath(fixtureRoot),
		ERGOPTI_CONFIG_DIR: ''
	};
	// Fake uv owns the child operations; its supported route is fixture input.
	// Do not depend on a developer relay or native scutil in this portable mirror.
	for (const key of Object.keys(environment)) {
		if (
			/^(?:https?_proxy|all_proxy|no_proxy|ssl_cert_file|ssl_cert_dir|requests_ca_bundle|curl_ca_bundle|uv_system_certs)$/i.test(
				key
			)
		)
			delete environment[key];
	}
	environment.HTTPS_PROXY = 'http://fixture.invalid:3128';
	return spawnSync(bash, [toBashPath(scriptPath)], {
		cwd: fixtureRoot,
		encoding: 'utf8',
		maxBuffer: 16 * 1024 * 1024,
		env: environment
	});
}

function runDetail(run) {
	return JSON.stringify({
		status: run.status,
		error: run.error && run.error.message,
		stdout: run.stdout,
		stderr: run.stderr
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

// Literal artifact receipts from https://pypi.org/pypi/truststore/0.10.4/json.
// Independent metadata SHA256: 803a5dafe852bdd8b209c3df0dd7488c8f949ce7d1862820557704db1134cb41.
const TRUSTSTORE_PYPI_RELEASE = {
	version: '0.10.4',
	artifacts: [
		{
			url: 'https://files.pythonhosted.org/packages/19/97/56608b2249fe206a67cd573bc93cd9896e1efb9e98bce9c163bcdc704b88/truststore-0.10.4-py3-none-any.whl',
			hash: 'sha256:adaeaecf1cbb5f4de3b1959b42d41f6fab57b2b1666adb59e89cb0b53361d981',
			size: 18660,
			kind: 'wheel'
		},
		{
			url: 'https://files.pythonhosted.org/packages/53/a3/1585216310e344e8102c22482f6060c7a6ea0322b63e026372e6dcefcfd6/truststore-0.10.4.tar.gz',
			hash: 'sha256:9d91bd436463ad5e4ee4aba766628dd6cd7010cf3e2461756b3303710eebc301',
			size: 26169,
			kind: 'sdist'
		}
	]
};

/**
 * Checks the shipped TOML resolution without executing uv or installing packages.
 * @param {object} project Parsed pyproject.toml.
 * @param {object} lock Parsed uv.lock.
 * @returns {string[]} Literal refusal reasons for inconsistent truststore records.
 */
function truststoreLockIssues(project, lock) {
	const issues = [];
	const dependencies = project.project && project.project.dependencies;
	const direct = Array.isArray(dependencies)
		? dependencies.filter(
				(value) => typeof value === 'string' && /^truststore(?:[<>=!~;\s\[]|$)/i.test(value)
			)
		: [];
	const pin = direct.length === 1 && /^truststore==([A-Za-z0-9][A-Za-z0-9.!+_-]*)$/.exec(direct[0]);
	if (!pin) issues.push('direct-pin');
	const packages = Array.isArray(lock.package) ? lock.package : [];
	const resolved = packages.filter((entry) => entry.name === 'truststore');
	const distribution = resolved.length === 1 ? resolved[0] : null;
	if (
		!distribution ||
		!pin ||
		distribution.version !== pin[1] ||
		distribution.version !== TRUSTSTORE_PYPI_RELEASE.version
	)
		issues.push('resolved-version');
	const projects = packages.filter(
		(entry) => project.project && entry.name === project.project.name
	);
	const virtual = projects.length === 1 ? projects[0] : null;
	if (
		!virtual ||
		!virtual.source ||
		virtual.source.virtual !== '.' ||
		virtual.version !== project.project.version
	)
		issues.push('virtual-project');
	const virtualDependencies = virtual && virtual.dependencies;
	const linked = Array.isArray(virtualDependencies)
		? virtualDependencies.filter((entry) => entry.name === 'truststore')
		: [];
	if (
		linked.length !== 1 ||
		linked[0].marker !== undefined ||
		(linked[0].version !== undefined &&
			(!distribution || linked[0].version !== distribution.version))
	)
		issues.push('virtual-dependency');
	const metadata = virtual && virtual.metadata && virtual.metadata['requires-dist'];
	const declared = Array.isArray(metadata)
		? metadata.filter((entry) => entry.name === 'truststore')
		: [];
	if (
		declared.length !== 1 ||
		!pin ||
		declared[0].specifier !== `==${pin[1]}` ||
		declared[0].marker !== undefined
	)
		issues.push('requires-dist');
	if (
		!distribution ||
		!distribution.source ||
		distribution.source.registry !== 'https://pypi.org/simple'
	)
		issues.push('pypi-registry');
	function officialArtifact(artifact, wheel) {
		if (
			!artifact ||
			typeof artifact.url !== 'string' ||
			!/^sha256:[0-9a-f]{64}$/.test(artifact.hash) ||
			!Number.isSafeInteger(artifact.size) ||
			artifact.size <= 0 ||
			!distribution
		)
			return false;
		let url;
		try {
			url = new URL(artifact.url);
		} catch {
			return false;
		}
		if (
			url.protocol !== 'https:' ||
			url.hostname !== 'files.pythonhosted.org' ||
			url.port ||
			url.username ||
			url.password ||
			url.search ||
			url.hash ||
			!url.pathname.startsWith('/packages/')
		)
			return false;
		const filename = url.pathname.slice(url.pathname.lastIndexOf('/') + 1);
		const matchesFilename = wheel
			? filename.startsWith(`truststore-${distribution.version}-`) && filename.endsWith('.whl')
			: filename === `truststore-${distribution.version}.tar.gz`;
		return (
			matchesFilename &&
			TRUSTSTORE_PYPI_RELEASE.artifacts.some(
				(expected) =>
					expected.kind === (wheel ? 'wheel' : 'sdist') &&
					expected.url === artifact.url &&
					expected.hash === artifact.hash &&
					expected.size === artifact.size
			)
		);
	}
	if (!distribution || !officialArtifact(distribution.sdist, false)) issues.push('sdist-artifact');
	if (
		!distribution ||
		!Array.isArray(distribution.wheels) ||
		distribution.wheels.length !==
			TRUSTSTORE_PYPI_RELEASE.artifacts.filter((entry) => entry.kind === 'wheel').length ||
		!distribution.wheels.every((artifact) => officialArtifact(artifact, true))
	)
		issues.push('wheel-artifact');
	return issues;
}

/**
 * Parses real source TOML, then checks independent causal mutations of its records.
 * These static controls do not claim native uv, Python import or macOS acceptance.
 */
function checkShippedTruststoreLock() {
	let project;
	let lock;
	try {
		project = TOML.parse(fs.readFileSync(SOURCE_PYPROJECT, 'utf8'));
		lock = TOML.parse(fs.readFileSync(SOURCE_LOCK, 'utf8'));
	} catch (error) {
		test('shipped MLX dependency sources parse as TOML', false, error.message);
		return;
	}
	test('shipped MLX dependency sources parse as TOML', true);
	const issues = truststoreLockIssues(project, lock);
	test(
		'shipped truststore pin, virtual project, metadata and PyPI artifacts agree',
		issues.length === 0,
		issues.join(', ')
	);
	function mutant(name, expected, change) {
		const changedProject = JSON.parse(JSON.stringify(project));
		const changedLock = JSON.parse(JSON.stringify(lock));
		let observed = [];
		try {
			change(changedProject, changedLock);
			observed = truststoreLockIssues(
				TOML.parse(TOML.stringify(changedProject)),
				TOML.parse(TOML.stringify(changedLock))
			);
		} catch (error) {
			test(name, false, error.message);
			return;
		}
		// A broken shipped baseline cannot earn mutation credit vacuously.
		test(name, issues.length === 0 && observed.includes(expected), observed.join(', '));
	}
	const virtual = (value) => value.package.find((entry) => entry.name === project.project.name);
	const distribution = (value) => value.package.find((entry) => entry.name === 'truststore');
	mutant('missing direct truststore pin is refused', 'direct-pin', (value) => {
		value.project.dependencies = value.project.dependencies.filter(
			(entry) => !entry.startsWith('truststore')
		);
	});
	mutant('unpinned direct truststore range is refused', 'direct-pin', (value) => {
		value.project.dependencies = value.project.dependencies.map((entry) =>
			entry.startsWith('truststore') ? 'truststore>=0.9.1' : entry
		);
	});
	mutant(
		'missing virtual-project truststore dependency is refused',
		'virtual-dependency',
		(_, value) => {
			virtual(value).dependencies = virtual(value).dependencies.filter(
				(entry) => entry.name !== 'truststore'
			);
		}
	);
	mutant('missing requires-dist truststore metadata is refused', 'requires-dist', (_, value) => {
		virtual(value).metadata['requires-dist'] = virtual(value).metadata['requires-dist'].filter(
			(entry) => entry.name !== 'truststore'
		);
	});
	mutant('missing resolved truststore package is refused', 'resolved-version', (_, value) => {
		value.package = value.package.filter((entry) => entry.name !== 'truststore');
	});
	mutant(
		'resolved truststore version differing from direct pin is refused',
		'resolved-version',
		(_, value) => {
			distribution(value).version = '0.0.0';
		}
	);
	mutant(
		'requires-dist version differing from direct pin is refused',
		'requires-dist',
		(_, value) => {
			virtual(value).metadata['requires-dist'].find(
				(entry) => entry.name === 'truststore'
			).specifier = '==0.0.0';
		}
	);
	mutant('non-virtual MLX project source is refused', 'virtual-project', (_, value) => {
		virtual(value).source = { registry: 'https://pypi.org/simple' };
	});
	mutant('non-PyPI truststore registry is refused', 'pypi-registry', (_, value) => {
		distribution(value).source.registry = 'https://example.invalid/simple';
	});
	mutant('missing truststore sdist is refused', 'sdist-artifact', (_, value) => {
		delete distribution(value).sdist;
	});
	mutant('missing truststore wheels are refused', 'wheel-artifact', (_, value) => {
		distribution(value).wheels = [];
	});
	mutant('foreign truststore wheel host is refused', 'wheel-artifact', (_, value) => {
		distribution(value).wheels[0].url = distribution(value).wheels[0].url.replace(
			'files.pythonhosted.org',
			'example.invalid'
		);
	});
	mutant('malformed truststore sdist SHA256 is refused', 'sdist-artifact', (_, value) => {
		distribution(value).sdist.hash = 'sha256:invalid';
	});
	mutant('malformed truststore wheel SHA256 is refused', 'wheel-artifact', (_, value) => {
		distribution(value).wheels[0].hash = 'sha256:invalid';
	});
	mutant('well-formed foreign truststore sdist digest is refused', 'sdist-artifact', (_, value) => {
		distribution(value).sdist.hash = `sha256:${'0'.repeat(64)}`;
	});
	mutant('well-formed foreign truststore wheel digest is refused', 'wheel-artifact', (_, value) => {
		distribution(value).wheels[0].hash = `sha256:${'0'.repeat(64)}`;
	});
	mutant(
		'truststore artifact size differing from official PyPI is refused',
		'wheel-artifact',
		(_, value) => {
			distribution(value).wheels[0].size += 1;
		}
	);
	mutant(
		'foreign artifact path on the official PyPI host is refused',
		'sdist-artifact',
		(_, value) => {
			distribution(value).sdist.url = distribution(value).sdist.url.replace(
				'/packages/',
				'/packages/foreign/'
			);
		}
	);
}

checkShippedTruststoreLock();

const bash = bashExecutable();

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
	fs.copyFileSync(SOURCE_NETWORK, path.join(path.dirname(scriptPath), 'network-retry.sh'));
	fs.copyFileSync(SOURCE_UV_RELEASE, path.join(path.dirname(scriptPath), 'uv-release.sh'));
	fs.copyFileSync(SOURCE_PYPROJECT, pyprojectPath);
	fs.copyFileSync(SOURCE_LOCK, lockPath);
	fs.chmodSync(scriptPath, 0o755);
	writeFakeUv(fakeUvPath);
	writeShasumFacade(shasumPath);

	const originalPyproject = fs.readFileSync(pyprojectPath);
	const originalLock = fs.readFileSync(lockPath);

	const cold = runBootstrap(bash, scriptPath, fixtureRoot);
	test(
		'cold bootstrap executes exactly one dependency sync',
		cold.status === 0 && cold.stdout.includes(SYNC_MARKER) && syncCount(countPath) === 1,
		runDetail(cold)
	);
	test(
		'development sync is allowed to update only uv.lock',
		fs.readFileSync(pyprojectPath).equals(originalPyproject) &&
			!fs.readFileSync(lockPath).equals(originalLock)
	);
	test(
		'cold bootstrap stores the post-sync combined fingerprint',
		fs.existsSync(markerPath) &&
			fs.readFileSync(markerPath, 'utf8') === combinedFingerprint(pyprojectPath, lockPath),
		fs.existsSync(markerPath) ? fs.readFileSync(markerPath, 'utf8') : 'marker missing'
	);

	const unchanged = runBootstrap(bash, scriptPath, fixtureRoot);
	test(
		'unchanged dependency sources take the silent fast path',
		unchanged.status === 0 && !unchanged.stdout.includes(SYNC_MARKER) && syncCount(countPath) === 1,
		runDetail(unchanged)
	);

	fs.appendFileSync(lockPath, '\n# external lock-only update\n', 'utf8');
	const lockOnly = runBootstrap(bash, scriptPath, fixtureRoot);
	test(
		'a lock-only update forces a second dependency sync',
		lockOnly.status === 0 && lockOnly.stdout.includes(SYNC_MARKER) && syncCount(countPath) === 2,
		runDetail(lockOnly)
	);
	test(
		'lock-only invalidation does not require a pyproject edit',
		fs.readFileSync(pyprojectPath).equals(originalPyproject)
	);

	const settled = runBootstrap(bash, scriptPath, fixtureRoot);
	test(
		'the updated lock fingerprint restores the silent fast path',
		settled.status === 0 && !settled.stdout.includes(SYNC_MARKER) && syncCount(countPath) === 2,
		runDetail(settled)
	);
} finally {
	const tempRoot = path.resolve(os.tmpdir()) + path.sep;
	if (path.resolve(fixtureRoot).startsWith(tempRoot)) {
		fs.rmSync(fixtureRoot, { recursive: true, force: true });
	}
}

report();
