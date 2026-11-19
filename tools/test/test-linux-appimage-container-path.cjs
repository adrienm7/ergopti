// tools/test/test-linux-appimage-container-path.cjs

/**
 * ==============================================================================
 * MODULE: Linux AppImage Container PATH Test
 * DESCRIPTION:
 * The AppImage is built in the oldest supported LTS container
 * (tools/build/appimage-oldest-lts.sh), and stage-linux-network-runtime.py
 * takes the owned programs (luajit, curl, sqlite3, openssl, zstd) from that
 * container's PATH. The build used to mount the runner's whole node prefix,
 * /usr/local on a GitHub runner, and front its bin/ on that PATH: the runner's
 * own /usr/local/bin/zstd, built from source on the newer runner, was staged
 * as the owned zstd, and ldd refused it ("Native packaging dependency needs a
 * newer C library than the build host's") on every Linux build. A directory
 * the build fronts on the container's PATH may receive the node executable
 * alone, never a runner directory; this check runs before any build job.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { REPO_ROOT } = require('../lib/paths.cjs');

const SCRIPT = path.join(REPO_ROOT, 'tools', 'build', 'appimage-oldest-lts.sh');

/** The section of a script between two markers, both required. */
function section(text, start, end) {
	const from = text.indexOf(start);
	const to = text.indexOf(end, from);
	assert.ok(from !== -1 && to !== -1, `${start} ... ${end} is present`);
	return text.slice(from, to);
}

/** Every mount of the runner a fronted PATH directory would reach, by directory. */
function reachingMounts(text) {
	const build = section(text, 'container_build() {', 'container_smoke() {');
	const run = section(text, '\tbuild)\n', '\tsmoke)\n');
	const fronted = [...build.matchAll(/export PATH="([^":$]+):\$PATH"/g)].map((match) => match[1]);
	assert.ok(fronted.length > 0, 'the container build fronts the node directory on PATH');
	const targets = [...run.matchAll(/-v "[^"]*:(\/[^":]*)(?::ro)?"/g)].map((match) => match[1]);
	return fronted.map((directory) => ({
		directory,
		reaching: targets.filter(
			(target) =>
				target === directory ||
				target.startsWith(`${directory}/`) ||
				directory.startsWith(`${target}/`)
		)
	}));
}

/** True when only the node executable is mounted where the container PATH starts. */
function nodeOnly(text) {
	return reachingMounts(text).every(
		({ directory, reaching }) => reaching.length === 1 && reaching[0] === `${directory}/node`
	);
}

// The checker itself: the mount that staged the runner's zstd is refused.
const failing =
	'container_build() {\n\texport PATH="/opt/node/bin:$PATH"\n}\ncontainer_smoke() {\n}\n' +
	'\tbuild)\n\t\tdocker run -v "$PROJECT_ROOT:/src" -v "$node_root:/opt/node:ro" -w /src\n\tsmoke)\n';
assert.equal(nodeOnly(failing), false, 'a mounted runner prefix is refused');
assert.equal(
	nodeOnly(
		failing.replace('"$node_root:/opt/node:ro"', '"$node_executable:/opt/node/bin/node:ro"')
	),
	true,
	'the node executable alone is admitted'
);

const text = fs.readFileSync(SCRIPT, 'utf8');
for (const { directory, reaching } of reachingMounts(text))
	assert.deepEqual(
		reaching,
		[`${directory}/node`],
		`only the node executable is mounted where the container PATH starts (${directory})`
	);
console.log('[OK] AppImage container build: its PATH fronts the runner node executable alone.');
