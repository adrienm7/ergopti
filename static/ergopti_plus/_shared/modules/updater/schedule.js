// _shared/modules/updater/schedule.js

/**
 * ==============================================================================
 * MODULE: Automatic Update-Check Schedule (canonical)
 * DESCRIPTION:
 * Decides when an automatic update check is due from the wall clock, the
 * persisted check record and the timing of defaults.json. The shared Lua port
 * (_shared/lua/updater/schedule.lua, macOS and Linux) and the AHK port
 * (windows/modules/updater/schedule.ahk) replay schedule_vectors.json with it.
 *
 * FEATURES & RATIONALE:
 * 1. Persisted, not process-relative: the next check follows the last one
 *    recorded (last_check_at), so a restart mid-interval does not check at
 *    boot, and a machine that was off past its due time catches up once the
 *    boot delay has passed (started_at is the start or the last wake).
 * 2. A clock moved back (a record in the future) is not trusted: the check is
 *    due after the boot delay instead of waiting for a date that may be years
 *    away.
 * 3. Failures retry on failure_backoff_sec, never later than the interval, and
 *    do not count as a success.
 * 4. Deterministic jitter per install: a fold of the install seed and the last
 *    check time, bounded by jitter_percent of the interval and jitter_max_sec,
 *    in integer arithmetic every runtime computes exactly.
 * 5. Retired intervals snap to the nearest preset by ratio (a tie takes the
 *    longer preset), so a saved value always shows a ticked menu row.
 * 6. Pure: no clock, no storage, no timers; drivers pass the values in.
 * ==============================================================================
 */

'use strict';

// Largest prime below 2^31: every intermediate of the jitter fold stays an
// exact integer in IEEE doubles (JavaScript, LuaJIT) and in AHK's Int64.
const HASH_MODULUS = 2147483647;
const HASH_MULTIPLIER = 31;
const NEVER_CODE = 'never';

// The persisted check record, in the order sanitizeState reports dropped fields.
const STATE_FIELDS = [
	['last_check_at', 'time'],
	['last_success_at', 'time'],
	['failures', 'count'],
	['seed', 'seed'],
	['last_notified_tag', 'tag']
];

// Reported when the stored record is not an object at all.
const WHOLE_RECORD = 'check_state';

function isCount(value) {
	return Number.isInteger(value) && value >= 0;
}

// ==========================================
// ==========================================
// ======= 1/ Timing Validation ============
// ==========================================
// ==========================================

/**
 * Validates the timing section of defaults.json.
 * @param {Object} timing - defaults.json timing.
 * @return {boolean} true; throws an Error naming the first problem otherwise.
 */
function validateTiming(timing) {
	if (!timing || typeof timing !== 'object') throw new Error('timing must be an object');
	const presets = timing.check_interval_presets;
	if (!Array.isArray(presets) || presets.length < 2)
		throw new Error('check_interval_presets needs at least two presets');
	const codes = new Set();
	let previous = 0;
	presets.forEach((preset, index) => {
		if (!preset || typeof preset.code !== 'string' || !/^[a-z0-9]+$/.test(preset.code)) {
			throw new Error(`preset ${index} has no valid code`);
		}
		if (codes.has(preset.code)) throw new Error(`preset code ${preset.code} is declared twice`);
		codes.add(preset.code);
		if (!isCount(preset.seconds))
			throw new Error(`preset ${preset.code} must be a whole number of seconds`);
		const last = index === presets.length - 1;
		if (last !== (preset.code === NEVER_CODE))
			throw new Error(`the ${NEVER_CODE} preset must be the last one`);
		if (last !== (preset.seconds === 0)) throw new Error('only the last preset may be 0 seconds');
		if (!last) {
			if (preset.seconds <= previous)
				throw new Error('presets must be ordered from the shortest to the longest');
			previous = preset.seconds;
		}
	});
	if (!presets.some((preset) => preset.seconds === timing.default_check_interval_sec)) {
		throw new Error('default_check_interval_sec must be one of the presets');
	}
	if (!isCount(timing.boot_check_delay_sec))
		throw new Error('boot_check_delay_sec must be a whole number of seconds');
	if (!isCount(timing.jitter_percent) || timing.jitter_percent > 100)
		throw new Error('jitter_percent must be 0 to 100');
	if (!isCount(timing.jitter_max_sec))
		throw new Error('jitter_max_sec must be a whole number of seconds');
	const backoff = timing.failure_backoff_sec;
	if (
		!Array.isArray(backoff) ||
		backoff.length === 0 ||
		!backoff.every((s) => isCount(s) && s > 0)
	) {
		throw new Error('failure_backoff_sec must list positive whole seconds');
	}
	if (!isCount(timing.reevaluate_sec) || timing.reevaluate_sec === 0)
		throw new Error('reevaluate_sec must be positive');
	return true;
}

// ==========================================
// ==========================================
// ======= 2/ Presets ======================
// ==========================================
// ==========================================

/**
 * Snaps a saved interval to the nearest preset by ratio.
 * @param {number} seconds - Saved interval (0 = never).
 * @param {Object} timing - defaults.json timing.
 * @return {{seconds: number, code: string, snapped: boolean}}
 */
function snapInterval(seconds, timing) {
	if (!isCount(seconds)) throw new TypeError('an interval must be a whole number of seconds');
	const presets = timing.check_interval_presets;
	if (seconds === 0) {
		const never = presets[presets.length - 1];
		return { seconds: 0, code: never.code, snapped: false };
	}
	const positive = presets.slice(0, -1);
	let best = positive[0];
	if (seconds >= positive[positive.length - 1].seconds) {
		best = positive[positive.length - 1];
	} else if (seconds > best.seconds) {
		for (const preset of positive) {
			// ratio(p) = max(p, s) / min(p, s); compared by cross-multiplication,
			// exact because s lies between two presets here.
			const candidate = Math.max(preset.seconds, seconds) * Math.min(best.seconds, seconds);
			const current = Math.max(best.seconds, seconds) * Math.min(preset.seconds, seconds);
			if (candidate <= current) best = preset;
		}
	}
	return { seconds: best.seconds, code: best.code, snapped: best.seconds !== seconds };
}

// ==========================================
// ==========================================
// ======= 3/ State Record =================
// ==========================================
// ==========================================

/**
 * Keeps the valid fields of a stored check record.
 * @param {*} raw - The value read from the driver's Storage port.
 * @return {{state: Object, dropped: string[]}} dropped names every invalid field.
 */
function sanitizeState(raw) {
	if (raw === undefined || raw === null) return { state: {}, dropped: [] };
	if (typeof raw !== 'object' || Array.isArray(raw)) return { state: {}, dropped: [WHOLE_RECORD] };
	const state = {};
	const dropped = [];
	for (const [field, kind] of STATE_FIELDS) {
		if (!(field in raw)) continue;
		const value = raw[field];
		let valid = false;
		if (kind === 'time' || kind === 'count') valid = isCount(value);
		else if (kind === 'seed') valid = typeof value === 'string' && value !== '';
		else valid = typeof value === 'string';
		if (valid) state[field] = value;
		else dropped.push(field);
	}
	return { state, dropped };
}

/**
 * Returns the record after one check completed; the input is not modified.
 * @param {Object} state - Sanitized record.
 * @param {number} now - Completion time (epoch seconds).
 * @param {boolean} ok - Whether the check reached GitHub and read the list.
 * @return {Object}
 */
function recordCheck(state, now, ok) {
	const next = {};
	for (const [field] of STATE_FIELDS) {
		if (field in state) next[field] = state[field];
	}
	next.last_check_at = now;
	if (ok) {
		next.last_success_at = now;
		next.failures = 0;
	} else {
		next.failures = (next.failures || 0) + 1;
	}
	return next;
}

// ==========================================
// ==========================================
// ======= 4/ Due Time =====================
// ==========================================
// ==========================================

/**
 * Deterministic per-install jitter for one period.
 * @param {string} seed - Install seed.
 * @param {number} anchor - The last check time the period starts from.
 * @param {number} interval - Interval in seconds.
 * @param {Object} timing - defaults.json timing.
 * @return {number} Whole seconds in [0, span].
 */
function jitterSeconds(seed, anchor, interval, timing) {
	const span = Math.min(
		Math.floor((interval * timing.jitter_percent) / 100),
		timing.jitter_max_sec
	);
	if (span <= 0) return 0;
	let hash = 0;
	for (const byte of new TextEncoder().encode(`${seed}:${anchor}`)) {
		hash = (hash * HASH_MULTIPLIER + byte) % HASH_MODULUS;
	}
	return hash % (span + 1);
}

/**
 * When the next automatic check is due.
 * @param {Object} input
 * @param {number} input.now - Wall clock (epoch seconds).
 * @param {number} input.startedAt - Driver start or last wake (epoch seconds).
 * @param {number} input.interval - Interval in seconds (0 = never).
 * @param {Object} input.state - Sanitized check record.
 * @param {Object} input.timing - defaults.json timing.
 * @return {{dueAt: number|null, reason: string}} dueAt null means never.
 */
function nextDue({ now, startedAt, interval, state, timing }) {
	if (!(interval > 0)) return { dueAt: null, reason: 'never' };
	const earliest = startedAt + timing.boot_check_delay_sec;
	const last = state.last_check_at;
	if (last === undefined) return { dueAt: earliest, reason: 'first_check' };
	if (last > now) return { dueAt: earliest, reason: 'clock_moved_back' };
	const failures = state.failures || 0;
	let candidate;
	let reason;
	if (failures > 0) {
		const backoff = timing.failure_backoff_sec;
		candidate = last + Math.min(backoff[Math.min(failures, backoff.length) - 1], interval);
		reason = 'retry_after_failure';
	} else {
		candidate = last + interval + jitterSeconds(state.seed || '', last, interval, timing);
		reason = 'scheduled';
	}
	if (candidate < earliest) return { dueAt: earliest, reason: 'catch_up' };
	return { dueAt: candidate, reason };
}

/**
 * Seconds to wait before re-evaluating: never past the due time, never longer
 * than reevaluate_sec (a timer that slept through a suspend is corrected then).
 * @param {number} dueAt - Due time (epoch seconds).
 * @param {number} now - Wall clock (epoch seconds).
 * @param {Object} timing - defaults.json timing.
 * @return {number}
 */
function delayUntil(dueAt, now, timing) {
	return Math.max(0, Math.min(dueAt - now, timing.reevaluate_sec));
}

export {
	validateTiming,
	snapInterval,
	sanitizeState,
	recordCheck,
	jitterSeconds,
	nextDue,
	delayUntil
};
