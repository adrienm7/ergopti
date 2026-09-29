// tools/test/test-macos-launcher-localizations.cjs

/**
 * ==============================================================================
 * MODULE: macOS Launcher Localizations
 * DESCRIPTION:
 * The generated launcher Info.plist declared no localization, so AppKit
 * resolved the application to its development region and every framework it
 * hosts followed: Sparkle's remaining windows stayed English whatever the
 * driver or the system language.
 *
 * ROOT CAUSE ENCODED:
 * 1. generate_info_plist declares CFBundleDevelopmentRegion (en) and a
 *    CFBundleLocalizations array filled by tools/build/launcher_localizations.py;
 * 2. that helper lists every locale of _shared/data/locale_order.json, in
 *    order, in macOS identifiers (no -> nb, zh -> zh-Hans), with no duplicate,
 *    so a language added to the driver is declared without a second edit;
 * 3. every declared localization names a locale catalogue the bundle ships.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..', '..');
const BUILD_SCRIPT = path.join(ROOT, 'tools', 'build', 'build_macos_app.sh');
const HELPER = path.join(ROOT, 'tools', 'build', 'launcher_localizations.py');
const SHARED_DATA = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'data');
const APPLE_IDENTIFIERS = { no: 'nb', zh: 'zh-Hans' };

const failures = [];
let checks = 0;
const expect = (condition, message) => {
	checks += 1;
	if (!condition) failures.push(message);
};

// 1. The plist generator declares the region and the helper's array
const script = fs.readFileSync(BUILD_SCRIPT, 'utf8');
const start = script.indexOf('generate_info_plist() {');
const end = script.indexOf('\n}\n', start);
expect(start !== -1 && end !== -1, 'build_macos_app.sh has no generate_info_plist function');
const generator = script.slice(start, end);
expect(
	/<key>CFBundleDevelopmentRegion<\/key>\s*<string>en<\/string>/.test(generator),
	'the launcher Info.plist must declare CFBundleDevelopmentRegion en'
);
expect(
	/<key>CFBundleLocalizations<\/key>\s*<array>\$LAUNCHER_LOCALIZATIONS<\/array>/.test(generator),
	'the launcher Info.plist must declare the CFBundleLocalizations the helper lists'
);
expect(
	/LAUNCHER_LOCALIZATIONS="\$\(python3 "\$REPO_ROOT\/tools\/build\/launcher_localizations\.py"\)"/.test(
		script
	),
	'the build must read the localizations from tools/build/launcher_localizations.py'
);
expect(
	script.indexOf('LAUNCHER_LOCALIZATIONS=') !== -1 &&
		script.indexOf('LAUNCHER_LOCALIZATIONS=') < start,
	'the localizations must be resolved before the plist is generated'
);

// 2. The helper declares every shipped locale in macOS identifiers
// A Windows checkout usually installs Python as `python`, as the sibling
// Python-backed checks expect
const PYTHON_CANDIDATES = process.platform === 'win32' ? ['python', 'python3'] : ['python3'];
const python = PYTHON_CANDIDATES.find(
	(command) => spawnSync(command, ['--version'], { encoding: 'utf8', timeout: 10000 }).status === 0
);
if (!python) throw new Error('Python is required to run tools/build/launcher_localizations.py');
const run = spawnSync(python, [HELPER], { encoding: 'utf8' });
expect(run.status === 0, `launcher_localizations.py failed: ${(run.stderr || '').trim()}`);
const declared = [...(run.stdout || '').matchAll(/<string>([^<]+)<\/string>/g)].map((m) => m[1]);
const order = JSON.parse(
	fs.readFileSync(path.join(SHARED_DATA, 'locale_order.json'), 'utf8')
).order;
const expected = order.map((code) => APPLE_IDENTIFIERS[code] || code);
expect(order.length === 21, `locale_order.json lists ${order.length} locales, expected 21`);
expect(
	JSON.stringify(declared) === JSON.stringify(expected),
	`the launcher declares ${JSON.stringify(declared)}, expected ${JSON.stringify(expected)}`
);
expect(new Set(declared).size === declared.length, 'a localization is declared twice');
expect(declared.includes('en'), 'the development region must be one of the localizations');

// 3. Every declared localization is a catalogue the bundle ships
const catalogues = new Set(
	fs
		.readdirSync(path.join(SHARED_DATA, 'locales'))
		.filter((name) => name.endsWith('.json'))
		.map((name) => name.replace(/\.json$/, ''))
);
for (const code of order) {
	expect(catalogues.has(code), `the launcher declares ${code}, which has no locale catalogue`);
}
expect(catalogues.size === order.length, 'a shipped catalogue is missing from the declared list');

if (failures.length) {
	console.error(
		`\x1b[31m[ERROR] macOS launcher localizations: ${failures.length} failure(s) in ${checks} check(s):\x1b[0m`
	);
	for (const failure of failures) console.error(`  - ${failure}`);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] the launcher declares its development region and all ${declared.length} driver languages (${checks} checks).\x1b[0m`
);
