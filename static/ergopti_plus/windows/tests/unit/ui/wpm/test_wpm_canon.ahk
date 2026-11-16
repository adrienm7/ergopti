; tests/unit/ui/wpm/test_wpm_canon.ahk

; ==============================================================================
; MODULE: WPM Widget Canon Tests
; DESCRIPTION:
; The widget's look comes from _shared/metrics/data/wpm_widget/constants.toml, the
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

; TWD-2, decided by the maintainer on 2026-11-16: the widget shows only while
; text is typed. The ending keys, modifiers and neutral keys come from the canon
; and the physical-key registry, the index macOS and Linux build too.
_WPMC_TypingBurstIndexFromTheCanon() {
	AssertTrue(WPMWidget_LoadSharedConst())
	Index := WPMWidgetConst.BURST
	AssertTrue(Index is Map && Index.Count > 0, "the burst index loads with the canon")
	AssertEqual("ends", WPMWidget_BurstRole(Index, 0x14B), "an arrow ends the burst")
	AssertEqual("ends", WPMWidget_BurstRole(Index, 0x001), "Escape ends the burst")
	AssertEqual("level", WPMWidget_BurstRole(Index, 0x02A), "Shift is a level modifier")
	AssertEqual("modifier", WPMWidget_BurstRole(Index, 0x01D), "Ctrl is a modifier")
	AssertEqual("neutral", WPMWidget_BurstRole(Index, 0x00E), "Backspace keeps a burst without starting one")
	AssertEqual("", WPMWidget_BurstRole(Index, 0x01E), "a letter is text")
	AssertEqual("", WPMWidget_BurstRole(0, 0x14B), "no index before the canon loads")
}
Test("WPM canon: the typing burst keys come from the canon (twd2-typing-burst)",
	_WPMC_TypingBurstIndexFromTheCanon)

; Text shows the widget; a shortcut, an arrow or a modifier tapped alone hides it;
; a held Shift that types a capital does not.
_WPMC_TypingBurstSequence() {
	AssertTrue(WPMWidget_LoadSharedConst())
	Index := WPMWidgetConst.BURST
	State := { _lone_modifier: 0, _last_break_ms: 0, _last_input_ms: 0 }
	Press(Sc, Shortcut, Now) => WPMWidget_BurstObserveKey(State, WPMWidget_BurstRole(Index, Sc), Sc, Shortcut, Now)
	LastInput := 100
	AssertFalse(WPMWidget_BurstEnded(LastInput, State._last_break_ms), "typed text shows the widget")
	Press(0x14B, false, 200)
	AssertTrue(WPMWidget_BurstEnded(LastInput, State._last_break_ms), "an arrow hides it")
	LastInput := 300
	AssertFalse(WPMWidget_BurstEnded(LastInput, State._last_break_ms), "new text shows it again")
	Press(0x01D, false, 400)
	AssertFalse(WPMWidget_BurstEnded(LastInput, State._last_break_ms), "Ctrl pressed alone hides nothing yet")
	Press(0x02E, true, 410)
	AssertTrue(WPMWidget_BurstEnded(LastInput, State._last_break_ms), "Ctrl+C hides it")
	WPMWidget_BurstObserveKeyUp(State, 0x01D, 420)
	LastInput := 500
	Press(0x02A, false, 510)
	Press(0x01E, false, 515)
	LastInput := 515
	WPMWidget_BurstObserveKeyUp(State, 0x02A, 520)
	AssertFalse(WPMWidget_BurstEnded(LastInput, State._last_break_ms), "a Shift held for a capital keeps the burst")
	Press(0x01D, false, 600)
	WPMWidget_BurstObserveKeyUp(State, 0x01D, 610)
	AssertTrue(WPMWidget_BurstEnded(LastInput, State._last_break_ms), "a Ctrl tapped alone hides it")
	State._last_input_ms := 700
	Press(0x00E, false, 710)
	AssertEqual(710, State._last_input_ms, "a Backspace keeps a live burst going")
	AssertFalse(WPMWidget_BurstEnded(State._last_input_ms, State._last_break_ms), "a Backspace keeps the burst")
	Press(0x14B, false, 720)
	Press(0x00E, false, 730)
	AssertEqual(710, State._last_input_ms, "a Backspace never starts a burst")
	AssertTrue(WPMWidget_BurstEnded(State._last_input_ms, State._last_break_ms))
}
Test("WPM canon: text shows the widget, a shortcut, arrow or lone Ctrl hides it (twd2-typing-burst)",
	_WPMC_TypingBurstSequence)

; Shift, AltGr and Shift+AltGr type text (capitals, AltGr levels): held or tapped,
; alone or together, they never end the burst. AltGr arrives as LCtrl+RAlt: that
; LCtrl is no lone Ctrl tap. A real Ctrl+C still ends it (twd2-level-modifiers).
_WPMC_LevelModifiersKeepTheBurst() {
	AssertTrue(WPMWidget_LoadSharedConst())
	Index := WPMWidgetConst.BURST
	AssertEqual("level", WPMWidget_BurstRole(Index, 0x02A), "Shift is a level modifier")
	AssertEqual("level", WPMWidget_BurstRole(Index, 0x138), "AltGr is a level modifier")
	AssertEqual("modifier", WPMWidget_BurstRole(Index, 0x01D), "Ctrl is a shortcut modifier")
	State := { _lone_modifier: 0, _last_break_ms: 0, _last_input_ms: 100 }
	Press(Sc, Shortcut, Now) => WPMWidget_BurstObserveKey(State, WPMWidget_BurstRole(Index, Sc), Sc, Shortcut, Now)
	Release(Sc, Now) => WPMWidget_BurstObserveKeyUp(State, Sc, Now)
	Ended() => WPMWidget_BurstEnded(State._last_input_ms, State._last_break_ms)
	Press(0x02A, false, 110), Release(0x02A, 120)
	AssertFalse(Ended(), "Shift tapped alone keeps the burst")
	Press(0x01D, false, 130), Press(0x138, false, 131), Release(0x01D, 140), Release(0x138, 141)
	AssertFalse(Ended(), "AltGr tapped alone, LCtrl+RAlt, keeps the burst")
	Press(0x02A, false, 150), Press(0x01D, false, 151), Press(0x138, false, 152)
	Press(0x012, false, 160)
	State._last_input_ms := 160
	Release(0x01D, 170), Release(0x138, 171), Release(0x02A, 172)
	AssertFalse(Ended(), "Shift+AltGr held, then a key, keeps the burst")
	Press(0x01D, false, 180), Press(0x138, false, 181), Press(0x012, false, 190)
	State._last_input_ms := 190
	Release(0x01D, 195), Release(0x138, 196)
	AssertFalse(Ended(), "AltGr+e typing a euro sign keeps and updates the burst")
	Press(0x01D, false, 200), Press(0x02E, true, 210)
	AssertTrue(Ended(), "a real Ctrl+C ends it")
}
Test("WPM canon: Shift, AltGr and Shift+AltGr never end the burst (twd2-level-modifiers)",
	_WPMC_LevelModifiersKeepTheBurst)

; Any physical pointer input newer than the last key hides the widget, a single
; pixel included; the next key shows it again (twd2-pointer-hides).
_WPMC_PointerEndsTheBurst() {
	AssertTrue(WPMWidget_PointerEndsBurst(0, 5), "a pointer moved after the last key hides the widget")
	AssertFalse(WPMWidget_PointerEndsBurst(5, 0), "the next key shows it again")
	AssertFalse(WPMWidget_PointerEndsBurst(5, 5), "no pointer input since the key keeps it")
	Tick := _DriverFuncBody("WPMWidget_Tick")
	Watch := _DriverFuncBody("WPMWidget_MouseWatch")
	AssertTrue(Tick != "" && Watch != "", "the widget's tick and mouse watch exist")
	AssertTrue(InStr(Tick, "WPMWidget_PointerEndsBurst(A_TimeIdleMouse, A_TimeIdleKeyboard)") > 0,
		"the tick hides on physical pointer input")
	AssertTrue(InStr(Watch, "WPMWidget_PointerEndsBurst(A_TimeIdleMouse, A_TimeIdleKeyboard)") > 0,
		"the mouse watch ignores the driver's own cursor moves")
}
Test("WPM canon: any physical pointer input hides the widget, the next key shows it (twd2-pointer-hides)",
	_WPMC_PointerEndsTheBurst)

#Include test_wpm_tick_rollover_owner.ahk

#Include test_wpm_empty_source_hold_owner.ahk

#Include test_wpm_calc_sample_future_owner.ahk
