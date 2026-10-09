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

; The headless runner omits the UI-only display module (it stubs its class),
; so the colour rules are read from the production source, and the canon's
; values from the real loader.
_WPMC_NeutralSourcesComeFromTheCanon() {
	AssertTrue(WPMWidget_LoadSharedConst())
	AssertTrue(WPMWidgetConst.NEUTRAL.Has("rolls"))
	AssertTrue(WPMWidgetConst.NEUTRAL.Has("repeat_key"))
	AssertFalse(WPMWidgetConst.NEUTRAL.Has("magickey"),
		"a hotstring group with a colour of its own must colour the widget")
	AssertTrue(InStr(_DriverFuncBody("_WPMWidget_NeutralCategory"), "WPMWidgetConst.NEUTRAL.Has(category)") > 0,
		"the neutral categories must be the canon's, not a hand-kept list")
}
Test("WPM canon: neutral categories are the canon's (wpm-canon)",
	_WPMC_NeutralSourcesComeFromTheCanon)

_WPMC_AiTextPaintsTheAiColour() {
	Bg := _DriverFuncBody("WPMWidget_ResolveBgColor")
	AssertTrue(RegExMatch(Bg, "if has_ai\s+return WPMWidgetConst\.COLOR_BG_AI") > 0,
		"the AI's text must paint the pill in the canon's AI colour")
	AssertTrue(InStr(Bg, "WPMWidgetConst.COLOR_FALLBACK") > 0,
		"a group with no usable colour must take the canon's fallback accent")
	AssertTrue(InStr(_DriverFuncBody("WPMWidget_ResolveGraphColor"), "WPMWidget_ResolveBgColor(") > 0,
		"the curve takes the pill's colour, as on macOS and Linux")
	AssertTrue(InStr(_DriverFuncBody("_LLM_Bridge_CommitInjectedText"), "WPMWidget_Push(false, true)") > 0,
		"accepted AI text must reach the widget marked AI — nothing did, so the colour never showed")
}
Test("WPM canon: the AI's text paints the AI colour (wpm-canon)",
	_WPMC_AiTextPaintsTheAiColour)
