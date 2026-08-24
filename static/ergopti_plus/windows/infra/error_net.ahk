; infra/error_net.ahk

; ==============================================================================
; MODULE: Global Error Net
; DESCRIPTION:
; The process-wide uncaught-error handler armed via OnError() in the entry.
; Without it, any uncaught error pops a blocking AHK dialog mid-keystroke and
; can leave modifiers stuck down; this handler releases only genuinely-stuck
; modifiers, logs the failure, saves a crash report (no opt-in prompt — the
; confirmation step was removed as friction), and surfaces a non-blocking tray
; toast — so one bad callback never locks the keyboard.
; ==============================================================================





; ==================================
; ==================================
; ======= 1/ Error handler =========
; ==================================
; ==================================

; TTL for the per-signature crash-report dedup cache below. Mirrors
; HookDispatcher.Dispatch's own _err_cache pattern: a repeatedly-throwing
; callback OUTSIDE that dispatcher (a SetTimer callback, a hotkey the user
; holds/auto-repeats) would otherwise re-run the full WMI/healthcheck/git
; crash-report pipeline on every single occurrence, backing up the one
; thread that also serves every keystroke.
global ERROR_NET_DEDUP_TTL_MS := 60000
; Cap on the dedup cache before a hard Clear() — bounds memory when many
; DISTINCT error signatures accumulate over a long-running session.
global ERROR_NET_DEDUP_CACHE_CAP := 256

; Decides whether the error handler should force-release a modifier. A modifier
; is only RELEASED when it is LOGICALLY down (held by the driver / a failed
; callback) but the user is NOT physically holding it — i.e. genuinely stuck.
; Returning false when the user is physically holding the key prevents the old
; bug where the handler sent a Shift-Up for a Shift the user was legitimately
; holding (e.g. an error fires mid-chord while typing a capital), which desynced
; the modifier state and broke capitalisation for the rest of the word.
_ShouldReleaseModifier(ModKey) {
		; "P" = physical key state; the default state is the logical state AHK reports.
		return GetKeyState(ModKey) and !GetKeyState(ModKey, "P")
}

; Recognises the benign vendor/UIA.ahk "orphaned pattern object" defect: when
; el.GetPattern(...) receives a null COM pointer (the target element went stale
; between an IsTextPatternAvailable probe and the GetPattern call — e.g. its
; window closed or lost focus mid-poll), UIA.IUIAutomationBase.__New throws
; ValueError BEFORE DefineProp("ptr", ...) runs. AHK v2 then immediately invokes
; __Delete on the orphaned, ptr-less instance to unwind the failed construction,
; and that __Delete-time PropertyError is raised by the runtime's own cleanup
; machinery — it can NEVER be caught by a try/catch at the call site (confirmed
; empirically: a try/catch around the exact same construction pattern still
; receives the ORIGINAL ValueError normally, but OnError is separately and
; unavoidably invoked first for the PropertyError from __Delete). The call site
; (_UIA_SelectionPollTick in modules/keymap/layout.ahk) already catches the
; original ValueError and degrades to "no selection" — this is not a functional
; failure, only an unavoidable extra OnError notification for an already-handled
; condition. Suppressing the disruptive crash-report/toast for exactly this
; signature keeps the safety net intact for every other error while stopping the
; false-alarm noise (crash_reports/2026-06-25T17-14-06Z.json).
_IsBenignUiaOrphanedPatternError(Exc) {
		return Type(Exc) == "PropertyError"
				and Exc.HasProp("Extra") and Exc.Extra == "ptr"
				and Exc.HasProp("What") and InStr(Exc.What, "UIA.IUIAutomationBase.Prototype.Release") == 1
}

ErgoptiGlobalErrorHandler(Exc, Mode) {
		global ERROR_NET_DEDUP_TTL_MS, ERROR_NET_DEDUP_CACHE_CAP, _DriverBootPhase
		; Before the driver owns a fully started input pipeline, an uncaught error
		; is fatal. Suppressing it and returning to auto-execute leaves a process
		; resident with a partial set of hotkeys/hooks and no reliable recovery path.
		; Cleanup is best-effort because this handler also covers failures before
		; those modules are loaded; ExitApp is the only publication boundary here.
		if (_DriverBootPhase != "ready") {
				try LoggerError("ErgoptiPlus", "Fatal startup error during phase '{1}': {2}",
						_DriverBootPhase, Exc.Message
								. (Exc.HasProp("Stack") ? " | " . Exc.Stack : ""))
				; The ERROR line above only reaches disk once LOGGER_LOG_PATH is resolved (in
				; LoggerInit) and the pending queue is flushed. Many fail-fast loaders run
				; BEFORE LoggerInit, so a fault there would ExitApp with the line still in RAM:
				; no log, no crash report, no dialog -- the exe silently "does nothing" on every
				; launch. Resolve a log path and force a flush so the fatal line survives.
				; IsSet first. LOGGER_LOG_PATH is only DECLARED at the logger include's
				; position, well below where OnError is armed, so for every fault in the
				; window between the two — which is exactly the window this branch exists
				; to cover, the Bundle_Init pump — the bare read raised UnsetError inside
				; the error handler itself. The whole fail-closed contract below (resolve
				; a path, flush, tell the user, exit 1) never ran, AHK's raw error dialog
				; appeared instead, and nothing reached any log. That is why the boot
				; crashes of 07-19 exist only in crash_reports/ and in no daily log.
				if (!IsSet(LOGGER_LOG_PATH) or LOGGER_LOG_PATH == "")
						try LoggerInit()
				try _LoggerFlush(true)
				; Tell the user WHY the driver is exiting. A modal is safe here: no input
				; pipeline is owned yet and we are about to ExitApp. i18n may not be loaded
				; this early, so the message is a hardcoded French string (last-resort path).
				if !(IsSet(_DriverStartupSmokeDir) && _DriverStartupSmokeDir != "")
						try MsgBox("ErgoptiPlus n'a pas pu démarrer (phase « " . _DriverBootPhase . " ») :`n`n"
								. Exc.Message . "`n`nLe driver va se fermer. Le journal des erreurs contient le détail.",
								"ErgoptiPlus — erreur de démarrage", "Iconx")
				try KL_Stop()
				try HookDispatcher.Stop()
				ExitApp(1)
				return true
		}
		if _IsBenignUiaOrphanedPatternError(Exc) {
				; Log at WARNING (not ERROR) and skip the crash-report prompt/toast — the
				; originating call site already caught and handled the real error.
				try LoggerWarn("ErgoptiPlus", "Benign UIA orphaned-pattern PropertyError suppressed: {1}.", Exc.Message)
				return true
		}
		; Release ONLY modifiers that are logically stuck (not physically held) after
		; the failed callback — never yank a key the user is still pressing.
		for _, ModKey in ["LControl", "RControl", "LShift", "RShift", "LAlt", "RAlt", "LWin", "RWin"] {
				if _ShouldReleaseModifier(ModKey) {
						; AHK-35: SendEvent can throw on a hook conflict or foreground-window race;
						; guard it so a failure on one modifier doesn't abort releasing the others
						; or skip the deferred crash report + tray toast that follow
						try SendEvent("{" ModKey " Up}")
				}
		}
		; Best-effort logging — guarded because the logger may not be initialised
		; yet when an early-boot error fires the handler.
		try LoggerError("ErgoptiPlus", "Uncaught error: {1}",
				Exc.Message . (Exc.HasProp("Stack") ? " | " . Exc.Stack : ""))

		; Per-signature dedup, mirroring HookDispatcher.Dispatch's _err_cache. A
		; repeatedly-throwing callback OUTSIDE that dispatcher's own throttle (a
		; SetTimer callback, a hotkey the user holds/auto-repeats) would otherwise
		; re-run the full WMI/healthcheck/git crash-report pipeline on every single
		; occurrence, backing up the one thread that also serves every keystroke.
		; The modifier release + LoggerError above already ran unconditionally, so
		; nothing is silently dropped from the logs — only the expensive deferred
		; report + toast are throttled per fault signature.
		static _geh_dedup_map := Map()
		; Every Exc read here is guarded, including Message. It is the only
		; unguarded property access left on this path, and a throw INSIDE the error
		; handler means no report, no toast, and AHK's default blocking dialog —
		; precisely the outcome this module exists to prevent. Type() also keeps the
		; signature meaningful when a non-Error value is thrown.
		Sig := Type(Exc) . "|" . (Exc.HasProp("Message") ? Exc.Message : "")
				. "@" . (Exc.HasProp("What") ? Exc.What : "") . ":" . (Exc.HasProp("Line") ? Exc.Line : "")
		Now := A_TickCount
		if (_geh_dedup_map.Count >= ERROR_NET_DEDUP_CACHE_CAP)
				_geh_dedup_map.Clear()
		if (_geh_dedup_map.Has(Sig) and ((Now - _geh_dedup_map[Sig]) & 0xFFFFFFFF) <= ERROR_NET_DEDUP_TTL_MS) {
				try LoggerDebug("ErgoptiPlus", "Uncaught error signature throttled (seen within {1} ms): {2}.", ERROR_NET_DEDUP_TTL_MS, Sig)
				return true
		}
		_geh_dedup_map[Sig] := Now

		; Save a crash report before surfacing the generic alert. There is no
		; opt-in prompt — CrashReport_PromptUser saves unconditionally and then
		; shows the path (the confirmation step was removed as friction).
		;
		; It is NOT guarded internally: CrashReport_Save is called unguarded there,
		; and the only thing stopping a failure re-entering this handler is the
		; try/catch in _ErgoptiDeferredCrashReport below. Do not remove that catch
		; on the strength of a comment claiming protection elsewhere.
		; Defer the heavy crash-report collection OFF the input/dispatch thread. CrashReport_Build
		; does WMI ConnectServer + RegRead + a git subprocess Sleep-poll + a full healthcheck —
		; ~100-500 ms of blocking work. This handler can fire mid-keystroke (OnError, or
		; HookDispatcher's per-subscriber catch), so running it inline froze the keyboard. Schedule
		; it on a one-shot timer so the keystroke dispatch returns immediately; the cheap modifier
		; release + LoggerError above stay synchronous (crash-build-offthread).
		; Sig travels with the report so the throttle can be RELEASED when nothing
		; was written. Recording it above and never rolling it back meant one failed
		; save silenced the next ERROR_NET_DEDUP_TTL_MS of identical crashes — which
		; is how a repeatedly-throwing timer produces no reports at all.
		; ReleaseDedup is a closure over the static throttle map. The throttle has to
		; be recorded BEFORE the report is attempted — the handler must decide
		; whether to proceed before it can know the outcome — so without a way to
		; roll it back, one failed write silenced every recurrence of the same fault
		; for the whole TTL. That is the mechanism behind twelve uncaught errors
		; producing zero crash reports. A closure keeps the map a function static
		; rather than moving driver state into a global just to reach it.
		ReleaseDedup := (*) => _geh_dedup_map.Delete(Sig)
		SetTimer(_ErgoptiDeferredCrashReport.Bind(Exc, ReleaseDedup), -1)
		; Surface the error via a NON-BLOCKING tray notification, not a modal MsgBox.
		; A modal dialog on the input thread starves the keyboard hook — every key
		; pressed while it is up is dropped or queued, turning an uncaught error into
		; a lost-keystroke window. The tray toast informs the user without blocking.
		try NotifierSend(t("ergopti.error_caught") . "`n`n" . Exc.Message,
				Map("title", "ErgoptiPlus", "level", "error"))
		return true
}

_CrashReport_CheapAdapterState() {
	Validated := []
	Failed := []
	try {
		Specs := _HealthCheck_AdapterSpecs()
		for AdapterId, RequiredFns in Specs {
			Complete := true
			for _, FnName in RequiredFns {
				if !IsSet(%FnName%) or !((%FnName%) is Func) {
					Complete := false
					break
				}
			}
			if Complete
				Validated.Push(AdapterId)
			else
				Failed.Push(AdapterId . " (contract incomplete)")
		}
	}
	return Map(
		"validated", _CrashReport_JoinArr(Validated),
		"failed", _CrashReport_JoinArr(Failed))
}

_CrashReport_CheapSnapshot(Exc) {
	global _ConfigDir, _HealthCheckStartMs, _HealthCheckWarnCount, _HealthCheckErrCount

	Version := "unknown"
	try Version := Updater_CurrentVersion()
	UptimeSec := -1
	if IsSet(_HealthCheckStartMs)
		UptimeSec := (A_TickCount - _HealthCheckStartMs & 0xFFFFFFFF) // 1000
	ActiveWindowTitle := ""
	ActiveWindowProcess := ""
	try ActiveWindowTitle := WinGetTitle("A")
	try ActiveWindowProcess := WinGetProcessName("A")
	StuckMods := []
	for _, ModKey in ["LControl", "RControl", "LShift", "RShift", "LAlt", "RAlt", "LWin", "RWin"] {
		try {
			if GetKeyState(ModKey, "P")
				StuckMods.Push(ModKey)
		}
	}
	KeyloggerInitialized := "unknown"
	try KeyloggerInitialized := Keylogger.initialized ? "true" : "false"
	AdapterState := _CrashReport_CheapAdapterState()
	LogTail := ""
	try LogTail := _CrashReport_JoinNewlines(LoggerRingBufferSnapshot())

	return Map(
		"version", Version, "driver", "autohotkey",
		"timestamp", _CrashReport_IsoTimestamp(),
		"error_type", Type(Exc),
		"error_msg", Exc.HasProp("Message") ? Exc.Message : "",
		"error_extra", Exc.HasProp("Extra") ? String(Exc.Extra) : "",
		"error_what", Exc.HasProp("What") ? String(Exc.What) : "",
		"error_file", Exc.HasProp("File") ? String(Exc.File) : "",
		"error_line", Exc.HasProp("Line") ? String(Exc.Line) : "",
		"stack_trace", Exc.HasProp("Stack") ? Exc.Stack : "",
		"os_name", A_OSVersion, "os_build", "",
		"os_arch", A_Is64bitOS ? "64 bits" : "32 bits",
		"ahk_version", A_AhkVersion,
		"ahk_bitness", A_PtrSize = 8 ? "64-bit" : "32-bit",
		"cpu_name", "", "cpu_cores", "",
		"ram_total_gb", "", "ram_free_gb", "",
		"screen_resolution", A_ScreenWidth . "x" . A_ScreenHeight,
		"dpi", String(A_ScreenDPI),
		"dpi_scale", String(Round(A_ScreenDPI / 96 * 100)),
		"locale", A_Language, "script_dir", A_ScriptDir, "git_hash", "",
		"username_hash", _CrashReport_FoldHash(A_UserName),
		"uptime_sec", String(UptimeSec),
		"active_window_title", ActiveWindowTitle,
		"active_window_process", ActiveWindowProcess,
		"stuck_modifiers", StuckMods.Length ? _CrashReport_JoinArr(StuckMods) : "none",
		"adapters_ok", AdapterState["validated"],
		"adapters_failed", AdapterState["failed"],
		"session_warnings", IsSet(_HealthCheckWarnCount) ? String(_HealthCheckWarnCount) : "unknown",
		"session_errors", IsSet(_HealthCheckErrCount) ? String(_HealthCheckErrCount) : "unknown",
		"keylogger_initialized", KeyloggerInitialized,
		"config_dir", _ConfigDir, "log_tail", LogTail)
}

_CrashReport_WorkerDone(ReleaseDedup, ExitCode, Stdout, Stderr) {
	Text := Trim(Stdout . "`n" . Stderr)
	if (ExitCode = 0 and RegExMatch(Text, "m)^OK:(.+)$", &Match)) {
		try LoggerSuccess("CrashReporter", "Crash report saved by worker: {1}.", Match[1])
		try NotifierSend(Match[1], Map("title", t("crash.report.saved_title"), "level", "info"))
		return
	}
	if ReleaseDedup
		try ReleaseDedup()
	try LoggerError("CrashReporter", "Crash-report worker failed (exit={1}): {2}.", ExitCode, Text)
}

; The timer only snapshots cheap in-memory state, serializes that bounded Map,
; and starts a retained child. WMI, subprocess probes, and filesystem work run
; in PowerShell outside AHK's cooperative keyboard scheduler.
_ErgoptiDeferredCrashReport(Exc, ReleaseDedup := 0) {
	try {
		Snapshot := _CrashReport_CheapSnapshot(Exc)
		Done := _CrashReport_WorkerDone.Bind(ReleaseDedup)
		if !CrashReportWorker_Start(_CrashReport_ToJson(Snapshot), Done) {
			if ReleaseDedup
				try ReleaseDedup()
			try LoggerError("CrashReporter", "Crash-report worker could not start.")
		}
	} catch as Err {
		if ReleaseDedup
			try ReleaseDedup()
		; This IS the safety net — a bare try with no catch here means a
		; failure inside the crash-reporting pipeline itself is completely
		; silent, with no trace of either the original crash or this one.
		try LoggerError("ErgoptiPlus", "Deferred crash-report build/prompt failed: {1}.", Err.Message)
	}
}
