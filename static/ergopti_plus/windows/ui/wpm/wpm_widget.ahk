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
WPMWidget_EnsureGdip(Native := _WPMGdipNative) {
		if WPMWidget._gdip_started
				return true
		PreviousCritical := Critical("On")
		try {
				if WPMWidget._gdip_started
						return true
				if WPMWidget._gdip_initializing
						return false
				WPMWidget._gdip_initializing := true
		} finally Critical(PreviousCritical)

		AcquiredReceipt := 0
		FailureMessage := ""
		try {
				if WPMWidget._gdip_cleanup_debt is Map {
						if !_WPMGdipRelease(WPMWidget._gdip_cleanup_debt, Native) {
								FailureMessage := "previous partial initialization still owns cleanup debt"
								return false
						}
						WPMWidget._gdip_cleanup_debt := 0
				}

				Result := _WPMGdipAcquire(WPMWidgetConst.GRAPH_LABEL_PX, Native)
				if !Result["ok"] {
						if Result["receipt"] is Map
								WPMWidget._gdip_cleanup_debt := Result["receipt"]
						FailureMessage := Result["error"]
						return false
				}
				AcquiredReceipt := Result["receipt"]
				PreviousCritical := Critical("On")
				try {
						WPMWidget._gdip_module := AcquiredReceipt["module"]
						WPMWidget._gdip_token := AcquiredReceipt["token"]
						WPMWidget._gdip_family := AcquiredReceipt["family"]
						WPMWidget._gdip_font := AcquiredReceipt["font"]
						WPMWidget._gdip_fmt := AcquiredReceipt["format"]
						WPMWidget._gdip_started := true
						AcquiredReceipt := 0
				} finally Critical(PreviousCritical)
				return true
		} catch as Err {
				FailureMessage := Err.Message
				return false
		} finally {
				if AcquiredReceipt is Map {
						if !_WPMGdipRelease(AcquiredReceipt, Native)
								WPMWidget._gdip_cleanup_debt := AcquiredReceipt
				}
				PreviousCritical := Critical("On")
				try WPMWidget._gdip_initializing := false
				finally Critical(PreviousCritical)
				if FailureMessage != ""
						try LoggerError("WPMWidget",
								"GDI+ initialization failed — graph mode unavailable: {1}.",
								FailureMessage)
		}
}


; Renders the WPM graph into the layered graph window with GDI+ — the native
; replacement for the WebView2 canvas (no ~3-5 s browser cold-start, no per-key
; contention). Delegates the DIB + UpdateLayeredWindow lifecycle to the
; GraphicsRenderer adapter (the same path infra/spotlight.ahk uses); GR_DrawBitmap
; positions the bitmap at the window's current rect, so a drag never causes a jump.
WPMWidget_RenderGraph(Label, AccentHex, Native := _WPMGdipFrameNative) {
		g := WPMWidget._graph_gui
		if (!g or !WPMWidget_EnsureGdip())
				return false
		PreviousCritical := Critical("On")
		try {
				if WPMWidget._gdip_frame_rendering
						return false
				WPMWidget._gdip_frame_rendering := true
		} finally Critical(PreviousCritical)

		try {
				if WPMWidget._gdip_frame_cleanup_debt is Map {
						if !_WPMGdipFrameRelease(WPMWidget._gdip_frame_cleanup_debt, Native)
								return false
						WPMWidget._gdip_frame_cleanup_debt := 0
				}
				; Snapshot history so a concurrent WPMWidget_Push cannot mutate it mid-draw.
				Hist := WPMWidget._graph_hist.Clone()
				; The Gui is -DPIScale (physical pixels); render in logical coordinates.
				dpi := DllCall("GetDpiForWindow", "Ptr", g.Hwnd, "UInt")
				if (dpi < 72)
						dpi := 96
				Scale := dpi / 96.0

				DrawFn(MemDC, W, H) {
						FrameResult := _WPMGdipRunFrame(MemDC,
								_WPMWidget_DrawFrame.Bind(W / Scale, H / Scale, Scale,
										Label, AccentHex, Hist), Native)
						; Publish refused cleanup before returning to GR_DrawBitmap. Its
						; later UpdateLayeredWindow call can itself throw, and must not
						; strand this frame's only cleanup receipt in a dead closure.
						if FrameResult["receipt"] is Map
								WPMWidget._gdip_frame_cleanup_debt := FrameResult["receipt"]
						if !FrameResult["ok"]
								throw Error("WPM GDI+ frame failed: " . FrameResult["error"])
				}
				GR_DrawBitmap(g.Hwnd, DrawFn)
				return true
		} finally {
				PreviousCritical := Critical("On")
				try WPMWidget._gdip_frame_rendering := false
				finally Critical(PreviousCritical)
		}
}


_WPMWidget_DrawFrame(W, H, Scale, Label, AccentHex, Hist,
		pGfx, Receipt, Native) {
		if (Scale != 1.0)
				_WPMGdipFrameRequireOk(Native.ScaleWorld(pGfx, Scale),
						"GdipScaleWorldTransform")
		WPMWidget_DrawGraph(pGfx, W, H, Label, AccentHex, Hist, Receipt, Native)
}


; Paints the graph into a GDI+ context in LOGICAL coordinates (W x H): a rounded
; dark pill, a filled + stroked WPM sparkline clipped to the pill, and a centered
; WPM label. Mirrors the old canvas geometry 1:1 (PAD/LH/GH/GW/R/scale).
WPMWidget_DrawGraph(pGfx, W, H, Label, AccentHex, Hist, Receipt,
		Native := _WPMGdipFrameNative,
		LabelPx := WPMWidgetConst.GRAPH_LABEL_PX,
		GraphScaleMax := WPMWidgetConst.GRAPH_SCALE_MAX) {
		static PAD := 5, CORNER_R := 8
		static PILL_FILL   := 0xCC000000   ; rgba(0,0,0,0.8)
		static PILL_STROKE := 0x66FFFFFF   ; rgba(255,255,255,0.4)
		static LABEL_COLOR := 0xFFFFFFFF
		static FILL_ALPHA  := 0x33         ; 0.2 x 255 — sparkline fill area
		LH := LabelPx * 2
		GH := H - LH - PAD * 2
		GW := W - PAD * 2

		; Rounded-rect pill path — reused for fill, stroke and the sparkline clip.
		pPath := WPMWidget_MakeRoundRectPath(0, 0, W, H, CORNER_R,
				Receipt, Native)
		bgBrush := 0
		Status := Native.CreateBrush(PILL_FILL, &bgBrush)
		_WPMGdipFrameRequireCreated(Receipt, "brush", Status, bgBrush,
				"GdipCreateSolidFill for the WPM background")
		_WPMGdipFrameRequireOk(Native.FillPath(pGfx, bgBrush, pPath),
				"GdipFillPath for the WPM background")
		bgPen := 0
		Status := Native.CreatePen(PILL_STROKE, 1, &bgPen)
		_WPMGdipFrameRequireCreated(Receipt, "pen", Status, bgPen,
				"GdipCreatePen1 for the WPM background")
		_WPMGdipFrameRequireOk(Native.DrawPath(pGfx, bgPen, pPath),
				"GdipDrawPath for the WPM background")

		N := Hist.Length
		if (N >= 2) {
				ClipSet := false
				try {
						_WPMGdipFrameRequireOk(Native.SetClipPath(pGfx, pPath),
								"GdipSetClipPath for the WPM graph")
						ClipSet := true
						ScaleMax := GraphScaleMax
						Step := GW / (N - 1)
						BaseY := LH + PAD + GH
						Rgb := WPMWidget_HexToRgbInt(AccentHex)

						; Filled area: N samples plus two baseline corners.
						ptsFill := Buffer((N + 2) * 8)
						Loop N {
								i := A_Index - 1
								NumPut("Float", PAD + i * Step, ptsFill, i * 8)
								NumPut("Float", BaseY - (Hist[A_Index] / ScaleMax) * GH,
										ptsFill, i * 8 + 4)
						}
						NumPut("Float", PAD + (N - 1) * Step, ptsFill, N * 8)
						NumPut("Float", BaseY, ptsFill, N * 8 + 4)
						NumPut("Float", PAD, ptsFill, (N + 1) * 8)
						NumPut("Float", BaseY, ptsFill, (N + 1) * 8 + 4)
						fillBrush := 0
						Status := Native.CreateBrush((FILL_ALPHA << 24) | Rgb,
								&fillBrush)
						_WPMGdipFrameRequireCreated(Receipt, "brush", Status,
								fillBrush, "GdipCreateSolidFill for the WPM area")
						_WPMGdipFrameRequireOk(Native.FillPolygon(pGfx, fillBrush,
								ptsFill, N + 2), "GdipFillPolygon for the WPM area")

						; Stroked line over the fill.
						ptsLine := Buffer(N * 8)
						Loop N {
								i := A_Index - 1
								NumPut("Float", PAD + i * Step, ptsLine, i * 8)
								NumPut("Float", BaseY - (Hist[A_Index] / ScaleMax) * GH,
										ptsLine, i * 8 + 4)
						}
						linePen := 0
						Status := Native.CreatePen(0xFF000000 | Rgb, 2, &linePen)
						_WPMGdipFrameRequireCreated(Receipt, "pen", Status,
								linePen, "GdipCreatePen1 for the WPM line")
						_WPMGdipFrameRequireOk(Native.DrawLines(pGfx, linePen,
								ptsLine, N), "GdipDrawLines for the WPM line")
				} finally {
						if ClipSet
								_WPMGdipFrameRequireOk(Native.ResetClip(pGfx),
										"GdipResetClip for the WPM graph")
				}
		}

		; WPM label, centered in the top zone.
		txtBrush := 0
		Status := Native.CreateBrush(LABEL_COLOR, &txtBrush)
		_WPMGdipFrameRequireCreated(Receipt, "brush", Status, txtBrush,
				"GdipCreateSolidFill for the WPM label")
		rect := Buffer(16)
		NumPut("Float", 0, rect, 0), NumPut("Float", 0, rect, 4)
		NumPut("Float", W, rect, 8), NumPut("Float", LH, rect, 12)
		_WPMGdipFrameRequireOk(Native.DrawString(pGfx, Label,
				WPMWidget._gdip_font, rect, WPMWidget._gdip_fmt, txtBrush),
				"GdipDrawString for the WPM label")
}


; Builds a rounded-rectangle GraphicsPath and transfers it immediately to the
; current frame receipt before any later native operation can fail.
WPMWidget_MakeRoundRectPath(X, Y, W, H, R, Receipt,
		Native := _WPMGdipFrameNative) {
		d := R * 2
		path := 0
		Status := Native.CreatePath(&path)
		_WPMGdipFrameRequireCreated(Receipt, "path", Status, path,
				"GdipCreatePath for the WPM pill")
		_WPMGdipFrameRequireOk(Native.AddPathArc(path, X, Y, d, d, 180, 90),
				"first WPM pill arc")
		_WPMGdipFrameRequireOk(Native.AddPathArc(path, X + W - d, Y,
				d, d, 270, 90), "second WPM pill arc")
		_WPMGdipFrameRequireOk(Native.AddPathArc(path, X + W - d, Y + H - d,
				d, d, 0, 90), "third WPM pill arc")
		_WPMGdipFrameRequireOk(Native.AddPathArc(path, X, Y + H - d,
				d, d, 90, 90), "fourth WPM pill arc")
		_WPMGdipFrameRequireOk(Native.ClosePath(path), "GdipClosePathFigure")
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
