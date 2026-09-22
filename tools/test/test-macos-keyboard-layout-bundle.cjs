// tools/test/test-macos-keyboard-layout-bundle.cjs

/**
 * ==============================================================================
 * MODULE: macOS Keyboard Layout Bundle Packaging Guard
 * DESCRIPTION:
 * The packaged ErgoptiPlus.app must ship the Ergopti keyboard layout bundle at
 * the path its "Keyboard layout" menu resolves.
 *
 * ROOT CAUSE ENCODED:
 * ui/menu/menu_keyboard_layout.lua resolves BUNDLES_RELDIR against the driver
 * root (static/ergopti_plus/macos/), which lands on static/ergopti/macos/bundles/.
 * build_macos_app.sh mirrored the driver and the shared tree but never that
 * directory, so the packaged menu could only say "No Ergopti bundle found" and
 * its active-list row printed "v? → v?".
 *
 * FEATURES & RATIONALE:
 * 1. The menu's relative path is resolved here, and the build function must
 *    copy into exactly that location of the packaged static tree.
 * 2. The build function is extracted from the script and run for real against
 *    fixture repositories: it must pick the numerically highest version, copy
 *    it, and fail when no bundle exists.
 * 3. The function must be called from assemble_app, or it proves nothing.
 * 4. The repository must hold at least one bundle with an Info.plist to ship.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD_REL = 'tools/build/build_macos_app.sh';
const MENU_REL = 'static/ergopti_plus/macos/ui/menu/menu_keyboard_layout.lua';
const DRIVER_REL = 'static/ergopti_plus/macos/';
const SOURCE_BUNDLES_REL = 'static/ergopti/macos/bundles';

const errors = [];
const build = fs.readFileSync(path.join(ROOT, BUILD_REL), 'utf8');
const menu = fs.readFileSync(path.join(ROOT, MENU_REL), 'utf8');

// 1. Resolve the menu's bundles path from the driver root.
const relMatch = menu.match(/^local BUNDLES_RELDIR = "([^"]+)"/m);
let resolvedRel = null;
if (!relMatch) {
	errors.push(`${MENU_REL}: BUNDLES_RELDIR declaration not found.`);
} else {
	resolvedRel = path.posix.normalize(DRIVER_REL + relMatch[1]).replace(/\/$/, '');
	if (resolvedRel !== SOURCE_BUNDLES_REL) {
		errors.push(`${MENU_REL}: BUNDLES_RELDIR resolves to ${resolvedRel}, expected ${SOURCE_BUNDLES_REL}.`);
	}
}

// 2. Extract the packaging function; assemble_app must call it.
const fnMatch = build.match(/^bundle_keyboard_layout\(\) \{\n[\s\S]*?\n\}\n/m);
if (!fnMatch) {
	errors.push(`${BUILD_REL}: bundle_keyboard_layout() not found.`);
}
const assembleMatch = build.match(/^assemble_app\(\) \{\n[\s\S]*?\n\}\n/m);
if (!assembleMatch || !/^\tbundle_keyboard_layout "\$static_root"$/m.test(assembleMatch[0])) {
	errors.push(`${BUILD_REL}: assemble_app() must call bundle_keyboard_layout "$static_root".`);
}

// 3. The repository must hold something to ship.
const sourceDir = path.join(ROOT, SOURCE_BUNDLES_REL);
const shipped = fs.existsSync(sourceDir)
	? fs.readdirSync(sourceDir).filter((name) => /^Ergopti_v[\d.]+\.bundle$/.test(name)
		&& fs.existsSync(path.join(sourceDir, name, 'Contents', 'Info.plist')))
	: [];
if (shipped.length === 0) {
	errors.push(`${SOURCE_BUNDLES_REL}: no Ergopti_v*.bundle with an Info.plist to package.`);
}

/**
 * Runs the extracted build function against a fixture repository.
 * @param {string[]} versions Bundle versions present in the fixture.
 * @returns {{status: number|null, staticRoot: string, output: string}}
 */
function runPackaging(versions) {
	const fixture = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-layout-bundle-'));
	const bundles = path.join(fixture, 'repo', SOURCE_BUNDLES_REL);
	fs.mkdirSync(bundles, { recursive: true });
	for (const version of versions) {
		const contents = path.join(bundles, `Ergopti_v${version}.bundle`, 'Contents');
		fs.mkdirSync(contents, { recursive: true });
		fs.writeFileSync(path.join(contents, 'Info.plist'), version);
	}
	const staticRoot = path.join(fixture, 'app', 'static');
	fs.mkdirSync(staticRoot, { recursive: true });
	const script = [
		'set -euo pipefail',
		'log() { :; }',
		'fail() { printf "FAIL: %s\\n" "$*" >&2; exit 1; }',
		fnMatch[0],
		'bundle_keyboard_layout "$1"',
	].join('\n');
	const result = spawnSync('bash', ['-c', script, 'fixture', staticRoot.replace(/\\/g, '/')], {
		encoding: 'utf8',
		env: { ...process.env, REPO_ROOT: path.join(fixture, 'repo').replace(/\\/g, '/') },
	});
	if (result.error) throw result.error;
	return { status: result.status, staticRoot, output: `${result.stdout}${result.stderr}`, fixture };
}

if (fnMatch && resolvedRel) {
	const packaged = runPackaging(['2.2.9', '2.2.10', '2.1.0']);
	const destination = path.join(packaged.staticRoot, 'ergopti', 'macos', 'bundles');
	const copied = fs.existsSync(destination) ? fs.readdirSync(destination) : [];
	if (packaged.status !== 0) {
		errors.push(`bundle_keyboard_layout failed on a valid fixture: ${packaged.output.trim()}`);
	} else if (copied.join(',') !== 'Ergopti_v2.2.10.bundle') {
		errors.push(`bundle_keyboard_layout must package only the highest version (2.2.10), packaged: [${copied.join(', ')}].`);
	} else if (!fs.existsSync(path.join(destination, 'Ergopti_v2.2.10.bundle', 'Contents', 'Info.plist'))) {
		errors.push('bundle_keyboard_layout packaged the bundle without its Info.plist.');
	}
	fs.rmSync(packaged.fixture, { recursive: true, force: true });

	const empty = runPackaging([]);
	if (empty.status === 0) {
		errors.push('bundle_keyboard_layout must fail when no Ergopti_v*.bundle exists.');
	}
	fs.rmSync(empty.fixture, { recursive: true, force: true });
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] The packaged app does not ship the keyboard layout bundle its menu needs:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] build_macos_app.sh packages the newest keyboard layout bundle where the menu resolves it.\x1b[0m');
