// tools/test/test-linux-uninstall-sandbox.cjs

/**
 * ==============================================================================
 * MODULE: Linux Standalone Uninstall Regression
 * DESCRIPTION:
 * Exercises the shipped uninstaller against an isolated prefix. Removal must
 * preserve configuration and unrelated files and reject unowned installations.
 * ==============================================================================
 */

'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { createHash } = require('crypto');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const script = path.join(ROOT, 'static/ergopti_plus/linux/uninstall.sh');
assert.ok(fs.existsSync(script), 'Linux must ship an uninstaller beside install.sh');
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-uninstall-'));
const bashPath = (value) =>
	value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`);

try {
	const home = path.join(sandbox, 'home');
	const prefix = path.join(home, 'prefix with spaces');
	const library = path.join(prefix, 'lib/ergopti');
	const wrapper = path.join(prefix, 'bin/ergopti-hotstrings');
	const config = path.join(home, '.config/ergopti_plus/personal.toml');
	const neighbour = path.join(prefix, 'lib/another-app/keep');
	for (const file of [
		config,
		neighbour,
		path.join(library, 'linux/ergopti_hotstrings.lua'),
		path.join(library, '_shared/data/locales/en.json'),
		wrapper
	]) {
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, 'sentinel');
	}
	const stubs = path.join(sandbox, 'stubs');
	fs.mkdirSync(stubs);
	fs.writeFileSync(path.join(stubs, 'systemctl'), '#!/bin/bash\nexit 0\n', { mode: 0o755 });
	const run = (...args) =>
		spawnSync(bashExecutable(), [bashPath(script), '--prefix', bashPath(prefix), ...args], {
			encoding: 'utf8',
			input: '',
			timeout: 15000,
			env: { HOME: bashPath(home), PATH: `${bashPath(stubs)}:/usr/bin:/bin` }
		});
	assert.notEqual(run('--yes').status, 0, 'an unrelated wrapper must prevent removal');
	assert.ok(fs.existsSync(library), 'refusal preserves the installation');
	fs.writeFileSync(
		wrapper,
		`#!/bin/bash\nDRIVER_ROOT="${bashPath(library)}/linux"\nexec luajit "\${DRIVER_ROOT}/ergopti_hotstrings.lua" "$@"\n`
	);
	const manifest = ['linux/ergopti_hotstrings.lua', '_shared/data/locales/en.json']
		.map(
			(relative) =>
				`${createHash('sha256')
					.update(fs.readFileSync(path.join(library, relative)))
					.digest('hex')}\t${relative}\n`
		)
		.join('');
	const wrapperHash = createHash('sha256').update(fs.readFileSync(wrapper)).digest('hex');
	fs.writeFileSync(
		path.join(library, '.ergopti-owned-files'),
		manifest + `${wrapperHash}\t@wrapper\n`
	);
	const ownershipPath = path.join(library, '.ergopti-owned-files');
	const validOwnership = fs.readFileSync(ownershipPath, 'utf8');
	for (const invalidPath of ['linux/../../another-app/keep', 'linux//file', '@unknown']) {
		fs.writeFileSync(ownershipPath, validOwnership + `${wrapperHash}\t${invalidPath}\n`);
		assert.notEqual(run('--yes').status, 0, `unsafe receipt must be refused: ${invalidPath}`);
		assert.ok(fs.existsSync(wrapper), 'receipt refusal must happen before any deletion');
	}
	fs.writeFileSync(ownershipPath, validOwnership);
	const gitMarker = path.join(prefix, '.git');
	fs.writeFileSync(gitMarker, 'gitdir: elsewhere');
	assert.notEqual(run('--yes').status, 0, 'a registered checkout ancestor prevents removal');
	assert.ok(fs.existsSync(wrapper));
	fs.unlinkSync(gitMarker);
	const unit = path.join(home, '.config/systemd/user/ergopti-hotstrings.service');
	fs.mkdirSync(path.dirname(unit), { recursive: true });
	fs.writeFileSync(unit, `[Service]\nExecStart=${bashPath(wrapper)} --tray\n`);
	assert.notEqual(run('--yes').status, 0, 'an unrecorded service prevents removal');
	assert.ok(fs.existsSync(wrapper));
	fs.unlinkSync(unit);
	const desktop = path.join(home, '.config/autostart/ergopti-hotstrings.desktop');
	fs.mkdirSync(path.dirname(desktop), { recursive: true });
	const desktopExec = spawnSync(
		bashExecutable(),
		[
			'-c',
			'source "$1"; ergopti_desktop_exec "$2"',
			'desktop-owner',
			bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install/desktop_entry.sh')),
			bashPath(wrapper)
		],
		{ encoding: 'utf8' }
	);
	assert.equal(desktopExec.status, 0, desktopExec.stderr);
	fs.writeFileSync(
		desktop,
		`[Desktop Entry]\nType=Application\nName=Ergopti\n${desktopExec.stdout}Hidden=true\n`
	);
	const desktopHash = createHash('sha256').update(fs.readFileSync(desktop)).digest('hex');
	fs.appendFileSync(ownershipPath, `${desktopHash}\t@autostart\n`);
	assert.equal(run('--check').status, 0, 'preflight validates without removing files');
	assert.ok(fs.existsSync(wrapper));
	// The current installer uses Bash literal assignments and a quoted systemd
	// command. Accept that exact owner as well as the historical wrapper above.
	const quotedRoot = spawnSync(
		bashExecutable(),
		['-c', 'printf "%q" "$1"', 'wrapper-owner', `${bashPath(library)}/linux`],
		{ encoding: 'utf8' }
	);
	assert.equal(quotedRoot.status, 0);
	fs.writeFileSync(
		wrapper,
		`#!/bin/bash\nDRIVER_ROOT=${quotedRoot.stdout}\nexec bash "\${DRIVER_ROOT}/install/launch.sh" --service "$@"\n`
	);
	fs.writeFileSync(unit, `[Service]\nExecStart=/bin/bash "${bashPath(wrapper)}" --tray\n`);
	const newWrapperHash = createHash('sha256').update(fs.readFileSync(wrapper)).digest('hex');
	const unitHash = createHash('sha256').update(fs.readFileSync(unit)).digest('hex');
	fs.writeFileSync(
		ownershipPath,
		manifest + `${newWrapperHash}\t@wrapper\n${unitHash}\t@unit\n${desktopHash}\t@autostart\n`
	);
	const currentPreflight = run('--check');
	assert.equal(currentPreflight.status, 0, currentPreflight.stderr);
	const quotedInstall = spawnSync(
		bashExecutable(),
		['-c', 'printf "%q" "$1"', 'wrapper-owner', bashPath(library)],
		{ encoding: 'utf8' }
	);
	assert.equal(quotedInstall.status, 0);
	fs.writeFileSync(
		wrapper,
		`#!/bin/bash\nINSTALL_ROOT=${quotedInstall.stdout}\nexec bash "\${INSTALL_ROOT}/bin/ergopti-hotstrings" "$@"\n`
	);
	const innerLauncher = path.join(library, 'bin/ergopti-hotstrings');
	fs.mkdirSync(path.dirname(innerLauncher), { recursive: true });
	fs.writeFileSync(innerLauncher, '#!/bin/bash\nexit 0\n');
	const versionedHash = createHash('sha256').update(fs.readFileSync(innerLauncher)).digest('hex');
	const forwardingHash = createHash('sha256').update(fs.readFileSync(wrapper)).digest('hex');
	fs.writeFileSync(
		ownershipPath,
		manifest +
			`${forwardingHash}\t@wrapper\n${unitHash}\t@unit\n${desktopHash}\t@autostart\n${versionedHash}\tbin/ergopti-hotstrings\n`
	);
	const forwardingPreflight = run('--check');
	assert.equal(forwardingPreflight.status, 0, forwardingPreflight.stderr);
	const personalInside = path.join(library, 'linux/personal.toml');
	fs.writeFileSync(personalInside, 'personal-inside');
	fs.writeFileSync(path.join(library, '_shared/data/locales/en.json'), 'user-modified');
	assert.notEqual(run().status, 0, 'EOF is not confirmation');
	assert.ok(fs.existsSync(library), 'cancel preserves the installation');
	const removed = run('--yes');
	assert.equal(removed.status, 0, removed.stderr || removed.error?.message);
	assert.ok(
		!fs.existsSync(path.join(library, 'linux/ergopti_hotstrings.lua')),
		'owned runtime removed'
	);
	assert.equal(
		fs.readFileSync(personalInside, 'utf8'),
		'personal-inside',
		'unlisted personal files inside runtime survive'
	);
	assert.equal(
		fs.readFileSync(path.join(library, '_shared/data/locales/en.json'), 'utf8'),
		'user-modified',
		'modified shipped files survive'
	);
	assert.ok(!fs.existsSync(wrapper), 'owned launcher removed');
	assert.ok(!fs.existsSync(innerLauncher), 'versioned launcher removed with its payload');
	assert.ok(!fs.existsSync(desktop), 'menu-created startup entry removed');
	assert.ok(!fs.existsSync(unit), 'quoted service entry removed');
	assert.equal(fs.readFileSync(config, 'utf8'), 'sentinel', 'personal data preserved');
	assert.equal(fs.readFileSync(neighbour, 'utf8'), 'sentinel', 'neighbour application preserved');
	console.log('[OK] Linux uninstaller removes only the validated standalone installation.');
} finally {
	fs.rmSync(sandbox, { recursive: true, force: true });
}
