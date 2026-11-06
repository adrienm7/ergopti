'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const root = path.resolve(__dirname, '../..');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-flatpak-preflight-'));
try {
	const build = path.join(scratch, 'build');
	const staging = path.join(build, 'flatpak');
	fs.mkdirSync(staging, { recursive: true });
	const sentinel = path.join(staging, 'sentinel');
	fs.writeFileSync(sentinel, 'previous state\n');
	const missing = path.join(scratch, 'missing.sh');
	fs.writeFileSync(
		missing,
		'command() { if [ "$1" = -v ] && [ "$2" = "$MISSING_PROGRAM" ]; then return 1; fi; if [ "$1" = -v ] && { [ "$2" = flatpak ] || [ "$2" = flatpak-builder ]; }; then return 0; fi; builtin command "$@"; }\n'
	);
	for (const program of ['flatpak-builder', 'flatpak']) {
		const env = {
			...process.env,
			BASH_ENV: missing,
			MISSING_PROGRAM: program,
			ERGOPTI_LINUX_BUILD_DIR: build
		};
		const launch = (args) =>
			spawnSync(
				bashExecutable(),
				[path.join(root, 'tools/build/build-linux-flatpak.sh'), ...args],
				{ encoding: 'utf8', timeout: 10000, env }
			);
		const refused = launch([]);
		assert.equal(refused.status, 69, refused.stderr);
		assert.match(refused.stderr, new RegExp(program));
		assert.equal(fs.readFileSync(sentinel, 'utf8'), 'previous state\n');
		const stagingOnly = launch(['--skip-flatpak']);
		assert.notEqual(stagingOnly.status, 69);
		assert.match(stagingOnly.stdout, /Driver bundle not found/);
	}
	// Replay the real publication tail with a producer that fails after writing.
	const script = fs.readFileSync(path.join(root, 'tools/build/build-linux-flatpak.sh'), 'utf8');
	const start = script.indexOf('echo "Building the Flatpak..."');
	const end = script.indexOf('\nbundle_size=', start);
	assert.ok(start >= 0 && end > start);
	const artifact = path.join(build, 'existing.flatpak');
	fs.writeFileSync(artifact, 'previous bundle\n');
	const publication = spawnSync(
		bashExecutable(),
		[
			'-c',
			`set -euo pipefail\nflatpak-builder() { :; }\nflatpak() { printf 'partial' > "$3"; return 42; }\n${script.slice(start, end)}`
		],
		{
			encoding: 'utf8',
			timeout: 10000,
			env: {
				...process.env,
				BUILD_DIR: build,
				REPO_DIR: path.join(build, 'repo'),
				BUILDER_DIR: path.join(build, 'builder'),
				MANIFEST_FILE: path.join(build, 'manifest'),
				FLATPAK_FILE: artifact,
				APP_ID: 'org.ergopti.Ergopti',
				BRANCH: 'stable'
			}
		}
	);
	assert.notEqual(publication.status, 0, 'producer refusal must fail');
	assert.equal(
		fs.readFileSync(artifact, 'utf8'),
		'previous bundle\n',
		'failed packaging preserves the prior artifact'
	);
	assert.deepEqual(fs.readdirSync(build).sort(), ['existing.flatpak', 'flatpak']);
	const success = spawnSync(
		bashExecutable(),
		[
			'-c',
			`set -euo pipefail\nflatpak-builder() { :; }\nflatpak() { printf 'new bundle' > "$3"; }\n${script.slice(start, end)}`
		],
		{
			encoding: 'utf8',
			timeout: 10000,
			env: {
				...process.env,
				BUILD_DIR: build,
				REPO_DIR: path.join(build, 'repo'),
				BUILDER_DIR: path.join(build, 'builder'),
				MANIFEST_FILE: path.join(build, 'manifest'),
				FLATPAK_FILE: artifact,
				APP_ID: 'org.ergopti.Ergopti',
				BRANCH: 'stable'
			}
		}
	);
	assert.equal(success.status, 0, success.stderr);
	assert.equal(fs.readFileSync(artifact, 'utf8'), 'new bundle');
	assert.deepEqual(fs.readdirSync(build).sort(), ['existing.flatpak', 'flatpak']);

	console.log('Flatpak build checks its producer before staging.');
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
