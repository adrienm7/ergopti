; tests/meta/test_updater_manual_check_uses_dialog.ahk

; ==============================================================================
; MODULE: The manual update check answers in the update-check window
; DESCRIPTION:
; "Check for updates" answered "up to date", "no connection" and "cannot read
; the release" with tray balloons, and a newer release with the install
; prompt. Every answer now goes to the update-check window (ui/update_check):
; 1. the check opens the window ("checking") before it dispatches the request;
; 2. its callback shows no balloon and routes each answer to the window, and a
;    check cancelled without an answer closes the window it opened;
; 3. a newer release is offered in the window, whose Update button is the only
;    new consent point, through the existing install;
; 4. the list's other channels are kept for the window before the checked
;    channel's release is selected out of it;
; 5. a WebView2 that cannot be created leaves the check in the native window.
; ==============================================================================

#Requires AutoHotkey v2.0

_TUCM_CheckOpensTheWindowFirst() {
	Body := _DriverFuncBody("Updater_OneClickUpdate")
	BeginAt := InStr(Body, "UpdateCheck_Begin(Request, Current)")
	FetchAt := InStr(Body, "_Updater_FetchLatestJsonAsync(")
	Assert(BeginAt > 0 and FetchAt > BeginAt,
		"the manual check must show 'checking' before it dispatches the request")
}
Test("update check window: the manual check opens the window before its request (update-check-window)",
	_TUCM_CheckOpensTheWindowFirst)

_TUCM_CallbackAnswersInTheWindow() {
	Body := _DriverFuncBody("_Updater_OneClickUpdateCallback")
	AssertEqual(0, InStr(Body, "TrayTip("), "no balloon on the manual path")
	AssertEqual(0, InStr(Body, "NotifierSend("), "no notification on the manual path")
	Count := 0
	Position := 1
	while (Position := InStr(Body, "UpdateCheck_ShowResult(Request, Map(", , Position)) {
		Count += 1
		Position += 10
	}
	AssertEqual(4, Count, "no connection, no release, unreadable release and up to date answer in the window")
	for Phase in ['"state", "error"', '"state", "no_release"', '"state", "up_to_date"']
		Assert(InStr(Body, Phase) > 0, "the callback answers " . Phase)
	Assert(InStr(Body, '"reason", "no_connection"') > 0 and InStr(Body, '"reason", "parse_failed"') > 0,
		"each failure names its reason")
	Assert(InStr(Body, "UpdateCheck_Abandon(Request)") > 0,
		"a check cancelled without an answer closes its window")
	Publish := _DriverFuncBody("_Updater_PublishOneClickRelease")
	Assert(InStr(Publish, "UpdateCheck_ShowAvailable(Release, Request)") > 0,
		"a newer release is offered in the window")
}
Test("update check window: every manual answer goes to the window, none to a balloon (update-check-window)",
	_TUCM_CallbackAnswersInTheWindow)

_TUCM_UpdateUsesTheExistingInstall() {
	Install := _DriverFuncBody("_UpdateCheck_Install")
	Assert(InStr(Install, "_Updater_ActivateCachedRelease(Release, Request)") > 0,
		"the window's Update runs the existing install of the offered release")
	AssertEqual(0, InStr(Install, "Updater_DownloadAndInstall("),
		"the window starts no download of its own")
	Perform := _DriverFuncBody("UpdateCheck_Perform")
	Assert(InStr(Perform, '"update", "available"') == 0, "the phase table lives in UC_PAGE_ACTIONS")
	Assert(InStr(Perform, "UC_PAGE_ACTIONS[Name]") > 0, "every action is checked against the phase it needs")
}
Test("update check window: Update runs the existing install (update-check-window)",
	_TUCM_UpdateUsesTheExistingInstall)

_TUCM_OtherChannelsKeptBeforeSelection() {
	Body := _DriverFuncBody("_Updater_InterpretResponse")
	RecordAt := InStr(Body, "_Updater_RecordOtherChannels(Request, Json, Channel)")
	SelectAt := InStr(Body, "_Updater_SelectChannelRelease(Json, Channel)")
	Assert(RecordAt > 0 and SelectAt > RecordAt,
		"the other channels are read from the whole list before the checked channel's release is selected")
	Record := _DriverFuncBody("_Updater_RecordOtherChannels")
	Assert(InStr(Record, "UpdateChannels_NewerElsewhere(") > 0,
		"the shared rule (channel_vectors.json) decides which channels are newer")
}
Test("update check window: the other channels come from the whole release list (update-check-window)",
	_TUCM_OtherChannelsKeptBeforeSelection)

; Closing the window on a WebView2 failure dropped the check, so its answer was
; discarded and the click showed nothing: the failure opens the native window.
_TUCM_WebViewFailureFallsBackToNative() {
	Body := _DriverFuncBody("_UpdateCheck_Open")
	CatchAt := InStr(Body, "catch as Err")
	Assert(CatchAt > 0, "_UpdateCheck_Open must catch a WebView2 creation failure")
	Tail := SubStr(Body, CatchAt)
	Assert(InStr(Tail, "_UpdateCheck_FallBackToNative(Epoch, G)") > 0,
		"a WebView2 creation failure must fall back to the native window")
	AssertEqual(0, InStr(Tail, "_UpdateCheck_CloseWindow("),
		"a WebView2 creation failure must not close the window and drop the check")
}
Test("update check window: a WebView2 failure keeps the check in a native window (update-check-window)",
	_TUCM_WebViewFailureFallsBackToNative)
