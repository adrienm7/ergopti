; static/drivers/autohotkey/tests/test_layout_tables.ahk

; ==============================================================================
; MODULE: Layout Tables Tests
; DESCRIPTION:
; Sanity tests for the data tables produced by lib/layout_altgr.ahk and
; lib/layout_shift_caps.ahk. Includes a regression test for the AltGr
; dispatch crash (commit 48369d96) that fired every BoundFunc entry through
; AltGrShiftDispatch and asserted no exception bubbles up.
; ==============================================================================

; Build the tables once (idempotent — calling twice is fine).
_BuildAltGrTables()
_BuildShiftCapsTables()




; ── Assertion helpers ──
_AssertSCsPresent(M, SCs) {
	for _, SC in SCs {
		AssertTrue(M.Has(SC), "missing SC: " . SC)
	}
}
_AssertEntriesHavePlainShifted(M) {
	for SC, Entry in M {
		AssertTrue(Entry.HasOwnProp("Plain"), SC . " missing Plain")
		AssertTrue(Entry.HasOwnProp("Shifted"), SC . " missing Shifted")
	}
}
_AssertEntriesAreCallable(M) {
	for SC, Entry in M {
		AssertTrue(IsObject(Entry.Plain), SC . " Plain not callable")
		AssertTrue(IsObject(Entry.Shifted), SC . " Shifted not callable")
	}
}
_AssertSimpleValuesCallable(M) {
	for SC, Cb in M {
		AssertTrue(IsObject(Cb), SC . " not callable")
	}
}
_AssertDisjoint(A, B) {
	for SC in A {
		AssertFalse(B.Has(SC), "SC " . SC . " present in both maps")
	}
}
_AssertNumpadValues(M) {
	for SC, V in M {
		AssertContains(V, "Numpad")
	}
}




; =================================
; AltGr table structural invariants
; =================================
TestLT_PlusOverridesSCs() {
	_AssertSCsPresent(ALTGR_PLUS_OVERRIDES, ["SC012", "SC013", "SC018"])
}
Test("ALTGR_PLUS_OVERRIDES: contains the three documented SCs", TestLT_PlusOverridesSCs)

TestLT_PlusOverridesShape() {
	_AssertEntriesHavePlainShifted(ALTGR_PLUS_OVERRIDES)
}
Test("ALTGR_PLUS_OVERRIDES: every entry has Plain and Shifted",
	TestLT_PlusOverridesShape)

TestLT_NumberRowSCs() {
	AssertEqual(13, ALTGR_NUMBER_ROW.Count)
	_AssertSCsPresent(ALTGR_NUMBER_ROW, ["SC029", "SC002", "SC003", "SC004",
		"SC005", "SC006", "SC007", "SC008", "SC009", "SC00A", "SC00B", "SC00C", "SC00D"])
}
Test("ALTGR_NUMBER_ROW: covers SC029 + SC002..SC00D (13 entries)",
	TestLT_NumberRowSCs)

TestLT_CtrlAltNumpadSCs() {
	AssertEqual(10, CTRL_ALT_NUMPAD.Count)
	_AssertSCsPresent(CTRL_ALT_NUMPAD, ["SC002", "SC003", "SC004", "SC005",
		"SC006", "SC007", "SC008", "SC009", "SC00A", "SC00B"])
	_AssertNumpadValues(CTRL_ALT_NUMPAD)
}
Test("CTRL_ALT_NUMPAD: covers ten digits SC002..SC00B with Numpad targets",
	TestLT_CtrlAltNumpadSCs)

TestLT_BaseRowsCovered() {
	AssertTrue(ALTGR_BASE_ROWS.Count >= 30)
	_AssertSCsPresent(ALTGR_BASE_ROWS, ["SC039", "SC010", "SC035"])
}
Test("ALTGR_BASE_ROWS: contains the Space + every alpha row SC",
	TestLT_BaseRowsCovered)

TestLT_BaseRowsCallable() {
	_AssertEntriesHavePlainShifted(ALTGR_BASE_ROWS)
	_AssertEntriesAreCallable(ALTGR_BASE_ROWS)
}
Test("ALTGR_BASE_ROWS: every entry has callable Plain and Shifted",
	TestLT_BaseRowsCallable)




; =====================================
; Shift / CapsLock table invariants
; =====================================
TestLT_ShiftedLetters() {
	AssertEqual(40, SHIFTED_LETTERS.Count)
	AssertEqual("È", SHIFTED_LETTERS["SC010"])
	AssertEqual("J", SHIFTED_LETTERS["SC02E"])
	AssertEqual("1", SHIFTED_LETTERS["SC002"])
}
Test("SHIFTED_LETTERS: covers digits and uppercase rows", TestLT_ShiftedLetters)

TestLT_ShiftSymbolsDisjoint() {
	_AssertDisjoint(SHIFT_SYMBOLS, SHIFTED_LETTERS)
}
Test("SHIFT_SYMBOLS: keys are disjoint from SHIFTED_LETTERS",
	TestLT_ShiftSymbolsDisjoint)

TestLT_CapsLockSymbolsDisjoint() {
	_AssertDisjoint(CAPSLOCK_SYMBOLS, SHIFTED_LETTERS)
}
Test("CAPSLOCK_SYMBOLS: keys are disjoint from SHIFTED_LETTERS",
	TestLT_CapsLockSymbolsDisjoint)

TestLT_ShiftSymbolsCallable() {
	_AssertSimpleValuesCallable(SHIFT_SYMBOLS)
}
Test("SHIFT_SYMBOLS: every entry is callable", TestLT_ShiftSymbolsCallable)

TestLT_CapsLockSymbolsCallable() {
	_AssertSimpleValuesCallable(CAPSLOCK_SYMBOLS)
}
Test("CAPSLOCK_SYMBOLS: every entry is callable", TestLT_CapsLockSymbolsCallable)




; ==========================
; Regression: AltGr dispatch crash (commit 48369d96)
; ==========================
; The original AltGrShiftDispatch invoked ``Entry.Plain()`` directly, which
; AHK parsed as a method call and silently passed ``Entry`` as an implicit
; first argument. For BoundFuncs with all positional params bound (e.g.
; WrapTextIfSelected.Bind("X","X","X")) that overflowed and aborted the
; keystroke handler with "too many parameters passed to function". These
; tests fire every entry through the dispatcher to catch any regression.
TestLT_RegressionBaseRows() {
	ResetStubRecorders()
	for SC, _ in ALTGR_BASE_ROWS {
		try {
			AltGrShiftDispatch(SC, ALTGR_BASE_ROWS, "fake-hotkey-name")
		} catch as e {
			throw Error("AltGrShiftDispatch crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("AltGrShiftDispatch: no entry overflows the BoundFunc signature (base rows)",
	TestLT_RegressionBaseRows)

TestLT_RegressionPlusOverrides() {
	ResetStubRecorders()
	for SC, _ in ALTGR_PLUS_OVERRIDES {
		try {
			AltGrShiftDispatch(SC, ALTGR_PLUS_OVERRIDES, "fake-hotkey-name")
		} catch as e {
			throw Error("AltGrShiftDispatch crashed on Plus " . SC . ": " . e.Message)
		}
	}
}
Test("AltGrShiftDispatch: no entry overflows the BoundFunc signature (Plus)",
	TestLT_RegressionPlusOverrides)

TestLT_RegressionNumberRow() {
	ResetStubRecorders()
	for SC, _ in ALTGR_NUMBER_ROW {
		try {
			AltGrShiftDispatch(SC, ALTGR_NUMBER_ROW, "fake-hotkey-name")
		} catch as e {
			throw Error("AltGrShiftDispatch crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("AltGrShiftDispatch: no entry overflows the BoundFunc signature (Number row)",
	TestLT_RegressionNumberRow)




; ==========================
; LayerDispatch behaviour
; ==========================
TestLT_LayerDispatchLetter() {
	global LastSentCharacters
	ResetStubRecorders()
	LastSentCharacters := []
	; SendNewResult("È") -> SendEvent(...) -> UpdateLastSentCharacter("È")
	LayerDispatch("SC010", SHIFT_SYMBOLS)
	AssertEqual("È", _Stub_LastChars[_Stub_LastChars.Length])
}
Test("LayerDispatch: shift letter pushes the uppercase letter via SendNewResult",
	TestLT_LayerDispatchLetter)

TestLT_LayerDispatchSymbol() {
	global LastSentCharacters
	ResetStubRecorders()
	LastSentCharacters := []
	; SC029 in SHIFT_SYMBOLS calls ActivateHotstrings then SendNewResult(" €")
	LayerDispatch("SC029", SHIFT_SYMBOLS)
	AssertTrue(_Stub_LastChars.Length >= 1)
}
Test("LayerDispatch: shift symbol entry runs the configured override",
	TestLT_LayerDispatchSymbol)

TestLT_LayerDispatchUnknown() {
	ResetStubRecorders()
	LayerDispatch("SC999", SHIFT_SYMBOLS)
	AssertEqual(0, _Stub_LastChars.Length)
}
Test("LayerDispatch: unknown SC is silently ignored", TestLT_LayerDispatchUnknown)




; ==========================
; SHIFTED_LETTERS — spot-check key entries
; ==========================
TestLT_ShiftedLettersMiddleRow() {
	AssertEqual("A",  SHIFTED_LETTERS["SC01E"])
	AssertEqual("I",  SHIFTED_LETTERS["SC01F"])
	AssertEqual("E",  SHIFTED_LETTERS["SC020"])
	AssertEqual("U",  SHIFTED_LETTERS["SC021"])
	AssertEqual("V",  SHIFTED_LETTERS["SC023"])
	AssertEqual("S",  SHIFTED_LETTERS["SC024"])
	AssertEqual("N",  SHIFTED_LETTERS["SC025"])
	AssertEqual("T",  SHIFTED_LETTERS["SC026"])
	AssertEqual("R",  SHIFTED_LETTERS["SC027"])
	AssertEqual("Q",  SHIFTED_LETTERS["SC028"])
}
Test("SHIFTED_LETTERS: middle row letters are correct", TestLT_ShiftedLettersMiddleRow)

TestLT_ShiftedLettersBottomRow() {
	AssertEqual("Ê",  SHIFTED_LETTERS["SC056"])
	AssertEqual("É",  SHIFTED_LETTERS["SC02C"])
	AssertEqual("À",  SHIFTED_LETTERS["SC02D"])
	AssertEqual("J",  SHIFTED_LETTERS["SC02E"])
	AssertEqual("K",  SHIFTED_LETTERS["SC030"])
	AssertEqual("M",  SHIFTED_LETTERS["SC031"])
	AssertEqual("D",  SHIFTED_LETTERS["SC032"])
	AssertEqual("L",  SHIFTED_LETTERS["SC033"])
	AssertEqual("P",  SHIFTED_LETTERS["SC034"])
}
Test("SHIFTED_LETTERS: bottom row letters are correct", TestLT_ShiftedLettersBottomRow)

TestLT_ShiftedLettersTopRow() {
	AssertEqual("È",  SHIFTED_LETTERS["SC010"])
	AssertEqual("Y",  SHIFTED_LETTERS["SC011"])
	AssertEqual("O",  SHIFTED_LETTERS["SC012"])
	AssertEqual("W",  SHIFTED_LETTERS["SC013"])
	AssertEqual("B",  SHIFTED_LETTERS["SC014"])
	AssertEqual("F",  SHIFTED_LETTERS["SC015"])
	AssertEqual("G",  SHIFTED_LETTERS["SC016"])
	AssertEqual("H",  SHIFTED_LETTERS["SC017"])
	AssertEqual("C",  SHIFTED_LETTERS["SC018"])
	AssertEqual("X",  SHIFTED_LETTERS["SC019"])
	AssertEqual("Z",  SHIFTED_LETTERS["SC01A"])
}
Test("SHIFTED_LETTERS: top row letters are correct", TestLT_ShiftedLettersTopRow)

TestLT_ShiftedLettersDigits() {
	AssertEqual("1", SHIFTED_LETTERS["SC002"])
	AssertEqual("2", SHIFTED_LETTERS["SC003"])
	AssertEqual("9", SHIFTED_LETTERS["SC00A"])
	AssertEqual("0", SHIFTED_LETTERS["SC00B"])
}
Test("SHIFTED_LETTERS: digit entries contain the correct digits",
	TestLT_ShiftedLettersDigits)




; ==========================
; AltGr number row — value spot-checks
; ==========================
TestLT_AltGrEuroKey() {
	; SC029 (tilde key) → € plain, DeadKey(Currency) shifted
	AssertTrue(ALTGR_NUMBER_ROW.Has("SC029"))
	Entry := ALTGR_NUMBER_ROW["SC029"]
	AssertTrue(IsObject(Entry.Plain))
	AssertTrue(IsObject(Entry.Shifted))
}
Test("ALTGR_NUMBER_ROW: SC029 (euro/currency) entry is present and callable",
	TestLT_AltGrEuroKey)

TestLT_AltGrSuperscriptRow() {
	for _, SC in ["SC002", "SC003", "SC004", "SC005", "SC006",
	              "SC007", "SC008", "SC009", "SC00A", "SC00B"] {
		AssertTrue(ALTGR_NUMBER_ROW.Has(SC), "missing SC: " . SC)
		Entry := ALTGR_NUMBER_ROW[SC]
		AssertTrue(IsObject(Entry.Plain),   SC . " Plain not callable")
		AssertTrue(IsObject(Entry.Shifted), SC . " Shifted not callable")
	}
}
Test("ALTGR_NUMBER_ROW: SC002..SC00B all have callable Plain and Shifted",
	TestLT_AltGrSuperscriptRow)

TestLT_AltGrDegreeKey() {
	AssertTrue(ALTGR_NUMBER_ROW.Has("SC00D"))
}
Test("ALTGR_NUMBER_ROW: SC00D (degree sign) is present", TestLT_AltGrDegreeKey)




; ==========================
; CtrlAltDispatch — no crash per entry
; ==========================
TestLT_CtrlAltDispatchAllEntries() {
	ResetHotstringRecorders()
	for Combo, _ in CTRL_ALT_NUMPAD {
		try {
			CtrlAltDispatch(Combo, "fake-hotkey-name")
		} catch as e {
			throw Error("CtrlAltDispatch crashed on " . Combo . ": " . e.Message)
		}
	}
}
Test("CtrlAltDispatch: no entry crashes when dispatched", TestLT_CtrlAltDispatchAllEntries)




; ==========================
; AltGr dispatch — Shift variant of each entry
; ==========================
TestLT_AltGrDispatchShiftedBaseRows() {
	; Temporarily swap GetKeyState-like logic by calling AltGrShiftDispatch with
	; shift=true. We just verify no crash — the stub absorbs all sends.
	ResetStubRecorders()
	for SC, Entry in ALTGR_BASE_ROWS {
		try {
			; Call with a non-existing shifted param: AltGrShiftDispatch uses
			; GetKeyState("Shift","P") internally. Since we are not in a hotkey
			; context, Shift is always reported as up — Plain fires.
			; We explicitly exercise Shifted by calling the callable directly.
			Cb := Entry.Shifted
			Cb()
		} catch as e {
			throw Error("Entry.Shifted() crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("ALTGR_BASE_ROWS: every Shifted callable runs without crashing",
	TestLT_AltGrDispatchShiftedBaseRows)

TestLT_AltGrDispatchPlainBaseRows() {
	ResetStubRecorders()
	for SC, Entry in ALTGR_BASE_ROWS {
		try {
			Cb := Entry.Plain
			Cb()
		} catch as e {
			throw Error("Entry.Plain() crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("ALTGR_BASE_ROWS: every Plain callable runs without crashing",
	TestLT_AltGrDispatchPlainBaseRows)

TestLT_AltGrNumberRowPlainNocrash() {
	ResetStubRecorders()
	for SC, Entry in ALTGR_NUMBER_ROW {
		try {
			Cb := Entry.Plain
			Cb()
		} catch as e {
			throw Error("ALTGR_NUMBER_ROW Plain crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("ALTGR_NUMBER_ROW: every Plain callable runs without crashing",
	TestLT_AltGrNumberRowPlainNocrash)

TestLT_AltGrNumberRowShiftedNocrash() {
	ResetStubRecorders()
	for SC, Entry in ALTGR_NUMBER_ROW {
		try {
			Cb := Entry.Shifted
			Cb()
		} catch as e {
			throw Error("ALTGR_NUMBER_ROW Shifted crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("ALTGR_NUMBER_ROW: every Shifted callable runs without crashing",
	TestLT_AltGrNumberRowShiftedNocrash)




; ==========================
; SHIFT_SYMBOLS and CAPSLOCK_SYMBOLS — each callable runs
; ==========================
TestLT_ShiftSymbolsAllRun() {
	ResetStubRecorders()
	for SC, Cb in SHIFT_SYMBOLS {
		try {
			F := Cb
			F()
		} catch as e {
			throw Error("SHIFT_SYMBOLS crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("SHIFT_SYMBOLS: every entry runs without crashing", TestLT_ShiftSymbolsAllRun)

TestLT_CapsLockSymbolsAllRun() {
	ResetStubRecorders()
	for SC, Cb in CAPSLOCK_SYMBOLS {
		try {
			F := Cb
			F()
		} catch as e {
			throw Error("CAPSLOCK_SYMBOLS crashed on " . SC . ": " . e.Message)
		}
	}
}
Test("CAPSLOCK_SYMBOLS: every entry runs without crashing", TestLT_CapsLockSymbolsAllRun)
