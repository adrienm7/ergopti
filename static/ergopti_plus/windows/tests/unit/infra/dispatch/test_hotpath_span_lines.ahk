; tests/unit/infra/dispatch/test_hotpath_span_lines.ahk

; ==============================================================================
; MODULE: Paired Span Lines On The Paths A Person Waits On
; DESCRIPTION:
; Linux and macOS write "[TRACE] [Span] <name>…" and "[DONE] [Span] <name> done
; in N ms" at DEBUG for an expansion typed, a tray branch filled and a layout
; switched, so one search finds the same line on every OS. Windows wrote none,
; so a verbose field log on the maintainer's PC could not be compared with the
; other two. These cases prove the pair is written at DEBUG only, that it names
; the outcome, and that each waited-on path opens and closes its span.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ The paired lines =========
; =====================================
; =====================================

; Clears the ring and sets the level, so a case sees only its own lines.
; @param Level {String} The logger's minimum level for the case.
_HSL_Reset(Level) {
	global LOGGER_RING_BUFFER, LOGGER_RING_CURSOR, LOGGER_MIN_LEVEL
	global _LOGGER_PENDING, _LOGGER_PENDING_ERRORS
	global LOGGER_LOG_PATH, LOGGER_ERRORS_LOG_PATH
	global _LOGGER_DEDUP_KEY, _LOGGER_DEDUP_LEVEL, _LOGGER_DEDUP_COUNT
	LOGGER_RING_BUFFER := []
	LOGGER_RING_CURSOR := 0
	LOGGER_MIN_LEVEL := Level
	_LOGGER_PENDING := []
	_LOGGER_PENDING_ERRORS := []
	LOGGER_LOG_PATH := ""
	LOGGER_ERRORS_LOG_PATH := ""
	_LOGGER_DEDUP_KEY := ""
	_LOGGER_DEDUP_LEVEL := ""
	_LOGGER_DEDUP_COUNT := 0
	_LoggerRefreshFastFlags()
}

; Returns every line the ring holds, one per line.
_HSL_Ring() {
	global LOGGER_RING_BUFFER
	Out := ""
	for _, Line in LOGGER_RING_BUFFER
		Out .= Line . "`n"
	return Out
}

_HSL_DebugWritesThePair() {
	_HSL_Reset("DEBUG")
	Start := HotPath_SpanTrace("hotstring.expand")
	Assert(Start is Integer && Start > 0, "the trace must return a QPC stamp for its closing call")
	Elapsed := HotPath_SpanDone("hotstring.expand", Start, HotstringDispatchOutcome(true))
	Ring := _HSL_Ring()
	_HSL_Reset("INFO")
	Assert(InStr(Ring, "TRACE") && InStr(Ring, "[Span]") && InStr(Ring, "hotstring.expand…"),
		"the opening line must be the Linux and macOS « [TRACE] [Span] hotstring.expand… »: " . Ring)
	Assert(InStr(Ring, "DONE") && InStr(Ring, "hotstring.expand done in ") && InStr(Ring, "(fired)"),
		"the closing line must carry the duration and the outcome: " . Ring)
	Assert(Elapsed >= 0, "the closing call must return the measured milliseconds")
}

_HSL_BelowDebugWritesNothing() {
	_HSL_Reset("INFO")
	Start := HotPath_SpanTrace("tray.fill")
	Elapsed := HotPath_SpanDone("tray.fill", Start, "list=probe")
	Ring := _HSL_Ring()
	Assert(InStr(Ring, "tray.fill") == 0, "below DEBUG the span must write nothing: " . Ring)
	AssertEqual(0.0, Elapsed, "below DEBUG the closing call reads no clock")
}

_HSL_OutcomeNamesEachVerdict() {
	AssertEqual("pending", HotstringDispatchOutcome(Map("Pending", true)))
	AssertEqual("fired", HotstringDispatchOutcome(true))
	AssertEqual("declined", HotstringDispatchOutcome(false))
}





; ===========================================
; ===========================================
; ======= 2/ Every waited-on path ===========
; ===========================================
; ===========================================

; Each path opens and closes its own span. A path left without one is the
; original gap: its field log has no line to compare with the other drivers.
_HSL_EveryPathCarriesItsSpan() {
	Sites := [
		["MenuDeferred_Build", "tray.fill"],
		["_LAY_ChooseEmulation", "layout.switch"],
		["_LAY_SelectActiveLayout", "layout.switch"],
		["_SpaceTap", "hotstring.expand"],
		["HotstringCompleteEndKey", "hotstring.expand"],
	]
	for _, Site in Sites {
		Body := _StripFullLineComments(_DriverFuncBody(Site[1]))
		Assert(InStr(Body, 'HotPath_SpanTrace("' . Site[2] . '")') > 0,
			Site[1] . " must open the « " . Site[2] . " » span")
		Assert(InStr(Body, 'HotPath_SpanDone("' . Site[2] . '"') > 0,
			Site[1] . " must close the « " . Site[2] . " » span")
	}
	; The InputHook's typing path and its held-back end key both dispatch inside
	; the hook file (the first inside a long callback); each dispatch is paired.
	Src := _StripFullLineComments(_DriverFileSource("hotstring_inputhook.ahk"))
	Opens := 0, Closes := 0, Position := 1
	while (Position := InStr(Src, 'HotPath_SpanTrace("hotstring.expand")', , Position)) {
		Opens += 1
		Position += 1
	}
	Position := 1
	while (Position := InStr(Src, 'HotPath_SpanDone("hotstring.expand"', , Position)) {
		Closes += 1
		Position += 1
	}
	AssertEqual(2, Opens, "both InputHook dispatch sites must open the expansion span")
	AssertEqual(2, Closes, "both InputHook dispatch sites must close the expansion span")
}

Test("hotpath-span-lines: DEBUG writes the paired [Span] TRACE and DONE lines with the outcome", _HSL_DebugWritesThePair)
Test("hotpath-span-lines: below DEBUG a span writes nothing and reads no clock", _HSL_BelowDebugWritesNothing)
Test("hotpath-span-lines: the expansion outcome names pending, fired and declined", _HSL_OutcomeNamesEachVerdict)
Test("hotpath-span-lines: the expansion, tray fill and layout switch paths each carry their span", _HSL_EveryPathCarriesItsSpan)
