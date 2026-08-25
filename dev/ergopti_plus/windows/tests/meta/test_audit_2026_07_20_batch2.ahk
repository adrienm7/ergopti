; static/ergopti_plus/windows/tests/meta/test_audit_2026_07_20_batch2.ahk

; ==============================================================================
; MODULE: Audit 2026-07-20 (second pass) — findings F-09, F-10, F-12, F-13
; DESCRIPTION:
; Four independent guards that share no source file, grouped so each keeps its
; own root-cause rationale rather than being scattered into unrelated suites.
;
; F-09  KLWV_IsIsoDate used "\\d" inside a double-quoted AHK string. AHK v2
;       escapes with a BACKTICK, not a backslash, so PCRE received a literal
;       backslash plus a literal "d": the pattern matched only the text
;       \dddd-\dd-\dd and no real date could ever pass. Every dashboard range
;       request was rejected by KLWV_NormalizeRangeRequest with a bare 0 and
;       dropped with no log — the spinner span forever.
;
; F-10  _SR_Poll used to delete its task key after yielding in FileRead. A
;       Has-then-Delete guard prevented Map.Delete from throwing but did not make
;       completion and terminate one atomic winner: OnDone could still fire from
;       the stale snapshot after terminate had retired ownership. The poll now
;       claims the exact ObjPtr before any exit lookup, file I/O, or callback.
;
; F-12  LLM_OllamaCancelWarmupRetry never bumped _LLM_Ollama_WarmupGeneration.
;       The counter moved only on the START path, so the gen guard in the
;       completion callbacks could not invalidate anything a RESET was meant to
;       invalidate. The poll chain re-arms from an anonymous closure with no
;       cancel handle, so bumping the generation is the only way a cancel can
;       stop a late response mutating warmup state after a pause.
;
; F-13  _TooltipTimerFn had no A_IsSuspended guard. SetTimer bypasses native
;       Suspend, so it fired while paused and mutated hotstring-engine state.
;       The canonical deadline now delegates to an exact-owner helper which
;       preserves the deadline across a compensable raw pause and rejects before
;       TooltipHide; sibling callbacks still guard suspension directly.
; ==============================================================================

#Requires AutoHotkey v2.0

_A0720B2_IsoDatePatternMatchesARealDate() {
	Src := _DriverSourceNoComments()
	Assert(RegExMatch(Src, 'KLWV_ISO_DATE_PATTERN\s*:=\s*"([^"]+)"', &M) > 0,
		"the ISO-date pattern must be a named constant so this test can exercise the literal the driver actually compiles, not a copy of it")
	Pattern := M[1]

	Assert(RegExMatch("2026-07-20", Pattern) > 0,
		"KLWV_ISO_DATE_PATTERN must match a real ISO date — a backslash-escaped digit class reaches PCRE as a LITERAL backslash in AHK v2, which silently kills every dashboard range request")
	Assert(RegExMatch("2026-7-20", Pattern) = 0 and RegExMatch("not-a-date", Pattern) = 0,
		"KLWV_ISO_DATE_PATTERN must still reject malformed dates")

	Body := _DriverFuncBody("KLWV_IsIsoDate")
	Assert(Body != "", "KLWV_IsIsoDate must exist in modules/keylogger/keylogger_webview.ahk")
	Assert(InStr(Body, "KLWV_ISO_DATE_PATTERN") > 0,
		"KLWV_IsIsoDate must use the named pattern constant rather than an inline literal")
}
Test("keylogger-webview: the ISO-date guard actually matches an ISO date (F-09)",
	_A0720B2_IsoDatePatternMatchesARealDate)


_A0720B2_RangeRejectionIsLogged() {
	Body := _DriverFuncBody("KLWV_NormalizeRangeRequest")
	Assert(Body != "", "KLWV_NormalizeRangeRequest must exist")
	Assert(InStr(Body, "LoggerWarn") > 0,
		"KLWV_NormalizeRangeRequest must log a rejected range request — a bare `return 0` makes a malformed request indistinguishable from no request, which is exactly why the broken date pattern stayed invisible")
}
Test("keylogger-webview: a rejected range request is logged, not dropped silently (F-09)",
	_A0720B2_RangeRejectionIsLogged)


_A0720B2_SRPollClaimsBeforeYielding() {
	Body := _DriverFuncBody("_SR_Poll")
	Assert(Body != "", "_SR_Poll must exist in adapters/shell_runner.ahk")
	ClaimPos := InStr(Body, "_SR_LegacyClaimCompletion(task_id, task)")
	FinishPos := InStr(Body, "_SR_LegacyFinishCompletion(claim, exit_code)")
	Assert(ClaimPos > 0,
		"_SR_Poll must atomically claim the exact task from its stale snapshot")
	Assert(FinishPos > ClaimPos,
		"_SR_Poll must claim ownership before output capture and OnDone dispatch")
	Assert(InStr(Body, "_SR_ActiveTasks.Delete(task_id)") = 0,
		"_SR_Poll must not perform a Has-then-Delete itself because that does not stop OnDone after a concurrent terminate")
	ClaimBody := _DriverFuncBody("_SR_LegacyClaimCompletion")
	Assert(InStr(ClaimBody, "_SR_LegacyRegistryOwnsLocked") > 0,
		"the completion claim must verify exact live identity before deletion")
}
Test("shell-runner: _SR_Poll claims exact ownership before yielding (F-10)", _A0720B2_SRPollClaimsBeforeYielding)


_A0720B2_WarmupCancelBumpsGeneration() {
	Body := _DriverFuncBody("LLM_OllamaCancelWarmupRetry")
	Assert(Body != "", "LLM_OllamaCancelWarmupRetry must exist")
	Assert(InStr(Body, "_LLM_Ollama_WarmupGeneration += 1") > 0,
		"LLM_OllamaCancelWarmupRetry must bump _LLM_Ollama_WarmupGeneration — a counter incremented only on the START path can never invalidate a RESET, and the warmup poll chain re-arms from an anonymous closure with no cancel handle, so this bump is the only thing stopping a late response from setting _LLM_Ollama_IsReady and resetting the backoff ramp after the user paused")
	Assert(InStr(Body, "global") > 0 and InStr(Body, "_LLM_Ollama_WarmupGeneration") > 0,
		"_LLM_Ollama_WarmupGeneration must be declared global in the cancel function, or the increment would create a local and silently do nothing")
}
Test("llm-ollama: cancelling warmup invalidates in-flight callbacks (F-12)",
	_A0720B2_WarmupCancelBumpsGeneration)


; Class-wide: direct timer callbacks guard suspension themselves, while the
; canonical safety deadline delegates to one exact-owner helper which performs
; the guard before any hide attempt.
_A0720B2_EveryTooltipTimerIsSuspendGuarded() {
	for _, Fn in ["_TooltipDeferredShowFn", "_TooltipDequeueDeadlineFn",
			"_TooltipDequeuePollFn"] {
		Body := _StripFullLineComments(_DriverFuncBody(Fn))
		Assert(Body != "", Fn . " must exist in ui/tooltip/core.ahk")
		Assert(InStr(Body, "A_IsSuspended") > 0,
			Fn . " must bail out on A_IsSuspended because SetTimer callbacks bypass native Suspend")
	}
	Timer := _StripFullLineComments(_DriverFuncBody("_TooltipTimerFn"))
	Retry := _StripFullLineComments(
		_DriverFuncBody("_TooltipTimerHideOrRetry"))
	Assert(Timer != "" and Retry != "",
		"the canonical tooltip timer and its exact-owner retry helper must remain discoverable")
	Delegate := InStr(Timer, "_TooltipTimerHideOrRetry(")
	Assert(Delegate > 0 and InStr(Timer, "TooltipHide(") == 0,
		"the canonical timer must delegate instead of hiding or mutating tooltip state directly")
	SuspendGuard := InStr(Retry, "if A_IsSuspended")
	SuspendedRetry := InStr(Retry,
		"return _TooltipScheduleTimerRetry(", true, SuspendGuard)
	HideAttempt := InStr(Retry,
		'TooltipHide("TimerFn", true, ExpectedGeneration, ExpectedSurface)',
		true, SuspendedRetry)
	Assert(SuspendGuard > 0 and SuspendedRetry > SuspendGuard
		and HideAttempt > SuspendedRetry,
		"the delegated timer must preserve its exact deadline and return before any hide while suspended")
}
Test("tooltip: every tooltip timer honours the suspend invariant (F-13)",
	_A0720B2_EveryTooltipTimerIsSuspendGuarded)
