// tools/test/test-ahk-tray-rows-read-as-text.cjs

/**
 * ==============================================================================
 * MODULE: The Windows Tray Reads As Text
 * DESCRIPTION:
 * Boots the real ErgoptiPlus.ahk in an isolated profile, in French and in
 * English, walks the native tray at ready (tests/fixtures/tray_rows_walker.ahk)
 * and fails on a row whose visible text is an id, a config path, a raw key,
 * snake_case or an unfilled placeholder, or a French row gluing `:`, `?`, `!`
 * or `;` to its word.
 *
 * WHY A BOOT AND NOT A UNIT TEST:
 * The rows that showed `pause_switch_enabled` came from a provider, and a unit
 * fixture only holds the rows its author thought of. This reads the HMENU tree
 * Windows paints, whatever built it.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');
const {
	createStartupCodeFixture,
	prepareStartupPersonalInclude
} = require('./lib/ahk-startup-fixture.cjs');
const {
	frenchPunctuationDefect,
	loadAllowlist,
	rowTextDefect
} = require('./lib/menu-row-text.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const WALKER = path.join(WINDOWS, 'tests', 'fixtures', 'tray_rows_walker.ahk');
const FEATURES = path.join(WINDOWS, '_generated', 'features_manifest.ahk');
const MENU_MANIFEST = path.join(WINDOWS, '..', '_shared', 'menu', 'data', 'menu_manifest.json');
const LOCALES = ['fr', 'en'];
// A real tray holds hundreds of rows: fewer means the walk stopped early.
const MIN_ROWS = 200;
const BOOT_TIMEOUT_MS = 180000;
const AHK_CANDIDATES = [
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey64.exe',
	'C:\\Program Files\\AutoHotkey\\v2\\AutoHotkey.exe'
];

/**
 * Collects every id a menu row must never show.
 * @returns {Set<string>} Feature ids, feature paths and menu row ids.
 */
function readIdentifiers() {
	const identifiers = new Set();
	const features = fs.readFileSync(FEATURES, 'utf8');
	for (const match of features.matchAll(/Map\("path", "([^"]*)", "id", "([^"]*)"/g)) {
		identifiers.add(match[1]);
		identifiers.add(match[2]);
	}
	const visit = (node) => {
		if (Array.isArray(node)) node.forEach(visit);
		else if (node && typeof node === 'object') {
			if (typeof node.id === 'string' && node.id !== '---') identifiers.add(node.id);
			Object.values(node).forEach(visit);
		}
	};
	visit(JSON.parse(fs.readFileSync(MENU_MANIFEST, 'utf8')));
	return identifiers;
}

/**
 * Spells each submenu row joining a label to its value, so a walk stopping
 * short of them fails instead of judging nothing.
 * @param {string} platform Manifest platform name.
 * @returns {string[]} The French « label : » of every such row.
 */
function labelValueRows(platform) {
	const french = JSON.parse(
		fs.readFileSync(
			path.join(WINDOWS, '..', '_shared', 'core', 'i18n', 'data', 'locales', 'fr.json'),
			'utf8'
		)
	);
	const spelled = new Set();
	const visit = (node) => {
		if (Array.isArray(node)) node.forEach(visit);
		else if (node && typeof node === 'object') {
			if (
				node.current_choice_label_value === true &&
				(!node.platforms || node.platforms.includes(platform))
			)
				spelled.add(`${french[node.i18n]} : `);
			Object.values(node).forEach(visit);
		}
	};
	visit(JSON.parse(fs.readFileSync(MENU_MANIFEST, 'utf8')));
	return [...spelled];
}

/**
 * Boots one locale and returns the tray's rows.
 * @param {string} ahk Interpreter.
 * @param {string} wrapper Startup wrapper.
 * @param {string} windows Private driver copy.
 * @param {string} scratch Private directory.
 * @param {string} locale Locale code.
 * @returns {{trail: string, text: string}[]} Every row.
 */
function bootRows(ahk, wrapper, windows, scratch, locale) {
	const configRoot = path.join(scratch, locale);
	const config = path.join(configRoot, 'config', 'autohotkey');
	fs.mkdirSync(config, { recursive: true });
	fs.writeFileSync(path.join(config, 'config.toml'), `[script]\nlocale = "${locale}"\n`);
	prepareStartupPersonalInclude(windows, path.join(configRoot, 'config'));
	const result = spawnSync(ahk, ['/ErrorStdOut', wrapper], {
		cwd: windows,
		timeout: BOOT_TIMEOUT_MS,
		maxBuffer: 16 * 1024 * 1024,
		encoding: 'utf8',
		env: { ...process.env, LOCALAPPDATA: configRoot, ERGOPTI_STARTUP_SMOKE_DIR: configRoot }
	});
	if (result.error || result.status !== 0)
		throw new Error(`${locale} boot exited ${result.status}: ${result.error || result.stderr}`);
	return fs
		.readFileSync(path.join(configRoot, 'tray-rows.txt'), 'utf8')
		.split('\n')
		.filter((line) => line !== '')
		.map((line) => {
			const [trail, text] = line.split('\t');
			return { trail, text };
		});
}

function main() {
	if (process.platform !== 'win32') {
		console.log('\x1b[33m[SKIP] the Windows tray walk needs Windows.\x1b[0m');
		return 0;
	}
	const named = process.env.ERGOPTI_AHK_EXE || '';
	if (named && !fs.existsSync(named)) throw new Error(`ERGOPTI_AHK_EXE is missing: ${named}`);
	const ahk = named || AHK_CANDIDATES.find((candidate) => fs.existsSync(candidate));
	if (!ahk) {
		console.log('\x1b[33m[SKIP] AutoHotkey v2 is not installed.\x1b[0m');
		return 0;
	}
	const identifiers = readIdentifiers();
	const allowlist = loadAllowlist();
	const scratch = fs.mkdtempSync(path.join(os.tmpdir(), 'ergopti-tray-rows-'));
	const code = createStartupCodeFixture(path.join(scratch, 'code'), WINDOWS);
	const defects = [];
	try {
		const wrapper = path.join(code.windows, `.ergopti_tray_rows_${process.pid}.ahk`);
		fs.writeFileSync(
			wrapper,
			'\uFEFF#Requires AutoHotkey v2.0+\n_DriverStartupSmokeInspect := _TrayRowsWalkerInspect\n' +
				'#Include ErgoptiPlus.ahk\n' +
				fs.readFileSync(WALKER, 'utf8').replace(/^\uFEFF/, ''),
			'utf8'
		);
		for (const locale of LOCALES) {
			const rows = bootRows(ahk, wrapper, code.windows, scratch, locale);
			if (rows.length < MIN_ROWS)
				defects.push(`${locale}: only ${rows.length} rows walked, the walk stopped early`);
			for (const { trail, text } of rows) {
				const defect = rowTextDefect(text, identifiers, allowlist);
				if (defect) defects.push(`${locale}: ${trail} > "${text}" ${defect}`);
				const glued = locale === 'fr' ? frenchPunctuationDefect(text) : '';
				if (glued) defects.push(`fr: ${trail} > "${text}" glues "${glued}"`);
			}
			if (locale === 'fr')
				for (const spelled of labelValueRows('ahk'))
					if (!rows.some(({ text }) => text.includes(spelled)))
						defects.push(`fr: no walked row spells "${spelled}"`);
			console.log(`${locale}: ${rows.length} rows walked`);
			if (process.argv.includes('--dump'))
				for (const { trail, text } of rows) console.log(`  ${trail} > ${text}`);
		}
	} finally {
		code.close();
		fs.rmSync(scratch, { recursive: true, force: true, maxRetries: 3 });
	}
	if (defects.length > 0) {
		console.error(`\x1b[31m[ERROR] ${defects.length} tray row(s) read as identifiers:\x1b[0m`);
		for (const defect of defects) console.error(`  ${defect}`);
		return 1;
	}
	console.log('\x1b[32m[OK] Every tray row reads as text in French and English.\x1b[0m');
	return 0;
}

process.exit(main());
