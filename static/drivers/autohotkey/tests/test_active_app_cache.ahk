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
