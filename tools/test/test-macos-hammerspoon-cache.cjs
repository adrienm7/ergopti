// tools/test/test-macos-hammerspoon-cache.cjs

/**
 * ==============================================================================
 * MODULE: macOS Hammerspoon Download Cache Tests
 * DESCRIPTION:
 * build_macos_app.sh cached the Hammerspoon zip inside BUILD_DIR, which
 * clean_build_dir wipes first, so every build downloaded it again. These checks
 * replay the real clean_build_dir, hammerspoon_zip_matches and
 * download_hammerspoon with recording curl and unzip shims: the cache must
 * survive a wipe, a cached or downloaded zip must match the pinned SHA-256, and
 * a refused download must never be published under the cached name. The CI and
 * cold-bootstrap copies of the pin are held equal to the build script's.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD = fs.readFileSync(path.join(ROOT, 'tools/build/build_macos_app.sh'), 'utf8');

let checks = 0;
function check(name, body) {
	body();
	checks++;
	console.log(`PASS ${name}`);
}

/** Returns one top-level shell function of the build script, or of `source`. */
function shellFunction(name, source = BUILD) {
	const start = source.indexOf(`\n${name}() {\n`);
	assert(start >= 0, `the shell source defines ${name}()`);
	return source.slice(start + 1, source.indexOf('\n}\n', start + 1) + 2);
}

// The build sources the shared digest owner; the replay runs the real one.
const NETWORK_RETRY = fs.readFileSync(
	path.join(ROOT, 'static/ergopti_plus/macos/modules/llm/network-retry.sh'),
	'utf8'
);

const pin = BUILD.match(/^HAMMERSPOON_SHA256="\$\{HAMMERSPOON_SHA256:-([0-9a-f]{64})\}"$/m)?.[1];
const OFFICIAL = Buffer.from('official Hammerspoon release bytes');
const OFFICIAL_SHA = crypto.createHash('sha256').update(OFFICIAL).digest('hex');

check('the pin sits beside the version and every copy of it agrees', () => {
	assert(pin, 'HAMMERSPOON_SHA256 must be pinned next to HAMMERSPOON_VERSION');
	assert(BUILD.indexOf('HAMMERSPOON_SHA256=') > BUILD.indexOf('HAMMERSPOON_VERSION='));
	const cold = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_cold_bootstrap.py'),
		'utf8'
	);
	assert.equal(cold.match(/^HAMMERSPOON_ARCHIVE_SHA256 = "([0-9a-f]{64})"$/m)?.[1], pin);
	const workflow = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-macos.yml'), 'utf8');
	assert.match(
		workflow,
		new RegExp(`printf '%s  %s\\\\n' ${pin} "\\$archive" \\| shasum -a 256 --check`)
	);
});

check('the cache lives outside the directory every build wipes', () => {
	assert.match(BUILD, /^BUILD_DIR="\$REPO_ROOT\/build\/macos"$/m);
	assert.match(BUILD, /^HAMMERSPOON_CACHE_DIR="\$REPO_ROOT\/build\/cache\/hammerspoon"$/m);
	assert.match(shellFunction('clean_build_dir'), /rm -rf "\$BUILD_DIR"/);
	assert.match(shellFunction('download_hammerspoon'), /local cache_dir="\$HAMMERSPOON_CACHE_DIR"/);
	// The cold receiver verifies the zip the build kept, so it reads the same
	// folder: fc39ea4b95 moved the cache and the receiver still read the old one.
	const cold = fs.readFileSync(
		path.join(ROOT, 'tools/diagnostics/macos_cold_bootstrap.py'),
		'utf8'
	);
	assert.match(cold, /^HAMMERSPOON_CACHE = REPOSITORY \/ "build\/cache\/hammerspoon"$/m);
	assert.match(cold, /^ {4}archive = HAMMERSPOON_CACHE \/ "Hammerspoon-1\.1\.1\.zip"$/m);
	assert.doesNotMatch(cold, /app\.parent \/ "cache\//, 'the wiped build folder holds no cache');
	const ignore = fs.readFileSync(path.join(ROOT, '.gitignore'), 'utf8');
	assert.match(ignore, /^\/build\/$/m, 'the cache must stay out of Git');
});

if (process.platform === 'win32') {
	console.log('SKIP behavioural replay: the macOS build script is not run on Windows.');
} else {
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-hs-cache-'));
	const nodeBin = JSON.stringify(process.execPath);
	/** Runs clean_build_dir then download_hammerspoon with the given served bytes. */
	const build = (served, digest = OFFICIAL_SHA) => {
		const body = path.join(scratch, 'served.zip');
		fs.writeFileSync(body, served);
		const result = spawnSync(
			bashExecutable(),
			[
				'-c',
				`set -euo pipefail
REPO_ROOT=${JSON.stringify(scratch)}
LOG="$REPO_ROOT/calls.log"
log() { printf '%s\\n' "$*" >&2; }
fail() { printf 'ERROR: %s\\n' "$*" >&2; exit 1; }
curl() { local out=""; while [ "$#" -gt 0 ]; do [ "$1" = -o ] && out="$2"; shift; done; echo curl >> "$LOG"; cp ${JSON.stringify(body)} "$out"; }
unzip() { mkdir -p "$4/Hammerspoon.app"; }
shasum() { ${nodeBin} -e 'const c=require("node:crypto"),f=require("node:fs");process.stdout.write(c.createHash("sha256").update(f.readFileSync(process.argv[1])).digest("hex")+"  "+process.argv[1]+"\\n")' "$3"; }
ERGOPTI_HOST_GITHUB=github.com HAMMERSPOON_VERSION=1.1.1 HAMMERSPOON_SHA256=${digest}
BUILD_DIR="$REPO_ROOT/build/macos"
HAMMERSPOON_CACHE_DIR="$REPO_ROOT/build/cache/hammerspoon"
${shellFunction('clean_build_dir')}
${shellFunction('sha256_file_digest', NETWORK_RETRY)}
${shellFunction('hammerspoon_zip_matches')}
${shellFunction('download_hammerspoon')}
clean_build_dir
download_hammerspoon`
			],
			{ encoding: 'utf8', timeout: 30000 }
		);
		const log = path.join(scratch, 'calls.log');
		const downloads = fs.existsSync(log)
			? fs.readFileSync(log, 'utf8').split('\n').filter(Boolean).length
			: 0;
		if (fs.existsSync(log)) fs.rmSync(log);
		return { ...result, downloads };
	};
	const cached = path.join(scratch, 'build/cache/hammerspoon/Hammerspoon-1.1.1.zip');
	try {
		check('a first build downloads, a second reuses the verified cache after the wipe', () => {
			const first = build(OFFICIAL);
			assert.equal(first.status, 0, first.stderr);
			assert.equal(first.downloads, 1);
			assert.match(first.stderr, /Downloading Hammerspoon 1\.1\.1/);
			assert.deepEqual(fs.readFileSync(cached), OFFICIAL);
			const second = build(Buffer.from('a server answer that must not be fetched'));
			assert.equal(second.status, 0, second.stderr);
			assert.equal(second.downloads, 0, 'a verified cache must not be downloaded again');
			assert.match(second.stderr, /Using cached Hammerspoon 1\.1\.1/);
		});

		check('a truncated cache is refused and fetched again', () => {
			fs.writeFileSync(cached, OFFICIAL.subarray(0, 5));
			const result = build(OFFICIAL);
			assert.equal(result.status, 0, result.stderr);
			assert.equal(result.downloads, 1);
			assert.match(result.stderr, /does not match the pinned SHA-256; downloading it again/);
			assert.deepEqual(fs.readFileSync(cached), OFFICIAL);
		});

		check('a download with another digest fails and is never cached', () => {
			fs.rmSync(cached);
			const result = build(Buffer.from('tampered release bytes'));
			assert.notEqual(result.status, 0);
			assert.match(result.stderr, /does not match the pinned SHA-256/);
			assert.equal(fs.existsSync(cached), false, 'a refused download must not be published');
			assert.deepEqual(fs.readdirSync(path.dirname(cached)), [], 'no partial file may remain');
		});
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}
console.log(
	`[OK] macOS Hammerspoon cache survives rebuilds and admits only the pinned zip (${checks} checks).`
);
