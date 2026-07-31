// tools/test/test-logger-scalars-single-source.cjs

/**
 * ==============================================================================
 * MODULE: Logger Scalars Single-Source Guard
 * DESCRIPTION:
 * Four logger scalars are declared once per driver rather than once. This gate
 * pins every copy to _shared/modules/timings/constants.toml [logger]:
 *
 *   retention_days    14    AHK LOGGER_RETENTION_DAYS · HS max_age_days (×2)
 *   ring_buffer_size  200   AHK LOGGER_RING_BUFFER_SIZE · HS RING_BUFFER_SIZE ·
 *                           shared core RING_CAPACITY
 *   dedup_window_ms   5000  AHK LOGGER_DEDUP_WINDOW_MS · HS DEDUP_WINDOW_SEC
 *   flush_interval_ms 500   AHK LOGGER_FLUSH_INTERVAL_MS
 *
 * ROOT CAUSE ENCODED — THE DEDUP WINDOW WAS THE BAD ONE:
 * It was not merely duplicated. It existed only as a BARE LITERAL on both
 * sides, in different units: `(_now - _dedup.time) < 5` in macOS seconds, and
 * `… < 5000` in AHK milliseconds. Each site carried a comment asserting it
 * matched the other driver — "The window matches the AHK driver so both drivers
 * dedup identically" and "Mirrors the macOS driver" — and nothing anywhere
 * checked that claim. Two unnamed numbers in two units, each documented as
 * equal to the other, are indistinguishable from two numbers that have drifted.
 * Both are now named constants, and the conversion is asserted here rather than
 * asserted in prose.
 *
 * The retention and ring values matter for a different reason: they are the
 * contract between the logger and the crash reporter (how much history a crash
 * dump contains) and between the logger and the user's disk (how long logs
 * live). A driver quietly keeping 200 lines while another keeps 500 produces
 * crash reports that cannot be compared.
 *
 * NOTE — duplication is still duplication:
 * These constants are not yet READ from the registry at runtime; the drivers
 * declare their own. That is tolerable only because this gate locks them to the
 * registry, exactly as test-keylogger-timings-single-source.cjs does for the
 * keylogger intervals. Wiring the reads is the follow-up, not the guarantee.
 * ==============================================================================
 */

'use strict';

const fs = require('fs');
const path = require('path');
const toml = require('smol-toml');

const ROOT = path.resolve(__dirname, '..', '..');
const SP = path.join(ROOT, 'static', 'ergopti_plus');

const registry = toml.parse(
	fs.readFileSync(path.join(SP, '_shared/modules/timings/constants.toml'), 'utf8')
);

const errors = [];

if (!registry.logger) {
	console.error('\x1b[31m[ERROR] _shared/modules/timings/constants.toml has no [logger] section.\x1b[0m');
	process.exit(1);
}

function read(rel) {
	return fs.readFileSync(path.join(SP, rel), 'utf8');
}

/**
 * Finds every numeric declaration of `name` in `src` and checks them all.
 * Checking EVERY occurrence rather than the first is the point: the macOS
 * retention default is written twice in one file, and a gate that stopped at
 * the first would have let the second drift freely.
 */
function check(file, name, pattern, expected, note) {
	const src = read(file);
	const found = [...src.matchAll(pattern)];
	if (found.length === 0) {
		errors.push(
			`${file}: no declaration of ${name} found — it was renamed or removed, and this gate ` +
				'silently stopped guarding it'
		);
		return;
	}
	for (const m of found) {
		const value = Number(m[1]);
		if (value !== expected) {
			const line = src.slice(0, m.index).split('\n').length;
			errors.push(
				`${file}:${line}: ${name} is ${value}, registry says ${expected}` + (note ? ` (${note})` : '')
			);
		}
	}
}

// ── retention_days ──────────────────────────────────────────────────────────

check(
	'windows/lib/logger.ahk',
	'LOGGER_RETENTION_DAYS',
	/LOGGER_RETENTION_DAYS\s*:=\s*(\d+)/g,
	registry.logger.retention_days
);
check(
	'macos/lib/logger.lua',
	'max_age_days default',
	/max_age_days\s*=\s*max_age_days\s+or\s+(\d+)/g,
	registry.logger.retention_days,
	'declared twice in this file — both must match'
);

// ── ring_buffer_size ────────────────────────────────────────────────────────

check(
	'windows/lib/logger.ahk',
	'LOGGER_RING_BUFFER_SIZE',
	/LOGGER_RING_BUFFER_SIZE\s*:=\s*(\d+)/g,
	registry.logger.ring_buffer_size
);
check(
	'macos/lib/logger.lua',
	'RING_BUFFER_SIZE',
	/\bRING_BUFFER_SIZE\s*=\s*(\d+)/g,
	registry.logger.ring_buffer_size
);
check(
	'_shared/lua/logger/init.lua',
	'RING_CAPACITY',
	/\bRING_CAPACITY\s*=\s*(\d+)/g,
	registry.logger.ring_buffer_size
);

// ── dedup_window: the same duration, in two units ───────────────────────────

check(
	'windows/lib/logger.ahk',
	'LOGGER_DEDUP_WINDOW_MS',
	/LOGGER_DEDUP_WINDOW_MS\s*:=\s*(\d+)/g,
	registry.logger.dedup_window_ms
);
check(
	'macos/lib/logger.lua',
	'DEDUP_WINDOW_SEC',
	/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/g,
	registry.logger.dedup_window_ms / 1000,
	'macOS holds this in SECONDS — the registry value is milliseconds'
);

// The two must not merely each match the registry; they must denote the same
// duration. Stated separately because that is the invariant the comments on
// both sides claim, and the one nothing was checking.
{
	const ms = Number((read('windows/lib/logger.ahk').match(/LOGGER_DEDUP_WINDOW_MS\s*:=\s*(\d+)/) || [])[1]);
	const sec = Number((read('macos/lib/logger.lua').match(/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/) || [])[1]);
	if (Number.isFinite(ms) && Number.isFinite(sec) && ms !== sec * 1000) {
		errors.push(
			`the two dedup windows are different durations: AHK ${ms} ms vs HS ${sec} s (= ${sec * 1000} ms). ` +
				'Both files claim in a comment to mirror the other.'
		);
	}
}

// ── flush_interval_ms ───────────────────────────────────────────────────────

check(
	'windows/lib/logger.ahk',
	'LOGGER_FLUSH_INTERVAL_MS',
	/LOGGER_FLUSH_INTERVAL_MS\s*:=\s*(\d+)/g,
	registry.logger.flush_interval_ms
);

// ── No bare literal may creep back in ───────────────────────────────────────
//
// The whole failure was an unnamed number. A named constant that some other
// call site bypasses is the same failure wearing a better name.
{
	const hs = read('macos/lib/logger.lua');
	const bare = [...hs.matchAll(/_dedup\.time\)\s*<\s*(\d+)/g)];
	if (bare.length > 0) {
		errors.push(
			'macos/lib/logger.lua compares against the dedup window as a bare literal again — ' +
				'use DEDUP_WINDOW_SEC so the value stays greppable and gate-able'
		);
	}
}

if (errors.length > 0) {
	console.error('\x1b[31m[ERROR] logger scalars have drifted from the shared registry:\x1b[0m');
	for (const e of errors) console.error('    - ' + e);
	console.error('    Registry: static/ergopti_plus/_shared/modules/timings/constants.toml [logger]');
	process.exit(1);
}

console.log(
	'\x1b[32m[OK] all 8 logger scalar declaration(s) across the three drivers match ' +
		'[logger] in the shared timing registry (dedup window verified across the s/ms unit split).\x1b[0m'
);
