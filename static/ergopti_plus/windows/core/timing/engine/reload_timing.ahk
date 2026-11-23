; core/timing/engine/reload_timing.ahk

; ==============================================================================
; MODULE: Reload Duration Across The Restart (Windows)
; DESCRIPTION:
; Measures a Reload from the successor's launch to its boot completion and
; judges it against [budgets] driver_reload_ms, as the macOS driver does after
; hs.reload() and the Linux driver across its daemon restart
; (linux/core/timing/engine/reload_timing.lua). A Windows Reload starts a new
; process (core/lifecycle/engine/reload/successor.ahk), so the request and the
; end of the boot run in two processes.
;
; FEATURES & RATIONALE:
; 1. The launch tick travels in the successor's environment, set only around
;    its CreateProcess: no file outlives a refused reload, and no later child
;    of the requesting instance inherits it.
; 2. A_TickCount is the system-wide tick, so two processes of one session read
;    the same clock and a wall-clock correction cannot bend the duration.
; 3. The successor takes and clears the value at its first statements, so the
;    workers it starts later never report a reload.
; 4. The same log line as macOS and Linux ("Reload completed in N ms ...") and
;    the shared overrun warning (core/logger/engine/perf_budget.ahk), so
;    tools/dev/field-log-analyse.py reads the three drivers with one pattern.
; 5. Diagnostics only: a stamp that cannot be set or read is logged as an error
;    and never blocks the reload or the boot.
; ==============================================================================

#Requires AutoHotkey v2.0





; ============================================================
; ============================================================
; ======= 1/ Hand-off ========================================
; ============================================================
; ============================================================

; The environment variable that carries the launch tick to the successor. A
; function rather than a global: the successor reads it before this file's
; global initializers have run.
; @returns {String}
ReloadTimingEnvName() {
	return "ERGOPTI_RELOAD_REQUESTED_TICK"
}

; Launches the successor with the launch tick in its environment, then clears
; the variable so no later child inherits it.
; @param LaunchFn {Func} Starts the successor and returns its descriptor.
; @param NowTick {Integer} The launch tick, A_TickCount in production.
; @returns {Any} What LaunchFn returned.
ReloadTimingLaunchStamped(LaunchFn, NowTick := A_TickCount) {
	Name := ReloadTimingEnvName()
	try EnvSet(Name, String(NowTick))
	catch as StampErr
		LoggerError("Lifecycle", "The reload launch time could not be stamped ({1}): this reload goes unmeasured.",
			StampErr.Message)
	try return LaunchFn.Call()
	finally {
		try EnvSet(Name, "")
		catch as ClearErr
			LoggerError("Lifecycle", "The reload launch time could not be cleared after the launch: {1}.",
				ClearErr.Message)
	}
}

; Takes the launch tick this process inherited and clears it from its own
; environment. Runs at the successor's first statements.
; @returns {String} The inherited value, "" when this boot follows no reload.
ReloadTimingTakeInherited() {
	Name := ReloadTimingEnvName()
	Inherited := EnvGet(Name)
	if (Inherited != "")
		EnvSet(Name, "")
	return Inherited
}




; ============================================================
; ============================================================
; ======= 2/ Boot completion =================================
; ============================================================
; ============================================================

; At boot completion: reports the reload this boot follows, if any, and judges
; it against its budget.
; @param Inherited {String} What ReloadTimingTakeInherited returned.
; @param NowTick {Integer} The boot completion tick, A_TickCount in production.
; @returns {Integer|String} The reload's duration in ms, "" when unmeasured.
ReloadTimingComplete(Inherited, NowTick := A_TickCount) {
	_ReloadTimingVerdict("")
	if (Inherited == "")
		return ""
	if !RegExMatch(Inherited, "^\d{1,18}$") {
		LoggerError("Lifecycle", "The reload launch time is malformed; the reload goes unmeasured.")
		return ""
	}
	ReloadMs := NowTick - Integer(Inherited)
	if (ReloadMs < 0) {
		LoggerError("Lifecycle", "The reload launch time lies {1} ms in the future; the reload goes unmeasured.",
			-ReloadMs)
		return ""
	}
	; Published before the budget is read, so a refused read keeps the measure.
	_ReloadTimingVerdict(ReloadMs)
	LoggerInfo("Lifecycle", "Reload completed in {1} ms (reload request to boot complete).", ReloadMs)
	PerfBudget_Report("Lifecycle", "reload", ReloadMs, TimingsGet("budgets", "driver_reload_ms"))
	return ReloadMs
}

; The reload this boot completed, for the developer field run's reload step.
; @returns {Integer|String} -1 while the boot runs, the duration in ms, or ""
;   when this boot follows no measured reload.
ReloadTimingResult() {
	return _ReloadTimingVerdict()
}

; What ReloadTimingComplete found: -1 until it ran (the boot is not complete),
; then the reload's duration in ms, or "" when this boot follows no measured
; reload. Held here rather than in a global: only ReloadTimingComplete writes it.
; @param Value {Integer|String} The verdict to record; omitted, nothing changes.
; @returns {Integer|String} The current verdict.
_ReloadTimingVerdict(Value := unset) {
	static Verdict := -1
	if IsSet(Value)
		Verdict := Value
	return Verdict
}
