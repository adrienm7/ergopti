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
; ROOT CAUSES ENCODED: the count must be per individual KEY NAME, never per
; caller-supplied value; a 0->1 combination is one sender transaction whose
; counts publish only after success; and a failed 1->0 transition remains in a
; separate release-pending ledger until a bounded retry proves the Up.
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
	global _AHK_SendInput, _TSRC_Sent
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_TSRC_Sent := []
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
	_AHK_SendInput := _TSRC_Record
}

; Restores the suite-wide no-op installed by InstallSendNoOps and leaves no
; synthetic key logically held for the next test.
_TSRC_End() {
	global _AHK_SendInput
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_AHK_SendInput := (Keys) => 0
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
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

; Records every low-level attempt and throws on the second modifier Down. The
; adapter catches the exception, then its Array transaction rolls LCtrl back.
_TSRC_FailSecondDown(Keys) {
	global _TSRC_Sent
	_TSRC_Sent.Push(Keys)
	if (Keys == "{LShift Down}")
		throw Error("injected second modifier Down failure")
}

; The full AHK-03 repro: the second Down fails, then the compensating Up for
; the first successful Down fails too. The first key may remain down at the OS
; and must therefore survive as an explicit release-pending owner.
_TSRC_FailSecondDownAndRollback(Keys) {
	global _TSRC_Sent
	_TSRC_Sent.Push(Keys)
	if (Keys == "{LShift Down}" or Keys == "{LCtrl Up}")
		throw Error("injected Down/rollback failure")
}

; Records every low-level attempt and rejects every synthetic Up so the test
; can prove both the retry bound and ownership retention after exhaustion.
_TSRC_FailEveryUp(Keys) {
	global _TSRC_Sent
	_TSRC_Sent.Push(Keys)
	if InStr(Keys, " Up}")
		throw Error("injected synthetic Up failure")
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





; ============================================================
; ============================================================
; ======= 3/ Send failures preserve truthful ownership =======
; ============================================================
; ============================================================

; AHK-03: the old tap-hold loop incremented both counters before making two
; scalar sends. A failure on LShift therefore returned true, skipped the
; sender's Array rollback, and left two fictional owners over one OS Down.
_TSRC_FailedComboDownRollsBackBeforePublishing() {
	global _AHK_SendInput, _TSRC_Sent
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_TSRC_Begin()
	try {
		_AHK_SendInput := _TSRC_FailSecondDown
		Ok := TapHoldSyntheticKeyDown(["LCtrl", "LShift"])

		AssertEqual(false, Ok,
			"a failed 0->1 combination transaction must return false")
		AssertEqual(3, _TSRC_Sent.Length,
			"the sender must attempt two Downs and exactly one rollback")
		AssertEqual("{LCtrl Down}", _TSRC_Sent[1],
			"the first modifier Down must lead the transaction")
		AssertEqual("{LShift Down}", _TSRC_Sent[2],
			"the deterministic seam must fail on the second modifier Down")
		AssertEqual("{LCtrl Up}", _TSRC_Sent[3],
			"partial Downs must roll back in reverse order before failure returns")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count,
			"no active count may publish for an OS transaction that failed")
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count,
			"a proven rollback must not manufacture a release-pending owner")
	}
	finally {
		_TSRC_End()
	}
}

; AHK-03: returning false is not sufficient when rollback itself fails. The
; adapter must identify the exact key whose compensating Up was not proven and
; the tap-hold owner must retain it for lifecycle cleanup without publishing a
; fictional active refcount.
_TSRC_FailedComboRollbackRemainsReleasePending() {
	global _AHK_SendInput, _TSRC_Sent
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_TSRC_Begin()
	try {
		_AHK_SendInput := _TSRC_FailSecondDownAndRollback
		Ok := TapHoldSyntheticKeyDown(["LCtrl", "LShift"])

		AssertEqual(false, Ok,
			"a combination whose Down and rollback both fail must return false")
		AssertEqual(3, _TSRC_Sent.Length,
			"the failed transaction must attempt two Downs and one compensating Up")
		AssertEqual("{LCtrl Up}", _TSRC_Sent[3],
			"the rollback failure seam must target the first proven Down")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count,
			"a failed combination must never publish ordinary active counts")
		AssertTrue(_TH_SyntheticReleasePendingKeys.Has("LCtrl"),
			"a failed rollback Up must remain owned even though the Down transaction returned false")
		AssertTrue(!_TH_SyntheticReleasePendingKeys.Has("LShift"),
			"the modifier whose Down failed must not acquire fictional release ownership")

		_AHK_SendInput := _TSRC_Record
		AssertEqual(true, TapHoldReleaseSyntheticKeys(),
			"a later lifecycle cleanup must retry and prove the retained rollback Up")
		AssertEqual(4, _TSRC_Sent.Length,
			"cleanup must emit exactly one later retry for the retained key")
		AssertEqual("{LCtrl Up}", _TSRC_Sent[4],
			"cleanup must retry the exact rollback key, not the failed Down key")
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count,
			"only the later proven Up may retire rollback ownership")
	}
	finally {
		_TSRC_End()
	}
}

; AHK-03: a failed final Up used to delete the only ledger entry first. Both
; the normal finalizer and Suspend cleanup then forgot which OS key still
; needed release. Exhaust the bounded retry twice, then prove a later cleanup
; retains and drains the same pending owner.
_TSRC_FailedFinalUpStaysPendingUntilCleanupProvesRelease() {
	global _AHK_SendInput
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	global TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS
	_TSRC_Begin()
	try {
		AssertEqual(true, TapHoldSyntheticKeyDown("LCtrl"),
			"the fixture must first prove the synthetic Down")
		_AHK_SendInput := _TSRC_FailEveryUp

		Ok := TapHoldSyntheticKeyUp("LCtrl")
		AssertEqual(false, Ok,
			"an exhausted final-Up retry must return false")
		AssertEqual(TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS,
			_TSRC_Count("{LCtrl Up}"),
			"the normal release must stop at the named retry bound")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count,
			"a zero-count key must leave the active refcount ledger")
		AssertTrue(_TH_SyntheticReleasePendingKeys.Has("LCtrl"),
			"the failed 1->0 OS transition must remain explicitly release-pending")

		CleanupOk := TapHoldReleaseSyntheticKeys()
		AssertEqual(false, CleanupOk,
			"lifecycle cleanup must report an exhausted pending release")
		AssertEqual(TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS * 2,
			_TSRC_Count("{LCtrl Up}"),
			"each cleanup invocation must be bounded independently")
		AssertTrue(_TH_SyntheticReleasePendingKeys.Has("LCtrl"),
			"failed lifecycle retries must retain ownership for the next cleanup")

		_AHK_SendInput := _TSRC_Record
		AssertEqual(true, TapHoldReleaseSyntheticKeys(),
			"a later lifecycle retry must drain the retained owner once Up succeeds")
		AssertEqual(TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS * 2 + 1,
			_TSRC_Count("{LCtrl Up}"),
			"successful cleanup must stop immediately after the first proven Up")
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count,
			"a proven Up is the only event allowed to forget release ownership")
	}
	finally {
		_TSRC_End()
	}
}

; The pending ledger is per emitted key, not per caller value. A combination
; release must retain every failed Up independently; stopping after the first
; failure would recreate the original partial-combo leak for the later keys.
_TSRC_FailedComboUpRetainsEveryKey() {
	global _AHK_SendInput
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	global TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS
	_TSRC_Begin()
	try {
		AssertEqual(true, TapHoldSyntheticKeyDown(["LCtrl", "LShift"]),
			"the fixture must prove both synthetic Downs before failing release")
		_AHK_SendInput := _TSRC_FailEveryUp

		AssertEqual(false, TapHoldSyntheticKeyUp(["LCtrl", "LShift"]),
			"a combination release must report failure when either Up is unproven")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count,
			"both zero-count keys must leave the active refcount ledger")
		for _, Name in ["LCtrl", "LShift"] {
			AssertTrue(_TH_SyntheticReleasePendingKeys.Has(Name),
				"every failed combination Up must retain its own release owner: " . Name)
			AssertEqual(TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS,
				_TSRC_Count("{" . Name . " Up}"),
				"each key's immediate retry loop must have the same named bound: " . Name)
		}

		_AHK_SendInput := _TSRC_Record
		AssertEqual(true, TapHoldReleaseSyntheticKeys(),
			"later lifecycle cleanup must drain every retained combination key")
		for _, Name in ["LCtrl", "LShift"]
			AssertEqual(TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS + 1,
				_TSRC_Count("{" . Name . " Up}"),
				"cleanup must retry every pending combination key exactly once after recovery: " . Name)
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count,
			"cleanup may report success only after every combination Up is proven")
	}
	finally {
		_TSRC_End()
	}
}

; The two pass-through tap paths release a PHYSICAL LAlt/RCtrl before their tap
; action. They must not decrement or force-Up an unrelated synthetic owner of
; the same OS key; doing either turns a valid refcount into a lie.
_TSRC_PhysicalEarlyReleaseDoesNotConsumeSyntheticOwner() {
	global _TH_SyntheticHeldKeys
	_TSRC_Begin()
	try {
		AssertEqual(true, TapHoldSyntheticKeyDown("LAlt"),
			"the fixture must establish an unrelated synthetic owner")
		AssertEqual(false, TapHoldReleasePhysicalKey("LAlt"),
			"a pass-through physical tap must be suppressed while a synthetic owner still requires LAlt")
		AssertEqual(1, _TSRC_Count("{LAlt Down}"),
			"the synthetic owner must remain the sole proven Down")
		AssertEqual(0, _TSRC_Count("{LAlt Up}"),
			"physical early release must not force-Up a key an unrelated synthetic owner still holds")
		AssertEqual(1, _TH_SyntheticHeldKeys["LAlt"],
			"physical early release must not consume the synthetic owner's reference")
		AssertEqual(true, TapHoldSyntheticKeyUp("LAlt"),
			"the real owner must remain able to release normally")
		AssertEqual(1, _TSRC_Count("{LAlt Up}"),
			"the real owner must emit the one balancing Up")
	}
	finally {
		_TSRC_End()
	}
}

_TSRC_RejectShutdownSyntheticRelease(*) {
	return false
}

; A bounded release failure at OnExit must keep the process alive. Otherwise
; the release-pending Map dies with the process and the OS modifier has no
; remaining owner capable of sending the balancing Up.
_TSRC_ShutdownRefusesToDestroyPendingReleaseOwner() {
	global _TSRC_RejectShutdownSyntheticRelease
	AssertEqual(1,
		TapHoldShutdownReleaseGate(_TSRC_RejectShutdownSyntheticRelease) ? 0 : 1,
		"the shutdown gate must reject an unproven synthetic release")
}


Test("taphold-synthetic-refcount: a combo hold keeps LCtrl down when an overlapping single hold releases",
	_TSRC_ComboKeepsCtrlWhenOverlappingSingleHoldReleases)
Test("taphold-synthetic-refcount: two resolutions of the same combination share their counts",
	_TSRC_TwoResolutionsOfSameComboShareTheirCounts)
Test("taphold-synthetic-refcount: the scalar refcount still balances",
	_TSRC_ScalarRefcountStillBalances)
Test("taphold-synthetic-refcount: an untracked combo release balances every key of the combination",
	_TSRC_UntrackedReleaseStillBalancesEveryKeyOfACombo)
Test("taphold synthetic transaction AHK-03: failed combo Down rolls back before publishing counts",
	_TSRC_FailedComboDownRollsBackBeforePublishing)
Test("taphold synthetic transaction AHK-03: failed combo rollback remains release-pending",
	_TSRC_FailedComboRollbackRemainsReleasePending)
Test("taphold synthetic transaction AHK-03: failed final Up remains pending through bounded cleanup retries",
	_TSRC_FailedFinalUpStaysPendingUntilCleanupProvesRelease)
Test("taphold synthetic transaction AHK-03: failed combo Up retains every emitted key",
	_TSRC_FailedComboUpRetainsEveryKey)
Test("taphold synthetic transaction AHK-03: physical early release preserves an unrelated synthetic owner",
	_TSRC_PhysicalEarlyReleaseDoesNotConsumeSyntheticOwner)
Test("taphold synthetic transaction AHK-03: shutdown preserves a failed release owner",
	_TSRC_ShutdownRefusesToDestroyPendingReleaseOwner)
