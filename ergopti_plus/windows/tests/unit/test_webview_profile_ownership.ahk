; tests/unit/test_webview_profile_ownership.ahk

; ==============================================================================
; MODULE: WebView Profile Ownership Tests
; DESCRIPTION: Active profiles survive sweeping; exact exit receipts permit cleanup.
; ==============================================================================

#Requires AutoHotkey v2.0

class _WPO_Environment {
	BrowserProcessExited(Callback) {
		this.Callback := Callback
		return { retained: true }
	}
}

_WPO_Lifecycle() {
	global _WebView_ProfileOwners
	Prefix := "ergopti_profile_test_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . "_"
	Path := WebView_NewProfilePath(Prefix)
	Other := WebView_NewProfilePath(Prefix)
	Environment := _WPO_Environment()
	try {
		AssertFalse(Path = Other, "same-tick launches must have distinct profile identities")
		DirCreate(Path)
		FileAppend("active synthetic state", Path . "\state.txt", "UTF-8-RAW")
		WebView_WatchProfile(Path, { BrowserProcessId: 123, Environment: Environment })
		Owner := _WebView_ProfileOwners[Path]
		WebView_SweepStaleProfiles(Prefix)
		AssertTrue(FileExist(Path . "\state.txt"), "a matching prefix cannot authorize deletion")
		AssertTrue(WebView_RetireProfile(Path))
		AssertFalse(Owner["queued"], "closing a controller does not prove browser exit")
		Environment.Callback.Call(Environment, { BrowserProcessId: 124 })
		AssertFalse(Owner["exited"], "an unrelated browser cannot retire this profile")
		Environment.Callback.Call(Environment, { BrowserProcessId: 123 })
		AssertTrue(Owner["queued"])
		AssertTrue(DirExist(Path), "COM callback must defer filesystem cleanup")
		_WPO_WaitRemoved(Path)
		AssertFalse(_WebView_ProfileOwners.Has(Path))
		AssertFalse(FileExist(Path . ".retired"))
	} finally {
		_WPO_Cleanup(Path)
		_WPO_Cleanup(Other)
	}
}

_WPO_ExitBeforeClose() {
	global _WebView_ProfileOwners
	Path := WebView_NewProfilePath("ergopti_profile_test_")
	Environment := _WPO_Environment()
	try {
		DirCreate(Path)
		WebView_WatchProfile(Path, { BrowserProcessId: 123, Environment: Environment })
		Environment.Callback.Call(Environment, { BrowserProcessId: 123 })
		AssertFalse(_WebView_ProfileOwners[Path]["queued"], "exit must not erase a published window's profile")
		WebView_RetireProfile(Path)
		_WPO_WaitRemoved(Path)
	} finally
		_WPO_Cleanup(Path)
}

_WPO_ReceiptRecovery() {
	global _WebView_ProfileOwners
	Prefix := "ergopti_profile_test_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . "_"
	Path := WebView_NewProfilePath(Prefix)
	Unknown := WebView_NewProfilePath(Prefix)
	Lock := 0
	try {
		DirCreate(Path)
		DirCreate(Unknown)
		FileAppend("owned", Path . "\state.txt", "UTF-8-RAW")
		FileAppend("invalid", Unknown . ".retired", "UTF-8-RAW")
		_WebView_ProfileOwners.Delete(Unknown)
		Lock := FileOpen(Path . "\state.txt", "r-d")
		AssertTrue(IsObject(Lock))
		WebView_ConfirmProfileExit(Path)
		Owner := _WebView_ProfileOwners[Path]
		; Drive the last retry while a real native handle still refuses deletion.
		Owner["attempts"] := 3
		_WebView_CleanupProfile(Owner)
		AssertTrue(FileExist(Path . ".retired"), "failed cleanup must preserve its exit receipt")
		AssertFalse(_WebView_ProfileOwners.Has(Path), "bounded retries must release in-memory ownership")
		Lock.Close()
		Lock := 0
		WebView_SweepStaleProfiles(Prefix)
		AssertFalse(DirExist(Path), "a later sweep must recover the confirmed retired profile")
		AssertTrue(DirExist(Unknown), "an invalid receipt must never authorize deletion")
	} finally {
		if IsObject(Lock)
			Lock.Close()
		_WPO_Cleanup(Path)
		_WPO_Cleanup(Unknown)
	}
}

_WPO_WaitRemoved(Path) {
	Deadline := A_TickCount + 5000
	while DirExist(Path) && A_TickCount < Deadline
		Sleep(10)
	AssertFalse(DirExist(Path), "confirmed retired profile must be removed")
}

_WPO_AbandonUnknown() {
	global _WebView_ProfileOwners
	Prefix := "ergopti_profile_test_" . DllCall("GetCurrentProcessId") . "_" . A_TickCount . "_"
	Path := WebView_NewProfilePath(Prefix)
	try {
		DirCreate(Path)
		FileAppend("unconfirmed", Path . "\state.txt", "UTF-8-RAW")
		AssertTrue(WebView_AbandonProfile(Path))
		AssertFalse(_WebView_ProfileOwners.Has(Path), "failed initialization must release bookkeeping")
		WebView_SweepStaleProfiles(Prefix)
		AssertTrue(FileExist(Path . "\state.txt"), "unknown native launch state must preserve the profile")
		AssertFalse(FileExist(Path . ".retired"), "failure is not a termination receipt")
	} finally
		_WPO_Cleanup(Path)
}

_WPO_ConfirmedAbandon() {
	global _WebView_ProfileOwners
	Path := WebView_NewProfilePath("ergopti_profile_test_")
	try {
		DirCreate(Path)
		PreviousCritical := Critical("On")
		try {
			AssertTrue(WebView_ConfirmProfileExit(Path))
			AssertTrue(WebView_AbandonProfile(Path))
			AssertTrue(_WebView_ProfileOwners.Has(Path), "late abandon must retain confirmed cleanup ownership")
		} finally
			Critical(PreviousCritical)
		_WPO_WaitRemoved(Path)
	} finally
		_WPO_Cleanup(Path)
}

_WPO_StaleEdgeTerminal() {
	global _WebView_ProfileOwners
	Path := WebView_NewProfilePath("ergopti_profile_test_")
	CurrentPath := WebView_NewProfilePath("ergopti_profile_test_")
	Previous := _KLUI_GetEdgeOwner("typing")
	Old := Map("profile", Path)
	Current := Map("profile", CurrentPath)
	try {
		DirCreate(Path)
		DirCreate(CurrentPath)
		_KLUI_SetEdgeOwner("typing", Current)
		_KLUI_OnEdgeTerminal("typing", Old, 0, "", "")
		_WPO_WaitRemoved(Path)
		AssertTrue(_KLUI_GetEdgeOwner("typing") == Current, "old termination must not retire the new Edge owner")
		AssertTrue(DirExist(CurrentPath), "old termination must not remove the new profile")
		AssertFalse(_WebView_ProfileOwners[CurrentPath]["exited"])
	} finally {
		_KLUI_SetEdgeOwner("typing", Previous)
		_WPO_Cleanup(Path)
		_WPO_Cleanup(CurrentPath)
	}
}

_WPO_Cleanup(Path) {
	global _WebView_ProfileOwners
	if _WebView_ProfileOwners.Has(Path)
		_WebView_ProfileOwners.Delete(Path)
	if FileExist(Path . "\state.txt")
		FileDelete(Path . "\state.txt")
	if DirExist(Path)
		DirDelete(Path)
	if FileExist(Path . ".retired")
		FileDelete(Path . ".retired")
}

Test("WebView profile: active and stale browser ownership (profile-ownership)", _WPO_Lifecycle)
Test("WebView profile: browser exit can precede controller close (profile-ownership)", _WPO_ExitBeforeClose)
Test("WebView profile: native refusal retains only valid exit receipts (profile-ownership)", _WPO_ReceiptRecovery)
Test("WebView profile: unknown initialization failure preserves files (profile-ownership)", _WPO_AbandonUnknown)
Test("WebView profile: stale Edge termination retires only its own files (profile-ownership)", _WPO_StaleEdgeTerminal)
Test("WebView profile: late abandon preserves confirmed cleanup (profile-ownership)", _WPO_ConfirmedAbandon)
