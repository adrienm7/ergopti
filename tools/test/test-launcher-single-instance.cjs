// tools/test/test-launcher-single-instance.cjs

/**
 * ==============================================================================
 * MODULE: Launcher Single-Instance Guard
 * DESCRIPTION:
 * Regression guard for F-MED-29 — the generated Info.plist carried no
 * LSMultipleInstancesProhibited key, so two ErgoptiPlus launches could spawn
 * two competing embedded Hammerspoon children with no cross-process lock of
 * any kind (fighting eventtaps, duplicate Karabiner bridges, doubled hotstring
 * expansions).
 *
 * ROOT CAUSE ENCODED:
 * generate_info_plist() in tools/build/build_macos_app.sh builds the launcher's
 * Info.plist from scratch via a heredoc (no static template — see the function's
 * own docstring for why). This guard fails if that heredoc stops declaring
 * <key>LSMultipleInstancesProhibited</key><true/>.
 *
 * The embedded Hammerspoon must also have a bundle identifier distinct from
 * the already-running outer launcher. Giving both processes the same identity
 * caused macOS to terminate the child cleanly during bootstrap, before it
 * loaded init.lua, so the release smoke test saw no Lua log and exit code 0.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const read = (rel) => fs.readFileSync(path.join(ROOT, rel), 'utf8');

const build = read('tools/build/build_macos_app.sh');
const constants = read(
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/LauncherConstants.swift'
);
const launcher = read(
	'static/ergopti_plus/macos/launcher/Sources/ErgoptiPlus/main.swift'
);

const errors = [];

// The key must be present and paired with <true/> — a present-but-false key
// would defeat the guard just as silently as an absent one.
const keyMatch = build.match(/<key>LSMultipleInstancesProhibited<\/key>\s*<(true|false)\/>/);

if (!keyMatch) {
	errors.push(
		'build_macos_app.sh: generate_info_plist() must declare ' +
		'<key>LSMultipleInstancesProhibited</key><true/> so two launches cannot ' +
		'spawn two competing embedded Hammerspoon children (F-MED-29).'
	);
} else if (keyMatch[1] !== 'true') {
	errors.push(
		'build_macos_app.sh: LSMultipleInstancesProhibited must be <true/>, found <' + keyMatch[1] + '/>.'
	);
}

const outerId = build.match(/^BUNDLE_ID="([^"]+)"$/m)?.[1];
const embeddedId = build.match(/^HAMMERSPOON_BUNDLE_ID="([^"]+)"$/m)?.[1];
const swiftEmbeddedId = constants.match(
	/^let kEmbeddedHammerspoonBundleId = "([^"]+)"$/m
)?.[1];

if (!outerId || !embeddedId) {
	errors.push('build_macos_app.sh must declare outer and embedded Hammerspoon bundle IDs.');
} else if (outerId === embeddedId) {
	errors.push(
		'the embedded Hammerspoon bundle ID must differ from the running launcher ID; ' +
		'sharing one identity makes macOS terminate the child before init.lua loads.'
	);
}
if (!/plutil -replace CFBundleIdentifier -string "\$HAMMERSPOON_BUNDLE_ID" "\$hs_plist"/.test(build)) {
	errors.push('the embedded Hammerspoon Info.plist must use HAMMERSPOON_BUNDLE_ID.');
}
if (!embeddedId || swiftEmbeddedId !== embeddedId) {
	errors.push('Swift CFPreferences and the build script must use the same embedded Hammerspoon bundle ID.');
}
const preferenceDomainUses = launcher.match(/kEmbeddedHammerspoonBundleId as CFString/g) || [];
if (preferenceDomainUses.length !== 3) {
	errors.push(
		'main.swift must write and synchronize both early and normal Hammerspoon preferences ' +
		'under kEmbeddedHammerspoonBundleId (expected 3 domain uses).'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] macOS launcher/runtime instance isolation is broken:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log(
	'\x1b[32m[OK] launcher is single-instance and the embedded Hammerspoon identity is isolated.\x1b[0m'
);
