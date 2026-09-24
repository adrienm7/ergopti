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
 * ROOT CAUSE 2 — AN EARLIER INSTALL'S KANATA UNIT KEPT GRABBING THE KEYBOARD.
 * Installs before the in-daemon engine enabled a kanata user unit. Left in
 * place, it would grab the keyboard first and apply every tap-hold twice. A
 * re-install must retire the unit Ergopti wrote, and only that one: a kanata
 * unit the user set up is theirs.
 *
 * ROOT CAUSE 3 — THE DESKTOP HALF WAS NEVER INSTALLED.
 * The tray's libayatana-appindicator and the windows' WebKit2GTK typelib were
 * left to the user, so a fresh install showed no tray icon anywhere. Each must
 * be requested from the package manager when its probe fails.
 *
 * ROOT CAUSE 4 — AN OPTIONAL LUA PACKAGE ABSENT FROM THE ARCHIVE ABORTED IT.
 * lua-http does not exist on Arch, lua-filesystem not on openSUSE; the package
 * manager failed under `set -e` and the script died before copying the driver.
 * The names were also Lua 5.4 builds there, invisible to LuaJIT. An optional
 * module that cannot be installed must be reported and skipped.
 *
 * ROOT CAUSE 5 — ALPINE WAS REFUSED OUTRIGHT.
 * apk lives in /sbin, absent from an ordinary Alpine user's PATH, so the
 * manager was detected as "unknown" and every dependency refused; and the
 * group setup called usermod, which BusyBox does not ship, under set -e.
 *
 * ROOT CAUSE 6 — ON GNOME THE ICON WAS REGISTERED AND NEVER SHOWN.
 * GNOME Shell hosts no StatusNotifierItem without an extension; Ubuntu enables
 * its own, Fedora and Debian GNOME do not. The installer now installs and
 * enables the AppIndicator extension there, merged into the user's list.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const INSTALLER = path.join(ROOT, 'static', 'ergopti_plus', 'linux', 'install.sh');

function bashPath(value) {
	const normalized = value.replaceAll('\\', '/');
	if (process.platform !== 'win32') return normalized;
	return normalized.replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);
}

function bashExecutable() {
	if (process.platform !== 'win32') return 'bash';
	const candidates = [
		path.join(process.env.ProgramFiles || 'C:\\Program Files', 'Git', 'bin', 'bash.exe'),
		path.join(process.env.LOCALAPPDATA || '', 'Programs', 'Git', 'bin', 'bash.exe')
	];
	const found = candidates.find((candidate) => fs.existsSync(candidate));
	if (!found) throw new Error('Git Bash is required to run the Linux installer sandbox');
	return found;
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
	const stubs = path.join(sandbox, 'stubs');
	const callLog = path.join(sandbox, 'calls.log');
	const state = path.join(sandbox, 'state');
	fs.mkdirSync(home);
	fs.mkdirSync(stubs);
	fs.mkdirSync(state);
	if (scenario.seed) scenario.seed(home);
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
	stub(stubs, 'systemctl', `${log}\nexit 1`);
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
	// Every command a real system would provide.
	for (const name of ['notify-send', 'zenity', 'sqlite3', 'xkbcli', 'sha256sum']) stub(stubs, name, 'exit 0');
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
		...(scenario.gnome ? { XDG_CURRENT_DESKTOP: 'ubuntu:GNOME' } : {}),
		HOME: bashPath(home),
		PATH: `${bashPath(stubs)}:/usr/bin:/bin`,
		TMPDIR: bashPath(sandbox),
		LANG: 'C.UTF-8'
	};
	const result = spawnSync(bashExecutable(), [bashPath(INSTALLER)], { env, encoding: 'utf8', timeout: 60000 });
	const calls = fs.existsSync(callLog) ? fs.readFileSync(callLog, 'utf8').split('\n').filter(Boolean) : [];
	return {
		status: result.status,
		output: `${result.stdout || ''}${result.stderr || ''}`,
		home,
		stubs,
		calls,
		cleanup: () => fs.rmSync(sandbox, { recursive: true, force: true })
	};
}

const errors = [];

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
		const daemon = path.join(run.home, '.local', 'lib', 'ergopti', 'linux', 'ergopti_hotstrings.lua');
		if (!fs.existsSync(daemon)) errors.push('the driver tree was not copied');
		// Root cause 1: the tap-holds run in the daemon; nothing kanata is installed.
		if (fs.existsSync(path.join(run.home, '.config', 'systemd', 'user', 'kanata.service'))) {
			errors.push('install.sh still writes a kanata.service although the daemon runs the tap-holds');
		}
		if (fs.existsSync(path.join(run.home, '.config', 'kanata'))) {
			errors.push('install.sh still writes a kanata configuration although the daemon runs the tap-holds');
		}
		if (run.calls.some((call) => call.startsWith('curl') || /kanata/.test(call))) {
			errors.push(
				`install.sh still downloads or manages kanata: ${run.calls.filter((c) => c.startsWith('curl') || /kanata/.test(c)).join(' | ')}`
			);
		}
		// Root cause 3: both desktop backends were requested and re-probed.
		for (const pkg of ['libayatana-appindicator3-1', 'gir1.2-webkit2-4.1']) {
			if (!run.calls.some((call) => call.startsWith('sudo apt-get install') && call.includes(pkg))) {
				errors.push(`install.sh never asked the package manager for ${pkg}`);
			}
		}
		if (!/icône de la barre système \(libayatana-appindicator\) — capacité vérifiée/.test(run.output)) {
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
		if (!/posix \(signaux SIGTERM\/SIGHUP\) indisponible pour LuaJIT/.test(run.output)) {
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
		for (const group of ['input', 'uinput']) {
			if (!run.calls.some((call) => new RegExp(`^sudo addgroup \\S+ ${group}$`).test(call))) {
				errors.push(`the user was not added to ${group} through BusyBox's addgroup`);
			}
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
	const functions = (source.match(/_has_manager\(\) \{[\s\S]*?\n\}\n\n_detect_pkg_manager\(\) \{[\s\S]*?\n\}/) || [])[0];
	if (!functions) {
		errors.push('_has_manager/_detect_pkg_manager not found — the detection fixture did not run');
	} else {
		const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-sbin-'));
		try {
			fs.mkdirSync(path.join(fixture, 'sbin'));
			fs.mkdirSync(path.join(fixture, 'usr-sbin'));
			stub(path.join(fixture, 'sbin'), 'apk', 'exit 0');
			const harness = functions
				.replaceAll('"/sbin/$1"', `"${bashPath(fixture)}/sbin/$1"`)
				.replaceAll('"/usr/sbin/$1"', `"${bashPath(fixture)}/usr-sbin/$1"`) + '\n_detect_pkg_manager\n';
			// The interpreter is resolved with the caller's PATH; the script then
			// runs with an empty one, which is the point.
			const detected = spawnSync(bashExecutable(), ['-c', `PATH=\n${harness}`], { encoding: 'utf8' });
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
		if (!run.calls.some((call) => call.startsWith('sudo apt-get install') && call.includes('gnome-shell-extension-appindicator'))) {
			errors.push('GNOME without an AppIndicator extension: the extension was not installed');
		}
		const set = run.calls.find((call) => call.startsWith('gsettings set org.gnome.shell enabled-extensions'));
		const expected = "['user-theme@gnome-shell-extensions.gcampax.github.com', 'appindicatorsupport@rgcjonas.gmail.com']";
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

// ── The kanata unit an earlier install wrote ───────────────────────────────
/** Seeds a kanata user unit with the given Description line, plus Ergopti's layout. */
function seedKanataUnit(description) {
	return (home) => {
		const unitDir = path.join(home, '.config', 'systemd', 'user');
		fs.mkdirSync(unitDir, { recursive: true });
		fs.writeFileSync(
			path.join(unitDir, 'kanata.service'),
			`[Unit]\n${description}\n[Service]\nExecStart=/usr/bin/kanata\n`,
			'utf8'
		);
		fs.mkdirSync(path.join(home, '.config', 'kanata'), { recursive: true });
		fs.writeFileSync(path.join(home, '.config', 'kanata', 'ergopti.kbd'), '(defcfg)\n', 'utf8');
	};
}
{
	const run = runInstaller({
		desktopProvided: true,
		seed: seedKanataUnit('Description=Kanata key remapping daemon (Ergopti)')
	});
	try {
		if (run.status !== 0) errors.push(`install.sh exited ${run.status} over an earlier install's kanata unit`);
		if (fs.existsSync(path.join(run.home, '.config', 'systemd', 'user', 'kanata.service'))) {
			errors.push('the kanata unit an earlier install wrote was left in place — it would apply every tap-hold twice');
		}
		if (fs.existsSync(path.join(run.home, '.config', 'kanata', 'ergopti.kbd'))) {
			errors.push("the earlier install's ~/.config/kanata/ergopti.kbd was left behind");
		}
		if (!run.calls.some((call) => call === 'systemctl --user disable --now kanata.service')) {
			errors.push('the earlier kanata unit was deleted without being stopped and disabled first');
		}
		if (run.calls.some((call) => /appindicator|webkit2/.test(call))) {
			errors.push('desktop backends that were already present were installed again');
		}
	} finally {
		run.cleanup();
	}
}
{
	const run = runInstaller({ desktopProvided: true, seed: seedKanataUnit('Description=my kanata') });
	try {
		if (run.status !== 0) errors.push(`install.sh exited ${run.status} next to a user's own kanata unit`);
		if (!fs.existsSync(path.join(run.home, '.config', 'systemd', 'user', 'kanata.service'))) {
			errors.push('a kanata unit the user set up was deleted — only the one Ergopti wrote may be retired');
		}
		if (run.calls.some((call) => /kanata/.test(call))) {
			errors.push("a kanata unit the user set up was stopped or disabled");
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
	'\x1b[32m[OK] install.sh finishes with no remapper to fetch, retires only the kanata unit an earlier install wrote, installs the tray and window backends, and survives a missing optional package.\x1b[0m'
);
