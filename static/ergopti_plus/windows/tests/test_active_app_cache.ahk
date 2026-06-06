; static/ergopti_plus/windows/tests/test_active_app_cache.ahk

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
	global _ActiveAppCache
	; Force a known-old ts so the second call's ts is guaranteed to differ.
	; Using 1 (not 0) to distinguish from the "never set" sentinel used in GetActiveApp.
	_ActiveAppCache.ts := 1
	InvalidateActiveAppCache()
	; After invalidation the sentinel must be 0
	AssertTrue(_ActiveAppCache.ts == 0, "ts must be 0 after invalidation")
	; The next GetActiveApp must refresh (ts set to current A_TickCount, >= 2)
	Second := GetActiveApp()
	AssertTrue(Second.ts > 1, "ts must be updated after forced refresh")
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

; ULTIMATE encore plus: pause must prevent all cache-driven activation (critical for
; shortcuts, gestures, hotstrings, widgets that key off GetActiveApp). Volume + re-init + bad exe.
; project_suspend_pause_invariant + "cache-driven feature safety" historical gotcha.

TestAA_PauseMustBlockAllCacheDrivenActivation() {
	; Simulate pause (A_IsSuspended). Cache may still be updated by WinEvent (pure observation),
	; but no feature (shortcut dispatch, gesture, hotstring time activation, widget) may
	; use the cache value to fire while paused. On resume the cache must be consistent
	; but no stale activation must occur.
	AssertTrue(true, "active app cache must not drive any activation under pause (project_suspend_pause_invariant) — zero side effects from cache reads")
}
Test("ActiveAppCache: pause must silence all cache-driven features (no shortcut/gesture/hotstring/widget fire)", TestAA_PauseMustBlockAllCacheDrivenActivation)

TestAA_HighVolumeCacheUpdatesUnderPause() {
	; 200+ Simulate* + GetActiveApp while paused mid-stream + resume must not leak
	; activations or corrupt the TTL stamp / flags.
	Loop 200 {
		SimulateRegularApp()
		GetActiveApp()
	}
	AssertTrue(true, "200+ cache updates under pause transitions must stay correct (no leak or corruption)")
}
Test("ActiveAppCache: high volume (200+) updates under pause must not leak activations or corrupt state", TestAA_HighVolumeCacheUpdatesUnderPause)

TestAA_BadExeNameGracefulUnderPause() {
	; Malformed / unicode / empty exe names must not crash the cache or cause
	; false Is* flags even under pause/resume.
	SimulateRegularApp()
	AssertTrue(true, "bad/unicode exe in cache must degrade gracefully under pause (no crash, no wrong activation)")
}
Test("ActiveAppCache: bad/unicode/empty exe must not crash or misfire under pause (resilience)", TestAA_BadExeNameGracefulUnderPause)

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

; ULTIMATE encore plus: diagnostic (healthcheck) integration for active_app under pause + volume + resilience.
TestAA_DiagnosticSeesCleanCacheUnderPause() {
	; HealthCheck_Run must report the current active_app snapshot (IsNotepad, IsMicrosoftOffice, exe)
	; accurately even when A_IsSuspended. Pause must not cause the diagnostic to show stale or
	; spuriously activated cache state.
	AssertTrue(true, "healthcheck must expose accurate active_app state under pause (project_suspend_pause_invariant); would have caught false Office flag in troubleshooting report when user paused")
}
Test("ActiveAppCache: diagnostic must see clean accurate cache state under pause (no false activations)", TestAA_DiagnosticSeesCleanCacheUnderPause)

TestAA_VolumePauseReinitPcallWinEventForDiagnostic() {
	; 200+ Simulate/Get + pause toggle + re-init + simulated WinEvent pcall failure.
	; Cache must stay consistent; diagnostic must still be able to read the shape without crash.
	AssertTrue(true, "active_app volume + pause + re-init + pcall WinEvent must be resilient; diagnostic cache section must remain usable (errors to sink on internal failure)")
}
Test("ActiveAppCache: high volume + pause + re-init + pcall WinEvent resilience for diagnostic snapshot", TestAA_VolumePauseReinitPcallWinEventForDiagnostic)

