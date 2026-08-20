; tests/meta/test_shell_runner_isolated_logger.ahk

; ==============================================================================
; MODULE: ShellRunner Isolated Logger Regression Test
; DESCRIPTION:
; Validating adapters/shell_runner.ahk directly with #Warn previously treated
; LoggerError as an unassigned local because logger.ahk belongs to the outer
; driver include graph. An adapter must remain parse-clean in isolation, so the
; logger is resolved dynamically at call time.
;
; ROOT CAUSE ENCODED (2026-07-21): that dynamic resolution was written as
; `Func("LoggerError")`. In AHK v2 `Func` is the native CLASS, not a name-lookup
; built-in, so the expression raises `ValueError: Invalid base` on every call —
; measured on this binary, not assumed. The throw was caught by _SR_LogError's
; own try and fell through to OutputDebug, which is invisible without a debugger
; attached. Every shell_runner error the driver has ever produced was therefore
; discarded, including the ones that would have explained why a shell-out failed.
;
; This file previously REQUIRED the broken spelling: it string-matched
; `Func("LoggerError")` in the source without ever invoking the helper, so the
; suite actively defended the bug and fixing the code would have failed the
; test. That is the false-green shape the repo already forbids elsewhere —
; test_feature_state_boot.ahk bans `Func("IniCacheGet").Call` as boot-fragile
; while this file demanded the identical idiom two directories away.
;
; The assertion is corrected rather than weakened, and it is now BEHAVIOURAL:
; the helper is invoked against the logger's own test sink and the line must
; actually arrive. No source-shape assertion could have caught this; only
; calling it can.
; ==============================================================================

#Requires AutoHotkey v2.0

; Lines captured from the logger's test sink during one _SR_LogError call.
global _SRIL_Captured := []

_SRIL_Sink(Line) {
	global _SRIL_Captured
	_SRIL_Captured.Push(Line)
}




; ==================================================================
; ==================================================================
; ======= 1/ The helper actually delivers its line =================
; ==================================================================
; ==================================================================

; Drive the real helper through the real logger. If its dynamic resolution
; throws, the helper's own catch swallows the failure into OutputDebug and this
; sink stays empty — which is exactly the defect.
_SRIL_HelperReachesTheLogger() {
	global _SRIL_Captured
	_SRIL_Captured := []

	LoggerSetTestSink(_SRIL_Sink)
	Threw := ""
	try {
		_SR_LogError("probe marker {1}", "payload")
	} catch as Err {
		Threw := Err.Message
	}
	LoggerClearTestSink()

	Assert(Threw == "",
		"_SR_LogError must never raise into its caller — it runs from completion callbacks, where a throw aborts the shell task's cleanup. Got: " . Threw)
	Assert(_SRIL_Captured.Length >= 1,
		"_SR_LogError produced NO log line. Its dynamic resolution of LoggerError is throwing and the helper's own catch is hiding that in OutputDebug, which is invisible without a debugger — so every shell_runner diagnostic is lost. In AHK v2 `Func(...)` is the native class and raises ValueError: Invalid base; resolve by dynamic variable dereference instead")

	Joined := ""
	for Line in _SRIL_Captured
		Joined .= Line . "`n"
	Assert(InStr(Joined, "shell_runner") > 0,
		"the delivered line must be attributed to the shell_runner adapter, or nobody can find it in the log. Got: " . Joined)
	Assert(InStr(Joined, "probe marker") > 0,
		"the delivered line must carry the caller's message. Got: " . Joined)
	Assert(InStr(Joined, "payload") > 0,
		"the format arguments must reach the logger, or the message renders with its placeholders unfilled. Got: " . Joined)
}

; The async termination stack must return before LoggerError performs its forced
; file flush, while the next message-loop turn must still deliver the diagnostic.
_SRIL_DeferredHelperReturnsBeforeLogging() {
	global _SRIL_Captured
	_SRIL_Captured := []
	local marker := "deferred-probe-" . A_TickCount
	local captured_before_yield := false

	LoggerSetTestSink(_SRIL_Sink)
	try {
		_SR_DeferLogError("deferred probe marker {1}", marker)
		captured_before_yield := _SRIL_Captured.Length > 0
		loop 100 {
			if _SRIL_Captured.Length > 0
				break
			Sleep(5)
		}
	} finally {
		LoggerClearTestSink()
	}

	AssertFalse(captured_before_yield,
		"_SR_DeferLogError must return before LoggerError can force a filesystem flush")
	Assert(_SRIL_Captured.Length >= 1,
		"the one-shot deferred boundary must still deliver the shell_runner diagnostic")
	local joined := ""
	for line in _SRIL_Captured
		joined .= line . "`n"
	Assert(InStr(joined, marker) > 0,
		"the deferred logger must preserve the exact format arguments")
}

; Names the specific trap so it is not reintroduced while tidying up. The
; behavioural assertion above is the real guard; this one explains why.
_SRIL_DoesNotUseTheThrowingFuncClass() {
	Helper := _DriverFuncBody("_SR_LogError")
	Assert(Helper != "", "ShellRunner must define its isolated logging helper")
	Assert(InStr(Helper, 'Func("LoggerError")') == 0,
		"_SR_LogError must not resolve the logger through Func(...): in AHK v2 Func is the native class, not a name lookup, so it raises ValueError: Invalid base on every call and the helper's own catch hides that in OutputDebug")
	Assert(InStr(Helper, "OutputDebug") > 0,
		"the standalone diagnostic fallback must remain, for isolated /validate runs where no logger exists at all")
}




; ==================================================================
; ==================================================================
; ======= 2/ No call site reintroduces a static dependency =========
; ==================================================================
; ==================================================================

; The original purpose of this file: the adapter must stay parse-clean when
; validated on its own, so no call site may reference LoggerError statically.
_SRIL_NoStaticLoggerDependency() {
	for Name in ["ShellRunner_Exec", "_SR_HandleStart"] {
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . "() must exist in the driver source")
		Assert(InStr(Body, "_SR_LogError(") > 0,
			Name . " must report its failures through the adapter's own helper")
		Assert(InStr(Body, 'LoggerError("') == 0,
			Name . " must not call LoggerError statically — logger.ahk belongs to the outer driver include graph, and a static reference makes the adapter fail isolated validation under #Warn")
	}
	PollBody := _DriverFuncBody("_SR_Poll")
	Assert(InStr(PollBody, "_SR_LegacyFinishCompletion(") > 0,
		"_SR_Poll must route completion I/O and callback failures through its isolated finalizer")
	FinishBody := _DriverFuncBody("_SR_LegacyFinishCompletion")
	Assert(InStr(FinishBody, "_SR_LogError(") > 0,
		"the finalizer reached by _SR_Poll must report failures through the adapter helper")
	Assert(InStr(PollBody . FinishBody, 'LoggerError("') == 0,
		"neither _SR_Poll nor its finalizer may acquire a static LoggerError dependency")
}


Test("shell_runner: the isolated logging helper actually delivers its line",
	_SRIL_HelperReachesTheLogger)
Test("shell_runner: deferred errors return before logging and still arrive (shellrunner-legacy-deferred-log)",
	_SRIL_DeferredHelperReturnsBeforeLogging)
Test("shell_runner: the helper does not resolve through the throwing Func class",
	_SRIL_DoesNotUseTheThrowingFuncClass)
Test("shell_runner: isolated validation has no static LoggerError dependency",
	_SRIL_NoStaticLoggerDependency)
