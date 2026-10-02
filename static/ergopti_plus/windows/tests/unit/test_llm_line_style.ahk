; static/ergopti_plus/windows/tests/unit/test_llm_line_style.ahk

; ==============================================================================
; MODULE: Regression — what a prediction line reads on Windows (llm-line-style)
; DESCRIPTION:
; On the selected line of the AI prediction tooltip, the text already typed is
; grey, the part the model corrected green and the continuation orange, as on
; macOS. Windows painted the whole line green.
;
; ROOT CAUSE ENCODED: the parser knows the three parts (chunks and next words),
; but LLM_Parser_ParseResponse returned the slots as plain strings and dropped
; them. The render then rebuilt a diff from the slot text alone
; (LLM_Diff_Compute, a token prefix match against the last 200 characters of the
; context), which never matched and called the whole text an insertion: one
; green piece, no typed text, no next words. The parser's own reading now
; travels beside the slots to the render, and the retired diff is gone.
;
; The line rule is the Windows port of _shared/lua/tooltip/llm_line.lua; section
; 1 replays the corpus the three drivers share against it.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ The shared corpus =======
; ====================================
; ====================================

; THROWS when the corpus is missing: a cross-driver contract that went missing
; must fail this suite, never skip it.
_LLS_LoadCorpus() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\tooltip\llm_line_vectors.json"
	if !FileExist(Path)
		throw Error("LLM line corpus not found at '" . Path . "'")
	return JsonParse(FileRead(Path, "UTF-8"))
}

_LLS_PrefixesMatchTheCorpus() {
	Corpus := _LLS_LoadCorpus()
	AssertTrue(Corpus["prefixes"].Length > 0, "the corpus must carry prefix vectors")
	for Vec in Corpus["prefixes"] {
		Got := _LLM_LinePrefixes(Vec["indent"], Vec["line_count"],
			Corpus["mark"], Corpus["align"])
		AssertEqual(Vec["expected"]["selected"], Got.Selected,
			"prefix '" . Vec["id"] . "': selected line")
		AssertEqual(Vec["expected"]["unselected"], Got.Unselected,
			"prefix '" . Vec["id"] . "': other lines")
	}
}
Test("(llm-line-style) the line prefixes follow the shared corpus",
	_LLS_PrefixesMatchTheCorpus)

; The slot the tooltip receives for a corpus prediction.
_LLS_SlotOf(Prediction) {
	Chunks := []
	for Chunk in Prediction["chunks"]
		Chunks.Push({ type: Chunk["type"], text: Chunk["text"] })
	return { Text: "", Chunks: Chunks, NextWords: Prediction["nw"],
		HasCorrections: Prediction["has_corrections"], DisableBold: Prediction.Get("disable_bold", false) }
}

; Replay the complete shared line policy, including unselected emphasis.
_LLS_SegmentsMatchTheCorpus() {
	Corpus := _LLS_LoadCorpus()
	AssertTrue(Corpus["segments"].Length > 0, "the corpus must carry segment vectors")
	for Vec in Corpus["segments"] {
		Got := _LLM_SlotSegments(_LLS_SlotOf(Vec["prediction"]), Vec["selected"])
		AssertEqual(Vec["expected"].Length, Got.Length,
			"segments '" . Vec["id"] . "': piece count")
		for Index, Expected in Vec["expected"] {
			if (Index > Got.Length)
				break
			Where := "segments '" . Vec["id"] . "' #" . Index
			AssertEqual(Expected["text"], Got[Index].Text, Where . ": text")
			AssertEqual(Expected["role"], Got[Index].Role, Where . ": role")
			AssertEqual(Expected["bold"] ? true : false, Got[Index].Bold, Where . ": bold")
		}
	}
}
Test("(llm-line-style) the line pieces follow the shared corpus",
	_LLS_SegmentsMatchTheCorpus)





; =======================================================
; =======================================================
; ======= 2/ The parser's pieces reach the render =======
; =======================================================
; =======================================================

; Parses one model answer for a context and renders it as the engine does:
; returns the slot the tooltip is handed.
_LLS_RenderedSlot(Raw, Ctx) {
	global _LLM_Engine, _Stub_LlmTooltipCalls
	LLM_Engine_Init(Map())
	_LLM_Engine["inline_autotype"] := false
	_LLM_Engine_ForgetSlotDisplays()
	_Stub_LlmTooltipCalls := []
	State := Map("ctx", Ctx, "ctx_tail", Ctx, "min_words", 1, "max_words", 5,
		"is_batch", false, "requested", 1,
		"dedup_stats", LLM_ApiCommon_NewDedupStats(), "rewrite_edits", Map())
	Slots := _LLM_Engine_ParseSlots(Raw, State)
	AssertEqual(1, Slots.Length, "the answer must parse into one slot")
	LLM_Engine_OnResults(Slots, Ctx, 1, true)
	AssertTrue(_Stub_LlmTooltipCalls.Length > 0, "the render must reach the tooltip")
	return _Stub_LlmTooltipCalls[_Stub_LlmTooltipCalls.Length].slots[1]
}

_LLS_Roles(Slot) {
	Out := ""
	for , Segment in _LLM_SlotSegments(Slot)
		Out .= (Out == "" ? "" : "|") . Segment.Role . ":" . Segment.Text
	return Out
}

; The whole point: a completed word shows what was typed, what is corrected and
; what continues, while accepting it still types only the missing part.
_LLS_CorrectionKeepsItsThreeParts() {
	Slot := _LLS_RenderedSlot("TAIL_CORRECTED: Je dis bonjour`nNEXT_WORDS: tout le monde",
		"Je dis bonjou")
	AssertEqual("r tout le monde", _LLM_SlotGetText(Slot),
		"accepting types only what is missing")
	AssertEqual("typed:bonjou|corrected:r|next: tout le monde", _LLS_Roles(Slot),
		"the line reads the typed word, the correction, then the next words")
}
Test("(llm-line-style) a correction reaches the tooltip as typed, corrected, next",
	_LLS_CorrectionKeepsItsThreeParts)

; A plain continuation is next words, never a correction: this is the line that
; was painted green.
_LLS_ContinuationIsNextWords() {
	Slot := _LLS_RenderedSlot("tout le monde", "Bonjour a ")
	AssertEqual("next:tout le monde", _LLS_Roles(Slot),
		"a continuation must read as next words alone")
}
Test("(llm-line-style) a plain continuation reaches the tooltip as next words",
	_LLS_ContinuationIsNextWords)

; A rewrite shows the part of the sentence it keeps as typed, and what replaces
; the rest as corrected.
_LLS_RewriteIsTypedThenCorrected() {
	Slot := _LLM_Engine_RewriteDisplaySlot("e ce mail.", Map(
		"span", "Je vous envoit ce mail", "deleted_text", "t ce mail", "deletes", 9))
	AssertEqual("typed:Je vous envoi|corrected:e ce mail.", _LLS_Roles(Slot),
		"a rewrite reads the kept text, then the replacement")
}
Test("(llm-line-style) a rewrite reads as typed text then a correction",
	_LLS_RewriteIsTypedThenCorrected)

; The retired diff must not come back between the parser and the tooltip.
_LLS_RenderUsesTheParsersReading() {
	Render := _DriverFuncBody("LLM_Engine_OnResults")
	Assert(Render != "", "LLM_Engine_OnResults must exist in the driver source")
	Assert(InStr(Render, "_LLM_Engine_DisplaySlot(") > 0,
		"the render must show each slot as the parser read it")
	Assert(InStr(_DriverSourceNoComments(), "LLM_Diff_Compute") == 0,
		"no second diff may be rebuilt from the slot text: it cannot tell a correction from a continuation")
}
Test("(llm-line-style) the render shows the parser's reading, not a second diff",
	_LLS_RenderUsesTheParsersReading)





; =======================================
; =======================================
; ======= 3/ Colours and lifetime =======
; =======================================
; =======================================

_LLS_ColourFollowsTheRole() {
	global UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX, UI_LLM_UNSEL_GRAY_HEX
	Saved := [UI_LLM_CORR_SEL_HEX, UI_LLM_NW_SEL_HEX, UI_LLM_UNSEL_GRAY_HEX]
	UI_LLM_CORR_SEL_HEX := "40E666"
	UI_LLM_NW_SEL_HEX := "FF9E1A"
	UI_LLM_UNSEL_GRAY_HEX := "808080"
	try {
		AssertEqual("808080", _LLM_SegmentColorHex("typed", true), "typed text is grey")
		AssertEqual("40E666", _LLM_SegmentColorHex("corrected", true), "a correction is green")
		AssertEqual("FF9E1A", _LLM_SegmentColorHex("next", true), "the next words are orange")
		for Role in ["typed", "corrected", "next"]
			AssertEqual("808080", _LLM_SegmentColorHex(Role, false),
				"every piece of an unselected line is grey (" . Role . ")")
	} finally {
		UI_LLM_CORR_SEL_HEX := Saved[1]
		UI_LLM_NW_SEL_HEX := Saved[2]
		UI_LLM_UNSEL_GRAY_HEX := Saved[3]
	}
}
Test("(llm-line-style) grey typed, green corrected, orange next on the selected line",
	_LLS_ColourFollowsTheRole)

; The reading belongs to the context it was parsed for: the same text offered
; for another context, or after the prediction cache was dropped, is plain.
_LLS_ReadingBelongsToItsContext() {
	Ctx := "Je dis bonjou"
	_LLS_RenderedSlot("TAIL_CORRECTED: Je dis bonjour`nNEXT_WORDS: tout le monde", Ctx)
	AssertTrue(IsObject(_LLM_Engine_DisplaySlot("r tout le monde", Ctx)),
		"a cache hit on the same context keeps the parser's reading")
	AssertTrue(_LLM_Engine_DisplaySlot("r tout le monde", "Autre contexte") is String,
		"another context must not borrow it")
	LLM_Engine_StopGeneration()
	AssertTrue(_LLM_Engine_DisplaySlot("r tout le monde", Ctx) is String,
		"dropping the prediction cache drops the readings with it")
}
Test("(llm-line-style) a line's reading lives and dies with its context",
	_LLS_ReadingBelongsToItsContext)

; A parser decision must survive the ordinary display-store handoff, rather
; than being reconstructed from whether a painted line contains insert chunks.
_LLS_ParserEmphasisSuppressionReachesTheSlot() {
	Store := _LLM_Engine_SlotDisplayStore()
	SavedContext := Store.Ctx, SavedDisplays := Store.ByText
	try {
		_LLM_Engine_ForgetSlotDisplays()
		for Suppressed in [false, true] {
			Prediction := Map("chunks", [Map("type", "equal", "text", "bonjou"),
				Map("type", "insert", "text", "r")], "nw", " le monde",
				"has_corrections", true, "disable_bold", Suppressed)
			Context := Suppressed ? "suppressed context" : "emphasized context"
			_LLM_Engine_RememberSlotDisplays(Context,
				Map("r le monde", _LLM_Parser_DisplayOf(Prediction)))
			Slot := _LLM_Engine_DisplaySlot("r le monde", Context)
			AssertEqual(Suppressed, Slot.DisableBold,
				"the parser's presentation receipt must reach the real slot")
			Segments := _LLM_SlotSegments(Slot, false)
			AssertEqual(false, Segments[1].Bold, "typed reference stays regular")
			AssertEqual(!Suppressed, Segments[2].Bold, "correction honors suppression")
			AssertEqual(!Suppressed, Segments[3].Bold, "next words honor suppression")
		}
	} finally {
		Store.Ctx := SavedContext
		Store.ByText := SavedDisplays
	}
}
Test("(llm-line-style) parser emphasis suppression survives the ordinary display handoff",
	_LLS_ParserEmphasisSuppressionReachesTheSlot)

class _LLS_WeightedMeasure {
	static Calls := []
	static Measure(Text, Bold) {
		this.Calls.Push({ Text: Text, Bold: Bold })
		return { W: StrLen(Text) * (Bold ? 20 : 10), H: Bold ? 22 : 18 }
	}
}

_LLS_WidestBodyIncludesTheUnselectedWeight() {
	Slot := { Text: "", Chunks: [{ type: "equal", text: "a" },
		{ type: "insert", text: "b" }], NextWords: " c", HasCorrections: true }
	_LLS_WeightedMeasure.Calls := []
	Size := _LLM_TooltipMeasureSlotBody(Slot,
		(Text, Bold) => _LLS_WeightedMeasure.Measure(Text, Bold))
	AssertEqual(70, Size.W, "regular reference plus bold correction and next words reserve 70 units")
	AssertEqual(22, Size.H, "the row also reserves the bold font's actual height")
	Calls := _LLS_WeightedMeasure.Calls
	AssertEqual(6, Calls.Length, "both complete renderings must be measured")
	for Index in [1, 2, 3, 4]
		AssertEqual(false, Calls[Index].Bold, "selected pieces and unselected reference stay regular")
	AssertEqual(true, Calls[5].Bold, "unselected correction must request bold metrics")
	AssertEqual(true, Calls[6].Bold, "unselected continuation must request bold metrics")
	Row := _LLM_TooltipMeasurePredictionRow(Slot, { W: 30, H: 18 }, { W: 5, H: 18 },
		10, 7, (Text, Bold) => _LLS_WeightedMeasure.Measure(Text, Bold))
	AssertEqual(87, Row.W,
		"the actual selected width 30+40+10 wins over inactive 5+70, then adds the common shortcut")
	AssertEqual(22, Row.H, "bold height remains reserved when the selected width wins")
}
Test("(llm-line-style) panel geometry reserves the widest selected or emphasized body",
	_LLS_WidestBodyIncludesTheUnselectedWeight)

; Measure the HFONT actually attached to a native Text control, independently
; of the cached measurement font the production drawing helper selected.
_LLS_PaintedControlGeometry(Control, Text) {
	static WM_GETFONT := 0x31
	Font := DllCall("User32\SendMessageW", "Ptr", Control.Hwnd,
		"UInt", WM_GETFONT, "Ptr", 0, "Ptr", 0, "Ptr")
	Assert(Font != 0, "the actual Text control must acknowledge its font")
	LogFont := Buffer(92, 0)
	AssertEqual(92, DllCall("Gdi32\GetObjectW", "Ptr", Font,
		"Int", LogFont.Size, "Ptr", LogFont, "Int"))
	Receipt := _TooltipMeasureNewGdiReceipt()
	try {
		Receipt["screen_dc"] := _TooltipMeasureGdiNative.GetScreenDC()
		Assert(Receipt["screen_dc"] != 0)
		Receipt["old_font"] := _TooltipMeasureGdiNative.SelectObject(Receipt["screen_dc"], Font)
		AssertTrue(_TooltipGdiSelectSucceeded(Receipt["old_font"]))
		Receipt["font_selected"] := true
		Dpi := _TooltipMeasureGdiNative.GetVerticalDpi(Receipt["screen_dc"])
		Assert(Dpi > 0)
		Size := Buffer(8, 0)
		AssertTrue(_TooltipMeasureGdiNative.MeasureText(Receipt["screen_dc"], Text, Size))
		return { Weight: NumGet(LogFont, 16, "Int"),
			W: Ceil(NumGet(Size, 0, "Int") * 96 / Dpi),
			H: Ceil(NumGet(Size, 4, "Int") * 96 / Dpi) }
	} finally {
		AssertTrue(_TooltipMeasureSettleGdiReceipt(Receipt),
			"the paint-font observation must restore the font and release its DC")
	}
}

_LLS_DrawMeasuresTheActualPaintedWeight() {
	global _SharedDir, _TOOLTIP_FONT_NAME, _TOOLTIP_FONT_SIZE, UI_LLM_UNSEL_GRAY_HEX
	SavedFamily := _TOOLTIP_FONT_NAME, SavedSize := _TOOLTIP_FONT_SIZE
	SavedGray := UI_LLM_UNSEL_GRAY_HEX
	G := Gui("-Caption +ToolWindow")
	Slot := { Text: "", Chunks: [{ type: "equal", text: "Regular typed reference " },
		{ type: "insert", text: "Bold correction WWWMMMM" }],
		NextWords: " and continuation", HasCorrections: true }
	Segments := _LLM_SlotSegments(Slot, false)
	Texts := []
	for Segment in Segments
		Texts.Push(Segment.Text)
	Texts.Push("Regular after bold")
	try {
		; The headless runner does not load UI styles at boot. Paint with the
		; actual shared typography instead of the empty-family/zero-size sentinels,
		; which select a legacy stock font that cannot represent the bold spans.
		Constants := ParseTomlFile(_SharedDir . "\modules\tooltip\constants.toml")
		Family := IniCacheGet(Constants, "typography", "font_main_ahk")
		PointSize := IniCacheGet(Constants, "typography", "font_size_main_ahk")
		Assert(Family != "_" && Family != "", "the native fixture requires the shared font family")
		Assert(PointSize != "_" && IsNumber(PointSize) && PointSize > 0,
			"the native fixture requires the shared positive point size")
		_TOOLTIP_FONT_NAME := Family
		_TOOLTIP_FONT_SIZE := Integer(PointSize)
		UI_LLM_UNSEL_GRAY_HEX := LTrim(Constants["llm_colors"]["unsel_gray_hex"], "#")
		BodyWidth := _LLM_TooltipDrawSegments(G, 0, 0, 40, Segments, false)
		FinalWidth := _LLM_TooltipDrawText(G, BodyWidth, 0, 40, "808080",
			_TOOLTIP_FONT_SIZE, Texts[4], "norm")
		Index := 0
		PaintedBodyWidth := 0
		for Control in G {
			Index += 1
			Geometry := _LLS_PaintedControlGeometry(Control, Texts[Index])
			AssertEqual((Index == 2 || Index == 3) ? 700 : 400, Geometry.Weight,
				"bold painting is explicit and cannot leak into the following regular span")
			if Index <= 3
				PaintedBodyWidth += Geometry.W
			else
				AssertEqual(Geometry.W, FinalWidth, "the next normal piece must use its own font metrics")
			Assert(Geometry.W > 0 && Geometry.H > 0)
		}
		AssertEqual(4, Index, "all actual piece controls and the following normal label must be inspected")
		AssertEqual(PaintedBodyWidth, BodyWidth,
			"the production segment painter must advance by the actual painted fonts")
	} finally {
		try G.Destroy()
		finally {
			_TOOLTIP_FONT_NAME := SavedFamily
			_TOOLTIP_FONT_SIZE := SavedSize
			UI_LLM_UNSEL_GRAY_HEX := SavedGray
		}
	}
}
Test("(llm-line-style) actual Text controls paint and advance with the measured regular/bold font",
	_LLS_DrawMeasuresTheActualPaintedWeight)
