; tests/fixtures/context_tail_retry_owner_body.ahk
; Real capture, central append, native Suspend refusal, and independently acknowledged tail retry.
#Requires AutoHotkey v2.0

_KCTR_Append(Entry, &Rejected := false, Guard := unset, Commit := unset, Frozen := unset, Refuse := unset) {
	global _KCTR
	if _KCTR.RefuseTitle && Entry["type"] == "window_switch" {
		_KCTR.RefuseTitle := false
		_KCTR.Refusals += 1
		Suspend(true)
	}
	return KL_AppendLog(Entry, &Rejected, Guard?, Commit?, Frozen?, Refuse?)
}

KL_LogWindowSwitch(Values*) {
	global _KCTR
	if _KCTR.BlockNormalTitle && !KLHook.capture_stopping {
		_KCTR.BlockNormalTitle := false
		Suspend(true)
	}
	return _KCTR_ObservedLogWindowSwitch(Values*)
}

_KCTR_Count(Type) {
	Count := 0
	for Entry in Keystats._pending_entries
		if Entry["type"] == Type
			Count += 1
	return Count
}

_KCTR_Main() {
	global _KSD, _KCTR
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	A := {App: "fixture-tail-retry-a.exe", Title: "Fixture tail retry A", Hwnd: 1701}
	_KSD_Acquire(A)
	_KSD_Require(KL_Hook_RefreshContext(true), "The actual canonical source must create its own native clock.")
	Origin := KLHook.app_entered_at
	Sleep(40)
	if A_Args[1] == "transition-retry" {
		B := {App: "fixture-tail-retry-b.exe", Title: "Fixture tail retry B", Hwnd: 1702}
		_KCTR.BlockNormalTitle := true
		_KSD_Acquire(B)
		_KSD_Require(!KL_Hook_RefreshContext(true) && A_IsSuspended,
			"Only the actual paused central title append may retain the already accepted normal app transition.")
		_KSD_Require(!KL_Hook_Stop() && IsObject(KLHook.context_stop) && !IsObject(KLHook.context_stop.Tail)
			&& IsObject(KLHook.context_transition), "The real first Stop must retain its endpoint while the normal transition still needs its title ACK.")
		Stop := KLHook.context_stop
		AppOrigin := KLHook.app_entered_at, TitleOrigin := KLHook.title_entered_at
		Sleep(40)
		; Exercise the real shared compensation owner with actual native elapsed
		; time. This is its endpoint contract, not a claim of a measured OS race.
		KL_Hook_AdvanceContextWatermarks(TickElapsed64(Stop.EndTick))
		_KSD_Require(KLHook.app_entered_at == AppOrigin && KLHook.title_entered_at == TitleOrigin
			&& KLHook.context_transition.Title.Shift == 0,
			"No later compensation may move either origin past the already frozen first Stop endpoint.")
		Suspend(false)
		_KSD_Require(KL_Hook_Stop(), "The resumed actual append must drain both the earlier transition and its fixed-end tail.")
		AppMs := 0, TitleMs := 0
		for Entry in Keystats._pending_entries {
			if Entry["type"] == "app_switch"
				AppMs += Entry["duration_ms"]
			if Entry["type"] == "window_switch"
				TitleMs += Entry["duration_ms"]
			FileAppend("ROW " . KL_JsonEncode(Entry) . "`n", "*", "UTF-8")
		}
		Bound := TickElapsed64(Origin, Stop.EndTick)
		_KSD_Require(_KCTR_Count("app_switch") == 2 && _KCTR_Count("window_switch") == 2
			&& AppMs == Bound && TitleMs == Bound,
			"The real canonical rows may cover only the source through the first Stop, never the retry waiting time or a wrapped duration.")
	} else if A_Args[1] == "privacy-terminal" {
		MetricsFilters.disabled_apps := Map(A.App, true)
		_KSD_Require(MF_ShouldFilter(), "The actual app exclusion predicate must reject the owned focus.")
		_KSD_Require(KL_Hook_Stop(), "An actual privacy refusal is a terminal consumed interval, not retry debt.")
		_KSD_Require(_KCTR_Count("app_switch") == 0 && _KCTR_Count("window_switch") == 0,
			"Private terminal content must never enter the actual pending queue.")
		MetricsFilters.disabled_apps := Map()
		_KSD_Acquire(A)
		_KSD_Require(!MF_ShouldFilter(), "The fresh canonical focus must now be public.")
		_KSD_Require(KL_Hook_Stop(), "A later public Stop must not resurrect a privacy-consumed interval.")
		_KSD_Require(Keystats._pending_entries.Length == 0 && !IsObject(KLHook.context_stop),
			"The terminal privacy refusal must remain consumed after the settings/focus change.")
	} else {
		_KCTR.RefuseTitle := A_Args[1] == "partial-retry"
		First := KL_Hook_Stop(_KCTR_Append)
		if A_Args[1] == "partial-retry" {
			_KSD_Require(!First && A_IsSuspended && _KCTR.Refusals == 1,
				"Only a native pause before the actual second central append may create this retry debt.")
			_KSD_Require(_KCTR_Count("app_switch") == 1 && _KCTR_Count("window_switch") == 0
				&& IsObject(KLHook.context_stop), "The accepted app clock must survive the rejected title append independently.")
			EndTick := KLHook.context_stop.EndTick
			EndMs := TickElapsed64(Origin, EndTick)
			Sleep(40)
			Suspend(false)
			_KSD_Require(KL_Hook_Stop(_KCTR_Append), "The genuine resumed append must close the retained title exactly once.")
			_KSD_Require(!IsObject(KLHook.context_stop), "A complete retry must retire its exact close debt.")
		} else {
			_KSD_Require(First, "The ordinary actual central append must close both public clocks.")
			EndMs := Keystats._pending_entries[1]["duration_ms"]
		}
		_KSD_Require(_KCTR_Count("app_switch") == 1 && _KCTR_Count("window_switch") == 1,
			"Both independently acknowledged clocks must persist exactly once.")
		for Entry in Keystats._pending_entries {
			_KSD_Require(Entry["duration_ms"] == EndMs && EndMs >= 30,
				"A delayed retry must retain the first Stop endpoint rather than charge its waiting time.")
			FileAppend("ROW " . KL_JsonEncode(Entry) . "`n", "*", "UTF-8")
		}
		_KSD_Require(KL_Hook_Stop(_KCTR_Append) && _KCTR_Count("app_switch") == 1 && _KCTR_Count("window_switch") == 1,
			"A completed repeated stop cannot append either interval again.")
	}
	_KSD_Require(_KSD.Errors == 0 && !IsObject(_KSD.Failure), "No swallowed dependency error may qualify a clock close.")
	FileAppend("RECEIPT context-tail-retry mode=" . A_Args[1] . " app_rows=" . _KCTR_Count("app_switch")
		. " title_rows=" . _KCTR_Count("window_switch") . " refusals=" . _KCTR.Refusals . " errors=" . _KSD.Errors . "`n", "*", "UTF-8")
}

if A_Args.Length != 2 || !(A_Args[1] == "complete-control" || A_Args[1] == "partial-retry" || A_Args[1] == "privacy-terminal" || A_Args[1] == "transition-retry")
	throw Error("The context tail child requires an exact mode and owned directory.")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
global _KCTR := {RefuseTitle: false, Refusals: 0, BlockNormalTitle: false}
try {
	_KCTR_Main()
	FileAppend("PASS context-tail-retry " . A_Args[1] . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as _KCTR_EntryFailure {
	FileAppend("FAIL context-tail-retry " . _KCTR_EntryFailure.Message . " [" . _KCTR_EntryFailure.File . ":" . _KCTR_EntryFailure.Line . "]`n", "*", "UTF-8")
	ExitApp(1)
} finally {
	Suspend(false)
	Keystats.initialized := false
}
