// tools/test/test-linux-compositor-focus-install.cjs

/**
 * ==============================================================================
 * MODULE: Linux Desktop Focus Integration Installer
 * DESCRIPTION:
 * Runs the real linux/install/compositor_focus.sh in a throwaway HOME with
 * gnome-extensions, gsettings, kwriteconfig6 and gdbus replaced by recording
 * stubs. Pins what the per-application rules depend on under GNOME and KDE
 * Wayland: the extension and the KWin script are copied for the running
 * desktop only, enabled on the first install (for the next login when the
 * Shell refuses), left as the user set them on an update, and removed with
 * their enablement by uninstall, without touching a folder of the same name
 * the installer did not write.
 * ==============================================================================
 */

'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const { isLocalWindowsHost, reportNotExecuted } = require('./lib/host-capabilities.cjs');

if (isLocalWindowsHost()) {
	reportNotExecuted(
		'Linux desktop focus integration installer',
		'the helper writes Linux desktop folders through a POSIX shell'
	);
	process.exit(0);
}

const ROOT = path.resolve(__dirname, '..', '..');
const DRIVER = path.join(ROOT, 'static', 'ergopti_plus', 'linux');
const HELPER = path.join(DRIVER, 'install', 'compositor_focus.sh');
const UUID = 'focus@ergopti.fr';

function stub(dir, name, body) {
	fs.writeFileSync(path.join(dir, name), `#!/usr/bin/env bash\n${body}\n`, { mode: 0o755 });
}

/** One sandbox: a HOME, recording stubs and a gsettings value kept in a file. */
function sandbox({
	gnomeEnable = false,
	enabled = "['user-theme@gnome-shell-extensions.gcampax.github.com']"
} = {}) {
	const top = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-focus-install-'));
	const home = path.join(top, 'home');
	const stubs = path.join(top, 'stubs');
	const log = path.join(top, 'calls');
	const setting = path.join(top, 'enabled-extensions');
	fs.mkdirSync(home);
	fs.mkdirSync(stubs);
	fs.writeFileSync(setting, enabled);
	const record = `printf '%s %s\\n' "$(basename "$0")" "$*" >> ${JSON.stringify(log)}`;
	stub(
		stubs,
		'gnome-extensions',
		`${record}\n[ "$1" = enable ] && exit ${gnomeEnable ? 0 : 1}\nexit 0`
	);
	stub(
		stubs,
		'gsettings',
		`${record}\nif [ "$1" = get ]; then cat ${JSON.stringify(setting)}; exit 0; fi\n` +
			`if [ "$1" = set ]; then printf '%s' "$4" > ${JSON.stringify(setting)}; fi\nexit 0`
	);
	stub(stubs, 'kwriteconfig6', `${record}\nexit 0`);
	stub(stubs, 'gdbus', `${record}\nexit 0`);
	const run = (args, desktop) => {
		const result = spawnSync(bashExecutable(), [HELPER, ...args], {
			encoding: 'utf8',
			env: {
				HOME: home,
				PATH: `${stubs}:/usr/bin:/bin`,
				LANG: 'C.UTF-8',
				...(desktop ? { XDG_CURRENT_DESKTOP: desktop } : {})
			}
		});
		assert.equal(result.status, 0, `${args.join(' ')} failed: ${result.stderr}`);
		return result.stdout + result.stderr;
	};
	const calls = () => (fs.existsSync(log) ? fs.readFileSync(log, 'utf8') : '');
	return {
		home,
		run,
		calls,
		setting: () => fs.readFileSync(setting, 'utf8'),
		gnome: path.join(home, '.local/share/gnome-shell/extensions', UUID),
		kwin: path.join(home, '.local/share/kwin/scripts/ergopti-focus'),
		cleanup: () => fs.rmSync(top, { recursive: true, force: true })
	};
}

const errors = [];
function check(label, fn) {
	try {
		fn();
		console.log(`  ✔ ${label}`);
	} catch (error) {
		errors.push(`${label}: ${error.message}`);
		console.log(`  ✘ ${label}`);
	}
}

check('GNOME: a first install copies and enables the extension for the next login', () => {
	const box = sandbox();
	try {
		const output = box.run(['install', DRIVER], 'ubuntu:GNOME');
		assert.ok(fs.existsSync(path.join(box.gnome, 'extension.js')));
		assert.ok(fs.existsSync(path.join(box.gnome, 'metadata.json')));
		assert.ok(!fs.existsSync(box.kwin), 'the KWin script is for KDE only');
		assert.equal(
			box.setting(),
			`['user-theme@gnome-shell-extensions.gcampax.github.com', '${UUID}']`,
			'merged into the user list, not replacing it'
		);
		assert.match(output, /effective at the next login/);
	} finally {
		box.cleanup();
	}
});

check('GNOME: an update refreshes the files and keeps a user-disabled extension off', () => {
	const box = sandbox({ gnomeEnable: true });
	try {
		box.run(['install', DRIVER], 'GNOME');
		assert.match(box.calls(), new RegExp(`gnome-extensions enable ${UUID}`));
		fs.writeFileSync(path.join(box.gnome, 'extension.js'), 'stale');
		const before = box.calls();
		const output = box.run(['install', DRIVER], 'GNOME');
		assert.equal(
			fs.readFileSync(path.join(box.gnome, 'extension.js'), 'utf8'),
			fs.readFileSync(path.join(DRIVER, 'desktop_focus/gnome/extension.js'), 'utf8')
		);
		assert.equal(box.calls(), before, 'no enable on an update');
		assert.match(output, /focus integration updated/);
		assert.equal(box.run(['install', DRIVER], 'GNOME'), '', 'an unchanged copy says nothing');
	} finally {
		box.cleanup();
	}
});

check('KDE: a first install copies, enables in kwinrc and asks KWin to load it', () => {
	const box = sandbox();
	try {
		box.run(['install', DRIVER], 'KDE');
		assert.ok(fs.existsSync(path.join(box.kwin, 'contents/code/main.js')));
		assert.ok(!fs.existsSync(box.gnome));
		const calls = box.calls();
		assert.match(
			calls,
			/kwriteconfig6 --file kwinrc --group Plugins --key ergopti-focusEnabled true/
		);
		assert.match(
			calls,
			/gdbus call --session --dest org\.kde\.KWin --object-path \/Scripting --method org\.kde\.kwin\.Scripting\.start/
		);
	} finally {
		box.cleanup();
	}
});

check('other desktops: nothing is installed', () => {
	const box = sandbox();
	try {
		box.run(['install', DRIVER], 'COSMIC');
		box.run(['install', DRIVER], undefined);
		assert.ok(!fs.existsSync(path.join(box.home, '.local')));
		assert.equal(box.calls(), '');
	} finally {
		box.cleanup();
	}
});

check('remove: both integrations and their enablement go, a foreign folder stays', () => {
	const box = sandbox();
	try {
		box.run(['install', DRIVER], 'GNOME');
		box.run(['install', DRIVER], 'KDE');
		box.run(['remove'], undefined);
		assert.ok(!fs.existsSync(box.gnome) && !fs.existsSync(box.kwin));
		assert.equal(box.setting(), "['user-theme@gnome-shell-extensions.gcampax.github.com']");
		const calls = box.calls();
		assert.match(calls, /--key ergopti-focusEnabled --delete/);
		assert.match(calls, /Scripting\.unloadScript ergopti-focus/);
		fs.mkdirSync(box.gnome, { recursive: true });
		fs.writeFileSync(path.join(box.gnome, 'metadata.json'), '{"uuid": "someone-else"}');
		box.run(['remove'], undefined);
		assert.ok(fs.existsSync(box.gnome), 'a folder this helper did not write is kept');
	} finally {
		box.cleanup();
	}
});

check('the installer, the uninstaller and the launcher call the helper', () => {
	const read = (relative) => fs.readFileSync(path.join(DRIVER, relative), 'utf8');
	assert.match(read('install.sh'), /install\/compositor_focus\.sh" install "\$\{LIB_DIR\}\/linux"/);
	assert.match(read('uninstall.sh'), /install\/compositor_focus\.sh" remove/);
	assert.match(read('install/launch.sh'), /install\/compositor_focus\.sh" install "\$DRIVER_ROOT"/);
});

if (errors.length) {
	console.error(errors.join('\n'));
	process.exit(1);
}
console.log('Linux desktop focus integration installer: all checks passed.');
