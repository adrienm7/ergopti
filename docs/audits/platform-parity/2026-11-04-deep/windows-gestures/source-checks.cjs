'use strict';
// Source evidence only for AHK; pwsh worker behavior is executed separately.
const fs = require('fs'),
	assert = require('assert');
const root = '/workspace/ergopti/static/ergopti_plus/windows';
const read = (p) => fs.readFileSync(root + '/' + p, 'utf8').replace(/^\uFEFF/, '');
const registry = read('modules/gestures/touchpad_registry.ahk');
const ensure = registry.slice(
	registry.indexOf('TouchpadRegistryEnsureBackup(SnapshotFn'),
	registry.indexOf(
		'; ==============================',
		registry.indexOf('TouchpadRegistryEnsureBackup(SnapshotFn')
	)
);
assert(ensure.includes('if Exists.Call(Path) {'));
const existing = ensure.slice(
	ensure.indexOf('if Exists.Call(Path) {'),
	ensure.indexOf('Data := TouchpadRegistryData()')
);
assert(
	existing.includes('return true') &&
		!existing.includes('Read') &&
		!existing.includes('ParseBackup')
);
assert(registry.includes('Entries := _TouchpadRegistryParseBackup(Read.Call(Path), Data)'));
assert(
	registry.includes('if !TouchpadRegistryEnsureBackup(SnapshotFn, CreateFn, ExistsFn, BackupPath)')
);
console.log(
	'WG-002 SOURCE CONFIRMED: Apply accepts existing backup without reading it; Restore separately requires full parse/current inventory'
);
const onb = read('ui/onboarding/gesture_registration.ahk');
assert(onb.includes("Run('*RunAs powershell.exe"));
assert(onb.includes('TouchpadRegistryEnsureBackup()'));
assert(onb.includes('TouchpadRegistryPowerShellKey()'));
const generated = read('_generated/touchpad_registry.ahk');
assert(generated.includes('"powershell_key", "HKCU:'));
assert(!onb.includes('HKEY_USERS') && !onb.includes('WindowsIdentity') && !onb.includes('UserSid'));
console.log(
	'WG-003 SOURCE PREMISE CONFIRMED: onboarding backs up resident HKCU then *RunAs worker uses elevated-process HKCU; cross-account Windows behavior unexecuted'
);
const cfg = read('modules/gestures/config.ahk');
const tray = cfg.slice(
	cfg.indexOf('GestureAutoConfigureRegistry(OnDone'),
	cfg.indexOf('; Disables then re-enables')
);
assert(
	tray.indexOf('TouchpadRegistryApply()') < tray.indexOf('GestureRestartTouchpadDevice(OnDone)')
);
console.log('NEGATIVE CONTROL: tray writes resident HKCU before elevating only the restart worker');
const regWrite = registry.slice(
	registry.indexOf('TouchpadRegistryApply(WriteFn'),
	registry.indexOf('; The registry key in PowerShell')
);
assert(regWrite.indexOf('TouchpadRegistryEnsureBackup(') < regWrite.indexOf('Write.Call('));
console.log(
	'NEGATIVE CONTROL: newly created backup failure prevents writes; valid prior backup retention is deliberate'
);
