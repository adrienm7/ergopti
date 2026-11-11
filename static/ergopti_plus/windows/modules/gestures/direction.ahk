; modules/gestures/direction.ahk

; ==============================================================================
; MODULE: Gesture Direction (AutoHotkey port)
; DESCRIPTION:
; Port of _shared/lua/gestures/direction.lua, the classifier the macOS
; geometry and the Linux decoder share: a swipe displacement becomes the axis
; it travelled on, the direction name a slot carries, and its signed travel
; along that direction. The Windows incremental tracker
; (modules/gestures/incremental_tracker.ahk) classifies live raw-input travel
; through it, in millimetres.
;
; FEATURES & RATIONALE:
; 1. Same sectors as the shared module: within the shared sector angle
;    of an axis a swipe is straight; between the two it is a diagonal once it
;    has travelled the diagonal minimum. Both boundaries are inclusive of the
;    straight axis.
; 2. Manhattan travel (|dx| + |dy|) for both minimums, as on macOS and Linux.
; 3. Screen convention: y grows downward, so a positive dy is "down"; a
;    diagonal names its horizontal part first (right_down).
; 4. Pinned by _shared/tests/corpus/gestures/direction_vectors.json, which
;    tests/unit/modules/gestures/test_gesture_incremental_rule.ahk replays.
;    The sector angle and the diagonal factor are the shared timings
;    registry's [gestures] swipe_axis_max_degrees and
;    swipe_diagonal_minimum_factor, read once.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Axis and names =========
; ===================================
; ===================================

; Within this angle of the horizontal axis a swipe is horizontal, and within
; this angle of the vertical axis it is vertical (shared AXIS_MAX_DEGREES).
GestureDirectionAxisMaxDegrees() {
	static Degrees := TimingsGetNumber("gestures", "swipe_axis_max_degrees")
	return Degrees
}

; A three-finger or larger swipe's diagonal minimum as a multiple of its swipe
; minimum (shared DIAGONAL_MINIMUM_FACTOR).
GestureDirectionDiagonalFactor() {
	static Factor := TimingsGetNumber("gestures", "swipe_diagonal_minimum_factor")
	return Factor
}

; Rejects a minimum pair the shared module would refuse.
_GestureDirectionCheckMinimums(Minimum, DiagonalMinimum) {
	if !(Minimum is Number) || Minimum <= 0
		throw ValueError("The swipe minimum must be a positive number.")
	if !(DiagonalMinimum is Number) || DiagonalMinimum < Minimum
		throw ValueError("The diagonal minimum must be a number no smaller than the swipe minimum.")
}

; The axis a swipe has already committed to, for a live lock: nil (an empty
; string) while it is below the minimum or, in the diagonal sector, below the
; diagonal minimum. Mirrors direction.decided_axis.
; @param Dx {Number} Horizontal displacement, positive rightward.
; @param Dy {Number} Vertical displacement, positive downward.
; @param Minimum {Number} Least Manhattan travel that is a swipe at all.
; @param DiagonalMinimum {Number} Least Manhattan travel that may be a diagonal.
; @returns {String} "horiz", "vert", "diag" or "" while undecided.
GestureDirectionDecidedAxis(Dx, Dy, Minimum, DiagonalMinimum) {
	if !(Dx is Number) || !(Dy is Number)
		throw TypeError("A displacement needs numeric dx and dy.")
	_GestureDirectionCheckMinimums(Minimum, DiagonalMinimum)
	AxisMax := GestureDirectionAxisMaxDegrees()
	Adx := Abs(Dx), Ady := Abs(Dy)
	Travel := Adx + Ady
	if (Travel < Minimum)
		return ""
	; atan2(ady, adx) for non-negative arguments, in degrees.
	Angle := Adx = 0 ? 90.0 : ATan(Ady / Adx) * 180 / 3.141592653589793
	if (Angle >= 90 - AxisMax)
		return "vert"
	if (Angle <= AxisMax)
		return "horiz"
	if (Travel >= DiagonalMinimum)
		return "diag"
	return ""
}

; The axis of a finished swipe: as GestureDirectionDecidedAxis, but a short
; swipe in the diagonal sector takes its dominant axis. Mirrors direction.axis.
; @returns {String} "horiz", "vert", "diag" or "" below the minimum.
GestureDirectionAxis(Dx, Dy, Minimum, DiagonalMinimum) {
	Decided := GestureDirectionDecidedAxis(Dx, Dy, Minimum, DiagonalMinimum)
	if (Decided != "")
		return Decided
	if (Abs(Dx) + Abs(Dy) < Minimum)
		return ""
	return Abs(Dx) >= Abs(Dy) ? "horiz" : "vert"
}

; Names the direction of a displacement already classified on an axis.
; @param Axis {String} "horiz", "vert" or "diag".
; @returns {String} right, left, down, up or a horizontal_vertical diagonal.
GestureDirectionName(Axis, Dx, Dy) {
	Horizontal := Dx > 0 ? "right" : "left"
	Vertical := Dy > 0 ? "down" : "up"
	switch Axis, true {
		case "horiz": return Horizontal
		case "vert": return Vertical
		case "diag": return Horizontal . "_" . Vertical
	}
	throw ValueError("Unknown swipe axis: " . Axis)
}

; Classifies a displacement straight to its direction name.
; @returns {String} The direction, or "" below the minimum.
GestureDirectionClassify(Dx, Dy, Minimum, DiagonalMinimum) {
	Axis := GestureDirectionAxis(Dx, Dy, Minimum, DiagonalMinimum)
	return Axis = "" ? "" : GestureDirectionName(Axis, Dx, Dy)
}

; The straight direction of a displacement's dominant axis, the slot an
; unbound diagonal falls back to; a tie is horizontal.
GestureDirectionDominant(Dx, Dy) {
	if !(Dx is Number) || !(Dy is Number)
		throw TypeError("A displacement needs numeric dx and dy.")
	return GestureDirectionName(Abs(Dx) >= Abs(Dy) ? "horiz" : "vert", Dx, Dy)
}





; ===================================
; ===================================
; ======= 2/ Travel and minimums ====
; ===================================
; ===================================

; Signed travel of a displacement along a direction's own axis: positive
; rightward, downward, toward right_down or toward right_up. Both directions of
; one axis share its unit vector, so a swipe and its reversal sign alike.
; @param Name {String} A direction name.
; @returns {Number} The projection on that axis.
GestureDirectionAlong(Name, Dx, Dy) {
	static InvSqrt2 := 1 / Sqrt(2)
	switch Name, true {
		case "right", "left": return Dx
		case "down", "up": return Dy
		case "right_down", "left_up": return (Dx + Dy) * InvSqrt2
		case "right_up", "left_down": return (Dx - Dy) * InvSqrt2
	}
	throw ValueError("Unknown swipe direction: " . Name)
}

; The least travel, in millimetres, of a swipe of a finger count, from the
; shared timings registry's [gestures] *_minimum_mm keys (maintainer decision
; GSD-3): a pair has its own, the others a factor of the swipe minimum.
; @param Fingers {Integer} Finger count, from 2.
; @param Registry {Map} swipe_minimum_mm, pair_swipe_minimum_mm, pair_diagonal_minimum_mm.
; @param Minimum {VarRef} Receives the swipe minimum.
; @param DiagonalMinimum {VarRef} Receives the diagonal minimum.
GestureDirectionMinimumsMm(Fingers, Registry, &Minimum, &DiagonalMinimum) {
	if !(Fingers is Integer) || Fingers < 2
		throw ValueError("A swipe needs two fingers or more.")
	if !(Registry is Map)
		throw TypeError("The swipe minimums are read from the timings registry.")
	for Key in ["swipe_minimum_mm", "pair_swipe_minimum_mm", "pair_diagonal_minimum_mm"] {
		if !Registry.Has(Key) || !(Registry[Key] is Number) || Registry[Key] <= 0
			throw ValueError("The timings registry has no " . Key . ".")
	}
	if (Fingers = 2) {
		Minimum := Registry["pair_swipe_minimum_mm"]
		DiagonalMinimum := Registry["pair_diagonal_minimum_mm"]
		return
	}
	Minimum := Registry["swipe_minimum_mm"]
	DiagonalMinimum := Registry["swipe_minimum_mm"] * GestureDirectionDiagonalFactor()
}
