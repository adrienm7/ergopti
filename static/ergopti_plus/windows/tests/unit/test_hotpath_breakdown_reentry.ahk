; tests/unit/test_hotpath_breakdown_reentry.ahk

; ==============================================================================
; MODULE: Hot-path Breakdown Reentry Tests
; DESCRIPTION: Nested presentations must retain independent sub-step attribution.
; ==============================================================================

#Requires AutoHotkey v2.0

_HPBR_Nested(DrainInner) {
	OuterMarks := HotPath_BreakdownBegin()
	HotPath_BreakdownMark("outer_before", HotPath_Now(), OuterMarks)
	InnerMarks := HotPath_BreakdownBegin()
	HotPath_BreakdownMark("inner_only", HotPath_Now(), InnerMarks)
	if DrainInner {
		Inner := HotPath_BreakdownDetail(InnerMarks)
		AssertTrue(InStr(Inner, "inner_only "))
		AssertFalse(InStr(Inner, "outer_before "))
	}
	HotPath_BreakdownMark("outer_after", HotPath_Now(), OuterMarks)
	Outer := HotPath_BreakdownDetail(OuterMarks)
	if !DrainInner
		AssertFalse(InStr(Outer, "inner_only "),
			"an interrupted child must not donate its marks to the resumed parent")
	AssertTrue(InStr(Outer, "outer_before "),
		"a nested presentation must not erase the parent's earlier marks")
	AssertTrue(InStr(Outer, "outer_after "))
	AssertTrue(InStr(Outer, "outer_before ") < InStr(Outer, "outer_after "))
	AssertTrue(HotPath_BreakdownDetail(OuterMarks) == "")
	if !DrainInner
		AssertTrue(InStr(HotPath_BreakdownDetail(InnerMarks), "inner_only "))
}

for DrainInner in [true, false]
	Test("hotpath breakdown: nested scope drained=" . DrainInner . " (hotpath-breakdown-reentry)",
		_HPBR_Nested.Bind(DrainInner))
