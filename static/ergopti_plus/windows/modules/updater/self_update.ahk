; modules/updater/self_update.ahk

; ==============================================================================
; MODULE: Updater / Self-update Download + Swap + Background
; DESCRIPTION:
; The self-update mechanism: release-asset URL parser, background polling timer, tray-notify handler, the update prompt, and the download + executable-swap install flow.
;
; Split out of modules/updater.ahk (the module split); see modules/updater.ahk for the module
; overview. Functions and globals are hoisted, so load order across the
; updater/*.ahk files is irrelevant.
; ==============================================================================





; ==============================================================
; ==============================================================
; ======= 2/ Self-update: asset parser, swap, background =======
; ==============================================================
; ==============================================================



; ====================================
; ===== 2.1) Authenticated asset parser ========
; ====================================

; Parses the release object and returns the exact repository asset URL plus the
; SHA-256 digest authenticated by GitHub's release API. Asset objects contain
; nested metadata, so a flat-object regex cannot identify their field boundary
; safely. Returns 0 on malformed, unauthenticated, foreign or unusable input.
_Updater_FindAsset(Json, AssetName, Tag) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	if !(Json is String) || !(AssetName is String) || !(Tag is String)
		return 0
	if (AssetName == "" || Tag == "")
		return 0
	try Release := JsonParse(Json)
	catch as ParseErr {
		try LoggerWarn("Updater", "Release asset lookup for '{1}' could not parse the release JSON: {2}.",
			AssetName, ParseErr.Message)
		return 0
	}
	if !(Release is Map) || !Release.Has("assets")
		return 0
	Assets := Release["assets"]
	if !(Assets is Array)
		return 0
	ExpectedUrl := "https://github.com/" . UPDATER_GH_OWNER . "/"
		. UPDATER_GH_REPO . "/releases/download/" . Tag . "/" . AssetName
	for AssetIndex, Asset in Assets {
		if !(Asset is Map)
			continue
		if !Asset.Has("name") || !Asset.Has("browser_download_url")
			continue
		Name := Asset["name"]
		Url := Asset["browser_download_url"]
		if !(Name is String) || (Name !== AssetName)
			continue
		if !(Url is String) || (Url !== ExpectedUrl) || !Asset.Has("digest")
			return 0
		DigestField := Asset["digest"]
		if !(DigestField is String)
			return 0
		if !RegExMatch(DigestField, "i)^sha256:([0-9a-f]{64})$", &Match)
			return 0
		if !Asset.Has("size") || Type(Asset["size"]) != "Integer"
			|| Asset["size"] <= 0 || Asset["size"] > 2147483647
			return 0
		; JsonParse intentionally represents true as the native integer 1. Use
		; canonical source spans of this exact selected asset to retain JSON kind,
		; including decoded keys and the parser's last-member-wins identity.
		AssetSpans := JsonArrayElementSpans(JsonObjectMemberSpans(Json)["assets"]["text"])
		SizeToken := JsonObjectMemberSpans(AssetSpans[AssetIndex]["text"])["size"]["text"]
		if !RegExMatch(SizeToken, "^(?:0|[1-9][0-9]*)$")
			return 0
		return { Url: Url, Digest: StrLower(Match[1]), Size: Asset["size"] }
	}
	return 0
}



; =========================================
; ===== 2.2a) Check schedule ============
; =========================================

; Automatic checks follow the persisted check record, not the process start:
; a restart mid-interval does not check at boot, a machine that was off past its
; due time catches up once the boot delay has passed, and failures retry on the
; shared backoff. The decision is the shared port (modules/updater/schedule.ahk,
; replayed against _shared/modules/updater/schedule_vectors.json).

; Test seams: the Storage port (a Map with "read" and "write" callables) and the
; wall clock (a callable returning epoch seconds). 0 means the production ones.
global _UpdaterCheckStateStore := 0
global _UpdaterClockFn := 0
; The persisted check record, loaded once from the Storage port.
global _UpdaterCheckState := 0
; When the driver started or the system last woke (epoch seconds): a catch-up
; check waits the shared boot delay after it, so the network can come up.
global _UpdaterStartedAt := _Updater_EpochNow()

; WM_POWERBROADCAST and its two resume notices (one per wake, the second only
; when a user is present). Re-evaluating twice is harmless.
global UPDATER_WM_POWERBROADCAST := 0x218
global UPDATER_PBT_APMRESUMESUSPEND := 0x7
global UPDATER_PBT_APMRESUMEAUTOMATIC := 0x12

; Current wall clock in UTC epoch seconds (the injected test clock when set).
_Updater_EpochNow() {
	global _UpdaterClockFn
	if HasMethod(_UpdaterClockFn, "Call")
		return _UpdaterClockFn.Call()
	return DateDiff(A_NowUTC, "19700101000000", "Seconds")
}

_Updater_CheckStateRead(Key) {
	global _UpdaterCheckStateStore
	if (_UpdaterCheckStateStore is Map)
		return _UpdaterCheckStateStore["read"].Call(Key)
	return ST_Get(Key, "")
}

_Updater_CheckStateWrite(Key, Value) {
	global _UpdaterCheckStateStore
	if (_UpdaterCheckStateStore is Map)
		return _UpdaterCheckStateStore["write"].Call(Key, Value)
	return ST_Set(Key, Value)
}

; Returns the persisted check record, loading it once. An invalid field is
; dropped with a warning; a missing install seed is created and saved. The last
; notified release is restored so a restart does not announce it again.
_Updater_CheckState() {
	global _UpdaterCheckState, UPDATER_LAST_NOTIFIED_TAG
	if (_UpdaterCheckState is Map)
		return _UpdaterCheckState
	Key := UpdateSchedule_Timing()["state_storage_key"]
	Result := UpdateSchedule_SanitizeState(_Updater_CheckStateRead(Key))
	for _, Field in Result.Dropped
		try LoggerWarn("Updater", "Dropped the invalid '{1}' of the stored update-check record.", Field)
	State := Result.State
	_UpdaterCheckState := State
	if !State.Has("seed") {
		State["seed"] := Format("{:08x}{:08x}", Random(0, 0x7FFFFFFF), Random(0, 0x7FFFFFFF))
		_Updater_SaveCheckState(State)
	}
	if State.Has("last_notified_tag")
		UPDATER_LAST_NOTIFIED_TAG := State["last_notified_tag"]
	try LoggerDebug("Updater", "Update-check record loaded (last check {1}, failures {2}).",
		State.Get("last_check_at", "never"), State.Get("failures", 0))
	return State
}

; Saves the record. A refused write still advances this session's copy, so a
; failing Storage port cannot turn every re-evaluation into a new check.
_Updater_SaveCheckState(State) {
	global _UpdaterCheckState
	_UpdaterCheckState := State
	Saved := false
	try Saved := _Updater_CheckStateWrite(UpdateSchedule_Timing()["state_storage_key"], State)
	catch as Err
		try LoggerError("Updater", "The update-check record write raised: {1}.", Err.Message)
	if (Saved != true) {
		try LoggerError("Updater", "Could not save the update-check record; the schedule restarts from it next launch only if a later write succeeds.")
		return false
	}
	return true
}

; Records one completed background check. Ok means GitHub answered with a
; usable release list (up to date, a new release or no release yet).
_Updater_RecordBackgroundCheck(Ok) {
	Next := UpdateSchedule_RecordCheck(_Updater_CheckState(), _Updater_EpochNow(), Ok)
	_Updater_SaveCheckState(Next)
	try LoggerInfo("Updater", "Background check recorded: {1} (consecutive failures: {2}).",
		Ok ? "success" : "failure", Next["failures"])
}

; Persists the release the user was just told about.
_Updater_RecordNotifiedTag(Tag) {
	State := _Updater_CheckState().Clone()
	State["last_notified_tag"] := Tag
	_Updater_SaveCheckState(State)
}

; The schedule at the current wall clock: { Due, WaitMs, ReevaluateMs, DueAt,
; Reason }. WaitMs is the timer delay while nothing is due (never past the due
; time, never beyond reevaluate_sec, at least one second).
_Updater_ScheduleDecision() {
	global UPDATER_CHECK_INTERVAL, _UpdaterStartedAt
	Timing := UpdateSchedule_Timing()
	Now := _Updater_EpochNow()
	ReevaluateMs := Timing["reevaluate_sec"] * 1000
	Next := UpdateSchedule_NextDue(Now, _UpdaterStartedAt, UPDATER_CHECK_INTERVAL, _Updater_CheckState())
	if (Next.DueAt == "")
		return { Due: false, WaitMs: ReevaluateMs, ReevaluateMs: ReevaluateMs, DueAt: "", Reason: Next.Reason }
	return {
		Due: Next.DueAt <= Now,
		WaitMs: Max(1000, UpdateSchedule_DelayUntil(Next.DueAt, Now) * 1000),
		ReevaluateMs: ReevaluateMs,
		DueAt: Next.DueAt,
		Reason: Next.Reason
	}
}

; WM_POWERBROADCAST handler: a resume defers one re-evaluation off the message
; handler (the machine may have slept through a due check).
_Updater_OnPowerBroadcast(wParam, lParam, msg, hwnd, ReevaluateFn := 0) {
	global UPDATER_PBT_APMRESUMEAUTOMATIC, UPDATER_PBT_APMRESUMESUSPEND
	if (wParam != UPDATER_PBT_APMRESUMEAUTOMATIC and wParam != UPDATER_PBT_APMRESUMESUSPEND)
		return
	if HasMethod(ReevaluateFn, "Call") {
		ReevaluateFn.Call()
		return
	}
	SetTimer(_Updater_ReevaluateAfterWake, -1)
}

; Restarts the boot delay at the wake and re-arms the live cadence owner from
; the schedule. Nothing is dispatched here: a due check runs from its timer.
_Updater_ReevaluateAfterWake(*) {
	global _UpdaterStartedAt
	_UpdaterStartedAt := _Updater_EpochNow()
	return _Updater_RearmBackgroundOwner("wake")
}

; Re-arms the one armed cadence owner for the current schedule and disarms the
; timer it supersedes. A queued old callback is inert: its arm epoch is stale.
_Updater_RearmBackgroundOwner(Reason) {
	global _UpdaterBackgroundOwner
	Owner := 0
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (IsObject(_UpdaterBackgroundOwner) and _UpdaterBackgroundOwner.Active
			and _UpdaterBackgroundOwner.Armed and _UpdaterBackgroundOwner.Phase == "armed")
			Owner := _UpdaterBackgroundOwner
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !IsObject(Owner) {
		try LoggerDebug("Updater", "No armed update-check timer to re-evaluate after a {1}.", Reason)
		return false
	}
	OldTimerFn := Owner.TimerFn
	Decision := _Updater_ScheduleDecision()
	if !_Updater_ArmBackgroundOwner(Owner, -Decision.WaitMs) {
		if Updater_StopBackgroundChecks(false, Owner)
			try LoggerError("Updater", "Could not re-arm the background update timer after a {1}: {2}.",
				Reason, Owner.LastArmError)
		return false
	}
	if IsObject(OldTimerFn)
		try _Updater_BackgroundSchedule(Owner, 0, OldTimerFn)
	try LoggerInfo("Updater", "Update-check schedule re-evaluated after a {1}: next evaluation in {2} s ({3}).",
		Reason, Decision.WaitMs // 1000, Decision.Reason)
	return true
}



; =========================================
; ===== 2.2) Background poller ==========
; =========================================

; Schedules the periodic update check. No-op when:
;   - we're running from source (Updater_IsLocalSource — meaningless),
;   - the interval is 0 ("never"),
;   - a timer is already armed.
; Every period is one exact negative one-shot. Its callback publishes the next
; owned one-shot before dispatching HTTP, so a queued callback from an older
; Stop-Start epoch cannot adopt the successor's timer handle.
Updater_StartBackgroundChecks(ScheduleFn := 0, IsLocalSource := unset) {
	global UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	global _UpdaterBackgroundOwner, _UpdaterBackgroundOwnerCounter
	global _UpdaterAsyncAdmissionBoundary
	if !IsSet(IsLocalSource)
		IsLocalSource := Updater_IsLocalSource()
	if IsLocalSource {
		try LoggerDebug("Updater", "Local source — background checks disabled.")
		return true
	}
	if (UPDATER_CHECK_INTERVAL <= 0) {
		try LoggerDebug("Updater", "Check interval is 0 (never) — background checks disabled.")
		return true
	}
	Owner := 0
	AlreadyRunning := false
	AdmissionClosed := false
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		AdmissionClosed := IsObject(_UpdaterAsyncAdmissionBoundary)
		AlreadyRunning := IsSet(_UpdaterBackgroundFn)
			or IsObject(_UpdaterBackgroundOwner)
		if !AdmissionClosed and !AlreadyRunning {
			_UpdaterBackgroundOwnerCounter += 1
			Owner := {
				Id: _UpdaterBackgroundOwnerCounter,
				Active: true,
				Armed: false,
				Phase: "reserved",
				ScheduleFn: ScheduleFn,
				TimerFn: 0,
				ArmEpoch: 0,
				FiredArmEpoch: 0,
				LastArmError: ""
			}
			_UpdaterBackgroundOwner := Owner
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if AdmissionClosed {
		try LoggerDebug("Updater", "Background checks refused during channel replacement.")
		return false
	}
	if AlreadyRunning {
		try LoggerDebug("Updater", "Background checks already running — ignoring start.")
		return true
	}
	; The first timer follows the persisted schedule: the boot delay for a fresh
	; install or an overdue check, the remaining wait otherwise (bounded by the
	; re-evaluation period). It used to fire min(30 s, interval) after every boot.
	Decision := _Updater_ScheduleDecision()
	FirstMs := Decision.WaitMs
	if !_Updater_ArmBackgroundOwner(Owner, -FirstMs) {
		Retired := false
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if (IsObject(_UpdaterBackgroundOwner)
				and ObjPtr(_UpdaterBackgroundOwner) == ObjPtr(Owner)) {
				Owner.Active := false
				Owner.Armed := false
				Owner.Phase := "retired"
				_UpdaterBackgroundFn := unset
				_UpdaterBackgroundOwner := 0
				Retired := true
			}
		} finally {
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
		if Retired and IsObject(Owner.TimerFn) {
			try _Updater_BackgroundSchedule(Owner, 0)
			; Owner.TimerFn is a BoundFunc that captures Owner. Break that reference
			; cycle after the exact callback has been disarmed.
			Owner.TimerFn := 0
		}
		try LoggerError("Updater", "Could not arm background update timer: {1}.",
			Owner.LastArmError == "" ? "timer owner was displaced" : Owner.LastArmError)
		return false
	}
	try LoggerInfo("Updater", "Background update checks armed (every {1} s; next evaluation in {2} s, {3}).",
		UPDATER_CHECK_INTERVAL, FirstMs // 1000, Decision.Reason)
	return true
}

; Arms one exact one-shot callback. If an injected scheduler dispatches inline,
; the callback records that this arm was consumed and Start retries once with a
; fresh epoch; success therefore always means a future callback exists.
_Updater_ArmBackgroundOwner(Owner, DelayMs) {
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterAsyncAdmissionBoundary
	global UPDATER_BACKGROUND_ARM_MAX_ATTEMPTS
	if Type(Owner) != "Object"
		return false
	loop UPDATER_BACKGROUND_ARM_MAX_ATTEMPTS {
		ArmEpoch := 0
		TimerFn := 0
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if IsObject(_UpdaterAsyncAdmissionBoundary) {
				Owner.LastArmError := "channel replacement closed timer admission"
				return false
			}
			if (!Owner.Active or !IsObject(_UpdaterBackgroundOwner)
				or ObjPtr(_UpdaterBackgroundOwner) != ObjPtr(Owner)) {
				Owner.LastArmError := "timer owner lost before arm"
				return false
			}
			Owner.ArmEpoch += 1
			ArmEpoch := Owner.ArmEpoch
			Owner.FiredArmEpoch := 0
			Owner.Armed := false
			Owner.Phase := "arming"
			TimerFn := Updater_BackgroundTick.Bind(Owner, ArmEpoch)
			Owner.TimerFn := TimerFn
			_UpdaterBackgroundFn := TimerFn
		} finally {
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
		ArmOk := false
		ArmErr := 0
		try ArmOk := _Updater_ResultSucceeded(
			_Updater_BackgroundSchedule(Owner, DelayMs))
		catch as Err
			ArmErr := Err
		ExactOwner := false
		ConsumedInline := false
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			ExactOwner := Owner.Active and IsObject(_UpdaterBackgroundOwner)
				and ObjPtr(_UpdaterBackgroundOwner) == ObjPtr(Owner)
				and !IsObject(_UpdaterAsyncAdmissionBoundary)
				and Owner.ArmEpoch == ArmEpoch
				and IsSet(_UpdaterBackgroundFn)
				and ObjPtr(_UpdaterBackgroundFn) == ObjPtr(TimerFn)
			ConsumedInline := ExactOwner and Owner.FiredArmEpoch == ArmEpoch
			if (ExactOwner and ArmOk and !ConsumedInline) {
				Owner.Armed := true
				Owner.Phase := "armed"
				Owner.LastArmError := ""
			} else if ExactOwner {
				Owner.Phase := ArmOk ? "armConsumed" : "armFailed"
				Owner.LastArmError := IsObject(ArmErr)
					? ArmErr.Message
					: (ArmOk
						? "timer callback consumed the arm inline"
						: "timer scheduler returned false")
			}
		} finally {
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
		if !ExactOwner {
			; Stop may have retired this owner while its scheduler pumped messages.
			; Disarm only the detached callback; never touch the replacement owner.
			try _Updater_BackgroundSchedule(Owner, 0, TimerFn)
			Owner.TimerFn := 0
			return false
		}
		if !ArmOk
			return false
		if !ConsumedInline
			return true
	}
	Owner.LastArmError := "timer callback consumed every bounded arm attempt inline"
	return false
}

_Updater_BackgroundSchedule(Owner, DelayMs, TimerFn := unset) {
	if Type(Owner) != "Object" or !Owner.HasOwnProp("TimerFn")
		return false
	if !IsSet(TimerFn)
		TimerFn := Owner.TimerFn
	if !IsObject(TimerFn)
		return false
	if Owner.HasOwnProp("ScheduleFn") and IsObject(Owner.ScheduleFn)
		return Owner.ScheduleFn.Call(TimerFn, DelayMs)
	; Default cadence arms only one-shots. Keeping the negative sign at the
	; SetTimer site also lets the fast-timer inventory prove this cannot become a
	; hidden repeating poller.
	if DelayMs == 0
		SetTimer(TimerFn, 0)
	else
		SetTimer(TimerFn, -Abs(DelayMs))
	return true
}

; Stops the periodic timer if armed. Safe to call when nothing is running.
Updater_StopBackgroundChecks(CancelInFlight := true, ExpectedOwner := 0) {
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	Stopped := false
	ExpectedOwnerLost := false
	Owner := 0
	TimerFn := 0
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (IsObject(ExpectedOwner)
			and (!IsObject(_UpdaterBackgroundOwner)
				or ObjPtr(_UpdaterBackgroundOwner) != ObjPtr(ExpectedOwner))) {
			ExpectedOwnerLost := true
		} else if IsSet(_UpdaterBackgroundFn) or IsObject(_UpdaterBackgroundOwner) {
			Stopped := true
			Owner := IsObject(_UpdaterBackgroundOwner)
				? _UpdaterBackgroundOwner : 0
			TimerFn := IsObject(Owner) ? Owner.TimerFn : _UpdaterBackgroundFn
			if IsObject(Owner) {
				Owner.Active := false
				Owner.Armed := false
				Owner.Phase := "retiring"
			}
			; Producer retirement is visible before SetTimer or cancellation can
			; pump a queued callback.
			_UpdaterBackgroundFn := unset
			_UpdaterBackgroundOwner := 0
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	StopErr := 0
	if Stopped
		try LoggerTrace("Updater", "Stopping background update checks…")
	if Stopped and IsObject(TimerFn) {
		try {
			if IsObject(Owner) {
				if !_Updater_ResultSucceeded(_Updater_BackgroundSchedule(Owner, 0))
					StopErr := Error("background scheduler returned false while disarming")
			} else {
				SetTimer(TimerFn, 0)
			}
		} catch as Err {
			StopErr := Err
		}
		if IsObject(Owner)
			Owner.Phase := IsObject(StopErr) ? "disarmFailed" : "retired"
		if IsObject(Owner)
			Owner.TimerFn := 0
	}
	if IsObject(StopErr)
		try LoggerError("Updater", "Could not disarm background update timer: {1}.", StopErr.Message)
	; Cancellation runs only after the producer has become unreachable.
	if CancelInFlight and !ExpectedOwnerLost
		_Updater_CancelAsyncChecks()
	if Stopped
		try LoggerDone("Updater", "Background update checks stopped.")
	return !ExpectedOwnerLost and !IsObject(StopErr)
}

; One iteration of the background poller: re-arms itself for the next interval,
; then dispatches a silent, ASYNCHRONOUS GitHub query. The response is harvested
; off this tick in _Updater_HandleBackgroundResult, so the network round-trip
; never blocks the main thread — the synchronous call here was what froze
; keyboard remapping a few seconds after startup on a slow or stalled network.
_Updater_BackgroundMayDispatch(IsLocalSource := unset, ExpectedOwner := 0) {
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterAsyncAdmissionBoundary
	if A_IsSuspended
		return false
	if IsObject(_UpdaterAsyncAdmissionBoundary)
		return false
	if !IsSet(_UpdaterBackgroundFn) or !IsObject(_UpdaterBackgroundOwner)
		return false
	if (IsObject(ExpectedOwner)
		and ObjPtr(ExpectedOwner) != ObjPtr(_UpdaterBackgroundOwner))
		return false
	if (!_UpdaterBackgroundOwner.Active or !_UpdaterBackgroundOwner.Armed
		or _UpdaterBackgroundOwner.Phase != "armed")
		return false
	if !IsSet(IsLocalSource)
		IsLocalSource := Updater_IsLocalSource()
	return !IsLocalSource
}

Updater_BackgroundTick(Owner := 0, ArmEpoch := 0, *) {
	global UPDATER_CHANNEL, UPDATER_CHECK_INTERVAL, _UpdaterBackgroundFn
	global _UpdaterBackgroundOwner
	global UPDATER_REQUEST_ORIGIN_BACKGROUND
	if !IsObject(Owner) {
		Owner := _UpdaterBackgroundOwner
		if IsObject(Owner)
			ArmEpoch := Owner.ArmEpoch
	}
	InlineArm := false
	MayRun := false
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		Current := IsObject(Owner) and IsObject(_UpdaterBackgroundOwner)
			and ObjPtr(Owner) == ObjPtr(_UpdaterBackgroundOwner)
			and Owner.Active and Owner.ArmEpoch == ArmEpoch
		if Current and Owner.Phase == "arming" {
			Owner.FiredArmEpoch := ArmEpoch
			InlineArm := true
		} else if (Current and Owner.Phase == "armed" and Owner.Armed) {
			Owner.Armed := false
			Owner.Phase := "firing"
			MayRun := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if InlineArm or !MayRun
		return false
	; The wall clock decides, so a timer that slept through a suspend is
	; corrected at its next re-evaluation.
	try Decision := _Updater_ScheduleDecision()
	catch as Err {
		try LoggerError("Updater", "Update-check schedule could not be evaluated: {1}.", Err.Message)
		Decision := { Due: false, WaitMs: UpdateSchedule_Timing()["reevaluate_sec"] * 1000, Reason: "error" }
	}
	; Re-arm first so a thrown error below cannot leave the loop dead. A due
	; check is re-evaluated after reevaluate_sec: its completion records the
	; check, from which the next due time follows.
	if !_Updater_ArmBackgroundOwner(
		Owner, -(Decision.Due ? Decision.ReevaluateMs : Decision.WaitMs)) {
		; Retire only the owner whose arm failed. A yielding scheduler may already
		; have run Stop -> Start and installed a successor.
		if Updater_StopBackgroundChecks(false, Owner)
			try LoggerError("Updater", "Could not rearm background update timer: {1}.",
				Owner.LastArmError)
		return false
	}
	if !Decision.Due
		return
	; Pause invariant: a suspended driver must be fully silent. SetTimer
	; callbacks are not gated by native Suspend, so we re-arm above (so the
	; loop survives pause and resumes cleanly) but skip the network dispatch,
	; the TrayTip and the tray-menu rebuild while suspended. The record is left
	; unchanged, so the check runs at the first re-evaluation after resuming.
	if A_IsSuspended
		return
	if !_Updater_BackgroundMayDispatch(, Owner)
		return
	try LoggerInfo("Updater", "Background update check due ({1}).", Decision.Reason)
	Current := Updater_CurrentVersion()
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_BACKGROUND)
	; ``Current`` and request provenance are captured at the same dispatch
	; boundary and stay paired until the async callback runs.
	_Updater_FetchLatestJsonAsync(UPDATER_CHANNEL, Request,
		(Json, CompletedRequest, Terminal := 0) => _Updater_HandleBackgroundResult(
			Json, Current, CompletedRequest, Terminal))
}

; Completion handler for a background check, invoked once the async fetch
; finishes (Json == "" on any failure). Compares tags, dedupes via
; LAST_NOTIFIED_TAG, and on a genuinely new release caches it, rebuilds the tray
; menu, and surfaces a TrayTip. Any failure is logged and the loop just waits
; for the next interval — a network blip must not silently kill the updater.
_Updater_HandleBackgroundResult(Json, Current, Request, Terminal := 0) {
	; Background work may publish only in the exact pause generation where it
	; was born. This also closes the register-vs-suspend race in the shared owner.
	if !_Updater_RequestMayPublish(Request)
		return
	global UPDATER_LAST_NOTIFIED_TAG, UPDATER_LATEST_RELEASE
	if _Updater_AsyncTerminalIsCancelled(Terminal) {
		try LoggerDebug("Updater", "Background check cancelled ({1}).", Terminal.Reason)
		return
	}
	; Every outcome is INFO: a check runs a few times a day, and "did it check,
	; and what did it find" is the first question when an update never arrives.
	if _Updater_JsonPayloadIsFailure(Json) {
		try LoggerInfo("Updater", "Background check result: network unreachable.")
		_Updater_RecordBackgroundCheck(false)
		return
	}
	if _Updater_JsonIsNoChannelRelease(Json) {
		try LoggerInfo("Updater", "Background check result: no release on channel {1} yet (current {2}).",
			Request.Channel, Current)
		_Updater_RecordBackgroundCheck(true)
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "") {
		; This used to be reported as "up to date", hiding a malformed response.
		try LoggerWarn("Updater", "Background check result: the release response carried no tag (current {1}).", Current)
		_Updater_RecordBackgroundCheck(false)
		return
	}
	_Updater_RecordBackgroundCheck(true)
	if !UpdateChannels_ShouldOffer(
		Latest, Current, Request.Channel, _Updater_InstalledChannel()) {
		try LoggerInfo("Updater", "Background check result: up to date (current {1}, latest {2}, channel {3}).",
			Current, Latest, Request.Channel)
		return
	}
	Release := {
		Tag:         Latest,
		Body:        Updater_ParseBody(Json),
		RawJson:     Json,
		HtmlUrl:     _Updater_ParseHtmlUrl(Json),
		PublishedAt: _Updater_ParsePublishedAt(Json),
		Prerelease:  _Updater_ParsePrerelease(Json)
	}
	; Parsing can outlive the initial callback gate. Commit both shared updater
	; fields through the generation lock immediately before visible output.
	if !_Updater_TryPublishRelease(Request, Release)
		return
	Reservation := _Updater_TryReserveReleaseNotification(Request, Latest)
	if !IsObject(Reservation) {
		try LoggerInfo("Updater", "Background check result: {1} available, already notified.", Latest)
		return
	}
	try LoggerInfo("Updater", "New release available: {1} (current: {2}).", Latest, Current)
	; Rebuild the tray menu so the one-click item label changes to
	; "Mettre à jour vers vX.Y.Z" without requiring a manual open.
	_Updater_ScheduleMenuRebuildForRequest(Request)
	; The TrayTip is the user's entry point: clicking the notification bubble opens
	; the full update prompt. The click is intercepted via OnMessage below.
	if !_Updater_RequestMayPublish(Request) {
		_Updater_ReleaseNotificationReservation(Reservation)
		return
	}
	try {
		_Updater_ClaimBalloon()
		TrayTip(Format(t("updater.tray_new_version_body"), Latest), t("updater.tray_new_version_title"))
		if _Updater_CommitReleaseNotification(Reservation, Request)
			_Updater_RecordNotifiedTag(Latest)
	} catch as Err {
		_Updater_ReleaseNotificationReservation(Reservation)
		try LoggerError("Updater", "Could not surface background update notification: {1}.", Err.Message)
	}
}

; Balloon ownership. Every balloon of the driver is a TrayTip on the one tray
; icon, and Windows reports a click with no balloon identity, so ownership is
; last-shown-wins: the updater claims the balloon right before its update offer
; and releases it before any other balloon it shows; a NIN_BALLOONSHOW it did
; not claim hands the balloon to whoever showed it. Only a click while the
; updater owns the balloon opens the update prompt: a saved screenshot, a
; copied colour or the manual check's "up to date" used to open it too.
global _UpdaterBalloon := { Owned: false, ShowPending: false }
global UPDATER_NIN_BALLOONSHOW := 0x402
global UPDATER_NIN_BALLOONUSERCLICK := 0x405

; Claims the balloon the updater is about to show (its update offer).
_Updater_ClaimBalloon() {
	global _UpdaterBalloon
	_UpdaterBalloon.Owned := true
	_UpdaterBalloon.ShowPending := true
}

; Gives up the balloon before the updater shows one that is not an offer.
_Updater_ReleaseBalloon() {
	global _UpdaterBalloon
	_UpdaterBalloon.Owned := false
	_UpdaterBalloon.ShowPending := false
}

; NIN_BALLOONSHOW: the first show after a claim is the updater's own; any
; later one replaced it.
_Updater_OnBalloonShown() {
	global _UpdaterBalloon
	if _UpdaterBalloon.ShowPending {
		_UpdaterBalloon.ShowPending := false
		return
	}
	_UpdaterBalloon.Owned := false
}

; Spends the claim on the click that answers it; false when not owned.
_Updater_TakeBalloonClick() {
	global _UpdaterBalloon
	if !_UpdaterBalloon.Owned
		return false
	_Updater_ReleaseBalloon()
	return true
}

; Wires an OnMessage handler so clicking the updater's balloon notification
; fires Updater_ShowAvailableUpdate. AHK v2 does not expose a dedicated
; TrayTip-click callback, but Windows posts WM_TRAYICON (0x404) with lParam ==
; 0x405 (NIN_BALLOONUSERCLICK) when the user clicks the notification body.
; Safe to call multiple times — the handler is idempotent (OnMessage replaces
; any prior registration for the same message + function pair).
Updater_InitTrayNotifyHandler() {
	global UPDATER_WM_POWERBROADCAST
	; maxThreads=1: no reentrant update prompts.
	OnMessage(0x404, _Updater_OnTrayMsg, 1)
	; A wake re-evaluates the update-check schedule (_Updater_OnPowerBroadcast).
	OnMessage(UPDATER_WM_POWERBROADCAST, _Updater_OnPowerBroadcast)
	try LoggerDebug("Updater", "Tray notification click and wake handlers registered.")
}

; OnMessage handler for WM_TRAYICON (0x404).
; lParam 0x402 = NIN_BALLOONSHOW, 0x405 = NIN_BALLOONUSERCLICK (the user clicked
; the notification body). Returns "" to let AHK continue its own tray processing.
_Updater_OnTrayMsg(wParam, lParam, msg, hwnd, ShowFn := 0) {
	global UPDATER_NIN_BALLOONSHOW, UPDATER_NIN_BALLOONUSERCLICK
	if (lParam == UPDATER_NIN_BALLOONSHOW) {
		_Updater_OnBalloonShown()
		return ""
	}
	; OnMessage bypasses native Suspend, so every genuine click on the updater's
	; balloon must reach the same visible entry policy as the tray-menu action
	; instead of disappearing.
	if (lParam == UPDATER_NIN_BALLOONUSERCLICK) {
		if !_Updater_TakeBalloonClick() {
			try LoggerDebug("Updater", "Balloon click ignored: the balloon is not the updater's offer.")
			return ""
		}
		if IsObject(ShowFn) {
			try ShowFn.Call()
		} else {
			try Updater_ShowAvailableUpdate()
		}
	}
	return ""
}



; =========================================
; ===== 2.3) "Update now" UI ============
; =========================================

; Singleton handle for the update-prompt Gui -- reused across calls so a second
; trigger (TrayTip click, changelog "Install this version", "Show update" menu
; item) brings the existing dialog to the front instead of opening a duplicate
; that could race Updater_DownloadAndInstall against the same staging file
; (updater-download-reentrancy).
global _Updater_PromptGui := unset
global _UpdaterDownloadWorker := 0
global _UpdaterDownloadRequest := 0
global _UpdaterDownloadArtifacts := 0
global _UpdaterDownloadStartedTick := 0
global _UpdaterStagingTransportCounter := 0
global UPDATER_STAGING_ENV_MAX_CHARS := 7000
; Application source-publication budget, not a Windows environment-block limit.
; Eight individually bounded fragments admit the production worker with room
; for growth while refusing an unbounded encoded source before any EnvSet.
global UPDATER_STAGING_MAX_SCRIPT_CHUNKS := 8
global _UpdaterSwapOwner := 0
; Boot installs an admitted recovery claim before loading this module. Other
; ordinary module consumers own an absent target; never overwrite a boot claim.
if !IsSet(_UpdaterRecoveryPublishTarget)
	global _UpdaterRecoveryPublishTarget := ""
global _UpdaterExitIntent := 0
global _UpdaterExitInvocation := 0
global _UpdaterSwapTransactionCounter := 0
global _UpdaterSelfUpdateEpoch := 0
global _UpdaterLifecycleRecoveryPending := false
global _UpdaterLifecycleRecoveryNoticeShown := false
global _UpdaterLifecycleRecoveryNoticeRequested := false
global _UpdaterLifecycleRecoveryAttemptCount := 0

; The four-event handshake is timer-polled on the AHK side. Every wait is a
; zero-time probe; only the exact native PowerShell worker performs blocking waits
; after it has left the keyboard thread.
global UPDATER_SWAP_HANDSHAKE_POLL_MS := 50
global UPDATER_SWAP_READY_TIMEOUT_MS := 10000
global UPDATER_SWAP_ACK_TIMEOUT_MS := 10000
global UPDATER_SWAP_PROBATION_MS := 750
global UPDATER_SWAP_BOOT_READY_TIMEOUT_MS := 60000
global UPDATER_SWAP_RESTORE_ATTEMPTS := 3
global UPDATER_SWAP_RESTORE_RETRY_MS := 100
global UPDATER_SWAP_EXIT_RETRY_MS := 100
global UPDATER_SWAP_MAX_EXIT_RETRIES := 50
global UPDATER_SWAP_RECOVERY_RETRY_BASE_MS := 250
global UPDATER_SWAP_RECOVERY_RETRY_MAX_MS := 5000
global UPDATER_RECOVERY_HANDOFF_RETRY_MS := 250
global UPDATER_RECOVERY_CLEANUP_INITIAL_MS := 1000

; Win32 process/event constants for the exact suspended-child protocol.
global UPDATER_SWAP_CREATE_SUSPENDED := 0x00000004
global UPDATER_SWAP_CREATE_NO_WINDOW := 0x08000000
global UPDATER_SWAP_SYNCHRONIZE := 0x00100000
global UPDATER_SWAP_WAIT_OBJECT_0 := 0x00000000
global UPDATER_SWAP_WAIT_TIMEOUT := 0x00000102
global UPDATER_SWAP_WAIT_FAILED := 0xFFFFFFFF
global UPDATER_SWAP_RESUME_FAILED := 0xFFFFFFFF
global _UpdaterSwapCleanupDebt := Map()
global _UpdaterSwapCleanupDebtCounter := 0
global _UpdaterSwapCleanupRetryTimer := 0
global UPDATER_SWAP_CLEANUP_RETRY_MS := 50

; Returns the canonical executable encoded by a rollback recovery filename, or
; an empty string for every other path. The exact 32-hex GUID suffix prevents an
; arbitrary similarly named executable from entering the self-repair lifecycle.
_Updater_RecoveryTargetForExecutable(Path) {
	if (Type(Path) != "String" or Path == "")
		return ""
	if !RegExMatch(Path,
		"i)^(.*\.exe)\.[0-9a-f]{32}\.recovery\.exe$", &Match)
		return ""
	return Match[1]
}

; Environment input is untrusted. A canonical process may delete a recovery
; executable only when that sibling's encoded target is this exact executable.
_Updater_RecoveryCleanupPathForCurrent(CurrentPath, CandidatePath) {
	if (Type(CurrentPath) != "String" or Type(CandidatePath) != "String"
		or CurrentPath == "" or CandidatePath == "")
		return ""
	EncodedTarget := _Updater_RecoveryTargetForExecutable(CandidatePath)
	if (EncodedTarget == ""
		or StrCompare(EncodedTarget, CurrentPath, false) != 0)
		return ""
	return CandidatePath
}

; The claim is a two-line, same-directory capability written atomically by the
; swap worker only after both old-good executables are complete. The stage path
; is derived independently from the recovery filename before its content is
; trusted, so a forged claim cannot redirect MoveFileEx to an arbitrary file.
_Updater_LoadRecoveryDescriptor(RecoveryPath) {
	static RECOVERY_CLAIM_MAX_BYTES := 32768
	TargetPath := _Updater_RecoveryTargetForExecutable(RecoveryPath)
	if (TargetPath == "")
		return 0
	ExpectedStage := RegExReplace(RecoveryPath,
		"i)\.recovery\.exe$", ".republish.exe")
	ClaimPath := RecoveryPath . ".claim"
	ClaimText := FSReadBounded(ClaimPath, RECOVERY_CLAIM_MAX_BYTES)
	if !(ClaimText is String)
		return 0
	Lines := StrSplit(StrReplace(ClaimText, "`r", ""), "`n")
	while (Lines.Length and Lines[Lines.Length] == "")
		Lines.Pop()
	if (Lines.Length != 2
		or StrCompare(Lines[1], TargetPath, false) != 0
		or StrCompare(Lines[2], ExpectedStage, false) != 0)
		return 0
	RecoverySize := FSSize(RecoveryPath)
	if (!FSExists(RecoveryPath) or !FSExists(ExpectedStage)
		or RecoverySize <= 0 or FSSize(ExpectedStage) != RecoverySize)
		return 0
	return Map("Target", TargetPath, "Stage", ExpectedStage,
		"Claim", ClaimPath)
}

_Updater_ValidateBootReadyEventName(Name) {
	if (Type(Name) != "String")
		return ""
	return RegExMatch(Name,
		"^Local\\ErgoptiPlus\.Updater\.BootReady\.[0-9a-fA-F]{32}$")
		? Name : ""
}

_Updater_SwapFailureTerminalPath() {
	LocalAppData := ResolveLocalAppDataDir()
	if (LocalAppData == "")
		return ""
	return LocalAppData . "\Ergopti\updates\swap_update.ps1.log.terminal"
}

; The inherited path is a capability, not an arbitrary file-read request. Only
; the exact bounded receipt owned by this updater installation is accepted.
_Updater_LoadSwapFailureTerminal(CandidatePath, ExpectedPath := "") {
	if (Type(CandidatePath) != "String" or CandidatePath == "")
		return ""
	if (ExpectedPath == "")
		ExpectedPath := _Updater_SwapFailureTerminalPath()
	if (Type(ExpectedPath) != "String" or ExpectedPath == ""
		or StrCompare(CandidatePath, ExpectedPath, false) != 0)
		return ""
	Terminal := FSReadBounded(CandidatePath, 2048)
	if !(Terminal is String)
		return ""
	Terminal := RTrim(Terminal, "`r`n")
	if !RegExMatch(Terminal, "^SWAP_ERROR:[^`r`n]{1,2000}$")
		return ""
	return Terminal
}

_Updater_ArmInheritedSwapFailureNotice() {
	global _UpdaterInheritedSwapFailure
	if (_UpdaterInheritedSwapFailure == "")
		return false
	return TimerArmOneShotMs(_Updater_SurfaceInheritedSwapFailure, 1)
}

_Updater_SurfaceInheritedSwapFailure(*) {
	global _UpdaterInheritedSwapFailure, _UpdaterInheritedSwapFailurePath
	Terminal := _UpdaterInheritedSwapFailure
	if (Terminal == "")
		return false
	try LoggerError("Updater", "Previous executable replacement failed after shutdown: {1}.", Terminal)
	try {
		Ui_MsgBox(t("updater.install_error") . "`n`n" . Terminal,
			t("updater.window_title"), "Icon!")
		if (_UpdaterInheritedSwapFailurePath != ""
			and !FSDelete(_UpdaterInheritedSwapFailurePath))
			throw Error("Consumed swap failure receipt could not be deleted")
		_UpdaterInheritedSwapFailure := ""
		_UpdaterInheritedSwapFailurePath := ""
		return true
	} catch as Err {
		try LoggerError("Updater", "Could not surface the inherited swap failure: {1}.", Err.Message)
		return false
	}
}

_Updater_SignalInheritedBootReady() {
	global _UpdaterInheritedBootReadyName
	Name := _UpdaterInheritedBootReadyName
	if (Name == "")
		return true
	if PLC_SignalNamedEvent(Name) {
		_UpdaterInheritedBootReadyName := ""
		return true
	}
	try LoggerError("Updater", "Inherited boot-ready event could not be signaled.")
	return false
}

_Updater_RecoveryRetryDelay(AttemptCount) {
	global UPDATER_SWAP_RECOVERY_RETRY_BASE_MS
	global UPDATER_SWAP_RECOVERY_RETRY_MAX_MS
	return Min(UPDATER_SWAP_RECOVERY_RETRY_BASE_MS * Max(AttemptCount, 1),
		UPDATER_SWAP_RECOVERY_RETRY_MAX_MS)
}

; The worker has already copied and validated the old-good bytes off-thread.
; Runtime recovery only retries one same-directory write-through rename, so an
; antivirus lock cannot trigger repeated full-executable copies on the keyboard
; thread.
_Updater_RepublishRecoveryExecutable(StagePath, TargetPath, ExpectedSize) {
	if (Type(StagePath) != "String" or Type(TargetPath) != "String"
		or StagePath == "" or TargetPath == "" or ExpectedSize <= 0)
		throw ValueError("Recovery publish requires an authorized stage and target")
	if (FSSize(StagePath) != ExpectedSize)
		throw Error("Recovery republish stage changed size")
	if !FSAtomicMoveReplace(StagePath, TargetPath)
		throw Error("Atomic recovery publish failed")
	; A successful same-directory MoveFileEx is the transaction's commit point.
	; Do not add a fallible post-rename probe here: the stage has been consumed,
	; so a transient probe failure would make every retry permanently impossible.
	; The handoff gate validates TargetPath again immediately before launch.
	return true
}

_Updater_ArmRecoveryMaintenanceAfterReady() {
	global _UpdaterRecoveryPublishTarget, _UpdaterRecoveryCleanupPath
	global UPDATER_RECOVERY_CLEANUP_INITIAL_MS
	if (_UpdaterRecoveryPublishTarget != "") {
		TimerArmOneShotMs(_Updater_RecoveryRepublishPoll, 1)
	} else {
		_Updater_SignalInheritedBootReady()
	}
	if (_UpdaterRecoveryCleanupPath != "")
		TimerArmOneShotMs(_Updater_RecoveryCleanupPoll,
			UPDATER_RECOVERY_CLEANUP_INITIAL_MS)
}

; The recovery process remains a complete, responsive driver while antivirus or
; another process keeps Current.exe locked. Each retry stages off-path; only the
; final MoveFileEx rename touches the canonical executable.
_Updater_RecoveryRepublishPoll(*) {
	global _UpdaterRecoveryPublishTarget, _UpdaterRecoveryPublishAttemptCount
	global _UpdaterRecoveryPublishStage, _UpdaterRecoveryHandoffPending
	TargetPath := _UpdaterRecoveryPublishTarget
	if (TargetPath == "" or _UpdaterRecoveryHandoffPending)
		return
	try {
		_Updater_RepublishRecoveryExecutable(_UpdaterRecoveryPublishStage,
			TargetPath, FSSize(A_ScriptFullPath))
		PreviousCritical := Critical("On")
		try {
			_UpdaterRecoveryPublishAttemptCount := 0
			_UpdaterRecoveryHandoffPending := true
		} finally {
			Critical(PreviousCritical)
		}
		try LoggerInfo("Updater", "Recovery driver atomically republished canonical executable '{1}'.", TargetPath)
		_Updater_RecoveryReadySignalPoll()
		return
	} catch as Err {
		PreviousCritical := Critical("On")
		try AttemptCount := ++_UpdaterRecoveryPublishAttemptCount
		finally Critical(PreviousCritical)
		DelayMs := _Updater_RecoveryRetryDelay(AttemptCount)
		try LoggerWarn("Updater", "Recovery republish attempt {1} failed; retrying in {2} ms: {3}.", AttemptCount, DelayMs, Err.Message)
		TimerArmOneShotMs(_Updater_RecoveryRepublishPoll, DelayMs)
	}
}

_Updater_RecoveryReadySignalPoll(*) {
	; The recovery launcher is not the process the swap worker ultimately needs
	; to trust. Preserve the inherited event for canonical Current.exe; that new
	; process signals only after its own _DriverReady contract is published.
	_Updater_RequestRecoveryHandoffExit()
}

; Current.exe inherits exactly one validated recovery path. Deletion is deferred
; until this replacement has reached ready, and remains best-effort: cleanup
; failure never disables the driver or re-enters the swap transaction.
_Updater_RecoveryCleanupPoll(*) {
	global _UpdaterRecoveryCleanupPath, _UpdaterRecoveryCleanupAttemptCount
	CandidatePath := _UpdaterRecoveryCleanupPath
	if (CandidatePath == "")
		return
	if (_Updater_RecoveryCleanupPathForCurrent(A_ScriptFullPath, CandidatePath) == "") {
		_UpdaterRecoveryCleanupPath := ""
		return
	}
	try {
		ClaimPath := CandidatePath . ".claim"
		if !FSDelete(ClaimPath)
			throw Error("Recovery claim could not be deleted")
		if !FSDelete(CandidatePath)
			throw Error("Recovery executable could not be deleted")
		_UpdaterRecoveryCleanupPath := ""
		_UpdaterRecoveryCleanupAttemptCount := 0
		try LoggerInfo("Updater", "Retired rollback recovery executable after canonical driver reached ready.")
	} catch as Err {
		PreviousCritical := Critical("On")
		try AttemptCount := ++_UpdaterRecoveryCleanupAttemptCount
		finally Critical(PreviousCritical)
		DelayMs := _Updater_RecoveryRetryDelay(AttemptCount)
		try LoggerWarn("Updater", "Recovery cleanup attempt {1} failed; retrying in {2} ms: {3}.", AttemptCount, DelayMs, Err.Message)
		TimerArmOneShotMs(_Updater_RecoveryCleanupPoll, DelayMs)
	}
}

; The transient invocation token is the recovery equivalent of the updater's
; Ack-to-exit token. A concurrent ordinary Quit after publication must not be
; converted into an automatic relaunch of Current.exe.
_Updater_RequestRecoveryHandoffExit(*) {
	global _UpdaterRecoveryHandoffPending, _UpdaterRecoveryExitInvocation
	global UPDATER_RECOVERY_HANDOFF_RETRY_MS
	if !_Updater_PrepareRecoverySuspendHandoff() {
		TimerArmOneShotMs(_Updater_RequestRecoveryHandoffExit,
			UPDATER_RECOVERY_HANDOFF_RETRY_MS)
		return
	}
	PreviousCritical := Critical("On")
	try {
		if !_UpdaterRecoveryHandoffPending
			return
		_UpdaterRecoveryExitInvocation := true
		TimerArmOneShotMs(_Updater_RequestRecoveryHandoffExit,
			UPDATER_RECOVERY_HANDOFF_RETRY_MS)
		ExitApp(0)
	} finally {
		_UpdaterRecoveryExitInvocation := false
		Critical(PreviousCritical)
	}
}

_Updater_PrepareRecoverySuspendHandoff() {
	global _UpdaterRecoverySuspendPrepared
	Path := _SuspendMarkerPath()
	if !A_IsSuspended {
		; A prior refused attempt may have left inert pending state. Resuming the
		; still-live recovery driver revokes that intent before the next ExitApp.
		Cleaned := _SuspendHandoffCancelMarker(Path)
		_UpdaterRecoverySuspendPrepared := false
		return Cleaned
	}
	if (Path == "" or !_SuspendHandoffPrepareMarker(Path)) {
		try LoggerError("Updater", "Recovery handoff refused because suspended state could not be published.")
		return false
	}
	_UpdaterRecoverySuspendPrepared := true
	return true
}

; Before canonical publication the recovery executable is the only complete
; driver. No ordinary Quit/Reload may cross destructive teardown in that state;
; the external swap worker also supervises this lease before OnExit is armed.
_Updater_RecoveryMayEnterTerminalShutdown() {
	global _UpdaterRecoveryPublishTarget, _UpdaterRecoveryHandoffPending
	if (_UpdaterRecoveryPublishTarget == "" or _UpdaterRecoveryHandoffPending)
		return true
	TimerArmOneShotMs(_Updater_RecoveryRepublishPoll, 1)
	return false
}

_Updater_DeferRecoveryHandoffRetry() {
	global _UpdaterRecoveryExitInvocation
	global UPDATER_RECOVERY_HANDOFF_RETRY_MS
	if !_UpdaterRecoveryExitInvocation
		return false
	TimerArmOneShotMs(_Updater_RequestRecoveryHandoffExit,
		UPDATER_RECOVERY_HANDOFF_RETRY_MS)
	return true
}

; Called as the last fallible action in Ergopti_OnShutdown. Every refusal gate
; has accepted before the canonical successor is launched, so it can wait on
; the still-owned driver mutex for the few milliseconds until this callback
; returns and the recovery process exits.
_Updater_CompleteRecoveryHandoffOnExit() {
	global _UpdaterRecoveryPublishTarget, _UpdaterRecoveryHandoffPending
	global _UpdaterRecoveryExitInvocation, _UpdaterRecoveryClaimPath
	global _UpdaterInheritedBootReadyName, _UpdaterRecoverySuspendPrepared
	if !_UpdaterRecoveryExitInvocation
		return true
	TargetPath := _UpdaterRecoveryPublishTarget
	if (!_UpdaterRecoveryHandoffPending or TargetPath == "")
		return false
	try {
		if !FSExists(TargetPath)
			throw Error("Canonical recovery target disappeared before handoff")
		if (FSSize(TargetPath) != FSSize(A_ScriptFullPath))
			throw Error("Canonical recovery target changed size before handoff")
		EnvSet("ERGOPTI_UPDATER_RECOVERY_CLEANUP", A_ScriptFullPath)
		if (_UpdaterInheritedBootReadyName != "")
			EnvSet("ERGOPTI_UPDATER_BOOT_READY", _UpdaterInheritedBootReadyName)
		; The canonical child blocks on this process's driver mutex. Launch it
		; before publishing pause intent: if the following durable promotion
		; fails, this callback refuses exit and the child times out without ever
		; reaching config/bootstrap state.
		Run('"' . TargetPath . '"', , "Hide")
		if _UpdaterRecoverySuspendPrepared {
			Path := _SuspendMarkerPath()
			if !_SuspendHandoffCommitMarker(Path)
				throw Error("Suspended recovery intent could not reach terminal publication")
			_UpdaterRecoverySuspendPrepared := false
		}
		try {
			if (_UpdaterRecoveryClaimPath != "")
				FSDelete(_UpdaterRecoveryClaimPath)
		}
		try LoggerInfo("Updater", "Recovery handoff launched canonical driver after every shutdown refusal gate.")
		return true
	} catch as Err {
		try EnvSet("ERGOPTI_UPDATER_RECOVERY_CLEANUP", "")
		try EnvSet("ERGOPTI_UPDATER_BOOT_READY", "")
		try LoggerError("Updater", "Recovery handoff could not launch canonical driver: {1}.", Err.Message)
		return false
	}
}

; Two-pane window: release tag/date on the left summary, full release notes
; on the right, with three buttons at the bottom: ``Update now`` (downloads
; the asset and triggers the swap), ``Open on GitHub`` (browser fallback),
; and ``Later`` (close). Used both from the TrayTip click and from the
; explicit "Show update" menu item that appears on new-version availability.
Updater_ShowUpdatePrompt(Release, Request := unset) {
	global _VendorDir, _Updater_PromptGui
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if !IsSet(Request) {
		if A_IsSuspended
			return _Updater_RefuseManualWhileSuspended()
		Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
		if Request.BornSuspended
			return _Updater_RefuseManualWhileSuspended()
	}
	if (Type(Release) != "Object")
		return
	if !_Updater_RequestMayPublish(Request)
		return
	; Singleton: bring the existing prompt forward instead of opening a
	; duplicate dialog that could trigger a second concurrent download
	; (updater-download-reentrancy).
	if IsSet(_Updater_PromptGui) {
		try LoggerDebug("Updater", "Update prompt already open -- reusing existing window instead of opening a duplicate.")
		if !_Updater_RequestMayPublish(Request) {
			_Updater_CloseGui(_Updater_PromptGui)
			return
		}
		WMPresentWindow(_Updater_PromptGui)
		if !_Updater_RequestMayPublish(Request)
			_Updater_CloseGui(_Updater_PromptGui)
		return
	}
	G := Gui_Create("+Resize +MinSize720x420", t("updater.update_window_title"))
	_Updater_PromptGui := G
	G.SetFont("s11 bold", "Segoe UI")
	G.MarginX := 14
	G.MarginY := 12
	; Header: "Update available — vX.Y.Z" so the user immediately sees the
	; tag they're about to install. Date below if we have one.
	HeaderText := Format(t("updater.update_dialog_header"), Release.Tag)
	G.Add("Text", "xm w700", HeaderText)
	G.SetFont("s9 norm")
	if (Release.HasProp("PublishedAt") and Release.PublishedAt != "") {
		G.Add("Text", "xm y+2 cGray w700", SubStr(Release.PublishedAt, 1, 10))
	}
	G.SetFont("s10 norm")
	G.Add("Text", "xm y+10 w700", t("updater.update_dialog_changelog"))

	; Placeholder that WebView2 overlays — same height as the former Edit control.
	BodyPane := G.Add("Text", "xm y+4 w700 h300", "")

	BtnInstall := G.Add("Button", "xm y+12 Default", t("updater.update_dialog_install"))
	BtnOpen    := G.Add("Button", "x+8 yp",          t("updater.update_dialog_open"))
	BtnLater   := G.Add("Button", "x+8 yp",          t("updater.update_dialog_later"))

	BtnInstall.OnEvent("Click", (*) => _Updater_InstallPromptRelease(G, Release))
	BtnOpen.OnEvent("Click",    (*) => _Updater_OpenPromptReleaseUrl(Release))
	BtnLater.OnEvent("Click",   (*) => _Updater_CloseGui(G))
	G.WVC := 0
	G.OnEvent("Close",  (*) => _Updater_CloseGui(G))
	G.OnEvent("Escape", (*) => _Updater_CloseGui(G))
	if !_Updater_RequestMayPublish(Request) {
		_Updater_CloseGui(G)
		return
	}
	G.Show("w740 AutoSize")
	if !_Updater_RequestMayPublish(Request) {
		_Updater_CloseGui(G)
		return
	}

	; Spin up WebView2 after Show() (Hwnd is valid then) and load the shared
	; release-notes page: the release's changelog, rendered like the Versions window.
	UseWV := IsSet(WebView2) && FileExist(_VendorDir . "\64bit\WebView2Loader.dll") && !WebView_ShouldUseNativeFallback()
	if UseWV {
		loader := _VendorDir . "\64bit\WebView2Loader.dll"
		WVC := unset
		try {
			; Reuse the shared session environment (infra/webview_utils.ahk) so no
			; second Chromium process boots and reopens are near-instant.
			WVC := WebView2.create(BodyPane.Hwnd, , WebView_SharedEnvironment(loader))
			G.WVC := WVC
		} catch as Err {
			try LoggerWarn("Updater", "WebView2 create failed in update prompt: {1}.", Err.Message)
			UseWV := false
		}
		if UseWV and IsSet(WVC) {
			try {
				s := WVC.CoreWebView2.Settings
				s.AreDevToolsEnabled              := false
				s.AreDefaultContextMenusEnabled   := false
				s.IsStatusBarEnabled              := false
				s.AreBrowserAcceleratorKeysEnabled := false
			}
			WVC.Fill()
			try {
				G.WVSub := _Updater_NavigateReleaseNotes(WVC, Release)
			} catch as Err {
				try LoggerWarn("Updater", "Update prompt shows the native notes instead: {1}.", Err.Message)
				try WVC.Close()
				G.WVC := 0
				UseWV := false
			}
		}
	}
	if (!UseWV or !IsSet(WVC)) {
		; Fallback: replace the placeholder with a plain read-only Edit showing the
		; changelog section (or the localized empty-notes message).
		BodyPane.GetPos(&bx, &by, &bw, &bh)
		BodyText := _Updater_ReleaseNotesToPlain(Release.Body)
		G.Add("Edit", "x" . bx . " y" . by . " w" . bw . " h" . bh
			. " ReadOnly +Multi -Wrap +VScroll", BodyText)
	}
	; WebView2 creation/navigation can pump the suspend reactor. A prompt owned
	; by an async request must not survive if its generation changed mid-build.
	if !_Updater_RequestMayPublish(Request)
		_Updater_CloseGui(G)
}

_Updater_OpenPromptReleaseUrl(Release, IsSuspended := unset, NotifyFn := 0, RunFn := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	HasSuspendOverride := IsSet(IsSuspended)
	if (HasSuspendOverride ? IsSuspended : A_IsSuspended)
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	Request := HasSuspendOverride
		? _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, IsSuspended)
		: _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	Url := (Type(Release) == "Object" and Release.HasProp("HtmlUrl") and Release.HtmlUrl != "")
		? Release.HtmlUrl : Updater_ReleasesPageUrl()
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended)
			return false
	} else if !_Updater_RequestMayPublish(Request) {
		return false
	}
	try {
		if IsObject(RunFn)
			RunFn.Call(Url)
		else
			Run(Url)
	} catch as Err {
		try LoggerError("Updater", "Could not open update URL '{1}': {2}.", Url, Err.Message)
		return false
	}
	return true
}

_Updater_InstallPromptRelease(G, Release) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	if A_IsSuspended
		return _Updater_RefuseManualWhileSuspended()
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return false
	_Updater_CloseGui(G)
	Updater_DownloadAndInstall(Release, Request)
}

_Updater_CloseGui(G) {
	global _Updater_PromptGui
	; Identity check happens BEFORE Destroy() so it never depends on reading
	; state from an already torn-down Gui. _Updater_CloseGui is shared with
	; the changelog window's own Gui instance, so only clear the singleton
	; when this call is actually closing the update prompt.
	IsPromptGui := IsSet(_Updater_PromptGui) && (G.Hwnd == _Updater_PromptGui.Hwnd)
	; Release the notes pane's bridge subscription while its controller is still
	; alive: freeing it unsubscribes on the controller, which fails once closed.
	if G.HasProp("WVSub")
		G.WVSub := 0
	if G.HasProp("WVC") && G.WVC
		try G.WVC.Close()
	try G.Destroy()
	if IsPromptGui
		_Updater_PromptGui := unset
}


; Menu/notification entry point — pulls the cached release record from the
; last background tick when present, otherwise hits the API on the spot so
; the user can always summon the prompt from the tray.
Updater_ShowAvailableUpdate(*) {
	return _Updater_ShowAvailableUpdateEntry()
}

_Updater_ShowAvailableUpdateEntry(IsSuspended := unset, NotifyFn := 0, ContinueFn := 0) {
	if !IsSet(IsSuspended)
		IsSuspended := A_IsSuspended
	if IsSuspended
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	if IsObject(ContinueFn)
		return ContinueFn.Call()
	return _Updater_ShowAvailableUpdateRunning()
}

_Updater_ShowAvailableUpdateRunning() {
	global UPDATER_LATEST_RELEASE, UPDATER_CHANNEL
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Request := _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	if Request.BornSuspended
		return _Updater_RefuseManualWhileSuspended()
	if !_Updater_RequestMayPublish(Request)
		return false
	if IsSet(UPDATER_LATEST_RELEASE) and Type(UPDATER_LATEST_RELEASE) == "Object" {
		Updater_ShowUpdatePrompt(UPDATER_LATEST_RELEASE, Request)
		return
	}
	if Updater_IsLocalSource() {
		Ui_MsgBox(t("updater.local_source"), t("updater.window_title"), "Iconi")
		return
	}
	; No cached release — fetch one ASYNCHRONOUSLY so the network round-trip
	; never blocks the AHK main thread (a synchronous WinHttp.Send here would
	; freeze keyboard remapping and drop keystrokes for the whole resolve /
	; connect / receive budget on a stalled or captive-portal network). ``T2``
	; auto-dismisses the brief "Verification…" notice; the actual update prompt
	; is surfaced from the async callback once the response arrives.
	Ui_MsgBox(Format(t("updater.checking"), _Updater_ChannelLabel(UPDATER_CHANNEL)), t("updater.window_title"), "Iconi T2")
	; ``Current`` is captured with the request, as on the background path.
	Current := Updater_CurrentVersion()
	_Updater_FetchLatestJsonAsync(UPDATER_CHANNEL, Request,
		(Json, CompletedRequest, Terminal := 0) => _Updater_ShowAvailableUpdateCallback(
			Json, CompletedRequest, Terminal, 0, 0, Current))
}

; Completion handler for the async fetch dispatched by Updater_ShowAvailableUpdate
; when no release is cached. Mirrors the synchronous tail it replaced: surfaces a
; localized error on failure, reports an installed version that is already the
; channel's latest, otherwise builds the release record and shows the update
; prompt. Runs off a poll timer so it never blocks the main thread. NotifyFn and
; PromptFn are test seams for the message box and the prompt.
_Updater_ShowAvailableUpdateCallback(Json, Request, Terminal := 0, NotifyFn := 0, PromptFn := 0, Current := unset) {
	if !_Updater_RequestMayPublish(Request)
		return
	if _Updater_AsyncTerminalIsCancelled(Terminal) {
		try LoggerDebug("Updater", "Manual update check cancelled ({1}).", Terminal.Reason)
		return
	}
	if _Updater_JsonPayloadIsFailure(Json) {
		if !_Updater_RequestMayPublish(Request)
			return
		if IsObject(NotifyFn)
			NotifyFn.Call(t("updater.no_connection"), t("updater.title_update"), "Icon!")
		else
			Ui_MsgBox(t("updater.no_connection"), t("updater.window_title"), "Icon!")
		return
	}
	if _Updater_JsonIsNoChannelRelease(Json) {
		if !_Updater_RequestMayPublish(Request)
			return
		Ui_MsgBox(_Updater_NoChannelReleaseMessage(Request.Channel), t("updater.window_title"), "Iconi")
		return
	}
	Tag := Updater_ParseTagName(Json)
	if (Tag == "") {
		if !_Updater_RequestMayPublish(Request)
			return
		Ui_MsgBox(t("updater.parse_failed"), t("updater.window_title"), "Icon!")
		return
	}
	if !IsSet(Current)
		Current := Updater_CurrentVersion()
	; The same offer rule as the background check: this fallback used to show
	; the prompt for whatever the list's latest tag was, so a balloon click
	; announced "Update available" for the version already installed.
	if !UpdateChannels_ShouldOffer(Tag, Current, Request.Channel, _Updater_InstalledChannel()) {
		try LoggerInfo("Updater", "Update prompt not shown: {1} is up to date (latest {2}, channel {3}).",
			Current, Tag, Request.Channel)
		if !_Updater_RequestMayPublish(Request)
			return
		Message := Format(t("updater.up_to_date"), Current)
		if IsObject(NotifyFn)
			NotifyFn.Call(Message, t("updater.title_update"), "Iconi")
		else
			Ui_MsgBox(Message, t("updater.window_title"), "Iconi")
		return
	}
	Release := {
		Tag:         Tag,
		Body:        Updater_ParseBody(Json),
		RawJson:     Json,
		HtmlUrl:     _Updater_ParseHtmlUrl(Json),
		PublishedAt: _Updater_ParsePublishedAt(Json),
		Prerelease:  _Updater_ParsePrerelease(Json)
	}
	; GUI construction can yield to the suspend reactor; reject a request that
	; crossed that boundary while release metadata was being parsed.
	if !_Updater_RequestMayPublish(Request)
		return
	if IsObject(PromptFn)
		PromptFn.Call(Release, Request)
	else
		Updater_ShowUpdatePrompt(Release, Request)
}



; =====================================================
; ===== 2.4) Download + swap (binary replacement) =====
; =====================================================

; The Versions window's observer of the install it asked for (a release chosen
; there, modules/updater/release_install.ahk), or 0. While one is set, the
; phases and failures of the transaction go to that window, which shows them
; with a Retry button. Called as (Phase, ReasonKey, optional FailureReceipt).
global _UpdaterInstallObserver := 0
global _UpdaterInstallObserverEpoch := 0
; The shared failure interpreter and host presenter are initialized once at boot.
; The private terminal owner never crosses a WebView or a worker command line.
global _UpdaterManagedFailureContract := 0
global _UpdaterManagedFailurePresenter := 0
global _UpdaterManagedFailureRetireFn := 0
global _UpdaterManagedFailureOwner := 0

; Tells the Versions window one phase of the install it follows: "installing",
; "restarting" or "failed" (which ends the following).
; @param Phase {String}
; @param ReasonKey {String} Page locale key of a failure.
; @returns {Boolean} True when a window follows this install.
_Updater_NotifyInstallPhase(Phase, ReasonKey := "", FailureReceipt := 0, ExpectedObserver := unset) {
	global _UpdaterInstallObserver, _UpdaterInstallObserverEpoch
	PreviousCritical := Critical("On")
	try {
		Observer := IsSet(ExpectedObserver) ? ExpectedObserver : _UpdaterInstallObserver
		if IsObject(Observer) && Phase == "failed"
			&& IsObject(_UpdaterInstallObserver) && _UpdaterInstallObserver == Observer {
			_UpdaterInstallObserver := 0
			_UpdaterInstallObserverEpoch += 1
		}
	} finally {
		Critical(PreviousCritical)
	}
	if !IsObject(Observer)
		return false
	try {
		if FailureReceipt is Map
			Observer.Call(Phase, ReasonKey, FailureReceipt)
		else
			Observer.Call(Phase, ReasonKey)
	}
	catch as Err
		try LoggerError("Updater", "The Versions window's install observer raised: {1}.", Err.Message)
	return true
}

; Reports an install failure to the Versions window that follows the install,
; or in the modal box an update from the menu or the prompt has always shown.
; @param MessageKey {String} Updater locale key of the modal box.
; @param ReasonKey {String} Page locale key of the window's failure.
; @param Icon {String} Modal box icon option.
_Updater_ReportInstallFailure(MessageKey, ReasonKey, Icon := "Icon!", FailureReceipt := 0) {
	if _Updater_NotifyInstallPhase("failed", ReasonKey, FailureReceipt)
		return
	Ui_MsgBox(t(MessageKey), t("updater.window_title"), Icon)
}

; Whether the staging worker's ERR line is a refused verification (a missing or
; different SHA-256 digest, an executable too small to be one) rather than a
; failed or truncated download.
; @param Stdout {String}
; @returns {Boolean}
_Updater_StagingFailureIsVerification(Stdout) {
	return (Stdout is String) && (InStr(Stdout, "SHA-256") || InStr(Stdout, "too small"))
}


; Configures only native callbacks. The UI translates the shared contract's
; safe report; neither the envelope nor the retained owner is a page payload.
Updater_ConfigureManagedFailurePresenter(Contract, Presenter, RetireFn := 0) {
	global _UpdaterManagedFailureContract, _UpdaterManagedFailurePresenter
	global _UpdaterManagedFailureRetireFn
	if !HasMethod(Contract, "Classify") || !HasMethod(Contract, "Actions")
		|| !HasMethod(Presenter, "Call")
		throw TypeError("Invalid managed updater failure presenter")
	_UpdaterManagedFailureContract := Contract
	_UpdaterManagedFailurePresenter := Presenter
	_UpdaterManagedFailureRetireFn := RetireFn
}

_Updater_GetManagedFailureOwner() {
	global _UpdaterManagedFailureOwner
	return _UpdaterManagedFailureOwner
}

; Versions binds its own private request and original release at dispatch; a
; newer menu failure cannot become that window's safe report or retry owner.
_Updater_GetManagedFailureOwnerFor(Request, Release) {
	Owner := _Updater_GetManagedFailureOwner()
	if !_Updater_ManagedFailureOwnerIsCurrent(Owner) || Type(Release) != "Object"
		|| !Release.HasProp("RawJson") || !Release.HasProp("Tag")
		|| Owner["request"] != Request
		|| !(Release.RawJson is String) || !(Release.Tag is String)
		|| StrCompare(Owner["release"].RawJson, Release.RawJson, true) != 0
		|| StrCompare(Owner["release"].Tag, Release.Tag, true) != 0
		return 0
	return Owner
}

_Updater_ExactFailureField(Record, Name, Default := 0) {
	if !(Record is Map)
		return Default
	for Key, Value in Record
		if Key is String && StrCompare(Key, Name, true) == 0
			return Value
	return Default
}

; Parsing is after the existing epoch and process-completion fences. Unknown,
; malformed or extra worker fields can never turn stdout text into a diagnosis.
; The JSON codec maps both booleans and numbers to AHK integers. Admit this
; private flag from its actual top-level JSON token, never from truthiness or
; a regex that can borrow text from a nested receipt string.
_Updater_StagingNativeDebtToken(Stdout) {
	NativeDebt := false
	Seen := Map()
	Seen.CaseSense := "On"
	Position := 1
	_JsonSkipWs(&Stdout, &Position)
	Position += 1
	loop {
		_JsonSkipWs(&Stdout, &Position)
		if SubStr(Stdout, Position, 1) == "}"
			return NativeDebt
		Key := _JsonParseString(&Stdout, &Position, true)
		if Seen.Has(Key)
			throw ValueError("Duplicate private staging envelope field")
		Seen[Key] := true
		_JsonSkipWs(&Stdout, &Position)
		Position += 1
		_JsonSkipWs(&Stdout, &Position)
		Start := Position
		_JsonParseValue(&Stdout, &Position, 1)
		if StrCompare(Key, "native_cleanup_debt", true) == 0 {
			Token := SubStr(Stdout, Start, Position - Start)
			if StrCompare(Token, "true", true) == 0
				NativeDebt := true
			else if StrCompare(Token, "false", true) == 0
				NativeDebt := false
			else
				throw ValueError("Native cleanup flag is not a JSON boolean")
		}
		_JsonSkipWs(&Stdout, &Position)
		if SubStr(Stdout, Position, 1) == ","
			Position += 1
	}
}

_Updater_ParseStagingFailure(Stdout) {
	global _UpdaterManagedFailureContract
	Unknown := Map("valid", false, "reason", "download", "receipt", Map(), "cleanup_debt", [], "native_cleanup_debt", false)
	if !(Stdout is String) || StrLen(Stdout) > 4096 || _ManagedNetworkWindows_HasStoredNul(Stdout)
		return Unknown
	try Envelope := JsonParse(Stdout)
	catch
		return Unknown
	if !(Envelope is Map) || Envelope.Count < 5 || Envelope.Count > 7
		return Unknown
	for Key in Envelope
		if !(Key is String) || !RegExMatch(Key, "^(?:schema_version|state|operation|reason|receipt|cleanup_debt|native_cleanup_debt)$")
			return Unknown
	try NativeDebt := _Updater_StagingNativeDebtToken(Stdout)
	catch
		return Unknown
	Version := _Updater_ExactFailureField(Envelope, "schema_version")
	State := _Updater_ExactFailureField(Envelope, "state")
	Operation := _Updater_ExactFailureField(Envelope, "operation")
	if !(Version is Integer) || Version != 1 || !(State is String) || !(Operation is String)
		|| StrCompare(State, "failed", true) != 0 || StrCompare(Operation, "download", true) != 0
		return Unknown
	Reason := _Updater_ExactFailureField(Envelope, "reason", "")
	if !(Reason is String) || (StrCompare(Reason, "download", true) != 0
		&& StrCompare(Reason, "verify", true) != 0 && StrCompare(Reason, "deadline", true) != 0)
		return Unknown
	Contract := _UpdaterManagedFailureContract
	Admitted := _Updater_AdmitStagingReceipt(_Updater_ExactFailureField(Envelope, "receipt"), Contract)
	if !(Admitted is Map)
		return Unknown
	Debt := []
	if _Updater_ExactFailureField(Envelope, "cleanup_debt", -1) != -1 {
		RawDebt := _Updater_ExactFailureField(Envelope, "cleanup_debt")
		if !(RawDebt is Array) || RawDebt.Length > 6
			return Unknown
		for Entry in RawDebt {
			if !(Entry is Map) || Entry.Count != 2
				return Unknown
			Resource := _Updater_ExactFailureField(Entry, "resource")
			if !(Resource is String) || !RegExMatch(Resource,
				"^(?:request|output|input|response|staged_executable|swap_worker)$")
				return Unknown
			CleanReceipt := _Updater_AdmitStagingReceipt(_Updater_ExactFailureField(Entry, "receipt"), Contract)
			if !(CleanReceipt is Map)
				return Unknown
			Debt.Push(Map("resource", Resource, "receipt", CleanReceipt))
		}
	}
	return Map("valid", true, "reason", Reason, "receipt", Admitted, "cleanup_debt", Debt, "native_cleanup_debt", NativeDebt)
}

_Updater_AdmitStagingReceipt(Receipt, Contract) {
	if !(Receipt is Map) || Receipt.Count > 16
		return 0
	if !HasMethod(Contract, "Classify") || !Contract.HasProp("Policy")
		return Map()
	Admitted := Map()
	Admitted.CaseSense := "On"
	for Field, Value in Receipt {
		Definition := _ManagedNetwork_Get(Contract.Policy["fields"], Field)
		if !(Definition is Map) || !_ManagedNetwork_Scalar(Value, Definition)
			|| (Value is String && StrLen(Value) > 128)
			return 0
		Admitted[Field] := Value
	}
	return Admitted
}

_Updater_NewManagedFailureOwner(Release, Request, AssetUrl, Digest, StagingEpoch, ExpectedObserver := unset) {
	global _UpdaterInstallObserver
	if !_Updater_RequestContextValid(Request) || Type(Release) != "Object"
		|| !Release.HasProp("RawJson") || !Release.HasProp("Tag")
		return 0
	return Map("release", { RawJson: Release.RawJson, Tag: Release.Tag },
		"request", Request, "asset_url", AssetUrl, "digest", Digest,
		"staging_epoch", StagingEpoch, "terminal", false, "retired", false,
		"install_observer", IsSet(ExpectedObserver) ? ExpectedObserver : _UpdaterInstallObserver)
}

_Updater_DispatchManagedFailureRetirement(Owner) {
	global _UpdaterManagedFailureRetireFn
	if HasMethod(_UpdaterManagedFailureRetireFn, "Call") {
		try _UpdaterManagedFailureRetireFn.Call(Owner)
		catch as Err
			try LoggerWarn("Updater", "Managed failure retirement callback raised {1}; the old owner remains revoked.", Type(Err))
	}
}

_Updater_RetireManagedFailure(ExpectedOwner := unset) {
	global _UpdaterManagedFailureOwner
	PreviousCritical := Critical("On")
	try {
		Owner := _UpdaterManagedFailureOwner
		if IsSet(ExpectedOwner) && (!(Owner is Map) || Owner != ExpectedOwner)
			return false
		_UpdaterManagedFailureOwner := 0
		if Owner is Map
			Owner["retired"] := true
	} finally {
		Critical(PreviousCritical)
	}
	if Owner is Map
		TimerSetCallback(_Updater_DispatchManagedFailureRetirement.Bind(Owner), -1)
	return true
}

; Old pause/channel generations and a newer same-tag request cannot borrow this
; terminal request's release identity or consent, even if its dialog stays open.
_Updater_ManagedFailureOwnerIsCurrent(Owner) {
	global _UpdaterManagedFailureOwner, _UpdaterSelfUpdateEpoch
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker, _UpdaterSwapOwner
	global _UpdaterRecoveryPublishTarget, UPDATER_REQUEST_POLICY_ALLOW
	if !(Owner is Map) || !(_UpdaterManagedFailureOwner is Map)
		|| Owner != _UpdaterManagedFailureOwner || !Owner.Get("terminal", false)
		|| Owner.Get("retired", true) || Owner.Get("staging_epoch", 0) != _UpdaterSelfUpdateEpoch
		|| _UpdaterDownloadInProgress || IsObject(_UpdaterDownloadWorker)
		|| (_UpdaterSwapOwner is Map) || _UpdaterRecoveryPublishTarget != ""
		return false
	return _Updater_RequestPolicy(Owner["request"]) == UPDATER_REQUEST_POLICY_ALLOW
}

_Updater_RetryManagedFailure(Owner, Observer := unset) {
	global BUNDLE_RELEASE_ASSET, _UpdaterInstallObserver
	if !_Updater_ManagedFailureOwnerIsCurrent(Owner)
		return false
	Release := Owner["release"]
	Asset := _Updater_FindAsset(Release.RawJson, BUNDLE_RELEASE_ASSET, Release.Tag)
	if !IsObject(Asset) || StrCompare(Asset.Url, Owner["asset_url"], true) != 0
		|| StrCompare(Asset.Digest, Owner["digest"], true) != 0
		|| !_Updater_ManagedFailureOwnerIsCurrent(Owner)
		return false
	; The existing Critical reservation compares and claims this exact owner.
	return _Updater_StartObservedInstall(Release, IsSet(Observer) ? Observer : _UpdaterInstallObserver, Owner["request"], Owner) == true
}

_Updater_PublishManagedFailure(Failure, Owner, StagingEpoch) {
	global _UpdaterManagedFailureOwner, _UpdaterManagedFailurePresenter
	global _UpdaterSelfUpdateEpoch, _UpdaterInstallObserver
	Observer := Owner is Map ? Owner.Get("install_observer", 0) : _UpdaterInstallObserver
	if Failure.Get("native_cleanup_debt", false)
		try LoggerWarn("Updater", "Staging reported native resolver retirement debt; its owned process tree has physically retired.")
	if Failure.Get("cleanup_debt", []).Length > 0
		try LoggerWarn("Updater", "Staging reported {1} cleanup refusal(s); its process tree has physically retired.",
			Failure["cleanup_debt"].Length)
	if !_Updater_EndDownloadTransaction(StagingEpoch)
		return false
	PreviousCritical := Critical("On")
	try {
		if _UpdaterSelfUpdateEpoch != StagingEpoch
			return false
		if Owner is Map && Owner["staging_epoch"] == StagingEpoch {
			Owner["terminal"] := true
			Owner["failure"] := Failure
			_UpdaterManagedFailureOwner := Owner
		}
	} finally {
		Critical(PreviousCritical)
	}
	if Owner is Map && !_Updater_ManagedFailureOwnerIsCurrent(Owner)
		return false
	if Failure["reason"] == "verify" {
		if !_Updater_NotifyInstallPhase("failed", "changelog_window.install_error_verify",
			Failure["receipt"], Observer)
			Ui_MsgBox(t("updater.install_error_download"), t("updater.window_title"), "Icon!")
		return true
	}
	Observed := _Updater_NotifyInstallPhase("failed",
		"changelog_window.install_error_download", Failure["receipt"], Observer)
	if Owner is Map && !_Updater_ManagedFailureOwnerIsCurrent(Owner)
		return false
	if !Observed && HasMethod(_UpdaterManagedFailurePresenter, "Call") {
		try {
			if _UpdaterManagedFailurePresenter.Call(Failure, Owner) == true
				return true
		}
	}
	if !Observed
		Ui_MsgBox(t("updater.install_error_download"), t("updater.window_title"), "Icon!")
	return true
}

; Dispatches the whole staging transaction to a child process. AHK's one
; interpreter thread is also the keyboard hook thread, so response-body COM,
; disk persistence, integrity checks and swap-script creation must never run here.
; This side only validates the request, launches/polls the worker and performs
; the final non-blocking process hand-off after the worker reports READY.
_Updater_TryReserveDownloadTransaction(Request, BoundarySuspended, ExpectedFailureOwner := 0) {
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	global _UpdaterDownloadRequest, _UpdaterRecoveryPublishTarget
	global _UpdaterDownloadStartedTick
	global UPDATER_REQUEST_POLICY_ALLOW
	Outcome := {
		Reserved: false,
		ShouldDrop: false,
		RecoveryBusy: false,
		DuplicateDownload: false,
		RetryStale: false,
		Epoch: 0
	}
	PreviousCritical := Critical("On")
	try {
		if ExpectedFailureOwner is Map && (!_Updater_ManagedFailureOwnerIsCurrent(ExpectedFailureOwner)
			|| ExpectedFailureOwner["request"] != Request) {
			Outcome.RetryStale := true
		} else if (_Updater_RequestPolicy(Request, BoundarySuspended)
			!= UPDATER_REQUEST_POLICY_ALLOW) {
			Outcome.ShouldDrop := true
		} else if (_UpdaterRecoveryPublishTarget != "") {
			Outcome.RecoveryBusy := true
		} else if _UpdaterDownloadInProgress {
			Outcome.DuplicateDownload := true
		} else {
			if ExpectedFailureOwner is Map
				_Updater_RetireManagedFailure(ExpectedFailureOwner)
			else
				_Updater_RetireManagedFailure()
			_UpdaterDownloadInProgress := true
			Outcome.Epoch := ++_UpdaterSelfUpdateEpoch
			_UpdaterDownloadRequest := Request
			_UpdaterDownloadStartedTick := A_TickCount
			Outcome.Reserved := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	return Outcome
}

; Opens the lifecycle pair before publishing a cancellable owner. Logger sinks
; can pump lifecycle callbacks: if START itself is interrupted by Pause, there
; is deliberately no transaction for cancellation to terminate. The resumed
; reservation then observes stale provenance and closes START with WARNING.
_Updater_BeginDownloadTransaction(Request, BoundarySuspended, Tag, AssetUrl, ExpectedFailureOwner := 0) {
	try LoggerStart("Updater", "Downloading update '{1}' from {2}…", Tag, AssetUrl)
	try {
		Outcome := _Updater_TryReserveDownloadTransaction(
			Request, BoundarySuspended, ExpectedFailureOwner)
	} catch as Err {
		try LoggerError("Updater", "Download reservation failed after START: {1}.", Err.Message)
		throw Err
	}
	if Outcome.Reserved
		return Outcome
	if Outcome.RetryStale {
		try LoggerWarn("Updater", "Download retry cancelled because its exact terminal owner changed.")
	} else if Outcome.ShouldDrop {
		try LoggerWarn("Updater", "Download start cancelled before reservation because request policy changed.")
	} else if Outcome.RecoveryBusy {
		try LoggerWarn("Updater", "Update reservation refused while rollback recovery became active.")
	} else if Outcome.DuplicateDownload {
		try LoggerWarn("Updater", "Download reservation lost to a concurrent install request.")
	} else {
		try LoggerError("Updater", "Download reservation returned no terminal classification after START.")
	}
	return Outcome
}

Updater_DownloadAndInstall(Release, Request := unset, IsSuspended := unset, RebuildFn := 0, NotifyFn := 0, ExpectedFailureOwner := 0) {
	global BUNDLE_RELEASE_ASSET
	global _UpdaterDownloadInProgress
	global _UpdaterRecoveryPublishTarget, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterInstallObserver
	InstallObserver := _UpdaterInstallObserver
	HasSuspendOverride := IsSet(IsSuspended)
	if !IsSet(Request) {
		if (HasSuspendOverride ? IsSuspended : A_IsSuspended)
			return _Updater_RefuseManualWhileSuspended(NotifyFn)
		Request := HasSuspendOverride
			? _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL, IsSuspended)
			: _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	}
	if (_Updater_RequestContextValid(Request) and Request.BornSuspended)
		return _Updater_RefuseManualWhileSuspended(NotifyFn)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
			return false
	} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
		return false
	}
	ActionOwner := _Updater_AcquireAsyncActionLease(
		"Update install", NotifyFn)
	if !IsObject(ActionOwner)
		return false
	try {
	if (_UpdaterRecoveryPublishTarget != "") {
		try LoggerWarn("Updater", "Update-now refused while the rollback recovery lease is repairing the canonical executable.")
		if HasSuspendOverride {
			if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
				return false
		} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
			return false
		}
		_Updater_ReportInstallFailure("updater.install_error", "changelog_window.install_error_busy")
		return false
	}
	if (Type(Release) != "Object" or !Release.HasProp("RawJson")) {
		try LoggerError("Updater", "Install request refused malformed release data.")
		if HasSuspendOverride {
			if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
				return false
		} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
			return false
		}
		_Updater_ReportInstallFailure("updater.install_error", "changelog_window.install_error_unexpected")
		return false
	}
	; Re-entrancy guard: two independent "Update now" triggers (the TrayTip
	; update prompt and the changelog's "Install this version" button, each
	; opening its own dialog) can both reach this function before the first
	; download finishes. Without this check both open a second async WinHTTP
	; request against the SAME staging file, and the two eventual stream
	; writes to disk race with no lock, risking a corrupted or truncated exe
	; that the swap script then moves into production
	; (updater-download-reentrancy).
	if _UpdaterDownloadInProgress {
		try LoggerWarn("Updater", "Download already in progress -- ignoring duplicate Updater_DownloadAndInstall call.")
		_Updater_NotifyInstallPhase("failed", "changelog_window.install_error_busy")
		return false
	}
	AssetName := IsSet(BUNDLE_RELEASE_ASSET) and BUNDLE_RELEASE_ASSET != ""
		? BUNDLE_RELEASE_ASSET : "ErgoptiPlus.exe"
	Asset := _Updater_FindAsset(Release.RawJson, AssetName, Release.Tag)
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
			return false
	} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
		return false
	}
	if !IsObject(Asset) {
		try LoggerError("Updater", "No authenticated asset named '{1}' in release '{2}'.", AssetName, Release.Tag)
		if HasSuspendOverride {
			if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
				return false
		} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
			return false
		}
		_Updater_ReportInstallFailure("updater.install_error_no_asset", "changelog_window.install_error_no_asset")
		return false
	}
	AssetUrl := Asset.Url
	if Updater_IsLocalSource() {
		; Running from source — replacing the .ahk would be wrong, and the
		; user is almost certainly developing on this very tree. Bail with a
		; friendly note rather than silently doing nothing.
		if HasSuspendOverride {
			if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
				return false
		} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
			return false
		}
		_Updater_ReportInstallFailure("updater.install_local_source", "changelog_window.install_error_unexpected", "Iconi")
		return false
	}

	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
			return false
	} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
		return false
	}
	LocalAppData := ResolveLocalAppDataDir()
	if HasSuspendOverride {
		if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
			return false
	} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
		return false
	}
	if (LocalAppData == "") {
		_Updater_ReportInstallFailure("updater.install_error", "changelog_window.install_error_install")
		return false
	}
	StagingDir := LocalAppData . "\Ergopti\updates"
	NewExe := StagingDir . "\ErgoptiPlus_new.exe"
	SwapScriptPath := StagingDir . "\swap_update.ps1"
	CurrentExe := A_ScriptFullPath
	; START precedes owner publication. A logger sink can pump Pause; that callback
	; must see no transaction until START has returned and the reservation below
	; atomically claims the exact request + epoch.
	BoundarySuspended := HasSuspendOverride ? IsSuspended : A_IsSuspended
	Reservation := _Updater_BeginDownloadTransaction(
		Request, BoundarySuspended, Release.Tag, AssetUrl, ExpectedFailureOwner)
	if Reservation.RetryStale
		return false
	if Reservation.ShouldDrop {
		_Updater_RequestMayPublish(Request, BoundarySuspended, NotifyFn)
		return false
	}
	if Reservation.RecoveryBusy {
		if _Updater_RequestMayPublish(Request, BoundarySuspended, NotifyFn)
			_Updater_ReportInstallFailure("updater.install_error", "changelog_window.install_error_busy")
		return false
	}
	if Reservation.DuplicateDownload {
		_Updater_NotifyInstallPhase("failed", "changelog_window.install_error_busy")
		return false
	}
	if !Reservation.Reserved
		return false
	StagingEpoch := Reservation.Epoch
	if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
		return false
	if !_Updater_RegisterDownloadArtifacts(StagingEpoch, NewExe, SwapScriptPath) {
		_Updater_EndDownloadTransaction(StagingEpoch)
		return false
	}

	_Updater_StartStagingWorker(AssetUrl, Asset.Digest, NewExe, SwapScriptPath,
		CurrentExe, Release.Tag, StagingEpoch, Release, Request, InstallObserver, Asset.Size)
	if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
		return false
	if IsObject(RebuildFn)
		RebuildFn.Call()
	else
		_Updater_ScheduleMenuRebuildForRequest(Request)
	return true
	} finally {
		_Updater_ReleaseAsyncActionLease(ActionOwner)
	}
}


; Starts an isolated PowerShell transaction. ShellRunner owns process polling,
; preventing a slow CDN, antivirus scan or file flush from entering AHK's hook
; dispatch loop.
; PowerShell -EncodedCommand requires UTF-16LE before Base64. The shared crypto
; adapter emits Base64 without CR/LF, so both the worker payload and bootstrap
; satisfy ShellRunner's single-line cmd.exe transport.
_Updater_EncodePowerShellCommand(Command) {
	if Type(Command) != "String"
		throw TypeError("PowerShell command must be a String")
	ByteCount := StrLen(Command) * 2
	if ByteCount <= 0
		return ""
	Bytes := Buffer(ByteCount, 0)
	DllCall("RtlMoveMemory", "Ptr", Bytes.Ptr, "Ptr", StrPtr(Command),
		"UPtr", ByteCount)
	return CryptoBase64Encode(Bytes)
}

_Updater_PowerShellPath() {
	return A_WinDir . "\System32\WindowsPowerShell\v1.0\powershell.exe"
}

; The persisted swap script is transported as UTF-8 data, not as an encoded
; PowerShell command. UTF-8 keeps the independent environment payload below the
; inherited-value budget while the staging worker writes the exact bytes that
; Windows PowerShell later reads from the .ps1 file.
_Updater_EncodeUtf8Payload(Text) {
	if Type(Text) != "String"
		throw TypeError("UTF-8 payload must be a String")
	return CryptoBase64EncodeUtf8(Text)
}

; Publish the large multi-line worker and its argv under unique inherited
; environment names, then pass only a small single-line bootstrap to cmd.exe.
; This avoids synchronous script-file I/O on the menu thread and preserves
; release metadata as data rather than interpolating it into PowerShell syntax.
_Updater_BuildStagingTransport(Script, SwapScript, AssetUrl, ExpectedSha256, NewExe,
	SwapScriptPath, CurrentExe,
	MinimumSize, TimeoutMs, DownloadModulePath := "", DeadlineMs := 0, StartedTick := 0,
	ProxyPolicyPath := "", UpdaterDefaultsPath := "", AuthenticatedSize := 0) {
	global _UpdaterStagingTransportCounter, UPDATER_STAGING_ENV_MAX_CHARS, UPDATER_STAGING_MAX_SCRIPT_CHUNKS
	_UpdaterStagingTransportCounter += 1
	Prefix := "ERGOPTI_UPDATER_" . DllCall("GetCurrentProcessId", "UInt")
		. "_" . A_TickCount . "_" . _UpdaterStagingTransportCounter
	ScriptPayload := _Updater_EncodePowerShellCommand(Script)
	SwapScriptPayload := _Updater_EncodeUtf8Payload(SwapScript)
	ScriptChunkCount := Ceil(StrLen(ScriptPayload) / UPDATER_STAGING_ENV_MAX_CHARS)
	if (ScriptPayload == "" or ScriptChunkCount > UPDATER_STAGING_MAX_SCRIPT_CHUNKS)
		throw ValueError("Encoded staging worker exceeds the bounded chunk transport budget")
	if (SwapScriptPayload == "")
		throw ValueError("Encoded swap worker is empty")
	Environment := [
		{ Name: Prefix . "_SCRIPT", Value: SubStr(ScriptPayload, 1, UPDATER_STAGING_ENV_MAX_CHARS) },
		{ Name: Prefix . "_URL", Value: AssetUrl },
		{ Name: Prefix . "_DIGEST", Value: ExpectedSha256 },
		{ Name: Prefix . "_NEW_EXE", Value: NewExe },
		{ Name: Prefix . "_SWAP_PATH", Value: SwapScriptPath },
		{ Name: Prefix . "_CURRENT", Value: CurrentExe },
		{ Name: Prefix . "_MINIMUM", Value: MinimumSize },
		{ Name: Prefix . "_TIMEOUT", Value: TimeoutMs },
		{ Name: Prefix . "_DOWNLOAD_MODULE", Value: DownloadModulePath },
		{ Name: Prefix . "_DEADLINE", Value: DeadlineMs },
		{ Name: Prefix . "_STARTED_TICK", Value: StartedTick },
		{ Name: Prefix . "_PROXY_POLICY", Value: ProxyPolicyPath },
		{ Name: Prefix . "_UPDATER_DEFAULTS", Value: UpdaterDefaultsPath },
		{ Name: Prefix . "_AUTHENTICATED_SIZE", Value: AuthenticatedSize }
	]
	Environment.Push({ Name: Prefix . "_SCRIPT_COUNT", Value: ScriptChunkCount })
	Loop ScriptChunkCount - 1 {
		ChunkNumber := A_Index + 1
		Environment.Push({
			Name: Prefix . "_SCRIPT_" . ChunkNumber,
			Value: SubStr(ScriptPayload, ((ChunkNumber - 1) * UPDATER_STAGING_ENV_MAX_CHARS) + 1,
				UPDATER_STAGING_ENV_MAX_CHARS)
		})
	}
	SwapChunkCount := Ceil(StrLen(SwapScriptPayload)
		/ UPDATER_STAGING_ENV_MAX_CHARS)
	Environment.Push({ Name: Prefix . "_SWAP_COUNT", Value: SwapChunkCount })
	Loop SwapChunkCount {
		ChunkOffset := ((A_Index - 1) * UPDATER_STAGING_ENV_MAX_CHARS) + 1
		Environment.Push({
			Name: Prefix . "_SWAP_" . A_Index,
			Value: SubStr(SwapScriptPayload, ChunkOffset,
				UPDATER_STAGING_ENV_MAX_CHARS)
		})
	}
	for Pair in Environment {
		if StrLen(Pair.Value) > UPDATER_STAGING_ENV_MAX_CHARS
			throw ValueError("Staging environment value exceeds the cmd.exe inheritance budget")
	}
	Bootstrap := '$ErrorActionPreference=' . Chr(39) . 'Stop' . Chr(39) . ';'
		. '$ProgressPreference=' . Chr(39) . 'SilentlyContinue' . Chr(39) . ';'
		. '$scriptPayload=$env:' . Prefix . '_SCRIPT;'
		. 'for($i=2;$i -le [int]$env:' . Prefix . '_SCRIPT_COUNT;$i++){$scriptPayload+=[Environment]::GetEnvironmentVariable(' . Chr(39) . Prefix . '_SCRIPT_' . Chr(39) . '+$i)};'
		. '$source=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($scriptPayload));'
		. '$swapPayload=' . Chr(39) . Chr(39) . ';'
		. 'for($i=1;$i -le [int]$env:' . Prefix . '_SWAP_COUNT;$i++){$swapPayload+=[Environment]::GetEnvironmentVariable(' . Chr(39) . Prefix . '_SWAP_' . Chr(39) . '+$i)};'
		. '$worker=[ScriptBlock]::Create($source);'
		. '& $worker $env:' . Prefix . '_URL $env:' . Prefix . '_DIGEST $env:' . Prefix . '_NEW_EXE $env:' . Prefix . '_SWAP_PATH $env:' . Prefix . '_CURRENT'
		. ' ([int64]$env:' . Prefix . '_MINIMUM) ([int]$env:' . Prefix . '_TIMEOUT'
		. ') $swapPayload $env:' . Prefix . '_DOWNLOAD_MODULE ([int]$env:' . Prefix . '_DEADLINE) ([int64]$env:' . Prefix . '_STARTED_TICK) $env:' . Prefix . '_PROXY_POLICY $env:' . Prefix . '_UPDATER_DEFAULTS -AuthenticatedSize ([int64]$env:' . Prefix . '_AUTHENTICATED_SIZE)'
	Args := ["-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
		"-EncodedCommand", _Updater_EncodePowerShellCommand(Bootstrap)]
	for Arg in Args {
		if (InStr(Arg, "`n") or InStr(Arg, "`r"))
			throw ValueError("Encoded staging transport unexpectedly contains a newline")
	}
	Published := []
	try {
		for Pair in Environment {
			EnvSet(Pair.Name, Pair.Value)
			Published.Push(Pair.Name)
		}
	} catch {
		for Name in Published
			try EnvSet(Name, "")
		throw
	}
	return {
		Args: Args,
		Environment: Environment,
		ScriptPayload: ScriptPayload,
		ScriptChunkCount: ScriptChunkCount,
		SwapScriptPayload: SwapScriptPayload,
		SwapChunkCount: SwapChunkCount,
		Bootstrap: Bootstrap
	}
}

_Updater_ClearStagingTransport(Transport) {
	if (Type(Transport) != "Object" or !Transport.HasOwnProp("Environment"))
		return
	for Pair in Transport.Environment
		try EnvSet(Pair.Name, "")
}

_Updater_StartStagingWorker(AssetUrl, ExpectedSha256, NewExe, SwapScriptPath, CurrentExe, Tag, StagingEpoch, Release := 0, Request := 0, InstallObserver := unset, AuthenticatedSize := 0) {
	global _UpdaterDownloadWorker, UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS, UPDATER_MIN_EXE_SIZE_BYTES
	global _VendorDir, _SharedDir, UPDATER_HTTP_DOWNLOAD_DEADLINE_MS, _UpdaterDownloadStartedTick
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	StagingScript := _Updater_BuildStagingWorkerScript()
	SwapScript := _Updater_BuildSwapWorkerScript()
	FailureOwner := IsSet(InstallObserver)
		? _Updater_NewManagedFailureOwner(Release, Request, AssetUrl,
			ExpectedSha256, StagingEpoch, InstallObserver)
		: _Updater_NewManagedFailureOwner(Release, Request, AssetUrl,
			ExpectedSha256, StagingEpoch)
	_OnDone := (ExitCode, Stdout, Stderr) => _Updater_PollDownloadAsync(
		ExitCode, Stdout, Stderr, SwapScriptPath, NewExe, CurrentExe, Tag,
		StagingEpoch, FailureOwner)
	Transport := 0
	Worker := 0
	Started := false
	Published := false
	StartError := ""
	try {
		Transport := _Updater_BuildStagingTransport(
			StagingScript, SwapScript, AssetUrl, ExpectedSha256, NewExe, SwapScriptPath, CurrentExe,
			UPDATER_MIN_EXE_SIZE_BYTES, UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS,
			_VendorDir . "\ergopti_updater_download.ps1", UPDATER_HTTP_DOWNLOAD_DEADLINE_MS,
			_UpdaterDownloadStartedTick,
			_SharedDir . "\modules\network\proxy_policy.json",
			_SharedDir . "\modules\updater\defaults.json", AuthenticatedSize)
		if _Updater_SelfUpdateEpochIsCurrent(StagingEpoch) {
			Worker := ShellRunner_SpawnTreeOwned(
				_Updater_PowerShellPath(), Transport.Args, _OnDone)
			PreviousCritical := Critical("On")
			try {
				if (_UpdaterDownloadInProgress
					and _UpdaterSelfUpdateEpoch == StagingEpoch) {
					_UpdaterDownloadWorker := Worker
					Published := true
				}
			} finally {
				Critical(PreviousCritical)
			}
			if Published
				Started := IsObject(Worker) and Worker.start()
			else if IsObject(Worker)
				try Worker.terminate()
		}
	} catch as Err {
		StartError := Err.Message
	} finally {
		; Run/CreateProcess has already inherited the values when start() returns.
		; Clear the parent copy immediately so secrets and paths do not linger.
		_Updater_ClearStagingTransport(Transport)
	}
	if !Started {
		PreviousCritical := Critical("On")
		try {
			if (IsObject(Worker) and IsObject(_UpdaterDownloadWorker)
				and _UpdaterDownloadWorker == Worker)
				_UpdaterDownloadWorker := 0
		} finally {
			Critical(PreviousCritical)
		}
		if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
			return
		if StartError != "" {
			try LoggerError("Updater", "Could not prepare or launch the isolated update staging worker: {1}.", StartError)
		} else {
			try LoggerError("Updater", "Could not launch the isolated update staging worker.")
		}
		_Updater_ReportInstallFailure("updater.install_error_download", "changelog_window.install_error_download")
		_Updater_EndDownloadTransaction(StagingEpoch)
		return
	}
	SetTimer(_Updater_MonitorStagingWorker, UPDATER_ASYNC_POLL_MS)
}

; Cancels the subprocess while native Suspend is active. ShellRunner deliberately
; defers completion callbacks during Suspend, so this independent timer enforces
; the stronger invariant that no network or staging I/O remains alive while paused.
_Updater_MonitorStagingWorker(*) {
	global _UpdaterDownloadInProgress
	if !_UpdaterDownloadInProgress {
		SetTimer(_Updater_MonitorStagingWorker, 0)
		return
	}
	if !A_IsSuspended
		return _Updater_EnforceDownloadDeadline()
	_Updater_CancelSelfUpdateForSuspend()
}

_Updater_SelfUpdateEpochIsCurrent(StagingEpoch) {
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	PreviousCritical := Critical("On")
	try return _UpdaterDownloadInProgress
		and _UpdaterSelfUpdateEpoch == StagingEpoch
	finally Critical(PreviousCritical)
}

_Updater_RegisterDownloadArtifacts(StagingEpoch, NewExe, SwapScriptPath) {
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	global _UpdaterDownloadArtifacts
	PreviousCritical := Critical("On")
	try {
		if (!_UpdaterDownloadInProgress
			or _UpdaterSelfUpdateEpoch != StagingEpoch)
			return false
		_UpdaterDownloadArtifacts := {
			NewExe: NewExe,
			SwapScript: SwapScriptPath
		}
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; Suspend entry is an event, not a state that a 250 ms poll may sample later.
; Take every in-process owner synchronously and invalidate queued READY callbacks
; before returning to the suspend transition. Native termination happens outside
; Critical, using each adapter/owner's exact process or Job handles.
_Updater_CancelSelfUpdateForSuspend() {
	return _Updater_CancelSelfUpdateTransaction(
		"Update transaction synchronously aborted on suspend entry.", true, true)
}

_Updater_QuiesceSelfUpdateForSuspend() {
	_Updater_CancelSelfUpdateForSuspend()
	return _Updater_RetrySwapCleanupDebt()
}

_Updater_CancelSelfUpdateTransaction(LogMessage, RebuildMenu := true, SurfacePausedRequest := false, ExpectedEpoch := 0) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterDownloadRequest
	global _UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterSelfUpdateEpoch
	Worker := 0
	Owner := 0
	Request := 0
	Artifacts := 0
	HadTransaction := false
	PreviousCritical := Critical("On")
	try {
		if ExpectedEpoch && _UpdaterSelfUpdateEpoch != ExpectedEpoch
			return false
		HadTransaction := _UpdaterDownloadInProgress
			or IsObject(_UpdaterDownloadWorker) or (_UpdaterSwapOwner is Map)
			or IsObject(_UpdaterDownloadRequest)
		Worker := IsObject(_UpdaterDownloadWorker) ? _UpdaterDownloadWorker : 0
		Owner := (_UpdaterSwapOwner is Map) ? _UpdaterSwapOwner : 0
		Request := IsObject(_UpdaterDownloadRequest) ? _UpdaterDownloadRequest : 0
		Artifacts := IsObject(_UpdaterDownloadArtifacts)
			? _UpdaterDownloadArtifacts : 0
		_UpdaterDownloadWorker := 0
		_UpdaterDownloadRequest := 0
		_UpdaterDownloadArtifacts := 0
		_UpdaterDownloadStartedTick := 0
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		_Updater_RetireManagedFailure()
		_UpdaterDownloadInProgress := false
		_UpdaterSelfUpdateEpoch += 1
	} finally {
		Critical(PreviousCritical)
	}
	if IsObject(Worker)
		try Worker.terminate()
	if (Owner is Map)
		_Updater_CloseSwapOwner(Owner, true)
	if IsObject(Artifacts) {
		for Name in ["NewExe", "SwapScript"] {
			Path := Artifacts.HasOwnProp(Name) ? Artifacts.%Name% : ""
			if (Path != "" and FSExists(Path) and !FSDelete(Path))
				try LoggerError("Updater", "Could not delete cancelled staging artifact '{1}'.", Path)
		}
	}
	SetTimer(_Updater_MonitorStagingWorker, 0)
	; Process teardown wins before the visible terminal. RequestMayPublish queues
	; exactly one manual notice for resume; a second cancellation has no Request.
	if SurfacePausedRequest and IsObject(Request)
		_Updater_RequestMayPublish(Request, true)
	if HadTransaction {
		try LoggerError("Updater", LogMessage)
		_Updater_NotifyInstallPhase("failed", "changelog_window.install_error_download")
		if RebuildMenu
			try TimerArmOneShotMs((*) => _Updater_RebuildMenu(), 50)
	}
	return HadTransaction
}

; Enforces one monotonic wall-clock budget for the entire hidden download
; process. This is independent from HttpWebRequest's per-operation timeouts.
_Updater_EnforceDownloadDeadline(NowTick := unset, RebuildMenu := true,
	NotifyFn := 0, CancelFn := _Updater_CancelSelfUpdateTransaction, ExpectedEpoch := 0) {
	global _UpdaterSelfUpdateEpoch, _UpdaterDownloadInProgress, _UpdaterDownloadStartedTick
	global UPDATER_HTTP_DOWNLOAD_DEADLINE_MS
	PreviousCritical := Critical("On")
	try {
		if ExpectedEpoch && (!_UpdaterDownloadInProgress || _UpdaterSelfUpdateEpoch != ExpectedEpoch)
			return false
		if !_UpdaterDownloadInProgress || !_UpdaterDownloadStartedTick
			return false
		StartedTick := _UpdaterDownloadStartedTick
	} finally {
		Critical(PreviousCritical)
	}
	if !IsSet(NowTick)
		NowTick := A_TickCount
	if !TickExpired64(StartedTick,
		UPDATER_HTTP_DOWNLOAD_DEADLINE_MS, NowTick)
		return false
	Cancelled := ExpectedEpoch
		? CancelFn.Call("Update download exceeded its absolute wall-clock deadline.",
			RebuildMenu, false, ExpectedEpoch)
		: CancelFn.Call("Update download exceeded its absolute wall-clock deadline.",
			RebuildMenu, false)
	if !Cancelled
		return false
	_Updater_SurfaceFailure("updater.install_error_download",
		"Absolute download deadline exceeded.", NotifyFn)
	return true
}

; State-only admission ends before any completion diagnostics, UI or native handoff.
_Updater_AdmitStagingCompletion(StagingEpoch) {
	global _UpdaterDownloadWorker
	PreviousCritical := Critical("On")
	try {
		if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
			return false
		_UpdaterDownloadWorker := 0
		TimerSetCallback(_Updater_MonitorStagingWorker, 0)
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; The only staging completion callback running in AHK. The worker's READY
; token means it has already persisted and verified the executable plus the
; UTF-8 PowerShell swap worker.
_Updater_PollDownloadAsync(ExitCode, Stdout, Stderr, SwapScriptPath, NewExe, CurrentExe, Tag, StagingEpoch, FailureOwner := 0, CompletionTick := unset, DeadlineNotifyFn := 0) {
	global _UpdaterDownloadWorker
	if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
		return
	; Completion can arrive after the deadline but before the monitor's tick.
	; Keep the exact worker/monitor until the original parent budget is admitted.
	NowTick := IsSet(CompletionTick) ? CompletionTick : A_TickCount
	if _Updater_EnforceDownloadDeadline(NowTick, true, DeadlineNotifyFn,
		_Updater_CancelSelfUpdateTransaction, StagingEpoch)
		return
	if !_Updater_AdmitStagingCompletion(StagingEpoch)
		return
	if A_IsSuspended {
		try LoggerWarn("Updater", "Update staging completion discarded while suspended.")
		_Updater_NotifyInstallPhase("failed", "changelog_window.install_error_download")
		_Updater_EndDownloadTransaction(StagingEpoch)
		return
	}
	if (ExitCode != 0 or Stdout != "READY") {
		try LoggerError("Updater", "Update staging worker failed (exit {1}); private output omitted.", ExitCode)
		Failure := _Updater_ParseStagingFailure(Stdout)
		_Updater_PublishManagedFailure(Failure, FailureOwner, StagingEpoch)
		return
	}
	try LoggerSuccess("Updater", "Update downloaded and verified for '{1}'.", Tag)
	_Updater_NotifyInstallPhase("installing")
	if !_Updater_StartSwapTransaction(SwapScriptPath, NewExe, CurrentExe, Tag,
		StagingEpoch) {
		if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
			return
		_Updater_ReportInstallFailure("updater.install_error", "changelog_window.install_error_install")
		_Updater_EndDownloadTransaction(StagingEpoch)
		return
	}
	_Updater_NotifyInstallPhase("restarting")
	global UPDATER_LAST_NOTIFIED_TAG := ""
}

; Returns the compact staging orchestrator. Trusted helper paths and release
; data use the private inherited environment, never PowerShell interpolation.
_Updater_BuildStagingWorkerScript() {
	return 'param([string]$Url, [string]$ExpectedSha256, [string]$NewExe, [string]$SwapScriptPath, [string]$CurrentExe, [int64]$MinimumSize, [int]$TimeoutMs, [string]$SwapScriptPayload, [string]$DownloadModulePath, [int]$DeadlineMs, [int64]$StartedTick, [string]$ProxyPolicyPath, [string]$UpdaterDefaultsPath, [scriptblock]$ReadConfig=$null, [scriptblock]$ReadEnvironment=$null, [int64]$AuthenticatedSize=0)' . "`n"
		. '$ErrorActionPreference = "Stop"' . "`n"
		. '$State=@{Stage="proxy_resolve";Reason="download";Receipt=@{};CleanupDebt=@()}' . "`n"
		. 'function CleanWorker($Path,$Name){try{[IO.File]::Delete($Path)}catch{if(Get-Command Add-ErgoptiUpdaterCleanupDebt -ErrorAction SilentlyContinue){Add-ErgoptiUpdaterCleanupDebt $State $Name "file_remove" $_.Exception}else{$State.CleanupDebt+=@{resource=$Name;receipt=@{backend="dotnet";stage="file_remove";failure_provenance="unknown"}}}}}' . "`n"
		. 'try {' . "`n"
		. '  . $DownloadModulePath' . "`n"
		. '  . (Join-Path (Split-Path -Parent $DownloadModulePath) "ergopti_network_routes.ps1")' . "`n"
		. '  $Resolver={param($Destination,$Budget) Resolve-ErgoptiNativeNetworkRoutes $Destination $Budget $ReadConfig $ReadEnvironment $ProxyPolicyPath $UpdaterDefaultsPath}' . "`n"
		. '  $Request=[System.Net.HttpWebRequest]::Create($Url)' . "`n"
		. '  $Request.ReadWriteTimeout = $TimeoutMs' . "`n"
		. '  if ($AuthenticatedSize -gt 0) {$ExpectedSize=Invoke-ErgoptiUpdaterCurlDownload ([Uri]$Url) $NewExe $TimeoutMs $State $Resolver $DeadlineMs $StartedTick $AuthenticatedSize $ProxyPolicyPath $UpdaterDefaultsPath $ReadEnvironment} else {$ExpectedSize=Invoke-ErgoptiUpdaterDownload $Request $NewExe $TimeoutMs $State $Resolver $DeadlineMs $StartedTick}' . "`n"
		. '  $State.Stage="file_read"' . "`n"
		. '  $ActualSize=(Get-Item -LiteralPath $NewExe).Length' . "`n"
		. '  if ($ExpectedSize -gt 0 -and $ActualSize -ne $ExpectedSize) { throw "Content-Length mismatch" }' . "`n"
		. '  if ($ActualSize -lt $MinimumSize) { $State.Reason="verify";throw "Downloaded file is too small" }' . "`n"
		. '  if ($ExpectedSha256 -cnotmatch "^[0-9a-f]{64}$") { $State.Reason="verify";throw "Missing or invalid trusted SHA-256 digest" }' . "`n"
		. '  $ActualDigest=& { $HashStream=$null; $Hasher=[Security.Cryptography.SHA256]::Create(); try { $HashStream=[IO.File]::Open($NewExe,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); [BitConverter]::ToString($Hasher.ComputeHash($HashStream)).Replace("-","").ToLowerInvariant() } finally { try { if ($null -ne $HashStream) { $HashStream.Dispose() } } finally { $Hasher.Dispose() } } }' . "`n"
		. '  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State' . "`n"
		. '  if ($ActualDigest -cne $ExpectedSha256) { $State.Reason="verify";throw "SHA-256 digest mismatch" }' . "`n"
		. '  $SwapSource=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SwapScriptPayload))' . "`n"
		. '  if ($AuthenticatedSize -le 0) {$State.Stage="file_remove";[IO.File]::Delete($SwapScriptPath)}' . "`n"
		. '  $State.Stage="file_write"' . "`n"
		. '  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State' . "`n"
		. '  if ($AuthenticatedSize -le 0) {[IO.File]::WriteAllText($SwapScriptPath,$SwapSource,[Text.UTF8Encoding]::new($false))} else {$SwapOutput=$null;try{$State.Stage="file_create";$SwapOutput=[IO.File]::Open($SwapScriptPath,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None);$State.SwapWorkerOwned=$true;$State.Stage="file_write";$SwapBytes=[Text.Encoding]::UTF8.GetBytes($SwapSource);$SwapOutput.Write($SwapBytes,0,$SwapBytes.Length);$SwapOutput.Flush($true)}finally{Close-ErgoptiUpdaterResource $SwapOutput "swap_worker" "file_write" $State}}' . "`n"
		. '  $null=Get-ErgoptiUpdaterRemainingMilliseconds $StartedTick $DeadlineMs $State' . "`n"
		. '  if ($State.NativeCleanupDebt -or $State.CleanupDebt.Count -ne 0) {throw "Staging resources have unacknowledged retirement"}' . "`n"
		. '  Write-Output "READY"' . "`n"
		. '  exit 0' . "`n"
		. '} catch {' . "`n"
		. '  $Receipt=@{}' . "`n"
		. '  if (Get-Command Get-ErgoptiUpdaterFailureReceipt -ErrorAction SilentlyContinue) { $Receipt=Get-ErgoptiUpdaterFailureReceipt $_.Exception $State }' . "`n"
		. '  if ($AuthenticatedSize -le 0 -or $State.StagedExecutableOwned) {CleanWorker $NewExe "staged_executable"}' . "`n"
		. '  if ($AuthenticatedSize -le 0 -or $State.SwapWorkerOwned) {CleanWorker $SwapScriptPath "swap_worker"}' . "`n"
		. '  @{schema_version=1;state="failed";operation="download";reason=$State.Reason;receipt=$Receipt;cleanup_debt=$State.CleanupDebt;native_cleanup_debt=[bool]$State.NativeCleanupDebt}|ConvertTo-Json -Depth 4 -Compress' . "`n"
		. '  exit 1' . "`n"
		. '}'
}

; The swapper is a separate PowerShell process because it must survive the AHK
; process whose executable it replaces. Its four-event protocol prevents any
; production-file mutation until AHK has passed every shutdown refusal gate and
; the inherited exact parent HANDLE proves that process has really exited.
_Updater_BuildSwapWorkerScript() {
	return 'param([string]$ReadyName,[string]$CommitName,[string]$AckName,[string]$FinalExitName,[int64]$ParentHandle,[string]$NewExe,[string]$CurrentExe,[int]$ProbationMs,[int]$BootReadyTimeoutMs,[int]$RestoreAttempts,[int]$RestoreRetryMs,[string]$DiagnosticPath)' . "`n"
		. '$ErrorActionPreference="Stop";$R=$null;$C=$null;$A=$null;$F=$null;$P=$null' . "`n"
		. 'function Diag($M){try{[IO.File]::AppendAllText($DiagnosticPath,$M+[Environment]::NewLine)}catch{}}' . "`n"
		. 'function RemoveBest($Path,$Label){try{if($Path -and [IO.File]::Exists($Path)){[IO.File]::Delete($Path)}}catch{Diag($Label+":"+$_.Exception.Message)}}' . "`n"
		. 'function WriteTerminal($Path,$Message){$Temp=$Path+".tmp";$Utf8=[Text.UTF8Encoding]::new($false);try{RemoveBest $Temp "terminal-temp";RemoveBest $Path "terminal-stale";$Clean=($Message -replace "[\r\n]+"," ");if($Clean.Length -gt 2000){$Clean=$Clean.Substring(0,2000)};[IO.File]::WriteAllText($Temp,$Clean,$Utf8);[IO.File]::Move($Temp,$Path)}finally{RemoveBest $Temp "terminal-temp-cleanup"}}' . "`n"
		. 'function PublishCopy($Source,$Destination){$Temp=$Destination+".tmp";try{RemoveBest $Temp "precopy-temp";if([IO.File]::Exists($Destination)){throw "Unique publish destination already exists"};[IO.File]::Copy($Source,$Temp,$false);$Expected=[IO.FileInfo]::new($Source).Length;if($Expected -le 0 -or [IO.FileInfo]::new($Temp).Length -ne $Expected){throw "Pre-copy size mismatch"};[IO.File]::Move($Temp,$Destination);if([IO.FileInfo]::new($Destination).Length -ne $Expected){throw "Published copy size mismatch"};return $Destination}finally{RemoveBest $Temp "precopy-temp-cleanup"}}' . "`n"
		. 'function WriteClaim($Claim,$Target,$Stage){$Temp=$Claim+".tmp";$Utf8=[Text.UTF8Encoding]::new($false);try{RemoveBest $Temp "claim-temp";RemoveBest $Claim "claim-stale";[IO.File]::WriteAllText($Temp,$Target+[Environment]::NewLine+$Stage,$Utf8);[IO.File]::Move($Temp,$Claim)}finally{RemoveBest $Temp "claim-temp-cleanup"}}' . "`n"
		. 'function StopExact($Process){if($null -eq $Process){return $true};try{$Exact=$Process.Handle;$Process.Refresh();if(!$Process.HasExited){$Process.Kill()};if(!$Process.WaitForExit(5000)){Diag("exact-stop-timeout");return $false};return $true}catch{Diag("exact-stop:"+$_.Exception.Message);return $false}}' . "`n"
		. 'function StartReady($Path,$TimeoutMs,$Probation,$AllowLauncherExit){$Event=$null;$Process=$null;$ProcessWait=$null;$OldReady=[Environment]::GetEnvironmentVariable("ERGOPTI_UPDATER_BOOT_READY");try{$EventName="Local\ErgoptiPlus.Updater.BootReady."+[Guid]::NewGuid().ToString("N");$Event=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset,$EventName);[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_BOOT_READY",$EventName);$Process=Start-Process -FilePath $Path -PassThru -WindowStyle Hidden;$Exact=$Process.Handle;if($AllowLauncherExit){if(!$Event.WaitOne($TimeoutMs)){throw "Canonical driver did not acknowledge recovery handoff"};return $Process};$ProcessWait=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset);$OldSafe=$ProcessWait.SafeWaitHandle;$ProcessWait.SafeWaitHandle=[Microsoft.Win32.SafeHandles.SafeWaitHandle]::new([IntPtr]$Exact,$false);$OldSafe.Dispose();$Wait=[Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($Event,$ProcessWait),$TimeoutMs);if($Wait -eq 1){throw "Driver exited before boot-ready"};if($Wait -ne 0){throw "Driver boot-ready timeout"};Start-Sleep -Milliseconds $Probation;$Process.Refresh();if($Process.HasExited){throw "Driver exited during post-ready probation"};return $Process}catch{$Failure=$_;if($null -ne $Process -and !(StopExact $Process)){throw "UNSAFE_CHILD:"+$Failure.Exception.Message};throw $Failure}finally{[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_BOOT_READY",$OldReady);if($null -ne $ProcessWait){$ProcessWait.Dispose()};if($null -ne $Event){$Event.Dispose()}}}' . "`n"
		. 'try {' . "`n"
		. '  $R=[Threading.EventWaitHandle]::OpenExisting($ReadyName);$C=[Threading.EventWaitHandle]::OpenExisting($CommitName);$A=[Threading.EventWaitHandle]::OpenExisting($AckName);$F=[Threading.EventWaitHandle]::OpenExisting($FinalExitName)' . "`n"
		. '  $P=[Threading.EventWaitHandle]::new($false,[Threading.EventResetMode]::AutoReset);$H=$P.SafeWaitHandle;$P.SafeWaitHandle=[Microsoft.Win32.SafeHandles.SafeWaitHandle]::new([IntPtr]$ParentHandle,$true);$H.Dispose()' . "`n"
		. '  if(!$R.Set()){throw "Ready signal failed"};$G=[Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($C,$P));if($G -eq 1){exit 20};if($G -ne 0){throw "Commit wait failed"}' . "`n"
		. '  if(!$A.Set()){throw "Ack signal failed"};$G=[Threading.WaitHandle]::WaitAny([Threading.WaitHandle[]]@($F,$P));if($G -eq 1){exit 21};if($G -ne 0){throw "FinalExit wait failed"};$P.WaitOne()|Out-Null' . "`n"
		. '  $B=$CurrentExe+".bak";$Had=[IO.File]::Exists($CurrentExe);$Retired=(!$Had -and [IO.File]::Exists($B));$Installed=$false;$Token=[Guid]::NewGuid().ToString("N");$Candidate=$CurrentExe+"."+$Token+".candidate.exe";$RecoveryPath=$CurrentExe+"."+$Token+".recovery.exe";$RecoveryStage=$CurrentExe+"."+$Token+".republish.exe";$RecoveryClaim=$RecoveryPath+".claim";$Recovery=$null;$TerminalPath=$DiagnosticPath+".terminal";RemoveBest $TerminalPath "terminal-stale"' . "`n"
		. '  try {' . "`n"
		. '    PublishCopy $NewExe $Candidate|Out-Null;$OldSource=if($Had){$CurrentExe}elseif($Retired){$B}else{$null}' . "`n"
		. '    if($null -ne $OldSource){PublishCopy $OldSource $RecoveryPath|Out-Null;PublishCopy $OldSource $RecoveryStage|Out-Null;WriteClaim $RecoveryClaim $CurrentExe $RecoveryStage;$Recovery=$RecoveryPath}' . "`n"
		. '    if($Had){RemoveBest $B "stale-bak";[IO.File]::Replace($Candidate,$CurrentExe,$B,$true);$Retired=$true}else{[IO.File]::Move($Candidate,$CurrentExe)};$Installed=$true;RemoveBest $NewExe "new-cleanup"' . "`n"
		. '    $Child=StartReady $CurrentExe $BootReadyTimeoutMs $ProbationMs $false' . "`n"
		. '    RemoveBest $RecoveryClaim "success-claim-cleanup";RemoveBest $B "success-bak-cleanup";RemoveBest $RecoveryStage "success-stage-cleanup";RemoveBest $Recovery "success-recovery-cleanup";exit 0' . "`n"
		. '  } catch {' . "`n"
		. '    $Failure=$_;if($Failure.Exception.Message.StartsWith("UNSAFE_CHILD:")){throw $Failure};$TerminalMessage="SWAP_ERROR:"+$Failure.Exception.Message;try{WriteTerminal $TerminalPath $TerminalMessage}catch{Diag("terminal-write:"+$_.Exception.Message)};RemoveBest $Candidate "rollback-candidate-cleanup";$Restored=(!$Installed -and $Had -and [IO.File]::Exists($CurrentExe))' . "`n"
		. '    for($I=0;$I -lt $RestoreAttempts -and !$Restored;$I++){' . "`n"
		. '      try{$Source=if([IO.File]::Exists($RecoveryStage)){$RecoveryStage}elseif([IO.File]::Exists($B)){$B}else{$null};if($null -eq $Source){break};if([IO.File]::Exists($CurrentExe)){$Bad=$CurrentExe+"."+$Token+".failed.exe";RemoveBest $Bad "rollback-failed-stale";[IO.File]::Replace($Source,$CurrentExe,$Bad,$true);RemoveBest $Bad "rollback-failed-cleanup"}else{[IO.File]::Move($Source,$CurrentExe)};$Restored=$true}' . "`n"
		. '      catch{Diag("rollback-restore-"+$I+":"+$_.Exception.Message);if(($I+1) -lt $RestoreAttempts){Start-Sleep -Milliseconds $RestoreRetryMs}}' . "`n"
		. '    }' . "`n"
		. '    $OldTerminal=[Environment]::GetEnvironmentVariable("ERGOPTI_UPDATER_SWAP_TERMINAL");[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_SWAP_TERMINAL",$TerminalPath);try{$DriverReady=$false;if($Restored){try{$RestoredChild=StartReady $CurrentExe $BootReadyTimeoutMs $ProbationMs $false;$DriverReady=$true;RemoveBest $RecoveryClaim "rollback-claim-cleanup";RemoveBest $B "rollback-bak-cleanup";RemoveBest $RecoveryStage "rollback-stage-cleanup";RemoveBest $Recovery "rollback-recovery-cleanup"}catch{if($_.Exception.Message.StartsWith("UNSAFE_CHILD:")){throw};Diag("rollback-relaunch:"+$_.Exception.Message)}}' . "`n"
		. '    for($RecoveryAttempt=0;$RecoveryAttempt -lt $RestoreAttempts -and !$DriverReady -and $null -ne $Recovery -and [IO.File]::Exists($Recovery);$RecoveryAttempt++){try{if(![IO.File]::Exists($RecoveryStage)){PublishCopy $Recovery $RecoveryStage|Out-Null};WriteClaim $RecoveryClaim $CurrentExe $RecoveryStage;$RecoveryChild=StartReady $Recovery $BootReadyTimeoutMs $ProbationMs $true;$DriverReady=$true;Diag("rollback-recovery:"+$Recovery)}catch{if($_.Exception.Message.StartsWith("UNSAFE_CHILD:")){throw};Diag("rollback-recovery-"+$RecoveryAttempt+":"+$_.Exception.Message);if(($RecoveryAttempt+1) -lt $RestoreAttempts){Start-Sleep -Milliseconds $RestoreRetryMs}}}' . "`n"
		. '    if(!$DriverReady){throw "Rollback could not start either canonical or recovery driver"}}finally{[Environment]::SetEnvironmentVariable("ERGOPTI_UPDATER_SWAP_TERMINAL",$OldTerminal)};throw $Failure' . "`n"
		. '  }' . "`n"
		. '} catch {$M="SWAP_ERROR:"+$_.Exception.Message;Diag($M);[Console]::Error.WriteLine($M);exit 1}' . "`n"
		. 'finally{foreach($W in @($R,$C,$A,$F,$P)){if($null -ne $W){$W.Dispose()}}}'
}

_Updater_QuoteCreateProcessArg(Value) {
	Text := Value . ""
	Result := '"'
	BackslashCount := 0
	Loop Parse Text {
		Character := A_LoopField
		if (Character == "\") {
			BackslashCount += 1
			continue
		}
		if (Character == '"') {
			Loop BackslashCount * 2 + 1
				Result .= "\"
			Result .= '"'
			BackslashCount := 0
			continue
		}
		Loop BackslashCount
			Result .= "\"
		BackslashCount := 0
		Result .= Character
	}
	Loop BackslashCount * 2
		Result .= "\"
	return Result . '"'
}

_Updater_CreateNamedSwapEvent(Name) {
	return PLC_CreateNamedManualResetEvent(Name)
}

_Updater_QueueSwapCleanupDebt(Handle, Terminate) {
	global _UpdaterSwapCleanupDebt, _UpdaterSwapCleanupDebtCounter
	if !Handle
		return 0
	PreviousCritical := Critical("On")
	try {
		for DebtId, Record in _UpdaterSwapCleanupDebt {
			if Record["handle"] == Handle {
				Record["terminate"] := Record["terminate"] || Terminate
				return DebtId
			}
		}
		_UpdaterSwapCleanupDebtCounter += 1
		DebtId := _UpdaterSwapCleanupDebtCounter
		_UpdaterSwapCleanupDebt[DebtId] := Map(
			"handle", Handle, "terminate", Terminate,
			"running", false, "warned", false)
		return DebtId
	} finally Critical(PreviousCritical)
}

_Updater_ScheduleSwapCleanupRetry() {
	global _UpdaterSwapCleanupDebt, _UpdaterSwapCleanupRetryTimer
	global UPDATER_SWAP_CLEANUP_RETRY_MS
	PreviousCritical := Critical("On")
	try {
		if _UpdaterSwapCleanupDebt.Count == 0
			return true
		if HasMethod(_UpdaterSwapCleanupRetryTimer, "Call")
			return true
		RetryTimer := (*) => _Updater_RetrySwapCleanupDebt()
		_UpdaterSwapCleanupRetryTimer := RetryTimer
	} finally Critical(PreviousCritical)
	try {
		SetTimer(RetryTimer, -UPDATER_SWAP_CLEANUP_RETRY_MS)
		return true
	} catch as Err {
		PreviousCritical := Critical("On")
		try {
			if _UpdaterSwapCleanupRetryTimer == RetryTimer
				_UpdaterSwapCleanupRetryTimer := 0
		} finally Critical(PreviousCritical)
		try LoggerError("Updater",
			"Could not schedule updater swap cleanup retry: {1}.", Err.Message)
		return false
	}
}

_Updater_TrySwapCleanupRecord(Record) {
	Handle := Record["handle"]
	if Record["terminate"] {
		Terminated := PLC_TerminateProcessHandle(Handle)
		if !Terminated && PLC_WaitHandle(Handle, 0) != 0
			return false
	}
	return PLC_CloseNativeHandle(Handle)
}

_Updater_DrainSwapCleanupRecord(DebtId) {
	global _UpdaterSwapCleanupDebt
	PreviousCritical := Critical("On")
	try {
		if !_UpdaterSwapCleanupDebt.Has(DebtId)
			return true
		Record := _UpdaterSwapCleanupDebt[DebtId]
		if Record["running"]
			return false
		Record["running"] := true
	} finally Critical(PreviousCritical)
	Complete := _Updater_TrySwapCleanupRecord(Record)
	Warn := false
	PreviousCritical := Critical("On")
	try {
		if (_UpdaterSwapCleanupDebt.Has(DebtId)
				&& ObjPtr(_UpdaterSwapCleanupDebt[DebtId]) == ObjPtr(Record)) {
			if Complete {
				_UpdaterSwapCleanupDebt.Delete(DebtId)
			} else {
				Record["running"] := false
				if !Record["warned"] {
					Record["warned"] := true
					Warn := true
				}
			}
		}
	} finally Critical(PreviousCritical)
	if Warn
		try LoggerWarn("Updater",
			"Retaining updater swap handle {1} after native cleanup refusal.",
			Record["handle"])
	return Complete
}

_Updater_ReleaseSwapHandle(Handle, Terminate := false) {
	if !Handle
		return true
	DebtId := _Updater_QueueSwapCleanupDebt(Handle, Terminate)
	Complete := _Updater_DrainSwapCleanupRecord(DebtId)
	if !Complete
		_Updater_ScheduleSwapCleanupRetry()
	return Complete
}

_Updater_RetrySwapCleanupDebt() {
	global _UpdaterSwapCleanupDebt, _UpdaterSwapCleanupRetryTimer
	PreviousCritical := Critical("On")
	try {
		_UpdaterSwapCleanupRetryTimer := 0
		Snapshot := _UpdaterSwapCleanupDebt.Clone()
	} finally Critical(PreviousCritical)
	for DebtId, _ in Snapshot
		_Updater_DrainSwapCleanupRecord(DebtId)
	PreviousCritical := Critical("On")
	try Pending := _UpdaterSwapCleanupDebt.Count != 0
	finally Critical(PreviousCritical)
	if Pending
		_Updater_ScheduleSwapCleanupRetry()
	return !Pending
}

_Updater_CloseNativeSwapHandle(Handle) {
	return _Updater_ReleaseSwapHandle(Handle)
}

_Updater_TakeSwapHandle(Owner, Name) {
	if !(Owner is Map)
		return 0
	PreviousCritical := Critical("On")
	try {
		Handle := Owner.Get(Name, 0)
		Owner[Name] := 0
	} finally {
		Critical(PreviousCritical)
	}
	return Handle
}

_Updater_TakeSwapResumeHandles(Owner) {
	if !(Owner is Map)
		return [0, 0]
	PreviousCritical := Critical("On")
	try {
		ThreadHandle := Owner.Get("ThreadHandle", 0)
		ParentHandle := Owner.Get("ParentHandle", 0)
		Owner["ThreadHandle"] := 0
		Owner["ParentHandle"] := 0
	} finally {
		Critical(PreviousCritical)
	}
	return [ThreadHandle, ParentHandle]
}

_Updater_TakeSwapProcessHandles(Owner) {
	if !(Owner is Map)
		return [0, 0]
	PreviousCritical := Critical("On")
	try {
		ProcessHandle := Owner.Get("ProcessHandle", 0)
		ThreadHandle := Owner.Get("ThreadHandle", 0)
		ProcessInfo := Owner.Get("ProcessInfo", 0)
		; CreateProcessW may have filled the shared PROCESS_INFORMATION Buffer
		; immediately before OnExit preempted the creator. Claim those unpublished
		; values exactly once so proceeding with exit cannot orphan the child.
		if (ProcessInfo is Buffer) {
			if !ProcessHandle
				ProcessHandle := NumGet(ProcessInfo, 0, "Ptr")
			if !ThreadHandle
				ThreadHandle := NumGet(ProcessInfo, A_PtrSize, "Ptr")
			NumPut("Ptr", 0, ProcessInfo, 0)
			NumPut("Ptr", 0, ProcessInfo, A_PtrSize)
		}
		Owner["ProcessHandle"] := 0
		Owner["ThreadHandle"] := 0
		Owner["ProcessInfo"] := 0
	} finally {
		Critical(PreviousCritical)
	}
	return [ProcessHandle, ThreadHandle]
}

_Updater_CloseSwapOwner(Owner, TerminateChild := false) {
	if !(Owner is Map)
		return true
	; Take-and-zero before TerminateProcess. A stale callback may still hold the
	; same Owner Map; reading first and closing later would let that callback use
	; a closed HANDLE value after Windows had already recycled it.
	ProcessHandles := _Updater_TakeSwapProcessHandles(Owner)
	ProcessHandle := ProcessHandles[1]
	ThreadHandle := ProcessHandles[2]
	Complete := _Updater_ReleaseSwapHandle(ProcessHandle, TerminateChild)
	Released := _Updater_CloseNativeSwapHandle(ThreadHandle)
	Complete := Released && Complete
	for Name in ["ParentHandle", "ReadyHandle",
		"CommitHandle", "AckHandle", "FinalExitHandle"] {
		Handle := _Updater_TakeSwapHandle(Owner, Name)
		Released := _Updater_CloseNativeSwapHandle(Handle)
		Complete := Released && Complete
	}
	return Complete
}

_Updater_MakeSwapEventName(TransactionId, Role) {
	ProcessId := PLC_CurrentProcessId()
	if !ProcessId
		throw Error("Updater event name requires the current process identity")
	return "Local\ErgoptiUpdaterSwap_" . ProcessId
		. "_" . TransactionId . "_" . A_TickCount . "_" . Role
}

_Updater_NewSwapOwner(TransactionId) {
	return Map(
		"Id", TransactionId,
		"ProcessHandle", 0,
		"ThreadHandle", 0,
		"ParentHandle", 0,
		"ReadyHandle", 0,
		"CommitHandle", 0,
		"AckHandle", 0,
		"FinalExitHandle", 0,
		"ProcessInfo", 0,
		"ProcessId", 0,
		"Phase", "Starting",
		"PhaseStartedTick", A_TickCount,
		"FinalExitSignaled", false,
		"ExitRetryCount", 0,
		"Tag", "")
}

; Reserve the process-wide owner before any native child exists. OnExit can
; claim this zero-handle Starting owner while CreateProcess is in flight; the
; creator then observes the lost reservation and terminates its still-local
; suspended handles instead of orphaning an unpublished process.
_Updater_ReserveSwapOwner(TransactionId, StagingEpoch := 0) {
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	Owner := _Updater_NewSwapOwner(TransactionId)
	PreviousCritical := Critical("On")
	try {
		if (StagingEpoch and (!_UpdaterDownloadInProgress
			or _UpdaterSelfUpdateEpoch != StagingEpoch))
			return 0
		if (_UpdaterSwapOwner is Map)
			return 0
		Owner["Epoch"] := StagingEpoch
		_UpdaterSwapOwner := Owner
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		return Owner
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_CloseUnpublishedSwapHandles(Handles, TerminateChild := false) {
	if !(Handles is Map)
		return true
	ProcessInfo := Handles.Get("ProcessInfo", 0)
	ProcessHandle := ProcessInfo is Buffer ? NumGet(ProcessInfo, 0, "Ptr") : 0
	ThreadHandle := ProcessInfo is Buffer ? NumGet(ProcessInfo, A_PtrSize, "Ptr") : 0
	if (ProcessInfo is Buffer) {
		NumPut("Ptr", 0, ProcessInfo, 0)
		NumPut("Ptr", 0, ProcessInfo, A_PtrSize)
	}
	Handles["ProcessInfo"] := 0
	Complete := _Updater_ReleaseSwapHandle(ProcessHandle, TerminateChild)
	Released := _Updater_CloseNativeSwapHandle(ThreadHandle)
	Complete := Released && Complete
	for Name in ["ParentHandle", "ReadyHandle",
		"CommitHandle", "AckHandle", "FinalExitHandle"] {
		Handle := Handles.Get(Name, 0)
		Handles[Name] := 0
		Released := _Updater_CloseNativeSwapHandle(Handle)
		Complete := Released && Complete
	}
	return Complete
}

; Creates the exact swapper process suspended. ParentProcessHandle is an
; ownership-transfer seam used only by behavior tests; production passes 0 and
; receives an inheritable SYNCHRONIZE handle to this exact AHK process. A
; nonzero test handle is adopted at call entry and closed even when creation
; throws, so the caller must take-and-zero its own slot before invoking us.
_Updater_CreateSuspendedSwapOwner(SwapScriptPath, NewExe, CurrentExe, TransactionId, ParentProcessHandle := 0, ReservedOwner := 0, BeforePublishFn := 0) {
	global UPDATER_SWAP_CREATE_SUSPENDED, UPDATER_SWAP_CREATE_NO_WINDOW
	global UPDATER_SWAP_SYNCHRONIZE, UPDATER_SWAP_PROBATION_MS
	global UPDATER_SWAP_BOOT_READY_TIMEOUT_MS
	global UPDATER_SWAP_RESTORE_ATTEMPTS, UPDATER_SWAP_RESTORE_RETRY_MS
	global _UpdaterSwapOwner
	Owner := ReservedOwner is Map ? ReservedOwner : _Updater_NewSwapOwner(TransactionId)
	if (Owner.Get("Id", 0) != TransactionId)
		throw ValueError("Reserved swap owner does not match its transaction")
	LocalHandles := Map(
		"ParentHandle", ParentProcessHandle,
		"ReadyHandle", 0,
		"CommitHandle", 0,
		"AckHandle", 0,
		"FinalExitHandle", 0)
	try {
		for Role in ["Ready", "Commit", "Ack", "FinalExit"] {
			EventName := _Updater_MakeSwapEventName(TransactionId, Role)
			Owner[Role . "Name"] := EventName
			LocalHandles[Role . "Handle"] := _Updater_CreateNamedSwapEvent(EventName)
		}
		if !LocalHandles["ParentHandle"] {
			LocalHandles["ParentHandle"] := PLC_OpenCurrentProcessHandle(
				UPDATER_SWAP_SYNCHRONIZE)
			if !LocalHandles["ParentHandle"]
				throw Error("OpenProcess could not create the inheritable exact-parent handle")
		}

		PowerShellPath := _Updater_PowerShellPath()
		Args := [PowerShellPath, "-NoProfile", "-NonInteractive", "-ExecutionPolicy",
			"Bypass", "-File", SwapScriptPath, Owner["ReadyName"], Owner["CommitName"],
			Owner["AckName"], Owner["FinalExitName"], LocalHandles["ParentHandle"], NewExe,
			CurrentExe, UPDATER_SWAP_PROBATION_MS, UPDATER_SWAP_BOOT_READY_TIMEOUT_MS,
			UPDATER_SWAP_RESTORE_ATTEMPTS,
			UPDATER_SWAP_RESTORE_RETRY_MS, SwapScriptPath . ".log"]
		CommandLine := ""
		for Arg in Args
			CommandLine .= (CommandLine == "" ? "" : " ") . _Updater_QuoteCreateProcessArg(Arg)
		CommandBuffer := Buffer((StrLen(CommandLine) + 1) * 2, 0)
		StrPut(CommandLine, CommandBuffer, "UTF-16")
		StartupInfo := Buffer(A_PtrSize == 8 ? 104 : 68, 0)
		NumPut("UInt", StartupInfo.Size, StartupInfo, 0)
		ProcessInfo := Buffer((A_PtrSize * 2) + 8, 0)
		LocalHandles["ProcessInfo"] := ProcessInfo
		PreviousCritical := Critical("On")
		try {
			ReservationLive := !(ReservedOwner is Map)
				or (_UpdaterSwapOwner is Map and _UpdaterSwapOwner == Owner)
			if !ReservationLive
				throw Error("Swap reservation was canceled before CreateProcessW")
			; PROCESS_INFORMATION is shared before the call. If an OnExit thread
			; lands at the first post-DllCall message check, it can atomically take
			; and terminate the exact handles Windows just wrote into this Buffer.
			Owner["ProcessInfo"] := ProcessInfo
		} finally {
			Critical(PreviousCritical)
		}
		CreationFlags := UPDATER_SWAP_CREATE_SUSPENDED | UPDATER_SWAP_CREATE_NO_WINDOW
		PLC_CreateProcessWithInheritedHandles(PowerShellPath, CommandBuffer,
			CreationFlags, StartupInfo, ProcessInfo)
		ProcessId := NumGet(ProcessInfo, A_PtrSize * 2, "UInt")
		if HasMethod(BeforePublishFn, "Call")
			BeforePublishFn.Call(Owner, ProcessId)
		Published := false
		PreviousCritical := Critical("On")
		try {
			ReservationLive := !(ReservedOwner is Map)
				or (_UpdaterSwapOwner is Map and _UpdaterSwapOwner == Owner)
			ProcessInfoOwned := Owner.Get("ProcessInfo", 0) == ProcessInfo
			if ReservationLive {
				if !ProcessInfoOwned
					throw Error("Swap PROCESS_INFORMATION ownership was lost before publication")
				Owner["ProcessHandle"] := NumGet(ProcessInfo, 0, "Ptr")
				Owner["ThreadHandle"] := NumGet(ProcessInfo, A_PtrSize, "Ptr")
				NumPut("Ptr", 0, ProcessInfo, 0)
				NumPut("Ptr", 0, ProcessInfo, A_PtrSize)
				Owner["ProcessInfo"] := 0
				for Name in ["ParentHandle", "ReadyHandle",
					"CommitHandle", "AckHandle", "FinalExitHandle"] {
					Owner[Name] := LocalHandles[Name]
					LocalHandles[Name] := 0
				}
				Owner["ProcessId"] := ProcessId
				Owner["Phase"] := "AwaitReady"
				Owner["PhaseStartedTick"] := A_TickCount
				Published := true
			}
		} finally {
			Critical(PreviousCritical)
		}
		if !Published
			throw Error("Swap reservation was canceled while CreateProcessW was in flight")
		return Owner
	} catch {
		_Updater_CloseUnpublishedSwapHandles(LocalHandles, true)
		_Updater_CloseSwapOwner(Owner, true)
		throw
	}
}

_Updater_ResumeSwapOwner(Owner) {
	global UPDATER_SWAP_RESUME_FAILED
	ResumeHandles := _Updater_TakeSwapResumeHandles(Owner)
	ThreadHandle := ResumeHandles[1]
	ParentHandle := ResumeHandles[2]
	if !ThreadHandle {
		_Updater_CloseNativeSwapHandle(ParentHandle)
		return false
	}
	ResumeResult := UPDATER_SWAP_RESUME_FAILED
	ResumeError := ""
	ResumeWin32Error := 0
	try {
		ResumeOutcome := PLC_ResumeThreadHandle(ThreadHandle)
		ResumeResult := ResumeOutcome["Value"]
		ResumeWin32Error := ResumeOutcome["Error"]
		ResumeError := ResumeOutcome["Exception"]
	} catch as Err {
		ResumeError := Err.Message
	} finally {
		_Updater_CloseNativeSwapHandle(ThreadHandle)
		_Updater_CloseNativeSwapHandle(ParentHandle)
	}
	if (ResumeError != "") {
		try LoggerError("Updater", "ResumeThread threw for swap worker transaction {1}: {2}.", Owner.Get("Id", 0), ResumeError)
		return false
	}
	if (ResumeResult == UPDATER_SWAP_RESUME_FAILED) {
		try LoggerError("Updater", "ResumeThread failed for swap worker transaction {1} (Win32 {2}).", Owner.Get("Id", 0), ResumeWin32Error)
		return false
	}
	return true
}

_Updater_CurrentSwapOwner(TransactionId := 0) {
	global _UpdaterSwapOwner
	PreviousCritical := Critical("On")
	try {
		Owner := _UpdaterSwapOwner
		if !(Owner is Map)
			return 0
		if (TransactionId and Owner.Get("Id", 0) != TransactionId)
			return 0
		return Owner
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_ClaimSwapOwner(TransactionId := 0) {
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	PreviousCritical := Critical("On")
	try {
		Owner := _UpdaterSwapOwner
		if !(Owner is Map)
			return 0
		if (TransactionId and Owner.Get("Id", 0) != TransactionId)
			return 0
		_UpdaterSwapOwner := 0
		if (_UpdaterExitIntent is Map
			and _UpdaterExitIntent.Get("TransactionId", 0) == Owner.Get("Id", 0))
			_UpdaterExitIntent := 0
		if (_UpdaterExitInvocation is Map
			and _UpdaterExitInvocation.Get("TransactionId", 0) == Owner.Get("Id", 0))
			_UpdaterExitInvocation := 0
		return Owner
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_WaitHandleState(Handle) {
	global UPDATER_SWAP_WAIT_OBJECT_0, UPDATER_SWAP_WAIT_TIMEOUT
	global UPDATER_SWAP_WAIT_FAILED
	if !Handle
		return -1
	WaitResult := PLC_WaitHandle(Handle, 0)
	if (WaitResult == UPDATER_SWAP_WAIT_OBJECT_0)
		return 1
	if (WaitResult == UPDATER_SWAP_WAIT_TIMEOUT)
		return 0
	if (WaitResult == UPDATER_SWAP_WAIT_FAILED)
		return -1
	return -1
}

_Updater_SetSwapEvent(Handle) {
	return PLC_SetEventHandle(Handle)
}

; Shared HANDLE slots may be claimed and closed by OnExit. Keep each zero-time
; probe/signal inside the same short Critical span as its Map read so a stale
; callback can never issue a Win32 call on a closed and recycled value.
_Updater_WaitSwapOwnerHandleState(Owner, Name) {
	if !(Owner is Map)
		return -1
	PreviousCritical := Critical("On")
	try {
		return _Updater_WaitHandleState(Owner.Get(Name, 0))
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_SetSwapOwnerEvent(Owner, Name) {
	if !(Owner is Map)
		return false
	PreviousCritical := Critical("On")
	try {
		return _Updater_SetSwapEvent(Owner.Get(Name, 0))
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_ArmSwapHandshakePoll(TransactionId) {
	global UPDATER_SWAP_HANDSHAKE_POLL_MS
	TimerArmOneShotMs(() => _Updater_PollSwapHandshake(TransactionId),
		UPDATER_SWAP_HANDSHAKE_POLL_MS)
}

_Updater_StartSwapTransaction(SwapScriptPath, NewExe, CurrentExe, Tag, StagingEpoch) {
	global _UpdaterSwapTransactionCounter
	TransactionId := ++_UpdaterSwapTransactionCounter
	Owner := _Updater_ReserveSwapOwner(TransactionId, StagingEpoch)
	if !(Owner is Map) {
		try LoggerError("Updater", "Could not reserve current-epoch ownership for swap transaction {1}.", TransactionId)
		return false
	}
	try {
		_Updater_CreateSuspendedSwapOwner(
			SwapScriptPath, NewExe, CurrentExe, TransactionId, 0, Owner)
		Owner["Tag"] := Tag
	} catch as Err {
		Claimed := _Updater_ClaimSwapOwner(TransactionId)
		if (Claimed is Map)
			_Updater_CloseSwapOwner(Claimed, true)
		try LoggerError("Updater", "Could not create the suspended swap worker: {1}.", Err.Message)
		return false
	}
	if !_Updater_ResumeSwapOwner(Owner) {
		Claimed := _Updater_ClaimSwapOwner(TransactionId)
		if (Claimed is Map)
			_Updater_CloseSwapOwner(Claimed, true)
		try LoggerError("Updater", "Suspended swap worker could not be resumed; update remains staged and the driver stays alive.")
		return false
	}
	try LoggerInfo("Updater", "Swap worker transaction {1} launched; awaiting readiness acknowledgement.", TransactionId)
	_Updater_ArmSwapHandshakePoll(TransactionId)
	return true
}

_Updater_FailSwapTransaction(TransactionId, Message, ShowUi := true) {
	Owner := _Updater_ClaimSwapOwner(TransactionId)
	if !(Owner is Map)
		return
	StagingEpoch := Owner.Get("Epoch", 0)
	_Updater_CloseSwapOwner(Owner, true)
	try LoggerError("Updater", "Swap transaction {1} aborted: {2}.", TransactionId, Message)
	if ShowUi {
		try _Updater_ReportInstallFailure("updater.install_error", "changelog_window.install_error_install")
	} else {
		TimerArmOneShotMs(_Updater_ShowDeferredSwapFailureNotice, 1)
	}
	_Updater_EndDownloadTransaction(StagingEpoch)
}

; OnExit must return before user-visible UI or a recovery Reload can run. A
; named timer coalesces the failure notice and guarantees that a post-teardown
; reload happens only after the user has seen the updater failure.
_Updater_ShowDeferredSwapFailureNotice(*) {
	; A failure balloon is not an update offer: a click on it must not open the
	; update prompt.
	NotifyFn := (*) => (_Updater_ReleaseBalloon(), TrayTip(t("updater.install_error"),
		t("updater.title_update"), "Iconx Mute"))
	ArmRetryFn := (DelayMs) => TimerArmOneShotMs(
		_Updater_ShowDeferredSwapFailureNotice, DelayMs)
	if _Updater_AttemptLifecycleRecovery(NotifyFn, ArmRetryFn,
		ReloadPreservingSuspend)
		return
	try Ui_MsgBox(t("updater.install_error"), t("updater.window_title"), "Icon!")
}

; A launched Reload returns at once and destroys this process only when its
; successor asks it to close, so the retry is armed only for a refusal: at once
; when no successor was launched, or from the refusal callback when OnExit later
; refused it. Arming before every attempt launched one more /restart successor
; per backoff tick while the first was still loading. Pending remains the sole
; recovery owner until the process ends. There is deliberately no in-place
; "success" state: KL_BeginShutdown and watcher teardown are terminal in this
; process.
_Updater_AttemptLifecycleRecovery(NotifyFn, ArmRetryFn, ReloadFn) {
	global _UpdaterLifecycleRecoveryPending, _UpdaterLifecycleRecoveryNoticeShown
	global _UpdaterLifecycleRecoveryNoticeRequested
	global _UpdaterLifecycleRecoveryAttemptCount
	global UPDATER_SWAP_RECOVERY_RETRY_BASE_MS, UPDATER_SWAP_RECOVERY_RETRY_MAX_MS
	if !(HasMethod(NotifyFn, "Call") and HasMethod(ArmRetryFn, "Call")
		and HasMethod(ReloadFn, "Call"))
		throw TypeError("Updater lifecycle recovery requires callable seams")
	ShowRecoveryNotice := false
	RetryDelayMs := 0
	PreviousCritical := Critical("On")
	try {
		if !_UpdaterLifecycleRecoveryPending
			return false
		if (_UpdaterLifecycleRecoveryNoticeRequested
			and !_UpdaterLifecycleRecoveryNoticeShown) {
			_UpdaterLifecycleRecoveryNoticeShown := true
			ShowRecoveryNotice := true
		}
		_UpdaterLifecycleRecoveryAttemptCount += 1
		RetryDelayMs := Min(
			UPDATER_SWAP_RECOVERY_RETRY_BASE_MS
				* _UpdaterLifecycleRecoveryAttemptCount,
			UPDATER_SWAP_RECOVERY_RETRY_MAX_MS)
	} finally {
		Critical(PreviousCritical)
	}
	if ShowRecoveryNotice
		try NotifyFn.Call()
	ArmRetry := _Updater_ArmLifecycleRecoveryRetry.Bind(ArmRetryFn, RetryDelayMs)
	Launched := false
	try Launched := ReloadFn.Call(0, 0, ArmRetry)
	catch as Err
		try LoggerError("Updater", "Lifecycle recovery Reload failed after swap cancellation: {1}.", Err.Message)
	if !((Launched is Integer) && Launched == 1)
		ArmRetry.Call()
	return true
}

_Updater_ArmLifecycleRecoveryRetry(ArmRetryFn, RetryDelayMs, *) {
	try ArmRetryFn.Call(RetryDelayMs)
	catch as Err
		try LoggerError("Updater", "Lifecycle recovery retry could not be armed: {1}.", Err.Message)
}

_Updater_ScheduleLifecycleRecoveryReload(ShowUpdaterFailureNotice := false) {
	global _UpdaterLifecycleRecoveryPending, _UpdaterLifecycleRecoveryNoticeShown
	global _UpdaterLifecycleRecoveryNoticeRequested
	global _UpdaterLifecycleRecoveryAttemptCount
	PreviousCritical := Critical("On")
	try {
		if !_UpdaterLifecycleRecoveryPending {
			_UpdaterLifecycleRecoveryNoticeShown := false
			_UpdaterLifecycleRecoveryNoticeRequested := false
			_UpdaterLifecycleRecoveryAttemptCount := 0
		}
		if ShowUpdaterFailureNotice
			_UpdaterLifecycleRecoveryNoticeRequested := true
		_UpdaterLifecycleRecoveryPending := true
	} finally {
		Critical(PreviousCritical)
	}
	TimerArmOneShotMs(_Updater_ShowDeferredSwapFailureNotice, 1)
}

_Updater_SetSwapPhase(TransactionId, Phase) {
	global _UpdaterSwapOwner
	PreviousCritical := Critical("On")
	try {
		if !(_UpdaterSwapOwner is Map)
			return false
		if (_UpdaterSwapOwner.Get("Id", 0) != TransactionId)
			return false
		_UpdaterSwapOwner["Phase"] := Phase
		_UpdaterSwapOwner["PhaseStartedTick"] := A_TickCount
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_PublishExitIntent(TransactionId, Owner) {
	global _UpdaterSwapOwner, _UpdaterExitIntent
	PreviousCritical := Critical("On")
	try {
		if !(_UpdaterSwapOwner is Map)
			return false
		if (_UpdaterSwapOwner != Owner
			or _UpdaterSwapOwner.Get("Id", 0) != TransactionId)
			return false
		if (_UpdaterExitIntent is Map)
			return _UpdaterExitIntent.Get("TransactionId", 0) == TransactionId
		_UpdaterExitIntent := Map("TransactionId", TransactionId, "Owner", Owner)
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_PollSwapHandshake(TransactionId, NowTick := unset,
	WaitFn := _Updater_WaitSwapOwnerHandleState,
	FailFn := _Updater_FailSwapTransaction, ArmFn := _Updater_ArmSwapHandshakePoll,
	SetEventFn := _Updater_SetSwapOwnerEvent) {
	global UPDATER_SWAP_READY_TIMEOUT_MS, UPDATER_SWAP_ACK_TIMEOUT_MS
	Owner := _Updater_CurrentSwapOwner(TransactionId)
	if !(Owner is Map)
		return
	if A_IsSuspended {
		FailFn.Call(TransactionId,
			"the driver was suspended before the swap handshake completed")
		return
	}
	ProcessState := WaitFn.Call(Owner, "ProcessHandle")
	if (ProcessState != 0) {
		FailFn.Call(TransactionId,
			ProcessState == 1 ? "the swap worker exited before ownership transfer"
				: "the exact swap-worker process handle could not be queried")
		return
	}
	Phase := Owner.Get("Phase", "")
	if (Phase == "AwaitReady") {
		ReadyState := WaitFn.Call(Owner, "ReadyHandle")
		if (ReadyState < 0) {
			FailFn.Call(TransactionId, "the Ready event could not be queried")
			return
		}
		if (ReadyState == 0) {
			PhaseStartedTick := Owner.Get("PhaseStartedTick", A_TickCount)
			if TickExpired64(PhaseStartedTick,
				UPDATER_SWAP_READY_TIMEOUT_MS, NowTick?) {
				FailFn.Call(TransactionId, "the Ready event timed out")
				return
			}
			ArmFn.Call(TransactionId)
			return
		}
		if !SetEventFn.Call(Owner, "CommitHandle") {
			FailFn.Call(TransactionId, "the Commit event could not be signaled")
			return
		}
		if !_Updater_SetSwapPhase(TransactionId, "AwaitAck")
			return
		ArmFn.Call(TransactionId)
		return
	}
	if (Phase != "AwaitAck") {
		FailFn.Call(TransactionId, "the swap handshake entered an invalid phase")
		return
	}
	AckState := WaitFn.Call(Owner, "AckHandle")
	if (AckState < 0) {
		FailFn.Call(TransactionId, "the Ack event could not be queried")
		return
	}
	if (AckState == 0) {
		PhaseStartedTick := Owner.Get("PhaseStartedTick", A_TickCount)
		if TickExpired64(PhaseStartedTick,
			UPDATER_SWAP_ACK_TIMEOUT_MS, NowTick?) {
			FailFn.Call(TransactionId, "the Ack event timed out")
			return
		}
		ArmFn.Call(TransactionId)
		return
	}
	; Ack is only authority to request shutdown while the exact child remains
	; alive. The OnExit handler performs the same check again immediately before
	; publishing FinalExit and once more before ownership transfer.
	if (WaitFn.Call(Owner, "ProcessHandle") != 0) {
		FailFn.Call(TransactionId, "the swap worker died after Ack")
		return
	}
	if !_Updater_PublishExitIntent(TransactionId, Owner) {
		FailFn.Call(TransactionId, "the updater exit intent could not be published atomically")
		return
	}
	try LoggerInfo("Updater", "Swap worker transaction {1} acknowledged commit; requesting guarded shutdown.", TransactionId)
	TimerArmOneShotMs(() => _Updater_RequestExitForIntent(TransactionId), 1)
}

_Updater_IntentOwner(TransactionId := 0) {
	global _UpdaterSwapOwner, _UpdaterExitIntent
	PreviousCritical := Critical("On")
	try {
		if !(_UpdaterExitIntent is Map) or !(_UpdaterSwapOwner is Map)
			return 0
		IntentId := _UpdaterExitIntent.Get("TransactionId", 0)
		if (TransactionId and IntentId != TransactionId)
			return 0
		if (_UpdaterSwapOwner.Get("Id", 0) != IntentId
			or _UpdaterExitIntent.Get("Owner", 0) != _UpdaterSwapOwner)
			return 0
		return _UpdaterSwapOwner
	} finally {
		Critical(PreviousCritical)
	}
}

; ExitIntent means the acknowledged child is eligible to request shutdown. It
; is intentionally NOT authority for an arbitrary concurrent Quit/Reload. The
; transient invocation exists only inside the Critical sequence that calls
; ExitApp synchronously; an OnExit refusal returns through finally and clears
; it before any delayed retry can coexist with an ordinary user exit.
_Updater_PublishExitInvocation(TransactionId, Owner) {
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	PreviousCritical := Critical("On")
	try {
		if !(Owner is Map) or !(_UpdaterSwapOwner is Map)
			or !(_UpdaterExitIntent is Map)
			return false
		if (_UpdaterSwapOwner != Owner
			or _UpdaterSwapOwner.Get("Id", 0) != TransactionId
			or _UpdaterExitIntent.Get("TransactionId", 0) != TransactionId
			or _UpdaterExitIntent.Get("Owner", 0) != Owner)
			return false
		if (_UpdaterExitInvocation is Map)
			return false
		_UpdaterExitInvocation := Map(
			"TransactionId", TransactionId, "Owner", Owner)
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_ClearExitInvocation(TransactionId, Owner) {
	global _UpdaterExitInvocation
	PreviousCritical := Critical("On")
	try {
		if (_UpdaterExitInvocation is Map
			and _UpdaterExitInvocation.Get("TransactionId", 0) == TransactionId
			and _UpdaterExitInvocation.Get("Owner", 0) == Owner)
			_UpdaterExitInvocation := 0
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_ExitInvocationOwner(TransactionId := 0) {
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	PreviousCritical := Critical("On")
	try {
		if !(_UpdaterExitInvocation is Map)
			or !(_UpdaterExitIntent is Map) or !(_UpdaterSwapOwner is Map)
			return 0
		InvocationId := _UpdaterExitInvocation.Get("TransactionId", 0)
		if (TransactionId and InvocationId != TransactionId)
			return 0
		if (_UpdaterExitIntent.Get("TransactionId", 0) != InvocationId
			or _UpdaterSwapOwner.Get("Id", 0) != InvocationId
			or _UpdaterExitInvocation.Get("Owner", 0) != _UpdaterSwapOwner
			or _UpdaterExitIntent.Get("Owner", 0) != _UpdaterSwapOwner)
			return 0
		return _UpdaterSwapOwner
	} finally {
		Critical(PreviousCritical)
	}
}

; Pure authorization seam for the three independent Ack-to-exit boundaries.
; SuspendedOverride exists so tests can reproduce a Pause landing between the
; initial exit request and OnExit without suspending the test runner itself.
_Updater_ExitIntentStillAuthorized(Owner, SuspendedOverride := unset) {
	if !(Owner is Map)
		return false
	PreviousCritical := Critical("On")
	try {
		SuspendedNow := IsSet(SuspendedOverride) ? SuspendedOverride : A_IsSuspended
		if SuspendedNow
			return false
		return _Updater_WaitHandleState(Owner.Get("ProcessHandle", 0)) == 0
	} finally {
		Critical(PreviousCritical)
	}
}

_Updater_RequestExitForIntent(TransactionId) {
	Owner := _Updater_IntentOwner(TransactionId)
	if !(Owner is Map)
		return
	if !_Updater_ExitIntentStillAuthorized(Owner) {
		_Updater_FailSwapTransaction(TransactionId,
			"suspend state or exact-child liveness revoked guarded shutdown")
		return
	}
	; Prevent a buffered menu/hotkey thread from landing after publication but
	; before ExitApp. OnExit itself starts as a fresh, non-interruptible thread,
	; so this Critical span ends at the synchronous exit call and never covers
	; shutdown I/O.
	PreviousCritical := Critical("On")
	InvocationPublished := false
	try {
		InvocationPublished := _Updater_PublishExitInvocation(TransactionId, Owner)
		if InvocationPublished
			ExitApp(0)
	} finally {
		_Updater_ClearExitInvocation(TransactionId, Owner)
		Critical(PreviousCritical)
	}
	if !InvocationPublished
		_Updater_FailSwapTransaction(TransactionId,
			"the guarded updater ExitApp invocation could not be published")
}

; Called only from Ergopti_OnShutdown after every refusal gate has accepted the
; exit. Destructive teardown has already started, so the caller must cancel the
; transaction and schedule a recovery Reload if this authorization fails.
_Updater_SignalFinalExitForIntent() {
	Owner := _Updater_ExitInvocationOwner()
	if !(Owner is Map)
		return true
	TransactionId := Owner.Get("Id", 0)
	Authorized := false
	Signaled := false
	StatePublishError := ""
	PreviousCritical := Critical("On")
	try {
		Current := _Updater_ExitInvocationOwner(TransactionId)
		if (Current is Map and Current == Owner
			and _Updater_ExitIntentStillAuthorized(Current)) {
			Authorized := true
			Signaled := Current.Get("FinalExitSignaled", false)
				or _Updater_SetSwapEvent(Current.Get("FinalExitHandle", 0))
			if Signaled {
				try Current["FinalExitSignaled"] := true
				catch as Err
					StatePublishError := Err.Message
			}
		}
	} finally {
		Critical(PreviousCritical)
	}
	if (StatePublishError != "")
		try LoggerWarn("Updater", "FinalExit event was signaled, but its idempotence marker could not be published for transaction {1}: {2}.", TransactionId, StatePublishError)
	if (Authorized and Signaled)
		return true
	_Updater_FailSwapTransaction(TransactionId,
		Authorized ? "the FinalExit event could not be signaled"
			: "suspend state or exact-child liveness revoked FinalExit authorization",
		false)
	return false
}

_Updater_DeferExitIntentRetry() {
	global UPDATER_SWAP_EXIT_RETRY_MS, UPDATER_SWAP_MAX_EXIT_RETRIES
	Owner := _Updater_ExitInvocationOwner()
	if !(Owner is Map)
		return
	TransactionId := Owner.Get("Id", 0)
	PreviousCritical := Critical("On")
	try {
		Current := _Updater_IntentOwner(TransactionId)
		if !(Current is Map)
			return
		Current["ExitRetryCount"] := Current.Get("ExitRetryCount", 0) + 1
		RetryCount := Current["ExitRetryCount"]
	} finally {
		Critical(PreviousCritical)
	}
	if (RetryCount > UPDATER_SWAP_MAX_EXIT_RETRIES) {
		TimerArmOneShotMs(() => _Updater_ExhaustExitIntentRetry(TransactionId), 1)
		return
	}
	TimerArmOneShotMs(() => _Updater_RequestExitForIntent(TransactionId),
		UPDATER_SWAP_EXIT_RETRY_MS)
}

_Updater_ExhaustExitIntentRetry(TransactionId) {
	_Updater_FailSwapTransaction(TransactionId,
		"shutdown refusal gates did not clear inside the bounded retry budget", false)
}

; The final hotstring gate runs after KL_BeginShutdown and watcher teardown.
; Unlike the pre-teardown TapHold gate, it cannot safely leave this process live
; for a bounded retry. Cancel the updater child immediately, surface the failure,
; and reload only after OnExit has returned.
_Updater_CancelExitIntentAfterLifecycleTeardown(Message) {
	Owner := _Updater_IntentOwner()
	if !(Owner is Map)
		return false
	TransactionId := Owner.Get("Id", 0)
	_Updater_FailSwapTransaction(TransactionId, Message, false)
	_Updater_ScheduleLifecycleRecoveryReload(true)
	return true
}

; Called immediately after the final shutdown refusal gate. Once this returns
; true, every remaining OnExit action is best-effort: the exact live child owns
; the authorized transaction and _Updater_AbortStagingOnExit can no longer kill
; it accidentally.
_Updater_TransferExitIntentAfterShutdownGates() {
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterDownloadInProgress, _UpdaterDownloadArtifacts
	global _UpdaterDownloadStartedTick
	Owner := _Updater_ExitInvocationOwner()
	if !(Owner is Map)
		return true
	TransactionId := Owner.Get("Id", 0)
	Transferred := false
	PreviousCritical := Critical("On")
	try {
		Current := _Updater_ExitInvocationOwner(TransactionId)
		if (Current is Map and Current == Owner
			and _Updater_ExitIntentStillAuthorized(Current)) {
			_UpdaterSwapOwner := 0
			_UpdaterExitIntent := 0
			_UpdaterExitInvocation := 0
			_UpdaterDownloadInProgress := false
			_UpdaterDownloadArtifacts := 0
			_UpdaterDownloadStartedTick := 0
			Transferred := true
		}
	} finally {
		Critical(PreviousCritical)
	}
	if !Transferred {
		_Updater_FailSwapTransaction(TransactionId,
			"suspend state, ownership, or exact-child liveness revoked final transfer",
			false)
		return false
	}
	_Updater_CloseSwapOwner(Owner, false)
	try LoggerInfo("Updater", "Swap transaction {1} transferred to the acknowledged child after all shutdown gates.", TransactionId)
	return true
}

; The download guard spans HTTP polling, response persistence, integrity checks,
; swap-script creation, and the successful replacement hand-off. Releasing it
; merely because WaitForResponse completed admits a second updater transaction
; while both callbacks still target the same staging filenames.
_Updater_EndDownloadTransaction(StagingEpoch := 0) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadRequest, _UpdaterSelfUpdateEpoch
	global _UpdaterDownloadArtifacts, _UpdaterDownloadStartedTick
	PreviousCritical := Critical("On")
	try {
		if (StagingEpoch and _UpdaterSelfUpdateEpoch != StagingEpoch)
			return false
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadRequest := 0
		_UpdaterDownloadArtifacts := 0
		_UpdaterDownloadStartedTick := 0
	} finally {
		Critical(PreviousCritical)
	}
	try SetTimer((*) => _Updater_RebuildMenu(), -50)
	return true
}
