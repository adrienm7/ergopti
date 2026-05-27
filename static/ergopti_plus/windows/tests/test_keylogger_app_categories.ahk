; static/ergopti_plus/windows/tests/test_keylogger_app_categories.ahk

; ==============================================================================
; MODULE: Keylogger App Categories Tests
; DESCRIPTION:
; Unit-tests for the pure lookup/classification logic in
; modules/keylogger/keylogger_app_categories.ahk.
; Tests exercise KL_AppCat_Get against a seeded in-memory Map and validate
; that KLAppCatConst.DEFAULTS contains the expected category assignments.
; File I/O and the deferred-save timer are not exercised here.
; ==============================================================================





; ==================================================
; ==================================================
; ======= 1/ DEFAULTS vocabulary check ============
; ==================================================
; ==================================================

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





; =============================================
; =============================================
; ======= 2/ KL_AppCat_Get — lookup ==========
; =============================================
; =============================================

; Seed a clean in-memory map before each test group so tests are isolated.
_KLAppCat_SeedMap() {
	; Set file_path to a non-empty sentinel so KL_AppCat_RequireInit passes
	KLAppCat.file_path := "stub"
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
