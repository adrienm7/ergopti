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
	let configHome = null;
	fs.mkdirSync(stubs);
	fs.writeFileSync(path.join(stubs, 'systemctl'), '#!/bin/bash\nexit 0\n', { mode: 0o755 });
	const run = (...args) =>
		spawnSync(bashExecutable(), [bashPath(script), '--prefix', bashPath(prefix), ...args], {
			encoding: 'utf8',
			input: '',
			timeout: 15000,
			env: {
				HOME: bashPath(home),
				PATH: `${bashPath(stubs)}:/usr/bin:/bin`,
				...(configHome ? { XDG_CONFIG_HOME: bashPath(configHome) } : {})
			}
		});
	assert.notEqual(run('--yes').status, 0, 'an unrelated wrapper must prevent removal');
	assert.ok(fs.existsSync(library), 'refusal preserves the installation');
	// The failure dialog falls back from zenity to kdialog, then to stderr and
	// notify-send, so a KDE host without zenity still reports the failure.
	const kdialogLog = path.join(sandbox, 'kdialog.log');
	const notifyLog = path.join(sandbox, 'notify.log');
	fs.writeFileSync(
		path.join(stubs, 'kdialog'),
		`#!/bin/bash\nprintf '%s|' "$@" > "${bashPath(kdialogLog)}"\n`,
		{ mode: 0o755 }
	);
	assert.notEqual(run('--yes', '--gui', 'Title', 'Body', 'Missing {1}').status, 0);
	assert.match(
		fs.readFileSync(kdialogLog, 'utf8'),
		/--error\|Body\|/,
		'kdialog must show the failure'
	);
	fs.unlinkSync(path.join(stubs, 'kdialog'));
	fs.writeFileSync(
		path.join(stubs, 'notify-send'),
		`#!/bin/bash\nprintf '%s|' "$@" > "${bashPath(notifyLog)}"\n`,
		{ mode: 0o755 }
	);
	const bareRun = run('--yes', '--gui', 'Title', 'Body', 'Missing {1}');
	assert.match(bareRun.stderr, /Title: Body/, 'stderr must carry the failure text');
	assert.match(
		fs.readFileSync(notifyLog, 'utf8'),
		/Title\|Body\|/,
		'notify-send is the last resort'
	);
	fs.unlinkSync(path.join(stubs, 'notify-send'));
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
	// Replay removal under a custom XDG config root. An ignored @unit receipt
	// otherwise leaves an enabled service pointing to the deleted launcher.
	configHome = path.join(home, 'config with spaces');
	const customUnit = path.join(configHome, 'systemd/user/ergopti-hotstrings.service');
	const customPersonal = path.join(configHome, 'ergopti/personal.toml');
	const ownedFiles = [
		['linux/ergopti_hotstrings.lua', path.join(library, 'linux/ergopti_hotstrings.lua'), 'runtime'],
		[
			'@wrapper',
			wrapper,
			`#!/bin/bash\nDRIVER_ROOT="${bashPath(library)}/linux"\nexec luajit "\${DRIVER_ROOT}/ergopti_hotstrings.lua" "$@"\n`
		],
		['@unit', customUnit, `[Service]\nExecStart=/bin/bash "${bashPath(wrapper)}" --tray\n`]
	];
	let customManifest = '';
	for (const [relative, file, contents] of ownedFiles) {
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, contents);
		customManifest += `${createHash('sha256').update(contents).digest('hex')}\t${relative}\n`;
	}
	fs.mkdirSync(path.dirname(customPersonal), { recursive: true });
	fs.writeFileSync(customPersonal, 'custom-personal');
	fs.writeFileSync(ownershipPath, customManifest);
	const customPreflight = run('--check');
	assert.equal(customPreflight.status, 0, customPreflight.stderr);
	assert.ok(fs.existsSync(customUnit), 'XDG preflight preserves the owned service');
	const customRemoval = run('--yes');
	assert.equal(customRemoval.status, 0, customRemoval.stderr);
	assert.ok(!fs.existsSync(customUnit), 'XDG config service must be removed with its launcher');
	assert.equal(fs.readFileSync(customPersonal, 'utf8'), 'custom-personal');
	// A system installation owned by dpkg on a host without apt-get exits 69
	// after a machine-readable `missing-program apt-get` line, and the menu's
	// localized template reaches the dialog with the program filled in.
	const packaged = path.join(sandbox, 'packaged');
	const bare = path.join(sandbox, 'bare');
	fs.mkdirSync(path.join(packaged, 'install'), { recursive: true });
	fs.mkdirSync(bare);
	for (const helper of ['desktop_entry.sh', 'config_home.sh']) {
		fs.copyFileSync(
			path.join(path.dirname(script), 'install', helper),
			path.join(packaged, 'install', helper)
		);
	}
	fs.writeFileSync(
		path.join(packaged, 'uninstall.sh'),
		fs
			.readFileSync(script, 'utf8')
			.replace('[ "$SCRIPT_DIR" = /usr/lib/ergopti ]', `[ "$SCRIPT_DIR" = ${bashPath(packaged)} ]`)
			.replace(
				"'ergopti: /usr/lib/ergopti/uninstall.sh'",
				`'ergopti: ${bashPath(packaged)}/uninstall.sh'`
			)
	);
	for (const name of ['dirname', 'grep', 'cat', 'rm']) {
		fs.symlinkSync(
			['/usr/bin', '/bin'].map((d) => path.join(d, name)).find(fs.existsSync),
			path.join(bare, name)
		);
	}
	fs.writeFileSync(
		path.join(bare, 'dpkg-query'),
		`#!/bin/bash\necho 'ergopti: ${bashPath(packaged)}/uninstall.sh'\n`,
		{ mode: 0o755 }
	);
	const dialogLog = path.join(sandbox, 'missing-dialog.log');
	fs.writeFileSync(
		path.join(bare, 'zenity'),
		`#!/bin/bash\nprintf '%s|' "$@" > "${bashPath(dialogLog)}"\n`,
		{ mode: 0o755 }
	);
	const nativeActionLog = path.join(sandbox, 'native-package-action.log');
	let nativePackageOwner = 'ergopti';
	let nativeActionStatus = '0';
	let nativeQueryStatus = '0';
	const packagedRun = (...args) =>
		spawnSync(bashExecutable(), [bashPath(path.join(packaged, 'uninstall.sh')), ...args], {
			encoding: 'utf8',
			input: '',
			timeout: 15000,
			env: {
				HOME: bashPath(home),
				PATH: bashPath(bare),
				ERGOPTI_TEST_PACKAGE_OWNER: nativePackageOwner,
				ERGOPTI_TEST_PACKAGE_STATUS: nativeActionStatus,
				ERGOPTI_TEST_QUERY_STATUS: nativeQueryStatus,
				ERGOPTI_TEST_PACKAGE_LOG: nativeActionLog,
				ERGOPTI_TEST_PACKAGE_FILE: path.join(packaged, 'uninstall.sh')
			}
		});
	const terminal = packagedRun('--yes');
	assert.equal(terminal.status, 69, 'a missing package manager is EX_UNAVAILABLE');
	assert.equal(terminal.stderr.trim(), 'missing-program apt-get', 'the program is named on stderr');
	const menu = packagedRun('--yes', '--gui', 'Title', 'Body', 'Install {1} first');
	assert.equal(menu.status, 69);
	assert.match(
		fs.readFileSync(dialogLog, 'utf8'),
		/--text=Install apt-get first\|/,
		'the dialog shows the localized message naming the missing program'
	);
	if (process.platform === 'linux') {
		// Absolute native paths are not payload-relative paths. GNU checksums
		// escape the former when they contain a backslash, even though the
		// receipt's relative names need no escaping at all.
		const nativeRoot = path.join(sandbox, 'native\\path with spaces');
		const nativeSource = path.join(nativeRoot, 'source\\checkout');
		const nativeDriver = path.join(nativeSource, 'linux');
		const nativeShared = path.join(nativeSource, '_shared');
		const nativePrefix = path.join(nativeRoot, 'prefix\\installed');
		const nativeLibrary = path.join(nativePrefix, 'lib/ergopti');
		const nativeWrapper = path.join(nativePrefix, 'bin/ergopti-hotstrings');
		const nativeConfig = path.join(nativeRoot, 'config\\settings');
		const nativeDesktop = path.join(nativeConfig, 'autostart/ergopti-hotstrings.desktop');
		const nativeManifest = path.join(nativeLibrary, '.ergopti-owned-files');
		const nativeEnv = {
			HOME: home,
			XDG_CONFIG_HOME: nativeConfig,
			PATH: `${stubs}:/usr/bin:/bin`
		};
		fs.mkdirSync(path.join(nativeDriver, 'install'), { recursive: true });
		fs.mkdirSync(path.join(nativeShared, 'data/locales'), { recursive: true });
		fs.writeFileSync(path.join(nativeDriver, 'ergopti_hotstrings.lua'), 'native-runtime');
		fs.writeFileSync(path.join(nativeShared, 'data/locales/en.json'), '{}');
		for (const helper of [
			'ownership.sh',
			'start_at_login.sh',
			'desktop_entry.sh',
			'config_home.sh'
		]) {
			fs.copyFileSync(
				path.join(path.dirname(script), 'install', helper),
				path.join(nativeDriver, 'install', helper)
			);
		}
		fs.mkdirSync(nativeLibrary, { recursive: true });
		fs.cpSync(nativeDriver, path.join(nativeLibrary, 'linux'), { recursive: true });
		fs.cpSync(nativeShared, path.join(nativeLibrary, '_shared'), { recursive: true });
		fs.mkdirSync(path.dirname(nativeWrapper), { recursive: true });
		const quoteRoot = spawnSync(
			bashExecutable(),
			['-c', 'printf "%q" "$1"', 'native-owner', nativeLibrary],
			{ encoding: 'utf8' }
		);
		assert.equal(quoteRoot.status, 0, quoteRoot.stderr);
		fs.writeFileSync(
			nativeWrapper,
			`#!/bin/bash\nINSTALL_ROOT=${quoteRoot.stdout}\nexec bash "\${INSTALL_ROOT}/bin/ergopti-hotstrings" "$@"\n`
		);
		fs.mkdirSync(path.join(nativeLibrary, 'bin'), { recursive: true });
		fs.writeFileSync(path.join(nativeLibrary, 'bin/ergopti-hotstrings'), '#!/bin/bash\nexit 0\n');
		const nativeFailures = [];
		const recorded = spawnSync(
			bashExecutable(),
			[path.join(nativeDriver, 'install/ownership.sh'), nativeDriver, nativeShared, nativeLibrary],
			{ encoding: 'utf8', env: nativeEnv, timeout: 15000 }
		);
		if (recorded.status !== 0) nativeFailures.push(`payload receipt: ${recorded.stderr.trim()}`);
		if (recorded.status === 0) {
			const invalidSource = path.join(nativeRoot, 'invalid\nsource');
			fs.cpSync(nativeDriver, invalidSource, { recursive: true });
			const badChecksumBin = path.join(nativeRoot, 'bad-checksum-bin');
			fs.mkdirSync(badChecksumBin);
			fs.writeFileSync(
				path.join(badChecksumBin, 'sha256sum'),
				`#!/bin/bash\nprintf '%s\\n' "$ERGOPTI_TEST_CHECKSUM_RECEIPT"\n`,
				{ mode: 0o755 }
			);
			const previousReceipt = fs.readFileSync(nativeManifest);
			for (const checksum of ['', 'invalid-checksum', 'f'.repeat(63)]) {
				const refused = spawnSync(
					bashExecutable(),
					[
						path.join(nativeDriver, 'install/ownership.sh'),
						invalidSource,
						nativeShared,
						nativeLibrary
					],
					{
						encoding: 'utf8',
						timeout: 15000,
						env: {
							...nativeEnv,
							PATH: `${badChecksumBin}:${nativeEnv.PATH}`,
							ERGOPTI_TEST_CHECKSUM_RECEIPT: checksum
						}
					}
				);
				assert.notEqual(refused.status, 0, 'invalid checksum receipts must refuse publication');
				assert.match(
					refused.stderr,
					/^\[ownership\] code=invalid_checksum path=/,
					'the preboot failure is a structured developer diagnostic'
				);
				assert.equal(
					refused.stderr.split('\n').length,
					2,
					'native source path newlines cannot forge additional diagnostic records'
				);
				assert.deepEqual(
					fs.readFileSync(nativeManifest),
					previousReceipt,
					'checksum refusal preserves the previous ownership publication'
				);
			}
		}

		// Independently author the receipt so a failed producer cannot hide the
		// consumer's native-path bug, then verify every actual producer below.
		let authored = '';
		function receiptFiles(directory, prefix) {
			for (const name of fs.readdirSync(directory)) {
				const file = path.join(directory, name);
				if (fs.statSync(file).isDirectory()) receiptFiles(file, `${prefix}${name}/`);
				else
					authored += `${createHash('sha256').update(fs.readFileSync(file)).digest('hex')}\t${prefix}${name}\n`;
			}
		}
		receiptFiles(nativeDriver, 'linux/');
		receiptFiles(nativeShared, '_shared/');
		for (const [file, relative] of [
			[nativeWrapper, '@wrapper'],
			[path.join(nativeLibrary, 'bin/ergopti-hotstrings'), 'bin/ergopti-hotstrings']
		]) {
			authored += `${createHash('sha256').update(fs.readFileSync(file)).digest('hex')}\t${relative}\n`;
		}
		if (recorded.status === 0) {
			const expectedPayload = authored
				.split('\n')
				.filter((row) => row && !row.endsWith('\t@wrapper'))
				.sort();
			assert.deepEqual(
				fs.readFileSync(nativeManifest, 'utf8').trim().split('\n').sort(),
				expectedPayload,
				'payload producer records exact relative names and independent content digests'
			);
		}
		fs.writeFileSync(nativeManifest, authored);
		const startup = spawnSync(
			bashExecutable(),
			[path.join(nativeLibrary, 'linux/install/start_at_login.sh'), 'enable'],
			{ encoding: 'utf8', env: nativeEnv, timeout: 15000 }
		);
		if (startup.status !== 0) nativeFailures.push(`startup publication: ${startup.stderr.trim()}`);
		const startupDigest = createHash('sha256').update(fs.readFileSync(nativeDesktop)).digest('hex');
		if (
			!fs.readFileSync(nativeManifest, 'utf8').split('\n').includes(`${startupDigest}\t@autostart`)
		) {
			nativeFailures.push('startup receipt has an escaped digest');
		}
		// Feed an independently valid startup receipt to the remover too.
		fs.writeFileSync(nativeManifest, authored + `${startupDigest}\t@autostart\n`);
		const nativeRemoved = spawnSync(bashExecutable(), [script, '--prefix', nativePrefix, '--yes'], {
			encoding: 'utf8',
			env: nativeEnv,
			timeout: 15000
		});
		if (nativeRemoved.status !== 0)
			nativeFailures.push(`uninstall: ${nativeRemoved.stderr.trim()}`);
		if (
			fs.existsSync(nativeWrapper) ||
			fs.existsSync(nativeDesktop) ||
			fs.existsSync(path.join(nativeLibrary, 'linux/ergopti_hotstrings.lua'))
		) {
			nativeFailures.push('uninstall retained unchanged owned files');
		}
		assert.deepEqual(
			nativeFailures,
			[],
			'native-receipt-path: producers and remover preserve absolute path bytes'
		);
	}
	// A verified Arch package owns the same flat layout as DEB/RPM. Querying
	// ownership is read-only; only the isolated privilege port records removal.
	fs.writeFileSync(path.join(bare, 'dpkg-query'), '#!/bin/bash\nexit 1\n', { mode: 0o755 });
	fs.writeFileSync(
		path.join(bare, 'pacman'),
		[
			'#!/bin/bash',
			'flags="${1#-}"',
			'[ "$#" -eq 3 ] && [ "${#flags}" -eq 3 ] && [[ "$flags" != *[^Qoq]* ]] || exit 64',
			'[[ "$flags" == *Q* && "$flags" == *o* && "$flags" == *q* ]] || exit 64',
			'[ "$2" = -- ] && [ "$3" = "$ERGOPTI_TEST_PACKAGE_FILE" ] || exit 64',
			'printf "%s\n" "$ERGOPTI_TEST_PACKAGE_OWNER"',
			'exit "$ERGOPTI_TEST_QUERY_STATUS"',
			''
		].join('\n'),
		{ mode: 0o755 }
	);
	fs.writeFileSync(
		path.join(bare, 'pkexec'),
		[
			'#!/bin/bash',
			'printf "%s\n" "$@" > "$ERGOPTI_TEST_PACKAGE_LOG"',
			'exit "$ERGOPTI_TEST_PACKAGE_STATUS"',
			''
		].join('\n'),
		{ mode: 0o755 }
	);
	const ownerProbe = spawnSync(
		bashExecutable(),
		[path.join(bare, 'pacman'), '-Qoq', '--', path.join(packaged, 'uninstall.sh')],
		{
			encoding: 'utf8',
			env: {
				ERGOPTI_TEST_PACKAGE_OWNER: nativePackageOwner,
				ERGOPTI_TEST_QUERY_STATUS: nativeQueryStatus,
				ERGOPTI_TEST_PACKAGE_FILE: path.join(packaged, 'uninstall.sh')
			}
		}
	);
	assert.equal(
		ownerProbe.status,
		0,
		'the independent owner port must accept the actual query protocol'
	);
	assert.equal(ownerProbe.stdout, 'ergopti\n');
	const archPreflight = packagedRun('--check');
	assert.equal(archPreflight.status, 0, `verified-pacman-owner: ${archPreflight.stderr}`);
	assert.ok(!fs.existsSync(nativeActionLog), 'owner preflight never acquires removal authority');
	const nativeStartup = path.join(home, '.config/autostart/ergopti.desktop');
	fs.mkdirSync(path.dirname(nativeStartup), { recursive: true });
	const ownedStartup =
		'[Desktop Entry]\nExec=/bin/bash "/usr/bin/ergopti" --session-start --tray\n';
	fs.writeFileSync(nativeStartup, ownedStartup);
	nativeQueryStatus = '23';
	assert.notEqual(
		packagedRun('--yes').status,
		0,
		'a failed query cannot claim ownership through partial stdout'
	);
	assert.ok(!fs.existsSync(nativeActionLog), 'unacknowledged query output cannot reach pkexec');
	nativeQueryStatus = '0';

	nativePackageOwner = 'another-package';
	assert.notEqual(packagedRun('--yes').status, 0, 'foreign package ownership blocks removal');
	assert.ok(!fs.existsSync(nativeActionLog), 'a foreign owner cannot reach pkexec');
	assert.equal(
		fs.readFileSync(nativeStartup, 'utf8'),
		ownedStartup,
		'foreign package ownership preserves startup'
	);
	nativePackageOwner = 'ergopti';
	nativeActionStatus = '75';
	assert.equal(packagedRun('--yes').status, 75, 'package-manager failure is preserved');
	assert.equal(
		fs.readFileSync(nativeStartup, 'utf8'),
		ownedStartup,
		'refused removal preserves startup'
	);
	assert.deepEqual(
		fs.readFileSync(nativeActionLog, 'utf8').trimEnd().split('\n'),
		['/usr/bin/pacman', '-R', '--noconfirm', 'ergopti'],
		'only the verified package is delegated to its manager'
	);
	nativeActionStatus = '0';
	assert.equal(packagedRun('--yes').status, 0, 'the verified Arch owner can finish removal');
	assert.ok(
		!fs.existsSync(nativeStartup),
		'confirmed package removal retires its own user startup entry'
	);
	fs.writeFileSync(nativeStartup, '[Desktop Entry]\nExec=/other/application\n');
	assert.equal(packagedRun('--yes').status, 0);
	assert.equal(
		fs.readFileSync(nativeStartup, 'utf8'),
		'[Desktop Entry]\nExec=/other/application\n',
		'package removal preserves a foreign user startup command'
	);
	assert.ok(
		fs.existsSync(path.join(packaged, 'uninstall.sh')),
		'the helper never deletes package files itself'
	);
	console.log('[OK] Linux uninstaller removes only the validated standalone installation.');
} finally {
	fs.rmSync(sandbox, { recursive: true, force: true });
}
