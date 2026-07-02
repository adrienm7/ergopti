; tests/meta/test_updater_onjson_callback_catch.ahk

; ==============================================================================
; MODULE: Updater Async OnJson Callback Catch Meta Test
; DESCRIPTION:
; Regression guard for finding F28: four "try OnJson(...)" call sites in
; lib/updater/core.ahk had no catch clause. AHK v2 does not route an uncaught
; exception from inside a try block to the registered global OnError handler
; when the try itself has no catch -- an exception thrown while building the
; changelog GUI from inside an OnJson callback was therefore completely
; invisible, with zero trace in the logs.
;
; SCOPE: source introspection of lib/updater/core.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; =============================================================
; ======= 1/ Every OnJson call site has a logging catch =======
; =============================================================
; ============================================================

; One entry per function that dispatches OnJson(...). Each is checked
; independently since _DriverFuncBody resolves function bodies by name.
_UOCC_Functions() {
	return [
		"_Updater_FetchLatestJsonAsync",
		"_Updater_PollAsync",
		"_Updater_FetchReleasesListJsonAsync",
		"_Updater_PollReleasesListAsync"
	]
}

for _UOCC_FnName in _UOCC_Functions() {
	(Name => Test(
		"updater: " . Name . "'s OnJson(...) call is followed by a logging catch (updater-onjson-swallowed-exception)",
		() => _UOCC_CheckOnJsonHasCatch(Name)
	))(_UOCC_FnName)
}

_UOCC_CheckOnJsonHasCatch(FnName) {
	Body := _DriverFuncBody(FnName)
	Assert(Body != "", FnName . " must exist in lib/updater/core.ahk")

	TryPos := InStr(Body, "try OnJson(")
	Assert(TryPos > 0, FnName . " must still call OnJson(...) via a try")

	CatchPos := InStr(Body, "catch", , TryPos)
	Assert(CatchPos > 0 and CatchPos < TryPos + 40,
		FnName . "'s try OnJson(...) must be immediately followed by a catch clause -- a bare try with no catch means an exception thrown while building the changelog GUI is completely invisible (updater-onjson-swallowed-exception)")

	CatchBody := SubStr(Body, CatchPos, 200)
	Assert(InStr(CatchBody, "Logger") > 0,
		FnName . "'s catch around OnJson(...) must log the failure so it is diagnosable instead of silently invisible (updater-onjson-swallowed-exception)")
}
