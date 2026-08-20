; tests/meta/test_updater_onjson_callback_catch.ahk

; ==============================================================================
; MODULE: Updater Async OnJson Callback Catch Meta Test
; DESCRIPTION:
; Regression guard for finding F28 plus AHK-31 terminal ownership. Every async
; callback flows through one dispatcher that logs exceptions and holds terminal
; quiescence until callback return. Four independent try/catch copies could
; drift and would leave deferred Reload unable to prove that no callback frame
; can still re-enter updater state.
;
; SCOPE: source introspection of modules/updater/core.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; =============================================================
; =============================================================
; ======= 1/ Every terminal uses the owned dispatcher ========
; =============================================================
; =============================================================

; One entry per function that dispatches OnJson(...). Each is checked
; independently since _DriverFuncBody resolves function bodies by name.
_UOCC_Functions() {
	return [
		"_Updater_FetchLatestJsonAsync",
		"_Updater_PollAsync",
		"_Updater_FetchReleasesListJsonAsync",
		"_Updater_PollReleasesListAsync",
		"_Updater_DeliverAsyncCancellationRecord",
		"_Updater_FailOwnedAsyncDispatch"
	]
}

for _UOCC_FnName in _UOCC_Functions() {
	(Name => Test(
		"updater: " . Name . " routes OnJson through terminal ownership (updater-onjson-swallowed-exception) (updater-channel-replacement-transaction)",
		() => _UOCC_CheckOnJsonUsesDispatcher(Name)
	))(_UOCC_FnName)
}

_UOCC_CheckOnJsonUsesDispatcher(FnName) {
	Body := _DriverFuncBody(FnName)
	Assert(Body != "", FnName . " must exist in modules/updater/core.ahk")
	Assert(InStr(Body, "_Updater_InvokeAsyncOnJson(") > 0,
		FnName . " must route every terminal through the shared owned dispatcher")
	Assert(InStr(Body, "try OnJson(") == 0,
		FnName . " must not reintroduce a local callback path that bypasses terminal ownership")
}

_UOCC_DispatcherLogsAndReleasesTerminal() {
	Body := _DriverFuncBodyOrEmpty("_Updater_InvokeAsyncOnJson")
	Assert(Body != "", "the shared async terminal dispatcher must exist")
	CallAt := InStr(Body, "OnJson.Call(")
	CatchAt := InStr(Body, "catch as Err", , CallAt)
	LogAt := InStr(Body, "LoggerError(", , CatchAt)
	FinallyAt := InStr(Body, "finally", , LogAt)
	EndRecordAt := InStr(Body, "_Updater_EndAsyncTerminalRecord(", , FinallyAt)
	EndDeliveryAt := InStr(Body, "_Updater_EndAsyncTerminalDelivery()", , FinallyAt)
	Assert(CallAt > 0 and CatchAt > CallAt and LogAt > CatchAt
		and FinallyAt > LogAt and EndRecordAt > FinallyAt
		and EndDeliveryAt > FinallyAt,
		"the dispatcher must catch/log callback errors and release either exact-record or standalone terminal ownership from finally")
}
Test("updater AHK-31: shared OnJson dispatcher logs and releases terminal ownership (updater-channel-replacement-transaction)",
	_UOCC_DispatcherLogsAndReleasesTerminal)

_UOCC_CountOccurrences(Haystack, Needle) {
	Count := 0
	Pos := 1
	while Pos := InStr(Haystack, Needle, , Pos) {
		Count += 1
		Pos += StrLen(Needle)
	}
	return Count
}

_UOCC_DispatcherIsTheOnlyRawCallbackSite() {
	SplitPath(A_ScriptDir, , &Root)
	Core := FileRead(StrReplace(Root, "\", "/")
		. "/modules/updater/core.ahk")
	AssertEqual(1, _UOCC_CountOccurrences(Core, "OnJson.Call("),
		"the shared dispatcher must be the sole raw OnJson.Call site in updater core")
	Assert(InStr(Core, '["on_json"](') == 0
		and InStr(Core, '["on_json"].Call(') == 0,
		"no map-owned terminal callback may bypass the shared dispatcher")
}
Test("updater AHK-31: dispatcher is the sole raw OnJson callback site (updater-channel-replacement-transaction)",
	_UOCC_DispatcherIsTheOnlyRawCallbackSite)
