// tools/test/test-linux-tray-icon-assets.cjs

/**
 * ==============================================================================
 * MODULE: Linux Tray Icon Assets Guard
 * DESCRIPTION:
 * The Linux tray shows _shared/assets/ergopti_tray{,_paused}.png. They are byte
 * copies of static/img/logo/logo_simple{,_disabled}.png — the logo the macOS
 * menu bar and the Windows tray draw — kept in _shared because every Linux
 * package format ships that tree and none ships static/img.
 *
 * ROOT CAUSE ENCODED:
 * The tray resolved its icon from an assets directory that did not exist, so
 * every Linux user saw a generic keyboard glyph. A copy is only acceptable if it
 * cannot drift: this guard fails when either copy is missing, is not a PNG, or
 * differs from the logo it mirrors.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const PAIRS = [
	['static/ergopti_plus/_shared/assets/ergopti_tray.png', 'static/img/logo/logo_simple.png'],
	['static/ergopti_plus/_shared/assets/ergopti_tray_paused.png', 'static/img/logo/logo_simple_disabled.png'],
];
const PNG_MAGIC = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);

const failures = [];
for (const [copy, original] of PAIRS) {
	const copyPath = path.join(ROOT, copy);
	const originalPath = path.join(ROOT, original);
	if (!fs.existsSync(copyPath)) {
		failures.push(`${copy} is missing — the Linux tray falls back to a generic glyph`);
		continue;
	}
	const bytes = fs.readFileSync(copyPath);
	if (!bytes.subarray(0, 8).equals(PNG_MAGIC)) {
		failures.push(`${copy} is not a PNG`);
	}
	if (!bytes.equals(fs.readFileSync(originalPath))) {
		failures.push(`${copy} differs from ${original} — re-copy the logo`);
	}
}

if (failures.length > 0) {
	console.error('\x1b[31m[ERROR] Linux tray icon assets drifted:\x1b[0m');
	for (const failure of failures) console.error(`    - ${failure}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] ${PAIRS.length} Linux tray icon(s) match the logo they mirror.\x1b[0m`);
