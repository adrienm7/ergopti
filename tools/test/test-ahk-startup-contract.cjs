// tools/test/test-ahk-startup-contract.cjs

/**
 * ==============================================================================
 * MODULE: AutoHotkey Startup Contract
 * DESCRIPTION:
 * Guards the load-order boundary that compilation cannot exercise: globals read
 * by the entry-point auto-execute section must be assigned before that read.
 * Also pins the real-process smoke seam and actionable fatal-startup logging.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const WINDOWS = path.join(ROOT, 'static', 'ergopti_plus', 'windows');
const ENTRY = path.join(WINDOWS, 'ErgoptiPlus.ahk');
const CONFIG_IO = path.join(WINDOWS, 'infra', 'config_io.ahk');
const ERROR_NET = path.join(WINDOWS, 'infra', 'error_net.ahk');
const LIFECYCLE = path.join(WINDOWS, 'infra', 'lifecycle.ahk');
const SUSPEND_HANDOFF = path.join(WINDOWS, 'infra', 'suspend_handoff.ahk');

const errors = [];
const read = (file) => (fs.existsSync(file) ? fs.readFileSync(file, 'utf8') : '');
const entry = read(ENTRY);
const configIo = read(CONFIG_IO);
const errorNet = read(ERROR_NET);
const lifecycle = read(LIFECYCLE);
const suspendHandoff = read(SUSPEND_HANDOFF);
const includeNeedle = '#Include infra/config_io.ahk';
const useNeedle = '_ConfigQueueFullSave(CONFIG_FULL_SAVE_BOOT_DELAY_MS, 0, false)';

if (entry.indexOf(includeNeedle) < 0 || entry.indexOf(includeNeedle) > entry.indexOf(useNeedle)) {
	errors.push('config_io.ahk must execute before the boot full-save API or any of its module globals are read');
}

for (const name of [
	'CONFIG_FULL_SAVE_RETRY_DELAY_MS',
	'CONFIG_FULL_SAVE_FAILURE_RETRY_DELAY_MS',
	'CONFIG_FULL_SAVE_BOOT_DELAY_MS',
]) {
	const assignment = new RegExp(`^global ${name}\\s*:=`, 'gm');
	const owned = (configIo.match(assignment) || []).length;
	if (owned !== 1) errors.push(`${name} must have exactly one assignment in config_io.ahk`);
}

if (!errorNet.includes('Exc.HasProp("Stack") ? " | " . Exc.Stack : ""')) {
	errors.push('fatal startup logs must retain the exception stack (file and line), not only the generic message');
}
if (!entry.includes('ERGOPTI_STARTUP_SMOKE_DIR') || !entry.includes('_DriverStartupSmokeDir')) {
	errors.push('the real entry point must expose the isolated startup-smoke seam');
}
if (!entry.includes('EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"],')) {
	errors.push('the startup smoke must continue after first-run personal-shortcuts creation instead of escaping through Reload');
}
const smokeMenuBuild = entry.indexOf('if !BuildTrayMenuDeferred()');
const smokeExit = entry.indexOf('DllCall("ExitProcess", "UInt", 0)', smokeMenuBuild);
if (smokeMenuBuild < 0 || smokeExit < 0 || smokeMenuBuild > smokeExit) {
	errors.push('the startup smoke must consume the deferred tray-menu build before reporting a clean boot');
}
if (!lifecycle.includes('BuildTrayMenuDeferred()')
		|| !lifecycle.includes('return false')
		|| !lifecycle.includes('return true')) {
	errors.push('the deferred tray-menu builder must expose a status the startup smoke can consume');
}

const suspendInclude = entry.indexOf('#Include infra/suspend_handoff.ahk');
const bootInclude = entry.indexOf('#Include infra/boot.ahk');
if (suspendInclude < 0 || bootInclude < 0 || suspendInclude > bootInclude) {
	errors.push('suspend hand-off globals must execute before boot can arm the suspend watchdog');
}
const markerAssignment = /^global SUSPEND_MARKER_FILENAME\s*:=/gm;
if ((suspendHandoff.match(markerAssignment) || []).length !== 1) {
	errors.push('suspend_handoff.ahk must own exactly one SUSPEND_MARKER_FILENAME assignment');
}
if ((lifecycle.match(markerAssignment) || []).length !== 0) {
	errors.push('lifecycle.ahk must not initialize the marker after its boot timer is already armed');
}

if (errors.length) {
	console.error('\x1b[31m[ERROR] AHK startup contract:\x1b[0m');
	for (const error of errors) console.error(`    - ${error}`);
	process.exit(1);
}

console.log('\x1b[32m[OK] AHK startup contract: early globals, fatal diagnostics, and smoke seam are wired.\x1b[0m');
