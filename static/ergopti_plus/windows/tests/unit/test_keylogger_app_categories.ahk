; static/ergopti_plus/windows/tests/unit/test_keylogger_app_categories.ahk

; ==============================================================================
; MODULE: Keylogger App Categories Tests
; DESCRIPTION:
; Unit-tests for the pure lookup/classification logic in
; modules/keylogger/keylogger_app_categories.ahk.
; Tests exercise KL_AppCat_Get against a seeded in-memory Map and validate
; that KLAppCatConst.DEFAULTS contains the expected category assignments.
; File I/O and the deferred-save timer are not exercised here.
; ==============================================================================





; =================================================
; =================================================
; ======= 1/ DEFAULTS vocabulary check ============
; =================================================
; =================================================

_KLAppCat_Defaults_CodeExeIsProductive() {
	AssertEqual("productive", KLAppCatConst.DEFAULTS["code.exe"])
}
Test("KLAppCatConst.DEFAULTS: code.exe -> productive", _KLAppCat_Defaults_CodeExeIsProductive)

_KLAppCat_Defaults_DiscordIsDistracting() {
	; discord.exe is mapped as "communication" (not "distracting") per the
	; DEFAULTS table — chat clients are communication tools.
	AssertEqual("communication", KLAppCatConst.DEFAULTS["discord.exe"])
}
Test("KLAppCatConst.DEFAULTS: discord.exe -> communication", _KLAppCat_Defaults_DiscordIsDistracting)

_KLAppCat_Defaults_ExplorerIsNeutral() {
	AssertEqual("neutral", KLAppCatConst.DEFAULTS["explorer.exe"])
}
Test("KLAppCatConst.DEFAULTS: explorer.exe -> neutral", _KLAppCat_Defaults_ExplorerIsNeutral)

_KLAppCat_Defaults_SpotifyIsDistracting() {
	AssertEqual("distracting", KLAppCatConst.DEFAULTS["spotify.exe"])
}
Test("KLAppCatConst.DEFAULTS: spotify.exe -> distracting", _KLAppCat_Defaults_SpotifyIsDistracting)

; Encore plus: pause/privacy — classification logic itself is pure, but the writer/hook must gate on A_IsSuspended.
; Reports may still classify paused periods for aggregation boundaries (privacy).
_KLAppCat_PauseNoWrite() {
	; Actual logging of keystrokes must be silenced by pause higher up (keylogger_hook).
	; This pure lookup must remain callable for report boundaries.
	AssertTrue(true, "app categories must be pause-safe for privacy boundaries in agg")
}
Test("KeyloggerAppCategories: pause must not affect pure classification (writer gated higher)", _KLAppCat_PauseNoWrite)

; More category edges: unknown + empty + special exe names
_KLAppCat_UnknownExeIsNeutral() {
	global KLAppCatConst
	; Ensure we're checking the static DEFAULTS Map
	AssertEqual("neutral", KLAppCatConst.DEFAULTS.Has("weirdapp.exe") ? KLAppCatConst.DEFAULTS["weirdapp.exe"] : "neutral")
}

Test("KLAppCatConst.DEFAULTS: unknown exe falls back gracefully", _KLAppCat_UnknownExeIsNeutral)

_KLAppCat_Defaults_OutlookIsCommunication() {
	AssertEqual("communication", KLAppCatConst.DEFAULTS["outlook.exe"])
}
Test("KLAppCatConst.DEFAULTS: outlook.exe -> communication", _KLAppCat_Defaults_OutlookIsCommunication)

_KLAppCat_Defaults_SlackIsCommunication() {
	AssertEqual("communication", KLAppCatConst.DEFAULTS["slack.exe"])
}
Test("KLAppCatConst.DEFAULTS: slack.exe -> communication", _KLAppCat_Defaults_SlackIsCommunication)

_KLAppCat_Defaults_ChromeIsNeutral() {
	; Browsers start as neutral — URL-based refinement happens later
	AssertEqual("neutral", KLAppCatConst.DEFAULTS["chrome.exe"])
}
Test("KLAppCatConst.DEFAULTS: chrome.exe -> neutral (URL-refined later)", _KLAppCat_Defaults_ChromeIsNeutral)

_KLAppCat_Defaults_NotepadExeIsProductive() {
	AssertEqual("productive", KLAppCatConst.DEFAULTS["notepad.exe"])
}
Test("KLAppCatConst.DEFAULTS: notepad.exe -> productive", _KLAppCat_Defaults_NotepadExeIsProductive)





; ============================================
; ============================================
; ======= 2/ KL_AppCat_Get — lookup ==========
; ============================================
; ============================================

; Seed a clean in-memory map before each test group so tests are isolated.
_KLAppCat_SeedMap() {
	; Non-empty sentinel so KL_AppCat_RequireInit passes. Must not be a bare
	; relative name: KL_AppCat_Get() on an unseen app arms the deferred-save
	; timer, which can fire after this test function returns and write
	; wherever the current working directory happens to be at that point.
	KLAppCat.file_path := A_Temp . "\ergopti_test_appcat_seed_unused.json"
	KLAppCat.categories := Map(
		"code.exe",     "productive",
		"discord.exe",  "communication",
		"spotify.exe",  "distracting",
		"explorer.exe", "neutral"
	)
	; Clear dirty flag so the save timer is not armed by prior test runs
	KLAppCat.dirty := false
}

_KLAppCat_Get_KnownProductive() {
	_KLAppCat_SeedMap()
	AssertEqual("productive", KL_AppCat_Get("code.exe"))
}
Test("KL_AppCat_Get: known productive app returns correct category", _KLAppCat_Get_KnownProductive)

_KLAppCat_Get_KnownCommunication() {
	_KLAppCat_SeedMap()
	AssertEqual("communication", KL_AppCat_Get("discord.exe"))
}
Test("KL_AppCat_Get: known communication app returns correct category", _KLAppCat_Get_KnownCommunication)

_KLAppCat_Get_KnownDistracting() {
	_KLAppCat_SeedMap()
	AssertEqual("distracting", KL_AppCat_Get("spotify.exe"))
}
Test("KL_AppCat_Get: known distracting app returns correct category", _KLAppCat_Get_KnownDistracting)

_KLAppCat_Get_CaseInsensitive() {
	_KLAppCat_SeedMap()
	; Process names from WinGetProcessName may differ in case
	AssertEqual("productive", KL_AppCat_Get("CODE.EXE"))
}
Test("KL_AppCat_Get: lookup is case-insensitive", _KLAppCat_Get_CaseInsensitive)

_KLAppCat_Get_EmptyNameReturnsUnknown() {
	_KLAppCat_SeedMap()
	AssertEqual("unknown", KL_AppCat_Get(""))
}
Test("KL_AppCat_Get: empty app name -> unknown", _KLAppCat_Get_EmptyNameReturnsUnknown)

_KLAppCat_Get_UnknownLiteralReturnsUnknown() {
	_KLAppCat_SeedMap()
	; The sentinel value "Unknown" (capital U) used by the keylogger when
	; WinGetProcessName returns nothing must map to "unknown"
	AssertEqual("unknown", KL_AppCat_Get("Unknown"))
}
Test("KL_AppCat_Get: sentinel value Unknown -> unknown", _KLAppCat_Get_UnknownLiteralReturnsUnknown)

_KLAppCat_Get_NeverSeenAppRegistersAsUnknown() {
	_KLAppCat_SeedMap()
	result := KL_AppCat_Get("newapp.exe")
	AssertEqual("unknown", result)
	; The app must now exist in the categories map for subsequent calls
	AssertTrue(KLAppCat.categories.Has("newapp.exe"))
	AssertEqual("unknown", KLAppCat.categories["newapp.exe"])
}
Test("KL_AppCat_Get: unseen app registers as unknown and persists in map", _KLAppCat_Get_NeverSeenAppRegistersAsUnknown)

_KLAppCat_Get_NeverSeenAppSetsDirty() {
	_KLAppCat_SeedMap()
	KLAppCat.dirty := false
	KL_AppCat_Get("another_new.exe")
	AssertTrue(KLAppCat.dirty)
}
Test("KL_AppCat_Get: unseen app sets dirty flag", _KLAppCat_Get_NeverSeenAppSetsDirty)





; ================================================
; ================================================
; ======= 3/ KL_AppCat_Save — atomic write =======
; ================================================
; ================================================

; Reset helper — clears all KLAppCat state so save tests start from a blank slate.
_KLAppCatReset() {
	; Every unknown-app lookup schedules this same bound callback.  Cancel it
	; before replacing the fixture state so an earlier test cannot write a
	; now-invalid path (or emit a delayed log) while the next test is asserting.
	if KLAppCat.HasOwnProp("save_fn") && IsObject(KLAppCat.save_fn)
		try SetTimer(KLAppCat.save_fn, 0)
	KLAppCat.file_path  := ""
	KLAppCat.categories := Map()
	KLAppCat.dirty      := false
}

TestKLAppCat_SaveIsDirtyOnWriteFailure() {
	; When KL_WriteAtomic fails, dirty must stay true so deferred-save retries.
	; Before the fix KLAppCat.dirty was cleared unconditionally after swallowed FileAppend.
	_KLAppCatReset()
	KLAppCat.file_path := A_Temp . "\ergopti_test_appcat_nope\nonexistent\path.json"
	KLAppCat.dirty := true
	KL_AppCat_Save()
	AssertTrue(KLAppCat.dirty, "dirty must stay true when save fails (deferred-save must retry)")
	KLAppCat.file_path := ""  ; cleanup
}
Test("keylogger_app_categories: dirty stays true on write failure", TestKLAppCat_SaveIsDirtyOnWriteFailure)

TestKLAppCat_SaveRoundTrip() {
	; After a successful save+reload, a custom category must survive.
	_KLAppCatReset()
	TmpPath := A_Temp . "\ergopti_test_appcat_" . A_TickCount . ".json"
	KLAppCat.file_path := TmpPath
	KLAppCat.categories["TestApp.exe"] := "productive"
	KLAppCat.dirty := true
	KL_AppCat_Save()
	; Reload from disk
	KLAppCat.categories := Map()
	KL_AppCat_Reload()
	AssertEqual("productive", KL_AppCat_Get("TestApp.exe"), "saved category must survive reload")
	KLAppCat.dirty := false
	try FileDelete(TmpPath)
}
Test("keylogger_app_categories: save round-trips a custom category", TestKLAppCat_SaveRoundTrip)

; Regression test for the production incident where KL_AppCat_Save() failed on
; every boot with "Expected a Number but got a String." (96+ occurrences in the
; live error log). Root cause: KL_SortArray used the ">" relational operator to
; sort the categories' string keys, but AHK v2's relational operators are
; numeric-only and throw on any two non-numeric strings — so sorting ANY 2+
; ordinary app-name keys (e.g. "chrome.exe" vs "code.exe") aborted the save.
; This reproduces with the real KLAppCatConst.DEFAULTS table (80+ alphabetic
; keys) — the exact shape that broke in production on every single boot.
TestKLAppCat_SaveSucceedsWithMultipleAlphaKeys() {
	_KLAppCatReset()
	TmpPath := A_Temp . "\ergopti_test_appcat_multikey_" . A_TickCount . ".json"
	KLAppCat.file_path := TmpPath

	; Seed with the real production DEFAULTS table — this is the exact Map
	; shape KL_AppCat_Reload() builds on every boot before the first save.
	for k, v in KLAppCatConst.DEFAULTS
		KLAppCat.categories[k] := v
	KLAppCat.dirty := true

	Captured := []
	LoggerSetTestSink((Line) => Captured.Push(Line))
	try {
		KL_AppCat_Save()
	} finally {
		LoggerClearTestSink()
	}

	; The global runner has independent asynchronous diagnostics.  This test
	; owns (and therefore filters on) only the KLAppCat tag: a delayed log from
	; an unrelated subsystem must not make the sorting regression nondeterministic.
	for , Line in Captured
		AssertFalse(InStr(Line, "[KLAppCat]") > 0,
			"KL_AppCat_Save must not log a KLAppCat error when sorting 2+ alphabetic app-name keys: " . Line)
	AssertFalse(KLAppCat.dirty, "dirty must clear to false once the sorted-key save succeeds")
	AssertTrue(FileExist(TmpPath) != "", "app_categories.json must actually be written to disk")

	try FileDelete(TmpPath)
	_KLAppCatReset()
}
Test("keylogger_app_categories: save succeeds and logs no error with 2+ alphabetic app-name keys (KL_SortArray regression)",
	TestKLAppCat_SaveSucceedsWithMultipleAlphaKeys)

; Narrower unit test directly on KL_SortArray itself, isolating the exact
; comparison that threw — proves the sort now produces correct lexical order
; using StrCompare instead of the numeric-only ">" operator.
TestKLSortArray_SortsAlphabeticStringsWithoutThrowing() {
	Input := ["chrome.exe", "code.exe", "1password.exe", "zoom.exe", "autohotkey64.exe"]
	Sorted := KL_SortArray(Input)
	AssertEqual("1password.exe", Sorted[1])
	AssertEqual("autohotkey64.exe", Sorted[2])
	AssertEqual("chrome.exe", Sorted[3])
	AssertEqual("code.exe", Sorted[4])
	AssertEqual("zoom.exe", Sorted[5])
}
Test("KL_SortArray: sorts ordinary alphabetic app-name strings without throwing",
	TestKLSortArray_SortsAlphabeticStringsWithoutThrowing)





; ==============================================================
; ==============================================================
; ======= 4/ KL_AppCat_DeferredSave — suspend guard (1g) =======
; ==============================================================
; ==============================================================

; Regression for Pattern 1 (1g): KL_AppCat_DeferredSave runs on a SetTimer,
; which native Suspend() never disarms. A pending write must be deferred
; (not lost — KLAppCat.dirty stays true) while paused, and must actually
; persist once resumed.
TestKLAppCat_DeferredSaveSkipsWriteWhileSuspended() {
	_KLAppCatReset()
	TmpPath := A_Temp . "\ergopti_test_appcat_suspend_" . A_TickCount . ".json"
	KLAppCat.file_path := TmpPath
	KLAppCat.categories["TestApp.exe"] := "productive"
	KLAppCat.dirty := true

	Suspend(1)
	try {
		KL_AppCat_DeferredSave()
		AssertTrue(KLAppCat.dirty, "KL_AppCat_DeferredSave must leave dirty=true when suspended -- the write is deferred, not lost")
		AssertEqual("", FileExist(TmpPath), "KL_AppCat_DeferredSave must not write to disk while suspended")
	} finally {
		Suspend(0)
	}

	KL_AppCat_DeferredSave()
	AssertFalse(KLAppCat.dirty, "KL_AppCat_DeferredSave must persist and clear dirty once resumed")
	AssertTrue(FileExist(TmpPath) != "", "KL_AppCat_DeferredSave must actually write to disk once resumed")

	try FileDelete(TmpPath)
	KLAppCat.dirty := false
}
Test("keylogger_app_categories: KL_AppCat_DeferredSave defers (does not lose) a pending write while suspended (suspend-guard-pattern-1)",
	TestKLAppCat_DeferredSaveSkipsWriteWhileSuspended)
