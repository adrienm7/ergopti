; ui/wpm/wpm_widget.ahk

; ==============================================================================
; MODULE: WPM Widget - GDI+ Rendering Layer
; DESCRIPTION:
; The on-screen WPM widget's drawing layer: compact + graph Gui construction,
; the GDI+ (gdiplus) lifecycle, the layered-window graph renderer, rounded-rect
; path building, hex->ARGB conversion, and the drag handlers. Mirrors the macOS
; wpm_widget.lua rendering split so both drivers isolate the same layer.
;
; Extracted from ui/wpm/init.ahk (audit F3) and #Include'd in place by it. Pure
; definitions only - AHK resolves these symbols across the whole compilation
; unit, so the include position does not affect behaviour.
; ==============================================================================

#Requires AutoHotkey v2.0+





; =====================================================
; =====================================================
; ======= 1/ GUI Construction & GDI+ Rendering ========
; =====================================================
; =====================================================

; Returns a hex color string darkened by 25% (each RGB channel × 0.75).
; Input and output are 6-character hex strings without leading '#'.
_WPMWidget_DarkenHex(hex) {
		f := WPMWidgetConst.UNIT_DARKEN
		r := Round(Integer("0x" . SubStr(hex, 1, 2)) * f)
		g := Round(Integer("0x" . SubStr(hex, 3, 2)) * f)
		b := Round(Integer("0x" . SubStr(hex, 5, 2)) * f)
		return Format("{:02x}{:02x}{:02x}", r, g, b)
}


WPMWidget_BuildCompact() {
		w       := WPMWidgetConst.W
		h       := WPMWidgetConst.H
		h_num   := WPMWidgetConst.H_NUMBER
		h_gap   := WPMWidgetConst.H_GAP
		h_unit  := WPMWidgetConst.H_UNIT
		strip_y := h_num + h_gap
		dark_bg := _WPMWidget_DarkenHex(WPMWidgetConst.COLOR_BG_IDLE)

		g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale", "ErgoptiPlus WPM")
		g.BackColor := WPMWidgetConst.COLOR_BG_IDLE
		g.MarginX   := 0
		g.MarginY   := 0

		; Large WPM number — vertically centred in the upper zone.
		g.SetFont("s" . WPMWidgetConst.NUMBER_FONT_SIZE . " w700 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
		lbl_wpm := g.AddText("x0 y0 w" . w . " h" . h_num . " Center BackgroundTrans +0x200", "—")

		; Darker strip behind the unit label (drawn before the label so it appears below it).
		g.SetFont("s1", "Segoe UI")
		lbl_strip := g.AddText("x0 y" . strip_y . " w" . w . " h" . h_unit . " Background" . dark_bg, "")

		; Unit label text drawn on top of the strip.
		g.SetFont("s" . WPMWidgetConst.UNIT_FONT_SIZE . " w600 c" . WPMWidgetConst.COLOR_TXT_IDLE, "Segoe UI")
		lbl_unit := g.AddText("x0 y" . strip_y . " w" . w . " h" . h_unit . " Center BackgroundTrans",
				t("menu.metrics.wpm_unit"))

		lbl_wpm.OnEvent("Click",   WPMWidget_DragStart)
		lbl_unit.OnEvent("Click",  WPMWidget_DragStart)
		lbl_strip.OnEvent("Click", WPMWidget_DragStart)
		g.OnEvent("Close", WPMWidget_Close)
		; WM_EXITSIZEMOVE fires after the OS native move loop completes (PostMessage WM_NCLBUTTONDOWN).
		OnMessage(0x0232, WPMWidget_DragEnd, 1)

		WPMWidget._gui       := g
		WPMWidget._lbl_wpm   := lbl_wpm
		WPMWidget._lbl_unit  := lbl_unit
		WPMWidget._lbl_strip := lbl_strip
}


WPMWidget_BuildGraph() {
		g := Gui("+AlwaysOnTop -Caption +ToolWindow +E0x80000 -DPIScale", "ErgoptiPlus WPM Graph")
		g.BackColor := WPMWidgetConst.COLOR_BG_IDLE
		g.MarginX   := 0
		g.MarginY   := 0

		; The graph surface is painted entirely by GDI+ and used to carry NO control,
		; so a click on it went straight to DefWindowProc: the widget could not be
		; dragged in graph mode at all, even though the module docstring advertises it
		; as draggable, WPMWidget_ResetPosition moves this very window, and the
		; show_graph branches of DragStart/DragEnd — including the anchor conversion —
		; sat here as unreachable code. A full-size transparent Text gives the graph
		; the same entry point the three compact labels give the compact mode.
		; UpdateLayeredWindow paints the window from its own bitmap and never renders
		; child controls, so this one is invisible and serves purely as a hit target.
		drag_area := g.AddText("x0 y0 w" . WPMWidgetConst.GRAPH_W
				. " h" . WPMWidgetConst.GRAPH_H . " BackgroundTrans", "")
		drag_area.OnEvent("Click", WPMWidget_DragStart)

		g.OnEvent("Close", WPMWidget_Close)
		OnMessage(0x0232, WPMWidget_DragEnd, 1)

		WPMWidget._graph_gui := g
}

; Gui.Close hides a window by default after its callback returns. Always return
; non-zero so a refused config transaction cannot be bypassed by that native
; fallback; the surface is hidden explicitly only after visibility is durable.
WPMWidget_Close(GuiObj, WriterFn := 0, NotifyFn := 0, HideFn := 0, *) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
				Critical("Off")
				try return WPMWidget_Close(GuiObj, WriterFn, NotifyFn, HideFn)
				finally Critical(InheritedCritical)
		}
		if !WPMWidget_SaveVisible(false, WriterFn, NotifyFn)
				return true
		try {
				if HasMethod(HideFn, "Call")
						HideFn.Call()
				else
						WPMWidget_Hide()
		} catch as Err {
				try LoggerError("WPMWidget",
						"Could not hide the widget after its close preference was persisted: {1}.",
						Err.Message)
				try GuiObj.Hide()
				catch as FallbackErr
						try LoggerError("WPMWidget",
								"Could not apply the native close fallback after persistence: {1}.",
								FallbackErr.Message)
		}
		return true
}


; Starts GDI+ once and creates the reusable font + centered string format. Held
; for the process lifetime — the graph re-renders every tick, so the per-call
; startup/shutdown the spotlight overlay uses would be pure waste here. Returns
; true when GDI+ is ready to draw.
WPMWidget_EnsureGdip() {
		if WPMWidget._gdip_started
				return true
		DllCall("LoadLibrary", "str", "gdiplus")
		si := Buffer(24, 0)
		NumPut("uint", 1, si)
		if DllCall("gdiplus\GdiplusStartup", "ptr*", &token := 0, "ptr", si, "ptr", 0) {
				LoggerError("WPMWidget", "GdiplusStartup failed — graph mode unavailable.")
				return false
		}
		WPMWidget._gdip_token := token

		; Font is in logical pixels (UnitPixel = 2); the per-render world transform
		; scales it to the right physical size on any DPI. GRAPH_LABEL_PX mirrors the
		; old WebView2 canvas (TS = 15). Fall back to Arial if Segoe UI is absent.
		DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Segoe UI", "ptr", 0, "ptr*", &family := 0)
		if !family
				DllCall("gdiplus\GdipCreateFontFamilyFromName", "wstr", "Arial", "ptr", 0, "ptr*", &family := 0)
		WPMWidget._gdip_family := family
		DllCall("gdiplus\GdipCreateFont", "ptr", family,
				"float", WPMWidgetConst.GRAPH_LABEL_PX, "int", 0, "int", 2, "ptr*", &font := 0)
		WPMWidget._gdip_font := font

		; Centered string format (horizontal + vertical), so the label sits in the
		; middle of the top zone exactly like the old canvas textAlign/textBaseline.
		DllCall("gdiplus\GdipCreateStringFormat", "int", 0, "ushort", 0, "ptr*", &fmt := 0)
		DllCall("gdiplus\GdipSetStringFormatAlign",     "ptr", fmt, "int", 1)   ; StringAlignmentCenter
		DllCall("gdiplus\GdipSetStringFormatLineAlign", "ptr", fmt, "int", 1)
		WPMWidget._gdip_fmt := fmt

		WPMWidget._gdip_started := true
		return true
}


; Renders the WPM graph into the layered graph window with GDI+ — the native
; replacement for the WebView2 canvas (no ~3-5 s browser cold-start, no per-key
; contention). Delegates the DIB + UpdateLayeredWindow lifecycle to the
; GraphicsRenderer adapter (the same path infra/spotlight.ahk uses); GR_DrawBitmap
; positions the bitmap at the window's current rect, so a drag never causes a jump.
WPMWidget_RenderGraph(Label, AccentHex) {
		g := WPMWidget._graph_gui
		if (!g or !WPMWidget_EnsureGdip())
				return
		; Snapshot the history so a concurrent WPMWidget_Push can't mutate it mid-draw.
		Hist := WPMWidget._graph_hist.Clone()
		; The Gui is -DPIScale (physical pixels); render in logical coords scaled by
		; the DPI factor so the layout matches the old DPI-scaled WebView2 canvas.
		dpi := DllCall("GetDpiForWindow", "ptr", g.Hwnd, "uint")
		if (dpi < 72)
				dpi := 96
		Scale := dpi / 96.0

		DrawFn(MemDC, W, H) {
				DllCall("gdiplus\GdipCreateFromHDC", "ptr", MemDC, "ptr*", &pGfx := 0)
				if !pGfx
						return
				DllCall("gdiplus\GdipSetSmoothingMode",     "ptr", pGfx, "int", 4)   ; AntiAlias
				DllCall("gdiplus\GdipSetTextRenderingHint", "ptr", pGfx, "int", 4)   ; AntiAliasGridFit (sets alpha)
				if (Scale != 1.0)
						DllCall("gdiplus\GdipScaleWorldTransform", "ptr", pGfx, "float", Scale, "float", Scale, "int", 0)
				WPMWidget_DrawGraph(pGfx, W / Scale, H / Scale, Label, AccentHex, Hist)
				DllCall("gdiplus\GdipDeleteGraphics", "ptr", pGfx)
		}
		GR_DrawBitmap(g.Hwnd, DrawFn)
}


; Paints the graph into a GDI+ context in LOGICAL coordinates (W x H): a rounded
; dark pill, a filled + stroked WPM sparkline clipped to the pill, and a centered
; WPM label. Mirrors the old canvas geometry 1:1 (PAD/LH/GH/GW/R/scale).
WPMWidget_DrawGraph(pGfx, W, H, Label, AccentHex, Hist) {
		static PAD := 5, CORNER_R := 8
		static PILL_FILL   := 0xCC000000   ; rgba(0,0,0,0.8)
		static PILL_STROKE := 0x66FFFFFF   ; rgba(255,255,255,0.4)
		static LABEL_COLOR := 0xFFFFFFFF
		static FILL_ALPHA  := 0x33         ; 0.2 x 255 — sparkline fill area
		LH := WPMWidgetConst.GRAPH_LABEL_PX * 2
		GH := H - LH - PAD * 2
		GW := W - PAD * 2

		; Rounded-rect pill path — reused for fill, stroke and the sparkline clip.
		pPath := WPMWidget_MakeRoundRectPath(0, 0, W, H, CORNER_R)
		DllCall("gdiplus\GdipCreateSolidFill", "uint", PILL_FILL, "ptr*", &bgBrush := 0)
		DllCall("gdiplus\GdipFillPath", "ptr", pGfx, "ptr", bgBrush, "ptr", pPath)
		DllCall("gdiplus\GdipDeleteBrush", "ptr", bgBrush)
		DllCall("gdiplus\GdipCreatePen1", "uint", PILL_STROKE, "float", 1, "int", 2, "ptr*", &bgPen := 0)
		DllCall("gdiplus\GdipDrawPath", "ptr", pGfx, "ptr", bgPen, "ptr", pPath)
		DllCall("gdiplus\GdipDeletePen", "ptr", bgPen)

		N := Hist.Length
		if (N >= 2) {
				DllCall("gdiplus\GdipSetClipPath", "ptr", pGfx, "ptr", pPath, "int", 0)   ; CombineModeReplace
				ScaleMax := WPMWidgetConst.GRAPH_SCALE_MAX
				Step  := GW / (N - 1)
				BaseY := LH + PAD + GH
				Rgb   := WPMWidget_HexToRgbInt(AccentHex)

				; Filled area under the line: N points + two baseline corners to close it.
				ptsFill := Buffer((N + 2) * 8)
				Loop N {
						i := A_Index - 1
						NumPut("float", PAD + i * Step, ptsFill, i * 8)
						NumPut("float", BaseY - (Hist[A_Index] / ScaleMax) * GH, ptsFill, i * 8 + 4)
				}
				NumPut("float", PAD + (N - 1) * Step, ptsFill, N * 8),       NumPut("float", BaseY, ptsFill, N * 8 + 4)
				NumPut("float", PAD,                  ptsFill, (N + 1) * 8), NumPut("float", BaseY, ptsFill, (N + 1) * 8 + 4)
				DllCall("gdiplus\GdipCreateSolidFill", "uint", (FILL_ALPHA << 24) | Rgb, "ptr*", &fillBrush := 0)
				DllCall("gdiplus\GdipFillPolygon", "ptr", pGfx, "ptr", fillBrush, "ptr", ptsFill, "int", N + 2, "int", 0)
				DllCall("gdiplus\GdipDeleteBrush", "ptr", fillBrush)

				; Stroked line over the fill.
				ptsLine := Buffer(N * 8)
				Loop N {
						i := A_Index - 1
						NumPut("float", PAD + i * Step, ptsLine, i * 8)
						NumPut("float", BaseY - (Hist[A_Index] / ScaleMax) * GH, ptsLine, i * 8 + 4)
				}
				DllCall("gdiplus\GdipCreatePen1", "uint", 0xFF000000 | Rgb, "float", 2, "int", 2, "ptr*", &linePen := 0)
				DllCall("gdiplus\GdipDrawLines", "ptr", pGfx, "ptr", linePen, "ptr", ptsLine, "int", N)
				DllCall("gdiplus\GdipDeletePen", "ptr", linePen)
				DllCall("gdiplus\GdipResetClip", "ptr", pGfx)
		}

		; WPM label, centered in the top zone.
		DllCall("gdiplus\GdipCreateSolidFill", "uint", LABEL_COLOR, "ptr*", &txtBrush := 0)
		rect := Buffer(16)
		NumPut("float", 0, rect, 0), NumPut("float", 0, rect, 4)
		NumPut("float", W, rect, 8), NumPut("float", LH, rect, 12)
		DllCall("gdiplus\GdipDrawString", "ptr", pGfx, "wstr", Label, "int", -1,
				"ptr", WPMWidget._gdip_font, "ptr", rect, "ptr", WPMWidget._gdip_fmt, "ptr", txtBrush)
		DllCall("gdiplus\GdipDeleteBrush", "ptr", txtBrush)

		DllCall("gdiplus\GdipDeletePath", "ptr", pPath)
}


; Builds a rounded-rectangle GraphicsPath (four 90-degree corner arcs). Caller
; owns the returned path and must GdipDeletePath it.
WPMWidget_MakeRoundRectPath(X, Y, W, H, R) {
		d := R * 2
		DllCall("gdiplus\GdipCreatePath", "int", 0, "ptr*", &path := 0)
		DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X,         "float", Y,         "float", d, "float", d, "float", 180, "float", 90)
		DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X + W - d, "float", Y,         "float", d, "float", d, "float", 270, "float", 90)
		DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X + W - d, "float", Y + H - d, "float", d, "float", d, "float", 0,   "float", 90)
		DllCall("gdiplus\GdipAddPathArc", "ptr", path, "float", X,         "float", Y + H - d, "float", d, "float", d, "float", 90,  "float", 90)
		DllCall("gdiplus\GdipClosePathFigure", "ptr", path)
		return path
}


; Parses a 6-hex color string ("#rrggbb" or "rrggbb") into a 0xRRGGBB integer for
; GDI+ ARGB construction. Falls back to the manual blue accent on bad input.
WPMWidget_HexToRgbInt(Hex) {
		H := Trim(Hex)
		if (SubStr(H, 1, 1) == "#")
				H := SubStr(H, 2)
		if !RegExMatch(H, "^[0-9A-Fa-f]{6}$")
				H := "4499FF"
		return (Integer("0x" . SubStr(H, 1, 2)) << 16)
				| (Integer("0x" . SubStr(H, 3, 2)) << 8)
				| Integer("0x" . SubStr(H, 5, 2))
}




; ── Drag support ──────────────────────────────────────────────────────────────
; Non-blocking drag: WM_NCLBUTTONDOWN tells Windows to handle the move loop
; natively — the window follows the cursor with zero lag and no timer polling.
; WPMWidget_DragEnd (WM_EXITSIZEMOVE) fires when the user releases the button
; and saves the final compact-anchor position to config.

WPMWidget_DragStart(ctrl, info, PostFn := 0, *) {
		InheritedCritical := Critical("On")
		try {
				gui_ref := WPMWidget.show_graph
						? WPMWidget._graph_gui
						: WPMWidget._gui
				if !gui_ref || WPMWidget._dragging
						return false
				; Native admission must precede the logical latch. PostMessage can
				; reject a surface whose HWND disappeared during a close/rebuild;
				; publishing first would suppress every later drag because no native
				; move loop exists to emit WM_EXITSIZEMOVE and clear the latch.
				if HasMethod(PostFn, "Call")
						PostFn.Call(0x00A1, 2, 0, gui_ref)
				else
						PostMessage(0x00A1, 2, 0, , gui_ref)
				WPMWidget._dragging := true
				return true
		} finally Critical(InheritedCritical)
}

WPMWidget_DragEnd(WParam := 0, LParam := 0, Message := 0, Hwnd := 0,
		MoveFn := 0, WriterFn := 0, NotifyFn := 0, *) {
		InheritedCritical := A_IsCritical
		if InheritedCritical {
				Critical("Off")
				try return WPMWidget_DragEnd(WParam, LParam, Message, Hwnd,
						MoveFn, WriterFn, NotifyFn)
				finally Critical(InheritedCritical)
		}
		if !WPMWidget._dragging
				return
		WPMWidget._dragging := false
		gui_ref := WPMWidget.show_graph ? WPMWidget._graph_gui : WPMWidget._gui
		if !gui_ref
				return
		gui_ref.GetPos(&fx, &fy)
		if WPMWidget.show_graph {
				; bottom-right = graph top-left + graph size; compact top-left = bottom-right - compact size
				NewX := fx + WPMWidgetConst.GRAPH_W - WPMWidgetConst.W
				NewY := fy + WPMWidgetConst.GRAPH_H - WPMWidgetConst.H
		} else {
				NewX := fx
				NewY := fy
		}
		if !WPMWidget_SavePosition(NewX, NewY, WriterFn, NotifyFn) {
				; Native dragging has already moved the window. A refused durable
				; candidate must restore the retained anchor as well as retain RAM.
				try {
						if HasMethod(MoveFn, "Call")
								MoveFn.Call(gui_ref)
						else
								_WPMWidget_ApplySurfaceGeometry(gui_ref)
				} catch as Err
						try LoggerError("WPMWidget", "Could not restore the widget after its dragged position was refused: {1}.", Err.Message)
				return
		}
}
