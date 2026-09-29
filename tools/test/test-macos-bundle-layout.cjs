// tools/test/test-macos-bundle-layout.cjs

/**
 * ==============================================================================
 * MODULE: macOS Bundle-Layout Guard
 * DESCRIPTION:
 * Regression guard for the .app bundle's internal driver layout. The
 * static/drivers -> static/ergopti_plus reorg migrated the Lua code to expect
 * the driver at static/ergopti_plus/macos (guarded by the Lua suite's
 * test_download_window_assets_dir and test_config_repo_root), but the macOS
 * packaging kept shipping the driver under the legacy
 * Contents/Resources/static/drivers/hammerspoon prefix. That divergence meant
 * hs.configdir-relative resolution and every gsub("/static/ergopti_plus/macos$")
 * only worked via resilient fallbacks in the bundle, silently differing from a
 * dev checkout.
 *
 * ROOT CAUSE ENCODED:
 * The bundle must mirror the repo layout exactly: the payload manifest
 * (tools/build/macos-bundle-manifest.json, staged by build_macos_app.sh into
 * Contents/Resources/static) maps the driver to static/ergopti_plus/macos and
 * _shared to static/ergopti_plus/_shared, and main.swift points MJConfigDir at
 * the same path. This guard fails if either reverts to the legacy drivers/
 * prefix or the two stop agreeing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const build = read('tools/build/build_macos_app.sh');
const manifest = JSON.parse(read('tools/build/macos-bundle-manifest.json'));
const swift = read('static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/main.swift');

const errors = [];

// 1. The build script must not bundle under the legacy drivers/ prefix...
if (/drivers\/hammerspoon/.test(build)) {
	errors.push(
		'build_macos_app.sh: still bundles the driver under drivers/hammerspoon — must be ergopti_plus/macos.'
	);
}
if (/drivers\/_shared/.test(build)) {
	errors.push(
		'build_macos_app.sh: still bundles _shared under drivers/_shared — must be ergopti_plus/_shared.'
	);
}
// ...and the payload manifest must place both at the repo-mirroring location,
// below the Contents/Resources/static root the build stages it into.
const mirrors = (source, target) =>
	manifest.trees.some((tree) => tree.source === source && tree.target === target);
if (!mirrors('static/ergopti_plus/macos', 'ergopti_plus/macos')) {
	errors.push(
		'macos-bundle-manifest.json: must map static/ergopti_plus/macos to ergopti_plus/macos.'
	);
}
if (!mirrors('static/ergopti_plus/_shared', 'ergopti_plus/_shared')) {
	errors.push(
		'macos-bundle-manifest.json: must map static/ergopti_plus/_shared to ergopti_plus/_shared.'
	);
}
if (
	!build.includes('local static_root="$res/static"') ||
	!build.includes('local res="$APP_PATH/Contents/Resources"') ||
	!build.includes('macos-bundle-payload.cjs" stage "$REPO_ROOT" "$static_root"')
) {
	errors.push(
		'build_macos_app.sh: must stage the payload manifest into Contents/Resources/static.'
	);
}

// 2. The Swift launcher's MJConfigDir must agree with that layout.
if (/static\/drivers\/hammerspoon/.test(swift)) {
	errors.push(
		'main.swift: still points the bundled config dir at static/drivers/hammerspoon — must be static/ergopti_plus/macos.'
	);
}
if (!/static\/ergopti_plus\/macos/.test(swift)) {
	errors.push('main.swift: must point the bundled config dir at static/ergopti_plus/macos.');
}

// 3. Every bundled tool the launcher points the driver at must be one the build
// creates, and every launcher key the boot trail reports must still be exported:
// the launcher kept exporting ERGOPTI_KARABINER_INSTALLER, and the boot trail
// kept reporting it present, after the build stopped vendoring that installer.
const launcherSources = path.join(ROOT, 'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus');
const launcherSwift = fs
	.readdirSync(launcherSources)
	.filter((name) => name.endsWith('.swift'))
	.map((name) => fs.readFileSync(path.join(launcherSources, name), 'utf8'))
	.join('\n');
const launcherTools = [
	...launcherSwift.matchAll(/Contents\/Resources\/Tools\/([A-Za-z0-9_-]+)\//g)
].map((match) => match[1]);
// The app now bundles no tool at all (Karabiner-Elements and Ollama are both
// installed on demand), so an empty scan is proven rather than blind only while
// the build creates no Tools folder either.
if (launcherTools.length === 0 && /\$tools_dir\b|Resources\/Tools\/[A-Za-z]/.test(build)) {
	errors.push(
		'main.swift points at no Contents/Resources/Tools path while build_macos_app.sh still ' +
			'bundles one; the tool scan went blind.'
	);
}
for (const tool of new Set(launcherTools)) {
	if (!build.includes(`"$tools_dir/${tool}/`)) {
		errors.push(
			`launcher: points at Contents/Resources/Tools/${tool}, which build_macos_app.sh never bundles.`
		);
	}
}
const environmentLua = read('static/ergopti_plus/macos/infra/launcher_environment.lua');
const reportedKeys = [...environmentLua.matchAll(/^\t"(ERGOPTI_[A-Z_]+)",$/gm)].map(
	(match) => match[1]
);
if (reportedKeys.length === 0) {
	errors.push('launcher_environment.lua: no exported key found; the key scan went blind.');
}
for (const key of reportedKeys) {
	if (!launcherSwift.includes(`"${key}"`)) {
		errors.push(`launcher_environment.lua: reports ${key}, which the Swift launcher never sets.`);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] macOS bundle layout diverges from the repo layout:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] macOS .app bundle mirrors the static/ergopti_plus layout (build script + launcher agree).\x1b[0m'
);
