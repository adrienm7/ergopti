; lib/lifecycle.ahk

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

; File name of the one-shot marker that carries a pause across a Reload. It sits
; next to config.toml (so a paths.toml relocation is honoured for free) and is
; CONSUMED the moment it is read — a crash between writing it and restoring the
; pause must never wedge the driver suspended on every future boot.
global SUSPEND_MARKER_FILENAME := "suspend_restore.marker"

; Absolute path of the suspend hand-off marker, derived from the resolved
; configuration file so it always follows the user's real config directory.
_SuspendMarkerPath() {
		global ConfigurationFile
		if !IsSet(ConfigurationFile) or (ConfigurationFile == "")
				return ""
		SplitPath(ConfigurationFile, , &Dir)
		return Dir . "\" . SUSPEND_MARKER_FILENAME
}

; Reloads the driver WITHOUT discarding the user's pause.
;
; AHK's Reload starts a fresh process that is never suspended, and the tray menu
; is the one surface that stays fully clickable while paused — native Suspend
; only disarms hotkeys and hotstrings, never a tray WM_COMMAND. So every menu
; action that persists a setting and reloads used to come back fully armed, with
; the « Suspendre » checkmark gone and nothing whatsoever in the logs. Persist
; the state first, then reload; _SuspendRestoreFromMarker re-applies it on the
; next boot. A marker that cannot be written is reported as an ERROR rather than
; swallowed: silently resuming a driver the user paused is exactly the failure
; this exists to remove.
ReloadPreservingSuspend() {
		if A_IsSuspended {
				Path := _SuspendMarkerPath()
				Written := false
				if (Path != "") {
						try {
								Handle := FileOpen(Path, "w")
								if IsObject(Handle) {
										Handle.Write("1")
										Handle.Close()
										Written := true
								}
						}
				}
				if Written
						LoggerInfo("Lifecycle", "Reloading while suspended — pause handed off via '{1}'.", Path)
				else
						LoggerError("Lifecycle", "Reloading while suspended but the pause marker could NOT be written to '{1}' — the driver will come back ARMED.", Path)
		}
		Reload()
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
		if (Path == "") or !FileExist(Path)
				return
		try FileDelete(Path)
		; Already suspended means the user beat the restore to it (a tray pause in
		; the boot window); the marker is spent and there is nothing left to do.
		if A_IsSuspended
				return
		LoggerInfo("Lifecycle", "Restoring the pause that a menu-driven Reload would otherwise have dropped.")
		ToggleSuspend()
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
		Suspend(1)
		_SuspendStateWatchdog()
}
Ergopti_OnSuspendEnter() {
	global _SpaceHoldInputHook, _OneShotShiftInputHook, _DeadKeyInputHook
	; The suspend/resume machine tears down a dozen subsystems that native
	; Suspend does not touch — InputHooks, timers and OnMessage handlers all
	; bypass it — and it emitted NOTHING. So "pause = tout éteint", the invariant
	; the whole teardown exists to uphold, was unfalsifiable from a log: a
	; feature still running while paused and a feature correctly stopped produced
	; identical output. This pair makes the bracket searchable, and an ENTER with
	; no matching entered line now marks a teardown that died halfway.
	LoggerStart("Lifecycle", "Entering suspend…")
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
		; Disarm the 20 Hz metrics focus poll. Same class as the pointer watch above:
		; a repeating SetTimer bypasses native Suspend, and its WinGetTitle probe is a
		; blocking WM_GETTEXT round-trip against the foreground window. Re-armed from
		; Ergopti_OnSuspendResume when metrics are enabled.
		try MF_StopFocusRefresh()
		; Cancel in-flight background update checks so a stale async callback cannot
		; surface a TrayTip or rebuild the menu while paused ("pause = tout éteint").
		try _Updater_CancelAsyncChecks()
		; A metrics projection can be a multi-second detached AHK process.  Native
		; Suspend only disarms hotkeys, so explicitly kill its process tree rather
		; than letting SQLite/JSON work continue throughout a paused driver.
		try KLPF_CancelBuild("typing")
		try KLPF_CancelBuild("apps")
		try KLPF_CancelBuild("range:typing")
		try StopActivitySimulation()
		; AHK-12: A gesture left/right click-hold (SendEvent "{LButton Down}") that
		; was in progress when the user pauses the driver outlives the suspend because
		; SetTimer callbacks bypass native Suspend — the button stays logically held
		; until the next mouse event. Release both hold states unconditionally here so
		; no synthetic button-down leaks into the suspended window ("pause = tout éteint").
	try GestureReleaseLeftClick()
	try GestureReleaseRightClick()
	; A tap-hold may have armed a synthetic modifier before entering KeyWait.
	; Suspend does not cancel that pseudo-thread, so release its tracked keys
	; immediately instead of waiting for the eventual physical key-up/finally.
	try TapHoldReleaseSyntheticKeys()
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
}
Ergopti_OnSuspendResume() {
		LoggerStart("Lifecycle", "Resuming from suspend…")
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
		; Deferred dependency callbacks are not allowed to rebuild the tray or
		; start the bridge while native Suspend is active. Replay the pending work
		; only after the resume transition has completed.
		if IsSet(LLM_Menu_OnResume)
				try LLM_Menu_OnResume()
		LoggerSuccess("Lifecycle", "Resumed — suspend-bypassing subsystems restarted.")
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
				try _SuspendRestoreFromMarker()
		}
		if (A_IsSuspended == _LastSuspendState)
				return
		if _TransitionBusy
				return
		_TransitionBusy := true
		try {
				_LastSuspendState := A_IsSuspended
				UpdateTrayIcon()
				if A_IsSuspended
						Ergopti_OnSuspendEnter()
				else
						Ergopti_OnSuspendResume()
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
; detached PowerShell child, and swap_update.cmd is launched only from
; _Updater_PollDownloadAsync, so a Reload here used to orphan the download and
; the user's "Update now" click silently installed nothing
; (updater-staging-worker-orphaned-on-exit). Every future subsystem with that
; shape belongs in this handler too.
Ergopti_OnShutdown(reason, code) {
		try KL_Stop()
		try HotstringPrefixWatcherStop()
		try HookDispatcher.Stop()
		try KLWV_CloseAll()
		try OllamaWV_Close()
		try _Updater_AbortStagingOnExit()
		return 0
}
; Build the full tray menu off the boot critical path (armed after "ready").
; initMenu stages every subtree while the old root remains live and enters
; Critical only for the short root replacement. UpdateTrayIcon runs last, once
; MenuSuspend exists.
BuildTrayMenuDeferred() {
		global _DriverReady, _LangMenuBuildPending, LANG_MENU_DEFER_MS
		; Same rationale for the bundled-extensions scan: it does DirExist/Loop Files/
		; FileRead over the extensions tree. Warm its cache off-Critical too so the
		; under-Critical _HS_Extensions call hits only the warm cache.
		_HS_PreScanExtensions()
		; Warm the personal-hotstrings prescan cache BEFORE taking Critical. The scan
		; recurses the personal-hotstrings dir and parses every ext TOML — unbounded
		; file I/O that, on a cloud-synced config dir (OneDrive Files On-Demand) or a
		; spun-down drive, can stall for seconds. Critical("On") starves the LL keyboard
		; hook for its whole duration, so doing that I/O under Critical turns a one-time
		; menu build into a multi-second keyboard freeze on the first keystrokes after
		; launch. _HS_PreScanPersonal is cache-guarded (idempotent once
		; _HS_PreScanPersonalCacheLoaded is set), so the InitSubMenus call below hits
		; only the warm cache — the Critical span then covers ONLY the pure Win32
		; Menu.Add / RegisterMenuItem pass that must be one uninterrupted block.
		_HS_PreScanPersonal()
	try {
		InitSubMenus()
		; Build everything EXCEPT the 21-locale language submenu. Forcing
		; _DriverReady false preserves the deferred language-menu behaviour.
				_SavedReady := _DriverReady
				_DriverReady := false
				; Restore _DriverReady even if initMenu() throws (I/O error, parse failure…);
				; leaving it false permanently would silently block all async saves thereafter.
				try initMenu()
				finally _DriverReady := _SavedReady
				UpdateTrayIcon()
	} catch as e {
		try LoggerError("TrayMenu", "Deferred tray-menu build failed: {1}", e.Message)
	}
		if _LangMenuBuildPending
				SetTimer(BuildLanguageMenuDeferred, -LANG_MENU_DEFER_MS)
		BootProfile_Mark("Tray menu built (deferred, off time-to-ready)")
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
