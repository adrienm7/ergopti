; tests/meta/modules/keystats/test_keystats_journal_lifecycle_owner.ahk

; ==============================================================================
; MODULE: Keystats Journal Lifecycle Ownership Tests
; DESCRIPTION:
; Failed handoff compensation must fence every live reader, writer and teardown
; path, not just the next handoff. Shared scope behavior has separate unit tests.
; ==============================================================================

#Requires AutoHotkey v2.0

_KJLO_Entry(Name, FirstEffect) {
	Body := _StripFullLineComments(_DriverFuncBody(Name))
	AssertTrue(Body != "", "journal lifecycle function must exist: " . Name)
	AssertContains(Body, "Scope := _KL_JournalEnter(Token)")
	AssertContains(Body, "if !IsObject(Scope)")
	AssertContains(Body, "finally {")
	AssertContains(Body, "_KL_JournalLeave(Scope)")
	Admission := InStr(Body, "Scope := _KL_JournalEnter(Token)")
	Effect := InStr(Body, FirstEffect)
	AssertTrue(Effect > Admission, "ownership must precede the first lifecycle effect")
}

/** Registers vectors without publishing global loop variables. */
_KJLO_RegisterEntryCases() {
	local Name, FirstEffect
	for Name, FirstEffect in Map("KL_OpenTodayFh", "today := KL_Today()",
		"KL_CloseTodayFh", "Keystats._today_fh.Close()",
		"KL_ReadNewTodayLog", "KL_FlushTodayFh(Keystats._today_fh)",
		"KL_IngestOnce", "return KL_DayRollover(",
		"KL_DayRollover", "Keystats.rollover_in_progress := true",
		"KL_Stop", "KL_BeginShutdown()")
		Test("keystats: journal ownership fences " . Name . " (keystats-journal-lifecycle-owner)", _KJLO_Entry.Bind(Name, FirstEffect))
}
_KJLO_RegisterEntryCases()

_KJLO_PauseBeforeRepair(Name) {
	Body := _StripFullLineComments(_DriverFuncBody(Name))
	AssertTrue(Body != "")
	Pause := InStr(Body, "if A_IsSuspended && !Keystats._shutting_down")
	Admission := InStr(Body, "Scope := _KL_JournalEnter(Token)")
	AssertTrue(Pause > 0 && Admission > Pause,
		"a suspended timer must refuse before ownership acquisition can repair disk state")
}

/** Registers vectors without publishing global loop variables. */
_KJLO_RegisterPauseCases() {
	local Name
	for Name in ["KL_IngestOnce", "KL_DayRollover"]
		Test("keystats: pause precedes journal repair in " . Name . " (keystats-journal-pause-repair)", _KJLO_PauseBeforeRepair.Bind(Name))
}
_KJLO_RegisterPauseCases()
