; Last modified on 2026-04-23 at 00:00 (UTC+2)
#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
; No process starts with a tray icon: the driver path reveals it once the custom
; icon and the safe bootstrap menu are in place, and a detached worker never does.
#NoTrayIcon

; The driver re-runs this entry (or its compiled executable) with a worker flag
; for the detached keylogger-prefetch and UIA-selection workers. AutoHotkey
; creates a script's tray icon, main window and load-time hotkeys BEFORE its
; first statement runs, so each worker looked like a second driver: an
; "ErgoptiPlus" tray icon (the default green H in source mode), the driver's
; exact window title, which Reload and #SingleInstance search to find the
; instance they close, and every static hotkey armed in a second keyboard hook.
; Before any other statement a worker therefore releases those hotkeys and takes
; a title of its own. Both predicates read only A_Args and are hoisted.
global _DriverIsDetachedWorker := KLPF_IsWorkerInvocation() || UIASW_IsWorkerInvocation()
if _DriverIsDetachedWorker {
	Suspend(true)
	; A pure HWND reaches the hidden main window whatever DetectHiddenWindows
	; says, and ProcessExist() with no argument is this process's own PID.
	WinSetTitle("ErgoptiPlus detached worker " . ProcessExist(), A_ScriptHwnd)
}

BootProfile_Stamp("Auto-execute entered")

SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

; The real-process startup smoke runs this exact entry point under a uniquely
; named wrapper and an isolated config tree. It exists because parsing the full
; include graph cannot detect an auto-execute read of a global whose owning
; include has not executed yet. Production launches leave the variable empty.
global _DriverStartupSmokeDir := EnvGet("ERGOPTI_STARTUP_SMOKE_DIR")

; A rollback recovery executable is a byte-for-byte copy of the last known-good
; compiled driver named ``Current.exe.<guid>.recovery.exe``. Detect it before the
; mutex and before any hook can be registered. The helper is defined in the
; updater include below and is available here because AHK hoists function
; definitions across the merged #Include graph.
global _UpdaterRecoveryShapedTarget := A_IsCompiled
	? _Updater_RecoveryTargetForExecutable(A_ScriptFullPath) : ""
global _UpdaterRecoveryDescriptor := A_IsCompiled
	? _Updater_LoadRecoveryDescriptor(A_ScriptFullPath) : 0
; A recovery-shaped filename is data, never authority. A stale artifact that no
; longer owns its tiny transaction claim exits before the mutex, Bundle_Init or
; any message pump, so double-clicking it cannot downgrade a healthy driver.
if (_UpdaterRecoveryShapedTarget != ""
	and !(_UpdaterRecoveryDescriptor is Map))
	ExitApp(0)
if (_UpdaterRecoveryDescriptor is Map)
	try A_TrayMenu.Delete()
global _UpdaterRecoveryPublishTarget := (_UpdaterRecoveryDescriptor is Map)
	? _UpdaterRecoveryDescriptor["Target"] : ""
global _UpdaterRecoveryPublishStage := (_UpdaterRecoveryDescriptor is Map)
	? _UpdaterRecoveryDescriptor["Stage"] : ""
global _UpdaterRecoveryClaimPath := (_UpdaterRecoveryDescriptor is Map)
	? _UpdaterRecoveryDescriptor["Claim"] : ""
global _UpdaterRecoveryCleanupPath := ""
if A_IsCompiled {
	try _UpdaterRecoveryCleanupPath := _Updater_RecoveryCleanupPathForCurrent(
		A_ScriptFullPath, EnvGet("ERGOPTI_UPDATER_RECOVERY_CLEANUP"))
	; The value is single-use inheritance from the recovery process. Clear the
	; parent copy before any later child is spawned.
	try EnvSet("ERGOPTI_UPDATER_RECOVERY_CLEANUP", "")
}
global _UpdaterRecoveryPublishAttemptCount := 0
global _UpdaterRecoveryCleanupAttemptCount := 0
global _UpdaterRecoveryHandoffPending := false
global _UpdaterRecoveryExitInvocation := false
global _UpdaterRecoverySuspendPrepared := false
global _UpdaterInheritedBootReadyName := ""
if A_IsCompiled {
	try _UpdaterInheritedBootReadyName := _Updater_ValidateBootReadyEventName(
		EnvGet("ERGOPTI_UPDATER_BOOT_READY"))
	try EnvSet("ERGOPTI_UPDATER_BOOT_READY", "")
}
global _UpdaterInheritedSwapFailurePath := ""
global _UpdaterInheritedSwapFailure := ""
if A_IsCompiled {
	try {
		_UpdaterInheritedSwapFailurePath := EnvGet(
			"ERGOPTI_UPDATER_SWAP_TERMINAL")
		_UpdaterInheritedSwapFailure := _Updater_LoadSwapFailureTerminal(
			_UpdaterInheritedSwapFailurePath)
		if (_UpdaterInheritedSwapFailure == "")
			_UpdaterInheritedSwapFailurePath := ""
	}
	try EnvSet("ERGOPTI_UPDATER_SWAP_TERMINAL", "")
}

; --- Single-owner gate: establish exclusivity BEFORE any hook/log/message pump ---
; #SingleInstance Force only replaces the previous instance at the END of THIS
; script's load (~875-1460 ms parse), and terminating a hung/dialog-blocked old
; instance is best-effort — so during a rapid double-launch two processes can
; briefly co-own the keyboard hook and the log (observed in the field: interleaved
; duplicate log lines for minutes, and a boot killed mid-registration with hotkeys
; already armed). Acquire a named session-local mutex here — the first auto-execute
; statement, before the Bundle_Init RunWait step pumps messages — and, when a
; previous instance still owns it, WAIT a bounded time for it to exit before we
; register anything. Only WAIT_OBJECT_0 and WAIT_ABANDONED establish ownership;
; contention and every ambiguous native failure terminate before bootstrap. An
; acquired handle is intentionally never closed: the OS releases the mutex when
; this process exits, so a successor's wait unblocks the instant we die.
;
; EXEMPT: detached keylogger-prefetch and UIA-selection workers. The driver
; deliberately re-runs this entry with /force and a worker flag; those workers
; register no hook and no log owner, and hide their tray icon first thing,
; so it is not what this gate exists to prevent. But the gate is the FIRST
; auto-execute statement while the worker's own gate sits ~300 lines below, so
; every worker spawned while the driver is alive blocked the full wait on the
; live driver's mutex, timed out and ExitApp(0)'d before reaching its main —
; the projection could never publish. _DriverIsDetachedWorker, resolved at the
; top of this file, is the single definition of a worker invocation.
#Include infra/single_instance_gate.ahk
global DRIVER_MUTEX_NAME := "Local\ErgoptiPlusDriver"
global DRIVER_MUTEX_WAIT_MS := 3000 ; max boot delay while a previous instance exits
global _DriverMutexHandle := 0
global _DriverMutexWait := 0xFFFFFFFF
global _DriverMutexError := 0
global _DriverMutexDecision := DRIVER_MUTEX_EXEMPT
if !(_DriverIsDetachedWorker || _DriverStartupSmokeDir != "") {
	_DriverMutexHandle := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "Str", DRIVER_MUTEX_NAME, "Ptr")
	if !_DriverMutexHandle
		_DriverMutexError := DllCall("kernel32\GetLastError", "UInt")
	else {
		; Take ownership, waiting (bounded) for any previous owner to release it.
		_DriverMutexWait := DllCall("WaitForSingleObject", "Ptr", _DriverMutexHandle,
			"UInt", DRIVER_MUTEX_WAIT_MS, "UInt")
		if DriverMutex_WaitFailed(_DriverMutexWait)
			_DriverMutexError := DllCall("kernel32\GetLastError", "UInt")
	}
	_DriverMutexDecision := DriverMutex_Decide(
		_DriverMutexHandle, _DriverMutexWait)
	if (_DriverMutexDecision != DRIVER_MUTEX_ACQUIRED) {
		; WAIT_TIMEOUT yields to the live owner. A null handle, WAIT_FAILED, or an
		; unknown native state exits as a startup failure. Neither path may reach a
		; hook: continuing without proven ownership is exactly what lets a rapid
		; multi-launch put N keyboard owners on one machine.
		; Written directly to disk, NOT through the logger. This runs as the
		; second statement of the script: LoggerInit has not run, so
		; LOGGER_LOG_PATH is empty and the logger's severity flags are unset —
		; LoggerWarn would raise UnsetError, the bare `try` would swallow it, and
		; the line would vanish. Then ExitApp fires immediately, so even a queued
		; line would never be flushed. That is why multi-instance contention has
		; been invisible to three audits: the one event that proves it happened
		; was unwritable by construction.
		;
		; Calling LoggerInit() here instead would be worse. It runs
		; _LoggerInitSubFiles, which DELETES any sub-file whose mtime is a
		; previous day — so a yielding instance would destroy the LIVE owner's
		; gestures/layout/tray sub-logs on its way out.
		;
		; LoggerAppendBootstrapLine writes to bootstrap.log in the default logs
		; folder, which needs nothing but %LOCALAPPDATA%: it is reachable before
		; any path resolution and never collides with the live owner's dated
		; log files.
		try {
			_MutexOutcome := (_DriverMutexDecision = DRIVER_MUTEX_YIELD)
				? "Another instance owns the single-owner mutex after "
					. DRIVER_MUTEX_WAIT_MS . " ms"
				: "Single-owner mutex acquisition failed (wait="
					. Format("0x{:08X}", _DriverMutexWait)
					. ", error=" . _DriverMutexError . ")"
			_MutexSeverity := (_DriverMutexDecision = DRIVER_MUTEX_YIELD)
				? "WARNING" : "ERROR"
			LoggerAppendBootstrapLine(_MutexSeverity, "ErgoptiPlus",
				_MutexOutcome . "; terminating without registering any hook.")
		}
		ExitApp(_DriverMutexDecision = DRIVER_MUTEX_YIELD ? 0 : 1)
	}
}

BootProfile_Stamp("Single-owner gate completed")

; Single source of truth for the driver's baseline (non-boosted) process
; priority class. Every restore site outside a transient boost — LLM_Menu_Init's
; defensive reset, LLM_Deps_Fail, LLM_Deps_Cancel, _LLM_Deps_OnPollProbeResult —
; MUST reference this constant instead of a hardcoded "Normal" literal. Before
; this fix those four sites restored to the OS default "Normal", silently
; undoing the AboveNormal boot boost below the first time any of them ran
; (driver-baseline-priority-reverted-to-normal).
global DRIVER_BASELINE_PRIORITY_CLASS := "AboveNormal"

; Raise this process above the default OS scheduling class. The keyboard hook
; and hotstring engine are latency-sensitive on every keystroke; at Normal
; priority, Windows can leave them waiting behind other processes that are
; saturating the CPU (a busy IDE/build/watch process, a background scan, …),
; which surfaces as multi-second "Slow OnChar"/"Slow HSE.FeedChar" HotPath
; warnings even though this driver's own per-keystroke work is sub-millisecond.
; AboveNormal (not High) keeps this driver ahead of ordinary background work
; without contending with genuinely real-time OS/driver threads (hotpath-priority-starvation).
; A detached worker owns no hook and does background work: it keeps the default
; class so a long projection never competes with the foreground.
if !_DriverIsDetachedWorker
	try ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)

; Globals referenced by ``#HotIf`` expressions across the driver. They MUST
; be assigned before any code that pumps the message loop runs — otherwise
; AHK throws "global variable has not been assigned a value" the first time
; a keystroke during early init causes a #HotIf expression to be evaluated.
;
; ``Bundle_Init()`` below shells out to PowerShell via ``RunWait`` (see
; ``infra/bundle.ahk``), and RunWait pumps messages. Any key pressed during the
; ~250ms unzip would otherwise trigger #HotIf evaluation on hotkeys like
; ``#HotIf CapsWordEnabled`` or ``#HotIf LayerEnabled`` while those globals
; are still unset — assigning them here keeps the very first message pump
; well-formed.
global CapsWordEnabled := False
global LayerEnabled := False
global TapHold := Map("keys", Map())
; Read in FIRST position by a parse-time #HotIf (platform/remap/altgr.ahk), which
; can be evaluated during Bundle_Init's message-pumping RunWait — long before
; infra/hotstrings/hotstring_engine.ahk's include position. Seed it here so that #HotIf
; short-circuits to false instead of throwing; HotstringEngineInit() resolves the
; real value (auto-probe + TOML override) later in boot.
global _ALTGR_KANA_FIXUP := False
; Personal hotkeys become callable before layout registration finishes. Their
; callbacks may emit text while the auto-execute thread is still pumping, so the
; registry read by _EmitReachedScreen must already exist. The entries are global
; names because the owning InputHooks are initialised later in separate modules.
global _EMIT_SUPPRESSING_HOOKS := [
	"_SpaceHoldInputHook", "_MagicKeyEditorInputHook"
]
; The global error net must distinguish a recoverable callback fault from an
; init fault. Before this reaches "ready", continuing would leave a resident
; half-driver with a subset of hooks/menu state registered.
global _DriverBootPhase := "starting"
; Registry for runtime-registered personal shortcuts (personal_shortcuts.ahk).
; Stores ordered names + per-name descriptions so the tray menu can render them.
global _PersonalShortcutsRegistry := Map("__Order", [])
; Single source of truth for this process's PID. A_Pid is NOT an AHK v2 built-in
; (reading it throws UnsetError), so every log line and temp-file stem must use
; this global. Assigned in the pre-pump block so it exists before the first
; LoggerStart and before any parse-time-armed callback or deferred worker reads it.
global DriverPid := DllCall("GetCurrentProcessId", "UInt")
#Include infra/manifest_reader.ahk
#Include infra/feature_io.ahk

; ===== Global error net — armed BEFORE the first message pump =====
; Without this, any uncaught error pops an AHK dialog mid-keystroke and can leave
; modifiers stuck down. We log and continue so one bad callback never locks the
; keyboard. The handler must return true to consider the error "handled".
; It MUST be armed here, above Bundle_Init(): that call shells out through RunWait,
; which PUMPS MESSAGES, so a key pressed during the extraction can evaluate a
; parse-time #HotIf and throw with no net at all. error_net.ahk has no dependency
; that prevents loading it this early — its Logger calls are try-wrapped and function
; definitions are hoisted across the whole #Include graph before auto-execute runs.
#Include infra/error_net.ahk
if _DriverIsDetachedWorker
	OnError(DetachedWorkerErrorHandler)
else
	OnError(ErgoptiGlobalErrorHandler)

; In compiled mode the .exe ships an embedded zip of every runtime asset
; (hotstrings TOMLs, locales, icons, _shared tree, vendor DLLs). The bundle
; bootstrapper extracts it next to the .exe on first launch so the rest of
; the driver can keep reading from _StaticDir without caring whether it runs
; from source or from a compiled binary. In dev mode Bundle_Init() is a no-op.
#Include infra/bundle.ahk
Bundle_Init()
; First of the retroactive boot stamps (infra/boot_profiler.ahk). Everything from
; here to BootProfile_Begin() used to be one opaque "script parse + load: ~N ms"
; number, so a slow start could be attributed to "pre-boot" and no further. A
; stamp only records a tick — the logger does not exist yet — and BootProfile_Begin
; replays them all once it does.
BootProfile_Stamp("Bundle extracted")

; Compute _StaticDir and _VendorDir early so i18n.ahk and any module-level
; t() calls that run during #Include processing can resolve locale file paths.
; In compiled mode both point at the extracted bundle dir under LocalAppData
; (resolved by Bundle_Init above). In dev mode _StaticDir walks up two levels
; from the script location (static/ergopti_plus/windows → static) and _VendorDir
; is the vendor/ sibling of the entry script.
if A_IsCompiled {
		_StaticDir := _BundleDir . "\static"
		_VendorDir := _BundleDir . "\vendor"
} else {
		SplitPath(A_ScriptDir, , &_DriversDir_early)    ; static/ergopti_plus
		SplitPath(_DriversDir_early, , &_StaticDir)     ; static
		_VendorDir := A_ScriptDir . "\vendor"
}
global _StaticDir
global _VendorDir
; Sub-roots derived from _StaticDir — declared here so every #Include below can use them.
global _SharedDir := _StaticDir . "\ergopti_plus\_shared"
global _DriverDir := _StaticDir . "\ergopti_plus\windows"
; Extension packs sit beside _shared, not under static/. Resolved once here because
; two read sites had independently derived the pre-reorg path and both failed
; silently behind a DirExist() guard.
global _ExtensionsDir := _StaticDir . "\ergopti_plus\extensions"

; #Warn directives apply to the whole compilation unit in AHK v2 — they
; cannot be scoped to a single #Include. VarUnset and LocalSameAsGlobal are
; disabled globally because UIA.ahk (third-party) triggers both intentionally.
#Warn All
#Warn VarUnset, Off
#Warn LocalSameAsGlobal, Off

#Include *i vendor/UIA.ahk ; UIA v2 library — third-party, kept verbatim in vendor/ (source: https://github.com/Descolada/UIA-v2)
BootProfile_Stamp("UIA include initialised")
; *i = no error if the file isn't found. UIA is only used by WrapTextIfSelected
; (a Shift/AltGr shortcut that wraps the selection with the typed symbol). If
; that feature is disabled in your INI and you want to trim boot time / memory,
; you can safely delete ``vendor\UIA.ahk``: WrapTextIfSelected falls back to
; a plain SendNewResult via ``isSet(UIA)`` at the call site (see modules/keymap/layout.ahk).
; AHK v2 resolves #Include at parse time, so there is no true runtime lazy-load.

; The global error net itself is armed far above, before Bundle_Init()'s
; message-pumping RunWait — see the "Global error net" block there.
#Include infra/personal_features.ahk
#Include infra/menu_helpers.ahk

; #Hotstring EndChars -()[]{}:;'"/\,.?!`n`s`t   ; Adds the no breaking spaces as hotstrings triggers
A_MenuMaskKey := "vkff" ; Change the masking key to the void key
A_MaxHotkeysPerInterval := 150 ; Reduce messages saying too many hotkeys pressed in the interval

; AHK silently DROPS new pseudo-threads (hotkey callbacks, tray-menu items,
; OnMessage handlers, SetTimer callbacks) once A_MaxThreads concurrent
; threads are already active. The default ceiling of 10 is easy to hit
; with the keylogger's ~6 background timers + mouse/keyboard hooks. The
; menu-dispatcher bypass in infra/menu_dispatcher.ahk also relies on a free
; slot for its retry SetTimer, so the headroom matters even more there.
A_MaxThreads := 64

SetKeyDelay(0) ; No delay between key presses
SendMode("Event") ; Everything concerning hotstrings MUST use SendEvent and not SendInput which is the default
; Otherwise, we can't have a hotstring triggering another hotstring, triggering another hotstring, etc.

; Logger pulled in first so every other infra/module can call it during init.
; ``LoggerInit()`` is invoked after the configuration file is parsed so the
; minimum log level can be honoured from the very first INFO/START line.
; Generated sub-file routing table, included before the logger that calls it.
; It defines a FUNCTION rather than a global, so this ordering is a convenience
; and not a requirement — LoggerSubFilesData() is called at LoggerInit time.
#Include _generated/logger_sub_files.ahk
; Application folder, logs folder and log file names, generated from
; _shared/modules/paths/app_dirs.toml; functions too, read by the logger.
#Include _generated/app_dirs.ahk
#Include infra/tick_count.ahk
#Include infra/wall_clock.ahk
#Include infra/logger.ahk
#Include infra/boot_profiler.ahk
#Include infra/startup_smoke.ahk
#Include infra/diagnostic_snapshot.ahk
#Include infra/issue_link.ahk
#Include infra/redact.ahk
#Include infra/issue_report.ahk
#Include infra/error_policy.ahk
#Include infra/error_report.ahk
#Include infra/hotpath_profiler.ahk
#Include infra/registry.ahk
#Include infra/app_state.ahk
BootProfile_Stamp("Diagnostics and core state initialised")

; The chord notation the HotkeyRegistrar adapter parses with, loaded before the
; adapters block that consumes it
#Include infra/chord.ahk

; Port adapters — thin OS wrappers that isolate every DllCall, Send*, and
; WinGet* from the domain modules. Loaded before any infra/ or module/ file
; that references adapter functions (e.g. NI_GetSsidHash in keylogger_network).
#Include adapters/crypto.ahk
#Include adapters/clipboard.ahk
#Include adapters/timer_scheduler.ahk
#Include adapters/file_system.ahk
; Crash-safe multi-file config transitions bind strict Windows-only filesystem
; operations at this integration boundary; the portable core remains OS-free.
#Include infra/config_transition.ahk
#Include infra/config_transition_runtime.ahk
#Include adapters/window_info.ahk
#Include adapters/uia_worker.ahk
#Include adapters/hotkey_registrar.ahk
#Include ../_shared/modules/shortcuts/magic_editor.ahk
#Include infra/magic_editor.ahk
#Include adapters/notifier.ahk
#Include adapters/tray_menu.ahk
#Include adapters/text_sender.ahk
#Include ../_shared/modules/network/failure.ahk
#Include adapters/http_client.ahk
#Include adapters/secure_field_detector.ahk
#Include adapters/storage.ahk
#Include adapters/process_lifecycle.ahk
#Include adapters/key_state.ahk
#Include adapters/app_launcher.ahk
#Include adapters/network_info.ahk
#Include adapters/keyboard_hook.ahk
#Include adapters/llm_nav_event_owner.ahk
#Include adapters/mouse_control.ahk
#Include adapters/window_manager.ahk
#Include adapters/system_control.ahk
#Include adapters/graphics_renderer.ahk
#Include adapters/tooltip_renderer.ahk
#Include adapters/shell_runner.ahk
#Include ../_shared/modules/actions/brightness.ahk
#Include adapters/screen_brightness.ahk
#Include adapters/crash_report_worker.ahk
#Include modules/keymap/uia_selection_worker.ahk
BootProfile_Stamp("Adapters initialised")
SFD_ConfigureUiaWorker(
	UIASW_RequestPassword, UIASW_Start, UIASW_ContextMatches)

; Compiled workers reuse this executable. Exit into the minimal worker loop as
; soon as its UIA/window dependencies exist, before loading keylogger/WebView
; modules or running any normal-driver initialiser.
if UIASW_IsWorkerInvocation()
	UIASW_WorkerMain()

; INI helpers extracted to their own lib so the test runner can ``#Include``
; them without bootstrapping the rest of the driver.
#Include infra/toml/toml_helpers.ahk
; Shared timing registry reader (TimingsLoadShared / TimingsGet). Needs
; ParseTomlFile (above); consumed by the reassign-at-boot loaders below.
#Include infra/timings/timings_config.ahk
#Include modules/keymap/layout/layout_ergopti.ahk
#Include modules/keymap/layout/accented_shortcuts.ahk

; Active-app cache must come before hotstring_engine.ahk because both
; ``HotstringHandler`` and ``MicrosoftApps``.
#Include infra/window_utils.ahk
#Include infra/external_url_policy.ahk
#Include infra/text_utils.ahk
#Include infra/text_case.ahk
#Include infra/wrap_pair.ahk
#Include infra/send_input_parameter.ahk
#Include ui/spotlight/init.ahk
#Include infra/nav_layer_helpers.ahk

; Core hotstring engine (send primitives, hotstring builders, text helpers)
; and TOML reader helpers (UnescapeTomlString, LoadHotstringsSection,
; FoldAsciiLower) extracted into dedicated submodules so the main file
; stays focused on ErgoptiPlus-specific logic.
#Include infra/hotstrings/hotstring_engine.ahk
; The AltGr family HotstringEngineInit decides at boot and that then follows
; the foreground window's layout (AltGrFamilyStartFollowing, below).
#Include infra/altgr_family.ahk
#Include infra/hotstrings/hotstring_engine_main.ahk
#Include infra/hotstrings/hotstring_buffer_effects.ahk
#Include infra/hotstrings/hotstring_live_toggle.ahk
#Include infra/hotstrings/hotstring_count_policy.ahk
; Generated terminator catalogue (single source of truth — shared with macOS via
; _shared/core/domain/Terminators.spec.js). Both the tray and config-window delimiter
; menus render this catalogue so the word-terminator list never drifts between
; drivers. Included before the menus and before HSE_Terminators is instantiated.
#Include _generated/terminators.ahk
#Include infra/toml/toml_loader.ahk
#Include infra/hotstrings/extension_packs.ahk
#Include infra/toml/toml_config_loader.ahk
BootProfile_Stamp("Hotstring and TOML state initialised")
; The config.toml schema migration the boot runs before any reader or writer.
#Include infra/config_migrate.ahk
; manifest_reader.ahk + feature_io.ahk are loaded at the top of the file so
; Features / feature-IO functions are available before any #HotIf expression is
; evaluated. Re-listing them here would cause AHK to complain about the same
; script being included twice.
#Include infra/first_boot.ahk
#Include ../_shared/modules/config/outdated.ahk
#Include platform/remap/tap_hold_loader.ahk
#Include platform/remap/tap_hold_writer.ahk
; Tap-hold timing constants must load HERE, before infra/boot.ahk calls
; TapHoldsLoadTimings(): AHK v2 executes a file's top-level `global X := sentinel`
; assignments at its #Include position, so if constants.ahk loaded at its natural
; spot (inside platform/remap.ahk, far below boot.ahk) the sentinel 0s would
; re-clobber the registry values boot.ahk just loaded. #Include dedupes by path,
; so the later include via platform/remap.ahk is a no-op (mirrors the
; DYN_HOTSTRINGS_DEFAULT_DELAY early-layer precedent).
#Include platform/remap/constants.ahk
#Include infra/master_gates.ahk
#Include infra/manifest_descriptions.ahk
#Include infra/menu_dispatcher.ahk
#Include infra/hook_dispatcher.ahk
#Include infra/menu_manifest.ahk
#Include infra/manifest_menu.ahk
#Include infra/llm_defaults.ahk
#Include modules/updater.ahk
#Include infra/uninstall.ahk
#Include infra/start_at_login.ahk
#Include ui/changelog/init.ahk
#Include ui/healthcheck/init.ahk
#Include ui/error_dialog/init.ahk
#Include ui/update_check/init.ahk
#Include modules/diagnostics/crash_reporter.ahk
#Include infra/json.ahk
; i18n layer — must come after toml_loader.ahk (TOML_BatchWrite), logger.ahk, and json.ahk.
; locale.ahk (string loading + t()) precedes i18n.ahk (locale management), which calls into it.
#Include infra/locale.ahk
#Include _generated/gesture_emit_actions.ahk
#Include _generated/action_catalogue.ahk
#Include _generated/locale_table.ahk
#Include infra/i18n.ahk
#Include ui/onboarding/init.ahk
BootProfile_Stamp("Manifest, updater and locale state initialised")
#Include ../_shared/modules/hotstrings/terminator_scope.ahk
#Include infra/hotstrings/hotstrings_config.ahk
#Include ui/hotstrings_config_window/init.ahk
#Include ui/hotstrings_config_window/webview.ahk
#Include ui/prompt_editor/init.ahk
#Include infra/wrap_symbols_config.ahk
#Include _generated/window_titles.ahk
#Include infra/native_dialogs.ahk
#Include infra/ui_style.ahk
#Include ui/tooltip/init.ahk
#Include infra/hotstrings/hotstring_prefix_watcher.ahk
; Self-healing hotstring cache for the bundled TOMLs. Replaces the old ~1 MB of
; committed generated_*.ahk (tokenised at boot, before the tray icon could appear)
; with a gitignored flat .tsv read at registration — the same pattern as the i18n
; locale cache. LoadHotstringsSection ensures + consults it, falling back to the
; runtime TOML parser on a cache miss. No generated CODE is kept in the repo.
#Include infra/hotstrings/hotstrings_cache.ahk
#Include ui/personal_toml_editor.ahk
#Include ui/personal_toml_editor_webview.ahk
#Include modules/keymap/layout/layout_altgr.ahk
#Include ../_shared/modules/features/number_row_policy.ahk
#Include modules/keymap/layout/layout_shift_caps.ahk
; .keylayout reading (registry layout emulation and the Ergopti tables):
; definitions only. The hotkeys are registered by KeylayoutEmulation_Boot below
; and the Ergopti tables are read by modules/keymap/layout.ahk.
#Include modules/keymap/keylayout/keylayout_parser.ahk
#Include modules/keymap/keylayout/keylayout_tables.ahk
#Include modules/keymap/keylayout/keylayout_emulation.ahk
#Include modules/keymap/keylayout/layout_registry.ahk
#Include modules/keymap/keylayout/layout_catalogue.ahk
#Include modules/keymap/keylayout/layout_extension.ahk
#Include infra/app_picker.ahk
#Include infra/config_shortcuts.ahk
#Include infra/metrics/metrics_shortcuts.ahk
#Include infra/metrics/metrics_filters.ahk
#Include ui/wpm/init.ahk
#Include infra/sqlite3.ahk
#Include vendor/ComVar.ahk
#Include vendor/Promise.ahk
#Include vendor/WebView2.ahk
BootProfile_Stamp("WebView and metrics UI state initialised")
#Include infra/webview_utils.ahk
#Include ui/console_window.ahk
#Include modules/keylogger/keylogger_app_categories.ahk
#Include modules/keylogger/keylogger.ahk
#Include modules/keylogger/keylogger_hotstring_log.ahk
#Include modules/keylogger/keylogger_walker.ahk
#Include modules/keylogger/keylogger_hook.ahk
#Include modules/keylogger/keylogger_watchers.ahk
#Include modules/keylogger/keylogger_mouse.ahk
#Include modules/keylogger/keylogger_sensors.ahk
#Include modules/keylogger/keylogger_ergonomics.ahk
#Include modules/keylogger/keylogger_window_topology.ahk
#Include modules/keylogger/keylogger_av_state.ahk
#Include modules/keylogger/keylogger_network.ahk
#Include modules/keylogger/keylogger_clipboard.ahk
#Include modules/keylogger/keylogger_roi_prune.ahk
#Include modules/keylogger/keylogger_trigger_roi.ahk

; Bundled extension shortcut menus — each defines BuildExtMenu_<id>().
; ``*i`` keeps the driver runnable if an extension is removed without
; updating this list. NOTE: one ``..`` only — this file lives in
; static/ergopti_plus/windows/, so ``..\extensions`` is the real tree. The
; previous ``..\..\extensions`` resolved to static/extensions/, which has not
; existed since the static/ reorg, and ``*i`` suppressed the include error, so
; BuildExtMenu_ergopti_demo() was never defined and the extensions submenu never
; rendered.
#Include *i ..\extensions\ergopti-demo\shortcuts\menu.ahk
#Include modules/keylogger/keylogger_reader.ahk
#Include modules/keylogger/keylogger_prefetch.ahk
#Include modules/keylogger/keylogger_webview.ahk
#Include modules/keylogger/keylogger_ui.ahk
BootProfile_Stamp("Keylogger modules initialised")

; A detached prefetch worker shares these projection modules but must never run
; the normal driver boot: no hooks, timers, tray, WebView, or config mutation.
; It publishes one staged JSON file and exits; the live instance validates the
; generation before atomically making that file visible to a dashboard.
if KLPF_IsWorkerInvocation()
		KLPF_WorkerMain()
KLPF_InitializeCleanup()

#Include _generated/prompt_builder.ahk
#Include modules/llm/api_common.ahk
#Include modules/llm/api_token_crypto.ahk
#Include modules/llm/api_ollama.ahk
#Include modules/llm/rewrite.ahk
#Include modules/llm/parser.ahk
#Include modules/llm/remote_formats.ahk
#Include ..\_shared\modules\llm\local_server_auth.ahk
#Include modules/llm/api_remote.ahk
#Include modules/llm/models.ahk
; LLM_GetSharedPath is now available — load the cross-platform defaults before
; prediction_engine.ahk and menu_llm.ahk initialise their state maps.
LLM_Defaults_Load()
BootProfile_Stamp("LLM defaults loaded")
#Include _generated/llm_profiles_data.ahk
#Include modules/llm/profiles.ahk
#Include modules/llm/option_validation.ahk
#Include modules/llm/prompt_action.ahk
#Include modules/llm/tone.ahk
#Include modules/llm/tone_action.ahk
#Include modules/llm/vision.ahk
#Include modules/llm/vision_action.ahk
#Include modules/llm/translate.ahk
#Include modules/llm/translate_action.ahk
#Include modules/llm/agent.ahk
#Include modules/llm/agent_connectors.ahk
#Include modules/llm/agent_action.ahk
#Include modules/llm/prediction_engine.ahk
#Include modules/keymap/llm_bridge.ahk
#Include modules/llm/ollama_webview.ahk
#Include modules/llm/ollama_deps_checker.ahk
#Include ui/tooltip/tooltip_llm.ahk
#Include ui/menu/menu_llm/_index.ahk
#Include ui/model_browser/init.ahk
; Closes the include graph: every module's top-level initialiser has now run.
BootProfile_Stamp("Module includes initialised")

; ======================================================
; ======================================================
; ======================================================
; ================ 1/ SCRIPT MANAGEMENT ================
; ======================================================
; ======================================================
; ======================================================

; The code in this section shouldn't be modified
; All features can be changed by using the configuration file

; =============================================
; ======= 1.1) Variables initialization =======
; =============================================

#Include infra/suspend_handoff.ahk
#Include infra/boot.ahk
BootProfile_Stamp("Paths and shared configuration loaded")
#Include infra/feature_state.ahk
; Settle parse-time personal includes before any process reveals the tray icon.
try {
		if !EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"],
				_PersonalShortcutsBootAllowsReload(A_IsCompiled,
						_DriverStartupSmokeDir != "" and EnvGet("ERGOPTI_STARTUP_SMOKE_BOOTSTRAP") != "1"))
				throw Error("personal shortcuts bootstrap was not durable")
} catch as _epsErr {
		try LoggerError("ErgoptiPlus", "EnsurePersonalShortcutsFile failed: {1}.", _epsErr.Message)
		LoggerAppendBootstrapLine("ERROR", "ErgoptiPlus", "Personal shortcuts bootstrap failed: " . _epsErr.Message)
		ExitApp(1)
}
#Include infra/tray_bootstrap.ahk
#Include adapters/tray_startup_click.ahk
#Include adapters/tray_startup_commands.ahk

; AHK-21: atomically replace the stock AHK tray items
; (Pause/Suspend/Reload/Exit/Edit) BEFORE the blocking onboarding wizard so
; those stock actions are never live
; during first-run setup. On a normal (non-first-run) boot Onboarding_Run is
; a no-op, so this move is safe — and it closes the brief stock-menu window
; regardless of the boot path (normal OR first-run).
_InstallSafeBootstrapTray()
global _TrayStartupCommands := TrayStartupCommands(
	() => IsSet(_DriverReady) && _DriverReady, TrayStartupCommand)
if FileExist(ConfigurationFile)
	_InstallNativeStartupTray(ObjBindMethod(_TrayStartupCommands, "Request"))
global _TrayStartupClick := TrayStartupClick(
	() => IsSet(_DriverMenuReady) && _DriverMenuReady,
	_DriverStartupSmokeDir != "" ? (*) => 0 : 0, 0, 0, 0, 0,
	_DriverStartupSmokeDir != "" ? 0 : TrayStartupOnboarding)
; Retain context requests until the complete root exists. Entering the native
; bootstrap menu here blocks auto-execute for the user's navigation interval.
if (_DriverStartupSmokeDir != "" && IsSet(_DriverStartupSmokeInspectBootstrap))
	_DriverStartupSmokeInspectBootstrap.Call()
; #NoTrayIcon kept the icon hidden until now: it appears with the custom icon and
; the safe menu, never with AutoHotkey's default icon and stock items.
A_IconHidden := false
if (_DriverStartupSmokeDir != "") {
		; The real onboarding WebView pumps messages while startup is incomplete.
		; Reproduce that hazard without an interactive window: the suspend watchdog
		; must remain unarmed here until the later lifecycle include initializes all
		; state consumed by marker restoration.
		_StartupSmokePumpStarted := A_TickCount
		while !TickExpired(_StartupSmokePumpStarted, 650)
				Sleep(20)
} else {
		Onboarding_Run()
}
; Blocking on a first run, a no-op otherwise — which is exactly why it needs its
; own stamp: a first-run boot and a normal boot are otherwise indistinguishable
; in the timings.
BootProfile_Stamp("Tray reset + onboarding")

; Version config.toml before anything reads it: the snapshot below,
; ApplyBootConfigToml and the boot full save all see the migrated file. A file
; this build cannot version (a newer schema, a failed migration) stays
; untouched and every write to it is refused for the session
; (infra/config_migrate.ahk, docs/adr/009-config-versioning.md).
ConfigMigrateBoot(ConfigurationFile)
BootProfile_Stamp("Configuration migration checked")

global _IniCache := ParseConfigTomlFile(ConfigurationFile)
BootProfile_Stamp("Configuration TOML snapshot parsed")
; Latch the session sentinel SaveFullConfig honours when that parse could not
; READ an existing config.toml. This snapshot is taken once and never refreshed,
; yet it seeds the locale, the magic key, every category master gate, both
; shortcut tables, the gesture assignments and the WPM widget — all of which
; SaveFullConfig serialises back a few hundred ms later. By then the transient
; lock has usually cleared, so no write-time check can tell that the payload was
; derived from nothing; only latching at the instant of the failed read can.
if TOML_UnreadableFile(ConfigurationFile) {
		_ConfigBootReadFailed := true
		try LoggerError("ErgoptiPlus", "Cannot read '{1}' at boot: every setting below stays at its compiled-in default, so persistence is blocked for this session. Restart the driver once the file is readable.", ConfigurationFile)
}
ReadScriptConfig(_IniCache)
BootProfile_Stamp("Script preferences applied")
; Language-pack category gates come from the shared hotstring index, so they are
; added before the gates are read from config.toml.
HotstringsSeedLanguageCategoryGates(CategoryEnabled)
ReadCategoryEnabled(_IniCache)
I18nInit(_IniCache)
BootProfile_Stamp("Config parsed (TOML + i18n)")

; Resolve _ALTGR_KANA_FIXUP: TOML override (ScriptInformation["AltGrIsKanaRemap"])
; wins when set; otherwise auto-detect via the reverse VK_RMENU→SC probe. Must
; run before the first hotstring fires. After boot the family follows the
; foreground window's layout without a reload (AltGrFamilyStartFollowing and
; the layout poll at the bottom of this file).
HotstringEngineInit()
; The layout the one boot registration that reads the keyboard layout is built
; for: the magic-key source scan, without the Ergopti emulation (the digit-row
; swap reads the foreground layout per press, DigitRowIsSwapped). It is the
; layout the boot probe read, so that registration and the AltGr family
; describe one layout, and the layout poll starts from it.
global _LAYOUT_REMAP_HKL := _ALTGR_LAYOUT_PROBE["hkl"]
BootProfile_Stamp("Hotstring engine initialised")

; Initialise the logger now that the ini cache is built and ScriptInformation
; reflects user overrides — LoggerInit reads [Script] LogLevel from the ini.
LoggerInit()
; Right after the logger: every later ERROR of the boot can open the error
; window, which waits for the driver to be ready before it shows
ErrorDialog_Init(_IniCache)
bootScriptName := IsSet(A_ScriptName) ? A_ScriptName : "ErgoptiPlus"
if !IsSet(A_ScriptName) && IsSet(A_ScriptFullPath) {
		bootScriptName := A_ScriptFullPath
}
if !IsSet(A_ScriptName) {
		LoggerWarn("ErgoptiPlus", "A_ScriptName was not set during boot; using fallback name='{1}'.", bootScriptName)
}
try Updater_LoadChannel()
try Updater_LoadCheckInterval()
; Schedule the background update poller. No-op in dev / source mode, or
; when the user has chosen "never" — those checks happen inside the helper.
try Updater_StartBackgroundChecks()
try Updater_InitTrayNotifyHandler()
LoggerStart("ErgoptiPlus", "Booting ErgoptiPlus driver (pid={1}, script='{2}')…", DriverPid, bootScriptName)
; Boot phase profiling — emits one INFO line per phase so a slow start can be
; diagnosed from the log alone (see infra/boot_profiler.ahk).
BootProfile_Begin()
HotPath_StartStatistics()
; The environment is logged FIRST, not only in the post-ready snapshot: a boot
; that dies half-way never reaches the snapshot, and then these facts are the
; only description of the machine it died on.
try LoggerInfo("ErgoptiPlus", "{1}", DiagSnapshot_EarlyLine())
catch as _EnvErr
	LoggerError("ErgoptiPlus", "Boot environment could not be described: {1}.", _EnvErr.Message)

; Eager-load the ACTIVE i18n locale now. It is otherwise lazy on the first t()
; call, which lands mid-config and buries its JSON parse inside a later, unrelated
; mark. The tray menu needs it within milliseconds anyway. Only the active locale
; is parsed here; the EN/FR fallbacks (consulted solely on a missing key) are
; warmed off the critical path by I18nWarmFallbacks() armed after "ready" — which
; halves the boot i18n cost on a complete locale (one parse instead of two).
BootProfile_StageBegin("i18n")
I18nPreload()
BootProfile_StageEnd("i18n", "locale " . I18nGetLocale())
BootProfile_Mark("i18n locale preloaded")

; Load tooltip visual constants from _shared/modules/tooltip/constants.toml so the
; runtime values stay in sync with the TOML single source of truth.
; Must run after _SharedDir is set (line ~51) and ParseTomlFile is available.
UiStyle_LoadSharedConst()
; Now that UI_AI_LOADING_HEX is loaded, source the llm_prediction hotstring tint
; from it (single canonical AI loading colour) — must run after the line above
; and before the tray menu build / any HotstringsResolve.
HotstringsConfigLoadLlmPredictionColor()

; Log the probe that decided the AltGr family (HotstringEngineInit), not a
; second read of the layout: the HKL, the raw reverse-probe result (VK_RMENU →
; SC; 0 means a Kana-like remap), the AltGr key's virtual key, the resolved flag
; and what decided it ("override" for the [Script] AltGrIsKanaRemap flag).
if (_ALTGR_LAYOUT_PROBE["source"] == "unresolved") {
		LoggerError("AltGrDetect",
				"No keyboard layout could be read at boot; AltGr is handled as a standard AltGr layout until the next layout change, _ALTGR_KANA_FIXUP={1}.",
				_ALTGR_KANA_FIXUP ? "true" : "false")
} else if (_ALTGR_KANA_FIXUP and !_ALTGR_LAYOUT_PROBE["altgr_vk"]) {
		LoggerError("AltGrDetect",
				"HKL=0x{1:X}: a Kana-style AltGr is set (source={2}) but the layout gives the AltGr key no virtual key; every press or release of it the driver sends is refused.",
				_ALTGR_LAYOUT_PROBE["hkl"], _ALTGR_LAYOUT_PROBE["source"])
} else if AltGrFamilyOverrideContradictsProbe(_ALTGR_LAYOUT_PROBE) {
		; The same facts as the line below, as a warning: every AltGr feature now
		; names the key of the family the layout does not have.
		LoggerWarn("AltGrDetect",
				"HKL=0x{1:X}, VK_RMENU→SC=0x{2:X}, AltGr VK=0x{3:X}, AltGr level={4}: [script] alt_gr_is_kana_remap forces _ALTGR_KANA_FIXUP={5} against what the layout reads as; AltGr shortcuts and tap-holds name the other family's key unless the probe is wrong.",
				_ALTGR_LAYOUT_PROBE["hkl"], _ALTGR_LAYOUT_PROBE["rmenu_sc"], _ALTGR_LAYOUT_PROBE["altgr_vk"],
				_ALTGR_LAYOUT_PROBE["altgr_level"] ? "true" : "false",
				_ALTGR_KANA_FIXUP ? "true" : "false")
} else {
		LoggerInfo("AltGrDetect",
				"HKL=0x{1:X}, VK_RMENU→SC=0x{2:X}, AltGr VK=0x{3:X}, AltGr level={4}, _ALTGR_KANA_FIXUP={5} (source={6}).",
				_ALTGR_LAYOUT_PROBE["hkl"], _ALTGR_LAYOUT_PROBE["rmenu_sc"], _ALTGR_LAYOUT_PROBE["altgr_vk"],
				_ALTGR_LAYOUT_PROBE["altgr_level"] ? "true" : "false",
				_ALTGR_KANA_FIXUP ? "true" : "false", _ALTGR_LAYOUT_PROBE["source"])
}

; Under this text is the configuration of the features, especially whether or not they are enabled.
; It is advised to modify which features are enabled by using the ErgoptiPlus_Configuration.ini file.
; This configuration file will automatically be created or updated as soon as one element of the tray menu is toggled on/off.
; It can also be created manually. The content will look like this, with the different categories in brackets:
; [Layout]
; ErgoptiBase.Enabled=0
; [TapHolds]
; AltGr.Enabled=1

; It is best to modify those values by using the option in the script menu
global PersonalInformation := Map(
		"first_name", "Prénom",
		"last_name", "Nom",
		"date_of_birth", "01/01/2000",
		"email_address", "prenom.nom@mail.fr",
		"work_email_address", "prenom.nom@mail.pro",
		"phone_number", "0606060606",
		"phone_number_clean", "06 06 06 06 06",
		"street_address", "1 Rue de la Paix",
		"city", "Paris",
		"country", "France",
		"postal_code", "75000",
		"iban", "FR00 0000 0000 0000 0000 0000 000",
		"bic", "ABCDFRPP",
		"credit_card", "1234 5678 9012 3456",
		"social_security_number", "1 99 99 99 999 999 99",
)
global PersonalInformationLetters := Map(
		"a", "street_address",
		"b", "bic",
		"c", "credit_card",
		"d", "date_of_birth",
		"e", "email_address",
		"f", "phone_number_clean",
		"i", "iban",
		"m", "email_address",
		"n", "last_name",
		"p", "first_name",
		"s", "social_security_number",
		"t", "phone_number",
		"w", "work_email_address",
)

; ======================================================================
; ======= 1.2) Variables update if there is a configuration file =======
; ======================================================================

; Configuration is hydrated from the user's v2 config.toml by
; ApplyConfigToml below. The legacy INI-based ReadConfiguration path
; and the v1 Features Map are gone.

; Materialise personal_info.toml from defaults if missing, so renaming or
; deleting the file simply triggers a fresh re-creation on the next launch
; (same guarantee EnsurePersonalShortcutsFile gives for personal_shortcuts.ahk).
BootProfile_StageBegin("configuration")
EnsurePersonalInfoTomlFile(ScriptInformation["PersonalInfoTomlPath"])
ReadPersonalInfoToml(ScriptInformation["PersonalInfoTomlPath"])

EnsureUserConfigsExist()
; Guard: the generated manifest must be present and loaded before we build
; the Features Map. If it is missing (e.g. after a fresh clone or when the
; codegen has not been run yet), ManifestBuildFeaturesMap returns an empty
; Map and every downstream Features["llm"]["enabled"] access throws a
; cryptic "Item has no value" error. Fail loudly here instead.
if !ManifestEnsureLoaded() {
	Ui_MsgBox(t("startup.manifest_missing"), t("startup.manifest_window_title"), "OK Iconx")
	ExitApp(1)
}
global Features := ManifestBuildFeaturesMap()
; Seed file-discovered personal hotstring sections (beyond the manifest's fixed 5) into
; Features["hotstrings"]["personal"] BEFORE ApplyConfigToml, so a persisted toggle for a
; custom section is accepted (not rejected as an unknown path) and the section's hotstrings
; register + honour the tray toggle like the built-ins (personal-hotstring-seed).
try {
	_PersonalHsData := ReadPersonalToml()
	if (_PersonalHsData is Map and _PersonalHsData.Has("sections_order")) {
		for _, _PHSec in _PersonalHsData["sections_order"] {
			if (_PHSec != "-")
				EnsurePersonalHotstringFeature(_PHSec)
		}
	}
}
_HotstringExtensionPacks := HotstringExtensions_Prepare(Features,
	HotstringExtensions_Roots(_ConfigDir, _ExtensionsDir))
_BootConfigApplied := ApplyBootConfigToml(Features, _ConfigDir . _AhkSubDir . "config.toml")
global TapHold := LoadTapHoldToml(_ConfigDir . _AhkSubDir . "tap_hold.toml",
	_SharedDir . "\tap_hold\defaults.toml")
BootProfile_StageEnd("configuration", Format("{1} config.toml value(s) applied, {2} tap-hold key(s)",
	_BootConfigApplied, (TapHold is Map && TapHold.Has("keys")) ? TapHold["keys"].Count : 0))



; Safe nested read
_SpaceAroundSymbolsNode := (Features.Has("hotstrings")
	and Features["hotstrings"].Has("distances_reduction")
	and Features["hotstrings"]["distances_reduction"].Has("space_around_symbols"))
	? Features["hotstrings"]["distances_reduction"]["space_around_symbols"]
	: Map()
global SpaceAroundSymbols := (_SpaceAroundSymbolsNode.Has("enabled") and _SpaceAroundSymbolsNode["enabled"]) ? " " : ""

#Include ui/tray_menu.ahk




/**
 * Only source-mode startup can reload a newly generated parse-time include.
 * Compiled includes are embedded at build time; restarting the same executable
 * cannot load a newly written personal file or forwarding stub. Keep the empty
 * first-use template durable without retiring the instance before readiness.
 * @param {Boolean} IsCompiled - The actual A_IsCompiled capability.
 * @param {Boolean} IsStartupSmoke - Whether the owned startup smoke is active.
 * @returns {Boolean} Whether source-mode bootstrap may perform its terminal reload.
 */
_PersonalShortcutsBootAllowsReload(IsCompiled, IsStartupSmoke) {
	if !(IsCompiled is Integer) || (IsCompiled != 0 && IsCompiled != 1)
		throw TypeError("personal-shortcuts compiled capability must be Boolean")
	if !(IsStartupSmoke is Integer) || (IsStartupSmoke != 0 && IsStartupSmoke != 1)
		throw TypeError("personal-shortcuts startup-smoke capability must be Boolean")
	return !IsCompiled && !IsStartupSmoke
}

EnsurePersonalShortcutsFile(Path, AllowReload := true, WriterFn := 0,
		ReplaceFn := 0, ReadFn := 0) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
				Critical("Off")
				try return EnsurePersonalShortcutsFile(Path, AllowReload,
						WriterFn, ReplaceFn, ReadFn)
				finally Critical(InheritedCritical)
		}
		if (!IsSet(Path) or Type(Path) != "String" or Path == "") {
				try LoggerWarn("ErgoptiPlus", "EnsurePersonalShortcutsFile called with empty Path — skipping.")
				return false
		}
		FileWasCreated := false
		if !FileExist(Path) {
				try {
						Dir := RegExReplace(Path, "\\[^\\]+$", "")
						if (Dir != "" and !DirExist(Dir)) {
								DirCreate(Dir)
						}
						Template := PersonalShortcutsTemplate()
						; A complete same-directory stage is published atomically. The old
						; FileAppend path could leave a truncated AHK source on interruption.
						if !_PersonalShortcutsPublishFile(Path, Chr(0xFEFF) . Template,
								WriterFn, ReplaceFn, ReadFn, true)
								throw Error("the personal shortcuts file could not be published atomically")
						FileWasCreated := true
						try LoggerInfo("ErgoptiPlus", "Personal shortcuts file created from template at '{1}'.", Path)
				} catch as e {
						try LoggerWarn("ErgoptiPlus", "Could not create personal shortcuts file at '{1}': {2}.",
								Path, e.Message)
						return false
				}
		}
		StubDir := ""
		if A_IsCompiled {
				LocalAppData := ResolveLocalAppDataDir()
				if (LocalAppData == "") {
						try LoggerWarn("ErgoptiPlus", "EnsurePersonalShortcutsFile: cannot resolve LocalAppData — skipping stub creation.")
						return false
				}
				StubDir := LocalAppData . "\Ergopti\_generated"
		} else {
				StubDir := A_ScriptDir . "\_generated"
		}
		try DirCreate(StubDir)
		StubPath := StubDir . "\personal_shortcuts.ahk"
		DesiredStub := "; Auto-generated forwarding stub — do not edit.`n"
				. "; Forwards to the user's personal shortcuts file located at:`n"
				. ";     " . Path . "`n"
				. "; Edit that file (e.g. via the tray menu) rather than this stub.`n"
				. "#Include *i " . Path . "`n"
		Existing := ""
		if FileExist(StubPath) {
				try Existing := HasMethod(ReadFn, "Call")
						? ReadFn.Call(StubPath) : FSRead(StubPath)
		}
		if (Existing is String) and SubStr(Existing, 1, 1) == Chr(0xFEFF)
				Existing := SubStr(Existing, 2)
		StubMatches := (Existing == DesiredStub)
		if !StubMatches {
				try {
						if !_PersonalShortcutsPublishFile(StubPath,
								Chr(0xFEFF) . DesiredStub, WriterFn, ReplaceFn, ReadFn)
								throw Error("the forwarding stub could not be published atomically")
						try LoggerInfo("ErgoptiPlus", "Personal shortcuts forwarding stub refreshed at '{1}'.", StubPath)
				} catch as e {
						try LoggerWarn("ErgoptiPlus", "Could not write forwarding stub at '{1}': {2}.",
								StubPath, e.Message)
						return false
				}
		}
		if FileWasCreated or !StubMatches {
				if !AllowReload {
						; A runtime caller (the "open personal shortcuts" gesture/menu) wants to open
						; the file for editing, NOT restart the driver mid-session — the freshly
						; written file is an empty template, so nothing needs re-including before the
						; user has even edited it. Their next Reload picks up the edits.
						try LoggerInfo("ErgoptiPlus", "Personal shortcuts file/stub (re)created; skipping Reload (caller opted out).")
						return true
				}
				try LoggerInfo("ErgoptiPlus", "Reloading to pick up freshly-written personal shortcuts chain.")
				; The one bare Reload left, and deliberately so: only the boot
				; auto-execute thread gets here (a runtime caller passes
				; AllowReload=false), before OnExit(Ergopti_OnShutdown) is
				; registered, so no gate can refuse the successor's close request,
				; before the process can be paused and before any reload can be
				; pending. The terminal hand-off needs the configuration bundle and
				; lifecycle state that do not exist yet here.
				Reload
				; Reload starts the replacement instance but returns to this
				; auto-execute thread. Continuing would register the old instance's
				; hooks/layout beside the replacement for one scheduling window.
				; Exit immediately: native input remains available until the new
				; process is ready, but there is never two owners of the keyboard.
				ExitApp(0)
		}
		return true
}

; Publish one generated AHK file only after its full bytes can be re-read from
; the stage. This helper is deliberately status-bearing so menu/gesture callers
; never open a path whose creation silently failed.
_PersonalShortcutsPublishFile(Path, Content, WriterFn := 0, ReplaceFn := 0,
		ReadFn := 0, CreateOnly := false) {
		static StageSequence := 0
		OwnerToken := _ConfigWriteLeaseTryAcquire(
				Path, "personal-shortcuts-publication")
		if !(OwnerToken is Object) {
				try LoggerError("ErgoptiPlus",
						"Could not publish generated personal shortcuts at '{1}': another configuration transaction owns the target.",
						Path)
				return false
		}
		StagePath := ""
		try {
				StageSequence += 1
				StagePath := Path . "." . A_NowUTC . "." . A_ScriptHwnd . "."
						. A_TickCount . "." . StageSequence . ".stage"
				Written := HasMethod(WriterFn, "Call")
						? WriterFn.Call(StagePath, Content) : FSWriteDurable(StagePath, Content)
				if !((Written is Integer) && Written == 1) {
						try LoggerError("ErgoptiPlus",
								"Generated personal-shortcuts stage write was not durable at '{1}' (status={2}).",
								StagePath, String(Written))
						return false
				}
				Observed := HasMethod(ReadFn, "Call") ? ReadFn.Call(StagePath) : false
				StageMatches := HasMethod(ReadFn, "Call")
						? ((Observed is String) and Observed == Content)
						: FSUtf8ExactMatches(StagePath, Content)
				if !StageMatches {
						try LoggerError("ErgoptiPlus",
								"Generated personal-shortcuts stage verification failed at '{1}' (expected={2} chars/U+{3}, observed={4} chars/U+{5}).",
								StagePath, StrLen(Content), Ord(SubStr(Content, 1, 1)),
								(Observed is String) ? StrLen(Observed) : -1,
								(Observed is String) && Observed != "" ? Ord(SubStr(Observed, 1, 1)) : -1)
						try FSDelete(StagePath)
						return false
				}
				; The writer/read seam can yield to a path relocation or another
				; user action. Only the exact still-live owner may publish its stage.
				if !_ConfigWriteLeaseOwns(OwnerToken, Path) {
						try LoggerError("ErgoptiPlus",
								"Generated personal-shortcuts publication lost its config lease for '{1}'.", Path)
						try FSDelete(StagePath)
						return false
				}
				Replaced := HasMethod(ReplaceFn, "Call")
						? ReplaceFn.Call(StagePath, Path, CreateOnly)
						: (CreateOnly ? FSAtomicMoveCreate(StagePath, Path)
								: FSAtomicMoveReplace(StagePath, Path))
				if !((Replaced is Integer) && Replaced == 1) {
						try LoggerError("ErgoptiPlus",
								"Generated personal-shortcuts atomic publication failed from '{1}' to '{2}' (status={3}).",
								StagePath, Path, String(Replaced))
						try FSDelete(StagePath)
						; Another process may have won creation after our initial absence
						; probe. Its user-owned file is success, never something to replace.
						if CreateOnly && FileExist(Path)
								return true
						return false
				}
				return true
		} finally {
				_ConfigWriteLeaseRelease(OwnerToken)
		}
}

#InputLevel 2
#Include *i _generated/personal_shortcuts.ahk
#Include *i %LocalAppData%\Ergopti\_generated\personal_shortcuts.ahk
#Include %A_ScriptDir%
#InputLevel 0
; Capture configuration intent once before deriving the effective runtime.
BootProfile_StageBegin("feature gates")
_GateCountsBefore := DiagSnapshot_CountFeatures(Features)
MasterGateInitialize(Features, TapHold, IsCategoryGated, LoggerDebug)
_GateCountsAfter := DiagSnapshot_CountFeatures(Features)
; The master gates silently zero whole categories. Without the counts a user log
; cannot tell "the feature is off" from "its category is off".
BootProfile_StageEnd("feature gates", Format("{1}/{2} feature switch(es) enabled, {3} forced off by a disabled category",
	_GateCountsAfter["enabled"], _GateCountsAfter["total"],
	_GateCountsBefore["enabled"] - _GateCountsAfter["enabled"]))

#Include modules/take_note.ahk
; The touchpad registry table and its one owner (backup, write, restore).
; Functions only: the first-run wizard above already calls them.
#Include _generated/touchpad_registry.ahk
#Include modules/gestures/touchpad_registry.ahk
#Include modules/gestures/init.ahk
#Include modules/gestures/click.ahk
#Include modules/gestures/screenshots.ahk
#Include modules/gestures/window_cycle.ahk
#Include modules/gestures/virtual_desktops.ahk
#Include modules/gestures/config.ahk
BootProfile_StageBegin("shortcuts")
ReadScriptShortcutsConfig()
ReadKeyboardShortcutsConfig()

LoggerStart("KeyboardShortcuts", "Registering configurable keyboard hotkeys…")
_KbBoundCount := 0
for _KbSlot, _KbAction in KeyboardShortcutAssignments {
		if _KbSlot == MagicEditorSlot()["id"]
				continue
		if MagicEditorRecordOrdinaryPhysical(_KbSlot, _KbAction)
				continue
		if (_KbAction == "none")
				continue
		_KbChord := _KeyboardSlotChord(_KbSlot)
		if (_KbChord == "") {
				LoggerWarn("KeyboardShortcuts", "Slot '{1}' skipped — chord not resolvable.", _KbSlot)
				continue
		}
		; The registrar owns the OS call and reports refusal by returning "", so the
		; try/catch that used to wrap Hotkey() here would now only ever catch our own
		; bugs — which must surface, not be logged as a skipped shortcut
		_KbHandle := HotkeyRegistrarBind(_KbChord, ((_s) => (*) => RunKeyboardShortcutAction(_s))(_KbSlot))
		if (_KbHandle == "") {
				LoggerWarn("KeyboardShortcuts", "Failed to register hotkey '{1}' ({2}).", _KbSlot, _KbChord)
				continue
		}
		LoggerDebug("KeyboardShortcuts", "Hotkey '{1}' → '{2}' registered.", _KbSlot, _KbAction)
		MagicEditorRecordOrdinaryHandle(_KbSlot, _KbHandle)
		_KbBoundCount++
}
LoggerSuccess("KeyboardShortcuts", "Configurable hotkeys registered ({1} active).", _KbBoundCount)

#Include infra/config_io.ahk
#Include infra/config_scope.ahk
#Include ../_shared/modules/hotstrings/scope_overrides.ahk
#Include infra/hotstrings/hotstrings_scope.ahk
#Include infra/config_global_scope.ahk
CS_Load()
global _SaveFullConfigReady := true
global _ParseExtTomlSectionsCache := Map()
if MetricsShortcuts.enabled
		WPMWidget_LoadConfig(_IniCache)

BootProfile_StageEnd("shortcuts", _KbBoundCount . " configurable hotkey(s) bound")
BootProfile_Mark("Config, features & shortcuts loaded")
; Publish the configured native root before registering the input surface. Leaf
; pickers finish before paint or prewarm after input readiness; command admission
; retains feature selections until their runtime owners genuinely exist.
; Stock tray items (Pause/Suspend/Reload/Exit/Edit) are cleared once at boot,
; before Onboarding_Run (AHK-21), so they are never live during the first-run wizard.
; Keep the real native commands throughout boot and refresh their locale before
; feature initialization. No temporary loading surface replaces the tray root.
_DriverReady := false
_LangMenuRef := ""
_LangMenuBuildPending := false
LANG_MENU_DEFER_MS := 120  ; short post-ready delay for the language-submenu populate
MENU_BUILD_DEFER_MS := 16  ; offer optional configuration maintenance after ready
_InstallNativeStartupTray(ObjBindMethod(_TrayStartupCommands, "Request"))
#Include infra/tap_keys.ahk
TapKeysReadConfig(_IniCache)
#Include infra/key_combinations.ahk
KeyCombinationsReadConfig(_IniCache)
#Include infra/lifecycle.ahk
; Cleanup must own windows before the configured menu admits diagnostic clicks.
; Empty, uninitialized metrics now pass the reversible persistence preflight.
OnExit(Ergopti_OnShutdown, -1)
global _DriverUiCleanupReady := true
LoggerInfo("ErgoptiPlus", "Shutdown handler registered before configured menu publication.")
if _DriverStartupSmokeDir == ""
	WebView_BeginBrowserWarmup()
global _FmtCountCache := Map()
global _DriverInputInitPending := true
global _DriverMenuReady := false
MenuStartupCommands_Begin(() => _DriverReady && _LLM_Menu_RuntimeActivated)
_TrayRootBootDetailsPending := true
if !BuildTrayMenuDeferred()
	throw Error("the configured startup menu could not be published")
if (_DriverStartupSmokeDir != "" && IsSet(_DriverStartupSmokeInspectShell))
	_DriverStartupSmokeInspectShell.Call()
ConfigRegistryCacheFlushPending()
BootProfile_StageBegin("magic key source")
; The physical key typing the magic key (LayoutRegistry_MagicKeySource): the
; key the user chose in [hotstrings] magic_key_source always wins; then the key
; the active layout's extension declares — the emulated registry layout, or the
; built-in Ergopti emulation; then, with no layout emulated, the key that types
; MagicKeySourceChar ("j" by default) on the user's own OS layout — on bépo not
; the SC02E Ergopti/QWERTY position; then the key the shipped Ergopti layout
; declares. A layout is emulated only while the base layer is on
; (_KLE_BaseCriterion): a layout left selected in the manager with the base
; layer off types nothing, so the OS layout is still probed.
;
; The OS layout probed is _LAYOUT_REMAP_HKL, the one the boot AltGr probe read
; (through the KS_ResolveKeyboardLayout cascade: foreground, then the AHK
; thread, then the system default), so the scan and the AltGr family describe
; one layout and the layout poll, seeded with the same HKL, reloads when the
; user switched — only when the key follows the OS layout at all.
_MagicKeySource := LayoutRegistry_MagicKeySource(Map(
	"chosen", ScriptInformation["MagicKeySourceChosen"],
	"configured", ScriptInformation["MagicKeySource"],
	"declared", LayoutRegistry_DeclaredMagicKey(
		LayoutRegistry_ActiveLayoutExtension(KeylayoutEmulation_SelectedId(),
			Features["layout"]["ergopti_base"], ERGOPTI_LAYOUT_ID,
			() => LayoutCatalogue_ReadInstalled(LayoutRegistry_LocalDir(_ConfigDir))),
		_HotstringExtensionPacks, LayoutRegistry_BundledDir()),
	"emulated", Features["layout"]["ergopti_base"],
	"keycodes", LayoutRegistry_Keycodes(),
	"detect", LayoutRegistry_DetectMagicKeyScan.Bind(_LAYOUT_REMAP_HKL, ScriptInformation["MagicKeySourceChar"]),
	"shipped", LayoutRegistry_ShippedMagicKey))
ScriptInformation["MagicKeySourceScan"] := _MagicKeySource["scan"]
ScriptInformation["MagicKeySourceFollowsOsLayout"] := _MagicKeySource["follows_os_layout"]
ScriptInformation["MagicKeySourceOverridesEmulation"] := _MagicKeySource["overrides_emulation"]
LoggerInfo("ErgoptiPlus", "Magic-key source: {1} ({2}).", _MagicKeySource["scan"], _MagicKeySource["origin"])

BootProfile_StageEnd("magic key source", _MagicKeySource["origin"])
if ConfigFullStateCanPersist() {
	if !_ConfigQueueFullSave(CONFIG_FULL_SAVE_BOOT_DELAY_MS, 0, false)
		ConfigReportPersistenceFailure("the boot full-configuration save wake-up")
}

; HookDispatcher owns the process-wide mouse Hotkeys consumed by four independent
; features (hotstring prefix-watcher click-reset, CapsWord cancel, gesture
; click-toggle cross-release, LLM tooltip dismiss-on-click). None of those are
; gated by the keylogger/metrics flag, so Start() must be unconditional here.
; Start() is idempotent (guarded by _started), so a stray second call is harmless.
; HookDispatcher.Stop() is called by Ergopti_OnShutdown (already registered via
; OnExit) — do NOT register a second anonymous OnExit lambda here; double-Stop
; can trigger a "hook already released" error on some AHK builds.
BootProfile_StageBegin("keyboard hook")
if !HookDispatcher.Start() {
		; The shared hook is the driver’s keyboard ownership boundary. Publishing
		; readiness without it would create a half-boot where menu/UI state looks
		; healthy but remaps and hook consumers silently never receive input.
		LoggerError("ErgoptiPlus", "Startup aborted: unified keyboard hook could not start.")
		ExitApp(1)
}
BootProfile_StageEnd("keyboard hook", "unified hook armed")

BootProfile_StageBegin("metrics")

if MetricsShortcuts.enabled {
		LoggerDebug("Startup", "Metrics enabled — WPMWidget.visible={1}, show_graph={2}.",
				WPMWidget.visible, WPMWidget.show_graph)
		; Refresh one canonical focus snapshot from a resident periodic timer. The
		; title transaction has an OS-enforced deadline and every partial identity is
		; published invalid, so same-thread keyboard consumers remain bounded and
		; privacy fail-closed. Arm inside the metrics gate and BEFORE KL_Init: with
		; metrics off, no consumer needs this snapshot.
		MF_StartFocusRefresh()
		; (The WebView2 widget cold-start is armed at the very END of boot — after
		; "Driver fully initialised" — NOT here. A timer armed mid-boot fires ~its
		; delay later, while the hotstring registration is still running, and AHK
		; preempts that auto-execute thread to run it: WebView2's ~3 s startup gets
		; dragged back onto the critical path, AND the interruption pumps the message
		; queue, painting a tray click queued during boot against a half-built menu.
		; See the deferred-task block after LoggerSuccess("…ready").)
		KeyloggerReady := false
		try KeyloggerReady := KL_Init(KL_MetricsDirFor(_ConfigDir))
		catch as Err
			try LoggerError("Keylogger", "Initialization failed: {1}.", Err.Message)
		if !KeyloggerReady {
			LoggerError("ErgoptiPlus",
				"Startup aborted because keylogger persistence is unavailable.")
			ExitApp(1)
		}
		; HookDispatcher is already started unconditionally above.
		KL_Hook_Start()
		KL_Watchers_Start()
		KL_Mouse_Start()
		KL_Sensors_Start()
		KL_Topo_Start()
		KL_AV_Start()
		KL_Net_Start()
		KL_Clip_Start()
		KL_Roi_Start()
}

BootProfile_StageEnd("metrics", MetricsShortcuts.enabled ? "keylogger and sensors started" : "metrics disabled")
BootProfile_Mark("Metrics/keylogger started")








#Include ui/editors.ahk




#Include ui/action_picker/init.ahk
#Include ui/action_picker_webview.ahk
#Include ui/paths_editor/init.ahk
#Include ui/layout_manager/init.ahk
#Include ui/personal_info_editor/init.ahk
#Include ui/layer_editor/init.ahk

#Include infra/suppressive_inputhook_ownership.ahk

#Include infra/script_altgr_hotkeys.ahk
BootProfile_StageBegin("layout and remaps")
_RegisterScriptAltGrHotkeys()
; Before modules/keymap/layout.ahk: AHK fires the earliest-created hotkey variant
; whose criterion holds, so the registry layout emulation must register first to
; own its keys over every Ergopti layer. A no-op when no registry layout is chosen.
KeylayoutEmulation_Boot(_ConfigDir)
BootProfile_Mark("LAYOUT: registry emulation registered")

; Personal hotstrings are loaded exactly once, inside RegisterAllHotstrings()
; below. There used to be an inline forward-order load here at #InputLevel 0,
; but personal hotstrings register through HSE (CreateHotstring → HSE_Register),
; not AHK-native Hotstring(), so #InputLevel never applied to them — the inline
; loop was a pre-HSE leftover that double-registered all 263 personal specs and
; re-parsed their TOML on every boot/reload. RegisterAllHotstrings now loads
; them in forward order so first-declared (prominent) sections win HSE's
; first-registered-wins collision tiebreak, matching the old effective order.
#InputLevel 2
; The number-row tap keys first: AutoHotkey fires the earliest-created eligible
; #HotIf variant of a hotkey, and the digit-row emulation below binds the same
; three scancodes. Their assignments are read before a press can reach them.
#Include modules/shortcuts/tap_keys.ahk
; The key combinations: their slots are read before the pair hotkeys of
; platform/remap.ahk can answer a press.
#Include modules/keymap/layout.ahk
BootProfile_Mark("LAYOUT: Ergopti layout registered")
#Include modules/shortcuts.ahk
BootProfile_Mark("LAYOUT: shortcut modules registered")
#Include platform/remap.ahk
BootProfile_Mark("LAYOUT: tap-holds and navigation registered")
#Include modules/hotstrings.ahk
MagicEditorStart()
; The module now only DEFINES RegisterAllHotstrings(); invoke it here so the
; registration runs at the same boot point (and A_InputLevel) as before the
; in-process refactor. A_InputLevel is still 2 from the #InputLevel 2 above.
; Split the former single "hotstrings + prefix watcher" mark into three so the
; boot log bisects the late-startup cost: everything since the last mark (the
; layout / shortcuts / tap-hold / AltGr module includes registered above), then
; the ~5400-hotstring HSE registration, then the prefix-watcher index build. A
; micro-bench (tests/bench_boot_hotstrings.ahk) shows magic-key text expansion is
; the heaviest registration category by a wide margin.
BootProfile_StageEnd("layout and remaps")
BootProfile_Mark("Layout/shortcuts/tap-holds + AltGr registered")
; Clear any phantom modifier carried across a Reload BEFORE the input hook starts
; observing keystrokes, so a Reload that landed mid-AltGr cannot leave this fresh
; process stuck on the AltGr layer for the first keystrokes (transient
; « AltGr bloqué »). See _ReleasePhantomModifiers in infra/lifecycle.ahk.
_ReleasePhantomModifiers()
; Ready is an output contract: every advertised trigger, including emoji/symbol
; sections and its preview index, must exist before the driver publishes ready.
; Deferring these ~3000 registrations after ready made a first emoji/symbol trigger
; literal for seconds and allowed the timer to stall the first typing burst.
BootProfile_StageBegin("hotstrings")
RegisterAllHotstrings(false)
BootProfile_StageEnd("hotstrings")
BootProfile_Mark("Hotstrings registered (HSE complete)")
BootProfile_StageBegin("prefix watcher")
HotstringPrefixWatcherInit()
; Install the shared low-level keyboard arbiter after the prefix InputHook. Its
; terminal capture then runs first in the hook chain and can hold physical edges
; while paced terminal output completes. A failed native admission is reported
; by the adapter and terminal expansions remain fail-open.
LLM_NavEventOwner_EnsureStarted()
HotstringPrefixWatcherRebuildIndex()
BootProfile_StageEnd("prefix watcher")
BootProfile_Mark("Prefix watcher index complete")
SuspendWatchdogStart()
_SuspendStateWatchdog()
_DriverInputInitPending := false
#InputLevel 0
LLM_Menu_ActivateRuntime()
_DriverReady := true
if _LLM_Menu_RuntimeActivated
	_MenuStartupCommands.NotifyReady()
_MenuPopulationPublished.Start()
_DriverBootPhase := "ready"
LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")
; Release retained lifecycle commands only after real input readiness.
_TrayStartupCommands.NotifyReady()
_BootTotalMs := BootProfile_TotalBootMs()
_BootOpenStages := BootProfile_OpenStageNames()
if (_BootOpenStages != "")
	LoggerWarn("BootProfile", "Boot completed with unclosed stage(s): {1}.", _BootOpenStages)
LoggerInfo("BootProfile", "Boot complete in {1} ms (since process start).", _BootTotalMs)
; One environment summary with the same field names on every driver. A probe
; failure is reported and never allowed to turn a ready driver into a dead one.
try DiagSnapshot_Emit(_BootTotalMs)
catch as _SnapshotErr
	LoggerError("Diagnostics", "Diagnostic snapshot could not be collected: {1}.", _SnapshotErr.Message)
if (_DriverStartupSmokeDir != "") {
		_StartupSmokeExpectedSuspend :=
				EnvGet("ERGOPTI_STARTUP_SMOKE_EXPECT_SUSPENDED") == "1"
		if _StartupSmokeExpectedSuspend {
				_StartupSmokeSuspendStarted := A_TickCount
				while (!A_IsSuspended
						and !TickExpired(_StartupSmokeSuspendStarted, 750))
						Sleep(20)
				if !A_IsSuspended
						throw Error("suspend marker was not restored before ready")
		}
		; The complete configured root precedes input registration, including a
		; paused reload. Reaching ready alone cannot prove that publication order.
		if !_DriverMenuReady
				throw Error("the complete configured menu was not published before input readiness")
		if IsSet(_DriverStartupSmokeInspectAdmission)
				_DriverStartupSmokeInspectAdmission.Call()
		; The same driver must come back from that pause: lift it and wait for the
		; AI hotkeys its paused build deferred. Any error the resume logs fails
		; the fixture like any other.
		if _StartupSmokeExpectedSuspend {
				ToggleSuspend()
				_StartupSmokeResumeStarted := A_TickCount
				while ((A_IsSuspended or _LLM_Menu_FirstRestoreHotkeysDeferred)
						and !TickExpired(_StartupSmokeResumeStarted, 3000))
						Sleep(20)
				if A_IsSuspended
						throw Error("the restored pause could not be lifted")
				if _LLM_Menu_FirstRestoreHotkeysDeferred
						throw Error("the AI hotkeys deferred by the pause were not activated on resume")
		}
		; #NoTrayIcon hides every process's icon at load; the driver path alone
		; reveals it. A driver that reaches ready without it has no tray at all.
		if A_IconHidden
				throw Error("the driver reached ready without revealing its tray icon")
		; The isolated wrapper can inspect the ready registry before ExitProcess
		; deliberately bypasses production teardown and OnExit callbacks.
		if IsSet(_DriverStartupSmokeInspect)
				_DriverStartupSmokeInspect.Call()
		if !LoggerPrepareShutdown(&_StartupSmokeLoggerRefusal) {
				; The smoke already retains stdout on failure; never enqueue more debt.
				try FileAppend("startup-smoke-logger-refusal: phase="
						. _StartupSmokeLoggerRefusal["phase"]
						. " flush_active=" . _StartupSmokeLoggerRefusal["flush_active"]
						. " force_flush_pending=" . _StartupSmokeLoggerRefusal["force_flush_pending"]
						. " append_owners=" . _StartupSmokeLoggerRefusal["append_owners"]
						. " append_debts=" . _StartupSmokeLoggerRefusal["append_debts"]
						. " append_repairs=" . _StartupSmokeLoggerRefusal["append_repairs"]
						. " main_lines=" . _StartupSmokeLoggerRefusal["main_lines"]
						. " error_lines=" . _StartupSmokeLoggerRefusal["error_lines"]
						. " topical_queues=" . _StartupSmokeLoggerRefusal["topical_queues"]
						. " topical_lines=" . _StartupSmokeLoggerRefusal["topical_lines"] . "`n",
						"*", "UTF-8-RAW")
				throw Error("The startup smoke could not make its diagnostic logs durable.")
		}
		_StartupSmokeNonce := EnvGet("ERGOPTI_STARTUP_SMOKE_NONCE")
		if _StartupSmokeNonce != ""
				StartupSmokePublishReady(_DriverStartupSmokeDir, _StartupSmokeNonce, true)
		if EnvGet("ERGOPTI_STARTUP_SMOKE_ACK") == "1"
				StartupSmokeAwaitObserver(_DriverStartupSmokeDir, _StartupSmokeNonce)
		; This isolated probe has just materialised a deep native Menu tree and must
		; not run the production OnExit teardown against test-only paths/owners. AHK's
		; immediate destruction of that fresh tree can itself raise STATUS_HEAP_CORRUPTION
		; while the OS is already ending the disposable process. ExitProcess preserves
		; the startup verdict without turning teardown into an unrelated smoke target.
		DllCall("ExitProcess", "UInt", 0)
}

; A last-known-good rollback copy first becomes a fully functional driver. Only
; after the ready contract exists may it republish itself atomically to the
; canonical Current.exe and request the guarded OnExit handoff. A canonical
; Current.exe similarly retires the old recovery copy only after it is ready.
_Updater_ArmRecoveryMaintenanceAfterReady()
_Updater_ArmInheritedSwapFailureNotice()

; Warm the persistent selection worker after the ready contract is published.
; Its dedicated source entry parses only UIA + the worker, so this does not
; replay the full driver boot, and no provider call happens until an idle-gated
; request arrives. Starting it here prevents the first wrap action after a
; reload from racing a cold worker process.
if Features.Has("shortcuts") && Features["shortcuts"].Has("wrap_text_if_selected")
	&& Features["shortcuts"]["wrap_text_if_selected"]
	SetTimer(UIASW_Start, -1)

if _DriverStartupSmokeDir == "" && IsCategoryGated("Hotstrings")
	SetTimer(TooltipPositionWarmStart, -1)

; ── Deferred post-"ready" tasks ──────────────────────────────────────────────
; All the heavy off-critical-path work is armed HERE, after the driver is ready,
; rather than mid-boot. A SetTimer armed earlier fires ~its-delay later and AHK
; preempts the still-running auto-execute (the ~5400-hotstring registration) to
; run it — which (a) drags heavy work like the WebView2 cold-start back into
; contention with registration, and (b) pumps the message queue mid-boot, so a
; heavy background work competes with the first native menu. Arming after
; "ready" leaves early publication free of optional provider and widget work.
;
; Order by delay so the passes never contend (same-priority AHK timers serialise,
; they never preempt one another): the LLM submenu populates first (fast, so its
; dropdown is ready), then the text-expansion pass (core magic-key abbreviations,
; brought online quickly), then the emoji/symbol pass, then the WebView2 widget
; last (its delay clears the registration passes).
; The configured root and language rows are already published. Only remaining
; native leaf rows and optional post-ready work need the idle message loop.
; Obsolete configuration keys are a maintenance task, not a runtime error.
; Offer the existing backed-up cleanup only after the driver is ready.
SetTimer(ConfigUnusedKeysOffer.Bind(ConfigurationFile), -MENU_BUILD_DEFER_MS)
if _LangMenuBuildPending
	SetTimer(BuildLanguageMenuDeferred, -LANG_MENU_DEFER_MS)
; The deferred boot worker owns the OFF-state IA population. It arms that
; request only after the initial root publishes, so the LLM timer cannot
; invalidate the boot generation and force a duplicate full submenu scan. The
; enabled path is still owned by asynchronous dependency readiness.
; Warm the i18n EN/FR fallback caches off the critical path (the active locale is
; already parsed at boot). One JSON parse, only consulted on a missing key; a miss
; before this fires triggers a one-time lazy load inside t().
SetTimer(I18nWarmFallbacks, -I18N_FALLBACK_WARM_DELAY_MS)
; Hotstrings and their preview index were completed before ready above. Do not arm a
; duplicate post-ready registration timer: even a no-op timer can contend with the
; first keystroke and must not define feature availability.
if (MetricsShortcuts.enabled and WPMWidget.visible) {
	; Graph mode: pre-create the GDI+ layered window + warm GDI+ in the quiet slot
	; before the emoji pass, so its one-time DWM allocation is paid off the typing
	; path rather than as a ~110 ms tooltip blip when the widget first appears.
	if WPMWidget.show_graph
		SetTimer(WPMWidget_PrewarmGraph, -WPMWidgetConst.PREWARM_DELAY_MS)
	SetTimer(WPMWidget_Show, -WPMWidgetConst.BOOT_SHOW_DELAY_MS)
}
; Publish the metrics dashboards' sidecars in a background worker once boot has
; settled, so the first open paints from disk at once instead of waiting for a
; cold projection (keylogger_webview.ahk, background sidecar warm-up).
if MetricsShortcuts.enabled
	KLWV_WarmSchedule(KL_MetricsDirFor(_ConfigDir), KLWV.WARM_START_DELAY_MS)

global _LAYOUT_POLL_INTERVAL_MS := 1000
; The baseline is the layout the boot registrations were built for, the one the
; boot probe decided the AltGr family on, not a second read: a switch made
; during the seconds of boot then shows up as a change, and reloads when those
; registrations do not fit the new layout (LayoutRemapNeedsReload).
global _LAST_KEYBOARD_HKL := _LAYOUT_REMAP_HKL
global _PENDING_KEYBOARD_HKL := 0

; The quiescence decision is a pure function extracted to infra/ so the headless
; test suite can exercise it without #including this whole entry point (which
; registers every hotkey at load). Single source of truth — defined once there,
; consumed here and by tests/meta/test_layout_quiescence.ahk.
#Include modules/keymap/layout_poll_helper.ahk

; The layout poll's seams onto the reload lifecycle (see LayoutPollTick). Its
; reload reports a refused stage without the "save failed" notice, and it asks
; whether OnExit could still refuse before starting one.
LayoutPollPort() {
		static Port := Map(
				"needs_reload", LayoutRemapNeedsReload,
				"reload", (RefusedFn) => ReloadPreservingSuspend(0, 0, RefusedFn, LayoutPollStageRefused),
				"pending", ReloadTerminalHandoffPending,
				"veto_honored", LifecycleShutdownVetoHonored,
				"now", () => A_TickCount,
				"notify", ReloadRefusedNotify)
		return Port
}

CheckKeyboardLayoutChange() {
		global HSE_Suppressed, _PrefixWatcherSuppressed
		
		suspended := A_IsSuspended
		isBlacklisted := false
		try {
				if IsSet(MF_ShouldFilter) && MF_ShouldFilter()
						isBlacklisted := true
		}
		
		curHkl := GetForegroundKeyboardLayout()
		; The AltGr family follows the foreground layout without a reload. The
		; foreground hook switches it with the window; this catches what that
		; hook cannot see: a layout switched inside one window (Win+Space), or a
		; UWP app whose focused control settles on its own thread after the event.
		AltGrFamilyFollow(curHkl)
		hseSup := (IsSet(HSE_Suppressed)) ? HSE_Suppressed : 0
		pwSup := (IsSet(_PrefixWatcherSuppressed)) ? _PrefixWatcherSuppressed : 0
	inputBusy := (IsSet(InDeadKeySequence) and InDeadKeySequence)
		or (IsSet(_SpaceHoldInputHook) and IsObject(_SpaceHoldInputHook))
		or SIHO_HasActive()
		or GetKeyState("SC039", "P") or GetKeyState("SC038", "P") or GetKeyState("SC138", "P")
		
		LayoutPollTick(curHkl, suspended, isBlacklisted, hseSup, pwSup, A_TimeIdlePhysical,
				inputBusy, LayoutPollPort())
}
AltGrFamilyStartFollowing()
SetTimer(CheckKeyboardLayoutChange, _LAYOUT_POLL_INTERVAL_MS)
