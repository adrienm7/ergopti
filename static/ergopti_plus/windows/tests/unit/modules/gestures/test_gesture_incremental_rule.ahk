; tests/unit/modules/gestures/test_gesture_incremental_rule.ahk

; ==============================================================================
; MODULE: Incremental Swipe Rules (Windows ports)
; DESCRIPTION:
; Replays _shared/tests/corpus/gestures/incremental_steps.json, which the
; macOS and Linux suites replay through _shared/lua/gestures/incremental.lua,
; through modules/gestures/incremental.ahk, constants included; replays the
; boundary vectors of _shared/tests/corpus/gestures/direction_vectors.json
; through modules/gestures/direction.ahk; and pins the Windows sensitivity
; choices to the shared menu corpus.
;
; ROOT CAUSE ENCODED:
; Windows had no step rule at all: its swipes arrived finished from the
; Precision Touchpad settings. A port with no shared vectors would drift from
; the rule macOS and Linux count with, one millimetre at a time.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================
; ============================================
; ======= 1/ The shared step rule ============
; ============================================
; ============================================

; @returns {Map} One decoded corpus under _shared/tests/corpus.
_GIR_Corpus(Relative) {
	global _SharedDir
	AssertTrue(IsSet(_SharedDir), "the harness must expose _SharedDir")
	Path := _SharedDir . "\tests\corpus\" . Relative
	AssertTrue(FileExist(Path) != "", "the corpus must exist at " . Path)
	return JsonParse(FileRead(Path, "UTF-8"))
}

_GIR_StepConstants() {
	Corpus := _GIR_Corpus("gestures\incremental_steps.json")
	; The port reads them from the shared timings registry: the corpus pins the
	; registry to the Lua constants macOS and Linux count with.
	AssertEqual(Corpus["first_step"], GestureIncrementalFirstStep(), "first step")
	AssertEqual(Corpus["max_actions_per_frame"], GestureIncrementalMaxActions(), "frame bound")
	AssertEqual(Corpus["reverse_floor_mm"], GestureIncrementalReverseFloor(), "reversal floor")
	Rule := _GIR_Corpus("gestures\direction_vectors.json")["boundary_rule"]
	AssertEqual(Rule["axis_max_degrees"], GestureDirectionAxisMaxDegrees(), "straight-axis sector")
	AssertEqual(Rule["diagonal_minimum"], GestureDirectionDiagonalFactor(), "diagonal factor")
}
Test("incremental rule: the port holds the corpus constants (incremental-step-vectors)", _GIR_StepConstants)

_GIR_StepVectors() {
	Corpus := _GIR_Corpus("gestures\incremental_steps.json")
	Checked := 0
	for Vector in Corpus["steps"] {
		AssertEqual(Vector["steps"], GestureIncrementalSteps(Vector["distance"], Vector["step"]), Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 15, "expected the step vectors, found " . Checked)
	Checked := 0
	for Vector in Corpus["reverse_min"] {
		AssertEqual(Vector["reverse_min"], GestureIncrementalReverseMin(Vector["step"], Vector["floor"]), Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 5, "expected the reversal vectors, found " . Checked)
}
Test("incremental rule: the port counts every corpus vector (incremental-step-vectors)", _GIR_StepVectors)

; One invalid vector per call, so the refused call reads a parameter rather
; than a for-loop variable a closure cannot see.
_GIR_RefusesVector(Vector) {
	AssertThrows(() => GestureIncrementalSteps(Vector["distance"], Vector["step"]), Vector["id"] . " must be refused")
}

_GIR_RefusesInvalid() {
	Corpus := _GIR_Corpus("gestures\incremental_steps.json")
	Refused := 0
	for Vector in Corpus["invalid"] {
		_GIR_RefusesVector(Vector)
		Refused += 1
	}
	AssertTrue(Refused >= 3, "expected the invalid vectors, found " . Refused)
	; Non-finite numbers, which JSON cannot carry, and a step so small the
	; count would overflow.
	Huge := 1.0e308 * 10
	AssertThrows(() => GestureIncrementalSteps(Huge, 3.5), "an infinite distance")
	AssertThrows(() => GestureIncrementalSteps(10, Huge), "an infinite step")
	AssertThrows(() => GestureIncrementalSteps("10", 3.5), "a non-numeric distance")
	AssertThrows(() => GestureIncrementalSteps(10, "x"), "a non-numeric step")
	AssertThrows(() => GestureIncrementalSteps(10, 1.0e-320), "an overflowing count")
	AssertFalse(GestureIncrementalIsFinite(Huge - Huge), "NaN is not finite")
}
Test("incremental rule: the port refuses every invalid input (incremental-step-vectors)", _GIR_RefusesInvalid)





; ============================================
; ============================================
; ======= 2/ The shared direction rule =======
; ============================================
; ============================================

_GIR_DirectionBoundaries() {
	Corpus := _GIR_Corpus("gestures\direction_vectors.json")
	Rule := Corpus["boundary_rule"]
	Checked := 0
	for Vector in Corpus["boundary_vectors"] {
		Expected := Vector["direction"] == JSON_NULL ? "" : Vector["direction"]
		Actual := GestureDirectionClassify(Vector["dx"], Vector["dy"], Rule["minimum"], Rule["diagonal_minimum"])
		AssertEqual(Expected, Actual, Vector["id"])
		Checked += 1
	}
	AssertTrue(Checked >= 15, "expected the boundary vectors, found " . Checked)
}
Test("incremental rule: the direction port replays the boundary vectors (incremental-step-vectors)", _GIR_DirectionBoundaries)

; The angle vectors: the unit vector scaled to four swipe minimums (a swipe)
; or a quarter of one (no swipe), as the macOS and Linux replays scale theirs.
_GIR_DirectionAngles() {
	Corpus := _GIR_Corpus("gestures\direction_vectors.json")
	Minimum := 1.5
	Checked := 0
	for Vector in Corpus["vectors"] {
		Radians := Vector["angle"] * 3.141592653589793 / 180
		Scale := (Vector["travel"] = "swipe" ? 4 : 0.25) * Minimum
		Actual := GestureDirectionClassify(Cos(Radians) * Scale, Sin(Radians) * Scale, Minimum,
			Minimum * GestureDirectionDiagonalFactor())
		Expected := Vector["direction"] == JSON_NULL ? "" : Vector["direction"]
		AssertEqual(Expected, Actual, "angle " . Vector["angle"] . " " . Vector["travel"])
		Checked += 1
	}
	AssertTrue(Checked >= 15, "expected the angle vectors, found " . Checked)
}
Test("incremental rule: the direction port names every corpus angle (incremental-step-vectors)", _GIR_DirectionAngles)

_GIR_LiveAxisWaitsForTheDiagonalMinimum() {
	; In the diagonal sector below the diagonal minimum a live swipe has no
	; axis yet, while a finished one takes its dominant axis.
	AssertEqual("", GestureDirectionDecidedAxis(0.8, 0.6, 1, 1.5), "undecided while moving")
	AssertEqual("horiz", GestureDirectionAxis(0.8, 0.6, 1, 1.5), "dominant once finished")
	AssertEqual("diag", GestureDirectionDecidedAxis(0.9, 0.7, 1, 1.5), "a diagonal at its minimum")
	AssertEqual("left", GestureDirectionDominant(-2, 1), "dominant straight direction")
	AssertEqual("right", GestureDirectionDominant(1, 1), "a tie is horizontal")
	; Travel along a direction's own axis signs its reversal alike.
	AssertEqual(3, GestureDirectionAlong("left", 3, 9), "horizontal travel")
	AssertEqual(-2, GestureDirectionAlong("up", 5, -2), "vertical travel")
	AssertTrue(Abs(GestureDirectionAlong("right_up", 1, -1) - Sqrt(2)) < 1e-9, "the right_up axis")
	AssertTrue(Abs(GestureDirectionAlong("left_down", -1, 1) + Sqrt(2)) < 1e-9, "its reversal signs negative")
	AssertThrows(() => GestureDirectionAlong("sideways", 1, 1), "an unknown direction")
	AssertThrows(() => GestureDirectionDecidedAxis(1, 1, 2, 1), "a diagonal minimum below the minimum")
}
Test("incremental rule: a live swipe waits for its diagonal minimum (incremental-step-vectors)", _GIR_LiveAxisWaitsForTheDiagonalMinimum)

_GIR_MinimumsFromTheRegistry() {
	Registry := Map("swipe_minimum_mm", 1.5, "pair_swipe_minimum_mm", 3.0, "pair_diagonal_minimum_mm", 5.0)
	GestureDirectionMinimumsMm(3, Registry, &Minimum, &Diagonal)
	AssertEqual(1.5, Minimum, "three fingers")
	AssertEqual(2.25, Diagonal, "three fingers' diagonal")
	GestureDirectionMinimumsMm(2, Registry, &Minimum, &Diagonal)
	AssertEqual(3.0, Minimum, "a pair")
	AssertEqual(5.0, Diagonal, "a pair's diagonal")
	AssertThrows(() => GestureDirectionMinimumsMm(1, Registry, &Minimum, &Diagonal), "one finger")
	AssertThrows(() => GestureDirectionMinimumsMm(3, Map("swipe_minimum_mm", 1.5), &Minimum, &Diagonal), "a partial registry")
	; The live values come from the shared timings registry, as a number:
	; TimingsGet would truncate 1.5 mm to 1.
	AssertEqual(1.5, TimingsGetNumber("gestures", "swipe_minimum_mm"), "the shared swipe minimum")
	AssertThrows(() => TimingsGetNumber("gestures", "no_such_minimum_mm"), "a missing timing")
}
Test("incremental rule: the swipe minimums come from the timings registry (incremental-step-vectors)", _GIR_MinimumsFromTheRegistry)

_GIR_SensitivityChoices() {
	Corpus := _GIR_Corpus("menus\gesture_slot_controls.json")
	Expected := Corpus["sensitivity_values"]
	AssertEqual(Expected.Length, GESTURE_SENSITIVITY_OPTIONS.Length, "as many choices as the shared menu")
	for Index, Value in Expected
		AssertEqual(Value, GESTURE_SENSITIVITY_OPTIONS[Index], "choice " . Index)
	AssertEqual(3.5, GestureCoerceSensitivity(3.5), "a choice")
	AssertEqual(7.25, GestureCoerceSensitivity("7.25"), "a hand-edited value inside the range")
	AssertEqual("", GestureCoerceSensitivity(0.5), "below the range")
	AssertEqual("", GestureCoerceSensitivity(61), "above the range")
	AssertEqual("", GestureCoerceSensitivity("fast"), "not a number")
}
Test("incremental rule: the sensitivity choices are the shared ones (incremental-step-vectors)", _GIR_SensitivityChoices)
