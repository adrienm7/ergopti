; tests/unit/keyboard/engine/tap_hold/test_taphold_synthetic_user_held.ahk

; ==============================================================================
; MODULE: A synthetic hold never releases a modifier the user holds
; DESCRIPTION:
; Windows keeps one down bit per key. Holding LCtrl, then tapping CapsLock held
; as Ctrl, made the CapsLock owner press LCtrl again and release it at its last
; Up: LCtrl was logically up while the user still held it, and C then typed "c".
; CapsLock papered over its own tap with a CtrlActivated wrapper, which released
; LCtrl the same way. The owner now remembers, when it first presses a key,
; whether the user already held it down and delivered to the system; it leaves
; such a key down at its last release when the key is still physically held,
; since the user's own Up will release it. A press the driver suppressed (the
; RCtrl tap-hold holding its own RCtrl, the LAlt one-shot Shift) was never
; delivered, so its physical Up is swallowed and the synthetic Up must still be
; sent, or the modifier would stay down (synthetic-user-held-2026-09-25).
; ==============================================================================

#Requires AutoHotkey v2.0

global _TSUH_Sent := []
global _TSUH_Logical := Map()
global _TSUH_Physical := Map()
global _TSUH_OwnerState := 0

_TSUH_Begin(Logical, Physical) {
	global _AHK_SendInput, _TapHoldKeyIsDown, _TSUH_Sent, _TSUH_Logical, _TSUH_Physical, _TSUH_OwnerState
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _TH_OwnedModifiers, _TH_ModifierOwners, _TH_OwnedPresses, _TH_RetractedOwners, _TH_AltGrLCtrlOwners
	global _TH_AltGrPresses, _TH_TabAltOwner, _TH_LayerOwner, LayerEnabled, NumberOfRepetitions
	AssertFalse(IsObject(_TSUH_OwnerState), "A foreign synthetic-key fixture cannot be replaced")
	AssertEqual(0, _TH_SyntheticHeldKeys.Count + _TH_SyntheticReleasePendingKeys.Count,
		"A foreign native acquisition or release debt cannot be parked")
	AssertEqual(0, _TH_ModifierOwners.Count + _TH_OwnedPresses.Count + _TH_AltGrLCtrlOwners.Count,
		"A foreign live gesture cannot be parked across teardown")
	AssertFalse(IsObject(_TH_LayerOwner) || IsObject(_TH_TabAltOwner))
	_TSUH_OwnerState := {Send: _AHK_SendInput, KeyState: _TapHoldKeyIsDown,
		Held: _TH_SyntheticHeldKeys, Pending: _TH_SyntheticReleasePendingKeys, User: _TH_SyntheticUserHeldKeys,
		Names: _TH_OwnedModifiers, Owners: _TH_ModifierOwners, Presses: _TH_OwnedPresses,
		Retracted: _TH_RetractedOwners, AltCtrl: _TH_AltGrLCtrlOwners, AltPress: _TH_AltGrPresses,
		Tab: _TH_TabAltOwner, LayerOwner: _TH_LayerOwner, Layer: LayerEnabled, Repetitions: NumberOfRepetitions}
	_TSUH_Sent := [], _TSUH_Logical := Logical, _TSUH_Physical := Physical
	_TH_SyntheticHeldKeys := Map(), _TH_SyntheticReleasePendingKeys := Map(), _TH_SyntheticUserHeldKeys := Map()
	_TH_OwnedModifiers := Map(), _TH_ModifierOwners := Map(), _TH_OwnedPresses := Map(), _TH_RetractedOwners := Map()
	_TH_AltGrLCtrlOwners := Map(), _TH_AltGrPresses := Map(), _TH_TabAltOwner := 0, _TH_LayerOwner := 0
	LayerEnabled := false, NumberOfRepetitions := 1
	_AHK_SendInput := (Keys) => _TSUH_Sent.Push(Keys)
	_TapHoldKeyIsDown := _TSUH_KeyIsDown
}

_TSUH_End() {
	global _AHK_SendInput, _TapHoldKeyIsDown, _TSUH_OwnerState
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _TH_OwnedModifiers, _TH_ModifierOwners, _TH_OwnedPresses, _TH_RetractedOwners, _TH_AltGrLCtrlOwners
	global _TH_AltGrPresses, _TH_TabAltOwner, _TH_LayerOwner, LayerEnabled, NumberOfRepetitions
	Saved := _TSUH_OwnerState
	_AHK_SendInput := Saved.Send, _TapHoldKeyIsDown := Saved.KeyState
	_TH_SyntheticHeldKeys := Saved.Held, _TH_SyntheticReleasePendingKeys := Saved.Pending, _TH_SyntheticUserHeldKeys := Saved.User
	_TH_OwnedModifiers := Saved.Names, _TH_ModifierOwners := Saved.Owners, _TH_OwnedPresses := Saved.Presses
	_TH_RetractedOwners := Saved.Retracted, _TH_AltGrLCtrlOwners := Saved.AltCtrl, _TH_AltGrPresses := Saved.AltPress
	_TH_TabAltOwner := Saved.Tab, _TH_LayerOwner := Saved.LayerOwner
	LayerEnabled := Saved.Layer, NumberOfRepetitions := Saved.Repetitions
	; Epochs stay monotone. Preconditions above exclude any live foreign owner.
	_TSUH_OwnerState := 0
}

_TSUH_KeyIsDown(Name, Mode) {
	global _TSUH_Logical, _TSUH_Physical
	return (Mode == "P") ? _TSUH_Physical.Has(Name) : _TSUH_Logical.Has(Name)
}

_TSUH_Count(Payload) {
	global _TSUH_Sent
	N := 0
	for _, Sent in _TSUH_Sent {
		if (Sent == Payload)
			N++
	}
	return N
}

_TSUH_UserHeldCtrlSurvivesTheHold() {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_TSUH_Begin(Map("LCtrl", true), Map("LCtrl", true))
	try {
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl"), "the hold must still be owned")
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl"), "the release must succeed")
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"),
			"LCtrl held by the user must stay down: releasing it made C type 'c' under the user's Ctrl")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count, "the owner's count must end")
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count, "nothing may stay release-pending")
	} finally _TSUH_End()
}
Test("taphold-synthetic: a modifier the user holds stays down after a synthetic hold (synthetic-user-held-2026-09-25)",
	_TSUH_UserHeldCtrlSurvivesTheHold)

_TSUH_SuppressedOwnKeyIsReleased() {
	; RCtrl held as its own RCtrl through the suppressing tap-hold: physically
	; down, never delivered, so logically up until the synthetic Down.
	_TSUH_Begin(Map(), Map("RCtrl", true))
	try {
		TapHoldSyntheticKeyDown("RCtrl")
		TapHoldSyntheticKeyUp("RCtrl")
		AssertEqual(1, _TSUH_Count("{RCtrl Up}"),
			"a suppressed press's physical Up is swallowed: skipping the synthetic Up would leave RCtrl stuck down")
	} finally _TSUH_End()
}
Test("taphold-synthetic: a suppressed own press is still released (synthetic-user-held-2026-09-25)",
	_TSUH_SuppressedOwnKeyIsReleased)

_TSUH_UserReleasedBeforeTheHoldEnds() {
	global _TSUH_Physical
	_TSUH_Begin(Map("LCtrl", true), Map("LCtrl", true))
	try {
		TapHoldSyntheticKeyDown("LCtrl")
		_TSUH_Physical := Map()
		TapHoldSyntheticKeyUp("LCtrl")
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"),
			"once the user has let go, the last owner must release the key")
	} finally _TSUH_End()
}
Test("taphold-synthetic: a key the user let go is released by the last owner (synthetic-user-held-2026-09-25)",
	_TSUH_UserReleasedBeforeTheHoldEnds)

_TSUH_LifecycleCleanupLeavesTheUsersKey() {
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	_TSUH_Begin(Map("LCtrl", true), Map("LCtrl", true, "LShift", true))
	try {
		TapHoldSyntheticKeyDown(["LCtrl", "LShift"])
		AssertTrue(TapHoldReleaseSyntheticKeys(), "the cleanup must succeed")
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"), "the cleanup must not release the key the user holds")
		AssertEqual(1, _TSUH_Count("{LShift Up}"),
			"LShift was not delivered before the hold, so the cleanup must release it")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count + _TH_SyntheticReleasePendingKeys.Count,
			"the cleanup must leave no owner behind")
	} finally _TSUH_End()
}
Test("taphold-synthetic: lifecycle cleanup leaves a key the user holds (synthetic-user-held-2026-09-25)",
	_TSUH_LifecycleCleanupLeavesTheUsersKey)

_TSUH_CapsLockHasNoCtrlWrapper() {
	Body := _DriverFuncBody("_CapsLockInvokeTap")
	Assert(Body != "", "_CapsLockInvokeTap must exist")
	Assert(!InStr(Body, "TapHoldSyntheticKeyDown") and !InStr(Body, "CtrlActivated"),
		"the CapsLock tap must not wrap itself in a synthetic LCtrl: the owner now keeps a held LCtrl down")
}
Test("taphold-synthetic: the CapsLock tap no longer wraps itself in Ctrl (synthetic-user-held-2026-09-25)",
	_TSUH_CapsLockHasNoCtrlWrapper)


_TSUH_RetiredOwnerPreservesSuccessor() {
	global _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	WasSuspended := A_IsSuspended
	Ticks := 0
	Now() {
		Ticks += 1
		return Ticks == 1 ? 1000 : 1100
	}
	WaitRelease(*) {
		Suspend(true)
		try AssertTrue(TapHoldReleaseSyntheticKeys(), "The genuine teardown must acknowledge A's release")
		finally Suspend(false)
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl"), "A fresh post-resume acquisition B must reach the actual ledger")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"])
		return true
	}
	try {
		Suspend(false)
		Result := TapHoldOwnImmediateModifier("caps_lock", "CapsLock", "LCtrl", 0.2,
			WaitRelease, (*) => false, Now, 0, 0, (*) => "")
		AssertTrue(_TH_SyntheticHeldKeys.Has("LCtrl"), "Unwinding retired A must preserve the current B ownership")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"], "An old release must not consume B's reference")
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"), "Only the actual teardown may have emitted an Up before B ends")
		AssertFalse(Result["tap"], "A revoked gesture must not become a tap after resume")
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl"))
		AssertEqual(2, _TSUH_Count("{LCtrl Up}"), "B must retain its own independently balanced final release")
	} finally {
		if _TH_SyntheticHeldKeys.Has("LCtrl")
			TapHoldSyntheticKeyUp("LCtrl")
		Suspend(WasSuspended)
		_TSUH_End()
	}
}
Test("taphold-synthetic: a retired modifier owner preserves a post-resume acquisition (synthetic-owner-epoch)",
	_TSUH_RetiredOwnerPreservesSuccessor)

_TSUH_OwnerReleaseIsOnce() {
	global _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	try {
		A := TapHoldNewOwner(), B := TapHoldNewOwner()
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", A))
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", B))
		AssertEqual(2, _TH_SyntheticHeldKeys["LCtrl"])
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", A))
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", A), "A repeated release must retain its acknowledged verdict")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"], "The same gesture cannot consume B's reference on a second terminal path")
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"))
		AssertFalse(TapHoldSyntheticKeyDown("LCtrl", A), "A completed owner cannot acquire again")
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", B))
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", A))
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"), "Only B's final balancing release may reach the sender")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count)
	} finally _TSUH_End()
}
Test("taphold-synthetic: repeated owner release preserves its receipt and peer reference (synthetic-owner-once)", _TSUH_OwnerReleaseIsOnce)

_TSUH_RevokedBeforeDown() {
	global _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	WasSuspended := A_IsSuspended, Waits := 0
	Now() {
		Suspend(true)
		try AssertTrue(TapHoldReleaseSyntheticKeys())
		finally Suspend(false)
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl"))
		return 1000
	}
	Wait(*) {
		Waits += 1
		return true
	}
	try {
		Suspend(false)
		Result := TapHoldOwnImmediateModifier("caps_lock", "CapsLock", "LCtrl", 0.2,
			Wait, (*) => false, Now, 0, 0, (*) => "")
		AssertFalse(Result["activated"])
		AssertFalse(Result["tap"])
		AssertEqual(0, Waits, "A producer revoked before Down must not start its release wait")
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"], "Only the fresh B acquisition may remain")
		AssertEqual(1, _TSUH_Count("{LCtrl Down}"))
		AssertEqual(0, _TSUH_Count("{LCtrl Up}"), "The old frame must not release the fresh key on early refusal")
		AssertFalse(TapHoldPressIsOwned("caps_lock"))
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl"))
	} finally {
		Suspend(WasSuspended)
		_TSUH_End()
	}
}
Test("taphold-synthetic: teardown before the first Down rejects the old producer (synthetic-owner-before-down)", _TSUH_RevokedBeforeDown)

_TSUH_RetiredOwnerLeavesNewPhysicalKey() {
	global _TSUH_Logical, _TSUH_Physical
	_TSUH_Begin(Map(), Map())
	WasSuspended := A_IsSuspended, Clock := 900
	Wait(*) {
		Suspend(true)
		try AssertTrue(TapHoldReleaseSyntheticKeys())
		finally Suspend(false)
		; This is an explicit key-state observation port, not injected desktop input.
		_TSUH_Logical["LCtrl"] := true, _TSUH_Physical["LCtrl"] := true
		return true
	}
	try {
		Suspend(false)
		Result := TapHoldOwnImmediateModifier("caps_lock", "CapsLock", "LCtrl", 0.2,
			Wait, (*) => false, (*) => (Clock += 100), 0, 0, (*) => "")
		AssertFalse(Result["tap"])
		AssertEqual(1, _TSUH_Count("{LCtrl Up}"),
			"Only teardown may release A; an untracked old Up must never lift the newly delivered physical key")
		AssertTrue(_TSUH_Logical.Has("LCtrl") && _TSUH_Physical.Has("LCtrl"))
	} finally {
		Suspend(WasSuspended)
		_TSUH_End()
	}
}
Test("taphold-synthetic: a revoked frame cannot release a new physical key observation (synthetic-owner-physical)", _TSUH_RetiredOwnerLeavesNewPhysicalKey)

_TSUH_OwnerFailureRetainsDebt() {
	global _AHK_SendInput, _TSUH_Sent, _TH_SyntheticReleasePendingKeys, _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	FailUp(Keys) {
		_TSUH_Sent.Push(Keys)
		if InStr(Keys, " Up}")
			throw Error("Controlled owner release refusal")
	}
	try {
		A := TapHoldNewOwner(), B := TapHoldNewOwner()
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", A))
		_AHK_SendInput := FailUp
		AssertFalse(TapHoldSyntheticKeyUp("LCtrl", A))
		AssertTrue(_TH_SyntheticReleasePendingKeys.Has("LCtrl"), "A consumed reference must transfer its unproved native Up to the actual debt ledger")
		_AHK_SendInput := (Keys) => _TSUH_Sent.Push(Keys)
		AssertTrue(TapHoldSyntheticKeyDown("LCtrl", B), "B must repair the native debt before acquiring the key")
		AssertFalse(_TH_SyntheticReleasePendingKeys.Has("LCtrl"))
		Before := _TSUH_Count("{LCtrl Up}")
		AssertFalse(TapHoldSyntheticKeyUp("LCtrl", A), "A repeated refused receipt must not fabricate success or consume B")
		AssertEqual(Before, _TSUH_Count("{LCtrl Up}"))
		AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"])
		AssertTrue(TapHoldSyntheticKeyUp("LCtrl", B))
		AssertEqual(Before + 1, _TSUH_Count("{LCtrl Up}"))
	} finally _TSUH_End()
}
Test("taphold-synthetic: consumed owner release retains native debt without consuming its successor (synthetic-owner-debt)", _TSUH_OwnerFailureRetainsDebt)

_TSUH_TabFallbackAndFinallyShareReceipt() {
	global _TH_TabAltOwner, _TH_SyntheticHeldKeys
	_TSUH_Begin(Map(), Map())
	Saved := _TH_TabAltOwner
	try {
		A := TapHoldNewOwner(), B := TapHoldNewOwner()
		_TH_TabAltOwner := A
		AssertTrue(TapHoldSyntheticKeyDown("LAlt", A))
		AssertTrue(TapHoldSyntheticKeyDown("LAlt", B))
		AssertTrue(_TapHoldReleaseTabAltOwner(), "The actual static Up fallback must acknowledge A")
		AssertTrue(_TapHoldReleaseOwnedModifier("LAlt", A), "The waiting frame must read the same acknowledged receipt")
		AssertEqual(1, _TH_SyntheticHeldKeys["LAlt"])
		AssertEqual(0, _TSUH_Count("{LAlt Up}"), "The two terminal paths must leave B's Alt held")
		AssertTrue(_TapHoldReleaseOwnedModifier("LAlt", B))
		AssertEqual(1, _TSUH_Count("{LAlt Up}"))
	} finally {
		_TH_TabAltOwner := Saved
		_TSUH_End()
	}
}
Test("taphold-synthetic: Tab Up and its waiting frame share one acknowledged release (synthetic-owner-tab)", _TSUH_TabFallbackAndFinallyShareReceipt)


; Model the port's actual effect separately from its ACK. The production sender
; and synthetic ledger must reconcile a delivered Down followed by an exception.
_TSFD_EffectBeforeRefusal(Mode) {
	global _AHK_SendInput, _TSUH_Sent, _TSUH_Logical, _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TSUH_Physical
	global _ALTGR_KANA_FIXUP, _ALTGR_LAYOUT_PROBE
	SavedKana := _ALTGR_KANA_FIXUP, SavedProbe := _ALTGR_LAYOUT_PROBE
	Combo := Mode == "combo" || Mode == "preheld-combo" || Mode == "other-owner-combo"
	User := Mode == "preheld" || Mode == "preheld-combo"
	Sibling := Mode == "other-owner" || Mode == "other-owner-combo"
	Initial := User ? Map("LCtrl", true) : Map()
	_TSUH_Begin(Initial, User || Mode == "suppressed-own" ? Map("LCtrl", true) : Map())
	State := {downs: 0, ups: 0, throws: 0, nested: false, other: 0, otherResult: false, newUser: false}
	Emit(Keys) {
		_TSUH_Sent.Push(Keys)
		for Name in ["LCtrl", "LShift"] {
			if Keys == "{" . Name . " Down}" {
				State.downs += 1
				_TSUH_Logical[Name] := true
				if Name == (Combo ? "LShift" : "LCtrl") {
					if Sibling {
						if State.nested
							return 0
						State.nested := true
						State.other := TapHoldNewOwner()
						State.otherResult := TapHoldSyntheticKeyDown("LCtrl", State.other)
						State.nested := false
					}
					if Mode == "new-user" {
						_TSUH_Physical[Name] := true
						State.newUser := true
					}
					State.throws += 1
					throw Error("Port refused AFTER its modeled Down effect")
				}
			} else if Keys == "{" . Name . " Up}" {
				State.ups += 1
				if _TSUH_Logical.Has(Name)
					_TSUH_Logical.Delete(Name)
			}
		}
		return 0
	}
	try {
		_AHK_SendInput := Emit
		if Mode == "no-payload" {
			_ALTGR_KANA_FIXUP := true
			_ALTGR_LAYOUT_PROBE := Map("altgr_vk", 0)
		}
		Owner := TapHoldNewOwner()
		Key := Combo ? ["LCtrl", "LShift"] : Mode == "no-payload" ? "SC138" : "LCtrl"
		Result := TapHoldSyntheticKeyDown(Key, Owner)
		_TestPrint("# synthetic failed-down mode=" . Mode . " result=" . Result . " downs=" . State.downs
			. " throws=" . State.throws . " held=" . _TH_SyntheticHeldKeys.Count . " pending=" . _TH_SyntheticReleasePendingKeys.Count)
		AssertFalse(Result)
		AssertFalse(Owner.Held, "a refused transaction cannot publish a successful owner")
		if Mode == "no-payload" {
			AssertEqual(0, State.downs, "an absent layout VK must refuse before calling the native port")
			AssertEqual(0, State.throws)
			AssertTrue(TapHoldReleaseSyntheticKeys())
			AssertEqual(0, State.ups, "format refusal cannot manufacture an unaddressable Up debt")
			AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count)
		} else {
			AssertEqual(1, State.throws, "the effect-before-error cutpoint must genuinely be reached")
			if Sibling {
				AssertTrue(State.otherResult && State.other.Held, "the real sibling Down must acknowledge before the outer port fails")
				AssertEqual(Combo ? 1 : 0, State.ups, "the failed older operation releases only its own uncertain key, never the sibling's proven Down")
				AssertTrue(_TSUH_Logical.Has("LCtrl"))
				AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"], "the sibling keeps its exact count")
				AssertTrue(TapHoldSyntheticKeyUp("LCtrl", State.other))
				AssertEqual(Combo ? 2 : 1, State.ups)
			} else {
				AssertTrue(TapHoldReleaseSyntheticKeys(), "the real lifecycle resolves every owned release debt")
				if User || Mode == "new-user" {
					if Mode == "new-user"
						AssertTrue(State.newUser && _TSUH_Physical.Has("LCtrl"), "a separate physical event really establishes new user custody during the port call")
					AssertEqual(Combo ? 1 : 0, State.ups, "a user hold delivered before the failed Down remains the user's")
					AssertTrue(_TSUH_Logical.Has("LCtrl"))
					AssertFalse(_TSUH_Logical.Has("LShift"))
				} else {
					AssertFalse(_TSUH_Logical.Has("LCtrl") || _TSUH_Logical.Has("LShift"),
						"a failed first or later Down must not strand any modeled native key after lifecycle")
					AssertEqual(Combo ? 2 : 1, State.ups, "each potentially delivered key receives exactly one proven release")
				}
			}
			AssertEqual(0, _TH_SyntheticHeldKeys.Count)
			AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count)
		}
	} finally {
		_ALTGR_KANA_FIXUP := SavedKana, _ALTGR_LAYOUT_PROBE := SavedProbe
		_TSUH_End()
	}
}
for _TSFD_Mode in ["first", "combo", "preheld", "preheld-combo", "other-owner", "other-owner-combo", "new-user", "suppressed-own", "no-payload"]
	Test("synthetic failed Down: " . _TSFD_Mode . " preserves actual release ownership (synthetic-down-effect-refusal)",
		_TSFD_EffectBeforeRefusal.Bind(_TSFD_Mode))


; A rejected scalar restoration can already have changed the keyboard. These
; deterministic ports model custody and effect separately; no hardware claim.
_TSLR_ScalarRestore(Mode) {
	global _AHK_SendInput, _TSUH_Sent, _TSUH_Logical, _TSUH_Physical
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys
	User := Mode != "owned"
	_TSUH_Begin(User ? Map("LCtrl", true) : Map(), User ? Map("LCtrl", true) : Map())
	State := {armed: false, downs: 0, ups: 0, throws: 0, released: false}
	Emit(Keys) {
		_TSUH_Sent.Push(Keys)
		if Keys == "{LCtrl Down}" {
			State.downs += 1
			_TSUH_Logical["LCtrl"] := true
			if State.armed {
				if Mode == "user-released" {
					_TSUH_Physical.Delete("LCtrl")
					State.released := true
				}
				State.throws += 1
				throw Error("Scalar restoration port refused AFTER modeled Down delivery")
			}
		} else if Keys == "{LCtrl Up}" {
			State.ups += 1
			if _TSUH_Logical.Has("LCtrl")
				_TSUH_Logical.Delete("LCtrl")
		}
		return 0
	}
	try {
		_AHK_SendInput := Emit
		if !User {
			Owner := TapHoldNewOwner()
			AssertTrue(TapHoldSyntheticKeyDown("LCtrl", Owner), "the owned control begins with a genuine counted acquisition")
			AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"])
		}
		UserHeld := _TH_UserHoldsDeliveredKey("LCtrl")
		AssertEqual(User, UserHeld, "custody must be captured before the lift")
		AssertTrue(TapHoldLiftKey("LCtrl"), "the actual producer must acknowledge its preceding lift")
		AssertFalse(_TSUH_Logical.Has("LCtrl"), "the modeled key really is up before restoration")
		State.armed := true
		Result := TapHoldRestoreLiftedKey("LCtrl", UserHeld)
		_TestPrint("# scalar restore mode=" . Mode . " result=" . Result . " downs=" . State.downs
			. " ups=" . State.ups . " throws=" . State.throws . " released=" . State.released
			. " logical=" . _TSUH_Logical.Has("LCtrl") . " held=" . _TH_SyntheticHeldKeys.Count
			. " pending=" . _TH_SyntheticReleasePendingKeys.Count)
		AssertEqual(User ? 1 : 2, State.downs, "the scalar restoration must reach its actual lower sender")
		AssertEqual(1, State.throws, "the port must refuse only after its modeled native effect")
		AssertFalse(Result, "no restoration ACK may be invented after the port exception")
		if Mode == "owned" {
			AssertTrue(Owner.Held && _TH_SyntheticHeldKeys["LCtrl"] == 1,
				"a refused restoration cannot steal the existing owner's active count")
			AssertEqual(1, State.ups, "the restore failure itself must not Up the still-owned modifier")
		} else if Mode == "user-still-held" {
			AssertTrue(_TSUH_Physical.Has("LCtrl") && _TSUH_Logical.Has("LCtrl"),
				"the original delivered user hold remains theirs")
			AssertEqual(1, State.ups, "the restore failure cannot inject an extra Up under the user")
		} else
			AssertTrue(State.released && !_TSUH_Physical.Has("LCtrl"),
				"a separate physical release must really win during the rejected restoration")
		AssertTrue(TapHoldReleaseSyntheticKeys(), "the actual lifecycle must reconcile any retained release debt")
		if Mode == "user-still-held" {
			AssertTrue(_TSUH_Logical.Has("LCtrl"))
			AssertEqual(1, State.ups, "lifecycle also preserves the user's current hold")
		} else {
			AssertFalse(_TSUH_Logical.Has("LCtrl"), "a refused restored Down cannot remain stuck after its owner/user no longer holds it")
			AssertEqual(2, State.ups, "the original lift and one acknowledged balancing Up are the only releases")
		}
		AssertEqual(0, _TH_SyntheticHeldKeys.Count)
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count)
	} finally _TSUH_End()
}
for _TSLR_Mode in ["owned", "user-still-held", "user-released"]
	Test("scalar lifted restoration: " . _TSLR_Mode . " retains exact release custody (synthetic-lifted-down-refusal)",
		_TSLR_ScalarRestore.Bind(_TSLR_Mode))


_TSLX_PostPortCustody(Mode) {
	global _AHK_SendInput, _TSUH_Sent, _TSUH_Logical, _TSUH_Physical
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS
	User := Mode == "pending-up"
	_TSUH_Begin(User ? Map("LCtrl", true) : Map(), User ? Map("LCtrl", true) : Map())
	State := {armed: false, nested: false, allowUp: false, downs: 0, ups: 0, refusedUps: 0,
		throws: 0, retired: false, sibling: 0, siblingAck: false, original: 0}
	Emit(Keys) {
		_TSUH_Sent.Push(Keys)
		if Keys == "{LCtrl Down}" {
			State.downs += 1
			if State.armed && !State.nested {
				if Mode == "withdrawn" {
					State.retired := TapHoldReleaseSyntheticKeys()
				} else if Mode == "sibling" {
					State.nested := true
					State.retired := TapHoldSyntheticKeyUp("LCtrl", State.original)
					State.sibling := TapHoldNewOwner()
					State.siblingAck := TapHoldSyntheticKeyDown("LCtrl", State.sibling)
					State.nested := false
				} else
					_TSUH_Physical.Delete("LCtrl")
				_TSUH_Logical["LCtrl"] := true
				State.throws += 1
				throw Error("Restoration refused after custody changed and modeled Down arrived")
			}
			_TSUH_Logical["LCtrl"] := true
		} else if Keys == "{LCtrl Up}" {
			if State.armed && Mode == "pending-up" && !State.allowUp {
				State.refusedUps += 1
				throw Error("Balancing Up refused before modeled delivery")
			}
			State.ups += 1
			if _TSUH_Logical.Has("LCtrl")
				_TSUH_Logical.Delete("LCtrl")
		}
		return 0
	}
	try {
		_AHK_SendInput := Emit
		if !User {
			State.original := TapHoldNewOwner()
			AssertTrue(TapHoldSyntheticKeyDown("LCtrl", State.original))
			AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"])
		}
		UserHeld := _TH_UserHoldsDeliveredKey("LCtrl")
		AssertEqual(User, UserHeld)
		AssertTrue(TapHoldLiftKey("LCtrl"))
		State.armed := true
		Result := TapHoldRestoreLiftedKey("LCtrl", UserHeld)
		_TestPrint("# lifted restore custody mode=" . Mode . " result=" . Result . " downs=" . State.downs
			. " ups=" . State.ups . " throws=" . State.throws . " refused_ups=" . State.refusedUps
			. " retired=" . State.retired . " sibling_ack=" . State.siblingAck
			. " held=" . _TH_SyntheticHeldKeys.Count . " pending=" . _TH_SyntheticReleasePendingKeys.Count)
		AssertEqual(1, State.throws, "the scalar producer must actually reach the post-effect refusal")
		AssertFalse(Result, "recovery must never turn a refused Down into a restoration ACK")
		if Mode == "pending-up" {
			AssertFalse(_TSUH_Physical.Has("LCtrl"), "the user really releases during the Down port")
			AssertEqual(TAPHOLD_SYNTHETIC_RELEASE_MAX_ATTEMPTS, State.refusedUps)
			AssertTrue(_TH_SyntheticReleasePendingKeys.Has("LCtrl") && _TSUH_Logical.Has("LCtrl"),
				"the actual unproved balancing Up must remain explicitly owned")
			State.allowUp := true
		} else {
			AssertTrue(State.retired, "the genuine original owner must retire before the final Down arrives")
			if Mode == "sibling" {
				AssertTrue(State.siblingAck && State.sibling.Held)
				AssertEqual(1, _TH_SyntheticHeldKeys["LCtrl"])
				AssertEqual(2, State.ups, "the refused restore cannot release the fresh sibling's key")
				AssertTrue(_TSUH_Logical.Has("LCtrl"))
			} else {
				AssertEqual(0, _TH_SyntheticHeldKeys.Count)
				AssertFalse(_TSUH_Logical.Has("LCtrl"), "an obsolete captured Owned flag cannot strand a key after actual owner retirement")
			}
		}
		AssertTrue(TapHoldReleaseSyntheticKeys())
		AssertFalse(_TSUH_Logical.Has("LCtrl"))
		AssertEqual(User ? 2 : 3, State.ups, "every actual owner or uncertain Down gets exactly its acknowledged balancing release")
		AssertEqual(0, _TH_SyntheticHeldKeys.Count)
		AssertEqual(0, _TH_SyntheticReleasePendingKeys.Count)
	} finally _TSUH_End()
}
for _TSLX_Mode in ["withdrawn", "sibling", "pending-up"]
	Test("lifted restoration custody: " . _TSLX_Mode . " resolves after the real sender port (synthetic-lifted-down-custody)",
		_TSLX_PostPortCustody.Bind(_TSLX_Mode))
