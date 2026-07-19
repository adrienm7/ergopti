; tests/meta/test_menu_dispatch_epoch.ahk
#Requires AutoHotkey v2.0

Test_MenuDispatcher_StaleRetryRequiresRegistrationIdentity() {
	Source := FileRead(A_ScriptDir . "\..\lib\menu_dispatcher.ahk", "UTF-8")
	CommandBody := _DriverFuncBody("_OnMenuCommandWmCommand")
	RetryBody := _DriverFuncBody("_DispatchIfMissed")
	TrackedBody := _DriverFuncBody("_TrackedDispatch")
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
	Assert(InStr(TrackedBody, "TrackedObj.Epoch = _MenuDispatcherEpoch") > 0,
		"a stale native callback must not mutate a newer registration")
}
Test("menu dispatcher: stale retry cannot cross a rebuild epoch", Test_MenuDispatcher_StaleRetryRequiresRegistrationIdentity)
