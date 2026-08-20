// _shared/modules/tooltip/dequeue.js

/**
 * ==============================================================================
 * MODULE: Tooltip Dequeue Engine
 * DESCRIPTION:
 * Pure stacked-tooltip row-expiry logic for the Ergopti+ hotstring preview.
 * When a trigger produces multiple outputs with distinct display durations, each
 * row tracks its own absolute expiry; as deadlines pass, expired rows are pruned
 * and the surviving stack is re-rendered.
 *
 * EXAMPLE (output1 delay 1 s, output2 delay 2 s):
 *   t ∈ [0, 0.8 s]   — both rows visible (effective 1 s − 0.2 s decrement)
 *   t ∈ [0.8 s, 1.8 s] — only output2 visible (its effective window is 1.8 s)
 *
 * Both AHK (lib/tooltip.ahk) and Hammerspoon (ui/tooltip/tooltip_hotstring.lua)
 * MUST implement this module's contract. Test vectors in dequeueTestVectors()
 * are the cross-driver ground truth.
 * ==============================================================================
 */

'use strict';

const DEFAULT_TIMEOUT_DECREMENT_SEC = 0.2;
const DEFAULT_TIMEOUT_FLOOR_SEC = 0.05;
const MIN_TIMER_MS = 50;

/**
 * Shortens a caller duration by the shared decrement, with a hard floor.
 * @param {number} callerDurationSec
 * @param {object} [opts]
 * @returns {number} Effective display duration in seconds (0 when caller ≤ 0).
 */
function effectiveDurationSec(callerDurationSec, opts = {}) {
	const dec = opts.timeoutDecrementSec ?? DEFAULT_TIMEOUT_DECREMENT_SEC;
	const floor = opts.timeoutFloorSec ?? DEFAULT_TIMEOUT_FLOOR_SEC;
	if (!(callerDurationSec > 0)) return 0;
	return Math.max(floor, callerDurationSec - dec);
}

/**
 * @param {object} row
 * @param {string} field
 * @returns {number}
 */
function rowDurationSec(row, field) {
	const d = row[field];
	return typeof d === 'number' && d > 0 ? d : 0;
}

/**
 * @param {object} row
 * @param {string} expireField
 * @returns {boolean}
 */
function hasExpiryStamp(row, expireField) {
	const v = row[expireField];
	return v != null && v !== 0;
}

/**
 * Decides whether the dequeue (per-row expiry) path is required.
 * @param {object[]} rows
 * @param {object} [opts]
 *   - durationField: caller duration key (default "durationSec")
 *   - expireField: absolute expiry key (default "expireMs")
 * @returns {{ isRebuild: boolean, hasAnyDur: boolean, hasMixedDur: boolean }}
 */
function analyzeDurations(rows, opts = {}) {
	const durationField = opts.durationField ?? 'durationSec';
	const expireField = opts.expireField ?? 'expireMs';

	let isRebuild = false;
	for (const row of rows) {
		if (hasExpiryStamp(row, expireField)) {
			isRebuild = true;
			break;
		}
	}

	let firstDur = 0;
	let hasAnyDur = false;
	let hasMixedDur = false;

	if (!isRebuild) {
		for (const row of rows) {
			const d = rowDurationSec(row, durationField);
			if (d > 0) {
				hasAnyDur = true;
				if (firstDur === 0) firstDur = d;
				else if (d !== firstDur) hasMixedDur = true;
			}
		}
	}

	return { isRebuild, hasAnyDur, hasMixedDur };
}

/**
 * @param {object[]} rows
 * @param {object} [opts]
 * @returns {boolean}
 */
function shouldUseDequeuePath(rows, opts = {}) {
	const { isRebuild, hasAnyDur, hasMixedDur } = analyzeDurations(rows, opts);
	return isRebuild || (hasAnyDur && hasMixedDur);
}

/**
 * Stamps absolute expiry timestamps on shallow row copies.
 * @param {object[]} rows
 * @param {number} nowMs Monotonic clock in milliseconds.
 * @param {object} [opts]
 * @returns {{ rows: object[], maxRemainingMs: number }}
 */
function stampExpiryTimes(rows, nowMs, opts = {}) {
	const durationField = opts.durationField ?? 'durationSec';
	const expireField = opts.expireField ?? 'expireMs';
	const { isRebuild } = analyzeDurations(rows, opts);

	const stamped = [];
	let maxRemainingMs = 0;

	for (const row of rows) {
		const copy = { ...row };
		let expireMs;

		if (isRebuild && hasExpiryStamp(copy, expireField)) {
			expireMs = copy[expireField];
		} else {
			const d = rowDurationSec(row, durationField);
			if (d > 0) {
				const eff = effectiveDurationSec(d, opts);
				expireMs = nowMs + Math.round(eff * 1000);
			} else {
				expireMs = 0;
			}
		}

		copy[expireField] = expireMs;
		stamped.push(copy);

		if (expireMs > 0) {
			maxRemainingMs = Math.max(maxRemainingMs, Math.max(MIN_TIMER_MS, expireMs - nowMs));
		}
	}

	return { rows: stamped, maxRemainingMs };
}

/**
 * Removes rows whose expiry deadline has passed.
 * @param {object[]} rows
 * @param {number} nowMs
 * @param {object} [opts]
 * @returns {object[]}
 */
function pruneExpired(rows, nowMs, opts = {}) {
	const expireField = opts.expireField ?? 'expireMs';
	const remaining = [];
	for (const row of rows) {
		const exp = row[expireField];
		if (!exp || exp === 0 || nowMs < exp) {
			remaining.push(row);
		}
	}
	return remaining;
}

/**
 * Milliseconds until the earliest not-yet-expired row deadline.
 * @param {object[]} rows
 * @param {number} nowMs
 * @param {object} [opts]
 * @returns {number}
 */
function nextExpiryDelayMs(rows, nowMs, opts = {}) {
	const expireField = opts.expireField ?? 'expireMs';
	let earliest = null;
	for (const row of rows) {
		const exp = row[expireField];
		if (exp > 0 && nowMs < exp) {
			if (earliest == null || exp < earliest) earliest = exp;
		}
	}
	if (earliest == null) return 0;
	return Math.max(MIN_TIMER_MS, earliest - nowMs);
}

/**
 * Cross-driver test vectors. Each scenario exercises the 1 s / 2 s stacked
 * timing contract described in SPEC.md § 7.1.
 * @returns {Array<object>}
 */
function dequeueTestVectors() {
	return [
		{
			id: 'mixed_1s_2s_stacked_destuck',
			description: 'output1 (1 s) + output2 (2 s): both visible 0.8 s, then output2 alone 1.0 s.',
			rows: [
				{ id: 'out1', durationSec: 1 },
				{ id: 'out2', durationSec: 2 }
			],
			expectDequeue: true,
			steps: [
				{
					atMs: 0,
					action: 'stamp',
					expectIds: ['out1', 'out2'],
					expectExpiries: { out1: 800, out2: 1800 }
				},
				{
					atMs: 500,
					action: 'prune',
					expectIds: ['out1', 'out2']
				},
				{
					atMs: 800,
					action: 'prune',
					expectIds: ['out2'],
					expectNextDelayMs: 1000
				},
				{
					atMs: 1800,
					action: 'prune',
					expectIds: []
				}
			]
		},
		{
			id: 'identical_durations_simple_path',
			description: 'Equal durations → single global timer, no dequeue.',
			rows: [
				{ id: 'a', durationSec: 2 },
				{ id: 'b', durationSec: 2 }
			],
			expectDequeue: false
		},
		{
			id: 'single_positive_duration_simple_path',
			description: 'One finite + one zero-duration row → simple path (not mixed).',
			rows: [
				{ id: 'finite', durationSec: 1 },
				{ id: 'infinite', durationSec: 0 }
			],
			expectDequeue: false
		}
	];
}

module.exports = {
	DEFAULT_TIMEOUT_DECREMENT_SEC,
	DEFAULT_TIMEOUT_FLOOR_SEC,
	MIN_TIMER_MS,
	effectiveDurationSec,
	analyzeDurations,
	shouldUseDequeuePath,
	stampExpiryTimes,
	pruneExpired,
	nextExpiryDelayMs,
	dequeueTestVectors
};
