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

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] launcher Info.plist is missing the single-instance guard:\x1b[0m');
	for (const e of errors) console.error('  - ' + e);
	process.exit(1);
}
console.log('\x1b[32m[OK] launcher Info.plist declares LSMultipleInstancesProhibited (F-MED-29).\x1b[0m');
