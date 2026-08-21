; ui/menu/menu_rebuild.ahk

; ==============================================================================
; MODULE: Tray Menu / Live Rebuild & Logging
; DESCRIPTION:
; Live hotstrings rebuild, full tray-menu rebuild and the log-level submenu (selector, label, emoji) used to change the logger verbosity at runtime.
;
; Split out of ui/tray_menu.ahk (the module split). tray_menu.ahk remains the module
; index: it declares the shared menu globals and #Include-s this file. Every
; function here is hoisted into the global namespace, so load order across the
; menu/*.ahk files is irrelevant.
; ==============================================================================




; A_TrayMenu is a read-only built-in object, so a replacement root cannot be
; swapped in wholesale. Build every child Menu while the current root remains
; usable, then record the small set of root mutations and apply them in one
; Critical section. This prevents both the empty-menu click window and a long
; Critical section around TOML, i18n, and renderer work.
global _TrayMenuStage := false
global _TrayRootRequestedGeneration := 0
global _TrayRootPublishedGeneration := 0
global _TrayRootActive := false
global _TrayRootLifecycleEpoch := 0
global _TrayRootLatestAuthorizeFn := 0
global _TrayRootLatestWorkerFn := 0

; Expected retained work must not look like a fresh crash on every watchdog
; tick. A fatal dynamic-context error is different: retire that exact root
; generation and end the current logical thread so no later registration can
; inherit an unproven HotIf context.
class TrayRootRetryPendingError extends Error {
}

class TrayRootFatalContextError extends Error {
}

_TrayRootErrorIsSilent(Err) {
	return (Err is TrayRootRetryPendingError)
		or (Err is TrayRootFatalContextError)
}

TrayMenuStage_Begin() {
	global _TrayMenuStage
	if IsObject(_TrayMenuStage)
		throw Error("Tray-menu staging is already active")
	_TrayMenuStage := []
	return _TrayMenuStage
}

TrayMenuStage_Add(Label := "", Target := "") {
	global _TrayMenuStage
	if !IsObject(_TrayMenuStage) {
		if (Label == "")
			return A_TrayMenu.Add()
		return A_TrayMenu.Add(Label, Target)
	}
	_TrayMenuStage.Push(Map("kind", "submenu", "label", Label, "target", Target))
}

TrayMenuStage_AddAction(Label, Callback) {
	global _TrayMenuStage
	if !IsObject(_TrayMenuStage)
		return RegisterMenuItem(A_TrayMenu, Label, Callback)
	_TrayMenuStage.Push(Map("kind", "action", "label", Label, "target", Callback))
}

TrayMenuStage_Check(Label) {
	global _TrayMenuStage
	if !IsObject(_TrayMenuStage)
		return A_TrayMenu.Check(Label)
	_TrayMenuStage.Push(Map("kind", "check", "label", Label))
}

TrayMenuStage_Disable(Label) {
	global _TrayMenuStage
	if !IsObject(_TrayMenuStage)
		return A_TrayMenu.Disable(Label)
	_TrayMenuStage.Push(Map("kind", "disable", "label", Label))
}

TrayMenuStage_Abort() {
	global _TrayMenuStage
	_TrayMenuStage := false
}

TrayMenuStage_Publish(AuthorizeFn := 0, ApplyFn := 0) {
	global _TrayMenuStage
	if !IsObject(_TrayMenuStage)
		throw Error("Tray-menu publication requires an active stage")
	Stage := _TrayMenuStage
	_PublishCritical := Critical("On")
	try {
		; The potentially yielding menu build happened before this lock. Revalidate
		; its lifecycle/generation ticket at the irreversible root-swap boundary so
		; a pause or a newer request cannot publish a stale dispatcher tree.
		if HasMethod(AuthorizeFn, "Call") {
			Authorized := AuthorizeFn.Call()
			if !((Authorized is Integer) and Authorized == 1) {
				_TrayMenuStage := false
				return false
			}
		}
		if HasMethod(ApplyFn, "Call") {
			Applied := ApplyFn.Call(Stage)
			if !((Applied is Integer) and Applied == 1)
				throw Error("Tray-menu publication adapter refused the staged tree")
			_TrayMenuStage := false
			return true
		}
		; Invalidate retries for the retired tree, but retain dispatcher entries
		; for detached child menus that were registered during staging.
		MenuDispatcher_BeginReplacement()
		A_TrayMenu.Delete()
		for _, Entry in Stage {
			switch Entry["kind"] {
				case "submenu":
					if (Entry["label"] == "")
						A_TrayMenu.Add()
					else
						A_TrayMenu.Add(Entry["label"], Entry["target"])
				case "action":
					RegisterMenuItem(A_TrayMenu, Entry["label"], Entry["target"])
				case "check":
					A_TrayMenu.Check(Entry["label"])
				case "disable":
					A_TrayMenu.Disable(Entry["label"])
			}
		}
		; The new subtrees are now reachable from the tray. One whole-tree walk
		; drops only registrations left behind by the retired generation.
		MenuDispatcher_PruneMenu(A_TrayMenu)
		return true
	} finally {
		_TrayMenuStage := false
		Critical(_PublishCritical)
	}
}

_TrayRootRequestAndTryAcquire(AuthorizeFn := 0, WorkerFn := 0,
		&RequestedGeneration := 0) {
	global _TrayRootRequestedGeneration, _TrayRootActive
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	PreviousCritical := Critical("On")
	try {
		_TrayRootRequestedGeneration += 1
		RequestedGeneration := _TrayRootRequestedGeneration
		_TrayRootLatestAuthorizeFn := AuthorizeFn
		_TrayRootLatestWorkerFn := WorkerFn
		if _TrayRootActive
			return false
		_TrayRootActive := true
		return true
	} finally Critical(PreviousCritical)
}

_TrayRootAcquireRetained(&TargetGeneration, &AuthorizeFn, &WorkerFn) {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive, _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	PreviousCritical := Critical("On")
	try {
		if _TrayRootActive
			return false
		if _TrayRootRequestedGeneration <= _TrayRootPublishedGeneration
			return false
		_TrayRootActive := true
		TargetGeneration := _TrayRootRequestedGeneration
		AuthorizeFn := _TrayRootLatestAuthorizeFn
		WorkerFn := _TrayRootLatestWorkerFn
		return true
	} finally Critical(PreviousCritical)
}

_TrayRootClaimLatest(&TargetGeneration, &AuthorizeFn, &WorkerFn,
		&LifecycleEpoch) {
	global _TrayRootRequestedGeneration, _TrayRootLifecycleEpoch
	global _TrayRootLatestAuthorizeFn, _TrayRootLatestWorkerFn
	PreviousCritical := Critical("On")
	try {
		TargetGeneration := _TrayRootRequestedGeneration
		AuthorizeFn := _TrayRootLatestAuthorizeFn
		WorkerFn := _TrayRootLatestWorkerFn
		LifecycleEpoch := _TrayRootLifecycleEpoch
		return true
	} finally Critical(PreviousCritical)
}

_TrayRootPublishAuthorized(TargetGeneration, LifecycleEpoch,
		UpstreamAuthorizeFn := 0) {
	global _TrayRootRequestedGeneration, _TrayRootLifecycleEpoch
	if A_IsSuspended
		return false
	if TargetGeneration != _TrayRootRequestedGeneration
		or LifecycleEpoch != _TrayRootLifecycleEpoch
		return false
	if HasMethod(UpstreamAuthorizeFn, "Call") {
		try Authorized := UpstreamAuthorizeFn.Call()
		catch
			return false
		return (Authorized is Integer) and Authorized == 1
	}
	return true
}

_TrayRootRelease(PublishedGeneration := 0) {
	global _TrayRootRequestedGeneration, _TrayRootPublishedGeneration
	global _TrayRootActive
	PreviousCritical := Critical("On")
	try {
		if PublishedGeneration > 0
			_TrayRootPublishedGeneration := Max(
				_TrayRootPublishedGeneration, PublishedGeneration)
		if _TrayRootPublishedGeneration < _TrayRootRequestedGeneration
			return false
		_TrayRootActive := false
		return true
	} finally Critical(PreviousCritical)
}

_TrayRootTryReleaseFailed(TargetGeneration) {
	global _TrayRootRequestedGeneration, _TrayRootActive
	PreviousCritical := Critical("On")
	try {
		; A request accepted while the failed builder yielded already believes
		; this owner will consume it. Keep ownership when that generation exists;
		; otherwise release atomically so a later requester can acquire itself.
		if _TrayRootRequestedGeneration > TargetGeneration
			return false
		_TrayRootActive := false
		return true
	} finally Critical(PreviousCritical)
}

_TrayRootRetireFatal(TargetGeneration) {
	global _TrayRootPublishedGeneration, _TrayRootActive
	PreviousCritical := Critical("On")
	try {
		_TrayRootPublishedGeneration := Max(
			_TrayRootPublishedGeneration, TargetGeneration)
		_TrayRootActive := false
		return true
	} finally Critical(PreviousCritical)
}

_TrayRootBuildOnce(PublishAuthorizeFn, WorkerFn := 0) {
	if HasMethod(WorkerFn, "Call")
		return WorkerFn.Call(PublishAuthorizeFn)
	_HS_InvalidatePersonalCache()
	InitSubMenus()
	return initMenu(PublishAuthorizeFn)
}

_TrayRootDrain() {
	loop {
		_TrayRootClaimLatest(&TargetGeneration, &UpstreamAuthorizeFn,
			&WorkerFn, &LifecycleEpoch)
		PublishAuthorizeFn := _TrayRootPublishAuthorized.Bind(
			TargetGeneration, LifecycleEpoch, UpstreamAuthorizeFn)
		try Published := _TrayRootBuildOnce(PublishAuthorizeFn, WorkerFn)
		catch as Err {
			if (Err is TrayRootFatalContextError) {
				_TrayRootRetireFatal(TargetGeneration)
				throw Err
			}
			if !_TrayRootTryReleaseFailed(TargetGeneration)
				continue
			if (Err is TrayRootRetryPendingError)
				throw Err
			try LoggerError("Menu", "Tray-root reconstruction failed and remains pending: {1}", Err.Message)
			return false
		}
		if !((Published is Integer) and Published == 1) {
			; A newer request invalidated this detached stage: keep the same owner
			; and immediately build the latest candidate. Suspend/upstream refusal
			; has no newer generation, so release for its lifecycle-specific owner.
			if !_TrayRootTryReleaseFailed(TargetGeneration)
				continue
			return false
		}
		if _TrayRootRelease(TargetGeneration)
			return true
	}
}

_TrayRootServiceRetained() {
	global _TrayRootLatestAuthorizeFn
	; A caller-specific ticket (HSLR/updater) must be refreshed by that caller;
	; replaying it here would spin forever on a deliberately stale generation.
	if HasMethod(_TrayRootLatestAuthorizeFn, "Call")
		return false
	if !_TrayRootAcquireRetained(&TargetGeneration, &AuthorizeFn, &WorkerFn)
		return true
	return _TrayRootDrain()
}

_TrayRootServiceRetainedWork(RootFn := 0, NextFn := 0, LogFn := 0) {
	if HasMethod(RootFn, "Call") {
		try RootFn.Call()
		catch as Err {
			; A failed HotIf reset can leave this logical thread's dynamic
			; registration context selected. Retire the root and end this
			; watchdog pass before any other native hotkey mutation runs.
			if Err is TrayRootFatalContextError
				return false
		}
	}
	if HasMethod(NextFn, "Call") {
		try NextFn.Call()
		catch as Err {
			if HasMethod(LogFn, "Call") {
				try LogFn.Call(Err)
			} else {
				try LoggerError("Lifecycle",
					"LLM trigger recovery watchdog service failed: {1}.",
					Err.Message)
			}
		}
	}
	return true
}

_TrayRootOnSuspendEnter() {
	global _TrayRootLifecycleEpoch
	PreviousCritical := Critical("On")
	try _TrayRootLifecycleEpoch += 1
	finally Critical(PreviousCritical)
	return true
}

; Re-run the hotstring registration in-process so a section toggle takes effect
; immediately, with no script Reload. Clears the HSE engine and its buffer, then
; re-runs RegisterAllHotstrings(): it re-evaluates every Features guard and
; recomputes SpaceAroundSymbols. The Ê deadkey and "…" ellipsis are now HSE
; raw-callback hotstrings (no native Hotstring()), so they are cleared and
; re-registered here like every other section; they stay reload-only in the
; blocklist, so toggling one of them DIRECTLY still reloads (see
; hotstring_live_toggle.ahk). Finally rebuilds the preview index and tray.
global _HSLR_RequestedGeneration := 0
global _HSLR_PublishedGeneration := 0
global _HSLR_Active := false

; Request one publication and atomically acquire its long-running owner when no
; earlier pseudo-thread has it. Critical covers three scalar writes only; it is
; restored before any registry, filesystem, index, or tray work begins.
_HSLR_RequestAndTryAcquire() {
	global _HSLR_RequestedGeneration, _HSLR_Active, HSE_RebuildInProgress
	PreviousCritical := Critical("On")
	try {
		_HSLR_RequestedGeneration += 1
		if _HSLR_Active
			return false
		_HSLR_Active := true
		HSE_RebuildInProgress := true
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; Snapshot all work known at the start of one pass. Publication uses the same
; short state lock, but the expensive registry rebuild between them never does.
_HSLR_ClaimNext(&TargetGeneration) {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration
	PreviousCritical := Critical("On")
	try {
		TargetGeneration := _HSLR_RequestedGeneration
		return TargetGeneration > _HSLR_PublishedGeneration
	} finally {
		Critical(PreviousCritical)
	}
}

_HSLR_PublishGeneration(TargetGeneration) {
	global _HSLR_PublishedGeneration
	PreviousCritical := Critical("On")
	try {
		_HSLR_PublishedGeneration := Max(
			_HSLR_PublishedGeneration, TargetGeneration)
	} finally {
		Critical(PreviousCritical)
	}
}

_HSLR_IsDrained() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration
	PreviousCritical := Critical("On")
	try return _HSLR_PublishedGeneration >= _HSLR_RequestedGeneration
	finally {
		Critical(PreviousCritical)
	}
}

; Release only if a second check inside the state lock still sees no work. A
; request delivered after the optimistic _HSLR_IsDrained check increments the
; generation while the owner remains active, so this refuses release and the
; existing owner performs another pass instead of losing the wake-up.
_HSLR_TryReleaseIfDrained() {
	global _HSLR_RequestedGeneration, _HSLR_PublishedGeneration, _HSLR_Active
	global HSE_RebuildInProgress
	PreviousCritical := Critical("On")
	try {
		if (_HSLR_PublishedGeneration < _HSLR_RequestedGeneration)
			return false
		_HSLR_Active := false
		HSE_RebuildInProgress := false
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; A coordinator invariant failure has no trustworthy generation to hand off.
; Release its owner and matcher fence together before surfacing the failure.
_HSLR_ReleaseAfterInvariantFailure() {
	global _HSLR_Active, HSE_RebuildInProgress
	PreviousCritical := Critical("On")
	try {
		_HSLR_Active := false
		HSE_RebuildInProgress := false
	} finally {
		Critical(PreviousCritical)
	}
}

; A failed registry pass never publishes its target. If another pseudo-thread
; requested a newer generation while the failed pass yielded, keep the current
; owner and fence so that accepted request receives its own bounded retry pass.
; Otherwise release atomically and let the caller surface the terminal failure.
_HSLR_TryReleaseFailedGeneration(TargetGeneration) {
	global _HSLR_RequestedGeneration, _HSLR_Active, HSE_RebuildInProgress
	PreviousCritical := Critical("On")
	try {
		if (_HSLR_RequestedGeneration > TargetGeneration)
			return false
		_HSLR_Active := false
		HSE_RebuildInProgress := false
		return true
	} finally {
		Critical(PreviousCritical)
	}
}

; Serialize live rebuild requests across AHK pseudo-threads. Registration does
; file I/O and deliberately yields for ~1.3 s, so a tray callback can interrupt
; an editor-triggered rebuild. Entering the old body recursively let the inner
; finally lower HSE_RebuildInProgress while the outer registry was still torn.
; A request that arrives during an active pass is acknowledged immediately but
; consumed only after the current owner finishes; one following pass snapshots
; every generation accumulated while it yielded.
RebuildHotstringsLive(RebuildOnceFn := 0, BeforeIdleReleaseFn := 0,
	AfterIdleReleaseFn := 0) {
	if !_HSLR_RequestAndTryAcquire()
		return true
	return _HSLR_DrainOwner(
		RebuildOnceFn, BeforeIdleReleaseFn, AfterIdleReleaseFn)
}

_HSLR_DrainOwner(RebuildOnceFn := 0, BeforeIdleReleaseFn := 0,
	AfterIdleReleaseFn := 0) {
	TargetGeneration := 0
	loop {
		if !_HSLR_ClaimNext(&TargetGeneration) {
			_HSLR_ReleaseAfterInvariantFailure()
			throw Error("Live-rebuild owner has no pending generation")
		}

		try Result := HasMethod(RebuildOnceFn, "Call")
			? RebuildOnceFn.Call() : _RebuildHotstringsLiveOnce()
		catch as Err {
			if !_HSLR_TryReleaseFailedGeneration(TargetGeneration)
				continue
			throw Err
		}
		if !((Result is Integer) && Result == 1) {
			if !_HSLR_TryReleaseFailedGeneration(TargetGeneration)
				continue
			return false
		}
		_HSLR_PublishGeneration(TargetGeneration)
		if _HSLR_IsDrained() {
			; The test seam runs after the optimistic drain observation and
			; before the authoritative release/recheck — the old lost-wakeup
			; window, not merely another point inside the loop.
			if HasMethod(BeforeIdleReleaseFn, "Call") {
				try BeforeIdleReleaseFn.Call()
				catch as Err {
					if !_HSLR_TryReleaseFailedGeneration(TargetGeneration)
						continue
					throw Err
				}
			}
			if _HSLR_TryReleaseIfDrained() {
				; Test-only seam for the stale-cleanup/ABA window after the old
				; owner has released itself. Production never supplies a callback.
				if HasMethod(AfterIdleReleaseFn, "Call")
					AfterIdleReleaseFn.Call()
				return true
			}
		}
	}
}

; One indivisible registry publication pass. Only the coordinator above may
; call this function. The coordinator holds HSE_RebuildInProgress across every
; coalesced pass and lowers it atomically with final owner release.
_RebuildHotstringsLiveOnce() {
	try LoggerStart("Menu", "Rebuilding hotstrings in-process (live toggle)…")
	try {
		try SetTimer(RegisterEmojisSymbolsDeferred, 0)
		; HSE_RebuildInProgress is the fence: HSE_FindMatchAtEnd returns no match while
		; it is set, so an InputHook OnChar can never observe the empty or
		; partially-populated registry — keystrokes simply pass through unexpanded for
		; the duration of the rebuild. This is deliberately NOT wrapped in Critical:
		; RegisterAllHotstrings is ~1.3 s of registration PLUS _HS_RegisterPersonal's
		; directory enumeration and TOML reads, and holding Critical across all of that
		; froze the keyboard for 1-2 s on every tray hotstring toggle (worse on
		; cloud-synced dirs). The per-mutation Criticals inside
		; HSE_Register/HSE_DisableGroup/HSE_EnableGroup still prevent torn reads.
		HSE_RegistryClear()
		RegisterAllHotstrings()
		; Reset only after the registry is fully populated; skip when a send
		; burst is in flight (HSE_Suppressed > 0) so we
		; do not clobber a live expansion's buffer state. The registration pass above
		; intentionally stays interruptible for ~1.3 s, so its final buffer reset must
		; use the short paired transaction: an OnChar queued between two raw reset
		; calls otherwise entered HSE_Buffer and was then erased only from the preview.
		if HSE_Suppressed == 0 {
			_PrefixInvalidateInputContext(0, false)
		}
		if IsSet(HotstringPrefixWatcherRebuildIndex) {
			HotstringPrefixWatcherRebuildIndex()
		}
		RebuildTrayMenu()
		try LoggerSuccess("Menu", "Hotstrings rebuilt in-process.")
		return true
	} catch as e {
		try LoggerError("Menu", "Hotstring live rebuild failed: {1}", e.Message)
		throw e
	}
}

; Reconstructs the tray menu in place without a full process restart.
; Suitable for lightweight UI-only toggles (WPM display, color themes) that
; do not require re-parsing config or rebinding hotkeys. State-changing
; hotstring section toggles rebuild in-process via RebuildHotstringsLive; other
; state-changing toggles (layout, tap-holds, shortcuts) still call Reload().
RebuildTrayMenu(PublishAuthorizeFn := 0, WorkerFn := 0,
		QueuedOutcome := true) {
	; Every root reconstruction—tray click, editor projection, updater, HSLR—uses
	; one generation owner. A request delivered while an older detached tree is
	; building only invalidates that tree; it never enters TrayMenuStage_Begin
	; recursively or throws out of the user callback.
	Acquired := _TrayRootRequestAndTryAcquire(
		PublishAuthorizeFn, WorkerFn, &RequestedGeneration)
	if !Acquired
		return QueuedOutcome
	return _TrayRootDrain()
}

; Sets the active log level without a restart. Disk and the cached hot-path
; flags are one transaction: a terminal config transition or failed writer must
; leave both the level and its menu projection unchanged.
LoggerSetLevel(Level, WriterFn := 0, NotifyFn := 0, RebuildFn := 0) {
	global LOGGER_SEVERITY, ConfigurationFile
	InheritedCritical := A_IsCritical
	if InheritedCritical {
		Critical("Off")
		try return LoggerSetLevel(Level, WriterFn, NotifyFn, RebuildFn)
		finally Critical(InheritedCritical)
	}
	if !LOGGER_SEVERITY.Has(Level) {
		try LoggerWarn("Menu", "LoggerSetLevel: unknown level '{1}' — ignoring.", Level)
		return false
	}
	Updates := [{ Section: "script", Key: "log_level", Value: Level }]
	Persisted := ConfigCommitUpdates(ConfigurationFile, Updates,
		"the runtime log level", WriterFn, NotifyFn,
		_LoggerSetLevelPublish.Bind(Level))
	if !Persisted {
		try LoggerError("Menu", "Log level {1} was refused because config.toml could not accept the transaction; the live level was left unchanged.", Level)
		return false
	}
	try LoggerInfo("Menu", "Log level set to {1}.", Level)
	if HasMethod(RebuildFn, "Call")
		RebuildFn.Call()
	else
		RebuildTrayMenu()
	return true
}

_LoggerSetLevelPublish(Level) {
	global LOGGER_MIN_LEVEL
	LOGGER_MIN_LEVEL := Level
	_LoggerRefreshFastFlags()
}

; Returns the label shown for the log-level submenu entry, including the
; active level so the user can see the current setting without opening the submenu.
_LogLevelMenuLabel() {
	global LOGGER_MIN_LEVEL
	return t("menu.debug.log_level") . " : " . _LogLevelEmoji(LOGGER_MIN_LEVEL) . " " . LOGGER_MIN_LEVEL
}

; The log-level choices, as row DATA: one row per severity level
; (DEBUG / INFO / WARNING / ERROR), the currently active one ticked.
_MI_LogLevelChoiceRows() {
	global LOGGER_MIN_LEVEL
	Rows := []
	for _, Level in ["DEBUG", "INFO", "WARNING", "ERROR"] {
		Rows.Push(Map(
			"label",   _LogLevelEmoji(Level) . " " . Level,
			"checked", (LOGGER_MIN_LEVEL == Level),
			"action",  ((_l) => (*) => LoggerSetLevel(_l))(Level)))
	}
	return Rows
}

_LogLevelEmoji(Level) {
	switch Level {
		case "DEBUG":   return "🐛"
		case "INFO":    return "ℹ️"
		case "WARNING": return "⚠️"
		case "ERROR":   return "❌"
		default:        return "📝"
	}
}
