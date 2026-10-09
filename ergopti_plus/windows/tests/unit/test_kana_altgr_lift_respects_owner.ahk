; tests/unit/test_kana_altgr_lift_respects_owner.ahk

; ==============================================================================
; MODULE: Lifting the Kana AltGr around output keeps a tap-hold's hold
; DESCRIPTION:
; On a Kana-style layout the AltGr key (SC138) modifies every character typed
; while it is down, so the hotstring engine sent a raw "{SC138 Up}" before each
; expansion, and the script AltGr chords sent one after running. None of them
; consulted the synthetic ledger: with AltGr held by a tap-hold (CapsLock or
; Space held as AltGr), an expansion released it for good and the rest of the
; hold typed plain characters, while the owner still counted it down
; (kana-altgr-lift-owner-2026-09-25). Keyboard expansion output now goes through
; _HSE_SendWithAltGrUp, which on a Kana layout has the owner lift the key
; around the output and press it again only while a tap-hold still holds it,
; and the chord cleanup leaves an owned key to its owner. The cases below drive
; that production path, on a Kana layout and on a standard one.
;
; The same lift ended an AltGr the USER holds (AltGr held as AltGr passes the
; key through, and AltGr with no tap-hold is the plain key): the owner only
; pressed back a synthetic hold, so every expansion left the user's AltGr up
; for the rest of the hold (kana-altgr-user-hold-2026-09-25). The owner now
; also presses back a key the user held, delivered, before the lift and still
; holds physically.
; ==============================================================================

#Requires AutoHotkey v2.0

global _KALO_Sent := []
global _KALO_Logical := false
global _KALO_Physical := false

; The AltGr key's state as the owner reads it, instead of the real keyboard.
_KALO_KeyIsDown(Name, Mode) {
	global _KALO_Logical, _KALO_Physical
	if (Name != KS_AltGrKeyName())
		return false
	return (Mode == "P") ? _KALO_Physical : _KALO_Logical
}

; Record the funnel sends and the expansion sends in one ordered list, with an
; isolated synthetic ledger and key state. Holder is who holds AltGr: ""
; (nobody), "tap-hold" (a synthetic hold: logically down only), "user" (a
; delivered physical hold: logically and physically down) or "suppressed" (a
; physical press a hotkey swallowed). Returns the globals it replaced.
_KALO_Begin(Kana, Holder := "") {
	global _AHK_SendInput, _KALO_Sent, _TapHoldKeyIsDown
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	global _KALO_Logical, _KALO_Physical
	Saved := {
		SendInput: _AHK_SendInput, Family: _TestSetAltGrFamily(Kana), KeyIsDown: _TapHoldKeyIsDown,
		Held: _TH_SyntheticHeldKeys, Pending: _TH_SyntheticReleasePendingKeys,
		UserHeld: _TH_SyntheticUserHeldKeys
	}
	_KALO_Sent := []
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
	if (Holder == "tap-hold")
		_TH_SyntheticHeldKeys[KS_AltGrKeyName()] := 1
	_KALO_Logical := (Holder == "tap-hold" or Holder == "user")
	_KALO_Physical := (Holder == "user" or Holder == "suppressed")
	_TapHoldKeyIsDown := _KALO_KeyIsDown
	_AHK_SendInput := (Keys) => _KALO_Sent.Push(Keys)
	return Saved
}

_KALO_End(Saved) {
	global _AHK_SendInput, _TapHoldKeyIsDown
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	_AHK_SendInput := Saved.SendInput
	_TestRestoreAltGrFamily(Saved.Family)
	_TapHoldKeyIsDown := Saved.KeyIsDown
	_TH_SyntheticHeldKeys := Saved.Held
	_TH_SyntheticReleasePendingKeys := Saved.Pending
	_TH_SyntheticUserHeldKeys := Saved.UserHeld
}

_KALO_Joined() {
	global _KALO_Sent
	Out := ""
	for _, Keys in _KALO_Sent
		Out .= (Out == "" ? "" : "|") . Keys
	return Out
}

_KALO_Count(Haystack, Needle) {
	return (StrLen(Haystack) - StrLen(StrReplace(Haystack, Needle))) // StrLen(Needle)
}

_KALO_Burst() {
	global _KALO_Sent
	_KALO_Sent.Push("burst")
	return true
}

; What an output leaves on the wire with a tap-hold or the user holding AltGr.
; On a Kana layout both are lifted and pressed again around it. On a standard
; layout a tap-hold's synthetic AltGr (RAlt, which AHK keeps down around a
; non-blind Send because the driver pressed it) is lifted too, masked, since
; right Alt is a plain Alt on some layouts (std-altgr-expansion-lift-2026-09-26);
; the user's own AltGr is lifted by the Send itself and left alone.
_KALO_AroundOwnedHold(Kana, Sends, Holder := "tap-hold") {
	if Kana
		return "{Blind}{vkDF Up}|" . Sends . "|{Blind}{vkDF Down}"
	if (Holder == "tap-hold")
		return "{Blind}{" . A_MenuMaskKey . "}|{RAlt Up}|" . Sends . "|{RAlt Down}"
	return Sends
}

_KALO_LayoutName(Kana) {
	return Kana ? "Kana layout" : "standard AltGr layout"
}

_KALO_OwnedHoldSurvivesTheOutput() {
	global _TH_SyntheticHeldKeys
	for _, Kana in [true, false] {
		Saved := _KALO_Begin(Kana, "tap-hold")
		try {
			AssertTrue(_HSE_SendWithAltGrUp(_KALO_Burst), "the output must be sent")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "burst"), _KALO_Joined(),
				_KALO_LayoutName(Kana) . ": a tap-hold's AltGr must be lifted for the output and pressed again after it")
			AssertEqual(1, _TH_SyntheticHeldKeys[KS_AltGrKeyName()], "the owner's count must be untouched")
		} finally _KALO_End(Saved)
	}
}
Test("kana altgr lift: a tap-hold's AltGr survives an expansion (kana-altgr-lift-owner-2026-09-25)",
	_KALO_OwnedHoldSurvivesTheOutput)

; The AltGr layer's own output (a table entry or a roll) under an AltGr a
; tap-hold holds: AutoHotkey kept that synthetic key down around the layer's
; non-blind Send, so where right Alt is a plain Alt (QWERTY) the text went out
; under Alt, as menu mnemonics (qwerty-altgr-layer-under-alt-2026-09-26). An
; AltGr only the user holds is the Send's own business.
_KALO_LayerOutputUnderAnOwnedAltGr() {
	for _, Kana in [true, false] {
		for _, Holder in ["tap-hold", "user"] {
			Saved := _KALO_Begin(Kana, Holder)
			try {
				AltGrLayerEmit(_KALO_Burst)
				Expected := (Holder == "tap-hold") ? _KALO_AroundOwnedHold(Kana, "burst") : "burst"
				AssertEqual(Expected, _KALO_Joined(),
					_KALO_LayoutName(Kana) . ", " . Holder . " hold: an AltGr-layer output is lifted out of a tap-hold's AltGr only")
			} finally _KALO_End(Saved)
		}
	}
}
Test("kana altgr lift: the AltGr layer's output is lifted out of a tap-hold's AltGr (qwerty-altgr-layer-under-alt-2026-09-26)",
	_KALO_LayerOutputUnderAnOwnedAltGr)

; An AltGr nobody holds modifies nothing: the Kana layout lifted it before
; every expansion anyway, one extra SendInput and an orphan release in front of
; each burst (kana-altgr-lift-idle-2026-09-26). A key logically stuck down with
; nobody holding it is still lifted, and not pressed again.
_KALO_UnownedKeyStaysUp() {
	global _KALO_Logical
	for _, Kana in [true, false] {
		Saved := _KALO_Begin(Kana)
		try {
			_HSE_SendWithAltGrUp(_KALO_Burst)
			AssertEqual("burst", _KALO_Joined(),
				_KALO_LayoutName(Kana) . ": an AltGr nobody holds is never lifted")
		} finally _KALO_End(Saved)
	}
	Saved := _KALO_Begin(true)
	try {
		_KALO_Logical := true
		_HSE_SendWithAltGrUp(_KALO_Burst)
		AssertEqual("{Blind}{vkDF Up}|burst", _KALO_Joined(),
			"a Kana AltGr stuck down with nobody holding it is lifted and left up")
	} finally _KALO_End(Saved)
}
Test("kana altgr lift: an AltGr nobody holds is not lifted, a stuck one is (kana-altgr-lift-idle-2026-09-26)",
	_KALO_UnownedKeyStaysUp)

_KALO_OwnerReleasingDuringOutputWins() {
	global _TH_SyntheticHeldKeys
	Saved := _KALO_Begin(true, "tap-hold")
	try {
		_HSE_SendWithAltGrUp(() => (TapHoldSyntheticKeyUp("SC138"), _KALO_Burst()))
		AssertEqual(0, _TH_SyntheticHeldKeys.Count, "the owner released its hold")
		AssertEqual(0, InStr(_KALO_Joined(), "{Blind}{vkDF Down}"),
			"a hold released during the output must not be pressed again, or AltGr stays stuck down")
	} finally _KALO_End(Saved)
}
Test("kana altgr lift: a hold released during the output is not pressed again (kana-altgr-lift-owner-2026-09-25)",
	_KALO_OwnerReleasingDuringOutputWins)

; A Kana AltGr the user holds, delivered, is pressed again after the output
; while the user still holds it; the user's own release passes through later.
_KALO_UserHoldSurvivesTheOutput() {
	for _, Kana in [true, false] {
		Saved := _KALO_Begin(Kana, "user")
		try {
			AssertTrue(_HSE_SendWithAltGrUp(_KALO_Burst), "the output must be sent")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "burst", "user"), _KALO_Joined(),
				_KALO_LayoutName(Kana) . ": an AltGr the user holds must be lifted for the output and pressed again after it, only where it would modify the output")
		} finally _KALO_End(Saved)
	}
}
Test("kana altgr lift: an AltGr the user holds survives an expansion (kana-altgr-user-hold-2026-09-25)",
	_KALO_UserHoldSurvivesTheOutput)

_KALO_ReleasePhysically() {
	global _KALO_Physical
	_KALO_Physical := false
	return _KALO_Burst()
}

_KALO_UserReleasingDuringOutputWins() {
	for _, Kana in [true, false] {
		Saved := _KALO_Begin(Kana, "user")
		try {
			_HSE_SendWithAltGrUp(_KALO_ReleasePhysically)
			AssertEqual(Kana ? "{Blind}{vkDF Up}|burst" : "burst", _KALO_Joined(),
				_KALO_LayoutName(Kana) . ": an AltGr the user let go of during the output must stay up, or it is stuck down")
		} finally _KALO_End(Saved)
	}
}
Test("kana altgr lift: an AltGr the user releases during the output is not pressed again (kana-altgr-user-hold-2026-09-25)",
	_KALO_UserReleasingDuringOutputWins)

; The release reaches the keyboard state right after the re-press is decided.
_KALO_RecordReleasingOnDown(Keys) {
	global _KALO_Sent, _KALO_Physical
	_KALO_Sent.Push(Keys)
	if (Keys == "{Blind}{vkDF Down}")
		_KALO_Physical := false
	return true
}

_KALO_UserReleaseRacingTheRepressIsUndone() {
	global _AHK_SendInput
	Saved := _KALO_Begin(true, "user")
	try {
		_AHK_SendInput := _KALO_RecordReleasingOnDown
		_HSE_SendWithAltGrUp(_KALO_Burst)
		AssertEqual("{Blind}{vkDF Up}|burst|{Blind}{vkDF Down}|{Blind}{vkDF Up}", _KALO_Joined(),
			"a release that lands between the check and the re-press must be undone, or AltGr stays down with nobody holding it")
	} finally _KALO_End(Saved)
}
Test("kana altgr lift: a release racing the re-press is undone (kana-altgr-user-hold-2026-09-25)",
	_KALO_UserReleaseRacingTheRepressIsUndone)

; A press a hotkey swallowed never reached the system, so nothing is given back.
_KALO_SuppressedPressIsNotPressedBack() {
	for _, Kana in [true, false] {
		Saved := _KALO_Begin(Kana, "suppressed")
		try {
			_HSE_SendWithAltGrUp(_KALO_Burst)
			AssertEqual("burst", _KALO_Joined(),
				_KALO_LayoutName(Kana) . ": a suppressed AltGr press, logically up, needs no lift and must not be pressed on the user's behalf")
		} finally _KALO_End(Saved)
	}
}
Test("kana altgr lift: a suppressed AltGr press is not pressed back (kana-altgr-user-hold-2026-09-25)",
	_KALO_SuppressedPressIsNotPressedBack)

; The recorder every expansion sender hands its payload to under a test hook.
_KALO_RecordExpansionSend(Name, Args*) {
	global _KALO_Sent
	_KALO_Sent.Push(Name)
	return true
}

; Keyboard expansion paths lift and restore owned AltGr; literal native output
; sends no keyboard edges and must leave both ownership ledgers untouched. Runs inside
; the send-failure suite's isolation (_AHK04_RunIsolated), which snapshots and
; restores the engine, preview, ring and hook state these paths commit.
_KALO_EveryExpansionPathImpl() {
	global _SendHook, HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer, _KALO_Sent, _LLM_Bridge_Buffer
	global _TH_SyntheticHeldKeys, _TH_SyntheticUserHeldKeys, _TH_SyntheticReleasePendingKeys
	for _, Scenario in [[true, "tap-hold"], [false, "tap-hold"], [true, "user"], [false, "user"]] {
		Kana := Scenario[1]
		Layout := _KALO_LayoutName(Kana) . ", " . Scenario[2] . " hold"
		Saved := _KALO_Begin(Kana, Scenario[2])
		try {
			_SendHook := _KALO_RecordExpansionSend
			KLHook.prev_app := "kalo-test.exe"
			OutputHostResolverPrimeForTest("kalo-test.exe")
			HSE_Buffer := "xxab"
			HSE_StartIsWordBoundary := true
			_PrefixBuffer := "xxab"
			AssertTrue(HSE_DispatchMatch(_AHK04_NormalSpec(), ""), Layout . ": the atomic expansion must fire")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendFinalResult", Scenario[2]), _KALO_Joined(),
				Layout . ": the atomic expansion burst must go out through the AltGr owner")

			_KALO_Sent := []
			AssertTrue(_HotstringDispatch("Z", " ", "{BackSpace 2}", "a", true, false, 0),
				Layout . ": the recorder-path expansion must fire")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendNewResult|SendNewResult|SendNewResult", Scenario[2]), _KALO_Joined(),
				Layout . ": the recorder-path erase, replacement and end-char must go out through the AltGr owner")

			_KALO_Sent := []
			AssertTrue(_HSE_SendTerminalPaced(2, "Z", 1,
				(Payload) => (_KALO_Sent.Push("SendTerminalResult"), true), (*) => true),
				Layout . ": the paced terminal burst must be sent")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendTerminalResult", Scenario[2]), _KALO_Joined(),
				Layout . ": the paced terminal burst must go out through the AltGr owner")

			KLHook.prev_app := "notepad.exe"
			OutputHostResolverPrimeForTest("notepad.exe")
			_KALO_Sent := []
			HSE_Buffer := "ab"
			_PrefixBuffer := "ab"
			_LLM_Bridge_Buffer := "ab"
			Native := Map("Requests", [])
			HeldBefore := _TH_SyntheticHeldKeys.Count
			UserHeldBefore := _TH_SyntheticUserHeldKeys.Count
			PendingBefore := _TH_SyntheticReleasePendingKeys.Count
			Owner := HSE_DispatchMatch(_AHK04_NormalSpec(), "", , false, _HNP_Record.Bind(Native))
			AssertTrue(Owner is Map, Layout . ": native output must retain its real pending owner")
			AssertTrue(Owner["Pending"], Layout . ": native scheduling cannot report a fire")
			AssertEqual("ab", HSE_Buffer, Layout . ": pending receiving cannot commit the engine")
			AssertEqual("", _KALO_Joined(), Layout . ": native scheduling must not emit keyboard or modifier edges")
			AssertEqual(HeldBefore, _TH_SyntheticHeldKeys.Count, Layout . ": pending output retains synthetic holds")
			AssertEqual(UserHeldBefore, _TH_SyntheticUserHeldKeys.Count, Layout . ": pending output retains user holds")
			AssertEqual(PendingBefore, _TH_SyntheticReleasePendingKeys.Count, Layout . ": pending output creates no release debt")
			_HNP_Settle(Native)
			AssertTrue(Owner["FinalSucceeded"], Layout . ": actual canonical completion acknowledges native output")
			AssertEqual("Z", HSE_Buffer, Layout . ": completion commits the exact visible effect")
			AssertEqual("Z", _LLM_Bridge_Buffer, Layout . ": canonical completion commits the same LLM mirror")
			AssertEqual("", _KALO_Joined(), Layout . ": native completion also leaves modifiers untouched")
			AssertEqual(HeldBefore, _TH_SyntheticHeldKeys.Count, Layout . ": completion preserves synthetic hold ownership")
			AssertEqual(UserHeldBefore, _TH_SyntheticUserHeldKeys.Count, Layout . ": completion preserves user hold ownership")
			AssertEqual(PendingBefore, _TH_SyntheticReleasePendingKeys.Count, Layout . ": completion creates no release debt")

			_KALO_Sent := []
			AssertTrue(_HotstringDispatch("Z", " ", "{BackSpace 2}", "a", true, false, 0),
				Layout . ": the recorder-path Notepad expansion must fire")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendInstant", Scenario[2]), _KALO_Joined(),
				Layout . ": the recorder-path Notepad paste must go out through the AltGr owner")
		} finally _KALO_End(Saved)
	}
}

_KALO_EveryExpansionPathKeepsTheHold() {
	_HNP_Run(_KALO_EveryExpansionPathImpl)
}
Test("kana altgr lift: keyboard paths lift AltGr and native output preserves its owner (kana-altgr-lift-owner-2026-09-25)",
	_KALO_EveryExpansionPathKeepsTheHold)

_KALO_RecordRelease(Name) {
	global _KALO_Sent
	_KALO_Sent.Push("release " . Name)
	return true
}

_KALO_ChordCleanupLeavesAnOwnedKey() {
	Saved := _KALO_Begin(true, "tap-hold")
	try {
		ResetScriptComboKeys("SC01C", _KALO_RecordRelease)
		AssertEqual("", _KALO_Joined(),
			"the chord cleanup must not release an AltGr a tap-hold holds")
	} finally _KALO_End(Saved)
	Saved := _KALO_Begin(true)
	try {
		ResetScriptComboKeys("SC01C", _KALO_RecordRelease)
		AssertEqual("release SC138", _KALO_Joined(),
			"an unowned AltGr latched by the chord must still be cleared")
	} finally _KALO_End(Saved)
}
Test("kana altgr lift: the script chord cleanup leaves an owned AltGr (kana-altgr-lift-owner-2026-09-25)",
	_KALO_ChordCleanupLeavesAnOwnedKey)

; The chord cleanup released an AltGr the user still held, which ended the
; layout's AltGr for the rest of that hold (kana-altgr-chord-user-hold). It now
; leaves that key down and looks again once the user lets go, releasing the key
; only if a swallowed release left it latched. A standard layout has nothing to
; clear.
global _KALO_Armed := []

_KALO_Arm(Callback, DelayMs) {
	global _KALO_Armed
	_KALO_Armed.Push(Callback)
	return true
}

; Runs the look the cleanup armed last, as its timer would.
_KALO_RunArmed() {
	global _KALO_Armed
	AssertEqual(1, _KALO_Armed.Length, "exactly one next look must be armed")
	Look := _KALO_Armed.Pop()
	Look.Call()
}

_KALO_ChordCleanupWaitsForTheUser() {
	global _ScriptComboArmFn, _KALO_Armed, _KALO_Logical, _KALO_Physical
	SavedArm := _ScriptComboArmFn
	_ScriptComboArmFn := _KALO_Arm
	try {
		for _, Kana in [true, false] {
			for _, Latched in [true, false] {
				Where := _KALO_LayoutName(Kana) . (Latched ? ", release swallowed" : ", release delivered")
				Saved := _KALO_Begin(Kana, "user")
				_KALO_Armed := []
				try {
					ResetScriptComboKeys("SC01C", _KALO_RecordRelease)
					AssertEqual("", _KALO_Joined(),
						Where . ": an AltGr the user still holds must stay down after the chord")
					if Kana {
						_KALO_RunArmed()
						AssertEqual("", _KALO_Joined(), Where . ": still held on the next look, so still left alone")
						_KALO_Physical := false
						_KALO_Logical := Latched
						_KALO_RunArmed()
						AssertEqual(Latched ? "release SC138" : "", _KALO_Joined(),
							Where . ": once the user lets go, only a key left latched is released")
					}
					AssertEqual(0, _KALO_Armed.Length, Where . ": nothing is left to look at")
				} finally _KALO_End(Saved)
			}
		}
	} finally _ScriptComboArmFn := SavedArm
}
Test("kana altgr lift: the script chord cleanup leaves the AltGr the user holds (kana-altgr-chord-user-hold)",
	_KALO_ChordCleanupWaitsForTheUser)

; Every emitter of a raw AltGr release must go through the owner. The boot-time
; phantom release runs before any hold can exist.
_KALO_NoRawAltGrReleaseOutsideTheOwner() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")
	Offenders := ""
	BootRelease := 0
	Pos := 1
	while (At := RegExMatch(Src, "i)\{SC138 up\}", &Match, Pos)) {
		Pos := At + Match.Len
		LineStart := InStr(SubStr(Src, 1, At), "`n", , -1) + 1
		LineEnd := InStr(Src, "`n", , At)
		Line := Trim(SubStr(Src, LineStart, (LineEnd ? LineEnd : StrLen(Src) + 1) - LineStart))
		if InStr(Line, "{Blind}{LCtrl up}{RCtrl up}") {
			BootRelease += 1
			continue
		}
		Offenders .= (Offenders = "" ? "" : " | ") . Line
	}
	Assert(BootRelease >= 1,
		"the scan must reach the boot-time phantom AltGr release it allows, or its pattern matches nothing")
	AssertEqual("", Offenders,
		"a raw {SC138 Up} bypasses the synthetic ledger and ends a tap-hold's AltGr; use TapHoldSendWithKeyUp or TapHoldReleaseUnlessOwned")
	for Name, Outputs in Map("HSE_DispatchMatch", 1, "_HotstringDispatch", 1, "_HSE_SendTerminalPaced", 1) {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must exist")
		AssertEqual(Outputs, _KALO_Count(Body, "_HSE_SendWithAltGrUp("),
			Name . " must send each output through _HSE_SendWithAltGrUp, the AltGr owner's path")
	}
	; The lift and the re-press are one transaction that only the owner pairs:
	; each is called once in the driver, from TapHoldSendWithKeyUp.
	Paired := _DriverFuncBody("TapHoldSendWithKeyUp")
	Assert(Paired != "", "TapHoldSendWithKeyUp must exist")
	for _, Step in ["TapHoldLiftKey", "TapHoldRestoreLiftedKey"] {
		Calls := _KALO_Count(Src, Step . "(") - _KALO_Count(Src, "`n" . Step . "(")
		AssertEqual(1, Calls, Step . " must be called only by TapHoldSendWithKeyUp, which pairs the lift with the re-press")
		Assert(InStr(Paired, Step . "(") > 0, "TapHoldSendWithKeyUp must call " . Step)
	}
	Body := _DriverFuncBody("ResetScriptComboKeys")
	Clear := _DriverFuncBody("_ScriptComboClearAltGr")
	Assert(InStr(Body, "_ScriptComboClearAltGr(") > 0 and InStr(Clear, "TapHoldReleaseUnlessOwned(") > 0,
		"the script chord cleanup must release AltGr through the owner")
}
Test("kana altgr lift: no raw AltGr release bypasses the owner (kana-altgr-lift-owner-2026-09-25)",
	_KALO_NoRawAltGrReleaseOutsideTheOwner)
