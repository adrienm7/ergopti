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
