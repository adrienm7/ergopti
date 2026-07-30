; tests/meta/test_today_bucket_slots_all_fed.ahk

; ==============================================================================
; MODULE: Declared-but-unfed Today Slots (range-reader-today-slots-unfed)
; DESCRIPTION:
; Three sibling readers project the "today" block of the dashboard and only two
; of them were complete. KLR_NewTodayBucket declares thirteen slots, but
; KLR_NGRAM_TYPE_TABLE names only nine, so the remaining four -- kc (keycode
; heatmap), sc_kb (scancode heatmap), sc (shortcuts) and sc_bg (shortcut
; bigrams) -- have to be filled explicitly. KLR_ReadRangeSplitTodayFast and
; KLR_BuildTodayIdxJson did. KLR_ReadRangeSplitToday, the full first-paint AND
; user-range path, iterated KLR_NGRAM_TYPE_TABLE only and returned those four as
; present-and-empty maps: pick a custom date range that includes today and the
; Shortcuts tab loses today's counts and the keyboard heatmap loses today's
; contribution, with no log line and no exception, because every downstream walk
; over a well-formed empty map succeeds as a no-op.
;
; The shipped assertion for this class, _MHC_TodayPathKeepsScancodes, greps the
; whole modules/keylogger directory for one literal, so the correct twin
; satisfied it while the incomplete one stayed short -- exactly the "verified
; the wrong function" mistake the original commit message recorded.
;
; ROOT CAUSE ENCODED: the slot list is derived FROM KLR_NewTodayBucket rather
; than named here, so a fourteenth slot joins this guarantee automatically
; instead of being silently exempt.
; ==============================================================================

#Requires AutoHotkey v2.0





; ======================================
; ======================================
; ======= 1/ Source scan helpers =======
; ======================================
; ======================================

; The function body of EntryName plus the bodies of every KLR_* function it
; calls. One level of delegation is enough: a today projection either writes a
; slot itself or hands it to a single filler helper.
_TBS_ReachableSource(EntryName) {
	Body := _DriverFuncBody(EntryName)
	Out  := Body
	Pos  := 1
	while RegExMatch(Body, "(KLR_\w+)\(", &m, Pos) {
		Pos := m.Pos + m.Len
		if (m[1] = EntryName)
			continue
		Out .= "`n" . _DriverFuncBody(m[1])
	}
	return Out
}





; ======================================================
; ======================================================
; ======= 2/ Every declared slot is actually fed =======
; ======================================================
; ======================================================

_TBS_EveryDeclaredTodaySlotIsFed() {
	Bucket := _DriverFuncBody("KLR_NewTodayBucket")
	Assert(Bucket != "", "KLR_NewTodayBucket must exist")

	; Derive the slot names from the declaration itself.
	Slots := []
	Pos   := 1
	while RegExMatch(Bucket, '"([a-z_]+)",\s*Map\(\)', &m, Pos) {
		Slots.Push(m[1])
		Pos := m.Pos + m.Len
	}
	Assert(Slots.Length >= 13,
		"prerequisite: KLR_NewTodayBucket must still declare the full today bucket. Parsed "
		. Slots.Length . " slot(s)")

	Reach := _TBS_ReachableSource("KLR_ReadRangeSplitToday")
	Assert(Reach != "", "KLR_ReadRangeSplitToday must be resolvable")

	; The nine text n-gram slots are covered by the generic loop over
	; KLR_NGRAM_TYPE_TABLE, which writes through the loop variable.
	Generic := InStr(Reach, "today_idx[app][code]") > 0
	Assert(Generic,
		"prerequisite: the range reader still fills the KLR_NGRAM_TYPE_TABLE slots through "
		. "its generic loop")

	for _, Slot in Slots {
		if KLR_NGRAM_TYPE_TABLE.Has(Slot)
			continue
		Assert(InStr(Reach, 'today_idx[app]["' . Slot . '"]') > 0,
			'the "' . Slot . '" slot is declared by KLR_NewTodayBucket but never written on '
			. "the KLR_ReadRangeSplitToday path. KLR_NGRAM_TYPE_TABLE does not cover it, so "
			. "the generic loop cannot, and the reader hands the dashboard a well-formed "
			. "EMPTY map instead: a declared-but-unfed slot renders nothing and complains "
			. "about nothing (range-reader-today-slots-unfed)")
	}
}

Test("keylogger reader: every declared today slot is fed on the range path (range-reader-today-slots-unfed)",
	_TBS_EveryDeclaredTodaySlotIsFed)





; =========================================================
; =========================================================
; ======= 3/ The three projections share one filler =======
; =========================================================
; =========================================================

; Copying the four queries into the third caller would only have set up the next
; drift -- the defect was three copies of one projection, two of them complete.
_TBS_AuxSlotsHaveASingleOwner() {
	Filler := _DriverFuncBody("KLR__FillTodayAuxTables")
	Assert(Filler != "",
		"KLR__FillTodayAuxTables must exist: the four non-generic today slots need one owner, "
		. "not one copy per reader (range-reader-today-slots-unfed)")

	for _, Caller in ["KLR_ReadRangeSplitToday", "KLR_ReadRangeSplitTodayFast"] {
		Body := _DriverFuncBody(Caller)
		Assert(Body != "", Caller . " must exist")
		Assert(InStr(Body, "KLR__FillTodayAuxTables(") > 0,
			Caller . " must fill its shortcut / keycode / scancode slots through the shared "
			. "helper, so the two paths cannot answer differently again")
	}
}

Test("keylogger reader: both range projections share one aux-slot filler (range-reader-today-slots-unfed)",
	_TBS_AuxSlotsHaveASingleOwner)
