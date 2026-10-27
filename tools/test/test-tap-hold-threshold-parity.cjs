// tools/test/test-tap-hold-threshold-parity.cjs

/**
 * ==============================================================================
 * MODULE: Tap-Hold Delay Parity
 * DESCRIPTION:
 * The tap-vs-hold delay decides how long a key must be held before the hold
 * action fires instead of the tap. All three drivers share ONE model (PAR-15):
 *   - NO key ships a delay of its own: `[tap_hold.keys.*]` in
 *     _shared/tap_hold/defaults.toml declares none;
 *   - every key follows the GLOBAL delay, whose default is one declaration, the
 *     timing registry's tap_hold.default_activation_ms;
 *   - the user can change the global delay, or give one key its own delay; a
 *     key's own delay survives a change of the global, and "use global" removes it.
 *
 * WHAT THIS CAUGHT:
 * macOS sat at 1000 ms against 200-350 ms on the other two, a 3-5x divergence in the
 * same setting. It was not a decision: 1000 is Karabiner-Elements' own default
 * for to_if_alone_timeout_milliseconds. Later Windows and Linux shipped 350 ms for
 * Caps Lock and Left Shift and 200 ms for the rest, and a rewrite of the user's
 * tap_hold.toml copied those into the file, where they passed for the user's own
 * choice and would have frozen the keys against any change of the global delay.
 *
 * THE RETIRED DELAYS:
 * `[tap_hold.retired_delays]` keeps the old per-key values, only so Windows and
 * Linux can tell a copied value from a chosen one while migrating a file. They
 * are pinned exactly: adding a key to it would silently discard a user's choice.
 * ==============================================================================
 */

'use strict';

require('../lib/config-key-source-view.cjs').install(); // driver Lua may name a generated config-key constant

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const APP = path.join(ROOT, 'static', 'ergopti_plus');
const DEFAULTS = path.join(APP, '_shared', 'tap_hold', 'defaults.toml');
const REGISTRY = path.join(APP, '_shared', 'modules', 'timings', 'constants.toml');
const read = (...parts) => fs.readFileSync(path.join(APP, ...parts), 'utf8');

const errors = [];

if (!fs.existsSync(DEFAULTS)) {
	console.error(
		`\x1b[31m[ERROR] ${DEFAULTS} is missing — the shared tap-hold defaults moved.\x1b[0m`
	);
	process.exit(1);
}
const src = fs.readFileSync(DEFAULTS, 'utf8');
const registrySrc = fs.readFileSync(REGISTRY, 'utf8');

// ===== 1) No shipped key carries a delay =====

const KEY_BLOCK = /\[tap_hold\.keys\.([a-z_]+)\][\s\S]*?(?=\n\[|$)/g;
const keyBlocks = [];
let m;
while ((m = KEY_BLOCK.exec(src)) !== null) keyBlocks.push(m);
if (keyBlocks.length === 0) {
	errors.push(
		'no [tap_hold.keys.*] section found. Either the schema changed or this scan is broken — ' +
			'and a check over an empty set passes forever.'
	);
}
for (const block of keyBlocks) {
	if (/^\s*time_activation_seconds\s*=/m.test(block[0])) {
		errors.push(
			`[tap_hold.keys.${block[1]}] ships a time_activation_seconds: no key ships a delay, ` +
				'every key follows the global delay until the user gives it one.'
		);
	}
}
if (/^\s*tap_hold_timeout_ms\s*=/m.test(src)) {
	errors.push(
		"[hs_timeouts] declares tap_hold_timeout_ms: the global delay is the timing registry's " +
			'tap_hold.default_activation_ms, never a second declaration.'
	);
}

// ===== 2) The global default is ONE value, in the timing registry =====

const fallbackMatch = /^default_activation_ms\s*=\s*(\d+)/m.exec(registrySrc);
if (!fallbackMatch)
	errors.push('the timing registry [tap_hold] declares no default_activation_ms.');
const fallbackMs = fallbackMatch ? parseInt(fallbackMatch[1], 10) : null;
const EXPECTED_GLOBAL_MS = 200;
if (fallbackMs !== EXPECTED_GLOBAL_MS) {
	errors.push(
		`the global delay is ${fallbackMs} ms, expected ${EXPECTED_GLOBAL_MS} ms. ` +
			'Change the shipped value and this table together.'
	);
}
// A delay outside human tapping range is wrong on every platform: below the band
// ordinary typing fires holds, above it every hold waits.
if (fallbackMs !== null && (fallbackMs < 100 || fallbackMs > 500)) {
	errors.push(`the global delay ${fallbackMs} ms is outside the 100-500 ms usable band.`);
}

// Windows loads the registry value at boot into its constant; no literal remains.
const AHK_CONSTANTS = read('windows', 'platform', 'remap', 'constants.ahk');
if (!/^global TAPHOLD_DEFAULT_ACTIVATION_SECONDS\s*:=\s*0\s*$/m.test(AHK_CONSTANTS)) {
	errors.push(
		'windows platform/remap/constants.ahk must declare TAPHOLD_DEFAULT_ACTIVATION_SECONDS with ' +
			'the sentinel 0 (the registry value is loaded at boot).'
	);
}
if (
	!/TAPHOLD_DEFAULT_ACTIVATION_SECONDS\s*:=\s*TimingsGetSec\("tap_hold",\s*"default_activation_ms"\)/.test(
		AHK_CONSTANTS
	)
) {
	errors.push(
		'windows TapHoldsLoadTimings() must load TAPHOLD_DEFAULT_ACTIVATION_SECONDS from the ' +
			"registry's tap_hold.default_activation_ms."
	);
}
if (
	/TAPHOLD_DEFAULT_ACTIVATION_SECONDS\s*:=\s*[0-9.]+\s*$/m.test(
		read('windows', 'platform', 'remap', 'tap_hold_loader.ahk')
	)
) {
	errors.push(
		'windows tap_hold_loader.ahk still holds a literal TAPHOLD_DEFAULT_ACTIVATION_SECONDS.'
	);
}

// Linux and macOS read the registry value, never a literal of their own.
if (
	!/GLOBAL_DEFAULT_SECONDS\s*=\s*require\("infra\.timings"\)\.ms\("tap_hold", "default_activation_ms"\)/.test(
		read('linux', 'platform', 'remap', 'tap_hold_loader.lua')
	)
) {
	errors.push(
		'linux tap_hold_loader.lua must read GLOBAL_DEFAULT_SECONDS from the timing registry.'
	);
}
const MACOS_DEFAULTS_SRC = read('macos', 'platform', 'remap', 'defaults.lua');
if (
	!/D\.tap_hold_timeout_ms\s*=\s*require\("infra\.timings"\)\.ms\("tap_hold", "default_activation_ms"\)/.test(
		MACOS_DEFAULTS_SRC
	)
) {
	errors.push(
		'macos/platform/remap/defaults.lua must read the global delay from the timing registry.'
	);
}
if (
	/tap_hold_key_timeouts_ms|load_thresholds|get_tap_default_timeout/.test(
		MACOS_DEFAULTS_SRC +
			read('macos', 'platform', 'remap', 'generator.lua') +
			read('macos', 'platform', 'remap', 'init.lua')
	)
) {
	errors.push(
		'macOS still resolves a shipped per-key delay (tap_hold_key_timeouts_ms / load_thresholds).'
	);
}

// ===== 3) The retired delays: pinned, and only for keys the catalogue lists =====

const EXPECTED_RETIRED = {
	caps_lock: 0.35,
	left_shift: 0.35,
	left_ctrl: 0.2,
	left_alt: 0.2,
	right_ctrl: 0.2,
	alt_gr: 0.2,
	tab: 0.2
};
const retiredBlock = /\[tap_hold\.retired_delays\]([\s\S]*?)(?=\n\[|$)/.exec(src);
const retired = {};
if (!retiredBlock) {
	errors.push('defaults.toml declares no [tap_hold.retired_delays].');
} else {
	for (const line of retiredBlock[1].split('\n')) {
		const kv = /^\s*([a-z_]+)\s*=\s*([0-9.]+)\s*$/.exec(line);
		if (kv) retired[kv[1]] = parseFloat(kv[2]);
	}
	if (JSON.stringify(retired) !== JSON.stringify(EXPECTED_RETIRED)) {
		errors.push(
			`[tap_hold.retired_delays] is ${JSON.stringify(retired)}, expected ` +
				`${JSON.stringify(EXPECTED_RETIRED)}. It records what earlier builds shipped; it never changes.`
		);
	}
}

// ===== 4) The global/own/reset model is wired in every driver =====
//
// The behaviour is exercised by each driver's own suite (a global change does not
// move an overridden key, moves a key without one, a reset follows the global
// again); this only pins that each driver offers the three rows.

const MENU = read('_shared', 'modules', 'menu', 'menu_manifest.json');
for (const id of ['tap_hold_global_delay', 'tap_hold_key_delay', 'tap_hold_key_delay_use_global']) {
	if (!MENU.includes(`"${id}"`)) errors.push(`the tap-hold menu manifest declares no '${id}' row.`);
}
const useGlobal = JSON.stringify(JSON.parse(MENU).tap_hold_key_delay_tail ?? []);
if (/"platforms"/.test(useGlobal)) {
	errors.push(
		'tap_hold_key_delay_tail restricts a row to some platforms: the per-key delay and its reset ' +
			'are on Windows, macOS and Linux alike.'
	);
}
for (const [file, needles] of [
	[
		['windows', 'ui', 'menu', 'menu_taphold.ahk'],
		['WriteTapHoldGlobalDuration', 'WriteTapHoldDurationReset']
	],
	[
		['linux', 'ui', 'menu', 'menu_builder.lua'],
		['set_global_threshold', 'tap_hold_key_delay_use_global']
	],
	[
		['macos', 'ui', 'menu', 'menu_tap_holds.lua'],
		['set_tap_hold_timeout', 'tap_hold_key_delay_use_global']
	]
]) {
	const text = read(...file);
	for (const needle of needles) {
		if (!text.includes(needle)) errors.push(`${file.join('/')} does not wire ${needle}.`);
	}
}

// ===== 5) The one-shot timeout is ONE value =====
//
// Windows and Linux read tap_hold.one_shot_shift_timeout_ms from the timing
// registry; macOS declared its own sticky_timeout_ms (3000 ms) beside the
// registry's 2000 ms, so the same one-shot Shift lasted 50 % longer there.

if (/^\s*sticky_timeout_ms\s*=/m.test(src)) {
	errors.push(
		"[hs_timeouts] declares sticky_timeout_ms: the one-shot timeout is the timing registry's " +
			'tap_hold.one_shot_shift_timeout_ms on every driver, never a second declaration.'
	);
}
const registryOneShot = /^one_shot_shift_timeout_ms\s*=\s*(\d+)/m.exec(registrySrc);
if (!registryOneShot || parseInt(registryOneShot[1], 10) !== 2000) {
	errors.push('the timing registry must declare one_shot_shift_timeout_ms = 2000.');
}
const MACOS_DEFAULTS = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'macos',
	'platform',
	'remap',
	'defaults.lua'
);
if (
	!/D\.sticky_timeout_ms\s*=\s*require\("infra\.timings"\)\.ms\("tap_hold", "one_shot_shift_timeout_ms"\)/.test(
		fs.readFileSync(MACOS_DEFAULTS, 'utf8')
	)
) {
	errors.push(
		'macos/platform/remap/defaults.lua must read the one-shot timeout from the timing registry ' +
			'(tap_hold.one_shot_shift_timeout_ms).'
	);
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] tap-hold threshold parity:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	process.exit(1);
}

console.log(
	`\x1b[32m[OK] tap-hold delays agree — no shipped per-key delay, one ${fallbackMs} ms global default.\x1b[0m`
);
