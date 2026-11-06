// tools/test/test-touchpad-registry-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Windows Touchpad Registry Single-Source Contract
 * DESCRIPTION:
 * F2: the Precision Touchpad registry values Ergopti writes come from one data
 * file, both writers read the generated table, and one owner backs up the
 * prior values before the first write; the Gestures clear restores them, or the
 * Windows factory defaults when no backup exists.
 *
 * ROOT CAUSE ENCODED:
 * The first-run wizard's elevated PowerShell script hand-typed every value
 * name and KeyParams number again, "kept in sync" by a comment with the maps
 * of modules/gestures/init.ahk, and neither writer recorded what it replaced.
 * This gate fails when a value name or the key path is typed anywhere but the
 * data file, when a writer stops going through the owner, when the wizard can
 * launch its script before the backup, or when the generated table drifts.
 * The AHK suite proves the owner's behaviour; this gate runs where AutoHotkey
 * cannot.
 * ==============================================================================
 */

'use strict';

require('../lib/config-key-source-view.cjs').install(); // driver source may name a generated constant
const fs = require('fs');
const path = require('path');
const {
	buildContract,
	renderOutputs,
	SOURCE
} = require('../codegen/codegen-touchpad-registry.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const WIN = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const MENU_MANIFEST = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'menu',
	'menu_manifest.json'
);
const OWNER = path.join(WIN, 'modules', 'gestures', 'touchpad_registry.ahk');
const GENERATED = path.join(WIN, '_generated', 'touchpad_registry.ahk');
const KEY_TAIL = 'CurrentVersion\\PrecisionTouchPad';

const failures = [];
const check = (condition, message) => {
	if (!condition) failures.push(message);
};

/** Reads one repository file as UTF-8 without its BOM. */
function read(file) {
	return fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
}

/** Every .ahk file of the Windows driver, outside tests and vendored code. */
function driverSources(dir, out = []) {
	for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
		const full = path.join(dir, entry.name);
		if (entry.isDirectory()) {
			if (['tests', 'vendor', '_generated'].includes(entry.name)) continue;
			driverSources(full, out);
		} else if (entry.name.endsWith('.ahk')) {
			out.push(full);
		}
	}
	return out;
}

/** The body of one column-0 AHK function, through its column-0 closing brace, or "". */
function functionBody(source, name) {
	const start = source.search(new RegExp(`^${name}\\(`, 'm'));
	if (start < 0) return '';
	const bodyStart = source.indexOf('\n', start) + 1;
	const close = source.slice(bodyStart).search(/^\}/m);
	return close < 0 ? source.slice(start) : source.slice(start, bodyStart + close + 1);
}

// =========================================
// =========================================
// ======= 1/ The Data and Its Table =======
// =========================================
// =========================================

(async () => {
	const { parse } = await import('smol-toml');
	const data = parse(read(SOURCE));
	const contract = buildContract(data);
	check(contract.values.length > 0, 'the touchpad table must list the values Ergopti writes');
	for (const output of renderOutputs(data)) {
		check(
			fs.existsSync(output.path) && fs.readFileSync(output.path, 'utf8') === output.content,
			`${path.relative(ROOT, output.path)} is stale: run npm run codegen:touchpad-registry`
		);
	}

	// The slots are the driver's gesture slots, and each one's function key is
	// the shortcut the manual-setup tutorial tells the user to bind.
	const constants = read(path.join(WIN, 'modules', 'gestures', 'constants.ahk'));
	const slotBlock = functionBody(constants, 'GestureSlotIds');
	const slotIds = [...slotBlock.matchAll(/"([a-z0-9_]+)"/g)].map((m) => m[1]);
	check(
		slotIds.length > 0 &&
			JSON.stringify(slotIds) === JSON.stringify(contract.slots.map((s) => s.id)),
		`the touchpad slots must be GestureSlotIds() in order: ${slotIds.join(', ')}`
	);
	const labels = functionBody(constants, 'GestureShortcutLabels');
	for (const slot of contract.slots) {
		check(
			// Key name ids: the tutorial names them in the user's language.
			new RegExp(`"${slot.id}",\\s*"ctrl\\+win\\+shift\\+F${slot.functionKey}"`).test(labels),
			`${slot.id} writes F${slot.functionKey}, which the setup tutorial must show too`
		);
	}

	// =================================
	// =================================
	// ======= 2/ No Second Copy =======
	// =================================
	// =================================

	const names = contract.values.map((entry) => entry.name);
	const sources = driverSources(WIN);
	check(sources.includes(OWNER), 'the touchpad registry owner must exist');
	for (const file of sources) {
		const text = read(file);
		const relative = path.relative(ROOT, file);
		check(
			!text.includes(KEY_TAIL),
			`${relative} types the touchpad key path; read the generated table`
		);
		for (const name of names) {
			check(
				!text.includes(`"${name}"`) && !text.includes(`'${name}'`),
				`${relative} types the touchpad value ${name}; read the generated table`
			);
		}
	}
	const generated = read(GENERATED);
	check(
		names.every((name) => generated.includes(`"${name}"`)),
		'the generated table must carry every value name'
	);

	// ==========================================
	// ==========================================
	// ======= 3/ One Owner, Backup First =======
	// ==========================================
	// ==========================================

	const owner = read(OWNER);
	const apply = functionBody(owner, 'TouchpadRegistryApply');
	check(
		apply.indexOf('TouchpadRegistryEnsureBackup(') > 0 &&
			apply.indexOf('TouchpadRegistryEnsureBackup(') < apply.indexOf('Write.Call('),
		'the owner must back up the prior values before its first write'
	);
	const writers = sources.filter(
		(file) => file !== OWNER && read(file).includes('TouchpadRegistryData()')
	);
	for (const file of writers) {
		check(
			path.relative(WIN, file).split(path.sep).join('/') === 'modules/gestures/init.ahk',
			`${path.relative(ROOT, file)} reads the raw table; go through the owner`
		);
	}
	const config = read(path.join(WIN, 'modules', 'gestures', 'config.ahk'));
	const configure = functionBody(config, 'GestureAutoConfigureRegistry');
	check(
		configure.includes('TouchpadRegistryApply(') && !configure.includes('Reg_WriteDword'),
		'the in-process writer must write through the owner, never on its own'
	);
	// WG-003: HKCU in an elevated worker is the hive of the account that
	// answered UAC, so the wizard writes in process and elevates only the restart.
	const wizard = read(path.join(WIN, 'ui', 'onboarding', 'gesture_registration.ahk'));
	const launch = functionBody(wizard, '_Onboarding_StartGestureAuto');
	const applyAt = launch.indexOf('TouchpadRegistryApply()');
	check(
		applyAt > 0 && applyAt < launch.indexOf('Run('),
		'the wizard must write the values in process, through the owner, before elevating'
	);
	const restart = functionBody(config, '_GestureRestartBuildPsScript');
	check(
		launch.includes('_GestureRestartBuildPsScript(') &&
			restart !== '' &&
			!/HKCU|HKEY_|ItemProperty/.test(restart),
		'the elevated wizard worker must be the registry-free touchpad restart'
	);

	// ==================================
	// ==================================
	// ======= 4/ The Restore Row =======
	// ==================================
	// ==================================

	// The Configuration row was merged into the Gestures clear (maintainer,
	// 2026-11-03): « Tout effacer » puts the touchpad back to its system state.
	const manifest = JSON.parse(read(MENU_MANIFEST));
	check(
		!(manifest.configuration_menu || []).some((r) => r.id === 'restore_touchpad_gestures'),
		'Configuration must not declare a separate touchpad restore row any more'
	);
	const menuGestures = read(path.join(WIN, 'ui', 'menu', 'menu_gestures.ahk'));
	const clearAt = functionBody(menuGestures, '_GES_ApplyScope').indexOf(
		'TouchpadRegistryClearFromScope('
	);
	check(clearAt > 0, 'the Gestures clear must restore the touchpad through the owner');
	const globalScope = read(path.join(WIN, 'infra', 'config_global_scope.ahk'));
	check(
		functionBody(globalScope, 'ConfigGlobalScopeApply').includes('TouchpadRegistryClearFromScope('),
		'the global clear must restore the touchpad through the owner too'
	);
	const restore = functionBody(owner, 'TouchpadRegistryRestore');
	check(
		restore.includes('_TouchpadRegistryFactoryEntries(') && contract.factoryDefaults.length > 0,
		'without a backup the restore must write the generated factory defaults'
	);

	if (failures.length > 0) {
		console.error(`[FAIL] Windows touchpad registry: ${failures.length} failure(s)`);
		for (const failure of failures) console.error(`  - ${failure}`);
		process.exit(1);
	}
	console.log(
		`[OK] Windows touchpad registry: ${contract.values.length} value(s) from one data file, ` +
			'written through one backing-up owner by both writers, restored by the Gestures clear.'
	);
})().catch((error) => {
	console.error(`[ERROR] ${error.stack || error.message}`);
	process.exit(1);
});
