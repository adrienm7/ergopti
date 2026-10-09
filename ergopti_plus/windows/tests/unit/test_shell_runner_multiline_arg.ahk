; tests/unit/test_shell_runner_multiline_arg.ahk

; ==============================================================================
; MODULE: ShellRunner Multi-line Argument Guard
; DESCRIPTION:
; ShellRunner_Spawn routes its command through A_ComSpec /c so the stdout
; redirection is interpreted by a real shell. cmd.exe terminates its /c command
; string at the first 0x0A, so an Arg carrying a newline drops the redirection
; tail AND every argument after it — measured end to end, the target program is
; never launched at all, yet cmd.exe still exits 0, no temp file is created, and
; the poller reports exit=0 with an empty stdout.
;
; That is a pseudo-success no caller can tell from a real one. The updater's
; staging worker passed a 39-line PowerShell script as its -Command argument and
; therefore took its `ExitCode != 0 or Stdout != "READY"` failure branch on every
; single attempt: one ERROR line, one download-error dialog, and no update ever
; installed.
;
; ROOT CAUSE ENCODED: the transport cannot carry a newline, so the adapter must
; refuse one at the door (conventions 5.3) instead of manufacturing a clean-
; looking success. The shipped guard for the fix that introduced the cmd.exe hop
; only asserts that the source mentions "A_ComSpec" and "/c" — structurally
; incapable of noticing that the mandated transport silently drops stdout.
;
; SCOPE: behavioural — it drives the real adapter, no source grepping.
; ==============================================================================

#Requires AutoHotkey v2.0





; ===========================================
; ===========================================
; ======= 1/ A newline Arg is refused =======
; ===========================================
; ===========================================

; Every newline flavour, not just LF: CRLF and a bare CR reach cmd.exe the same
; way, and a guard that only knew about "`n" would let the Windows-native
; spelling through.
_SRML_NewlineArgIsRefused() {
	Checked := 0
	for Sep in [Chr(10), Chr(13) . Chr(10), Chr(13)] {
		Handle := ShellRunner_Spawn("cmd.exe", ["/c", "echo a" . Sep . "echo b"], (*) => 0)
		Assert(IsObject(Handle), "ShellRunner_Spawn must still return a handle for a rejected command")
		Started := Handle.start()
		Assert(Started == false,
			"ShellRunner_Spawn must refuse an Arg containing a newline: cmd.exe truncates its /c command line at the first newline, so the process never runs, the redirection tail is discarded and OnDone fires with exit 0 and an empty stdout — a failure indistinguishable from success")
		try Handle.terminate()
		Checked += 1
	}
	Assert(Checked = 3, "all three newline spellings must be exercised")
}

; Positive control: the guard must reject newlines, not everything. Without this
; a `return false` at the top of start() would satisfy the assertion above.
_SRML_SingleLineArgStillSpawns() {
	Handle := ShellRunner_Spawn("cmd.exe", ["/c", "echo ok"], (*) => 0)
	Started := Handle.start()
	Assert(Started == true,
		"a single-line Arg must still spawn — the newline guard must not turn into a blanket refusal")
	try Handle.terminate()
}


Test("shell_runner: an Arg containing a newline is refused instead of silently losing stdout",
	_SRML_NewlineArgIsRefused)
Test("shell_runner: a single-line Arg still spawns (newline guard is not a blanket refusal)",
	_SRML_SingleLineArgStillSpawns)
