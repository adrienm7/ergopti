// tools/test/test-linux-network-runtime.cjs

/** Exercises mandatory network runtime admission; real native probes are opt-in. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable, bashPath } = require('../lib/git-bash.cjs');
const generator = require('../codegen/codegen-linux-native-runtime.cjs');
const ROOT = path.resolve(__dirname, '../..');
const DRIVER = 'static/ergopti_plus/linux';
// The installer's functions print through its message reader; a harness that
// runs them sources the genuine one, as install.sh does.
const MESSAGES_READER = require('./lib/shell-messages-fixture.cjs').readerSource();
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
	check('private runtime staging refuses an incomplete symlink inventory', () => {
		if (process.platform !== 'linux') return;
		const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runtime-inventory-'));
		try {
			const app = path.join(scratch, 'AppDir'),
				usr = path.join(app, 'usr');
			for (const name of ['bin', 'lib/ergopti', 'share'])
				fs.mkdirSync(path.join(usr, name), { recursive: true });
			fs.writeFileSync(path.join(usr, 'bin/luajit'), '#!/bin/sh\n', { mode: 0o755 });
			fs.writeFileSync(path.join(usr, 'lib/ergopti/network-runtime-env.sh'), ':\n');
			fs.writeFileSync(path.join(usr, 'share/internal.lua'), 'return {}\n');
			fs.symlinkSync('internal.lua', path.join(usr, 'share/module.lua'));
			const bin = path.join(scratch, 'commands');
			fs.mkdirSync(bin);
			fs.writeFileSync(
				path.join(bin, 'find'),
				'#!/bin/sh\nif [ "$INVENTORY_PARTIAL" = 1 ]; then printf "%s\\0" "$1/share/module.lua"; fi\nexit 73\n',
				{ mode: 0o755 }
			);
			for (const partial of ['0', '1']) {
				const result = spawnSync(
					bashExecutable(),
					[
						path.join(ROOT, 'tools/build/stage-linux-private-runtime.sh'),
						app,
						path.join(scratch, `runtime-${partial}`),
						'/usr/lib/ergopti'
					],
					{
						encoding: 'utf8',
						timeout: 10000,
						env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, INVENTORY_PARTIAL: partial }
					}
				);
				assert.notEqual(result.status, 0, 'an inventory refusal cannot certify a package');
				assert.match(result.stderr, /runtime link inventory/);
			}
		} finally {
			fs.rmSync(scratch, { recursive: true, force: true });
		}
	});
	check('private runtime staging admits only links resolving inside the copied prefix', () => {
		if (process.platform !== 'linux') return;
		const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runtime-link-target-'));
		try {
			for (const kind of ['inside', 'outside', 'absolute-inside', 'dangling']) {
				const root = path.join(scratch, kind),
					app = path.join(root, 'AppDir'),
					usr = path.join(app, 'usr');
				for (const name of ['bin', 'lib/ergopti', 'share'])
					fs.mkdirSync(path.join(usr, name), { recursive: true });
				fs.writeFileSync(path.join(usr, 'bin/luajit'), '#!/bin/sh\n', { mode: 0o755 });
				fs.writeFileSync(path.join(usr, 'lib/ergopti/network-runtime-env.sh'), ':\n');
				fs.writeFileSync(path.join(usr, 'share/internal.lua'), 'return {}\n');
				const external = path.join(root, 'external.lua');
				fs.writeFileSync(external, 'return {}\n');
				const destination = path.join(root, 'runtime');
				const target =
					kind === 'inside'
						? 'internal.lua'
						: kind === 'outside'
							? external
							: kind === 'absolute-inside'
								? path.join(destination, 'share/internal.lua')
								: 'missing.lua';
				fs.symlinkSync(target, path.join(usr, 'share/module.lua'));
				const result = spawnSync(
					bashExecutable(),
					[
						path.join(ROOT, 'tools/build/stage-linux-private-runtime.sh'),
						app,
						destination,
						'/usr/lib/ergopti'
					],
					{ encoding: 'utf8', timeout: 10000 }
				);
				if (kind === 'inside') {
					assert.equal(result.status, 0, result.stderr);
					assert.equal(
						fs.readFileSync(path.join(destination, 'share/module.lua'), 'utf8'),
						'return {}\n'
					);
				} else {
					assert.notEqual(result.status, 0, kind);
					assert.match(
						result.stderr,
						/link (leaves|contains)|contains an unresolved link|nonrelocatable absolute link/
					);
				}
			}
		} finally {
			fs.rmSync(scratch, { recursive: true, force: true });
		}
	});
	check(
		'private runtime staging refuses linked source directories before removing a launcher',
		() => {
			if (process.platform !== 'linux') return;
			const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runtime-linked-source-'));
			try {
				for (const linked of ['bin', 'lib', 'share']) {
					const root = path.join(scratch, linked);
					const app = path.join(root, 'AppDir');
					const usr = path.join(app, 'usr');
					for (const name of ['bin', 'lib/ergopti', 'share'])
						fs.mkdirSync(path.join(usr, name), { recursive: true });
					fs.writeFileSync(path.join(usr, 'bin/luajit'), '#!/bin/sh\n', { mode: 0o755 });
					fs.writeFileSync(path.join(usr, 'bin/ergopti'), 'owned source launcher\n');
					fs.writeFileSync(path.join(usr, 'lib/ergopti/network-runtime-env.sh'), ':\n');
					const external = path.join(root, 'external');
					fs.renameSync(path.join(usr, linked), external);
					fs.symlinkSync(external, path.join(usr, linked));
					const destination = path.join(root, 'runtime');
					const result = spawnSync(
						bashExecutable(),
						[
							path.join(ROOT, 'tools/build/stage-linux-private-runtime.sh'),
							app,
							destination,
							'/usr/lib/ergopti'
						],
						{ encoding: 'utf8', timeout: 10000 }
					);
					assert.notEqual(result.status, 0, linked);
					assert.match(result.stderr, /not a direct directory/);
					assert.equal(
						fs.readFileSync(path.join(usr, 'bin/ergopti'), 'utf8'),
						'owned source launcher\n'
					);
					assert.equal(fs.existsSync(destination), false);
				}
			} finally {
				fs.rmSync(scratch, { recursive: true, force: true });
			}
		}
	);
	check('private runtime staging copies double-dot hidden library entries', () => {
		if (process.platform !== 'linux') return;
		const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-runtime-hidden-'));
		try {
			const app = path.join(scratch, 'AppDir');
			const lib = path.join(app, 'usr/lib');
			const bin = path.join(app, 'usr/bin');
			fs.mkdirSync(path.join(lib, 'ergopti'), { recursive: true });
			fs.mkdirSync(bin, { recursive: true });
			fs.mkdirSync(path.join(app, 'usr/share'));
			fs.writeFileSync(path.join(bin, 'luajit'), '#!/bin/sh\n', { mode: 0o755 });
			fs.writeFileSync(path.join(lib, 'ergopti/network-runtime-env.sh'), ':\n');
			fs.writeFileSync(path.join(lib, '..hidden-runtime'), 'runtime bytes\n');
			const destination = path.join(scratch, 'runtime');
			const result = spawnSync(
				bashExecutable(),
				[
					path.join(ROOT, 'tools/build/stage-linux-private-runtime.sh'),
					app,
					destination,
					'/usr/lib/ergopti'
				],
				{ encoding: 'utf8', timeout: 10000 }
			);
			assert.equal(result.status, 0, result.stderr);
			assert.equal(
				fs.readFileSync(path.join(destination, 'lib/..hidden-runtime'), 'utf8'),
				'runtime bytes\n'
			);
		} finally {
			fs.rmSync(scratch, { recursive: true, force: true });
		}
	});
	check('failed native luv publication retires its private temporary file', () => {
		if (process.platform !== 'linux') return;
		const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-luv-publication-'));
		try {
			const installer = outputs[`${DRIVER}/install.sh`];
			const start = installer.indexOf('\tNATIVE_LUV_PUBLICATION="$(mktemp');
			const end = installer.indexOf('\nfi\ncp -r', start);
			assert.ok(start >= 0 && end > start, 'actual publication block');
			const block = installer.slice(start, end);
			const stage = path.join(scratch, 'stage');
			const library = path.join(scratch, 'lib');
			const modules = path.join(library, 'linux/native_modules');
			fs.mkdirSync(stage);
			fs.mkdirSync(modules, { recursive: true });
			fs.writeFileSync(path.join(stage, 'luv.so'), 'new bytes');
			fs.writeFileSync(path.join(modules, 'luv.so'), 'existing bytes');
			for (const failure of ['install', 'mv']) {
				const script = `set -euo pipefail\n${failure}() { return 71; }\n${block}`;
				const result = spawnSync(bashExecutable(), ['-c', script], {
					encoding: 'utf8',
					timeout: 10000,
					env: { ...process.env, LIB_DIR: library, NATIVE_LUV_STAGE: stage }
				});
				assert.notEqual(result.status, 0, `${failure} must fail publication`);
				assert.deepEqual(fs.readdirSync(modules), ['luv.so']);
				assert.equal(fs.readFileSync(path.join(modules, 'luv.so'), 'utf8'), 'existing bytes');
			}
		} finally {
			fs.rmSync(scratch, { recursive: true, force: true });
		}
	});
	check('failed native ownership receipt publication retires its temporary file', () => {
		if (process.platform !== 'linux') return;
		const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-native-receipt-'));
		try {
			const installer = outputs[`${DRIVER}/install.sh`];
			const start = installer.indexOf(
				'if [ -n "$NATIVE_OUTPUT_STAGE" ] || [ -n "$NATIVE_LUV_RETAINED_DIGEST" ]; then'
			);
			const end = installer.indexOf('\nif [ -n "$NATIVE_LUV_STAGE" ]; then', start);
			assert.ok(start >= 0 && end > start, 'actual receipt publication block');
			const block = installer.slice(start, end);
			const library = path.join(scratch, 'lib');
			fs.mkdirSync(path.join(library, 'linux/bin'), { recursive: true });
			fs.writeFileSync(path.join(library, 'linux/bin/libergopti_archive_publication.so'), 'binary');
			const receipt = path.join(library, '.ergopti-owned-files');
			fs.writeFileSync(receipt, 'abc\tlinux/sentinel\n');
			for (const failure of ['write', 'mv']) {
				const stub = failure === 'write' ? 'printf() { return 71; }' : 'mv() { return 71; }';
				const result = spawnSync(bashExecutable(), ['-c', `set -euo pipefail\n${stub}\n${block}`], {
					encoding: 'utf8',
					timeout: 10000,
					env: {
						...process.env,
						LIB_DIR: library,
						NATIVE_OUTPUT_STAGE: '/unused-stage',
						NATIVE_LUV_STAGE: '',
						NATIVE_LUV_RETAINED_DIGEST: ''
					}
				});
				assert.notEqual(result.status, 0, `${failure} must fail publication`);
				assert.deepEqual(fs.readdirSync(library).sort(), ['.ergopti-owned-files', 'linux']);
				assert.equal(fs.readFileSync(receipt, 'utf8'), 'abc\tlinux/sentinel\n');
			}
			const stage = path.join(scratch, 'native-stage');
			fs.mkdirSync(stage);
			fs.writeFileSync(path.join(stage, 'libergopti_archive_publication.so'), 'built binary');
			fs.mkdirSync(path.join(library, 'linux/native_modules'));
			fs.writeFileSync(path.join(library, 'linux/native_modules/luv.so'), 'luv module');
			const success = spawnSync(bashExecutable(), ['-c', `set -euo pipefail\n${block}`], {
				encoding: 'utf8',
				timeout: 10000,
				env: {
					...process.env,
					LIB_DIR: library,
					NATIVE_OUTPUT_STAGE: stage,
					NATIVE_LUV_STAGE: '/luv-stage',
					NATIVE_LUV_RETAINED_DIGEST: ''
				}
			});
			assert.equal(success.status, 0, success.stderr);
			const rows = fs.readFileSync(receipt, 'utf8');
			assert.match(rows, /^abc\tlinux\/sentinel$/m);
			assert.match(rows, /^[0-9a-f]{64}\tlinux\/bin\/libergopti_archive_publication\.so$/m);
			assert.match(rows, /^[0-9a-f]{64}\tlinux\/native_modules\/luv\.so$/m);
			assert.equal(fs.existsSync(stage), false);
		} finally {
			fs.rmSync(scratch, { recursive: true, force: true });
		}
	});
	check('native luv build stage is representable in Lua paths', () => {
		if (process.platform !== 'linux') return;
		const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-luv-stage-'));
		const helper = shellFunction(outputs[`${DRIVER}/install.sh`], '_native_luv_stage_create');
		try {
			for (const suffix of ['ordinary', 'with;separator', 'with?substitution', 'relative']) {
				const temporary = suffix === 'relative' ? 'relative' : path.join(scratch, suffix);
				if (suffix !== 'relative') fs.mkdirSync(temporary);
				const result = spawnSync(bashExecutable(), ['-c', `${helper}\n_native_luv_stage_create`], {
					encoding: 'utf8',
					env: { ...process.env, TMPDIR: temporary }
				});
				assert.equal(result.status, 0, result.stderr);
				const stage = result.stdout.trim();
				try {
					assert.ok(path.isAbsolute(stage));
					assert.doesNotMatch(stage, /[;?]/);
					assert.equal(path.dirname(stage), suffix === 'ordinary' ? temporary : '/tmp');
				} finally {
					fs.rmSync(stage, { recursive: true, force: true });
				}
			}
		} finally {
			fs.rmSync(scratch, { recursive: true, force: true });
		}
	});
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
							MESSAGES_READER +
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
					prepare.indexOf('NATIVE_LUV_STAGE="$(_native_luv_stage_create)"')
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
			const launcher = read(`${DRIVER}/install/standalone_launcher.sh`);
			// A checkout install admits its compiled luv; a release install
			// sources the private runtime it carries instead.
			assert.match(launcher, /^\s*ergopti_admit_native_modules "\$DRIVER_ROOT" optional$/m);
			assert.match(
				launcher,
				/source "\$DRIVER_ROOT\/network-runtime-env\.sh" "\$DRIVER_ROOT\/runtime" "\$DRIVER_ROOT"/
			);
			assert.match(
				read(`${DRIVER}/install/native_modules_env.sh`),
				/export LUA_CPATH="\$modules\/\?\.so;\$\{LUA_CPATH:-;;\}"/
			);
			assert.match(read(`${DRIVER}/tests/distro/e2e_install.sh`), /runtime_probe\.lua/);
		}
	);
	check(
		'source archive builds declare complete compiler and libc headers separately from runtime',
		() => {
			assert.deepEqual(source.archive_build_packages, {
				apt: ['gcc', 'libc6-dev', 'linux-libc-dev'],
				dnf: ['gcc', 'glibc-devel', 'kernel-headers'],
				zypper: ['gcc', 'glibc-devel', 'linux-glibc-devel'],
				pacman: ['gcc', 'glibc', 'linux-api-headers'],
				xbps: null,
				apk: ['gcc', 'musl-dev', 'linux-headers']
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
								MESSAGES_READER +
								`SRC_DRIVER='${bashPath(path.join(ROOT, DRIVER))}'\n` +
								'NATIVE_PROBE_COUNT=0\nnative_source_compile_probe() { NATIVE_PROBE_COUNT=$((NATIVE_PROBE_COUNT + 1)); [ "$NATIVE_PROBE_COUNT" -gt 1 ]; }\n' +
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
				installer.indexOf("IFS= read -r -d '' NATIVE_OUTPUT_REPO"),
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
			// LuaJIT and curl come from the private runtime of these three.
			deb: ['xclip', 'libnotify-bin', 'at-spi2-core'],
			rpm: ['xclip', 'libnotify', 'at-spi2-core'],
			arch: ['xclip', 'libnotify', 'at-spi2-core'],
			nix_library_path: ['libayatana-appindicator', 'gtk3', 'glib', 'libxkbcommon', 'at-spi2-core']
		})) {
			for (const requirement of old)
				assert.ok(generator.requirements(source, format).includes(requirement));
		}
	});
	// The Arch recipe repacks the release tarball (tools/build/PKGBUILD), so it
	// ships the same private runtime as the .deb and the .rpm; a format that lost
	// it would name the host's LuaJIT, curl or luv package again.
	check('private-runtime packages name no host LuaJIT, curl or luv', () => {
		for (const [format, manager] of [
			['deb', 'apt'],
			['rpm', 'dnf'],
			['arch', 'pacman']
		]) {
			const required = generator.requirements(source, format);
			const host = ['luajit', 'curl', ...(source.network_runtime.providers[manager] || [])];
			for (const name of host.filter((entry) => /lua|curl/.test(entry)))
				assert.equal(required.includes(name), false, `${format} must not require the host ${name}`);
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
					MESSAGES_READER +
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
					PATH: bashPath(bin),
					SRC_DRIVER: '/private driver/linux',
					SRC_SHARED: '/private shared/_shared',
					EXPECTED_PROBE: '/private driver/linux/core/network/adapters/runtime_probe.lua',
					EXPECTED_SHARED: '/private shared/_shared',
					PRESENT: bashPath(present),
					INSTALLS: bashPath(installs),
					PROBES: bashPath(probes),
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
						'/private driver/linux/core/network/adapters/runtime_probe.lua',
						'/private shared/_shared',
						'/private driver/linux/core/network/adapters/runtime_probe.lua',
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
		fs.mkdirSync(path.join(driver, 'core/fs/engine'), { recursive: true });
		fs.copyFileSync(
			path.join(ROOT, DRIVER, 'core/fs/engine/regular_file_reader.lua'),
			path.join(driver, 'core/fs/engine/regular_file_reader.lua')
		);
		fs.mkdirSync(path.join(driver, '_generated'), { recursive: true });
		fs.mkdirSync(shared, { recursive: true });
		fs.mkdirSync(cwd);
		for (const name of ['runtime_probe.lua', 'native_proxy_runtime.lua'])
			fs.copyFileSync(
				path.join(ROOT, DRIVER, 'core/network/adapters', name),
				path.join(driver, 'platform/network', name)
			);
		// Each shared module is staged under its own folder, whatever its depth.
		for (const name of ['core/text/engine/json.lua', 'core/lifecycle/engine/compat/utf8.lua']) {
			fs.mkdirSync(path.dirname(path.join(shared, name)), { recursive: true });
			fs.copyFileSync(path.join(ROOT, SHARED, name), path.join(shared, name));
		}
		// The installed lookup helper bounds its receipt by the shared policy's limits.
		fs.mkdirSync(path.join(shared, 'core/network/data'), { recursive: true });
		fs.copyFileSync(
			path.join(ROOT, SHARED, 'core/network/data/proxy_policy.json'),
			path.join(shared, 'core/network/data/proxy_policy.json')
		);
		fs.writeFileSync(
			path.join(driver, '_generated/native_runtime.lua'),
			outputs[generator.LUA_OUTPUT]
		);
		const probe = path.join(driver, 'core/network/adapters/runtime_probe.lua');
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
					path.join(ROOT, DRIVER, 'core/network/adapters/system_proxy_probe.lua'),
					path.join(driver, 'core/network/adapters/system_proxy_probe.lua')
				);
				const runHelper = () => {
					const helper = spawnSync(
						'luajit',
						[path.join(driver, 'core/network/adapters/system_proxy_probe.lua'), shared],
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
					return JSON.parse(helper.stdout);
				};
				// Withhold only the staged canonical policy, then restore the same file:
				// a missing policy and missing schema must remain independent refusals.
				const policy = path.join(shared, 'core/network/data/proxy_policy.json');
				const withheldPolicy = path.join(root, 'withheld-proxy-policy.json');
				fs.renameSync(policy, withheldPolicy);
				assert.deepEqual(runHelper(), { ok: false, error: 'proxy-policy-unavailable' });
				fs.renameSync(withheldPolicy, policy);
				assert.deepEqual(runHelper(), { ok: false, error: 'proxy-backend-unavailable' });
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
