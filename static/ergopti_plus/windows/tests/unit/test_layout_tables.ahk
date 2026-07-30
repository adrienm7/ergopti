; static/ergopti_plus/windows/tests/unit/test_layout_tables.ahk

; ==============================================================================
; MODULE: Layout Tables Tests
; DESCRIPTION:
; Sanity tests for the data tables produced by modules/keymap/layout/layout_altgr.ahk and
; modules/keymap/layout/layout_shift_caps.ahk. Includes a regression test for the AltGr
; dispatch crash (commit 48369d96) that fired every BoundFunc entry through
; AltGrShiftDispatch and asserted no exception bubbles up.
; ==============================================================================

; Build the tables once (idempotent — calling twice is fine).
_BuildAltGrTables()
_BuildShiftCapsTables()




; ── Assertion helpers ──
_AssertSCsPresent(M, SCs) {
	for SC in SCs {
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
	for SC in ALTGR_BASE_ROWS {
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
	for SC in ALTGR_PLUS_OVERRIDES {
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
	for SC in ALTGR_NUMBER_ROW {
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
	ResetStubRecorders()
	_LSCResetFrom([])
	; SendNewResult("È") -> SendEvent(...) -> UpdateLastSentCharacter("È")
	LayerDispatch("SC010", SHIFT_SYMBOLS)
	AssertEqual("È", _Stub_LastChars[_Stub_LastChars.Length])
}
Test("LayerDispatch: shift letter pushes the uppercase letter via SendNewResult",
	TestLT_LayerDispatchLetter)

TestLT_LayerDispatchSymbol() {
	ResetStubRecorders()
	_LSCResetFrom([])
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
; Shift-layer French typography — exact nbsp/nnbsp prefix per punctuation
; ==========================
; Regression guard for the Ergopti layout emulation (AHK only — macOS uses
; Karabiner): Shift+period must emit a full no-break space (NBSP, U+00A0)
; before ":" while Shift+comma emits a NARROW no-break space (NNBSP, U+202F)
; before ";". The two spaces are visually identical but distinct codepoints,
; and downstream hotstring case variants key off the exact prefix the layout
; emits — swapping NBSP and NNBSP silently broke matching.

; Returns the SendNewResult payload whose final character is TargetChar,
; skipping the " " / "{BackSpace}" pokes that ActivateHotstrings emits first.
_LT_RecordedSymbolFor(TargetChar) {
	global _Stub_RecordedSends
	for _, Rec in _Stub_RecordedSends {
		if (Rec.fn == "SendNewResult" && SubStr(Rec.args[1], -1) == TargetChar) {
			return Rec.args[1]
		}
	}
	return ""
}

; Hooks are installed globally by run_all.ahk, so these tests only reset the
; recorders and read back the captured SendNewResult payloads — they must NOT
; install/uninstall hooks themselves (that would tear down the shared hook for
; every later test in the process).
TestLT_ShiftPeriodEmitsNbspColon() {
	ResetHotstringRecorders()
	LayerDispatch("SC022", SHIFT_SYMBOLS)   ; Shift+period -> ":" on Ergopti
	Payload := _LT_RecordedSymbolFor(":")
	AssertEqual(Chr(0xA0) ":", Payload,
		"Shift+period emits NBSP (U+00A0) + colon per French typography")
	AssertEqual(Chr(0xA0), SubStr(Payload, 1, 1),
		"the colon prefix is a full no-break space, never the narrow NNBSP")
}
Test("SHIFT_SYMBOLS: Shift+period emits NBSP + colon (not NNBSP)",
	TestLT_ShiftPeriodEmitsNbspColon)

TestLT_ShiftCommaEmitsNnbspSemicolon() {
	ResetHotstringRecorders()
	LayerDispatch("SC02F", SHIFT_SYMBOLS)   ; Shift+comma -> semicolon on Ergopti
	Payload := _LT_RecordedSymbolFor(Chr(0x3B))
	AssertEqual(Chr(0x202F) Chr(0x3B), Payload,
		"Shift+comma emits NNBSP (U+202F) + semicolon per French typography")
	AssertEqual(Chr(0x202F), SubStr(Payload, 1, 1),
		"the semicolon prefix is the narrow no-break space, never the full NBSP")
}
Test("SHIFT_SYMBOLS: Shift+comma emits NNBSP + semicolon (not NBSP)",
	TestLT_ShiftCommaEmitsNnbspSemicolon)




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
	for SC in ["SC002", "SC003", "SC004", "SC005", "SC006",
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
	for Combo in CTRL_ALT_NUMPAD {
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





; ==========================================================================
; ==========================================================================
; ======= Regression: AltGr number-row must not require ergopti_base =======
; ==========================================================================
; ==========================================================================

; Source-scan the registration block in layout_altgr.ahk to ensure the HotIf
; condition for ALTGR_NUMBER_ROW does not require ergopti_base. When that
; requirement existed, AltGr+digit (superscripts, subscripts, euro) were silently
; disabled for users who had Ergopti AltGr on but Ergopti base emulation off.
TestLT_AltGrNumberRowRegistrationNoErgoptiBase() {
	; Move-resilient: scan the layout module dir via the framework helper instead of
	; a pinned modules/keymap/layout/layout_altgr.ahk read. The ergopti_alt_gr HotIf token is
	; unique to layout_altgr.ahk within modules/keymap/layout, so the scan stays scoped to it.
	Content := _DriverDirConcat("modules/keymap/layout")
	; Locate the HotIf line that gates ALTGR_NUMBER_ROW registration.
	; That line should contain "ergopti_alt_gr" but must NOT contain "ergopti_base".
	Pattern := "HotIf\([^)]*ergopti_alt_gr[^)]*\)"
	Pos := 1
	while (Pos := RegExMatch(Content, Pattern, &M, Pos)) {
		if InStr(M[], "ergopti_base") {
			AssertFalse(true,
				"ALTGR_NUMBER_ROW HotIf condition must not require ergopti_base"
				. " (superscripts/subscripts are layout-independent). Found: " . M[])
			return
		}
		Pos += StrLen(M[])
	}
	; No forbidden condition found.
	AssertTrue(true)
}
Test("ALTGR_NUMBER_ROW registration: HotIf does not require ergopti_base",
	TestLT_AltGrNumberRowRegistrationNoErgoptiBase)
