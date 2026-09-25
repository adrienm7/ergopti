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
; (kana-altgr-lift-owner-2026-09-25). Every expansion output now goes through
; _HSE_SendWithAltGrUp, which on a Kana layout has the owner lift the key
; around the output and press it again only while a tap-hold still holds it,
; and the chord cleanup leaves an owned key to its owner. The cases below drive
; that production path, on a Kana layout and on a standard one.
; ==============================================================================

#Requires AutoHotkey v2.0

global _KALO_Sent := []

; Record the funnel sends and the expansion sends in one ordered list, with an
; isolated synthetic ledger. Returns the globals it replaced, for _KALO_End.
_KALO_Begin(Kana, Owned := false) {
	global _AHK_SendInput, _KALO_Sent, _ALTGR_KANA_FIXUP
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	Saved := {
		SendInput: _AHK_SendInput, Kana: _ALTGR_KANA_FIXUP,
		Held: _TH_SyntheticHeldKeys, Pending: _TH_SyntheticReleasePendingKeys,
		UserHeld: _TH_SyntheticUserHeldKeys
	}
	_KALO_Sent := []
	_ALTGR_KANA_FIXUP := Kana
	_TH_SyntheticHeldKeys := Map()
	_TH_SyntheticReleasePendingKeys := Map()
	_TH_SyntheticUserHeldKeys := Map()
	if Owned
		_TH_SyntheticHeldKeys[KS_AltGrKeyName()] := 1
	_AHK_SendInput := (Keys) => _KALO_Sent.Push(Keys)
	return Saved
}

_KALO_End(Saved) {
	global _AHK_SendInput, _ALTGR_KANA_FIXUP
	global _TH_SyntheticHeldKeys, _TH_SyntheticReleasePendingKeys, _TH_SyntheticUserHeldKeys
	_AHK_SendInput := Saved.SendInput
	_ALTGR_KANA_FIXUP := Saved.Kana
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

; What an output leaves on the wire with a tap-hold holding AltGr: lifted and
; pressed again around it on a Kana layout, untouched on a standard one.
_KALO_AroundOwnedHold(Kana, Sends) {
	return Kana ? "{SC138 Up}|" . Sends . "|{SC138 Down}" : Sends
}

_KALO_LayoutName(Kana) {
	return Kana ? "Kana layout" : "standard AltGr layout"
}

_KALO_OwnedHoldSurvivesTheOutput() {
	global _TH_SyntheticHeldKeys
	for _, Kana in [true, false] {
		Saved := _KALO_Begin(Kana, true)
		try {
			AssertTrue(_HSE_SendWithAltGrUp(_KALO_Burst), "the output must be sent")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "burst"), _KALO_Joined(),
				_KALO_LayoutName(Kana) . ": a tap-hold's AltGr must be lifted for the output and pressed again after it, only where it would modify the output")
			AssertEqual(1, _TH_SyntheticHeldKeys[KS_AltGrKeyName()], "the owner's count must be untouched")
		} finally _KALO_End(Saved)
	}
}
Test("kana altgr lift: a tap-hold's AltGr survives an expansion (kana-altgr-lift-owner-2026-09-25)",
	_KALO_OwnedHoldSurvivesTheOutput)

_KALO_UnownedKeyStaysUp() {
	for _, Kana in [true, false] {
		Saved := _KALO_Begin(Kana, false)
		try {
			_HSE_SendWithAltGrUp(_KALO_Burst)
			AssertEqual(Kana ? "{SC138 Up}|burst" : "burst", _KALO_Joined(),
				_KALO_LayoutName(Kana) . ": an AltGr nobody holds is lifted and left up on a Kana layout, and never touched elsewhere")
		} finally _KALO_End(Saved)
	}
}
Test("kana altgr lift: an unowned AltGr is lifted and left up (kana-altgr-lift-owner-2026-09-25)",
	_KALO_UnownedKeyStaysUp)

_KALO_OwnerReleasingDuringOutputWins() {
	global _TH_SyntheticHeldKeys
	Saved := _KALO_Begin(true, true)
	try {
		_HSE_SendWithAltGrUp(() => (TapHoldSyntheticKeyUp("SC138"), _KALO_Burst()))
		AssertEqual(0, _TH_SyntheticHeldKeys.Count, "the owner released its hold")
		AssertEqual(0, InStr(_KALO_Joined(), "{SC138 Down}"),
			"a hold released during the output must not be pressed again, or AltGr stays stuck down")
	} finally _KALO_End(Saved)
}
Test("kana altgr lift: a hold released during the output is not pressed again (kana-altgr-lift-owner-2026-09-25)",
	_KALO_OwnerReleasingDuringOutputWins)

; The recorder every expansion sender hands its payload to under a test hook.
_KALO_RecordExpansionSend(Name, Args*) {
	global _KALO_Sent
	_KALO_Sent.Push(Name)
	return true
}

; Every production expansion path, with a tap-hold holding AltGr. Runs inside
; the send-failure suite's isolation (_AHK04_RunIsolated), which snapshots and
; restores the engine, preview, ring and hook state these paths commit.
_KALO_EveryExpansionPathImpl() {
	global _SendHook, HSE_Buffer, HSE_StartIsWordBoundary, _PrefixBuffer, _KALO_Sent
	for _, Kana in [true, false] {
		Layout := _KALO_LayoutName(Kana)
		Saved := _KALO_Begin(Kana, true)
		try {
			_SendHook := _KALO_RecordExpansionSend
			KLHook.prev_app := "kalo-test.exe"
			OutputHostResolverPrimeForTest("kalo-test.exe")
			HSE_Buffer := "xxab"
			HSE_StartIsWordBoundary := true
			_PrefixBuffer := "xxab"
			AssertTrue(HSE_DispatchMatch(_AHK04_NormalSpec(), ""), Layout . ": the atomic expansion must fire")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendFinalResult"), _KALO_Joined(),
				Layout . ": the atomic expansion burst must go out through the AltGr owner")

			_KALO_Sent := []
			AssertTrue(_HotstringDispatch("Z", " ", "{BackSpace 2}", "a", true, false, 0),
				Layout . ": the recorder-path expansion must fire")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendNewResult|SendNewResult|SendNewResult"), _KALO_Joined(),
				Layout . ": the recorder-path erase, replacement and end-char must go out through the AltGr owner")

			_KALO_Sent := []
			AssertTrue(_HSE_SendTerminalPaced(2, "Z", 1,
				(Payload) => (_KALO_Sent.Push("SendTerminalResult"), true), (*) => true),
				Layout . ": the paced terminal burst must be sent")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendTerminalResult"), _KALO_Joined(),
				Layout . ": the paced terminal burst must go out through the AltGr owner")

			KLHook.prev_app := "notepad.exe"
			OutputHostResolverPrimeForTest("notepad.exe")
			_KALO_Sent := []
			HSE_Buffer := "ab"
			_PrefixBuffer := "ab"
			AssertTrue(HSE_DispatchMatch(_AHK04_NormalSpec(), ""), Layout . ": the Notepad expansion must fire")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendInstant"), _KALO_Joined(),
				Layout . ": the Notepad clipboard expansion must go out through the AltGr owner")

			_KALO_Sent := []
			AssertTrue(_HotstringDispatch("Z", " ", "{BackSpace 2}", "a", true, false, 0),
				Layout . ": the recorder-path Notepad expansion must fire")
			AssertEqual(_KALO_AroundOwnedHold(Kana, "SendInstant"), _KALO_Joined(),
				Layout . ": the recorder-path Notepad paste must go out through the AltGr owner")
		} finally _KALO_End(Saved)
	}
}

_KALO_EveryExpansionPathKeepsTheHold() {
	_AHK04_RunIsolated(_KALO_EveryExpansionPathImpl)
}
Test("kana altgr lift: every expansion path lifts AltGr through the owner (kana-altgr-lift-owner-2026-09-25)",
	_KALO_EveryExpansionPathKeepsTheHold)

_KALO_RecordRelease(Name) {
	global _KALO_Sent
	_KALO_Sent.Push("release " . Name)
	return true
}

_KALO_ChordCleanupLeavesAnOwnedKey() {
	Saved := _KALO_Begin(true, true)
	try {
		ResetScriptComboKeys("SC01C", _KALO_RecordRelease)
		AssertEqual("", _KALO_Joined(),
			"the chord cleanup must not release an AltGr a tap-hold holds")
	} finally _KALO_End(Saved)
	Saved := _KALO_Begin(true, false)
	try {
		ResetScriptComboKeys("SC01C", _KALO_RecordRelease)
		AssertEqual("release SC138", _KALO_Joined(),
			"an unowned AltGr latched by the chord must still be cleared")
	} finally _KALO_End(Saved)
}
Test("kana altgr lift: the script chord cleanup leaves an owned AltGr (kana-altgr-lift-owner-2026-09-25)",
	_KALO_ChordCleanupLeavesAnOwnedKey)

; Every emitter of a raw AltGr release must go through the owner. The boot-time
; phantom release runs before any hold can exist.
_KALO_NoRawAltGrReleaseOutsideTheOwner() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "the driver source must be readable")
	Offenders := ""
	Pos := 1
	while (At := RegExMatch(Src, "i)\{SC138 up\}", &Match, Pos)) {
		Pos := At + Match.Len
		LineStart := InStr(SubStr(Src, 1, At), "`n", , -1) + 1
		LineEnd := InStr(Src, "`n", , At)
		Line := Trim(SubStr(Src, LineStart, (LineEnd ? LineEnd : StrLen(Src) + 1) - LineStart))
		if InStr(Line, "{Blind}{LCtrl up}{RCtrl up}")
			continue
		Offenders .= (Offenders = "" ? "" : " | ") . Line
	}
	AssertEqual("", Offenders,
		"a raw {SC138 Up} bypasses the synthetic ledger and ends a tap-hold's AltGr; use TapHoldSendWithKeyUp or TapHoldReleaseUnlessOwned")
	for Name, Outputs in Map("HSE_DispatchMatch", 2, "_HotstringDispatch", 1, "_HSE_SendTerminalPaced", 1) {
		Body := _StripFullLineComments(_DriverFuncBody(Name))
		Assert(Body != "", Name . " must exist")
		AssertEqual(Outputs, _KALO_Count(Body, "_HSE_SendWithAltGrUp("),
			Name . " must send each output through _HSE_SendWithAltGrUp, the AltGr owner's path")
	}
	; The lift and the re-press are one transaction that only the owner pairs:
	; each is called once in the driver, from TapHoldSendWithKeyUp.
	Paired := _DriverFuncBody("TapHoldSendWithKeyUp")
	Assert(Paired != "", "TapHoldSendWithKeyUp must exist")
	for _, Step in ["TapHoldLiftKey", "TapHoldRepressOwnedKey"] {
		Calls := _KALO_Count(Src, Step . "(") - _KALO_Count(Src, "`n" . Step . "(")
		AssertEqual(1, Calls, Step . " must be called only by TapHoldSendWithKeyUp, which pairs the lift with the re-press")
		Assert(InStr(Paired, Step . "(") > 0, "TapHoldSendWithKeyUp must call " . Step)
	}
	Body := _DriverFuncBody("ResetScriptComboKeys")
	Assert(Body != "" and InStr(Body, "TapHoldReleaseUnlessOwned(") > 0,
		"the script chord cleanup must release AltGr through the owner")
}
Test("kana altgr lift: no raw AltGr release bypasses the owner (kana-altgr-lift-owner-2026-09-25)",
	_KALO_NoRawAltGrReleaseOutsideTheOwner)
