; Last modified on 2026-04-23 at 00:00 (UTC+2)
#Requires Autohotkey v2.0+
#SingleInstance Force ; Ensure that only one instance of the script can run at once
SetWorkingDir(A_ScriptDir) ; Set the working directory where the script is located

; --- Single-owner gate: establish exclusivity BEFORE any hook/log/message pump ---
; #SingleInstance Force only replaces the previous instance at the END of THIS
; script's load (~875-1460 ms parse), and terminating a hung/dialog-blocked old
; instance is best-effort — so during a rapid double-launch two processes can
; briefly co-own the keyboard hook and the log (observed in the field: interleaved
; duplicate log lines for minutes, and a boot killed mid-registration with hotkeys
; already armed). Acquire a named session-local mutex here — the first auto-execute
; statement, before the Bundle_Init RunWait step pumps messages — and, when a
; previous instance still owns it, WAIT a bounded time for it to exit before we register
; anything. We never ExitApp on contention (that would fight #SingleInstance Force,
; which wants THIS instance to win); the bounded wait plus the Force backstop keep a
; single live hook/log owner in the common case. The handle is intentionally never
; closed: the OS releases the mutex when this process exits, so a successor's wait
; unblocks the instant we die.
;
; EXEMPT: the detached keylogger-prefetch worker. The driver deliberately
; re-runs this entry with /force and --keylogger-prefetch-worker to compute a
; metrics projection; that worker registers no hook, no log owner and no tray,
; so it is not what this gate exists to prevent. But the gate is the FIRST
; auto-execute statement while the worker's own gate sits ~300 lines below, so
; every worker spawned while the driver is alive blocked the full wait on the
; live driver's mutex, timed out and ExitApp(0)'d before reaching its main —
; the projection could never publish. KLPF_IsWorkerInvocation reads only
; A_Args and its definition is hoisted, so it is callable here.
global DRIVER_MUTEX_NAME := "Local\ErgoptiPlusDriver"
global DRIVER_MUTEX_WAIT_MS := 3000 ; max boot delay while a previous instance exits
global _DriverMutexHandle := 0
if !KLPF_IsWorkerInvocation()
	_DriverMutexHandle := DllCall("CreateMutexW", "Ptr", 0, "Int", 0, "Str", DRIVER_MUTEX_NAME, "Ptr")
if (_DriverMutexHandle) {
	; Take ownership, waiting (bounded) for any previous owner to release it (exit).
	; 0 = WAIT_OBJECT_0 (acquired), 0x80 = WAIT_ABANDONED (prior owner died holding it
	; — also acquired), 0x102 = WAIT_TIMEOUT (another instance is STILL ALIVE and owns it).
	_DriverMutexWait := DllCall("WaitForSingleObject", "Ptr", _DriverMutexHandle, "UInt", DRIVER_MUTEX_WAIT_MS, "UInt")
	if (_DriverMutexWait == 0x102) {
		; A live owner remains, so #SingleInstance Force did NOT replace it — its
		; replacement races when several instances are launched at once. YIELD: exit
		; before registering a single hook. Continuing here (the previous behaviour)
		; is exactly what let a rapid multi-launch put N keyboard hooks on one machine
		; and hang it. Trade-off: if Force loses that race on a legitimate relaunch,
		; the new instance yields and the OLD one keeps running (quit + relaunch to
		; apply changes) — vastly preferable to N live hook owners.
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
		; A_AppData is a built-in needing no bootstrap, and A_AppData\Ergopti is
		; already where paths.toml lives, so this sink is reachable before any
		; path resolution and never collides with the live owner's log files.
		try {
			_YieldDir := A_AppData . "\Ergopti"
			if !DirExist(_YieldDir)
				DirCreate(_YieldDir)
			FileAppend(FormatTime(A_Now, "yyyy-MM-dd HH:mm:ss")
				. " [WARNING] [ErgoptiPlus] Another instance owns the single-owner mutex after "
				. DRIVER_MUTEX_WAIT_MS . " ms; yielding without registering any hook.`r`n",
				_YieldDir . "\bootstrap.log", "UTF-8")
		}
		ExitApp(0)
	}
}

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
try ProcessSetPriority(DRIVER_BASELINE_PRIORITY_CLASS)

; Globals referenced by ``#HotIf`` expressions across the driver. They MUST
; be assigned before any code that pumps the message loop runs — otherwise
; AHK throws "global variable has not been assigned a value" the first time
; a keystroke during early init causes a #HotIf expression to be evaluated.
;
; ``Bundle_Init()`` below shells out to PowerShell via ``RunWait`` (see
; ``lib/bundle.ahk``), and RunWait pumps messages. Any key pressed during the
; ~250ms unzip would otherwise trigger #HotIf evaluation on hotkeys like
; ``#HotIf CapsWordEnabled`` or ``#HotIf LayerEnabled`` while those globals
; are still unset — assigning them here keeps the very first message pump
; well-formed.
global CapsWordEnabled := False
global LayerEnabled := False
global TapHold := Map("keys", Map(), "layers", Map())
; Read in FIRST position by a parse-time #HotIf (modules/tap_holds/altgr.ahk), which
; can be evaluated during Bundle_Init's message-pumping RunWait — long before
; lib/hotstrings/hotstring_engine.ahk's include position. Seed it here so that #HotIf
; short-circuits to false instead of throwing; HotstringEngineInit() resolves the
; real value (auto-probe + TOML override) later in boot.
global _ALTGR_KANA_FIXUP := False
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
#Include lib/manifest_reader.ahk
#Include lib/feature_io.ahk

; ===== Global error net — armed BEFORE the first message pump =====
; Without this, any uncaught error pops an AHK dialog mid-keystroke and can leave
; modifiers stuck down. We log and continue so one bad callback never locks the
; keyboard. The handler must return true to consider the error "handled".
; It MUST be armed here, above Bundle_Init(): that call shells out through RunWait,
; which PUMPS MESSAGES, so a key pressed during the extraction can evaluate a
; parse-time #HotIf and throw with no net at all. error_net.ahk has no dependency
; that prevents loading it this early — its Logger calls are try-wrapped and function
; definitions are hoisted across the whole #Include graph before auto-execute runs.
#Include lib/error_net.ahk
OnError(ErgoptiGlobalErrorHandler)

; In compiled mode the .exe ships an embedded zip of every runtime asset
; (hotstrings TOMLs, locales, icons, _shared tree, vendor DLLs). The bundle
; bootstrapper extracts it next to the .exe on first launch so the rest of
; the driver can keep reading from _StaticDir without caring whether it runs
; from source or from a compiled binary. In dev mode Bundle_Init() is a no-op.
#Include lib/bundle.ahk
Bundle_Init()
; First of the retroactive boot stamps (lib/boot_profiler.ahk). Everything from
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
; *i = no error if the file isn't found. UIA is only used by WrapTextIfSelected
; (a Shift/AltGr shortcut that wraps the selection with the typed symbol). If
; that feature is disabled in your INI and you want to trim boot time / memory,
; you can safely delete ``vendor\UIA.ahk``: WrapTextIfSelected falls back to
; a plain SendNewResult via ``isSet(UIA)`` at the call site (see modules/keymap/layout.ahk).
; AHK v2 resolves #Include at parse time, so there is no true runtime lazy-load.

; The global error net itself is armed far above, before Bundle_Init()'s
; message-pumping RunWait — see the "Global error net" block there.
#Include lib/personal_features.ahk
#Include lib/menu_helpers.ahk

; #Hotstring EndChars -()[]{}:;'"/\,.?!`n`s`t   ; Adds the no breaking spaces as hotstrings triggers
A_MenuMaskKey := "vkff" ; Change the masking key to the void key
A_MaxHotkeysPerInterval := 150 ; Reduce messages saying too many hotkeys pressed in the interval

; AHK silently DROPS new pseudo-threads (hotkey callbacks, tray-menu items,
; OnMessage handlers, SetTimer callbacks) once A_MaxThreads concurrent
; threads are already active. The default ceiling of 10 is easy to hit
; with the keylogger's ~6 background timers + mouse/keyboard hooks. The
; menu-dispatcher bypass in lib/menu_dispatcher.ahk also relies on a free
; slot for its retry SetTimer, so the headroom matters even more there.
A_MaxThreads := 64

SetKeyDelay(0) ; No delay between key presses
SendMode("Event") ; Everything concerning hotstrings MUST use SendEvent and not SendInput which is the default
; Otherwise, we can't have a hotstring triggering another hotstring, triggering another hotstring, etc.

; Logger pulled in first so every other lib/module can call it during init.
; ``LoggerInit()`` is invoked after the configuration file is parsed so the
; minimum log level can be honoured from the very first INFO/START line.
#Include lib/logger.ahk
#Include lib/boot_profiler.ahk
#Include lib/hotpath_profiler.ahk
#Include lib/registry.ahk
#Include lib/app_state.ahk

; Port adapters — thin OS wrappers that isolate every DllCall, Send*, and
; WinGet* from the domain modules. Loaded before any lib/ or module/ file
; that references adapter functions (e.g. NI_GetSsidHash in keylogger_network).
#Include adapters/crypto.ahk
#Include adapters/clipboard.ahk
#Include adapters/timer_scheduler.ahk
#Include adapters/file_system.ahk
#Include adapters/window_info.ahk
#Include adapters/notifier.ahk
#Include adapters/tray_menu.ahk
#Include adapters/text_sender.ahk
#Include adapters/http_client.ahk
#Include adapters/secure_field_detector.ahk
#Include adapters/storage.ahk
#Include adapters/process_lifecycle.ahk
#Include adapters/key_state.ahk
#Include adapters/app_launcher.ahk
#Include adapters/network_info.ahk
#Include adapters/keyboard_hook.ahk
#Include adapters/mouse_control.ahk
#Include adapters/window_manager.ahk
#Include adapters/graphics_renderer.ahk
#Include adapters/tooltip_renderer.ahk
#Include adapters/shell_runner.ahk

; INI helpers extracted to their own lib so the test runner can ``#Include``
; them without bootstrapping the rest of the driver.
#Include lib/toml/toml_helpers.ahk
; Shared timing registry reader (TimingsLoadShared / TimingsGet). Needs
; ParseTomlFile (above); consumed by the reassign-at-boot loaders below.
#Include lib/timings/timings_config.ahk
#Include modules/keymap/layout/layout_ergopti.ahk

; Active-app cache must come before hotstring_engine.ahk because both
; ``HotstringHandler`` and ``MicrosoftApps``.
#Include lib/window_utils.ahk
#Include lib/text_utils.ahk
#Include ui/spotlight/init.ahk
#Include lib/nav_layer_helpers.ahk

; Core hotstring engine (send primitives, hotstring builders, text helpers)
; and TOML reader helpers (UnescapeTomlString, LoadHotstringsSection,
; FoldAsciiLower) extracted into dedicated submodules so the main file
; stays focused on ErgoptiPlus-specific logic.
#Include lib/hotstrings/hotstring_engine.ahk
#Include lib/hotstrings/hotstring_engine_main.ahk
#Include lib/hotstrings/hotstring_buffer_effects.ahk
#Include lib/hotstrings/hotstring_live_toggle.ahk
#Include lib/hotstrings/hotstring_count_policy.ahk
; Generated terminator catalogue (single source of truth — shared with macOS via
; _shared/core/domain/Terminators.spec.js). Both the tray and config-window delimiter
; menus render this catalogue so the word-terminator list never drifts between
; drivers. Included before the menus and before HSE_Terminators is instantiated.
#Include _generated/terminators.ahk
#Include lib/toml/toml_loader.ahk
#Include lib/toml/toml_config_loader.ahk
; manifest_reader.ahk + feature_io.ahk are loaded at the top of the file so
; Features / feature-IO functions are available before any #HotIf expression is
; evaluated. Re-listing them here would cause AHK to complain about the same
; script being included twice.
#Include lib/first_boot.ahk
#Include lib/tap_hold/tap_hold_loader.ahk
#Include lib/tap_hold/tap_hold_writer.ahk
; Tap-hold timing constants must load HERE, before lib/boot.ahk calls
; TapHoldsLoadTimings(): AHK v2 executes a file's top-level `global X := sentinel`
; assignments at its #Include position, so if constants.ahk loaded at its natural
; spot (inside modules/tap_holds.ahk, far below boot.ahk) the sentinel 0s would
; re-clobber the registry values boot.ahk just loaded. #Include dedupes by path,
; so the later include via modules/tap_holds.ahk is a no-op (mirrors the
; DYN_HOTSTRINGS_DEFAULT_DELAY early-layer precedent).
#Include modules/tap_holds/constants.ahk
#Include lib/master_gates.ahk
#Include lib/manifest_descriptions.ahk
#Include lib/menu_dispatcher.ahk
#Include lib/hook_dispatcher.ahk
#Include lib/menu_manifest.ahk
#Include lib/manifest_menu.ahk
#Include lib/llm_defaults.ahk
#Include lib/updater.ahk
#Include ui/changelog/init.ahk
#Include ui/healthcheck/init.ahk
#Include lib/crash_reporter.ahk
#Include lib/json.ahk
; i18n layer — must come after toml_loader.ahk (TOML_BatchWrite), logger.ahk, and json.ahk.
; locale.ahk (string loading + t()) precedes i18n.ahk (locale management), which calls into it.
#Include lib/locale.ahk
#Include lib/i18n.ahk
#Include ui/onboarding/init.ahk
#Include lib/hotstrings/hotstrings_config.ahk
#Include ui/hotstrings_config_window/init.ahk
#Include ui/hotstrings_config_window/webview.ahk
#Include ui/prompt_editor/init.ahk
#Include lib/wrap_symbols_config.ahk
#Include lib/ui_style.ahk
#Include ui/tooltip/init.ahk
#Include lib/llm_diff.ahk
#Include lib/hotstrings/hotstring_prefix_watcher.ahk
; Self-healing hotstring cache for the bundled TOMLs. Replaces the old ~1 MB of
; committed generated_*.ahk (tokenised at boot, before the tray icon could appear)
; with a gitignored flat .tsv read at registration — the same pattern as the i18n
; locale cache. LoadHotstringsSection ensures + consults it, falling back to the
; runtime TOML parser on a cache miss. No generated CODE is kept in the repo.
#Include lib/hotstrings/hotstrings_cache.ahk
#Include ui/personal_toml_editor.ahk
#Include ui/personal_toml_editor_webview.ahk
#Include modules/keymap/layout/layout_altgr.ahk
#Include modules/keymap/layout/layout_shift_caps.ahk
#Include lib/app_picker.ahk
#Include lib/config_shortcuts.ahk
#Include lib/metrics/metrics_shortcuts.ahk
#Include lib/metrics/metrics_filters.ahk
#Include ui/wpm/init.ahk
#Include lib/sqlite3.ahk
#Include vendor/ComVar.ahk
#Include vendor/Promise.ahk
#Include vendor/WebView2.ahk
#Include lib/webview_utils.ahk
#Include modules/keylogger/keylogger_app_categories.ahk
#Include modules/keylogger/keylogger.ahk
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

; A detached prefetch worker shares these projection modules but must never run
; the normal driver boot: no hooks, timers, tray, WebView, or config mutation.
; It publishes one staged JSON file and exits; the live instance validates the
; generation before atomically making that file visible to a dashboard.
if KLPF_IsWorkerInvocation()
		KLPF_WorkerMain()

#Include _generated/prompt_builder.ahk
#Include modules/llm/api_common.ahk
#Include modules/llm/api_token_crypto.ahk
#Include modules/llm/api_ollama.ahk
#Include modules/llm/parser.ahk
#Include modules/llm/api_remote.ahk
#Include modules/llm/models.ahk
; LLM_GetSharedPath is now available — load the cross-platform defaults before
; prediction_engine.ahk and menu_llm.ahk initialise their state maps.
LLM_Defaults_Load()
#Include _generated/llm_profiles_data.ahk
#Include modules/llm/profiles.ahk
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

#Include lib/boot.ahk

#Include lib/feature_state.ahk

; AHK-21: clear the stock AHK tray items (Pause/Suspend/Reload/Exit/Edit)
; BEFORE the blocking onboarding wizard so those stock actions are never live
; during first-run setup. On a normal (non-first-run) boot Onboarding_Run is
; a no-op, so this move is safe — and it closes the brief stock-menu window
; regardless of the boot path (normal OR first-run).
A_TrayMenu.Delete()
Onboarding_Run()
; Blocking on a first run, a no-op otherwise — which is exactly why it needs its
; own stamp: a first-run boot and a normal boot are otherwise indistinguishable
; in the timings.
BootProfile_Stamp("Tray reset + onboarding")

global _IniCache := ParseTomlFile(ConfigurationFile)
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
ReadCategoryEnabled(_IniCache)
I18nInit(_IniCache)
BootProfile_Stamp("Config parsed (TOML + i18n)")

; Resolve _ALTGR_KANA_FIXUP: TOML override (ScriptInformation["AltGrIsKanaRemap"])
; wins when set; otherwise auto-detect via the reverse VK_RMENU→SC probe. Must
; run before the first hotstring fires. The layout-poll timer at the bottom of
; this file triggers a full Reload() on layout switch, so this re-runs and
; adapts to the new layout automatically.
HotstringEngineInit()
BootProfile_Stamp("Hotstring engine initialised")

; Initialise the logger now that the ini cache is built and ScriptInformation
; reflects user overrides — LoggerInit reads [Script] LogLevel from the ini.
LoggerInit()
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
; diagnosed from the log alone (see lib/boot_profiler.ahk).
BootProfile_Begin()

; Eager-load the ACTIVE i18n locale now. It is otherwise lazy on the first t()
; call, which lands mid-config and buries its JSON parse inside a later, unrelated
; mark. The tray menu needs it within milliseconds anyway. Only the active locale
; is parsed here; the EN/FR fallbacks (consulted solely on a missing key) are
; warmed off the critical path by I18nWarmFallbacks() armed after "ready" — which
; halves the boot i18n cost on a complete locale (one parse instead of two).
I18nPreload()
BootProfile_Mark("i18n locale preloaded")

; Load tooltip visual constants from _shared/modules/tooltip/constants.toml so the
; runtime values stay in sync with the TOML single source of truth.
; Must run after _SharedDir is set (line ~51) and ParseTomlFile is available.
UiStyle_LoadSharedConst()
; Now that UI_AI_LOADING_HEX is loaded, source the llm_prediction hotstring tint
; from it (single canonical AI loading colour) — must run after the line above
; and before the tray menu build / any HotstringsResolve.
HotstringsConfigLoadLlmPredictionColor()

; Log both the raw reverse-probe result (VK_RMENU → SC) and the resolved
; Kana-remap flag so future regressions on exotic layouts surface immediately.
; SC=0 means VK_RMENU is not mapped → Kana-like remap; non-zero means RAlt
; exists on this layout → standard AltGr. The resolved flag also accounts for
; any manual TOML override from [Script] AltGrIsKanaRemap.
; HKL resolution + VK_RMENU reverse-probe live in adapters/key_state.ahk so the
; layout-detection DllCalls are isolated there, not inlined in the boot sequence.
_DetectHKL := KS_ResolveKeyboardLayout()
_DetectSC := KS_ProbeRightAltScancode(_DetectHKL)
LoggerInfo("AltGrDetect",
		"HKL=0x{1:X}, VK_RMENU→SC=0x{2:X}, _ALTGR_KANA_FIXUP={3}.",
		_DetectHKL, _DetectSC,
		_ALTGR_KANA_FIXUP ? "true" : "false")

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
EnsurePersonalInfoTomlFile(ScriptInformation["PersonalInfoTomlPath"])
ReadPersonalInfoToml(ScriptInformation["PersonalInfoTomlPath"])

EnsureUserConfigsExist()
; Guard: the generated manifest must be present and loaded before we build
; the Features Map. If it is missing (e.g. after a fresh clone or when the
; codegen has not been run yet), ManifestBuildFeaturesMap returns an empty
; Map and every downstream Features["llm"]["enabled"] access throws a
; cryptic "Item has no value" error. Fail loudly here instead.
if !ManifestEnsureLoaded() {
	MsgBox(t("startup.manifest_missing"), t("startup.manifest_title"), "OK Iconx")
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
ApplyConfigToml(Features, _ConfigDir . _AhkSubDir . "config.toml")
global TapHold := LoadTapHoldToml(_ConfigDir . _AhkSubDir . "tap_hold.toml",
	_SharedDir . "\tap_hold\defaults.toml")

; When Ergopti keyboard emulation is off, MagicKeySourceScan must point to
; the physical key that produces MagicKeySourceChar ("j" by default) on the
; user's active OS layout. On bépo, "j" lives on a different scancode than
; SC02E (the Ergopti/QWERTY position), so we probe the layout at startup.
;
; Strategy: enumerate scancodes 0x01→0x7F, call ToUnicodeEx on each with no
; modifiers, and pick the one whose output matches MagicKeySourceChar.
; VkKeyScanExW is not used here because it fails on layouts like bépo where
; the target character ("j") sits behind a driver-level remapping that the
; API cannot see.
;
; HKL resolution cascade: at script startup there may be no foreground window
; (AHK launches tray-only), so GetForegroundKeyboardLayout() returns 0.
; Fallback 1: GetKeyboardLayout(GetCurrentThreadId()) — layout of the AHK thread itself.
; Fallback 2: SystemParametersInfo(SPI_GETDEFAULTINPUTLANG) — system default.
; HKL resolution + the no-modifier scancode scan live in adapters/key_state.ahk
; so the layout-detection DllCalls (MapVirtualKeyExW / ToUnicodeEx) are isolated
; there; this boot step only interprets the result and updates ScriptInformation.
if !Features["layout"]["ergopti_base"] {
	_HKL := KS_ResolveKeyboardLayout()
	if _HKL != 0 {
		_TargetChar := ScriptInformation["MagicKeySourceChar"]
		_Found := KS_ScanScancodeForChar(_HKL, _TargetChar)
		if _Found["scan"] != 0 {
			ScriptInformation["MagicKeySourceScan"] := Format("SC{:03X}", _Found["scan"])
			LoggerInfo("ErgoptiPlus",
				"Magic-key source resolved from layout: char='{1}', VK=0x{2:X}, scan={3} (HKL=0x{4:X}).",
				_TargetChar, _Found["vk"], ScriptInformation["MagicKeySourceScan"], _HKL)
		} else {
			LoggerWarn("ErgoptiPlus",
				"Magic-key source: char '{1}' not found on any base scancode of layout"
				. " HKL=0x{2:X} — keeping default scan {3}.",
				_TargetChar, _HKL, ScriptInformation["MagicKeySourceScan"])
		}
	} else {
		LoggerWarn("ErgoptiPlus",
			"Magic-key source resolution skipped: could not obtain a valid HKL at startup"
			. " — keeping default scan {1}.",
			ScriptInformation["MagicKeySourceScan"])
	}
}


; Safe nested read
_SpaceAroundSymbolsNode := (Features.Has("hotstrings")
	and Features["hotstrings"].Has("distances_reduction")
	and Features["hotstrings"]["distances_reduction"].Has("space_around_symbols"))
	? Features["hotstrings"]["distances_reduction"]["space_around_symbols"]
	: Map()
global SpaceAroundSymbols := (_SpaceAroundSymbolsNode.Has("enabled") and _SpaceAroundSymbolsNode["enabled"]) ? " " : ""

#Include ui/tray_menu.ahk




EnsurePersonalShortcutsFile(Path, AllowReload := true) {
		global PERSONAL_SHORTCUTS_TEMPLATE
		if (!IsSet(Path) or Type(Path) != "String" or Path == "") {
				try LoggerWarn("ErgoptiPlus", "EnsurePersonalShortcutsFile called with empty Path — skipping.")
				return
		}
		FileWasCreated := false
		if !FileExist(Path) {
				try {
						Dir := RegExReplace(Path, "\\[^\\]+$", "")
						if (Dir != "" and !DirExist(Dir)) {
								DirCreate(Dir)
						}
						Template := IsSet(PERSONAL_SHORTCUTS_TEMPLATE) ? PERSONAL_SHORTCUTS_TEMPLATE : ""
						; Every generated AHK source must be UTF-8 with BOM and LF.
						; `UTF-8-RAW` silently creates a parser-risking BOM-less file.
						FileAppend(Template, Path, "UTF-8")
						FileWasCreated := true
						try LoggerInfo("ErgoptiPlus", "Personal shortcuts file created from template at '{1}'.", Path)
				} catch as e {
						try LoggerWarn("ErgoptiPlus", "Could not create personal shortcuts file at '{1}': {2}.",
								Path, e.Message)
						return
				}
		}
		StubDir := ""
		if A_IsCompiled {
				LocalAppData := ResolveLocalAppDataDir()
				if (LocalAppData == "") {
						try LoggerWarn("ErgoptiPlus", "EnsurePersonalShortcutsFile: cannot resolve LocalAppData — skipping stub creation.")
						return
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
				try Existing := FileRead(StubPath, "UTF-8-RAW")
		}
		StubMatches := (Existing == DesiredStub)
		if !StubMatches {
				try {
						if FileExist(StubPath) {
								FileDelete(StubPath)
						}
						FileAppend(DesiredStub, StubPath, "UTF-8")
						try LoggerInfo("ErgoptiPlus", "Personal shortcuts forwarding stub refreshed at '{1}'.", StubPath)
				} catch as e {
						try LoggerWarn("ErgoptiPlus", "Could not write forwarding stub at '{1}': {2}.",
								StubPath, e.Message)
						return
				}
		}
		if FileWasCreated or !StubMatches {
				if !AllowReload {
						; A runtime caller (the "open personal shortcuts" gesture/menu) wants to open
						; the file for editing, NOT restart the driver mid-session — the freshly
						; written file is an empty template, so nothing needs re-including before the
						; user has even edited it. Their next Reload picks up the edits.
						try LoggerInfo("ErgoptiPlus", "Personal shortcuts file/stub (re)created; skipping Reload (caller opted out).")
						return
				}
				try LoggerInfo("ErgoptiPlus", "Reloading to pick up freshly-written personal shortcuts chain.")
				Reload
				; Reload starts the replacement instance but returns to this
				; auto-execute thread. Continuing would register the old instance's
				; hooks/layout beside the replacement for one scheduling window.
				; Exit immediately: native input remains available until the new
				; process is ready, but there is never two owners of the keyboard.
				ExitApp(0)
		}
}

try {
		EnsurePersonalShortcutsFile(ScriptInformation["PersonalAhkPath"])
} catch as _epsErr {
		try LoggerError("ErgoptiPlus", "EnsurePersonalShortcutsFile failed: {1}.", _epsErr.Message)
}
#InputLevel 2
#Include *i _generated/personal_shortcuts.ahk
#Include *i %LocalAppData%\Ergopti\_generated\personal_shortcuts.ahk
#Include %A_ScriptDir%
#InputLevel 0
; Capture the un-gated per-section hotstring Features BEFORE gating, so a live
; category toggle (ToggleCategoryAllFeatures) can restore a category's sections on
; re-enable. Declared + populated here, before gating, so the auto-execute thread
; never re-inits the Map after filling it.
global _HSCategorySnapshot := Map()
try _HSSnapshotAllCategories()
ApplyMasterGatesToFeatures(Features, TapHold, IsCategoryGated, LoggerDebug)

#Include modules/gestures/init.ahk
#Include modules/gestures/click.ahk
#Include modules/gestures/screenshots.ahk
#Include modules/gestures/window_cycle.ahk
#Include modules/gestures/config.ahk
ReadScriptShortcutsConfig()
ReadKeyboardShortcutsConfig()

LoggerStart("KeyboardShortcuts", "Registering configurable keyboard hotkeys…")
_KbBoundCount := 0
for _KbSlot, _KbAction in KeyboardShortcutAssignments {
		if (_KbAction == "none")
				continue
		_KbSend := _KeyboardSlotSendCode(_KbSlot)
		if (_KbSend == "") {
				LoggerWarn("KeyboardShortcuts", "Slot '{1}' skipped — send code not found.", _KbSlot)
				continue
		}
		try {
				Hotkey(_KbSend, ((_s) => (*) => RunKeyboardShortcutAction(_s))(_KbSlot))
				LoggerDebug("KeyboardShortcuts", "Hotkey '{1}' → '{2}' registered.", _KbSlot, _KbAction)
				_KbBoundCount++
		} catch as _KbErr {
				LoggerWarn("KeyboardShortcuts", "Failed to register hotkey '{1}': {2}.", _KbSlot, _KbErr.Message)
		}
}
LoggerSuccess("KeyboardShortcuts", "Configurable hotkeys registered ({1} active).", _KbBoundCount)

CS_Load()
global _SaveFullConfigReady := true
global _ParseExtTomlSectionsCache := Map()
if MetricsShortcuts.enabled
		WPMWidget_LoadConfig(_IniCache)

BootProfile_Mark("Config, features & shortcuts loaded")
; The tray menu build (~157 ms: per-category TOML submenus + manifest items) was the
; single largest remaining time-to-ready chunk, and the menu is only needed once the
; user right-clicks the tray. So it is DEFERRED off the boot critical path: built by
; BuildTrayMenuDeferred armed right after "ready" (see the deferred-task block).
; Stock tray items (Pause/Suspend/Reload/Exit/Edit) are cleared once at boot,
; before Onboarding_Run (AHK-21), so they are never live during the first-run wizard.
; This second Delete() is a safe no-op on an already-empty menu — kept to make the
; comment block here accurate; _DriverReady stays false until "ready".
_DriverReady := false
_LangMenuRef := ""
_LangMenuBuildPending := false
LANG_MENU_DEFER_MS := 120  ; short post-ready delay for the language-submenu populate
MENU_BUILD_DEFER_MS := 16  ; build the full tray menu first thing after "ready"
A_TrayMenu.Delete()
SetTimer(SaveFullConfig, -500)

; HookDispatcher owns the process-wide mouse Hotkeys consumed by four independent
; features (hotstring prefix-watcher click-reset, CapsWord cancel, gesture
; click-toggle cross-release, LLM tooltip dismiss-on-click). None of those are
; gated by the keylogger/metrics flag, so Start() must be unconditional here.
; Start() is idempotent (guarded by _started), so a stray second call is harmless.
; HookDispatcher.Stop() is called by Ergopti_OnShutdown (registered below via
; OnExit) — do NOT register a second anonymous OnExit lambda here; double-Stop
; can trigger a "hook already released" error on some AHK builds.
if !HookDispatcher.Start() {
		; The shared hook is the driver’s keyboard ownership boundary. Publishing
		; readiness without it would create a half-boot where menu/UI state looks
		; healthy but remaps and hook consumers silently never receive input.
		LoggerError("ErgoptiPlus", "Startup aborted: unified keyboard hook could not start.")
		ExitApp(1)
}

if MetricsShortcuts.enabled {
		LoggerDebug("Startup", "Metrics enabled — WPMWidget.visible={1}, show_graph={2}.",
				WPMWidget.visible, WPMWidget.show_graph)
		; Refresh the metrics focus cache off the keystroke thread via a periodic timer
		; so WinGetTitle/WinGetProcessName (which send WM_GETTEXT and can block on a
		; busy foreground window) never land on the hot path. Armed here — inside the
		; metrics gate and BEFORE KL_Init below — because the cache has exactly one
		; reader, MF_ShouldFilter, which the keylogger consults per event: with metrics
		; off the poll would issue blocking probes nobody reads.
		MF_StartFocusRefresh()
		; (The WebView2 widget cold-start is armed at the very END of boot — after
		; "Driver fully initialised" — NOT here. A timer armed mid-boot fires ~its
		; delay later, while the hotstring registration is still running, and AHK
		; preempts that auto-execute thread to run it: WebView2's ~3 s startup gets
		; dragged back onto the critical path, AND the interruption pumps the message
		; queue, painting a tray click queued during boot against a half-built menu.
		; See the deferred-task block after LoggerSuccess("…ready").)
		KL_Init(_ConfigDir . "metrics")
		MS_ApplyAll(KLUI_ToggleTyping, KLUI_ToggleApps)
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

BootProfile_Mark("Metrics/keylogger started")
; Register the global shutdown handler now that the keylogger is up — Reload()/
; ExitApp() run only OnExit callbacks, so this is the single seam that flushes the
; RAM-buffered metrics (KL_Stop) before the process tears down. Registered
; unconditionally: the handler is fully try-wrapped and KL_Stop is a no-op when
; metrics are disabled (Keylogger.initialized stays false).
OnExit(Ergopti_OnShutdown)
LoggerInfo("ErgoptiPlus", "Tray menu built and icon set.")








#Include ui/editors.ahk

global _FmtCountCache := Map()



#Include lib/config_io.ahk

#Include ui/action_picker/init.ahk
#Include ui/action_picker_webview.ahk
#Include ui/paths_editor/init.ahk
#Include ui/personal_info_editor/init.ahk

#Include lib/lifecycle.ahk

#Include lib/script_altgr_hotkeys.ahk
_RegisterScriptAltGrHotkeys()

; Personal hotstrings are loaded exactly once, inside RegisterAllHotstrings()
; below. There used to be an inline forward-order load here at #InputLevel 0,
; but personal hotstrings register through HSE (CreateHotstring → HSE_Register),
; not AHK-native Hotstring(), so #InputLevel never applied to them — the inline
; loop was a pre-HSE leftover that double-registered all 263 personal specs and
; re-parsed their TOML on every boot/reload. RegisterAllHotstrings now loads
; them in forward order so first-declared (prominent) sections win HSE's
; first-registered-wins collision tiebreak, matching the old effective order.
#InputLevel 2
#Include modules/keymap/layout.ahk
#Include modules/shortcuts.ahk
#Include modules/tap_holds.ahk
#Include modules/hotstrings.ahk
; The module now only DEFINES RegisterAllHotstrings(); invoke it here so the
; registration runs at the same boot point (and A_InputLevel) as before the
; in-process refactor. A_InputLevel is still 2 from the #InputLevel 2 above.
; Split the former single "hotstrings + prefix watcher" mark into three so the
; boot log bisects the late-startup cost: everything since the last mark (the
; layout / shortcuts / tap-hold / AltGr module includes registered above), then
; the ~5400-hotstring HSE registration, then the prefix-watcher index build. A
; micro-bench (tests/bench_boot_hotstrings.ahk) shows magic-key text expansion is
; the heaviest registration category by a wide margin.
BootProfile_Mark("Layout/shortcuts/tap-holds + AltGr registered")
; Clear any phantom modifier carried across a Reload BEFORE the input hook starts
; observing keystrokes, so a Reload that landed mid-AltGr cannot leave this fresh
; process stuck on the AltGr layer for the first keystrokes (transient
; « AltGr bloqué »). See _ReleasePhantomModifiers in lib/lifecycle.ahk.
_ReleasePhantomModifiers()
; Ready is an output contract: every advertised trigger, including emoji/symbol
; sections and its preview index, must exist before the driver publishes ready.
; Deferring these ~3000 registrations after ready made a first emoji/symbol trigger
; literal for seconds and allowed the timer to stall the first typing burst.
RegisterAllHotstrings(false)
BootProfile_Mark("Hotstrings registered (HSE complete)")
HotstringPrefixWatcherInit()
HotstringPrefixWatcherRebuildIndex()
BootProfile_Mark("Prefix watcher index complete")
_DriverReady := true
_DriverBootPhase := "ready"
LoggerSuccess("ErgoptiPlus", "Driver fully initialised — ready.")

; ── Deferred post-"ready" tasks ──────────────────────────────────────────────
; All the heavy off-critical-path work is armed HERE, after the driver is ready,
; rather than mid-boot. A SetTimer armed earlier fires ~its-delay later and AHK
; preempts the still-running auto-execute (the ~5400-hotstring registration) to
; run it — which (a) drags heavy work like the WebView2 cold-start back into
; contention with registration, and (b) pumps the message queue mid-boot, so a
; tray click the user queued during startup is painted against a half-built menu
; (the "menu shows only the first items" bug). Arming after "ready" means the
; countdowns start once the critical path is done, so they fire on the idle
; message loop with the menu fully built and registration complete.
;
; Order by delay so the passes never contend (same-priority AHK timers serialise,
; they never preempt one another): the LLM submenu populates first (fast, so its
; dropdown is ready), then the text-expansion pass (core magic-key abbreviations,
; brought online quickly), then the emoji/symbol pass, then the WebView2 widget
; last (its delay clears the registration passes).
; Build the full tray menu off the time-to-ready path, FIRST in the deferred
; sequence so the menu is populated within ~tens of ms of "ready". _DriverReady is
; already true here, so the deferred initMenu builds the language submenu inline (no
; separate _LangMenuBuildPending pass needed on this boot path).
SetTimer(BuildTrayMenuDeferred, -MENU_BUILD_DEFER_MS)
if _LangMenuBuildPending
	SetTimer(BuildLanguageMenuDeferred, -LANG_MENU_DEFER_MS)
; Populate the IA submenu at boot ONLY when the feature is OFF. This must NOT be
; gated on a flag set by LLM_Menu_Init: at boot the full menu — initMenu() →
; LLM_Menu_Init() — is built only inside the DEFERRED BuildTrayMenuDeferred pass
; (armed just above), so any such flag is still at its initial value when this
; synchronous boot-tail line runs (an earlier flag-gated guard here never fired →
; empty IA submenu when off, since the health-probe tick only rebuilds on a
; backend-status CHANGE, which never happens while disabled).
;
; OFF: the build is cheap and the ONLY thing that would ever populate the submenu —
; the model submenu skips the Ollama install-probe when deps aren't ready, so there
; is no network call and no blocking.
;
; ON: do NOT build here. LLM_Menu_Init armed LLM_Menu_BootstrapOllama, which builds
; the menu via LLM_Menu_OnDepsReady AFTER Ollama readiness is confirmed
; ASYNCHRONOUSLY. Building at boot instead would run the model submenu's SYNCHRONOUS
; /api/tags install-probe (_LLM_GetInstalledTagsCached → LLM_OllamaListModels) against
; a still-cold daemon and block the keyboard thread for seconds — a stuck/empty menu
; AND missed prediction-cancel on mouse/keystroke while the thread is frozen.
if !_LLM_Menu["enabled"]
	SetTimer(LLM_Menu_Build, -LLM_MENU_BUILD_DEFER_MS)
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

global _LAYOUT_POLL_INTERVAL_MS := 1000
global _LAST_KEYBOARD_HKL := GetForegroundKeyboardLayout()
global _PENDING_KEYBOARD_HKL := 0

; The quiescence decision is a pure function extracted to lib/ so the headless
; test suite can exercise it without #including this whole entry point (which
; registers every hotkey at load). Single source of truth — defined once there,
; consumed here and by tests/meta/test_layout_quiescence.ahk.
#Include modules/keymap/layout_poll_helper.ahk

CheckKeyboardLayoutChange() {
		global _LAST_KEYBOARD_HKL, _PENDING_KEYBOARD_HKL, HSE_Suppressed, _PrefixWatcherSuppressed
		
		suspended := A_IsSuspended
		isBlacklisted := false
		try {
				if IsSet(MF_ShouldFilter) && MF_ShouldFilter()
						isBlacklisted := true
		}
		
		curHkl := GetForegroundKeyboardLayout()
		hseSup := (IsSet(HSE_Suppressed)) ? HSE_Suppressed : 0
		pwSup := (IsSet(_PrefixWatcherSuppressed)) ? _PrefixWatcherSuppressed : 0
	inputBusy := (IsSet(InDeadKeySequence) and InDeadKeySequence)
		or (IsSet(_SpaceHoldInputHook) and IsObject(_SpaceHoldInputHook))
		or (IsSet(_OneShotShiftInputHook) and IsObject(_OneShotShiftInputHook))
		or (IsSet(_DeadKeyInputHook) and IsObject(_DeadKeyInputHook))
		or GetKeyState("SC039", "P") or GetKeyState("SC038", "P") or GetKeyState("SC138", "P")
		
		if _ShouldReloadForHkl(curHkl, &_LAST_KEYBOARD_HKL, &_PENDING_KEYBOARD_HKL, suspended, isBlacklisted, hseSup, pwSup, A_TimeIdlePhysical, inputBusy) {
				Reload()
		}
}
SetTimer(CheckKeyboardLayoutChange, _LAYOUT_POLL_INTERVAL_MS)
