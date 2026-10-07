// tools/test/test-menu-enable-disable-all-retired.cjs

/**
 * ==============================================================================
 * MODULE: Enable All / Disable All Stay Retired
 * DESCRIPTION:
 * The global « Tout activer » / « Tout désactiver » rows were removed on every
 * driver. Each category now opens with its own first-row switch, the
 * recommended preset is restored through « Restaurer les valeurs conseillées »,
 * and an empty configuration already means "every input-altering feature off".
 * Two whole-tree switches next to those were a second way to move every
 * feature, and the one users reported as doing nothing on macOS.
 *
 * WHAT THIS PINS, per surface, so a partial revert cannot pass:
 *   1. The manifest menus that held the rows declare neither id.
 *   2. No locale carries their labels or the Windows warning dialog.
 *   3. No driver keeps a handler that only those rows could reach: the Windows
 *      bulk writer and its dialog, the macOS actions, the Linux callbacks and
 *      the global switch module that stored the snapshot they restored.
 *
 * A retired name is matched in production source with comments stripped, and
 * every scan asserts it read something first: an empty scan would pass this
 * gate while checking nothing.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const assert = require('node:assert/strict');
const { scriptTokens } = require('../lib/script-source.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const MANIFEST = path.join(SP, '_shared', 'modules', 'menu', 'menu_manifest.json');
const LOCALES = path.join(SP, '_shared', 'data', 'locales');

// The menus that held the two rows, whichever of them the manifest still has.
const GLOBAL_MENUS = ['global_actions', 'configuration_menu'];
const RETIRED_IDS = ['enable_all', 'disable_all'];
const RETIRED_KEYS = [
	'menu.global.enable_all',
	'menu.global.disable_all',
	'dialog.enable_all.warning',
	'notify.all_features_enabled',
	'notify.all_features_disabled'
];

// Production symbols that existed only to serve the two rows.
const RETIRED_SYMBOLS = {
	windows: {
		ext: '.ahk',
		names: [
			'ToggleAllFeaturesOn',
			'ToggleAllFeaturesOff',
			'ToggleAllFeatures(',
			'_CollectFeatureFlipUpdates',
			'_FeatureFlipLeafIsSwitch'
		]
	},
	macos: {
		ext: '.lua',
		names: [
			'actions.enable_all',
			'actions.disable_all',
			'set_all_enabled',
			'owner.enable_all',
			'owner.disable_all',
			'request("enable")',
			'request("disable")'
		]
	},
	linux: {
		ext: '.lua',
		names: [
			'on_enable_all',
			'on_disable_all',
			'global_feature_switch',
			'closed_category_gates',
			'restore_category_gates'
		]
	}
};

function retiredSymbolUsed(text, name, extension) {
	if (!/^[A-Za-z_][A-Za-z0-9_]*$/.test(name)) return text.includes(name);
	return scriptTokens(text, extension).some(
		(token) => ['identifier', 'string'].includes(token.kind) && token.value === name
	);
}
for (const extension of ['.lua', '.ahk']) {
	for (const name of ['on_enable_all', 'on_disable_all']) {
		assert.equal(retiredSymbolUsed('extension_' + name.slice(3), name, extension), false);
		assert.equal(retiredSymbolUsed(name + '()', name, extension), true);
		assert.equal(retiredSymbolUsed('"' + name + '"', name, extension), true);
		assert.equal(retiredSymbolUsed('"extension_' + name.slice(3) + '"', name, extension), false);
	}
}

const errors = [];

// ==================================================
// ==================================================
// ======= 1/ The manifest ==========================
// ==================================================
// ==================================================

const manifest = JSON.parse(fs.readFileSync(MANIFEST, 'utf8'));
let globalRows = 0;
for (const menu of GLOBAL_MENUS) {
	for (const row of manifest[menu] || []) {
		globalRows += 1;
		if (RETIRED_IDS.includes(row.id)) {
			errors.push(`${menu} declares the retired row "${row.id}" again.`);
		}
	}
}
if (globalRows === 0) {
	errors.push(
		`none of ${GLOBAL_MENUS.join(', ')} declares a row — the manifest scan read nothing.`
	);
}

// ==================================================
// ==================================================
// ======= 2/ The locales ===========================
// ==================================================
// ==================================================

const localeFiles = fs.readdirSync(LOCALES).filter((f) => f.endsWith('.json'));
if (localeFiles.length < 21) errors.push(`read ${localeFiles.length} locale file(s), expected 21`);
for (const file of localeFiles) {
	const table = JSON.parse(fs.readFileSync(path.join(LOCALES, file), 'utf8'));
	for (const key of RETIRED_KEYS) {
		if (table[key] !== undefined) errors.push(`${file} still carries the retired key "${key}".`);
	}
}

// ==================================================
// ==================================================
// ======= 3/ The drivers ===========================
// ==================================================
// ==================================================

/**
 * One driver's production source, full-line comments removed.
 * @param {string} driver Driver folder name.
 * @param {string} ext File extension.
 * @returns {{files: number, text: string}}
 */
function productionSource(driver, ext) {
	const comment = ext === '.ahk' ? /^\s*;/ : /^\s*--/;
	let files = 0;
	const parts = [];
	(function walk(dir) {
		for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
			const full = path.join(dir, entry.name);
			if (entry.isDirectory()) {
				if (!['tests', 'vendor', '_generated', 'node_modules'].includes(entry.name)) walk(full);
			} else if (entry.name.endsWith(ext)) {
				files += 1;
				const lines = fs
					.readFileSync(full, 'utf8')
					.split('\n')
					.filter((line) => !comment.test(line));
				parts.push(lines.join('\n'));
			}
		}
	})(path.join(SP, driver));
	return { files, text: parts.join('\n') };
}

for (const [driver, { ext, names }] of Object.entries(RETIRED_SYMBOLS)) {
	const { files, text } = productionSource(driver, ext);
	if (files < 20) {
		errors.push(
			`${driver}: read ${files} production file(s) — the scan is broken and proves nothing.`
		);
		continue;
	}
	for (const name of names) {
		if (retiredSymbolUsed(text, name, ext))
			errors.push(`${driver} production source still uses the retired "${name}".`);
	}
}

// ==================================================
// ==================================================
// ======= 4/ Report ================================
// ==================================================
// ==================================================

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] Enable all / Disable all came back:\x1b[0m');
	for (const error of errors) console.error(`  - ${error}`);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] Enable all / Disable all stay retired: ${globalRows} global row(s), ${localeFiles.length} ` +
		'locales and three driver trees checked.\x1b[0m'
);
