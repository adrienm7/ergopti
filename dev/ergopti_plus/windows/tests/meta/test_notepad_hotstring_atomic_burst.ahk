; tests/meta/test_notepad_hotstring_atomic_burst.ahk
;
; ==============================================================================
; MODULE: Notepad Hotstring Atomic Burst Meta Test
; DESCRIPTION:
; The clipboard compatibility path used to release Critical, SendEvent the
; erase, then paste in a second injection. A physical key could be inserted in
; the gap. The erase sequence must instead be passed into SendInstant as its
; prefix, and SendInstant must emit Prefix . "^v" in one SendInput call.
; ==============================================================================

#Requires AutoHotkey v2.0

_NHAB_NotepadEraseAndPasteAreOneBurst() {
    Dispatch := _DriverFuncBody("HSE_DispatchMatch")
    Legacy := _DriverFuncBody("_HotstringDispatch")
    SendBody := _DriverFuncBody("SendInstant")
    Assert(Dispatch != "" and Legacy != "" and SendBody != "", "both Notepad dispatchers and SendInstant must exist")
    Start := InStr(Dispatch, "if IsNotepadApp {")
    End := InStr(Dispatch, "} else {", , Start)
    Branch := (Start > 0 and End > Start) ? SubStr(Dispatch, Start, End - Start) : ""
    LegacyStart := InStr(Legacy, "if isNotepad {")
    LegacyEnd := InStr(Legacy, "} else if FinalResult", , LegacyStart)
    LegacyBranch := (LegacyStart > 0 and LegacyEnd > LegacyStart)
        ? SubStr(Legacy, LegacyStart, LegacyEnd - LegacyStart) : ""
    Assert(Branch != "", "HSE_DispatchMatch must retain an explicit Notepad branch")
    Assert(InStr(Branch, 'Critical("On")') > 0,
        "Notepad clipboard output must retain Critical across its one injection burst")
    Assert(InStr(Branch, "SendInstant(Replacement . EndCharEmitted, BackSpaceSeq)") > 0,
        "Notepad output must pass erase and paste to one SendInstant transaction")
    Assert(InStr(Branch, "SendNewResult(BackSpaceSeq") = 0,
        "Notepad output must not emit the erase through a separate SendEvent")
    Assert(InStr(LegacyBranch, "try SendInstant(Replacement . EndChar, BackSpaceSeq)") > 0
        and InStr(LegacyBranch, "SendNewResult(BackSpaceSeq") = 0,
        "legacy native hotstring callbacks must use the same indivisible Notepad clipboard transaction")
    Assert(InStr(SendBody, 'SendInput(Prefix . "^v")') > 0,
        "SendInstant must combine its prefix and Ctrl+V in one SendInput call")
}

Test("hotstrings: Notepad erase and clipboard paste are one atomic burst (notepad-hotstring-atomic-burst)",
    _NHAB_NotepadEraseAndPasteAreOneBurst)
