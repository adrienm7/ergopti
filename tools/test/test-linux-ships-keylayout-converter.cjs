// tools/test/test-linux-ships-keylayout-converter.cjs

/**
 * ==============================================================================
 * MODULE: Linux Package Ships the .keylayout Converter
 * DESCRIPTION:
 * A registry layout reaches Linux as its macOS .keylayout only; the XKB files
 * are produced on the user's machine by static/ergopti/linux/xkb_generation/
 * keylayout_to_xkb.py, run by modules/keymap/layout_registry.lua. This guard pins the
 * three places that must agree for that to work in an installed package:
 *   1. the Linux build copies the converter into linux/xkb_generation/ and its
 *      integrity check requires the converter and EVERY data file it reads
 *      (discovered from the converter source, not listed by hand here);
 *   2. the Lua module looks for the converter at that packaged path first, and
 *      its source-checkout candidate resolves to the real converter;
 *   3. the Lua pieces and shared data of the transaction ship as well;
 *   4. the user XKB installer ships with every local module it imports
 *      (discovered from its imports), where the Lua module looks for it;
 *   5. the registry folder ships where the Lua module looks for it, so the
 *      Ergopti layouts install offline.
 * ==============================================================================
 */

'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const CONVERTER_DIR = 'static/ergopti/linux/xkb_generation';
const CONVERTER = `${CONVERTER_DIR}/keylayout_to_xkb.py`;
const BUILD = 'tools/build/build-linux-driver.sh';
const LUA_MODULE = 'static/ergopti_plus/linux/modules/keymap/layout_registry.lua';
const PACKAGED_DIR = 'linux/xkb_generation';
const INSTALLER_DIR = 'static/ergopti/linux/xkb_installation';
const INSTALLER = `${INSTALLER_DIR}/user_layout_installer.py`;
const PACKAGED_INSTALLER_DIR = 'linux/xkb_installation';
const LAYOUT_DEFAULTS = JSON.parse(read('static/ergopti_plus/_shared/modules/layouts/defaults.json'));

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

/** Data files the converter opens through DATA_DIR. */
function converterDataFiles() {
	const names = [...read(CONVERTER).matchAll(/DATA_DIR\s*\/\s*"([^"]+)"/g)].map((m) => m[1]);
	return [...new Set(names)];
}

console.log('Linux package ships the .keylayout converter');

const build = read(BUILD);
const required = requiredFiles(build);

check('the build copies the converter tree into the driver', () => {
	const copy = /copy_tree\s+"\$\{REPO_ROOT\}\/static\/ergopti\/linux\/xkb_generation\/"\s+"\$\{BUILD_DIR\}\/linux\/xkb_generation\/"([^\n]*)/.exec(build);
	assert.ok(copy, `${BUILD} must copy ${CONVERTER_DIR}/ into \${BUILD_DIR}/${PACKAGED_DIR}/`);
	assert.ok(!/--exclude\s+data\b/.test(copy[1]), 'the converter data must not be excluded');
});

check('the integrity check requires the converter and every data file it reads', () => {
	const data = converterDataFiles();
	assert.ok(data.length >= 3, `found only ${data.length} DATA_DIR file(s) in the converter`);
	for (const name of data) {
		assert.ok(fs.existsSync(path.join(ROOT, CONVERTER_DIR, 'data', name)), `data/${name} is not in the repository`);
	}
	const missing = [`${PACKAGED_DIR}/keylayout_to_xkb.py`, ...data.map((name) => `${PACKAGED_DIR}/data/${name}`)]
		.filter((file) => !required.includes(file));
	assert.deepStrictEqual(missing, [], 'REQUIRED_FILES lacks these converter files');
});

check('the Lua pieces and shared data of the conversion ship', () => {
	const expected = [
		'linux/modules/keymap/layout_registry.lua',
		'linux/adapters/process_runner.lua',
		'_shared/lua/layouts/registry.lua',
		'_shared/lua/layouts/catalogue.lua',
		'_shared/modules/layouts/defaults.json',
		'_shared/modules/layouts/mac_keycodes.json'
	];
	const missing = expected.filter((file) => !required.includes(file));
	assert.deepStrictEqual(missing, [], 'REQUIRED_FILES lacks these files');
});

check('the Lua module looks where the package and the source tree put the converter', () => {
	const source = read(LUA_MODULE);
	const block = /CONVERTER_CANDIDATES\s*=\s*\{([\s\S]*?)\}/.exec(source);
	assert.ok(block, `${LUA_MODULE} declares no CONVERTER_CANDIDATES`);
	const candidates = [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
	assert.strictEqual(candidates.length, 2, 'a packaged and a source-checkout candidate are expected');
	assert.strictEqual(`linux/${candidates[0]}`, `${PACKAGED_DIR}/keylayout_to_xkb.py`,
		'the first candidate must be where the build puts the converter');
	const fromDriver = path.resolve(ROOT, 'static/ergopti_plus/linux', candidates[1]);
	assert.strictEqual(fromDriver, path.join(ROOT, CONVERTER), 'the source candidate must resolve to the real converter');
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

check('the build ships the user XKB installer with every module it imports', () => {
	const modules = installerModules();
	assert.ok(modules.length >= 3, `found only ${modules.length} installer module(s)`);
	for (const name of modules) {
		assert.ok(new RegExp(`/static/ergopti/linux/xkb_installation/${name}\\.py"`).test(build),
			`${BUILD} must copy ${name}.py into \${BUILD_DIR}/${PACKAGED_INSTALLER_DIR}/`);
	}
	const missing = modules.map((name) => `${PACKAGED_INSTALLER_DIR}/${name}.py`).filter((f) => !required.includes(f));
	assert.deepStrictEqual(missing, [], 'REQUIRED_FILES lacks these installer files');
});

check('the Lua module looks where the package and the source tree put the installer', () => {
	const source = read(LUA_MODULE);
	const block = /INSTALLER_CANDIDATES\s*=\s*\{([\s\S]*?)\}/.exec(source);
	assert.ok(block, `${LUA_MODULE} declares no INSTALLER_CANDIDATES`);
	const candidates = [...block[1].matchAll(/"([^"]+)"/g)].map((m) => m[1]);
	assert.strictEqual(candidates.length, 2, 'a packaged and a source-checkout candidate are expected');
	assert.strictEqual(`linux/${candidates[0]}`, `${PACKAGED_INSTALLER_DIR}/user_layout_installer.py`);
	const fromDriver = path.resolve(ROOT, 'static/ergopti_plus/linux', candidates[1]);
	assert.strictEqual(fromDriver, path.join(ROOT, INSTALLER), 'the source candidate must resolve to the real installer');
});

check('the build ships the registry folder where the Lua module looks for it', () => {
	const folder = LAYOUT_DEFAULTS.registry.folder;
	assert.ok(new RegExp(`copy_tree\\s+"\\$\\{REPO_ROOT\\}/${folder}/"\\s+"\\$\\{BUILD_DIR\\}/linux/${folder}/"`).test(build),
		`${BUILD} must copy ${folder}/ into \${BUILD_DIR}/linux/${folder}/`);
	assert.ok(required.includes(`linux/${folder}/${LAYOUT_DEFAULTS.registry.index_file}`),
		'REQUIRED_FILES must require the shipped registry index');
	const source = read(LUA_MODULE);
	assert.ok(source.includes('driver_root .. "/" .. settings.folder'), 'the packaged candidate is <driver>/<folder>');
	assert.ok(source.includes('driver_root .. "/../../../" .. settings.folder'), 'the checkout candidate is the repository folder');
});

if (failures > 0) process.exit(1);
console.log('All converter packaging checks passed.');
