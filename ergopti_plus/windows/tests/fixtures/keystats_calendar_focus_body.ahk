; tests/fixtures/keystats_calendar_focus_body.ahk
; Real initializer, focus, rollover, stop, journal ingestion and SQLite readers.
; Only the two public calendar clock reads are explicit declared-boundary ports.
#Requires AutoHotkey v2.0

global _MAD := {AssetHashes: Map()}
global _KMCD := {Day: "2026-11-05", Stamp: "2026-11-05 23:59:59.000"}
OnError(_MAD_InitializationError)
_KMCD_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
_KMCD_Day(Self, *) {
	global _KMCD
	return _KMCD.Day
}
_KMCD_Stamp(Self, *) {
	global _KMCD
	return _KMCD.Stamp
}
_KMCD_Main() {
	global _MAD_Root, _KMCD
	_KMCD_Require(A_Args.Length == 2 && _MAD_Root == _MAD_ExpectedRoot
		&& (A_Args[2] == "same-day" || A_Args[2] == "midnight"), "The declared calendar mode and private store must be exact.")
	_KMCD_Require(!FSStrictExists(_MAD_Root), "Never adopt an existing store.")
	_KMCD_Require(FSCreateDirectoryExclusiveStrict(_MAD_Root) == 1, "Acquire the subject store exclusively.")
	_MAD_CopyShared()
	TimingsLoadShared()
	KeystatsWalkerLoadTimings()
	ReceiverGui := Gui(, "Ergopti owned calendar foreground receiver")
	Receiver := ReceiverGui.AddEdit("w320 r3", "owned receiver")
	TodayFn := KL_Today, StampFn := KL_NowTimestamp
	_KMCD_Require(!TodayFn.HasOwnProp("Call") && !StampFn.HasOwnProp("Call"), "Do not replace an existing clock owner.")
	TodayFn.DefineProp("Call", {Call: _KMCD_Day})
	StampFn.DefineProp("Call", {Call: _KMCD_Stamp})
	InitAttempted := false
	try {
		DirDelete(_MAD_Root . "\by_device\owned")
		_KMCD_Require(FSCreateDirectoryExclusiveStrict(_MAD_Root . "\private-temp") == 1, "Own temporary initializer output.")
		EnvSet("TMP", _MAD_Root . "\private-temp")
		EnvSet("TEMP", _MAD_Root . "\private-temp")
		InitAttempted := true
		_KMCD_Require(KL_Init(_MAD_Root), "The actual initializer must admit the exact journal/device/state store.")
		_KMCD_Require(KL_TimerGroupStop(Keystats, ["_initial_ingest_timer", "_ingest_timer", "_midnight_timer"], SetTimer, "core"), "Retire exact core timers before the declared calendar boundary.")
		KL_Mig_Cancel()
		_KMCD_Require(!KL_Mig_IsActive() && !KLMigration.syncPending, "No migration may race the private source.")
		ReceiverGui.Show()
		_KMCD_Require(WinGetPID("ahk_id " . ReceiverGui.Hwnd) == ProcessExist(), "The native receiver must belong to this exact child.")
		WinActivate("ahk_id " . ReceiverGui.Hwnd)
		_KMCD_Require(WinWaitActive("ahk_id " . ReceiverGui.Hwnd, , 2), "The owned foreground receiver must activate.")
		Receiver.Focus()
		MetricsFilters.secure_field := false
		_KMCD_Require(MF_RefreshFocus(true), "Real native focus acquisition must succeed.")
		Focus := MF_GetFocusSnapshot()
		_KMCD_Require(Focus.valid && Focus.hwnd == ReceiverGui.Hwnd, "The canonical native focus must own the receiver.")
		_KMCD_Require(KL_Hook_RefreshContext(true) && KLHook.app_entered_at > 0, "The genuine context producer must establish the interval.")
		Origin := KLHook.app_entered_at
		Sleep(50)
		if A_Args[2] == "midnight"
			_KMCD.Day := "2026-11-06", _KMCD.Stamp := "2026-11-06 00:00:00.000"
		KL_MidnightCheck()
		_KMCD_Require(Keystats.today_log_date == _KMCD.Day && !Keystats.rollover_in_progress,
			"The real maintenance path must retain or rotate its actual declared journal day.")
		BoundaryElapsed := TickElapsed64(Origin)
		Sleep(50)
		_KMCD_Require(KL_Hook_Stop(), "The real terminal producer must acknowledge both clocks.")
		Ingest := KL_IngestOnce(true, true)
		_KMCD_Require(Ingest["ok"] && Ingest["eof"], "Actual durable journal ingestion must settle, not a fabricated SQL row.")
		Db := KLR_BuildDatabase(_MAD_Root)
		_KMCD_Require(Db != 0, "The true canonical reader must reconstruct the source.")
		OldMs := SQLite_Query(Db, "SELECT COALESCE(SUM(app_time_ms),0) AS ms FROM agg_app_day WHERE date='2026-11-05'")[1]["ms"]
		NewMs := SQLite_Query(Db, "SELECT COALESCE(SUM(app_time_ms),0) AS ms FROM agg_app_day WHERE date='2026-11-06'")[1]["ms"]
		OldTitleMs := SQLite_Query(Db, "SELECT COALESCE(SUM(ms),0) AS ms FROM agg_app_day_titles WHERE date='2026-11-05'")[1]["ms"]
		NewTitleMs := SQLite_Query(Db, "SELECT COALESCE(SUM(ms),0) AS ms FROM agg_app_day_titles WHERE date='2026-11-06'")[1]["ms"]
		Switches := SQLite_Query(Db, "SELECT COUNT(*) AS n FROM events_app_switch WHERE COALESCE(next_app,'')!=''")[1]["n"]
		FileAppend("OBS calendar-focus mode=" . A_Args[2] . " boundary_elapsed=" . BoundaryElapsed
			. " old_ms=" . OldMs . " new_ms=" . NewMs . " old_title_ms=" . OldTitleMs
			. " new_title_ms=" . NewTitleMs . " actual_switches=" . Switches . "`n", "*", "UTF-8-RAW")
		_KMCD_Require(Switches == 0, "A declared calendar closure and terminal closure must not fabricate app switches.")
		_KMCD_Require(OldMs >= 40, "The public foreground before the declared boundary must remain on its actual calendar day.")
		_KMCD_Require(A_Args[2] == "midnight" ? NewMs >= 40 : NewMs == 0,
			"Only the post-boundary foreground may enter the following day.")
		_KMCD_Require(OldTitleMs >= 40 && (A_Args[2] == "midnight" ? NewTitleMs >= 40 : NewTitleMs == 0),
			"The same calendar ownership must hold for the actual outgoing window title interval.")
	} finally {
		if InitAttempted {
			_KMCD_Require(KL_TimerGroupStop(Keystats, ["_initial_ingest_timer", "_ingest_timer", "_midnight_timer"], SetTimer, "core"), "Retire initializer timers before cleanup.")
			KL_Mig_Cancel()
			_KMCD_Require(KL_CloseTodayFh(), "The actual journal handle must retire before parent cleanup.")
		}
		Keystats.initialized := false
		KLR_ResetCache()
		ReceiverGui.Destroy()
		TodayFn.DeleteProp("Call")
		StampFn.DeleteProp("Call")
	}
	FileAppend("PASS calendar-focus " . A_Args[2] . "`n", "*", "UTF-8-RAW")
}
try {
	_KMCD_Main()
	ExitApp(0)
} catch as KMCDEntryFailure {
	FileAppend("FAIL calendar-focus " . KMCDEntryFailure.Message . " line=" . KMCDEntryFailure.Line . "`n" . KMCDEntryFailure.Stack . "`n", "**", "UTF-8-RAW")
	ExitApp(1)
}
