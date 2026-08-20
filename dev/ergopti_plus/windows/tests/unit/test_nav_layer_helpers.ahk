; static/ergopti_plus/windows/tests/unit/test_nav_layer_helpers.ahk

; ==============================================================================
; MODULE: Navigation Layer Helpers Tests
; DESCRIPTION:
; Unit-tests for the five nav-layer state helpers extracted to
; infra/nav_layer_helpers.ahk: ActivateLayer, DisableLayer,
; SetNumberOfRepetitions, ResetNumberOfRepetitions, and ActionLayer.
; ==============================================================================





; =========================================
; =========================================
; ======= 1/ Layer state management =======
; =========================================
; =========================================

_NL_ActivateLayerSetsEnabled() {
	global LayerEnabled := false
	global NumberOfRepetitions := 5
	global CapsWordEnabled := false
	ResetStubRecorders()
	ActivateLayer()
	AssertTrue(LayerEnabled)
}
Test("ActivateLayer: sets LayerEnabled to true", _NL_ActivateLayerSetsEnabled)

_NL_ActivateLayerResetsRepetitions() {
	global LayerEnabled := false
	global NumberOfRepetitions := 7
	global CapsWordEnabled := false
	ResetStubRecorders()
	ActivateLayer()
	AssertEqual(1, NumberOfRepetitions)
}
Test("ActivateLayer: resets NumberOfRepetitions to 1", _NL_ActivateLayerResetsRepetitions)

_NL_DisableLayerSetsDisabled() {
	global LayerEnabled := true
	global CapsWordEnabled := false
	ResetStubRecorders()
	DisableLayer()
	AssertFalse(LayerEnabled)
}
Test("DisableLayer: sets LayerEnabled to false", _NL_DisableLayerSetsDisabled)





; =============================================
; =============================================
; ======= 2/ Repetition counter helpers =======
; =============================================
; =============================================

_NL_SetRepetitionsSetsCounter() {
	global NumberOfRepetitions := 1
	SetNumberOfRepetitions(4)
	AssertEqual(4, NumberOfRepetitions)
}
Test("SetNumberOfRepetitions: sets the global counter", _NL_SetRepetitionsSetsCounter)

_NL_SetRepetitionsAcceptsTen() {
	SetNumberOfRepetitions(10)
	AssertEqual(10, NumberOfRepetitions)
}
Test("SetNumberOfRepetitions: accepts value 10", _NL_SetRepetitionsAcceptsTen)

_NL_ResetRepetitionsResetsToOne() {
	global NumberOfRepetitions := 9
	ResetNumberOfRepetitions()
	AssertEqual(1, NumberOfRepetitions)
}
Test("ResetNumberOfRepetitions: resets counter to 1", _NL_ResetRepetitionsResetsToOne)

_NL_ResetRepetitionsIdempotent() {
	global NumberOfRepetitions := 1
	ResetNumberOfRepetitions()
	AssertEqual(1, NumberOfRepetitions)
}
Test("ResetNumberOfRepetitions: idempotent when already 1", _NL_ResetRepetitionsIdempotent)





; ===================================
; ===================================
; ======= 3/ ActionLayer stub =======
; ===================================
; ===================================

; ActionLayer calls SendInput then ResetNumberOfRepetitions.
; In the test runner SendInput is a real OS call — we only verify the
; side-effect that is safe to observe: NumberOfRepetitions is reset to 1.
_NL_ActionLayerResetsRepetitions() {
	global NumberOfRepetitions := 3
	; Send a no-op key sequence that produces no visible effect in CI
	ActionLayer("{LShift}")
	AssertEqual(1, NumberOfRepetitions)
}
Test("ActionLayer: resets NumberOfRepetitions after firing", _NL_ActionLayerResetsRepetitions)




; =====================================================================
; =====================================================================
; ======= 4/ MaxHotkeysPerInterval symmetry (layer-rate-limit) ========
; =====================================================================
; =====================================================================

_NL_ActivateLayerRaisesLimit() {
	global LayerEnabled := false
	global CapsWordEnabled := false
	ResetStubRecorders()
	; Start from AHK's own low default so the raise is observable.
	A_MaxHotkeysPerInterval := 70
	ActivateLayer()
	AssertEqual(NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL, A_MaxHotkeysPerInterval,
		"ActivateLayer must RAISE A_MaxHotkeysPerInterval — bursts happen while the layer is held active, not while it is idle")
}
Test("ActivateLayer: raises A_MaxHotkeysPerInterval to the shared raised ceiling (layer-rate-limit)", _NL_ActivateLayerRaisesLimit)


_NL_DisableLayerRestoresRaisedLimit() {
	global LayerEnabled := true
	global CapsWordEnabled := false
	ResetStubRecorders()
	; Simulate a degraded ceiling to prove DisableLayer restores the single
	; raised boot-time value rather than leaving/lowering it to a different number.
	A_MaxHotkeysPerInterval := 70
	DisableLayer()
	AssertEqual(NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL, A_MaxHotkeysPerInterval,
		"DisableLayer must restore A_MaxHotkeysPerInterval to the same raised boot-time ceiling nav_layer.ahk set, not a different hardcoded number")
}
Test("DisableLayer: restores A_MaxHotkeysPerInterval to the raised boot-time ceiling (layer-rate-limit)", _NL_DisableLayerRestoresRaisedLimit)


_NL_ActivateDisableCycleNeverDropsBelowRaisedLimit() {
	global LayerEnabled := false
	global CapsWordEnabled := false
	ResetStubRecorders()
	A_MaxHotkeysPerInterval := 70
	ActivateLayer()
	DisableLayer()
	AssertEqual(NAV_LAYER_MAX_HOTKEYS_PER_INTERVAL, A_MaxHotkeysPerInterval,
		"After an Activate→Disable cycle A_MaxHotkeysPerInterval must remain at the raised ceiling, never clobbered back down toward the AHK default")
}
Test("Activate/DisableLayer cycle: A_MaxHotkeysPerInterval stays at the raised ceiling (layer-rate-limit)", _NL_ActivateDisableCycleNeverDropsBelowRaisedLimit)
