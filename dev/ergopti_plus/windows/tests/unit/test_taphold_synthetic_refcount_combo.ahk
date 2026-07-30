; static/ergopti_plus/windows/tests/unit/test_taphold_synthetic_refcount_combo.ahk

; ==============================================================================
; MODULE: Regression — synthetic-modifier refcount survives combination holds
; DESCRIPTION:
; The tray hold picker offers combinations (« Ctrl + Maj »), and
; ResolveHoldModifierKey answers those with an Array of key names. Each per-key
; XxxHoldModKey() wrapper re-invokes the resolver on every press, so every hold
; site gets a FRESHLY ALLOCATED Array — and AHK v2 Map keys are identity-based
; for objects. Keying _TH_SyntheticHeldKeys on the value it is handed therefore
; gave each hold site a private counter that could never collide with another
; branch's: not with an identical combination, and not with the scalar "LCtrl"
; a second key was already holding. The reference counting degraded to
; "release on the first Up", which is precisely the failure it exists to
; prevent — the user keeps a key physically held while its modifier is gone,
; and every keystroke until release arrives unmodified.
;
; ROOT CAUSE ENCODED: the count must be per individual KEY NAME, never per
; caller-supplied value. Both shapes (scalar and combo) must share one counter
; for the same key name, so the Down is emitted only on 0->1 and the Up only
; on 1->0.
;
; SCOPE: behavioural. TapHoldSyntheticKeyDown/Up live in the tap-hold constants
; module, which the headless runner includes; the send primitive is swapped for
; a recorder (the _AHK_SendInput injection point test_stubs.ahk already owns) so
; the real emitted key events are asserted rather than the internal map.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===================================
; ===================================
; ======= 1/ Recorder fixture =======
; ===================================
; ===================================

global _TSRC_Sent := []   ; Every payload handed to the send primitive, in order

; Stands in for _AHK_SendInput so "{LCtrl Down}" / "{LCtrl Up}" can be counted.
_TSRC_Record(Keys) {
	global _TSRC_Sent
	_TSRC_Sent.Push(Keys)
	return 0
}

_TSRC_Begin() {
	global _AHK_SendInput, _TSRC_Sent, _TH_SyntheticHeldKeys
	_TSRC_Sent := []
	_TH_SyntheticHeldKeys := Map()
	_AHK_SendInput := _TSRC_Record
}

; Restores the suite-wide no-op installed by InstallSendNoOps and leaves no
; synthetic key logically held for the next test.
_TSRC_End() {
	global _AHK_SendInput, _TH_SyntheticHeldKeys
	_AHK_SendInput := (Keys) => 0
	_TH_SyntheticHeldKeys := Map()
}

_TSRC_Count(Payload) {
	global _TSRC_Sent
	N := 0
	for _, Sent in _TSRC_Sent {
		if (Sent == Payload)
			N++
	}
	return N
}





; ============================================================
; ============================================================
; ======= 2/ Overlapping holds share one count per key =======
; ============================================================
; ============================================================

; A combo hold and a single-modifier hold that overlap on LCtrl: the reported
; failure, reduced. CapsLock holds « Ctrl + Maj », then Tab holds « Ctrl » and
; is released first.
_TSRC_ComboKeepsCtrlWhenOverlappingSingleHoldReleases() {
	global _TH_SyntheticHeldKeys
	_TSRC_Begin()
	try {
		Combo := ResolveHoldModifierKey("ctrl+shift", "caps_lock")
		AssertEqual("Array", Type(Combo),
			"the hold picker offers combinations, so the resolver must still answer ctrl+shift with an Array — everything below is vacuous otherwise")
		Single := ResolveHoldModifierKey("ctrl", "tab")

		TapHoldSyntheticKeyDown(Combo)
		TapHoldSyntheticKeyDown(Single)
		AssertEqual(1, _TSRC_Count("{LCtrl Down}"),
			"the second owner of LCtrl must not re-inject a Down — the shared count, not the caller, decides the 0->1 transition")

		TapHoldSyntheticKeyUp(Single)
		AssertEqual(0, _TSRC_Count("{LCtrl Up}"),
			"releasing the Tab hold must NOT release LCtrl while the CapsLock combo still owns it — counting the Array object instead of the key names gives every hold site a private entry and turns reference counting into release-on-first-Up")

		TapHoldSyntheticKeyUp(Combo)
		AssertEqual(1, _TSRC_Count("{LCtrl Up}"),
			"the last owner's release must actually release LCtrl")
		AssertEqual(1, _TSRC_Count("{LShift Up}"),
			"and must release every key of the combination exactly once")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count,
			"no synthetic key may stay logically held once every owner has released")
	}
	finally {
		_TSRC_End()
	}
}

; Two hold sites configured with the SAME combination resolve to two distinct
; Array objects, so identity-keyed counting could never coalesce them either.
_TSRC_TwoResolutionsOfSameComboShareTheirCounts() {
	global _TH_SyntheticHeldKeys
	_TSRC_Begin()
	try {
		A := ResolveHoldModifierKey("ctrl+shift", "caps_lock")
		B := ResolveHoldModifierKey("ctrl+shift", "tab")

		TapHoldSyntheticKeyDown(A)
		TapHoldSyntheticKeyDown(B)
		AssertEqual(2, _TH_SyntheticHeldKeys.Count,
			"two overlapping holds of the same combination must share one counter per KEY NAME (LCtrl, LShift) — a value-keyed map allocates a private entry per resolution")
		AssertEqual(1, _TSRC_Count("{LShift Down}"),
			"the combination must not be pressed twice at the OS level")

		TapHoldSyntheticKeyUp(A)
		AssertEqual(0, _TSRC_Count("{LCtrl Up}"),
			"the first release must leave both modifiers held for the branch that still owns them")
		AssertEqual(0, _TSRC_Count("{LShift Up}"),
			"the first release must leave both modifiers held for the branch that still owns them")

		TapHoldSyntheticKeyUp(B)
		AssertEqual(1, _TSRC_Count("{LCtrl Up}"), "the final release must release LCtrl once")
		AssertEqual(1, _TSRC_Count("{LShift Up}"), "the final release must release LShift once")
	}
	finally {
		_TSRC_End()
	}
}

; The scalar path is the one that always worked; the per-key rewrite must not
; have changed it.
_TSRC_ScalarRefcountStillBalances() {
	global _TH_SyntheticHeldKeys
	_TSRC_Begin()
	try {
		TapHoldSyntheticKeyDown("LAlt")
		TapHoldSyntheticKeyDown("LAlt")
		AssertEqual(1, _TSRC_Count("{LAlt Down}"),
			"a scalar modifier is still pressed once for two overlapping owners")

		TapHoldSyntheticKeyUp("LAlt")
		AssertEqual(0, _TSRC_Count("{LAlt Up}"),
			"the first of two owners releasing must not release the modifier")

		TapHoldSyntheticKeyUp("LAlt")
		AssertEqual(1, _TSRC_Count("{LAlt Up}"),
			"the last owner releasing must release the modifier")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count)
	}
	finally {
		_TSRC_End()
	}
}

; A suspend cleanup drains the map; the surviving finally must still be able to
; re-balance an untracked key without throwing, for both shapes.
_TSRC_UntrackedReleaseStillBalancesEveryKeyOfACombo() {
	_TSRC_Begin()
	try {
		TapHoldSyntheticKeyUp(ResolveHoldModifierKey("ctrl+shift", "caps_lock"))
		AssertEqual(1, _TSRC_Count("{LCtrl Up}"),
			"an untracked combo release must still balance every key it owns, not just the set as a whole")
		AssertEqual(1, _TSRC_Count("{LShift Up}"),
			"an untracked combo release must still balance every key it owns, not just the set as a whole")
	}
	finally {
		_TSRC_End()
	}
}


Test("taphold-synthetic-refcount: a combo hold keeps LCtrl down when an overlapping single hold releases",
	_TSRC_ComboKeepsCtrlWhenOverlappingSingleHoldReleases)
Test("taphold-synthetic-refcount: two resolutions of the same combination share their counts",
	_TSRC_TwoResolutionsOfSameComboShareTheirCounts)
Test("taphold-synthetic-refcount: the scalar refcount still balances",
	_TSRC_ScalarRefcountStillBalances)
Test("taphold-synthetic-refcount: an untracked combo release balances every key of the combination",
	_TSRC_UntrackedReleaseStillBalancesEveryKeyOfACombo)
