// tools/test/test-linux-launcher-deps.cjs

/**
 * ==============================================================================
 * MODULE: Linux Launcher Startup Guard
 * DESCRIPTION:
 * `static/ergopti_plus/linux/bin/ergopti-hotstrings` is the only thing standing
 * between a user who has installed the driver and a running daemon. It shipped
 * two defects that made it a wall instead of a door, and neither could be caught
 * by any Lua or AutoHotkey suite — a shell launcher belongs to no driver's test
 * runner, so it is guarded here.
 *
 * ROOT CAUSE 1 — A HARD FAILURE OVER A DEPENDENCY THE PROJECT REMOVED.
 * The launcher collected missing commands and exited 1 with
 * "Erreur : dépendances manquantes". `ydotool` was on that list, while
 * install.sh deliberately does NOT install it (the daemon writes /dev/uinput
 * itself; ydotool assumed a US layout, needed a root daemon and forked once per
 * event). So the supported install path produced a machine the launcher refused
 * to start on, and the user was told to install a package the driver stopped
 * using. NEITHER LIST IS HARDCODED HERE: both are parsed out of the two scripts,
 * so the rule keeps holding when the dependencies change, and it fails the day
 * someone adds a hard requirement the installer does not satisfy.
 *
 * ROOT CAUSE 2 — AN EXPORTED PATH TO A DIRECTORY THAT DOES NOT EXIST.
 * The launcher exported LUA_PATH over `${ERGOPTI_ROOT}/shared/lua`. The tree is
 * `_shared`, with an underscore, everywhere else — install.sh, the package
 * builder, the repo. It went unnoticed for so long because the daemon rebuilds
 * package.path from its own location before requiring anything, so the broken
 * entry was never the one that resolved a module: the export was decoration that
 * looked load-bearing. Every shared-tree path the launcher composes is therefore
 * resolved here and checked to exist, rather than read.
 *
 * The parses are floored: a regex that stopped matching would find nothing and
 * pass over nothing.
 *
 * ROOT CAUSE 3 — LIVE XKB WAS DECLARED OPTIONAL.
 * Capture resolves every evdev event through libxkbcommon and refuses to grab a
 * keyboard without it. A package that lists the library only as a recommendation
 * can therefore install successfully and ship a daemon that correctly refuses
 * to start. Each package recipe is checked against its native hard-dependency
 * syntax; PATH-only exposure in Nix is not accepted in place of the shared
 * library path used by LuaJIT FFI.
 *
 * ROOT CAUSE 4 — THE STANDALONE KANATA BOOTSTRAP WAS NOT A LINUX INSTALLER.
 * Its x86_64 URL named an obsolete unarchived asset under the mutable `latest`
 * alias, while its ARM branch downloaded a macOS executable. Download failures
 * and invalid payloads then returned success, leaving a supported installation
 * without the launcher's hard dependency. The guard below requires a pinned,
 * checksummed Linux archive, fail-closed architecture handling, object and
 * version validation, and atomic publication after every validation step.
 *
 * ROOT CAUSE 5 — THREE PACKAGE COLUMNS PRETENDED TO COVER SIX MANAGERS.
 * zypper reused Fedora names while apk and xbps reused Arch names, so Alpine
 * requested `libxkbcommon` instead of the package that actually owns xkbcli.
 * A package-manager exit code was then accepted without re-probing the required
 * command or SONAME. The table and behavioral fixture below require every
 * manager/capability pair and prove that a false-success installer is rejected.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const LAUNCHER = path.join(DRIVER, 'bin', 'ergopti-hotstrings');
const INSTALLER = path.join(DRIVER, 'install.sh');
const DEB_BUILDER = path.join(ROOT, 'tools', 'build', 'build-linux-deb.sh');
const RPM_BUILDER = path.join(ROOT, 'tools', 'build', 'build-linux-rpm.sh');
const PKGBUILD = path.join(ROOT, 'tools', 'build', 'PKGBUILD');
const NIX_FLAKE = path.join(ROOT, 'tools', 'build', 'nix', 'flake.nix');

const errors = [];

/** Reads a tracked script, or records why the whole guard cannot run. */
function readScript(abs, label) {
	if (!fs.existsSync(abs)) {
		errors.push(
			`${label} is missing at ${path.relative(ROOT, abs).split(path.sep).join('/')} — it moved, and this guard no longer covers it`
		);
		return '';
	}
	return fs.readFileSync(abs, 'utf8');
}

/** Drops whole-line shell comments so prose about a tool never counts as a use. */
function withoutComments(src) {
	return src
		.split(/\r?\n/)
		.filter((line) => !/^\s*#/.test(line))
		.join('\n');
}

const launcherSrc = readScript(LAUNCHER, 'the Linux launcher');
const installerSrc = readScript(INSTALLER, 'the Linux installer');
const debSrc = readScript(DEB_BUILDER, 'the Debian package builder');
const rpmSrc = readScript(RPM_BUILDER, 'the RPM package builder');
const pkgbuildSrc = readScript(PKGBUILD, 'the Arch PKGBUILD');
const nixSrc = readScript(NIX_FLAKE, 'the Nix flake');
const launcherCode = withoutComments(launcherSrc);
const installerCode = withoutComments(installerSrc);

// =========================================================
// =========================================================
// ======= 1/ No Hard Failure The Installer Ignores =======
// =========================================================
// =========================================================

// The launcher's hard-failure list: every command probed inside _check_deps,
// which is the function that ends in `exit 1`.
const checkDepsBody = (launcherCode.match(/_check_deps\(\)\s*\{([\s\S]*?)\n\}/) || [])[1] || '';
const launcherDeps = [...checkDepsBody.matchAll(/_has\s+([A-Za-z0-9_.-]+)/g)].map((m) => m[1]);

if (!/exit\s+1/.test(checkDepsBody)) {
	errors.push(
		'_check_deps() no longer exits 1 — either the function was renamed (this guard then measures an ' +
			'empty string) or a missing dependency stopped being fatal, in which case say so here.'
	);
}
if (launcherDeps.length < 2) {
	errors.push(
		`parsed ${launcherDeps.length} hard dependency(ies) out of the launcher — expected at least 2. ` +
			'The parser drifted, and a subset check over nothing passes forever.'
	);
}

// What install.sh actually provides: every command handed to _check_or_install,
// plus every _install_<name> helper that probes `command -v <name>` (that is how
// kanata is installed — by its own function, not by the generic helper).
const installed = new Set(
	[...installerCode.matchAll(/_check_or_install\s+([A-Za-z0-9_.-]+)/g)].map((m) => m[1])
);
for (const m of installerCode.matchAll(/_install_([A-Za-z0-9_]+)\(\)/g)) {
	if (new RegExp(`command -v ${m[1]}\\b`).test(installerCode)) installed.add(m[1]);
}

if (installed.size < 3) {
	errors.push(
		`parsed ${installed.size} installed command(s) out of install.sh — expected at least 3; the parser drifted`
	);
}

const unmet = launcherDeps.filter((dep) => !installed.has(dep));
if (unmet.length > 0) {
	errors.push(
		`the launcher refuses to start without ${unmet.map((d) => `'${d}'`).join(', ')}, and install.sh does ` +
			'not install ' +
			(unmet.length > 1 ? 'them' : 'it') +
			'. A user who followed the supported install ' +
			'path then gets "Erreur : dépendances manquantes" and is told to install something the driver may ' +
			'no longer use. Either install it in install.sh, or stop making it fatal in the launcher.\n' +
			`      launcher requires: ${launcherDeps.join(', ')}\n` +
			`      install.sh installs: ${[...installed].sort().join(', ')}`
	);
}

const packageRows = [...installerCode.matchAll(
	/^\s*(apt|dnf|zypper|pacman|xbps|apk):([A-Za-z0-9_.-]+)\)\s+echo "([A-Za-z0-9_.+-]+)" ;;/gm
)];
const packageTable = new Map(packageRows.map((match) => [`${match[1]}:${match[2]}`, match[3]]));
const packageManagers = ['apt', 'dnf', 'zypper', 'pacman', 'xbps', 'apk'];
const requiredCapabilities = ['luajit', 'notify-send', 'unzip', 'sha256sum', 'xkbcli', 'libatspi.so.0'];
if (packageRows.length !== packageTable.size) {
	errors.push('the required dependency table contains a duplicate manager/capability row');
}
for (const manager of packageManagers) {
	for (const capability of requiredCapabilities) {
		if (!packageTable.has(`${manager}:${capability}`)) {
			errors.push(`the required dependency table has no ${manager}:${capability} row`);
		}
	}
}

const expectedPackages = new Map([
	['apt:luajit', 'luajit'],
	['apt:notify-send', 'libnotify-bin'],
	['apt:unzip', 'unzip'],
	['apt:sha256sum', 'coreutils'],
	['apt:xkbcli', 'libxkbcommon-tools'],
	['apt:libatspi.so.0', 'at-spi2-core'],
	['dnf:luajit', 'luajit'],
	['dnf:notify-send', 'libnotify'],
	['dnf:unzip', 'unzip'],
	['dnf:sha256sum', 'coreutils'],
	['dnf:xkbcli', 'libxkbcommon-utils'],
	['dnf:libatspi.so.0', 'at-spi2-core'],
	['zypper:luajit', 'luajit'],
	['zypper:notify-send', 'libnotify-tools'],
	['zypper:unzip', 'unzip'],
	['zypper:sha256sum', 'coreutils'],
	['zypper:xkbcli', 'libxkbcommon-tools'],
	['zypper:libatspi.so.0', 'at-spi2-core'],
	['pacman:luajit', 'luajit'],
	['pacman:notify-send', 'libnotify'],
	['pacman:unzip', 'unzip'],
	['pacman:sha256sum', 'coreutils'],
	['pacman:xkbcli', 'libxkbcommon'],
	['pacman:libatspi.so.0', 'at-spi2-core'],
	['xbps:luajit', 'LuaJIT'],
	['xbps:notify-send', 'libnotify'],
	['xbps:unzip', 'unzip'],
	['xbps:sha256sum', 'coreutils'],
	['xbps:xkbcli', 'libxkbcommon-tools'],
	['xbps:libatspi.so.0', 'at-spi2-core'],
	['apk:luajit', 'luajit'],
	['apk:notify-send', 'libnotify'],
	['apk:unzip', 'unzip'],
	['apk:sha256sum', 'coreutils'],
	['apk:xkbcli', 'xkbcli'],
	['apk:libatspi.so.0', 'at-spi2-core']
]);
for (const [dependency, expectedPackage] of expectedPackages) {
	const actualPackage = packageTable.get(dependency);
	if (actualPackage !== expectedPackage) {
		errors.push(
			`install.sh maps ${dependency} to '${actualPackage || '<missing>'}', expected '${expectedPackage}'`
		);
	}
}

const dependencyFunctions =
	(installerSrc.match(/(_required_dependency_package\(\)\s*\{[\s\S]*?)(?=\nif \$SKIP_DEPS; then)/) ||
		[])[1] || '';
if (
	!dependencyFunctions.includes('_required_dependency_package()') ||
	!dependencyFunctions.includes('_install_required_package()') ||
	!dependencyFunctions.includes('_check_or_install()')
) {
	errors.push('the dependency function fixture is incomplete; behavioral postcondition proof did not run');
} else {
	const fixtureRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-linux-deps-'));
	const fakeManager = path.join(fixtureRoot, 'apk');
	const toPosix = (value) => value.replace(/^([A-Za-z]):/, '/$1').replaceAll('\\', '/');
	const bash =
		process.platform === 'win32' && fs.existsSync('C:/Program Files/Git/bin/bash.exe')
			? 'C:/Program Files/Git/bin/bash.exe'
			: 'bash';
	try {
		fs.writeFileSync(
			fakeManager,
			'#!/bin/bash\n' +
				'if [ "${ERGOPTI_FAKE_PROVIDE:-0}" = "1" ]; then\n' +
				'\tprintf \'#!/bin/bash\\nexit 0\\n\' > "${ERGOPTI_FAKE_BIN}/xkbcli"\n' +
				'\t/bin/chmod 0755 "${ERGOPTI_FAKE_BIN}/xkbcli"\n' +
				'fi\n' +
				'exit 0\n',
			'utf8'
		);
		fs.chmodSync(fakeManager, 0o755);
		const harness =
			'set -u\n' +
			'_detect_pkg_manager() { echo apk; }\n' +
			'sudo() { "$@"; }\n' +
			dependencyFunctions +
			'\n_check_or_install xkbcli\n';
		const runFixture = (provide) => spawnSync(bash, ['-s'], {
			input: harness,
			encoding: 'utf8',
			env: {
				...process.env,
				ERGOPTI_FAKE_BIN: toPosix(fixtureRoot),
				ERGOPTI_FAKE_PROVIDE: provide ? '1' : '0',
				PATH: toPosix(fixtureRoot)
			}
		});
		const falseSuccess = runFixture(false);
		if (falseSuccess.status === 0) {
			errors.push('a package manager that exits 0 without providing xkbcli still passes the installer');
		}
		const realSuccess = runFixture(true);
		if (realSuccess.status !== 0) {
			errors.push(
				`the dependency fixture installed xkbcli but the installer rejected it: ` +
					`${(realSuccess.stderr || realSuccess.error?.message || '').trim()}`
			);
		}
	} finally {
		fs.rmSync(fixtureRoot, { recursive: true, force: true });
	}
}

// =========================================================
// =========================================================
// ======= 2/ Every Exported Path Exists =======
// =========================================================
// =========================================================

// The launcher composes its paths from shell variables, so they are resolved the
// way the shell resolves them: in order, following the same assignments. Only the
// repo-checkout branch is verifiable here — the installed branch points at
// /usr/lib/ergopti, which exists on a user's machine and not in a clone — and it
// is the branch that wins, because it is assigned last.
const vars = new Map([['SCRIPT_DIR', path.dirname(LAUNCHER)]]);

for (const line of launcherCode.split(/\r?\n/)) {
	// NAME="$(cd "${OTHER}/rel" && pwd -P)" — a walk relative to a known directory.
	let m = line.match(/^\s*([A-Z_]+)="\$\(cd "\$\{([A-Z_]+)\}\/([^"]*)"\s*&&\s*pwd -P\)"/);
	if (m && vars.has(m[2])) {
		vars.set(m[1], path.resolve(vars.get(m[2]), m[3]));
		continue;
	}
	// NAME="${OTHER}" or NAME="${OTHER}/suffix" — a plain composition.
	m = line.match(/^\s*([A-Z_]+)="\$\{([A-Z_]+)\}([^"$]*)"/);
	if (m && vars.has(m[2])) {
		vars.set(m[1], path.join(vars.get(m[2]), m[3]));
	}
}

const exportLine = (launcherCode.match(/^\s*export LUA_PATH=.*$/m) || [])[0] || '';
if (exportLine === '') {
	errors.push(
		'no `export LUA_PATH=` line found in the launcher — the daemon would inherit whatever LUA_PATH the session had'
	);
}

const referenced = [...new Set([...exportLine.matchAll(/\$\{([A-Z_]+)\}/g)].map((m) => m[1]))];
if (referenced.length < 2) {
	errors.push(
		`the exported LUA_PATH references ${referenced.length} variable(s) — expected at least 2 (the driver ` +
			'tree and the shared tree). The parser drifted, and an existence check over nothing passes forever.'
	);
}

for (const name of referenced) {
	const resolved = vars.get(name);
	if (!resolved) {
		errors.push(
			`LUA_PATH is built from \${${name}}, which no assignment in the launcher defines — it expands to the empty string`
		);
		continue;
	}
	// An absolute install path cannot be checked from a clone; the checkout branch can.
	if (!resolved.startsWith(ROOT)) continue;
	if (!fs.existsSync(resolved)) {
		errors.push(
			`${name} resolves to ${path.relative(ROOT, resolved).split(path.sep).join('/')}, which does not ` +
				'exist. LUA_PATH would carry an entry that can never match, and the failure is invisible: the ' +
				'daemon rebuilds package.path from its own location, so a broken export looks harmless right up ' +
				'until something relies on it.'
		);
	}
}

// =========================================================
// =========================================================
// ======= 3/ Live XKB Is A Runtime Dependency =======
// =========================================================
// =========================================================

const debDepends = (debSrc.match(/^Depends:\s*(.+)$/m) || [])[1] || '';
if (!/(?:^|,\s*)libxkbcommon0(?:\s|,|$)/.test(debDepends)) {
	errors.push('the Debian Depends line must require libxkbcommon0 for LuaJIT FFI capture');
}
if (!/(?:^|,\s*)libxkbcommon-tools(?:\s|,|$)/.test(debDepends)) {
	errors.push(
		'the Debian Depends line must require libxkbcommon-tools to obtain the session keymap'
	);
}
if (!/(?:^|,\s*)at-spi2-core(?:\s|,|$)/.test(debDepends)) {
	errors.push('the Debian Depends line must require at-spi2-core for secure-field detection');
}

const rpmRequires = new Set([...rpmSrc.matchAll(/^Requires:\s*([^\s]+)/gm)].map((m) => m[1]));
if (!rpmRequires.has('libxkbcommon')) {
	errors.push('the RPM spec must Require libxkbcommon for LuaJIT FFI capture');
}
if (!rpmRequires.has('libxkbcommon-utils')) {
	errors.push('the RPM spec must Require libxkbcommon-utils to obtain the session keymap');
}
if (!rpmRequires.has('at-spi2-core')) {
	errors.push('the RPM spec must Require at-spi2-core for secure-field detection');
}

const archDepends = (pkgbuildSrc.match(/^depends=\(([^\n]*)\)$/m) || [])[1] || '';
if (!/(?:^|\s)'libxkbcommon'(?:\s|$)/.test(archDepends)) {
	errors.push("the Arch depends() array must include 'libxkbcommon' as a hard dependency");
}
if (!/(?:^|\s)'at-spi2-core'(?:\s|$)/.test(archDepends)) {
	errors.push("the Arch depends() array must include 'at-spi2-core' as a hard dependency");
}

const nixLibraryPath =
	(nixSrc.match(/--prefix LD_LIBRARY_PATH[\s\S]*?makeLibraryPath[\s\S]*?\[([\s\S]*?)\]\)}/) ||
		[])[1] || '';
if (!/\blibxkbcommon\b/.test(nixLibraryPath)) {
	errors.push('the Nix wrapper must expose libxkbcommon through LD_LIBRARY_PATH, not PATH alone');
}
if (!/\bat-spi2-core\b/.test(nixLibraryPath)) {
	errors.push('the Nix wrapper must expose at-spi2-core through LD_LIBRARY_PATH');
}
const nixBinPath =
	(nixSrc.match(/--prefix PATH[\s\S]*?makeBinPath[\s\S]*?\[([\s\S]*?)\]\)}/) || [])[1] || '';
if (!/\blibxkbcommon\b/.test(nixBinPath)) {
	errors.push('the Nix wrapper must expose xkbcli from libxkbcommon through PATH');
}

const packageDependencyChecks = [debDepends, rpmRequires, archDepends, nixLibraryPath, nixBinPath];
if (packageDependencyChecks.some((value) => value == null || value === '' || value.size === 0)) {
	errors.push(
		'one or more XKB package dependency parsers matched nothing — the guard is not allowed to pass vacuously'
	);
}

// =========================================================
// =========================================================
// ======= 4/ Kanata Bootstrap Supply Chain =======
// =========================================================
// =========================================================

const kanataBody =
	(installerCode.match(/^_install_kanata\(\)\s*\(([\s\S]*?)^\)$/m) || [])[1] || '';
if (kanataBody.length < 500) {
	errors.push(
		'_install_kanata() is missing or too small to contain download, authentication, validation and publication'
	);
}

const kanataVersion =
	(installerCode.match(/^KANATA_VERSION="([0-9]+\.[0-9]+\.[0-9]+)"$/m) || [])[1] || '';
const kanataAsset =
	(installerCode.match(/^KANATA_LINUX_X64_ASSET="([^"]+)"$/m) || [])[1] || '';
const kanataSha256 =
	(installerCode.match(/^KANATA_LINUX_X64_SHA256="([0-9a-f]{64})"$/m) || [])[1] || '';
const kanataBinary =
	(installerCode.match(/^KANATA_LINUX_X64_BINARY="([^"]+)"$/m) || [])[1] || '';

if (!kanataVersion || !kanataAsset || !kanataSha256 || !kanataBinary) {
	errors.push(
		'the Kanata release contract must declare one semantic version, Linux x64 archive, SHA-256 and archive member'
	);
}
if (!/^linux-.*x64\.zip$/.test(kanataAsset)) {
	errors.push(`the pinned Kanata asset must be a Linux x64 ZIP, got '${kanataAsset || '<missing>'}'`);
}
if (!/^kanata_linux_.*x64$/.test(kanataBinary)) {
	errors.push(
		`the extracted Kanata member must identify Linux x64, got '${kanataBinary || '<missing>'}'`
	);
}
if (/releases\/latest\/download/.test(kanataBody)) {
	errors.push('the Kanata download still follows the mutable releases/latest alias');
}
if (/macos|darwin/i.test(kanataBody)) {
	errors.push('the Linux Kanata bootstrap still references a macOS artifact');
}
if (!/x86_64\|amd64\)\s*;;[\s\S]*?\*\)[\s\S]*?return\s+1/.test(kanataBody)) {
	errors.push('unsupported Kanata architectures must fail explicitly instead of reporting success');
}

const kanataStages = [
	['versioned release URL', 'releases/download/v${KANATA_VERSION}/${KANATA_LINUX_X64_ASSET}'],
	['archive download destination', '--output "${archive}"'],
	['SHA-256 authentication', 'sha256sum --check --status'],
	['single-member extraction', 'unzip -p "${archive}" "${KANATA_LINUX_X64_BINARY}"'],
	['ELF architecture validation', '${elf_header:36:4}'],
	['runtime version validation', '"${candidate}" --version'],
	['atomic publication', 'mv -f -- "${install_tmp}" "${dest}"']
];
let previousStage = -1;
for (const [label, needle] of kanataStages) {
	const stage = kanataBody.indexOf(needle);
	if (stage === -1) {
		errors.push(`the Kanata bootstrap is missing its ${label} stage`);
	} else if (stage <= previousStage) {
		errors.push(`the Kanata ${label} stage runs before an earlier validation stage`);
	}
	previousStage = Math.max(previousStage, stage);
}

const kanataInvocation = installerCode.match(
	/if ! \$SKIP_DEPS; then[\s\S]*?=== Installation de kanata ===[\s\S]*?_install_kanata[\s\S]*?fi/
);
if (!kanataInvocation) {
	errors.push('--no-deps must skip the Kanata dependency download as its help text promises');
}

// =========================================================
// =========================================================
// ======= 5/ Report =======
// =========================================================
// =========================================================

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] the Linux launcher cannot start where install.sh leaves a machine:\x1b[0m'
	);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] launcher hard-requires ${launcherDeps.length} command(s), all installed by install.sh; ` +
		`${referenced.length} exported LUA_PATH root(s) resolve to real directories; ` +
		`4 package recipe(s) hard-provide live XKB; Kanata ${kanataVersion} is authenticated and published atomically.\x1b[0m`
);
