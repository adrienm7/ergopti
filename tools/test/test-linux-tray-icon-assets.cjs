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
const os = require('os');
const { spawnSync } = require('child_process');
const { bashExecutable } = require('../lib/git-bash.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const PAIRS = [
	['static/ergopti_plus/_shared/assets/ergopti_tray.png', 'static/img/logo/logo_simple.png'],
	[
		'static/ergopti_plus/_shared/assets/ergopti_tray_paused.png',
		'static/img/logo/logo_simple_disabled.png'
	]
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

// Execute each actual packaging icon section in an isolated staging tree. File
// presence alone accepted both an empty RPM icon and the invisible 1x1 PNGs.
const sandbox = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-launcher-icons-'));
try {
	const logo = fs.readFileSync(path.join(ROOT, PAIRS[0][0]));
	fs.mkdirSync(path.join(sandbox, '_shared', 'assets'), { recursive: true });
	fs.writeFileSync(path.join(sandbox, '_shared', 'assets', 'ergopti_tray.png'), logo);
	for (const format of ['deb', 'rpm', 'appimage']) {
		const source = fs.readFileSync(path.join(ROOT, `tools/build/build-linux-${format}.sh`), 'utf8');
		const section = source.match(
			/^# (?:\d+\. )?(?:Placeholder|Application) icon\n(?:# -+\n)?([\s\S]*?)(?=\n# -{10,})/m
		);
		if (!section) throw new Error(`Missing ${format} icon packaging section`);
		const stage = path.join(sandbox, format);
		for (const size of ['128x128', '512x512']) {
			fs.mkdirSync(path.join(stage, 'usr/share/icons/hicolor', size, 'apps'), { recursive: true });
		}
		const script = path.join(sandbox, `${format}.sh`);
		fs.writeFileSync(script, section[1]);
		const result = spawnSync(bashExecutable(), ['-eu', script.replaceAll('\\', '/')], {
			encoding: 'utf8',
			env: {
				...process.env,
				BUILD_DIR: sandbox.replaceAll('\\', '/'),
				DEB_ROOT: stage.replaceAll('\\', '/'),
				INSTALL_ROOT: stage.replaceAll('\\', '/'),
				APPDIR: stage.replaceAll('\\', '/')
			}
		});
		if (result.status !== 0)
			throw new Error(`${format} icon staging failed: ${result.error || result.stderr}`);
		const icon =
			format === 'appimage'
				? path.join(stage, 'ergopti.png')
				: path.join(stage, 'usr/share/icons/hicolor/512x512/apps/ergopti.png');
		if (!fs.existsSync(icon) || !fs.readFileSync(icon).equals(logo)) {
			failures.push(`${format} launcher must ship the real 512x512 Ergopti logo`);
		}
	}
} finally {
	fs.rmSync(sandbox, { recursive: true, force: true });
}

if (failures.length > 0) {
	console.error('\x1b[31m[ERROR] Linux tray icon assets drifted:\x1b[0m');
	for (const failure of failures) console.error(`    - ${failure}`);
	process.exit(1);
}
console.log(`\x1b[32m[OK] ${PAIRS.length} Linux tray icon(s) match the logo they mirror.\x1b[0m`);
