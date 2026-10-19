// tools/test/test-linux-appimage-portability.cjs

/**
 * ==============================================================================
 * MODULE: Linux AppImage Portability
 * DESCRIPTION:
 * Pins what the AppImage catalogue test checks: every bundled ELF file loads on
 * the oldest supported Ubuntu LTS, the image is built and launched on it, and
 * its asset name carries no "linux".
 *
 * FEATURES & RATIONALE:
 * 1. Built on ubuntu-latest, the bundled luajit needed GLIBC_2.38 and died on
 *    Ubuntu 22.04 (glibc 2.35) before any tray icon appeared. The ceiling check
 *    must refuse that exact readelf output and admit 2.35.
 * 2. The build and the launch run in the container the check names, so moving
 *    the build back onto the runner fails here, not in the catalogue.
 * 3. The catalogue warns on a name containing "linux": one name, everywhere
 *    the release, its notes and the website refer to it.
 * 4. The catalogue's runner has GTK 3 and an XEmbed tray but no libayatana:
 *    the image bundles the tray library without GTK, and the smoke replays the
 *    catalogue's stalonetray check on a host without libayatana.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');

const ROOT = path.resolve(__dirname, '..', '..');
const Ceiling = require('../build/check-elf-glibc-ceiling.cjs');

const APPIMAGE_ASSET = 'ErgoptiPlus-x86_64.AppImage';
let passed = 0;

function read(relative) {
	return fs.readFileSync(path.join(ROOT, relative), 'utf8');
}

// readelf --version-info --wide of the v1.0.1 luajit, reduced to its needs.
const LUAJIT_NOBLE = [
	"Version symbols section '.gnu.version' contains 3 entries:",
	'  000:   0 (*local*)       2 (GLIBC_2.2.5)   3 (GLIBC_2.38)',
	'',
	"Version needs section '.gnu.version_r' contains 2 entries:",
	' Addr: 0x0000000000001a10  Offset: 0x001a10  Link: 7 (.dynstr)',
	'  000000: Version: 1  File: libm.so.6  Cnt: 2',
	'  0x0010:   Name: GLIBC_2.29  Flags: none  Version: 5',
	'  0x0020:   Name: GLIBC_2.2.5  Flags: none  Version: 4',
	'  0x0030: Version: 1  File: libc.so.6  Cnt: 2',
	'  0x0040:   Name: GLIBC_2.38  Flags: none  Version: 3',
	'  0x0050:   Name: GLIBC_2.34  Flags: none  Version: 2',
	''
].join('\n');

assert.deepEqual(Ceiling.parseVersionNeeds(LUAJIT_NOBLE), [
	{ file: 'libm.so.6', name: 'GLIBC_2.29' },
	{ file: 'libm.so.6', name: 'GLIBC_2.2.5' },
	{ file: 'libc.so.6', name: 'GLIBC_2.38' },
	{ file: 'libc.so.6', name: 'GLIBC_2.34' }
]);
assert.deepEqual(Ceiling.parseVersionNeeds('There are no version information sections.\n'), []);
passed++;

assert.equal(Ceiling.GLIBC_CEILING, '2.35');
for (const [name, exceeds] of [
	['GLIBC_2.38', true],
	['GLIBC_2.36', true],
	['GLIBC_3.0', true],
	['GLIBC_PRIVATE', true],
	['GLIBC_2.35', false],
	['GLIBC_2.34', false],
	['GLIBC_2.2.5', false],
	['GLIBC_2.3.4', false],
	['GCC_7.0.0', false],
	['OPENSSL_3.2.0', false]
]) {
	assert.equal(Ceiling.exceedsCeiling(name), exceeds, name);
}
passed++;

// A tree: the v1.0.1 luajit, one admissible library, a non-ELF script and a
// symbolic link that must not be followed out of the tree.
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-glibc-ceiling-'));
try {
	const elf = Buffer.concat([Buffer.from([0x7f, 0x45, 0x4c, 0x46]), Buffer.alloc(16)]);
	fs.mkdirSync(path.join(scratch, 'usr/bin'), { recursive: true });
	fs.mkdirSync(path.join(scratch, 'usr/lib'), { recursive: true });
	fs.writeFileSync(path.join(scratch, 'usr/bin/luajit'), elf);
	fs.writeFileSync(path.join(scratch, 'usr/lib/libuv.so.1'), elf);
	fs.writeFileSync(path.join(scratch, 'AppRun'), '#!/bin/bash\n');
	const outputs = {
		luajit: LUAJIT_NOBLE,
		'libuv.so.1': LUAJIT_NOBLE.replaceAll('GLIBC_2.38', 'GLIBC_2.32')
	};
	const reads = [];
	const readVersions = (file) => {
		reads.push(path.basename(file));
		return outputs[path.basename(file)];
	};
	const result = Ceiling.checkTree([scratch], readVersions);
	assert.deepEqual(reads.sort(), ['libuv.so.1', 'luajit'], 'only ELF files are read');
	assert.equal(result.checked.length, 2);
	assert.deepEqual(
		result.violations.map((violation) => [path.basename(violation.path), violation.name]),
		[['luajit', 'GLIBC_2.38']]
	);
	outputs.luajit = LUAJIT_NOBLE.replaceAll('GLIBC_2.38', 'GLIBC_2.35');
	assert.deepEqual(Ceiling.checkTree([scratch], readVersions).violations, []);
	const empty = path.join(scratch, 'empty');
	fs.mkdirSync(empty);
	assert.equal(Ceiling.checkTree([empty], readVersions).checked.length, 0);
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
passed++;

// The packager refuses its own image, and CI builds and launches it in the
// container of the ceiling's LTS.
const builder = read('tools/build/build-linux-appimage.sh');
assert.match(builder, /\nnode "\$SCRIPT_DIR\/check-elf-glibc-ceiling\.cjs" "\$APPDIR"\n/);
assert.ok(
	builder.indexOf('check-elf-glibc-ceiling.cjs" "$APPDIR"') <
		builder.indexOf('ARCH="$ARCH" appimagetool'),
	'the ceiling is checked before the image is packaged'
);
const stager = read('tools/build/stage-linux-network-runtime.py');
for (const library of ['libglib-2.0.so.0', 'libgio-2.0.so.0', 'libstdc++.so.6']) {
	assert.ok(stager.includes(`"${library}"`), `${library} is left to the recipient`);
}
// v1.0.3 exited in the catalogue with "libayatana-appindicator3 is missing":
// its runner has GTK 3 and an XEmbed tray but no libayatana. The image carries
// the tray library and its non-GTK dependencies, never GTK itself.
const trayList = stager.slice(
	stager.indexOf('TRAY_LIBRARIES = frozenset('),
	stager.indexOf('\n)\n', stager.indexOf('TRAY_LIBRARIES = frozenset('))
);
assert.ok(stager.includes('TRAY_ROOT = "libayatana-appindicator3.so.1"'));
for (const library of [
	'libayatana-indicator3.so.7',
	'libayatana-ido3-0.4.so.0',
	'libdbusmenu-glib.so.4',
	'libdbusmenu-gtk3.so.4'
]) {
	assert.ok(trayList.includes(`"${library}"`), `${library} is bundled with the tray`);
}
assert.ok(
	!/gtk-3|gdk-3|cairo|pango/.test(trayList.replace('dbusmenu-gtk3', '')),
	"GTK stays the recipient's"
);
assert.match(
	stager,
	/for name, source in sorted\(tray_sources\(\)\.items\(\)\):\n\s+copy_unique\(source, prefix \/ "lib" \/ name, owners\)/
);
const container = read('tools/build/appimage-oldest-lts.sh');
const containerBuildBody = container.slice(
	container.indexOf('container_build() {'),
	container.indexOf('container_smoke() {')
);
const containerSmokeBody = container.slice(
	container.indexOf('container_smoke() {'),
	container.indexOf('user_smoke() {')
);
assert.ok(
	containerBuildBody.includes('libayatana-appindicator3-1'),
	'the build host has the tray library'
);
assert.ok(
	!/apt_install[^\n]*(\\\n[^\n]*)*libayatana/.test(containerSmokeBody),
	'the smoke host lacks libayatana, as the catalogue does'
);
assert.ok(containerSmokeBody.includes('libgtk-3-0 stalonetray x11-utils'));
assert.ok(
	container.includes(
		'env -u DBUS_SESSION_BUS_ADDRESS xvfb-run -a bash "$SELF" xembed-in-display "$appimage"'
	),
	"the catalogue's XEmbed tray check runs without a session bus"
);
assert.ok(container.includes("grep -E '^ +0x' | grep -v ' 1x1+'"), 'an icon docked in stalonetray');
assert.ok(container.includes(`\nOLDEST_LTS_IMAGE="${Ceiling.OLDEST_LTS_IMAGE}"\n`));
assert.ok(container.includes('\n\tbash tools/build/build-linux-appimage.sh\n'));
assert.ok(container.includes('unshare --net -- runuser -u "$SMOKE_USER"'), 'launched offline');
assert.ok(
	container.includes('xvfb-run -a "$appimage"'),
	'launched with no arguments, as a desktop does'
);
assert.ok(container.includes('runuser -u "$SMOKE_USER"'), 'launched outside the input group');
const workflow = read('.github/workflows/ci-linux.yml');
const packageJob = workflow.slice(
	workflow.indexOf('\n  package-linux:\n'),
	workflow.indexOf('\n  install-linux:\n')
);
const containerBuild = packageJob.indexOf('run: bash tools/build/appimage-oldest-lts.sh build\n');
assert.ok(containerBuild > packageJob.indexOf('run: bash tools/build/build-linux-driver.sh\n'));
assert.ok(
	containerBuild < packageJob.indexOf('tar -czf "build/linux/$LINUX_BUNDLE_ASSET"') &&
		containerBuild < packageJob.indexOf('bash tools/build/build-linux-deb.sh'),
	'every package is made from the bundle after its native backend is rebuilt'
);
assert.ok(
	!packageJob.includes('\n          bash tools/build/build-linux-appimage.sh\n'),
	'the AppImage is never built on the runner itself'
);
const installJob = workflow.slice(workflow.indexOf('\n  install-linux:\n'));
assert.ok(installJob.includes('node tools/build/check-elf-glibc-ceiling.cjs squashfs-root pkg'));
assert.ok(installJob.includes('run: bash tools/build/appimage-oldest-lts.sh smoke "$(find pkg'));
passed++;

// A machine without a CA bundle still starts the app: the environment used to
// return 1 there, and an offline sandbox without /etc/ssl never showed its tray.
const environment = read('tools/build/templates/linux-portable-runtime-env.sh');
const missingTrust = environment.slice(
	environment.indexOf('if [ "$ERGOPTI_SYSTEM_CA_FOUND" != true ]; then')
);
assert.ok(missingTrust.length < environment.length, 'the missing-bundle branch exists');
assert.ok(
	!/\b(return|exit)\b/.test(missingTrust.slice(0, missingTrust.indexOf('\n  fi\n'))),
	'a missing CA bundle must not stop the launch'
);
if (process.platform === 'linux') {
	const { spawnSync } = require('node:child_process');
	const { bashExecutable } = require('../lib/git-bash.cjs');
	const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-no-trust-'));
	try {
		const prefix = path.join(sandbox, 'usr');
		for (const name of [
			'bin/luajit',
			'bin/curl',
			'lib/lua/5.1/luv.so',
			'lib/gio/modules/libgiolibproxy.so',
			'share/glib-2.0/schemas/gschemas.compiled'
		]) {
			fs.mkdirSync(path.dirname(path.join(prefix, name)), { recursive: true });
			fs.writeFileSync(path.join(prefix, name), 'existence fixture, never executed');
		}
		const script = path.join(sandbox, 'environment.sh');
		fs.writeFileSync(
			script,
			environment.replace(
				/ERGOPTI_SYSTEM_CA_FILES=\([^)]*\)/,
				`ERGOPTI_SYSTEM_CA_FILES=("${path.join(sandbox, 'absent-bundle.crt')}")`
			)
		);
		const env = { ...process.env };
		for (const name of ['CURL_CA_BUNDLE', 'SSL_CERT_FILE', 'SSL_CERT_DIR']) delete env[name];
		const observed = spawnSync(
			bashExecutable(),
			[
				'-c',
				'set -euo pipefail; source "$1" "$2" "$3"; echo "started:${CURL_CA_BUNDLE:-none}"',
				'no-trust',
				script,
				prefix,
				path.join(prefix, 'lib/ergopti')
			],
			{ encoding: 'utf8', env }
		);
		assert.equal(observed.status, 0, observed.stderr);
		assert.equal(observed.stdout, 'started:none\n');
		assert.match(observed.stderr, /certificate bundle unavailable/);
	} finally {
		fs.rmSync(sandbox, { recursive: true, force: true });
	}
}
passed++;

// One asset name, with no "linux" in it, wherever the release names it.
for (const [relative, minimum] of [
	['.github/workflows/ci-linux.yml', 2],
	['.github/workflows/ci.yml', 3],
	['src/lib/js/getGitHubRelease.js', 1],
	['src/routes/ergopti-plus/Hero.svelte', 0],
	['src/routes/ergopti-plus/Platforms.svelte', 0],
	['src/routes/ergopti-plus/StickyCta.svelte', 0],
	['tools/test/browser/site-artifact-smoke.playwright.cjs', 1]
]) {
	const text = read(relative);
	assert.ok(
		!/ErgoptiPlus-linux-[A-Za-z0-9_]+\.AppImage/.test(text),
		`${relative} still names the old AppImage`
	);
	assert.ok(
		text.split(APPIMAGE_ASSET).length - 1 >= minimum,
		`${relative} names ${APPIMAGE_ASSET}`
	);
}
assert.ok(!/linux/i.test(APPIMAGE_ASSET));
passed++;

// The website's Linux buttons never point at "#": a release published before
// the rename has no asset by the new name, so they open its release page.
const releaseHelper = read('src/lib/js/getGitHubRelease.js');
assert.ok(releaseHelper.includes(`export const LINUX_APPIMAGE_ASSET = '${APPIMAGE_ASSET}';`));
assert.match(
	releaseHelper,
	/if \(!release\) return RELEASES_PAGE;\n\treturn release\.url\(name\) \?\? `\$\{RELEASES_PAGE\}\/tag\/\$\{encodeURIComponent\(release\.tag\)\}`;/
);
for (const relative of [
	'src/routes/ergopti-plus/Hero.svelte',
	'src/routes/ergopti-plus/Platforms.svelte',
	'src/routes/ergopti-plus/StickyCta.svelte'
]) {
	const text = read(relative);
	assert.ok(text.includes('assetUrlOrPage(ui.release, LINUX_APPIMAGE_ASSET)'), relative);
	assert.ok(!/AppImage'\) \?\? '#'/.test(text), `${relative} falls back to "#"`);
}
passed++;

console.log(`Linux AppImage portability: ${passed} checks passed.`);
