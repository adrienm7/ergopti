// tools/test/test-linux-network-runtime.cjs

/** Exercises mandatory network runtime admission; real native probes are opt-in. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const generator = require('../codegen/codegen-linux-native-runtime.cjs');
const ROOT = path.resolve(__dirname, '../..');
const DRIVER = 'static/ergopti_plus/linux';
const SHARED = 'static/ergopti_plus/_shared';
const source = JSON.parse(fs.readFileSync(path.join(ROOT, generator.SOURCE), 'utf8'));
const read = (name) => fs.readFileSync(path.join(ROOT, name), 'utf8');
const outputs = generator.render(source, read);
let passed = 0;
let skipped = 0;

/** Counts an assertion group only after all its independent postconditions pass. */
function check(name, fn) {
	fn();
	passed++;
	console.log(`PASS ${name}`);
}

/** Extracts a complete top-level production shell function without running install.sh. */
function shellFunction(installer, name) {
	const match = installer.match(new RegExp(`^${name}\\(\\) \\{[\\s\\S]*?^\\}`, 'm'));
	assert.ok(match, `Missing actual installer function: ${name}`);
	return match[0];
}

/** Preserves inherited unrelated environment values while deleting overrideable keys. */
function nativeEnvironment(extra) {
	const env = { ...process.env };
	for (const name of ['LUA_PATH', 'LUA_INIT', 'LUA_INIT_5_1', 'GIO_USE_PROXY_RESOLVER'])
		delete env[name];
	if (env.ERGOPTI_NATIVE_LUA_CPATH) env.LUA_CPATH = env.ERGOPTI_NATIVE_LUA_CPATH;
	return { ...env, ...extra };
}

/** Tests actual generated installer decisions with private package/runtime witnesses. */
function portable() {
	check(
		'native module parents refuse source and installation symlink aliases without writes',
		() => {
			if (process.platform !== 'linux') {
				skipped++;
				return;
			}
			const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-module-parents-'));
			const installer = outputs[`${DRIVER}/install.sh`];
			const functions = ['_native_output_ordinary_directory', '_native_output_bin_parents']
				.map((name) => shellFunction(installer, name))
				.join('\n');
			try {
				const outside = path.join(root, 'outside');
				fs.mkdirSync(outside);
				const sentinel = path.join(outside, 'luv.so');
				fs.writeFileSync(sentinel, 'foreign unchanged bytes');
				for (const alias of ['source', 'installed', 'ordinary']) {
					const sourceRoot = path.join(root, alias, 'source');
					const installed = path.join(root, alias, 'installed');
					fs.mkdirSync(sourceRoot, { recursive: true });
					fs.mkdirSync(path.join(installed, 'linux'), { recursive: true });
					const target =
						alias === 'source'
							? path.join(sourceRoot, 'native_modules')
							: path.join(installed, 'linux/native_modules');
					if (alias !== 'ordinary') fs.symlinkSync(outside, target, 'dir');
					const result = spawnSync(bashExecutable(), ['-s'], {
						input:
							'set -eu\n' +
							functions +
							'\nSRC_DRIVER=' +
							JSON.stringify(sourceRoot) +
							'\nLIB_DIR=' +
							JSON.stringify(installed) +
							'\n_native_output_bin_parents\n',
						encoding: 'utf8',
						timeout: 5000
					});
					assert.ifError(result.error);
					assert.equal(result.signal, null);
					assert.equal(result.status, alias === 'ordinary' ? 0 : 1);
					assert.equal(fs.readFileSync(sentinel, 'utf8'), 'foreign unchanged bytes');
				}
			} finally {
				fs.rmSync(root, { recursive: true, force: true });
			}
		}
	);
	check(
		'source luv producer refuses malformed pins and occupied output before Git or compilation',
		() => {
			const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-luv-refusal-'));
			try {
				for (const [url, revision, occupied] of [
					['http://github.com/luvit/luv.git', '26e62e49b0230891ece45a78cc1f63c074e60020', false],
					['https://github.com/luvit/luv.git', 'not-a-commit', false],
					['https://github.com/luvit/luv.git', '26e62e49b0230891ece45a78cc1f63c074e60020', true]
				]) {
					if (occupied) fs.writeFileSync(path.join(root, 'luv.so'), 'foreign');
					const result = spawnSync(
						bashExecutable(),
						[
							path.join(ROOT, DRIVER, 'install/build_native_luv.sh'),
							root,
							url,
							revision,
							'-DLUA_BUILD_TYPE=System'
						],
						{ encoding: 'utf8', timeout: 5000 }
					);
					assert.ifError(result.error);
					assert.equal(result.signal, null);
					assert.equal(result.status, 2);
					assert.equal(fs.existsSync(path.join(root, 'source')), false);
				}
				assert.equal(fs.readFileSync(path.join(root, 'luv.so'), 'utf8'), 'foreign');
			} finally {
				fs.rmSync(root, { recursive: true, force: true });
			}
		}
	);
	check(
		'Fedora source installs bootstrap the pinned LuaJIT module without guessing an archive package',
		() => {
			assert.deepEqual(source.network_runtime.source_luv_build_packages, {
				apt: null,
				dnf: [
					'git',
					'gcc',
					'glibc-devel',
					'make',
					'cmake',
					'pkgconf-pkg-config',
					'luajit-devel',
					'glib-networking',
					'gsettings-desktop-schemas',
					'dconf'
				],
				zypper: null,
				pacman: null,
				xbps: null,
				apk: null
			});
			assert.equal(
				source.network_runtime.providers.dnf,
				null,
				'no invented distribution LuaJIT package'
			);
			for (const mutate of [
				(data) => delete data.network_runtime.source_luv_build_packages,
				(data) => delete data.network_runtime.source_luv_build_packages.dnf,
				(data) => (data.network_runtime.source_luv_build_packages.dnf = []),
				(data) => (data.network_runtime.source_luv_build_packages.dnf = ['git', 'git']),
				(data) => (data.network_runtime.source_luv_build_packages.dnf = ['git; exit 0'])
			]) {
				const invalid = structuredClone(source);
				mutate(invalid);
				assert.throws(() => generator.validate(invalid), /source luv build/);
			}
			const installer = outputs[`${DRIVER}/install.sh`];
			const prepare = shellFunction(installer, '_prepare_source_network_runtime');
			assert.ok(
				prepare.indexOf('_native_output_bin_parents || return 1') <
					prepare.indexOf('NATIVE_LUV_STAGE="$(mktemp -d)"')
			);
			assert.match(prepare, /_network_runtime_available; then return 0; fi/);
			assert.match(
				prepare,
				/if \[ "\$SRC_DRIVER" != "\$\{repository\}\/static\/ergopti_plus\/linux" \]; then return 0; fi/
			);
			assert.match(prepare, /NATIVE_LUV_CMAKE_OPTIONS\[@\]/);
			const admission = installer.indexOf(
				'_prepare_source_network_runtime\n_ensure_network_runtime'
			);
			assert.ok(admission > installer.indexOf('if $SKIP_DEPS; then'));
			const builder = read(`${DRIVER}/install/build_native_luv.sh`);
			for (const guard of [
				'git -C "$SOURCE" fetch --depth=1 "$SOURCE_URL" "$SOURCE_REVISION"',
				'[ "$(git -C "$SOURCE" rev-parse HEAD)" = "$SOURCE_REVISION" ]',
				'git -C "$SOURCE" fsck --strict',
				'git -C "$SOURCE" submodule update --init --depth=1 -- deps/libuv deps/lua-compat-5.3',
				'cmake -S "$SOURCE" -B "$BUILD"',
				'package.loadlib(arg[1], "luaopen_luv")',
				'assert(debug.getinfo(uv.fs_stat, "S").what == "C")'
			])
				assert.ok(builder.includes(guard), `Missing native producer guard: ${guard}`);
			assert.deepEqual(generator.LUV_CMAKE_OPTIONS, [
				'-DLUA_BUILD_TYPE=System',
				'-DWITH_LUA_ENGINE=LuaJIT',
				'-DBUILD_MODULE=ON',
				'-DBUILD_SHARED_LIBS=OFF',
				'-DBUILD_STATIC_LIBS=OFF',
				'-DWITH_SHARED_LIBUV=OFF'
			]);
			assert.match(installer, /linux\/native_modules\/luv\.so/);
			assert.match(
				read(`${DRIVER}/install/standalone_launcher.sh`),
				/export LUA_CPATH="\$DRIVER_ROOT\/native_modules\/\?\.so;\$\{LUA_CPATH:-;;\}"/
			);
			assert.match(read(`${DRIVER}/tests/distro/e2e_install.sh`), /runtime_probe\.lua/);
		}
	);
	check(
		'source archive builds declare complete compiler and libc headers separately from runtime',
		() => {
			assert.deepEqual(source.archive_build_packages, {
				apt: ['gcc', 'libc6-dev'],
				dnf: ['gcc', 'glibc-devel'],
				zypper: ['gcc', 'glibc-devel'],
				pacman: ['gcc', 'glibc'],
				xbps: null,
				apk: ['gcc', 'musl-dev']
			});
			for (const mutate of [
				(data) => delete data.archive_build_packages,
				(data) => delete data.archive_build_packages.apk,
				(data) => (data.archive_build_packages.apt = []),
				(data) => (data.archive_build_packages.apt = ['gcc', 'gcc']),
				(data) => (data.archive_build_packages.apt = ['gcc; exit 0'])
			]) {
				const invalid = structuredClone(source);
				mutate(invalid);
				assert.throws(() => generator.validate(invalid), /archive build/);
			}
			const installer = outputs[`${DRIVER}/install.sh`];
			const functions = ['_native_output_build_packages', '_ensure_native_output_toolchain']
				.map((name) => shellFunction(installer, name))
				.join('\n');
			for (const [manager, packages] of Object.entries(source.archive_build_packages)) {
				for (const skip of [false, true]) {
					for (const installStatus of [0, 7]) {
						const result = spawnSync(bashExecutable(), ['-s'], {
							input:
								'set -u\n' +
								functions +
								'\n' +
								`SKIP_DEPS=${skip}\n_detect_pkg_manager() { echo ${manager}; }\n` +
								`_install_required_package() { printf 'INSTALL %s %s\\n' "$1" "$2"; return ${installStatus}; }\n` +
								'_ensure_native_output_toolchain\n',
							encoding: 'utf8',
							timeout: 5000
						});
						assert.ifError(result.error);
						assert.equal(result.signal, null);
						assert.equal(result.status, skip || (packages && !installStatus) ? 0 : 1);
						const expected =
							skip || !packages ? [] : installStatus ? packages.slice(0, 1) : packages;
						assert.deepEqual(
							result.stdout.trim().split('\n').filter(Boolean),
							expected.map((pkg) => `INSTALL ${manager} ${pkg}`)
						);
					}
				}
			}
			const sourceBranch = installer.slice(
				installer.indexOf('NATIVE_OUTPUT_REPO='),
				installer.indexOf('# Create destination directories.')
			);
			assert.match(
				sourceBranch,
				/if \[ "\$SRC_DRIVER" = "\$\{NATIVE_OUTPUT_REPO\}\/static\/ergopti_plus\/linux" \]; then/
			);
			assert.ok(
				sourceBranch.indexOf('_ensure_native_output_toolchain || exit 1') <
					sourceBranch.indexOf('NATIVE_OUTPUT_STAGE="$(mktemp -d)"')
			);
			assert.ok(
				sourceBranch.indexOf('_ensure_native_output_toolchain || exit 1') >
					sourceBranch.indexOf('Canonical native archive build helper unavailable')
			);
			for (const format of ['deb', 'rpm', 'arch'])
				assert.ok(
					generator
						.requirements(source, format)
						.every((name) => !['gcc', 'libc6-dev', 'glibc-devel', 'musl-dev'].includes(name))
				);
		}
	);
	check('original library identities and all historical package requirements survive', () => {
		assert.deepEqual(generator.KEYS, ['xkbcommon', 'xkbcommon_x11', 'x11', 'x11_xcb']);
		for (const [format, old] of Object.entries({
			deb: ['luajit (>= 2.1)', 'xclip', 'libnotify-bin', 'curl', 'at-spi2-core'],
			rpm: ['luajit >= 2.1', 'xclip', 'libnotify', 'curl', 'at-spi2-core'],
			arch: ['luajit', 'xclip', 'libnotify', 'curl', 'at-spi2-core'],
			nix_library_path: ['libayatana-appindicator', 'gtk3', 'glib', 'libxkbcommon', 'at-spi2-core']
		})) {
			for (const requirement of old)
				assert.ok(generator.requirements(source, format).includes(requirement));
		}
	});
	check('independent provider inventory rejects fabricated Void and unsupported providers', () => {
		assert.deepEqual(source.network_runtime.providers, {
			apt: ['glib-networking', 'gsettings-desktop-schemas', 'lua-luv'],
			dnf: null,
			zypper: ['glib-networking', 'gsettings-desktop-schemas', 'luajit-luv'],
			pacman: ['glib-networking', 'gsettings-desktop-schemas', 'lua51-luv'],
			xbps: null,
			apk: ['glib-networking', 'gsettings-desktop-schemas', 'lua5.1-luv']
		});
		const invalid = structuredClone(source);
		invalid.network_runtime.providers.apk.push('name;exit 0');
		assert.throws(() => generator.validate(invalid), /provider package/);
		const missing = structuredClone(source);
		delete missing.network_runtime.providers.xbps;
		assert.throws(() => generator.validate(missing), /availability/);
	});
	const installer = outputs[`${DRIVER}/install.sh`];
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-network-runtime-'));
	const posix = (value) => value.replace(/^([A-Za-z]):/, '/$1').replaceAll('\\', '/');
	try {
		const bin = path.join(root, 'bin');
		fs.mkdirSync(bin);
		fs.mkdirSync(path.join(root, 'unrelated cwd'));
		fs.writeFileSync(
			path.join(bin, 'luajit'),
			'#!/bin/bash\n' +
				'printf "%s\\n" "$@" >> "$PROBES"\n' +
				'[ "$#" = 2 ] && [ "$1" = "$EXPECTED_PROBE" ] && [ "$2" = "$EXPECTED_SHARED" ] || exit 9\n' +
				'[ -f "$PRESENT" ]\n'
		);
		fs.chmodSync(path.join(bin, 'luajit'), 0o700);
		const harness = [
			'_network_runtime_packages',
			'_network_runtime_available',
			'_ensure_network_runtime'
		]
			.map((name) => shellFunction(installer, name))
			.join('\n');
		const moduleWitness = {
			apt: 'lua-luv',
			apk: 'lua5.1-luv',
			zypper: 'luajit-luv',
			pacman: 'lua51-luv'
		};
		const run = (
			manager,
			provide,
			packageStatus = 0,
			initiallyPresent = false,
			unavailableFixture = false
		) => {
			// Retain every original null-provider refusal/no-repair control even
			// when saved metadata admits a new current provider for that manager.
			const fixturePolicy = structuredClone(source);
			if (unavailableFixture) fixturePolicy.network_runtime.providers[manager] = null;
			const actualInstaller = unavailableFixture
				? generator.render(fixturePolicy, read)[`${DRIVER}/install.sh`]
				: installer;
			const actualHarness = unavailableFixture
				? ['_network_runtime_packages', '_network_runtime_available', '_ensure_network_runtime']
						.map((name) => shellFunction(actualInstaller, name))
						.join('\n')
				: harness;
			const present = path.join(root, 'present');
			const installs = path.join(root, 'installs');
			const probes = path.join(root, 'probes');
			for (const name of [present, installs, probes]) fs.rmSync(name, { force: true });
			if (initiallyPresent) fs.writeFileSync(present, 'owned');
			const result = spawnSync(bashExecutable(), ['-s'], {
				input:
					'set -u\n' +
					actualHarness +
					'\n' +
					`_detect_pkg_manager() { echo ${manager}; }\n` +
					'_install_required_package() {\n' +
					' printf "%s:%s\\n" "$1" "$2" >> "$INSTALLS"\n' +
					` if [ "$2" = "${moduleWitness[manager] || 'no-owned-provider'}" ] && [ "$PROVIDE" = 1 ]; then : > "$PRESENT"; fi\n` +
					` return ${packageStatus}\n}\n_ensure_network_runtime\n`,
				cwd: path.join(root, 'unrelated cwd'),
				encoding: 'utf8',
				timeout: 5000,
				env: {
					...process.env,
					PATH: posix(bin),
					SRC_DRIVER: '/private driver/linux',
					SRC_SHARED: '/private shared/_shared',
					EXPECTED_PROBE: '/private driver/linux/platform/network/runtime_probe.lua',
					EXPECTED_SHARED: '/private shared/_shared',
					PRESENT: posix(present),
					INSTALLS: posix(installs),
					PROBES: posix(probes),
					PROVIDE: provide ? '1' : '0'
				}
			});
			assert.ifError(result.error);
			return {
				status: result.status,
				probes: fs.readFileSync(probes, 'utf8').trim().split('\n'),
				installs: fs.existsSync(installs)
					? fs.readFileSync(installs, 'utf8').trim().split('\n')
					: []
			};
		};
		// These expected package identities are hand-authored from saved upstream
		// distribution metadata, independently of the generator's output.
		const packageWitnesses = {
			apt: ['glib-networking', 'gsettings-desktop-schemas', 'lua-luv'],
			apk: ['glib-networking', 'gsettings-desktop-schemas', 'lua5.1-luv'],
			zypper: ['glib-networking', 'gsettings-desktop-schemas', 'luajit-luv'],
			pacman: ['glib-networking', 'gsettings-desktop-schemas', 'lua51-luv']
		};
		for (const manager of ['apt', 'apk', 'zypper', 'pacman']) {
			const packages = packageWitnesses[manager];
			check(
				`${manager} rejects package-manager false success and reprobes exact installed paths`,
				() => {
					const result = run(manager, false);
					assert.notEqual(result.status, 0);
					assert.deepEqual(
						result.installs,
						packages.map((name) => `${manager}:${name}`)
					);
					assert.deepEqual(result.probes, [
						'/private driver/linux/platform/network/runtime_probe.lua',
						'/private shared/_shared',
						'/private driver/linux/platform/network/runtime_probe.lua',
						'/private shared/_shared'
					]);
				}
			);
			check(`${manager} requires the actual runtime witness after successful repair`, () => {
				assert.equal(run(manager, true).status, 0);
			});
			check(
				`${manager} preserves package refusal before any later package or success admission`,
				() => {
					const result = run(manager, true, 7);
					assert.notEqual(result.status, 0);
					assert.deepEqual(result.installs, [`${manager}:glib-networking`]);
					assert.equal(result.probes.length, 2);
				}
			);
		}
		for (const manager of ['dnf', 'zypper', 'pacman', 'xbps']) {
			check(`${manager} refuses unsupported repair without trying guessed packages`, () => {
				const result = run(manager, false, 0, false, true);
				assert.notEqual(result.status, 0);
				assert.deepEqual(result.installs, []);
			});
			check(`${manager} admits an already present runtime without repair`, () => {
				const result = run(manager, false, 0, true, true);
				assert.equal(result.status, 0);
				assert.deepEqual(result.installs, []);
			});
		}
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

/** Runs actual lookup-free GIO/LuaJIT probes in a private installed-shaped tree. */
function native() {
	if (process.platform !== 'linux') {
		skipped++;
		console.log('SKIP actual Linux native runtime: non-Linux host');
		return;
	}
	const available = spawnSync('luajit', ['-v'], { encoding: 'utf8', timeout: 5000 });
	assert.ifError(available.error);
	assert.equal(available.status, 0);
	const root = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-installed-network-'));
	try {
		const driver = path.join(root, 'installed driver/linux');
		const shared = path.join(root, 'installed driver/_shared');
		const cwd = path.join(root, 'unrelated cwd');
		fs.mkdirSync(path.join(driver, 'platform/network'), { recursive: true });
		fs.mkdirSync(path.join(driver, '_generated'), { recursive: true });
		fs.mkdirSync(path.join(shared, 'lua'), { recursive: true });
		fs.mkdirSync(cwd);
		for (const name of ['runtime_probe.lua', 'native_proxy_runtime.lua'])
			fs.copyFileSync(
				path.join(ROOT, DRIVER, 'platform/network', name),
				path.join(driver, 'platform/network', name)
			);
		fs.copyFileSync(path.join(ROOT, SHARED, 'lua/json.lua'), path.join(shared, 'lua/json.lua'));
		fs.mkdirSync(path.join(shared, 'lua/compat'));
		fs.copyFileSync(
			path.join(ROOT, SHARED, 'lua/compat/utf8.lua'),
			path.join(shared, 'lua/compat/utf8.lua')
		);
		fs.writeFileSync(
			path.join(driver, '_generated/native_runtime.lua'),
			outputs[generator.LUA_OUTPUT]
		);
		const probe = path.join(driver, 'platform/network/runtime_probe.lua');
		const run = (extra) => {
			const result = spawnSync('luajit', [probe, shared], {
				cwd,
				encoding: 'utf8',
				timeout: 10000,
				maxBuffer: 1024,
				env: nativeEnvironment(extra)
			});
			assert.ifError(result.error);
			assert.equal(result.signal, null);
			// Native stderr is private: only the bounded canonical receipt is parsed.
			const receipt = JSON.parse(result.stdout);
			assert.ok(
				Object.keys(receipt).every((key) =>
					[
						'ok',
						'error',
						'acknowledgement',
						'schema_available',
						'schema_required',
						'selection_scope'
					].includes(key)
				)
			);
			return { status: result.status, receipt };
		};
		check('actual LuaJIT refuses missing luv from an unrelated installed CWD', () => {
			const result = run({
				LUA_CPATH: path.join(root, 'absent/?.so'),
				LUA_PATH: path.join(root, 'absent/?.lua')
			});
			assert.equal(result.status, 1);
			assert.deepEqual(result.receipt, { ok: false, error: 'proxy-async-unavailable' });
		});
		check('actual installed GLib with dummy resolver refuses native package admission', () => {
			const result = run({ GIO_USE_PROXY_RESOLVER: 'dummy' });
			assert.equal(result.status, 1);
			assert.deepEqual(result.receipt, { ok: false, error: 'proxy-backend-unavailable' });
		});
		check(
			'actual missing compiled schema refuses helper and installer before resolver construction',
			() => {
				const schemas = path.join(root, 'empty schemas');
				fs.mkdirSync(schemas);
				const isolated = {
					XDG_DATA_DIRS: schemas,
					XDG_DATA_HOME: schemas,
					GSETTINGS_SCHEMA_DIR: schemas,
					XDG_CURRENT_DESKTOP: 'GNOME',
					GIO_USE_PROXY_RESOLVER: 'gnome'
				};
				const receipt = run(isolated);
				assert.equal(receipt.status, 1);
				assert.deepEqual(receipt.receipt, { ok: false, error: 'proxy-backend-unavailable' });
				// Exercise the actual lookup helper as well, without a destination connection.
				fs.copyFileSync(
					path.join(ROOT, DRIVER, 'platform/network/system_proxy_probe.lua'),
					path.join(driver, 'platform/network/system_proxy_probe.lua')
				);
				const helper = spawnSync(
					'luajit',
					[path.join(driver, 'platform/network/system_proxy_probe.lua'), shared],
					{
						cwd,
						encoding: 'utf8',
						timeout: 10000,
						maxBuffer: 1024,
						input: JSON.stringify({ url: 'https://owned-probe.invalid/' }),
						env: nativeEnvironment(isolated)
					}
				);
				assert.ifError(helper.error);
				assert.equal(helper.signal, null);
				assert.equal(helper.status, 0);
				assert.deepEqual(JSON.parse(helper.stdout), {
					ok: false,
					error: 'proxy-backend-unavailable'
				});
			}
		);
		check('actual installed runtime locates native and shared sources independently of CWD', () => {
			const result = run({});
			assert.equal(
				result.status,
				0,
				'Native luv/GIO module/schema prerequisites are not qualified on this host.'
			);
			assert.equal(result.receipt.ok, true);
			assert.equal(result.receipt.acknowledgement, 'native-runtime');
			assert.equal(result.receipt.selection_scope, 'native-selection');
			assert.equal(typeof result.receipt.schema_available, 'boolean');
			assert.equal(typeof result.receipt.schema_required, 'boolean');
		});
	} finally {
		fs.rmSync(root, { recursive: true, force: true });
	}
}

if (process.argv.includes('--native')) native();
else portable();
console.log(
	`Linux network runtime: ${passed} passed; ${skipped} skipped. Actual native probes require --native.`
);
