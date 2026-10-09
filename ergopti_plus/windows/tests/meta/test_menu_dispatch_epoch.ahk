; tests/meta/test_menu_dispatch_epoch.ahk
#Requires AutoHotkey v2.0

Test_MenuDispatcher_StaleRetryRequiresRegistrationIdentity() {
	Source := FileRead(A_ScriptDir . "\..\infra\menu_dispatcher.ahk", "UTF-8")
	CommandBody := _DriverFuncBody("_OnMenuCommandWmCommand")
	Assert(InStr(CommandBody, "MenuCommandOrigin_IsMenuSelection(wParam, lParam)") > 0,
		"WM_COMMAND retry dispatch must reject controls by checking both notification code and lParam")
	RetryBody := _DriverFuncBody("_DispatchIfMissed")
	TrackedBody := _DriverFuncBody("_TrackedDispatch")
	InsertBody := _DriverFuncBody("RegisterMenuItemInsert")
	Assert(InStr(CommandBody, "_MenuDispatcherEpoch") > 0 and InStr(CommandBody, "_MenuDispatchTokens") > 0,
		"WM_COMMAND must capture the dispatcher epoch and registration token")
	Assert(InStr(CommandBody, "_DispatchIfMissed.Bind(ItemId, LastFire, _MenuDispatcherEpoch, _MenuDispatchTokens[ItemId], ClickSequence)") > 0,
		"retry timer must carry immutable registration and click identity, not ItemId alone")
	Assert(InStr(CommandBody, "_MenuDispatchClickSequences[ItemId] := ClickSequence") > 0,
		"every WM_COMMAND retry must own a monotonically advancing click sequence")
	Assert(InStr(RetryBody, "ExpectedEpoch != _MenuDispatcherEpoch") > 0,
		"stale retries from an older dispatcher epoch must no-op")
	Assert(InStr(RetryBody, "_MenuDispatchTokens[ItemId] != ExpectedToken") > 0,
		"recycled native item IDs must be rejected when their token differs")
	Assert(InStr(RetryBody, "_MenuDispatchClickSequences[ItemId] != ExpectedClickSequence") > 0,
		"an older retry must no-op after a newer click on the same native item ID")
	; The invariant is unchanged — a stale native callback must not mutate a
	; newer registration — but it is enforced by TOKEN identity, not by the
	; registration-time epoch. A replacement registration on the same native
	; ItemId writes a new token, so a stale TrackedObj cannot match.
	;
	; The epoch was removed from THIS function because it contradicted the
	; behaviour TrayMenuStage_Publish documents ("retain dispatcher entries for
	; detached child menus"): submenu items are registered before the bump, so
	; the epoch rejected their native dispatch and left every submenu click to
	; the 60 ms retry, which logged a false "AHK drop detected" each time.
	Assert(InStr(TrackedBody, "_MenuDispatchTokens[TrackedObj.ItemId] = TrackedObj.Token") > 0,
		"a stale native callback must not mutate a newer registration — the token fence is what enforces this")
	Assert(InStr(TrackedBody, "TrackedObj.Epoch = _MenuDispatcherEpoch") == 0,
		"the registration-time epoch must NOT gate native dispatch: submenu items are registered before the publish bump, so it rejects them and silently downgrades every submenu click to the retry path")
	Assert(InStr(InsertBody, "Epoch: _MenuDispatcherEpoch, Token: 0") > 0,
		"inserted menu wrappers must initialize every identity field read by _TrackedDispatch")
	Assert(InStr(InsertBody, "TrackedObj.Token := _MenuDispatchTokenCounter") > 0
		and InStr(InsertBody, "_MenuDispatchTokens[ItemId]    := TrackedObj.Token") > 0,
		"inserted menu items must publish their token before their callback can run")
}
Test("menu dispatcher: stale retry cannot cross a rebuild epoch", Test_MenuDispatcher_StaleRetryRequiresRegistrationIdentity)
