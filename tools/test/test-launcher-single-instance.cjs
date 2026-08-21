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
if (!outerId || !embeddedId || outerId === embeddedId) {
	errors.push('the single-instance outer app and its embedded GUI runtime need distinct bundle IDs.');
}
if (!/plutil -replace CFBundleIdentifier -string "\$HAMMERSPOON_BUNDLE_ID" "\$hs_plist"/.test(build)) {
	errors.push('the embedded Hammerspoon Info.plist must use HAMMERSPOON_BUNDLE_ID.');
}
if (!embeddedId || swiftEmbeddedId !== embeddedId) {
	errors.push('Swift CFPreferences and the build script must share the embedded runtime bundle ID.');
}
if ((launcher.match(/kEmbeddedHammerspoonBundleId as CFString/g) || []).length !== 3) {
	errors.push('all three Hammerspoon preference-domain uses must target the embedded runtime ID.');
}
for (const inheritedKey of ['__CFBundleIdentifier', 'XPC_SERVICE_NAME']) {
	const escapedKey = inheritedKey.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
	if (!new RegExp(`environment\\.removeValue\\(forKey: "${escapedKey}"\\)`).test(launcher)) {
		errors.push(
			`the embedded GUI child must not inherit the outer Launch Services identity ${inheritedKey}.`
		);
	}
}
if (!/NSWorkspace\.shared\.openApplication\(/.test(launcher)) {
	errors.push('the embedded Hammerspoon GUI must be launched through NSWorkspace.');
}
if (!/embeddedApplicationBundleURL\(binaryPath: binaryPath\)/.test(launcher)) {
	errors.push('Launch Services must receive the embedded .app, not its inner Mach-O.');
}
if (/proc\.executableURL\s*=/.test(launcher)) {
	errors.push('the embedded AppKit GUI must not be executed directly as a Process.');
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] launcher Info.plist is missing the single-instance guard:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] launcher Info.plist declares LSMultipleInstancesProhibited (F-MED-29).\x1b[0m');
