; tests/meta/test_metrics_private_title_memo.ahk

; ==============================================================================
; MODULE: Private-Browsing Title Scan Is Memoized (metrics-private-title-regex-per-event)
; DESCRIPTION:
; MF_ShouldFilter() is the single chokepoint KL_AppendLog calls before any disk
; I/O, so it runs on EVERY logged keylogger event. With the private-browsing
; filter on (the shipped default) it ran seven RegExMatch calls over the focused
; window title every single time — the only real per-event regex site in the
; driver.
;
; ROOT CAUSE ENCODED: the title it scans comes from MetricsFocusCache, which a
; bounded resident timer refreshes every 50 ms; between two refreshes the input
; is byte-identical, so the scan re-derived a value that could not have changed.
; The scan is now memoized on the title itself and only re-runs when the title
; actually changes.
;
; The memo must not become a correctness hole, so three properties are pinned
; alongside it: it lives INSIDE the private_browsing toggle (turning the filter
; off must still skip the check), title and verdict are published together
; through one reference assignment (a timer interrupting mid-scan must never see
; a new title paired with the previous verdict), and MF_ShouldFilterFor — which
; evaluates an arbitrary caller-supplied title, not the live focus cache — keeps
; scanning unconditionally.
;
; SCOPE: source introspection. infra/metrics/metrics_filters.ahk is not among the
; production files the headless runner includes, so MF_ShouldFilter cannot be
; called here; a behavioural twin becomes possible the day that include is added.
; ==============================================================================

#Requires AutoHotkey v2.0




; =====================================================================
; =====================================================================
; ======= 1/ The scan is memoized on the title ========================
; =====================================================================
; =====================================================================

_MFP_ScanIsMemoizedOnTheTitle() {
	Body := _DriverFuncBody("MF_ShouldFilter")
	Assert(Body != "", "MF_ShouldFilter must exist in infra/metrics/metrics_filters.ahk")

	MemoPos  := InStr(Body, "static _private_memo")
	GuardPos := InStr(Body, "title !== memo.title")
	LoopPos  := InStr(Body, "for _, pat in MF_PRIVATE_TITLE_PATTERNS")
	Assert(LoopPos > 0,
		"prerequisite: MF_ShouldFilter must still scan MF_PRIVATE_TITLE_PATTERNS — the memo may skip repeat work, never the check itself")
	Assert(MemoPos > 0,
		"MF_ShouldFilter must memoize the private-browsing title scan — it runs on every logged event, and seven RegExMatch calls per keystroke re-derive a value that only changes when the 50 ms focus refresh publishes a new title (metrics-private-title-regex-per-event)")
	Assert(GuardPos > 0 and GuardPos < LoopPos,
		"the pattern loop must sit behind a title-change guard, otherwise the memo is declared but never spares a single RegExMatch")
}
Test("metrics_filters: the private-browsing title scan is memoized (metrics-private-title-regex-per-event)",
	_MFP_ScanIsMemoizedOnTheTitle)




; =====================================================================
; =====================================================================
; ======= 2/ The memo cannot become a correctness hole ================
; =====================================================================
; =====================================================================

_MFP_MemoObeysTheUserToggle() {
	Body := _DriverFuncBody("MF_ShouldFilter")
	Assert(Body != "", "MF_ShouldFilter must exist")
	TogglePos := InStr(Body, "MetricsFilters.private_browsing")
	MemoUsePos := InStr(Body, "memo := _private_memo")
	Assert(TogglePos > 0, "prerequisite: the private-browsing toggle must still gate the check")
	Assert(MemoUsePos > TogglePos,
		"the memo lookup must sit INSIDE the MetricsFilters.private_browsing branch — a cached 'this title is private' verdict must never survive the user switching the filter off")
}
Test("metrics_filters: the title memo stays inside the private-browsing toggle (metrics-private-title-regex-per-event)",
	_MFP_MemoObeysTheUserToggle)


; Build-then-swap, the same discipline MetricsFocusCache documents: the title
; and its verdict must be published in ONE reference assignment. Written as two
; separate field writes, a timer firing between them would leave the memo
; claiming the new title had the old title's verdict — and a "not private"
; verdict wrongly attached to a private window means keystrokes reach the disk.
_MFP_MemoIsPublishedAtomically() {
	Body := _DriverFuncBody("MF_ShouldFilter")
	Assert(Body != "", "MF_ShouldFilter must exist")
	LoopPos    := InStr(Body, "for _, pat in MF_PRIVATE_TITLE_PATTERNS")
	BuildPos   := InStr(Body, "memo := { title: title, is_private: is_private }")
	PublishPos := InStr(Body, "_private_memo := memo")
	Assert(BuildPos > LoopPos,
		"the memo entry must be built AFTER the scan completes, from a single object literal carrying both the title and its verdict")
	Assert(PublishPos > BuildPos,
		"the freshly built entry must then be published in one reference assignment — two separate field writes leave a window in which the new title carries the previous verdict")
}
Test("metrics_filters: the title memo is published in one atomic swap (metrics-private-title-regex-per-event)",
	_MFP_MemoIsPublishedAtomically)


; MF_ShouldFilterFor evaluates an explicit (app, title) pair for the OUTGOING
; side of an app/window switch. Its title is not the live focus title, so the
; live-focus memo would answer the wrong question for it.
_MFP_OutgoingVariantScansUnconditionally() {
	Body := _DriverFuncBody("MF_ShouldFilterFor")
	Assert(Body != "", "MF_ShouldFilterFor must exist in infra/metrics/metrics_filters.ahk")
	Assert(InStr(Body, "for _, pat in MF_PRIVATE_TITLE_PATTERNS") > 0,
		"prerequisite: MF_ShouldFilterFor must still scan the private-browsing patterns against the supplied title")
	Assert(InStr(Body, "_private_memo") = 0,
		"MF_ShouldFilterFor must NOT read the live-focus title memo — it is handed an arbitrary outgoing title, and a memo keyed on the currently focused window would answer a different question entirely")
}
Test("metrics_filters: the outgoing-context variant does not reuse the live-focus memo (metrics-private-title-regex-per-event)",
	_MFP_OutgoingVariantScansUnconditionally)




; =====================================================================
; =====================================================================
; ======= 3/ No pattern was dropped in the name of speed ==============
; =====================================================================
; =====================================================================

; The cheapest way to "fix" seven regexes per event is to delete some of them.
; The heuristic is deliberately generous — a false positive only means "we
; logged a bit less than we could have", which is the safe direction — so the
; list must keep every locale variant it had.
_MFP_PatternListBlock() {
	Src := _DriverSourceNoComments()
	Start := InStr(Src, "MF_PRIVATE_TITLE_PATTERNS := [")
	if !Start
		return ""
	End := InStr(Src, "]", , Start)
	if !End
		return ""
	return SubStr(Src, Start, End - Start + 1)
}

_MFP_EveryPatternSurvived() {
	Block := _MFP_PatternListBlock()
	Assert(Block != "", "the MF_PRIVATE_TITLE_PATTERNS array literal must be findable in the driver source")
	Count := 0
	Pos := 1
	while (Pos := InStr(Block, '"i)', , Pos)) {
		Count += 1
		Pos += 3
	}
	Assert(Count >= 7,
		"MF_PRIVATE_TITLE_PATTERNS must keep at least its seven case-insensitive heuristics (InPrivate, Incognito, Private Browsing, (Private), Navigation privée, Privé, Privater Modus) — memoizing the scan is the way to make it cheap, dropping locales is not (metrics-private-title-regex-per-event)")
}
Test("metrics_filters: no private-browsing pattern was dropped for speed (metrics-private-title-regex-per-event)",
	_MFP_EveryPatternSurvived)
