// tools/test/test-linux-arch-package.cjs

/**
 * MODULE: Arch Package Runtime Staging Regression
 * Executes the actual recipe and native bundle builder in a private pkgdir.
 * Installed entry points then run with relocated filesystem roots and recorded
 * system-command boundaries; no package-manager transaction or root is used.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const recipe = path.join(ROOT, 'tools/build/PKGBUILD');
const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-arch-package-'));
const failures = [];
function check(name, callback) {
	try {
		callback();
		console.log(`PASS ${name}`);
	} catch (error) {
		failures.push(name);
		console.error(`FAIL ${name}: ${error.message}`);
	}
}
try {
	assert.equal(process.platform, 'linux', 'Arch native package staging requires Linux');
	const srcdir = path.join(scratch, 'src');
	const pkgdir = path.join(scratch, 'pkg');
	const stubs = path.join(scratch, 'stubs');
	const calls = path.join(scratch, 'calls');
	for (const directory of [srcdir, pkgdir, stubs]) fs.mkdirSync(directory);
	fs.symlinkSync(ROOT, path.join(srcdir, 'ergopti'), 'dir');
	const staged = spawnSync(bashExecutable(), ['-s', '--', recipe, srcdir, pkgdir, scratch], {
		input:
			'set -euo pipefail\nsource "$1"\nsrcdir="$2"\npkgdir="$3"\n' +
			'printf "%s\\0" "${depends[@]}" > "$4/dependencies"\n' +
			'printf "%s" "${install:-}" > "$4/hook-name"\npackage\n',
		encoding: 'utf8',
		timeout: 120000
	});
	assert.equal(staged.status, 0, staged.stderr || staged.stdout || staged.error?.message);
	const library = path.join(pkgdir, 'usr/lib/ergopti');
	const native = fs.readFileSync(path.join(library, 'bin/libergopti_archive_publication.so'));
	assert.deepEqual(
		native.subarray(0, 4),
		Buffer.from([127, 69, 76, 70]),
		'actual native backend must ship'
	);
	const record = 'printf "%s %s\\n" "${0##*/}" "$*" >> "$ARCH_CALLS"';
	const stub = (name, body) =>
		fs.writeFileSync(path.join(stubs, name), `#!/bin/bash\n${record}\n${body}\n`, { mode: 0o755 });
	stub('systemctl', 'exit 0');
	stub('pkexec', 'exit 126');
	stub('id', 'if [ "$1" = -u ]; then echo 1000; else echo "users input uinput"; fi');
	const interpreter = spawnSync(bashExecutable(), ['-c', 'command -v luajit'], {
		encoding: 'utf8'
	});
	assert.equal(interpreter.status, 0, interpreter.stderr);
	const realLua = interpreter.stdout.trim();
	assert.ok(path.isAbsolute(realLua), 'a real LuaJIT interpreter must be available');
	stub(
		'luajit',
		'if [ -n "${ARCH_PACKAGE_PROBE:-}" ]; then exec "$ARCH_REAL_LUA" -e "$ARCH_PACKAGE_PROBE"; fi\nexec "$ARCH_REAL_LUA" "$@"'
	);
	const wrapper = path.join(scratch, 'installed-ergopti');
	fs.writeFileSync(
		wrapper,
		fs
			.readFileSync(path.join(pkgdir, 'usr/bin/ergopti'), 'utf8')
			.replaceAll('/usr/lib/ergopti', library)
	);
	const env = {
		...process.env,
		PATH: `${stubs}:${process.env.PATH}`,
		ARCH_CALLS: calls,
		ARCH_REAL_LUA: realLua
	};
	const launch = (...args) => {
		fs.writeFileSync(calls, '');
		return spawnSync(bashExecutable(), [wrapper, ...args], {
			env,
			encoding: 'utf8',
			timeout: 15000
		});
	};
	check('arch-desktop-entry-reaches-the-session-owner', () => {
		const desktop = fs.readFileSync(
			path.join(pkgdir, 'usr/share/applications/ergopti.desktop'),
			'utf8'
		);
		const command = desktop.match(/^Exec=(.+)$/m);
		assert.ok(command, 'staged desktop must name its executable');
		const result = launch(...command[1].trim().split(/\s+/).slice(1), '--help');
		assert.equal(result.status, 0, result.stderr);
		const invoked = fs.readFileSync(calls, 'utf8');
		assert.match(invoked, /systemctl --user start ergopti-hotstrings.service/);
		assert.doesNotMatch(invoked, /luajit|pkexec/);
	});
	check('arch-unit-permission-refusal-prevents-daemon-start', () => {
		stub('id', 'if [ "$1" = -u ]; then echo 1000; else echo users; fi');
		const unit = fs.readFileSync(
			path.join(pkgdir, 'usr/lib/systemd/user/ergopti-hotstrings.service'),
			'utf8'
		);
		const command = unit.match(/^ExecStart=(.+)$/m);
		assert.ok(command, 'staged unit must have an executable command');
		const result = launch(...command[1].trim().split(/\s+/).slice(1), '--help');
		assert.equal(result.status, 78, result.stderr);
		const invoked = fs.readFileSync(calls, 'utf8');
		assert.match(invoked, /pkexec .*setup_permissions.sh --user 1000/);
		assert.doesNotMatch(invoked, /systemctl|luajit/);
		assert.match(unit, /^RestartPreventExitStatus=78$/m);
	});
	check('arch-service-acquires-stale-groups-before-starting-the-daemon', () => {
		stub(
			'id',
			'if [ "$1" = -u ]; then echo 1000; elif [ "$#" = 2 ]; then echo "users input uinput"; else echo "users ${ARCH_ACQUIRED_GROUPS:-}"; fi'
		);
		stub(
			'sg',
			'export ARCH_ACQUIRED_GROUPS="${ARCH_ACQUIRED_GROUPS:-} $1"\nexec /bin/bash -c "$3"'
		);
		const result = launch('--service', '--tray', '--help');
		assert.equal(result.status, 0, result.stderr);
		const invoked = fs.readFileSync(calls, 'utf8');
		assert.equal(
			(invoked.match(/^sg /gm) || []).length,
			2,
			'both stale group credentials must be acquired'
		);
		assert.match(invoked, /^luajit .*ergopti_hotstrings\.lua --tray --help$/m);
		assert.doesNotMatch(invoked, /pkexec|systemctl/);
	});
	check('arch-staged-bootstrap-and-data-readers-use-the-packaged-shared-tree', () => {
		const booted = launch('--help');
		assert.equal(booted.status, 0, booted.stderr);
		assert.match(booted.stdout, /--config/, 'the actual packaged entry point must print its help');
		const head = spawnSync('git', ['-C', ROOT, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
		assert.equal(head.status, 0, head.stderr);
		const shared = path.join(library, '_shared');
		const probe = [
			'local Paths = require("infra.paths")',
			'local Fs = require("adapters.file_system")',
			'local Snapshot = require("diagnostics.snapshot")',
			'assert(Paths.driver_root() == os.getenv("ARCH_LIBRARY_ROOT"), "staged driver root")',
			'assert(Paths.shared_root() == os.getenv("ARCH_SHARED_ROOT"), "staged shared root")',
			'local commit, origin = Snapshot.resolve_commit(Fs, Paths.shared_root(), Paths.driver_root())',
			'assert(origin == Snapshot.COMMIT_SOURCE_BUILD and #commit > 0, "staged build identity")',
			'assert(os.getenv("ARCH_EXPECTED_COMMIT"):sub(1, #commit) == commit, "actual source commit")',
			'for _, rel in ipairs({ "data/locales/en.json", "data/db/schema.sql", "assets/ergopti_tray.png", "core/config_schema/migrations.toml", "ui/apps.manifest.json" }) do',
			' local bytes = Fs.read(Paths.shared(rel)); assert(type(bytes) == "string" and #bytes > 0, "staged resource: " .. rel)',
			'end',
			'local defaults = assert(require("json").decode(Fs.read(Paths.shared("modules/updater/defaults.json"))))',
			'local factory, refusal = require("infra.archive_output").native_artifact(defaults.release_assets.linux_bundle)',
			'assert(type(factory) == "table", "staged native backend: " .. tostring(refusal and refusal.capability_reason))',
			'print("ARCH_STAGED_ROOTS_OK")'
		].join('\n');
		const probeEnv = {
			...env,
			ARCH_PACKAGE_PROBE: probe,
			ARCH_LIBRARY_ROOT: library,
			ARCH_SHARED_ROOT: shared,
			ARCH_EXPECTED_COMMIT: head.stdout.trim()
		};
		const readData = () =>
			spawnSync(bashExecutable(), [wrapper, '--help'], {
				env: probeEnv,
				encoding: 'utf8',
				timeout: 15000
			});
		const resolved = readData();
		assert.equal(resolved.status, 0, resolved.stderr);
		assert.match(resolved.stdout, /^ARCH_STAGED_ROOTS_OK$/m);
		const sentinel = path.join(shared, 'data/locales/en.json');
		const hidden = `${sentinel}.private-test`;
		fs.renameSync(sentinel, hidden);
		try {
			const broken = readData();
			assert.equal(
				broken.status,
				1,
				'a damaged staged tree must not borrow source checkout resources'
			);
			assert.match(broken.stderr, /staged shared root/);
		} finally {
			fs.renameSync(hidden, sentinel);
		}
		const backend = path.join(library, 'bin/libergopti_archive_publication.so');
		const hiddenBackend = `${backend}.private-test`;
		fs.renameSync(backend, hiddenBackend);
		try {
			const broken = readData();
			assert.equal(
				broken.status,
				1,
				'native admission must not borrow a backend from the source checkout'
			);
			assert.match(broken.stderr, /staged native backend: native_archive_component_unavailable/);
		} finally {
			fs.renameSync(hiddenBackend, backend);
		}
	});
	check('arch-package-installs-owned-input-rules', () => {
		for (const [source, destination] of [
			['99-ergopti-uinput.rules', 'etc/udev/rules.d/99-ergopti-uinput.rules'],
			['ergopti-uinput.conf', 'etc/modules-load.d/ergopti-uinput.conf']
		]) {
			assert.deepEqual(
				fs.readFileSync(path.join(pkgdir, destination)),
				fs.readFileSync(path.join(library, 'install', source))
			);
		}
	});
	check('arch-package-hooks-enroll-and-retire-through-the-canonical-owners', () => {
		const hookName = fs.readFileSync(path.join(scratch, 'hook-name'), 'utf8');
		assert.notEqual(hookName, '', 'the recipe must declare a pacman lifecycle hook');
		const hook = fs.readFileSync(path.join(path.dirname(recipe), hookName), 'utf8');
		const relocatedHook = path.join(scratch, 'package.install');
		fs.writeFileSync(relocatedHook, hook.replaceAll('/usr/lib/ergopti', library));
		// Only the privileged filesystem boundary is relocated. The shipped
		// setup function, session selection and account validation execute intact.
		const setup = path.join(library, 'install/setup_permissions.sh');
		fs.writeFileSync(setup, fs.readFileSync(setup, 'utf8').replaceAll('/etc/', `${pkgdir}/etc/`));
		stub('id', 'echo 0');
		stub(
			'getent',
			'if [ "$1" = passwd ]; then echo "desktop:x:1000:1000::/home/desktop:/bin/bash"; else exit 2; fi'
		);
		stub(
			'loginctl',
			'if [ "$1" = list-sessions ]; then echo "1 1000 desktop seat0 tty2"; else printf "Type=wayland\\nRemote=no\\nClass=user\\nActive=yes\\nUser=1000\\n"; fi'
		);
		for (const name of ['groupadd', 'usermod', 'modprobe', 'udevadm']) stub(name, 'exit 0');
		const runHook = (action) => {
			fs.writeFileSync(calls, '');
			return spawnSync(
				bashExecutable(),
				['-c', 'set -euo pipefail; source "$1"; "$2"', 'arch-hook', relocatedHook, action],
				{ env, encoding: 'utf8', timeout: 15000 }
			);
		};
		for (const action of ['post_install', 'post_upgrade']) {
			const result = runHook(action);
			assert.equal(result.status, 0, `${action}: ${result.stderr}`);
			const invoked = fs.readFileSync(calls, 'utf8');
			assert.match(invoked, /usermod -aG input,uinput desktop/);
			assert.match(invoked, /modprobe uinput/);
		}
		stub('usermod', 'exit 73');
		const refused = runHook('post_upgrade');
		assert.equal(refused.status, 73, 'a failed account mutation must remain a package failure');
		assert.doesNotMatch(
			fs.readFileSync(calls, 'utf8'),
			/modprobe|udevadm/,
			'a refused hook must stop before later privileged work'
		);

		const runtimeRoot = path.join(scratch, 'run/user');
		for (const uid of ['1000', '1001']) {
			fs.mkdirSync(path.join(runtimeRoot, uid), { recursive: true });
			fs.writeFileSync(path.join(runtimeRoot, uid, 'bus'), 'private bus-presence fixture');
		}
		const stop = path.join(library, 'install/stop_sessions.sh');
		// A regular fixture records socket presence; no real session bus or
		// account switch is permitted in this unprivileged package test.
		fs.writeFileSync(
			stop,
			fs
				.readFileSync(stop, 'utf8')
				.replaceAll('/run/user/', `${runtimeRoot}/`)
				.replaceAll('[ -S ', '[ -f ')
		);
		stub('getent', 'echo "desktop$2:x:$2:$2::/home/desktop$2:/bin/bash"');
		stub(
			'runuser',
			'export ARCH_SESSION_USER="$2"\nwhile [ "$1" != systemctl ]; do shift; done\nexec "$@"'
		);
		stub(
			'systemctl',
			'printf "session %s %s\\n" "$ARCH_SESSION_USER" "$*" >> "$ARCH_CALLS"\nif [ "$2" = show ]; then\nif [ "$ARCH_SESSION_USER" = desktop1000 ]; then echo /usr/lib/systemd/user/ergopti-hotstrings.service; else echo /home/desktop1001/.config/systemd/user/ergopti-hotstrings.service; fi\nfi'
		);
		const removed = runHook('pre_remove');
		assert.equal(removed.status, 0, removed.stderr);
		const removedCalls = fs.readFileSync(calls, 'utf8');
		assert.match(
			removedCalls,
			/^session desktop1000 --user disable --now ergopti-hotstrings.service$/m
		);
		assert.doesNotMatch(
			removedCalls,
			/^session desktop1001 .*disable/m,
			'a user-owned service override must survive removal'
		);
		assert.doesNotMatch(
			removedCalls,
			/usermod|modprobe|pkexec/,
			'removal must never grant keyboard access'
		);
	});
	check('arch-native-entrypoint-programs-have-runtime-packages', () => {
		const dependencies = fs.readFileSync(path.join(scratch, 'dependencies'), 'utf8').split('\0');
		for (const name of [
			'polkit',
			'kmod',
			'systemd',
			'shadow',
			'util-linux',
			'glibc',
			'libayatana-appindicator',
			'zenity',
			'lua51-lgi',
			'webkit2gtk-4.1',
			'python'
		]) {
			assert.ok(dependencies.includes(name), `missing runtime package: ${name}`);
		}
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
assert.equal(failures.length, 0, `Arch runtime staging failures: ${failures.join(', ')}`);
console.log('Arch native recipe staging and runtime entry contracts passed.');
