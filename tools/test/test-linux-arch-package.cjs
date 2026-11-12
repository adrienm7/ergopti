// tools/test/test-linux-arch-package.cjs

/**
 * MODULE: Arch Package Runtime Staging Regression
 * The recipe repacks the release tarball. The test assembles that tarball's
 * tree from the real driver builder (linux/, _shared/, bin/, install.sh) plus
 * a private runtime prefix that stands in for the one the oldest-LTS container
 * stages, with the real network-runtime-env.sh, then executes the actual
 * package() into a private pkgdir. Installed entry points run with relocated
 * filesystem roots and recorded system-command boundaries; no package-manager
 * transaction or root is used.
 */
'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '../..');
const shellQuote = (value) => "'" + value.replaceAll("'", "'\\''") + "'";
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
	// Arch accepts literal POSIX backslashes; every staged helper must keep them.
	const pkgdir = path.join(scratch, 'pkg\\native');
	const stubs = path.join(scratch, 'stubs');
	const calls = path.join(scratch, 'calls');
	for (const directory of [srcdir, pkgdir, stubs]) fs.mkdirSync(directory);
	// The release tarball's tree: the real driver bundle the CI tarball step packs.
	const build = path.join(scratch, 'build');
	const assembled = spawnSync(
		bashExecutable(),
		[path.join(ROOT, 'tools/build/build-linux-driver.sh'), '--skip-smoke'],
		{
			cwd: ROOT,
			env: { ...process.env, ERGOPTI_LINUX_BUILD_DIR: build },
			encoding: 'utf8',
			timeout: 300000
		}
	);
	assert.equal(
		assembled.status,
		0,
		assembled.stderr || assembled.stdout || assembled.error?.message
	);
	const interpreter = spawnSync(bashExecutable(), ['-c', 'command -v luajit'], {
		encoding: 'utf8'
	});
	assert.equal(interpreter.status, 0, interpreter.stderr);
	const realLua = interpreter.stdout.trim();
	assert.ok(path.isAbsolute(realLua), 'a real LuaJIT interpreter must be available');
	// The private runtime prefix the tarball carries in linux/runtime, standing
	// in for the oldest-LTS staging: its LuaJIT is the recorded interpreter
	// boundary, its Lua C modules are this host's own, and the parts only the
	// environment checks for exist. The environment is the real shared template.
	const prefix = path.join(build, 'linux/runtime');
	const record = 'printf "%s %s\\n" "${0##*/}" "$*" >> "$ARCH_CALLS"';
	const writeExecutable = (file, body) => {
		fs.mkdirSync(path.dirname(file), { recursive: true });
		fs.writeFileSync(file, `#!/bin/bash\n${body}\n`, { mode: 0o755 });
	};
	writeExecutable(
		path.join(prefix, 'bin/luajit'),
		`${record}\nif [ -n "\${ARCH_PACKAGE_PROBE:-}" ]; then exec "$ARCH_REAL_LUA" -e "$ARCH_PACKAGE_PROBE"; fi\nexec "$ARCH_REAL_LUA" "$@"`
	);
	for (const program of ['curl', 'sqlite3', 'openssl', 'zstd'])
		writeExecutable(path.join(prefix, 'bin', program), `${record}\nexit 0`);
	const hostModule = (name, field) =>
		spawnSync(
			realLua,
			['-e', `io.write(package.searchpath(${JSON.stringify(name)}, package.${field}) or "")`],
			{
				encoding: 'utf8'
			}
		).stdout;
	for (const [name, field, relative] of [
		['luv', 'cpath', 'lib/lua/5.1/luv.so'],
		['lfs', 'cpath', 'lib/lua/5.1/lfs.so'],
		['posix.sys.stat', 'cpath', 'lib/lua/5.1/posix/sys/stat.so'],
		['posix', 'path', 'share/lua/5.1/posix/init.lua']
	]) {
		const target = path.join(prefix, relative);
		fs.mkdirSync(path.dirname(target), { recursive: true });
		const found = hostModule(name, field);
		if (found) fs.copyFileSync(found, target);
		else fs.writeFileSync(target, '');
	}
	for (const relative of [
		'lib/gio/modules/libgiolibproxy.so',
		'share/glib-2.0/schemas/gschemas.compiled'
	]) {
		fs.mkdirSync(path.dirname(path.join(prefix, relative)), { recursive: true });
		fs.writeFileSync(path.join(prefix, relative), '');
	}
	fs.copyFileSync(
		path.join(ROOT, 'tools/build/templates/linux-portable-runtime-env.sh'),
		path.join(build, 'linux/network-runtime-env.sh')
	);
	const staged = spawnSync(bashExecutable(), ['-s', '--', recipe, srcdir, pkgdir, scratch], {
		env: { ...process.env, ERGOPTI_ARCH_BUNDLE_DIR: build },
		input:
			'set -euo pipefail\nsource "$1"\nsrcdir="$2"\npkgdir="$3"\n' +
			'printf "%s\\0" "${depends[@]}" > "$4/dependencies"\n' +
			'printf "%s" "${install:-}" > "$4/hook-name"\n' +
			'printf "%s\\0" "${arch[@]}" > "$4/architectures"\n' +
			'printf "%s\\0" "${source[@]}" > "$4/sources"\npackage\n',
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
	check('arch-package-architecture-is-the-private-runtime-architecture', () => {
		// The release tarball's private runtime and native backend are x86_64 ELF,
		// staged in the oldest-LTS container: the recipe declares exactly that.
		const declared = fs
			.readFileSync(path.join(scratch, 'architectures'), 'utf8')
			.split('\0')
			.filter(Boolean);
		assert.deepEqual(declared, ['x86_64']);
		assert.ok(native[5] === 1 || native[5] === 2, 'native ELF must name its byte order');
	});
	check('arch-package-repacks-the-release-tarball', () => {
		const sources = fs
			.readFileSync(path.join(scratch, 'sources'), 'utf8')
			.split('\0')
			.filter(Boolean);
		assert.equal(sources.length, 1, 'the recipe has one source: the release tarball');
		assert.match(
			sources[0],
			/^ergopti-plus-linux-__PKGVER__\.tar\.gz::https:\/\/github\.com\/adrienm7\/ergopti\/releases\/download\/__TAG__\/ergopti-plus-linux\.tar\.gz$/
		);
		for (const relative of ['runtime/bin/luajit', 'network-runtime-env.sh'])
			assert.ok(fs.existsSync(path.join(library, relative)), `the package must ship ${relative}`);
		assert.equal(fs.existsSync(path.join(library, 'tests')), false, 'tests are not installed');
	});
	check('arch-recipe-renders-from-the-tarball-identity', () => {
		const renderer = require('../build/render-arch-pkgbuild.cjs');
		const template = fs.readFileSync(recipe, 'utf8');
		const rendered = renderer.render(template, { version: '1.2.3', sha256: 'a'.repeat(64) });
		assert.match(rendered, /^pkgver=1\.2\.3$/m);
		assert.match(rendered, /\/releases\/download\/v1\.2\.3\/ergopti-plus-linux\.tar\.gz"\)$/m);
		assert.match(rendered, new RegExp(`^sha256sums=\\('${'a'.repeat(64)}'\\)$`, 'm'));
		assert.match(
			renderer.render(template, { version: '0.0.0-dev.7', sha256: 'b'.repeat(64) }),
			/^pkgver=0\.0\.0dev\.7$/m,
			'a prerelease sorts before its stable core in pacman and keeps no hyphen'
		);
		assert.throws(() => renderer.render(template, { version: 'nightly', sha256: 'a'.repeat(64) }));
		assert.throws(() => renderer.render(template, { version: '1.2.3', sha256: 'SKIP' }));
	});
	check('arch-desktop-icon-ships-the-real-canonical-png-at-its-native-size', () => {
		const themes = path.join(pkgdir, 'usr/share/icons/hicolor');
		const icons = fs
			.readdirSync(themes)
			.map((size) => path.join(themes, size, 'apps/ergopti.png'))
			.filter((file) => fs.existsSync(file));
		assert.equal(icons.length, 1, 'the package must supply exactly one desktop icon');
		const actual = fs.readFileSync(icons[0]);
		assert.ok(actual.length > 0, 'the desktop icon must not be an empty placeholder');
		const expected = fs.readFileSync(path.join(library, '_shared/tray/data/ergopti_tray.png'));
		assert.deepEqual(actual, expected, 'desktop and tray must use the canonical logo bytes');
		const width = expected.readUInt32BE(16),
			height = expected.readUInt32BE(20);
		assert.equal(
			path.relative(themes, icons[0]),
			`${width}x${height}/apps/ergopti.png`,
			'hicolor size metadata must match the PNG dimensions'
		);
	});
	const stub = (name, body) =>
		fs.writeFileSync(path.join(stubs, name), `#!/bin/bash\n${record}\n${body}\n`, { mode: 0o755 });
	stub('systemctl', 'exit 0');
	stub('pkexec', 'exit 126');
	stub('id', 'if [ "$1" = -u ]; then echo 1000; else echo "users input uinput"; fi');
	const flock = spawnSync(bashExecutable(), ['-c', 'command -v flock'], { encoding: 'utf8' });
	assert.equal(flock.status, 0, flock.stderr);
	const realFlock = flock.stdout.trim();
	assert.ok(path.isAbsolute(realFlock), 'the actual session-lock owner must be available');
	stub('flock', 'exec "$ARCH_REAL_FLOCK" "$@"');
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
		ARCH_REAL_LUA: realLua,
		ARCH_REAL_FLOCK: realFlock,
		ARCH_PACKAGE_PROBE: ''
	};
	const launchWithEnvironment = (extra, ...args) => {
		fs.writeFileSync(calls, '');
		return spawnSync(bashExecutable(), [wrapper, ...args], {
			env: { ...env, ...extra },
			encoding: 'utf8',
			timeout: 15000
		});
	};
	const launch = (...args) => launchWithEnvironment({}, ...args);
	// These cases stop at the already controlled interpreter boundary, not help:
	// the real launcher must acquire the resources that an actual daemon needs.
	const launchDaemon = (...args) =>
		launchWithEnvironment({ ARCH_PACKAGE_PROBE: 'print("ARCH_DAEMON_ENTRY")' }, ...args);
	check('arch-wrapper-refuses-without-its-private-runtime', () => {
		// A missing part of the private prefix is refused by the shared
		// environment before anything runs: never a fall back to host programs.
		const curl = path.join(library, 'runtime/bin/curl');
		fs.renameSync(curl, `${curl}.private-test`);
		try {
			const result = launch('--help');
			assert.notEqual(result.status, 0, 'the wrapper must refuse an incomplete private runtime');
			assert.match(result.stderr, /Required installed native package component unavailable/);
			assert.doesNotMatch(fs.readFileSync(calls, 'utf8'), /^luajit /m);
		} finally {
			fs.renameSync(`${curl}.private-test`, curl);
		}
	});
	check('arch-desktop-entry-reaches-the-session-owner', () => {
		const desktop = fs.readFileSync(
			path.join(pkgdir, 'usr/share/applications/ergopti.desktop'),
			'utf8'
		);
		const command = desktop.match(/^Exec=(.+)$/m);
		assert.ok(command, 'staged desktop must name its executable');
		const result = launchDaemon(...command[1].trim().split(/\s+/).slice(1));
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
		const result = launchDaemon(...command[1].trim().split(/\s+/).slice(1));
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
		const result = launchDaemon('--service', '--tray');
		assert.equal(result.status, 0, result.stderr);
		const invoked = fs.readFileSync(calls, 'utf8');
		assert.equal(
			(invoked.match(/^sg /gm) || []).length,
			2,
			'both stale group credentials must be acquired'
		);
		assert.match(invoked, /^luajit .*ergopti_hotstrings\.lua --tray$/m);
		assert.match(
			result.stdout,
			/^ARCH_DAEMON_ENTRY$/m,
			'the controlled daemon boundary must execute'
		);
		assert.doesNotMatch(invoked, /pkexec|systemctl/);
	});
	check('arch-packaged-mixed-help-does-not-acquire-session-resources', () => {
		stub('id', 'if [ "$1" = -u ]; then echo 1000; else echo users; fi');
		const desktop = fs.readFileSync(
			path.join(pkgdir, 'usr/share/applications/ergopti.desktop'),
			'utf8'
		);
		const unit = fs.readFileSync(
			path.join(pkgdir, 'usr/lib/systemd/user/ergopti-hotstrings.service'),
			'utf8'
		);
		const desktopCommand = desktop.match(/^Exec=(.+)$/m);
		const unitCommand = unit.match(/^ExecStart=(.+)$/m);
		assert.ok(desktopCommand && unitCommand, 'both actual package entry points must be present');
		const desktopArgs = desktopCommand[1].trim().split(/\s+/).slice(1);
		const unitArgs = unitCommand[1].trim().split(/\s+/).slice(1);
		for (const help of ['--help', '-h']) {
			for (const args of [desktopArgs, unitArgs, ['--groups-refreshed', ...unitArgs]]) {
				for (const combined of [
					[...args, help],
					[help, ...args]
				]) {
					// No probe: this must be the genuine packaged driver's usage path.
					const result = launch(...combined);
					assert.equal(result.status, 0, `${combined.join(' ')}: ${result.stderr}`);
					assert.match(result.stdout, /^Usage: luajit ergopti_hotstrings\.lua \[OPTIONS\]/m);
					assert.doesNotMatch(result.stdout, /ARCH_DAEMON_ENTRY/);
					const invoked = fs.readFileSync(calls, 'utf8');
					assert.match(invoked, /^luajit /m, 'help must reach the packaged interpreter');
					assert.doesNotMatch(invoked, /^(?:systemctl|pkexec|sg|flock|id) /m);
				}
			}
		}
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
			'local Snapshot = require("diagnostics.engine.snapshot")',
			'assert(Paths.driver_root() == os.getenv("ARCH_LIBRARY_ROOT"), "staged driver root")',
			'assert(Paths.shared_root() == os.getenv("ARCH_SHARED_ROOT"), "staged shared root")',
			'local commit, origin = Snapshot.resolve_commit(Fs, Paths.shared_root(), Paths.driver_root())',
			'assert(origin == Snapshot.COMMIT_SOURCE_BUILD and #commit > 0, "staged build identity")',
			'assert(os.getenv("ARCH_EXPECTED_COMMIT"):sub(1, #commit) == commit, "actual source commit")',
			'for _, rel in ipairs({ "core/i18n/data/locales/en.json", "metrics/data/db/schema.sql", "tray/data/ergopti_tray.png", "settings/data/config_schema/migrations.toml", "ui/apps.manifest.json" }) do',
			' local bytes = Fs.read(Paths.shared(rel)); assert(type(bytes) == "string" and #bytes > 0, "staged resource: " .. rel)',
			'end',
			'local defaults = assert(require("core.text.engine.json").decode(Fs.read(Paths.shared("updater/data/defaults.json"))))',
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
		const sentinel = path.join(shared, 'core/i18n/data/locales/en.json');
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
		const packageRootAssignment = '_ergopti_package_root=/usr/lib/ergopti';
		assert.equal(
			hook.split(packageRootAssignment).length,
			2,
			'the hook root assignment must be unique'
		);
		fs.writeFileSync(
			relocatedHook,
			hook.replace(packageRootAssignment, () => `_ergopti_package_root=${shellQuote(library)}`)
		);
		// Only the privileged filesystem boundary is relocated. The shipped
		// setup function, session selection and account validation execute intact.
		const setup = path.join(library, 'install/setup_permissions.sh');
		const setupSource = fs.readFileSync(setup, 'utf8');
		assert.match(setupSource, /^install -d \/etc\/udev\/rules\.d \/etc\/modules-load\.d$/m);
		fs.writeFileSync(
			setup,
			setupSource.replaceAll(' /etc/', () => ` ${shellQuote(path.join(pkgdir, 'etc'))}/`)
		);
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
		const ownedScratchEntries = fs.readdirSync(scratch).sort();
		for (const action of ['post_install', 'post_upgrade']) {
			const result = runHook(action);
			assert.equal(result.status, 0, `${action}: ${result.stderr}`);
			const invoked = fs.readFileSync(calls, 'utf8');
			assert.match(invoked, /usermod -aG input,uinput desktop/);
			assert.match(invoked, /modprobe uinput/);
			assert.deepEqual(
				fs.readdirSync(scratch).sort(),
				ownedScratchEntries,
				'permission setup must not create an unowned sibling of the staged package'
			);
		}
		stub('usermod', 'exit 73');
		const refused = runHook('post_upgrade');
		// setup_permissions.sh enrolls every other session before it reports the
		// refusal (test-linux-package-setup.cjs pins that contract), so the hook
		// ends failed and names the session it could not enroll.
		assert.notEqual(refused.status, 0, 'a failed account mutation must remain a package failure');
		assert.match(refused.stderr, /code=session-enrollment-failed session=1 uid=1000/);

		const runtimeRoot = path.join(scratch, 'run\\native/user');
		for (const uid of ['1000', '1001']) {
			fs.mkdirSync(path.join(runtimeRoot, uid), { recursive: true });
			fs.writeFileSync(path.join(runtimeRoot, uid, 'bus'), 'private bus-presence fixture');
		}
		const stop = path.join(library, 'install/stop_sessions.sh');
		// A regular fixture records socket presence; no real session bus or
		// account switch is permitted in this unprivileged package test.
		const stopSource = fs.readFileSync(stop, 'utf8');
		const runtimeLoop = 'for runtime in /run/user/[0-9]*; do';
		assert.equal(
			stopSource.split(runtimeLoop).length,
			2,
			'the session enumeration must have one owner'
		);
		fs.writeFileSync(
			stop,
			stopSource
				.replace(runtimeLoop, () => `for runtime in ${shellQuote(runtimeRoot)}/[0-9]*; do`)
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
			'lua51-lgi',
			'webkit2gtk-4.1'
		]) {
			assert.ok(dependencies.includes(name), `missing runtime package: ${name}`);
		}
		// The private runtime in the tarball runs the daemon and its programs:
		// a host package for any of them would let the host decide what runs.
		for (const name of [
			'luajit',
			'lua51-luv',
			'curl',
			'openssl',
			'sqlite',
			'zstd',
			'glib-networking',
			// The XKB installer runs on Ergopti's own Python, downloaded on consent.
			'python'
		])
			assert.ok(!dependencies.includes(name), `the host ${name} must not be required`);
		// Every dialog is Ergopti's own GTK window (linux/ui/dialog_host.lua).
		for (const name of ['zenity', 'kdialog'])
			assert.ok(
				!dependencies.includes(name),
				`the host dialog program ${name} must not be required`
			);
	});
	check('ci-arch-smoke-builds-without-host-depends-then-pacman-resolves-them', () => {
		// The release smoke builds in a bare archlinux container: makepkg must not
		// demand the runtime depends of a package it only builds, and pacman -U
		// must install them from the repositories, as a user's install does.
		const workflow = fs.readFileSync(path.join(ROOT, '.github/workflows/ci-linux.yml'), 'utf8');
		const step = (name) => {
			const start = workflow.indexOf(`- name: ${name}`);
			assert.ok(start >= 0, `missing workflow step: ${name}`);
			const next = workflow.indexOf('\n      - name: ', start + 1);
			return workflow.slice(start, next < 0 ? undefined : next);
		};
		const build = step('Build the release recipe with makepkg (pkgbuild)');
		assert.match(build, /sudo -u ergopti-builder makepkg --noconfirm --nodeps\b/);
		assert.doesNotMatch(build, /--syncdeps|\s-s\b/);
		const install = step('Install the package with pacman (pkgbuild)');
		assert.match(install, /pacman -U --noconfirm "\$\{packages\[0\]\}"/);
	});
} finally {
	fs.rmSync(scratch, { recursive: true, force: true });
}
assert.equal(failures.length, 0, `Arch runtime staging failures: ${failures.join(', ')}`);
console.log('Arch native recipe staging and runtime entry contracts passed.');
