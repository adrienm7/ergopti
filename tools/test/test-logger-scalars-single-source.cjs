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

/**
 * The inverse of check(): asserts a file does NOT hold a scalar, because it
 * delegates to whoever does.
 *
 * A constant that moved out of a driver leaves check() reporting "renamed or
 * removed, and this gate silently stopped guarding it" — which is correct and
 * exactly what it should say. Deleting the check to make that go away is what
 * loses the guarantee: nothing would then object to the constant being pasted
 * back in a month later, next to a delegating call that quietly stops being the
 * source. So the assertion is inverted instead of dropped, and it is the stronger
 * of the two: not "these numbers agree" but "there is only one number".
 *
 * @param {string} file Path relative to static/ergopti_plus.
 * @param {string} name The constant that must not reappear.
 * @param {RegExp} pattern Global regex matching its declaration.
 * @param {string} why What holds the value instead.
 */
function mustNotDeclare(file, name, pattern, why) {
	const src = read(file);
	const found = [...src.matchAll(pattern)];
	for (const m of found) {
		const line = src.slice(0, m.index).split('\n').length;
		errors.push(
			`${file}:${line}: ${name} is declared here again — ${why}. Two copies of one number ` +
				'agree until the day one of them is edited, which is the whole reason this gate exists.'
		);
	}
}

// ── retention_days ──────────────────────────────────────────────────────────

check(
	'windows/infra/logger.ahk',
	'LOGGER_RETENTION_DAYS',
	/LOGGER_RETENTION_DAYS\s*:=\s*(\d+)/g,
	registry.logger.retention_days
);
check(
	'macos/infra/logger.lua',
	'max_age_days default',
	/max_age_days\s*=\s*max_age_days\s+or\s+(\d+)/g,
	registry.logger.retention_days,
	'declared twice in this file — both must match'
);
// Linux reads the registry directly rather than declaring a default, so there
// is no literal to pin. What must be checked is that it purges at all: it
// rolled a new pair of files every day and deleted none, so the directory grew
// for the life of the install. A gate over the other two drivers' copies of a
// number cannot see a driver that ignores the number entirely.
{
	const sink = read('linux/infra/logger_sink.lua');
	// Matches the lookup by its arguments, not by one spelling of the call: it
	// travels through pcall, so `Timings.count("logger", "retention_days")` and
	// `pcall(Timings.count, "logger", "retention_days")` are both correct and only
	// one of them has the parentheses.
	if (!/Timings\.count/.test(sink) || !/["']logger["'][\s\S]{0,24}["']retention_days["']/.test(sink)) {
		errors.push(
			'linux/infra/logger_sink.lua: the retention window is not read ' +
				'from the shared registry — either it purges on a number of its own, which is ' +
				'what this gate exists to prevent, or it does not purge at all.'
		);
	}
	if (!/-mtime/.test(sink)) {
		errors.push(
			'linux/infra/logger_sink.lua: no age-based purge found. ' +
				'Rolling a file per day and deleting none grows the log directory without ' +
				'bound, and nothing else in this driver would ever notice.'
		);
	}
}

// ── ring_buffer_size ────────────────────────────────────────────────────────

check(
	'windows/infra/logger.ahk',
	'LOGGER_RING_BUFFER_SIZE',
	/LOGGER_RING_BUFFER_SIZE\s*:=\s*(\d+)/g,
	registry.logger.ring_buffer_size
);
check(
	'_shared/lua/logger/init.lua',
	'RING_CAPACITY',
	/\bRING_CAPACITY\s*=\s*(\d+)/g,
	registry.logger.ring_buffer_size
);
mustNotDeclare(
	'macos/infra/logger.lua',
	'RING_BUFFER_SIZE',
	/\bRING_BUFFER_SIZE\s*=\s*\d+/g,
	'the macOS driver delegates its ring to the shared core'
);

// ── dedup_window: the same duration, in two units ───────────────────────────

check(
	'windows/infra/logger.ahk',
	'LOGGER_DEDUP_WINDOW_MS',
	/LOGGER_DEDUP_WINDOW_MS\s*:=\s*(\d+)/g,
	registry.logger.dedup_window_ms
);
mustNotDeclare(
	'macos/infra/logger.lua',
	'DEDUP_WINDOW_SEC',
	/\bDEDUP_WINDOW_SEC\s*=\s*\d+/g,
	'the macOS driver delegates its suppression window to the shared core'
);

check(
	'_shared/lua/logger/init.lua',
	'DEDUP_WINDOW_SEC',
	/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/g,
	registry.logger.dedup_window_ms / 1000,
	'the shared core holds this in SECONDS — the registry value is milliseconds'
);

// The three must not merely each match the registry; they must denote the same
// duration. Stated separately because that is the invariant the comments claim,
// and the one nothing was checking. The shared core joined them on 2026-08-03:
// it had no dedup at all, so adopting it would have removed flood suppression
// from a driver that had it.
{
	const ms = Number((read('windows/infra/logger.ahk').match(/LOGGER_DEDUP_WINDOW_MS\s*:=\s*(\d+)/) || [])[1]);
	const sec = Number((read('macos/infra/logger.lua').match(/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/) || [])[1]);
	const coreSec = Number((read('_shared/lua/logger/init.lua').match(/\bDEDUP_WINDOW_SEC\s*=\s*(\d+)/) || [])[1]);
	if (Number.isFinite(ms) && Number.isFinite(sec) && ms !== sec * 1000) {
		errors.push(
			`the two dedup windows are different durations: AHK ${ms} ms vs HS ${sec} s (= ${sec * 1000} ms). ` +
				'Both files claim in a comment to mirror the other.'
		);
	}
	if (Number.isFinite(sec) && Number.isFinite(coreSec) && sec !== coreSec) {
		errors.push(
			`the macOS driver and the shared core disagree on the dedup window: ${sec} s vs ${coreSec} s. ` +
				'The core is what macOS is being migrated onto, so a difference here IS the migration failing.'
		);
	}
}

// And the cross-driver corpus must record the same window, or the vectors that
// exercise suppression would be measuring a duration no driver uses.
{
	const corpus = JSON.parse(read('_shared/tests/corpus/logger/behaviour_vectors.json'));
	const windowSec = corpus.dedup && corpus.dedup.window_seconds;
	if (windowSec !== registry.logger.dedup_window_ms / 1000) {
		errors.push(
			`the logger behaviour corpus records a ${windowSec} s dedup window, the registry says ` +
				`${registry.logger.dedup_window_ms / 1000} s. The vectors would exercise a duration nothing uses.`
		);
	}
}

// ── flush_interval_ms ───────────────────────────────────────────────────────

check(
	'windows/infra/logger.ahk',
	'LOGGER_FLUSH_INTERVAL_MS',
	/LOGGER_FLUSH_INTERVAL_MS\s*:=\s*(\d+)/g,
	registry.logger.flush_interval_ms
);

// ── No bare literal may creep back in ───────────────────────────────────────
//
// The whole failure was an unnamed number. A named constant that some other
// call site bypasses is the same failure wearing a better name.
{
	const hs = read('macos/infra/logger.lua');
	const bare = [...hs.matchAll(/_dedup\.time\)\s*<\s*(\d+)/g)];
	if (bare.length > 0) {
		errors.push(
			'macos/infra/logger.lua compares against the dedup window as a bare literal again — ' +
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
