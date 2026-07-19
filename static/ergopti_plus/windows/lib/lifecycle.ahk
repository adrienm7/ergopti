; lib/lifecycle.ahk

; ==============================================================================
; MODULE: Driver Lifecycle, Tray & Debug Actions
; DESCRIPTION:
; Suspend/resume (ToggleSuspend, Ergopti_OnSuspendEnter/Resume, the suspend-state
; watchdog and prefix drain), shutdown (Ergopti_OnShutdown), the deferred tray
; menu build + icon update, and the debug/control actions (reload, exit, WindowSpy,
; ListVars, KeyHistory, healthcheck, edit). Extracted verbatim from ErgoptiPlus.ahk
; (P4 entrypoint decomposition) and #Include'd in place; functions are hoisted so
; their OnExit/SetTimer/hotkey call sites in the entry boot section are unaffected.
; ==============================================================================

ActivateEdit(*) {
    Edit()
}
; Physical keys registered as an AHK custom-combination PREFIX (the left side of
; a "&" hotkey definition, e.g. "SC138 & SC01C::" in script_altgr_hotkeys.ahk or
; "SC038 & SC03A::" in modules/shortcuts/base_modifier.ahk). AHK's custom-
; combination prefix-down flag latches across Suspend() and cannot be cleared by
; synthetic events -- see _SuspendDrainPrefix below. Single source of truth: add
; any NEW custom-combination prefix key here so it is drained automatically
; before every future suspend instead of leaving a THIRD un-drained sibling for
; the same latch bug to hide in (feedback_ahk_suspend_prefix_latch, F42).
global SUSPEND_CUSTOM_COMBO_PREFIX_KEYS := ["SC138", "SC038"]
global _SuspendPending := false

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
; _SuspendDrainPrefix before a Suspend, the one transition that freezes it).
_ReleasePhantomModifiers() {
    Send("{Blind}{LCtrl up}{RCtrl up}{LAlt up}{RAlt up}{LShift up}{RShift up}{LWin up}{RWin up}{SC138 up}")
}
ToggleSuspend(*) {
    global _SuspendPending
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
    LoggerWarn("Lifecycle", "Suspend deferred until custom-combination prefix keys are released.")
    SetTimer(_SuspendPendingPoll, 25)
}
_SuspendPendingPoll() {
    global _SuspendPending
    if !_SuspendPending or A_IsSuspended {
        SetTimer(_SuspendPendingPoll, 0)
        return
    }
    if !_SuspendPrefixesAreClear()
        return
    _SuspendPending := false
    SetTimer(_SuspendPendingPoll, 0)
    Suspend(1)
    _SuspendStateWatchdog()
}
Ergopti_OnSuspendEnter() {
	global _SpaceHoldInputHook, _OneShotShiftInputHook, _DeadKeyInputHook
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
    global _LLM_Deps_PollTimer
    if IsSet(_LLM_Deps_PollTimer)
        try SetTimer(_LLM_Deps_PollTimer, 0)
}
Ergopti_OnSuspendResume() {
    if IsSet(_ResetPrefixBuffer)
        try _ResetPrefixBuffer()
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
    ; Deferred dependency callbacks are not allowed to rebuild the tray or
    ; start the bridge while native Suspend is active. Replay the pending work
    ; only after the resume transition has completed.
    if IsSet(LLM_Menu_OnResume)
        try LLM_Menu_OnResume()
}
_SuspendStateWatchdog() {
    global _LastSuspendState
    if (A_IsSuspended == _LastSuspendState)
        return
    _LastSuspendState := A_IsSuspended
    UpdateTrayIcon()
    if A_IsSuspended
        Ergopti_OnSuspendEnter()
    else
        Ergopti_OnSuspendResume()
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
Ergopti_OnShutdown(reason, code) {
    try KL_Stop()
    try HotstringPrefixWatcherStop()
    try HookDispatcher.Stop()
    try KLWV_CloseAll()
    try OllamaWV_Close()
    return 0
}
; Build the full tray menu off the boot critical path (armed after "ready"). The
; build runs under Critical so it is ONE uninterrupted pass — a tray click queued
; during boot cannot pump the message loop mid-build and paint a half-built menu
; (the documented "menu shows only the first items" bug). No Sleep inside, so it is
; safe to hold Critical across it. UpdateTrayIcon runs last, once MenuSuspend exists.
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
    _MenuBuildCritical := Critical("On")
    try {
        ; Clear the dispatch bypass Maps BEFORE the InitSubMenus()/initMenu()
        ; re-registration pass. AHK reuses freed menu-item IDs after Menu.Delete();
        ; a stale entry left in the Maps could bind a reused ID to a different
        ; item's callback and fire the WRONG action on a dropped-click retry (see
        ; menu_dispatcher.ahk).
        MenuDispatcher_Reset()
        InitSubMenus()
        ; Build everything EXCEPT the 21-locale language submenu (~219 ms of Win32 menu
        ; registration + flag-icon loads). Forcing _DriverReady false makes initMenu
        ; DEFER that submenu (its boot behaviour) so THIS post-ready build stays ~157 ms
        ; instead of ~420 ms — small enough not to lag the first keystrokes after launch.
        ; The language submenu is then armed on its own timer below, exactly as the
        ; original boot path did, so it never piles onto this Critical section.
        _SavedReady := _DriverReady
        _DriverReady := false
        ; Restore _DriverReady even if initMenu() throws (I/O error, parse failure…);
        ; leaving it false permanently would silently block all async saves thereafter.
        try initMenu()
        finally _DriverReady := _SavedReady
        UpdateTrayIcon()
    } finally {
        ; A failed submenu/menu build must never strand the low-level keyboard
        ; hook in Critical mode for the rest of the session.
        Critical(_MenuBuildCritical)
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
ActivateReload(*) {
    Reload()
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
