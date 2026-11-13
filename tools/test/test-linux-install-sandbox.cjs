// tools/test/test-linux-install-sandbox.cjs

/**
 * ==============================================================================
 * MODULE: Linux Installer Sandbox Run
 * DESCRIPTION:
 * Runs the REAL static/ergopti_plus/linux/install.sh — dependencies included,
 * not --no-deps — inside a throwaway HOME, with every system-facing command
 * (sudo, the package manager, systemctl, curl, luajit's library probes)
 * replaced by a stub on PATH. It answers the questions a first install
 * answers, on any machine, in a second:
 *
 * ROOT CAUSE 1 — A KANATA THAT CANNOT RUN ABORTED THE WHOLE INSTALL.
 * The upstream kanata 1.12.0 binary needed glibc 2.39, so on Ubuntu 22.04 and
 * Debian 12 the script died under `set -e` before copying a single driver
 * file. The tap-holds now run in the daemon itself (platform/remap/), so the
 * installer fetches no remapper at all: the install must finish, and must not
 * write or download anything kanata.
 *
 * ROOT CAUSE 2 — THE DESKTOP HALF WAS NEVER INSTALLED.
 * The tray's libayatana-appindicator and the windows' WebKit2GTK typelib were
 * left to the user, so a fresh install showed no tray icon anywhere. Each must
 * be requested from the package manager when its probe fails.
 *
 * ROOT CAUSE 3 — AN OPTIONAL LUA PACKAGE ABSENT FROM THE ARCHIVE ABORTED IT.
 * lua-http does not exist on Arch, lua-filesystem not on openSUSE; the package
 * manager failed under `set -e` and the script died before copying the driver.
 * The names were also Lua 5.4 builds there, invisible to LuaJIT. An optional
 * module that cannot be installed must be reported and skipped.
 *
 * ROOT CAUSE 4 — ALPINE WAS REFUSED OUTRIGHT.
 * apk lives in /sbin, absent from an ordinary Alpine user's PATH, so the
 * manager was detected as "unknown" and every dependency refused; and the
 * group setup called usermod, which BusyBox does not ship, under set -e.
 *
 * ROOT CAUSE 5 — ON GNOME THE ICON WAS REGISTERED AND NEVER SHOWN.
 * GNOME Shell hosts no StatusNotifierItem without an extension; Ubuntu enables
 * its own, Fedora and Debian GNOME do not. The installer now installs and
 * enables the AppIndicator extension there, merged into the user's list.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const assert = require('node:assert/strict');
const { createHash } = require('node:crypto');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const { isLocalWindowsHost, reportNotExecuted } = require('./lib/host-capabilities.cjs');

// A checkout install compiles the Linux native archive helper before it copies
// anything; Git Bash has no Linux C toolchain, so no scenario can complete.
if (isLocalWindowsHost()) {
	reportNotExecuted(
		'Linux install.sh sandboxed real run (every scenario)',
		'a checkout install compiles the Linux native archive helper, which needs a Linux C toolchain'
	);
	process.exit(0);
}

const ROOT = path.resolve(__dirname, '..', '..');
const INSTALLER = path.join(ROOT, 'static', 'ergopti_plus', 'linux', 'install.sh');

function bashPath(value) {
	if (process.platform !== 'win32') return value;
	return value
		.replaceAll('\\', '/')
		.replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);
}

/** Writes an executable stub. */
function stub(dir, name, body) {
	const file = path.join(dir, name);
	fs.writeFileSync(file, `#!/usr/bin/env bash\n${body}\n`, 'utf8');
	fs.chmodSync(file, 0o755);
}

/**
 * Runs install.sh in a fresh sandbox.
 * @param {object} scenario { desktopProvided: boolean, seed?: (home: string) => void }
 * @returns {{ status: number, output: string, home: string, stubs: string, calls: string[] }}
 */
function runInstaller(scenario) {
	const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-install-'));
	const home = path.join(sandbox, 'home');
	const configRoot = path.join(home, scenario.configRootName || '.config');
	const stubs = path.join(sandbox, 'stubs');
	const callLog = path.join(sandbox, 'calls.log');
	const state = path.join(sandbox, 'state');
	fs.mkdirSync(home);
	fs.mkdirSync(stubs);
	fs.mkdirSync(state);
	if (scenario.seed) scenario.seed(home, configRoot);
	const log = `echo "$(basename "$0") $*" >> ${JSON.stringify(bashPath(callLog))}`;

	// Privilege is recorded and never performed — except the package manager,
	// which is itself a stub, so its markers are what the probes read back.
	// scenario.busybox: no shadow-utils, as on Alpine — usermod and groupadd
	// do not exist, BusyBox's addgroup does.
	stub(
		stubs,
		'sudo',
		`${log}\n[ "$1" = apt-get ] && exec "$@"\n` +
			(scenario.busybox ? 'case "$1" in usermod|groupadd) exit 127 ;; esac\n' : '') +
			'exit 0'
	);
	if (scenario.rootWithoutCaller) {
		stub(stubs, 'id', '[ "$1" = -u ] && { echo 0; exit 0; }; exec /usr/bin/id "$@"');
		fs.writeFileSync(
			path.join(stubs, 'bash'),
			'#!/bin/bash\ncase "${1:-}" in */setup_permissions.sh) exit 1 ;; esac\nexec /bin/bash "$@"\n',
			{ mode: 0o755 }
		);
	}
	if (scenario.refuseLibraryScan) {
		stub(stubs, 'find', 'case "${1:-}" in */lib/ergopti) exit 73 ;; esac\nexec /usr/bin/find "$@"');
	}
	stub(
		stubs,
		'systemctl',
		`${log}\n[ "$2" = is-enabled ] && [ "${scenario.systemdEnabled ? 1 : 0}" = 1 ] && exit 0\n[ "$2" = show ] && { ${scenario.refuseShow ? 'exit 1;' : `printf 'FragmentPath=%s\\nDropInPaths=\\n' "\${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/ergopti-hotstrings.service"; exit 0;`} }\n[ "$4" = list-unit-files ] && { echo 'ergopti-hotstrings.service ${scenario.systemdEnabled ? 'enabled' : 'disabled'} enabled'; exit 0; }\n[ "$2 $3" = '--no-reload disable' ] && exit 0\nexit 1`
	);
	if (
		scenario.refuseUnitPublish ||
		scenario.refuseLauncherPublish ||
		scenario.refuseAutostartPublish
	) {
		const destination = scenario.refuseUnitPublish
			? '*/ergopti-hotstrings.service'
			: scenario.refuseLauncherPublish
				? '*/bin/ergopti-hotstrings'
				: '*/ergopti-hotstrings.desktop';
		stub(
			stubs,
			'mv',
			`for arg in "$@"; do case "$arg" in ${destination}) printf '[fixture] publish-refused\\n' >&2; exit 1 ;; esac; done\nexec /usr/bin/mv "$@"`
		);
	}
	if (scenario.refuseUnitMode || scenario.refuseLauncherMode || scenario.refuseAutostartMode) {
		const temporary = scenario.refuseUnitMode
			? '*/.ergopti-service.*'
			: scenario.refuseLauncherMode
				? '*/.ergopti-launcher.*'
				: '*/.ergopti-autostart.*';
		stub(
			stubs,
			'chmod',
			`for arg in "$@"; do case "$arg" in ${temporary}) printf '[fixture] mode-refused\\n' >&2; exit 1 ;; esac; done\nexec /usr/bin/chmod "$@"`
		);
	}
	if (scenario.protectSystemPrefix) {
		stub(
			stubs,
			'install',
			'for arg in "$@"; do case "$arg" in /usr|/usr/*) exit 77 ;; esac; done\nexec /usr/bin/install "$@"'
		);
	}
	if (process.platform === 'win32') {
		stub(
			stubs,
			'install',
			'if [ "$1 $2 $3" = "-d -m 700" ]; then shift 3; exec mkdir -p -- "$@"; fi\nexec /usr/bin/install "$@"'
		);
	}
	// The package manager "installs" by dropping a marker the probes read.
	// A package named in scenario.absentPackages is not in the archive: the
	// manager fails, as apt/pacman/zypper do for an unknown name.
	const absent = (scenario.absentPackages || []).join(' ');
	stub(
		stubs,
		'apt-get',
		`${log}\nfor p in "$@"; do case " ${absent} " in *" $p "*) exit 100 ;; esac; done\n` +
			`for p in "$@"; do touch ${JSON.stringify(bashPath(state))}/"$p"; done\nexit 0`
	);
	// Stub desktop capabilities; ownership hashes must come from real coreutils.
	for (const name of ['notify-send', 'sqlite3', 'secret-tool', 'xkbcli'])
		stub(stubs, name, 'exit 0');
	// luajit: library probes answer from the markers, so the desktop backends
	// are "missing" until the package manager was asked for them.
	stub(
		stubs,
		'luajit',
		[
			'code="$*"',
			`st=${JSON.stringify(bashPath(state))}`,
			'case "$code" in',
			`  *appindicator*) [ -e "$st/libayatana-appindicator3-1" ] || [ "${scenario.desktopProvided ? 1 : 0}" = 1 ] ;;`,
			`  *WebKit2*) [ -e "$st/gir1.2-webkit2-4.1" ] || [ "${scenario.desktopProvided ? 1 : 0}" = 1 ] ;;`,
			`  *"require('posix')"*) [ -e "$st/lua-posix" ] || [ "${scenario.posixProvided === false ? 0 : 1}" = 1 ] ;;`,
			'  *) exit 0 ;;',
			'esac'
		].join('\n')
	);
	// Recorded so a download the installer no longer needs shows up as a call.
	stub(stubs, 'curl', `${log}\nexit 1`);
	if (scenario.gnome) {
		// A GNOME Shell with no AppIndicator extension, which refuses to enable
		// one installed during this session (the running shell never loaded it).
		stub(stubs, 'gnome-extensions', `${log}\n[ "$1" = enable ] && exit 1\nexit 0`);
		stub(
			stubs,
			'gsettings',
			`${log}\n[ "$1" = get ] && { echo "['user-theme@gnome-shell-extensions.gcampax.github.com']"; exit 0; }\nexit 0`
		);
	}

	const env = {
		...(scenario.configRootName ? { XDG_CONFIG_HOME: bashPath(configRoot) } : {}),
		...(scenario.gnome ? { XDG_CURRENT_DESKTOP: 'ubuntu:GNOME' } : {}),
		HOME: bashPath(home),
		PATH: `${bashPath(stubs)}:/usr/bin:/bin`,
		TMPDIR: bashPath(sandbox),
		LANG: 'C.UTF-8'
	};
	if (scenario.sudoUid !== undefined) env.SUDO_UID = scenario.sudoUid;
	if (scenario.omitHome) delete env.HOME;
	// Git Bash may reconstruct PATH when a child Bash starts. Keep the same
	// inert command boundary in the installer and its newly installed helpers.
	const bashEnvironment = path.join(sandbox, 'bash-environment');
	fs.writeFileSync(
		bashEnvironment,
		'export PATH="$TEST_STUBS:/usr/bin:/bin"\n' +
			(scenario.refuseUnitWrite
				? 'printf() { if [[ "$1" = "%s\\n" && "${2:-}" = ExecStart=* ]]; then return 1; fi; builtin printf "$@"; }\n'
				: '') +
			(scenario.refuseLauncherWrite ? 'cat() { return 1; }\n' : '') +
			(scenario.refuseAutostartWrite
				? 'cat() { local target; target="$(readlink "/proc/$$/fd/1")"; [[ "$target" = */.ergopti-autostart.* ]] && { printf "[fixture] write-refused\\n" >&2; return 1; }; command cat "$@"; }\n'
				: '')
	);
	env.TEST_STUBS = bashPath(stubs);
	env.BASH_ENV = bashPath(bashEnvironment);
	const installArgs =
		scenario.prefixArgument !== undefined
			? ['--prefix', scenario.prefixArgument]
			: scenario.prefixName
				? ['--prefix', bashPath(path.join(home, scenario.prefixName))]
				: [];
	if (scenario.noService) installArgs.push('--no-service');
	const result = spawnSync(bashExecutable(), [bashPath(INSTALLER), ...installArgs], {
		env,
		cwd: scenario.fromHome ? home : undefined,
		encoding: 'utf8',
		timeout: 60000
	});
	const calls = fs.existsSync(callLog)
		? fs.readFileSync(callLog, 'utf8').split('\n').filter(Boolean)
		: [];
	return {
		status: result.status,
		output: `${result.stdout || ''}${result.stderr || ''}`,
		home,
		configRoot,
		stubs,
		env,
		calls,
		cleanup: () => fs.rmSync(sandbox, { recursive: true, force: true })
	};
}

/** Verifies genuine installed bytes against every producer ownership receipt. */
function verifyOwnership(run, contents, prefix = path.join(run.home, '.local'), hasStartup = true) {
	const library = path.join(prefix, 'lib/ergopti');
	const manifest = contents ?? fs.readFileSync(path.join(library, '.ergopti-owned-files'), 'utf8');
	assert.notEqual(manifest, '', 'an empty ownership manifest cannot certify an installation');
	const rows = manifest.endsWith('\n') ? manifest.slice(0, -1).split('\n') : manifest.split('\n');
	const external = {
		'@wrapper': path.join(prefix, 'bin/ergopti-hotstrings'),
		'@unit': path.join(run.configRoot, 'systemd/user/ergopti-hotstrings.service'),
		'@autostart': path.join(run.configRoot, 'autostart/ergopti-hotstrings.desktop')
	};
	const observed = new Set();
	for (const row of rows) {
		const fields = /^([0-9a-f]{64})\t([^\t\n]+)$/.exec(row);
		assert.ok(fields, 'each ownership row must carry a genuine SHA-256 and one path');
		const [, digest, relative] = fields;
		assert.ok(!observed.has(relative), 'ownership paths must be unique');
		observed.add(relative);
		assert.ok(
			external[relative] ||
				/^(?:linux|_shared)\//.test(relative) ||
				relative === 'bin/ergopti-hotstrings',
			'every ownership row must address the installed payload or its startup entries'
		);
		const file = external[relative] || path.join(library, relative);
		assert.equal(
			createHash('sha256').update(fs.readFileSync(file)).digest('hex'),
			digest,
			`receipt digest must match independently read installed bytes: ${relative}`
		);
	}
	const requiredOwners = [
		'linux/ergopti_hotstrings.lua',
		'_shared/core/i18n/data/locales/en.json',
		'linux/install/libergopti_archive_publication.so',
		'bin/ergopti-hotstrings',
		'@wrapper'
	];
	if (hasStartup) requiredOwners.push('@unit', '@autostart');
	else
		assert.ok(
			!observed.has('@unit') && !observed.has('@autostart'),
			'--no-service must own no startup entries'
		);
	for (const required of requiredOwners) {
		assert.ok(observed.has(required), `the actual installation must own ${required}`);
	}
	return manifest;
}

// A durable launcher must use the same physical prefix as removal, independent
// of where installation and the later desktop or terminal launch happen.
if (process.platform === 'linux') {
	for (const candidate of [
		{ prefix: 'staging/../relative Applications' },
		{ prefix: 'alias\\with spaces', alias: true },
		{ prefix: 'prefix with trailing newline\n', noService: true }
	]) {
		const run = runInstaller({
			desktopProvided: true,
			prefixArgument: candidate.prefix,
			fromHome: true,
			noService: candidate.noService,
			seed(home) {
				if (candidate.alias) {
					const target = path.join(home, 'physical prefix');
					fs.mkdirSync(target, { mode: 0o700 });
					fs.symlinkSync(target, path.join(home, candidate.prefix), 'dir');
				}
			}
		});
		try {
			assert.equal(run.status, 0, run.output.slice(-1800));
			const selected = path.join(run.home, candidate.prefix);
			const prefix = fs.realpathSync(selected);
			const wrapper = path.join(prefix, 'bin/ergopti-hotstrings');
			const fullReceipt = verifyOwnership(run, undefined, prefix, !candidate.noService);
			// c7b743's full-content layer above validates every installed digest.
			// This layer isolates prefix ownership with a faithful small receipt;
			// the complete uninstaller's per-file cost is not a prefix invariant.
			const ownerPaths = new Set([
				'linux/ergopti_hotstrings.lua',
				'_shared/core/i18n/data/locales/en.json',
				'bin/ergopti-hotstrings',
				'@wrapper',
				'@unit',
				'@autostart'
			]);
			const receipt = fullReceipt.split('\n').filter((row) => ownerPaths.has(row.split('\t')[1]));
			fs.writeFileSync(
				path.join(prefix, 'lib/ergopti/.ergopti-owned-files'),
				receipt.join('\n') + '\n'
			);
			if (candidate.alias) {
				assert.equal(
					fs.statSync(prefix).mode & 0o777,
					0o700,
					'normalization preserves an existing private prefix mode'
				);
				fs.unlinkSync(selected);
			}
			const environment = {
				HOME: bashPath(run.home),
				XDG_CONFIG_HOME: bashPath(run.configRoot),
				PATH: `${bashPath(run.stubs)}:/usr/bin:/bin`
			};
			const launched = spawnSync(bashExecutable(), [bashPath(wrapper), '--help'], {
				cwd: run.stubs,
				env: environment,
				encoding: 'utf8',
				timeout: 15000
			});
			assert.equal(launched.status, 0, `prefix-launch-from-other-cwd: ${launched.stderr}`);
			const checked = spawnSync(
				bashExecutable(),
				[
					bashPath(path.join(path.dirname(INSTALLER), 'uninstall.sh')),
					'--prefix',
					bashPath(prefix),
					'--check'
				],
				{
					cwd: run.stubs,
					env: environment,
					encoding: 'utf8',
					timeout: 15000
				}
			);
			assert.equal(
				checked.status,
				0,
				`prefix-uninstall-owner: ${checked.stderr || checked.error?.message || checked.signal}`
			);
		} finally {
			run.cleanup();
		}
	}
}

const errors = [];

// The standalone uninstaller refuses an installation nested in any checkout.
// Do not create that unremovable installation, even when the prefix is new.
for (const viaAlias of [false, true]) {
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		prefixName: `${viaAlias ? 'checkout-alias' : 'checkout'}/new-prefix`,
		seed(home) {
			const checkout = path.join(home, 'checkout');
			fs.mkdirSync(checkout);
			const initialized = spawnSync('git', ['init', '--quiet', checkout], { encoding: 'utf8' });
			assert.equal(initialized.status, 0, initialized.stderr);
			if (viaAlias) fs.symlinkSync(checkout, path.join(home, 'checkout-alias'));
		}
	});
	try {
		assert.notEqual(run.status, 0, 'a prefix inside a checkout must be refused');
		assert.equal(fs.existsSync(path.join(run.home, 'checkout/new-prefix')), false);
		assert.equal(
			run.calls.some((call) => call.startsWith('sudo ')),
			false
		);
	} finally {
		run.cleanup();
	}
}

// A checkout already inside an installation is user-owned too.
{
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		seed(home) {
			const checkout = path.join(home, '.local/lib/ergopti/linux/custom-checkout');
			fs.mkdirSync(checkout, { recursive: true });
			const initialized = spawnSync('git', ['init', '--quiet', checkout], { encoding: 'utf8' });
			assert.equal(initialized.status, 0, initialized.stderr);
			fs.writeFileSync(path.join(checkout, 'keep'), 'user data\n');
		}
	});
	try {
		assert.notEqual(run.status, 0, 'an installation containing a checkout must be refused');
		assert.equal(
			fs.readFileSync(path.join(run.home, '.local/lib/ergopti/linux/custom-checkout/keep'), 'utf8'),
			'user data\n'
		);
		assert.equal(
			run.calls.some((call) => call.startsWith('sudo ')),
			false
		);
	} finally {
		run.cleanup();
	}
}

// A linked bin or lib directory redirects publication outside the admitted
// prefix and cannot later pass the uninstaller's physical-path checks.
for (const [linked, dangling] of ['bin', 'lib'].flatMap((name) => [
	[name, false],
	[name, true]
])) {
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		seed(home) {
			const prefix = path.join(home, '.local');
			const foreign = path.join(home, `foreign-${linked}`);
			fs.mkdirSync(prefix);
			fs.mkdirSync(foreign);
			fs.symlinkSync(foreign, path.join(prefix, linked));
			if (dangling) fs.rmdirSync(foreign);
		}
	});
	try {
		assert.notEqual(run.status, 0, `linked ${linked} must be refused`);
		const foreign = path.join(run.home, `foreign-${linked}`);
		if (dangling) assert.equal(fs.existsSync(foreign), false);
		else assert.deepEqual(fs.readdirSync(foreign), []);
		assert.equal(
			run.calls.some((call) => call.startsWith('sudo ')),
			false
		);
	} finally {
		run.cleanup();
	}
}

// A refused scan cannot certify that replacing an existing tree is safe.
{
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		refuseLibraryScan: true,
		seed(home) {
			const file = path.join(home, '.local/lib/ergopti/linux/ergopti_hotstrings.lua');
			fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(file, 'retained\n');
		}
	});
	try {
		assert.notEqual(run.status, 0);
		assert.match(run.output, /code=scan-refused/);
		assert.equal(
			fs.readFileSync(
				path.join(run.home, '.local/lib/ergopti/linux/ergopti_hotstrings.lua'),
				'utf8'
			),
			'retained\n'
		);
		assert.equal(
			run.calls.some((call) => call.startsWith('sudo ')),
			false
		);
	} finally {
		run.cleanup();
	}
}

// A root shell without a desktop caller cannot enroll UID 0. Refuse before
// replacing payload files, not at the final permission-setup step.
for (const sudoUid of [undefined, '0', '999', '65534', 'invalid']) {
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		rootWithoutCaller: true,
		sudoUid,
		seed(home) {
			const file = path.join(home, '.local/lib/ergopti/linux/ergopti_hotstrings.lua');
			fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(file, 'existing installation\n');
		}
	});
	try {
		assert.notEqual(run.status, 0);
		assert.match(run.output, /Refusing a non-desktop account/);
		assert.equal(
			fs.readFileSync(
				path.join(run.home, '.local/lib/ergopti/linux/ergopti_hotstrings.lua'),
				'utf8'
			),
			'existing installation\n'
		);
		assert.equal(fs.existsSync(path.join(run.home, '.local/bin/ergopti-hotstrings')), false);
	} finally {
		run.cleanup();
	}
}

// An explicit prefix allows installation even when HOME is unavailable.
{
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		omitHome: true,
		prefixName: 'explicit'
	});
	try {
		assert.equal(run.status, 0, run.output);
		assert.ok(fs.existsSync(path.join(run.home, 'explicit/bin/ergopti-hotstrings')));
	} finally {
		run.cleanup();
	}
}

// Standalone installs under a system root cannot be removed by the standalone
// uninstaller and must not write into an OS package's namespace.
for (const candidate of ['/usr', '/usr/', 'system-alias']) {
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		prefixArgument: candidate,
		fromHome: candidate === 'system-alias',
		protectSystemPrefix: true,
		seed(home) {
			if (candidate === 'system-alias') fs.symlinkSync('/usr', path.join(home, candidate));
		}
	});
	try {
		assert.notEqual(run.status, 0);
		assert.match(run.output, /Refusing a system installation prefix/);
		assert.equal(
			run.calls.some((call) => call.startsWith('sudo ')),
			false
		);
	} finally {
		run.cleanup();
	}
}

// A service entry cannot encode control characters in the launcher path. The
// installer must discover that before copying a payload or asking for access.
for (const name of ['service\ninvalid', 'service\rinvalid', 'service\tinvalid']) {
	const run = runInstaller({ desktopProvided: true, prefixName: name });
	try {
		assert.notEqual(run.status, 0);
		assert.equal(fs.existsSync(path.join(run.home, name, 'lib/ergopti')), false);
		assert.equal(
			run.calls.some((call) => call.startsWith('sudo ')),
			false
		);
	} finally {
		run.cleanup();
	}
}

{
	const missingPrefix = spawnSync(bashExecutable(), [bashPath(INSTALLER), '--prefix'], {
		encoding: 'utf8',
		env: { ...process.env, LC_ALL: 'C' }
	});
	assert.equal(missingPrefix.status, 64);
	assert.match(missingPrefix.stderr, /Missing --prefix value/);
	assert.doesNotMatch(missingPrefix.stderr, /unbound variable/);
}

// Lua interprets these bytes inside every module-search template, so a driver
// installed under either prefix cannot load its own modules.
for (const prefixName of ['invalid;prefix', 'invalid?prefix']) {
	const run = runInstaller({ desktopProvided: true, noService: true, prefixName });
	try {
		assert.notEqual(run.status, 0);
		assert.match(run.output, /code=unsupported-prefix/);
		assert.equal(fs.existsSync(path.join(run.home, prefixName, 'lib/ergopti')), false);
	} finally {
		run.cleanup();
	}
}

// Runtime configuration and systemd use the same XDG config root. A legacy
// canonical pack there must retire before the new installed bundle replaces it.
{
	const legacyPack = '[legacy]\nvalue = "old canonical value"\n';
	const run = runInstaller({
		desktopProvided: true,
		configRootName: 'config with spaces',
		seed(home, configRoot) {
			for (const file of [
				path.join(home, '.local/lib/ergopti/_shared/hotstrings/data/catalogue/legacy.toml'),
				path.join(configRoot, 'ergopti/hotstrings/legacy.toml')
			]) {
				fs.mkdirSync(path.dirname(file), { recursive: true });
				fs.writeFileSync(file, legacyPack);
			}
		}
	});
	try {
		if (run.status !== 0) errors.push(`XDG config install failed: ${run.output.slice(-1800)}`);
		for (const relative of [
			'systemd/user/ergopti-hotstrings.service',
			'autostart/ergopti-hotstrings.desktop',
			'ergopti/hotstrings/.ergopti-canonical-packs-v2'
		]) {
			if (!fs.existsSync(path.join(run.configRoot, relative)))
				errors.push(`XDG config installation did not publish ${relative}`);
		}
		const hotstrings = path.join(run.configRoot, 'ergopti/hotstrings');
		if (fs.existsSync(path.join(hotstrings, 'legacy.toml')))
			errors.push('XDG config legacy canonical pack still masks the updated bundle');
		const backup = path.join(
			hotstrings,
			'.ergopti-migrations/canonical-seeds/legacy.toml.legacy-seed'
		);
		if (!fs.existsSync(backup) || fs.readFileSync(backup, 'utf8') !== legacyPack)
			errors.push('XDG config migration did not retain the old canonical bytes');
		for (const relative of ['.config/systemd/user', '.config/ergopti/hotstrings']) {
			if (fs.existsSync(path.join(run.home, relative)))
				errors.push(`XDG config install wrote to the unused default root: ${relative}`);
		}
	} finally {
		run.cleanup();
	}
}

// Both startup formats must quote the same installed wrapper, even on a fresh
// install where no menu-generated Desktop entry exists yet.
{
	const run = runInstaller({ desktopProvided: true, prefixName: 'Applications Ergopti' });
	try {
		if (run.status !== 0) errors.push(`install with spaces failed: ${run.output.slice(-1800)}`);
		const wrapper = `${bashPath(run.home)}/Applications Ergopti/bin/ergopti-hotstrings`;
		const unit = fs.readFileSync(
			path.join(run.home, '.config/systemd/user/ergopti-hotstrings.service'),
			'utf8'
		);
		const desktop = fs.readFileSync(
			path.join(run.home, '.config/autostart/ergopti-hotstrings.desktop'),
			'utf8'
		);
		if (!unit.includes(`ExecStart=/bin/bash "${wrapper}" --tray\n`))
			errors.push('unit does not quote the installed wrapper');
		if (!desktop.includes(`Exec=/bin/bash "${wrapper}" --session-start --tray\n`))
			errors.push('Desktop entry does not quote the installed wrapper');
	} finally {
		run.cleanup();
	}
}

// ── A first install, with no remapper to fetch ─────────────────────────────
{
	const run = runInstaller({ desktopProvided: false });
	try {
		if (run.status !== 0) {
			errors.push(
				`install.sh exited ${run.status} on a first install. Last lines:\n` +
					run.output.split('\n').slice(-12).join('\n')
			);
		}
		const launcher = path.join(run.home, '.local', 'bin', 'ergopti-hotstrings');
		if (!fs.existsSync(launcher)) errors.push('no launcher was installed');
		const daemon = path.join(
			run.home,
			'.local',
			'lib',
			'ergopti',
			'linux',
			'ergopti_hotstrings.lua'
		);
		if (!fs.existsSync(daemon)) errors.push('the driver tree was not copied');

		const receipt = verifyOwnership(run);
		const firstRow = receipt.split('\n')[0];
		const malformed = [
			'',
			receipt.replace(/^[0-9a-f]{64}/, 'not-a-sha256'),
			receipt.replace(/^[0-9a-f]{64}/, '0'.repeat(64)),
			`${receipt}${firstRow}\n`
		];
		for (const candidate of malformed) {
			assert.throws(
				() => verifyOwnership(run, candidate),
				'empty, malformed, false and duplicate receipts cannot certify installed bytes'
			);
		}

		// The daemon reads the layout registry below its driver root, and the
		// Ergopti extension inside it supplies SFB reduction, rolls and the magic
		// key's repeat corrections; a checkout keeps it outside the copied trees.
		// Discovery through the real Lua consumer is covered independently by
		// test-linux-install-layout-registry.cjs; every ownership digest is verified above.
		const extension = path.join(
			run.home,
			...'.local/lib/ergopti/linux/static/layouts/registry/ergopti/hotstrings/rolls.toml'.split('/')
		);
		if (!fs.existsSync(extension)) {
			errors.push('a checkout install does not ship the Ergopti extension of the layout registry');
		}
		// Root cause 1: the tap-holds run in the daemon; nothing kanata is installed.
		if (fs.existsSync(path.join(run.home, '.config', 'systemd', 'user', 'kanata.service'))) {
			errors.push(
				'install.sh still writes a kanata.service although the daemon runs the tap-holds'
			);
		}
		if (fs.existsSync(path.join(run.home, '.config', 'kanata'))) {
			errors.push(
				'install.sh still writes a kanata configuration although the daemon runs the tap-holds'
			);
		}
		if (run.calls.some((call) => call.startsWith('curl') || /kanata/.test(call))) {
			errors.push(
				`install.sh still downloads or manages kanata: ${run.calls.filter((c) => c.startsWith('curl') || /kanata/.test(c)).join(' | ')}`
			);
		}
		// Root cause 2: both desktop backends were requested and re-probed.
		for (const pkg of ['libayatana-appindicator3-1', 'gir1.2-webkit2-4.1']) {
			if (
				!run.calls.some((call) => call.startsWith('sudo apt-get install') && call.includes(pkg))
			) {
				errors.push(`install.sh never asked the package manager for ${pkg}`);
			}
		}
		if (!/system tray icon \(libayatana-appindicator\) — capability verified/.test(run.output)) {
			errors.push('the tray backend was not re-probed after its package was installed');
		}
	} finally {
		run.cleanup();
	}
}

// ── An optional Lua package the archive does not carry ─────────────────────
{
	const run = runInstaller({
		desktopProvided: true,
		posixProvided: false,
		absentPackages: ['lua-posix']
	});
	try {
		if (run.status !== 0) {
			errors.push(
				`install.sh exited ${run.status} when an optional Lua package was absent from the archive:\n` +
					run.output.split('\n').slice(-8).join('\n')
			);
		}
		if (!fs.existsSync(path.join(run.home, '.local', 'bin', 'ergopti-hotstrings'))) {
			errors.push('no launcher was installed after an optional Lua package failed');
		}
		// The installer prints in the session's language (C.UTF-8 here: English), so the
		// expected line is built from the catalogue rather than spelled in one locale.
		const catalogue = JSON.parse(
			fs.readFileSync(
				path.join(ROOT, 'static/ergopti_plus/_shared/core/i18n/data/locales/en.json'),
				'utf8'
			)
		);
		const degraded = catalogue['linux_shell.install.lua_module_degraded']
			.replace('{1}', 'posix')
			.replace('{2}', catalogue['linux_shell.install.label_posix']);
		if (!run.output.includes(degraded)) {
			errors.push('an optional Lua module that stayed unavailable was not reported');
		}
	} finally {
		run.cleanup();
	}
}

// ── A BusyBox system with no usermod (Alpine) ───────────────────────────────
{
	const run = runInstaller({ desktopProvided: true, busybox: true });
	try {
		if (run.status !== 0) {
			errors.push(
				`install.sh exited ${run.status} on a system without usermod (Alpine):\n` +
					run.output.split('\n').slice(-6).join('\n')
			);
		}
		// The shared privileged helper now owns BusyBox enrollment; its actual
		// addgroup branch runs in test-linux-package-setup.cjs. This sandbox
		// refuses elevation, and verifies the delegation rather than faking it.
		if (
			!run.calls.some((call) =>
				/^sudo bash .*\/install\/setup_permissions\.sh --user \d+$/.test(call)
			)
		) {
			errors.push(
				'the installer did not delegate account enrollment to the shared permission owner'
			);
		}
	} finally {
		run.cleanup();
	}
}

// ── The package manager lives in /sbin (Alpine's apk) ───────────────────────
{
	// Extracted and run on its own: the real /sbin cannot be staged, so the two
	// system directories are pointed at fixtures. PATH is empty, as an ordinary
	// Alpine user's PATH is for /sbin.
	const source = fs.readFileSync(INSTALLER, 'utf8');
	const functions = (source.match(
		/_has_manager\(\) \{[\s\S]*?\n\}\n\n_detect_pkg_manager\(\) \{[\s\S]*?\n\}/
	) || [])[0];
	if (!functions) {
		errors.push('_has_manager/_detect_pkg_manager not found — the detection fixture did not run');
	} else {
		const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-sbin-'));
		try {
			fs.mkdirSync(path.join(fixture, 'sbin'));
			fs.mkdirSync(path.join(fixture, 'usr-sbin'));
			stub(path.join(fixture, 'sbin'), 'apk', 'exit 0');
			const harness =
				functions
					.replaceAll('"/sbin/$1"', `"${bashPath(fixture)}/sbin/$1"`)
					.replaceAll('"/usr/sbin/$1"', `"${bashPath(fixture)}/usr-sbin/$1"`) +
				'\n_detect_pkg_manager\n';
			// The interpreter is resolved with the caller's PATH; the script then
			// runs with an empty one, which is the point.
			const detected = spawnSync(bashExecutable(), ['-c', `PATH=\n${harness}`], {
				encoding: 'utf8'
			});
			if ((detected.stdout || '').trim() !== 'apk') {
				errors.push(
					`with apk only in /sbin, the installer detected '${(detected.stdout || '').trim()}' — ` +
						'an Alpine user was refused every dependency'
				);
			}
		} finally {
			fs.rmSync(fixture, { recursive: true, force: true });
		}
	}
}

// ── GNOME without a tray host ──────────────────────────────────────────────
{
	const run = runInstaller({ desktopProvided: true, gnome: true });
	try {
		if (run.status !== 0) errors.push(`install.sh exited ${run.status} on GNOME`);
		if (
			!run.calls.some(
				(call) =>
					call.startsWith('sudo apt-get install') &&
					call.includes('gnome-shell-extension-appindicator')
			)
		) {
			errors.push('GNOME without an AppIndicator extension: the extension was not installed');
		}
		const set = run.calls.find((call) =>
			call.startsWith('gsettings set org.gnome.shell enabled-extensions')
		);
		const expected =
			"['user-theme@gnome-shell-extensions.gcampax.github.com', 'appindicatorsupport@rgcjonas.gmail.com']";
		if (!set || !set.endsWith(expected)) {
			errors.push(
				`the extension must be enabled for the next login, merged into the user's list; got ${set || '<no gsettings set>'}`
			);
		}
	} finally {
		run.cleanup();
	}
}
{
	const run = runInstaller({ desktopProvided: true });
	try {
		if (run.calls.some((call) => /gnome-extensions|gsettings/.test(call))) {
			errors.push('outside GNOME, no GNOME extension may be touched');
		}
	} finally {
		run.cleanup();
	}
}

// Refuse foreign or linked launchers and startup entries before replacing the payload.
for (const kind of [
	'unit',
	'desktop',
	'linked-unit',
	'linked-desktop',
	'launcher',
	'linked-launcher'
]) {
	const relative = kind.endsWith('launcher')
		? '../.local/bin/ergopti-hotstrings'
		: kind.endsWith('unit')
			? 'systemd/user/ergopti-hotstrings.service'
			: 'autostart/ergopti-hotstrings.desktop';
	const run = runInstaller({
		desktopProvided: true,
		noService: kind.endsWith('launcher'),
		seed(home, configRoot) {
			const entry = path.join(configRoot, relative);
			fs.mkdirSync(path.dirname(entry), { recursive: true });
			if (kind.startsWith('linked-')) {
				fs.writeFileSync(path.join(home, 'foreign-target'), 'keep target\n');
				fs.symlinkSync(path.join(home, 'foreign-target'), entry);
			} else fs.writeFileSync(entry, 'foreign startup\n');
		}
	});
	try {
		assert.notEqual(run.status, 0, `${kind} must be refused`);
		const entry = path.join(run.configRoot, relative);
		if (kind.startsWith('linked-')) {
			assert.ok(fs.lstatSync(entry).isSymbolicLink());
			assert.equal(fs.readFileSync(path.join(run.home, 'foreign-target'), 'utf8'), 'keep target\n');
		} else assert.equal(fs.readFileSync(entry, 'utf8'), 'foreign startup\n');
		assert.equal(fs.existsSync(path.join(run.home, '.local/lib/ergopti')), false);
	} finally {
		run.cleanup();
	}
}

// An expected command in a duplicate key or action does not own the main entry.
for (const kind of [
	'duplicate',
	'key-space',
	'key-tab',
	'key-return',
	'key-formfeed',
	'group-space',
	'nul-comment',
	'action-decoy'
]) {
	let original;
	const run = runInstaller({
		desktopProvided: true,
		seed(home, configRoot) {
			const desktop = path.join(configRoot, 'autostart/ergopti-hotstrings.desktop');
			const launcher = `${bashPath(home)}/.local/bin/ergopti-hotstrings`;
			fs.mkdirSync(path.dirname(desktop), { recursive: true });
			const foreign = {
				duplicate: 'Exec=/other/program',
				'key-space': ' Exec =/other/program',
				'key-tab': 'Exec\t=/other/program',
				'key-return': '\rExec=/other/program',
				'key-formfeed': 'Exec\f=/other/program',
				'group-space': ' [Desktop Entry] \nExec=/other/program',
				'nul-comment': '# user\0data'
			};
			original =
				kind === 'action-decoy'
					? `[Desktop Entry]\nExec=/other/program\n[Desktop Action Example]\nExec=${launcher} --tray\n`
					: `[Desktop Entry]\nExec=${launcher} --tray\n${foreign[kind]}\n`;
			fs.writeFileSync(desktop, original);
		}
	});
	try {
		assert.notEqual(run.status, 0, `${kind} main entry must be refused`);
		assert.equal(
			fs.readFileSync(path.join(run.configRoot, 'autostart/ergopti-hotstrings.desktop'), 'utf8'),
			original
		);
		assert.equal(fs.existsSync(path.join(run.home, '.local/lib/ergopti')), false);
	} finally {
		run.cleanup();
	}
}

// A valid receipt's last row remains authoritative without a trailing newline.
{
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		seed(home) {
			const library = path.join(home, '.local/lib/ergopti');
			const module = path.join(library, 'linux/native_modules/luv.so');
			fs.mkdirSync(path.dirname(module), { recursive: true });
			fs.writeFileSync(module, 'previous native module');
			const digest = createHash('sha256').update(fs.readFileSync(module)).digest('hex');
			fs.writeFileSync(
				path.join(library, '.ergopti-owned-files'),
				`${digest}\tlinux/native_modules/luv.so`
			);
		}
	});
	try {
		assert.equal(run.status, 0, run.output);
		const receipt = fs.readFileSync(
			path.join(run.home, '.local/lib/ergopti/.ergopti-owned-files'),
			'utf8'
		);
		assert.ok(
			receipt.includes('\tlinux/native_modules/luv.so\n'),
			'retained native module remains owned'
		);
		verifyOwnership(run, receipt, path.join(run.home, '.local'), false);
	} finally {
		run.cleanup();
	}
}

// A reinstall removes the files the previous version owned and this one no
// longer ships (install-reinstall-retired-files). install.sh extracts over the
// old tree, so they stayed behind unowned: the tree then failed its own receipt
// (Ownership.verify) and, once it was <root>.old, the next update could not
// retire it. A retired file the user changed is kept, as uninstall keeps it.
{
	const retired = ['linux/retired/old_module.lua', '_shared/retired/old_data.json'];
	const edited = 'linux/retired/edited.lua';
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		seed(home) {
			const library = path.join(home, '.local/lib/ergopti');
			const rows = [];
			for (const relative of [...retired, edited]) {
				const file = path.join(library, relative);
				fs.mkdirSync(path.dirname(file), { recursive: true });
				fs.writeFileSync(file, `shipped by the previous version: ${relative}\n`);
				const digest = createHash('sha256').update(fs.readFileSync(file)).digest('hex');
				rows.push(`${digest}\t${relative}`);
			}
			fs.appendFileSync(path.join(library, edited), 'a line the user added\n');
			fs.writeFileSync(path.join(library, '.ergopti-owned-files'), `${rows.join('\n')}\n`);
		}
	});
	try {
		assert.equal(run.status, 0, run.output);
		const library = path.join(run.home, '.local/lib/ergopti');
		for (const relative of retired)
			assert.equal(
				fs.existsSync(path.join(library, relative)),
				false,
				`retired and unchanged: ${relative}`
			);
		assert.ok(fs.existsSync(path.join(library, edited)), 'a retired file the user changed is kept');
		const receipt = fs.readFileSync(path.join(library, '.ergopti-owned-files'), 'utf8');
		verifyOwnership(run, receipt, path.join(run.home, '.local'), false);
		const owned = new Set(receipt.split('\n').map((row) => row.split('\t')[1]));
		const unowned = [];
		const walk = (relative) => {
			for (const entry of fs.readdirSync(path.join(library, relative), { withFileTypes: true })) {
				const child = `${relative}/${entry.name}`;
				if (entry.isDirectory()) walk(child);
				else if (!owned.has(child) && child !== edited) unowned.push(child);
			}
		};
		walk('linux');
		walk('_shared');
		assert.deepEqual(unowned, [], 'every payload file of the reinstalled tree is in its receipt');
	} catch (error) {
		errors.push(`install-reinstall-retired-files: ${error.message}`);
	} finally {
		run.cleanup();
	}
}

// Reinstalling over this prefix's own launcher remains supported.
{
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		seed(home) {
			const bin = path.join(home, '.local/bin');
			fs.mkdirSync(bin, { recursive: true });
			fs.writeFileSync(
				path.join(bin, 'ergopti-hotstrings'),
				`INSTALL_ROOT=${bashPath(home)}/.local/lib/ergopti\nexec bash "\${INSTALL_ROOT}/bin/ergopti-hotstrings" "$@"\n`
			);
		}
	});
	try {
		assert.equal(run.status, 0, run.output);
	} finally {
		run.cleanup();
	}
}

// Skipping service setup on an upgrade must not erase ownership of the startup
// files that the earlier install left in place.
{
	const run = runInstaller({ desktopProvided: true });
	try {
		assert.equal(run.status, 0, run.output);
		const updated = spawnSync(bashExecutable(), [bashPath(INSTALLER), '--no-service'], {
			env: run.env,
			encoding: 'utf8',
			timeout: 60000
		});
		assert.equal(updated.status, 0, updated.stderr);
		verifyOwnership(run);
		const uninstall = spawnSync(
			bashExecutable(),
			[bashPath(path.join(path.dirname(INSTALLER), 'uninstall.sh')), '--check'],
			{ env: run.env, encoding: 'utf8', timeout: 60000 }
		);
		assert.equal(uninstall.status, 0, uninstall.stderr);
		const unit = path.join(run.configRoot, 'systemd/user/ergopti-hotstrings.service');
		fs.appendFileSync(unit, '# user modification\n');
		const modified = spawnSync(
			bashExecutable(),
			[bashPath(path.join(path.dirname(INSTALLER), 'uninstall.sh')), '--check'],
			{ env: run.env, encoding: 'utf8', timeout: 60000 }
		);
		assert.notEqual(modified.status, 0, 'a modified service must not be claimed');
		assert.match(fs.readFileSync(unit, 'utf8'), /# user modification/);
	} finally {
		run.cleanup();
	}
}

// Replacing owned startup files preserves their pre-existing access modes.
{
	const run = runInstaller({
		desktopProvided: true,
		seed(home, configRoot) {
			const wrapper = path.join(home, '.local/bin/ergopti-hotstrings');
			const unit = path.join(configRoot, 'systemd/user/ergopti-hotstrings.service');
			const desktop = path.join(configRoot, 'autostart/ergopti-hotstrings.desktop');
			for (const file of [wrapper, unit, desktop])
				fs.mkdirSync(path.dirname(file), { recursive: true });
			fs.writeFileSync(
				wrapper,
				`INSTALL_ROOT=${bashPath(home)}/.local/lib/ergopti\nexec bash "\${INSTALL_ROOT}/bin/ergopti-hotstrings" "$@"\n`,
				{ mode: 0o700 }
			);
			fs.writeFileSync(unit, `ExecStart=${bashPath(wrapper)} --tray\n`, { mode: 0o600 });
			fs.writeFileSync(desktop, `[Desktop Entry]\nExec=${bashPath(wrapper)} --tray\n`, {
				mode: 0o600
			});
		}
	});
	try {
		assert.equal(run.status, 0, run.output);
		assert.equal(
			fs.statSync(path.join(run.home, '.local/bin/ergopti-hotstrings')).mode & 0o777,
			0o700 | (0o111 & ~process.umask())
		);
		assert.equal(
			fs.statSync(path.join(run.configRoot, 'systemd/user/ergopti-hotstrings.service')).mode &
				0o777,
			0o600
		);
		assert.equal(
			fs.statSync(path.join(run.configRoot, 'autostart/ergopti-hotstrings.desktop')).mode & 0o777,
			0o600
		);
	} finally {
		run.cleanup();
	}
}

// A failed XDG generation, chmod or publication leaves the previous entry complete.
for (const fault of ['refuseAutostartWrite', 'refuseAutostartMode', 'refuseAutostartPublish']) {
	const run = runInstaller({
		desktopProvided: true,
		[fault]: true,
		seed(home, configRoot) {
			const file = path.join(configRoot, 'autostart/ergopti-hotstrings.desktop');
			fs.mkdirSync(path.dirname(file), { recursive: true });
			const previous = `[Desktop Entry]\nExec=${bashPath(home)}/.local/bin/ergopti-hotstrings --tray\n# previous\n`;
			fs.writeFileSync(file, previous);
			const library = path.join(home, '.local/lib/ergopti');
			fs.mkdirSync(library, { recursive: true });
			const digest = createHash('sha256').update(previous).digest('hex');
			fs.writeFileSync(path.join(library, '.ergopti-owned-files'), `${digest}\t@autostart\n`);
		}
	});
	try {
		assert.notEqual(run.status, 0);
		const expected =
			fault === 'refuseAutostartWrite'
				? 'write'
				: fault === 'refuseAutostartMode'
					? 'mode'
					: 'publish';
		assert.ok(
			run.output.includes(`[fixture] ${expected}-refused`),
			'the intended failure was reached'
		);
		const directory = path.join(run.configRoot, 'autostart');
		assert.match(
			fs.readFileSync(path.join(directory, 'ergopti-hotstrings.desktop'), 'utf8'),
			/# previous/
		);
		assert.equal(
			fs.readdirSync(directory).filter((name) => name.startsWith('.ergopti-autostart.')).length,
			0
		);
	} finally {
		run.cleanup();
	}
}

// Failed launcher generation, chmod or publication leaves the old file intact.
for (const fault of ['refuseLauncherWrite', 'refuseLauncherMode', 'refuseLauncherPublish']) {
	const run = runInstaller({
		desktopProvided: true,
		noService: true,
		[fault]: true,
		seed(home) {
			const bin = path.join(home, '.local/bin');
			fs.mkdirSync(bin, { recursive: true });
			fs.writeFileSync(
				path.join(bin, 'ergopti-hotstrings'),
				`INSTALL_ROOT=${bashPath(home)}/.local/lib/ergopti\nexec bash "\${INSTALL_ROOT}/bin/ergopti-hotstrings" "$@"\n# previous launcher\n`
			);
		}
	});
	try {
		assert.notEqual(run.status, 0);
		const bin = path.join(run.home, '.local/bin');
		assert.match(
			fs.readFileSync(path.join(bin, 'ergopti-hotstrings'), 'utf8'),
			/# previous launcher/
		);
		assert.equal(
			fs.readdirSync(bin).filter((name) => name.startsWith('.ergopti-launcher.')).length,
			0
		);
	} finally {
		run.cleanup();
	}
}

// A failed service generation, chmod or publication keeps the previous unit
// complete and retires its private temporary file.
for (const fault of ['refuseUnitWrite', 'refuseUnitMode', 'refuseUnitPublish']) {
	const run = runInstaller({
		desktopProvided: true,
		[fault]: true,
		seed(home, configRoot) {
			const unit = path.join(configRoot, 'systemd/user/ergopti-hotstrings.service');
			fs.mkdirSync(path.dirname(unit), { recursive: true });
			fs.writeFileSync(
				unit,
				`[Service]\nExecStart=${bashPath(home)}/.local/bin/ergopti-hotstrings --tray\n# previous unit\n`
			);
		}
	});
	try {
		assert.notEqual(run.status, 0, 'refused publication must stop installation');
		assert.equal(
			fs.readFileSync(path.join(run.configRoot, 'systemd/user/ergopti-hotstrings.service'), 'utf8'),
			`[Service]\nExecStart=${bashPath(run.home)}/.local/bin/ergopti-hotstrings --tray\n# previous unit\n`
		);
		assert.equal(
			fs
				.readdirSync(path.join(run.configRoot, 'systemd/user'))
				.filter((name) => name.startsWith('.ergopti-service.')).length,
			0,
			`${fault} must retire its temporary file`
		);
	} finally {
		run.cleanup();
	}
}

// An update must preserve a choice already made through the startup menu.
for (const format of ['plain', 'crlf', 'spaced', 'numeric']) {
	const run = runInstaller({
		desktopProvided: true,
		systemdEnabled: true,
		seed(home) {
			const directory = path.join(home, '.config/autostart');
			fs.mkdirSync(directory, { recursive: true });
			let entry = `[Desktop Entry]\nType=Application\nName=Ergopti\nExec=${bashPath(home)}/.local/bin/ergopti-hotstrings --tray\nHidden=true\nX-Ergopti-Startup=true\n`;
			if (format === 'crlf') entry = entry.replaceAll('\n', '\r\n');
			if (format === 'numeric')
				entry = entry
					.replace('Hidden=true', 'Hidden=1  ')
					.replace('X-Ergopti-Startup=true', 'X-Ergopti-Startup=1');
			if (format === 'spaced')
				entry = entry
					.replace('Hidden=true', ' Hidden = true')
					.replace('X-Ergopti-Startup=true', ' X-Ergopti-Startup = true');
			fs.writeFileSync(path.join(directory, 'ergopti-hotstrings.desktop'), entry);
		}
	});
	try {
		if (run.status !== 0)
			errors.push(`install with disabled startup failed: ${run.output.slice(-1800)}`);
		const desktop = fs.readFileSync(
			path.join(run.home, '.config/autostart/ergopti-hotstrings.desktop'),
			'utf8'
		);
		if (!/^Hidden=true$/m.test(desktop))
			errors.push('installation re-enabled an explicit startup refusal');
		if (run.calls.some((call) => /systemctl .* (enable|restart|start) /.test(call))) {
			errors.push('installation activated a service despite the disabled startup choice');
		}
		const receipt = fs.readFileSync(
			path.join(run.home, '.local/lib/ergopti/.ergopti-owned-files'),
			'utf8'
		);
		if (/\t@autostart\n/.test(receipt))
			errors.push('a preexisting unowned startup entry must not be adopted');
	} finally {
		run.cleanup();
	}
}

// Reinstallation must not claim a user-customized startup entry.
for (const kind of ['unowned', 'modified', 'owned']) {
	let oldDigest;
	const run = runInstaller({
		desktopProvided: true,
		seed(home) {
			const library = path.join(home, '.local/lib/ergopti');
			const desktop = path.join(home, '.config/autostart/ergopti-hotstrings.desktop');
			const original = `[Desktop Entry]\nExec=${bashPath(home)}/.local/bin/ergopti-hotstrings --tray\nHidden=true\nX-Ergopti-Startup=true\n`;
			oldDigest = createHash('sha256').update(original).digest('hex');
			fs.mkdirSync(path.dirname(desktop), { recursive: true });
			fs.writeFileSync(
				desktop,
				kind === 'owned' ? original : `${original}# personal startup setting\n`
			);
			if (kind !== 'unowned') {
				fs.mkdirSync(library, { recursive: true });
				fs.writeFileSync(path.join(library, '.ergopti-owned-files'), `${oldDigest}\t@autostart\n`);
			}
		}
	});
	try {
		assert.equal(run.status, 0, run.output);
		const desktop = path.join(run.home, '.config/autostart/ergopti-hotstrings.desktop');
		if (kind !== 'owned')
			assert.match(fs.readFileSync(desktop, 'utf8'), /^# personal startup setting$/m);
		const receipt = fs.readFileSync(
			path.join(run.home, '.local/lib/ergopti/.ergopti-owned-files'),
			'utf8'
		);
		const row = receipt.split('\n').find((value) => value.endsWith('\t@autostart'));
		if (kind === 'unowned') assert.equal(row, undefined);
		else if (kind === 'modified') assert.equal(row, `${oldDigest}\t@autostart`);
		else {
			const digest = createHash('sha256').update(fs.readFileSync(desktop)).digest('hex');
			assert.equal(row, `${digest}\t@autostart`);
		}
	} finally {
		run.cleanup();
	}
}

// A manually created compatible entry has its own startup preference and data.
{
	const run = runInstaller({
		desktopProvided: true,
		refuseShow: true,
		seed(home) {
			const desktop = path.join(home, '.config/autostart/ergopti-hotstrings.desktop');
			fs.mkdirSync(path.dirname(desktop), { recursive: true });
			fs.writeFileSync(
				desktop,
				`[Desktop Entry]\nExec=${bashPath(home)}/.local/bin/ergopti-hotstrings --tray\nHidden=true\n# personal manual choice\n`
			);
		}
	});
	try {
		assert.equal(run.status, 0, run.output);
		const desktop = path.join(run.home, '.config/autostart/ergopti-hotstrings.desktop');
		const content = fs.readFileSync(desktop, 'utf8');
		assert.match(content, /^Hidden=true$/m);
		assert.match(content, /^# personal manual choice$/m);
		const receipt = fs.readFileSync(
			path.join(run.home, '.local/lib/ergopti/.ergopti-owned-files'),
			'utf8'
		);
		assert.doesNotMatch(receipt, /\t@autostart\n/);
	} finally {
		run.cleanup();
	}
}

// Existing fallback receipts authorize migration only while bytes still match.
for (const kind of ['owned', 'modified', 'owned-disabled']) {
	const run = runInstaller({
		desktopProvided: true,
		seed(home) {
			const desktop = path.join(home, '.config/autostart/ergopti-hotstrings.desktop');
			const library = path.join(home, '.local/lib/ergopti');
			const original = `[Desktop Entry]\nExec=${bashPath(home)}/.local/bin/ergopti-hotstrings --tray\nHidden=${kind === 'owned' ? 'false' : 'true'}\n`;
			fs.mkdirSync(path.dirname(desktop), { recursive: true });
			fs.mkdirSync(library, { recursive: true });
			fs.writeFileSync(desktop, original + (kind === 'modified' ? '# personal setting\n' : ''));
			fs.writeFileSync(
				path.join(library, '.ergopti-owned-files'),
				`${createHash('sha256').update(original).digest('hex')}\t@autostart\n`
			);
		}
	});
	try {
		assert.equal(run.status, 0, run.output);
		const desktop = path.join(run.home, '.config/autostart/ergopti-hotstrings.desktop');
		const content = fs.readFileSync(desktop, 'utf8');
		if (kind === 'modified') {
			assert.match(content, /^# personal setting$/m);
			assert.match(content, /^Hidden=true$/m);
		} else {
			if (kind === 'owned') assert.match(content, /^X-GNOME-Autostart-enabled=true$/m);
			else assert.match(content, /^Hidden=true$/m);
			const digest = createHash('sha256').update(content).digest('hex');
			assert.ok(
				fs
					.readFileSync(path.join(run.home, '.local/lib/ergopti/.ergopti-owned-files'), 'utf8')
					.includes(`${digest}\t@autostart\n`)
			);
		}
	} finally {
		run.cleanup();
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] install.sh does not leave a working first install:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] install.sh finishes with no remapper to fetch, installs the tray and window backends, and survives a missing optional package.\x1b[0m'
);
