// tools/test/test-linux-portable-commands.cjs

/**
 * ==============================================================================
 * MODULE: Linux Portable Commands Gate
 * DESCRIPTION:
 * The Linux driver, its installer scripts and its tests run on minimal Arch,
 * Fedora and openSUSE container images, which ship far fewer programs than the
 * Ubuntu runner a developer works on. A program that exists on Debian and not
 * there fails only in the distribution matrix, minutes into a CI run, with a
 * confusing symptom (a device key built from an empty string, a fixture that
 * never reads its record).
 *
 * ROOT CAUSE — A PROGRAM THE MINIMAL IMAGES DO NOT SHIP.
 * Two Linux tests launched `hostname` (and one linked it into a private PATH).
 * Debian has it; minimal Arch, Fedora and openSUSE images do not, and the
 * driver itself reads /proc/sys/kernel/hostname. The bug surfaced late in CI
 * (100e42bc65 and 80802ed0dc). This gate makes the class fail in seconds on any
 * host: it lists every external program the Linux code launches and refuses one
 * that is neither in every minimal image, installed by the CI image preparation,
 * nor declared as a runtime dependency.
 *
 * WHAT IS INVENTORIED (static/ergopti_plus/linux, tracked files only):
 *   - Lua: io.popen and os.execute (also through pcall and a local alias), the
 *     ShellRunner helpers (run, exec, exec_line, exec_checked, with_stdin,
 *     exec_stdin, with_exact_stdin, exec_exact_stdin take a shell string;
 *     has_command and run_async take a program), ProcessRunner.run,
 *     ProgramRunner.spawn and available, OwnedProcess.start, uv.spawn and
 *     luv.spawn.
 *   - Python: subprocess.*, os.system, os.popen, os.exec*, os.spawn*,
 *     asyncio.create_subprocess_* and shutil.which.
 *   - Shell scripts: every simple command, including `command -v`, command
 *     substitutions, `sh -c` payloads, `find -exec` targets and the program
 *     behind a wrapper such as sudo, env or timeout.
 * Comments are removed by a lexer first, so commented-out code is no call site.
 *
 * WHAT IS SKIPPED, ON PURPOSE, AND NAMED IN THE REPORT:
 *   - a program that is not a literal once the nearest visible `name = "..."` of
 *     the same file is resolved (a parameter, a table field, a shell variable):
 *     counted as "dynamic" with its file:line;
 *   - a path inside the repository (`./run.sh`, `tests/x.sh`) and a function
 *     defined by a scanned shell script;
 *   - heredoc bodies and code handed to an interpreter (python3 -c, luajit -e):
 *     data, not shell, unless the receiving program is a shell;
 *   - JavaScript files under the Linux tree, the .service unit, the vendor,
 *     _generated and native directories and EXCLUDED_FILES (the Windows-hosted
 *     compatibility shim of the Lua runner).
 *   - what no call site shows: a command stored in a table field and run later
 *     (the clipboard backends), a program chosen at run time. The probes of the
 *     same tools (has_command) are call sites, which keeps most of them in view.
 * Shell builtins are listed in SHELL_BUILTINS and never reach the reference.
 *
 * REFERENCE: ONE LIST. PROGRAMS states, for each program, why it may be launched.
 * An entry that claims "installed by CI" or "declared dependency" names the file
 * and the token that proves it, and this gate reads that file, so a dropped
 * package cannot leave a stale justification behind. An entry no call site uses
 * fails too, so the list never outlives the code.
 *
 * SCOPES. A launch is judged where its file runs: "driver" (a user's machine:
 * driver, installer, launcher), "test" (the distribution containers, which hold
 * only the CI image preparation) or "host" (tests/hardware and the other files that
 * only the Ubuntu runners execute). An entry lists the scopes it is valid for, and
 * a machine-checked proof must back each of them: a file proof this gate reads
 * (an install by CI, a declared dependency, the container entry point of every
 * image), bound to the scopes it covers, or a probe of the program in every file
 * of the probed scopes that launches it, host scripts included. No program
 * rests on its justification alone, and an entry with a scope neither proven
 * nor probed is refused.
 *
 * FIXTURES. A launch of an absolute path under no top-level directory a Linux
 * system creates (anything outside FHS_ROOTS, such as /nonexistent) cannot run
 * any installed program: it is a refusal fixture of a test, recognised by that
 * structure and never listed. The same path in a driver file is refused.
 *
 * The scan is floored (FLOORS) so a broken scanner cannot pass by finding nothing,
 * and a self-test proves the scanner reports io.popen("hostname") and ignores the
 * same call inside a comment. The two commits above are also caught in their
 * original form: the `for` loop that linked "mkdir" and "hostname" is followed.
 *
 * DEBUGGING: ERGOPTI_PORTABLE_COMMANDS_REPORT=1 prints the whole inventory.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const LINUX_DIR = 'static/ergopti_plus/linux';

// Placeholder for a part of a command that is not a literal.
const DYN = '\u0001';

// Floors on what the scanner must find on the current tree, so a lexer or a call
// matcher that silently stopped working cannot pass by finding nothing. Measured
// on 2026-10-25: 1400 call sites (760 Lua, 464 shell, 176 Python), 1085 of them
// resolved to a program name, 144 distinct programs. Each floor sits about 10%
// below its measure; raise it only after the measure grew for good.
const FLOORS = Object.freeze({ total: 1250, lua: 650, shell: 400, python: 150, resolved: 950 });

// ========================================
// ========================================
// ======= 1/ Reference Of Programs =======
// ========================================
// ========================================

/** Programs the shell executes itself, which no image has to ship. */
const SHELL_BUILTINS = new Set([
	'.',
	':',
	'[',
	'[[',
	'alias',
	'bg',
	'break',
	'builtin',
	'cd',
	'command',
	'continue',
	'declare',
	'echo',
	'eval',
	'exec',
	'exit',
	'export',
	'false',
	'fg',
	'getopts',
	'hash',
	'jobs',
	'kill',
	'let',
	'local',
	'mapfile',
	'printf',
	'pwd',
	'read',
	'readarray',
	'readonly',
	'return',
	'set',
	'shift',
	'shopt',
	'source',
	'test',
	'times',
	'trap',
	'true',
	'type',
	'typeset',
	'ulimit',
	'umask',
	'unalias',
	'unset',
	'wait'
]);

/** Directories whose programs are named by their base name. */
const SYSTEM_DIRS = new Set(['/bin', '/sbin', '/usr/bin', '/usr/sbin', '/usr/local/bin']);

/** Programs that run the program written after their own options. */
const WRAPPERS = new Map([
	// name: [options that take a value, positional words to skip before the program]
	['env', [['-u', '-C', '-S'], 0]],
	['sudo', [['-u', '-g', '-h', '-p', '-C', '-D', '-R', '-T', '-U'], 0]],
	['nohup', [[], 0]],
	['setsid', [[], 0]],
	['nice', [['-n'], 0]],
	['ionice', [['-c', '-n', '-p'], 0]],
	['timeout', [['-s', '-k'], 1]],
	['stdbuf', [['-i', '-o', '-e'], 0]],
	['xargs', [['-I', '-n', '-P', '-L', '-d', '-E', '-s'], 0]],
	['flock', [['-w', '-E'], 1]],
	['pkexec', [['--user'], 0]]
]);

const SHELLS = new Set(['sh', 'bash', 'dash', 'zsh']);

const MATRIX_JSON = '.github/linux-install-matrix.json';
const DISTRO_PREP = 'tools/test/prepare-linux-distro-unit.sh';
const CI_LINUX = '.github/workflows/ci-linux.yml';
const INSTALLER = `${LINUX_DIR}/install.sh`;
const DEB_RECIPE = 'tools/build/build-linux-deb.sh';
const RPM_RECIPE = 'tools/build/build-linux-rpm.sh';
const DISTRO_RUNNER = 'tools/test/run-linux-distro-unit.sh';

// Where a program may be launched. "driver" is a user's machine (the driver, the
// installer and the launcher), "test" the distribution containers that run the
// unit suite, "host" the Ubuntu runners of the hardware and desktop lanes.
const ALL = ['driver', 'test', 'host'];
const DRIVER = ['driver'];
const DRIVER_TEST = ['driver', 'test'];
const DRIVER_HOST = ['driver', 'host'];
const TEST = ['test'];
const HOST = ['host'];

/**
 * One justification and its machine-checked evidence, per scope. Each of
 * `proofs` (or the single `proof`) names a file and a pattern this gate reads,
 * so the claim cannot outlive its evidence; it covers its own `scopes`, or all
 * of the entry's. `probed` (true for every scope of the entry, or a list of
 * scopes) demands a `command -v` (or has_command) of the program in every file
 * of those scopes that launches it, proof or not. Every scope of an entry is
 * probed or covered by a proof, or the entry is refused: no program rests on
 * its justification alone.
 */
function why(text, scopes, { proof = null, proofs = null, probed = false } = {}) {
	const cited = (proofs ?? (proof ? [proof] : [])).map((item) => ({
		...item,
		scopes: item.scopes ?? scopes
	}));
	return { why: text, scopes, proofs: cited, probed: probed === true ? scopes : probed || [] };
}

const inMatrix = (token, text) =>
	why(`${text}; installed by CI: ${MATRIX_JSON} prep`, ALL, {
		proof: { file: MATRIX_JSON, token }
	});
const inPrep = (token, text) =>
	why(`${text}; installed by CI: ${DISTRO_PREP}`, ALL, { proof: { file: DISTRO_PREP, token } });
const inUbuntuJob = (token, text) =>
	why(`${text}; installed on the Ubuntu runner by ${CI_LINUX}`, HOST, {
		proof: { file: CI_LINUX, token }
	});
const declaredByInstaller = (name, text, scopes = DRIVER) =>
	why(`${text}; declared dependency: install.sh _check_or_install`, scopes, {
		proof: { file: INSTALLER, token: `_check_or_install ${name}\\b` }
	});
const declaredByDeb = (token, text, scopes = DRIVER) =>
	why(`${text}; declared dependency: ${DEB_RECIPE} Depends`, scopes, {
		proof: { file: DEB_RECIPE, token: `Depends:.*\\b${token}\\b` }
	});
const recommendedByDeb = (token, text, scopes = DRIVER) =>
	why(`${text}; declared optional dependency: ${DEB_RECIPE} Recommends`, scopes, {
		proof: { file: DEB_RECIPE, token: `Recommends:.*\\b${token}\\b` }
	});
const optionalTool = (text, scopes = DRIVER) =>
	why(`${text}; optional tool, absent means the feature is off, probed before use`, scopes, {
		probed: true
	});
const packageManager = (text, scopes) =>
	why(`${text}; detected with command -v in every file that runs it`, scopes, { probed: true });
const coreutils = why(`coreutils; installed by CI: ${MATRIX_JSON} prep`, ALL, {
	proof: { file: MATRIX_JSON, token: 'coreutils' }
});

/**
 * Top-level directories a Linux system creates: the FHS ones, plus the stores
 * of Nix, Guix, Snap and Flatpak. A program under any other root cannot be
 * installed, so launching it can only be a test's refusal fixture.
 */
const FHS_ROOTS = new Set([
	'app',
	'bin',
	'boot',
	'dev',
	'etc',
	'gnu',
	'home',
	'lib',
	'lib32',
	'lib64',
	'libx32',
	'media',
	'mnt',
	'nix',
	'opt',
	'proc',
	'root',
	'run',
	'sbin',
	'snap',
	'srv',
	'sys',
	'tmp',
	'usr',
	'var'
]);

/** Whether a program name is an absolute path no Linux system can hold. */
function isUnrunnablePath(name) {
	const top = /^\/([^/]+)\//.exec(name)?.[1];
	return top !== undefined && !FHS_ROOTS.has(top);
}

/** Files outside the scan, with the reason. */
const EXCLUDED_FILES = new Map([
	[
		`${LINUX_DIR}/tests/win_compat.lua`,
		'the Windows-hosted compatibility shim of the Lua runner (cmd, ping), never loaded on Linux'
	]
]);

/** Files that run on the Ubuntu runners although they sit outside tests/hardware. */
const HOST_FILES = new Map([
	[
		`${LINUX_DIR}/tests/support/ui/healthcheck/run_native_desktop_report.py`,
		'drives a real Xvfb, not referenced by the distribution lanes'
	]
]);

/**
 * Reference of every program Linux code may launch, keyed by program name (the
 * absolute path when it is outside SYSTEM_DIRS). One line each, with its proof.
 */
const PROGRAMS = {
	// Every minimal image: coreutils, which the CI image preparation installs explicitly.
	basename: coreutils,
	cat: coreutils,
	chmod: coreutils,
	chown: coreutils,
	cp: coreutils,
	cut: coreutils,
	date: coreutils,
	df: coreutils,
	dirname: coreutils,
	env: coreutils,
	head: coreutils,
	id: coreutils,
	install: coreutils,
	ln: coreutils,
	ls: coreutils,
	mkdir: coreutils,
	mkfifo: coreutils,
	mktemp: coreutils,
	mv: coreutils,
	printf: coreutils,
	readlink: coreutils,
	rm: coreutils,
	rmdir: coreutils,
	seq: coreutils,
	sha256sum: coreutils,
	sleep: coreutils,
	stat: coreutils,
	tail: coreutils,
	tee: coreutils,
	timeout: coreutils,
	touch: coreutils,
	tr: coreutils,
	uname: coreutils,
	wc: coreutils,
	bash: inMatrix('\\bbash\\b', 'the shell the scripts name'),
	// Both container entry points start every distribution image of the matrix
	// through sh before anything is installed: an image without it fails at once.
	sh: why('the POSIX shell, run by the entry point of every distribution image', ALL, {
		proofs: [
			{ file: DISTRO_RUNNER, token: '"\\$image" sh -c ' },
			{ file: `${LINUX_DIR}/tests/distro/run_in_docker.sh`, token: '"\\$\\{IMAGE\\}" sh -c ' }
		]
	}),
	find: inMatrix('findutils', 'findutils'),
	grep: inMatrix('\\bgrep\\b', 'grep'),
	sed: inMatrix('\\bsed\\b', 'sed'),
	sudo: inMatrix('\\bsudo\\b', 'sudo'),
	useradd: inMatrix('shadow|passwd', 'shadow'),
	usermod: inMatrix('shadow|passwd', 'shadow (BusyBox addgroup is the Alpine branch)'),
	groupadd: inMatrix('shadow|passwd', 'shadow (BusyBox addgroup is the Alpine branch)'),
	addgroup: why(
		'BusyBox applet, reached only when usermod or groupadd is absent (Alpine)',
		DRIVER,
		{
			proof: { file: `${LINUX_DIR}/install/setup_permissions.sh`, token: 'command -v usermod' }
		}
	),
	adduser: why('BusyBox applet, reached only after useradd failed (Alpine)', TEST, {
		proof: {
			file: `${LINUX_DIR}/tests/distro/e2e_install.sh`,
			token: 'useradd -m .*\\|\\| adduser'
		}
	}),
	getent: why(
		'the C library package (glibc, musl-utils); every launching script refuses without it',
		DRIVER_TEST,
		{
			probed: true
		}
	),
	su: why(
		'util-linux (BusyBox on Alpine); the first-install lane refuses an image without it',
		TEST,
		{
			probed: true
		}
	),
	// Installed by the CI image preparation of the distribution lanes.
	git: inPrep('\\bgit\\b', 'git'),
	cmake: inPrep('cmake', 'cmake'),
	'pkg-config': inPrep('pkg-config|pkgconf', 'pkg-config'),
	curl: inPrep('\\bcurl\\b', 'curl'),
	python3: inPrep('python3', 'the Python the fixtures spawn'),
	luajit: inPrep('luajit', 'the production interpreter'),
	// Declared runtime dependencies (packages and install.sh).
	xclip: declaredByDeb('xclip', 'clipboard on X11', DRIVER_HOST),
	'notify-send': declaredByInstaller('notify-send', 'desktop notifications'),
	zenity: declaredByInstaller('zenity', 'dialogs'),
	sqlite3: why(
		'declared dependency: install.sh _check_or_install sqlite3, and every driver and test launch probes it first; the Ubuntu jobs install it',
		ALL,
		{
			proofs: [
				{ file: INSTALLER, token: '_check_or_install sqlite3\\b', scopes: DRIVER },
				{ file: CI_LINUX, token: 'ubuntu_apt\\.py.* sqlite3\\b', scopes: HOST }
			],
			probed: DRIVER_TEST
		}
	),
	openssl: declaredByInstaller('openssl', 'hashing and the TLS helper', DRIVER_HOST),
	xkbcli: declaredByInstaller('xkbcli', 'keymap compilation', DRIVER_HOST),
	pkexec: declaredByDeb('pkexec', 'privileged permission setup'),
	modprobe: declaredByDeb('kmod', 'loads the uinput module'),
	udevadm: declaredByDeb('udev', 'reloads the uinput rules'),
	flock: declaredByDeb('util-linux', 'single-instance lock', DRIVER_HOST),
	xdotool: recommendedByDeb('xdotool', 'focused window and screen geometry on X11', DRIVER_HOST),
	wmctrl: recommendedByDeb('wmctrl', 'window list on X11'),
	'wl-copy': why(
		`clipboard on Wayland; declared optional dependency: ${DEB_RECIPE} Recommends, probed before use`,
		DRIVER_HOST,
		{
			proof: { file: DEB_RECIPE, token: 'Recommends:.*\\bwl-clipboard\\b' },
			probed: true
		}
	),
	'wl-paste': why(
		`clipboard on Wayland; declared optional dependency: ${DEB_RECIPE} Recommends, probed before use`,
		DRIVER,
		{
			proof: { file: DEB_RECIPE, token: 'Recommends:.*\\bwl-clipboard\\b' },
			probed: true
		}
	),
	// Optional desktop and system tools: probed before use in every launching file.
	xsel: optionalTool('clipboard fallback on X11', DRIVER_HOST),
	gdbus: optionalTool('GNOME tooltip preview', DRIVER_HOST),
	systemctl: optionalTool('systemd user service', DRIVER_HOST),
	pactl: why(
		'PulseAudio volume metric; probed before use, and the audio lane of the Ubuntu runner installs it',
		DRIVER_HOST,
		{ proof: { file: CI_LINUX, token: 'pulseaudio-utils', scopes: HOST }, probed: DRIVER }
	),
	kdialog: optionalTool('KDE dialogs'),
	amixer: optionalTool('ALSA volume metric'),
	nmcli: optionalTool('network metric'),
	iwgetid: optionalTool('Wi-Fi metric'),
	'gnome-extensions': optionalTool('AppIndicator extension on GNOME'),
	loginctl: optionalTool('logind sessions'),
	tar: why('the installer probes it and refuses clearly when absent', DRIVER_HOST, {
		probed: true
	}),
	localectl: optionalTool('system keyboard layout of systemd-localed'),
	gsettings: optionalTool('GNOME settings'),
	xrandr: optionalTool(
		'action picker window switching, the menu row is disabled with a reason when absent'
	),
	xprop: optionalTool(
		'action picker window switching, the menu row is disabled with a reason when absent'
	),
	xwininfo: optionalTool(
		'action picker window switching, the menu row is disabled with a reason when absent'
	),
	'gnome-control-center': optionalTool(
		'opens the system settings, the first of several applications that is present'
	),
	systemsettings: optionalTool(
		'opens the system settings, the first of several applications that is present'
	),
	'xfce4-settings-manager': optionalTool(
		'opens the system settings, the first of several applications that is present'
	),
	'cinnamon-settings': optionalTool(
		'opens the system settings, the first of several applications that is present'
	),
	'mate-control-center': optionalTool(
		'opens the system settings, the first of several applications that is present'
	),
	'lxqt-config': optionalTool(
		'opens the system settings, the first of several applications that is present'
	),
	qdbus: optionalTool('KDE workspace switching, the first present of several binaries'),
	'qdbus-qt5': optionalTool('KDE workspace switching, the first present of several binaries'),
	'qdbus-qt6': optionalTool('KDE workspace switching, the first present of several binaries'),
	qdbus6: optionalTool('KDE workspace switching, the first present of several binaries'),
	hyprctl: optionalTool('Hyprland window identity'),
	swaymsg: optionalTool('Sway window identity', DRIVER_HOST),
	niri: optionalTool('Niri window identity'),
	'xdg-open': why(
		`opens links and files; declared dependency: install.sh _check_or_install, ${DEB_RECIPE} Depends and ${RPM_RECIPE} Requires`,
		DRIVER,
		{
			proofs: [
				{ file: INSTALLER, token: '_check_or_install xdg-open\\b' },
				{ file: DEB_RECIPE, token: 'Depends:.*\\bxdg-utils\\b' },
				{ file: RPM_RECIPE, token: 'Requires: +xdg-utils\\b' }
			]
		}
	),
	// The driver reads /proc instead; the hardware lanes probe procps first.
	ps: optionalTool('procps process listing of the hardware lanes', HOST),
	node: why('reads the version for install.sh and falls back to "dev"', DRIVER_HOST, {
		proof: { file: INSTALLER, token: '\\|\\| echo "dev"' }
	}),
	// Package managers: each distribution's own, reached through the detection of install.sh.
	'apt-get': packageManager('the Debian package manager', DRIVER_TEST),
	'apt-cache': packageManager('the Debian package database', DRIVER_TEST),
	'dpkg-query': why('the Debian package database, probed by uninstall.sh', DRIVER, {
		probed: true
	}),
	dnf: packageManager('the Fedora package manager', DRIVER_TEST),
	rpm: why('the RPM database, probed by uninstall.sh', DRIVER, { probed: true }),
	pacman: packageManager('the Arch package manager', DRIVER_TEST),
	zypper: packageManager('the openSUSE package manager', DRIVER_TEST),
	apk: packageManager('the Alpine package manager', DRIVER_TEST),
	'xbps-install': packageManager('the Void package manager', DRIVER),
	'update-ca-certificates': why(
		'Debian CA tool of the first-install lane, probed before use',
		TEST,
		{ probed: true }
	),
	'update-ca-trust': why('Fedora CA tool of the first-install lane, probed before use', TEST, {
		probed: true
	}),
	trust: why('p11-kit CA tool of the first-install lane, probed before use', TEST, {
		probed: true
	}),
	// Only where a test chooses it: a Lua interpreter's compiler, a fake, a Windows branch.
	luac: why('compiler of the PUC Lua developer path, never reached on LuaJIT', TEST, {
		proof: {
			file: `${LINUX_DIR}/tests/meta/architecture/test_parse_coverage.lua`,
			token: 'if jit then'
		}
	}),
	cmd: why('cmd.exe, in the Windows branch of a portable test', TEST, {
		proof: {
			file: `${LINUX_DIR}/tests/unit/infra/config/test_paths_shared_root_layouts.lua`,
			token: 'package\\.config:sub\\(1, 1\\) == "\\\\\\\\"'
		}
	}),
	// The Ubuntu runners of the hardware and desktop lanes.
	Xvfb: inUbuntuJob('xvfb', 'X server'),
	'xvfb-run': inUbuntuJob('xvfb', 'X server wrapper'),
	openbox: inUbuntuJob('openbox', 'window manager'),
	dunst: inUbuntuJob('dunst', 'notification daemon'),
	'dbus-launch': inUbuntuJob('dbus-x11', 'session bus'),
	'dbus-daemon': inUbuntuJob('\\bdbus\\b', 'session bus'),
	'dbus-send': inUbuntuJob('\\bdbus\\b', 'bus client'),
	'dbus-monitor': inUbuntuJob('\\bdbus\\b', 'bus monitor'),
	'dbus-run-session': inUbuntuJob('\\bdbus\\b', 'session bus wrapper'),
	xev: inUbuntuJob('x11-utils', 'key event viewer'),
	xmessage: inUbuntuJob('x11-utils', 'window fixture'),
	setxkbmap: inUbuntuJob('x11-xkb-utils', 'keymap setter'),
	xkbcomp: inUbuntuJob('x11-xkb-utils', 'keymap compiler'),
	strace: inUbuntuJob('strace', 'syscall tracer'),
	zstd: inUbuntuJob('zstd', 'archive tool'),
	sway: inUbuntuJob('\\bsway\\b', 'Wayland compositor'),
	pulseaudio: inUbuntuJob('pulseaudio', 'sound server'),
	lua: inUbuntuJob('lua5\\.4', 'Lua interpreter'),
	'lua5.4': inUbuntuJob('lua5\\.4', 'Lua interpreter'),
	mount: inUbuntuJob('util-linux', 'util-linux'),
	umount: inUbuntuJob('util-linux', 'util-linux'),
	findmnt: inUbuntuJob('util-linux', 'util-linux'),
	setpriv: inUbuntuJob('util-linux', 'util-linux'),
	pkill: optionalTool('procps, in the Ubuntu runner image', HOST),
	docker: optionalTool('the container engine this script drives from the developer host', HOST)
};

// ======================================
// ======================================
// ======= 2/ Lexers For Comments =======
// ======================================
// ======================================

/**
 * Lexes Lua into name, str, num and op tokens, dropping comments. Strings are
 * decoded so the shell analysis sees the real command text.
 */
function lexLua(src) {
	const tokens = [];
	const n = src.length;
	let i = 0;
	let line = 1;
	if (src.startsWith('#')) {
		while (i < n && src[i] !== '\n') i++;
	}
	const longOpen = /\[(=*)\[/y;
	const numberRe =
		/0[xX][0-9a-fA-F.]+(?:[pP][+-]?\d+)?|\d+\.?\d*(?:[eE][+-]?\d+)?|\.\d+(?:[eE][+-]?\d+)?/y;
	const nameRe = /[A-Za-z_][A-Za-z0-9_]*/y;
	const readLong = (from) => {
		longOpen.lastIndex = from;
		const m = longOpen.exec(src);
		if (!m) return null;
		const close = `]${m[1]}]`;
		const end = src.indexOf(close, from + m[0].length);
		if (end === -1) throw new Error(`unterminated long bracket at line ${line}`);
		let body = src.slice(from + m[0].length, end);
		if (body.startsWith('\r\n')) body = body.slice(2);
		else if (body.startsWith('\n')) body = body.slice(1);
		return { body, next: end + close.length, raw: src.slice(from, end + close.length) };
	};
	const countLines = (text) => (text.match(/\n/g) || []).length;
	while (i < n) {
		const c = src[i];
		if (c === '\n') {
			line++;
			i++;
		} else if (c === ' ' || c === '\t' || c === '\r' || c === '\f' || c === '\v') {
			i++;
		} else if (c === '-' && src[i + 1] === '-') {
			i += 2;
			const long = src[i] === '[' ? readLong(i) : null;
			if (long) {
				line += countLines(long.raw);
				i = long.next;
			} else {
				while (i < n && src[i] !== '\n') i++;
			}
		} else if (c === '"' || c === "'") {
			const start = line;
			let value = '';
			i++;
			for (;;) {
				if (i >= n || src[i] === '\n') throw new Error(`unterminated string at line ${start}`);
				const ch = src[i];
				if (ch === c) {
					i++;
					break;
				}
				if (ch !== '\\') {
					value += ch;
					i++;
					continue;
				}
				const e = src[i + 1];
				i += 2;
				const simple = { n: '\n', t: '\t', r: '\r', a: '\x07', b: '\b', f: '\f', v: '\v' };
				if (e in simple) value += simple[e];
				else if (e === '\n') {
					value += '\n';
					line++;
				} else if (e === 'z') {
					while (i < n && /\s/.test(src[i])) {
						if (src[i] === '\n') line++;
						i++;
					}
				} else if (e === 'x') {
					value += String.fromCharCode(parseInt(src.slice(i, i + 2), 16));
					i += 2;
				} else if (/\d/.test(e)) {
					let digits = e;
					while (digits.length < 3 && /\d/.test(src[i] || '')) digits += src[i++];
					value += String.fromCharCode(Number(digits));
				} else if (e === 'u' && src[i] === '{') {
					const close = src.indexOf('}', i);
					value += String.fromCodePoint(parseInt(src.slice(i + 1, close), 16));
					i = close + 1;
				} else value += e;
			}
			tokens.push({ t: 'str', v: value, line: start });
		} else if (c === '[' && (src[i + 1] === '[' || src[i + 1] === '=') && readLong(i)) {
			const long = readLong(i);
			tokens.push({ t: 'str', v: long.body, line });
			line += countLines(long.raw);
			i = long.next;
		} else if (/[0-9]/.test(c) || (c === '.' && /[0-9]/.test(src[i + 1] || ''))) {
			numberRe.lastIndex = i;
			const m = numberRe.exec(src);
			tokens.push({ t: 'num', v: m[0], line });
			i += m[0].length;
			while (/[A-Za-z]/.test(src[i] || '')) i++;
		} else if (/[A-Za-z_]/.test(c)) {
			nameRe.lastIndex = i;
			const m = nameRe.exec(src);
			tokens.push({ t: 'name', v: m[0], line });
			i += m[0].length;
		} else {
			const three = src.slice(i, i + 3);
			const two = src.slice(i, i + 2);
			const op =
				three === '...'
					? three
					: ['..', '==', '~=', '<=', '>=', '::', '//', '<<', '>>'].includes(two)
						? two
						: c;
			tokens.push({ t: 'op', v: op, line });
			i += op.length;
		}
	}
	return tokens;
}

/**
 * Lexes Python into name, str, num and op tokens, dropping comments. An f-string
 * keeps its text and turns each replacement field into a placeholder.
 */
function lexPython(src) {
	const tokens = [];
	const n = src.length;
	let i = 0;
	let line = 1;
	const stringStart = /([rRbBuUfF]{0,2})('''|"""|'|")/y;
	const nameRe = /[A-Za-z_][A-Za-z0-9_]*/y;
	while (i < n) {
		const c = src[i];
		if (c === '\n') {
			line++;
			i++;
			continue;
		}
		if (/\s/.test(c)) {
			i++;
			continue;
		}
		if (c === '#') {
			while (i < n && src[i] !== '\n') i++;
			continue;
		}
		stringStart.lastIndex = i;
		const sm = /[A-Za-z'"]/.test(c) ? stringStart.exec(src) : null;
		if (sm) {
			const prefix = sm[1].toLowerCase();
			const quote = sm[2];
			const raw = prefix.includes('r');
			const fmt = prefix.includes('f');
			const start = line;
			let value = '';
			i += sm[0].length;
			for (;;) {
				if (i >= n) throw new Error(`unterminated string at line ${start}`);
				if (src.startsWith(quote, i)) {
					i += quote.length;
					break;
				}
				const ch = src[i];
				if (ch === '\n') line++;
				if (ch === '\\' && !raw) {
					const e = src[i + 1];
					i += 2;
					const simple = { n: '\n', t: '\t', r: '\r', '\\': '\\', "'": "'", '"': '"', 0: '\0' };
					if (e === '\n') line++;
					else value += e in simple ? simple[e] : `\\${e}`;
					continue;
				}
				if (ch === '\\') {
					value += ch + (src[i + 1] || '');
					if (src[i + 1] === '\n') line++;
					i += 2;
					continue;
				}
				if (fmt && ch === '{') {
					if (src[i + 1] === '{') {
						value += '{';
						i += 2;
						continue;
					}
					let depth = 0;
					while (i < n) {
						if (src[i] === '{') depth++;
						else if (src[i] === '}' && --depth === 0) break;
						if (src[i] === '\n') line++;
						i++;
					}
					value += DYN;
					i++;
					continue;
				}
				if (fmt && ch === '}' && src[i + 1] === '}') {
					value += '}';
					i += 2;
					continue;
				}
				value += ch;
				i++;
			}
			// Adjacent literals concatenate, as they do in Python.
			const last = tokens[tokens.length - 1];
			if (last && last.t === 'str') last.v += value;
			else tokens.push({ t: 'str', v: value, line: start });
			continue;
		}
		if (/[A-Za-z_]/.test(c)) {
			nameRe.lastIndex = i;
			const m = nameRe.exec(src);
			tokens.push({ t: 'name', v: m[0], line });
			i += m[0].length;
			continue;
		}
		if (/[0-9]/.test(c)) {
			const m = /[0-9][0-9A-Za-z_.]*/y;
			m.lastIndex = i;
			const hit = m.exec(src);
			tokens.push({ t: 'num', v: hit[0], line });
			i += hit[0].length;
			continue;
		}
		tokens.push({ t: 'op', v: c, line });
		i++;
	}
	return tokens;
}

// =================================
// =================================
// ======= 3/ Shell Analysis =======
// =================================
// =================================

/** Index of the parenthesis closing the one at `open`, honouring quotes. */
function matchParen(text, open) {
	let depth = 0;
	for (let j = open; j < text.length; j++) {
		const ch = text[j];
		if (ch === '\\') j++;
		else if (ch === "'") {
			const close = text.indexOf("'", j + 1);
			j = close === -1 ? text.length : close;
		} else if (ch === '"') {
			for (j++; j < text.length && text[j] !== '"'; j++) if (text[j] === '\\') j++;
		} else if (ch === '(') depth++;
		else if (ch === ')' && --depth === 0) return j;
	}
	return text.length;
}

/** Index of the brace closing the one at `open`, honouring quotes. */
function matchBrace(text, open) {
	let depth = 0;
	for (let j = open; j < text.length; j++) {
		const ch = text[j];
		if (ch === '\\') j++;
		else if (ch === "'") {
			const close = text.indexOf("'", j + 1);
			j = close === -1 ? text.length : close;
		} else if (ch === '"') {
			for (j++; j < text.length && text[j] !== '"'; j++) if (text[j] === '\\') j++;
		} else if (ch === '{') depth++;
		else if (ch === '}' && --depth === 0) return j;
	}
	return text.length;
}

const countNewlines = (text) => (text.match(/\n/g) || []).length;

/**
 * Splits shell text into simple commands (arrays of words). Comments, heredoc
 * bodies, case patterns and redirections are consumed here; command and
 * process substitutions are analysed recursively into the same output.
 * A word holds `text` (quotes removed, substitutions replaced by DYN) and `dyn`.
 */
function tokenizeShell(text, baseLine, out) {
	const n = text.length;
	let i = 0;
	let line = baseLine;
	let word = null;
	let cmd = [];
	let cmdLine = baseLine;
	let redirectPending = false;
	let parenDepth = 0;
	let doubleBracket = false;
	const heredocs = [];
	const caseStack = [];

	const addChar = (ch) => {
		if (!word) word = { text: '', dyn: false, line };
		word.text += ch;
		if (ch === DYN) word.dyn = true;
	};
	const ensureWord = () => {
		if (!word) word = { text: '', dyn: false, line };
	};
	const endWord = () => {
		if (!word) return;
		const w = word;
		word = null;
		if (redirectPending) {
			redirectPending = false;
			return;
		}
		if (cmd.length === 0) cmdLine = w.line;
		cmd.push(w);
		if (doubleBracket && w.text === ']]') doubleBracket = false;
		else if (!doubleBracket && w.text === '[[') doubleBracket = true;
		if (!w.dyn && w.text === 'in' && cmd.length === 3 && cmd[0].text === 'case') {
			cmd = [];
			caseStack.push({ expectPattern: true });
		}
		if (!w.dyn && w.text === 'esac' && cmd.length === 1 && caseStack.length) caseStack.pop();
	};
	const endCmd = () => {
		endWord();
		if (cmd.length) {
			if (cmd[0].text === 'function' && cmd[1] && !cmd[1].dyn) out.context.names.add(cmd[1].text);
			out.commands.push({ words: cmd, line: cmdLine });
		}
		cmd = [];
	};
	const sub = (inner, at) => {
		tokenizeShell(inner, at, out);
		addChar(DYN);
	};
	/** Expands a `$` at `i`; returns the new index. */
	const dollar = () => {
		const next = text[i + 1];
		if (next === '(') {
			const end = matchParen(text, i + 1);
			if (text[i + 2] === '(') addChar(DYN);
			else sub(text.slice(i + 2, end), line);
			line += countNewlines(text.slice(i, end));
			return end + 1;
		}
		if (next === '{') {
			const end = matchBrace(text, i + 1);
			addChar(DYN);
			line += countNewlines(text.slice(i, end));
			return end + 1;
		}
		const m = /^(?:[A-Za-z_][A-Za-z0-9_]*|[0-9@*#?$!-])/.exec(text.slice(i + 1, i + 80));
		if (m) {
			addChar(DYN);
			return i + 1 + m[0].length;
		}
		addChar('$');
		return i + 1;
	};
	const backtick = () => {
		let j = i + 1;
		while (j < n && text[j] !== '`') j += text[j] === '\\' ? 2 : 1;
		sub(text.slice(i + 1, j).replace(/\\`/g, '`'), line);
		line += countNewlines(text.slice(i, j));
		return j + 1;
	};
	const readHeredocs = () => {
		for (const hd of heredocs.splice(0)) {
			const start = line;
			const body = [];
			for (;;) {
				if (i >= n) break;
				let eol = text.indexOf('\n', i);
				if (eol === -1) eol = n;
				let current = text.slice(i, eol);
				i = Math.min(eol + 1, n);
				line++;
				if (hd.strip) current = current.replace(/^\t+/, '');
				if (current === hd.delim) break;
				body.push(current);
			}
			out.heredocs.push({ owner: hd.owner, body: body.join('\n'), line: start });
		}
	};

	while (i < n) {
		const c = text[i];
		// A case pattern is consumed whole: it is not a command.
		if (caseStack.length && cmd.length === 0 && !word) {
			const top = caseStack[caseStack.length - 1];
			if (top.expectPattern) {
				while (i < n && (/[\s;]/.test(text[i]) || text[i] === '#')) {
					if (text[i] === '#') while (i < n && text[i] !== '\n') i++;
					if (text[i] === '\n') line++;
					i++;
				}
				if (/^esac(?![\w-])/.test(text.slice(i, i + 6))) {
					caseStack.pop();
					i += 4;
					continue;
				}
				let j = i;
				while (j < n && text[j] !== ')') {
					if (text[j] === "'") {
						const close = text.indexOf("'", j + 1);
						j = close === -1 ? n : close + 1;
					} else if (text[j] === '"') {
						for (j++; j < n && text[j] !== '"'; j += text[j] === '\\' ? 2 : 1);
						j++;
					} else j += text[j] === '\\' ? 2 : 1;
				}
				line += countNewlines(text.slice(i, j));
				i = j + 1;
				top.expectPattern = false;
				continue;
			}
		}
		if (c === '\\') {
			if (text[i + 1] === '\n') {
				line++;
				i += 2;
			} else {
				addChar(text[i + 1] === undefined ? '' : text[i + 1]);
				i += 2;
			}
		} else if (c === '\n') {
			endCmd();
			line++;
			i++;
			readHeredocs();
		} else if (c === ' ' || c === '\t' || c === '\r') {
			endWord();
			i++;
		} else if (c === '#' && !word) {
			while (i < n && text[i] !== '\n') i++;
		} else if (c === "'") {
			ensureWord();
			const close = text.indexOf("'", i + 1);
			const end = close === -1 ? n : close;
			for (const ch of text.slice(i + 1, end)) addChar(ch);
			line += countNewlines(text.slice(i, end));
			i = end + 1;
		} else if (c === '"') {
			ensureWord();
			i++;
			while (i < n && text[i] !== '"') {
				const ch = text[i];
				if (ch === '\\') {
					const e = text[i + 1];
					if (e === '\n') line++;
					else if ('$`"\\'.includes(e)) addChar(e);
					else {
						addChar('\\');
						addChar(e === undefined ? '' : e);
					}
					i += 2;
				} else if (ch === '$') i = dollar();
				else if (ch === '`') i = backtick();
				else {
					if (ch === '\n') line++;
					addChar(ch);
					i++;
				}
			}
			i++;
		} else if (c === '$') {
			if (text[i + 1] === "'") {
				ensureWord();
				let j = i + 2;
				while (j < n && text[j] !== "'") j += text[j] === '\\' ? 2 : 1;
				addChar(DYN);
				i = j + 1;
			} else i = dollar();
		} else if (c === '`') {
			i = backtick();
		} else if ((c === '>' || c === '<') && doubleBracket) {
			addChar(c);
			i++;
		} else if (c === '>' || c === '<') {
			if (text[i + 1] === '(') {
				const end = matchParen(text, i + 1);
				sub(text.slice(i + 2, end), line);
				i = end + 1;
				continue;
			}
			if (word && /^\d+$/.test(word.text)) word = null;
			else endWord();
			const ops = c === '>' ? ['>>', '>&', '>|', '>'] : ['<<<', '<<-', '<<', '<&', '<>', '<'];
			const op = ops.find((candidate) => text.startsWith(candidate, i));
			i += op.length;
			if (op === '<<' || op === '<<-') {
				while (text[i] === ' ' || text[i] === '\t') i++;
				let delim = '';
				while (i < n && !/[\s;|&<>()]/.test(text[i])) {
					if (text[i] === "'" || text[i] === '"') {
						const close = text.indexOf(text[i], i + 1);
						delim += text.slice(i + 1, close === -1 ? n : close);
						i = close === -1 ? n : close + 1;
					} else if (text[i] === '\\') i++;
					else delim += text[i++];
				}
				heredocs.push({ delim, strip: op === '<<-', owner: cmd });
			} else redirectPending = true;
		} else if (c === '&') {
			if (doubleBracket) {
				endWord();
				i += text[i + 1] === '&' ? 2 : 1;
			} else if (text[i + 1] === '>') {
				endWord();
				i += text[i + 2] === '>' ? 3 : 2;
				redirectPending = true;
			} else {
				endCmd();
				i += text[i + 1] === '&' ? 2 : 1;
			}
		} else if (c === '|') {
			const width = text[i + 1] === '|' || text[i + 1] === '&' ? 2 : 1;
			if (doubleBracket) endWord();
			else endCmd();
			i += width;
		} else if (c === ';') {
			endCmd();
			if (text[i + 1] === ';' || text[i + 1] === '&') {
				i += text[i + 2] === '&' ? 3 : 2;
				if (caseStack.length) caseStack[caseStack.length - 1].expectPattern = true;
			} else i++;
		} else if ((c === '(' || c === ')') && doubleBracket) {
			addChar(c);
			i++;
		} else if (c === '(') {
			if (word && word.text.endsWith('=')) {
				const end = matchParen(text, i);
				addChar(DYN);
				line += countNewlines(text.slice(i, end));
				i = end + 1;
			} else if (
				(cmd.length === 0 || (cmd.length === 1 && cmd[0].text === 'for')) &&
				!word &&
				text[i + 1] === '('
			) {
				const end = matchParen(text, i);
				line += countNewlines(text.slice(i, end));
				i = end + 1;
			} else if (/^\(\s*\)/.test(text.slice(i, i + 40)) && (word || cmd.length)) {
				// `name()` and `function name()` define a function, not a command.
				if (word && !word.dyn) out.context.names.add(word.text);
				else if (cmd.length && !cmd[cmd.length - 1].dyn)
					out.context.names.add(cmd[cmd.length - 1].text);
				word = null;
				cmd = [];
				i += text.slice(i).match(/^\(\s*\)/)[0].length;
			} else {
				endCmd();
				parenDepth++;
				i++;
			}
		} else if (c === ')') {
			if (parenDepth > 0) {
				parenDepth--;
				endCmd();
			} else {
				word = null;
				cmd = [];
			}
			i++;
		} else {
			addChar(c);
			i++;
		}
	}
	endCmd();
}

/**
 * Appends to `records` the programs one simple command launches, looking through
 * wrappers (sudo, env, timeout), `sh -c` payloads and `find -exec`. A record is
 * { line, name } for a program, plus probe for a presence check, or dynamic,
 * skipped or builtin when there is nothing to look up.
 */
function programsOfCommand(command, out, records, depth = 0) {
	const words = command.words;
	let i = 0;
	while (i < words.length) {
		const t = words[i];
		if (/^[A-Za-z_][A-Za-z0-9_]*(?:\[[^\]]*\])?\+?=/.test(t.text)) i++;
		else if (
			!t.dyn &&
			[
				'if',
				'then',
				'else',
				'elif',
				'fi',
				'while',
				'until',
				'do',
				'done',
				'!',
				'{',
				'}',
				'time',
				'esac'
			].includes(t.text)
		)
			i++;
		else break;
	}
	if (i >= words.length) return;
	const head = words[i];
	const line = command.line;
	if (!head.dyn && ['for', 'select', 'case', 'function', 'in'].includes(head.text)) return;
	let name = head.text;
	if (head.dyn || !SHELL_BUILTINS.has(name)) {
		const word = classifyProgram(head.text, head.dyn);
		if (!word.name) {
			records.push({ line, ...word });
			return;
		}
		name = word.name;
	}
	if (out.context.names.has(name) && !out.context.probes.has(name)) return;
	const rest = words.slice(i + 1);
	if (out.context.probes.has(name)) {
		const target = rest.find((w) => !/^-/.test(w.text));
		if (!target || target.dyn)
			records.push({ name: null, line, dynamic: `probe wrapper ${name} with a variable target` });
		else records.push({ name: target.text, line, probe: true });
		return;
	}
	if (SHELL_BUILTINS.has(name)) {
		if (name === 'command' || name === 'type' || name === 'hash') {
			const flags = rest
				.filter((w) => /^-[a-zA-Z]+$/.test(w.text))
				.map((w) => w.text)
				.join('');
			const targets = rest.filter((w) => !/^-/.test(w.text));
			if (name === 'command' && !/[vV]/.test(flags)) {
				if (targets.length) programsOfCommand({ words: targets, line }, out, records, depth + 1);
			} else {
				for (const target of targets) {
					if (target.dyn) records.push({ name: null, line, dynamic: 'probe target is a variable' });
					else records.push({ name: target.text, line, probe: true });
				}
			}
		} else if (name === 'exec' && rest.length && !/^\d*[<>]/.test(rest[0].text)) {
			programsOfCommand({ words: rest, line }, out, records, depth + 1);
		}
		records.push({ name: null, line, builtin: name });
		return;
	}
	records.push({ name, line });
	if (SHELLS.has(name)) {
		const scriptAt = rest.findIndex((w) => /^-[a-zA-Z]*c[a-zA-Z]*$/.test(w.text));
		if (scriptAt !== -1 && rest[scriptAt + 1] && depth < 4) {
			const inner = { commands: [], heredocs: [], context: out.context };
			tokenizeShell(rest[scriptAt + 1].text, line, inner);
			for (const nested of inner.commands) programsOfCommand(nested, inner, records, depth + 1);
		}
		for (const hd of out.heredocs.filter((h) => h.owner === command.words)) {
			const inner = { commands: [], heredocs: [], context: out.context };
			tokenizeShell(hd.body, hd.line, inner);
			for (const nested of inner.commands) programsOfCommand(nested, inner, records, depth + 1);
		}
		return;
	}
	if (name === 'which') {
		for (const target of rest.filter((w) => !/^-/.test(w.text))) {
			if (!target.dyn) records.push({ name: target.text, line, probe: true });
		}
		return;
	}
	if (name === 'find') {
		for (let k = 0; k < rest.length; k++) {
			if (['-exec', '-execdir', '-ok', '-okdir'].includes(rest[k].text)) {
				const tail = [];
				for (let m = k + 1; m < rest.length && rest[m].text !== ';' && rest[m].text !== '+'; m++)
					tail.push(rest[m]);
				if (tail.length) programsOfCommand({ words: tail, line }, out, records, depth + 1);
			}
		}
		return;
	}
	const wrapper = WRAPPERS.get(name);
	if (wrapper) {
		const [valueOptions, positional] = wrapper;
		let k = 0;
		let skip = positional;
		while (k < rest.length) {
			const w = rest[k];
			if (/^[A-Za-z_][A-Za-z0-9_]*=/.test(w.text) && name === 'env') k++;
			else if (valueOptions.includes(w.text)) k += 2;
			else if (/^-/.test(w.text) && !w.dyn) k++;
			else if (skip > 0) {
				skip--;
				k++;
			} else break;
		}
		if (k < rest.length && depth < 4)
			programsOfCommand({ words: rest.slice(k), line }, out, records, depth + 1);
	}
}

/**
 * Programs launched by a shell text: [{ name, line, probe?, dynamic?, skipped?,
 * builtin? }]. `line` is the line within the text offset by baseLine.
 */
function analyzeShell(text, baseLine, context) {
	const out = { commands: [], heredocs: [], context };
	tokenizeShell(text, baseLine, out);
	const records = [];
	for (const command of out.commands) programsOfCommand(command, out, records);
	return records;
}

/** Collects the function names a shell text defines, so calls to them are not programs. */
function shellFunctionNames(text, context) {
	tokenizeShell(text, 1, { commands: [], heredocs: [], context });
	// A function whose first command is `command -v "$1"` is a probe wrapper.
	const wrapper =
		/^[ \t]*(?:function[ \t]+)?([A-Za-z_][\w-]*)[ \t]*\(\)[ \t]*\{[ \t]*\n(?:[ \t]*#[^\n]*\n)*[ \t]*command -v "\$1"/gm;
	for (const match of text.matchAll(wrapper)) context.probes.add(match[1]);
}

// =====================================
// =====================================
// ======= 4/ Call Site Scanners =======
// =====================================
// =====================================

/** What each launcher takes as its first argument: a shell string, a program or a probed name. */
const LUA_LAUNCHERS = {
	io: { popen: 'shell' },
	os: { execute: 'shell' },
	'adapters.shell_runner': {
		run: 'shell',
		exec: 'shell',
		exec_checked: 'shell',
		exec_line: 'shell',
		with_stdin: 'shell',
		exec_stdin: 'shell',
		with_exact_stdin: 'shell',
		exec_exact_stdin: 'shell',
		has_command: 'probe',
		run_async: 'program'
	},
	'adapters.process_runner': { run: 'program' },
	'adapters.program_runner': { spawn: 'program', available: 'probe' },
	'adapters.owned_process': { start: 'program' },
	luv: { spawn: 'program' }
};

const PYTHON_LAUNCHERS = {
	subprocess: {
		run: ['argv', 0],
		Popen: ['argv', 0],
		call: ['argv', 0],
		check_call: ['argv', 0],
		check_output: ['argv', 0],
		getoutput: ['shell', 0],
		getstatusoutput: ['shell', 0]
	},
	os: {
		system: ['shell', 0],
		popen: ['shell', 0],
		execv: ['program', 0],
		execve: ['program', 0],
		execl: ['program', 0],
		execle: ['program', 0],
		execlp: ['program', 0],
		execlpe: ['program', 0],
		execvp: ['program', 0],
		execvpe: ['program', 0],
		spawnv: ['program', 1],
		spawnve: ['program', 1],
		spawnl: ['program', 1],
		spawnle: ['program', 1],
		spawnlp: ['program', 1],
		spawnlpe: ['program', 1],
		spawnvp: ['program', 1],
		spawnvpe: ['program', 1]
	},
	shutil: { which: ['probe', 0] },
	asyncio: { create_subprocess_exec: ['program', 0], create_subprocess_shell: ['shell', 0] }
};

/** Index of the bracket matching the opener at `open` in a token list. */
function matchToken(tokens, open) {
	const pairs = { '(': ')', '[': ']', '{': '}' };
	const opener = tokens[open].v;
	const closer = pairs[opener];
	let depth = 0;
	for (let j = open; j < tokens.length; j++) {
		if (tokens[j].t !== 'op') continue;
		if (tokens[j].v === opener) depth++;
		else if (tokens[j].v === closer && --depth === 0) return j;
	}
	return tokens.length - 1;
}

/** Splits a token list at a depth-0 operator. */
function splitTokens(tokens, separator) {
	const parts = [[]];
	let depth = 0;
	for (const token of tokens) {
		if (token.t === 'op') {
			if ('([{'.includes(token.v)) depth++;
			else if (')]}'.includes(token.v)) depth--;
			else if (token.v === separator && depth === 0) {
				parts.push([]);
				continue;
			}
		}
		parts[parts.length - 1].push(token);
	}
	return parts.filter((part, index) => part.length || index < parts.length - 1);
}

/** Replaces printf-style and format() fields by the placeholder. */
function formatTemplate(text) {
	return text.replace(/%%|%[-+ #0]*\d*(?:\.\d+)?[a-zA-Z]/g, (field) =>
		field === '%%' ? '%' : DYN
	);
}

/**
 * Index records of a Lua token stream: the visible `name = value` assignments,
 * resolved lexically so a variable named like a parameter elsewhere is not read.
 */
function luaLexicalInfo(tokens) {
	const frames = [{ id: 0, braces: 0 }];
	const paths = new Array(tokens.length);
	const assigns = new Map();
	let nextId = 1;
	let pendingFor = null;
	const currentPath = () => frames.map((frame) => frame.id).join('/') + '/';
	const record = (name, at, rhs, pathText, alts = null) => {
		if (!assigns.has(name)) assigns.set(name, []);
		assigns.get(name).push({ at, rhs, path: pathText, alts });
	};
	/** The string literals of a table constructor at `open`, or null when any element is not one. */
	const literalList = (open) => {
		if (!tokens[open] || tokens[open].v !== '{') return null;
		const elements = splitTokens(tokens.slice(open + 1, matchToken(tokens, open)), ',');
		return elements.length &&
			elements.every((element) => element.length === 1 && element[0].t === 'str')
			? elements.map((element) => element[0].v)
			: null;
	};
	for (let i = 0; i < tokens.length; i++) {
		const tok = tokens[i];
		paths[i] = currentPath();
		const previous = tokens[i - 1];
		if (tok.t === 'op') {
			if (tok.v === '{') frames[frames.length - 1].braces++;
			else if (tok.v === '}') frames[frames.length - 1].braces--;
			else if (tok.v === '=' && frames[frames.length - 1].braces === 0) {
				const names = [];
				let k = i - 1;
				while (
					k >= 0 &&
					tokens[k].t === 'name' &&
					!(tokens[k - 1] && ['.', ':'].includes(tokens[k - 1].v))
				) {
					names.unshift(k);
					if (tokens[k - 1] && tokens[k - 1].v === ',') k -= 2;
					else break;
				}
				if (names.length === 1) record(tokens[names[0]].v, names[0], i + 1, paths[i]);
				else for (const index of names) record(tokens[index].v, index, null, paths[i]);
			}
			continue;
		}
		if (tok.t !== 'name' || (previous && ['.', ':'].includes(previous.v))) continue;
		if (tok.v === 'function') {
			frames.push({ id: nextId++, braces: 0 });
			let k = i + 1;
			while (k < tokens.length && tokens[k].v !== '(') k++;
			if (
				tokens[i + 1] &&
				tokens[i + 1].v !== '(' &&
				tokens.slice(i + 1, k).some((t) => t.v === ':')
			) {
				record('self', k, null, currentPath());
			}
			for (let m = k + 1; m < tokens.length && tokens[m].v !== ')'; m++) {
				if (tokens[m].t === 'name') record(tokens[m].v, m, null, currentPath());
			}
		} else if (tok.v === 'if' || tok.v === 'repeat') frames.push({ id: nextId++, braces: 0 });
		else if (tok.v === 'for') {
			pendingFor = [];
			let k = i + 1;
			for (; k < tokens.length && tokens[k].v !== 'in' && tokens[k].v !== '='; k++) {
				if (tokens[k].t === 'name') pendingFor.push({ name: tokens[k].v, at: k, alts: null });
			}
			// `for _, program in ipairs({ "a", "b" })` (or ipairs(NAME) of such a table) binds literals.
			if (
				tokens[k] &&
				tokens[k].v === 'in' &&
				tokens[k + 1] &&
				tokens[k + 1].v === 'ipairs' &&
				tokens[k + 2] &&
				tokens[k + 2].v === '(' &&
				pendingFor.length === 2
			) {
				let list = literalList(k + 3);
				if (
					!list &&
					tokens[k + 3] &&
					tokens[k + 3].t === 'name' &&
					tokens[k + 4] &&
					tokens[k + 4].v === ')'
				) {
					const defs = (assigns.get(tokens[k + 3].v) || []).filter(
						(entry) => entry.at < i && entry.rhs !== null
					);
					if (defs.length) list = literalList(defs[defs.length - 1].rhs);
				}
				pendingFor[1].alts = list;
			}
		} else if (tok.v === 'do') {
			frames.push({ id: nextId++, braces: 0 });
			for (const entry of pendingFor || [])
				record(entry.name, entry.at, null, currentPath(), entry.alts);
			pendingFor = null;
		} else if ((tok.v === 'end' || tok.v === 'until') && frames.length > 1) frames.pop();
	}
	return { paths, assigns };
}

/** End (exclusive) of one operand: a literal, a name with suffixes, or a parenthesis. */
function luaOperandEnd(tokens, start) {
	const first = tokens[start];
	if (!first) return start;
	let j = start;
	if (first.t === 'str' || first.t === 'num') return start + 1;
	if (first.t === 'name') {
		if (['function', 'not', 'end', 'then', 'do', 'and', 'or'].includes(first.v)) return start;
		j = start + 1;
	} else if (first.v === '(') j = matchToken(tokens, start) + 1;
	else return start;
	for (;;) {
		const next = tokens[j];
		if (!next) break;
		if (next.v === '.' && tokens[j + 1] && tokens[j + 1].t === 'name') j += 2;
		else if (
			next.v === ':' &&
			tokens[j + 1] &&
			tokens[j + 1].t === 'name' &&
			tokens[j + 2] &&
			tokens[j + 2].v === '('
		)
			j += 2;
		else if (next.t === 'op' && (next.v === '(' || next.v === '[')) j = matchToken(tokens, j) + 1;
		else break;
	}
	return j;
}

/** End (exclusive) of a concatenation expression starting at `start`. */
function luaExprEnd(tokens, start) {
	let j = luaOperandEnd(tokens, start);
	if (j === start) return start;
	while (tokens[j] && tokens[j].v === '..') {
		const k = luaOperandEnd(tokens, j + 1);
		if (k === j + 1) break;
		j = k;
	}
	return j;
}

const MAX_ALTERNATIVES = 24;
const LUA_BINARY_OPERATORS = ['==', '~=', '<', '>', '<=', '>=', '+', '-', '*', '/', '%', '^', '//'];

/** Cartesian concatenation of two alternative lists; too many collapse to one dynamic text. */
function concatAlternatives(left, right) {
	const out = [];
	for (const l of left) for (const r of right) out.push(l + r);
	return out.length > MAX_ALTERNATIVES ? [DYN] : [...new Set(out)];
}

/**
 * Texts a Lua string expression can take, with DYN for every part that is not a
 * literal. Names resolve to the nearest visible assignment of the same file, and
 * a loop variable over a literal table stands for each of its elements.
 */
function evalLuaString(tokens, file, at, depth = 0) {
	let texts = [''];
	for (const operand of splitTokens(tokens, '..')) {
		let part = [DYN];
		if (operand.length === 1 && operand[0].t === 'str') part = [operand[0].v];
		else if (operand.length === 1 && operand[0].t === 'name' && depth < 6) {
			const candidates = (file.info.assigns.get(operand[0].v) || []).filter(
				(entry) => entry.at < at && file.info.paths[at].startsWith(entry.path)
			);
			const nearest = candidates[candidates.length - 1];
			if (nearest && nearest.alts) part = nearest.alts;
			else if (nearest && nearest.rhs !== null) {
				const end = luaExprEnd(file.tokens, nearest.rhs);
				const after = file.tokens[end];
				// `x == "a" and y or z` is no string: a trailing operator makes the right side dynamic.
				const continues =
					after &&
					((after.t === 'op' && LUA_BINARY_OPERATORS.includes(after.v)) ||
						(after.t === 'name' && ['and', 'or'].includes(after.v)));
				if (!continues)
					part = evalLuaString(file.tokens.slice(nearest.rhs, end), file, nearest.at, depth + 1);
			}
		} else if (
			operand.length >= 3 &&
			operand[0].v === '(' &&
			matchToken(operand, 0) === operand.length - 1
		) {
			part = evalLuaString(operand.slice(1, -1), file, at, depth + 1);
		} else if (
			operand.length >= 6 &&
			operand[0].v === 'string' &&
			operand[1].v === '.' &&
			operand[2].v === 'format' &&
			operand[3].v === '(' &&
			matchToken(operand, 3) === operand.length - 1
		) {
			const first = splitTokens(operand.slice(4, -1), ',')[0] || [];
			part = evalLuaString(first, file, at, depth + 1).map(formatTemplate);
		} else if (
			operand.length >= 7 &&
			operand[0].v === '(' &&
			operand[2].v === ')' &&
			operand[3].v === ':' &&
			operand[4].v === 'format' &&
			operand[5].v === '(' &&
			matchToken(operand, 5) === operand.length - 1
		) {
			part = evalLuaString([operand[1]], file, at, depth + 1).map(formatTemplate);
		}
		texts = concatAlternatives(texts, part);
	}
	return texts;
}

/** Maps local names to the module (or "io", "os") a `require` or `= io.popen` bound them to. */
function luaAliases(tokens) {
	const modules = new Map([
		['uv', 'luv'],
		['luv', 'luv']
	]);
	const direct = new Map();
	const namesBefore = (index) => {
		const names = [];
		let k = index - 1;
		while (k >= 0 && tokens[k].t === 'name') {
			names.unshift(tokens[k].v);
			if (tokens[k - 1] && tokens[k - 1].v === ',') k -= 2;
			else break;
		}
		return names;
	};
	const at = (index) => tokens[index] || { t: '', v: '' };
	for (let i = 0; i < tokens.length; i++) {
		const tok = tokens[i];
		if (tok.t === 'name' && tok.v === 'require') {
			let lit = null;
			let holder = i - 1;
			if (at(i + 1).v === '(' && at(i + 2).t === 'str') lit = tokens[i + 2];
			else if (at(i + 1).t === 'str') lit = tokens[i + 1];
			else if (
				at(i - 1).v === '(' &&
				at(i - 2).v === 'pcall' &&
				at(i + 1).v === ',' &&
				at(i + 2).t === 'str'
			) {
				lit = tokens[i + 2];
				holder = i - 3;
			}
			if (lit && at(holder).v === '=')
				for (const name of namesBefore(holder)) modules.set(name, lit.v);
		} else if (tok.t === 'op' && tok.v === '=') {
			// `local a, b = os.execute, io.popen`: positional aliases of the launchers themselves.
			const names = namesBefore(i);
			let k = i + 1;
			for (const name of names) {
				const lib = tokens[k];
				const fn = tokens[k + 2];
				if (
					lib &&
					fn &&
					lib.t === 'name' &&
					tokens[k + 1].v === '.' &&
					fn.t === 'name' &&
					tokens[k + 3] &&
					tokens[k + 3].v !== '('
				) {
					const method =
						lib.v === 'io' && fn.v === 'popen'
							? 'io.popen'
							: lib.v === 'os' && fn.v === 'execute'
								? 'os.execute'
								: null;
					if (method) direct.set(name, method);
				}
				k += 3;
				if (!tokens[k] || tokens[k].v !== ',') break;
				k++;
			}
		}
	}
	return { modules, direct };
}

/** The launcher a callee names, or null: { key, kind, next }. */
function luaCallee(tokens, j, aliases) {
	const a = tokens[j];
	if (!a || a.t !== 'name') return null;
	if (
		a.v === 'require' &&
		tokens[j + 1] &&
		tokens[j + 1].v === '(' &&
		tokens[j + 2] &&
		tokens[j + 2].t === 'str'
	) {
		const close = j + 3;
		if (
			tokens[close] &&
			tokens[close].v === ')' &&
			tokens[close + 1] &&
			tokens[close + 1].v === '.' &&
			tokens[close + 2] &&
			tokens[close + 2].t === 'name'
		) {
			const module = tokens[j + 2].v;
			const kind = LUA_LAUNCHERS[module] && LUA_LAUNCHERS[module][tokens[close + 2].v];
			return kind ? { key: `${module}.${tokens[close + 2].v}`, kind, next: close + 3 } : null;
		}
		return null;
	}
	if (tokens[j + 1] && tokens[j + 1].v === '.' && tokens[j + 2] && tokens[j + 2].t === 'name') {
		const root = a.v === 'io' || a.v === 'os' ? a.v : aliases.modules.get(a.v);
		const kind = root && LUA_LAUNCHERS[root] && LUA_LAUNCHERS[root][tokens[j + 2].v];
		return kind ? { key: `${root}.${tokens[j + 2].v}`, kind, next: j + 3 } : null;
	}
	if (aliases.direct.has(a.v)) {
		const key = aliases.direct.get(a.v);
		return { key, kind: 'shell', next: j + 1 };
	}
	return null;
}

/** Normalises one program word into a site record. */
function classifyProgram(text, dyn) {
	if (dyn)
		return { dynamic: `program is not a literal (${text.replace(new RegExp(DYN, 'g'), '...')})` };
	let name = text;
	if (name.startsWith('/')) {
		if (SYSTEM_DIRS.has(path.posix.dirname(name))) name = path.posix.basename(name);
	} else if (name.includes('/')) return { skipped: `repository path ${name}` };
	if (!/^[A-Za-z0-9_.+/-]+$/.test(name)) return { dynamic: `unparsed word "${name}"` };
	return { name };
}

/** Call sites of one Lua file. */
function scanLua(rel, src, context) {
	const tokens = lexLua(src);
	const file = { tokens, info: luaLexicalInfo(tokens) };
	const aliases = luaAliases(tokens);
	const sites = [];
	const emit = (via, line, record) => sites.push({ file: rel, line, via, ...record });
	for (let i = 0; i < tokens.length; i++) {
		const tok = tokens[i];
		if (tok.t !== 'name') continue;
		const previous = tokens[i - 1];
		if (previous && ['.', ':', 'function'].includes(previous.v)) continue;
		let callee = null;
		let argStart = -1;
		if (tok.v === 'pcall' && tokens[i + 1] && tokens[i + 1].v === '(') {
			callee = luaCallee(tokens, i + 2, aliases);
			if (callee && tokens[callee.next] && tokens[callee.next].v === ',')
				argStart = callee.next + 1;
			else callee = null;
		} else {
			callee = luaCallee(tokens, i, aliases);
			if (callee && tokens[callee.next] && tokens[callee.next].v === '(')
				argStart = callee.next + 1;
			else callee = null;
		}
		if (!callee) continue;
		let end = argStart;
		for (let depth = 0; end < tokens.length; end++) {
			const t = tokens[end];
			if (t.t === 'op' && '([{'.includes(t.v)) depth++;
			else if (t.t === 'op' && ')]}'.includes(t.v)) {
				if (depth === 0) break;
				depth--;
			} else if (t.t === 'op' && t.v === ',' && depth === 0) break;
		}
		const via = callee.key;
		for (const text of evalLuaString(tokens.slice(argStart, end), file, i)) {
			if (callee.kind === 'shell') {
				for (const record of analyzeShell(text, tok.line, context)) emit(via, record.line, record);
			} else {
				const word = classifyProgram(text, text.includes(DYN) || text === '');
				emit(via, tok.line, { ...word, probe: callee.kind === 'probe' });
			}
		}
	}
	return sites;
}

/** Texts a Python string expression can take (DYN for non-literal parts), with names resolved. */
function evalPythonString(tokens, file, at, depth = 0) {
	let texts = [''];
	for (const operand of splitTokens(tokens, '+')) {
		let part = [DYN];
		if (
			operand.length >= 1 &&
			operand[0].t === 'str' &&
			(operand.length === 1 || operand[1].v === '%')
		) {
			part = [operand.length === 1 ? operand[0].v : formatTemplate(operand[0].v)];
		} else if (
			operand.length >= 3 &&
			operand[0].t === 'str' &&
			operand[1].v === '.' &&
			operand[2].v === 'format'
		) {
			part = [operand[0].v.replace(/\{[^}]*\}/g, DYN)];
		} else if (operand.length === 1 && operand[0].t === 'name' && depth < 4) {
			const hit = pythonAssignment(file, operand[0].v, at);
			if (hit && hit.alts) part = hit.alts;
			else if (hit && hit.tokens) part = evalPythonString(hit.tokens, file, hit.at, depth + 1);
		}
		texts = concatAlternatives(texts, part);
	}
	return texts;
}

/** The nearest preceding binding of a Python name: { at, tokens|null, alts|null }. */
function pythonAssignment(file, name, at) {
	const entries = (file.assigns.get(name) || []).filter((entry) => entry.at < at);
	return entries[entries.length - 1] || null;
}

/** The string literals of a Python list or tuple, or null when any element is not one. */
function pythonLiteralList(tokens) {
	if (
		!tokens ||
		!tokens.length ||
		!['[', '('].includes(tokens[0].v) ||
		matchToken(tokens, 0) !== tokens.length - 1
	)
		return null;
	const elements = splitTokens(tokens.slice(1, -1), ',').filter((element) => element.length);
	return elements.length &&
		elements.every((element) => element.length === 1 && element[0].t === 'str')
		? elements.map((element) => element[0].v)
		: null;
}

/** Indexes `NAME = literal-or-list`, def parameters and loop targets of a Python token stream. */
function pythonAssignments(tokens) {
	const assigns = new Map();
	const record = (name, at, value, alts = null) => {
		if (!assigns.has(name)) assigns.set(name, []);
		assigns.get(name).push({ at, tokens: value, alts });
	};
	for (let i = 0; i < tokens.length; i++) {
		const tok = tokens[i];
		if (tok.t !== 'name') continue;
		const next = tokens[i + 1];
		const previous = tokens[i - 1];
		if (tok.v === 'def' && tokens[i + 2] && tokens[i + 2].v === '(') {
			const close = matchToken(tokens, i + 2);
			for (let k = i + 3; k < close; k++) {
				if (tokens[k].t === 'name' && [',', '(', '*'].includes(tokens[k - 1].v))
					record(tokens[k].v, k, null);
			}
		} else if (tok.v === 'for') {
			const targets = [];
			let k = i + 1;
			for (; k < tokens.length && tokens[k].v !== 'in'; k++)
				if (tokens[k].t === 'name') targets.push(k);
			// `for tool in ["a", "b"]` (or in NAME bound to such a list) binds each literal.
			let alts = null;
			if (targets.length === 1 && tokens[k]) {
				const open = tokens[k + 1];
				if (open && ['[', '('].includes(open.v))
					alts = pythonLiteralList(tokens.slice(k + 1, matchToken(tokens, k + 1) + 1));
				else if (open && open.t === 'name') {
					const defs = (assigns.get(open.v) || []).filter((entry) => entry.at < i && entry.tokens);
					if (defs.length) alts = pythonLiteralList(defs[defs.length - 1].tokens);
				}
			}
			for (const index of targets)
				record(tokens[index].v, index, null, targets.length === 1 ? alts : null);
		} else if (
			next &&
			next.v === '=' &&
			tokens[i + 2] &&
			tokens[i + 2].v !== '=' &&
			!(previous && previous.v === '.')
		) {
			let end = i + 2;
			if (tokens[end].v === '[' || tokens[end].v === '(') end = matchToken(tokens, end) + 1;
			else {
				while (tokens[end] && (tokens[end].t === 'str' || tokens[end].v === '+')) end++;
				if (end === i + 2) end = i + 3;
			}
			// A value continued on the same line (`"a" if x else "b"`) is no literal.
			const continued =
				tokens[end] && tokens[end].line === tokens[end - 1].line && tokens[end].v !== ';';
			record(tok.v, i, continued ? null : tokens.slice(i + 2, end));
		}
	}
	return assigns;
}

/** Call sites of one Python file. */
function scanPython(rel, src, context) {
	const tokens = lexPython(src);
	const file = { tokens, assigns: pythonAssignments(tokens) };
	const modules = new Map(Object.keys(PYTHON_LAUNCHERS).map((name) => [name, name]));
	const imported = new Map();
	for (let i = 0; i < tokens.length; i++) {
		if (tokens[i].v === 'import' && tokens[i - 1] && tokens[i - 1].v !== 'from') {
			for (let k = i + 1; tokens[k] && tokens[k].line === tokens[i].line; k++) {
				if (
					tokens[k].v === 'as' &&
					tokens[k - 1] &&
					PYTHON_LAUNCHERS[tokens[k - 1].v] &&
					tokens[k + 1]
				)
					modules.set(tokens[k + 1].v, tokens[k - 1].v);
			}
		} else if (
			tokens[i].v === 'from' &&
			tokens[i + 1] &&
			PYTHON_LAUNCHERS[tokens[i + 1].v] &&
			tokens[i + 2] &&
			tokens[i + 2].v === 'import'
		) {
			const module = tokens[i + 1].v;
			for (let k = i + 3; tokens[k] && tokens[k].line === tokens[i].line; k++) {
				if (tokens[k].t !== 'name' || !PYTHON_LAUNCHERS[module][tokens[k].v]) continue;
				imported.set(
					tokens[k + 1] && tokens[k + 1].v === 'as' && tokens[k + 2]
						? tokens[k + 2].v
						: tokens[k].v,
					[module, tokens[k].v]
				);
			}
		}
	}
	const sites = [];
	for (let i = 0; i < tokens.length; i++) {
		const tok = tokens[i];
		if (tok.t !== 'name' || (tokens[i - 1] && ['.', 'def'].includes(tokens[i - 1].v))) continue;
		let module;
		let method;
		let open;
		if (
			tokens[i + 1] &&
			tokens[i + 1].v === '.' &&
			tokens[i + 2] &&
			tokens[i + 2].t === 'name' &&
			modules.has(tok.v)
		) {
			module = modules.get(tok.v);
			method = tokens[i + 2].v;
			open = i + 3;
		} else if (imported.has(tok.v)) {
			[module, method] = imported.get(tok.v);
			open = i + 1;
		} else continue;
		const launcher = PYTHON_LAUNCHERS[module] && PYTHON_LAUNCHERS[module][method];
		if (!launcher || !tokens[open] || tokens[open].v !== '(') continue;
		const close = matchToken(tokens, open);
		const args = splitTokens(tokens.slice(open + 1, close), ',');
		const isKeyword = (arg) => arg.length > 2 && arg[0].t === 'name' && arg[1].v === '=';
		const positional = args.filter((arg) => !isKeyword(arg));
		const keywordArgs = args.find((arg) => isKeyword(arg) && arg[0].v === 'args');
		const first =
			launcher[0] === 'argv' && keywordArgs ? keywordArgs.slice(2) : positional[launcher[1]];
		const viaShell =
			launcher[0] === 'shell' ||
			args.some((arg) => isKeyword(arg) && arg[0].v === 'shell' && arg[2] && arg[2].v === 'True');
		const emit = (record) =>
			sites.push({ file: rel, line: tok.line, via: `${module}.${method}`, ...record });
		if (!first || !first.length) {
			emit({ dynamic: 'no first argument found' });
			continue;
		}
		let listTokens = null;
		if (first[0].v === '[' || first[0].v === '(') listTokens = first.slice(1, -1);
		else if (first.length === 1 && first[0].t === 'name') {
			const hit = pythonAssignment(file, first[0].v, i);
			if (hit && hit.tokens && (hit.tokens[0].v === '[' || hit.tokens[0].v === '('))
				listTokens = hit.tokens.slice(1, -1);
		}
		if (
			launcher[0] === 'program' ||
			launcher[0] === 'probe' ||
			(launcher[0] === 'argv' && listTokens && !viaShell)
		) {
			// Alternatives are followed for the program word only; the other words keep their first reading.
			const elements = listTokens
				? splitTokens(listTokens, ',').map((element) => evalPythonString(element, file, i))
				: [evalPythonString(first, file, i)];
			for (const head of elements[0] || [DYN]) {
				const words = [head, ...elements.slice(1).map((alternatives) => alternatives[0])];
				const records = [];
				const out = { commands: [], heredocs: [], context };
				programsOfCommand(
					{ words: words.map((text) => ({ text, dyn: text.includes(DYN) })), line: tok.line },
					out,
					records
				);
				for (const record of records) {
					if (record.builtin) continue;
					emit({ ...record, probe: launcher[0] === 'probe' || record.probe });
				}
			}
			continue;
		}
		for (const text of evalPythonString(first, file, i)) {
			for (const record of analyzeShell(text, tok.line, context))
				sites.push({ file: rel, via: `${module}.${method}`, ...record });
		}
	}
	return sites;
}

// ===================================
// ===================================
// ======= 5/ Inventory & Gate =======
// ===================================
// ===================================

const EXCLUDED_DIRS = ['/vendor/', '/_generated/', '/native/'];

/**
 * Where a file runs: "host" (the Ubuntu CI runner only), "test" (the distribution
 * containers, with the CI image preparation and nothing else) or "driver" (a user's
 * machine, with the declared runtime dependencies).
 */
function scopeOf(rel) {
	if (
		rel.startsWith(`${LINUX_DIR}/tests/hardware/`) ||
		rel === `${LINUX_DIR}/tests/distro/run_in_docker.sh` ||
		HOST_FILES.has(rel)
	)
		return 'host';
	return rel.startsWith(`${LINUX_DIR}/tests/`) ? 'test' : 'driver';
}

/** The scanner that reads a file, or null for a kind this gate does not cover. */
function kindOf(rel, src) {
	if (EXCLUDED_DIRS.some((dir) => rel.includes(dir)) || EXCLUDED_FILES.has(rel)) return null;
	const ext = path.extname(rel);
	if (ext === '.lua') return 'lua';
	if (ext === '.py') return 'python';
	if (ext === '.sh') return 'shell';
	if (ext === '' && /^#!.*\b(?:ba|da)?sh\b/.test(src)) return 'shell';
	return null;
}

/**
 * Files of the Linux tree that Git knows: tracked ones, plus new ones not yet
 * added so that a local run sees a file before its author stages it. Ignored
 * build output is excluded and a file deleted in the work tree is skipped.
 */
function linuxTreeFiles() {
	const listed = spawnSync(
		'git',
		['ls-files', '-z', '--cached', '--others', '--exclude-standard', '--', LINUX_DIR],
		{ cwd: ROOT, encoding: 'utf8', maxBuffer: 1 << 26 }
	);
	if (listed.status !== 0) throw new Error(`git ls-files failed: ${listed.stderr}`);
	return [...new Set(listed.stdout.split('\0').filter(Boolean))].filter((rel) =>
		fs.existsSync(path.join(ROOT, rel))
	);
}

/**
 * Scans sources: [{ rel, src }] -> { sites, failures, files }. A site is
 * { file, line, via, name?, probe?, dynamic?, skipped?, builtin? }.
 */
function scanSources(sources) {
	const context = { names: new Set(), probes: new Set() };
	const failures = [];
	const kinds = new Map(sources.map(({ rel, src }) => [rel, kindOf(rel, src)]));
	// A Windows checkout may carry CRLF; a heredoc delimiter must still match its line.
	for (const source of sources) source.src = source.src.replace(/\r\n/g, '\n');
	for (const { rel, src } of sources) {
		if (kinds.get(rel) === 'shell') shellFunctionNames(src, context);
	}
	const sites = [];
	let files = 0;
	for (const { rel, src } of sources) {
		const kind = kinds.get(rel);
		if (!kind) continue;
		files++;
		try {
			if (kind === 'lua') sites.push(...scanLua(rel, src, context));
			else if (kind === 'python') sites.push(...scanPython(rel, src, context));
			else
				sites.push(
					...analyzeShell(src, 1, context).map((record) => ({ file: rel, via: 'shell', ...record }))
				);
		} catch (error) {
			failures.push(`${rel}: the scanner could not read this file: ${error.message}`);
		}
	}
	return { sites, failures, files };
}

/** Problems of a set of sites against PROGRAMS, plus how often each entry was used. */
function evaluateSites(sites) {
	const problems = [];
	const used = new Map();
	const probedIn = new Set(
		sites.filter((site) => site.probe && site.name).map((site) => `${site.file}\0${site.name}`)
	);
	const fixtures = [];
	for (const site of sites) {
		if (!site.name) continue;
		const scope = scopeOf(site.file);
		const where = `${site.file}:${site.line}`;
		const how = site.probe ? `${site.via}, probe` : site.via;
		if (isUnrunnablePath(site.name)) {
			if (scope === 'driver')
				problems.push(
					`${where}: "${site.name}" (${how}) names a root no system creates; a driver file cannot launch a fixture path`
				);
			else fixtures.push(site);
			continue;
		}
		used.set(site.name, (used.get(site.name) || 0) + 1);
		const entry = PROGRAMS[site.name];
		if (!entry) {
			problems.push(
				`${where}: "${site.name}" (${how}) is not in every minimal Arch, Fedora and openSUSE image, ` +
					'is not installed by CI and is not a declared runtime dependency. Read /proc or /sys, use a ' +
					'program the images ship, or declare it in PROGRAMS with its proof.'
			);
		} else if (!entry.scopes.includes(scope)) {
			problems.push(
				`${where}: "${site.name}" (${how}) is justified for ${entry.scopes.join(' and ')} only (${entry.why}), ` +
					`but this ${scope} file runs where it is absent`
			);
		} else if (entry.probed.includes(scope)) {
			if (!site.probe && !probedIn.has(`${site.file}\0${site.name}`))
				problems.push(
					`${where}: "${site.name}" (${how}) is an optional tool but this file never probes for it (command -v, has_command)`
				);
		} else if (!entry.proofs.some((item) => item.scopes.includes(scope))) {
			problems.push(
				`${where}: "${site.name}" (${how}) has no proof for this ${scope} file: no cited file covers the scope and none probes it`
			);
		}
	}
	return { problems, used, fixtures };
}

/**
 * Reads every proof file an entry cites, and refuses an entry with a scope
 * that no cited file covers and no probe guards: its justification alone is no
 * evidence.
 * @param {object} programs The reference, PROGRAMS or a self-test copy.
 * @returns {string[]}
 */
function verifyProofs(programs = PROGRAMS) {
	const problems = [];
	for (const [name, entry] of Object.entries(programs)) {
		if (entry.proofs.length === 0 && entry.probed.length === 0)
			problems.push(
				`PROGRAMS["${name}"] rests on its justification alone: cite a file proof or probe it where it is launched`
			);
		for (const scope of entry.scopes)
			if (
				!entry.probed.includes(scope) &&
				!entry.proofs.some((item) => item.scopes.includes(scope))
			)
				problems.push(`PROGRAMS["${name}"] has no proof for its ${scope} scope`);
		for (const proofOf of entry.proofs) {
			const abs = path.join(ROOT, proofOf.file);
			if (!fs.existsSync(abs)) {
				problems.push(`PROGRAMS["${name}"] cites ${proofOf.file}, which does not exist`);
			} else if (!new RegExp(proofOf.token).test(fs.readFileSync(abs, 'utf8'))) {
				problems.push(
					`PROGRAMS["${name}"] cites ${proofOf.file} for /${proofOf.token}/, which it no longer contains`
				);
			}
		}
	}
	return problems;
}

/** Whether the scanner reports a launch in a fixture: the negative self-test. */
function selfTest() {
	const problems = [];
	const find = (rel, src, name) =>
		scanSources([{ rel, src }]).sites.filter((site) => site.name === name);
	const expectFound = (label, rel, src) => {
		if (find(rel, src, 'hostname').length === 0)
			problems.push(`self-test: ${label} was not reported`);
	};
	const expectIgnored = (label, rel, src) => {
		if (find(rel, src, 'hostname').length !== 0)
			problems.push(`self-test: ${label} was reported although it is commented out`);
	};
	expectFound('Lua io.popen("hostname")', 'fixture.lua', 'local pipe = io.popen("hostname")\n');
	expectFound(
		'Lua through a local constant',
		'fixture.lua',
		'local cmd = "hostname -f"\nlocal pipe = io.popen(cmd)\n'
	);
	expectFound(
		'Lua os.execute through pcall',
		'fixture.lua',
		'pcall(os.execute, "hostname >/dev/null")\n'
	);
	expectFound(
		'Lua ShellRunner.exec_line',
		'fixture.lua',
		'local Shell = require("adapters.shell_runner")\nShell.exec_line("hostname")\n'
	);
	expectFound(
		'Lua loop over a literal table, the form of the first regression',
		'fixture.lua',
		'local Shell = require("adapters.shell_runner")\nfor _, program in ipairs({ "mkdir", "hostname" }) do\n\tShell.exec_checked("command -v " .. program)\nend\n'
	);
	expectFound(
		'Python loop over a literal list',
		'fixture.py',
		'import shutil\nfor tool in ["mkdir", "hostname"]:\n    shutil.which(tool)\n'
	);
	expectFound('shell command substitution', 'fixture.sh', '#!/bin/sh\nname=$(hostname)\n');
	expectFound(
		'shell command -v probe',
		'fixture.sh',
		'#!/bin/sh\ncommand -v hostname >/dev/null\n'
	);
	expectFound(
		'Python subprocess list',
		'fixture.py',
		'import subprocess\nsubprocess.run(["hostname"])\n'
	);
	expectIgnored('Lua line comment', 'fixture.lua', '-- local pipe = io.popen("hostname")\n');
	expectIgnored(
		'Lua block comment',
		'fixture.lua',
		'--[[\nlocal pipe = io.popen("hostname")\n]]\nlocal ok = 1\n'
	);
	expectIgnored('Lua trailing comment', 'fixture.lua', 'local ok = 1 -- io.popen("hostname")\n');
	expectIgnored('Lua leveled block comment', 'fixture.lua', '--[==[ io.popen("hostname") ]==]\n');
	expectIgnored('shell comment', 'fixture.sh', '#!/bin/sh\n# hostname\necho ok # hostname\n');
	expectIgnored('shell heredoc body', 'fixture.sh', '#!/bin/sh\ncat <<EOF\nhostname\nEOF\n');
	expectIgnored(
		'shell case pattern',
		'fixture.sh',
		'#!/bin/sh\ncase "$1" in\n hostname) echo x ;;\nesac\n'
	);
	expectIgnored(
		'Python comment',
		'fixture.py',
		'import subprocess\n# subprocess.run(["hostname"])\n'
	);
	expectIgnored(
		'text in a Lua string',
		'fixture.lua',
		'local x = "-- io.popen(hostname)"\nlocal y = 1\n'
	);
	if (PROGRAMS.hostname)
		problems.push(
			'self-test: "hostname" must stay out of PROGRAMS, it is the program the images lack'
		);
	const fixture = scanSources([{ rel: 'fixture.lua', src: 'local pipe = io.popen("hostname")\n' }]);
	if (evaluateSites(fixture.sites).problems.length !== 1)
		problems.push('self-test: the reference check did not reject io.popen("hostname")');
	// A program justified for the Ubuntu runners only must be refused in a unit test.
	const hostOnly = scanSources([
		{ rel: `${LINUX_DIR}/tests/unit/fixture.lua`, src: 'local p = io.popen("Xvfb")\n' }
	]);
	if (evaluateSites(hostOnly.sites).problems.length !== 1)
		problems.push('self-test: a host-only program was accepted in a unit test');
	// A probed tool must be probed in a host file too: no scope is exempt.
	const unprobedHost = scanSources([
		{ rel: `${LINUX_DIR}/tests/hardware/fixture.sh`, src: '#!/bin/sh\ndocker info\n' }
	]);
	if (evaluateSites(unprobedHost.sites).problems.length !== 1)
		problems.push('self-test: an unprobed host launch of a probed tool was accepted');
	const probedHost = scanSources([
		{
			rel: `${LINUX_DIR}/tests/hardware/fixture.sh`,
			src: '#!/bin/sh\ncommand -v docker >/dev/null || exit 2\ndocker info\n'
		}
	]);
	if (evaluateSites(probedHost.sites).problems.length !== 0)
		problems.push('self-test: a probed host launch of a probed tool was refused');
	// A fixture path is recognised by its root in a test, refused in the driver.
	const fixturePath = (rel) =>
		evaluateSites(
			scanSources([{ rel, src: 'local p = io.popen("/nonexistent/ergopti-fixture")\n' }]).sites
		);
	const testFixture = fixturePath(`${LINUX_DIR}/tests/unit/fixture.lua`);
	if (testFixture.problems.length !== 0 || testFixture.fixtures.length !== 1)
		problems.push('self-test: a test fixture path was not recognised structurally');
	if (fixturePath(`${LINUX_DIR}/adapters/fixture.lua`).problems.length !== 1)
		problems.push('self-test: a fixture path was accepted in a driver file');
	if (!isUnrunnablePath('/not/a/real/program') || isUnrunnablePath('/usr/local/bin/x'))
		problems.push('self-test: the filesystem-root rule misjudged a path');
	if (isUnrunnablePath('/opt/vendor/bin/x') || isUnrunnablePath('fixture-name'))
		problems.push('self-test: an installable or bare name was taken for a fixture path');
	// An entry with neither a proof nor a probe is refused, whatever it says.
	const unbacked = { bare: why('a reason and nothing else', ALL) };
	if (verifyProofs(unbacked).length === 0)
		problems.push('self-test: an entry resting on its justification alone was accepted');
	// A proof bound to one scope cannot stand in for another.
	const hostOnlyProof = {
		bound: why('installed on the Ubuntu runners only', DRIVER_HOST, {
			proof: { file: CI_LINUX, token: 'ubuntu_apt', scopes: HOST }
		})
	};
	if (verifyProofs(hostOnlyProof).length !== 1)
		problems.push('self-test: a host-bound proof was accepted for the driver scope');
	return problems;
}

// =========================
// =========================
// ======= 6/ Report =======
// =========================
// =========================

const errors = [];
const sources = linuxTreeFiles().map((rel) => ({
	rel,
	src: fs.readFileSync(path.join(ROOT, rel), 'utf8')
}));
const scan = scanSources(sources);
errors.push(...scan.failures, ...selfTest(), ...verifyProofs());

const launches = scan.sites.filter((site) => !site.builtin);
const resolved = launches.filter((site) => site.name);
const dynamic = launches.filter((site) => site.dynamic);
const skipped = launches.filter((site) => site.skipped);
const builtins = scan.sites.filter((site) => site.builtin);

const kindOfSite = (site) =>
	site.file.endsWith('.lua') ? 'lua' : site.file.endsWith('.py') ? 'python' : 'shell';
const measured = {
	total: launches.length,
	lua: launches.filter((site) => kindOfSite(site) === 'lua').length,
	shell: launches.filter((site) => kindOfSite(site) === 'shell').length,
	python: launches.filter((site) => kindOfSite(site) === 'python').length,
	resolved: resolved.length
};
for (const [key, floor] of Object.entries(FLOORS)) {
	if (measured[key] < floor) {
		errors.push(
			`only ${measured[key]} ${key} call sites found, expected at least ${floor}: the scanner no longer reads the Linux tree`
		);
	}
}

const evaluation = evaluateSites(scan.sites);
errors.push(...evaluation.problems);
for (const name of Object.keys(PROGRAMS)) {
	if (!evaluation.used.has(name))
		errors.push(`PROGRAMS["${name}"] is used by no call site any more: delete it`);
}

if (process.env.ERGOPTI_PORTABLE_COMMANDS_REPORT) {
	const byName = new Map();
	for (const site of resolved) {
		if (!byName.has(site.name)) byName.set(site.name, []);
		byName.get(site.name).push(site);
	}
	for (const [name, list] of [...byName].sort((a, b) => a[0].localeCompare(b[0]))) {
		const scopes = ['driver', 'test', 'host'].map((scope) => {
			const inScope = list.filter((site) => scopeOf(site.file) === scope);
			const first = inScope[0];
			return inScope.length
				? `${scope}=${inScope.length}@${first.file.replace(`${LINUX_DIR}/`, '')}:${first.line}`
				: '';
		});
		console.log(
			`${name}\t${list.length}\t${PROGRAMS[name] ? 'listed' : 'UNLISTED'}\t${scopes.filter(Boolean).join(' ')}`
		);
	}
	console.log(`-- dynamic (${dynamic.length})`);
	for (const site of dynamic)
		console.log(
			`${site.file.replace(`${LINUX_DIR}/`, '')}:${site.line}\t${site.via}\t${site.dynamic}`
		);
	console.log(`-- skipped repository paths (${skipped.length})`);
	for (const site of skipped)
		console.log(`${site.file.replace(`${LINUX_DIR}/`, '')}:${site.line}\t${site.skipped}`);
}

if (errors.length > 0) {
	console.error(
		'\x1b[31m[FAIL] Linux code launches programs the minimal Arch, Fedora and openSUSE images lack:\x1b[0m'
	);
	for (const e of errors) console.error(`  - ${e}`);
	process.exit(1);
}

const byKind = { proof: 0, probed: 0 };
for (const name of evaluation.used.keys()) {
	if (PROGRAMS[name].probed.length === 0) byKind.proof++;
	else byKind.probed++;
}
console.log(
	`\x1b[32m[OK] ${measured.total} Linux call sites in ${scan.files} files (floor ${FLOORS.total}; ` +
		`${measured.lua} Lua, ${measured.shell} shell, ${measured.python} Python): ` +
		`${evaluation.used.size} programs proven in PROGRAMS ` +
		`(${byKind.proof} with file proofs alone, ${byKind.probed} probed where launched in some scope, none on its justification alone); ` +
		`${evaluation.fixtures.length} test launches of fixture paths no system holds; ` +
		`${dynamic.length} dynamic and ${skipped.length} repository-path launches skipped by design, ` +
		`${builtins.length} shell builtins not counted; the scanner reports io.popen("hostname") and ignores it in comments.\x1b[0m`
);
