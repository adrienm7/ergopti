// tools/test/test-linux-ships-keylayout-converter.cjs

/**
 * ==============================================================================
 * MODULE: Linux Package Ships the .keylayout Converter
 * DESCRIPTION:
 * A registry layout reaches Linux as its macOS .keylayout only; the XKB files
 * are produced on the user's machine, in Lua, by modules/keymap/layout_registry.lua
 * (layouts/keylayout.lua and layouts/xkb_converter.lua) from the data files of
 * static/ergopti/linux/xkb_generation/data. This guard pins the places that must
 * agree for that to work in an installed package:
 *   1. the Linux build stages the conversion data into linux/xkb_generation/
 *      through install/xkb_helpers.sh, and its integrity check requires EVERY
 *      data file the Lua module reads (discovered from the Lua source, not
 *      listed by hand here); the Python converter is not shipped, nothing in
 *      the package runs it;
 *   2. the Lua module looks for the data at that packaged path first, and its
 *      source-checkout candidate resolves to the real data folder;
 *   3. the Lua pieces and shared data of the transaction ship as well;
 *   4. the user XKB installer ships with every local module it imports
 *      (discovered from its imports), where the Lua module looks for it;
 *   5. the registry folder ships where the Lua module looks for it, so the
 *      Ergopti layouts install offline;
 *   6. a checkout install.sh stages the same helpers below the installed
 *      driver and owns them: it used to copy only the driver tree, so every
 *      layout install failed with "the XKB conversion data is not shipped".
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const childProcess = require('child_process');
const crypto = require('crypto');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { bashExecutable, bashPath } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const CONVERTER_DIR = 'static/ergopti/linux/xkb_generation';
const BUILD = 'tools/build/build-linux-driver.sh';
const LUA_MODULE = 'static/ergopti_plus/linux/modules/keymap/layout_registry.lua';
const PACKAGED_DIR = 'linux/xkb_generation';
const INSTALLER_DIR = 'static/ergopti/linux/xkb_installation';
const INSTALLER = `${INSTALLER_DIR}/user_layout_installer.py`;
const PACKAGED_INSTALLER_DIR = 'linux/xkb_installation';
const LAYOUT_DEFAULTS = JSON.parse(read('static/ergopti_plus/_shared/layouts/data/defaults.json'));
const DRIVERS = path.join(ROOT, 'static/ergopti_plus');
const DRIVER = path.join(DRIVERS, 'linux');
const HELPERS = path.join(DRIVER, 'install/xkb_helpers.sh');
const OWNERSHIP = path.join(DRIVER, 'install/ownership.sh');
const INSTALL_SH = 'static/ergopti_plus/linux/install.sh';

/** Quotes one value for Bash. */
function shellQuote(value) {
	return `'${String(value).replaceAll("'", `'"'"'`)}'`;
}

/** Runs Bash lines and returns the child result. */
function bash(lines) {
	return childProcess.spawnSync(bashExecutable(), ['-c', lines.join('\n')], {
		cwd: ROOT,
		encoding: 'utf8'
	});
}

/** Every file below a folder, relative to it, sorted. */
function listFiles(dir) {
	const out = [];
	const walk = (rel) => {
		for (const name of fs.readdirSync(path.join(dir, rel))) {
			const child = rel ? `${rel}/${name}` : name;
			if (fs.statSync(path.join(dir, child)).isDirectory()) walk(child);
			else out.push(child);
		}
	};
	walk('');
	return out.sort();
}

/** Runs the helpers' stage_xkb_helpers into a fresh folder and lists what it wrote. */
function stagedHelpers(scratch) {
	const destination = path.join(scratch, 'staged');
	const result = bash([
		'set -euo pipefail',
		`source ${shellQuote(bashPath(HELPERS))}`,
		`stage_xkb_helpers ${shellQuote(bashPath(path.join(ROOT, 'static/ergopti/linux')))} ${shellQuote(bashPath(destination))}`
	]);
	assert.strictEqual(result.status, 0, `stage_xkb_helpers failed: ${result.stderr}`);
	return listFiles(destination);
}

let failures = 0;
function check(name, fn) {
	try {
		fn();
		console.log(`  ok   ${name}`);
	} catch (err) {
		failures += 1;
		console.error(`  FAIL ${name}\n       ${err.message}`);
	}
}

/** The REQUIRED_FILES array of the build script. */
function requiredFiles(build) {
	const block = /REQUIRED_FILES=\(([\s\S]*?)\n\)/.exec(build);
	assert.ok(block, 'the build script has no REQUIRED_FILES array');
	return [...block[1].matchAll(/^\s*"([^"]+)"/gm)].map((m) => m[1]);
}

/** Data files the Lua manager reads from the conversion data folder. */
function conversionDataFiles() {
	const names = [...read(LUA_MODULE).matchAll(/data_dir\s*\.\.\s*"\/([^"]+)"/g)].map((m) => m[1]);
	return [...new Set(names)];
}

console.log('Linux package ships the .keylayout conversion');

const build = read(BUILD);
const required = requiredFiles(build);

check(
	'the build stages the conversion data into the driver and leaves the Python converter behind',
	() => {
		assert.ok(
			build.includes(
				'source "${LINUX_SRC}/install/xkb_helpers.sh"\nstage_xkb_helpers "${REPO_ROOT}/static/ergopti/linux" "${BUILD_DIR}/linux"'
			),
			`${BUILD} must stage the XKB helpers with install/xkb_helpers.sh`
		);
		const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-xkb-helpers-'));
		try {
			const expected = [
				...conversionDataFiles().map((name) => `xkb_generation/data/${name}`),
				...installerModules().map((name) => `xkb_installation/${name}.py`)
			].sort();
			assert.deepStrictEqual(
				stagedHelpers(scratch),
				expected,
				'the staged helpers are exactly the files the daemon reads, without the Python converter'
			);
		} finally {
			fs.rmSync(scratch, { recursive: true, force: true });
		}
	}
);

check('the integrity check requires every data file the Lua manager reads', () => {
	const data = conversionDataFiles();
	assert.ok(data.length >= 3, `found only ${data.length} data file(s) in the Lua manager`);
	for (const name of data) {
		assert.ok(
			fs.existsSync(path.join(ROOT, CONVERTER_DIR, 'data', name)),
			`data/${name} is not in the repository`
		);
	}
	const missing = data
		.map((name) => `${PACKAGED_DIR}/data/${name}`)
		.filter((file) => !required.includes(file));
	assert.deepStrictEqual(missing, [], 'REQUIRED_FILES lacks these conversion data files');
	assert.ok(
		!required.includes(`${PACKAGED_DIR}/keylayout_to_xkb.py`),
		'REQUIRED_FILES must not require the Python converter the package does not ship'
	);
});

check('the Lua pieces and shared data of the conversion ship', () => {
	const expected = [
		'linux/modules/keymap/layout_registry.lua',
		'linux/core/process/adapters/runner.lua',
		'_shared/layouts/engine/registry/registry_core.lua',
		'_shared/layouts/engine/composer/catalogue.lua',
		'_shared/layouts/engine/composer/keylayout.lua',
		'_shared/layouts/engine/composer/xkb_converter.lua',
		'_shared/layouts/data/defaults.json',
		'_shared/layouts/data/mac_keycodes.json'
	];
	const missing = expected.filter((file) => !required.includes(file));
	assert.deepStrictEqual(missing, [], 'REQUIRED_FILES lacks these files');
});

check('the Lua module looks where the package and the source tree put the conversion data', () => {
	const source = read(LUA_MODULE);
	const block = /CONVERTER_DATA_CANDIDATES\s*=\s*\{([\s\S]*?)\}/.exec(source);
	assert.ok(block, `${LUA_MODULE} declares no CONVERTER_DATA_CANDIDATES`);
	const candidates = [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
	assert.strictEqual(
		candidates.length,
		2,
		'a packaged and a source-checkout candidate are expected'
	);
	assert.strictEqual(
		`linux/${candidates[0]}`,
		`${PACKAGED_DIR}/data`,
		'the first candidate must be where the build puts the data'
	);
	const fromDriver = path.resolve(ROOT, 'static/ergopti_plus/linux', candidates[1]);
	assert.strictEqual(
		fromDriver,
		path.join(ROOT, CONVERTER_DIR, 'data'),
		'the source candidate must resolve to the real data folder'
	);
});

/** The installer and every module of its folder it imports, transitively. */
function installerModules() {
	const seen = new Set();
	const queue = ['user_layout_installer'];
	while (queue.length > 0) {
		const name = queue.shift();
		if (seen.has(name)) continue;
		seen.add(name);
		const source = read(`${INSTALLER_DIR}/${name}.py`);
		for (const match of source.matchAll(/^from\s+([a-z_]+)\s+import/gm)) {
			if (fs.existsSync(path.join(ROOT, INSTALLER_DIR, `${match[1]}.py`))) queue.push(match[1]);
		}
	}
	return [...seen].sort();
}

check('the build requires the user XKB installer with every module it imports', () => {
	const modules = installerModules();
	assert.ok(modules.length >= 3, `found only ${modules.length} installer module(s)`);
	const missing = modules
		.map((name) => `${PACKAGED_INSTALLER_DIR}/${name}.py`)
		.filter((f) => !required.includes(f));
	assert.deepStrictEqual(missing, [], 'REQUIRED_FILES lacks these installer files');
});

check('the Lua module looks where the package and the source tree put the installer', () => {
	const source = read(LUA_MODULE);
	const block = /INSTALLER_CANDIDATES\s*=\s*\{([\s\S]*?)\}/.exec(source);
	assert.ok(block, `${LUA_MODULE} declares no INSTALLER_CANDIDATES`);
	const candidates = [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
	assert.strictEqual(
		candidates.length,
		2,
		'a packaged and a source-checkout candidate are expected'
	);
	assert.strictEqual(
		`linux/${candidates[0]}`,
		`${PACKAGED_INSTALLER_DIR}/user_layout_installer.py`
	);
	const fromDriver = path.resolve(ROOT, 'static/ergopti_plus/linux', candidates[1]);
	assert.strictEqual(
		fromDriver,
		path.join(ROOT, INSTALLER),
		'the source candidate must resolve to the real installer'
	);
});

check('the build ships the registry folder where the Lua module looks for it', () => {
	const folder = LAYOUT_DEFAULTS.registry.folder;
	assert.ok(
		new RegExp(
			`copy_tree\\s+"\\$\\{REPO_ROOT\\}/${folder}/"\\s+"\\$\\{BUILD_DIR\\}/linux/${folder}/"`
		).test(build),
		`${BUILD} must copy ${folder}/ into \${BUILD_DIR}/linux/${folder}/`
	);
	assert.ok(
		required.includes(`linux/${folder}/${LAYOUT_DEFAULTS.registry.index_file}`),
		'REQUIRED_FILES must require the shipped registry index'
	);
	const source = read(LUA_MODULE);
	assert.ok(
		source.includes('driver_root .. "/" .. settings.folder'),
		'the packaged candidate is <driver>/<folder>'
	);
	assert.ok(
		source.includes('driver_root .. "/../../../" .. settings.folder'),
		'the checkout candidate is the repository folder'
	);
});

check('a checkout install.sh ships and owns the XKB helpers below the installed driver', () => {
	const installer = read(INSTALL_SH);
	const resolved = installer.indexOf(
		'SRC_XKB_HELPERS="$(xkb_helpers_source "${SRC_DRIVER}" "${DRIVERS_ROOT}")"'
	);
	assert.ok(resolved >= 0, 'install.sh must resolve the XKB helpers');
	assert.ok(
		resolved < installer.indexOf('install -d "${LIB_DIR}/linux"'),
		'install.sh resolves the helpers before it touches the installation'
	);
	assert.ok(
		installer.includes('stage_xkb_helpers "${SRC_XKB_HELPERS}" "${XKB_HELPERS_STAGE}"'),
		'install.sh must stage the helpers it copies'
	);
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-xkb-checkout-'));
	try {
		const lib = path.join(scratch, 'lib/ergopti');
		const stage = path.join(scratch, 'stage');
		fs.mkdirSync(path.join(lib, 'linux'), { recursive: true });
		// The replay covers the helper resolution, staging and receipt; the
		// driver tree copy itself is test-linux-install-layout-registry.cjs's.
		const replay = bash([
			'set -euo pipefail',
			'sha256sum() { command sha256sum --binary "$@"; }',
			'export -f sha256sum',
			`source ${shellQuote(bashPath(HELPERS))}`,
			`SRC="$(xkb_helpers_source ${shellQuote(bashPath(DRIVER))} ${shellQuote(bashPath(DRIVERS))})"`,
			'[ -n "$SRC" ]',
			`stage_xkb_helpers "$SRC" ${shellQuote(bashPath(stage))}`,
			`cp -r ${shellQuote(bashPath(stage))}/. ${shellQuote(bashPath(path.join(lib, 'linux')))}/`,
			`bash ${shellQuote(bashPath(OWNERSHIP))} ${shellQuote(bashPath(DRIVER))} ` +
				`${shellQuote(bashPath(path.join(DRIVERS, '_shared')))} ${shellQuote(bashPath(lib))} ` +
				`${shellQuote(bashPath(path.join(stage, 'xkb_generation/data')))} linux/xkb_generation/data ` +
				`${shellQuote(bashPath(path.join(stage, 'xkb_installation')))} linux/xkb_installation`
		]);
		assert.strictEqual(replay.status, 0, `the checkout replay failed: ${replay.stderr}`);
		const source = read(LUA_MODULE);
		const dataCandidate = /CONVERTER_DATA_CANDIDATES\s*=\s*\{\s*"([^"]+)"/.exec(source)[1];
		const installerCandidate = /INSTALLER_CANDIDATES\s*=\s*\{\s*"([^"]+)"/.exec(source)[1];
		assert.ok(
			fs.existsSync(path.join(lib, 'linux', dataCandidate, 'key_sym.json')),
			'the installed driver finds its conversion data'
		);
		assert.ok(
			fs.existsSync(path.join(lib, 'linux', installerCandidate)),
			'the installed driver finds its user XKB installer'
		);
		const receipt = new Map(
			fs
				.readFileSync(path.join(lib, '.ergopti-owned-files'), 'utf8')
				.split('\n')
				.filter(Boolean)
				.map((line) => line.split('\t').reverse())
		);
		for (const relative of listFiles(stage)) {
			const digest = crypto
				.createHash('sha256')
				.update(fs.readFileSync(path.join(lib, 'linux', relative)))
				.digest('hex');
			assert.strictEqual(
				receipt.get(`linux/${relative}`),
				digest,
				`the receipt owns linux/${relative}`
			);
		}
		// A driver that already carries them (the tarball's) needs no copy.
		const tarball = bash([
			'set -euo pipefail',
			`source ${shellQuote(bashPath(HELPERS))}`,
			`xkb_helpers_source ${shellQuote(bashPath(path.join(lib, 'linux')))} ${shellQuote(bashPath(scratch))}`
		]);
		assert.strictEqual(tarball.status, 0, tarball.stderr);
		assert.strictEqual(tarball.stdout, '', 'a driver that carries the helpers needs no copy');
		// Neither layout: refused with the reason, before anything is copied.
		const bare = path.join(scratch, 'bare/ergopti_plus/linux');
		fs.mkdirSync(bare, { recursive: true });
		const refused = bash([
			'set -euo pipefail',
			'export LANG=C LC_ALL=',
			`source ${shellQuote(bashPath(HELPERS))}`,
			`xkb_helpers_source ${shellQuote(bashPath(bare))} ${shellQuote(bashPath(path.dirname(bare)))}`
		]);
		assert.notStrictEqual(refused.status, 0, 'a source without the helpers is refused');
		assert.match(refused.stderr, /no keyboard layout can be installed/);
	} finally {
		fs.rmSync(scratch, { recursive: true, force: true });
	}
});

if (failures > 0) process.exit(1);
console.log('All converter packaging checks passed.');
