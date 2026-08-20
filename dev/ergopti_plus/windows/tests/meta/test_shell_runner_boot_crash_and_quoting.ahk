; tests/meta/test_shell_runner_boot_crash_and_quoting.ahk

; ==============================================================================
; MODULE: ShellRunner Boot-Crash and Quoting Regression Tests
; DESCRIPTION:
; Retroactive regression coverage for the audit's F1 finding (the single most
; consequential bug in AUDIT_AHK_2026-07-01.md): adapters/shell_runner.ahk had
; NO dedicated tests despite shipping a fat-arrow multi-statement body that
; aborted the ENTIRE driver's boot (AHK v2 tokenises the whole compilation unit
; before running anything, and ErgoptiPlus.ahk #Includes this adapter).
;
; Six distinct sub-bugs were bundled in that one fix; each gets its own
; assertion here so none of them can silently regress:
;   1. Fat-arrow multi-statement handle.start/terminate bodies -> boot-crash.
;   2. ShellRunner_Exec's RunWait command must wrap the WHOLE
;      "Cmd > TmpFile 2>&1" tail in one extra outer quote pair, or cmd.exe's
;      /c never strips the wrapping quotes and the redirection silently never
;      applies.
;   3. ShellRunner_Spawn escaped a literal quote inside an Arg with a no-op
;      backtick-quote (discarded inside a single-quoted AHK v2 literal)
;      instead of doubling it.
;   4. ShellRunner_Spawn built its command with no shell in the picture (a
;      bare Run(), no A_ComSpec /c), so redirection never worked.
;   5. Missing `global` declarations on _SR_TaskCounter (ShellRunner_Spawn)
;      and _SR_PollRunning (_SR_EnsurePoller, _SR_Poll) let AHK v2's
;      auto-local scoping shadow the module globals, throwing on the very
;      first read/increment.
;   6. terminate() called Map.Delete() on a key that might never have been
;      inserted (start() never ran), throwing "Item has no value".
;
; Needles containing a literal quote or backtick are built via Chr() instead
; of inline backslash/backtick escapes, to avoid the exact `\"`-style parse
; hazard already documented elsewhere in this test suite.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================================================
; ======================================================================
; ======= 1/ No fat-arrow multi-statement handle.start/terminate =======
; ======================================================================
; ======================================================================

_TSRBC_NoFatArrowBootCrash() {
	Body := _DriverFuncBody("ShellRunner_Spawn")
	Assert(Body != "", "ShellRunner_Spawn must exist in adapters/shell_runner.ahk")

	Assert(!InStr(Body, "handle.start := () =>"),
		"ShellRunner_Spawn must not assign handle.start via a fat-arrow function — a "
		. "multi-statement fat-arrow body is a parse error that aborts the ENTIRE "
		. "driver's boot (F1, shell-runner-boot-crash)")
	Assert(!InStr(Body, "handle.terminate := () =>"),
		"ShellRunner_Spawn must not assign handle.terminate via a fat-arrow function "
		. "(F1, shell-runner-boot-crash)")

	Assert(InStr(Body, "_SR_HandleStart") > 0 and InStr(Body, "_SR_HandleTerminate") > 0,
		"ShellRunner_Spawn must define handle.start/terminate as named nested functions "
		. "(_SR_HandleStart/_SR_HandleTerminate) instead of fat-arrow closures (F1, shell-runner-boot-crash)")

	StartBody := _DriverFuncBody("_SR_HandleStart")
	Assert(StartBody != "", "_SR_HandleStart must exist as a standalone nested function")
	TermBody := _DriverFuncBody("_SR_HandleTerminate")
	Assert(TermBody != "", "_SR_HandleTerminate must exist as a standalone nested function")
}
Test("shell_runner: no fat-arrow multi-statement handle.start/terminate bodies (F1, shell-runner-boot-crash)",
	_TSRBC_NoFatArrowBootCrash)




; ======================================================================
; ======================================================================
; ======= 2/ ShellRunner_Exec wraps the whole redirection tail =========
; ======================================================================
; ======================================================================

_TSRBC_ExecOuterQuoteWrap() {
	Body := _DriverFuncBody("ShellRunner_Exec")
	Assert(Body != "", "ShellRunner_Exec must exist in adapters/shell_runner.ahk")

	; The bug: quoting only Cmd and closing the quote BEFORE the redirection
	; makes the last character of the /c argument a digit, not a quote, so
	; cmd.exe never strips the wrapping quotes.
	BuggyNeedle := "' . Cmd . '" . Chr(34) . " > " . Chr(34)
	Assert(InStr(Body, BuggyNeedle) == 0,
		"ShellRunner_Exec must not close the quote right after Cmd and before the "
		. "redirection — cmd.exe's /c only strips a quote pair when the FIRST and "
		. "LAST characters of the whole argument are quotes (shell-runner-quote-wrap)")

	; The fix: the ENTIRE tail (Cmd, redirection, TmpFile, 2>&1) is wrapped in one
	; outer quote pair that closes only at the very end, right after "2>&1".
	FixedNeedle := "2>&1" . Chr(34)
	Assert(InStr(Body, FixedNeedle) > 0,
		"ShellRunner_Exec's RunWait command must end with a closing quote right after "
		. "2>&1 so the outer quote pair wraps the whole redirection tail (shell-runner-quote-wrap)")
}
Test("shell_runner: ShellRunner_Exec wraps the whole redirection tail in one outer quote pair (shell-runner-quote-wrap)",
	_TSRBC_ExecOuterQuoteWrap)




; ======================================================================
; ======================================================================
; ======= 3/ ShellRunner_Spawn doubles quotes, does not backtick-escape=
; ======================================================================
; ======================================================================

_TSRBC_SpawnDoublesQuotes() {
	Body := _DriverFuncBody("ShellRunner_Spawn")
	Assert(Body != "", "ShellRunner_Spawn must exist in adapters/shell_runner.ahk")

	; The bug: a backtick-quote escape is a no-op inside a single-quoted AHK v2
	; string literal (the backtick is discarded), so Arg was never actually escaped.
	BuggyNeedle := "StrReplace(Arg, '" . Chr(34) . "', '" . Chr(96) . Chr(34) . "')"
	Assert(InStr(Body, BuggyNeedle) == 0,
		"ShellRunner_Spawn must not escape a literal quote in Arg with a backtick-quote "
		. "— it is a no-op inside a single-quoted AHK v2 literal (shell-runner-quote-escape)")

	; The fix: doubling the quote is the form both cmd.exe and Run()'s
	; ShellExecute-based launch actually honour.
	FixedNeedle := "StrReplace(Arg, '" . Chr(34) . "', '" . Chr(34) . Chr(34) . "')"
	Assert(InStr(Body, FixedNeedle) > 0,
		"ShellRunner_Spawn must escape a literal quote in Arg by DOUBLING it "
		. "(shell-runner-quote-escape)")
}
Test("shell_runner: ShellRunner_Spawn escapes Arg quotes by doubling, not backtick (shell-runner-quote-escape)",
	_TSRBC_SpawnDoublesQuotes)




; ======================================================================
; ======================================================================
; ======= 4/ ShellRunner_Spawn routes through A_ComSpec /c =============
; ======================================================================
; ======================================================================

_TSRBC_SpawnRoutesThroughComSpec() {
	Body := _DriverFuncBody("ShellRunner_Spawn")
	Assert(Body != "", "ShellRunner_Spawn must exist in adapters/shell_runner.ahk")

	Assert(InStr(Body, "A_ComSpec") > 0 and InStr(Body, "/c") > 0,
		"ShellRunner_Spawn must route its command through A_ComSpec /c so the "
		. "redirection tokens are interpreted by a real shell — a bare Run() with "
		. "no shell in the picture never redirects stdout/stderr for a genuine "
		. "external program (shell-runner-no-shell-redirect)")
}
Test("shell_runner: ShellRunner_Spawn routes the command through A_ComSpec /c (shell-runner-no-shell-redirect)",
	_TSRBC_SpawnRoutesThroughComSpec)




; ======================================================================
; ======================================================================
; ======= 5/ global declarations guard against auto-local shadowing ====
; ======================================================================
; ======================================================================

_TSRBC_GlobalDeclarationsPresent() {
	SpawnBody := _DriverFuncBody("ShellRunner_Spawn")
	Assert(SpawnBody != "", "ShellRunner_Spawn must exist in adapters/shell_runner.ahk")
	Assert(InStr(SpawnBody, "global _SR_TaskCounter") > 0,
		"ShellRunner_Spawn must declare 'global _SR_TaskCounter' — without it AHK v2 "
		. "treats the pre-incremented name as an unassigned function-local, throwing "
		. "on the very first call (shell-runner-auto-local-shadow)")

	EnsureBody := _DriverFuncBody("_SR_EnsurePoller")
	Assert(EnsureBody != "", "_SR_EnsurePoller must exist in adapters/shell_runner.ahk")
	Assert(InStr(EnsureBody, "global _SR_PollRunning") > 0,
		"_SR_EnsurePoller must declare 'global _SR_PollRunning' — the read on the very "
		. "next line would otherwise throw on an unassigned local (shell-runner-auto-local-shadow)")

	PollBody := _DriverFuncBody("_SR_Poll")
	Assert(PollBody != "", "_SR_Poll must exist in adapters/shell_runner.ahk")
	Assert(InStr(PollBody, "global _SR_PollRunning") > 0,
		"_SR_Poll must also declare 'global _SR_PollRunning' — same auto-local "
		. "shadowing hazard as _SR_EnsurePoller (shell-runner-auto-local-shadow)")
}
Test("shell_runner: _SR_TaskCounter/_SR_PollRunning are declared global where assigned (shell-runner-auto-local-shadow)",
	_TSRBC_GlobalDeclarationsPresent)




; ======================================================================
; ======================================================================
; ======= 6/ terminate() claims exact task before Map.Delete ===========
; ======================================================================
; ======================================================================

_TSRBC_TerminateUsesExactClaim() {
	HandleBody := _DriverFuncBody("_SR_HandleTerminate")
	Assert(InStr(HandleBody, "_SR_LegacyClaimTerminate(state)") > 0,
		"_SR_HandleTerminate must delegate pre-start and live-task ownership to the atomic claim helper")
	Assert(InStr(HandleBody, "_SR_ActiveTasks.Delete(") = 0,
		"the public handle must not perform a racy Has-then-Delete itself")

	ClaimBody := _DriverFuncBody("_SR_LegacyClaimTerminate")
	ReadyPos := InStr(ClaimBody, "phase = SR_LEGACY_PHASE_READY")
	IdentityPos := InStr(ClaimBody, "_SR_LegacyRegistryOwnsLocked(State)")
	DeletePos := InStr(ClaimBody, '_SR_ActiveTasks.Delete(State["TaskId"])')
	Assert(ReadyPos > 0 and IdentityPos > ReadyPos and DeletePos > IdentityPos,
		"terminate-before-start must return before deletion, while a live task must pass exact identity before Delete (shell-runner-terminate-delete-unguarded)")
}
Test("shell_runner: terminate-before-start is a no-op and live deletion is exact (shell-runner-terminate-delete-unguarded)",
	_TSRBC_TerminateUsesExactClaim)
