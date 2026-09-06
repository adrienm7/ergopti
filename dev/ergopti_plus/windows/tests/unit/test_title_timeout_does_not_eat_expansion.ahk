; tests/unit/test_title_timeout_does_not_eat_expansion.ahk

; =============================================================================
; MODULE: Title deadline never eats an expansion
;         (hotstring-title-timeout-eats-expansion)
; DESCRIPTION:
; The hotstring send path resolves one foreground receipt with RequireTitle and
; refuses to expand when that receipt is invalid. The title probe behind it is a
; SendMessageTimeout with a 5 ms budget, so any foreground window that is busy
; for a few milliseconds -- a browser mid-layout, an Electron app, a window
; repainting -- made the receipt invalid and the expansion vanished.
;
; Nothing said so. _OutputHostReject throttles identical diagnostics to one per
; minute, and the dispatch returns a bare false, so the user sees a hotstring
; that simply does not fire. Field logs from 2026-09-05 show "ct" + the magic
; key failing a dozen times between 21:10:23 and 21:10:52, succeeding once at
; 21:10:39, and reloads changing nothing -- because the driver was never the
; thing that was broken.
;
; ROOT CAUSE ENCODED: a latency budget is not a correctness proof. Identity and
; metadata are verified before the title is ever read, so a missed title
; deadline must degrade the ONE decision the title feeds, not the receipt. These
; tests pin both halves: the receipt survives, and the terminal classification
; still answers from the executable when the title is unavailable.
; =============================================================================

#Requires AutoHotkey v2.0

_TTE_CountOccurrences(Haystack, Needle) {
	Count := 0
	Offset := 1
	loop {
		Found := InStr(Haystack, Needle, , Offset)
		if !Found
			break
		Count += 1
		Offset := Found + StrLen(Needle)
	}
	return Count
}





; ============================================================
; ============================================================
; ======= 1/ A missed deadline degrades, never rejects =======
; ============================================================
; ============================================================

_TTE_TheResolverDegradesOnADeadline() {
	Body := _DriverFuncBody("OutputHostResolve")
	Assert(Body != "",
		"OutputHostResolve must be readable -- a renamed resolver would make every "
		. "assertion here pass vacuously (hotstring-title-timeout-eats-expansion)")
	Stripped := _StripFullLineComments(Body)

	Assert(InStr(Stripped, '_OutputHostReject("title_timeout"') = 0,
		"a title deadline must not reject the receipt: the caller turns an invalid "
		. "receipt into a silent `return false`, which is the user's expansion "
		. "disappearing (hotstring-title-timeout-eats-expansion)")
	Assert(InStr(Stripped, '_OutputHostLogFailure("title_timeout")') > 0,
		"the deadline must still be reported -- degrading is not the same as hiding")
	Assert(InStr(Stripped, '_OutputHostReject("title_error"') > 0,
		"a probe that FAILED rather than timed out is not a deadline and must still "
		. "fail closed; without this the test above would pass by removing both")
}

Test("title deadline: the resolver degrades instead of rejecting (hotstring-title-timeout-eats-expansion)",
	_TTE_TheResolverDegradesOnADeadline)





; ===============================================================
; ===============================================================
; ======= 2/ The send path still refuses only on validity =======
; ===============================================================
; ===============================================================

; The degrade above only reaches the user if the consumers keep gating on
; "Valid" alone. A consumer that also refused on TimedOut would reinstate the
; whole defect one level up, so enumerate every RequireTitle site.
_TTE_EveryTitleConsumerGatesOnValidityAlone() {
	Src := _DriverSourceNoComments()
	Assert(Src != "", "driver source must be readable")

	Sites := _TTE_CountOccurrences(Src, "OutputHostResolve(true)")
	Assert(Sites >= 2,
		"both RequireTitle consumers in the send path must still exist; found "
		. Sites . " (hotstring-title-timeout-eats-expansion)")

	Assert(InStr(Src, 'Host["TimedOut"]') = 0
			&& InStr(Src, 'OutputHost["TimedOut"]') = 0
			&& InStr(Src, 'RawHost["TimedOut"]') = 0,
		"no send-path consumer may refuse an expansion because the title probe was "
		. "slow: identity and metadata are proven, and the title feeds exactly one "
		. "classification (hotstring-title-timeout-eats-expansion)")
}

Test("title deadline: every title consumer refuses on validity alone (hotstring-title-timeout-eats-expansion)",
	_TTE_EveryTitleConsumerGatesOnValidityAlone)





; ================================================================
; ================================================================
; ======= 3/ The degraded classification stays truthful ==========
; ================================================================
; ================================================================

; What the degrade actually costs, stated as a test rather than left to trust:
; a known terminal is still recognised by its executable, and only the embedded
; substring heuristic loses its answer. That is the trade being made, and it is
; strictly smaller than losing every expansion.
_TTE_TerminalClassificationSurvivesAnEmptyTitle() {
	Known := ["WindowsTerminal.exe", "mintty.exe", "tabby.exe", "hyper.exe"]
	Checked := 0
	for Exe in Known {
		AssertTrue(_HSE_IsTerminalInputHost(Exe, ""),
			Exe . " must still be classified as a terminal without a title -- the "
			. "executable list never needed one "
			. "(hotstring-title-timeout-eats-expansion)")
		Checked += 1
	}
	AssertEqual(Known.Length, Checked,
		"every executable-listed terminal must have been inspected")

	AssertFalse(_HSE_IsTerminalInputHost("Code.exe", ""),
		"an ordinary editor must not be mistaken for a terminal when the title is "
		. "unavailable -- degrading must not invent a classification")
	AssertTrue(_HSE_IsTerminalInputHost("Code.exe", "freebuff — session"),
		"and with a title, the embedded-terminal heuristic must still work; this is "
		. "precisely the answer a timed-out probe gives up")
}

Test("title deadline: terminal classification survives an empty title (hotstring-title-timeout-eats-expansion)",
	_TTE_TerminalClassificationSurvivesAnEmptyTitle)
