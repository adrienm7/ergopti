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




; ======================================================================
; ======================================================================
; ======= 2/ Immediate tap-hold layer ownership =======================
; ======================================================================
; ======================================================================

global _NL_ImmediateOrder := []
global _NL_ImmediateTicks := []
global _NL_ImmediateWaitResults := []
global _NL_ImmediateDownResults := []

_NL_ImmediateReset(Ticks, WaitResults, DownResults := []) {
	global _NL_ImmediateOrder := []
	global _NL_ImmediateTicks := Ticks.Clone()
	global _NL_ImmediateWaitResults := WaitResults.Clone()
	global _NL_ImmediateDownResults := DownResults.Clone()
}

_NL_ImmediateActivate() {
	global _NL_ImmediateOrder, LayerEnabled
	_NL_ImmediateOrder.Push("activate")
	LayerEnabled := true
	return true
}

_NL_ImmediateDisable() {
	global _NL_ImmediateOrder, LayerEnabled
	_NL_ImmediateOrder.Push("disable")
	LayerEnabled := false
}

_NL_ImmediateWait(KeyName, TimeoutSec) {
	global _NL_ImmediateOrder, _NL_ImmediateWaitResults, LayerEnabled
	AssertTrue(LayerEnabled,
		"LayerEnabled must be visible before the owner yields to the physical-release wait")
	AssertEqual(STUCK_MODIFIER_RELEASE_TIMEOUT_SEC, TimeoutSec,
		"Every release wait must retain the stuck-key timeout")
	_NL_ImmediateOrder.Push("wait")
	return _NL_ImmediateWaitResults.RemoveAt(1)
}

_NL_ImmediateIsDown(KeyName) {
	global _NL_ImmediateDownResults
	return _NL_ImmediateDownResults.RemoveAt(1)
}

_NL_ImmediateNow() {
	global _NL_ImmediateTicks
	return _NL_ImmediateTicks.RemoveAt(1)
}

_NL_ImmediateThrowingWait(KeyName, TimeoutSec) {
	throw Error("release seam failed")
}

_NL_ImmediateQuickTapDisablesBeforeTap() {
	global _NL_ImmediateOrder, LayerEnabled := false
	_NL_ImmediateReset([1000, 1050], [true])
	Result := TapHoldOwnImmediateLayer("SC038", 0.2,
		_NL_ImmediateWait, _NL_ImmediateIsDown, _NL_ImmediateNow,
		_NL_ImmediateActivate, _NL_ImmediateDisable)
	if Result["tap"]
		_NL_ImmediateOrder.Push("tap")
	AssertTrue(Result["activated"])
	AssertFalse(LayerEnabled)
	AssertEqual(4, _NL_ImmediateOrder.Length)
	AssertEqual("activate", _NL_ImmediateOrder[1])
	AssertEqual("wait", _NL_ImmediateOrder[2])
	AssertEqual("disable", _NL_ImmediateOrder[3])
	AssertEqual("tap", _NL_ImmediateOrder[4],
		"The tap must be emitted only after the layer owner has disabled the layer")
}
Test("tap-hold layer: key-down activates immediately and quick release taps after disable (tap-hold-layer-immediate)", _NL_ImmediateQuickTapDisablesBeforeTap)

_NL_ImmediateInterposedKeySeesLayer() {
	global LayerEnabled := false
	_NL_ImmediateReset([2000, 2300], [true])
	Result := TapHoldOwnImmediateLayer("SC038", 0.2,
		_NL_ImmediateWait, _NL_ImmediateIsDown, _NL_ImmediateNow,
		_NL_ImmediateActivate, _NL_ImmediateDisable)
	AssertFalse(Result["tap"], "A key held past the threshold must never emit its tap")
	AssertFalse(LayerEnabled)
}
Test("tap-hold layer: an interposed key before the threshold observes the active layer (tap-hold-layer-immediate)", _NL_ImmediateInterposedKeySeesLayer)

_NL_ImmediateReleaseWaitRearmsWhileHeld() {
	global _NL_ImmediateOrder, LayerEnabled := false
	_NL_ImmediateReset([3000, 5400], [false, true], [true])
	Result := TapHoldOwnImmediateLayer("SC038", 0.2,
		_NL_ImmediateWait, _NL_ImmediateIsDown, _NL_ImmediateNow,
		_NL_ImmediateActivate, _NL_ImmediateDisable)
	AssertFalse(Result["tap"])
	AssertEqual(4, _NL_ImmediateOrder.Length,
		"The bounded release wait must re-arm while the physical key remains down")
	AssertEqual("wait", _NL_ImmediateOrder[2])
	AssertEqual("wait", _NL_ImmediateOrder[3])
	AssertFalse(LayerEnabled)
}
Test("tap-hold layer: bounded release waits re-arm while held (tap-hold-layer-immediate)", _NL_ImmediateReleaseWaitRearmsWhileHeld)

_NL_ImmediateExceptionAlwaysDisables() {
	global _NL_ImmediateOrder, LayerEnabled := false
	_NL_ImmediateReset([4000], [])
	AssertThrows(() => TapHoldOwnImmediateLayer("SC038", 0.2,
		_NL_ImmediateThrowingWait, _NL_ImmediateIsDown, _NL_ImmediateNow,
		_NL_ImmediateActivate, _NL_ImmediateDisable),
		"A release seam exception must propagate after cleanup")
	AssertFalse(LayerEnabled)
	AssertEqual("disable", _NL_ImmediateOrder[_NL_ImmediateOrder.Length],
		"DisableLayer must remain in a finally")
}
Test("tap-hold layer: exceptions cannot leave the layer latched (tap-hold-layer-immediate)", _NL_ImmediateExceptionAlwaysDisables)





; =============================================
; =============================================
; ======= 3/ Repetition counter helpers =======
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
; ======= 4/ ActionLayer stub =======
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
; ======= 5/ MaxHotkeysPerInterval symmetry (layer-rate-limit) ========
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
