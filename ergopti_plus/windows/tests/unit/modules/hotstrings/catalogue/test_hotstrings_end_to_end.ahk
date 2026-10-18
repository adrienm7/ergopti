; tests/unit/modules/hotstrings/catalogue/test_hotstrings_end_to_end.ahk

; ==============================================================================
; MODULE: Hotstrings End-to-End, Activation and Office Tagging
; DESCRIPTION:
; CreateHotstring through its callback into the handler, the
; case-sensitive cascade, ActivateHotstrings and the Microsoft Office
; tagging.
; ==============================================================================

#Requires AutoHotkey v2.0





TestE2E_CaseSensSingleCharLowercase() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; Single-char "a → b" registers ONE conform spec. Firing its callback (the
    ; lowercase form) yields the lowercase replacement "b".
    CreateCaseSensitiveHotstrings("*?", "a", "b")
    AssertEqual(1, _Stub_HotstringRegistrations.Length)
    Cb := _Stub_HotstringRegistrations[1].callback
    Cb()
    AssertEqual("b", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: case-sensitive 1-char lowercase 'a → b' fires correctly",
    TestE2E_CaseSensSingleCharLowercase)

TestE2E_CaseSensSingleCharUppercase() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", "a", "b")
    ; Type the trigger as a capital. A 1-char abbr has no distinct UPPER form, so a
    ; typed capital maps to the Title-cased replacement "B" (== upper for one char).
    ; Case-sensitive check — AssertEqual uses != which is case-INSENSITIVE in v2.
    HSE_FeedReset(true)
    Match := HSE_FeedChar("A")
    Assert(Match != "", "uppercase 'A' must match the case-insensitive conform spec")
    HSE_DispatchMatch(Match, "")
    Burst := _Stub_RecordedSends[1].args[1]
    Assert(InStr(Burst, "{Text}B", true) > 0,
        "typed 'A' must produce the conformed replacement 'B'")
}
Test("End-to-end: case-sensitive 1-char uppercase 'A → B' fires correctly",
    TestE2E_CaseSensSingleCharUppercase)

TestE2E_HookInstalledNoRealRegistration() {
    ; Sanity: with the hook installed, CreateHotstring must NOT call the real
    ; AHK Hotstring() builtin. We verify by counting registrations (only those
    ; the recorder captures are visible).
    Before := _Stub_HotstringRegistrations.Length
    CreateHotstring("*", "test_hook_proof", "y")
    AssertEqual(Before + 1, _Stub_HotstringRegistrations.Length)
}
Test("Hook integration: installed hook captures CreateHotstring instead of AHK builtin",
    TestE2E_HookInstalledNoRealRegistration)

TestE2E_AToB() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; This is the foundational "a → b" hotstring from the user's brief.
    ; Typing "a" must delete one character and send "b". Typing "ac" then
    ; produces "bc" because "c" is a normal keystroke that follows.
    CreateHotstring("*", "a", "b")
    Cb := _Stub_HotstringRegistrations[1].callback
    Cb()
    AssertEqual(3, _Stub_RecordedSends.Length)
    AssertEqual("{BackSpace 1}", _Stub_RecordedSends[1].args[1])
    AssertEqual("b", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: 'a → b' callback deletes 1 and sends 'b'", TestE2E_AToB)

TestE2E_AbToAbc() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    ; The "ab → abc" example from the user's brief.
    CreateHotstring("*", "ab", "abc")
    Cb := _Stub_HotstringRegistrations[1].callback
    Cb()
    AssertEqual(3, _Stub_RecordedSends.Length)
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
    AssertEqual("abc", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: 'ab → abc' callback deletes 2 and sends 'abc'", TestE2E_AbToAbc)

TestE2E_LongAbbreviation() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    CreateHotstring("*", "approximately", "≈")
    Cb := _Stub_HotstringRegistrations[1].callback
    Cb()
    AssertEqual("{BackSpace 13}", _Stub_RecordedSends[1].args[1])
    AssertEqual("≈", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: long abbreviation produces correct BackSpace count and unicode replacement",
    TestE2E_LongAbbreviation)

TestE2E_FinalResultPreservesEndChar() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    CreateHotstring("", "btw", "by the way", Map("FinalResult", true))
    Cb := _Stub_HotstringRegistrations[1].callback
    Cb()
    ; Without `*` the hotstring fires on an end character; A_EndChar is "" in
    ; our manual call, so the third send is the empty string.
    AssertEqual("SendFinalResult", _Stub_RecordedSends[1].fn)
    AssertEqual("by the way", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: FinalResult=true passes through to every send",
    TestE2E_FinalResultPreservesEndChar)

TestE2E_CaseSensitiveLowercaseFires() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; First registration is the lowercase variant.
    Cb := _Stub_HotstringRegistrations[1].callback
    Cb()
    AssertEqual("{BackSpace 2}", _Stub_RecordedSends[1].args[1])
    AssertEqual("xy", _Stub_RecordedSends[2].args[1])
}
Test("End-to-end: CreateCaseSensitive lowercase callback sends lowercase replacement",
    TestE2E_CaseSensitiveLowercaseFires)

TestE2E_CaseSensitiveUppercaseFires() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; Type "AB" through the engine; the conform spec must emit the UPPER-cased
    ; replacement "XY" (case-sensitive — AssertEqual is case-insensitive in v2).
    HSE_FeedReset(true)
    HSE_FeedChar("A")
    Match := HSE_FeedChar("B")
    Assert(Match != "", "uppercase 'AB' must match the conform spec")
    HSE_DispatchMatch(Match, "")
    Burst := _Stub_RecordedSends[1].args[1]
    Assert(InStr(Burst, "XY", true) > 0, "typed 'AB' must produce UPPER 'XY'")
    Assert(!InStr(Burst, "xy", true), "must NOT emit lowercase 'xy' for UPPER input")
}
Test("End-to-end: CreateCaseSensitive conform emits UPPER replacement for UPPER input",
    TestE2E_CaseSensitiveUppercaseFires)

TestE2E_CaseSensitiveTitlecaseFires() {
    ResetHotstringRecorders()
    SimulateRegularApp()
    HSE_TestReset()
    CreateCaseSensitiveHotstrings("*?", "ab", "xy")
    ; Type "Ab" (Title); the conform spec must emit the Title-cased "Xy".
    HSE_FeedReset(true)
    HSE_FeedChar("A")
    Match := HSE_FeedChar("b")
    Assert(Match != "", "title-case 'Ab' must match the conform spec")
    HSE_DispatchMatch(Match, "")
    Burst := _Stub_RecordedSends[1].args[1]
    Assert(InStr(Burst, "Xy", true) > 0, "typed 'Ab' must produce Title 'Xy'")
    Assert(!InStr(Burst, "XY", true), "must NOT emit UPPER 'XY' for Title input")
}
Test("End-to-end: CreateCaseSensitive conform emits Title replacement for Title input",
    TestE2E_CaseSensitiveTitlecaseFires)





; =====================================
; =====================================
; ======= 6/ ActivateHotstrings =======
; =====================================
; =====================================

TestAH_SendsTwoCalls() {
    global HSE_Buffer
    ResetHotstringRecorders()
    ; Seed a pending abbreviation so the flush dance runs — the gate skips it
    ; on an empty buffer (activate-hotstrings-sleep-on-keyboard-thread).
    HSE_Buffer := "ia"
    ActivateHotstrings()
    AssertEqual(2, _Stub_RecordedSends.Length)
}
Test("ActivateHotstrings: produces exactly 2 send calls (Space + BackSpace)",
    TestAH_SendsTwoCalls)

TestAH_FirstSendIsSpace() {
    global HSE_Buffer
    ResetHotstringRecorders()
    HSE_Buffer := "ia"
    ActivateHotstrings()
    AssertEqual("SendNewResult", _Stub_RecordedSends[1].fn)
    AssertEqual(" ", _Stub_RecordedSends[1].args[1])
}
Test("ActivateHotstrings: first send is a literal space", TestAH_FirstSendIsSpace)

TestAH_SecondSendIsBackspace() {
    global HSE_Buffer
    ResetHotstringRecorders()
    HSE_Buffer := "ia"
    ActivateHotstrings()
    AssertEqual("SendNewResult", _Stub_RecordedSends[2].fn)
    AssertEqual("{BackSpace}", _Stub_RecordedSends[2].args[1])
    AssertEqual(false, _Stub_RecordedSends[2].args[2])
}
Test("ActivateHotstrings: second send is {BackSpace} with OnlyText=false",
    TestAH_SecondSendIsBackspace)





; ===========================================
; ===========================================
; ======= 7/ Microsoft Office tagging =======
; ===========================================
; ===========================================

TestMS_DetectsWord() {
    SimulateMicrosoftOffice()
    AssertTrue(MicrosoftApps())
}
Test("MicrosoftApps: detects WINWORD.EXE through the active-app cache",
    TestMS_DetectsWord)

TestMS_NonOfficeReturnsFalse() {
    SimulateRegularApp()
    AssertFalse(MicrosoftApps())
}
Test("MicrosoftApps: returns false for a non-Office foreground app",
    TestMS_NonOfficeReturnsFalse)

TestMS_NotepadIsNotOffice() {
    SimulateNotepadActive()
    AssertFalse(MicrosoftApps())
}
Test("MicrosoftApps: Notepad is not classified as an Office app",
    TestMS_NotepadIsNotOffice)
