; tests/meta/ui/wpm/test_wpm_graph_upload_acknowledgement.ahk

; ==============================================================================
; MODULE: WPM Graph Upload Acknowledgement Meta Test
; DESCRIPTION:
; Regression guard for the Windows WPM parity audit finding WPMW-002. It is read
; from source because a refused UpdateLayeredWindow cannot be produced without a
; desktop.
;
; WPMWidget_RenderGraph ignored the Boolean GR_DrawBitmap returns when the native
; upload refuses, and so reported success: the tick then revealed a stale or blank
; surface. The acknowledgement is now returned to the caller, and the pre-warm no
; longer logs success for a refused upload.
; ==============================================================================

#Requires AutoHotkey v2.0

; Matches the call text of a source slice with its comments removed, so a comment
; that names the call cannot satisfy or defeat an assertion.
_WGU_Code(Name) {
	return _StripFullLineComments(_DriverFuncBody(Name))
}

_WGU_RenderGraphReturnsRefusal() {
	Body := _WGU_Code("WPMWidget_RenderGraph")
	Assert(Body != "", "WPMWidget_RenderGraph must exist in the wpm widget module")
	Assert(InStr(Body, "GR_DrawBitmap(g.Hwnd, DrawFn) != true") > 0,
		"WPMWidget_RenderGraph must test the acknowledgement GR_DrawBitmap returns")
	Refused := InStr(Body, "_graph_upload_refused := true")
	Accepted := InStr(Body, "_graph_upload_refused := false")
	Assert(Refused > 0 && Accepted > Refused,
		"a refused upload must be remembered and a later accepted one must clear it")
	Assert(RegExMatch(Body, "s)_graph_upload_refused := true\s+return false") > 0,
		"a refused upload must return false so the tick does not reveal the surface")
	Assert(InStr(Body, "LoggerError(") > 0,
		"a refused upload must be reported, not silently dropped")
}
Test("wpm-graph-upload: a refused native upload reaches the tick", _WGU_RenderGraphReturnsRefusal)

_WGU_PrewarmChecksUpload() {
	Body := _WGU_Code("WPMWidget_PrewarmGraph")
	Assert(Body != "", "WPMWidget_PrewarmGraph must exist in the wpm display module")
	UploadPos := InStr(Body, "Uploaded := GR_DrawBitmap(")
	DonePos := InStr(Body, "LoggerDone(")
	Assert(UploadPos > 0, "the pre-warm must capture the GR_DrawBitmap acknowledgement")
	Assert(InStr(Body, "if Uploaded != true") > UploadPos && InStr(Body, "if Uploaded != true") < DonePos,
		"a refused warm upload must throw before the pre-warmed success log")
}
Test("wpm-graph-upload: pre-warm does not log success for a refused upload", _WGU_PrewarmChecksUpload)
