; tests/unit/test_logger_format_failure_is_visible.ahk

; ==============================================================================
; MODULE: Logger Format-Failure Visibility Regression Test
; DESCRIPTION:
; Regression guard for logger-format-failure-silent.
;
; ROOT CAUSE ENCODED: _LoggerEmit wrapped Format(Msg, Args*) in a try whose
; catch assigned the raw template back to Body and did nothing else. A line
; whose arguments could not be substituted was therefore emitted with every
; placeholder intact and every value missing, and the failure itself was
; recorded nowhere — the emitted line was indistinguishable from a developer
; who had genuinely written braces into a message. Three config-load traces per
; boot lost their key that way.
;
; The invariant: a swallowed formatting failure must leave evidence ON the line
; it damaged. Reporting it through the logger would risk recursion on the hot
; path, so the marker is appended to the body. This is the §5.3 fail-loudly rule
; applied to the logger itself, which is the one component that cannot report
; its own failures through the normal channel.
;
; SCOPE: behavioural — drives the real LoggerInfo entry point and reads the ring
; buffer, so a comment mentioning the marker cannot satisfy it.
;
; KNOWN LIMITATION, stated so a future reader is not misled: this covers the
; RAISING path only. A placeholder index the argument list cannot satisfy does
; NOT raise in AHK v2 — Format("value={2}", "a") returns the literal
; "value={2}" — so that shape still loses information silently without ever
; reaching the catch. Closing it would mean validating placeholder indices
; against Args.Length on every emit, which is per-keystroke work on the hot
; path; it was deliberately left out of this fix.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================================
; =========================================================================
; ======= 1/ A failed substitution leaves evidence on the line =============
; =========================================================================
; =========================================================================

; Minimal, self-contained logger reset. Deliberately NOT reusing
; test_logger.ahk's _ResetLogger: this file must not depend on the include order
; of another test file. Paths are blanked so nothing touches the real log.
_LFFV_Reset() {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := "DEBUG"
	_LOGGER_PENDING := []
	_LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
}

; Concatenate whatever the ring buffer captured, so the assertions do not depend
; on the ring's internal layout.
_LFFV_RingText() {
	global LOGGER_RING_BUFFER
	Out := ""
	for _, Line in LOGGER_RING_BUFFER
		Out .= Line . "`n"
	return Out
}

_LFFV_FailedFormatIsMarked() {
	_LFFV_Reset()
	; An OBJECT argument is what actually makes Format raise, measured on AHK
	; 2.0.26: Format("value={1}", Map()) throws
	;   TypeError: Parameter #2 of Format requires a String, but received a Map.
	; A missing placeholder INDEX does not raise — Format("value={2}", "a")
	; returns the literal "value={2}" — so an out-of-range index would exercise
	; the success path and this test would pass against the unfixed code.
	; Passing an object where a string was meant is also the realistic production
	; trigger for this branch.
	LoggerInfo("LFFVTest", "value={1} tail", Map())
	Text := _LFFV_RingText()

	Assert(InStr(Text, "LFFVTest") > 0,
		"the line must still be emitted — a formatting failure must never cost the log line itself")
	Assert(InStr(Text, "log format failed") > 0,
		"a failed Format() substitution must leave evidence ON the emitted line. Without it the line carries "
		. "its placeholders and none of its values while looking like a normal entry, and nothing anywhere "
		. "records that the substitution failed (conventions 5.3) (logger-format-failure-silent)")
	Assert(InStr(Text, "1 arg(s) not substituted") > 0,
		"the marker must state how many arguments were lost, so the reader knows what is missing rather than "
		. "only that something is")
}

_LFFV_SuccessfulFormatIsUntouched() {
	_LFFV_Reset()
	LoggerInfo("LFFVTest", "value={1} tail", "substituted")
	Text := _LFFV_RingText()

	Assert(InStr(Text, "value=substituted tail") > 0,
		"a well-formed message must still be substituted normally")
	Assert(InStr(Text, "log format failed") == 0,
		"a successful Format() must NOT carry the failure marker — the marker would otherwise be noise on "
		. "every line and stop meaning anything")
}

_LFFV_NoArgsPathIsUntouched() {
	_LFFV_Reset()
	; Braces in a message with NO args must pass through verbatim: the Format
	; call is skipped entirely, so this path must not gain a marker either.
	LoggerInfo("LFFVTest", "literal {braces} kept")
	Text := _LFFV_RingText()

	Assert(InStr(Text, "literal {braces} kept") > 0,
		"a message with no arguments must be emitted verbatim, braces included")
	Assert(InStr(Text, "log format failed") == 0,
		"the no-argument path never calls Format(), so it must never be marked as a formatting failure")
}


Test("logger: a failed Format() substitution is marked on the emitted line (logger-format-failure-silent)",
	_LFFV_FailedFormatIsMarked)
Test("logger: a successful Format() carries no failure marker (logger-format-failure-silent)",
	_LFFV_SuccessfulFormatIsUntouched)
Test("logger: a message with no arguments keeps its braces and is not marked (logger-format-failure-silent)",
	_LFFV_NoArgsPathIsUntouched)
