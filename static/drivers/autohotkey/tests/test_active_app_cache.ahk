; static/drivers/autohotkey/tests/test_active_app_cache.ahk

; ==============================================================================
; MODULE: Active App Cache Tests
; DESCRIPTION:
; Verifies the cache invalidation logic and the IsMicrosoftOffice / IsNotepad
; flag derivation. The actual ``WinGet*`` calls are wrapped in try/catch so
; running in CI without a foreground window is a non-issue.
; ==============================================================================




; ==========================
; Constants
; ==========================
TestAA_TtlPositive() {
	AssertTrue(ACTIVE_APP_CACHE_TTL_MS > 0)
	AssertTrue(ACTIVE_APP_CACHE_TTL_MS <= 1000)
}
Test("ACTIVE_APP_CACHE_TTL_MS: positive and below 1 second", TestAA_TtlPositive)

TestAA_OfficeBigFour() {
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("Teams.exe"))
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("WINWORD.EXE"))
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("EXCEL.EXE"))
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("OUTLOOK.EXE"))
}
Test("MICROSOFT_OFFICE_EXES: includes Teams, Word, Excel, Outlook", TestAA_OfficeBigFour)

TestAA_OfficeNewExes() {
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("ms-teams.exe"))
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("olk.exe"))
}
Test("MICROSOFT_OFFICE_EXES: includes the new ms-teams.exe and olk.exe",
	TestAA_OfficeNewExes)




; ==========================
; GetActiveApp
; ==========================
TestAA_GetActiveAppShape() {
	App := GetActiveApp()
	AssertTrue(App.HasOwnProp("Class"))
	AssertTrue(App.HasOwnProp("Exe"))
	AssertTrue(App.HasOwnProp("IsNotepad"))
	AssertTrue(App.HasOwnProp("IsMicrosoftOffice"))
	AssertTrue(App.HasOwnProp("ts"))
}
Test("GetActiveApp: returns an object with the documented fields",
	TestAA_GetActiveAppShape)

TestAA_CacheReuse() {
	InvalidateActiveAppCache()
	First := GetActiveApp()
	FirstTs := First.ts
	Second := GetActiveApp()
	AssertEqual(FirstTs, Second.ts)
}
Test("GetActiveApp: caches snapshot within TTL window", TestAA_CacheReuse)

TestAA_InvalidateForcesRefresh() {
	First := GetActiveApp()
	FirstTs := First.ts
	InvalidateActiveAppCache()
	Sleep(2)
	Second := GetActiveApp()
	AssertTrue(Second.ts > FirstTs or Second.ts == 0)
}
Test("InvalidateActiveAppCache: forces a refresh on the next call",
	TestAA_InvalidateForcesRefresh)




; ==========================
; Simulator helpers (from test_stubs.ahk)
; ==========================
TestAA_SimulateNotepad() {
	SimulateNotepadActive()
	App := GetActiveApp()
	AssertTrue(App.IsNotepad)
	AssertFalse(App.IsMicrosoftOffice)
	AssertEqual("notepad.exe", App.Exe)
}
Test("SimulateNotepadActive: cache reflects Notepad flags", TestAA_SimulateNotepad)

TestAA_SimulateRegularApp() {
	SimulateRegularApp()
	App := GetActiveApp()
	AssertFalse(App.IsNotepad)
	AssertFalse(App.IsMicrosoftOffice)
}
Test("SimulateRegularApp: cache reflects non-special app flags", TestAA_SimulateRegularApp)

TestAA_SimulateMicrosoftOffice() {
	SimulateMicrosoftOffice()
	App := GetActiveApp()
	AssertFalse(App.IsNotepad)
	AssertTrue(App.IsMicrosoftOffice)
	AssertEqual("WINWORD.EXE", App.Exe)
}
Test("SimulateMicrosoftOffice: cache reflects Office flags", TestAA_SimulateMicrosoftOffice)

TestAA_SimulatorCachedWithinTTL() {
	; Write a known state, immediately read back — must not re-query WinGet*
	SimulateNotepadActive()
	First := GetActiveApp()
	; Mutate cache to test.exe to distinguish a re-fetch
	SimulateRegularApp()
	; Within TTL the old stamp is gone (SimulateRegularApp overwrites ts),
	; so just confirm the flag is now false
	Second := GetActiveApp()
	AssertFalse(Second.IsNotepad)
}
Test("SimulateRegularApp after SimulateNotepad: GetActiveApp reflects new state",
	TestAA_SimulatorCachedWithinTTL)




; ==========================
; MICROSOFT_OFFICE_EXES completeness
; ==========================
TestAA_OfficePowerPoint() {
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("POWERPNT.EXE"))
}
Test("MICROSOFT_OFFICE_EXES: includes PowerPoint", TestAA_OfficePowerPoint)

TestAA_OfficeExcel() {
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("EXCEL.EXE"))
}
Test("MICROSOFT_OFFICE_EXES: includes Excel", TestAA_OfficeExcel)

TestAA_OfficeOneNote() {
	AssertTrue(MICROSOFT_OFFICE_EXES.Has("ONENOTE.exe"))
}
Test("MICROSOFT_OFFICE_EXES: includes OneNote", TestAA_OfficeOneNote)

TestAA_OfficeNotNotepad() {
	AssertFalse(MICROSOFT_OFFICE_EXES.Has("notepad.exe"))
}
Test("MICROSOFT_OFFICE_EXES: does not include notepad.exe", TestAA_OfficeNotNotepad)
