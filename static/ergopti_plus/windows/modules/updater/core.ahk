; modules/updater/core.ahk

; ==============================================================================
; MODULE: Updater / Config + Version + Release Fetch
; DESCRIPTION:
; Updater constants, channel and check-interval config, semantic-version parsing and comparison, GitHub Releases API URLs, and the (sync + async) latest-release / releases-list fetch and JSON parsing.
;
; Split out of modules/updater.ahk (the module split); see modules/updater.ahk for the module
; overview. Functions and globals are hoisted, so load order across the
; updater/*.ahk files is irrelevant.
; ==============================================================================



; =====================================
; ===== 1.1) Constants & Defaults =====
; =====================================

global UPDATER_GH_OWNER  := "adrienm7"
global UPDATER_GH_REPO   := "ergopti"
global UPDATER_CHANNEL   := "main"    ; overwritten by Updater_LoadChannel()
global UPDATER_INI_KEY   := "channel"
global UPDATER_INI_SECTION := "updater"

; Background update-check interval. 0 means "never" (disabled). The default
; 24h cadence is a sensible balance between freshness and network restraint
; — most users do not want a release-day notification but appreciate hearing
; about a security fix within the same day. Honoured by ``Updater_StartBackgroundChecks``.
global UPDATER_INI_INTERVAL_KEY    := "check_interval_seconds"
global UPDATER_DEFAULT_INTERVAL    := 86400
global UPDATER_CHECK_INTERVAL      := UPDATER_DEFAULT_INTERVAL

; WinHttp timeout budget (ms) for the synchronous GitHub Releases / asset calls.
; EVERY phase must be finite: WinHttp treats 0 as "infinite", so a stalled DNS
; resolve (a connecting VPN, a captive portal, a dead resolver) blocks the
; synchronous call — and therefore the AHK main thread, and therefore ALL
; keyboard remapping — until the network recovers. The resolve phase used to be
; passed as 0 here, which is exactly how the background check could freeze the
; driver a few seconds after startup. Bounding every phase turns a permanent
; freeze into a brief, self-healing hiccup on a flaky network.
global UPDATER_HTTP_RESOLVE_TIMEOUT_MS := 5000     ; DNS resolution
global UPDATER_HTTP_CONNECT_TIMEOUT_MS := 15000    ; TCP connect
global UPDATER_HTTP_SEND_TIMEOUT_MS    := 30000    ; request send
global UPDATER_HTTP_RECEIVE_TIMEOUT_MS := 30000    ; response receive
; The download phase streams a multi-MB binary asset, so it needs a far larger receive
; budget than the tiny JSON API calls above. Reusing the 30 s API value made the
; WinHttpRequest receive timeout abort the transfer at 30 s on slow/metered links,
; defeating the 600 s SetTimer poll ceiling (updater-download-receive-timeout).
global UPDATER_HTTP_DOWNLOAD_RECEIVE_TIMEOUT_MS := 600000  ; binary download receive
; Absolute wall-clock owner for the complete download transaction. Per-read
; timeouts do not stop a peer that sends one byte before every read deadline.
global UPDATER_HTTP_DOWNLOAD_DEADLINE_MS := 1200000

; Floor for the downloaded exe size (512 KB). A real ErgoptiPlus binary is
; several MB; anything below this is certainly a partial download or a CDN
; error page and must not be swapped in as the production exe.
global UPDATER_MIN_EXE_SIZE_BYTES := 524288

; In-flight async background-check requests, keyed by an incrementing id. Each
; value owns transport, callback, polling and the exact operation lease that
; linearizes cancellation against every yielding WinHTTP effect.
; The background poller dispatches through here so its network round-trip runs
; in WinHTTP async mode and is harvested by a poll timer — the synchronous call
; that used to block (and freeze) the main thread near startup is gone for the
; unprompted path. See _Updater_FetchLatestJsonAsync / _Updater_PollAsync.
global _UpdaterAsyncRequests := Map()
global _UpdaterAsyncCounter  := 0
global _UpdaterActiveSendLeaseCount := 0
global _UpdaterActiveAsyncTerminalDeliveryCount := 0
global _UpdaterAsyncAdmissionBoundary := 0
global _UpdaterAsyncActionLeases := Map()
global _UpdaterAsyncActionLeaseCounter := 0
global _UpdaterChannelReloadTransition := 0
global _UpdaterChannelReloadCounter := 0
global UPDATER_CHANNEL_RELOAD_POLL_MS := 25
global UPDATER_CHANNEL_RELOAD_QUIESCE_TIMEOUT_MS := 10000

; Immutable provenance carried by every asynchronous updater request. Manual
; work born while paused is refused at the entry point; work born running is
; invalidated by the first later suspend boundary.
global UPDATER_REQUEST_ORIGIN_BACKGROUND := "background"
global UPDATER_REQUEST_ORIGIN_MANUAL     := "manual"
global UPDATER_REQUEST_POLICY_ALLOW      := "allow"
global UPDATER_REQUEST_POLICY_DROP       := "drop"
global UPDATER_REQUEST_POLICY_NOTIFY     := "notify"
global UPDATER_CANCEL_REASON_SUSPEND     := "suspend"
global UPDATER_CANCEL_REASON_CHANNEL_SWITCH := "channel switch"
global UPDATER_ASYNC_TERMINAL_CANCELLED  := "cancelled"
global _UpdaterPauseGeneration          := 0
global _UpdaterBackgroundGeneration     := 0
global _UpdaterChannelEpoch             := 1
global _UpdaterRequestCounter           := 0
global _UpdaterPendingManualPauseNoticeCount := 0
global _UpdaterPendingManualPauseNoticeIds := Map()
global _UpdaterMenuRebuildPending       := false

; Cadence + safety cap for polling an async background check to completion. The
; poll only asks "ready yet?" (WaitForResponse(0), 0 = do not wait), so a slack
; interval is fine — freshness does not matter for a silent check. The max-polls
; cap is derived from the timeout budget so a wedged request can never leave a
; poll timer running forever.
global UPDATER_ASYNC_POLL_MS   := 250
global UPDATER_ASYNC_MAX_POLLS := Ceil((UPDATER_HTTP_RESOLVE_TIMEOUT_MS + UPDATER_HTTP_CONNECT_TIMEOUT_MS + UPDATER_HTTP_SEND_TIMEOUT_MS + UPDATER_HTTP_RECEIVE_TIMEOUT_MS) / UPDATER_ASYNC_POLL_MS) + 20

; User-facing presets for the frequency submenu. Kept in display order so the
; menu renders the way users naturally read time: short to long, with the
; "off" row at the very bottom — a destructive choice deserves its own slot.
global UPDATER_INTERVAL_PRESETS := [
	{ Code: "1m",    Seconds: 60      },
	{ Code: "5m",    Seconds: 300     },
	{ Code: "10m",   Seconds: 600     },
	{ Code: "1h",    Seconds: 3600    },
	{ Code: "2h",    Seconds: 7200    },
	{ Code: "3h",    Seconds: 10800   },
	{ Code: "6h",    Seconds: 21600   },
	{ Code: "12h",   Seconds: 43200   },
	{ Code: "24h",   Seconds: 86400   },
	{ Code: "2d",    Seconds: 172800  },
	{ Code: "7d",    Seconds: 604800  },
	{ Code: "never", Seconds: 0       }
]

; Last release tag we already surfaced a notification for, so we don't keep
; nagging the user every interval tick about the same available update. Reset
; only when the user installs (or explicitly dismisses) the offer.
global UPDATER_LAST_NOTIFIED_TAG   := ""
global _UpdaterPendingReleaseNotification := 0

; Latest release record cached from the most recent successful background check.
; Used by the "Show update" tray entry so clicking the notification or the menu
; row does not have to re-hit the GitHub API. Cleared after a successful install.
global UPDATER_LATEST_RELEASE      := unset

; Background timer handle so ``Updater_SetCheckInterval`` can stop the previous
; timer before scheduling a new one with the freshly chosen cadence.
global _UpdaterBackgroundFn        := unset
global _UpdaterBackgroundOwner     := 0
global _UpdaterBackgroundOwnerCounter := 0
global UPDATER_BACKGROUND_ARM_MAX_ATTEMPTS := 2

; Per-channel GitHub API cache for conditional GET (If-None-Match). A 304
; response does not count against the anonymous 60 req/h rate limit, which
; makes short intervals like 1m viable for background polling.
global _UpdaterFetchCache          := Map()

; AHK v2 loosely equates the String "0" with false. Native and injected
; effect seams therefore acknowledge success only with a non-zero Integer.
_Updater_ResultSucceeded(Result) {
	return Type(Result) == "Integer" and Result != 0
}

; Transport payloads are Strings. Keep the valid JSON String "0" distinct
; from the empty String and from non-String failure sentinels.
_Updater_JsonPayloadIsFailure(Json) {
	return !(Json is String) or Json == ""
}

_Updater_JsonPayloadIsUsable(Json) {
	return Json is String and Json != ""
}

; Shared visible failure terminal for updater effects. Notification itself is
; typed so a false, String-zero, or throwing notifier is observable upstream.
_Updater_SurfaceFailure(MessageKey, LogMessage, NotifyFn := 0,
	Level := "error") {
	try LoggerError("Updater", LogMessage)
	try {
		Message := t(MessageKey)
		Options := Map("title", t("updater.title_update"), "level", Level)
		Result := IsObject(NotifyFn)
			? NotifyFn.Call(Message, Options)
			: NotifierSend(Message, Options)
		if !_Updater_ResultSucceeded(Result) {
			try LoggerError("Updater", "Updater failure notification returned an unsuccessful result for key '{1}'.", MessageKey)
			return false
		}
		return true
	} catch as Err {
		try LoggerError("Updater", "Could not surface updater failure '{1}': {2}.", MessageKey, Err.Message)
		return false
	}
}


; One exact channel transition closes HTTP admission across yielding persistence,
; cancellation callbacks and deferred Reload. Opaque identity prevents stale
; cleanup from reopening a successor transition.
_Updater_BeginAsyncAdmissionBoundary(Reason) {
	global _UpdaterAsyncAdmissionBoundary, _UpdaterAsyncActionLeases
	if !(Reason is String) or Reason == ""
		throw ValueError("Updater admission boundary requires a reason")
	Owner := { Reason: Reason }
	PreviousCritical := A_IsCritical
	Published := false
	Critical("On")
	try {
		if (!IsObject(_UpdaterAsyncAdmissionBoundary)
			and _UpdaterAsyncActionLeases.Count == 0) {
			_UpdaterAsyncAdmissionBoundary := Owner
			Published := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Published ? Owner : 0
}

_Updater_EndAsyncAdmissionBoundary(Owner) {
	global _UpdaterAsyncAdmissionBoundary
	if !IsObject(Owner)
		return false
	PreviousCritical := A_IsCritical
	Released := false
	Critical("On")
	try {
		if (IsObject(_UpdaterAsyncAdmissionBoundary)
			and ObjPtr(_UpdaterAsyncAdmissionBoundary) == ObjPtr(Owner)) {
			_UpdaterAsyncAdmissionBoundary := 0
			Released := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Released
}

_Updater_AsyncAdmissionBoundaryReason() {
	global _UpdaterAsyncAdmissionBoundary
	PreviousCritical := A_IsCritical
	Reason := ""
	Critical("On")
	try {
		if (IsObject(_UpdaterAsyncAdmissionBoundary)
			and _UpdaterAsyncAdmissionBoundary.HasOwnProp("Reason")
			and _UpdaterAsyncAdmissionBoundary.Reason is String)
			Reason := _UpdaterAsyncAdmissionBoundary.Reason
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Reason
}

_Updater_AsyncAdmissionBoundaryActive() {
	return _Updater_AsyncAdmissionBoundaryReason() != ""
}

_Updater_AsyncAdmissionBoundaryOwned(Owner) {
	global _UpdaterAsyncAdmissionBoundary
	if !IsObject(Owner)
		return false
	PreviousCritical := A_IsCritical
	Critical("On")
	try return IsObject(_UpdaterAsyncAdmissionBoundary)
		and ObjPtr(_UpdaterAsyncAdmissionBoundary) == ObjPtr(Owner)
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
}

_Updater_NotifyAsyncAdmissionRefusal(Action, Reason, NotifyFn := 0) {
	if !(Action is String) or Action == ""
		Action := "updater action"
	if !(Reason is String) or Reason == ""
		Reason := "channel transition"
	try LoggerWarn("Updater", "{1} refused while async admission is closed ({2}).", Action, Reason)
	try {
		Message := t("updater.channel_transition_busy")
		Options := Map("title", t("updater.title_update"), "level", "warning")
		Result := IsObject(NotifyFn)
			? NotifyFn.Call(Message, Options)
			: NotifierSend(Message, Options)
		if !_Updater_ResultSucceeded(Result)
			try LoggerError("Updater", "Channel-transition refusal notification returned an unsuccessful result.")
	} catch as Err {
		try LoggerError("Updater", "Could not surface channel-transition refusal: {1}.", Err.Message)
	}
	return false
}

; Non-HTTP updater actions can yield in TOML, GUI and staging code just like
; WinHTTP callbacks. An exact action lease makes those effects mutually
; exclusive with channel replacement in the same Critical domain.
_Updater_AcquireAsyncActionLease(Action, NotifyFn := 0) {
	global _UpdaterAsyncAdmissionBoundary, _UpdaterAsyncActionLeases
	global _UpdaterAsyncActionLeaseCounter
	if !(Action is String) or Action == ""
		throw ValueError("Updater action lease requires an action name")
	Owner := 0
	Reason := ""
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if IsObject(_UpdaterAsyncAdmissionBoundary) {
			Reason := _UpdaterAsyncAdmissionBoundary.HasOwnProp("Reason")
				and _UpdaterAsyncAdmissionBoundary.Reason is String
				? _UpdaterAsyncAdmissionBoundary.Reason : "channel transition"
		} else if _UpdaterAsyncActionLeases.Count > 0 {
			for _Id, Incumbent in _UpdaterAsyncActionLeases {
				Reason := (Type(Incumbent) == "Object"
					and Incumbent.HasOwnProp("Action")
					and Incumbent.Action is String)
					? Incumbent.Action : "updater action"
				break
			}
		} else {
			_UpdaterAsyncActionLeaseCounter += 1
			Owner := { Id: _UpdaterAsyncActionLeaseCounter, Action: Action }
			_UpdaterAsyncActionLeases[Owner.Id] := Owner
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !IsObject(Owner)
		_Updater_NotifyAsyncAdmissionRefusal(Action, Reason, NotifyFn)
	return Owner
}

_Updater_ReleaseAsyncActionLease(Owner) {
	global _UpdaterAsyncActionLeases
	if (Type(Owner) != "Object" or !Owner.HasOwnProp("Id"))
		return false
	Released := false
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (_UpdaterAsyncActionLeases.Has(Owner.Id)
			and ObjPtr(_UpdaterAsyncActionLeases[Owner.Id]) == ObjPtr(Owner)) {
			_UpdaterAsyncActionLeases.Delete(Owner.Id)
			Released := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Released
}

_Updater_AsyncActionLeaseOwned(Owner) {
	global _UpdaterAsyncActionLeases
	if (Type(Owner) != "Object" or !Owner.HasOwnProp("Id"))
		return false
	PreviousCritical := A_IsCritical
	Critical("On")
	try return _UpdaterAsyncActionLeases.Has(Owner.Id)
		and ObjPtr(_UpdaterAsyncActionLeases[Owner.Id]) == ObjPtr(Owner)
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
}

_Updater_HandoffAdmissionToActionLease(BoundaryOwner, Action) {
	global _UpdaterAsyncAdmissionBoundary, _UpdaterAsyncActionLeases
	global _UpdaterAsyncActionLeaseCounter
	if !IsObject(BoundaryOwner) or !(Action is String) or Action == ""
		return 0
	Owner := 0
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (IsObject(_UpdaterAsyncAdmissionBoundary)
			and ObjPtr(_UpdaterAsyncAdmissionBoundary) == ObjPtr(BoundaryOwner)) {
			_UpdaterAsyncActionLeaseCounter += 1
			Owner := { Id: _UpdaterAsyncActionLeaseCounter, Action: Action }
			_UpdaterAsyncActionLeases[Owner.Id] := Owner
			_UpdaterAsyncAdmissionBoundary := 0
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Owner
}

_Updater_AsyncTerminalDeliveryActive() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	PreviousCritical := A_IsCritical
	Critical("On")
	try return _UpdaterActiveAsyncTerminalDeliveryCount > 0
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
}

_Updater_BeginAsyncTerminalDelivery() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	PreviousCritical := A_IsCritical
	Critical("On")
	try _UpdaterActiveAsyncTerminalDeliveryCount += 1
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
	return true
}

_Updater_EndAsyncTerminalDelivery() {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	PreviousCritical := A_IsCritical
	Critical("On")
	try _UpdaterActiveAsyncTerminalDeliveryCount := Max(
		0, _UpdaterActiveAsyncTerminalDeliveryCount - 1)
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
	_Updater_ScheduleDeferredChannelReloadIfReady()
	return true
}

_Updater_ClaimAsyncTerminalRecord(Record) {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	if !(Record is Map)
		return false
	PreviousCritical := A_IsCritical
	Claimed := false
	Critical("On")
	try {
		if !Record.Get("terminal_claimed", false) {
			Record["terminal_claimed"] := true
			_UpdaterActiveAsyncTerminalDeliveryCount += 1
			Claimed := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Claimed
}

_Updater_EndAsyncTerminalRecord(Record) {
	global _UpdaterActiveAsyncTerminalDeliveryCount
	if !(Record is Map)
		return false
	PreviousCritical := A_IsCritical
	Ended := false
	Critical("On")
	try {
		if Record.Get("terminal_claimed", false) {
			Record["terminal_claimed"] := false
			_UpdaterActiveAsyncTerminalDeliveryCount := Max(
				0, _UpdaterActiveAsyncTerminalDeliveryCount - 1)
			Ended := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if Ended
		_Updater_ScheduleDeferredChannelReloadIfReady()
	return Ended
}

_Updater_InvokeAsyncOnJson(OnJson, Json, Request, Terminal := 0, Context := "async request", TerminalRecord := 0) {
	UsesRecord := TerminalRecord is Map
	if UsesRecord
		_Updater_ClaimAsyncTerminalRecord(TerminalRecord)
	else
		_Updater_BeginAsyncTerminalDelivery()
	try {
		if !IsObject(OnJson) {
			try LoggerError("Updater", "Async terminal callback was not callable during {1}.", Context)
			return false
		}
		OnJson.Call(Json, Request, Terminal)
		return true
	} catch as Err {
		try LoggerError("Updater", "OnJson callback threw during {1}: {2}.", Context, Err.Message)
		return false
	} finally {
		if UsesRecord
			_Updater_EndAsyncTerminalRecord(TerminalRecord)
		else
			_Updater_EndAsyncTerminalDelivery()
	}
}

_Updater_ChannelReloadTransitionActive() {
	global _UpdaterChannelReloadTransition
	PreviousCritical := A_IsCritical
	Critical("On")
	try return IsObject(_UpdaterChannelReloadTransition)
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
}

_Updater_ChannelReloadQuiescent() {
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	global _UpdaterActiveAsyncTerminalDeliveryCount
	PreviousCritical := A_IsCritical
	Critical("On")
	try return _UpdaterAsyncRequests.Count == 0
		and _UpdaterActiveSendLeaseCount == 0
		and _UpdaterActiveAsyncTerminalDeliveryCount == 0
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
}

_Updater_DefaultChannelReload(ConfigBundle := 0) {
	return ReloadPreservingSuspend(0, ConfigBundle)
}

_Updater_DefaultChannelReloadSchedule(Continuation, DelayMs) {
	SetTimer(Continuation, -DelayMs)
	return true
}

_Updater_DefaultChannelRecoverySchedule(Continuation, DelayMs) {
	SetTimer(Continuation, -Abs(DelayMs))
	return true
}

; Keeps the public updater writer seam stable while routing persistence through
; the strict batch gateways. Tests and embedders historically receive
; (Value, Path, Section, Key); the gateway receives (Path, Updates).
_Updater_InvokeLegacyConfigWriter(WriteFn, Path, Updates) {
	if !HasMethod(WriteFn, "Call") || !(Updates is Array)
		|| Updates.Length != 1
		return false
	Update := Updates[1]
	if !(Update is Object) || !Update.HasOwnProp("Section")
		|| !Update.HasOwnProp("Key") || !Update.HasOwnProp("Value")
		return false
	return WriteFn.Call(Update.Value, Path, Update.Section, Update.Key)
}

; Channel changes share Reload's complete lifecycle bundle because config.toml
; is not the only durable authority Reload may have to reconcile. The bundle's
; process-wide admission flag also blocks every sibling configuration store.
_Updater_AcquireChannelConfigBundle() {
	global ConfigurationFile
	Bundle := 0
	try Bundle := LLM_Menu_AcquireLifecycleBundle()
	catch as Err {
		try LoggerError("Updater", "Could not acquire the channel-transition configuration bundle: {1}.", Err.Message)
		return false
	}
	if !(Bundle is Object)
		return false
	if !(_ConfigWriteLeaseSelectOwner(Bundle, ConfigurationFile) is Object) {
		_ConfigWriteTerminalRelease(Bundle)
		return false
	}
	Bundle.UpdaterChannelRetained := false
	Bundle.UpdaterChannelReleased := false
	return Bundle
}

_Updater_ChannelConfigBundleRetained(Bundle) {
	if !(Bundle is Object)
		return false
	PreviousCritical := Critical("On")
	try return Bundle.HasOwnProp("UpdaterChannelRetained")
		&& Bundle.UpdaterChannelRetained
	finally Critical(PreviousCritical)
}

_Updater_RetainChannelConfigBundle(Bundle, RetentionOwner) {
	global ConfigurationFile
	if !(Bundle is Object) || !(RetentionOwner is Object)
		return false
	PreviousCritical := Critical("On")
	try {
		; Validate the exact owner and publish its retention target atomically.
		; Otherwise a terminal callback could release the bundle between the
		; ownership probe and the deferred/recovery state's first reference.
		if !(_ConfigWriteLeaseSelectOwner(Bundle,
				ConfigurationFile) is Object)
			return false
		if Bundle.HasOwnProp("UpdaterChannelReleased")
			&& Bundle.UpdaterChannelReleased
			return false
		Bundle.UpdaterChannelRetained := true
		RetentionOwner.ConfigBundle := Bundle
		return true
	} finally Critical(PreviousCritical)
}

_Updater_ReleaseChannelConfigBundle(Bundle) {
	if !(Bundle is Object)
		return false
	PreviousCritical := Critical("On")
	try {
		if Bundle.HasOwnProp("UpdaterChannelReleased")
			&& Bundle.UpdaterChannelReleased
			return true
		Released := _ConfigWriteTerminalRelease(Bundle)
		if Released {
			Bundle.UpdaterChannelRetained := false
			Bundle.UpdaterChannelReleased := true
		}
		return Released
	} finally Critical(PreviousCritical)
}

_Updater_RestorePrecommitCadence(FailureMessage := "", FailureErr := 0,
	ScheduleFn := 0, StartFn := 0, PreclaimedOwner := 0) {
	if (IsObject(PreclaimedOwner)
		and !_Updater_AsyncActionLeaseOwned(PreclaimedOwner))
		return false
	try return _Updater_ResultSucceeded(IsObject(StartFn)
		? StartFn.Call() : Updater_StartBackgroundChecks())
	catch as Err {
		try LoggerError("Updater", "Could not restore pre-commit background cadence: {1}.", Err.Message)
		return false
	}
}

_Updater_FinishChannelRecovery(ActionOwner, RebuildFn := 0, *) {
	global _UpdaterAsyncActionLeases
	if !IsObject(ActionOwner)
		return false
	PreviousCritical := A_IsCritical
	Claimed := false
	Critical("On")
	try {
		if (ActionOwner.HasOwnProp("Id")
			and _UpdaterAsyncActionLeases.Has(ActionOwner.Id)
			and ObjPtr(_UpdaterAsyncActionLeases[ActionOwner.Id])
				== ObjPtr(ActionOwner)
			and ActionOwner.HasOwnProp("RecoveryPending")
			and ActionOwner.RecoveryPending) {
			ActionOwner.RecoveryPending := false
			Claimed := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !Claimed
		return false
	MenuOk := false
	try {
		MenuOk := _Updater_RebuildMenu(0, RebuildFn)
		if !MenuOk
			_Updater_SurfaceFailure("updater.channel_transition_failed",
				"The updater menu could not be restored after channel transition.")
		return MenuOk
	} finally {
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			ActionOwner.RecoveryCompleted := true
			ActionOwner.RecoveryResult := MenuOk
			ActionOwner.RecoveryContinuation := 0
		} finally {
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
		_Updater_ReleaseAsyncActionLease(ActionOwner)
		if ActionOwner.HasOwnProp("ConfigBundle")
			_Updater_ReleaseChannelConfigBundle(ActionOwner.ConfigBundle)
	}
}

_Updater_RecoverCommittedChannelTransition(FailureMessage := "",
	FailureErr := 0, ScheduleFn := 0, StartFn := 0,
	PreclaimedOwner := 0, RebuildFn := 0) {
	; Callers release the exact channel boundary first. A short-lived action
	; lease then excludes a successor channel transaction until cadence startup
	; has itself acknowledged a future timer; merely scheduling Start would leave
	; a retry window where another boundary can consume and lose that callback.
	if !IsObject(ScheduleFn)
		ScheduleFn := _Updater_DefaultChannelRecoverySchedule
	CallerOwnsLease := IsObject(PreclaimedOwner)
	ActionOwner := CallerOwnsLease
		? PreclaimedOwner
		: _Updater_AcquireAsyncActionLease("Channel recovery")
	if !IsObject(ActionOwner) {
		try LoggerError("Updater", "Channel-transition recovery could not acquire action admission.")
		return false
	}
	CadenceOk := false
	MenuOk := false
	try {
		try CadenceOk := _Updater_ResultSucceeded(IsObject(StartFn)
			? StartFn.Call() : Updater_StartBackgroundChecks())
		catch as Err
			try LoggerError("Updater", "Could not restore channel-transition cadence: {1}.", Err.Message)
		if !CadenceOk
			try LoggerError("Updater", "Channel-transition cadence recovery did not start.")
		ActionOwner.RecoveryPending := true
		ActionOwner.RecoveryCompleted := false
		ActionOwner.RecoveryResult := false
		ActionOwner.RecoveryRetained := false
		Continuation := _Updater_FinishChannelRecovery.Bind(
			ActionOwner, RebuildFn)
		ActionOwner.RecoveryContinuation := Continuation
		ScheduleOk := false
		try ScheduleOk := _Updater_ResultSucceeded(
			ScheduleFn.Call(Continuation, 1))
		catch as Err
			try LoggerError("Updater", "Could not schedule channel-transition menu recovery: {1}.", Err.Message)
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			if !ScheduleOk and !ActionOwner.RecoveryCompleted {
				ActionOwner.RecoveryPending := false
				ActionOwner.RecoveryContinuation := 0
			}
			if ScheduleOk and !ActionOwner.RecoveryCompleted {
				ActionOwner.RecoveryRetained := true
				MenuOk := true
			} else if ActionOwner.RecoveryCompleted {
				MenuOk := ActionOwner.RecoveryResult
			}
		} finally {
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
		if !MenuOk
			try LoggerError("Updater", "Channel-transition menu recovery was not scheduled.")
		return CadenceOk and MenuOk
	} finally {
		if (!CallerOwnsLease
			and (!ActionOwner.HasOwnProp("RecoveryRetained")
				or !ActionOwner.RecoveryRetained))
			_Updater_ReleaseAsyncActionLease(ActionOwner)
	}
}

_Updater_InvokeChannelRecovery(RecoverFn, FailureMessage, FailureErr := 0,
	BoundaryOwner := 0, ConfigBundle := 0) {
	HasBoundaryOwner := IsObject(BoundaryOwner)
	RecoveryOwner := HasBoundaryOwner
		? _Updater_HandoffAdmissionToActionLease(
			BoundaryOwner, "Channel recovery")
		: 0
	if !IsObject(RecoveryOwner) and !HasBoundaryOwner
		RecoveryOwner := _Updater_AcquireAsyncActionLease("Channel recovery")
	if !IsObject(RecoveryOwner) {
		try LoggerError("Updater", "Channel recovery could not acquire exact action ownership.")
		if IsObject(ConfigBundle)
			_Updater_ReleaseChannelConfigBundle(ConfigBundle)
		return false
	}
	if (IsObject(ConfigBundle)
		and !_Updater_RetainChannelConfigBundle(
			ConfigBundle, RecoveryOwner)) {
		try LoggerError("Updater", "Channel recovery could not retain the exact configuration bundle.")
		_Updater_ReleaseAsyncActionLease(RecoveryOwner)
		_Updater_ReleaseChannelConfigBundle(ConfigBundle)
		return false
	}
	if !IsObject(RecoverFn)
		RecoverFn := _Updater_RecoverCommittedChannelTransition
	RecoveryOk := false
	try {
		RecoveryOk := _Updater_ResultSucceeded(RecoverFn.Call(
			FailureMessage, FailureErr, 0, 0, RecoveryOwner))
	} catch as Err {
		try LoggerError("Updater", "Channel recovery callback threw: {1}.", Err.Message)
	} finally {
		if (!RecoveryOwner.HasOwnProp("RecoveryRetained")
			or !RecoveryOwner.RecoveryRetained) {
			_Updater_ReleaseAsyncActionLease(RecoveryOwner)
			if RecoveryOwner.HasOwnProp("ConfigBundle")
				_Updater_ReleaseChannelConfigBundle(
					RecoveryOwner.ConfigBundle)
		}
	}
	if !RecoveryOk
		try LoggerError("Updater", "Channel recovery callback did not complete successfully.")
	return RecoveryOk
}

_Updater_RetireDeferredChannelReload(State) {
	global _UpdaterChannelReloadTransition
	if !IsObject(State)
		return false
	PreviousCritical := A_IsCritical
	Retired := false
	Critical("On")
	try {
		if (IsObject(_UpdaterChannelReloadTransition)
			and ObjPtr(_UpdaterChannelReloadTransition) == ObjPtr(State)
			and State.Active) {
			State.Active := false
			State.Scheduled := false
			State.Continuation := 0
			_UpdaterChannelReloadTransition := 0
			Retired := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Retired
}

_Updater_FailDeferredChannelReload(State, FailureMessage, FailureErr := 0) {
	if !IsObject(State)
		return false
	PreviousCritical := A_IsCritical
	FirstFailure := false
	Critical("On")
	try {
		if !State.FailureDelivered {
			State.FailureDelivered := true
			FirstFailure := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !FirstFailure
		return false
	Detail := IsObject(FailureErr) ? FailureErr.Message : FailureMessage
	try LoggerError("Updater", "Deferred channel Reload failed: {1}.", Detail)
	try State.FailureFn.Call(FailureMessage, FailureErr)
	catch as Err
		try LoggerError("Updater", "Deferred channel Reload failure callback threw: {1}.", Err.Message)
	try _Updater_SurfaceFailure("updater.channel_transition_failed",
		"The persisted update channel could not be applied safely.",
		State.NotifyFn)
	RecoveryOk := _Updater_InvokeChannelRecovery(
		State.RecoverFn, FailureMessage, FailureErr, State.BoundaryOwner,
		State.ConfigBundle)
	if !RecoveryOk
		try LoggerError("Updater", "Deferred channel Reload recovery did not complete successfully.")
	State.RecoveryOwned := RecoveryOk
	return RecoveryOk
}

_Updater_ArmDeferredChannelReload(State) {
	global _UpdaterChannelReloadTransition, UPDATER_CHANNEL_RELOAD_POLL_MS
	if !IsObject(State)
		return false
	Continuation := 0
	Epoch := 0
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (IsObject(_UpdaterChannelReloadTransition)
			and ObjPtr(_UpdaterChannelReloadTransition) == ObjPtr(State)
			and State.Active and !State.Scheduled) {
			State.ArmEpoch += 1
			Epoch := State.ArmEpoch
			Continuation := _Updater_RunDeferredChannelReload.Bind(State, Epoch)
			State.Scheduled := true
			State.Continuation := Continuation
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !IsObject(Continuation)
		return false
	ScheduleFailed := false
	ScheduleErr := 0
	try {
		ScheduleResult := State.ScheduleFn.Call(
			Continuation, UPDATER_CHANNEL_RELOAD_POLL_MS)
		if !_Updater_ResultSucceeded(ScheduleResult)
			ScheduleFailed := true
	} catch as Err {
		ScheduleFailed := true
		ScheduleErr := Err
	}
	if !ScheduleFailed
		return true
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (State.Active and State.ArmEpoch == Epoch)
			State.Scheduled := false
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	_Updater_RetireDeferredChannelReload(State)
	_Updater_FailDeferredChannelReload(State,
		"channel Reload continuation could not be scheduled", ScheduleErr)
	return false
}

_Updater_BeginDeferredChannelReload(BoundaryOwner, ReloadFn := 0,
	ScheduleFn := 0, FailureFn := 0, RecoverFn := 0,
	StartTick := unset, TimeoutMs := unset, NotifyFn := 0,
	ConfigBundle := 0) {
	global _UpdaterAsyncAdmissionBoundary, _UpdaterChannelReloadTransition
	global _UpdaterChannelReloadCounter, UPDATER_CHANNEL_RELOAD_QUIESCE_TIMEOUT_MS
	global ConfigurationFile
	if !IsObject(BoundaryOwner)
		return 0
	if !(ConfigBundle is Object)
		return 0
	if !(_ConfigWriteLeaseSelectOwner(ConfigBundle,
			ConfigurationFile) is Object)
		return 0
	if !IsObject(ReloadFn)
		ReloadFn := _Updater_DefaultChannelReload.Bind(ConfigBundle)
	if !IsObject(ScheduleFn)
		ScheduleFn := _Updater_DefaultChannelReloadSchedule
	if !IsObject(FailureFn)
		FailureFn := (*) => true
	if !IsObject(RecoverFn)
		RecoverFn := _Updater_RecoverCommittedChannelTransition
	if !IsSet(StartTick)
		StartTick := A_TickCount
	if !IsSet(TimeoutMs)
		TimeoutMs := UPDATER_CHANNEL_RELOAD_QUIESCE_TIMEOUT_MS
	if (Type(TimeoutMs) != "Integer" or TimeoutMs <= 0)
		throw ValueError("Channel Reload timeout must be a positive integer")
	State := 0
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (IsObject(_UpdaterAsyncAdmissionBoundary)
			and ObjPtr(_UpdaterAsyncAdmissionBoundary) == ObjPtr(BoundaryOwner)
			and !IsObject(_UpdaterChannelReloadTransition)) {
			_UpdaterChannelReloadCounter += 1
			CandidateState := {
				Id: _UpdaterChannelReloadCounter,
				BoundaryOwner: BoundaryOwner,
				ConfigBundle: ConfigBundle,
				ReloadFn: ReloadFn,
				ScheduleFn: ScheduleFn,
				FailureFn: FailureFn,
				RecoverFn: RecoverFn,
				NotifyFn: NotifyFn,
				StartTick: StartTick,
				TimeoutMs: TimeoutMs,
				Active: true,
				Scheduled: false,
				ArmEpoch: 0,
				Continuation: 0,
				FailureDelivered: false,
				RecoveryOwned: false
			}
			; Retention and deferred-state publication share one Critical boundary:
			; an ending async callback cannot arm or run the transition in between.
			if _Updater_RetainChannelConfigBundle(
					ConfigBundle, CandidateState) {
				State := CandidateState
				_UpdaterChannelReloadTransition := State
			}
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !IsObject(State)
		return 0
	if !_Updater_ArmDeferredChannelReload(State)
		return 0
	return State
}

_Updater_RunDeferredChannelReload(State, ArmEpoch := unset, NowTick := unset) {
	global _UpdaterChannelReloadTransition
	if !IsObject(State)
		return false
	if !IsSet(ArmEpoch)
		ArmEpoch := State.ArmEpoch
	PreviousCritical := A_IsCritical
	Current := false
	Critical("On")
	try {
		if (IsObject(_UpdaterChannelReloadTransition)
			and ObjPtr(_UpdaterChannelReloadTransition) == ObjPtr(State)
			and State.Active and State.Scheduled
			and State.ArmEpoch == ArmEpoch) {
			State.Scheduled := false
			Current := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !Current
		return false
	if !_Updater_ChannelReloadQuiescent() {
		if !IsSet(NowTick)
			NowTick := A_TickCount
		if TickExpired(State.StartTick, State.TimeoutMs, NowTick) {
			_Updater_RetireDeferredChannelReload(State)
			_Updater_FailDeferredChannelReload(State,
				"channel reload quiescence timed out")
			return false
		}
		_Updater_ArmDeferredChannelReload(State)
		return false
	}
	; Retire before Reload so a yielding handoff cannot rearm this exact state.
	if !_Updater_RetireDeferredChannelReload(State)
		return false
	ReloadErr := 0
	ReloadResult := false
	try ReloadResult := State.ReloadFn.Call()
	catch as Err
		ReloadErr := Err
	if IsObject(ReloadErr) {
		_Updater_FailDeferredChannelReload(
			State, "Reload raised an exception", ReloadErr)
		return false
	}
	if !_Updater_ResultSucceeded(ReloadResult) {
		_Updater_FailDeferredChannelReload(State, "Reload returned false")
		return false
	}
	BoundaryReleased := _Updater_EndAsyncAdmissionBoundary(
		State.BoundaryOwner)
	BundleReleased := _Updater_ReleaseChannelConfigBundle(
		State.ConfigBundle)
	if !BoundaryReleased || !BundleReleased {
		try LoggerError("Updater", "Accepted channel Reload did not release both exact transition owners.")
		return false
	}
	return true
}

_Updater_ScheduleDeferredChannelReloadIfReady() {
	global _UpdaterChannelReloadTransition
	PreviousCritical := A_IsCritical
	State := 0
	Critical("On")
	try {
		if (IsObject(_UpdaterChannelReloadTransition)
			and _UpdaterChannelReloadTransition.Active
			and !_UpdaterChannelReloadTransition.Scheduled)
			State := _UpdaterChannelReloadTransition
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return IsObject(State) ? _Updater_ArmDeferredChannelReload(State) : false
}



; ====================================
; ===== 1.2) Channel persistence =====
; ====================================

; Loads the saved channel from config.toml (via the shared INI cache).
;
; Priority order:
;   1. ``[Updater] UpdateChannel`` in config.toml — explicit user override
;      via the tray menu's "Update channel" submenu.
;   2. ``BUNDLE_CHANNEL`` stamped at build time — "dev" for pre-release exes,
;      "main" for stable. This means a user who downloads a dev pre-release
;      stays on dev (and gets pre-release update notifications) without
;      flipping any setting; the same exe published to main defaults to
;      "main".
;   3. Hardcoded "main" — last-resort default for dev / source-tree runs
;      where the build placeholder was never replaced.
Updater_LoadChannel() {
	global _IniCache, UPDATER_CHANNEL, UPDATER_INI_SECTION, UPDATER_INI_KEY
	global BUNDLE_CHANNEL

	; Step 2: seed from the build-stamped channel first (overridden below if
	; the user has an explicit config-file override). When running from the
	; source tree BUNDLE_CHANNEL is not set, so default to "dev" — all releases
	; are pre-releases in that context and "main" would show an empty list.
	if IsSet(BUNDLE_CHANNEL)
		and (BUNDLE_CHANNEL == "main" or BUNDLE_CHANNEL == "dev") {
		UPDATER_CHANNEL := BUNDLE_CHANNEL
	} else {
		UPDATER_CHANNEL := "dev"
	}

	; Step 1: explicit user override always wins.
	if IsSet(_IniCache) {
		raw := IniCacheGet(_IniCache, UPDATER_INI_SECTION, UPDATER_INI_KEY)
		if (raw != "_" and (raw == "main" or raw == "dev"))
			UPDATER_CHANNEL := raw
	}
}

; Persists the chosen channel, retires all old-channel producers and hands one
; exact closed-admission transaction to a quiescence-gated Reload timer.
Updater_SetChannel(Channel, Request := unset, IsSuspended := unset, NotifyFn := 0, WriteFn := 0, ReloadFn := 0, ReloadScheduleFn := 0, ReloadFailureFn := 0, ReloadRecoverFn := 0) {
	global UPDATER_CHANNEL, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_KEY
	global _UpdaterDownloadInProgress
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	global _UpdaterChannelEpoch, _UpdaterFetchCache
	global UPDATER_LATEST_RELEASE, _UpdaterPendingReleaseNotification
	global UPDATER_REQUEST_ORIGIN_MANUAL
	global UPDATER_CANCEL_REASON_CHANNEL_SWITCH
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		; Lifecycle-bundle discovery reads the stable WAL, and a successful action
		; persists config, retires producers, schedules Reload and emits feedback.
		; None of those operations may inherit a menu caller's Critical span.
		Critical("Off")
		try {
			if IsSet(Request) {
				if IsSet(IsSuspended)
					return Updater_SetChannel(Channel, Request, IsSuspended,
						NotifyFn, WriteFn, ReloadFn, ReloadScheduleFn,
						ReloadFailureFn, ReloadRecoverFn)
				return Updater_SetChannel(Channel, Request, unset,
					NotifyFn, WriteFn, ReloadFn, ReloadScheduleFn,
					ReloadFailureFn, ReloadRecoverFn)
			}
			if IsSet(IsSuspended)
				return Updater_SetChannel(Channel, unset, IsSuspended,
					NotifyFn, WriteFn, ReloadFn, ReloadScheduleFn,
					ReloadFailureFn, ReloadRecoverFn)
			return Updater_SetChannel(Channel, unset, unset,
				NotifyFn, WriteFn, ReloadFn, ReloadScheduleFn,
				ReloadFailureFn, ReloadRecoverFn)
		} finally Critical(InheritedCritical)
	}
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
	if (Channel != "main" and Channel != "dev") {
		try LoggerError("Updater", "Invalid update channel '{1}' was refused.", Channel)
		return false
	}
	; The self-update download's WinHttp request and poll-timer chain are
	; tracked only as local closures inside Updater_DownloadAndInstall /
	; _Updater_PollDownloadAsync -- never registered in the shared
	; _UpdaterAsyncRequests map that channel-switch cancellation drains. A
	; Reload here would orphan the in-flight request and the partial staging
	; file with zero log trace. Block the switch instead of racing it
	; (updater-channel-switch-download-race).
	BoundaryOwner := 0
	ConfigBundle := 0
	PreviousCritical := A_IsCritical
	DownloadActive := false
	CadenceWasRunning := false
	Critical("On")
	try {
		DownloadActive := _UpdaterDownloadInProgress
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if DownloadActive {
		try LoggerWarn("Updater", "Channel switch to '{1}' blocked: a download is currently in progress.", Channel)
		if IsObject(NotifyFn)
			_Updater_SurfaceFailure("updater.channel_switch_blocked_download",
				"An update download is already in progress.", NotifyFn)
		else
			MsgBox(t("updater.channel_switch_blocked_download"), t("updater.title_update"), "Icon!")
		return false
	}
	; Acquire machine-wide configuration admission before cadence retirement or
	; persistence. A sibling-path terminal transition must observe zero updater
	; writer, live, timer, menu and Reload effects.
	ConfigBundle := _Updater_AcquireChannelConfigBundle()
	if !(ConfigBundle is Object) {
		_Updater_SurfaceFailure("updater.settings_save_failed",
			"Channel persistence was refused because another configuration transition is in progress.",
			NotifyFn)
		return false
	}
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		; A download can acquire updater-local admission while lifecycle-bundle
		; discovery reads its journal. Recheck before closing updater admission.
		DownloadActive := _UpdaterDownloadInProgress
		if !DownloadActive {
			BoundaryOwner := _Updater_BeginAsyncAdmissionBoundary(
				UPDATER_CANCEL_REASON_CHANNEL_SWITCH)
			if IsObject(BoundaryOwner)
				CadenceWasRunning := IsSet(_UpdaterBackgroundFn)
					or IsObject(_UpdaterBackgroundOwner)
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if DownloadActive {
		_Updater_ReleaseChannelConfigBundle(ConfigBundle)
		try LoggerWarn("Updater", "Channel switch to '{1}' blocked: a download started during lifecycle admission.", Channel)
		_Updater_SurfaceFailure("updater.channel_switch_blocked_download",
			"An update download started during channel-transition admission.",
			NotifyFn)
		return false
	}
	if !IsObject(BoundaryOwner)
		try {
			return _Updater_NotifyAsyncAdmissionRefusal(
				"Channel switch", _Updater_AsyncAdmissionBoundaryReason(), NotifyFn)
		} finally {
			_Updater_ReleaseChannelConfigBundle(ConfigBundle)
		}
	TransitionOwned := false
	DurablyCommitted := false
	RestorePrecommitCadence := false
	try {
		; Retire the producer before the yielding write. A ready tick otherwise
		; observes the closed boundary, retires itself, and stays dead forever if
		; persistence later fails. The finally below restores only a cadence that
		; this exact pre-commit transaction actually displaced.
		if CadenceWasRunning {
			RestorePrecommitCadence := true
			StopOk := false
			try StopOk := _Updater_ResultSucceeded(
				Updater_StopBackgroundChecks(false))
			catch as Err
				try LoggerError("Updater", "Could not stop background cadence before channel persistence: {1}.", Err.Message)
			if !StopOk {
				_Updater_SurfaceFailure("updater.settings_save_failed",
					"Channel persistence was not attempted because the background cadence could not be retired.",
					NotifyFn)
				return false
			}
		}
		; Both TOML's normal false result and an injected/OS exception are durable
		; failures. Neither may publish the new epoch or leak closed admission.
		ConfigOwner := _ConfigWriteLeaseSelectOwner(
			ConfigBundle, ConfigurationFile)
		GatewayWriter := IsObject(WriteFn)
			? _Updater_InvokeLegacyConfigWriter.Bind(WriteFn) : 0
		Updates := [{ Section: UPDATER_INI_SECTION,
			Key: UPDATER_INI_KEY, Value: Channel }]
		Persisted := ConfigOwner is Object
			&& ConfigCommitBorrowedUpdates(ConfigOwner, ConfigurationFile,
				Updates, "the updater channel", GatewayWriter, NotifyFn)
		if !Persisted {
			try LoggerError("Updater", "Could not persist update channel '{1}'; keeping '{2}'.", Channel, UPDATER_CHANNEL)
			return false
		}

		; The durable write is the point of no return. Publish channel and monotone
		; epoch atomically, then invalidate every channel-derived cache. String
		; equality cannot revive stale main -> dev -> main work.
		PreviousCritical := A_IsCritical
		Critical("On")
		try {
			UPDATER_CHANNEL := Channel
			_UpdaterChannelEpoch += 1
			_UpdaterFetchCache := Map()
			_UpdaterPendingReleaseNotification := 0
			UPDATER_LATEST_RELEASE := unset
		} finally {
			Critical(PreviousCritical ? PreviousCritical : "Off")
		}
		DurablyCommitted := true
		RestorePrecommitCadence := false

		; Producer shutdown precedes the all-origin registry swap. Closed admission
		; prevents a ready tick or a reentrant terminal callback from publishing an
		; owner into the replacement Map that Reload would otherwise abandon.
		PostCommitErr := 0
		Transition := 0
		try {
			_Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_CHANNEL_SWITCH)
			Transition := _Updater_BeginDeferredChannelReload(
				BoundaryOwner, ReloadFn, ReloadScheduleFn,
				ReloadFailureFn, ReloadRecoverFn, , , NotifyFn,
				ConfigBundle)
		} catch as Err {
			PostCommitErr := Err
		}
		if IsObject(PostCommitErr) {
			Detail := PostCommitErr.Message
			try LoggerError("Updater", "Could not complete channel transition to '{1}': {2}.", Channel, Detail)
			_Updater_SurfaceFailure("updater.channel_transition_failed",
				"The persisted update channel could not be applied safely.", NotifyFn)
			RecoveryOk := _Updater_InvokeChannelRecovery(ReloadRecoverFn,
				"channel transition raised after commit", PostCommitErr,
				BoundaryOwner, ConfigBundle)
			if !RecoveryOk
				try LoggerError("Updater", "Committed channel-transition recovery was not owned.")
			return false
		}
		if !IsObject(Transition) {
			; Arm failure owns its own visible terminal, exact boundary release and
			; recovery. Surface here only if handoff returned false while our exact
			; boundary inexplicably remained live.
			if _Updater_AsyncAdmissionBoundaryOwned(BoundaryOwner) {
				try LoggerError("Updater", "Deferred Reload ownership was refused after switching channel to '{1}'.", Channel)
				_Updater_SurfaceFailure("updater.channel_transition_failed",
					"The persisted update channel could not be applied safely.", NotifyFn)
				RecoveryOk := _Updater_InvokeChannelRecovery(ReloadRecoverFn,
					"deferred Reload ownership was refused", 0,
					BoundaryOwner, ConfigBundle)
				if !RecoveryOk
					try LoggerError("Updater", "Refused channel-transition recovery was not owned.")
			}
			return false
		}
		TransitionOwned := true
		return true
	} finally {
		; A successful deferred owner retains the boundary until Reload or explicit
		; recovery. Every earlier exit retires only this exact owner.
		if !TransitionOwned {
			if (!DurablyCommitted and RestorePrecommitCadence) {
				PrecommitRecoverFn := IsObject(ReloadRecoverFn)
					? ReloadRecoverFn : _Updater_RestorePrecommitCadence
				RecoveryOk := _Updater_InvokeChannelRecovery(
					PrecommitRecoverFn,
					"channel transition ended before commit", 0,
					BoundaryOwner, ConfigBundle)
				if !RecoveryOk {
					try LoggerError("Updater", "Pre-commit channel cadence recovery was not owned.")
					_Updater_SurfaceFailure("updater.channel_transition_failed",
						"The previous background cadence could not be restored.",
						NotifyFn)
				}
			} else {
				_Updater_EndAsyncAdmissionBoundary(BoundaryOwner)
			}
			if (!_Updater_ChannelConfigBundleRetained(ConfigBundle))
				_Updater_ReleaseChannelConfigBundle(ConfigBundle)
		}
	}
}


; =========================================
; ===== 1.2b) Check-interval persistence ==
; =========================================

; Reads the saved background-check cadence from the INI cache. Accepts any
; non-negative integer (seconds); 0 means "never". Defaults to 24h when the
; key is absent so a fresh install gets a sensible cadence out of the box.
Updater_LoadCheckInterval() {
	global _IniCache, UPDATER_CHECK_INTERVAL, UPDATER_INI_SECTION
	global UPDATER_INI_INTERVAL_KEY, UPDATER_DEFAULT_INTERVAL
	if !IsSet(_IniCache) {
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
	raw := IniCacheGet(_IniCache, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY)
	if (raw == "_" or raw == "") {
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
	; Validate before arithmetic — AHK v2 throws a TypeError on a non-numeric
	; string in arithmetic (e.g. "fast" + 0), it does NOT silently coerce to 0
	; as the old comment claimed. A malformed entry falls back to the default
	; instead of aborting the boot auto-execute section.
	if !IsNumber(raw) {
		try LoggerWarn("Updater", "Ignoring non-numeric check_interval_seconds '{1}' — using default ({2} s).", raw, UPDATER_DEFAULT_INTERVAL)
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
	; IsNumber accepts magnitudes that can still overflow Integer(). Treat that
	; malformed extreme exactly like other invalid persisted values, never let it
	; abort the boot auto-execute path.
	try seconds := Integer(raw + 0)
	catch {
		try LoggerWarn("Updater", "Ignoring out-of-range check_interval_seconds '{1}' — using default ({2} s).", raw, UPDATER_DEFAULT_INTERVAL)
		UPDATER_CHECK_INTERVAL := UPDATER_DEFAULT_INTERVAL
		return
	}
	if (seconds < 0)
		seconds := 0
	UPDATER_CHECK_INTERVAL := seconds
}

; Builds the cadence transaction only after ConfigCommitBuilt owns config.toml.
; The old preference and timer owner therefore come from the same admitted
; snapshot as the durable rollback batch.
_Updater_BuildCheckIntervalPlan(Seconds, MenuScheduleFn := 0) {
	global UPDATER_CHECK_INTERVAL, UPDATER_INI_SECTION
	global UPDATER_INI_INTERVAL_KEY
	global _UpdaterBackgroundFn, _UpdaterBackgroundOwner
	PreviousCritical := Critical("On")
	try {
		OldSeconds := UPDATER_CHECK_INTERVAL
		CadenceWasRunning := IsSet(_UpdaterBackgroundFn)
			or IsObject(_UpdaterBackgroundOwner)
	} finally Critical(PreviousCritical)
	State := {
		OldSeconds: OldSeconds,
		CadenceWasRunning: CadenceWasRunning,
		NativeChanged: false,
		Finalized: false,
		Published: false
	}
	return {
		updates: [{ Section: UPDATER_INI_SECTION,
			Key: UPDATER_INI_INTERVAL_KEY, Value: Seconds }],
		rollback_updates: [{ Section: UPDATER_INI_SECTION,
			Key: UPDATER_INI_INTERVAL_KEY, Value: OldSeconds }],
		finalize: _Updater_FinalizeCheckInterval.Bind(
			State, Seconds, MenuScheduleFn),
		publish: _Updater_PublishCheckInterval.Bind(State, Seconds),
		compensate: _Updater_RestoreCheckInterval.Bind(State)
	}
}

_Updater_ScheduleCheckIntervalMenu(MenuScheduleFn := 0) {
	Callback := (*) => _Updater_RebuildMenu()
	if HasMethod(MenuScheduleFn, "Call")
		return _Updater_ResultSucceeded(
			MenuScheduleFn.Call(Callback, 50))
	try {
		SetTimer(Callback, -50)
		return true
	} catch as Err {
		try LoggerError("Updater", "Could not schedule the check-interval menu rebuild: {1}.", Err.Message)
		return false
	}
}

; Applies all native effects under the same global config owner as durability.
; The new preference is provisional until PublishFn reasserts it after the
; cadence and menu handoffs in the following non-yielding Critical window.
_Updater_FinalizeCheckInterval(State, Seconds, MenuScheduleFn := 0) {
	global UPDATER_CHECK_INTERVAL
	if !(State is Object)
		return false
	State.NativeChanged := true
	StopOk := false
	try StopOk := _Updater_ResultSucceeded(
		Updater_StopBackgroundChecks())
	catch as Err
		try LoggerError("Updater", "Could not retire the previous check cadence: {1}.", Err.Message)
	if !StopOk
		return false
	PreviousCritical := Critical("On")
	try UPDATER_CHECK_INTERVAL := Seconds
	finally Critical(PreviousCritical)
	StartOk := false
	try StartOk := _Updater_ResultSucceeded(
		Updater_StartBackgroundChecks())
	catch as Err
		try LoggerError("Updater", "Could not arm the new check cadence: {1}.", Err.Message)
	if !StartOk
		return false
	if !_Updater_ScheduleCheckIntervalMenu(MenuScheduleFn)
		return false
	State.Finalized := true
	return true
}

; Compensation is idempotent because ConfigCommitBuilt also invokes it for a
; writer refusal, before finalization has touched the cadence. If finalization
; did begin, restore both the retained live preference and its exact timer mode
; before the gateway attempts the durable rollback.
_Updater_RestoreCheckInterval(State) {
	global UPDATER_CHECK_INTERVAL
	if !(State is Object)
		return false
	if !State.NativeChanged
		return true
	StopOk := false
	try StopOk := _Updater_ResultSucceeded(
		Updater_StopBackgroundChecks())
	catch as Err
		try LoggerError("Updater", "Could not retire the rejected check cadence: {1}.", Err.Message)
	PreviousCritical := Critical("On")
	try UPDATER_CHECK_INTERVAL := State.OldSeconds
	finally Critical(PreviousCritical)
	RestoreOk := StopOk
	if RestoreOk && State.CadenceWasRunning {
		try RestoreOk := _Updater_ResultSucceeded(
			Updater_StartBackgroundChecks())
		catch as Err {
			RestoreOk := false
			try LoggerError("Updater", "Could not restore the previous check cadence: {1}.", Err.Message)
		}
	}
	if RestoreOk {
		State.NativeChanged := false
		State.Finalized := false
		State.Published := false
	}
	return RestoreOk
}

_Updater_PublishCheckInterval(State, Seconds) {
	global UPDATER_CHECK_INTERVAL
	if !(State is Object) || !State.Finalized
		throw Error("Check-interval native finalization was not acknowledged")
	; Finalization has already armed the timer from this candidate. Reassert the
	; authoritative live value here so even a yielding injected scheduler cannot
	; leave a reentrant mutation published after the durable commit.
	UPDATER_CHECK_INTERVAL := Seconds
	State.Published := true
	return true
}

; Persists the chosen cadence to config.toml AND restarts the background
; poller in-process so the change takes effect without a Reload. The menu
; re-tick has to wait for the next tray rebuild — that's fine because the
; same item is what triggered this call (the user sees their click confirmed).
Updater_SetCheckInterval(Seconds, Request := unset, IsSuspended := unset, NotifyFn := 0, WriteFn := 0, MenuScheduleFn := 0) {
	global UPDATER_CHECK_INTERVAL, ConfigurationFile, UPDATER_INI_SECTION, UPDATER_INI_INTERVAL_KEY
	global UPDATER_REQUEST_ORIGIN_MANUAL
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
	; Coerce defensively: a valid cadence may arrive as a String ("300") or
	; Float (300.0) — e.g. from a config migration or a future caller, since
	; Updater_LoadCheckInterval reads strings from TOML. An exact Type() ==
	; "Integer" test would silently drop those. Reject only genuinely invalid
	; input (non-numeric or negative) and LoggerWarn so a bad value is visible
	; in the log rather than disappearing without a trace.
	try {
		Seconds := Integer(Seconds)
	} catch {
		try LoggerWarn("Updater", "Ignoring non-numeric check interval: {1}.", Seconds)
		return
	}
	if (Seconds < 0) {
		try LoggerWarn("Updater", "Ignoring negative check interval: {1}.", Seconds)
		return false
	}
	ActionOwner := _Updater_AcquireAsyncActionLease(
		"Check-interval change", NotifyFn)
	if !IsObject(ActionOwner)
		return false
	try {
		GatewayWriter := IsObject(WriteFn)
			? _Updater_InvokeLegacyConfigWriter.Bind(WriteFn) : 0
		Committed := ConfigCommitBuilt(ConfigurationFile,
			"the updater check interval",
			_Updater_BuildCheckIntervalPlan.Bind(
				Seconds, MenuScheduleFn), GatewayWriter, NotifyFn)
		if Committed
			try LoggerInfo("Updater", "Background check interval set to {1} s.", Seconds)
		return Committed
	} finally {
		_Updater_ReleaseAsyncActionLease(ActionOwner)
	}
}



; ====================================
; ===== 1.3) Version helpers ==========
; ====================================

; Wrapper called from all updater SetTimer(-50) tray rebuild sites. initMenu()
; now stages child menus before publishing the replacement root; it advances the
; dispatcher epoch and prunes retired IDs at that publication point. Calling
; MenuDispatcher_Reset() here would erase registrations made during staging.
_Updater_RebuildMenu(PublishAuthorizeFn := 0, WorkerFn := 0) {
	try {
		Published := RebuildTrayMenu(PublishAuthorizeFn, WorkerFn, false)
		if !_Updater_ResultSucceeded(Published) {
			_Updater_MarkMenuRebuildPending()
			return false
		}
		return true
	} catch as Err {
		_Updater_MarkMenuRebuildPending()
		try LoggerError("Updater", "Updater menu rebuild failed: {1}.", Err.Message)
		return false
	}
}

; Returns true when running directly from the AHK source tree (not compiled).
; Detected by checking A_IsCompiled, which is 1 only for .exe builds.
; This state takes priority over any user-selected channel — update checking
; is meaningless and channel selection is hidden when running from source.
Updater_IsLocalSource() {
	return !A_IsCompiled
}

; Returns the current driver version string.
; In compiled mode: BUNDLE_VERSION (stamped at build time).
; In local-source mode: the placeholder stays as-is → shown as "local".
Updater_CurrentVersion() {
	global BUNDLE_VERSION
	if Updater_IsLocalSource()
		return "local"
	if (BUNDLE_VERSION == "__BUNDLE_VERSION__" or BUNDLE_VERSION == "")
		return "local"
	return BUNDLE_VERSION
}

; Strips a leading "v" so "v2.1.2" and "2.1.2" compare equal.
; GitHub tag_name always carries the prefix; BUNDLE_VERSION is stamped without
; it (the CI strips it with `${tag#v}`). Without this normalisation the
; background poller fires a spurious "update available" notification even when
; the user is already on the latest release.
_Updater_NormalizeTag(Tag) {
	return (SubStr(Tag, 1, 1) == "v") ? SubStr(Tag, 2) : Tag
}

; Semver helpers — canonical algorithm in _shared/modules/updater/version.js.
; Parses "2.5.0-dev.3" into { Maj, Min, Pat, PreParts } or 0 on failure.
_Updater_ParseVersion(Tag) {
	Norm := _Updater_NormalizeTag(Tag)
	if !RegExMatch(Norm, "^(?P<maj>\d+)\.(?P<min>\d+)\.(?P<pat>\d+)(?:-(?P<pre>.+))?$", &M)
		return 0
	PreParts := 0
	if M.pre != "" {
		PreParts := []
		for , Part in StrSplit(M.pre, ".")
			PreParts.Push(Part)
	}
	return { Maj: Integer(M.maj), Min: Integer(M.min), Pat: Integer(M.pat), PreParts: PreParts }
}

; Compares two prerelease identifier segments (numeric when all digits).
_Updater_ComparePreId(A, B) {
	if RegExMatch(A, "^\d+$") and RegExMatch(B, "^\d+$") {
		ai := Integer(A), bi := Integer(B)
		if (ai > bi)
			return 1
		if (ai < bi)
			return -1
		return 0
	}
	Cmp := StrCompare(A, B)
	return (Cmp > 0) ? 1 : (Cmp < 0) ? -1 : 0
}

; Returns 1 if A > B, -1 if A < B, 0 if equal (semver prerelease rules).
_Updater_ComparePre(A, B) {
	if (A == 0 and B == 0)
		return 0
	if (A == 0 and B != 0)
		return 1
	if (A != 0 and B == 0)
		return -1
	MaxLen := Max(A.Length, B.Length)
	loop MaxLen {
		ai := (A_Index <= A.Length) ? A[A_Index] : ""
		bi := (A_Index <= B.Length) ? B[A_Index] : ""
		if (ai == "")
			return -1
		if (bi == "")
			return 1
		Cmp := _Updater_ComparePreId(ai, bi)
		if (Cmp != 0)
			return Cmp
	}
	return 0
}

; Returns 1 if A > B, -1 if A < B, 0 if equal.
_Updater_CompareVersions(A, B) {
	Pa := _Updater_ParseVersion(A)
	Pb := _Updater_ParseVersion(B)
	if (Pa == 0 or Pb == 0) {
		; Non-semver tag(s): refuse to order them. Fail closed (return 0 = "not
		; newer") rather than guess lexicographically — "10" vs "9" and other
		; ambiguous tags must never trigger or suppress an update by accident.
		; Mirrors macOS modules/updater/init.lua + _shared/.../version.js; kept in
		; lock-step by the version-compare parity gate (D-1)
		return 0
	}
	if (Pa.Maj != Pb.Maj)
		return (Pa.Maj > Pb.Maj) ? 1 : -1
	if (Pa.Min != Pb.Min)
		return (Pa.Min > Pb.Min) ? 1 : -1
	if (Pa.Pat != Pb.Pat)
		return (Pa.Pat > Pb.Pat) ? 1 : -1
	return _Updater_ComparePre(Pa.PreParts, Pb.PreParts)
}

; Returns true when Latest is strictly newer than Current (semver comparison).
; Handles pre-release tags (e.g. 2.5.0-dev.3 → 2.5.0-dev.4). Canonical
; vectors live in _shared/modules/updater/version.js:versionTestVectors().
_Updater_IsNewerVersion(Latest, Current) {
	return _Updater_CompareVersions(Latest, Current) > 0
}

; Returns the immutable release channel stamped into the running executable.
; The source-tree placeholder is deliberately treated as dev, matching
; Updater_LoadChannel(). Compiled release artifacts are stamped main or dev by
; the release workflow.
_Updater_InstalledChannel() {
	global BUNDLE_CHANNEL
	if IsSet(BUNDLE_CHANNEL)
		and (BUNDLE_CHANNEL == "main" or BUNDLE_CHANNEL == "dev")
		return BUNDLE_CHANNEL
	return "dev"
}

; Enforces the tag family emitted by .github/workflows/ci.yml for each channel.
; Stable releases are ordinary semver; dev releases use v0.0.0-dev.N.
_Updater_TagMatchesChannel(Tag, Channel) {
	Parsed := _Updater_ParseVersion(Tag)
	if !IsObject(Parsed)
		return false
	if (Channel == "main")
		return Parsed.PreParts == 0
	if (Channel != "dev")
		return false
	return Parsed.Maj == 0 and Parsed.Min == 0 and Parsed.Pat == 0
		and IsObject(Parsed.PreParts) and Parsed.PreParts.Length == 2
		and Parsed.PreParts[1] == "dev"
		and RegExMatch(Parsed.PreParts[2], "^[1-9]\d*$")
}

; A deliberate channel change is an artifact-family migration, not an
; ordinary version upgrade. Its candidate is therefore eligible even when
; semver orders the CI dev family below the installed stable version. Within
; one channel, the strict newer-only rule remains unchanged.
_Updater_ShouldOfferCandidate(Latest, Current, SelectedChannel,
	InstalledChannel) {
	if !_Updater_TagMatchesChannel(Latest, SelectedChannel)
		return false
	if (SelectedChannel != InstalledChannel) {
		if (InstalledChannel != "main" and InstalledChannel != "dev")
			return false
		return true
	}
	return _Updater_IsNewerVersion(Latest, Current)
}



; ==========================================
; ===== 1.3b) Async request provenance =====
; ==========================================

; Captures the lifecycle state that authorizes one async updater request.
; Callers retain this object unchanged until their terminal callback.
_Updater_NewRequestContext(Origin, BornSuspended := unset, Channel := unset) {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_REQUEST_ORIGIN_MANUAL
	global _UpdaterPauseGeneration, _UpdaterBackgroundGeneration, _UpdaterRequestCounter
	global _UpdaterChannelEpoch, UPDATER_CHANNEL
	if (Origin != UPDATER_REQUEST_ORIGIN_BACKGROUND and Origin != UPDATER_REQUEST_ORIGIN_MANUAL) {
		try LoggerError("Updater", "Invalid async request origin '{1}'.", Origin)
		throw ValueError("Invalid updater request origin: " . Origin)
	}
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if !IsSet(BornSuspended)
			BornSuspended := A_IsSuspended
		if !IsSet(Channel)
			Channel := UPDATER_CHANNEL
		_UpdaterRequestCounter += 1
		RequestId := _UpdaterRequestCounter
		Generation := _UpdaterPauseGeneration
		BackgroundGeneration := _UpdaterBackgroundGeneration
		ChannelEpoch := _UpdaterChannelEpoch
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return {
		RequestId: RequestId,
		PauseTerminalState: { Claimed: false },
		Origin: Origin,
		BornSuspended: BornSuspended ? true : false,
		Generation: Generation,
		BackgroundGeneration: BackgroundGeneration,
		Channel: Channel,
		ChannelEpoch: ChannelEpoch
	}
}

; Capture manual provenance before a WebView bridge COM read can pump messages.
_Updater_ReadManualBridgeMessage(ReadFn) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
	Envelope := {
		Ok: false,
		Message: "",
		Request: _Updater_NewRequestContext(UPDATER_REQUEST_ORIGIN_MANUAL)
	}
	try {
		Envelope.Message := ReadFn.Call()
		Envelope.Ok := true
	} catch as Err {
		try LoggerError("Updater", "Could not read changelog bridge message: {1}.", Err.Message)
	}
	return Envelope
}

; Reject malformed callback provenance before any property read can raise.
_Updater_RequestContextValid(Request) {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_REQUEST_ORIGIN_MANUAL
	if (Type(Request) != "Object"
		or !Request.HasProp("RequestId")
		or !Request.HasProp("PauseTerminalState")
		or !Request.HasProp("Origin")
		or !Request.HasProp("BornSuspended")
		or !Request.HasProp("Generation")
		or !Request.HasProp("BackgroundGeneration")
		or !Request.HasProp("Channel")
		or !Request.HasProp("ChannelEpoch"))
		return false
	RequestId := Request.RequestId
	PauseTerminalState := Request.PauseTerminalState
	if (Type(PauseTerminalState) != "Object"
			or !PauseTerminalState.HasProp("Claimed"))
		return false
	PauseTerminalClaimed := PauseTerminalState.Claimed
	Origin := Request.Origin
	BornSuspended := Request.BornSuspended
	Generation := Request.Generation
	BackgroundGeneration := Request.BackgroundGeneration
	Channel := Request.Channel
	ChannelEpoch := Request.ChannelEpoch
	return Type(RequestId) == "Integer"
		and RequestId > 0
		and Type(PauseTerminalClaimed) == "Integer"
		and (PauseTerminalClaimed == 0 or PauseTerminalClaimed == 1)
		and Origin is String
		and (Origin == UPDATER_REQUEST_ORIGIN_BACKGROUND or Origin == UPDATER_REQUEST_ORIGIN_MANUAL)
		and Type(BornSuspended) == "Integer"
		and (BornSuspended == 0 or BornSuspended == 1)
		and Type(Generation) == "Integer"
		and Generation >= 0
		and Type(BackgroundGeneration) == "Integer"
		and BackgroundGeneration >= 0
		and Channel is String
		and (Channel == "main" or Channel == "dev")
		and Type(ChannelEpoch) == "Integer"
		and ChannelEpoch > 0
}

; Returns the immutable request's publication policy without mutating it.
_Updater_RequestPolicy(Request, IsSuspended := unset) {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_REQUEST_ORIGIN_MANUAL
	global UPDATER_REQUEST_POLICY_ALLOW, UPDATER_REQUEST_POLICY_DROP
	global UPDATER_REQUEST_POLICY_NOTIFY, _UpdaterPauseGeneration
	global _UpdaterBackgroundGeneration, _UpdaterChannelEpoch
	if !IsSet(IsSuspended)
		IsSuspended := A_IsSuspended
	if !_Updater_RequestContextValid(Request)
		return UPDATER_REQUEST_POLICY_DROP
	; A monotone epoch rejects stale main -> dev -> main completions even when
	; the channel String eventually matches again.
	if (Request.ChannelEpoch != _UpdaterChannelEpoch)
		return UPDATER_REQUEST_POLICY_DROP
	if (Request.Origin == UPDATER_REQUEST_ORIGIN_BACKGROUND) {
		if (Request.BornSuspended or IsSuspended
			or Request.Generation != _UpdaterPauseGeneration
			or Request.BackgroundGeneration != _UpdaterBackgroundGeneration)
			return UPDATER_REQUEST_POLICY_DROP
		return UPDATER_REQUEST_POLICY_ALLOW
	}
	if (Request.Origin != UPDATER_REQUEST_ORIGIN_MANUAL)
		return UPDATER_REQUEST_POLICY_DROP
	if Request.BornSuspended
		return UPDATER_REQUEST_POLICY_DROP
	if (IsSuspended or Request.Generation != _UpdaterPauseGeneration)
		return UPDATER_REQUEST_POLICY_NOTIFY
	return UPDATER_REQUEST_POLICY_ALLOW
}

; Visible terminal for a manual updater action attempted while paused.
_Updater_RefuseManualWhileSuspended(NotifyFn := 0) {
	try {
		Message := t("script_control.paused")
		Options := Map("title", t("updater.title_update"), "level", "warning")
		if IsObject(NotifyFn)
			NotifyFn.Call(Message, Options)
		else
			NotifierSend(Message, Options)
		try LoggerWarn("Updater", "Manual updater action refused while suspended.")
		return false
	} catch as Err {
		try LoggerError("Updater", "Could not surface paused-action refusal: {1}.", Err.Message)
		return false
	}
}

_Updater_QueueManualPauseNotice(Request) {
	global _UpdaterPendingManualPauseNoticeCount, _UpdaterPendingManualPauseNoticeIds
	if !_Updater_RequestContextValid(Request)
		return false
	; The immutable request owns a shared latch object. Every callback carrying
	; that request observes the same claim, including callbacks delivered after
	; the pending-id Map was drained. The latch is garbage-collected with the last
	; request owner, so exact-once deduplication needs no unbounded tombstone Map.
	Added := false
	PauseTerminalState := Request.PauseTerminalState
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		if (!PauseTerminalState.Claimed
				and !_UpdaterPendingManualPauseNoticeIds.Has(Request.RequestId)) {
			_UpdaterPendingManualPauseNoticeIds[Request.RequestId] := Request.Generation
			_UpdaterPendingManualPauseNoticeCount := _UpdaterPendingManualPauseNoticeIds.Count
			PauseTerminalState.Claimed := true
			Added := true
		}
	}
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
	if Added
		try LoggerWarn("Updater", "Manual update request {1} from generation {2} cancelled at a later suspend boundary; visible terminal queued.", Request.RequestId, Request.Generation)
	return Added
}

; Shared terminal policy for every updater/changelog async consumer.
_Updater_RequestMayPublish(Request, IsSuspended := unset, NotifyFn := 0) {
	global UPDATER_REQUEST_POLICY_ALLOW, UPDATER_REQUEST_POLICY_NOTIFY
	if !IsSet(IsSuspended)
		IsSuspended := A_IsSuspended
	if !_Updater_RequestContextValid(Request) {
		try LoggerError("Updater", "Async completion discarded because request provenance is missing or malformed.")
		return false
	}
	Policy := _Updater_RequestPolicy(Request, IsSuspended)
	if (Policy == UPDATER_REQUEST_POLICY_ALLOW)
		return true
	if (Policy == UPDATER_REQUEST_POLICY_NOTIFY) {
		_Updater_QueueManualPauseNotice(Request)
		if !IsSuspended
			Updater_OnSuspendResume(NotifyFn)
		return false
	}
	try LoggerDebug("Updater", "Update request from generation {1} discarded at a suspend boundary.", Request.Generation)
	return false
}

_Updater_NewAsyncCancellation(Reason := "") {
	global UPDATER_ASYNC_TERMINAL_CANCELLED
	if !(Reason is String)
		Reason := ""
	return { Kind: UPDATER_ASYNC_TERMINAL_CANCELLED, Reason: Reason }
}

_Updater_AsyncTerminalIsCancelled(Terminal) {
	global UPDATER_ASYNC_TERMINAL_CANCELLED
	return Type(Terminal) == "Object"
		and Terminal.HasProp("Kind")
		and Terminal.HasProp("Reason")
		and Terminal.Kind is String
		and Terminal.Kind == UPDATER_ASYNC_TERMINAL_CANCELLED
		and Terminal.Reason is String
}

; Commits release state only while the originating request still owns the
; current lifecycle generation.
_Updater_TryPublishRelease(Request, Release, IsSuspended := unset) {
	global UPDATER_REQUEST_POLICY_ALLOW, UPDATER_LATEST_RELEASE
	if !IsSet(IsSuspended)
		IsSuspended := A_IsSuspended
	if (Type(Release) != "Object" or !Release.HasProp("Tag")) {
		try LoggerError("Updater", "Release publication refused malformed release data.")
		return false
	}
	PreviousCritical := A_IsCritical
	Published := false
	Critical("On")
	try {
		if (_Updater_RequestPolicy(Request, IsSuspended) == UPDATER_REQUEST_POLICY_ALLOW) {
			UPDATER_LATEST_RELEASE := Release
			Published := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !Published
		_Updater_RequestMayPublish(Request, IsSuspended)
	return Published
}

_Updater_TryReserveReleaseNotification(Request, Tag, IsSuspended := unset) {
	global UPDATER_REQUEST_ORIGIN_BACKGROUND, UPDATER_REQUEST_POLICY_ALLOW
	global UPDATER_LAST_NOTIFIED_TAG, _UpdaterPendingReleaseNotification
	if !IsSet(IsSuspended)
		IsSuspended := A_IsSuspended
	if (!_Updater_RequestContextValid(Request)
		or Type(Tag) != "String" or Tag == "")
		return 0
	Reservation := {
		Tag: Tag,
		NormalizedTag: _Updater_NormalizeTag(Tag),
		Generation: Request.Generation
	}
	PreviousCritical := A_IsCritical
	Reserved := false
	Critical("On")
	try {
		if (_Updater_RequestPolicy(Request, IsSuspended) == UPDATER_REQUEST_POLICY_ALLOW
			and Request.Origin == UPDATER_REQUEST_ORIGIN_BACKGROUND
			and _Updater_NormalizeTag(UPDATER_LAST_NOTIFIED_TAG) != Reservation.NormalizedTag
			and !IsObject(_UpdaterPendingReleaseNotification)) {
			_UpdaterPendingReleaseNotification := Reservation
			Reserved := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !Reserved
		_Updater_RequestMayPublish(Request, IsSuspended)
	return Reserved ? Reservation : 0
}

_Updater_CommitReleaseNotification(Reservation, Request, IsSuspended := unset) {
	global UPDATER_REQUEST_POLICY_ALLOW
	global UPDATER_LAST_NOTIFIED_TAG, _UpdaterPendingReleaseNotification
	if !IsSet(IsSuspended)
		IsSuspended := A_IsSuspended
	if !IsObject(Reservation)
		return false
	PreviousCritical := A_IsCritical
	Committed := false
	Critical("On")
	try {
		if (IsObject(_UpdaterPendingReleaseNotification)
			and ObjPtr(_UpdaterPendingReleaseNotification) == ObjPtr(Reservation)
			and _Updater_RequestPolicy(Request, IsSuspended) == UPDATER_REQUEST_POLICY_ALLOW) {
			UPDATER_LAST_NOTIFIED_TAG := Reservation.Tag
			_UpdaterPendingReleaseNotification := 0
			Committed := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Committed
}

_Updater_ReleaseNotificationReservation(Reservation) {
	global _UpdaterPendingReleaseNotification
	if !IsObject(Reservation)
		return false
	PreviousCritical := A_IsCritical
	Released := false
	Critical("On")
	try {
		if (IsObject(_UpdaterPendingReleaseNotification)
			and ObjPtr(_UpdaterPendingReleaseNotification) == ObjPtr(Reservation)) {
			_UpdaterPendingReleaseNotification := 0
			Released := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Released
}

_Updater_TryPublishFetchCache(Channel, Etag, Json, Request) {
	global _UpdaterFetchCache, UPDATER_REQUEST_POLICY_ALLOW
	Entry := { Etag: Etag, Json: Json }
	PreviousCritical := A_IsCritical
	Published := false
	Critical("On")
	try {
		if (_Updater_RequestPolicy(Request) == UPDATER_REQUEST_POLICY_ALLOW) {
			_UpdaterFetchCache[Channel] := Entry
			Published := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Published
}

; Drain one retained visible terminal per interrupted manual request after the
; driver has resumed. Optional callables are deterministic test seams.
Updater_OnSuspendResume(NotifyFn := 0, IsSuspended := unset, RebuildFn := 0) {
	global _UpdaterPendingManualPauseNoticeCount, _UpdaterPendingManualPauseNoticeIds
	global _UpdaterPauseGeneration
	HasSuspendOverride := IsSet(IsSuspended)
	if (_UpdaterPendingManualPauseNoticeCount <= 0) {
		if HasSuspendOverride
			return _Updater_ReplayPendingMenuRebuild(RebuildFn, IsSuspended)
		return _Updater_ReplayPendingMenuRebuild(RebuildFn)
	}
	try {
		Message := t("script_control.paused")
		Options := Map("title", t("updater.title_update"), "level", "warning")
	} catch as Err {
		try LoggerError("Updater", "Could not resolve paused-request notification text: {1}.", Err.Message)
		return false
	}
	PreviousCritical := A_IsCritical
	Pending := []
	ResumeGeneration := -1
	Critical("On")
	try {
		CurrentlySuspended := HasSuspendOverride ? IsSuspended : A_IsSuspended
		if !CurrentlySuspended {
			for RequestId, RequestGeneration in _UpdaterPendingManualPauseNoticeIds
				Pending.Push({ RequestId: RequestId, Generation: RequestGeneration })
			_UpdaterPendingManualPauseNoticeIds.Clear()
			_UpdaterPendingManualPauseNoticeCount := 0
			ResumeGeneration := _UpdaterPauseGeneration
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	PendingCount := Pending.Length
	if (PendingCount <= 0)
		return false
	loop PendingCount {
		CurrentlySuspended := HasSuspendOverride ? IsSuspended : A_IsSuspended
		if (CurrentlySuspended or _UpdaterPauseGeneration != ResumeGeneration) {
			_Updater_RestoreManualPauseNotices(Pending, A_Index)
			return false
		}
		try {
			if IsObject(NotifyFn)
				NotifyFn.Call(Message, Options)
			else
				NotifierSend(Message, Options)
		} catch as Err {
			_Updater_RestoreManualPauseNotices(Pending, A_Index)
			try LoggerError("Updater", "Could not surface the paused-request terminal: {1}.", Err.Message)
			return false
		}
		CurrentlySuspended := HasSuspendOverride ? IsSuspended : A_IsSuspended
		if (CurrentlySuspended or _UpdaterPauseGeneration != ResumeGeneration) {
			Remaining := PendingCount - A_Index
			if (Remaining > 0)
				_Updater_RestoreManualPauseNotices(Pending, A_Index + 1)
			return (Remaining == 0)
		}
	}
	try LoggerInfo("Updater", "Surfaced {1} manual update request(s) cancelled by suspend.", PendingCount)
	if HasSuspendOverride
		_Updater_ReplayPendingMenuRebuild(RebuildFn, IsSuspended)
	else
		_Updater_ReplayPendingMenuRebuild(RebuildFn)
	return true
}

_Updater_RestoreManualPauseNotices(Notices, StartIndex) {
	global _UpdaterPendingManualPauseNoticeCount, _UpdaterPendingManualPauseNoticeIds
	if !IsObject(Notices) or Type(StartIndex) != "Integer" or StartIndex < 1
		return
	PreviousCritical := A_IsCritical
	Critical("On")
	try {
		loop Notices.Length - StartIndex + 1 {
			Notice := Notices[StartIndex + A_Index - 1]
			if !_UpdaterPendingManualPauseNoticeIds.Has(Notice.RequestId)
				_UpdaterPendingManualPauseNoticeIds[Notice.RequestId] := Notice.Generation
		}
		_UpdaterPendingManualPauseNoticeCount := _UpdaterPendingManualPauseNoticeIds.Count
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
}

_Updater_MarkMenuRebuildPending() {
	global _UpdaterMenuRebuildPending
	_UpdaterMenuRebuildPending := true
}

_Updater_ReplayPendingMenuRebuild(RebuildFn := 0, IsSuspended := unset) {
	global _UpdaterMenuRebuildPending, _UpdaterPauseGeneration
	if !_UpdaterMenuRebuildPending
		return false
	if !IsSet(IsSuspended)
		IsSuspended := A_IsSuspended
	if IsSuspended
		return false
	ResumeGeneration := _UpdaterPauseGeneration
	_UpdaterMenuRebuildPending := false
	try {
		Result := IsObject(RebuildFn)
			? _Updater_RunMenuRebuildForGeneration(
				ResumeGeneration, RebuildFn)
			: _Updater_ScheduleMenuRebuildForGeneration(ResumeGeneration)
		if !_Updater_ResultSucceeded(Result) {
			_UpdaterMenuRebuildPending := true
			return false
		}
	} catch as Err {
		_UpdaterMenuRebuildPending := true
		try LoggerError("Updater", "Could not replay the deferred updater menu rebuild: {1}.", Err.Message)
		return false
	}
	return true
}

_Updater_MenuGenerationAuthorized(Generation) {
	global _UpdaterPauseGeneration
	return !A_IsSuspended and Type(Generation) == "Integer"
		and Generation == _UpdaterPauseGeneration
}

_Updater_MenuRequestAuthorized(Request) {
	global UPDATER_REQUEST_POLICY_ALLOW
	return _Updater_RequestPolicy(Request) == UPDATER_REQUEST_POLICY_ALLOW
}

_Updater_ScheduleMenuRebuildForGeneration(Generation, DelayMs := 50) {
	global _UpdaterPauseGeneration
	if (A_IsSuspended or Generation != _UpdaterPauseGeneration) {
		_Updater_MarkMenuRebuildPending()
		return false
	}
	try SetTimer(_Updater_RunMenuRebuildForGeneration.Bind(Generation), -DelayMs)
	catch as Err {
		_Updater_MarkMenuRebuildPending()
		try LoggerError("Updater", "Could not schedule the lifecycle-owned updater menu rebuild: {1}.", Err.Message)
		return false
	}
	return true
}

_Updater_RunMenuRebuildForGeneration(Generation, WorkerFn := 0) {
	if !_Updater_MenuGenerationAuthorized(Generation) {
		_Updater_MarkMenuRebuildPending()
		return false
	}
	return _Updater_RebuildMenu(
		_Updater_MenuGenerationAuthorized.Bind(Generation), WorkerFn)
}

_Updater_ScheduleMenuRebuildForRequest(Request, DelayMs := 50) {
	global UPDATER_REQUEST_POLICY_ALLOW
	if (_Updater_RequestPolicy(Request) != UPDATER_REQUEST_POLICY_ALLOW) {
		_Updater_MarkMenuRebuildPending()
		return false
	}
	try SetTimer(_Updater_RunMenuRebuildForRequest.Bind(Request), -DelayMs)
	catch as Err {
		_Updater_MarkMenuRebuildPending()
		try LoggerError("Updater", "Could not schedule the updater menu rebuild: {1}.", Err.Message)
		return false
	}
	return true
}

_Updater_RunMenuRebuildForRequest(Request, WorkerFn := 0) {
	global UPDATER_REQUEST_POLICY_ALLOW
	if (_Updater_RequestPolicy(Request) != UPDATER_REQUEST_POLICY_ALLOW) {
		_Updater_MarkMenuRebuildPending()
		return false
	}
	return _Updater_RebuildMenu(
		_Updater_MenuRequestAuthorized.Bind(Request), WorkerFn)
}

; Returns the GitHub Releases API URL for the chosen channel.
; For the dev channel we fetch the last 10 releases and pick the first one
; whose "prerelease" flag is true.  Using per_page=1 was insufficient because
; GitHub returns releases in reverse-chronological order: if the most recent
; publish is a stable release it lands at position 1 and any newer prerelease
; hiding behind it would go undetected.
Updater_ReleaseApiUrl(Channel) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	if (Channel == "dev")
		return "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases?per_page=10"
	; Stable: the dedicated "latest" endpoint always returns the newest non-pre-release.
	return "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases/latest"
}

; Returns the GitHub Releases HTML page URL (for "Open in browser" actions).
Updater_ReleasesPageUrl() {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	return "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases"
}

; Returns the GitHub release URL to surface as the "current version" deep link
; in the tray menu. In compiled mode this is the stamped BUNDLE_RELEASE_URL
; (frozen at build time, so the link always points at the version actually
; running — even if a newer release has shipped since). In dev / source mode
; or when stamping failed we fall back to the channel's "latest" page so the
; menu entry still does something useful.
Updater_CurrentReleaseUrl() {
	global BUNDLE_RELEASE_URL, UPDATER_GH_OWNER, UPDATER_GH_REPO
	if IsSet(BUNDLE_RELEASE_URL)
		and BUNDLE_RELEASE_URL != ""
		and BUNDLE_RELEASE_URL != "__BUNDLE_RELEASE_URL__"
		return BUNDLE_RELEASE_URL
	return "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases/latest"
}

; Shared manual URL boundary for both About-menu links and changelog actions.
; Refuse a born-paused click before URL resolution or Run, then retain the
; immutable request across either yielding operation.
_Updater_IsAllowedManualUrl(Url) {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	if !(Url is String) || Url == ""
		return false
	if RegExMatch(Url, "[\x00-\x20\x7f]")
		return false
	AllowedRoot := "https://github.com/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO
	if SubStr(Url, 1, StrLen(AllowedRoot)) !== AllowedRoot
		return false
	Suffix := SubStr(Url, StrLen(AllowedRoot) + 1)
	if Suffix == ""
		return true
	Boundary := SubStr(Suffix, 1, 1)
	return Boundary == "/" || Boundary == "?" || Boundary == "#"
}

_Updater_OpenManualUrl(ResolveUrlFn, Request := unset, IsSuspended := unset, NotifyFn := 0, RunFn := 0) {
	global UPDATER_REQUEST_ORIGIN_MANUAL
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
	try {
		Url := ResolveUrlFn.Call()
		if HasSuspendOverride {
			if !_Updater_RequestMayPublish(Request, IsSuspended, NotifyFn)
				return false
		} else if !_Updater_RequestMayPublish(Request, , NotifyFn) {
			return false
		}
		if !_Updater_IsAllowedManualUrl(Url) {
			try LoggerWarn("Updater", "Refused a manual URL outside the repository HTTPS allowlist.")
			return false
		}
		if IsObject(RunFn)
			RunFn.Call(Url)
		else
			Run(Url)
		return true
	} catch as e {
		try LoggerWarn("Updater", "Failed to open release URL: {1}.", e.Message)
		return false
	}
}

Updater_OpenCurrentRelease(*) {
	return _Updater_OpenManualUrl(Updater_CurrentReleaseUrl)
}

Updater_OpenReleasesPage(*) {
	return _Updater_OpenManualUrl(Updater_ReleasesPageUrl)
}



; ====================================
; ===== 1.4) Network call =============
; ====================================

; Makes a synchronous GET to the GitHub Releases API and returns the raw JSON
; string. Returns "" on any error (network, HTTP non-200, COM failure).
; Uses If-None-Match when a prior ETag is cached so unchanged feeds return 304
; without consuming the GitHub anonymous rate-limit budget.
Updater_FetchLatestJson(Channel) {
	global _UpdaterFetchCache
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Url := Updater_ReleaseApiUrl(Channel)
	Json := ""
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, false)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		; Always-finite timeouts — a 0 in any slot means "infinite" to WinHttp
		; and lets a stalled DNS resolve freeze the AHK main thread (and all
		; keyboard remapping) until the network recovers. See the constants at
		; the top of this file for the per-phase budget and the rationale.
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		if _UpdaterFetchCache.Has(Channel) {
			Etag := _UpdaterFetchCache[Channel].Etag
			if (Etag is String and Etag != "")
				Req.SetRequestHeader("If-None-Match", Etag)
		}
		Req.Send()
		Etag := ""
		try Etag := Req.GetResponseHeader("ETag")
		Json := _Updater_InterpretResponse(Req.Status, Req.ResponseText, Etag, Channel, Url)
	} catch as Err {
		LoggerWarn("Updater", "HTTP request failed: {1}.", Err.Message)
	}
	return Json
}

; Interprets a completed GitHub Releases response into the single-object JSON
; string every downstream parser expects. Shared by the synchronous fetch above
; and the async background path so their status / ETag / array-unwrap handling
; can never drift apart. Returns "" when there is nothing usable (304 with no
; cached body, 403 rate limit, or any other non-200). Updates the per-channel
; conditional-GET cache on a fresh 200.
_Updater_InterpretResponse(Status, Body, Etag, Channel, Url, Request := unset) {
	global _UpdaterFetchCache
	Json := ""
	if (Status == 304) {
		if _UpdaterFetchCache.Has(Channel)
			Json := _UpdaterFetchCache[Channel].Json
		try LoggerDebug("Updater", "GitHub releases unchanged (304) for channel {1}.", Channel)
	} else if (Status == 200) {
		Json := Body
		if (Etag is String and Etag != ""
			and _Updater_JsonPayloadIsUsable(Json)) {
			if IsSet(Request)
				_Updater_TryPublishFetchCache(Channel, Etag, Json, Request)
			else
				_UpdaterFetchCache[Channel] := { Etag: Etag, Json: Json }
		}
	} else if (Status == 403) {
		try LoggerWarn("Updater", "GitHub API rate limit (HTTP 403) for '{1}'.", Url)
	} else {
		try LoggerWarn("Updater", "GitHub API HTTP {1} for '{2}'.", Status, Url)
	}
	; Array response (dev channel) — unwrap to the highest-semver prerelease so
	; every downstream parser receives a single-object JSON string.
	if (_Updater_JsonPayloadIsUsable(Json)
		and SubStr(LTrim(Json), 1, 1) == "[")
		Json := _Updater_UnwrapLatestPrerelease(Json)
	return Json
}

; Async, non-blocking sibling of Updater_FetchLatestJson. Dispatches the GitHub
; Releases request in a tree-owned curl child and returns at once;
; OnJson(Json) is invoked later from a poll timer once the response completes
; (Json == "" on any failure). This is what the background poller uses, so a
; slow or stalled network can never block the AHK main thread — and therefore
; never freeze keyboard remapping. User-initiated paths keep the synchronous
; fetch (bounded timeouts, the user is actively waiting on the click). Mirrors
; the WinHTTP-async + SetTimer-poll pattern used in modules/llm.
_Updater_FetchLatestJsonAsync(Channel, Request, OnJson) {
	Url := Updater_ReleaseApiUrl(Channel)
	; Publish exact cancellation ownership before the first COM call. Open(),
	; header configuration and cache-header application can pump messages; a
	; suspend reached from that re-entrancy must find this request in the shared
	; registry before any transport effect starts.
	Owner := _Updater_RegisterAsyncRequestOwner(
		0, Channel, OnJson, Url, Request)
	if !IsObject(Owner) {
		_Updater_InvokeAsyncOnJson(OnJson, "", Request, 0,
			"invalid async check ownership")
		return 0
	}
	_Updater_SendOwnedAsyncRequest(Owner, _Updater_PollAsync,
		"Async check dispatch", _Updater_PrepareLatestAsyncTransport)
	return Owner
}

; Publishes one opaque exact owner before transport construction or Send.
; Immutable request provenance lives with the record so completion,
; cancellation and setup failure all answer the same callback exactly once.
_Updater_RegisterAsyncRequestOwner(Http, Channel, OnJson, Url, Request) {
	global _UpdaterAsyncRequests, _UpdaterAsyncCounter
	global _UpdaterAsyncAdmissionBoundary
	global _UpdaterActiveAsyncTerminalDeliveryCount
	global UPDATER_REQUEST_POLICY_ALLOW
	if !_Updater_RequestContextValid(Request) {
		try LoggerError("Updater", "Async request registration refused malformed provenance.")
		return 0
	}
	if ((!IsObject(Http)
			and !(Type(Http) == "Integer" and Http == 0))
		or !IsObject(OnJson)
		or !(Channel is String)
		or !(Url is String)) {
		try LoggerError("Updater", "Async request registration refused malformed transport ownership.")
		return 0
	}
	Record := Map(
		"http", Http,
		"channel", Channel,
		"on_json", OnJson,
		"url", Url,
		"polls", 0,
		"request", Request,
		"send_leased", false,
		"cancel_terminal", 0,
		"terminal_claimed", false,
		"poll_fn", 0)
	Owner := { Id: 0, Record: Record }
	PreviousCritical := A_IsCritical
	AdmissionReason := ""
	Published := false
	Critical("On")
	try {
		if (IsObject(_UpdaterAsyncAdmissionBoundary)
			and _UpdaterAsyncAdmissionBoundary.HasOwnProp("Reason")
			and _UpdaterAsyncAdmissionBoundary.Reason is String) {
			AdmissionReason := _UpdaterAsyncAdmissionBoundary.Reason
			; Refusal owns a callback before registry absence becomes visible.
			Record["terminal_claimed"] := true
			_UpdaterActiveAsyncTerminalDeliveryCount += 1
		} else if (_Updater_RequestPolicy(Request) == UPDATER_REQUEST_POLICY_ALLOW) {
			_UpdaterAsyncCounter += 1
			Owner.Id := _UpdaterAsyncCounter
			_UpdaterAsyncRequests[Owner.Id] := Record
			Published := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if Published
		return Owner
	if (AdmissionReason != "") {
		Cancellation := _Updater_NewAsyncCancellation(AdmissionReason)
		_Updater_DeliverAsyncCancellationRecord(Record, Cancellation)
		Owner.TerminalDelivered := true
		return Owner
	}
	return 0
}

; Compatibility leaf for tests and callers that need only the numeric id.
_Updater_RegisterAsyncRequest(Http, Channel, OnJson, Url, Request) {
	Owner := _Updater_RegisterAsyncRequestOwner(
		Http, Channel, OnJson, Url, Request)
	return IsObject(Owner) ? Owner.Id : 0
}

_Updater_AsyncRequestOwned(Owner) {
	global _UpdaterAsyncRequests
	if (Type(Owner) != "Object"
		or !Owner.HasOwnProp("Id")
		or !Owner.HasOwnProp("Record")
		or Owner.Id <= 0
		or !(Owner.Record is Map))
		return false
	PreviousCritical := A_IsCritical
	Owned := false
	Critical("On")
	try {
		Owned := _UpdaterAsyncRequests.Has(Owner.Id)
			and ObjPtr(_UpdaterAsyncRequests[Owner.Id]) == ObjPtr(Owner.Record)
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Owned
}

; Acquires the exact record's operation lease. The historical "send" name is
; retained because this closes the claim-to-Send bug, but the same lease is also
; used by response polls: cancellation may detach registry admission at once,
; yet it must not Abort or callback while a COM frame still owns the transport.
_Updater_AcquireAsyncSendLease(Owner) {
	global _UpdaterAsyncRequests, _UpdaterActiveSendLeaseCount
	if (Type(Owner) != "Object"
		or !Owner.HasOwnProp("Id")
		or !Owner.HasOwnProp("Record")
		or !(Owner.Record is Map))
		return false
	Record := Owner.Record
	PreviousCritical := A_IsCritical
	Acquired := false
	Critical("On")
	try {
		if (_UpdaterAsyncRequests.Has(Owner.Id)
			and ObjPtr(_UpdaterAsyncRequests[Owner.Id]) == ObjPtr(Record)
			and !Record.Get("send_leased", false)) {
			Record["send_leased"] := true
			_UpdaterActiveSendLeaseCount += 1
			Acquired := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Acquired
}

; The Send decision is one atomic compare-and-commit against both exact registry
; ownership and any cancellation recorded while preparation pumped messages.
_Updater_CommitAsyncSendLease(Owner) {
	global _UpdaterAsyncRequests
	if (Type(Owner) != "Object"
		or !Owner.HasOwnProp("Id")
		or !Owner.HasOwnProp("Record")
		or !(Owner.Record is Map))
		return false
	Record := Owner.Record
	PreviousCritical := A_IsCritical
	Committed := false
	Critical("On")
	try {
		if (Record.Get("send_leased", false)
			and !IsObject(Record.Get("cancel_terminal", 0))
			and _UpdaterAsyncRequests.Has(Owner.Id)
			and ObjPtr(_UpdaterAsyncRequests[Owner.Id]) == ObjPtr(Record)) {
			Committed := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Committed
}

; Holds the global count until deferred Abort and callback return. A later
; lifecycle boundary must not mistake an empty registry for COM quiescence while
; the lower frame is still unwinding its exact cancellation terminal.
_Updater_ReleaseAsyncSendLease(Owner) {
	global _UpdaterActiveSendLeaseCount
	if (Type(Owner) != "Object"
		or !Owner.HasOwnProp("Record")
		or !(Owner.Record is Map))
		return false
	Record := Owner.Record
	PreviousCritical := A_IsCritical
	Released := false
	Cancellation := 0
	Critical("On")
	try {
		if Record.Get("send_leased", false) {
			Record["send_leased"] := false
			Cancellation := Record.Get("cancel_terminal", 0)
			Record["cancel_terminal"] := 0
			Released := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !Released
		return false
	try {
		if IsObject(Cancellation)
			_Updater_DeliverAsyncCancellationRecord(Record, Cancellation)
	} finally {
		PreviousCritical := A_IsCritical
		Critical("On")
		try _UpdaterActiveSendLeaseCount := Max(
			0, _UpdaterActiveSendLeaseCount - 1)
		finally Critical(PreviousCritical ? PreviousCritical : "Off")
		_Updater_ScheduleDeferredChannelReloadIfReady()
	}
	return IsObject(Cancellation)
}

_Updater_AsyncSendLeaseActive() {
	global _UpdaterActiveSendLeaseCount
	PreviousCritical := A_IsCritical
	Critical("On")
	try return _UpdaterActiveSendLeaseCount > 0
	finally Critical(PreviousCritical ? PreviousCritical : "Off")
}

_Updater_TakeAsyncRequest(Id, ExpectedRecord) {
	global _UpdaterAsyncRequests, _UpdaterActiveAsyncTerminalDeliveryCount
	if (Type(Id) != "Integer" or Id <= 0 or !(ExpectedRecord is Map))
		return false
	PreviousCritical := A_IsCritical
	Taken := false
	Critical("On")
	try {
		if (_UpdaterAsyncRequests.Has(Id)
			and ObjPtr(_UpdaterAsyncRequests[Id]) == ObjPtr(ExpectedRecord)) {
			_UpdaterAsyncRequests.Delete(Id)
			if !ExpectedRecord.Get("terminal_claimed", false) {
				ExpectedRecord["terminal_claimed"] := true
				_UpdaterActiveAsyncTerminalDeliveryCount += 1
			}
			Taken := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Taken
}

; Arms only while the same object still owns Id. Keeping the exact bound timer
; on the record lets cancellation disarm the one successor it is retiring.
_Updater_RearmOwnedPoll(Id, ExpectedRecord, PollFn, DelayMs) {
	global _UpdaterAsyncRequests
	if (Type(Id) != "Integer"
		or Id <= 0
		or !(ExpectedRecord is Map)
		or !IsObject(PollFn)
		or Type(DelayMs) != "Integer"
		or DelayMs <= 0)
		return false
	PreviousCritical := A_IsCritical
	Armed := false
	ArmErr := 0
	Critical("On")
	try {
		if (_UpdaterAsyncRequests.Has(Id)
			and ObjPtr(_UpdaterAsyncRequests[Id]) == ObjPtr(ExpectedRecord)) {
			ExpectedRecord["poll_fn"] := PollFn
			try {
				SetTimer(PollFn, -DelayMs)
				Armed := true
			} catch as Err {
				ExpectedRecord["poll_fn"] := 0
				ArmErr := Err
			}
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if IsObject(ArmErr)
		try LoggerError("Updater", "Could not arm async response poll: {1}.", ArmErr.Message)
	return Armed
}

_Updater_AbortAsyncTransport(Record, Context) {
	if !(Record is Map) or !IsObject(Record.Get("http", 0))
		return false
	try {
		Record["http"].Abort()
		return true
	} catch as AbortErr {
		try LoggerError("Updater", "Async transport Abort failed during {1}: {2}.", Context, AbortErr.Message)
		return false
	}
}

_Updater_DeferLeasedAsyncCancellation(Record, Cancellation) {
	if !(Record is Map) or !IsObject(Cancellation)
		return false
	PreviousCritical := A_IsCritical
	Deferred := false
	Critical("On")
	try {
		if Record.Get("send_leased", false) {
			if !IsObject(Record.Get("cancel_terminal", 0))
				Record["cancel_terminal"] := Cancellation
			Deferred := true
		}
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return Deferred
}

; One direct cancellation terminal: stop the exact timer successor, abort the
; detached transport, then callback outside Critical. Leased records reach this
; same path only after their COM frame has returned.
_Updater_DeliverAsyncCancellationRecord(Record, Cancellation) {
	if !(Record is Map and Record.Has("on_json") and Record.Has("request")) {
		try LoggerError("Updater", "Cancelled async request lacked callback provenance.")
		if Record is Map
			_Updater_EndAsyncTerminalRecord(Record)
		return false
	}
	; Abort and callback may both pump the deferred Reload continuation. Publish
	; terminal ownership before either effect can observe a false quiescence.
	_Updater_ClaimAsyncTerminalRecord(Record)
	if IsObject(Record.Get("poll_fn", 0))
		try SetTimer(Record["poll_fn"], 0)
	_Updater_AbortAsyncTransport(Record, "async cancellation")
	return _Updater_InvokeAsyncOnJson(Record["on_json"], "",
		Record["request"], Cancellation, "async cancellation", Record)
}

_Updater_PrepareLatestAsyncTransport(Owner, FactoryFn := 0) {
	global _UpdaterFetchCache
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Record := Owner.Record
	Req := IsObject(FactoryFn)
		? FactoryFn.Call()
		: CurlAsyncRequest()
	if !IsObject(Req)
		throw TypeError("Async transport factory did not return an object")
	; Publish the exact transport immediately after construction. Every later
	; COM call is now reachable through the already-published registry owner.
	Record["http"] := Req
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.Open("GET", Record["url"], true)
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.SetRequestHeader("Accept", "application/vnd.github+json")
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
		UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	if _UpdaterFetchCache.Has(Record["channel"]) {
		Etag := _UpdaterFetchCache[Record["channel"]].Etag
		if (Etag is String and Etag != "")
			Req.SetRequestHeader("If-None-Match", Etag)
	}
	return _Updater_AsyncRequestOwned(Owner) ? Req : 0
}

_Updater_PrepareReleasesListAsyncTransport(Owner, FactoryFn := 0) {
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Record := Owner.Record
	Req := IsObject(FactoryFn)
		? FactoryFn.Call()
		: CurlAsyncRequest()
	if !IsObject(Req)
		throw TypeError("Async transport factory did not return an object")
	Record["http"] := Req
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.Open("GET", Record["url"], true)
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.SetRequestHeader("Accept", "application/vnd.github+json")
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
	if !_Updater_AsyncRequestOwned(Owner)
		return 0
	Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
		UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
	return _Updater_AsyncRequestOwned(Owner) ? Req : 0
}

_Updater_FailOwnedAsyncDispatch(Owner, FailureContext, FailureErr) {
	if (Type(Owner) != "Object"
		or !Owner.HasOwnProp("Id")
		or !Owner.HasOwnProp("Record")
		or !(Owner.Record is Map))
		return false
	Record := Owner.Record
	if !_Updater_TakeAsyncRequest(Owner.Id, Record)
		return false
	_Updater_AbortAsyncTransport(Record, FailureContext)
	Detail := IsObject(FailureErr) and FailureErr.HasProp("Message")
		? FailureErr.Message
		: FailureErr . ""
	try LoggerDebug("Updater", "{1} failed: {2}.", FailureContext, Detail)
	_Updater_InvokeAsyncOnJson(Record["on_json"], "", Record["request"],
		0, FailureContext . " failure", Record)
	return false
}

_Updater_SendOwnedAsyncRequest(Owner, PollFn, FailureContext, PrepareFn := 0) {
	if (Type(Owner) != "Object"
		or !Owner.HasOwnProp("Record")
		or !(Owner.Record is Map))
		return false
	if !IsObject(PollFn)
		return _Updater_FailOwnedAsyncDispatch(
			Owner, FailureContext, TypeError("Async request requires a poll callback"))
	if !_Updater_AcquireAsyncSendLease(Owner)
		return false
	Record := Owner.Record
	SendCommitted := false
	SendError := 0
	FailurePhase := "preparation"
	CancelledDuringLease := false
	try {
		Http := IsObject(PrepareFn)
			? PrepareFn.Call(Owner)
			: Record.Get("http", 0)
		if !IsObject(Http)
			throw Error("Async transport preparation did not return a transport")
		Record["http"] := Http
		FailurePhase := "Send"
		SendCommitted := _Updater_CommitAsyncSendLease(Owner)
		if SendCommitted
			Http.Send()
	} catch as Err {
		SendError := Err
	} finally {
		CancelledDuringLease := _Updater_ReleaseAsyncSendLease(Owner)
	}
	; Cancellation owns the terminal and wins over a simultaneous preparation or
	; Send exception. The lease release already performed Abort + callback.
	if CancelledDuringLease
		return false
	if IsObject(SendError)
		return _Updater_FailOwnedAsyncDispatch(
			Owner, FailureContext . " " . FailurePhase, SendError)
	if !SendCommitted {
		if _Updater_AsyncRequestOwned(Owner)
			return _Updater_FailOwnedAsyncDispatch(
				Owner, FailureContext . " Send commit",
				Error("Send commit was refused without a terminal owner"))
		return false
	}
	if !_Updater_AsyncRequestOwned(Owner)
		return false
	PollStarted := false
	try PollStarted := _Updater_ResultSucceeded(PollFn.Call(Owner.Id))
	catch as Err {
		return _Updater_FailOwnedAsyncDispatch(
			Owner, FailureContext . " poll handoff", Err)
	}
	if !PollStarted and _Updater_AsyncRequestOwned(Owner)
		return _Updater_FailOwnedAsyncDispatch(
			Owner, FailureContext . " poll handoff",
			Error("Poll callback returned an unsuccessful result"))
	return PollStarted
}

; Non-blocking completion poll for one in-flight async update check. Asks WinHTTP
; "is the response ready?" via WaitForResponse(0) (0 = do not wait); re-arms
; itself until ready, then interprets the response and fires the stored OnJson.
; A throw means the request errored (DNS / connect / timeout) — treated as a
; failure that yields OnJson(""). UPDATER_ASYNC_MAX_POLLS is a belt-and-suspenders
; cap so a wedged request can never leave a poll timer running forever.
; The async update check polls on a timer, and each tick calls
; WaitForResponse(0) on a COM object. A COM call that blocks stalls the whole
; message pump — the same failure mode the Ollama busy-loop fix addressed — and
; this path had no segment, so a stall here was invisible and looked like general
; sluggishness. Two QPC reads; the log line is gated by the profiler floor.
_Updater_PollAsync(id) {
	global _UpdaterAsyncRequests, UPDATER_ASYNC_POLL_MS, UPDATER_ASYNC_MAX_POLLS
	PreviousCritical := A_IsCritical
	rec := 0
	Critical("On")
	try {
		if _UpdaterAsyncRequests.Has(id)
			rec := _UpdaterAsyncRequests[id]
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !(rec is Map)
		return false
	Owner := { Id: id, Record: rec }
	_hpUpdaterPoll := HotPath_Now()
	if !_Updater_AcquireAsyncSendLease(Owner)
		return false
	ready := false
	failed := false
	Rearmed := false
	ArmFailed := false
	Status := 0
	Body := ""
	Etag := ""
	CancelledDuringLease := false
	try {
		http := rec.Get("http", 0)
		if !IsObject(http)
			throw TypeError("Async poll record has no transport")
		ready := http.WaitForResponse(0)
		if !ready {
			rec["polls"] += 1
			if (rec["polls"] > UPDATER_ASYNC_MAX_POLLS) {
				failed := true
				try LoggerWarn("Updater", "Async check exceeded its poll budget — aborting.")
			} else {
				PollFn := _Updater_PollAsync.Bind(id)
				Rearmed := _Updater_RearmOwnedPoll(
					id, rec, PollFn, UPDATER_ASYNC_POLL_MS)
				ArmFailed := !Rearmed
			}
		} else {
			try Etag := http.GetResponseHeader("ETag")
			Status := http.Status
			Body := http.ResponseText
		}
	} catch as Err {
		failed := true
		try LoggerDebug("Updater", "Async check failed: {1}.", Err.Message)
	} finally {
		CancelledDuringLease := _Updater_ReleaseAsyncSendLease(Owner)
	}
	if CancelledDuringLease
		return false
	if Rearmed {
		; The re-arm exit is the one that runs on EVERY tick but the last, so
		; leaving it unmeasured would attribute the poll cost to the single
		; completion tick and report the path as fast.
		HotPath_LogIfSlow("Updater.Poll", _hpUpdaterPoll, "re-armed")
		return true
	}
	if ArmFailed
		return _Updater_FailOwnedAsyncDispatch(
			Owner, "Async poll handoff",
			Error("Could not arm the next async response poll"))
	Channel  := rec["channel"]
	Url      := rec["url"]
	Request  := rec["request"]
	Json := ""
	if (!failed and ready) {
		try {
			Json := _Updater_InterpretResponse(
				Status, Body, Etag, Channel, Url, Request)
		} catch as Err {
			try LoggerDebug("Updater", "Async response read failed: {1}.", Err.Message)
			Json := ""
		}
	}
	if !_Updater_TakeAsyncRequest(id, rec)
		return false
	if failed
		_Updater_AbortAsyncTransport(rec, "async poll failure")
	_Updater_InvokeAsyncOnJson(rec["on_json"], Json, Request, 0,
		"async background completion", rec)
	HotPath_LogIfSlow("Updater.Poll", _hpUpdaterPoll, failed ? "failed" : "completed")
	return true
}

; Abandons every in-flight async update check. Called when background checks are
; stopped (e.g. the user switches the cadence to "never") so a response landing
; after the fact cannot still pop a notification. Dropping the registry entry
; releases the WinHTTP object; any pending poll timer no-ops on its next tick
; because the id is gone.
; The swap itself is side-effect free beyond atomic state publication. Callers
; own Critical so the replacement Map and generation invalidation are one
; indivisible boundary; callbacks are delivered only after Critical is restored.
_Updater_SwapAsyncRequestsForBoundary(Reason, ReplacementRequests) {
	global _UpdaterAsyncRequests, _UpdaterPauseGeneration
	global _UpdaterBackgroundGeneration, _UpdaterPendingReleaseNotification
	global _UpdaterActiveAsyncTerminalDeliveryCount
	global UPDATER_CANCEL_REASON_SUSPEND
	if !(ReplacementRequests is Map)
		throw TypeError("Updater replacement registry must be a Map")
	if (Reason == UPDATER_CANCEL_REASON_SUSPEND)
		_UpdaterPauseGeneration += 1
	_UpdaterBackgroundGeneration += 1
	_UpdaterPendingReleaseNotification := 0
	PendingRequests := _UpdaterAsyncRequests
	; Claim non-leased terminals before an empty replacement becomes visible.
	; Leased records remain covered by the send count and claim on lease release.
	for _Id, Record in PendingRequests {
		if !(Record is Map) or Record.Get("send_leased", false)
			continue
		if !Record.Get("terminal_claimed", false) {
			Record["terminal_claimed"] := true
			_UpdaterActiveAsyncTerminalDeliveryCount += 1
		}
	}
	_UpdaterAsyncRequests := ReplacementRequests
	return PendingRequests
}

_Updater_DeliverCancelledAsyncRequests(PendingRequests, Reason := "") {
	if !(PendingRequests is Map)
		return false
	for _Id, Record in PendingRequests {
		Cancellation := _Updater_NewAsyncCancellation(Reason)
		if _Updater_DeferLeasedAsyncCancellation(Record, Cancellation)
			continue
		_Updater_DeliverAsyncCancellationRecord(Record, Cancellation)
	}
	if PendingRequests.Count > 0
		try LoggerDebug("Updater", "Cancelled {1} in-flight async update request(s) (reason: {2}).", PendingRequests.Count, Reason == "" ? "stopped" : Reason)
	return true
}

_Updater_CancelAsyncChecks(Reason := "") {
	global _UpdaterAsyncRequests
	PreviousCritical := A_IsCritical
	Critical("On")
	try Pending := _Updater_SwapAsyncRequestsForBoundary(Reason, Map())
	finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	return _Updater_DeliverCancelledAsyncRequests(Pending, Reason)
}

; Aborts an in-flight self-update staging worker because the process is going
; away. Wired into the driver's single OnExit handler (Ergopti_OnShutdown).
;
; Reload() and ExitApp() tear the process down WITHOUT running any per-module
; destructor, and Reload is this driver's standard "apply settings" mechanism —
; it also fires automatically from the keyboard-layout watcher. The download
; transaction, however, lives entirely in process-local state
; (_UpdaterDownloadInProgress plus the ShellRunner task in
; _UpdaterDownloadWorker). Once staging succeeds, _UpdaterSwapOwner replaces
; that callback ownership with an exact native process HANDLE. A normal
; Reload/quit must terminate whichever child currently owns the transaction;
; only the updater ExitIntent path may transfer the acknowledged swapper after
; every shutdown refusal gate has passed.
;
; Killing the child and logging a WARNING makes the interrupted update visible
; instead of vanishing. Never throws: an OnExit callback that throws is
; swallowed by AHK and can hang the exit.
_Updater_AbortStagingOnExit() {
	try _Updater_CancelSelfUpdateTransaction(
		"Update transaction aborted during ordinary process exit; its exact child owner was terminated.",
		false)
}

; Async, non-blocking sibling of Updater_FetchReleasesListJson. Dispatches the
; GitHub releases-list request in a tree-owned curl child and returns
; at once; OnJson(Json) is invoked from a poll timer once the response completes
; (Json == "" on any failure). Used by _Updater_OpenChangelogWindow so the
; changelog GUI build never blocks the keyboard hook on a slow network.
_Updater_FetchReleasesListJsonAsync(Channel, Request, OnJson) {
	Url := Updater_ReleasesListApiUrl(Channel)
	Owner := _Updater_RegisterAsyncRequestOwner(
		0, Channel, OnJson, Url, Request)
	if !IsObject(Owner) {
		_Updater_InvokeAsyncOnJson(OnJson, "", Request, 0,
			"invalid releases-list ownership")
		return 0
	}
	; Use the same pre-effect registry owner as the latest-release fetch.
	; _Updater_CancelAsyncChecks drains only that registry, so every transport
	; must be present there before construction, Open, headers or Send.
	_Updater_SendOwnedAsyncRequest(Owner,
		_Updater_PollReleasesListAsync, "Async releases-list dispatch",
		_Updater_PrepareReleasesListAsyncTransport)
	return Owner
}

; Non-blocking completion poll for one in-flight async releases-list fetch.
; Mirrors _Updater_PollAsync — including its registry-based cancellation: a tick
; whose id has been dropped from _UpdaterAsyncRequests no-ops — but without the
; ETag / _InterpretResponse machinery (the releases list is always returned in
; full — no 304 caching).
_Updater_PollReleasesListAsync(id) {
	global _UpdaterAsyncRequests, UPDATER_ASYNC_POLL_MS, UPDATER_ASYNC_MAX_POLLS
	PreviousCritical := A_IsCritical
	rec := 0
	Critical("On")
	try {
		if _UpdaterAsyncRequests.Has(id)
			rec := _UpdaterAsyncRequests[id]
	} finally {
		Critical(PreviousCritical ? PreviousCritical : "Off")
	}
	if !(rec is Map)
		return false
	Owner := { Id: id, Record: rec }
	if !_Updater_AcquireAsyncSendLease(Owner)
		return false
	ready  := false
	failed := false
	Rearmed := false
	ArmFailed := false
	Status := 0
	Body := ""
	CancelledDuringLease := false
	try {
		Req := rec.Get("http", 0)
		if !IsObject(Req)
			throw TypeError("Async releases-list poll record has no transport")
		ready := Req.WaitForResponse(0)
		if !ready {
			rec["polls"] += 1
			if (rec["polls"] > UPDATER_ASYNC_MAX_POLLS) {
				failed := true
				try LoggerWarn("Updater", "Async releases-list exceeded poll budget — aborting.")
			} else {
				PollFn := _Updater_PollReleasesListAsync.Bind(id)
				Rearmed := _Updater_RearmOwnedPoll(
					id, rec, PollFn, UPDATER_ASYNC_POLL_MS)
				ArmFailed := !Rearmed
			}
		} else {
			Status := Req.Status
			Body := Req.ResponseText
		}
	} catch as Err {
		failed := true
		try LoggerDebug("Updater", "Async releases-list poll failed: {1}.", Err.Message)
	} finally {
		CancelledDuringLease := _Updater_ReleaseAsyncSendLease(Owner)
	}
	if CancelledDuringLease
		return false
	if Rearmed
		return true
	if ArmFailed
		return _Updater_FailOwnedAsyncDispatch(
			Owner, "Async releases-list poll handoff",
			Error("Could not arm the next async releases-list response poll"))
	Request := rec["request"]
	Url := rec["url"]
	Json := ""
	if (!failed and ready) {
		try {
			if (Status == 200) {
				Json := Body
			} else {
				try LoggerWarn("Updater", "Releases-list HTTP {1} for '{2}'.", Status, Url)
			}
		} catch as Err {
			try LoggerDebug("Updater", "Async releases-list response read failed: {1}.", Err.Message)
		}
	}
	if !_Updater_TakeAsyncRequest(id, rec)
		return false
	if failed
		_Updater_AbortAsyncTransport(rec, "async releases-list poll failure")
	_Updater_InvokeAsyncOnJson(rec["on_json"], Json, Request, 0,
		"async releases-list completion", rec)
	return true
}

; Given a GitHub releases array JSON string, return the JSON object of the
; highest-semver prerelease entry. GitHub orders by publish date, not semver;
; a stable release at the top must not cause us to miss a newer prerelease
; further down the page. Falls back to the first entry when no prerelease
; is found.
_Updater_UnwrapLatestPrerelease(Json) {
	Chunks := _Updater_SplitReleasesArray(Json)
	BestTag := ""
	BestChunk := ""
	for _, Chunk in Chunks {
		if !_Updater_ParsePrerelease(Chunk)
			continue
		Tag := Updater_ParseTagName(Chunk)
		if (Tag == "")
			continue
		if (BestTag == "" or _Updater_CompareVersions(Tag, BestTag) > 0) {
			BestTag := Tag
			BestChunk := Chunk
		}
	}
	if (BestChunk != "")
		return BestChunk
	if (Chunks.Length > 0)
		return Chunks[1]
	return Json
}

; Returns the GitHub Releases LIST API URL for the channel. The page size is
; intentionally generous so the changelog window can show several months of
; history without paging — even on a busy dev channel that lands one release
; per commit. GitHub's free-tier limit (60 anon req/hour) leaves us plenty of
; headroom because the call is user-initiated only.
Updater_ReleasesListApiUrl(Channel := "") {
	global UPDATER_GH_OWNER, UPDATER_GH_REPO
	return "https://api.github.com/repos/" . UPDATER_GH_OWNER . "/" . UPDATER_GH_REPO . "/releases?per_page=50"
}

; Fetches the releases LIST endpoint (synchronous, like ``Updater_FetchLatestJson``)
; and returns the raw JSON array string. Returns "" on any error.
Updater_FetchReleasesListJson(Channel := "") {
	global UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS
	global UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS
	Url := Updater_ReleasesListApiUrl(Channel)
	Json := ""
	try {
		Req := ComObject("WinHttp.WinHttpRequest.5.1")
		Req.Open("GET", Url, false)
		Req.SetRequestHeader("Accept", "application/vnd.github+json")
		Req.SetRequestHeader("User-Agent", "ErgoptiPlus-Updater/1.0")
		; Always-finite timeouts — a 0 in any slot means "infinite" to WinHttp
		; and would let a stalled DNS resolve block the UI thread until the
		; network recovers. See the constants at the top of this file.
		Req.SetTimeouts(UPDATER_HTTP_RESOLVE_TIMEOUT_MS, UPDATER_HTTP_CONNECT_TIMEOUT_MS,
			UPDATER_HTTP_SEND_TIMEOUT_MS, UPDATER_HTTP_RECEIVE_TIMEOUT_MS)
		Req.Send()
		if (Req.Status == 200) {
			Json := Req.ResponseText
		} else {
			LoggerWarn("Updater", "Releases list HTTP {1} for '{2}'.", Req.Status, Url)
		}
	} catch as Err {
		LoggerWarn("Updater", "Releases list HTTP request failed: {1}.", Err.Message)
	}
	return Json
}

; Splits the top-level JSON array of releases into one substring per object,
; honouring quoted strings and escape sequences so a "}" inside a release body
; cannot fool the depth counter. Returns an Array of object-JSON strings.
_Updater_SplitReleasesArray(Json) {
	out := []
	Trimmed := LTrim(Json)
	if (SubStr(Trimmed, 1, 1) != "[")
		return out
	len := StrLen(Trimmed)
	pos := 2
	depth := 0
	start := 0
	in_str := false
	esc := false
	while (pos <= len) {
		c := SubStr(Trimmed, pos, 1)
		if in_str {
			if esc {
				esc := false
			} else if (c == "\") {
				esc := true
			} else if (c == '"') {
				in_str := false
			}
		} else {
			if (c == '"') {
				in_str := true
			} else if (c == "{") {
				if (depth == 0)
					start := pos
				depth += 1
			} else if (c == "}") {
				depth -= 1
				if (depth == 0 and start > 0) {
					out.Push(SubStr(Trimmed, start, pos - start + 1))
					start := 0
				}
			}
		}
		pos += 1
	}
	return out
}

; Extracts the boolean "prerelease" flag — true means a dev-channel release,
; false a stable one. Defaults to false when the field is absent.
_Updater_ParsePrerelease(Json) {
	if RegExMatch(Json, '"prerelease"\s*:\s*(true|false)', &M)
		return M[1] == "true"
	return false
}

; Extracts the "html_url" field from a single-release JSON object.
_Updater_ParseHtmlUrl(Json) {
	if RegExMatch(Json, '"html_url"\s*:\s*"([^"]+)"', &M)
		return M[1]
	return ""
}

; Extracts the "published_at" ISO-8601 timestamp from a release object.
_Updater_ParsePublishedAt(Json) {
	if RegExMatch(Json, '"published_at"\s*:\s*"([^"]+)"', &M)
		return M[1]
	return ""
}

; Build an array of release records from the raw JSON list. When ``MainOnly``
; is true the list is restricted to stable releases (``prerelease == false``);
; otherwise both pre-releases and stables come through so the dev channel can
; show every nightly side by side with the latest stable.
;
; Each entry: { Tag, Body, HtmlUrl, PublishedAt, Prerelease, RawJson }. The original
; API order is preserved (GitHub returns most-recent first) so callers do not
; need to sort. RawJson carries the per-release JSON chunk so changelog-list install
; can resolve the authenticated asset via _Updater_FindAsset (AHK-07).
Updater_ParseReleasesList(Json, MainOnly := false) {
	out := []
	for _, chunk in _Updater_SplitReleasesArray(Json) {
		rec := {
			Tag:         Updater_ParseTagName(chunk),
			Body:        Updater_ParseBody(chunk),
			HtmlUrl:     _Updater_ParseHtmlUrl(chunk),
			PublishedAt: _Updater_ParsePublishedAt(chunk),
			Prerelease:  _Updater_ParsePrerelease(chunk),
			RawJson:     chunk
		}
		if (rec.Tag == "")
			continue
		if (MainOnly and rec.Prerelease)
			continue
		out.Push(rec)
	}
	return out
}

; Extracts the "tag_name" field from a GitHub release JSON payload.
; Handles both object (latest endpoint) and array (list endpoint) responses.
Updater_ParseTagName(Json) {
	if _Updater_JsonPayloadIsFailure(Json)
		return ""
	; Unwrap array if callers pass raw list JSON (defensive — normally already
	; unwrapped by Updater_FetchLatestJson or Updater_ParseReleasesList).
	if (SubStr(LTrim(Json), 1, 1) == "[")
		Json := RegExReplace(Json, "^\s*\[", "")
	if RegExMatch(Json, '"tag_name"\s*:\s*"([^"]+)"', &M)
		return M[1]
	return ""
}

; Extracts the "body" field (release notes markdown) from a GitHub release JSON.
; Returns "" when the field is absent, null, or an empty string — callers
; display t("updater.changelog_empty") in that case.
Updater_ParseBody(Json) {
	if _Updater_JsonPayloadIsFailure(Json)
		return ""
	; Unwrap array defensively — normally already done by Updater_FetchLatestJson.
	if (SubStr(LTrim(Json), 1, 1) == "[")
		Json := RegExReplace(Json, "^\s*\[", "")
	; GitHub sets "body": null (not "") when a release has no description.
	; Detect null before trying the quoted-string pattern.
	if RegExMatch(Json, '"body"\s*:\s*null', &_)
		return ""
	; Possessive quantifier (*+) prevents catastrophic backtracking on large bodies.
	if RegExMatch(Json, '"body"\s*:\s*"((?:[^"\\]++|\\.)*+)"', &M) {
		try return JsonStringDecodeContents(M[1])
		catch as Err {
			try LoggerWarn("Updater", "Release body JSON decode failed: {1}.", Err.Message)
			return ""
		}
	}
	return ""
}
