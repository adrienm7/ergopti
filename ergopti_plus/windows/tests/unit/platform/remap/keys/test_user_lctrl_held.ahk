; tests/unit/platform/remap/keys/test_user_lctrl_held.ahk

; ==============================================================================
; MODULE: AltGr's fake LCtrl is not the user's LCtrl
; DESCRIPTION:
; On a standard AltGr layout Windows adds a fake LCtrl to every AltGr press,
; which AutoHotkey records as physically down (hook.cpp: "fake LCtrl is marked
; as physical"). BackSpaceLogic read that as "LCtrl physically held": with
; AltGr held and LAlt tapped as Backspace (AltGr+LAlt shortcut off, or the
; plain Backspace LAlt), it sent Ctrl+Backspace and deleted a whole word, and
; Ctrl+Delete under AltGr+Shift, where a Kana layout, whose AltGr adds no Ctrl,
; sent Backspace and Delete (std-altgr-fake-lctrl-backspace-2026-09-26).
; ==============================================================================

#Requires AutoHotkey v2.0

; A key-state stand-in where exactly the keys named in Down are held.
_ULH_Keys(Down*) {
	Held := Map()
	for _, Name in Down
		Held[Name] := true
	return (Name) => Held.Has(Name)
}

_ULH_AltGrLCtrlIsNotTheUsers() {
	Body := _DriverFuncBody("BackSpaceLogic")
	Assert(Body != "", "BackSpaceLogic must be found before its reads are counted")
	AssertFalse(InStr(Body, '"SC01D"') > 0,
		"BackSpaceLogic must not read AltGr's fake LCtrl as the user's LCtrl")
	; The user's LCtrl is a seam since the shared thumb Backspace vectors (THD-4):
	; its default is TapHoldUserLCtrlHeld, and every LCtrl branch asks it.
	Assert(InStr(Body, "UserLCtrlFn := TapHoldUserLCtrlHeld") > 0,
		"BackSpaceLogic's LCtrl defaults to the user's own LCtrl")
	StrReplace(Body, "UserLCtrlFn.Call()", , , &Reads)
	AssertEqual(3, Reads, "every LCtrl branch of BackSpaceLogic must ask for the user's own LCtrl")
	Family := _TestSetAltGrFamily(false)
	try {
		AssertFalse(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D", "RAlt")),
			"standard layout: LCtrl with RAlt physically down is AltGr's fake LCtrl")
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D")), "a real LCtrl alone is the user's")
		AssertFalse(TapHoldUserLCtrlHeld(_ULH_Keys("RAlt")), "no LCtrl at all")
	} finally _TestRestoreAltGrFamily(Family)
	Family := _TestSetAltGrFamily(true)
	try {
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D", "SC138")),
			"Kana layout: the AltGr key adds no Ctrl, so a physical LCtrl is the user's")
	} finally _TestRestoreAltGrFamily(Family)
}
Test("user lctrl: AltGr's fake LCtrl is not the user's LCtrl (std-altgr-fake-lctrl-backspace-2026-09-26)",
	_ULH_AltGrLCtrlIsNotTheUsers)

; The ledger's flag decides under AltGr on a standard layout, and on that layout
; only: a release missed during Ctrl+Alt+Del or on a secure desktop is forgotten
; by the ledger (item3-missed-release in nav_event_owner_test.c), so the later
; AltGr alone reads as the alias, and never as the user's Ctrl.
_ULH_LedgerTellsTheFakeLCtrl() {
	Family := _TestSetAltGrFamily(false)
	Physical := _ULH_Keys("SC01D", "RAlt")
	try {
		AssertTrue(TapHoldUserLCtrlHeld(Physical, (*) => 1),
			"a real LCtrl held with AltGr is the user's")
		AssertFalse(TapHoldUserLCtrlHeld(Physical, (*) => 0),
			"missed release then AltGr: the ledger forgot it, only the alias is down")
		AssertFalse(TapHoldUserLCtrlHeld(Physical, (*) => -1),
			"no owner: the LCtrl under AltGr stays AltGr's")
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D"), (*) => 0),
			"without AltGr the physical LCtrl answers, as before")
	} finally _TestRestoreAltGrFamily(Family)
	Family := _TestSetAltGrFamily(true)
	try AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D", "SC138"), (*) => 0),
		"Kana: no alias exists, the ledger is not asked")
	finally _TestRestoreAltGrFamily(Family)
}
Test("user lctrl: the ledger tells the fake LCtrl from a real one, a missed release included (item3-missed-release)",
	_ULH_LedgerTellsTheFakeLCtrl)

; On QWERTY right Alt is a plain Alt with no fake LCtrl (the boot probe finds no
; AltGr level), so a physical LCtrl held with it is the user's: LCtrl+RAlt then
; LAlt tapped as Backspace must take the Ctrl+Backspace branch, not the
; additive Ctrl+Alt+Backspace (qwerty-user-lctrl-2026-09-26).
_ULH_QwertyLCtrlWithRAltIsTheUsers() {
	Family := _TestSetAltGrFamily(false, false)
	try {
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D", "RAlt")),
			"QWERTY: a physical LCtrl held with the right Alt is the user's Ctrl")
		AssertTrue(TapHoldUserLCtrlHeld(_ULH_Keys("SC01D")), "QWERTY: a real LCtrl alone is the user's")
		AssertFalse(TapHoldUserLCtrlHeld(_ULH_Keys("RAlt")), "QWERTY: no LCtrl at all")
	} finally _TestRestoreAltGrFamily(Family)
}
Test("user lctrl: on QWERTY an LCtrl held with right Alt is the user's (qwerty-user-lctrl-2026-09-26)",
	_ULH_QwertyLCtrlWithRAltIsTheUsers)

; What a sequence of BackSpaceLogic presses deletes, in the corpus' words: the
; last key decides the direction (Delete, or Right then Backspace, is forward),
; Ctrl on it a word.
_ULH_Deletion(Presses) {
	if (Presses.Length == 0)
		return "char_back"
	Last := Presses[Presses.Length]
	Word := InStr(Last.Modifiers, "Ctrl") ? "word" : "char"
	Forward := Last.Key == "Delete" || (Presses.Length == 2 && Presses[1].Key == "Right" && Last.Key == "BackSpace")
	return Word . (Forward ? "_forward" : "_back")
}

; A seam answering Value.
_ULH_Constant(Value) {
	return () => Value
}

; A sender seam recording each key and its modifiers into Presses.
_ULH_Recorder(Presses) {
	return (Key, Modifiers) => (Presses.Push({Key: Key, Modifiers: Modifiers}), true)
}

; The shared thumb Backspace vectors, replayed through the real BackSpaceLogic
; with its key state and sender as seams; macOS and Linux replay the same file
; (maintainer decision THD-4 of 2026-11-21, thumb-backspace-vectors).
_ULH_ThumbBackspaceVectors() {
	global TapHold, _TH_SyntheticEpoch
	Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\tap_hold\thumb_backspace_vectors.json", "UTF-8"))
	Vectors := Corpus["vectors"]
	AssertEqual(8, Vectors.Length, "every thumb Backspace vector is replayed")
	SavedTapHold := TapHold
	Names := Map("shift", "Shift", "right_ctrl", "SC11D")
	try {
		for _, Vector in Vectors {
			TapHold := Map("keys", Map("right_ctrl", Map("tap_action", Vector["right_ctrl_tap"])))
			HeldNames := [], LCtrl := false
			for _, HeldKey in Vector["held"] {
				if (HeldKey == "left_ctrl")
					LCtrl := true
				else
					HeldNames.Push(Names[HeldKey])
			}
			Presses := []
			Typed := BackSpaceLogic(_TH_SyntheticEpoch, _ULH_Keys(HeldNames*), _ULH_Constant(LCtrl),
				_ULH_Recorder(Presses))
			AssertEqual(Presses.Length > 0, Typed, Vector["id"] . ": the logic reports whether it typed")
			AssertEqual(Vector["expected"], _ULH_Deletion(Presses), Vector["id"])
		}
	} finally {
		TapHold := SavedTapHold
	}
}
Test("thumb backspace: BackSpaceLogic replays the shared vectors (thumb-backspace-vectors)",
	_ULH_ThumbBackspaceVectors)
