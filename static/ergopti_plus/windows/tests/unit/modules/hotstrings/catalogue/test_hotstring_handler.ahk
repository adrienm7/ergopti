; tests/unit/modules/hotstrings/catalogue/test_hotstring_handler.ahk

; ==============================================================================
; MODULE: HotstringHandler Branches
; DESCRIPTION:
; HotstringHandler's branches and boundary cases: case transfer, delays,
; empty and long replacements, and the per-entry options it receives.
; ==============================================================================

#Requires AutoHotkey v2.0





TestHH_PriorKeyMissingFailsClosed() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; Map is empty — the prior char's timestamp may have been pruned after a
    ; long pause, so IsTimeActivationExpired must fail CLOSED (expired) and the
    ; time-gated expansion must be suppressed (0 sends), not fire as if typed now.
    LastSentCharacterKeyTime := Map()
    _TestCallHotstring("ab", "x", "", true, false, 1)
    AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: prior key absent from timing Map fails closed (suppressed)",
    TestHH_PriorKeyMissingFailsClosed)

TestHH_PriorKeyDifferentCharFailsClosed() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; The handler asks IsTimeActivationExpired for SubStr("xy", -2, 1) == "x".
    ; Only "y" is tracked, so the gate char "x" has no timestamp — we cannot
    ; prove "x" was typed recently, so the gate fails CLOSED (suppressed).
    LastSentCharacterKeyTime := Map("y", A_TickCount - 60000)
    _TestCallHotstring("xy", "z", "", true, false, 1)
    AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: absent gate-char timing fails closed (suppressed)",
    TestHH_PriorKeyDifferentCharFailsClosed)

TestHH_NotepadFinalResultStillNotepad() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    ; Even with FinalResult=true, the Notepad branch wins (it returns before
    ; the FinalResult check is reached).
    _TestCallHotstring("ab", "x", "!", true, true, 0)
    AssertEqual(1, _Stub_RecordedSends.Length)
    AssertEqual("SendInstant", _Stub_RecordedSends[1].fn)
}
Test("HotstringHandler: Notepad branch overrides FinalResult and uses SendInstant",
    TestHH_NotepadFinalResultStillNotepad)

TestHH_ReplacementWithControlChars() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; The replacement may contain any text; the handler must pass it verbatim
    ; without escaping or stripping.
    _TestCallHotstring("ab", "{Enter}", "", false, false, 0)
    AssertEqual("{Enter}", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement passes control sequences verbatim",
    TestHH_ReplacementWithControlChars)

TestHH_ReplacementWithLeadingSpace() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", " leading", "", true, false, 0)
    AssertEqual(" leading", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement preserves leading whitespace",
    TestHH_ReplacementWithLeadingSpace)

TestHH_BackspaceCountSingleChar() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("a", "b", "", true, false, 0)
    AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 1-char abbr → BackSpace 1", TestHH_BackspaceCountSingleChar)

TestHH_BackspaceCountTwoChar() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "abc", "", true, false, 0)
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 2-char abbr → BackSpace 2", TestHH_BackspaceCountTwoChar)

TestHH_BackspaceCountFiveChar() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("hello", "world", "", true, false, 0)
    AssertEqual("{BackSpace 5}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: 5-char abbr → BackSpace 5", TestHH_BackspaceCountFiveChar)

TestHH_BackspaceCountUnicodeAbbr() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; ★ is one Unicode code point; StrLen counts it as 1. The actual on-screen
    ; character takes one BackSpace press, so the count must remain 1.
    _TestCallHotstring("★", "x", "", true, false, 0)
    AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: Unicode abbr counts as one BackSpace", TestHH_BackspaceCountUnicodeAbbr)

TestHH_BackspaceFlagOnlyTextFalse() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "", true, false, 0)
    ; The BackSpace control sequence must be sent with OnlyText=false so it
    ; is interpreted as a real key press, not as literal text {BackSpace 2}.
    AssertEqual(false, _Stub_RecordedSends[1].args[2])
}
Test("HotstringHandler: BackSpace send uses OnlyText=false",
    TestHH_BackspaceFlagOnlyTextFalse)

TestHH_ReplacementIsSecondSend() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "REPLACE", "", true, false, 0)
    AssertEqual("REPLACE", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: replacement payload is the second send", TestHH_ReplacementIsSecondSend)

TestHH_EndCharIsThirdSend() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", " ", true, false, 0)
    AssertEqual(" ", _Stub_RecordedSends[3].args[1])
}
Test("HotstringHandler: end character is the third send", TestHH_EndCharIsThirdSend)

TestHH_EndCharFlagOnlyTextFalse() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    ; EndChar must be sent with OnlyText=false (third positional arg).
    AssertEqual(false, _Stub_RecordedSends[3].args[2])
}
Test("HotstringHandler: end character send uses OnlyText=false",
    TestHH_EndCharFlagOnlyTextFalse)

TestHH_DefaultPathSendCount() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: default path issues exactly 3 sends", TestHH_DefaultPathSendCount)

TestHH_DefaultPathUsesSendNewResult() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
    AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
    AssertEqual("SendNewResult", _Stub_RecordedSends[3].fn)
}
Test("HotstringHandler: default path uses SendNewResult for every send",
    TestHH_DefaultPathUsesSendNewResult)

TestHH_FinalResultUsesSendFinalResult() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "!", true, true, 0)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[2].fn)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[3].fn)
}
Test("HotstringHandler: FinalResult=true switches all three sends to SendFinalResult",
    TestHH_FinalResultUsesSendFinalResult)

TestHH_NotepadPathSendCount() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    ; Notepad path: erase prefix + clipboard paste are one SendInstant transaction.
    AssertEqual(1, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: Notepad branch issues one atomic send", TestHH_NotepadPathSendCount)

TestHH_NotepadPathUsesSendInstant() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    _TestCallHotstring("ab", "x", "!", true, false, 0)
    AssertEqual(1, _Stub_RecordedSends.Length)
    AssertEqual("SendInstant", _Stub_RecordedSends[1].fn)
}
Test("HotstringHandler: Notepad branch uses SendInstant for replacement+endchar",
    TestHH_NotepadPathUsesSendInstant)

TestHH_NotepadPathCombinesReplacementAndEndChar() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    _TestCallHotstring("ab", "REPL", "!", true, false, 0)
    ; Notepad path concatenates Replacement . EndChar into one paste payload while
    ; passing the erase sequence as SendInstant's atomic prefix.
    AssertEqual("REPL!", _Stub_RecordedSends[1].args[1])
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[2])
}
Test("HotstringHandler: Notepad branch concatenates Replacement and EndChar",
    TestHH_NotepadPathCombinesReplacementAndEndChar)

TestHH_TimeActivationExpiredSkipsAll() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    LastSentCharacterKeyTime := Map("a", A_TickCount - 60000)
    _TestCallHotstring("ab", "x", "", true, false, 1)
    ; Timeout 1 s exceeded by the 60 s gap → handler returns immediately.
    AssertEqual(0, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: expired time-activation produces zero sends",
    TestHH_TimeActivationExpiredSkipsAll)

TestHH_TimeActivationFreshAllowsAll() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    LastSentCharacterKeyTime := Map("a", A_TickCount)
    _TestCallHotstring("ab", "x", "", true, false, 1)
    AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: fresh prior-key timing within window allows expansion",
    TestHH_TimeActivationFreshAllowsAll)

TestHH_TimeActivationZeroDisablesGuard() {
    global LastSentCharacterKeyTime
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; Even with a stale prior key, timeout=0 must NEVER expire.
    LastSentCharacterKeyTime := Map("a", A_TickCount - 3600 * 1000)
    _TestCallHotstring("ab", "x", "", true, false, 0)
    AssertEqual(3, _Stub_RecordedSends.Length)
}
Test("HotstringHandler: TimeActivationSeconds=0 disables the guard entirely",
    TestHH_TimeActivationZeroDisablesGuard)

TestHH_OnlyTextFlagPropagation() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "x", "", false, false, 0)
    ; OnlyText=false → second send uses OnlyText=false (so SendEvent treats x as keys).
    AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("HotstringHandler: OnlyText=false flows to the replacement send",
    TestHH_OnlyTextFlagPropagation)

TestHH_EmptyAbbrYieldsZeroBackspace() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("", "x", "", true, false, 0)
    AssertEqual("{BackSpace 0}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: empty abbreviation produces BackSpace 0",
    TestHH_EmptyAbbrYieldsZeroBackspace)

TestHH_EmptyReplacementStillThreeSends() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ab", "", "", true, false, 0)
    ; Empty replacement is still emitted as the second send.
    AssertEqual(3, _Stub_RecordedSends.Length)
    AssertEqual("", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: empty replacement is still emitted as the second send",
    TestHH_EmptyReplacementStillThreeSends)

TestHH_StarMagicKeyAbbr() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; Abbreviation ending with MagicKey "★" — StrLen("ab★") = 3
    _TestCallHotstring("ab★", "x", "", true, false, 0)
    AssertEqual("{BackSpace 3}", _Stub_RecordedSends[1].args[1])
}
Test("HotstringHandler: MagicKey in abbreviation is counted by StrLen",
    TestHH_StarMagicKeyAbbr)

TestHH_OnlyTextTruePropagation() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; OnlyText=true must flow to the replacement send (second send).
    _TestCallHotstring("ab", "x", "", true, false, 0)
    AssertEqual(true, _Stub_RecordedSends[2].args[2])
}
Test("HotstringHandler: OnlyText=true flows to the replacement send",
    TestHH_OnlyTextTruePropagation)

TestHH_FinalResultBackspaceIsFinal() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; FinalResult=true path — all three sends must use SendFinalResult.
    _TestCallHotstring("xy", "hello", ".", true, true, 0)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
    AssertEqual(false, _Stub_RecordedSends[1].args[2])
}
Test("HotstringHandler: FinalResult backspace uses SendFinalResult with OnlyText=false",
    TestHH_FinalResultBackspaceIsFinal)

TestHH_FinalResultEndCharIsFinal() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("xy", "hello", ".", true, true, 0)
    AssertEqual("SendFinalResult", _Stub_RecordedSends[3].fn)
    AssertEqual(".", _Stub_RecordedSends[3].args[1])
}
Test("HotstringHandler: FinalResult end character uses SendFinalResult",
    TestHH_FinalResultEndCharIsFinal)

TestHH_UnicodeReplacementPreserved() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("->", "→", "", true, false, 0)
    AssertEqual("→", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: Unicode arrow replacement is preserved verbatim",
    TestHH_UnicodeReplacementPreserved)

TestHH_EmojisInReplacement() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    _TestCallHotstring("ok", "👍", "", true, false, 0)
    AssertEqual("👍", _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: emoji replacement is preserved verbatim",
    TestHH_EmojisInReplacement)

TestHH_MultiLineReplacement() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    Multi := "line1" . "`n" . "line2"
    _TestCallHotstring("ml", Multi, "", true, false, 0)
    AssertEqual(Multi, _Stub_RecordedSends[2].args[1])
}
Test("HotstringHandler: multi-line replacement is passed through unchanged",
    TestHH_MultiLineReplacement)

TestHH_NotepadAbbrWithUnicode() {
    ResetHotstringRecorders()
    SimulateNotepadActive()
    ; With Notepad + Unicode in abbr, BackSpace count must match StrLen("ab")
    _TestCallHotstring("ab", "★", "!", true, false, 0)
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[2])
    AssertContains(_Stub_RecordedSends[1].args[1], "★")
}
Test("HotstringHandler: Notepad path with Unicode replacement preserves character",
    TestHH_NotepadAbbrWithUnicode)
