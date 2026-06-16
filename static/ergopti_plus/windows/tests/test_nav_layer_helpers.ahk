; static/ergopti_plus/windows/tests/test_nav_layer_helpers.ahk

; ==============================================================================
; MODULE: Navigation Layer Helpers Tests
; DESCRIPTION:
; Unit-tests for the five nav-layer state helpers extracted to
; lib/nav_layer_helpers.ahk: ActivateLayer, DisableLayer,
; SetNumberOfRepetitions, ResetNumberOfRepetitions, and ActionLayer.
; ==============================================================================





; ==========================================
; =========================================
; ======= 1/ Layer state management =======
; =========================================
; ==========================================

_NL_ActivateLayerSetsEnabled() {
	global LayerEnabled := false
	AppState["number_of_repetitions"] := 5
	ResetStubRecorders()
	ActivateLayer()
	AssertTrue(LayerEnabled)
}
Test("ActivateLayer: sets LayerEnabled to true", _NL_ActivateLayerSetsEnabled)

_NL_ActivateLayerResetsRepetitions() {
	global LayerEnabled := false
	AppState["number_of_repetitions"] := 7
	ResetStubRecorders()
	ActivateLayer()
	AssertEqual(1, AppState["number_of_repetitions"])
}
Test("ActivateLayer: resets NumberOfRepetitions to 1", _NL_ActivateLayerResetsRepetitions)

_NL_DisableLayerSetsDisabled() {
	global LayerEnabled := true
	ResetStubRecorders()
	DisableLayer()
	AssertFalse(LayerEnabled)
}
Test("DisableLayer: sets LayerEnabled to false", _NL_DisableLayerSetsDisabled)





; ==============================================
; =============================================
; ======= 2/ Repetition counter helpers =======
; =============================================
; ==============================================

_NL_SetRepetitionsSetsCounter() {
	AppState["number_of_repetitions"] := 1
	SetNumberOfRepetitions(4)
	AssertEqual(4, AppState["number_of_repetitions"])
}
Test("SetNumberOfRepetitions: sets the global counter", _NL_SetRepetitionsSetsCounter)

_NL_SetRepetitionsAcceptsTen() {
	SetNumberOfRepetitions(10)
	AssertEqual(10, AppState["number_of_repetitions"])
}
Test("SetNumberOfRepetitions: accepts value 10", _NL_SetRepetitionsAcceptsTen)

_NL_ResetRepetitionsResetsToOne() {
	AppState["number_of_repetitions"] := 9
	ResetNumberOfRepetitions()
	AssertEqual(1, AppState["number_of_repetitions"])
}
Test("ResetNumberOfRepetitions: resets counter to 1", _NL_ResetRepetitionsResetsToOne)

_NL_ResetRepetitionsIdempotent() {
	AppState["number_of_repetitions"] := 1
	ResetNumberOfRepetitions()
	AssertEqual(1, AppState["number_of_repetitions"])
}
Test("ResetNumberOfRepetitions: idempotent when already 1", _NL_ResetRepetitionsIdempotent)





; ===================================
; ===================================
; ======= 3/ ActionLayer stub =======
; ===================================
; ===================================

; ActionLayer calls SendInput then ResetNumberOfRepetitions.
; In the test runner SendInput is a real OS call — we only verify the
; side-effect that is safe to observe: AppState["number_of_repetitions"] is reset to 1.
_NL_ActionLayerResetsRepetitions() {
	AppState["number_of_repetitions"] := 3
	; Send a no-op key sequence that produces no visible effect in CI
	ActionLayer("{LShift}")
	AssertEqual(1, AppState["number_of_repetitions"])
}
Test("ActionLayer: resets NumberOfRepetitions after firing", _NL_ActionLayerResetsRepetitions)
