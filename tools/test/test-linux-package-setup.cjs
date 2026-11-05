// tools/test/test-linux-package-setup.cjs

/**
 * ==============================================================================
 * MODULE: Linux Package Permission Setup Regression
 * DESCRIPTION:
 * Executes the privileged setup helper with isolated filesystem roots and
 * stubbed system commands. Only local graphical users may receive input access.
 * ==============================================================================
 */

'use strict';

const assert = require('assert/strict');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const { bashExecutable, bashPath } = require('../lib/git-bash.cjs');
const { provideShellMessages } = require('./lib/shell-messages-fixture.cjs');

const ROOT = path.resolve(__dirname, '../..');
const sourcePath = path.join(ROOT, 'static/ergopti_plus/linux/install/setup_permissions.sh');
assert.ok(fs.existsSync(sourcePath), 'native packages need an automatic permission setup owner');
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-package-setup-'));
const shellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
try {
	// Debian calls postinst for rollback and triggers as well as configuration.
	{
		const builder = fs.readFileSync(path.join(ROOT, 'tools/build/build-linux-deb.sh'), 'utf8');
		const match =
			/cat > "\$DEB_ROOT\/DEBIAN\/postinst" << 'POSTINST_EOF'\n([\s\S]*?)\nPOSTINST_EOF/.exec(
				builder
			);
		assert.ok(match, 'actual Debian postinst');
		const stubSetup = path.join(sandbox, 'postinst-setup.sh');
		const hook = path.join(sandbox, 'postinst');
		const calls = path.join(sandbox, 'postinst-calls');
		fs.writeFileSync(stubSetup, '#!/bin/bash\nprintf "%s\\n" "$*" >> "$CALL_LOG"\n');
		fs.writeFileSync(
			hook,
			match[1].replace('/usr/lib/ergopti/install/setup_permissions.sh', bashPath(stubSetup))
		);
		for (const action of [
			'configure',
			'abort-upgrade',
			'abort-remove',
			'abort-deconfigure',
			'triggered'
		]) {
			fs.writeFileSync(calls, '');
			const result = spawnSync(bashExecutable(), [bashPath(hook), action], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, CALL_LOG: calls }
			});
			assert.equal(result.status, 0, result.stderr);
			assert.equal(
				fs.readFileSync(calls, 'utf8'),
				action === 'configure' ? '--active-sessions\n' : '',
				action
			);
		}
	}
	// A checkout name is data, even when it contains JavaScript quotes.
	{
		const checkout = path.join(sandbox, "checkout's directory\n");
		const driver = path.join(checkout, 'static/ergopti_plus/linux');
		fs.mkdirSync(driver, { recursive: true });
		fs.writeFileSync(path.join(checkout, 'package.json'), '{"version":"7.8.9"}');
		const installer = fs.readFileSync(
			path.join(ROOT, 'static/ergopti_plus/linux/install.sh'),
			'utf8'
		);
		const assignment = installer.match(/ERGOPTI_VERSION="\$\([\s\S]*?\n\)"/);
		assert.ok(assignment, 'actual installer version assignment');
		const result = spawnSync(
			bashExecutable(),
			[
				'-c',
				`SCRIPT_DIR="$1"\n${assignment[0]}\nprintf '%s' "$ERGOPTI_VERSION"`,
				'version-test',
				bashPath(driver)
			],
			{ encoding: 'utf8', timeout: 10000 }
		);
		assert.equal(result.status, 0, result.stderr);
		assert.equal(result.stdout, '7.8.9');
	}
	// A release archive's install.sh sits directly at the extraction root,
	// whose name may end in a newline. Its help path must find the bundle.
	{
		const bundle = path.join(sandbox, 'extracted-bundle\n');
		const script = path.join(bundle, 'install.sh');
		const installDirectory = path.join(bundle, 'linux/install');
		provideShellMessages(installDirectory);
		fs.mkdirSync(path.join(bundle, '_shared/data'), { recursive: true });
		fs.copyFileSync(path.join(ROOT, 'static/ergopti_plus/linux/install.sh'), script);
		fs.copyFileSync(
			path.join(ROOT, 'static/ergopti_plus/_shared/data/identifiers.sh'),
			path.join(bundle, '_shared/data/identifiers.sh')
		);
		for (const [args, cwd] of [
			[[bashPath(script), '--help'], sandbox],
			[['install.sh', '--help'], bundle]
		]) {
			const result = spawnSync(bashExecutable(), args, { cwd, encoding: 'utf8', timeout: 10000 });
			assert.equal(result.status, 0, `bundle help: ${result.stderr}`);
			assert.match(result.stdout, /--no-service/);
		}
	}
	// A missing prefix value must not consume a later flag and create its name
	// as a directory (or silently re-enable the service/dependency setup).
	{
		const cwd = path.join(sandbox, 'missing-prefix-option');
		fs.mkdirSync(cwd);
		for (const name of ['install.sh', 'uninstall.sh']) {
			const installer = path.join(ROOT, 'static/ergopti_plus/linux', name);
			for (const flag of [
				'',
				'--no-service',
				'--no-deps',
				'--setup-perms',
				'--prefix',
				'--help',
				'-h',
				'--unknown',
				'--yes',
				'--check'
			]) {
				const result = spawnSync(bashExecutable(), [bashPath(installer), '--prefix', flag], {
					cwd,
					encoding: 'utf8',
					timeout: 10000,
					env: {
						...process.env,
						HOME: bashPath(sandbox),
						XDG_CONFIG_HOME: bashPath(path.join(sandbox, 'missing-config')),
						LC_ALL: 'C'
					}
				});
				assert.equal(result.status, 64, `missing prefix before ${flag}: ${result.stderr}`);
				assert.match(result.stderr, /Missing --prefix value/);
				assert.deepEqual(fs.readdirSync(cwd), [], 'argument refusal must not create a prefix');
				assert.equal(fs.existsSync(path.join(sandbox, 'missing-config')), false);
			}
		}
	}
	// Paths whose basename starts with '-' remain expressible with ./ or an
	// absolute path. Stop the installer at the existing UID admission boundary.
	{
		const cwd = path.join(sandbox, 'dash-prefix-paths');
		const bin = path.join(cwd, 'bin');
		fs.mkdirSync(bin, { recursive: true });
		fs.writeFileSync(path.join(bin, 'id'), '#!/bin/bash\necho 999\n', { mode: 0o755 });
		for (const name of ['install.sh', 'uninstall.sh']) {
			for (const prefix of ['./--name', path.join(cwd, '--name')]) {
				const mode = name === 'install.sh' ? '--no-deps' : '--check';
				const result = spawnSync(
					bashExecutable(),
					[bashPath(path.join(ROOT, 'static/ergopti_plus/linux', name)), '--prefix', prefix, mode],
					{
						cwd,
						encoding: 'utf8',
						timeout: 10000,
						env: {
							...process.env,
							PATH: `${bin}:/usr/bin:/bin`,
							HOME: bashPath(sandbox),
							LC_ALL: 'C'
						}
					}
				);
				assert.notEqual(result.status, 64, result.stderr);
				assert.equal(fs.existsSync(path.join(cwd, '--name')), false);
			}
		}
	}
	// Explicit invalid owner tokens must not be treated as “no owner”, which
	// would bypass waiting for the daemon; GUI arguments are all required.
	{
		const script = path.join(ROOT, 'static/ergopti_plus/linux/uninstall.sh');
		const cases = [
			['--wait-owner'],
			['--wait-owner', ''],
			['--wait-owner', '--yes'],
			['--wait-owner', 'abc'],
			['--gui'],
			['--gui', 'Title', 'Error'],
			['--gui', '', 'Error', 'Missing'],
			['--gui', 'Title', '', 'Missing'],
			['--gui', 'Title', 'Error', ''],
			['--gui', '--yes', 'Error', 'Missing'],
			['--gui', 'Title', '--check', 'Missing'],
			['--gui', 'Title', 'Error', '--prefix'],
			['--unknown']
		];
		for (const args of cases) {
			const result = spawnSync(bashExecutable(), [bashPath(script), ...args], {
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, HOME: bashPath(sandbox), LC_ALL: 'C' }
			});
			assert.equal(
				result.status,
				64,
				`invalid uninstall args ${JSON.stringify(args)}: ${result.stderr}`
			);
		}
		const setup = spawnSync(
			bashExecutable(),
			[
				bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install.sh')),
				'--setup-perms',
				'--prefix',
				''
			],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, HOME: bashPath(sandbox), LC_ALL: 'C' }
			}
		);
		assert.equal(setup.status, 64, 'empty prefix cannot fall through to permission setup');
	}
	// Receipt publication must never report success by moving into a directory,
	// nor replace an administrator's linked receipt.
	{
		const owner = path.join(ROOT, 'static/ergopti_plus/linux/install/ownership.sh');
		const installer = path.join(ROOT, 'static/ergopti_plus/linux/install.sh');
		const fixture = path.join(sandbox, 'receipt-type');
		const driver = path.join(fixture, 'driver');
		const shared = path.join(fixture, 'shared');
		fs.mkdirSync(driver, { recursive: true });
		fs.mkdirSync(path.join(shared, 'data/locales'), { recursive: true });
		fs.writeFileSync(path.join(driver, 'ergopti_hotstrings.lua'), 'runtime');
		fs.writeFileSync(path.join(shared, 'data/locales/en.json'), '{}');
		const regular = path.join(fixture, 'regular');
		fs.mkdirSync(regular);
		fs.writeFileSync(path.join(regular, '.ergopti-owned-files'), 'old receipt\n');
		const replaced = spawnSync(
			bashExecutable(),
			[bashPath(owner), bashPath(driver), bashPath(shared), bashPath(regular)],
			{ encoding: 'utf8', timeout: 10000 }
		);
		assert.equal(replaced.status, 0, replaced.stderr);
		assert.match(
			fs.readFileSync(path.join(regular, '.ergopti-owned-files'), 'utf8'),
			/\tlinux\/ergopti_hotstrings\.lua/
		);
		// A directory arriving after admission must not turn mv into a move
		// inside that directory, nor create a misleading successful receipt.
		const raced = path.join(fixture, 'raced');
		const raceBin = path.join(fixture, 'race-bin');
		fs.mkdirSync(raced);
		fs.mkdirSync(raceBin);
		fs.writeFileSync(
			path.join(raceBin, 'mv'),
			'#!/bin/bash\nmkdir -p -- "${!#}"\nprintf preserve > "${!#}/personal"\nexec /usr/bin/mv "$@"\n',
			{ mode: 0o755 }
		);
		const changed = spawnSync(
			bashExecutable(),
			[bashPath(owner), bashPath(driver), bashPath(shared), bashPath(raced)],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, PATH: `${raceBin}:/usr/bin:/bin` }
			}
		);
		assert.notEqual(changed.status, 0);
		assert.deepEqual(fs.readdirSync(path.join(raced, '.ergopti-owned-files')), ['personal']);
		assert.equal(
			fs.readFileSync(path.join(raced, '.ergopti-owned-files/personal'), 'utf8'),
			'preserve'
		);
		for (const kind of ['directory', 'symlink']) {
			const prefix = path.join(fixture, kind);
			const library = path.join(prefix, 'lib/ergopti');
			const receipt = path.join(library, '.ergopti-owned-files');
			const foreign = path.join(fixture, `${kind}-foreign`);
			fs.mkdirSync(library, { recursive: true });
			fs.mkdirSync(foreign);
			fs.writeFileSync(path.join(foreign, 'personal'), 'preserve');
			if (kind === 'directory') {
				fs.mkdirSync(receipt);
				fs.writeFileSync(path.join(receipt, 'personal'), 'preserve');
			} else fs.symlinkSync(foreign, receipt);
			const owned = spawnSync(
				bashExecutable(),
				[bashPath(owner), bashPath(driver), bashPath(shared), bashPath(library)],
				{
					encoding: 'utf8',
					timeout: 10000
				}
			);
			assert.notEqual(owned.status, 0, `owner refuses ${kind}`);
			assert.match(owned.stderr, /code=invalid_destination/);
			assert.deepEqual(fs.readdirSync(receipt), ['personal']);
			assert.equal(fs.readFileSync(path.join(foreign, 'personal'), 'utf8'), 'preserve');
			const installed = spawnSync(
				bashExecutable(),
				[bashPath(installer), '--prefix', bashPath(prefix), '--no-deps'],
				{
					encoding: 'utf8',
					timeout: 10000,
					env: {
						...process.env,
						HOME: bashPath(sandbox),
						XDG_CONFIG_HOME: bashPath(path.join(fixture, 'config')),
						LC_ALL: 'C'
					}
				}
			);
			assert.notEqual(installed.status, 0, `installer refuses ${kind}`);
			assert.match(installed.stderr, /code=invalid-receipt/);
			assert.equal(
				fs.existsSync(path.join(library, 'linux')),
				false,
				'receipt refused before payload copy'
			);
			assert.equal(
				fs.existsSync(path.join(fixture, 'config')),
				false,
				'receipt refused before config creation'
			);
			assert.deepEqual(fs.readdirSync(receipt), ['personal']);
		}
	}
	// A root shell need not have sudo installed: execute the detected package
	// manager directly, while retaining its actual failure as a failure.
	{
		const tools = path.join(sandbox, 'root-package-tools');
		const receipt = path.join(sandbox, 'root-package-receipt');
		const shellEnv = path.join(sandbox, 'root-package-env');
		fs.mkdirSync(tools);
		fs.writeFileSync(
			path.join(tools, 'id'),
			'#!/bin/bash\n[ "$1" = -u ] && echo "${TEST_UID:-0}"\n',
			{ mode: 0o755 }
		);
		fs.writeFileSync(
			path.join(tools, 'apt-get'),
			`#!/bin/bash\nprintf 'apt-get\\n' > ${shellQuote(receipt)}\nexit 42\n`,
			{ mode: 0o755 }
		);
		fs.writeFileSync(
			path.join(tools, 'sudo'),
			`#!/bin/bash\nprintf 'sudo\\n' > ${shellQuote(receipt)}\nexit 42\n`,
			{ mode: 0o755 }
		);
		fs.writeFileSync(
			shellEnv,
			'command() { if [ "$1" = -v ] && [ "$2" = luajit ]; then return 1; fi; builtin command "$@"; }\n'
		);
		const result = spawnSync(
			'/bin/bash',
			[
				bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install.sh')),
				'--prefix',
				bashPath(path.join(sandbox, 'root-prefix')),
				'--no-service'
			],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: {
					...process.env,
					HOME: sandbox,
					SUDO_UID: '1001',
					PATH: `${tools}:/usr/bin:/bin`,
					BASH_ENV: shellEnv
				}
			}
		);
		assert.equal(result.status, 42, result.stderr);
		assert.equal(fs.readFileSync(receipt, 'utf8'), 'apt-get\n');
		const unprivileged = spawnSync(
			'/bin/bash',
			[
				bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install.sh')),
				'--prefix',
				bashPath(path.join(sandbox, 'user-prefix')),
				'--no-service'
			],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: {
					...process.env,
					HOME: sandbox,
					TEST_UID: '1001',
					PATH: `${tools}:/usr/bin:/bin`,
					BASH_ENV: shellEnv
				}
			}
		);
		assert.equal(unprivileged.status, 42, unprivileged.stderr);
		assert.equal(fs.readFileSync(receipt, 'utf8'), 'sudo\n');
	}
	// An unprivileged invocation must enroll its own UID, even when it inherited
	// SUDO_UID from an earlier `sudo -u` context.
	{
		const tools = path.join(sandbox, 'installer-identity-tools');
		const receipt = path.join(sandbox, 'installer-identity-receipt');
		fs.mkdirSync(tools);
		fs.writeFileSync(
			path.join(tools, 'id'),
			'#!/bin/bash\n[ "$1" = -u ] && echo "${TEST_UID:-1001}"\n',
			{ mode: 0o755 }
		);
		fs.writeFileSync(
			path.join(tools, 'sudo'),
			`#!/bin/bash\nprintf '%s\\n' "$*" > ${shellQuote(receipt)}\n`,
			{ mode: 0o755 }
		);
		const setup = spawnSync(
			bashExecutable(),
			[bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install.sh')), '--setup-perms'],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: { ...process.env, HOME: sandbox, SUDO_UID: '1234', PATH: `${tools}:/usr/bin:/bin` }
			}
		);
		assert.equal(setup.status, 0, setup.stderr);
		assert.match(fs.readFileSync(receipt, 'utf8'), /--user 1001\n$/);
		const noHome = {
			...process.env,
			SUDO_UID: '1234',
			TMPDIR: sandbox,
			PATH: `${tools}:/usr/bin:/bin`
		};
		delete noHome.HOME;
		for (const args of [['--help'], ['--setup-perms']]) {
			const minimal = spawnSync(
				bashExecutable(),
				[bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install.sh')), ...args],
				{ encoding: 'utf8', timeout: 10000, env: noHome }
			);
			assert.equal(minimal.status, 0, `${args}: ${minimal.stderr}`);
		}
		const noPrefix = spawnSync(
			bashExecutable(),
			[bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install.sh'))],
			{ encoding: 'utf8', timeout: 10000, env: noHome }
		);
		assert.equal(noPrefix.status, 64, 'a normal install without HOME needs an explicit prefix');
		fs.writeFileSync(
			path.join(tools, 'bash'),
			`#!/bin/bash\nprintf '%s\\n' "$*" > ${shellQuote(receipt)}\n`,
			{ mode: 0o755 }
		);
		const elevated = spawnSync(
			'/bin/bash',
			[bashPath(path.join(ROOT, 'static/ergopti_plus/linux/install.sh')), '--setup-perms'],
			{
				encoding: 'utf8',
				timeout: 10000,
				env: {
					...process.env,
					HOME: sandbox,
					SUDO_UID: '1234',
					TEST_UID: '0',
					PATH: `${tools}:/usr/bin:/bin`
				}
			}
		);
		assert.equal(elevated.status, 0, elevated.stderr);
		assert.match(
			fs.readFileSync(receipt, 'utf8'),
			/--user 1234\n$/,
			'root retains the sudo caller'
		);
	}
	const stubs = path.join(sandbox, 'stubs');
	const callLog = path.join(sandbox, 'calls');
	fs.mkdirSync(stubs);
	const stub = (name, body) =>
		fs.writeFileSync(path.join(stubs, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
	stub('id', 'if [ "$1" = -u ]; then echo 0; else exit 1; fi');
	stub(
		'getent',
		'if [ "$1" = passwd ]; then echo "desktop:x:1000:1000::/home/desktop:/bin/bash"; [ "${AMBIGUOUS_PASSWD:-0}" = 1 ] && echo "other:x:1000:1000::/home/other:/bin/bash"; true; elif [ "$2" = "${FAIL_GROUP:-}" ]; then exit "${FAIL_STATUS:-1}"; else exit 2; fi'
	);
	stub(
		'loginctl',
		`case "$1" in
list-sessions) printf '1 1000 desktop seat0 tty2\n2 1001 remote - -\n3 1002 console seat0 tty3\n4 120 gdm seat0 tty1\n5 1003 inactive seat0 tty4\n6 1004 gone seat0 tty5\n7 999 kiosk seat0 tty6\n8 - incomplete seat0 tty7\n' ;;
show-session) case "$2" in
1) printf 'Type=wayland\nRemote=no\nUser=1000\nClass=user\nActive=yes\n' ;;
2) printf 'Type=x11\nRemote=yes\nUser=1001\nClass=user\nActive=yes\n' ;;
3) printf 'Type=tty\nRemote=no\nUser=1002\nClass=user\nActive=yes\n' ;;
4) printf 'Type=wayland\nRemote=no\nUser=120\nClass=greeter\nActive=yes\n' ;;
5) printf 'Type=x11\nRemote=no\nUser=1003\nClass=user\nActive=no\n' ;;
6) exit 1 ;;
7) printf 'Type=x11\nRemote=no\nUser=999\nClass=user\nActive=yes\n' ;;
8) printf 'Type=wayland\nRemote=no\nUser=\nClass=user\nActive=yes\n' ;;
*) exit 1 ;; esac ;; esac`
	);
	for (const name of ['groupadd', 'usermod', 'modprobe', 'udevadm']) {
		stub(name, 'printf "%s %s\\n" "${0##*/}" "$*" >> "$CALL_LOG"');
	}
	// The script reads its rules and its message catalogue beside it, as in the driver tree.
	const installDirectory = path.join(sandbox, 'install');
	provideShellMessages(installDirectory);
	const script = path.join(installDirectory, 'setup.sh');
	for (const name of ['99-ergopti-uinput.rules', 'ergopti-uinput.conf']) {
		fs.copyFileSync(path.join(path.dirname(sourcePath), name), path.join(installDirectory, name));
	}
	fs.writeFileSync(
		script,
		fs
			.readFileSync(sourcePath, 'utf8')
			.replaceAll('/etc/', `${shellQuote(bashPath(sandbox))}/etc/`)
			.replace('[ -S /run/udev/control ]', 'true')
			.replace('set -euo pipefail', 'set -euo pipefail\nexport PATH="$TEST_STUBS:/usr/bin:/bin"')
	);
	const ambiguous = spawnSync(bashExecutable(), [bashPath(script), '--user', '1000'], {
		encoding: 'utf8',
		timeout: 15000,
		env: {
			HOME: bashPath(sandbox),
			TEST_STUBS: bashPath(stubs),
			CALL_LOG: bashPath(callLog),
			AMBIGUOUS_PASSWD: '1'
		}
	});
	assert.notEqual(ambiguous.status, 0, 'ambiguous NSS identity must be refused');
	assert.equal(fs.existsSync(callLog), false, 'no privileged mutation before identity admission');
	for (const [group, status] of ['input', 'uinput'].flatMap((name) => [
		[name, 1],
		[name, 3]
	])) {
		const failed = spawnSync(bashExecutable(), [bashPath(script), '--user', '1000'], {
			encoding: 'utf8',
			timeout: 15000,
			env: {
				HOME: bashPath(sandbox),
				PATH: `${bashPath(stubs)}:/usr/bin:/bin`,
				TEST_STUBS: bashPath(stubs),
				CALL_LOG: bashPath(callLog),
				FAIL_GROUP: group,
				FAIL_STATUS: String(status)
			}
		});
		assert.equal(failed.status, status, `failed ${group} lookup must preserve its status`);
		assert.match(failed.stderr, /code=group-lookup-failed/);
		assert.equal(
			fs.existsSync(callLog),
			false,
			'no group or device mutation before complete lookup'
		);
		assert.equal(fs.existsSync(path.join(sandbox, 'etc')), false);
	}
	const result = spawnSync(bashExecutable(), [bashPath(script), '--active-sessions'], {
		encoding: 'utf8',
		timeout: 15000,
		env: {
			HOME: bashPath(sandbox),
			PATH: `${bashPath(stubs)}:/usr/bin:/bin`,
			TEST_STUBS: bashPath(stubs),
			CALL_LOG: bashPath(callLog)
		}
	});
	assert.equal(result.status, 0, result.stderr || result.error?.message);
	assert.match(
		result.stderr,
		/Session 6 could not be inspected/,
		'a logout race is reported and deferred'
	);
	assert.match(result.stderr, /Session 8 could not be inspected/, 'incomplete session is deferred');
	assert.match(result.stderr, /Refusing a non-desktop account/, 'system account remains excluded');
	const nonDesktop = spawnSync(bashExecutable(), [bashPath(script), '--user', '999'], {
		encoding: 'utf8',
		timeout: 10000,
		env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) }
	});
	assert.notEqual(nonDesktop.status, 0, 'explicit non-desktop requests remain refused');

	const calls = fs.readFileSync(callLog, 'utf8');
	assert.match(calls, /usermod -aG input,uinput desktop/);
	assert.equal(
		(calls.match(/usermod /g) || []).length,
		1,
		'only one local graphical account is enrolled'
	);
	assert.doesNotMatch(calls, /usermod.*(?:remote|console)/);
	assert.match(
		fs.readFileSync(path.join(sandbox, 'etc/udev/rules.d/99-ergopti-uinput.rules'), 'utf8'),
		/static_node=uinput/
	);
	assert.match(
		fs.readFileSync(path.join(sandbox, 'etc/modules-load.d/ergopti-uinput.conf'), 'utf8'),
		/^uinput$/m
	);
	assert.match(calls, /modprobe uinput/);
	assert.match(calls, /udevadm control --reload-rules/);
	// Reject each unusable link without replacing it or mutating groups/devices.
	for (const relative of [
		'etc/udev/rules.d/99-ergopti-uinput.rules',
		'etc/modules-load.d/ergopti-uinput.conf'
	]) {
		const config = path.join(sandbox, relative);
		const original = fs.readFileSync(config);
		fs.unlinkSync(config);
		fs.symlinkSync(path.join(sandbox, 'missing-target'), config);
		fs.writeFileSync(callLog, '');
		const dangling = spawnSync(bashExecutable(), [bashPath(script), '--user', '1000'], {
			encoding: 'utf8',
			timeout: 15000,
			env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) }
		});
		assert.equal(dangling.status, 78, dangling.stderr);
		assert.match(dangling.stderr, /code=dangling-configuration/);
		assert.ok(fs.lstatSync(config).isSymbolicLink(), 'preserve dangling configuration link');
		assert.equal(fs.readFileSync(callLog, 'utf8'), '', 'do not mutate groups or devices');
		fs.unlinkSync(config);
		fs.writeFileSync(config, original);
	}
	// A directory cannot provide rules or module configuration either.
	for (const relative of [
		'etc/udev/rules.d/99-ergopti-uinput.rules',
		'etc/modules-load.d/ergopti-uinput.conf'
	]) {
		const config = path.join(sandbox, relative);
		const original = fs.readFileSync(config);
		fs.unlinkSync(config);
		fs.mkdirSync(config);
		fs.writeFileSync(callLog, '');
		const refused = spawnSync(bashExecutable(), [bashPath(script), '--user', '1000'], {
			encoding: 'utf8',
			timeout: 15000,
			env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) }
		});
		assert.equal(refused.status, 78, 'directory cannot supply required configuration');
		assert.match(refused.stderr, /code=invalid-configuration/);
		assert.ok(fs.statSync(config).isDirectory());
		assert.equal(fs.readFileSync(callLog, 'utf8'), '', 'no privileged mutation on refusal');
		fs.rmdirSync(config);
		fs.symlinkSync('/dev/null', config);
		const masked = spawnSync(bashExecutable(), [bashPath(script), '--user', '1000'], {
			encoding: 'utf8',
			timeout: 15000,
			env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) }
		});
		assert.equal(masked.status, 0, 'administrator mask stays supported');
		assert.ok(fs.lstatSync(config).isSymbolicLink());
		fs.unlinkSync(config);
		fs.writeFileSync(config, original);
	}
	// Exercise the actual BusyBox branch with only command availability
	// replaced. Group mutations still go through the recorded stubs.
	stub('addgroup', 'printf "addgroup %s\\n" "$*" >> "$CALL_LOG"');
	fs.writeFileSync(
		script,
		fs
			.readFileSync(script, 'utf8')
			.replaceAll('command -v usermod >/dev/null 2>&1', 'false')
			.replaceAll('command -v groupadd >/dev/null 2>&1', 'false')
	);
	fs.writeFileSync(callLog, '');
	const busybox = spawnSync(bashExecutable(), [bashPath(script), '--user', '1000'], {
		encoding: 'utf8',
		timeout: 15000,
		env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) }
	});
	assert.equal(busybox.status, 0, busybox.stderr || busybox.error?.message);
	const busyboxCalls = fs.readFileSync(callLog, 'utf8');
	for (const group of ['input', 'uinput']) {
		assert.match(busyboxCalls, new RegExp(`^addgroup -S ${group}$`, 'm'));
		assert.match(busyboxCalls, new RegExp(`^addgroup desktop ${group}$`, 'm'));
	}
	assert.doesNotMatch(busyboxCalls, /usermod|groupadd/);
	const launcher = path.join(sandbox, 'installed/install/launch.sh');
	provideShellMessages(path.dirname(launcher));
	fs.writeFileSync(
		launcher,
		fs
			.readFileSync(path.join(ROOT, 'static/ergopti_plus/linux/install/launch.sh'), 'utf8')
			.replace('set -euo pipefail', 'set -euo pipefail\nexport PATH="$TEST_PATH"')
	);
	const logCall = 'printf "%s %s\\n" "${0##*/}" "$*" >> "$CALL_LOG"';
	stub(
		'id',
		`if [ "$1" = -u ]; then echo 1000
elif [ "$TEST_CASE" = cancel ] || [[ "$TEST_CASE" = help-no-groups-* ]]; then echo users
elif [ "$TEST_CASE" = stale ] && [ "$#" = 1 ]; then echo "users \${ACQUIRED_GROUPS:-}"
else echo "users input uinput"; fi`
	);
	stub('systemctl', logCall + '\n[[ "$TEST_CASE" = help-no-bus-* ]] && exit 1\nexit 0');
	stub('luajit', logCall + '\nexit 0');
	stub('pkexec', logCall + '\nexit 126');
	stub(
		'sg',
		logCall + '\nexport ACQUIRED_GROUPS="${ACQUIRED_GROUPS:-} $1"\nexec /bin/bash -c "$3"'
	);
	stub(
		'flock',
		logCall +
			'\n[ "$*" = "-n 9" ] || { echo "unsupported flock arguments" >&2; exit 64; }\n' +
			'case "$TEST_CASE" in busy|direct-busy) exit 1;; esac\n' +
			'if [ "$TEST_CASE" = lock-error ]; then echo "flock: Bad file descriptor" >&2; exit 1; fi'
	);
	if (process.platform === 'win32') {
		// NTFS does not implement the POSIX directory mode. Linux runs the real
		// install command; this seam changes only its filesystem mode operation.
		stub('install', '[[ "$1 $2 $3" = "-d -m 700" ]] || exit 64\nmkdir -p -- "$4"');
	}
	const noSystemdStubs = path.join(sandbox, 'no-systemd-stubs');
	fs.cpSync(stubs, noSystemdStubs, { recursive: true });
	fs.rmSync(path.join(noSystemdStubs, 'systemctl'));
	fs.writeFileSync(
		path.join(noSystemdStubs, 'dirname'),
		'#!/bin/bash\nexec /usr/bin/dirname "$@"\n',
		{
			mode: 0o755
		}
	);
	for (const [scenario, args, status, expected, forbidden] of [
		[
			'desktop',
			['--tray'],
			0,
			/systemctl --user start ergopti-hotstrings.service/,
			/luajit|pkexec|enable/
		],
		...[
			['tray-version', ['--tray', '--version'], /luajit .* --tray --version$/m],
			['tray-unknown', ['--tray', '--unknown'], /luajit .* --tray --unknown$/m],
			[
				'tray-config',
				['--tray', '--config', '/tmp/custom profile'],
				/luajit .* --tray --config \/tmp\/custom profile$/m
			],
			['tray-verbose', ['--tray', '--verbose'], /luajit .* --tray --verbose$/m],
			['tray-dry-run', ['--tray', '--dry-run'], /luajit .* --tray --dry-run$/m],
			['tray-missing-value', ['--tray', '--config'], /luajit .* --tray --config$/m],
			['tray-two-flags', ['--tray', '--tray'], /luajit .* --tray --tray$/m],
			['tray-help-args', ['--tray', '--help'], /luajit .* --tray --help$/m]
		].map(([scenario, args, expected]) => [scenario, args, 0, expected, /systemctl/]),
		[
			'service',
			['--service', '--tray'],
			0,
			/luajit .*ergopti_hotstrings.lua --tray/,
			/systemctl|pkexec/
		],
		['cancel', ['--service', '--tray'], 78, /pkexec .*setup_permissions.sh --user 1000/, /luajit/],
		['busy', ['--service', '--tray'], 0, /flock /, /luajit|pkexec/],
		['lock-error', ['--service', '--tray'], 1, /flock /, /luajit|pkexec/],
		['help', ['--help'], 0, /luajit .* --help/, /flock|pkexec|systemctl/],
		['help-short', ['--verbose', '-h'], 0, /luajit .* --verbose -h/, /flock|pkexec|systemctl/],
		// Help is interpreted by the daemon before every option, including tray
		// and service options. No combination may start a unit or ask for access.
		...['--help', '-h'].flatMap((help) =>
			['available', 'no-bus', 'no-systemd', 'no-groups'].flatMap((environment) =>
				[
					['tray-before', ['--tray', help]],
					['tray-after', [help, '--tray']],
					['session-start', ['--session-start', help]],
					['service', ['--service', '--tray', help]],
					['refreshed-tray', ['--groups-refreshed', '--tray', help]],
					['refreshed-service', ['--groups-refreshed', '--service', '--tray', help]]
				].map(([name, args]) => [
					`help-${environment}-${name}-${help}`,
					args,
					0,
					new RegExp(`luajit .* ${help}(?: |$)`, 'm'),
					/flock|pkexec|systemctl|sg /
				])
			)
		),
		// A terminal launch is a daemon too: it takes the same instance lock.
		[
			'direct',
			['--verbose'],
			0,
			/^flock -n 9\nluajit .*ergopti_hotstrings\.lua --verbose$/m,
			/pkexec|systemctl/
		],
		['direct-busy', ['--verbose'], 75, /flock /, /luajit|pkexec|systemctl/],
		[
			'stale',
			['--service', '--tray', "an argument's value"],
			0,
			/luajit .* --tray an argument's value/,
			/pkexec|systemctl/
		]
	]) {
		fs.writeFileSync(callLog, '');
		const launched = spawnSync(bashExecutable(), [bashPath(launcher), ...args], {
			encoding: 'utf8',
			timeout: 15000,
			env: {
				HOME: bashPath(sandbox),
				TEST_PATH: scenario.startsWith('help-no-systemd-')
					? bashPath(noSystemdStubs)
					: `${bashPath(stubs)}:/usr/bin:/bin`,
				CALL_LOG: bashPath(callLog),
				TEST_CASE: scenario
			}
		});
		assert.equal(launched.status, status, `${scenario}: ${launched.stderr}`);
		const invoked = fs.readFileSync(callLog, 'utf8');
		assert.match(invoked, expected, scenario);
		assert.doesNotMatch(invoked, forbidden, scenario);
		if (scenario === 'busy' || scenario === 'direct-busy') {
			assert.match(
				launched.stderr,
				/Ergopti\+ is already running in this session \(.*ergopti\.lock is held\); this launch was refused\./,
				`${scenario}: a refused launch must say why`
			);
		}
		if (scenario === 'lock-error') {
			assert.match(
				launched.stderr,
				/flock: Bad file descriptor/,
				'a native lock error must remain visible instead of being treated as contention'
			);
		}
		if (scenario === 'stale') {
			assert.equal((invoked.match(/^sg /gm) || []).length, 2, 'both stale groups are acquired');
			assert.equal(
				(invoked.match(/^flock /gm) || []).length,
				1,
				'credentials refresh precedes the single instance lock'
			);
		}
	}
	const stopScript = path.join(sandbox, 'install', 'stop-sessions.sh');
	const runtimeRoot = path.join(sandbox, 'run/user');
	for (const uid of ['1000', '1001']) {
		fs.mkdirSync(path.join(runtimeRoot, uid), { recursive: true });
		fs.writeFileSync(path.join(runtimeRoot, uid, 'bus'), 'isolated bus presence');
	}
	fs.writeFileSync(
		stopScript,
		fs
			.readFileSync(path.join(ROOT, 'static/ergopti_plus/linux/install/stop_sessions.sh'), 'utf8')
			.replaceAll('/run/user/', `${shellQuote(bashPath(runtimeRoot))}/`)
			.replaceAll('[ -S ', '[ -f ')
			.replace('set -euo pipefail', 'set -euo pipefail\nexport PATH="$TEST_STUBS:/usr/bin:/bin"')
	);
	stub('id', 'echo 0');
	stub('getent', 'echo "user$2:x:$2:$2::/home/user$2:/bin/bash"');
	stub(
		'runuser',
		'export SESSION_ACCOUNT="$2"\nwhile [ "$1" != systemctl ]; do shift; done\nexec "$@"'
	);
	stub(
		'systemctl',
		`printf '%s %s\\n' "$SESSION_ACCOUNT" "$*" >> "$CALL_LOG"
if [ "$2" = show ]; then
if [ "$SESSION_ACCOUNT" = user1000 ]; then echo /usr/lib/systemd/user/ergopti-hotstrings.service
else echo /home/user1001/.config/systemd/user/ergopti-hotstrings.service; fi
fi`
	);
	fs.writeFileSync(callLog, '');
	const stopped = spawnSync(bashExecutable(), [bashPath(stopScript)], {
		encoding: 'utf8',
		timeout: 15000,
		env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) }
	});
	assert.equal(stopped.status, 0, stopped.stderr || stopped.error?.message);
	const stopCalls = fs.readFileSync(callLog, 'utf8');
	assert.match(stopCalls, /^user1000 --user disable --now ergopti-hotstrings.service$/m);
	assert.doesNotMatch(
		stopCalls,
		/^user1001 .*disable/m,
		'package removal preserves a user-owned service override'
	);
	// NSS may return an inconsistent identity; do not act as another account.
	for (const entry of [
		'other:x:1001:1001::/home/other:/bin/bash',
		'user1000:x:1000:1000::/home/user1000:/bin/bash\nother:x:1001:1001::/home/other:/bin/bash'
	]) {
		stub('getent', `printf '%s\\n' ${shellQuote(entry)}`);
		fs.writeFileSync(callLog, '');
		const mismatch = spawnSync(bashExecutable(), [bashPath(stopScript)], {
			encoding: 'utf8',
			timeout: 15000,
			env: { HOME: bashPath(sandbox), TEST_STUBS: bashPath(stubs), CALL_LOG: bashPath(callLog) }
		});
		assert.notEqual(mismatch.status, 0, 'inconsistent NSS identity must fail');
		assert.equal(fs.readFileSync(callLog, 'utf8'), '', 'no session is touched');
	}
	// The Fedora job is a nonlogin container: HOME is supplied, while USER and
	// LOGNAME need the real account query before privacy admission in --help.
	const pipeline = require('./ci-pipeline.cjs');
	const workflow = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-linux.yml'), 'utf8');
	const installJob = pipeline
		.jobsOfText(workflow, '.github/workflows/ci-linux.yml')
		.filter((job) => job.id === 'install-linux');
	assert.equal(installJob.length, 1);
	const rpmStep = pipeline.step(installJob[0].body, 'Launch the installed binary (rpm)');
	const rpmSource = pipeline.runOf(rpmStep).join('\n');
	assert.equal(rpmSource.split('/usr/bin/ergopti --help').length, 2);
	const installed = path.join(sandbox, 'record-installed');
	const identityReceipt = path.join(sandbox, 'identity-receipt');
	fs.writeFileSync(
		installed,
		'#!/bin/bash\n' +
			'printf "%s\\n" "$HOME" "${USER-}" "${LOGNAME-}" "$#" "$*" > "$IDENTITY_RECEIPT"\n' +
			'[[ "${USER-}|${LOGNAME-}|$#|$*" = "fixture-account|fixture-account|1|--help" ]] || exit 78\n',
		{ mode: 0o755 }
	);
	stub(
		'id',
		'[[ "$*" = "-un" ]] || exit 64\n' +
			'case "$TEST_CASE" in identity-failed) exit 73 ;; identity-empty) exit 0 ;; *) printf "fixture-account\\n" ;; esac'
	);
	const rpmProgram = path.join(sandbox, 'rpm-launch.sh');
	fs.writeFileSync(
		rpmProgram,
		'unset USER LOGNAME\nexport PATH="$TEST_STUBS:/usr/bin:/bin"\n' +
			rpmSource.replace('/usr/bin/ergopti --help', '"$RPM_INSTALLED" --help')
	);
	for (const scenario of ['identity-present', 'identity-empty', 'identity-failed']) {
		if (fs.existsSync(identityReceipt)) fs.unlinkSync(identityReceipt);
		const result = spawnSync(bashExecutable(), [bashPath(rpmProgram)], {
			encoding: 'utf8',
			timeout: 15000,
			env: {
				HOME: bashPath(sandbox),
				TEST_STUBS: bashPath(stubs),
				RPM_INSTALLED: bashPath(installed),
				IDENTITY_RECEIPT: bashPath(identityReceipt),
				TEST_CASE: scenario
			}
		});
		assert.equal(result.error, undefined);
		if (scenario === 'identity-present') {
			assert.equal(result.status, 0, result.stderr);
			assert.deepEqual(fs.readFileSync(identityReceipt, 'utf8').trimEnd().split('\n'), [
				bashPath(sandbox),
				'fixture-account',
				'fixture-account',
				'1',
				'--help'
			]);
		} else {
			assert.notEqual(
				result.status,
				0,
				'Failed or empty identity cannot start the installed command.'
			);
			assert.equal(
				fs.existsSync(identityReceipt),
				false,
				'No launch occurs after account refusal.'
			);
		}
	}
	// A host without getent: the helpers refuse with EX_UNAVAILABLE and a
	// machine-readable `missing-program getent` line, never in silence, and the
	// launcher hands the program's name to the daemon, which localizes it.
	const bare = path.join(sandbox, 'bare');
	fs.mkdirSync(bare);
	for (const name of ['dirname', 'install', 'flock', 'cat']) {
		fs.symlinkSync(
			['/usr/bin', '/bin'].map((d) => path.join(d, name)).find(fs.existsSync),
			path.join(bare, name)
		);
	}
	const bareStub = (name, body) =>
		fs.writeFileSync(path.join(bare, name), `#!/bin/bash\n${body}\n`, { mode: 0o755 });
	bareStub('id', 'case "$1" in -u) echo 0 ;; -nG) echo users ;; *) exit 1 ;; esac');
	const linuxRoot = path.join(ROOT, 'static/ergopti_plus/linux');
	const bareEnv = {
		HOME: bashPath(sandbox),
		PATH: bashPath(bare),
		XDG_RUNTIME_DIR: bashPath(sandbox)
	};
	const withoutGetent = (relative, ...args) =>
		spawnSync(bashExecutable(), [bashPath(path.join(linuxRoot, relative)), ...args], {
			encoding: 'utf8',
			timeout: 15000,
			env: bareEnv
		});
	for (const [relative, args] of [
		['install/setup_permissions.sh', ['--active-sessions']],
		['install/stop_sessions.sh', []]
	]) {
		const refused = withoutGetent(relative, ...args);
		assert.equal(refused.status, 69, `${relative} must refuse without getent`);
		assert.equal(
			refused.stderr.trim(),
			'missing-program getent',
			`${relative} must name the missing program, not exit 69 in silence`
		);
	}
	const daemonReceipt = path.join(sandbox, 'daemon-receipt');
	bareStub(
		'luajit',
		`printf '%s\\n' "\${ERGOPTI_MISSING_PROGRAM-unset}" > "${bashPath(daemonReceipt)}"`
	);
	bareStub('systemctl', 'exit 1');
	bareStub('pkexec', 'exec "$@"');
	const launched = withoutGetent('install/launch.sh', '--tray');
	assert.equal(launched.status, 0, launched.stderr);
	assert.equal(
		fs.readFileSync(daemonReceipt, 'utf8').trim(),
		'getent',
		'the launcher passes the missing program to the daemon that tells the user'
	);
	assert.match(launched.stderr, /missing-program getent/);
	fs.unlinkSync(daemonReceipt);
	fs.unlinkSync(path.join(bare, 'pkexec'));
	const noPkexec = withoutGetent('install/launch.sh', '--tray');
	assert.equal(noPkexec.status, 0, noPkexec.stderr);
	assert.equal(fs.readFileSync(daemonReceipt, 'utf8').trim(), 'pkexec');
	assert.match(noPkexec.stderr, /missing-program pkexec/);
	fs.unlinkSync(daemonReceipt);
	bareStub('pkexec', 'exit 126');
	const cancelled = withoutGetent('install/launch.sh', '--tray');
	assert.equal(cancelled.status, 78, 'a cancelled authorization still stops the launch');
	assert.equal(fs.existsSync(daemonReceipt), false);
	console.log('[OK] Package setup provisions input access only for local graphical users.');
} finally {
	fs.rmSync(sandbox, { recursive: true, force: true });
}
