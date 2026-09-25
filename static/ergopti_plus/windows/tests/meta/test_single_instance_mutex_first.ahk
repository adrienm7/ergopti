; tests/meta/test_single_instance_mutex_first.ahk

; ==============================================================================
; MODULE: Single-owner mutex established before hook/message-pump ownership
; DESCRIPTION:
; #SingleInstance Force replaces the previous instance only at the END of the new
; instance's load, and killing a hung/dialog-blocked old instance is best-effort,
; so a rapid double-launch could leave two processes briefly co-owning the keyboard
; hook and the log (field-observed: interleaved duplicate log lines for minutes, a
; boot killed mid-registration with hotkeys armed). The fix acquires a named
; session-local mutex as the first auto-execute statement and waits (bounded) for a
; previous owner to exit before registering anything. This guards that the mutex is
; acquired BEFORE Bundle_Init() (whose RunWait pumps the first message loop) and
; BEFORE HookDispatcher.Start() — exclusivity must precede any message pump or hook
; registration, not the parse-time replacement #SingleInstance Force performs.
; (F02, audit 2026-07-20.) NOTE: the runtime mutex acquisition needs a live
; double-launch test on real hardware; this meta test only pins the source ordering.
; ==============================================================================

#Requires AutoHotkey v2.0

; The entry point is the one source every test below orders statements in. Full-
; line comments are stripped so the many prose mentions of Bundle_Init() and the
; worker predicates do not shadow the real statements when positions are compared.
_SIMF_EntryCode() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Src != "", "ErgoptiPlus.ahk must be readable for the single-instance meta-tests")
	return _StripFullLineComments(Src)
}

_SIMF_MutexEstablishedBeforeHookAndPump() {
	Code := _SIMF_EntryCode()
	MutexPos := InStr(Code, "CreateMutexW")
	BundlePos := InStr(Code, "Bundle_Init()")
	HookPos := InStr(Code, "HookDispatcher.Start()")

	Assert(MutexPos > 0, "ErgoptiPlus.ahk must acquire a named single-owner mutex (CreateMutexW) at boot")
	Assert(BundlePos > 0, "ErgoptiPlus.ahk must call Bundle_Init()")
	Assert(HookPos > 0, "ErgoptiPlus.ahk must start the hook dispatcher (HookDispatcher.Start())")
	Assert(MutexPos < BundlePos,
		"the single-owner mutex must be acquired BEFORE Bundle_Init() (its RunWait pumps the first message loop), so exclusivity precedes the first message pump")
	Assert(MutexPos < HookPos,
		"the single-owner mutex must be acquired BEFORE HookDispatcher.Start(), so two instances never co-own the keyboard hook")

	; Acquiring is not enough: every decision other than exact ownership must exit
	; before registration. The unit matrix separately proves that WAIT_TIMEOUT,
	; WAIT_FAILED, null handles, and unknown results all choose this branch.
	RejectPos := InStr(Code,
		"_DriverMutexDecision != DRIVER_MUTEX_ACQUIRED")
	Assert(RejectPos > 0,
		"the mutex gate must reject every decision other than exact ownership")
	ExitPos := InStr(Code, "ExitApp", , RejectPos)
	Assert(ExitPos > RejectPos,
		"a non-owner mutex decision must ExitApp, never continue best-effort")
	Assert(ExitPos < BundlePos && ExitPos < HookPos,
		"the yield must happen BEFORE Bundle_Init and HookDispatcher.Start, so a yielding instance never registers a hook")
}
Test("boot: single-owner mutex is acquired before the message pump and hook registration",
	_SIMF_MutexEstablishedBeforeHookAndPump)

; The gate exists to stop two HOOK OWNERS coexisting. The driver also re-runs
; this same entry on purpose, with /force and --keylogger-prefetch-worker, to
; compute a metrics projection in a detached process — a process that registers
; no hook, no log owner and no tray, and is therefore not what the gate is for.
;
; Because the gate is the FIRST auto-execute statement while the worker's own
; gate sits ~300 lines below, every worker spawned while the driver was alive
; blocked the full bounded wait on the live driver's mutex, timed out, and
; ExitApp(0)'d before ever reaching its main. The projection could never publish
; while the driver ran — which is every time it is asked for. Field logs showed
; zero projection lines in eleven days.
;
; The exemption must be tested BEFORE the mutex is created, not merely present
; somewhere in the file, so the ordering is what this asserts.
_SIMF_WorkerInvocationIsExemptFromTheGate() {
	Code := _SIMF_EntryCode()

	MutexPos := InStr(Code, "CreateMutexW")
	Assert(MutexPos > 0, "the entry must still acquire the single-owner mutex")
	for Worker in [
		["KLPF_IsWorkerInvocation()", "KLPF_WorkerMain()", "prefetch"],
		["UIASW_IsWorkerInvocation()", "UIASW_WorkerMain()", "UIA selection"]
	] {
		WorkerGatePos := InStr(Code, Worker[1])
		Assert(WorkerGatePos > 0,
			"the entry must identify the detached " . Worker[3] . " worker before acquiring the live driver's mutex")
		Assert(WorkerGatePos < MutexPos,
			"the " . Worker[3] . " worker exemption must be evaluated BEFORE CreateMutexW")
		MainPos := InStr(Code, Worker[2])
		Assert(MainPos > WorkerGatePos,
			"the detached " . Worker[3] . " worker main must remain reachable after its exemption")
	}
}
Test("boot: every detached worker is exempt from the single-owner mutex before it is created",
	_SIMF_WorkerInvocationIsExemptFromTheGate)

; A detached worker re-runs this entry and used to keep the tray icon AutoHotkey
; creates for every process: a second "ErgoptiPlus" entry with the default green
; H icon beside the real driver for as long as the worker lived
; (worker-tray-icon-2026-09-25). #NoTrayIcon cannot be conditional, so the entry
; must hide the icon for every worker flag before any other statement. The
; real-process twin is tests/unit/test_worker_tray_icon_hidden.ahk, which asks
; the shell whether a running worker owns an icon.
_SIMF_WorkerHidesTrayIconFirst() {
	Code := _SIMF_EntryCode()
	DefinePos := InStr(Code, "global _DriverIsDetachedWorker :=")
	Assert(DefinePos > 0, "the entry must resolve one detached-worker predicate")
	Definition := SubStr(Code, DefinePos, InStr(Code, "`n", , DefinePos) - DefinePos)
	for Predicate in ["KLPF_IsWorkerInvocation()", "UIASW_IsWorkerInvocation()"]
		Assert(InStr(Definition, Predicate) > 0,
			"the detached-worker predicate must cover " . Predicate)

	HidePos := RegExMatch(Code, "if _DriverIsDetachedWorker\R\s*A_IconHidden := true")
	Assert(HidePos > DefinePos,
		"a detached worker must hide its tray icon right after it is identified")
	for Line in StrSplit(SubStr(Code, 1, DefinePos - 1), "`n", "`r") {
		Line := Trim(Line)
		Assert(Line = "" || SubStr(Line, 1, 1) = "#",
			"only directives may run before the worker tray-icon guard, found: " . Line)
	}
	for Later in ["SetWorkingDir(", "CreateMutexW", "Bundle_Init()",
			"UIASW_WorkerMain()", "KLPF_WorkerMain()"]
		Assert(InStr(Code, Later) > HidePos,
			"the worker tray-icon guard must run before " . Later)

	GatePos := InStr(Code, "if !(_DriverIsDetachedWorker")
	Assert(GatePos > HidePos && GatePos < InStr(Code, "CreateMutexW"),
		"the single-owner mutex exemption must reuse the same detached-worker predicate")
}
Test("boot: a detached worker hides its tray icon before any other statement (worker-tray-icon-2026-09-25)",
	_SIMF_WorkerHidesTrayIconFirst)
