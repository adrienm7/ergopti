; modules/gestures/incremental.ahk

; ==============================================================================
; MODULE: Incremental Swipe Steps (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/lua/gestures/incremental.lua, the step rule the macOS engine
; and the Linux tracker count with: how many actions an incremental swipe has
; earned over the distance it travelled, and how far it must come back before
; it counts as a reversal. Distances are millimetres of travel on the pad.
;
; FEATURES & RATIONALE:
; 1. The first action fires once the swipe has travelled the smaller of
;    the first step (GestureIncrementalFirstStep) and the slot's step, each further one after
;    one more step.
; 2. A reversal needs half the first step, never less than the engine floor,
;    so lift-off drift neither reverses a swipe nor fires the opposite action.
; 3. Fail fast: a non-finite or non-positive input throws, as the shared module
;    raises, and an action count that would not be finite is refused.
; 4. Pinned by _shared/tests/corpus/gestures/incremental_steps.json, which the
;    macOS and Linux suites replay through the shared module and
;    tests/unit/modules/gestures/test_gesture_incremental_rule.ahk through this
;    port, constants included. The constants are the shared timings
;    registry's [gestures] incremental_* keys, read once.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Step rule ==============
; ===================================
; ===================================

; Travel before the first action of an incremental swipe (shared FIRST_STEP).
GestureIncrementalFirstStep() {
	static FirstStep := TimingsGetNumber("gestures", "incremental_first_step_mm")
	return FirstStep
}

; Bound on the actions one touch frame may earn (shared MAX_ACTIONS_PER_FRAME):
; an implausible sensor jump is refused, not truncated.
GestureIncrementalMaxActions() {
	static Bound := TimingsGet("gestures", "incremental_max_actions_per_frame")
	return Bound
}

; Smallest reversal an engine accepts (macOS LIVE_AXIS_MIN, Linux
; REVERSE_FLOOR_MM).
GestureIncrementalReverseFloor() {
	static FloorMm := TimingsGetNumber("gestures", "incremental_reverse_floor_mm")
	return FloorMm
}

; Whether a value is a finite number. NaN differs from itself and an infinity
; minus itself is NaN, so both fail the second test.
GestureIncrementalIsFinite(Value) {
	return (Value is Number) && Value = Value && (Value - Value) = 0
}

; Counts the incremental actions a swipe has earned over a distance.
; @param Distance {Number} Absolute travel along the swipe axis.
; @param StepSize {Number} Distance per action after the first (the sensitivity).
; @returns {Integer} The actions earned.
; @throws {ValueError} On a negative or non-finite distance, a non-positive or
;     non-finite step, or a count that would not be finite.
GestureIncrementalSteps(Distance, StepSize) {
	if !GestureIncrementalIsFinite(Distance) || Distance < 0
		throw ValueError("Incremental distance must be a finite non-negative number.")
	if !GestureIncrementalIsFinite(StepSize) || StepSize <= 0
		throw ValueError("Incremental step must be a finite positive number.")
	First := Min(GestureIncrementalFirstStep(), StepSize)
	if (Distance < First)
		return 0
	Count := (Distance - First) / StepSize
	if !GestureIncrementalIsFinite(Count)
		throw ValueError("Incremental action count is not finite.")
	return 1 + Floor(Count)
}

; Distance a swipe must come back from its last action before it counts as a
; reversal: half the first step, never less than the engine's floor.
; @param StepSize {Number} Distance per action after the first.
; @param FloorMm {Number} Smallest reversal distance the engine accepts.
; @returns {Number} The reversal distance.
GestureIncrementalReverseMin(StepSize, FloorMm) {
	return Max(FloorMm, Min(GestureIncrementalFirstStep(), StepSize) / 2)
}
