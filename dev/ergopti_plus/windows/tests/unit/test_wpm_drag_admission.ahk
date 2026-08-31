; tests/unit/test_wpm_drag_admission.ahk

; ==============================================================================
; MODULE: WPM Drag Admission Tests
; DESCRIPTION:
; Proves that the logical drag latch is published only after Windows accepts
; the native move-loop message. A destroyed surface must leave the widget
; immediately retryable instead of suppressing every later drag.
; ==============================================================================

#Requires AutoHotkey v2.0

global _WDA_PostCalls := 0

_WDA_AcceptPost(Message, WParam, LParam, GuiRef) {
	global _WDA_PostCalls
	AssertFalse(WPMWidget._dragging,
		"native drag admission must precede logical ownership publication")
	_WDA_PostCalls += 1
}

_WDA_RefusedPostLeavesDragRetryable() {
	global _WDA_PostCalls
	HadGui := WPMWidget.HasOwnProp("_gui")
	HadGraphGui := WPMWidget.HasOwnProp("_graph_gui")
	HadDragging := WPMWidget.HasOwnProp("_dragging")
	if HadGui
		SavedGui := WPMWidget._gui
	if HadGraphGui
		SavedGraphGui := WPMWidget._graph_gui
	if HadDragging
		SavedDragging := WPMWidget._dragging
	SavedShowGraph := WPMWidget.show_graph
	DestroyedGui := Gui()
	try {
		DestroyedGui.Destroy()
		WPMWidget._gui := DestroyedGui
		WPMWidget._graph_gui := 0
		WPMWidget.show_graph := false
		WPMWidget._dragging := false
		Thrown := false
		try WPMWidget_DragStart(0, 0)
		catch
			Thrown := true
		AssertTrue(Thrown,
			"PostMessage must reject a destroyed WPM surface in the regression fixture")
		AssertFalse(WPMWidget._dragging,
			"a refused native move loop must leave the WPM drag latch retryable")

		_WDA_PostCalls := 0
		WPMWidget._gui := "accepted-test-surface"
		AssertTrue(WPMWidget_DragStart(0, 0, _WDA_AcceptPost),
			"a successful native admission must report ownership")
		AssertTrue(WPMWidget._dragging,
			"the drag latch must publish after successful native admission")
		AssertEqual(1, _WDA_PostCalls)
		AssertFalse(WPMWidget_DragStart(0, 0, _WDA_AcceptPost),
			"a second drag must not acquire an already-owned move loop")
		AssertEqual(1, _WDA_PostCalls,
			"the duplicate drag guard must run before native admission")
	} finally {
		if HadGui
			WPMWidget._gui := SavedGui
		else
			WPMWidget.DeleteProp("_gui")
		if HadGraphGui
			WPMWidget._graph_gui := SavedGraphGui
		else
			WPMWidget.DeleteProp("_graph_gui")
		WPMWidget.show_graph := SavedShowGraph
		if HadDragging
			WPMWidget._dragging := SavedDragging
		else
			WPMWidget.DeleteProp("_dragging")
	}
}

Test("WPM drag: refused native admission leaves the latch retryable (wpm-drag-admission)",
	_WDA_RefusedPostLeavesDragRetryable)
