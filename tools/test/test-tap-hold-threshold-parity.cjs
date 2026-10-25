// tools/test/test-tap-hold-threshold-parity.cjs

/**
 * ==============================================================================
 * MODULE: Tap-Hold Threshold Parity
 * DESCRIPTION:
 * The tap-vs-hold threshold decides how long a key must be held before the hold
 * action fires instead of the tap. It is declared per key under `[tap_hold.keys.*]`
 * in _shared/tap_hold/defaults.toml, which every driver reads (macOS through the
 * catalogue's `hs` ids), plus one fallback in the timing registry.
 *
 * WHAT THIS CAUGHT:
 * macOS sat at 1000 ms against 200-350 ms on the other two — a 3-5x divergence
 * in the same setting, on the same keyboard, for the same user. It was not a
 * decision: 1000 is Karabiner-Elements' own default for
 * to_if_alone_timeout_milliseconds, so the value arrived by not being chosen.
 * Nothing compared the two numbers, and nothing could: they live under headers
 * the other driver ignores, and both are valid TOML.
 *
 * ONE DECLARATION (PAR-15):
 * macOS no longer ships its own global. A key takes the `time_activation_seconds`
 * of `[tap_hold.keys.<id>]` for the catalogue id its `hs` column names, and a key
 * with none of its own takes the timing registry's tap_hold.default_activation_ms,
 * the fallback Linux reads and the Windows literal TAPHOLD_DEFAULT_ACTIVATION_SECONDS
 * is pinned to below. The per-key values are pinned exactly, so changing one is a
 * deliberate edit of this table.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');

const ROOT = path.resolve(__dirname, '..', '..');
const DEFAULTS = path.join(ROOT, 'static', 'ergopti_plus', '_shared', 'tap_hold', 'defaults.toml');

const errors = [];

if (!fs.existsSync(DEFAULTS)) {
	console.error(
		`\x1b[31m[ERROR] ${DEFAULTS} is missing — the shared tap-hold defaults moved.\x1b[0m`
	);
	process.exit(1);
}
const src = fs.readFileSync(DEFAULTS, 'utf8');

// ===== 1) The per-key thresholds Windows and Linux read =====

const perKey = [];
const KEY_BLOCK = /\[tap_hold\.keys\.([a-z_]+)\][\s\S]*?(?=\n\[|$)/g;
let m;
while ((m = KEY_BLOCK.exec(src)) !== null) {
	const secs = /time_activation_seconds\s*=\s*([0-9.]+)/.exec(m[0]);
	if (secs) perKey.push({ key: m[1], ms: Math.round(parseFloat(secs[1]) * 1000) });
}

if (perKey.length === 0) {
	errors.push(
		'no [tap_hold.keys.*] section declares time_activation_seconds. Either the schema changed ' +
			'or this scan is broken — and a parity check over an empty set passes forever.'
	);
}

// ===== 2) The fallback is ONE value, in the timing registry =====

const REGISTRY = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'timings',
	'constants.toml'
);
const registrySrc = fs.readFileSync(REGISTRY, 'utf8');
const fallbackMatch = /^default_activation_ms\s*=\s*(\d+)/m.exec(registrySrc);
if (!fallbackMatch) {
	errors.push('the timing registry [tap_hold] declares no default_activation_ms.');
}
const fallbackMs = fallbackMatch ? parseInt(fallbackMatch[1], 10) : null;
if (/^\s*tap_hold_timeout_ms\s*=/m.test(src)) {
	errors.push(
		'[hs_timeouts] declares tap_hold_timeout_ms: macOS reads the per-key [tap_hold.keys.*] ' +
			"values and the timing registry's tap_hold.default_activation_ms, never a second declaration."
	);
}

// Windows keeps the fallback as a literal that its unit tests pin; it must equal the registry.
const AHK_LOADER = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'windows',
	'platform',
	'remap',
	'tap_hold_loader.ahk'
);
const ahkMatch = /^global TAPHOLD_DEFAULT_ACTIVATION_SECONDS\s*:=\s*([0-9.]+)/m.exec(
	fs.readFileSync(AHK_LOADER, 'utf8')
);
if (!ahkMatch || fallbackMs === null || Math.round(parseFloat(ahkMatch[1]) * 1000) !== fallbackMs) {
	errors.push(
		`TAPHOLD_DEFAULT_ACTIVATION_SECONDS (${ahkMatch ? ahkMatch[1] : 'missing'}) must equal ` +
			`the registry's default_activation_ms (${fallbackMs}).`
	);
}

// Linux and macOS read the registry value, never a literal of their own.
const LINUX_LOADER = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'linux',
	'platform',
	'remap',
	'tap_hold_loader.lua'
);
if (
	!/FALLBACK_THRESHOLD_SECONDS\s*=\s*require\("infra\.timings"\)\.ms\("tap_hold", "default_activation_ms"\)/.test(
		fs.readFileSync(LINUX_LOADER, 'utf8')
	)
) {
	errors.push(
		'linux tap_hold_loader.lua must read FALLBACK_THRESHOLD_SECONDS from the timing registry.'
	);
}
const MACOS_DEFAULTS_SRC = fs.readFileSync(
	path.join(ROOT, 'static', 'ergopti_plus', 'macos', 'platform', 'remap', 'defaults.lua'),
	'utf8'
);
if (
	!/D\.tap_hold_timeout_ms\s*=\s*require\("infra\.timings"\)\.ms\("tap_hold", "default_activation_ms"\)/.test(
		MACOS_DEFAULTS_SRC
	) ||
	!/D\.tap_hold_key_timeouts_ms\s*=\s*require\("tap_hold\.key_catalog"\)\.load_thresholds\(/.test(
		MACOS_DEFAULTS_SRC
	)
) {
	errors.push(
		'macos/platform/remap/defaults.lua must read the global from the registry and the per-key ' +
			'thresholds through the shared catalogue (key_catalog.load_thresholds).'
	);
}

// ===== 3) Every threshold lives inside a usable band =====

if (perKey.length > 0 && fallbackMs !== null) {
	// A threshold outside human tapping range is wrong on every platform: below
	// the band ordinary typing fires holds, above it every hold waits.
	const SANE_LO_MS = 100;
	const SANE_HI_MS = 500;
	for (const { key, ms } of perKey.concat([{ key: 'default_activation_ms', ms: fallbackMs }])) {
		if (ms < SANE_LO_MS || ms > SANE_HI_MS) {
			errors.push(
				`${key}: ${ms} ms is outside the ${SANE_LO_MS}-${SANE_HI_MS} ms band a tap-hold ` +
					'threshold can usefully occupy.'
			);
		}
	}
}

// ===== 4) The shipped values themselves (PAR-15) =====
//
// The shipped thresholds are a decision, so they are pinned exactly: changing one
// is a deliberate edit of this table, never a side effect.

const EXPECTED_PER_KEY_MS = {
	caps_lock: 350,
	left_shift: 350,
	left_ctrl: 200,
	left_alt: 200,
	right_ctrl: 200,
	alt_gr: 200,
	tab: 200
};
const EXPECTED_FALLBACK_MS = 200;

const actualPerKey = Object.fromEntries(perKey.map((k) => [k.key, k.ms]));
if (JSON.stringify(actualPerKey) !== JSON.stringify(EXPECTED_PER_KEY_MS)) {
	errors.push(
		`the per-key thresholds are ${JSON.stringify(actualPerKey)}, expected ` +
			`${JSON.stringify(EXPECTED_PER_KEY_MS)}. Change the shipped value and this table together.`
	);
}
if (fallbackMs !== EXPECTED_FALLBACK_MS) {
	errors.push(
		`the fallback threshold is ${fallbackMs} ms, expected ${EXPECTED_FALLBACK_MS} ms. ` +
			'Change the shipped value and this table together.'
	);
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

const values = perKey.map((k) => k.ms);
console.log(
	`\x1b[32m[OK] tap-hold thresholds agree — ${perKey.length} per-key value(s) spanning ` +
		`${Math.min(...values)}-${Math.max(...values)} ms, one ${fallbackMs} ms fallback.\x1b[0m`
);
