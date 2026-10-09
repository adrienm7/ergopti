; tests/meta/test_wpm_graph_mode_draggable.ahk

; ==============================================================================
; MODULE: Regression — the WPM widget must be draggable in graph mode too
;         (wpm-graph-mode-draggable)
; DESCRIPTION:
; WPMWidget_BuildCompact adds three Text controls and wires all three to
; WPMWidget_DragStart. WPMWidget_BuildGraph created a caption-less, control-less
; layered window painted entirely by GDI+ and wired NO click entry point at all —
; and the two Guis are mutually exclusive at runtime, so in graph mode the labels
; that carry the sole entry point do not exist.
;
; ROOT CAUSE ENCODED: both drag handlers were written mode-aware
; (`WPMWidget.show_graph ? _graph_gui : _gui`), including WPMWidget_DragEnd's
; graph-anchor conversion (`NewX := fx + GRAPH_W - W`) — but the ENTRY point was
; only ever bound by the compact builder. WPMWidget._dragging could therefore
; never become true in graph mode, DragEnd's guard always returned, and its graph
; branch was unreachable code that reads as working code. Nothing throws and
; nothing logs: a click on a control-less window is swallowed by DefWindowProc.
;
; The module docstring advertises the widget as draggable with no mode qualifier,
; WPMWidget_ResetPosition explicitly moves the graph window, and the macOS sibling
; (wpm_widget.lua) drags in both modes from a single mouse callback — so this is a
; Windows-only gap, not a deliberate limitation.
;
; SCOPE: source-level — ui/wpm builds Guis at call time and is outside the
; headless include graph.
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================================
; ==================================================================
; ======= 1/ Both builders bind the drag entry point ===============
; ==================================================================
; ==================================================================

_WGMD_BothBuildersBindDragStart() {
	Compact := _DriverFuncBody("WPMWidget_BuildCompact")
	Graph   := _DriverFuncBody("WPMWidget_BuildGraph")
	Assert(Compact != "", "WPMWidget_BuildCompact must exist in the driver source")
	Assert(Graph   != "", "WPMWidget_BuildGraph must exist in the driver source")

	Assert(InStr(Compact, "WPMWidget_DragStart") > 0,
		"prerequisite: compact mode binds the drag entry point — it is the shape graph mode has to match")

	Assert(InStr(Graph, "WPMWidget_DragStart") > 0,
		"WPMWidget_BuildGraph must bind a WPMWidget_DragStart entry point. The graph window has no controls of its own, so without one a click reaches DefWindowProc, WPMWidget._dragging can never become true in graph mode, WPMWidget_DragEnd always early-returns, and its graph anchor-conversion branch is dead code — while the module docstring advertises the widget as draggable and the macOS twin drags in both modes")
}
Test("meta wpm-graph-mode-draggable: both widget builders bind WPMWidget_DragStart",
	_WGMD_BothBuildersBindDragStart)





; ==================================================================
; ==================================================================
; ======= 2/ Start and end of a drag stay coherent =================
; ==================================================================
; ==================================================================

; The graph builder registers the WM_EXITSIZEMOVE end-of-drag handler. Registering
; the END of a gesture that can never START is exactly how this stayed invisible
; to readers of either handler, so the two are pinned together.
_WGMD_EndOfDragImpliesStartOfDrag() {
	Graph := _DriverFuncBody("WPMWidget_BuildGraph")
	Assert(Graph != "", "WPMWidget_BuildGraph must exist in the driver source")

	if (InStr(Graph, "OnMessage(0x0232") == 0)
		return   ; No end-of-drag registration: nothing to keep coherent.

	Assert(InStr(Graph, "WPMWidget_DragStart") > 0,
		"WPMWidget_BuildGraph registers WM_EXITSIZEMOVE (the end of a native move loop) but binds no way to start one. Either both belong here or neither does — a lone end handler is what made the missing entry point read as complete code")
}
Test("meta wpm-graph-mode-draggable: registering the end of a drag implies a way to start one",
	_WGMD_EndOfDragImpliesStartOfDrag)
