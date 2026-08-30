; tests/meta/test_wpm_widget_native_render.ahk

; ==============================================================================
; MODULE: WPM Widget Native-Render Guard
; DESCRIPTION:
; Guards that the WPM graph widget renders NATIVELY with GDI+ and never through a
; WebView2 canvas again.
;
; WHY THIS MATTERS (the regression this encodes):
;   The graph used to be an embedded WebView2 canvas. On first launch its
;   msedgewebview2 host processes cold-started for ~3-5 s, hammering CPU/disk; a
;   real boot log showed that contention inflate a single keystroke's dispatch to
;   ~480 ms (HSE.Dispatch 476 ms / OnChar 485 ms) and a tooltip build to ~268 ms
;   during the warm-up. The graph was rewritten to draw with GDI+ into a per-pixel
;   alpha layered window (infra/spotlight.ahk's pattern via the GraphicsRenderer
;   adapter), which has zero cold-start. If a future edit reintroduces WebView2 for
;   the widget, that whole-keyboard-freeze regression returns — this test makes
;   that loud.
;
; SCOPE: source introspection of ui/wpm/ (init.ahk + wpm_widget.ahk) + ui/tray_menu.ahk
;   (neither is loaded by the headless run_all, so a code-level guard is the only
;   automated net available for them). ASCII-only per the suite convention.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================
; =====================================
; ======= 1/ Test registrations =======
; =====================================
; =====================================

_MetaCheckWpmWidgetNativeRender() {
	SplitPath(A_ScriptDir, , &WindowsDir)   ; A_ScriptDir is tests\ -> WindowsDir is windows\

	; Scan the whole wpm module (init.ahk + the wpm_widget.ahk render layer after
	; the F3 split) so the GDI+ assertions stay green regardless of which sibling
	; the renderer lives in.
	Body := _DriverDirConcat("ui/wpm")
	Assert(Body != "", "ui/wpm sources must be readable for the native-render guard")

	; No WebView2 CODE may remain (comments may still mention the word historically,
	; so ban the actual call/property tokens, which only appear in real usage).
	for _, Banned in ["WebView2.create", "NavigateToString", "ExecuteScriptAsync",
	                  "CoreWebView2", "_graph_wv"] {
		Assert(!InStr(Body, Banned),
			"wpm_widget.ahk must not use '" . Banned . "' -- the graph renders with GDI+, "
			. "not a WebView2 canvas (its cold-start caused ~480 ms keystroke latency on boot)")
	}

	; The native GDI+ + layered-window render path must be present.
	Assert(InStr(Body, "GdiplusStartup"),
		"wpm_widget.ahk must start GDI+ (GdiplusStartup) for the native graph render")
	Assert(InStr(Body, "GR_DrawBitmap"),
		"wpm_widget.ahk must paint the graph via GR_DrawBitmap (UpdateLayeredWindow), no browser")
	Assert(InStr(Body, "WPMWidget_DrawGraph"),
		"wpm_widget.ahk must define the native GDI+ WPMWidget_DrawGraph renderer")

	; The tray-menu graph toggle must not touch the removed WebView2 widget state.
	TrayFile := WindowsDir . "\ui\tray_menu.ahk"
	TrayBody := ""
	try TrayBody := FileRead(TrayFile)
	Assert(TrayBody != "", "tray_menu.ahk must be readable for the native-render guard")
	Assert(!InStr(TrayBody, "_graph_wv"),
		"tray_menu.ahk must not reference the removed WebView2 widget state (_graph_wv)")
}

Test("meta wpm widget: graph renders natively with GDI+, no WebView2 cold-start",
	_MetaCheckWpmWidgetNativeRender)





_MetaCheckWpmGdipAcquisitionOwnership() {
	Acquire := _DriverFuncBody("_WPMGdipAcquire")
	Assert(Acquire != "",
		"WPM GDI+ startup must have one testable transactional acquisition owner")
	Release := _DriverFuncBody("_WPMGdipRelease")
	Assert(Release != "" and InStr(Acquire, "_WPMGdipRelease") > 0,
		"partial WPM GDI+ acquisition must route through retained reverse cleanup")
	Ensure := _DriverFuncBody("WPMWidget_EnsureGdip")
	Assert(InStr(Ensure, "_gdip_cleanup_debt") > 0,
		"failed cleanup must remain globally owned for a later retry")
	Assert(InStr(Ensure, "_gdip_started := true") > 0
		and InStr(Ensure, "Result[") > 0,
		"WPM may publish started only from a complete acquisition receipt")
}
Test("meta wpm widget: GDI+ initialization retains partial ownership",
	_MetaCheckWpmGdipAcquisitionOwnership)





_MetaCheckWpmGdipFrameOwnership() {
	Frame := _DriverFuncBody("_WPMGdipRunFrame")
	Assert(Frame != "" and InStr(Frame, "_WPMGdipFrameRelease") > 0,
		"every WPM frame must release its complete GDI+ receipt through one owner")
	Draw := _DriverFuncBody("WPMWidget_DrawGraph")
	Assert(Draw != "" and InStr(Draw, "_WPMGdipFrameRequireCreated") > 0,
		"every per-frame path, brush, and pen must enter the frame receipt")
	Assert(!RegExMatch(Draw, "i)GdipDelete(?:Brush|Pen|Path)"),
		"WPM drawing must not bypass the retained frame cleanup owner")
	Render := _DriverFuncBody("WPMWidget_RenderGraph")
	DebtPublish := InStr(Render, "_gdip_frame_cleanup_debt := FrameResult")
	BitmapCall := InStr(Render, "GR_DrawBitmap(g.Hwnd")
	Assert(DebtPublish > 0,
		"a refused per-frame native cleanup must remain owned across ticks")
	Assert(BitmapCall > DebtPublish,
		"cleanup debt must publish inside the callback before GR_DrawBitmap can throw later")
}
Test("meta wpm widget: every frame retains complete GDI+ ownership",
	_MetaCheckWpmGdipFrameOwnership)
