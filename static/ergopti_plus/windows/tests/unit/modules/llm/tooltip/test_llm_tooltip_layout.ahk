; tests/unit/modules/llm/tooltip/test_llm_tooltip_layout.ahk

; ==============================================================================
; MODULE: LLM Tooltip Layout And Placement Tests
; DESCRIPTION:
; Pins the Windows LLM prediction tooltip to the macOS geometry: the panel is
; as wide as its widest suggestion, the footer wraps instead of widening it, the
; lines stack without separators, text is measured in layout units, and the
; panel is placed below-right of the caret's bottom edge and clamped on the
; monitor holding the caret. Pure functions only, so no window is created.
; ==============================================================================

#Requires AutoHotkey v2.0

class _TLL_SpanGui {
	__New() {
		this.Options := ""
		this.Text := ""
		this.Font := ""
	}
	SetFont(Options, Name) {
		this.Font := Options . "|" . Name
	}
	Add(Kind, Options, Text) {
		this.Options := Options
		this.Text := Text
	}
}

_TLL_RetainedSpanSizePreservesGeometry() {
	G := _TLL_SpanGui()
	Size := { W: 37, H: 13 }
	Width := _LLM_TooltipDrawText(G, 11, 7, 20, "112233", 10, "fresh span", "norm", Size)
	AssertEqual(37, Width)
	AssertEqual("BackgroundTrans x11 y14 w39 h13", G.Options,
		"retained sizing must preserve bottom alignment and glyph overhang")
	AssertEqual("fresh span", G.Text)
	AssertEqual(0, _LLM_TooltipDrawText(G, 0, 0, 0, "112233", 10, "", "norm", Size))
}

Test("LLM tooltip: retained per-render span size preserves geometry (llm-span-cache-2026-10-02)",
	_TLL_RetainedSpanSizePreservesGeometry)

class _TLL_SegmentGui extends _TLL_SpanGui {
	__New() {
		super.__New()
		this.Spans := []
	}
	Add(Kind, Options, Text) {
		super.Add(Kind, Options, Text)
		this.Spans.Push({ Font: this.Font, Options: Options })
	}
}

_TLL_RetainedSegmentSizesPreserveEmphasis() {
	Slot := { Text: "", Chunks: [{ type: "equal", text: "a" },
		{ type: "insert", text: "b" }], NextWords: " c", HasCorrections: true }
	Row := _LLM_TooltipMeasurePredictionRow(Slot, { W: 30, H: 18 },
		{ W: 5, H: 18 }, 10,
		(Text, Bold) => { W: StrLen(Text) * (Bold ? 20 : 10), H: Bold ? 22 : 18 })
	for Selected in [true, false] {
		G := _TLL_SegmentGui()
		Segments := _LLM_SlotSegments(Slot, Selected)
		Body := Selected ? Row.Selected : Row.Unselected
		Width := _LLM_TooltipDrawSegments(G, 0, 0, 40,
			Segments, Selected, Body.Pieces)
		AssertEqual(Body.W, Width,
			"cached painting must use the dimensions of this exact emphasis state")
		AssertEqual(3, G.Spans.Length)
		for Index, Span in G.Spans {
			AssertEqual(Segments[Index].Bold, InStr(Span.Font, "bold") > 0,
				"retained dimensions must not erase the requested font weight")
			Assert(InStr(Span.Options, " w" . (Body.Pieces[Index].W + 2)
				. " h" . Body.Pieces[Index].H), "every retained piece controls native geometry")
		}
	}
}
Test("LLM tooltip: retained segments preserve shared emphasis geometry (llm-span-cache-2026-10-02)",
	_TLL_RetainedSegmentSizesPreserveEmphasis)

class _TLL_Native {
	static Dpi := 120

	static GetScreenDC() {
		return 201
	}

	static ReleaseScreenDC(DeviceContext) {
		return true
	}

	static GetVerticalDpi(DeviceContext) {
		return this.Dpi
	}

	static CreateFont(HeightPx, FontName, Bold := false) {
		return 301
	}

	static DeleteObject(ObjectHandle) {
		return true
	}

	static SelectObject(DeviceContext, ObjectHandle) {
		return 401
	}

	static MeasureText(DeviceContext, Text, Size) {
		NumPut("Int", 150, Size, 0)
		NumPut("Int", 25, Size, 4)
		return 1
	}
}

_TLL_Style() {
	return { PadX: 14, PadY: 7, LineSpacing: 8, HintSpacing: 4,
		ShortcutW: 0, LabelGap: 16, MaxPredsW: 800 }
}

_TLL_Footer(HintW, InfoW, InfoSizingW) {
	Footer := { Hint: { W: HintW, H: 15 }, Info: { W: InfoW, H: 13 },
		InfoSizing: { W: InfoSizingW, H: 13 }, Sep: { W: 30, H: 15 } }
	Footer.Combined := { W: HintW + 30 + InfoW, H: 15 }
	Footer.CombinedSizing := { W: HintW + 30 + InfoSizingW, H: 15 }
	return Footer
}

_TLL_ConstantsSection(Name) {
	global _SharedDir
	Parsed := ParseTomlFile(_SharedDir . "\core\ui\data\tooltip\constants.toml")
	Assert(Parsed.Has(Name), "constants.toml must declare [" . Name . "]")
	return Parsed[Name]
}





; ======================================
; ======================================
; ======= 0/ The shortcut column =======
; ======================================
; ======================================

_TLL_ColumnCorpusReplays() {
	global _SharedDir
	Data := JsonParse(FileRead(_SharedDir . "\tests\corpus\tooltip\llm_column_vectors.json", "UTF-8"))
	for Vec in Data["vectors"] {
		Column := _LLM_TooltipShortcutColumn(Vec["widest_line"], Vec["widest_label"], Vec["gap"], Vec["max_width"])
		Place := _LLM_TooltipColumnPlacement(Vec["content_w"], Column.ZoneW, Vec["label_w"], Vec["line_w"])
		Expected := Vec["expected"]
		AssertEqual(Expected["zone_w"], Column.ZoneW, Vec["id"] . ": zone_w")
		AssertEqual(Expected["preds_w"], Column.PredsW, Vec["id"] . ": preds_w")
		AssertEqual(Expected["label_x"], Place.LabelX, Vec["id"] . ": label_x")
		AssertEqual(Expected["line_limit"], Place.LineLimit, Vec["id"] . ": line_limit")
		AssertEqual(!!Expected["truncated"], Place.Truncated, Vec["id"] . ": truncated")
	}
}
Test("llm tooltip column: the shared corpus replays (llm-shortcut-column)", _TLL_ColumnCorpusReplays)

_TLL_ColumnFollowsAWiderPanel() {
	Style := _TLL_Style()
	Style.ShortcutW := 14
	Layout := _LLM_TooltipLayout([{ W: 120, H: 20 }], _TLL_Footer(260, 150, 170), Style)
	AssertEqual(260, Layout.ContentW, "the wrapped footer widens the panel past the lines")
	AssertEqual(30, Layout.ZoneW)
	AssertEqual(246, _LLM_TooltipColumnPlacement(Layout.ContentW, Layout.ZoneW, 14, 120).LabelX,
		"the chord ends on the inner edge, not label_gap past the line")
}
Test("llm tooltip column: the chord follows the panel a footer widened (llm-shortcut-column)",
	_TLL_ColumnFollowsAWiderPanel)

_TLL_LongLineStopsBeforeTheColumn() {
	Style := _TLL_Style()
	Style.ShortcutW := 14
	Layout := _LLM_TooltipLayout([{ W: 1000, H: 20 }], _TLL_Footer(100, 100, 100), Style)
	AssertEqual(800, Layout.ContentW, "the block stops at the cap, chord included")
	Place := _LLM_TooltipColumnPlacement(Layout.ContentW, Layout.ZoneW, 14, 1000)
	AssertTrue(Place.Truncated)
	AssertEqual(770, Place.LineLimit)
}
Test("llm tooltip column: a long line stops before the column at the cap (llm-shortcut-column)",
	_TLL_LongLineStopsBeforeTheColumn)

_TLL_CutPieceEndsInAnEllipsis() {
	G := _TLL_SegmentGui()
	Slot := { Text: "", Chunks: [], NextWords: "abcdefghij", HasCorrections: false }
	Segments := _LLM_SlotSegments(Slot, true)
	Width := _LLM_TooltipDrawSegments(G, 0, 0, 20, Segments, true, [{ W: 100, H: 20 }], 60)
	AssertEqual(60, Width, "the line stops at its limit")
	Assert(InStr(G.Spans[1].Options, "0x4000"), "the cut piece carries SS_ENDELLIPSIS")
	Assert(InStr(G.Spans[1].Options, " w60 "), "and the limit's width")
	G := _TLL_SegmentGui()
	AssertEqual(100, _LLM_TooltipDrawSegments(G, 0, 0, 20, Segments, true, [{ W: 100, H: 20 }], 200))
	Assert(!InStr(G.Spans[1].Options, "0x4000"), "a line that fits is left whole")
}
Test("llm tooltip column: a line past its limit ends in an ellipsis (llm-shortcut-column)",
	_TLL_CutPieceEndsInAnEllipsis)





; =================================
; =================================
; ======= 1/ Panel geometry =======
; =================================
; =================================

; The reported defect: the Windows panel always grew to the combined footer, so
; three short suggestions sat in a tooltip twice their width.
_TLL_FooterThatFitsNeverWidensThePanel() {
	Rows := [{ W: 300, H: 20 }, { W: 250, H: 20 }, { W: 200, H: 20 }]
	Layout := _LLM_TooltipLayout(Rows, _TLL_Footer(120, 100, 110), _TLL_Style())
	AssertEqual(300 + 2 * 14, Layout.W,
		"a footer whose combined row fits must leave the panel at its widest suggestion")
	AssertEqual("combined", Layout.Mode, "a fitting footer stays on one row")
}
Test("llm tooltip layout: a fitting footer never widens the panel (llm-tooltip-hs-parity)",
	_TLL_FooterThatFitsNeverWidensThePanel)

_TLL_FooterThatDoesNotFitWraps() {
	Rows := [{ W: 200, H: 20 }]
	Layout := _LLM_TooltipLayout(Rows, _TLL_Footer(260, 150, 170), _TLL_Style())
	AssertEqual("stacked", Layout.Mode,
		"a combined footer wider than the suggestions must wrap into hint and info rows")
	AssertEqual(260 + 2 * 14, Layout.W,
		"once wrapped, only the wider of its two rows may widen the panel — never the combined row (460)")
	Assert(Layout.InfoY > Layout.HintY, "the info row goes under the hint row")
	AssertEqual(Layout.HintY + 15 + 4, Layout.InfoY, "hint_spacing separates the wrapped rows")
}
Test("llm tooltip layout: an overflowing footer wraps instead of widening (llm-tooltip-hs-parity)",
	_TLL_FooterThatDoesNotFitWraps)

; Sized with the worst-case timing, drawn with the live one: the combined
; decision at draw time uses the actual info width against the frozen width.
_TLL_WidthIsSizedForTheWorstCaseTiming() {
	Rows := [{ W: 150, H: 20 }]
	Layout := _LLM_TooltipLayout(Rows, _TLL_Footer(120, 90, 200), _TLL_Style())
	AssertEqual(200 + 2 * 14, Layout.W,
		"the frame must fit the worst-case info line (200), not the live one (90), so the final TTLT never clips")
	AssertEqual("stacked", Layout.Mode,
		"the live combined footer (240) exceeds the frame (200), so it wraps")
}
Test("llm tooltip layout: the frame is sized for the worst-case timing line (llm-tooltip-hs-parity)",
	_TLL_WidthIsSizedForTheWorstCaseTiming)

_TLL_LinesStackWithoutGaps() {
	Rows := [{ W: 100, H: 20 }, { W: 100, H: 21 }, { W: 100, H: 19 }]
	Layout := _LLM_TooltipLayout(Rows, _TLL_Footer(30, 20, 20), _TLL_Style())
	AssertEqual("combined", Layout.Mode)
	AssertEqual(7, Layout.RowY[1], "the first line starts at pad_y")
	AssertEqual(27, Layout.RowY[2], "lines stack with no padding or separator between them")
	AssertEqual(48, Layout.RowY[3], "lines stack with no padding or separator between them")
	AssertEqual(7 + 60 + 8, Layout.SepY, "line_spacing then the footer rule")
	AssertEqual(Layout.SepY + 8, Layout.CombinedY, "line_spacing after the rule")
	AssertEqual(Layout.CombinedY + 15 + 7, Layout.H, "pad_y closes the panel under the footer")
}
Test("llm tooltip layout: suggestion lines stack like the macOS text block (llm-tooltip-hs-parity)",
	_TLL_LinesStackWithoutGaps)

_TLL_NoFooterIsJustPaddedLines() {
	Empty := { Hint: 0, Info: 0, InfoSizing: 0, Sep: { W: 0, H: 0 },
		Combined: 0, CombinedSizing: 0 }
	Layout := _LLM_TooltipLayout([{ W: 90, H: 20 }], Empty, _TLL_Style())
	AssertEqual("none", Layout.Mode)
	AssertEqual(7 + 20 + 7, Layout.H, "the loading panel is pad_y + line + pad_y")
	AssertEqual(90 + 28, Layout.W)
}
Test("llm tooltip layout: a footer-less panel is padded lines only (llm-tooltip-hs-parity)",
	_TLL_NoFooterIsJustPaddedLines)

; Gui coordinates are layout units (the Gui is DPI-scaled); GDI measures device
; pixels. At 125 % the old measurer made every tooltip 1.25x too wide.
_TLL_MeasurementIsInLayoutUnits() {
	global _TooltipMeasureGdiCleanupDebt
	OriginalDebt := _TooltipMeasureGdiCleanupDebt
	_TooltipMeasureGdiCleanupDebt := []
	try {
		_TLL_Native.Dpi := 120
		Size := _TooltipMeasureTextSize("any", 11, _TLL_Native, Map())
		AssertEqual(120, Size.W, "150 device px at 120 DPI are 120 layout units")
		AssertEqual(20, Size.H, "25 device px at 120 DPI are 20 layout units")
		_TLL_Native.Dpi := 96
		AssertEqual(150, _TooltipMeasureTextSize("any", 11, _TLL_Native, Map()).W,
			"at 96 DPI device pixels and layout units coincide")
	} finally _TooltipMeasureGdiCleanupDebt := OriginalDebt
}
Test("llm tooltip layout: text is measured in DPI-independent layout units (llm-tooltip-dpi)",
	_TLL_MeasurementIsInLayoutUnits)





; ==================================
; ==================================
; ======= 2/ Caret placement =======
; ==================================
; ==================================

_TLL_Opts() {
	Positioning := _TLL_ConstantsSection("positioning")
	Layout := _TLL_ConstantsSection("layout")
	return { CaretOffsetX: Positioning["caret_offset_x"],
		CaretOffsetY: Positioning["caret_offset_y"],
		WindowOffsetY: Positioning["window_offset_y"],
		Margin: Layout["screen_margin"] }
}

_TLL_AnchorFromCorpus(Vec) {
	A := Vec["anchor"]
	if !(A is Map)
		return 0
	return { Type: A["type"], X: A["x"], Y: A["y"], H: A["h"] }
}

; The full cascade the corpus describes, not a re-clamp of its answer: every
; shared vector's anchor, canvas and frame must land on the golden position.
_TLL_CorpusPositionsReplay() {
	Path := A_ScriptDir . "\..\..\_shared\tests\corpus\tooltip\layout_vectors.json"
	Data := JsonParse(FileRead(Path, "UTF-8"))
	Opts := _TLL_Opts()
	Checked := 0
	for Vec in Data["vectors"] {
		F := Vec["screenFrame"]
		C := Vec["canvasSize"]
		Out := _TooltipPlaceAnchor(_TLL_AnchorFromCorpus(Vec), C["w"], C["h"],
			F["x"], F["y"], F["x"] + F["w"], F["y"] + F["h"], Opts)
		AssertEqual(Vec["expected"]["x"], Out.X, "vector '" . Vec["id"] . "' x")
		AssertEqual(Vec["expected"]["y"], Out.Y, "vector '" . Vec["id"] . "' y")
		Checked += 1
	}
	Assert(Checked >= 6, "the shared corpus must still carry its 6 vectors")
}
Test("llm tooltip placement: every shared corpus vector places exactly like macOS (llm-tooltip-hs-parity)",
	_TLL_CorpusPositionsReplay)

; The Windows anchor used to omit the caret height, so the panel started 18 px
; under the caret's TOP and covered the line being typed.
_TLL_CaretPlacementClearsTheCaretLine() {
	Opts := _TLL_Opts()
	Out := _TooltipPlaceAnchor({ Type: "caret", X: 400, Y: 300, H: 22 }, 200, 80,
		0, 0, 1920, 1040, Opts)
	AssertEqual(400 + Opts.CaretOffsetX, Out.X, "below-RIGHT of the caret")
	AssertEqual(300 + 22 + Opts.CaretOffsetY, Out.Y,
		"the offset is measured from the caret's bottom edge, not its top")
}
Test("llm tooltip placement: the panel starts below the caret's bottom edge (llm-tooltip-hs-parity)",
	_TLL_CaretPlacementClearsTheCaretLine)

; A caret on a secondary monitor left of the primary (negative origin): the
; clamp must use that monitor's frame, never the primary's.
_TLL_ClampsWithinTheCaretMonitor() {
	Opts := _TLL_Opts()
	Out := _TooltipPlaceAnchor({ Type: "caret", X: -60, Y: 1000, H: 20 }, 300, 90,
		-1920, 0, 0, 1040, Opts)
	AssertEqual(0 - 300 - Opts.Margin, Out.X,
		"near the right edge of the left monitor the panel is pulled back inside it")
	AssertEqual(1040 - 90 - Opts.Margin, Out.Y, "and above the monitor's bottom work edge")
}
Test("llm tooltip placement: clamping uses the caret's own monitor frame (llm-tooltip-hs-parity)",
	_TLL_ClampsWithinTheCaretMonitor)

; Every coordinate source must be read in SCREEN coordinates. AHK's per-thread
; CoordMode defaults to "Client", which placed the tooltip relative to the
; active window's client origin — far from the caret of any non-maximised app.
_TLL_ResolverReadsScreenCoordinates() {
	Body := _DriverFuncBody("_TooltipResolvePosition")
	Assert(Body != "", "_TooltipResolvePosition() must exist in the driver source")
	Caret := InStr(Body, "CaretGetPos(")
	Mouse := InStr(Body, "MouseGetPos(")
	CaretMode := InStr(Body, 'CoordMode("Caret", "Screen")')
	MouseMode := InStr(Body, 'CoordMode("Mouse", "Screen")')
	Assert(Caret > 0 and CaretMode > 0 and CaretMode < Caret,
		'CaretGetPos must be preceded by CoordMode("Caret", "Screen") in the same thread')
	Assert(Mouse > 0 and MouseMode > 0 and MouseMode < Mouse,
		'MouseGetPos must be preceded by CoordMode("Mouse", "Screen") in the same thread')
}
Test("llm tooltip placement: the anchor is read in screen coordinates (llm-tooltip-coordmode)",
	_TLL_ResolverReadsScreenCoordinates)


; Shown together (llm.trigger.while_hotstring_tooltip = "both"), the hotstring rows
; head the panel as the hotstring stack draws them: a band per row, each closed
; by its 1 px rule, the label column right of the widest text.
_TLL_SharedHeaderStacksTheHotstringRows() {
	Header := _LLM_TooltipHeaderLayout([{ W: 90, H: 18 }, { W: 140, H: 18 }],
		[{ W: 12, H: 14 }, { W: 0, H: 0 }], { PadX: 14, PadY: 7, LabelGap: 16 })
	AssertEqual(14 + 140 + 16 + 12 + 14, Header.W, "as wide as the widest row and its label column")
	AssertEqual(2 * (7 + 18 + 7 + 1), Header.H, "each row and its rule, the last one separating the predictions")
	AssertEqual(0, Header.RowY[1])
	AssertEqual(7 + 18 + 7 + 1, Header.RowY[2], "the second row starts under the first row's rule")
	AssertEqual(140, Header.TextW)
	AssertEqual(12, Header.LabelW)
	Empty := _LLM_TooltipHeaderLayout([], [], { PadX: 14, PadY: 7, LabelGap: 16 })
	AssertEqual(0, Empty.W, "no rows, no header")
	AssertEqual(0, Empty.H)
}
Test("llm tooltip layout: shared hotstring rows head the panel (llm-hotstring-tooltip-both)",
	_TLL_SharedHeaderStacksTheHotstringRows)

; The predictions continue the stack under the header, every row and footer
; moved by its height, the panel widened to the header when it is wider.
_TLL_SharedHeaderMovesThePredictionsDown() {
	Layout := _LLM_TooltipLayout([{ W: 120, H: 20 }, { W: 80, H: 20 }], _TLL_Footer(100, 60, 60), _TLL_Style())
	Before := { H: Layout.H, W: Layout.W, Row1: Layout.RowY[1], Row2: Layout.RowY[2], Sep: Layout.SepY,
		Combined: Layout.CombinedY, Hint: Layout.HintY, Info: Layout.InfoY }
	_LLM_TooltipShiftLayout(Layout, 33, Before.W + 50)
	AssertEqual(Before.Row1 + 33, Layout.RowY[1], "the first prediction comes under the header")
	AssertEqual(Before.Row2 + 33, Layout.RowY[2])
	AssertEqual(Before.Sep + 33, Layout.SepY, "the footer rule follows")
	AssertEqual(Before.Combined + 33, Layout.CombinedY)
	AssertEqual(Before.Hint + 33, Layout.HintY)
	AssertEqual(Before.Info + 33, Layout.InfoY)
	AssertEqual(Before.H + 33, Layout.H, "the panel grows by the header")
	AssertEqual(Before.W + 50, Layout.W, "a wider header widens the panel")
	_LLM_TooltipShiftLayout(Layout, 0, 10)
	AssertEqual(Before.W + 50, Layout.W, "a narrower header never narrows it")
}
Test("llm tooltip layout: predictions continue the stack under the hotstring rows (llm-hotstring-tooltip-both)",
	_TLL_SharedHeaderMovesThePredictionsDown)

; Waiting is the default: no surface lends its rows to a prediction then.
_TLL_WaitSharesNoHotstringRows() {
	global _TooltipActiveSurface, _LLM_Engine
	SavedSurface := _TooltipActiveSurface
	SavedEngine := _LLM_Engine
	try {
		_LLM_Engine := SavedEngine.Clone()
		_TooltipActiveSurface := { DecisionItems: [{ Text: "btw", FireDecision: {} }] }
		_LLM_Engine[ConfigLeaf.WHILE_HOTSTRING_TOOLTIP] := "wait"
		AssertEqual(0, _LLM_TooltipSharedHotstringItems().Length, "waiting shares no row")
		_LLM_Engine[ConfigLeaf.WHILE_HOTSTRING_TOOLTIP] := "both"
		_TooltipActiveSurface := { DecisionItems: [{ Text: "Generating…" }] }
		AssertEqual(0, _LLM_TooltipSharedHotstringItems().Length,
			"only hotstring rows are shared, never a notice or the spinner")
		_TooltipActiveSurface := 0
		AssertEqual(0, _LLM_TooltipSharedHotstringItems().Length, "nothing on screen, nothing shared")
	} finally {
		_LLM_Engine := SavedEngine
		_TooltipActiveSurface := SavedSurface
	}
}
Test("llm tooltip layout: waiting shares no hotstring row (llm-hotstring-tooltip-wait)",
	_TLL_WaitSharesNoHotstringRows)

; A shared hotstring row leaves the « both » stack on its own deadline: the panel
; arms its repaint at the first row deadline still ahead, and none without one.
_TLL_SharedHeaderExpiryIsArmed() {
	global _TooltipActiveSurface
	Now := 1000000
	Rows := [{ Text: "btw", FireDecision: {}, ExpireOriginTick: Now - 500, ExpireDurationMs: 2000 },
		{ Text: "afaik", FireDecision: {}, ExpireOriginTick: Now - 100, ExpireDurationMs: 800 },
		{ Text: "gone", FireDecision: {}, ExpireOriginTick: Now - 900, ExpireDurationMs: 300 }]
	AssertEqual(700, _LLM_TooltipSharedHeaderNextExpiryMs(Rows, Now), "the first deadline still ahead")
	AssertEqual(0, _LLM_TooltipSharedHeaderNextExpiryMs([{ Text: "free", FireDecision: {} }], Now),
		"a row without a deadline arms nothing")
	SavedSurface := _TooltipActiveSurface
	try {
		_TooltipActiveSurface := 0
		AssertFalse(_LLM_TooltipArmSharedHeaderExpiry(Rows), "no surface, no repaint")
		Gone := { DecisionItems: [] }
		AssertFalse(_LLM_TooltipExpireSharedHeader(Gone), "a replaced surface is never repainted")
	} finally _TooltipActiveSurface := SavedSurface
}
Test("llm tooltip layout: a shared hotstring row leaves on its own expiry (llm-hotstring-tooltip-both-expiry)",
	_TLL_SharedHeaderExpiryIsArmed)

