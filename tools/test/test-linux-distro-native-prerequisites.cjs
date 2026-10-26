// tools/test/test-linux-distro-native-prerequisites.cjs

/** Executes distro preparation through its actual first package-manager boundary. */
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');
const ROOT = path.resolve(__dirname, '../..');
const helper = path.join(ROOT, 'tools/test/prepare-linux-distro-unit.sh');
const bashPath = (value) =>
	process.platform === 'win32'
		? value.replaceAll('\\', '/').replace(/^([A-Za-z]):/, (_, drive) => `/${drive.toLowerCase()}`)
		: value;
// These are native ABI/data/CLI providers, not desktop networking backends.
// Genuine distro qualification separately executes GVariant, SQLite and XKB fixtures.
const providers = [
	[
		'debian',
		'apt-get',
		'libglib2.0-0t64',
		'sqlite3',
		'tzdata',
		'libxkbcommon0',
		'xkb-data',
		'libx11-data'
	],
	[
		'fedora',
		'dnf',
		'glib2',
		'sqlite',
		'tzdata',
		'libxkbcommon',
		'xkeyboard-config',
		'libX11-common'
	],
	['arch', 'pacman', 'glib2', 'sqlite', 'tzdata', 'libxkbcommon', 'xkeyboard-config', 'libx11'],
	['alpine', 'apk', 'glib', 'sqlite', 'tzdata', 'libxkbcommon', 'xkeyboard-config', 'libx11'],
	[
		'opensuse',
		'zypper',
		'libglib-2_0-0',
		'sqlite3',
		'timezone',
		'libxkbcommon0',
		'xkeyboard-config',
		'libX11-data'
	]
];
/** Execute every package, pin and destination guard in one physical scratch tree. */
function runControls(scratch) {
	try {
		const bin = path.join(scratch, 'bin');
		fs.mkdirSync(bin);
		const recorded = path.join(scratch, 'package-argv');
		for (const command of providers.map((entry) => entry[1])) {
			fs.writeFileSync(
				path.join(bin, command),
				'#!/bin/bash\nprintf "%s\\0" "${0##*/}" "$@" > "$ERGOPTI_TEST_PACKAGE_ARGS"\nexit 73\n',
				{ mode: 0o755 }
			);
		}
		// A broken fail-fast boundary must never create an account on the test host.
		for (const command of ['useradd', 'adduser', 'luajit']) {
			fs.writeFileSync(path.join(bin, command), '#!/bin/bash\nexit 99\n', { mode: 0o755 });
		}
		const invoke = (distro, suite) =>
			spawnSync(bashExecutable(), [bashPath(helper), distro, bashPath(ROOT), suite], {
				encoding: 'utf8',
				timeout: 5000,
				env: {
					...process.env,
					PATH: `${bashPath(bin)}:/usr/bin:/bin`,
					ERGOPTI_TEST_PACKAGE_ARGS: bashPath(recorded)
				}
			});
		let checks = 0;
		for (const [distro, manager, glib, sqlite, timezone, xkb, keymaps, compose] of providers) {
			for (const suite of ['unit', 'integration']) {
				fs.rmSync(recorded, { force: true });
				const result = invoke(distro, suite);
				assert.equal(result.error, undefined, `${distro}/${suite}: helper must finish`);
				assert.equal(
					result.status,
					73,
					`${distro}/${suite}: package refusal must propagate before user/native setup: ${result.stderr}`
				);
				const [actualManager, ...args] = fs
					.readFileSync(recorded, 'utf8')
					.split('\0')
					.filter(Boolean);
				assert.equal(actualManager, manager, `${distro}: the actual authored backend must execute`);
				assert.equal(
					args.at(-1),
					'curl',
					`${distro}: curl remains the final acquisition prerequisite`
				);
				assert.ok(args.includes('tar'), `${distro}: the verified Lua archive needs extraction`);
				assert.ok(
					args.includes('openssl'),
					`${distro}: native key derivation requires the declared OpenSSL CLI`
				);
				assert.ok(
					args.includes(timezone),
					`${distro}: native local-calendar fixtures require declared timezone data`
				);
				assert.ok(args.includes(glib), `${distro}: native GVariant requires declared ${glib}`);
				assert.ok(
					args.includes(xkb),
					`${distro}: native keymap publication requires declared ${xkb}`
				);
				assert.ok(
					args.includes(keymaps),
					`${distro}: native XKB context requires declared ${keymaps}`
				);
				assert.ok(
					args.includes(compose),
					`${distro}: native Compose state requires declared ${compose}`
				);
				assert.ok(
					args.includes(sqlite),
					`${distro}: native metric reset requires declared ${sqlite}`
				);
				checks++;
			}
		}
		for (const [distro, suite] of [
			['unknown', 'unit'],
			['debian', 'unknown']
		]) {
			fs.rmSync(recorded, { force: true });
			const result = invoke(distro, suite);
			assert.equal(result.error, undefined);
			assert.notEqual(result.status, 0);
			assert.notEqual(
				result.status,
				73,
				'invalid preparation must refuse before any package action'
			);
			assert.equal(fs.existsSync(recorded), false);
			checks++;
		}
		// Exercise the real closed pin reader and both consumers, including malformed
		// contracts. The independent retained-product hash fence stays immutable.
		const pinFile = path.join(ROOT, 'tools/build/native-source-pins.json');
		const reader = path.join(ROOT, 'tools/build/read-native-source-pin.py');
		const pins = JSON.parse(fs.readFileSync(pinFile, 'utf8'));
		const readPin = (script, section, field) =>
			spawnSync('python3', [script, section, field], { encoding: 'utf8', timeout: 5000 });
		for (const [section, fields] of Object.entries(pins)) {
			for (const [field, value] of Object.entries(fields)) {
				const result = readPin(reader, section, field);
				assert.equal(result.error, undefined);
				assert.equal(result.status, 0, result.stderr);
				assert.equal(result.stdout, value + '\n');
				checks++;
			}
		}
		const productFence = fs.readFileSync(
			path.join(ROOT, 'tools/build/owned_runtime_product_build.py'),
			'utf8'
		);
		assert.ok(productFence.includes(`LUA_ARCHIVE_SHA256 = "${pins.lua54.sha256}"`));
		assert.ok(productFence.includes(`lua-${pins.lua54.version}/src`));
		const mac = fs.readFileSync(path.join(ROOT, 'tools/build/bundle-macos-luasocket.sh'), 'utf8');
		const preparation = fs.readFileSync(helper, 'utf8');
		assert.ok(mac.includes('read-native-source-pin.py'));
		assert.ok(preparation.includes('read-native-source-pin.py'));
		assert.equal(
			mac.includes(pins.lua54.sha256),
			false,
			'the download owner must read the shared pin'
		);
		for (const source of ['luv', 'lfs']) {
			assert.equal(
				preparation.includes(pins[source].revision),
				false,
				'Git pins have one download owner'
			);
		}
		checks++;
		const malformed = path.join(scratch, 'malformed');
		fs.mkdirSync(malformed);
		const copiedReader = path.join(malformed, 'read-native-source-pin.py');
		fs.copyFileSync(reader, copiedReader);
		const cases = [
			(data) => {
				delete data.lua54.sha256;
			},
			(data) => {
				data.lua54.extra = 'unknown';
			},
			(data) => {
				data.extra = {};
			},
			(data) => {
				data.lua54.sha256 = '0';
			},
			(data) => {
				data.lua54.url = 'https://example.invalid/lua.tar.gz';
			},
			(data) => {
				data.luv.revision = 'latest';
			},
			(data) => {
				data.lfs.repository = 'https://github.com/';
			},
			(data) => {
				data.lua54.version += '\n';
			}
		];
		for (const change of cases) {
			const data = structuredClone(pins);
			change(data);
			fs.writeFileSync(path.join(malformed, 'native-source-pins.json'), JSON.stringify(data));
			const result = readPin(copiedReader, 'lua54', 'version');
			assert.equal(result.error, undefined);
			assert.notEqual(result.status, 0, 'a malformed source contract must refuse before download');
			assert.equal(result.stdout, '');
			checks++;
		}
		fs.writeFileSync(
			path.join(malformed, 'native-source-pins.json'),
			fs.readFileSync(pinFile, 'utf8').replace('"version":', '"version":"ignored","version":')
		);
		assert.notEqual(
			readPin(copiedReader, 'lua54', 'version').status,
			0,
			'duplicate fields must refuse'
		);
		assert.notEqual(
			readPin(reader, 'lua54', 'unknown').status,
			0,
			'unknown query fields must refuse'
		);
		checks += 2;
		// Execute the actual authored destination guards. AND lists under errexit
		// must not let incumbent files or links reach a later installation.
		const buildSource = fs.readFileSync(
			path.join(ROOT, 'tools/test/build-linux-distro-lua54.sh'),
			'utf8'
		);
		const interpreterStart = 'stock_interpreter=/usr/bin/lua5.4\n';
		assert.equal(
			buildSource.split(interpreterStart).length,
			2,
			'one interpreter installation owner is required'
		);
		const interpreterGuard = buildSource.slice(
			buildSource.indexOf(interpreterStart) + interpreterStart.length,
			buildSource.indexOf('pin_reader=')
		);
		const moduleAssignment = buildSource.match(/stock_module="\$[\s\S]*?\n'\)"\n/g);
		assert.equal(
			moduleAssignment?.length,
			1,
			'one genuine interpreter module-site query is required'
		);
		const moduleGuard = buildSource.slice(
			buildSource.indexOf(moduleAssignment[0]) + moduleAssignment[0].length,
			buildSource.indexOf('mkdir -p "$(dirname "$stock_module")"')
		);
		for (const [variable, guard] of [
			['stock_interpreter', interpreterGuard],
			['stock_module', moduleGuard]
		]) {
			assert.ok(guard.trim(), `${variable}: the actual guard must exist`);
			for (const mode of ['absent', 'file', 'link', 'dangling']) {
				const owned = path.join(scratch, variable + '-' + mode);
				fs.mkdirSync(owned);
				const destination = path.join(owned, 'destination');
				const target = path.join(owned, 'owned-source');
				const marker = path.join(owned, 'install-marker');
				fs.writeFileSync(target, 'untouched target bytes', { mode: 0o600 });
				if (mode === 'file')
					fs.writeFileSync(destination, 'untouched destination bytes', { mode: 0o600 });
				if (mode === 'link' || mode === 'dangling')
					fs.symlinkSync(mode === 'link' ? 'owned-source' : 'missing-source', destination);
				const before = mode === 'absent' ? null : fs.lstatSync(destination);
				const script = path.join(owned, 'actual-guard.sh');
				fs.writeFileSync(
					script,
					`set -euo pipefail\n${variable}="$1"\n${guard}\nprintf installed > "$2"\n`
				);
				const result = spawnSync(
					bashExecutable(),
					[bashPath(script), bashPath(destination), bashPath(marker)],
					{ encoding: 'utf8', timeout: 5000 }
				);
				assert.equal(result.error, undefined, `${variable}/${mode}: actual guard must finish`);
				if (mode === 'absent') {
					assert.equal(result.status, 0, result.stderr);
					assert.equal(fs.readFileSync(marker, 'utf8'), 'installed');
					assert.equal(fs.existsSync(destination), false);
				} else {
					assert.notEqual(
						result.status,
						0,
						`${variable}/${mode}: incumbent must refuse before install`
					);
					assert.equal(
						fs.existsSync(marker),
						false,
						`${variable}/${mode}: installation must not execute`
					);
					assert.equal(fs.lstatSync(destination).mode, before.mode);
					if (mode === 'file')
						assert.equal(fs.readFileSync(destination, 'utf8'), 'untouched destination bytes');
					else
						assert.equal(
							fs.readlinkSync(destination),
							mode === 'link' ? 'owned-source' : 'missing-source'
						);
				}
				assert.equal(fs.readFileSync(target, 'utf8'), 'untouched target bytes');
				checks++;
			}
		}
		console.log(
			`Linux native unit prerequisites: ${checks} executed dispatch/refusal controls; 0 skipped.`
		);
		return checks;
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
}

// POSIX filename bytes must reach every authored Bash boundary unchanged.
// Windows cannot create these component names; its ordinary path keeps the
// existing Git Bash drive conversion and executes the same complete controls.
const scratchRoot = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-unit-prerequisites-'));
try {
	const prefixes =
		process.platform === 'win32'
			? ['ordinary']
			: ['ordinary', 'literal\\backslash', 'literal\nlinefeed'];
	let controls = 0;
	for (const prefix of prefixes) {
		const scratch = path.join(scratchRoot, prefix);
		fs.mkdirSync(scratch);
		controls += runControls(scratch);
		console.log(`Native prerequisite path ${JSON.stringify(prefix)}: complete controls passed.`);
	}
	console.log(
		`Native prerequisite paths: ${prefixes.length} physical prefixes; ${controls} executed controls; 0 skipped.`
	);
} finally {
	fs.rmSync(scratchRoot, { recursive: true, force: true });
}
