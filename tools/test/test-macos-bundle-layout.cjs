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
 * The bundle must mirror the repo layout exactly: build_macos_app.sh bundles the
 * driver into static/ergopti_plus/macos (and _shared into
 * static/ergopti_plus/_shared), and main.swift points MJConfigDir at the same
 * path. This guard fails if either reverts to the legacy drivers/ prefix or the
 * two stop agreeing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const build = read('tools/build/build_macos_app.sh');
const swift = read('static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/main.swift');

const errors = [];

// 1. The build script must not bundle under the legacy drivers/ prefix...
if (/drivers\/hammerspoon/.test(build)) {
	errors.push('build_macos_app.sh: still bundles the driver under drivers/hammerspoon — must be ergopti_plus/macos.');
}
if (/drivers\/_shared/.test(build)) {
	errors.push('build_macos_app.sh: still bundles _shared under drivers/_shared — must be ergopti_plus/_shared.');
}
// ...and must place both at the repo-mirroring location.
if (!/ergopti_plus\/macos\//.test(build)) {
	errors.push('build_macos_app.sh: must rsync the driver into static/ergopti_plus/macos/.');
}
if (!/ergopti_plus\/_shared/.test(build)) {
	errors.push('build_macos_app.sh: must copy the shared tree into static/ergopti_plus/_shared.');
}

// 2. The Swift launcher's MJConfigDir must agree with that layout.
if (/static\/drivers\/hammerspoon/.test(swift)) {
	errors.push('main.swift: still points the bundled config dir at static/drivers/hammerspoon — must be static/ergopti_plus/macos.');
}
if (!/static\/ergopti_plus\/macos/.test(swift)) {
	errors.push('main.swift: must point the bundled config dir at static/ergopti_plus/macos.');
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] macOS bundle layout diverges from the repo layout:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] macOS .app bundle mirrors the static/ergopti_plus layout (build script + launcher agree).\x1b[0m');
