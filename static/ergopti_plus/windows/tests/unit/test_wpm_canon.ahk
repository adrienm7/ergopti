; tests/unit/test_wpm_canon.ahk

; ==============================================================================
; MODULE: WPM Widget Canon Tests
; DESCRIPTION:
; The widget's look comes from _shared/modules/wpm_widget/constants.toml, the
; canon macOS and Linux draw from too, and its colours follow the same rules:
; the AI's text paints it in the AI colour — pill and curve alike — neutral
; categories never colour it, and a group without a usable colour takes the
; canon's fallback accent.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPMC_LoadsEveryKeyFromTheCanon() {
	AssertTrue(WPMWidget_LoadSharedConst(), "every canon key must load")
	AssertTrue(WPMWidgetConst.GRAPH_HISTORY > 0, "the graph history comes from the canon")
	AssertTrue(WPMWidgetConst.GRAPH_SCALE_MAX > 0, "the graph scale comes from the canon")
	AssertTrue(WPMWidgetConst.TICK_MS > 0, "the refresh comes from the timings registry")
	AssertTrue(WPMWidgetConst.CORNER_R > 0, "the pill's corners come from the canon")
	AssertEqual(6, StrLen(WPMWidgetConst.COLOR_FALLBACK), "the fallback accent is a bare hex colour")
}
Test("WPM canon: every key loads, no copied default (wpm-canon)",
	_WPMC_LoadsEveryKeyFromTheCanon)

_WPMC_NeutralSourcesComeFromTheCanon() {
	AssertTrue(WPMWidget_LoadSharedConst())
	AssertTrue(_WPMWidget_NeutralCategory("rolls"))
	AssertTrue(_WPMWidget_NeutralCategory("repeat_key"))
	AssertFalse(_WPMWidget_NeutralCategory("magickey"),
		"a hotstring group with a colour of its own must colour the widget")
}
Test("WPM canon: neutral categories are the canon's (wpm-canon)",
	_WPMC_NeutralSourcesComeFromTheCanon)

_WPMC_AiTextPaintsTheAiColour() {
	AssertTrue(WPMWidget_LoadSharedConst())
	AssertEqual(WPMWidgetConst.COLOR_BG_AI, WPMWidget_ResolveBgColor(false, false, true, false, true))
	AssertEqual(WPMWidgetConst.COLOR_BG_AI, WPMWidget_ResolveGraphColor(false, true, false, true),
		"the curve takes the pill's colour, as on macOS and Linux")
	AssertEqual(WPMWidgetConst.COLOR_BG_MANUAL, WPMWidget_ResolveBgColor(false, false, true, false, false),
		"with source colours off the pill stays the manual colour")
	Body := _DriverFuncBody("_LLM_Bridge_CommitInjectedText")
	AssertTrue(InStr(Body, "WPMWidget_Push(false, true)") > 0,
		"accepted AI text must reach the widget marked AI — nothing did, so the colour never showed")
}
Test("WPM canon: the AI's text paints the AI colour (wpm-canon)",
	_WPMC_AiTextPaintsTheAiColour)
