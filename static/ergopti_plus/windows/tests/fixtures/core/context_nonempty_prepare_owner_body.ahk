; tests/fixtures/core/context_nonempty_prepare_owner_body.ahk

; The real context preparation detaches a nonempty A snapshot. During its real
; privacy classification an independent native timer admits five public pointer
; distance units under canonical B, then optionally invokes the actual Stop.
; Pointer coordinates are isolated ports; this is not physical hardware input.
#Requires AutoHotkey v2.0

KLWV_NotifyIngest(*) => true
_KCNP_Position() {
	global _KCNP
	_KCNP.Samples += 1
	return {x: (_KCNP.Samples - 1) * 3, y: (_KCNP.Samples - 1) * 4}
}
; Test-only observation around the real window-switch producer; no result is
; substituted and no clock or owner is changed by this observer.
_KCNP_ObserveWindow(Values*) {
	global _KCNP
	if !IsSet(_KCNP) || _KCNP.Mode != "abc-deferred-sameapp-shift" || Values.Length < 3
		return
	if Values[2] == "Public prepare A" && Values[3] == _KCNP.B.Title
		_KCNP.BOrigin := KLHook.app_entered_at
	else if Values[2] == _KCNP.B.Title && Values[3] == _KCNP.C.Title {
		Frame := KLHook.context_transition
		_KSD_Require(IsObject(Frame) && Frame.NewTitle == _KCNP.C.Title && !Frame.App.Required,
			"The genuine promoted B-to-C frame must retain the shared app clock")
		_KCNP.SameAppPromotionSeen += 1
		_KCNP.PromotedAppOrigin := KLHook.app_entered_at
		_KCNP.PromotionObservedAt := A_TickCount
	}
}
_KCNP_Timer() {
	global _KCNP
	try {
		_KSD_Require(Keystats._flush_in_progress,
			"The original A snapshot must already be detached while its real flush is active")
		_KSD_Require(MetricsFocusCache.state.process_name == _KCNP.B.App,
			"The actual canonical privacy owner must already identify the public B input")
		if _KCNP.Mode == "external-active" || InStr(_KCNP.Mode, "abc-deferred") {
			_KCNP.RefreshReturned := KL_Hook_RefreshContext(true)
			if InStr(_KCNP.Mode, "abc-deferred")
				_KSD_Require(!_KCNP.RefreshReturned && Keystats._flush_in_progress
					&& IsObject(KLHook.context_transition),
					"The real B context frame must remain deferred behind the older active flush")
		}
		_KCNP.SessionAtInput := Keystats.session_app
		BeforeDistance := Keystats.mouse_distance
		_KSD_Require(BeforeDistance == 0 || (_KCNP.Mode == "existing-retry-stop" && BeforeDistance == 5),
			"Only the genuine preexisting A live buffer may precede this new public B sample")
		KL_Mouse_ParkTick(, _KCNP_Position)
		_KSD_Require(Keystats.mouse_distance == BeforeDistance + 5
			&& _KCNP.Samples == (InStr(_KCNP.Mode, "abc-deferred") ? 3 : _KCNP.ExpectedSamples),
			"The genuine public pointer producer must add exactly five new B units")
		if InStr(_KCNP.Mode, "abc-deferred") {
			BeforeGeneration := MetricsFocusCache.generation
			_KSD_Acquire(_KCNP.C)
			_KSD_Require(MetricsFocusCache.generation > BeforeGeneration && !MF_ShouldFilter(),
				"A third public context must be published by the real canonical focus owner")
			_KCNP.CRefreshReturned := KL_Hook_RefreshContext(true)
			_KSD_Require(!_KCNP.CRefreshReturned && Keystats._flush_in_progress
				&& IsObject(KLHook.context_transition),
				"The prior B frame must still be deferred when C input arrives")
			if _KCNP.Mode == "abc-deferred-shift" || _KCNP.Mode == "abc-deferred-sameapp-shift" {
				_KSD_Require(KLHook.context_observation_head <= KLHook.context_observations.Length,
					"The real deferred C refresh must own an observation before compensation")
				Last := KLHook.context_observations[-1]
				if _KCNP.Mode == "abc-deferred-sameapp-shift"
					Sleep(25) ; produce a nonzero observed interval, without changing the OS clock
				Now := A_TickCount
				KL_Hook_AdvanceContextWatermarks(100000, Now)
				KL_Hook_AdvanceContextWatermarks(100000, Now)
				_KSD_Require(Last.Shift == TickElapsed64(Last.EndTick, Now),
					"Repeated overlapping gap compensation must not move C into the future")
				if _KCNP.Mode == "abc-deferred-sameapp-shift" {
					_KSD_Require(Last.Shift > 0, "The shared-app promotion must exercise a nonzero bounded shift")
					_KCNP.ObservedShift := Last.Shift
				}
			}
			_KCNP.SessionAtCInput := Keystats.session_app
			BeforeC := Keystats.mouse_distance
			KL_Mouse_ParkTick(, _KCNP_Position)
			_KSD_Require(Keystats.mouse_distance == BeforeC + 5 && _KCNP.Samples == 4,
				"The real public pointer producer must add exactly five new C units")
		}
		if _KCNP.Mode == "stop-during-prepare" || _KCNP.Mode == "existing-retry-stop" || _KCNP.Mode == "abc-deferred-stop" {
			_KCNP.FirstStop := KL_Hook_Stop()
			_KSD_Require(!_KCNP.FirstStop && KLHook.capture_stopping && IsObject(KLHook.context_stop),
				"The nested real Stop must retain its close while the original nonempty flush is still active")
		}
	} catch Any as Failure {
		_KCNP.Failure := Failure
	} finally _KCNP.TimerDone := true
}
MF_ShouldFilter() {
	global _KCNP
	Result := _KCNP_ActualFilter()
	if IsSet(_KCNP) && _KCNP.Armed && Keystats._flush_in_progress {
		_KCNP.Armed := false
		_KCNP.Cutpoints += 1
		_KSD_Require(!Result, "The real privacy predicate must accept both public contexts before scheduling input")
		SetTimer(_KCNP_Timer, -1)
		Started := A_TickCount
		while !_KCNP.TimerDone && TickElapsed64(Started) < 2500
			Sleep(5)
		if IsObject(_KCNP.Failure)
			throw _KCNP.Failure
		_KSD_Require(_KCNP.TimerDone, "The independent native timer must finish before the original flush predicate returns")
	}
	return Result
}
; A controlled publication guard revokes a genuine detached attempt. It does
; not manufacture a retry row, event id or app attribution; the real rollback
; owner must return the exact snapshot and the exact pre-attempt flush clock.
_KCNP_SeedGuard() {
	global _KCNP
	if Keystats._flush_in_progress {
		_KCNP.SeedAttemptTick := Keystats.last_flush_time
		return false
	}
	return true
}
_KCNP_Main() {
	global _KSD, _KCNP
	Keystats.initialized := true
	MetricsFilters.secure_field := false
	A := {App: "fixture-prepare-a.exe", Title: "Public prepare A", Hwnd: 1801}
	_KCNP.B := {App: "fixture-prepare-b.exe", Title: "Public prepare B", Hwnd: 1802}
	_KCNP.C := {App: "fixture-prepare-c.exe", Title: "Public prepare C", Hwnd: 1803}
	if _KCNP.Mode == "abc-deferred-sameapp-shift"
		_KCNP.C.App := _KCNP.B.App
	if InStr(_KCNP.Mode, "abc-deferred")
		_KCNP.ExpectedSamples := 4
	KLAppCat.file_path := _KSD.Log . ".categories"
	for Identity in [A, _KCNP.B, _KCNP.C]
		KLAppCat.categories[Identity.App] := Map("type", "fixture-known", "score", 0)
	_KSD_Acquire(A)
	_KSD_Require(KL_Hook_RefreshContext(true), "The actual initial public A must establish its native context")
	KL_Mouse_ParkTick(, _KCNP_Position)
	KL_Mouse_ParkTick(, _KCNP_Position)
	_KSD_Require(Keystats.mouse_distance == 5 && Keystats.session_app == A.App,
		"Exactly five original units must belong to A before the transition")
	if _KCNP.Mode == "existing-retry-stop" {
		_KCNP.ExpectedSamples := 4
		_KCNP.ExpectedAUnits := 10
		_KCNP.ExpectedRows := 3
		BeforeFlushTime := Keystats.last_flush_time
		Sleep(20)
		_KSD_Require(!KL_FlushBuffer(_KCNP_SeedGuard), "The real publication guard must retain its detached A snapshot")
		_KSD_Require(Keystats._retry_snapshots.Length == 1 && Keystats.mouse_distance == 0
			&& Keystats._retry_snapshots[1].Distance == 5 && Keystats._retry_snapshots[1].App == A.App,
			"The real failed attempt must own exactly its original A payload in the native retry FIFO")
		_KSD_Require(_KCNP.SeedAttemptTick > BeforeFlushTime && Keystats.last_flush_time == BeforeFlushTime,
			"Refusing a real attempt must restore its exact earlier flush clock")
		_KCNP.SeedId := Keystats._retry_snapshots[1].EventId
		KL_Mouse_ParkTick(, _KCNP_Position)
		_KSD_Require(Keystats.mouse_distance == 5, "The preexisting retry must coexist with five real live A units")
	}
	Sleep(30)
	_KSD_Acquire(_KCNP.B)
	_KCNP.Armed := true
	_KCNP.RefreshReturned := (_KCNP.Mode == "external-active" || InStr(_KCNP.Mode, "abc-deferred"))
		? KL_FlushBuffer() : KL_Hook_RefreshContext(true)
	if IsObject(_KCNP.Failure)
		throw _KCNP.Failure
	_KSD_Require(_KCNP.Cutpoints == 1 && _KCNP.TimerDone && _KCNP.Samples == _KCNP.ExpectedSamples,
		"A real nonempty flush and its one native input/Stop cutpoint must execute")
	_KCNP.FinalStop := KL_Hook_Stop()
	_KSD_Require(_KCNP.FinalStop, "The actual final Stop or retained Stop retry must settle before attribution is sampled")
	AUnits := 0, BUnits := 0, CUnits := 0, Rows := 0, LastTypingId := 0, SeedSeen := false
	for Entry in Keystats._pending_entries {
		FileAppend("ROW " . KL_JsonEncode(Entry) . "`n", "*", "UTF-8")
		if Entry["type"] != "typing"
			continue
		Rows += 1
		_KSD_Require(Entry["_event_id"] > LastTypingId, "The actual typing FIFO must preserve reserved event-id order")
		LastTypingId := Entry["_event_id"]
		if Entry["_event_id"] == _KCNP.SeedId
			SeedSeen := Entry["app"] == A.App && Entry["mouse_distance_px"] == 5
		if Entry["app"] == A.App
			AUnits += Entry["mouse_distance_px"]
		else if _KCNP.Mode == "abc-deferred-sameapp-shift" {
			if Entry["app"] == _KCNP.B.App && Entry["title"] == _KCNP.B.Title
				BUnits += Entry["mouse_distance_px"]
			else if Entry["app"] == _KCNP.C.App && Entry["title"] == _KCNP.C.Title
				CUnits += Entry["mouse_distance_px"]
		} else if Entry["app"] == _KCNP.B.App
			BUnits += Entry["mouse_distance_px"]
		else if Entry["app"] == _KCNP.C.App
			CUnits += Entry["mouse_distance_px"]
	}
	FileAppend("OBSERVATION context-nonempty-prepare mode=" . _KCNP.Mode . " first_stop=" . _KCNP.FirstStop
		. " final_stop=" . _KCNP.FinalStop . " refresh_returned=" . _KCNP.RefreshReturned
		. " live_session_at_b_input=" . _KCNP.SessionAtInput . " live_session_at_c_input=" . _KCNP.SessionAtCInput
		. " c_refresh_returned=" . _KCNP.CRefreshReturned . " a_units=" . AUnits . " b_units=" . BUnits . " c_units=" . CUnits
		. " typing_rows=" . Rows . " samples=" . _KCNP.Samples . " seed_id=" . _KCNP.SeedId . " seed_seen=" . SeedSeen . " errors=" . _KSD.Errors . "`n", "*")
	_KSD_Require(_KSD.Errors == 0 && !IsObject(_KSD.Failure), "No dependency failure may impersonate a context transition refusal")
	if _KCNP.Mode == "abc-deferred-sameapp-shift" {
		FileAppend("OBSERVATION sameapp-shift b_origin=" . _KCNP.BOrigin . " shift=" . _KCNP.ObservedShift
			. " promoted_origin=" . _KCNP.PromotedAppOrigin . " observed_at=" . _KCNP.PromotionObservedAt
			. " promotions=" . _KCNP.SameAppPromotionSeen . "`n", "*")
		_KSD_Require(_KCNP.SameAppPromotionSeen == 1 && _KCNP.BOrigin > 0 && _KCNP.ObservedShift > 0
			&& _KCNP.PromotedAppOrigin == _KCNP.BOrigin + _KCNP.ObservedShift
			&& _KCNP.PromotedAppOrigin <= _KCNP.PromotionObservedAt,
			"The unchanged app clock must receive the bounded shift exactly once at C promotion")
	}
	if _KCNP.Mode == "existing-retry-stop"
		_KSD_Require(SeedSeen, "The original retry identity and payload must survive staging and Stop without adoption")
	if InStr(_KCNP.Mode, "abc-deferred")
		_KSD_Require(AUnits == 5 && BUnits == 5 && CUnits == 5 && Rows == 3,
			"A, B and C public samples retain their own contexts across a deferred preparation")
	else
		_KSD_Require(AUnits == _KCNP.ExpectedAUnits && BUnits == 5 && Rows == _KCNP.ExpectedRows,
			"A new public B input admitted during nonempty preparation must never be flushed under the older A context after Stop or retry")
}
if A_Args.Length != 2 || !(A_Args[1] == "ordinary-control" || A_Args[1] == "stop-during-prepare"
	|| A_Args[1] == "existing-retry-stop" || A_Args[1] == "external-active" || A_Args[1] == "abc-deferred" || A_Args[1] == "abc-deferred-stop" || A_Args[1] == "abc-deferred-shift" || A_Args[1] == "abc-deferred-sameapp-shift")
	throw Error("The private nonempty context probe requires its exact mode and owned source directory")
global _KSD := {Mode: A_Args[1], Log: A_Args[2] . "\private.log", Probes: 0, Errors: 0, LogCalls: 0, FlushCalls: 0, Failure: 0}
global _KCNP := {Mode: A_Args[1], B: 0, Armed: false, Samples: 0, Cutpoints: 0, TimerDone: false,
	FirstStop: false, FinalStop: false, RefreshReturned: false, SessionAtInput: "", Failure: 0,
	C: 0, CRefreshReturned: false, SessionAtCInput: "",
	BOrigin: 0, ObservedShift: 0, PromotedAppOrigin: 0, PromotionObservedAt: 0, SameAppPromotionSeen: 0,
	ExpectedSamples: 3, ExpectedAUnits: 5, ExpectedRows: 2, SeedId: 0, SeedAttemptTick: 0}
try {
	_KCNP_Main()
	FileAppend("PASS context-nonempty-prepare " . _KCNP.Mode . "`n", "*", "UTF-8")
	ExitApp(0)
} catch Any as KCNPEntryFailure {
	FileAppend("FAIL context-nonempty-prepare " . KCNPEntryFailure.Message . " [" . KCNPEntryFailure.File . ":" . KCNPEntryFailure.Line . "]`n", "*", "UTF-8")
	ExitApp(1)
} finally {
	SetTimer(_KCNP_Timer, 0)
	Keystats.initialized := false
}
