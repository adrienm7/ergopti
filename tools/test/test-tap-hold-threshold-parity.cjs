// tools/test/test-tap-hold-threshold-parity.cjs

/**
 * ==============================================================================
 * MODULE: Tap-Hold Threshold Parity
 * DESCRIPTION:
 * The tap-vs-hold threshold decides how long a key must be held before the hold
 * action fires instead of the tap. It is declared twice in
 * _shared/tap_hold/defaults.toml — per key under `[tap_hold.keys.*]`, which
 * Windows and Linux read, and once globally under `[hs_timeouts]`, which macOS
 * reads. The two namespaces describe the same seven physical keys and neither
 * loader looks at the other's headers.
 *
 * WHAT THIS CAUGHT:
 * macOS sat at 1000 ms against 200-350 ms on the other two — a 3-5x divergence
 * in the same setting, on the same keyboard, for the same user. It was not a
 * decision: 1000 is Karabiner-Elements' own default for
 * to_if_alone_timeout_milliseconds, so the value arrived by not being chosen.
 * Nothing compared the two numbers, and nothing could: they live under headers
 * the other driver ignores, and both are valid TOML.
 *
 * WHY A RANGE AND NOT AN EQUALITY:
 * macOS ships one global threshold where the others ship one value per key; a
 * per-key override exists there (the menu's per-key delay row and its
 * "use global" reset), but the shipped default is the global. The two
 * namespaces also spell the same keys differently (left_ctrl/left_control,
 * left_alt/left_option), so the shipped values cannot be compared key by key.
 * Requiring equality today would fail on arrival and be deleted. Requiring that
 * the global sits INSIDE the per-key range is true now, is what "the same
 * keyboard feels the same" actually means, and still fails on a 1000.
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

// ===== 2) The single global macOS reads =====

const globalMatch = /\[hs_timeouts\][\s\S]*?tap_hold_timeout_ms\s*=\s*(\d+)/.exec(src);
if (!globalMatch) {
	errors.push('[hs_timeouts] declares no tap_hold_timeout_ms — macOS has no threshold to read.');
}
const globalMs = globalMatch ? parseInt(globalMatch[1], 10) : null;

// ===== 3) The global must live inside the per-key range =====

if (perKey.length > 0 && globalMs !== null) {
	const values = perKey.map((k) => k.ms);
	const lo = Math.min(...values);
	const hi = Math.max(...values);

	if (globalMs < lo || globalMs > hi) {
		const near = globalMs < lo ? lo : hi;
		errors.push(
			`macOS's global tap-hold threshold is ${globalMs} ms while Windows and Linux use ` +
				`${lo}-${hi} ms per key — ${Math.abs(globalMs - near)} ms outside the range, ` +
				`${(globalMs / near).toFixed(1)}x the nearest. That is the same setting on the same ` +
				'keyboard behaving differently by platform: a hold that registers instantly on one ' +
				'driver takes a noticeable beat on the other, and a deliberate tap that overruns the ' +
				'threshold silently becomes a hold. Set it inside the range, or move the per-key ' +
				'values with it.'
		);
	}

	// A threshold outside human tapping range is wrong on every platform, whatever
	// the others say — this catches all three drifting together, which a pure
	// parity check cannot.
	const SANE_LO_MS = 100;
	const SANE_HI_MS = 500;
	for (const { key, ms } of perKey.concat([{ key: 'hs_timeouts global', ms: globalMs }])) {
		if (ms < SANE_LO_MS || ms > SANE_HI_MS) {
			errors.push(
				`${key}: ${ms} ms is outside the ${SANE_LO_MS}-${SANE_HI_MS} ms band a tap-hold ` +
					'threshold can usefully occupy. Below it, ordinary typing fires holds; above it, ' +
					'every hold waits.'
			);
		}
	}
}

// ===== 4) The shipped values themselves (PAR-15) =====
//
// The range above lets one driver drift inside it. The shipped thresholds are a
// decision, so they are pinned exactly: changing one is a deliberate edit of this
// table, never a side effect. macOS ships one global value inside the per-key range.

const EXPECTED_PER_KEY_MS = {
	caps_lock: 350,
	left_shift: 350,
	left_ctrl: 200,
	left_alt: 200,
	right_ctrl: 200,
	alt_gr: 200,
	tab: 200
};
const EXPECTED_MACOS_GLOBAL_MS = 250;

const actualPerKey = Object.fromEntries(perKey.map((k) => [k.key, k.ms]));
if (JSON.stringify(actualPerKey) !== JSON.stringify(EXPECTED_PER_KEY_MS)) {
	errors.push(
		`the per-key thresholds are ${JSON.stringify(actualPerKey)}, expected ` +
			`${JSON.stringify(EXPECTED_PER_KEY_MS)}. Change the shipped value and this table together.`
	);
}
if (globalMs !== EXPECTED_MACOS_GLOBAL_MS) {
	errors.push(
		`macOS's global threshold is ${globalMs} ms, expected ${EXPECTED_MACOS_GLOBAL_MS} ms. ` +
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
const REGISTRY = path.join(
	ROOT,
	'static',
	'ergopti_plus',
	'_shared',
	'modules',
	'timings',
	'constants.toml'
);
const registryOneShot = /^one_shot_shift_timeout_ms\s*=\s*(\d+)/m.exec(
	fs.readFileSync(REGISTRY, 'utf8')
);
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
		`${Math.min(...values)}-${Math.max(...values)} ms, macOS global ${globalMs} ms inside that ` +
		`range.\x1b[0m`
);
