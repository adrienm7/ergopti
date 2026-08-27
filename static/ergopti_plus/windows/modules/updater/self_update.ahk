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

; Parses the release object and returns the exact asset URL plus the SHA-256
; digest authenticated by GitHub's release API. Asset objects contain nested
; metadata, so a flat-object regex cannot identify their field boundary safely.
; Returns 0 on malformed, unauthenticated or unusable input.
_Updater_FindAsset(Json, AssetName) {
	if !(Json is String) || !(AssetName is String) || (AssetName == "")
		return 0
	try Release := JsonParse(Json)
	catch {
		return 0
	}
	if !(Release is Map) || !Release.Has("assets")
		return 0
	Assets := Release["assets"]
	if !(Assets is Array)
		return 0
	for _, Asset in Assets {
		if !(Asset is Map)
			continue
		if !Asset.Has("name") || !Asset.Has("browser_download_url")
			continue
		Name := Asset["name"]
		Url := Asset["browser_download_url"]
		if !(Name is String) || (Name !== AssetName)
			continue
		if !(Url is String) || (Url == "") || !Asset.Has("digest")
			return 0
		DigestField := Asset["digest"]
		if !(DigestField is String)
			return 0
		if !RegExMatch(DigestField, "i)^sha256:([0-9a-f]{64})$", &Match)
			return 0
		return { Url: Url, Digest: StrLower(Match[1]) }
	}
	return 0
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
	; Fire once shortly after boot (capped by the configured interval) so short
	; presets like "1m" are honoured without an extra-long initial wait.
	FirstMs := Min(30000, Max(1000, UPDATER_CHECK_INTERVAL * 1000))
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
	try LoggerInfo("Updater", "Background update checks armed (every {1}s).", UPDATER_CHECK_INTERVAL)
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
	; Re-arm first so a thrown error below cannot leave the loop dead.
	if !_Updater_ArmBackgroundOwner(
		Owner, -UPDATER_CHECK_INTERVAL * 1000) {
		; Retire only the owner whose arm failed. A yielding scheduler may already
		; have run Stop -> Start and installed a successor.
		if Updater_StopBackgroundChecks(false, Owner)
			try LoggerError("Updater", "Could not rearm background update timer: {1}.",
				Owner.LastArmError)
		return false
	}
	; Pause invariant: a suspended driver must be fully silent. SetTimer
	; callbacks are not gated by native Suspend, so we re-arm above (so the
	; loop survives pause and resumes cleanly) but skip the network dispatch,
	; the TrayTip and the tray-menu rebuild while suspended.
	if A_IsSuspended
		return
	if !_Updater_BackgroundMayDispatch(, Owner)
		return
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
	if _Updater_JsonPayloadIsFailure(Json) {
		try LoggerDebug("Updater", "Background check: network unreachable.")
		return
	}
	Latest := Updater_ParseTagName(Json)
	if (Latest == "" or !_Updater_ShouldOfferCandidate(
		Latest, Current, Request.Channel, _Updater_InstalledChannel())) {
		try LoggerDebug("Updater", "Background check: up to date ({1}).", Current)
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
	if !IsObject(Reservation)
		return
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
		TrayTip(Format(t("updater.tray_new_version_body"), Latest), t("updater.tray_new_version_title"))
		_Updater_CommitReleaseNotification(Reservation, Request)
	} catch as Err {
		_Updater_ReleaseNotificationReservation(Reservation)
		try LoggerError("Updater", "Could not surface background update notification: {1}.", Err.Message)
	}
}

; Wires an OnMessage handler so clicking a Windows balloon notification fires
; Updater_ShowAvailableUpdate. AHK v2 does not expose a dedicated TrayTip-click
; callback, but Windows posts WM_TRAYICON (0x404) with lParam == 0x405
; (NIN_BALLOONUSERCLICK) when the user clicks the notification body.
; Safe to call multiple times — the handler is idempotent (OnMessage replaces
; any prior registration for the same message + function pair).
Updater_InitTrayNotifyHandler() {
	; maxThreads=1: no reentrant update prompts.
	OnMessage(0x404, _Updater_OnTrayMsg, 1)
	try LoggerDebug("Updater", "Tray notification click handler registered.")
}

; OnMessage handler for WM_TRAYICON (0x404).
; lParam 0x405 = NIN_BALLOONUSERCLICK — user clicked the notification body.
; Returns "" to let AHK continue its own tray processing.
_Updater_OnTrayMsg(wParam, lParam, msg, hwnd, ShowFn := 0) {
	; OnMessage bypasses native Suspend, so every genuine click must reach the
	; same visible entry policy as the tray-menu action instead of disappearing.
	if (lParam == 0x405) {
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
global _UpdaterStagingTransportCounter := 0
global UPDATER_STAGING_ENV_MAX_CHARS := 7000
global _UpdaterSwapOwner := 0
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
		MsgBox(t("updater.install_error") . "`n`n" . Terminal,
			t("updater.title_update"), "Icon!")
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
		try _Updater_PromptGui.Restore()
		if !_Updater_RequestMayPublish(Request) {
			_Updater_CloseGui(_Updater_PromptGui)
			return
		}
		try WinActivate(_Updater_PromptGui.Hwnd)
		if !_Updater_RequestMayPublish(Request)
			_Updater_CloseGui(_Updater_PromptGui)
		return
	}
	G := Gui("+Resize +MinSize720x420 +AlwaysOnTop", t("updater.update_dialog_title"))
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

	; Spin up WebView2 for Markdown rendering after Show() (Hwnd is valid then).
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
			WVC.CoreWebView2.NavigateToString(_Updater_MakeMarkdownHtml(Release.Body))
		}
	}
	if (!UseWV or !IsSet(WVC)) {
		; Fallback: replace the placeholder with a plain read-only Edit.
		BodyPane.GetPos(&bx, &by, &bw, &bh)
		BodyText := (Release.Body != "") ? _Updater_MarkdownToPlain(Release.Body) : t("updater.changelog_empty")
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
		MsgBox(t("updater.local_source"), t("updater.title_update"), "Iconi")
		return
	}
	; No cached release — fetch one ASYNCHRONOUSLY so the network round-trip
	; never blocks the AHK main thread (a synchronous WinHttp.Send here would
	; freeze keyboard remapping and drop keystrokes for the whole resolve /
	; connect / receive budget on a stalled or captive-portal network). ``T2``
	; auto-dismisses the brief "Verification…" notice; the actual update prompt
	; is surfaced from the async callback once the response arrives.
	MsgBox(Format(t("updater.checking"), UPDATER_CHANNEL), t("updater.title_update"), "Iconi T2")
	_Updater_FetchLatestJsonAsync(UPDATER_CHANNEL, Request,
		(Json, CompletedRequest, Terminal := 0) => _Updater_ShowAvailableUpdateCallback(
			Json, CompletedRequest, Terminal))
}

; Completion handler for the async fetch dispatched by Updater_ShowAvailableUpdate
; when no release is cached. Mirrors the synchronous tail it replaced: surfaces a
; localized error on failure, otherwise builds the release record and shows the
; update prompt. Runs off a poll timer so it never blocks the main thread.
_Updater_ShowAvailableUpdateCallback(Json, Request, Terminal := 0, NotifyFn := 0) {
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
			MsgBox(t("updater.no_connection"), t("updater.title_update"), "Icon!")
		return
	}
	Tag := Updater_ParseTagName(Json)
	if (Tag == "") {
		if !_Updater_RequestMayPublish(Request)
			return
		MsgBox(t("updater.parse_failed"), t("updater.title_update"), "Icon!")
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
	Updater_ShowUpdatePrompt(Release, Request)
}



; =====================================================
; ===== 2.4) Download + swap (binary replacement) =====
; =====================================================

; Dispatches the whole staging transaction to a child process. AHK's one
; interpreter thread is also the keyboard hook thread, so response-body COM,
; disk persistence, integrity checks and swap-script creation must never run here.
; This side only validates the request, launches/polls the worker and performs
; the final non-blocking process hand-off after the worker reports READY.
_Updater_TryReserveDownloadTransaction(Request, BoundarySuspended) {
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	global _UpdaterDownloadRequest, _UpdaterRecoveryPublishTarget
	global UPDATER_REQUEST_POLICY_ALLOW
	Outcome := {
		Reserved: false,
		ShouldDrop: false,
		RecoveryBusy: false,
		DuplicateDownload: false,
		Epoch: 0
	}
	PreviousCritical := Critical("On")
	try {
		if (_Updater_RequestPolicy(Request, BoundarySuspended)
			!= UPDATER_REQUEST_POLICY_ALLOW) {
			Outcome.ShouldDrop := true
		} else if (_UpdaterRecoveryPublishTarget != "") {
			Outcome.RecoveryBusy := true
		} else if _UpdaterDownloadInProgress {
			Outcome.DuplicateDownload := true
		} else {
			_UpdaterDownloadInProgress := true
			Outcome.Epoch := ++_UpdaterSelfUpdateEpoch
			_UpdaterDownloadRequest := Request
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
_Updater_BeginDownloadTransaction(Request, BoundarySuspended, Tag, AssetUrl) {
	try LoggerStart("Updater", "Downloading update '{1}' from {2}…", Tag, AssetUrl)
	try {
		Outcome := _Updater_TryReserveDownloadTransaction(
			Request, BoundarySuspended)
	} catch as Err {
		try LoggerError("Updater", "Download reservation failed after START: {1}.", Err.Message)
		throw Err
	}
	if Outcome.Reserved
		return Outcome
	if Outcome.ShouldDrop {
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

Updater_DownloadAndInstall(Release, Request := unset, IsSuspended := unset, RebuildFn := 0, NotifyFn := 0) {
	global BUNDLE_RELEASE_ASSET
	global _UpdaterDownloadInProgress
	global _UpdaterRecoveryPublishTarget, UPDATER_REQUEST_ORIGIN_MANUAL
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
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
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
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
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
		return false
	}
	AssetName := IsSet(BUNDLE_RELEASE_ASSET) and BUNDLE_RELEASE_ASSET != ""
		? BUNDLE_RELEASE_ASSET : "ErgoptiPlus.exe"
	Asset := _Updater_FindAsset(Release.RawJson, AssetName)
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
		MsgBox(t("updater.install_error_no_asset"), t("updater.title_update"), "Icon!")
		return false
	}
	AssetUrl := Asset.Url
	if !A_IsCompiled {
		; Running from source — replacing the .ahk would be wrong, and the
		; user is almost certainly developing on this very tree. Bail with a
		; friendly note rather than silently doing nothing.
		if HasSuspendOverride {
			if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
				return false
		} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
			return false
		}
		MsgBox(t("updater.install_local_source"), t("updater.title_update"), "Iconi")
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
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
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
		Request, BoundarySuspended, Release.Tag, AssetUrl)
	if Reservation.ShouldDrop {
		_Updater_RequestMayPublish(Request, BoundarySuspended, NotifyFn)
		return false
	}
	if Reservation.RecoveryBusy {
		if _Updater_RequestMayPublish(Request, BoundarySuspended, NotifyFn)
			MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
		return false
	}
	if Reservation.DuplicateDownload
		return false
	if !Reservation.Reserved
		return false
	StagingEpoch := Reservation.Epoch
	if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
		return false

	_Updater_StartStagingWorker(AssetUrl, Asset.Digest, NewExe, SwapScriptPath,
		CurrentExe, Release.Tag, StagingEpoch)
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
	MinimumSize, TimeoutMs) {
	global _UpdaterStagingTransportCounter, UPDATER_STAGING_ENV_MAX_CHARS
	_UpdaterStagingTransportCounter += 1
	Prefix := "ERGOPTI_UPDATER_" . DllCall("GetCurrentProcessId", "UInt")
		. "_" . A_TickCount . "_" . _UpdaterStagingTransportCounter
	ScriptPayload := _Updater_EncodePowerShellCommand(Script)
	SwapScriptPayload := _Updater_EncodeUtf8Payload(SwapScript)
	if (ScriptPayload == ""
		or StrLen(ScriptPayload) > UPDATER_STAGING_ENV_MAX_CHARS)
		throw ValueError("Encoded staging worker exceeds the environment transport budget")
	if (SwapScriptPayload == "")
		throw ValueError("Encoded swap worker is empty")
	Environment := [
		{ Name: Prefix . "_SCRIPT", Value: ScriptPayload },
		{ Name: Prefix . "_URL", Value: AssetUrl },
		{ Name: Prefix . "_DIGEST", Value: ExpectedSha256 },
		{ Name: Prefix . "_NEW_EXE", Value: NewExe },
		{ Name: Prefix . "_SWAP_PATH", Value: SwapScriptPath },
		{ Name: Prefix . "_CURRENT", Value: CurrentExe },
		{ Name: Prefix . "_MINIMUM", Value: MinimumSize },
		{ Name: Prefix . "_TIMEOUT", Value: TimeoutMs }
	]
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
		. '$source=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($env:' . Prefix . '_SCRIPT));'
		. '$swapPayload=' . Chr(39) . Chr(39) . ';'
		. 'for($i=1;$i -le [int]$env:' . Prefix . '_SWAP_COUNT;$i++){$swapPayload+=[Environment]::GetEnvironmentVariable(' . Chr(39) . Prefix . '_SWAP_' . Chr(39) . '+$i)};'
		. '$worker=[ScriptBlock]::Create($source);'
		. '& $worker $env:' . Prefix . '_URL $env:' . Prefix . '_DIGEST $env:' . Prefix . '_NEW_EXE $env:' . Prefix . '_SWAP_PATH $env:' . Prefix . '_CURRENT'
		. ' ([int64]$env:' . Prefix . '_MINIMUM) ([int]$env:' . Prefix . '_TIMEOUT'
		. ') $swapPayload'
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

_Updater_StartStagingWorker(AssetUrl, ExpectedSha256, NewExe, SwapScriptPath, CurrentExe, Tag, StagingEpoch) {
	global _UpdaterDownloadWorker, UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS, UPDATER_MIN_EXE_SIZE_BYTES
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	StagingScript := _Updater_BuildStagingWorkerScript()
	SwapScript := _Updater_BuildSwapWorkerScript()
	_OnDone := (ExitCode, Stdout, Stderr) => _Updater_PollDownloadAsync(
		ExitCode, Stdout, Stderr, SwapScriptPath, NewExe, CurrentExe, Tag,
		StagingEpoch)
	Transport := 0
	Worker := 0
	Started := false
	Published := false
	StartError := ""
	try {
		Transport := _Updater_BuildStagingTransport(
			StagingScript, SwapScript, AssetUrl, ExpectedSha256, NewExe, SwapScriptPath, CurrentExe,
			UPDATER_MIN_EXE_SIZE_BYTES, UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS)
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
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
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
		return
	_Updater_CancelSelfUpdateForSuspend()
}

_Updater_SelfUpdateEpochIsCurrent(StagingEpoch) {
	global _UpdaterDownloadInProgress, _UpdaterSelfUpdateEpoch
	PreviousCritical := Critical("On")
	try return _UpdaterDownloadInProgress
		and _UpdaterSelfUpdateEpoch == StagingEpoch
	finally Critical(PreviousCritical)
}

; Suspend entry is an event, not a state that a 250 ms poll may sample later.
; Take every in-process owner synchronously and invalidate queued READY callbacks
; before returning to the suspend transition. Native termination happens outside
; Critical, using each adapter/owner's exact process or Job handles.
_Updater_CancelSelfUpdateForSuspend() {
	return _Updater_CancelSelfUpdateTransaction(
		"Update transaction synchronously aborted on suspend entry.", true, true)
}

_Updater_CancelSelfUpdateTransaction(LogMessage, RebuildMenu := true, SurfacePausedRequest := false) {
	global _UpdaterDownloadInProgress, _UpdaterDownloadWorker
	global _UpdaterDownloadRequest
	global _UpdaterSwapOwner, _UpdaterExitIntent, _UpdaterExitInvocation
	global _UpdaterSelfUpdateEpoch
	Worker := 0
	Owner := 0
	Request := 0
	HadTransaction := false
	PreviousCritical := Critical("On")
	try {
		HadTransaction := _UpdaterDownloadInProgress
			or IsObject(_UpdaterDownloadWorker) or (_UpdaterSwapOwner is Map)
			or IsObject(_UpdaterDownloadRequest)
		Worker := IsObject(_UpdaterDownloadWorker) ? _UpdaterDownloadWorker : 0
		Owner := (_UpdaterSwapOwner is Map) ? _UpdaterSwapOwner : 0
		Request := IsObject(_UpdaterDownloadRequest) ? _UpdaterDownloadRequest : 0
		_UpdaterDownloadWorker := 0
		_UpdaterDownloadRequest := 0
		_UpdaterSwapOwner := 0
		_UpdaterExitIntent := 0
		_UpdaterExitInvocation := 0
		_UpdaterDownloadInProgress := false
		_UpdaterSelfUpdateEpoch += 1
	} finally {
		Critical(PreviousCritical)
	}
	if IsObject(Worker)
		try Worker.terminate()
	if (Owner is Map)
		_Updater_CloseSwapOwner(Owner, true)
	SetTimer(_Updater_MonitorStagingWorker, 0)
	; Process teardown wins before the visible terminal. RequestMayPublish queues
	; exactly one manual notice for resume; a second cancellation has no Request.
	if SurfacePausedRequest and IsObject(Request)
		_Updater_RequestMayPublish(Request, true)
	if HadTransaction {
		try LoggerError("Updater", LogMessage)
		if RebuildMenu
			try TimerArmOneShotMs((*) => _Updater_RebuildMenu(), 50)
	}
	return HadTransaction
}

; The only staging completion callback running in AHK. The worker's READY
; token means it has already persisted and verified the executable plus the
; UTF-8 PowerShell swap worker.
_Updater_PollDownloadAsync(ExitCode, Stdout, Stderr, SwapScriptPath, NewExe, CurrentExe, Tag, StagingEpoch) {
	global _UpdaterDownloadWorker
	if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
		return
	_UpdaterDownloadWorker := 0
	SetTimer(_Updater_MonitorStagingWorker, 0)
	if A_IsSuspended {
		try LoggerWarn("Updater", "Update staging completion discarded while suspended.")
		_Updater_EndDownloadTransaction(StagingEpoch)
		return
	}
	if (ExitCode != 0 or Stdout != "READY") {
		try LoggerError("Updater", "Update staging worker failed (exit {1}): {2}.", ExitCode, Stdout)
		MsgBox(t("updater.install_error_download"), t("updater.title_update"), "Icon!")
		_Updater_EndDownloadTransaction(StagingEpoch)
		return
	}
	try LoggerSuccess("Updater", "Update downloaded and verified for '{1}'.", Tag)
	if !_Updater_StartSwapTransaction(SwapScriptPath, NewExe, CurrentExe, Tag,
		StagingEpoch) {
		if !_Updater_SelfUpdateEpochIsCurrent(StagingEpoch)
			return
		MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
		_Updater_EndDownloadTransaction(StagingEpoch)
		return
	}
	global UPDATER_LAST_NOTIFIED_TAG := ""
}

; Returns a self-contained worker script. Paths and URLs are passed as argv,
; never interpolated into the script, so release metadata cannot alter commands.
_Updater_BuildStagingWorkerScript() {
	return 'param([string]$Url, [string]$ExpectedSha256, [string]$NewExe, [string]$SwapScriptPath, [string]$CurrentExe, [int64]$MinimumSize, [int]$TimeoutMs, [string]$SwapScriptPayload)' . "`n"
		. '$ErrorActionPreference = "Stop"' . "`n"
		. 'try {' . "`n"
		. '  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $NewExe) | Out-Null' . "`n"
		. '  Remove-Item -LiteralPath $NewExe -Force -ErrorAction SilentlyContinue' . "`n"
		. '  Remove-Item -LiteralPath $SwapScriptPath -Force -ErrorAction SilentlyContinue' . "`n"
		. '  $Request = [System.Net.HttpWebRequest]::Create($Url)' . "`n"
		. '  $Request.Method = "GET"' . "`n"
		. '  $Request.UserAgent = "ErgoptiPlus-Updater/1.0"' . "`n"
		. '  $Request.Timeout = $TimeoutMs' . "`n"
		. '  $Request.ReadWriteTimeout = $TimeoutMs' . "`n"
		. '  $Response = $Request.GetResponse()' . "`n"
		. '  if ([int]$Response.StatusCode -ne 200) { throw ("HTTP " + [int]$Response.StatusCode) }' . "`n"
		. '  $ExpectedSize = [int64]$Response.ContentLength' . "`n"
		. '  $Input = $Response.GetResponseStream()' . "`n"
		. '  $Output = [System.IO.File]::Open($NewExe, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)' . "`n"
		. '  try { $Input.CopyTo($Output) } finally { $Output.Dispose(); $Input.Dispose(); $Response.Dispose() }' . "`n"
		. '  $ActualSize = (Get-Item -LiteralPath $NewExe).Length' . "`n"
		. '  if ($ExpectedSize -gt 0 -and $ActualSize -ne $ExpectedSize) { Remove-Item -LiteralPath $NewExe -Force; throw "Content-Length mismatch" }' . "`n"
		. '  if ($ActualSize -lt $MinimumSize) { Remove-Item -LiteralPath $NewExe -Force; throw "Downloaded file is too small" }' . "`n"
		. '  if ($ExpectedSha256 -cnotmatch "^[0-9a-f]{64}$") { Remove-Item -LiteralPath $NewExe -Force; throw "Missing or invalid trusted SHA-256 digest" }' . "`n"
		. '  $ActualDigest = (Get-FileHash -LiteralPath $NewExe -Algorithm SHA256).Hash.ToLowerInvariant()' . "`n"
		. '  if ($ActualDigest -cne $ExpectedSha256) { Remove-Item -LiteralPath $NewExe -Force; throw "SHA-256 digest mismatch" }' . "`n"
		. '  $SwapSource = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($SwapScriptPayload))' . "`n"
		. '  $Utf8 = [Text.UTF8Encoding]::new($false)' . "`n"
		. '  [System.IO.File]::WriteAllText($SwapScriptPath, $SwapSource, $Utf8)' . "`n"
		. '  Write-Output "READY"' . "`n"
		. '  exit 0' . "`n"
		. '} catch {' . "`n"
		. '  try { if ($NewExe -and (Test-Path -LiteralPath $NewExe)) { Remove-Item -LiteralPath $NewExe -Force } } catch {}' . "`n"
		. '  try { if ($SwapScriptPath -and (Test-Path -LiteralPath $SwapScriptPath)) { Remove-Item -LiteralPath $SwapScriptPath -Force } } catch {}' . "`n"
		. '  Write-Output ("ERR:" + $_.Exception.Message)' . "`n"
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

_Updater_CloseNativeSwapHandle(Handle) {
	if !Handle
		return true
	if PLC_CloseNativeHandle(Handle)
		return true
	try LoggerError("Updater", "CloseHandle failed for updater handle {1}.", Handle)
	return false
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
		return
	; Take-and-zero before TerminateProcess. A stale callback may still hold the
	; same Owner Map; reading first and closing later would let that callback use
	; a closed HANDLE value after Windows had already recycled it.
	ProcessHandles := _Updater_TakeSwapProcessHandles(Owner)
	ProcessHandle := ProcessHandles[1]
	ThreadHandle := ProcessHandles[2]
	if (TerminateChild and ProcessHandle) {
		if !PLC_TerminateProcessHandle(ProcessHandle)
			try LoggerError("Updater", "TerminateProcess failed for swap worker transaction {1}.", Owner.Get("Id", 0))
	}
	_Updater_CloseNativeSwapHandle(ProcessHandle)
	_Updater_CloseNativeSwapHandle(ThreadHandle)
	for Name in ["ParentHandle", "ReadyHandle",
		"CommitHandle", "AckHandle", "FinalExitHandle"] {
		Handle := _Updater_TakeSwapHandle(Owner, Name)
		_Updater_CloseNativeSwapHandle(Handle)
	}
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
		return
	ProcessInfo := Handles.Get("ProcessInfo", 0)
	ProcessHandle := ProcessInfo is Buffer ? NumGet(ProcessInfo, 0, "Ptr") : 0
	ThreadHandle := ProcessInfo is Buffer ? NumGet(ProcessInfo, A_PtrSize, "Ptr") : 0
	if (ProcessInfo is Buffer) {
		NumPut("Ptr", 0, ProcessInfo, 0)
		NumPut("Ptr", 0, ProcessInfo, A_PtrSize)
	}
	Handles["ProcessInfo"] := 0
	if (TerminateChild and ProcessHandle)
		PLC_TerminateProcessHandle(ProcessHandle)
	_Updater_CloseNativeSwapHandle(ProcessHandle)
	_Updater_CloseNativeSwapHandle(ThreadHandle)
	for Name in ["ParentHandle", "ReadyHandle",
		"CommitHandle", "AckHandle", "FinalExitHandle"] {
		Handle := Handles.Get(Name, 0)
		Handles[Name] := 0
		_Updater_CloseNativeSwapHandle(Handle)
	}
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
		try MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
	} else {
		TimerArmOneShotMs(_Updater_ShowDeferredSwapFailureNotice, 1)
	}
	_Updater_EndDownloadTransaction(StagingEpoch)
}

; OnExit must return before user-visible UI or a recovery Reload can run. A
; named timer coalesces the failure notice and guarantees that a post-teardown
; reload happens only after the user has seen the updater failure.
_Updater_ShowDeferredSwapFailureNotice(*) {
	NotifyFn := (*) => TrayTip(t("updater.install_error"),
		t("updater.title_update"), "Iconx Mute")
	ArmRetryFn := (DelayMs) => TimerArmOneShotMs(
		_Updater_ShowDeferredSwapFailureNotice, DelayMs)
	if _Updater_AttemptLifecycleRecovery(NotifyFn, ArmRetryFn,
		ReloadPreservingSuspend)
		return
	try MsgBox(t("updater.install_error"), t("updater.title_update"), "Icon!")
}

; A successful Reload destroys this process and therefore its pre-armed timer.
; If Reload returns because OnExit refused again, or the suspend marker could
; not be published, Pending remains the sole recovery owner and the timer tries
; again with a capped backoff. There is deliberately no in-place "success"
; state: KL_BeginShutdown and watcher teardown are terminal in this process.
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
	try ArmRetryFn.Call(RetryDelayMs)
	catch as Err
		try LoggerError("Updater", "Lifecycle recovery retry could not be armed: {1}.", Err.Message)
	try ReloadFn.Call()
	catch as Err
		try LoggerError("Updater", "Lifecycle recovery Reload failed after swap cancellation: {1}.", Err.Message)
	return true
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

_Updater_PollSwapHandshake(TransactionId) {
	global UPDATER_SWAP_READY_TIMEOUT_MS, UPDATER_SWAP_ACK_TIMEOUT_MS
	Owner := _Updater_CurrentSwapOwner(TransactionId)
	if !(Owner is Map)
		return
	if A_IsSuspended {
		_Updater_FailSwapTransaction(TransactionId,
			"the driver was suspended before the swap handshake completed")
		return
	}
	ProcessState := _Updater_WaitSwapOwnerHandleState(Owner, "ProcessHandle")
	if (ProcessState != 0) {
		_Updater_FailSwapTransaction(TransactionId,
			ProcessState == 1 ? "the swap worker exited before ownership transfer"
				: "the exact swap-worker process handle could not be queried")
		return
	}
	Phase := Owner.Get("Phase", "")
	if (Phase == "AwaitReady") {
		ReadyState := _Updater_WaitSwapOwnerHandleState(Owner, "ReadyHandle")
		if (ReadyState < 0) {
			_Updater_FailSwapTransaction(TransactionId, "the Ready event could not be queried")
			return
		}
		if (ReadyState == 0) {
			if TickExpired(Owner.Get("PhaseStartedTick", A_TickCount),
				UPDATER_SWAP_READY_TIMEOUT_MS) {
				_Updater_FailSwapTransaction(TransactionId, "the Ready event timed out")
				return
			}
			_Updater_ArmSwapHandshakePoll(TransactionId)
			return
		}
		if !_Updater_SetSwapOwnerEvent(Owner, "CommitHandle") {
			_Updater_FailSwapTransaction(TransactionId, "the Commit event could not be signaled")
			return
		}
		if !_Updater_SetSwapPhase(TransactionId, "AwaitAck")
			return
		_Updater_ArmSwapHandshakePoll(TransactionId)
		return
	}
	if (Phase != "AwaitAck") {
		_Updater_FailSwapTransaction(TransactionId, "the swap handshake entered an invalid phase")
		return
	}
	AckState := _Updater_WaitSwapOwnerHandleState(Owner, "AckHandle")
	if (AckState < 0) {
		_Updater_FailSwapTransaction(TransactionId, "the Ack event could not be queried")
		return
	}
	if (AckState == 0) {
		if TickExpired(Owner.Get("PhaseStartedTick", A_TickCount),
			UPDATER_SWAP_ACK_TIMEOUT_MS) {
			_Updater_FailSwapTransaction(TransactionId, "the Ack event timed out")
			return
		}
		_Updater_ArmSwapHandshakePoll(TransactionId)
		return
	}
	; Ack is only authority to request shutdown while the exact child remains
	; alive. The OnExit handler performs the same check again immediately before
	; publishing FinalExit and once more before ownership transfer.
	if (_Updater_WaitSwapOwnerHandleState(Owner, "ProcessHandle") != 0) {
		_Updater_FailSwapTransaction(TransactionId, "the swap worker died after Ack")
		return
	}
	if !_Updater_PublishExitIntent(TransactionId, Owner) {
		_Updater_FailSwapTransaction(TransactionId, "the updater exit intent could not be published atomically")
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
	global _UpdaterDownloadInProgress
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
	PreviousCritical := Critical("On")
	try {
		if (StagingEpoch and _UpdaterSelfUpdateEpoch != StagingEpoch)
			return false
		_UpdaterDownloadInProgress := false
		_UpdaterDownloadRequest := 0
	} finally {
		Critical(PreviousCritical)
	}
	try SetTimer((*) => _Updater_RebuildMenu(), -50)
	return true
}
