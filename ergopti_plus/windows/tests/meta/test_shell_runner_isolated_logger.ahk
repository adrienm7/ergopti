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
	local foreign_marker := "foreign-diagnostic-" . marker
	local foreign_records := []
	Capture(Line) {
		if InStr(Line, marker, true) && !InStr(Line, foreign_marker, true)
			_SRIL_Sink(Line)
		else
			foreign_records.Push(Line)
	}

	LoggerSetTestSink(Capture)
	try {
		LoggerError("tests.shell_runner", "{1}", foreign_marker)
		; A queued timer may interrupt this long-running test thread between the
		; helper's return and the observation. Protect only that causal boundary.
		local previous_critical := A_IsCritical
		Critical("On")
		try {
			_SR_DeferLogError("deferred probe marker {1}", marker)
			captured_before_yield := _SRIL_Captured.Length > 0
		} finally {
			Critical(previous_critical)
		}
		AssertEqual(previous_critical, A_IsCritical,
			"the causal observation must restore the caller's exact Critical state")
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
	AssertFalse(InStr(joined, foreign_marker) > 0,
		"foreign diagnostics must not become owned delivery observations")
	local foreign_joined := ""
	for foreign_line in foreign_records
		foreign_joined .= foreign_line . "`n"
	Assert(InStr(foreign_joined, foreign_marker, true) > 0,
		"the sink must preserve unrelated diagnostics without using them as causal evidence")
}

; Execute the actual causal assertion in private native children. Mutating only
; the copied production branch to inline logging must be rejected by that same
; assertion, even though the receipt boundary is protected from timer interrupts.
_SRIL_NativeDeferredMutationProof() {
	global _StaticDir
	local windows_dir := _StaticDir . "\ergopti_plus\windows"
	local adapter_source := FileRead(windows_dir . "\adapters\shell_runner.ahk", "UTF-8")
	local meta_source := FileRead(windows_dir . "\tests\meta\test_shell_runner_isolated_logger.ahk", "UTF-8")
	local log_helper := _DriverExtractFunctionBody(&adapter_source, "_SR_LogError")
	local deferred_helper := _DriverExtractFunctionBody(&adapter_source, "_SR_DeferLogError")
	local sink_helper := _DriverExtractFunctionBody(&meta_source, "_SRIL_Sink")
	local causal_test := _DriverExtractFunctionBody(&meta_source, "_SRIL_DeferredHelperReturnsBeforeLogging")
	Assert(log_helper != "" && deferred_helper != "" && sink_helper != "" && causal_test != "",
		"the native probe executes real production helpers and the real causal assertion")
	local deferred_branch := "try SetTimer(_SR_LogError.Bind(FormatString, Args*), -1)"
	local mutation_count := 0
	local inline_helper := StrReplace(deferred_helper, deferred_branch,
		"try _SR_LogError(FormatString, Args*)", true, &mutation_count)
	AssertEqual(1, mutation_count, "the private mutant changes exactly the owned scheduling branch")
	local root := A_Temp . "\ergopti_deferred_log_" . A_ScriptHwnd . "_" . A_TickCount
	AssertTrue(DllCall("CreateDirectoryW", "Str", root, "Ptr", 0),
		"the native deferred-logger fixture is exclusively owned")
	local ownership := {CanRetire: true}
	try {
		for inline in [false, true] {
			local harness := root . (inline ? "\inline.ahk" : "\deferred.ahk")
			local expected := inline ? "causal-assertion-rejected-inline" : "zero-before|delivered-after"
			local helpers := log_helper . "`n" . (inline ? inline_helper : deferred_helper)
			FileAppend(_SRIL_NativeProbeSource(windows_dir . "\tests\test_framework.ahk",
				helpers . "`n" . sink_helper . "`n" . causal_test), harness, "UTF-8")
			AssertEqual(expected, _SRIL_RunNativeProbe(harness, inline, ownership),
				"the real causal assertion accepts queued delivery and rejects inline production logging")
		}
	} finally {
		if ownership.CanRetire
			DirDelete(root, true)
	}
}

; Only ASCII acknowledgements use stdout; every unexpected native error remains
; fatal and visible, including #Warn diagnostics and failed mutation preconditions.
_SRIL_NativeProbeSource(Framework, Helpers) {
	return "#Requires AutoHotkey v2.0`n#SingleInstance Off`n#Warn All, StdOut`n"
		. '#Include ' . Framework . "`n"
		. 'global _SRIL_Captured := []' . "`n"
		. 'global _SRILProbeSink := 0' . "`n"
		. 'OnError(_SRILProbeUnexpectedError)' . "`n"
		. 'InlineProbe := A_Args[1] == "inline"' . "`n"
		. 'try {' . "`n"
		. '_SRIL_DeferredHelperReturnsBeforeLogging()' . "`n"
		. 'if InlineProbe' . "`n"
		. 'throw Error("the synchronous mutant escaped the real causal assertion")' . "`n"
		. 'FileAppend("zero-before|delivered-after", "*", "UTF-8-RAW")' . "`n"
		. '} catch as _SRILProbeCaughtError {' . "`n"
		. 'if !InlineProbe || !InStr(_SRILProbeCaughtError.Message, "_SR_DeferLogError must return before LoggerError can force a filesystem flush") {' . "`n"
		. '_SRILProbeUnexpectedError(_SRILProbeCaughtError)' . "`n}`n"
		. 'FileAppend("causal-assertion-rejected-inline", "*", "UTF-8-RAW")' . "`n}`n"
		. 'ExitApp(0)' . "`n"
		. Helpers . "`n"
		. 'LoggerSetTestSink(Candidate) {' . "`n"
		. 'global _SRILProbeSink' . "`n_SRILProbeSink := Candidate`n}`n"
		. 'LoggerClearTestSink() {' . "`n"
		. 'global _SRILProbeSink' . "`n_SRILProbeSink := 0`n}`n"
		. 'LoggerError(Tag, Message, Arguments*) {' . "`n"
		. 'global _SRILProbeSink' . "`n"
		. '_SRILProbeSink.Call(Tag . ": " . Format(Message, Arguments*))' . "`n}`n"
		. '_SRILProbeUnexpectedError(ProbeError, *) {' . "`n"
		. 'FileAppend(ProbeError.Message, "**", "UTF-8-RAW")' . "`nExitApp(2)`n}`n"
}

; Completion callbacks record observations; the calling test owns all assertions
; and exact process-tree retirement before deleting private source files.
_SRIL_RunNativeProbe(Harness, Inline, Ownership) {
	local receipt := {Calls: 0, Code: -1, Output: "", Errors: ""}
	OnDone(Code, Output, Errors) {
		receipt.Calls += 1
		receipt.Code := Code
		receipt.Output := Output
		receipt.Errors := Errors
	}
	local handle := ShellRunner_SpawnTreeOwned(A_AhkPath,
		["/ErrorStdOut", Harness, Inline ? "inline" : "deferred"], OnDone)
	try {
		AssertTrue(handle.start(), "the exact deferred-logger native child must start")
		local started := A_TickCount
		while !receipt.Calls && ((A_TickCount - started) & 0xFFFFFFFF) < 15000 {
			_SR_TreePoll()
			Sleep(10)
		}
		AssertEqual(1, receipt.Calls, "the private deferred-logger child completes exactly once")
		AssertEqual(0, receipt.Code, "the native causal probe parses and runs: "
			. receipt.Output . receipt.Errors)
		AssertEqual("", receipt.Errors, "the causal probe has no hidden native errors")
		return receipt.Output
	} finally {
		local settled := handle.terminate()
		if !settled
			Ownership.CanRetire := false
		AssertTrue(settled, "the exact deferred-logger child process tree is retired")
	}
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
	Assert(PollBody != "", "the legacy poller must exist for isolated logging coverage")
	Assert(InStr(PollBody, "_SR_LegacyFinishCompletion(") > 0,
		"_SR_Poll must route completion I/O and callback failures through its isolated finalizer")
	FinishBody := _DriverFuncBody("_SR_LegacyFinishCompletion")
	Assert(FinishBody != "", "the legacy finalizer must exist for isolated logging coverage")
	for Name in ["_SR_LegacyCleanupError", "_SR_CompletionDispatch"] {
		Assert(InStr(FinishBody, Name . "(") > 0,
			"the finalizer must route its failure surface through " . Name)
		Body := _DriverFuncBody(Name)
		Assert(Body != "", Name . " must exist for isolated logging coverage")
		Assert(InStr(Body, "_SR_LogError(") > 0,
			Name . " must report failures through the adapter helper")
		Assert(InStr(Body, 'LoggerError("') == 0,
			Name . " must not acquire a static LoggerError dependency")
	}
	Assert(InStr(PollBody . FinishBody, 'LoggerError("') == 0,
		"neither the poller nor finalizer may acquire a static LoggerError dependency")
}


Test("shell_runner: the isolated logging helper actually delivers its line",
	_SRIL_HelperReachesTheLogger)
Test("shell_runner: deferred errors return before logging and still arrive (shellrunner-legacy-deferred-log)",
	_SRIL_DeferredHelperReturnsBeforeLogging)
Test("shell_runner: the real causal assertion rejects synchronous private mutations (shellrunner-legacy-deferred-log)",
	_SRIL_NativeDeferredMutationProof)
Test("shell_runner: the helper does not resolve through the throwing Func class",
	_SRIL_DoesNotUseTheThrowingFuncClass)
Test("shell_runner: isolated validation has no static LoggerError dependency",
	_SRIL_NoStaticLoggerDependency)
