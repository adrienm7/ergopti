; infra/lifecycle.ahk

; ==============================================================================
; MODULE: Driver Lifecycle, Tray & Debug Actions
; DESCRIPTION:
; Suspend/resume (ToggleSuspend, Ergopti_OnSuspendEnter/Resume, the suspend-state
; watchdog and prefix drain), shutdown (Ergopti_OnShutdown), the deferred tray
; menu build + icon update, and the debug/control actions (reload, exit, WindowSpy,
; ListVars, KeyHistory, healthcheck, edit). Extracted verbatim from ErgoptiPlus.ahk
; (the entry-point decomposition) and #Include'd in place; functions are hoisted so
; their OnExit/SetTimer/hotkey call sites in the entry boot section are unaffected.
; ==============================================================================

#Include suspend_handoff.ahk
#Include reload_terminal_handoff.ahk
#Include reload_successor.ahk
#Include reload_deferral.ahk
#Include lifecycle_transition.ahk

ActivateEdit(*) {
		Edit()
}
; Physical keys registered as an AHK custom-combination PREFIX (the left side of
; a "&" hotkey definition, e.g. "SC138 & SC01C::" in script_altgr_hotkeys.ahk).
; AHK's custom-combination prefix-down flag latches across Suspend() and cannot be cleared by
; synthetic events -- see _SuspendPrefixesAreClear / _SuspendPendingPoll below.
; Single source of truth: EVERY key used as the prefix of an "X & Y" custom
; combination anywhere in the driver must appear here, so it is drained
; automatically before every future suspend instead of leaving an un-drained
; sibling for the same latch bug to hide in (feedback_ahk_suspend_prefix_latch,
; F42, F-30). The list is hand-maintained, so
; test_suspend_prefix_drain_covers_all_combos.ahk DERIVES the real prefix set
; from driver source and fails when a newly introduced combination is missing.
; LAlt left the list with "SC038 & SC03A::": the key combinations are plain
; hotkeys of their second key now (platform/remap/key_combination_keys.ahk).
;   SC138 = AltGr/Kana   SC01D = LCtrl   SC02A = LShift   SC11D = RCtrl
global SUSPEND_CUSTOM_COMBO_PREFIX_KEYS := ["SC138", "SC01D", "SC02A", "SC11D"]
global _SuspendPending := false

; Wall-clock bound on the deferred suspend. The gate waits for a physically
; held prefix key to lift, so a key that is stuck — or one the OS still reports
; as down after a Reload — deferred the suspend FOREVER: the poll simply
; returned every 25 ms and never gave up. Pausing is the user's escape hatch
; from a misbehaving driver, so a gate that can silently swallow it is worse
; than the latched prefix it exists to prevent. Widening the list from 2 to 5
; keys made that state five times easier to reach.
global SUSPEND_DEFER_TIMEOUT_MS := 2000
global _SuspendPendingSince := 0

; Watchdog state is initialized by this include, but the timer starts only after
; every boot subsystem reaches its ready boundary. Starting from boot.ahk let an
; onboarding message pump consume the marker before these globals existed;
; starting here would still let the reactor tear down subsystems whose later
; auto-execute initialization had not finished.
global SUSPEND_WATCHDOG_MS := 500
global _LastSuspendState := A_IsSuspended
global _SuspendWatchdogStarted := false

; Ergopti_OnShutdown holds thirteen independent gates, and every one of them
; vetoes the exit by returning 1 with no attempt bound. That is correct exactly
; once: a gate that can never be satisfied turns "quit" into a process the user
; cannot close, which is what happened on 2026-09-05 when a wedged profile
; receipt refused six consecutive exits and only a kill ended the driver.
;
; A refused OnExit call cannot be confused with a successful one, because a
; successful call ends the process. So counting entries counts refusals, and the
; budget below is a hard ceiling on "closed but still running"
; (lifecycle-shutdown-veto-unbounded).
global LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS := 5
global _LifecycleShutdownVetoAttempts := 0
; Reason of the OnExit call in progress. A veto of a "Reload" close request
; refuses the pending reload whose successor sent it.
global _LifecycleShutdownReason := ""
; Exact private AI attempt owned by this noninterruptible OnExit call.
global _LifecycleAiShutdownAttempt := 0

; Drains every registered custom-combination prefix key (see
; SUSPEND_CUSTOM_COMBO_PREFIX_KEYS) BEFORE a suspend flips. AHK prefix flags
; latch across Suspend and cannot be cleared by synthetic events — they must be
; prevented at the source by waiting (briefly) for the physical key to lift
; before suspending. Factored out of ToggleSuspend so EVERY code path that can
; trigger a suspend can call the same drain, and so a future native/external
; suspend hotkey cannot silently reintroduce the « AltGr/LAlt bloqué »
; regression by bypassing the wait. Safe no-op when entering from suspended
; state or when no prefix key is physically held. SC138 is waited for on every
; layout: the always-eligible ~SC138 anchor in platform/remap/altgr.ahk arms it
; on every AltGr press, not only on Kana-style layouts.
_SuspendPrefixesAreClear() {
		if A_IsSuspended
				return
		for PrefixKey in SUSPEND_CUSTOM_COMBO_PREFIX_KEYS {
				if GetKeyState(PrefixKey, "P")
						return false
		}
		return true
}
; Releases every modifier + the SC138 (AltGr/Kana) prefix key to clear any
; OS-level phantom "down" state carried across a Reload. A Reload — the driver's
; standard apply-settings path, also fired by the layout-change watcher — can
; land while AltGr (or any modifier) is physically held; the OS then keeps that
; key latched down for the fresh process, which reads it via GetKeyState and
; sticks on the AltGr layer until the user cycles the key (the transient
; « AltGr bloqué » report). Synthetic key-ups for keys that are genuinely up are
; harmless no-ops, and {Blind} stops AHK injecting its own modifier state. NOTE:
; this targets the OS phantom-modifier case ONLY — it does NOT clear AHK's
; internal custom-combination prefix latch (that is prevented at the source by
; the _SuspendPrefixesAreClear / _SuspendPendingPoll gate before a Suspend, the one
; transition that freezes it).
_ReleasePhantomModifiers() {
		Send("{Blind}{LCtrl up}{RCtrl up}{LAlt up}{RAlt up}{LShift up}{RShift up}{LWin up}{RWin up}{SC138 up}")
}
; Names the prefix keys currently holding the gate shut, for the timeout report.
; Without this a wedged deferral says only "still waiting" — the user has no way
; to know WHICH key to cycle, which is the one thing that would fix it.
_SuspendHeldPrefixKeys() {
		Held := ""
		for PrefixKey in SUSPEND_CUSTOM_COMBO_PREFIX_KEYS {
				if GetKeyState(PrefixKey, "P")
						Held .= (Held == "" ? "" : ", ") . PrefixKey
		}
		return Held == "" ? "(none)" : Held
}

; Absolute path of the suspend hand-off marker, derived from the locator whose
; own location stays stable while config.toml is redirected.
_SuspendMarkerPath() {
		global _PathsFile, SUSPEND_MARKER_FILENAME
		if !IsSet(_PathsFile) or (_PathsFile == "")
				return ""
		return SuspendHandoffMarkerPath(_PathsFile, SUSPEND_MARKER_FILENAME)
}

; Reloads the driver WITHOUT discarding the user's pause.
;
; AHK's Reload starts a fresh process that is never suspended, and the tray menu
; is the one surface that stays fully clickable while paused — native Suspend
; only disarms hotkeys and hotstrings, never a tray WM_COMMAND. So every menu
; action that persists a setting and reloads used to come back fully armed, with
; the « Suspendre » checkmark gone and nothing whatsoever in the logs. Persist
; the state first, then reload; _SuspendRestoreFromMarker atomically claims and
; consumes it before re-applying the pause on the next boot. A marker that
; cannot be written or consumed is reported as an ERROR rather than swallowed:
; silently resuming a driver the user paused is exactly the failure this exists
; to remove.
;
; The successor starts at once but this instance only exits later, when the
; successor asks it to close (see infra/reload_terminal_handoff.ahk). So 1 means
; "reload under way", never "reload finished": SuccessFn runs from OnExit, and
; RefusedFn(Reason) runs if the reload is refused after launch. A caller that
; lends ExistingBundle hands it to the pending reload on 1 and must neither
; release nor roll it back; RefusedFn gives it back and must release or retain
; it exactly as the caller's own synchronous refusal branch does. On 0 no
; successor was launched and the caller still owns the bundle.
;
; A stage that refuses before launch is reported through StageFailureFn(Stage,
; Path); by default _SuspendHandoffFailure, which also shows a "save failed"
; notice. The layout poll, which no user asked for, passes a quieter one.
ReloadPreservingSuspend(SuccessFn := 0, ExistingBundle := 0, RefusedFn := 0,
		StageFailureFn := 0) {
	; Twenty-five call sites reload through here and none said why. The caller's
	; name is read from the call stack (-2 = whoever called this function), so the
	; log answers "who asked" without threading a reason through every caller.
	try LoggerInfo("Lifecycle", "Reload requested by {1} (suspended={2}).",
		DiagCallerName(-2), A_IsSuspended ? "true" : "false")
	PreviousCritical := Critical("Off")
	try return _ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle,
		RefusedFn, StageFailureFn)
	finally Critical(PreviousCritical)
}


_ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle, RefusedFn,
		StageFailureFn) {
	global ConfigurationFile
	if IsSet(ProgramActions_Stop) {
		ProgramStopped := false
		try ProgramStopped := ProgramActions_Stop(A_IsSuspended)
		catch as Err
			try LoggerError("Lifecycle", "User-program reload preflight failed: {1}.", Err.Message)
		if !((ProgramStopped is Integer) && ProgramStopped == 1)
			return false
	}
	if (ExistingBundle is Object) && !HasMethod(RefusedFn, "Call")
		throw TypeError("A reload that borrows a configuration bundle needs a refusal callback to take it back.")
	ReportStage := HasMethod(StageFailureFn, "Call") ? StageFailureFn : _SuspendHandoffFailure
	Pending := ReloadTerminalHandoffPending()
	if (Pending is Map) {
		; The successor already launched will restart this instance on whatever
		; is on disk. A plain request joins it; one with its own completion or
		; refusal duties cannot be attached to a record it did not create.
		if HasMethod(SuccessFn, "Call") || HasMethod(RefusedFn, "Call") {
			try LoggerError("Lifecycle", "Reload refused because successor pid {1} is already pending and this request carries its own callbacks.",
				Pending["successor"]["pid"])
			return false
		}
		try LoggerInfo("Lifecycle", "Reload already under way (successor pid {1}); this request joins it.",
			Pending["successor"]["pid"])
		return true
	}
	OwnBundle := false
	OwnerBundle := ExistingBundle
	if !(OwnerBundle is Object) {
		OwnerBundle := ConfigTransitionRetainedBarrier()
		if !(OwnerBundle is Object) {
			OwnerBundle := ConfigWriteAcquireLifecycleBundle()
			OwnBundle := OwnerBundle is Object
		}
	}
	if !(OwnerBundle is Object) {
		; A configuration write is in progress, and this thread interrupted it:
		; a plain request waits for the write to end (infra/reload_deferral.ahk).
		if _ReloadRequestIsPlain(SuccessFn, ExistingBundle, RefusedFn, StageFailureFn)
				&& ReloadDeferralQueue(_ReloadAfterConfigWrite)
			return true
		try LoggerError("Lifecycle", "Reload refused because another configuration transaction owns config.toml.")
		ReportStage.Call("config-lease", ConfigurationFile)
		return false
	}
	ReloadDeferralSettle()
	if !(_ConfigWriteLeaseSelectOwner(OwnerBundle,
			ConfigurationFile) is Object) {
		try LoggerError("Lifecycle", "Reload refused because its borrowed configuration bundle is stale or does not own the active path.")
		ReportStage.Call("config-owner", ConfigurationFile)
		if OwnBundle
			_ConfigWriteTerminalRelease(OwnerBundle)
		return false
	}
	Launched := false
	try {
		Path := A_IsSuspended ? _SuspendMarkerPath() : ""
		; The intent names this reload, so a refusal after the terminal commit
		; retracts the marker it published and never another transition's.
		Intent := A_IsSuspended ? _SuspendHandoffNewIntent() : ""
		ReadyFn := _SuspendHandoffBeforeReload.Bind(Path)
		CommitFn := A_IsSuspended ? _SuspendHandoffCommitMarker.Bind(Path, Intent) : 0
		AbortFn := A_IsSuspended ? _SuspendHandoffCancelMarker.Bind(Path) : 0
		RetractFn := A_IsSuspended ? _SuspendHandoffRetractMarker.Bind(Path, Intent) : 0
		; A bundle this call acquired belongs to the pending reload once the
		; successor launched; a refusal releases it after the caller's callback.
		ReleaseFn := OwnBundle ? _ConfigWriteTerminalRelease.Bind(OwnerBundle) : 0
		ReloadFn := ReloadTerminalInvoke.Bind(OwnerBundle, SuccessFn,
			LifecycleLaunchSuccessor, ReloadSuccessorPort(), CommitFn, AbortFn,
			_ReloadPreservingSuspendRefused.Bind(RefusedFn), ReleaseFn, RetractFn)
		Launched := SuspendHandoffReload(A_IsSuspended, Path,
			(MarkerPath) => _SuspendHandoffPrepareMarker(MarkerPath, Intent), ReloadFn,
				ReadyFn, ReportStage, _SuspendHandoffCancelMarker)
		return Launched
	} finally {
		if OwnBundle && !Launched
			_ConfigWriteTerminalRelease(OwnerBundle)
	}
}

; Whether a reload request carries nothing a later retry could not carry: no
; completion or refusal callback, no borrowed configuration bundle and the
; default stage report. Only such a request is queued behind a write.
_ReloadRequestIsPlain(SuccessFn, ExistingBundle, RefusedFn, StageFailureFn) {
	return !HasMethod(SuccessFn, "Call") && !(ExistingBundle is Object)
		&& !HasMethod(RefusedFn, "Call") && !HasMethod(StageFailureFn, "Call")
}

; The deferred reload's retry, run by its one-shot timer once the interrupted
; writer could resume.
_ReloadAfterConfigWrite(*) {
	PreviousCritical := Critical("Off")
	try _ReloadPreservingSuspendNonCritical(0, 0, 0, 0)
	finally Critical(PreviousCritical)
}

; A launched reload refused later leaves this instance running on its previous
; in-memory settings: the caller repairs its own state and tells the user, or,
; without a refusal callback, the generic notice does (ReloadRefusalDeliver).
_ReloadPreservingSuspendRefused(CallerRefusedFn, Reason) {
	ReloadRefusalDeliver(CallerRefusedFn, Reason)
}

; Starts the replacement instance exactly as AutoHotkey's Reload does: the
; interpreter (or the compiled executable) with /restart, from the initial
; working directory. Reload itself returns nothing, so a successor whose close
; request was refused stayed anonymous and prompted "Could not close the
; previous instance" forever. The owned handle lets the hand-off notice a
; successor that died while loading and stop one whose request was refused.
; @returns {Map} The successor's "pid" and owned process "handle".
LifecycleLaunchSuccessor() {
	LifecycleRetireWorkers()
	Target := A_IsCompiled
		? '"' . A_ScriptFullPath . '" /restart'
		: '"' . A_AhkPath . '" /restart "' . A_ScriptFullPath . '"'
	return ReloadSuccessorLaunch(Target, A_InitialWorkingDir)
}

; Stops the detached workers before a successor launches. A worker that re-runs
; the driver entry (the metrics projection always, the UIA probe when compiled)
; holds the driver's window title while it starts, and /restart closes the
; newest window with that title (reload-worker-identity, see
; KLPF_ReloadKeepsWorkersOut). Workers are disposable and end with this instance
; anyway, and none starts again while the hand-off exists. A worker that could
; not be confirmed stopped is reported and the reload goes on: past its first
; statement it no longer shares the title, and a successor that still closes it
; is caught by the hand-off's liveness probe.
; @returns {Boolean} False when a worker could not be confirmed stopped.
LifecycleRetireWorkers() {
	PrefetchStopped := false
	try PrefetchStopped := KLPF_CancelAll()
	catch as Err
		try LoggerError("Lifecycle", "Metrics projection workers could not be stopped before the reload: {1}.", Err.Message)
	; UIASW_Stop reports false when it owned nothing, which is a stopped worker.
	UiaLive := IsObject(UIASWState.handle)
	UiaStopped := !UiaLive
	try UiaStopped := UIASW_Stop("canceled") || !UiaLive
	catch as Err
		try LoggerError("Lifecycle", "The UIA probe worker could not be stopped before the reload: {1}.", Err.Message)
	if !(PrefetchStopped && UiaStopped)
		try LoggerWarn("Lifecycle", "A detached worker was not confirmed stopped before the reload successor launched (metrics projection stopped={1}, UIA probe stopped={2}).",
			PrefetchStopped ? "true" : "false", UiaStopped ? "true" : "false")
	return PrefetchStopped && UiaStopped
}

; Logs successful publication immediately before Reload. Destructive UI cleanup
; is deliberately NOT called here: OnExit can still refuse. It runs through the
; terminal hand-off only after the last refusal gate has accepted.
_SuspendHandoffBeforeReload(Path) {
		if (Path != "")
				try LoggerInfo("Lifecycle", "Reloading while suspended — inert pause intent prepared for '{1}'.", Path)
}

_SuspendHandoffPrepareMarker(Path, Intent := "1") {
	return SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
		FSAtomicMoveReplace, FSDeleteStrict, Intent)
}

_SuspendHandoffCommitMarker(Path, Intent := "1") {
	return SuspendHandoffCommit(Path, FSRead, FSAtomicMoveReplace, Intent)
}

_SuspendHandoffRetractMarker(Path, Intent) {
	return SuspendHandoffRetract(Path, Intent, FSStrictExists, FSRead, FSDeleteStrict)
}

; Pause intent unique to one reload of this process: the leading "1" is the
; intent, the rest tells this reload's marker from any other.
_SuspendHandoffNewIntent() {
	static Serial := 0
	Serial += 1
	return Format("1 {1}-{2}-{3}", ProcessExist(), A_TickCount, Serial)
}

_SuspendHandoffCancelMarker(Path) {
	return SuspendHandoffAbort(Path, FSStrictExists, FSDeleteStrict)
}

; Surfaces hand-off failures without a modal dialog on the keyboard thread.
_SuspendHandoffFailure(Stage, Path) {
		try LoggerError("Lifecycle", "Suspend hand-off stage '{1}' failed for '{2}'; the state transition was aborted.", Stage, Path)
		try NotifierSend(t("onboarding.error.write_failed"),
				Map("title", t("paths_editor.save_failed_title"), "level", "error"))
}

; Consumes the hand-off marker left by ReloadPreservingSuspend and re-enters
; suspend. Called once, from the first _SuspendStateWatchdog invocation. The
; marker is deleted BEFORE the pause is re-applied, so a failure past this point
; costs one restored pause instead of wedging the driver suspended forever.
;
; Routed through ToggleSuspend rather than a bare Suspend(1) on purpose: that is
; the one path carrying the custom-combination prefix-drain protocol, and a
; Reload can land while a prefix key is still physically held — the very state
; the drain exists for. It also means the reactors and the tray indicator run
; exactly as they do for a manual pause.
_SuspendRestoreFromMarker() {
		Path := _SuspendMarkerPath()
		; Refused or interrupted preparations are inert. Their cleanup result is
		; surfaced, but cannot suppress consumption of separately committed intent.
		SuspendHandoffDiscardPending(Path, FSStrictExists, FSDeleteStrict,
			_SuspendHandoffFailure)
		return SuspendHandoffConsume(Path, A_IsSuspended,
				FSStrictExists, FSMove, FSDeleteStrict, ToggleSuspend,
				_SuspendHandoffBeforeToggle, _SuspendHandoffFailure)
}

_SuspendHandoffBeforeToggle() {
		LoggerInfo("Lifecycle", "Restoring the pause that a menu-driven Reload would otherwise have dropped.")
}

; The native navigation hook is independent of AHK's Suspend command. Refuse
; the transition unless it is quiesced first; if its own suspend operation
; fails, stop/unhook it so a paused driver can never keep consuming digits.
_LifecycleSetNavEventOwnerSuspended(Suspended) {
	if !IsSet(LLM_NavEventOwner_QuiesceForLifecycle)
		return true
	return LLM_NavEventOwner_QuiesceForLifecycle(Suspended)
}

ToggleSuspend(*) {
		global _SuspendPending, _SuspendPendingSince
		; The reactors log the transition itself; this line records who asked,
		; which is what separates a user pause from a restored or scripted one.
		try LoggerInfo("Lifecycle", "Suspend toggle requested by {1} (currently {2}).",
			DiagCallerName(-2), A_IsSuspended ? "suspended" : "active")
		; A second press while a suspend is PENDING must cancel it. Without this
		; branch the press fell through and simply re-armed the deferral, so the
		; control the user reaches for to escape a wedged gate was the one control
		; that could not escape it — and once the key finally lifted they were
		; suspended against their intent, having asked twice to not be.
		if (!A_IsSuspended and _SuspendPending) {
				_SuspendPending := false
				SetTimer(_SuspendPendingPoll, 0)
				LoggerInfo("Lifecycle", "Pending suspend cancelled by a second toggle.")
				return
		}
		if A_IsSuspended {
				_SuspendPending := false
				SetTimer(_SuspendPendingPoll, 0)
				Suspend(0)
				_SuspendStateWatchdog()
				return
		}
		if _SuspendPrefixesAreClear() {
				_SuspendPending := false
				if !_LifecycleSetNavEventOwnerSuspended(true)
					return
				Suspend(1)
				_SuspendStateWatchdog()
				return
		}
		PendingSince := A_TickCount
		HeldPrefixes := _SuspendHeldPrefixKeys()
		; Acquire the completion owner before publishing pending state. A rejected
		; timer must leave the pause action immediately retryable instead of
		; stranding a request that has neither completion nor timeout callbacks.
		SetTimer(_SuspendPendingPoll, 25)
		_SuspendPendingSince := PendingSince
		_SuspendPending := true
		LoggerWarn("Lifecycle", "Suspend deferred until custom-combination prefix keys are released (held: {1}).",
				HeldPrefixes)
}
_SuspendPendingPoll() {
		global _SuspendPending, _SuspendPendingSince
		if !_SuspendPending or A_IsSuspended {
				SetTimer(_SuspendPendingPoll, 0)
				return
		}
		if !_SuspendPrefixesAreClear() {
				; Bounded. Past the deadline, try once to clear an OS-level phantom
				; latch — the common cause after a Reload landed on a held modifier —
				; and if the key is genuinely still down, suspend anyway and say so.
				; A latched prefix on one key is strictly better than a driver the user
				; cannot pause (fail loudly rather than hang silently, conventions 5.3).
				if (((A_TickCount - _SuspendPendingSince) & 0xFFFFFFFF) < SUSPEND_DEFER_TIMEOUT_MS)
						return
				Held := _SuspendHeldPrefixKeys()
				_ReleasePhantomModifiers()
				if !_SuspendPrefixesAreClear() {
						LoggerError("Lifecycle", "Suspend deferral timed out after {1} ms — prefix key(s) still held ({2}); suspending anyway. Cycle that key if a layer stays latched.",
								SUSPEND_DEFER_TIMEOUT_MS, Held)
				} else {
						LoggerWarn("Lifecycle", "Suspend deferral cleared a phantom latch on {1} after {2} ms.",
								Held, SUSPEND_DEFER_TIMEOUT_MS)
				}
		}
		_SuspendPending := false
		SetTimer(_SuspendPendingPoll, 0)
		if !_LifecycleSetNavEventOwnerSuspended(true)
			return
		Suspend(1)
		_SuspendStateWatchdog()
}
Ergopti_OnSuspendEnter() {
	global _SpaceHoldInputHook
	global _MagicKeyEditorInputHook
	Transition := LifecycleTransitionBegin("suspend")
	if IsSet(ProgramActions_Stop)
		_LifecycleRunRequiredStep(Transition, "user-programs", () => ProgramActions_Stop(true), true)
	if IsSet(UserHotstringsInvalidate)
		_LifecycleRunRequiredStep(Transition, "user-hotstrings", UserHotstringsInvalidate.Bind("suspend"), true)
	if !_LifecycleRunRequiredStep(Transition, "navigation-event",
			() => _LifecycleSetNavEventOwnerSuspended(true), true) {
		LifecycleTransitionFinish(Transition)
		_LifecycleLogTransitionDebt(Transition)
		return false
	}
	if IsSet(LLM_AuxInvalidate)
		_LifecycleRunRequiredStep(Transition, "llm-aux-context",
			LLM_AuxInvalidate.Bind("suspend"))
	if IsSet(LLM_Menu_LocalServersOnSuspend)
		_LifecycleRunRequiredStep(Transition, "llm-local-servers",
			LLM_Menu_LocalServersOnSuspend, true)
	if IsSet(KL_Watchers_OnSuspend)
		_LifecycleRunRequiredStep(Transition, "keylogger-system-intervals",
			KL_Watchers_OnSuspend)
	; Release OS-level modifiers before even the lifecycle START log: LoggerStart
	; flushes synchronously to disk and a slow/locked config drive must not delay
	; the balancing Up. The same bounded owner drain is the first shutdown step.
	_LifecycleRunRequiredStep(Transition, "tap-hold-synthetic-keys",
		() => TapHoldReleaseSyntheticKeys(), true)
	; Invalidate every detached tray-root ticket before the first yielding log.
	; The requested generation remains retained for a fresh resume owner.
	if IsSet(_TrayRootOnSuspendEnter)
		_LifecycleRunRequiredStep(Transition, "tray-root",
			() => _TrayRootOnSuspendEnter())
	; The suspend/resume machine tears down a dozen subsystems that native
	; Suspend does not touch — InputHooks, timers and OnMessage handlers all
	; bypass it — and it emitted NOTHING. So "pause = tout éteint", the invariant
	; the whole teardown exists to uphold, was unfalsifiable from a log: a
	; feature still running while paused and a feature correctly stopped produced
	; identical output. This pair makes the bracket searchable, and an ENTER with
	; no matching entered line now marks a teardown that died halfway.
	LoggerStart("Lifecycle", "Entering suspend…")
	LifecycleTransitionMarkStarted(Transition)
	; Screenshot children are external processes: stopping their AHK polls does
	; not stop their disk or clipboard work. Retire every owner first, then ask
	; the shared process lifecycle to terminate each tree exactly once.
	if IsSet(ScreenBrightnessCancel)
		_LifecycleRunRequiredStep(Transition, "screen-brightness",
			() => ScreenBrightnessCancel("suspended"), true)
	if IsSet(GestureScreenshotCancelAll)
		_LifecycleRunRequiredStep(Transition, "gesture-screenshot",
			() => GestureScreenshotCancelAll("suspended"))
	; Retire every deferred hotstring callback before any subsystem state is
	; cleared. Fired records remain queued and receive one fresh owner on resume;
	; derived render/near-miss callbacks from this generation become inert.
	if IsSet(HotstringPrefixWatcherOnSuspend) {
		_LifecycleRunRequiredStep(Transition, "hotstring-prefix-watcher",
			HotstringPrefixWatcherOnSuspend)
	}
	; A clipboard-selection poll is timer-driven, so native Suspend does not
	; stop it. Cancel before any other teardown to restore the clipboard and
	; prevent its callback from injecting after pause.
	if IsSet(GetSelectionCancel)
		_LifecycleRunRequiredStep(Transition, "selection-capture",
			() => GetSelectionCancel())
	if IsSet(_SpaceHoldInputHook) and IsObject(_SpaceHoldInputHook)
		_LifecycleRunRequiredStep(Transition, "space-hold-input-hook",
			() => _SpaceHoldInputHook.Stop())
	_LifecycleRunRequiredStep(Transition, "suppressive-input-hooks",
		() => SIHO_StopAll())
	if IsSet(_MagicKeyEditorInputHook) and IsObject(_MagicKeyEditorInputHook)
		_LifecycleRunRequiredStep(Transition, "magic-key-editor-input-hook",
			() => _MagicKeyEditorStopOwned(_MagicKeyEditorInputHook), true)
	_LifecycleRunRequiredStep(Transition, "suspend-tooltip",
		TooltipHide.Bind("Suspend", true))
	_LifecycleRunRequiredStep(Transition, "llm-tooltip", LLM_Tooltip_Hide.Bind(true))
		; Pausing ends live mode: it is not resumed with the driver, the user
		; turns it on again ("pause = tout éteint").
	_LifecycleRunRequiredStep(Transition, "llm-live-mode",
		() => LLM_Engine_LiveStop("Ergopti+ was paused"))
	_LifecycleRunRequiredStep(Transition, "llm-generation-timer", LLM_Engine_CancelTimer)
		; Stop in-flight generation AND clear the prediction cache so a suggestion
		; produced before the pause cannot re-render after resume on a rebuilt
		; context ("pause = tout eteint" invariant). StopGeneration drops last_ctx /
		; last_results, bumps request_id, and cancels async streams.
	_LifecycleRunRequiredStep(Transition, "llm-generation", LLM_Engine_StopGeneration)
		; The AI agent watches the typing with the AI menu's switch off too: its
		; pause timer and its flow in flight are retired separately.
	if IsSet(LLM_Agent_OnSuspend)
		_LifecycleRunRequiredStep(Transition, "llm-agent-typing", LLM_Agent_OnSuspend)
		; Cancel the Ollama warm-up retry timer so it does not make background HTTP
		; calls while the driver is paused ("pause = tout éteint" invariant).
	_LifecycleRunRequiredStep(Transition, "ollama-warmup",
		LLM_OllamaCancelWarmupRetry, true)
		; Stop the LLM pointer-dismiss poll timer + its pass-through mouse hotkeys.
		; SetTimer/Hotkey callbacks bypass native Suspend, so without this the
		; 50 ms MouseGetPos poll keeps firing for the whole pause ("pause = tout
		; éteint" invariant). Re-armed from Ergopti_OnSuspendResume when the bridge
		; is active.
	_LifecycleRunRequiredStep(Transition, "llm-pointer-watch",
		() => _LLM_PointerWatch_Stop())
		; Disarm the 20 Hz canonical focus-snapshot poll. Its WM_GETTEXT transaction is
		; bounded, but every repeating SetTimer still bypasses native Suspend. Re-arm
		; from Ergopti_OnSuspendResume only when metrics are enabled.
	_LifecycleRunRequiredStep(Transition, "metrics-focus-refresh",
		MF_StopFocusRefresh, true)
		; Cancel in-flight background update checks so a stale async callback cannot
		; surface a TrayTip or rebuild the menu while paused ("pause = tout éteint").
	_LifecycleRunRequiredStep(Transition, "updater-checks",
		_Updater_CancelAsyncChecks.Bind(UPDATER_CANCEL_REASON_SUSPEND), true)
		; A self-update owns a separate tree-owned staging process or an exact
		; suspended swap child. Cancel it on the suspend EVENT itself: sampling
		; A_IsSuspended from a later poll loses a rapid Pause→Resume pulse.
	_LifecycleRunRequiredStep(Transition, "updater-self-update",
		_Updater_QuiesceSelfUpdateForSuspend, true)
		; A metrics projection can be a multi-second detached AHK process.  Native
		; Suspend only disarms hotkeys, so explicitly kill its process tree rather
		; than letting SQLite/JSON work continue throughout a paused driver.
	_LifecycleRunRequiredStep(Transition, "keylogger-prefetch-typing",
		() => KLPF_CancelBuild("typing"))
	_LifecycleRunRequiredStep(Transition, "keylogger-prefetch-apps",
		() => KLPF_CancelBuild("apps"))
	_LifecycleRunRequiredStep(Transition, "keylogger-prefetch-range",
		() => KLPF_CancelBuild("range:typing"))
		; The selection probe is a persistent detached AHK process. Native Suspend
		; cannot stop it, so retire request ownership and its process tree before
		; entering the paused state.
	_LifecycleRunRequiredStep(Transition, "uia-selection-worker",
		UIASW_Stop.Bind("canceled"))
		; Preserve an hours-long at-rest proof scan at its exact stream cursor while
		; disarming its one-shot slice/marker timers. Native Suspend does not stop
		; timers, so the migration must be lifecycle-owned explicitly.
	if IsSet(KL_Mig_OnSuspend)
		_LifecycleRunRequiredStep(Transition, "keylogger-text-migration",
			KL_Mig_OnSuspend)
	_LifecycleRunRequiredStep(Transition, "keep-awake",
		() => StopActivitySimulation())
		; AHK-12: A gesture left/right click-hold (SendEvent "{LButton Down}") that
		; was in progress when the user pauses the driver outlives the suspend because
		; SetTimer callbacks bypass native Suspend — the button stays logically held
		; until the next mouse event. Release both hold states unconditionally here so
		; no synthetic button-down leaks into the suspended window ("pause = tout éteint").
	_LifecycleRunRequiredStep(Transition, "gesture-left-hold",
		() => GestureReleaseLeftClick(), true)
	_LifecycleRunRequiredStep(Transition, "gesture-right-hold",
		() => GestureReleaseRightClick(), true)
	; AHK-16: CapsWord keeps the hardware CapsLock LED lit (via UpdateCapsLockLED)
		; and continues arming its mouse-cancel HookDispatcher listeners even when the
		; driver is suspended — the LED misleads the user and the listeners fire through
		; native Suspend. DisableCapsWord resets CapsWordEnabled, unregisters mouse
		; listeners, and corrects the LED ("pause = tout éteint" invariant).
	if IsSet(DisableCapsWord)
		_LifecycleRunRequiredStep(Transition, "caps-word", () => DisableCapsWord())
		; Reset OneShotShift so a shift armed just before suspension is not applied
		; to the first keystroke after resume ("pause = tout éteint" invariant)
		global OneShotShiftEnabled := False
		; Wipe the hotstring engine buffer: suspend is a context-unknown boundary just
		; like a mouse click, Ctrl+V or Win+L. The on-screen text the buffer mirrors can
		; change completely while paused (the user clicks into another document), so a
		; surviving buffer would fire a stale trigger on the first post-resume terminator
		; and BackSpace into unrelated text. Mirrors RebuildHotstringsLive/_LockWorkstationEmit;
		; _ResetPrefixBuffer() on resume keeps the preview buffer paired with the engine.
	if IsSet(HSE_HardReset)
		_LifecycleRunRequiredStep(Transition, "hotstring-engine", HSE_HardReset)
	global _LLM_Deps_PollTimer
	if IsSet(_LLM_Deps_PollTimer)
		_LifecycleRunRequiredStep(Transition, "llm-dependency-poll",
			() => SetTimer(_LLM_Deps_PollTimer, 0))
	if !LifecycleTransitionFinish(Transition) {
		_LifecycleLogTransitionDebt(Transition)
		return false
	}
	LoggerSuccess("Lifecycle", "Suspend entered — all suspend-bypassing subsystems torn down.")
	return true
}
Ergopti_OnSuspendResume() {
		Transition := LifecycleTransitionBegin("resume")
		if IsSet(ProgramActions_Stop)
			_LifecycleRunRequiredStep(Transition, "user-programs", () => ProgramActions_Stop(false), true)
		LoggerStart("Lifecycle", "Resuming from suspend…")
		LifecycleTransitionMarkStarted(Transition)
		_LifecycleRunRequiredStep(Transition, "navigation-event",
			() => _LifecycleSetNavEventOwnerSuspended(false), true)
		; Transfer any pre-pause fire batch to one new timer owner only after native
		; Suspend has been lifted. A stale pre-pause callback cannot pass the new
		; generation even if it was already queued in the message pump.
		if IsSet(HotstringPrefixWatcherOnResume) {
				_LifecycleRunRequiredStep(Transition, "hotstring-prefix-watcher",
					HotstringPrefixWatcherOnResume)
		}
		if IsSet(_ResetPrefixBuffer)
				_LifecycleRunRequiredStep(Transition, "prefix-buffer", _ResetPrefixBuffer)
		; Replay a prefix-index rebuild deferred because it was requested while
		; suspended (a live hotstring section toggle during pause), so the preview
		; index re-syncs with the engine registry instead of staying diverged.
		global _PrefixIndexRebuildPending
		if IsSet(_PrefixIndexRebuildPending) and _PrefixIndexRebuildPending {
				_PrefixIndexRebuildPending := false
				if IsSet(HotstringPrefixWatcherRebuildIndex)
						_LifecycleRunRequiredStep(Transition, "prefix-index",
							HotstringPrefixWatcherRebuildIndex)
		}
		global _LLM_Deps_PollTimer, _LLM_Deps_Checking
		if IsSet(_LLM_Deps_PollTimer) and IsSet(_LLM_Deps_Checking) and _LLM_Deps_Checking
				_LifecycleRunRequiredStep(Transition, "llm-dependency-poll",
					() => SetTimer(_LLM_Deps_PollTimer, 3000))
		; Re-arm the LLM pointer-dismiss watcher stopped in Ergopti_OnSuspendEnter,
		; but only when the bridge is still active — _LLM_PointerWatch_Start is a
		; no-op when already armed, so this is safe to call unconditionally on the
		; active path.
		global _LLM_Bridge_Active
		if IsSet(_LLM_Bridge_Active) and _LLM_Bridge_Active
				_LifecycleRunRequiredStep(Transition, "llm-pointer-watch",
					() => _LLM_PointerWatch_Start())
		; Re-arm the metrics focus poll disarmed in Ergopti_OnSuspendEnter, gated on
		; the same feature flag that armed it at boot. Without this the cache would
		; stay frozen after the first pause and every metrics privacy filter would
		; read a stale foreground window for the rest of the session.
		if IsSet(MetricsShortcuts) and MetricsShortcuts.enabled
				_LifecycleRunRequiredStep(Transition, "metrics-focus-refresh",
					MF_StartFocusRefresh, true)
		; Range-worker cancellation is delivered while native Suspend is active,
		; when WebView mutation is forbidden. Release the page-side request latch
		; now, on the first resumed stack, instead of leaving every later filter
		; click blocked behind loading_data until the watchdog expires.
		if IsSet(KLWV_OnSuspendResume)
				_LifecycleRunRequiredStep(Transition, "keylogger-webview",
					KLWV_OnSuspendResume)
		; Re-arm exactly one migration continuation (active slice, durable marker,
		; or deferred posture sync) after all pause guards have been lifted.
		if IsSet(KL_Mig_OnResume)
				_LifecycleRunRequiredStep(Transition, "keylogger-text-migration",
					KL_Mig_OnResume)
		; Deferred dependency callbacks are not allowed to rebuild the tray or
		; start the bridge while native Suspend is active. Replay the pending work
		; only after the resume transition has completed.
		if IsSet(LLM_Menu_OnResume)
				_LifecycleRunRequiredStep(Transition, "llm-menu",
					() => LLM_Menu_OnResume())
		; Drain the exact manual updater terminals retained across pause only after
		; native Suspend has lifted. Background work remains intentionally silent.
		; Its result is not checked: false is its answer when no terminal and no
		; menu rebuild was retained, which is every ordinary resume. Requiring
		; true logged an error and failed the transition on each of them
		; (resume-updater-nothing-pending). A throw is still a debt.
		if IsSet(Updater_OnSuspendResume)
				_LifecycleRunRequiredStep(Transition, "updater",
					Updater_OnSuspendResume)
		; Suspend terminates the persistent UIA process. Warm its lightweight
		; source entry again after the transition so the first selection-wrap after
		; resume cannot race a cold worker; UIASW_Start remains feature/suspend safe.
		if IsSet(Features) and Features.Has("shortcuts")
			and Features["shortcuts"].Has("wrap_text_if_selected")
			and Features["shortcuts"]["wrap_text_if_selected"]
			_LifecycleRunRequiredStep(Transition, "uia-selection-worker",
				() => SetTimer(UIASW_Start, -1))
		if !LifecycleTransitionFinish(Transition) {
				_LifecycleLogTransitionDebt(Transition)
				return false
		}
		if IsSet(LLM_Menu_LocalServersResumeFinished) {
			try LLM_Menu_LocalServersResumeFinished(Transition)
			catch as Err
				try LoggerError("Lifecycle", "Local AI server post-transition repair remains owned.")
		}
		LoggerSuccess("Lifecycle", "Resumed — suspend-bypassing subsystems restarted.")
		return true
}

_LifecycleLogTransitionDebt(Transaction) {
	for Debt in Transaction.debt
		try LoggerError("Lifecycle", "{1} transition owner '{2}' failed: {3}.",
			Transaction.phase, Debt.owner, Debt.message)
}

SuspendWatchdogStart() {
	global _LastSuspendState, _SuspendWatchdogStarted, SUSPEND_WATCHDOG_MS
	if _SuspendWatchdogStarted
		throw Error("suspend watchdog already started")
	_LastSuspendState := A_IsSuspended
	SetTimer(_SuspendStateWatchdog, SUSPEND_WATCHDOG_MS)
	_SuspendWatchdogStarted := true
	return true
}

_SuspendStateWatchdog() {
		global _LastSuspendState
		; Serialize the transition. This runs both from a 500 ms repeating timer and
		; directly on each toggle; AHK pseudo-threads are interruptible, so a rapid
		; double-toggle could otherwise interrupt Ergopti_OnSuspendEnter's teardown with
		; Ergopti_OnSuspendResume, leaving a resumed driver half torn down. If a reactor
		; is already running, leave _LastSuspendState unchanged and return — the repeating
		; timer re-detects the (possibly reversed) state on its next tick and dispatches
		; the correct reactor once the current one has finished.
		static _TransitionBusy := false
		; First invocation after boot: replay a pause handed off by
		; ReloadPreservingSuspend. Doing it here rather than in the boot block keeps
		; the whole suspend machine in one file, and the state change is picked up by
		; the comparison right below, so the restored pause runs the same reactor and
		; the same tray-icon update as a manual one.
		static _BootRestoreDone := false
		if !_BootRestoreDone {
				_BootRestoreDone := true
				_SuspendRestoreFromMarker()
		}
		if (A_IsSuspended == _LastSuspendState) {
				if !A_IsSuspended {
						RootService := 0
						if IsSet(_TrayRootServiceRetained)
								RootService := _TrayRootServiceRetained
						_TrayRootServiceRetainedWork(RootService)
				} else if IsSet(_TrayRootFirstPublicationPending)
						&& _TrayRootFirstPublicationPending() {
						; A pause restored after a reload can land while the boot
						; build of the tray root is staging, which makes that root
						; stale. It is the one retained root served under a pause:
						; without it the paused driver keeps the boot menu, without
						; the row that lifts the pause (first-root-under-pause).
						_TrayRootServiceRetainedWork(_TrayRootServiceRetained)
				}
				return
		}
		if _TransitionBusy
				return
		_TransitionBusy := true
		try {
				_LLM_NavEventOwnerApplyExternalSuspendTransition(
					A_IsSuspended, Ergopti_OnSuspendEnter,
					Ergopti_OnSuspendResume, Suspend, UpdateTrayIcon,
					LifecycleTransitionNeedsCompensation.Bind("suspend"))
		} finally {
				_TransitionBusy := false
		}
}
; Single global shutdown handler wired to OnExit (see the auto-execute section
; after the keylogger is started). AHK v2 Reload() and ExitApp() tear the process
; down WITHOUT running per-module destructors — only callbacks registered via
; OnExit run. The keylogger hot path is intentionally RAM-buffered (KL_AppendLog
; queues into _pending_entries; KL_Hook_Tick flushes buffer_events every 200 ms
; and KL_IngestOnce drains _pending_entries to data.sql every 5 s), so WITHOUT this
; handler a Reload (the driver's standard "apply settings" mechanism, also fired by
; CheckKeyboardLayoutChange on a layout switch) silently loses the last few seconds
; of typing metrics on every restart. KL_Stop is idempotent (guards on
; Keylogger.initialized) and already flushes + ingests + saves, so wiring it here
; closes the data-loss window. EVERY step is try-wrapped: an OnExit callback that
; throws is swallowed by AHK and can hang exit, so the handler must never throw.
; Returning 0 lets the exit proceed.
;
; The same reasoning covers any transaction whose COMPLETION depends on a
; callback owned by this process. The self-update staging worker is one: it is a
; tree-owned PowerShell task, followed by a suspended exact-HANDLE swap child
; published only from _Updater_PollDownloadAsync. A Reload here used to orphan
; the staging download and the user's "Update now" click silently installed nothing
; (updater-staging-worker-orphaned-on-exit). Every future subsystem with that
; shape belongs in this handler too.
; Best-effort release of everything this process may still be holding at the OS
; level, used only on the forced-exit path. A latched modifier or mouse button
; outlives the driver and breaks the whole session, so these are re-attempted
; even though their owning gate already failed — a second try costs nothing and
; each one that succeeds is damage the forced exit no longer does.
; @returns {Integer} 1 when every release reported success, 0 otherwise.
_LifecycleForceReleaseHeldInput() {
	Released := 1
	for Release in [GestureReleaseLeftClick, GestureReleaseRightClick,
			TapHoldReleaseSyntheticKeys] {
		try {
			Result := Release.Call()
			if !((Result is Integer) && Result == 1)
				Released := 0
		} catch as Err {
			Released := 0
			try LoggerError("Lifecycle",
				"Forced shutdown release raised: {1}.", Err.Message)
		}
	}
	return Released
}

; Whether OnExit would still honor one more veto. Past that one, the exit goes
; through whatever gate refuses it, so an automatic reload, which nobody asked
; to force, must not start once this is false (the layout poll).
; @returns {Boolean} True while one more refusal would keep this process alive.
LifecycleShutdownVetoHonored() {
	global LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS, _LifecycleShutdownVetoAttempts
	return _LifecycleShutdownVetoAttempts + 1 < LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS
}

; Counts one refused exit and decides whether the driver may keep refusing.
;
; Every gate in Ergopti_OnShutdown funnels its veto through here so the ceiling
; covers the whole class, including gates added later — the recurring defect in
; this repository is the one sibling site that kept the old behaviour. The
; ceiling, LIFECYCLE_SHUTDOWN_VETO_MAX_ATTEMPTS, is read through
; LifecycleShutdownVetoHonored, the one rule the layout poll also consults.
; @param Gate {String} Short name of the refusing gate, for the exhaustion line.
; @returns {Integer} 1 to veto the exit, 0 to let it proceed regardless.
_LifecycleRefuseShutdown(Gate, RequireNativeRetirement := false) {
	global _LifecycleShutdownVetoAttempts, _LifecycleShutdownReason
	global _LifecycleAiShutdownAttempt
	try UninstallCancel()
	catch as Err
		try LoggerError("Lifecycle", "Removal cancellation failed during shutdown refusal: {1}.", Err.Message)
	Honored := LifecycleShutdownVetoHonored()
	; Only an exact unsettled reload owner can extend the general veto ceiling.
	NativeStopPending := !Honored && IsSet(ReloadTerminalHandoffNativeStopPending)
		&& ReloadTerminalHandoffNativeStopPending.Call()
	if RequireNativeRetirement || NativeStopPending {
		Honored := true
		try KL_CancelShutdown()
	}
	_LifecycleShutdownVetoAttempts += 1
	if Honored {
		; The successor that asked is now waiting on this window. Stop it and hand
		; the transition back, or it prompts until someone answers.
		try ReloadTerminalHandoffRefuseForShutdown(_LifecycleShutdownReason, Gate)
		catch as Err
			try LoggerError("Lifecycle",
				"Refused reload could not be handed back: {1}.", Err.Message)
		; Cancellation retires only this exact AI attempt. Existing terminal,
		; reload and cleanup barriers keep their independent authority.
		if IsSet(LLM_Menu_ApiPrivateRefuseShutdown)
			LLM_Menu_ApiPrivateRefuseShutdown(_LifecycleAiShutdownAttempt)
		if IsSet(LLM_Menu_LocalServersShutdownRefused) {
			try LLM_Menu_LocalServersShutdownRefused(_LifecycleAiShutdownAttempt)
			catch as Err
				try LoggerError("Lifecycle", "Local AI server repair remains owned after shutdown refusal.")
		}
		return 1
	}
	Released := _LifecycleForceReleaseHeldInput()
	try LoggerError("Lifecycle",
		"Shutdown veto budget exhausted after {1} refusals (last gate: {2}); "
		. "exiting anyway. Held input release was {3}.",
		_LifecycleShutdownVetoAttempts, Gate,
		Released == 1 ? "proven" : "INCOMPLETE")
	return 0
}

; This admission protects only the exact unsettled successor retirement.
_LifecycleRefuseNativeRetirement(Gate) {
	return _LifecycleRefuseShutdown(Gate, true)
}

; Resumes only the same explicitly requested ordinary exit after native stop.
_LifecycleRetrySupersededExit(Code, Record, *) {
	if ReloadTerminalHandoffPending() != Record || Record["state"] != "abandon_ready"
			|| !Record["stop_acknowledged"]
		return false
	ExitApp(Code)
}

Ergopti_OnShutdown(reason, code) {
		global _LifecycleShutdownReason, _LifecycleAiShutdownAttempt
		if IsSet(LLM_Menu_ApiPrivateBeginShutdown)
			_LifecycleAiShutdownAttempt := LLM_Menu_ApiPrivateBeginShutdown()
		_LifecycleShutdownReason := reason
		; Button holds are OS state, so release them before any gate may keep this
		; process alive. Do not free the WinEvent hook yet: a refused OnExit must
		; return to a fully functional gesture subsystem.
		LeftHoldReleased := false
		RightHoldReleased := false
		try LeftHoldReleased := GestureReleaseLeftClick()
		catch as Err
			try LoggerError("Lifecycle", "Left click-hold shutdown release failed: {1}.", Err.Message)
		try RightHoldReleased := GestureReleaseRightClick()
		catch as Err
			try LoggerError("Lifecycle", "Right click-hold shutdown release failed: {1}.", Err.Message)
		if !((LeftHoldReleased is Integer) and LeftHoldReleased == 1
				and (RightHoldReleased is Integer) and RightHoldReleased == 1) {
			try LoggerError("Lifecycle", "Shutdown refused because a synthetic mouse button release remains pending.")
			try SetTimer(GestureReleaseLeftClick, -1)
			try SetTimer(GestureReleaseRightClick, -1)
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("a synthetic mouse button release remains pending")
		}
		if IsSet(UserHotstringsInvalidate) && !UserHotstringsInvalidate("shutdown-preflight")
			return _LifecycleRefuseShutdown("a programmable hotstring process or stage remains owned")
		NavOwnerReady := false
		try NavOwnerReady := LLM_NavEventOwner_PrepareShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Navigation-owner shutdown preflight failed: {1}.", Err.Message)
		if !NavOwnerReady {
			try LoggerError("Lifecycle", "Shutdown refused because native keyboard receipts or holds remain owned.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("native keyboard receipts or holds remain owned")
		}
		ShutdownTerminal := false
		try {
		TerminalHandoff := ReloadTerminalHandoffClaim(reason)
		; Any other exit while a launched successor still loads supersedes that
		; reload. It borrows the pending bundle, which blocks every fresh
		; acquisition, and stops the successor only after the last refusal gate.
		SupersededReload := ((TerminalHandoff is Map)
				|| StrCompare(reason, "Reload", true) == 0)
			? false : ReloadTerminalHandoffPending()
		RetainedTransition := ((TerminalHandoff is Map)
				|| (SupersededReload is Map))
			? false : ConfigTransitionRetainedBarrier()
		ShutdownOwners := (TerminalHandoff is Map)
			? TerminalHandoff["bundle"]
			: ((SupersededReload is Map)
				? SupersededReload["bundle"]
				: ((RetainedTransition is Object)
					? RetainedTransition : ConfigWriteAcquireLifecycleBundle()))
		if !(ShutdownOwners is Object) {
			try LoggerError("Lifecycle", "Shutdown refused because another configuration transaction is still active.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("another configuration transaction is still active")
		}
		OwnShutdownBundle := !(TerminalHandoff is Map)
			&& !(SupersededReload is Map)
			&& !(RetainedTransition is Object)
		try {
		SyntheticReleased := false
		try SyntheticReleased := TapHoldShutdownReleaseGate()
		if !SyntheticReleased {
			; Exiting would destroy the last owner of an OS-level Down. Refuse the
			; shutdown and retry once the OnExit callback has returned instead of
			; proceeding into a half-torn-down live driver.
			try LoggerError("Lifecycle", "Shutdown refused because a synthetic modifier release is still pending.")
			try SetTimer(TapHoldReleaseSyntheticKeys, -1)
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("a synthetic modifier release is still pending")
		}
		; Retire user programs only after OS-held input is released. A refused
		; exit keeps the real pause posture, and the enclosing finally blocks
		; return the configuration bundle and native admission to the live driver.
		ProgramStopped := !IsSet(ProgramActions_Stop)
		try {
			if IsSet(ProgramActions_Stop)
				ProgramStopped := ProgramActions_Stop(A_IsSuspended)
		} catch as Err {
			try LoggerError("Lifecycle", "User-program shutdown preflight failed: {1}.", Err.Message)
		}
		if !((ProgramStopped is Integer) && ProgramStopped == 1) {
			try LoggerError("Lifecycle", "Shutdown refused because a user program tree is still alive.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("a user program tree is still alive")
		}
		FullSaveSettled := false
		try FullSaveSettled := _ConfigFullSaveSettleTerminal(ShutdownOwners)
		catch as Err
			try LoggerError("Lifecycle", "Terminal full-save settlement failed: {1}.", Err.Message)
		if !((FullSaveSettled is Integer) && FullSaveSettled == 1) {
			try LoggerError("Lifecycle", "Shutdown refused because an accepted full configuration save remains non-durable.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("an accepted full configuration save remains non-durable")
		}
		RecoveryCanExit := false
		try RecoveryCanExit := _Updater_RecoveryMayEnterTerminalShutdown()
		if !RecoveryCanExit {
			try LoggerError("Lifecycle", "Shutdown refused while the recovery executable remains the sole durable driver owner.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("the recovery executable remains the sole durable driver owner")
		}
		; Publish only the reversible keylogger bypass before draining. OnExit is
		; non-interruptible, so the InputHook can remain installed until every
		; refusal-capable terminal operation has accepted. A refused Reload then
		; returns to a complete driver instead of one with its producers stopped.
		try KL_BeginShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Keylogger shutdown lease failed: {1}.", Err.Message)
		KeyloggerFlushReady := false
		try KeyloggerFlushReady := KL_FlushShutdownReady()
		catch as Err
			try LoggerError("Lifecycle", "Keylogger flush shutdown preflight failed: {1}.", Err.Message)
		if !KeyloggerFlushReady {
			try LoggerError("Lifecycle",
				"Shutdown refused because keylogger persistence debt is not durable yet.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("keylogger persistence debt is not durable yet")
		}
		AppCategoriesReady := false
		try AppCategoriesReady := KL_AppCat_PrepareShutdown()
		catch as Err
			try LoggerError("Lifecycle", "App-category shutdown preflight failed: {1}.", Err.Message)
		if !AppCategoriesReady {
			try LoggerError("Lifecycle",
				"Shutdown refused because pending app categories are not durable yet.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("pending app categories are not durable yet")
		}
		ClipboardRestoreReady := false
		try ClipboardRestoreReady := CB_PrepareShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Clipboard restore shutdown preflight failed: {1}.", Err.Message)
		if !ClipboardRestoreReady {
			try LoggerError("Lifecycle",
				"Shutdown refused because the user's clipboard snapshot is not restored yet.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("the user's clipboard snapshot is not restored yet")
		}
		FireDrainComplete := false
		try FireDrainComplete := HotstringPrefixWatcherPrepareShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Deferred hotstring shutdown drain failed: {1}.", Err.Message)
		if !FireDrainComplete {
			; The in-memory fire batch is still the sole owner. No producer has been
			; stopped, so withdrawing the reversible keylogger lease is sufficient.
			try LoggerError("Lifecycle", "Shutdown refused because deferred hotstring records are still pending.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("deferred hotstring records are still pending")
		}
		LocalServersSettled := true
		if IsSet(LLM_Menu_LocalServersPrepareShutdown) {
			LocalServersSettled := false
			try LocalServersSettled := LLM_Menu_LocalServersPrepareShutdown()
			catch as Err
				try LoggerError("Lifecycle", "Local AI server retirement failed before shutdown: {1}.", Err.Message)
		}
		if !LocalServersSettled {
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("local AI server requests remain owned")
		}
		InstallerStopped := false
		try InstallerStopped := LLM_Deps_PrepareShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Ollama installer shutdown preflight failed: {1}.", Err.Message)
		if !InstallerStopped {
			try LoggerError("Lifecycle",
				"Shutdown refused because the package installer tree is still alive.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("the package installer tree is still alive")
		}
		CrashWorkersStopped := false
		try CrashWorkersStopped := CrashReportWorker_StopAll()
		catch as Err
			try LoggerError("Lifecycle", "Crash-report worker shutdown preflight failed: {1}.", Err.Message)
		if !CrashWorkersStopped {
			try LoggerError("Lifecycle",
				"Shutdown refused because a crash-report process is still alive.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("a crash-report process is still alive")
		}
		PrefetchStopped := false
		try PrefetchStopped := KLPF_CancelAll()
		catch as Err
			try LoggerError("Lifecycle", "Keylogger prefetch shutdown failed: {1}.", Err.Message)
		if !PrefetchStopped {
			try LoggerError("Lifecycle",
				"Shutdown refused because a metrics projection worker is still alive.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("a metrics projection worker is still alive")
		}
		LoggerReady := false
		try _TooltipLogRenderAccounting("shutdown preflight")
		try LoggerReady := LoggerPrepareShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Logger shutdown preflight failed: {1}.", Err.Message)
		if !LoggerReady {
			try LoggerError("Lifecycle",
				"Shutdown refused because diagnostic records are not durable yet.")
			try KL_CancelShutdown()
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("diagnostic records are not durable yet")
		}
		; The reload-specific durable commit is still allowed to refuse. It must
		; precede every producer stop; a later veto refuses the pending reload
		; through _LifecycleRefuseShutdown, which runs the matching abort callback.
		if (TerminalHandoff is Map) {
			TerminalCommitted := false
			try TerminalCommitted := ReloadTerminalHandoffCommit(TerminalHandoff)
			catch as Err
				try LoggerError("Lifecycle", "Reload terminal commit failed before teardown: {1}.", Err.Message)
			if !TerminalCommitted {
				try KL_CancelShutdown()
				try _Updater_DeferExitIntentRetry()
				try _Updater_DeferRecoveryHandoffRetry()
				return _LifecycleRefuseShutdown("the reload terminal commit failed before teardown")
			}
		}
		; FinalExit and ownership transfer remain refusal gates, but all live
		; producers are still installed. A refusal rolls back the terminal handoff
		; through _LifecycleRefuseShutdown and withdraws the keylogger lease below.
		if FileReadActivityBusy() {
			try KL_CancelShutdown()
			return _LifecycleRefuseShutdown("an exact file read still owns native cleanup")
		}
		if (SupersededReload is Map) {
			ResumeExit := StrCompare(reason, "Exit", true) == 0
				? _LifecycleRetrySupersededExit.Bind(code) : 0
			StopReady := false
			try StopReady := ReloadTerminalHandoffPrepareAbandon(SupersededReload, reason, ResumeExit)
			catch as Err
				try LoggerError("Lifecycle", "Superseded reload retirement failed: {1}.", Err.Message)
			if !StopReady {
				try KL_CancelShutdown()
				return _LifecycleRefuseNativeRetirement("a reload successor still owns native retirement")
			}
		}
		FinalExitAuthorized := false
		try FinalExitAuthorized := _Updater_SignalFinalExitForIntent()
		catch as Err
			try LoggerError("Lifecycle", "Updater FinalExit authorization failed: {1}.", Err.Message)
		if !FinalExitAuthorized {
			try LoggerError("Lifecycle", "Shutdown refused because the updater swap worker could not accept FinalExit authorization.")
			try KL_CancelShutdown()
			return _LifecycleRefuseShutdown("the updater swap worker could not accept FinalExit authorization")
		}
		SwapOwnershipTransferred := false
		try SwapOwnershipTransferred := _Updater_TransferExitIntentAfterShutdownGates()
		catch as Err
			try LoggerError("Lifecycle", "Updater ownership transfer failed after shutdown gates: {1}.", Err.Message)
		if !SwapOwnershipTransferred {
			try LoggerError("Lifecycle", "Shutdown refused because the acknowledged updater child was no longer alive at ownership transfer.")
			try KL_CancelShutdown()
			return _LifecycleRefuseShutdown("the acknowledged updater child was no longer alive at ownership transfer")
		}
		RecoveryHandoffComplete := false
		try RecoveryHandoffComplete := _Updater_CompleteRecoveryHandoffOnExit()
		catch as Err
			try LoggerError("Lifecycle", "Recovery handoff failed before terminal teardown: {1}.", Err.Message)
		if !RecoveryHandoffComplete {
			try KL_CancelShutdown()
			try _Updater_DeferRecoveryHandoffRetry()
			return _LifecycleRefuseShutdown("the recovery handoff failed before terminal teardown")
		}
		ShutdownTerminal := true
		try UninstallCommit(reason)
		catch as Err
			try LoggerError("Lifecycle", "Removal authorization failed during terminal shutdown: {1}.", Err.Message)
		; No code below this point may refuse shutdown. All fallible authority
		; transfers have accepted while the live driver was still intact.
		if (SupersededReload is Map)
			try ReloadTerminalHandoffAbandon(SupersededReload, reason)
		try ScreenBrightnessCancel("shutdown")
		try GestureScreenshotCancelAll("shutdown")
		try HotstringPrefixWatcherStop()
		try HotstringPrefixWatcherOnShutdown()
		KeyloggerStopped := false
		try KeyloggerStopped := KL_Stop()
		catch as Err
			try LoggerError("Lifecycle", "Terminal keylogger stop failed: {1}.", Err.Message)
		if !KeyloggerStopped
			try LoggerError("Lifecycle",
				"Terminal keylogger stop retained persistence debt; exit will continue under the durable journal contract.")
		try UIASW_Stop("canceled")
		try {
			if !SFD_Stop()
				LoggerError("Lifecycle", "Secure-field focus hook teardown failed.")
		} catch as Err {
			try LoggerError("Lifecycle", "Secure-field focus hook teardown failed: {1}.",
				Err.Message)
		}
		try {
			if !AltGrFamilyStopFollowing()
				LoggerError("Lifecycle", "AltGr family foreground hook teardown failed.")
		} catch as Err {
			try LoggerError("Lifecycle", "AltGr family foreground hook teardown failed: {1}.",
				Err.Message)
		}
		try LLM_NavEventOwner_Stop(false, true)
		try TooltipReleaseRenderResources()
		try MenuPopulation_Shutdown()
		catch as Err
			try LoggerError("Lifecycle", "Native menu preparation teardown failed: {1}.", Err.Message)
		try MenuStartupCommands_Shutdown()
		catch as Err
			try LoggerError("Lifecycle", "Startup menu command teardown failed: {1}.", Err.Message)
		try CrashReportWorker_StopAll()
		try HookDispatcher.Stop()
		try KLWV_CloseAll()
		try _HC_Close()
		try WebView_StopBrowserWarmup()
		catch as Err
			try LoggerError("Lifecycle", "Shared browser warmup teardown failed: {1}.", Err.Message)
		try OllamaWV_Close()
		try _Updater_AbortStagingOnExit()
		if (TerminalHandoff is Map) {
			TerminalFinished := false
			; Finish validates terminal ownership before invoking _GestureUnhook,
			; then reports UI success. A false result therefore leaves the live
			; gesture hook untouched and makes refusal safe.
			try TerminalFinished := ReloadTerminalHandoffFinish(
				TerminalHandoff, _GestureUnhook)
			catch as Err
				try LoggerError("Lifecycle", "Reload terminal success finalization failed: {1}.", Err.Message)
			if !TerminalFinished {
				; Refusing now would strand a fully torn-down driver. The durable
				; commit already owns boot recovery, so log and let exit complete.
				try LoggerError("Lifecycle", "Reload terminal finalization failed after irreversible teardown; exit will continue.")
			}
		} else
			; Ordinary Exit has no reload-success callback to protect. Every refusal
			; gate has accepted, so best-effort teardown is terminal here.
			try _GestureUnhook()
		return 0
		} finally {
			if OwnShutdownBundle
				try _ConfigWriteTerminalRelease(ShutdownOwners)
		}
		} finally {
			if !ShutdownTerminal
				try LLM_NavEventOwner_CancelShutdown()
		}
}
; Publish the configured tray before input registration, then prewarm its leaves.
; initMenu stages every subtree while the old root remains live and enters
; Critical only for the short root replacement. UpdateTrayIcon runs last, once
; MenuSuspend exists.
_TrayRootBuildBoot(PublishAuthorizeFn) {
	global _DriverInputInitPending, _DriverMenuReady
	global _TrayRootBootDetailsPending
	global _MenuPopulationBuilding, _MenuPopulationPublished
	global _DriverReady, _LangMenuBuildPending, LANG_MENU_DEFER_MS
	global _LLM_Menu, LLM_MENU_BUILD_DEFER_MS
	_SavedReady := _DriverReady
	_DriverReady := false
	BootProfile_StageBegin("tray menu")
	if _MenuPopulationBuilding is MenuPopulation
		throw Error("Native menu population already has a build owner")
	PopulationOwner := MenuPopulation()
	_MenuPopulationBuilding := PopulationOwner
	try {
		InitSubMenus()
		Published := initMenu(PublishAuthorizeFn)
	} finally {
		_DriverReady := _SavedReady
		_MenuPopulationBuilding := false
		if _MenuPopulationPublished != PopulationOwner
			PopulationOwner.Pending.Clear()
	}
	if !((Published is Integer) and Published == 1) {
		; Closes the stage explicitly: a refused publication retries later, and an
		; open stage in the log would otherwise read as a hang.
		BootProfile_StageAbort("tray menu", "publication refused (status "
			. (IsSet(Published) ? String(Published) : "unset") . "); the build will be retried")
		return false
	}
	UpdateTrayIcon()
	BootProfile_StageEnd("tray menu", "published")
	InputPending := IsSet(_DriverInputInitPending) && _DriverInputInitPending
	if !InputPending
		PopulationOwner.Start()
	if _LangMenuBuildPending && !InputPending
		SetTimer(BuildLanguageMenuDeferred, -LANG_MENU_DEFER_MS)
	BootProfile_Mark("Configured tray menu published")
	; The independent LLM timer used to preempt this root worker, invalidate
	; its generation, and force a second full InitSubMenus scan. Arm the cheap
	; OFF-state population only after this root and its boot finalizer publish.
	; A retained/retried boot worker reaches the same ownership seam.
	; Either projection stands down when initMenu already populated the IA
	; handle inline: re-running the whole menu then only re-renders an
	; unchanged tree (~109-156 ms wall on real boots for 13 free rows).
	if !InputPending && _TrayRootBootIaPopulationNeeded() && _TrayRootScheduleBootProjectionIfDisabled(
			_LLM_Menu["enabled"], LLM_Menu_RequestBuild.Bind("boot"),
			SetTimer, LLM_MENU_BUILD_DEFER_MS) {
		try LoggerDebug("TrayMenu",
			"Deferred root published; arming boot IA submenu build in {1} ms.",
			LLM_MENU_BUILD_DEFER_MS)
	}
	; The api backend never reaches Ollama readiness, so unlike the ollama
	; case nothing else populates the IA submenu after boot. Arm the same
	; deferred population whenever the api backend is enabled (predicates owned
	; by menu_rebuild.ahk, next to the IfDisabled gate).
	if !InputPending && _TrayRootApiBootProjectionNeeded() && _TrayRootBootIaPopulationNeeded()
		SetTimer(LLM_Menu_RequestBuild.Bind("boot"), -LLM_MENU_BUILD_DEFER_MS)
	; Release navigation only after every timed build stage is closed, otherwise
	; the user's menu-reading time is charged to construction.
	_TrayRootBootDetailsPending := false
	_DriverMenuReady := true
	try LoggerInfo("BootProfile", "Complete configured menu usable at {1} ms since process start; input initialization pending={2}.",
		BootProfile_TotalBootMs(), InputPending ? "true" : "false")
	if IsSet(_TrayStartupClick)
		_TrayStartupClick.NotifyReady()
	return true
}

BuildTrayMenuDeferred() {
	; Warm both filesystem-backed caches before the coordinator starts a worker.
	_HS_PreScanExtensions()
	_HS_PreScanPersonal()
	try {
		BuildAccepted := RebuildTrayMenu(0, _TrayRootBuildBoot, false)
		if !((BuildAccepted is Integer) and BuildAccepted == 1) {
			; A pause restored while the root was staging is an expected refusal,
			; not a failure: the watchdog publishes the first root under the pause.
			if A_IsSuspended {
				try LoggerInfo("TrayMenu", "Deferred tray-menu build interrupted by the restored pause; the watchdog rebuilds it under the pause.")
			} else {
				try LoggerError("TrayMenu", "Deferred tray-menu build was retained for retry.")
			}
			return false
		}
		return true
	} catch as e {
		if _TrayRootErrorIsSilent(e)
			return false
		try LoggerError("TrayMenu", "Deferred tray-menu build failed: {1} [{2} at {3}:{4}]",
			e.Message,
			(e.HasProp("What") ? e.What : "?"),
			(e.HasProp("File") ? e.File : "?"),
			(e.HasProp("Line") ? e.Line : "?"))
		return false
	}
}

UpdateTrayIcon() {
		; The MenuSuspend item exists only after BuildTrayMenuDeferred has run. This is
		; called from ToggleSuspend / the suspend watchdog, which can fire in the brief
		; pre-build window after launch — guard the check so an early suspend cannot
		; throw on a not-yet-built menu item. The icon swap below still happens.
		if A_IsSuspended {
				try A_TrayMenu.Check(MenuSuspend)
				if FileExist(IconPathDisabled)
						TraySetIcon(IconPathDisabled, , True)
		}
		else {
				try A_TrayMenu.Uncheck(MenuSuspend)
				if FileExist(IconPath)
						TraySetIcon(IconPath)
		}
		; Rebuilds are refused while paused, so the live root is what the user
		; sees: grey every feature submenu on pause and restore them on resume.
		; The global rows, « Suspendre » included, are not feature rows.
		TrayMenu_ApplyPauseGreying(A_IsSuspended)
		MenuPopulation_Resume()
}
; The tray menu's own « Recharger » item — the single most obviously
; paused-reachable reload in the driver, and it dropped the pause like all the
; others. "Reload the driver" and "stop being paused" are two different requests;
; only one of them was made.
ActivateReload(*) {
		ReloadPreservingSuspend()
}
ActivateExitApp(*) {
		ExitApp()
}
WindowSpy(*) {
		SplitPath(A_AhkPath, , &ahkDir)
		SplitPath(ahkDir, , &parentDir)
		spyPath := parentDir "\WindowSpy.ahk"
		if FileExist(spyPath)
				Run(spyPath)
		else
				Ui_MsgBox(Format(t("ergopti.windowspy_not_found"), spyPath))
}
ActivateListVars(*) {
		return ConsoleWindow_Open("list_vars")
}
ActivateKeyHistory(*) {
		return ConsoleWindow_Open("key_history")
}
ShowHealthCheck(*) {
		HealthCheck_ShowWindow()
}

/**
 * Publishes global commands before scanning and rendering feature submenus.
 * @returns {Boolean} Whether the root coordinator accepted the publication.
 */
BuildReadyTrayShell() {
	global _TrayRootBootDetailsPending
	_TrayRootBootDetailsPending := true
	return RebuildTrayMenu(0, _TrayRootBuildShell, false)
}

; The manifest decides both the order and which rows belong to features. Global
; commands remain usable while the ordinary boot worker stages its detached tree.
; The shell uses the same publication owner and dispatcher as every later root.
_TrayRootBuildShell(PublishAuthorizeFn) {
	global _DriverReady, _LangMenuBuildPending
	SavedReady := _DriverReady
	_DriverReady := false
	BootProfile_StageBegin("tray global commands")
	try {
		Published := initMenu(PublishAuthorizeFn, true)
	} catch as Err {
		TrayMenuStage_Abort()
		BootProfile_StageAbort("tray global commands", Err.Message)
		throw Err
	} finally {
		_DriverReady := SavedReady
	}
	if !((Published is Integer) && Published == 1) {
		BootProfile_StageAbort("tray global commands", "publication refused")
		return false
	}
	UpdateTrayIcon()
	BootProfile_StageEnd("tray global commands", "published; feature submenus are pending")
	LoggerInfo("BootProfile", Format("Tray global commands usable at {1} ms since process start.",
		BootProfile_TotalBootMs()))
	return true
}
