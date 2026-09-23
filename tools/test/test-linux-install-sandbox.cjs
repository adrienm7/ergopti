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
 * The upstream kanata 1.12.0 binary needs glibc 2.39. On Ubuntu 22.04 and
 * Debian 12 its version check failed, _install_kanata returned 1 under
 * `set -e`, and the script died BEFORE copying a single driver file: no
 * launcher, no service, nothing to start — for a component hotstrings do not
 * even need. A failed kanata must leave a working install behind.
 *
 * ROOT CAUSE 2 — A DISTRIBUTION'S KANATA WAS NEVER ENABLED.
 * With kanata already on PATH (AUR, Nix, cargo) the download is skipped, but
 * the unit's ExecStart and the enable guard both named ~/.local/bin/kanata,
 * which then does not exist. The unit must run the kanata that is there.
 *
 * ROOT CAUSE 3 — THE DESKTOP HALF WAS NEVER INSTALLED.
 * The tray's libayatana-appindicator and the windows' WebKit2GTK typelib were
 * left to the user, so a fresh install showed no tray icon anywhere. Each must
 * be requested from the package manager when its probe fails.
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
 * @param {object} scenario { distroKanata: boolean, desktopProvided: boolean }
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
	const log = `echo "$(basename "$0") $*" >> ${JSON.stringify(bashPath(callLog))}`;

	// Privilege is recorded and never performed — except the package manager,
	// which is itself a stub, so its markers are what the probes read back.
	stub(stubs, 'sudo', `${log}\n[ "$1" = apt-get ] && exec "$@"\nexit 0`);
	stub(stubs, 'systemctl', `${log}\nexit 1`);
	// The package manager "installs" by dropping a marker the probes read.
	stub(stubs, 'apt-get', `${log}\nfor p in "$@"; do touch ${JSON.stringify(bashPath(state))}/"$p"; done\nexit 0`);
	// Every command a real system would provide.
	for (const name of ['notify-send', 'xkbcli', 'unzip', 'sha256sum']) stub(stubs, name, 'exit 0');
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
			'  *) exit 0 ;;',
			'esac'
		].join('\n')
	);
	// The kanata download: an archive whose checksum cannot match, i.e. the
	// same failure branch a binary that needs a newer glibc reaches.
	stub(stubs, 'curl', `${log}\nwhile [ $# -gt 0 ]; do [ "$1" = --output ] && { echo junk > "$2"; }; shift; done\nexit 0`);
	if (scenario.distroKanata) stub(stubs, 'kanata', 'echo "kanata 1.12.0"');

	const env = {
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

// ── A kanata that cannot be installed ──────────────────────────────────────
{
	const run = runInstaller({ distroKanata: false, desktopProvided: false });
	try {
		if (run.status !== 0) {
			errors.push(
				`install.sh exited ${run.status} when kanata could not be installed — it must finish the ` +
					`install without it. Last lines:\n${run.output.split('\n').slice(-12).join('\n')}`
			);
		}
		const launcher = path.join(run.home, '.local', 'bin', 'ergopti-hotstrings');
		if (!fs.existsSync(launcher)) {
			errors.push('no launcher was installed after a failed kanata download');
		}
		const daemon = path.join(run.home, '.local', 'lib', 'ergopti', 'linux', 'ergopti_hotstrings.lua');
		if (!fs.existsSync(daemon)) errors.push('the driver tree was not copied after a failed kanata download');
		if (!/kanata indisponible/.test(run.output)) {
			errors.push('a failed kanata install must be reported, not silent');
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

// ── A kanata the distribution already provides ─────────────────────────────
{
	const run = runInstaller({ distroKanata: true, desktopProvided: true });
	try {
		if (run.status !== 0) errors.push(`install.sh exited ${run.status} with kanata already on PATH`);
		const unit = path.join(run.home, '.config', 'systemd', 'user', 'kanata.service');
		const text = fs.existsSync(unit) ? fs.readFileSync(unit, 'utf8') : '';
		const execStart = (text.match(/^ExecStart=(\S+)/m) || [])[1] || '';
		if (execStart !== `${bashPath(run.stubs)}/kanata`) {
			errors.push(
				`kanata.service runs '${execStart || '<missing>'}' while the only kanata is the distribution's ` +
					`at ${bashPath(run.stubs)}/kanata — the unit would start nothing`
			);
		}
		if (run.calls.some((call) => call.startsWith('curl'))) {
			errors.push('kanata was downloaded although one is already on PATH');
		}
		if (run.calls.some((call) => /appindicator|webkit2/.test(call))) {
			errors.push('desktop backends that were already present were installed again');
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
	'\x1b[32m[OK] install.sh finishes without kanata, runs a distribution kanata, and installs the tray and window backends.\x1b[0m'
);
