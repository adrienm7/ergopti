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

_SIMF_MutexEstablishedBeforeHookAndPump() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	EntryFile := WindowsDir . "\ErgoptiPlus.ahk"
	Src := ""
	try Src := FileRead(EntryFile)
	Assert(Src != "", "ErgoptiPlus.ahk must be readable for the single-instance mutex meta-test")

	; Strip full-line comments so the several comment mentions of Bundle_Init() do
	; not shadow the actual call site when we compare source positions.
	Code := _StripFullLineComments(Src)
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

	; Acquiring is not enough: when a LIVE owner remains (WAIT_TIMEOUT), the new
	; instance must YIELD — exit before registering anything. The first version of this
	; fix logged a warning and continued, which is precisely what let a rapid
	; multi-launch put N keyboard hooks on one machine and hang it (#SingleInstance
	; Force's replacement races when several instances start at once).
	TimeoutPos := InStr(Code, "0x102")
	Assert(TimeoutPos > 0, "the mutex gate must test for WAIT_TIMEOUT (0x102)")
	ExitPos := InStr(Code, "ExitApp", , TimeoutPos)
	Assert(ExitPos > TimeoutPos,
		"on WAIT_TIMEOUT (a live owner remains) the instance must ExitApp and yield, never continue best-effort")
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
	SplitPath(A_ScriptDir, , &WindowsDir)
	Src := ""
	try Src := FileRead(WindowsDir . "\ErgoptiPlus.ahk")
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")
	Code := _StripFullLineComments(Src)

	WorkerGatePos := InStr(Code, "KLPF_IsWorkerInvocation()")
	MutexPos      := InStr(Code, "CreateMutexW")
	Assert(WorkerGatePos > 0,
		"the entry must ask whether this invocation is a prefetch worker — without it the worker blocks on the live driver's mutex and exits before reaching its own main")
	Assert(MutexPos > 0, "the entry must still acquire the single-owner mutex")
	Assert(WorkerGatePos < MutexPos,
		"the worker exemption must be evaluated BEFORE CreateMutexW. Placed after it, the worker still waits the full DRIVER_MUTEX_WAIT_MS on the live driver and still yields, so the projection never publishes")

	; The worker's own main must still run, and still run after the exemption —
	; exempting it from the mutex is pointless if it never reaches its entry point.
	MainPos := InStr(Code, "KLPF_WorkerMain()")
	Assert(MainPos > WorkerGatePos,
		"the worker's main must still be reachable after the exemption")
}
Test("boot: the prefetch worker is exempt from the single-owner mutex before it is created",
	_SIMF_WorkerInvocationIsExemptFromTheGate)
