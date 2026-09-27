// tools/test/test-tap-hold-one-shot-results-single-source.cjs

/**
 * ==============================================================================
 * MODULE: One Table For What The One-Shot Shift Types
 * DESCRIPTION:
 * A one-shot Shift tap followed by Space types "-", by "." types " :", by the
 * magic key types "J", and so on. Those results were an if/else chain inside
 * windows/platform/remap/one_shot_shift.ahk, so the Linux driver, which has the
 * same one-shot Shift, had none of them and shifted the key instead.
 *
 * WHAT IS CHECKED:
 * `_shared/tap_hold/one_shot_shift.json` declares the results; the Windows
 * one-shot takes them (and its InputHook end keys) from the shared reader in
 * tap_hold_loader.ahk and spells none itself; the Linux tap-hold manager reads
 * the same file and its engine spells none either.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');
const DATA = path.join(SP, '_shared', 'tap_hold', 'one_shot_shift.json');
const AHK_ONE_SHOT = path.join(SP, 'windows', 'platform', 'remap', 'one_shot_shift.ahk');
const AHK_LOADER = path.join(SP, 'windows', 'platform', 'remap', 'tap_hold_loader.ahk');
const LINUX_MANAGER = path.join(SP, 'linux', 'platform', 'remap', 'tap_hold_manager.lua');
const LINUX_ENGINE = path.join(SP, 'linux', 'platform', 'remap', 'tap_hold_engine.lua');
const MACOS_ADAPTER = path.join(SP, 'macos', 'adapters', 'one_shot_shift.lua');
const MACOS_OWNER = path.join(SP, 'macos', 'modules', 'keymap', 'one_shot_shift.lua');

const errors = [];
const data = JSON.parse(fs.readFileSync(DATA, 'utf8'));
const results = Array.isArray(data.results) ? data.results : [];

if (results.length < 7) {
	errors.push(`one_shot_shift.json declares ${results.length} result(s); the one-shot Shift has at least 7.`);
}
for (const entry of results) {
	if (typeof entry.char !== 'string' || [...entry.char].length !== 1) {
		errors.push(`one_shot_shift.json: ${JSON.stringify(entry)} must name exactly one character.`);
	}
	if (typeof entry.result !== 'string' || entry.result === '') {
		errors.push(`one_shot_shift.json: ${JSON.stringify(entry)} has no result.`);
	}
}
if (typeof data.magic_key_result !== 'string' || data.magic_key_result === '') {
	errors.push('one_shot_shift.json declares no magic_key_result.');
}

const oneShot = fs.readFileSync(AHK_ONE_SHOT, 'utf8');
const start = oneShot.indexOf('OneShotShift() {');
const body = start >= 0 ? oneShot.slice(start, oneShot.indexOf('\n}', start)) : '';
if (body === '') errors.push('windows/platform/remap/one_shot_shift.ahk has no OneShotShift().');
if (/SpecialCharacter\s*:=\s*("[^"]|Chr\()/.test(body)) {
	errors.push('OneShotShift() spells a one-shot result itself again instead of reading the shared table.');
}
if (!body.includes('TapHoldOneShotResult(') || !body.includes('TapHoldOneShotEndKeys(')) {
	errors.push('OneShotShift() must take its results and its end keys from TapHoldOneShotResult/TapHoldOneShotEndKeys.');
}
if (!fs.readFileSync(AHK_LOADER, 'utf8').includes('one_shot_shift.json')) {
	errors.push('windows/platform/remap/tap_hold_loader.ahk does not read _shared/tap_hold/one_shot_shift.json.');
}

if (!fs.readFileSync(LINUX_MANAGER, 'utf8').includes('tap_hold/one_shot_shift.json')) {
	errors.push('linux/platform/remap/tap_hold_manager.lua does not read _shared/tap_hold/one_shot_shift.json.');
}
if (!fs.readFileSync(MACOS_ADAPTER, 'utf8').includes('tap_hold/one_shot_shift.json')) {
	errors.push('macOS must load the same one-shot result table.');
}
for (const file of [LINUX_ENGINE, MACOS_OWNER]) {
	if (!fs.readFileSync(file, 'utf8').includes('require("tap_hold.one_shot_shift")')) {
		errors.push(`${path.relative(SP, file)} must consume the shared one-shot key and Unicode policy.`);
	}
}
// Code only: the engine's comments may quote a result to explain it.
const engine = fs
	.readFileSync(LINUX_ENGINE, 'utf8')
	.split('\n')
	.map((line) => line.replace(/--.*$/, ''))
	.join('\n');

for (const file of [LINUX_ENGINE, MACOS_ADAPTER, MACOS_OWNER]) {
	const source = file === LINUX_ENGINE ? engine : fs.readFileSync(file, 'utf8')
		.split('\n').map((line) => line.replace(/--.*$/, '')).join('\n');
	for (const entry of results) {
		if (source.includes(JSON.stringify(entry.result))) {
			errors.push(`${path.relative(SP, file)} spells the result ${JSON.stringify(entry.result)} itself.`);
		}
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[FAIL] the one-shot Shift results are not one table:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}
console.log(
	`\x1b[32m[OK] one-shot Shift: ${results.length} result(s) and the magic key's, read by all three drivers ` +
		'from one shared table.\x1b[0m'
);
