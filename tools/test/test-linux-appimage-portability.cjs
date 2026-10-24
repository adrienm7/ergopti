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
 * 5. A musl system or an older glibc is refused in words by a plain-sh AppRun
 *    preflight, before the loader fails or bash is needed.
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
assert.ok(
	containerSmokeBody.includes('x11-utils xdotool'),
	'the smoke clicks the icon as the catalogue does'
);
assert.ok(
	container.includes('/"Ergopti\\+": \\(/') && container.includes('Map State: IsViewable'),
	'the no-keyboard status window the catalogue screenshots is on screen'
);
assert.ok(
	/for button in 1 3; do\n\t\txdotool mousemove [^\n]* click "\$button"\n\t\tif ! wait_for_menu_popups 1; then/.test(
		container
	),
	'a left and a right click on the docked icon each map the tray menu'
);
assert.ok(
	container.includes("grep -q 'Override Redirect State: yes'"),
	'a menu is an override-redirect popup'
);
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

// A system whose C library cannot load the image is refused in words, in the
// user's language, before anything glibc-linked runs. On glibc 2.31 the bundled
// luajit died with "version `GLIBC_2.34' not found"; on Alpine, AppRun itself
// died with "No such file or directory": musl systems have no bash.
const Preflight = require('../build/render-appimage-libc-preflight.cjs');
const appRunSource = builder.slice(
	builder.indexOf('cat > "$APPDIR/AppRun" << \'APPRUN_EOF\'\n') +
		'cat > "$APPDIR/AppRun" << \'APPRUN_EOF\'\n'.length,
	builder.indexOf('\nAPPRUN_EOF\n') + 1
);
assert.ok(appRunSource.startsWith('#!/bin/sh\n'), 'AppRun starts without bash, which musl lacks');
const sourcedAt = appRunSource.indexOf('\n. "$HERE/usr/lib/ergopti/libc-preflight.sh"\n');
assert.ok(sourcedAt > 0, 'AppRun sources the preflight');
assert.ok(
	sourcedAt < appRunSource.indexOf('exec bash "$0" "$@"') &&
		sourcedAt < appRunSource.indexOf('network-runtime-env.sh') &&
		sourcedAt < appRunSource.indexOf('exec "$LUAJIT_BIN"'),
	'the preflight runs before bash and before any bundled program'
);
assert.ok(
	builder.includes(
		'\nnode "$SCRIPT_DIR/render-appimage-libc-preflight.cjs" "$APPDIR_LIB/libc-preflight.sh"\n'
	),
	'the packager renders the preflight into the image'
);
// The catalogue keys the preflight reads (tools/build is outside the
// translation audit's usage scan, which skips every build directory).
assert.deepEqual(Preflight.MESSAGE_KEYS, {
	title: 'startup.linux_appimage_libc_title',
	musl: 'startup.linux_appimage_musl_body',
	old: 'startup.linux_appimage_old_glibc_body'
});
const preflightLocales = Preflight.readLocales();
assert.equal(preflightLocales.length, 21, 'every shipped locale reads the refusal');
const preflight = Preflight.render(preflightLocales);
assert.ok(
	preflight.includes('\nergopti_glibc_required_major=2\nergopti_glibc_required_minor=35\n')
);
if (process.platform === 'linux') {
	const { spawnSync } = require('node:child_process');
	const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-libc-preflight-'));
	try {
		const appDir = path.join(sandbox, 'AppDir');
		const write = (relative, text, mode = 0o755) => {
			fs.mkdirSync(path.dirname(path.join(appDir, relative)), { recursive: true });
			fs.writeFileSync(path.join(appDir, relative), text, { mode });
		};
		write('AppRun', appRunSource);
		write('usr/lib/ergopti/libc-preflight.sh', preflight, 0o644);
		write(
			'usr/lib/ergopti/network-runtime-env.sh',
			'# The bundled environment, not under test.\n',
			0o644
		);
		write('usr/bin/luajit', '#!/bin/sh\necho "launched $*"\n');
		// Only what AppRun needs before the preflight, and a getconf that answers
		// as the system under test does: no bash, as on Alpine.
		const bin = path.join(sandbox, 'bin');
		fs.mkdirSync(bin);
		for (const tool of ['sh', 'readlink', 'dirname']) {
			const found = spawnSync('sh', ['-c', `command -v ${tool}`], { encoding: 'utf8' });
			assert.equal(found.status, 0, `${tool} is on this host`);
			fs.symlinkSync(found.stdout.trim(), path.join(bin, tool));
		}
		fs.writeFileSync(
			path.join(bin, 'getconf'),
			'#!/bin/sh\n[ "$1" = GNU_LIBC_VERSION ] && [ -n "$FAKE_LIBC" ] || exit 1\necho "$FAKE_LIBC"\n',
			{ mode: 0o755 }
		);
		const launch = (libc, language, withBash) => {
			const env = { PATH: bin, FAKE_LIBC: libc, LANG: language };
			if (withBash) {
				const bash = spawnSync('sh', ['-c', 'command -v bash'], { encoding: 'utf8' });
				fs.symlinkSync(bash.stdout.trim(), path.join(bin, 'bash'));
			}
			try {
				return spawnSync(path.join(appDir, 'AppRun'), [], { encoding: 'utf8', env });
			} finally {
				if (withBash) fs.unlinkSync(path.join(bin, 'bash'));
			}
		};
		const musl = launch('', 'C', false);
		assert.equal(musl.status, Preflight.REFUSAL_EXIT, musl.stderr);
		assert.equal(
			musl.stderr,
			'Ergopti+ cannot start on this system\nThis AppImage needs the GNU C library (glibc) 2.35 or newer. ' +
				'This system uses another C library, such as musl on Alpine Linux, which cannot run programs built for glibc.\n'
		);
		assert.equal(musl.stdout, '');
		const old = launch('glibc 2.31', 'fr_FR.UTF-8', false);
		assert.equal(old.status, Preflight.REFUSAL_EXIT, old.stderr);
		assert.match(old.stderr, /^Ergopti\+ ne peut pas démarrer sur ce système\n/);
		assert.match(old.stderr, /glibc\) 2\.35 ou plus récente, et ce système a la glibc 2\.31\./);
		// 2.9 is older than 2.35: the comparison is numeric.
		assert.equal(launch('glibc 2.9', 'de_DE', false).status, Preflight.REFUSAL_EXIT);
		assert.match(launch('glibc 2.34', 'xx_XX', false).stderr, /this system has glibc 2\.34\./);
		for (const libc of ['glibc 2.35', 'glibc 2.43', 'glibc 3.0']) {
			const admitted = launch(libc, 'en_US.UTF-8', true);
			assert.equal(admitted.status, 0, `${libc}: ${admitted.stderr}`);
			assert.equal(admitted.stderr, '');
			assert.match(
				admitted.stdout,
				/^launched \S+\/usr\/lib\/ergopti\/ergopti_hotstrings\.lua --tray\n$/
			);
		}
	} finally {
		fs.rmSync(sandbox, { recursive: true, force: true });
	}
}
passed++;

// One asset name, with no "linux" in it, wherever the release names it. The
// AppImage catalog (appimage.github.io, PR #10422) refuses an AppImage whose
// file name contains "Linux" in any case: ErgoptiPlus-linux-x86_64.AppImage was
// rejected for v1.0.1. The other Linux assets (.deb, .rpm, .flatpak) keep their
// "linux-" prefix; only the AppImage must stay without it.
for (const [relative, minimum] of [
	['.github/workflows/ci-linux.yml', 2],
	['.github/workflows/ci-release.yml', 3],
	['src/lib/js/getGitHubRelease.js', 1],
	['src/routes/ergopti-plus/Hero.svelte', 0],
	['src/routes/ergopti-plus/Platforms.svelte', 0],
	['src/routes/ergopti-plus/StickyCta.svelte', 0],
	['tools/test/browser/site-artifact-smoke.playwright.cjs', 1],
	['tools/test/test-site-github-release.cjs', 1],
	['tools/build/build-linux-appimage.sh', 0],
	['tools/build/appimage-oldest-lts.sh', 0],
	[
		'static/ergopti_plus/linux/tests/unit/modules/updater/check/test_updater_manager_module_loads_without.lua',
		1
	]
]) {
	const text = read(relative);
	for (const name of text.match(/[A-Za-z0-9_.${}-]+\.AppImage\b/gi) ?? []) {
		assert.ok(
			!/linux/i.test(name),
			`${relative} names the AppImage "${name}"; the AppImage catalog refuses "linux" in it`
		);
	}
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

// Update information: the AppImage embeds it, the .zsync is published beside it
// under the release asset name, and the verifier refuses anything else.
const Update = require('../build/check-appimage-update.cjs');

/** A minimal ELF64 little-endian image with one `.upd_info` section. */
function elfWith(updateInformation, sectionName = Update.UPDATE_SECTION) {
	const names = Buffer.from(`\0${sectionName}\0.shstrtab\0`, 'latin1');
	const info = Buffer.alloc(1024);
	info.write(updateInformation, 'utf8');
	const header = Buffer.alloc(64);
	Buffer.from([0x7f, 0x45, 0x4c, 0x46, 2, 1, 1]).copy(header);
	const namesAt = 64;
	const infoAt = namesAt + names.length;
	const tableAt = infoAt + info.length;
	header.writeBigUInt64LE(BigInt(tableAt), 0x28);
	header.writeUInt16LE(64, 0x3a);
	header.writeUInt16LE(3, 0x3c);
	header.writeUInt16LE(2, 0x3e);
	const entry = (name, offset, size) => {
		const raw = Buffer.alloc(64);
		raw.writeUInt32LE(name, 0);
		raw.writeBigUInt64LE(BigInt(offset), 0x18);
		raw.writeBigUInt64LE(BigInt(size), 0x20);
		return raw;
	};
	return Buffer.concat([
		header,
		names,
		info,
		entry(0, 0, 0),
		entry(1, infoAt, info.length),
		entry(1 + sectionName.length + 1, namesAt, names.length)
	]);
}

/** A zsync file whose header matches an image of `length` bytes. */
function zsyncFor(length, overrides = {}) {
	const fields = {
		zsync: '0.6.2',
		Filename: Update.APPIMAGE_ASSET,
		MTime: 'Fri, 23 Oct 2026 17:00:04 +0000',
		Blocksize: '2048',
		Length: String(length),
		'Hash-Lengths': '2,2,4',
		URL: Update.APPIMAGE_ASSET,
		'SHA-1': '0123456789abcdef0123456789abcdef01234567',
		...overrides
	};
	const text = Object.entries(fields)
		.filter(([, value]) => value !== null)
		.map(([key, value]) => `${key}: ${value}`)
		.join('\n');
	return Buffer.concat([Buffer.from(`${text}\n\n`, 'latin1'), Buffer.from([1, 2, 3, 4])]);
}

assert.equal(
	Update.UPDATE_INFORMATION,
	'gh-releases-zsync|adrienm7|ergopti|latest|ErgoptiPlus-*x86_64.AppImage.zsync'
);
assert.equal(Update.APPIMAGE_ASSET, APPIMAGE_ASSET);
assert.ok(
	Update.globMatches(
		Update.parseUpdateInformation(Update.UPDATE_INFORMATION).pattern,
		Update.ZSYNC_ASSET
	)
);
assert.ok(!Update.globMatches('ErgoptiPlus-*x86_64.AppImage.zsync', 'ErgoptiPlus-linux-amd64.deb'));
assert.throws(() => Update.parseUpdateInformation('zsync|a|b|c|d'), /gh-releases-zsync/);
const image = elfWith(Update.UPDATE_INFORMATION);
assert.equal(Update.readEmbeddedUpdateInformation(image), Update.UPDATE_INFORMATION);
assert.deepEqual(Update.verify(image, zsyncFor(image.length)), []);
for (const [what, badImage, badZsync, expected] of [
	['an AppImage built without -u', elfWith(''), zsyncFor(image.length), /differs from/],
	[
		'no update section at all',
		elfWith('x', '.other'),
		zsyncFor(image.length),
		/no \.upd_info section/
	],
	[
		'another repository',
		elfWith('gh-releases-zsync|someone|else|latest|*.zsync'),
		zsyncFor(image.length),
		/differs from/
	],
	[
		'a zsync made before the rename',
		image,
		zsyncFor(image.length, { URL: 'Ergopti-1.0.0-x86_64.AppImage' }),
		/URL is/
	],
	[
		'a zsync for another file name',
		image,
		zsyncFor(image.length, { Filename: 'x.AppImage' }),
		/Filename is/
	],
	['a zsync of another size', image, zsyncFor(image.length + 1), /Length/],
	['a zsync without a hash', image, zsyncFor(image.length, { 'SHA-1': null }), /SHA-1/],
	[
		'a zsync with no blocks',
		image,
		Buffer.from(zsyncFor(image.length).subarray(0, -4)),
		/no block checksums/
	],
	['a zsync with no header end', image, Buffer.from('zsync: 0.6.2\n'), /terminating blank line/],
	['a file that is not ELF', Buffer.alloc(100), zsyncFor(100), /not an ELF64/]
]) {
	const problems = Update.verify(badImage, badZsync);
	assert.ok(
		problems.some((problem) => expected.test(problem)),
		`${what}: ${problems.join(' | ')}`
	);
}
passed++;

// The packager embeds the update information through the single source, builds
// the AppImage under its release name and refuses a missing or wrong .zsync;
// the workflows publish the .zsync and the release refuses to go without it.
const packager = read('tools/build/build-linux-appimage.sh');
assert.match(packager, /--print-update-information/);
assert.match(packager, /appimagetool -u "\$UPDATE_INFORMATION" "\$APPDIR" "\$APPIMAGE_ASSET"/);
assert.match(packager, /node "\$APPIMAGE_CHECK" "\$APPIMAGE_FILE" "\$APPIMAGE_FILE\.zsync"/);
assert.ok(
	!/Ergopti-\$\{VERSION\}/.test(packager),
	'the AppImage keeps the release name from the start'
);
const ZSYNC = `${APPIMAGE_ASSET}.zsync`;
const linuxWorkflow = read('.github/workflows/ci-linux.yml');
assert.ok(
	linuxWorkflow.includes(`            build/linux/${ZSYNC}\n`),
	'the assets-linux artifact uploads the .zsync'
);
assert.ok(
	linuxWorkflow.includes(`build/linux/${ZSYNC}; do`),
	'the packaging step demands the .zsync'
);
assert.ok(
	read('.github/workflows/ci-release.yml').includes(`              ${ZSYNC} \\\n`),
	'the release refuses to publish without the .zsync'
);
passed++;

console.log(`Linux AppImage portability: ${passed} checks passed.`);
