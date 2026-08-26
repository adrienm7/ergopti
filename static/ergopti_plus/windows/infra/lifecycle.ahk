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

ActivateEdit(*) {
		Edit()
}
; Physical keys registered as an AHK custom-combination PREFIX (the left side of
; a "&" hotkey definition, e.g. "SC138 & SC01C::" in script_altgr_hotkeys.ahk or
; "SC038 & SC03A::" in modules/shortcuts/base_modifier.ahk). AHK's custom-
; combination prefix-down flag latches across Suspend() and cannot be cleared by
; synthetic events -- see _SuspendPrefixesAreClear / _SuspendPendingPoll below.
; Single source of truth: EVERY key used as the prefix of an "X & Y" custom
; combination anywhere in the driver must appear here, so it is drained
; automatically before every future suspend instead of leaving an un-drained
; sibling for the same latch bug to hide in (feedback_ahk_suspend_prefix_latch,
; F42, F-30). The list is hand-maintained, so
; test_suspend_prefix_drain_covers_all_combos.ahk DERIVES the real prefix set
; from driver source and fails when a newly introduced combination is missing.
;   SC138 = AltGr/Kana   SC038 = LAlt   SC01D = LCtrl   SC02A = LShift   SC11D = RCtrl
global SUSPEND_CUSTOM_COMBO_PREFIX_KEYS := ["SC138", "SC038", "SC01D", "SC02A", "SC11D"]
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

; Drains every registered custom-combination prefix key (see
; SUSPEND_CUSTOM_COMBO_PREFIX_KEYS) BEFORE a suspend flips. AHK prefix flags
; latch across Suspend and cannot be cleared by synthetic events — they must be
; prevented at the source by waiting (briefly) for the physical key to lift
; before suspending. Factored out of ToggleSuspend so EVERY code path that can
; trigger a suspend can call the same drain, and so a future native/external
; suspend hotkey cannot silently reintroduce the « AltGr/LAlt bloqué »
; regression by bypassing the wait. Safe no-op when entering from suspended
; state, when a key's own feature gate is off (SC138 only arms as a prefix when
; the Kana fixup is active), or when the key is not physically held.
_SuspendPrefixesAreClear() {
		global _ALTGR_KANA_FIXUP
		if A_IsSuspended
				return
		for PrefixKey in SUSPEND_CUSTOM_COMBO_PREFIX_KEYS {
				; SC138 (AltGr/Kana) only behaves as an armed prefix when the Kana
				; fixup is active on the current keyboard layout -- draining it
				; unconditionally would KeyWait on a key that is not really latching.
				if (PrefixKey = "SC138") and !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
						continue
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
		global _ALTGR_KANA_FIXUP
		Held := ""
		for PrefixKey in SUSPEND_CUSTOM_COMBO_PREFIX_KEYS {
				if (PrefixKey = "SC138") and !(IsSet(_ALTGR_KANA_FIXUP) and _ALTGR_KANA_FIXUP)
						continue
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
ReloadPreservingSuspend(SuccessFn := 0, ExistingBundle := 0) {
	PreviousCritical := Critical("Off")
	try return _ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle)
	finally Critical(PreviousCritical)
}

_ReloadPreservingSuspendNonCritical(SuccessFn, ExistingBundle) {
	global ConfigurationFile
	OwnBundle := false
	OwnerBundle := ExistingBundle
	if !(OwnerBundle is Object) {
		OwnerBundle := ConfigTransitionRetainedBarrier()
		if !(OwnerBundle is Object) {
			OwnerBundle := LLM_Menu_AcquireLifecycleBundle()
			OwnBundle := OwnerBundle is Object
		}
	}
	if !(OwnerBundle is Object) {
		try LoggerError("Lifecycle", "Reload refused because another configuration transaction owns config.toml.")
		_SuspendHandoffFailure("config-lease", ConfigurationFile)
		return false
	}
	if !(_ConfigWriteLeaseSelectOwner(OwnerBundle,
			ConfigurationFile) is Object) {
		try LoggerError("Lifecycle", "Reload refused because its borrowed configuration bundle is stale or does not own the active path.")
		_SuspendHandoffFailure("config-owner", ConfigurationFile)
		if OwnBundle
			_ConfigWriteTerminalRelease(OwnerBundle)
		return false
	}
	; Quiesce retained native handles before reconciling stable shortcut
	; authority. A refused recovery aborts with no new hand-off debris.
	try {
		if !LLM_Menu_QuiesceTriggerForLifecycle(OwnerBundle) {
			try LoggerError("Lifecycle", "Reload refused because LLM trigger recovery is incomplete.")
			_SuspendHandoffFailure("llm-trigger-recovery", ConfigurationFile)
			return false
		}
		Path := A_IsSuspended ? _SuspendMarkerPath() : ""
		ReadyFn := _SuspendHandoffBeforeReload.Bind(Path)
		CommitFn := A_IsSuspended ? _SuspendHandoffCommitMarker.Bind(Path) : 0
		AbortFn := A_IsSuspended ? _SuspendHandoffCancelMarker.Bind(Path) : 0
		ReloadFn := ReloadTerminalInvoke.Bind(OwnerBundle, SuccessFn, Reload,
			CommitFn, AbortFn)
		return SuspendHandoffReload(A_IsSuspended, Path,
			_SuspendHandoffPrepareMarker, ReloadFn,
				ReadyFn, _SuspendHandoffFailure, _SuspendHandoffCancelMarker)
	} finally {
		if OwnBundle
			_ConfigWriteTerminalRelease(OwnerBundle)
	}
}

; Logs successful publication immediately before Reload. Destructive UI cleanup
; is deliberately NOT called here: OnExit can still refuse. It runs through the
; terminal hand-off only after the last refusal gate has accepted.
_SuspendHandoffBeforeReload(Path) {
		if (Path != "")
				try LoggerInfo("Lifecycle", "Reloading while suspended — inert pause intent prepared for '{1}'.", Path)
}

_SuspendHandoffPrepareMarker(Path) {
	return SuspendHandoffPrepare(Path, FSWriteDurable, FSRead,
		FSAtomicMoveReplace, FSDelete)
}

_SuspendHandoffCommitMarker(Path) {
	return SuspendHandoffCommit(Path, FSRead, FSAtomicMoveReplace)
}

_SuspendHandoffCancelMarker(Path) {
	return SuspendHandoffAbort(Path, FSExists, FSDelete)
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
		SuspendHandoffDiscardPending(Path, FSExists, FSDelete,
			_SuspendHandoffFailure)
		return SuspendHandoffConsume(Path, A_IsSuspended,
				FSExists, FSMove, FSDelete, ToggleSuspend,
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
		_SuspendPending := true
		_SuspendPendingSince := A_TickCount
		LoggerWarn("Lifecycle", "Suspend deferred until custom-combination prefix keys are released (held: {1}).",
				_SuspendHeldPrefixKeys())
		SetTimer(_SuspendPendingPoll, 25)
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
	global _SpaceHoldInputHook, _OneShotShiftInputHook, _DeadKeyInputHook
	global _MagicKeyEditorInputHook
	if !_LifecycleSetNavEventOwnerSuspended(true)
		return false
	if IsSet(LLM_AuxInvalidate)
		try LLM_AuxInvalidate("suspend")
	; Release OS-level modifiers before even the lifecycle START log: LoggerStart
	; flushes synchronously to disk and a slow/locked config drive must not delay
	; the balancing Up. The same bounded owner drain is the first shutdown step.
	try TapHoldReleaseSyntheticKeys()
	; Invalidate every detached tray-root ticket before the first yielding log.
	; The requested generation remains retained for a fresh resume owner.
	if IsSet(_TrayRootOnSuspendEnter)
		try _TrayRootOnSuspendEnter()
	; The suspend/resume machine tears down a dozen subsystems that native
	; Suspend does not touch — InputHooks, timers and OnMessage handlers all
	; bypass it — and it emitted NOTHING. So "pause = tout éteint", the invariant
	; the whole teardown exists to uphold, was unfalsifiable from a log: a
	; feature still running while paused and a feature correctly stopped produced
	; identical output. This pair makes the bracket searchable, and an ENTER with
	; no matching entered line now marks a teardown that died halfway.
	LoggerStart("Lifecycle", "Entering suspend…")
	; Screenshot children are external processes: stopping their AHK polls does
	; not stop their disk or clipboard work. Retire every owner first, then ask
	; the shared process lifecycle to terminate each tree exactly once.
	if IsSet(GestureScreenshotCancelAll)
		try GestureScreenshotCancelAll("suspended")
	; Retire every deferred hotstring callback before any subsystem state is
	; cleared. Fired records remain queued and receive one fresh owner on resume;
	; derived render/near-miss callbacks from this generation become inert.
	if IsSet(HotstringPrefixWatcherOnSuspend) {
		try HotstringPrefixWatcherOnSuspend()
		catch as Err
			try LoggerError("Lifecycle", "Deferred hotstring suspend invalidation failed: {1}.", Err.Message)
	}
	; A clipboard-selection poll is timer-driven, so native Suspend does not
	; stop it. Cancel before any other teardown to restore the clipboard and
	; prevent its callback from injecting after pause.
	if IsSet(GetSelectionCancel)
		try GetSelectionCancel()
	if IsSet(_SpaceHoldInputHook) and IsObject(_SpaceHoldInputHook)
		try _SpaceHoldInputHook.Stop()
	if IsSet(_OneShotShiftInputHook) and IsObject(_OneShotShiftInputHook)
		try _OneShotShiftInputHook.Stop()
	if IsSet(_DeadKeyInputHook) and IsObject(_DeadKeyInputHook)
		try _DeadKeyInputHook.Stop()
	if IsSet(_MagicKeyEditorInputHook) and IsObject(_MagicKeyEditorInputHook)
		try _MagicKeyEditorInputHook.Stop()
		try TooltipHide("Suspend", true)
		try LLM_Tooltip_Hide(true)
		try LLM_Engine_CancelTimer()
		; Stop in-flight generation AND clear the prediction cache so a suggestion
		; produced before the pause cannot re-render after resume on a rebuilt
		; context ("pause = tout eteint" invariant). StopGeneration drops last_ctx /
		; last_results, bumps request_id, and cancels async streams.
		try LLM_Engine_StopGeneration()
		; Cancel the Ollama warm-up retry timer so it does not make background HTTP
		; calls while the driver is paused ("pause = tout éteint" invariant).
		try LLM_OllamaCancelWarmupRetry()
		; Stop the LLM pointer-dismiss poll timer + its pass-through mouse hotkeys.
		; SetTimer/Hotkey callbacks bypass native Suspend, so without this the
		; 50 ms MouseGetPos poll keeps firing for the whole pause ("pause = tout
		; éteint" invariant). Re-armed from Ergopti_OnSuspendResume when the bridge
		; is active.
		try _LLM_PointerWatch_Stop()
		; Disarm the 20 Hz canonical focus-snapshot poll. Its WM_GETTEXT transaction is
		; bounded, but every repeating SetTimer still bypasses native Suspend. Re-arm
		; from Ergopti_OnSuspendResume only when metrics are enabled.
		try MF_StopFocusRefresh()
		; Cancel in-flight background update checks so a stale async callback cannot
		; surface a TrayTip or rebuild the menu while paused ("pause = tout éteint").
		try _Updater_CancelAsyncChecks(UPDATER_CANCEL_REASON_SUSPEND)
		; A self-update owns a separate tree-owned staging process or an exact
		; suspended swap child. Cancel it on the suspend EVENT itself: sampling
		; A_IsSuspended from a later poll loses a rapid Pause→Resume pulse.
		try _Updater_CancelSelfUpdateForSuspend()
		; A metrics projection can be a multi-second detached AHK process.  Native
		; Suspend only disarms hotkeys, so explicitly kill its process tree rather
		; than letting SQLite/JSON work continue throughout a paused driver.
		try KLPF_CancelBuild("typing")
		try KLPF_CancelBuild("apps")
		try KLPF_CancelBuild("range:typing")
		; The selection probe is a persistent detached AHK process. Native Suspend
		; cannot stop it, so retire request ownership and its process tree before
		; entering the paused state.
		try UIASW_Stop("canceled")
		; Preserve an hours-long at-rest proof scan at its exact stream cursor while
		; disarming its one-shot slice/marker timers. Native Suspend does not stop
		; timers, so the migration must be lifecycle-owned explicitly.
		if IsSet(KL_Mig_OnSuspend)
				try KL_Mig_OnSuspend()
		try StopActivitySimulation()
		; AHK-12: A gesture left/right click-hold (SendEvent "{LButton Down}") that
		; was in progress when the user pauses the driver outlives the suspend because
		; SetTimer callbacks bypass native Suspend — the button stays logically held
		; until the next mouse event. Release both hold states unconditionally here so
		; no synthetic button-down leaks into the suspended window ("pause = tout éteint").
	try GestureReleaseLeftClick()
	try GestureReleaseRightClick()
	; AHK-16: CapsWord keeps the hardware CapsLock LED lit (via UpdateCapsLockLED)
		; and continues arming its mouse-cancel HookDispatcher listeners even when the
		; driver is suspended — the LED misleads the user and the listeners fire through
		; native Suspend. DisableCapsWord resets CapsWordEnabled, unregisters mouse
		; listeners, and corrects the LED ("pause = tout éteint" invariant).
		if IsSet(DisableCapsWord)
				try DisableCapsWord()
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
				try HSE_HardReset()
		global _LLM_Deps_PollTimer
		if IsSet(_LLM_Deps_PollTimer)
				try SetTimer(_LLM_Deps_PollTimer, 0)
		LoggerSuccess("Lifecycle", "Suspend entered — all suspend-bypassing subsystems torn down.")
		return true
}
Ergopti_OnSuspendResume() {
		LoggerStart("Lifecycle", "Resuming from suspend…")
		NavEventOwnerReady := _LifecycleSetNavEventOwnerSuspended(false)
		; Transfer any pre-pause fire batch to one new timer owner only after native
		; Suspend has been lifted. A stale pre-pause callback cannot pass the new
		; generation even if it was already queued in the message pump.
		if IsSet(HotstringPrefixWatcherOnResume) {
				try HotstringPrefixWatcherOnResume()
				catch as Err
						try LoggerError("Lifecycle", "Deferred hotstring resume transfer failed: {1}.", Err.Message)
		}
		if IsSet(_ResetPrefixBuffer)
				try _ResetPrefixBuffer()
		; Replay a prefix-index rebuild deferred because it was requested while
		; suspended (a live hotstring section toggle during pause), so the preview
		; index re-syncs with the engine registry instead of staying diverged.
		global _PrefixIndexRebuildPending
		if IsSet(_PrefixIndexRebuildPending) and _PrefixIndexRebuildPending {
				_PrefixIndexRebuildPending := false
				if IsSet(HotstringPrefixWatcherRebuildIndex)
						try HotstringPrefixWatcherRebuildIndex()
		}
		global _LLM_Deps_PollTimer, _LLM_Deps_Checking
		if IsSet(_LLM_Deps_PollTimer) and IsSet(_LLM_Deps_Checking) and _LLM_Deps_Checking
				try SetTimer(_LLM_Deps_PollTimer, 3000)
		; Re-arm the LLM pointer-dismiss watcher stopped in Ergopti_OnSuspendEnter,
		; but only when the bridge is still active — _LLM_PointerWatch_Start is a
		; no-op when already armed, so this is safe to call unconditionally on the
		; active path.
		global _LLM_Bridge_Active
		if IsSet(_LLM_Bridge_Active) and _LLM_Bridge_Active
				try _LLM_PointerWatch_Start()
		; Re-arm the metrics focus poll disarmed in Ergopti_OnSuspendEnter, gated on
		; the same feature flag that armed it at boot. Without this the cache would
		; stay frozen after the first pause and every metrics privacy filter would
		; read a stale foreground window for the rest of the session.
		if IsSet(MetricsShortcuts) and MetricsShortcuts.enabled
				try MF_StartFocusRefresh()
		; Range-worker cancellation is delivered while native Suspend is active,
		; when WebView mutation is forbidden. Release the page-side request latch
		; now, on the first resumed stack, instead of leaving every later filter
		; click blocked behind loading_data until the watchdog expires.
		if IsSet(KLWV_OnSuspendResume)
				try KLWV_OnSuspendResume()
		; Re-arm exactly one migration continuation (active slice, durable marker,
		; or deferred posture sync) after all pause guards have been lifted.
		if IsSet(KL_Mig_OnResume)
				try KL_Mig_OnResume()
		; Deferred dependency callbacks are not allowed to rebuild the tray or
		; start the bridge while native Suspend is active. Replay the pending work
		; only after the resume transition has completed.
		if IsSet(LLM_Menu_OnResume)
				try LLM_Menu_OnResume()
		; Drain the exact manual updater terminals retained across pause only after
		; native Suspend has lifted. Background work remains intentionally silent.
		if IsSet(Updater_OnSuspendResume)
				try Updater_OnSuspendResume()
		; Suspend terminates the persistent UIA process. Warm its lightweight
		; source entry again after the transition so the first selection-wrap after
		; resume cannot race a cold worker; UIASW_Start remains feature/suspend safe.
		if IsSet(Features) and Features.Has("shortcuts")
			and Features["shortcuts"].Has("wrap_text_if_selected")
			and Features["shortcuts"]["wrap_text_if_selected"]
			try SetTimer(UIASW_Start, -1)
		if NavEventOwnerReady
				LoggerSuccess("Lifecycle", "Resumed — suspend-bypassing subsystems restarted.")
		else
				LoggerError("Lifecycle", "Resume completed with the navigation event owner unavailable; its retained plan will retry on the next lifecycle transition.")
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
						TriggerService := 0
						if IsSet(_TrayRootServiceRetained)
								RootService := _TrayRootServiceRetained
						if IsSet(LLM_Menu_ServiceTriggerRecovery)
								TriggerService := LLM_Menu_ServiceTriggerRecovery
						_TrayRootServiceRetainedWork(
								RootService, TriggerService)
				}
				return
		}
		if _TransitionBusy
				return
		_TransitionBusy := true
		try {
				_LLM_NavEventOwnerApplyExternalSuspendTransition(
					A_IsSuspended, Ergopti_OnSuspendEnter,
					Ergopti_OnSuspendResume, Suspend, UpdateTrayIcon)
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
Ergopti_OnShutdown(reason, code) {
		; Button holds are OS state, so release them before any gate may keep this
		; process alive. Do not free the WinEvent hook yet: a refused OnExit must
		; return to a fully functional gesture subsystem.
		try GestureReleaseLeftClick()
		try GestureReleaseRightClick()
		NavOwnerReady := false
		try NavOwnerReady := LLM_NavEventOwner_PrepareShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Navigation-owner shutdown preflight failed: {1}.", Err.Message)
		if !NavOwnerReady {
			try LoggerError("Lifecycle", "Shutdown refused because native keyboard receipts or holds remain owned.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return 1
		}
		ShutdownTerminal := false
		try {
		TerminalHandoff := ReloadTerminalHandoffClaim(reason)
		RetainedTransition := (TerminalHandoff is Map)
			? false : ConfigTransitionRetainedBarrier()
		ShutdownOwners := (TerminalHandoff is Map)
			? TerminalHandoff["bundle"]
			: ((RetainedTransition is Object)
				? RetainedTransition : LLM_Menu_AcquireLifecycleBundle())
		if !(ShutdownOwners is Object) {
			try LoggerError("Lifecycle", "Shutdown refused because another configuration transaction is still active.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return 1
		}
		OwnShutdownBundle := !(TerminalHandoff is Map)
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
			return 1
		}
		FullSaveSettled := false
		try FullSaveSettled := _ConfigFullSaveSettleTerminal(ShutdownOwners)
		catch as Err
			try LoggerError("Lifecycle", "Terminal full-save settlement failed: {1}.", Err.Message)
		if !((FullSaveSettled is Integer) && FullSaveSettled == 1) {
			try LoggerError("Lifecycle", "Shutdown refused because an accepted full configuration save remains non-durable.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return 1
		}
		TriggerJournalCanExit := false
		; AutoHotkey documents OnExit callbacks as non-interruptible by hotkeys,
		; menu callbacks and timers. Once native+WAL quiescence succeeds here, no
		; fresh trigger edit can enter before the remaining shutdown gates finish.
		; A byte-preserved malformed trigger WAL must not make ordinary Quit
		; impossible. Reload and every destructive transition remain strict: only a
		; non-Reload process exit may accept read-only quarantine and leave the
		; artifact for the next visible boot diagnostic.
		AllowReadOnlyTriggerJournal := !(TerminalHandoff is Map)
			&& StrCompare(reason, "Reload", true) != 0
		try TriggerJournalCanExit := LLM_Menu_QuiesceTriggerForLifecycle(
			ShutdownOwners, 0, 0, 0, "", AllowReadOnlyTriggerJournal)
		catch as Err
			try LoggerError("Lifecycle", "LLM trigger journal shutdown recovery failed: {1}.", Err.Message)
		if !((TriggerJournalCanExit is Integer) && TriggerJournalCanExit == 1) {
			try LoggerError("Lifecycle", "Shutdown refused because LLM trigger journal recovery is incomplete.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return 1
		}
		RecoveryCanExit := false
		try RecoveryCanExit := _Updater_RecoveryMayEnterTerminalShutdown()
		if !RecoveryCanExit {
			try LoggerError("Lifecycle", "Shutdown refused while the recovery executable remains the sole durable driver owner.")
			try _Updater_DeferExitIntentRetry()
			try _Updater_DeferRecoveryHandoffRetry()
			return 1
		}
		; Publish only the reversible keylogger bypass before draining. OnExit is
		; non-interruptible, so the InputHook can remain installed until every
		; refusal-capable terminal operation has accepted. A refused Reload then
		; returns to a complete driver instead of one with its producers stopped.
		try KL_BeginShutdown()
		catch as Err
			try LoggerError("Lifecycle", "Keylogger shutdown lease failed: {1}.", Err.Message)
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
			return 1
		}
		; The reload-specific durable commit is still allowed to refuse. It must
		; precede every producer stop; ReloadTerminalInvoke will run the matching
		; abort callback when this OnExit returns nonzero later in the preflight.
		if (TerminalHandoff is Map) {
			TerminalCommitted := false
			try TerminalCommitted := ReloadTerminalHandoffCommit(TerminalHandoff)
			catch as Err
				try LoggerError("Lifecycle", "Reload terminal commit failed before teardown: {1}.", Err.Message)
			if !TerminalCommitted {
				try KL_CancelShutdown()
				try _Updater_DeferExitIntentRetry()
				try _Updater_DeferRecoveryHandoffRetry()
				return 1
			}
		}
		; FinalExit and ownership transfer remain refusal gates, but all live
		; producers are still installed. A refusal rolls back the terminal handoff
		; in ReloadTerminalInvoke and withdraws the keylogger lease below.
		FinalExitAuthorized := false
		try FinalExitAuthorized := _Updater_SignalFinalExitForIntent()
		catch as Err
			try LoggerError("Lifecycle", "Updater FinalExit authorization failed: {1}.", Err.Message)
		if !FinalExitAuthorized {
			try LoggerError("Lifecycle", "Shutdown refused because the updater swap worker could not accept FinalExit authorization.")
			try KL_CancelShutdown()
			return 1
		}
		SwapOwnershipTransferred := false
		try SwapOwnershipTransferred := _Updater_TransferExitIntentAfterShutdownGates()
		catch as Err
			try LoggerError("Lifecycle", "Updater ownership transfer failed after shutdown gates: {1}.", Err.Message)
		if !SwapOwnershipTransferred {
			try LoggerError("Lifecycle", "Shutdown refused because the acknowledged updater child was no longer alive at ownership transfer.")
			try KL_CancelShutdown()
			return 1
		}
		RecoveryHandoffComplete := false
		try RecoveryHandoffComplete := _Updater_CompleteRecoveryHandoffOnExit()
		catch as Err
			try LoggerError("Lifecycle", "Recovery handoff failed before terminal teardown: {1}.", Err.Message)
		if !RecoveryHandoffComplete {
			try KL_CancelShutdown()
			try _Updater_DeferRecoveryHandoffRetry()
			return 1
		}
		ShutdownTerminal := true
		; No code below this point may refuse shutdown. All fallible authority
		; transfers have accepted while the live driver was still intact.
		try GestureScreenshotCancelAll("shutdown")
		try HotstringPrefixWatcherStop()
		try HotstringPrefixWatcherOnShutdown()
		try KL_Stop()
		try UIASW_Stop("canceled")
		try LLM_NavEventOwner_Stop(false, true)
		try CrashReportWorker_StopAll()
		try HookDispatcher.Stop()
		try KLWV_CloseAll()
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
; Build the full tray menu off the boot critical path (armed after "ready").
; initMenu stages every subtree while the old root remains live and enters
; Critical only for the short root replacement. UpdateTrayIcon runs last, once
; MenuSuspend exists.
_TrayRootBuildBoot(PublishAuthorizeFn) {
	global _DriverReady, _LangMenuBuildPending, LANG_MENU_DEFER_MS
	global _LLM_Menu, LLM_MENU_BUILD_DEFER_MS
	_SavedReady := _DriverReady
	_DriverReady := false
	try {
		InitSubMenus()
		Published := initMenu(PublishAuthorizeFn)
	} finally {
		_DriverReady := _SavedReady
	}
	if !((Published is Integer) and Published == 1)
		return false
	UpdateTrayIcon()
	if _LangMenuBuildPending
		SetTimer(BuildLanguageMenuDeferred, -LANG_MENU_DEFER_MS)
	BootProfile_Mark("Tray menu built (deferred, off time-to-ready)")
	; The independent LLM timer used to preempt this root worker, invalidate
	; its generation, and force a second full InitSubMenus scan. Arm the cheap
	; OFF-state population only after this root and its boot finalizer publish.
	; A retained/retried boot worker reaches the same ownership seam.
	if _TrayRootScheduleBootProjectionIfDisabled(
			_LLM_Menu["enabled"], LLM_Menu_RequestBuild.Bind("boot"),
			SetTimer, LLM_MENU_BUILD_DEFER_MS) {
		try LoggerDebug("TrayMenu",
			"Deferred root published; arming boot IA submenu build in {1} ms.",
			LLM_MENU_BUILD_DEFER_MS)
	}
	return true
}

BuildTrayMenuDeferred() {
	; Warm both filesystem-backed caches before the coordinator starts a worker.
	_HS_PreScanExtensions()
	_HS_PreScanPersonal()
	try {
		BuildAccepted := RebuildTrayMenu(0, _TrayRootBuildBoot, false)
		if !((BuildAccepted is Integer) and BuildAccepted == 1) {
			try LoggerError("TrayMenu", "Deferred tray-menu build was retained for retry.")
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
				MsgBox(Format(t("ergopti.windowspy_not_found"), spyPath))
}
ActivateListVars(*) {
		ListVars()
}
ActivateKeyHistory(*) {
		KeyHistory()
}
ShowHealthCheck(*) {
		HealthCheck_ShowWindow()
}
