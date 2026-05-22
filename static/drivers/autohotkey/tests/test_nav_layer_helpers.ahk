; static/drivers/autohotkey/tests/test_nav_layer_helpers.ahk

; ==============================================================================
; MODULE: Navigation Layer Helpers Tests
; DESCRIPTION:
; Unit-tests for the five nav-layer state helpers extracted to
; lib/nav_layer_helpers.ahk: ActivateLayer, DisableLayer,
; SetNumberOfRepetitions, ResetNumberOfRepetitions, and ActionLayer.
; ==============================================================================




; ==========================================
; ==========================================
; ======= 1/ Layer state management =======
; ==========================================
; ==========================================

Test("ActivateLayer: sets LayerEnabled to true", () => {
	global LayerEnabled := false
	global NumberOfRepetitions := 5
	ResetStubRecorders()
	ActivateLayer()
	AssertTrue(LayerEnabled)
})

Test("ActivateLayer: resets NumberOfRepetitions to 1", () => {
	global LayerEnabled := false
	global NumberOfRepetitions := 7
	ResetStubRecorders()
	ActivateLayer()
	AssertEqual(1, NumberOfRepetitions)
})

Test("DisableLayer: sets LayerEnabled to false", () => {
	global LayerEnabled := true
	ResetStubRecorders()
	DisableLayer()
	AssertFalse(LayerEnabled)
})




; ==============================================
; ==============================================
; ======= 2/ Repetition counter helpers =======
; ==============================================
; ==============================================

Test("SetNumberOfRepetitions: sets the global counter", () => {
	global NumberOfRepetitions := 1
	SetNumberOfRepetitions(4)
	AssertEqual(4, NumberOfRepetitions)
})

Test("SetNumberOfRepetitions: accepts value 10", () => {
	SetNumberOfRepetitions(10)
	global NumberOfRepetitions
	AssertEqual(10, NumberOfRepetitions)
})

Test("ResetNumberOfRepetitions: resets counter to 1", () => {
	global NumberOfRepetitions := 9
	ResetNumberOfRepetitions()
	AssertEqual(1, NumberOfRepetitions)
})

Test("ResetNumberOfRepetitions: idempotent when already 1", () => {
	global NumberOfRepetitions := 1
	ResetNumberOfRepetitions()
	AssertEqual(1, NumberOfRepetitions)
})




; ===================================
; ===================================
; ======= 3/ ActionLayer stub =======
; ===================================
; ===================================

; ActionLayer calls SendInput then ResetNumberOfRepetitions.
; In the test runner SendInput is a real OS call — we only verify the
; side-effect that is safe to observe: NumberOfRepetitions is reset to 1.
Test("ActionLayer: resets NumberOfRepetitions after firing", () => {
	global NumberOfRepetitions := 3
	; Send a no-op key sequence that produces no visible effect in CI
	ActionLayer("{LShift}")
	AssertEqual(1, NumberOfRepetitions)
})
