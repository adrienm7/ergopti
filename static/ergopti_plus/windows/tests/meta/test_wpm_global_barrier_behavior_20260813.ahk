; tests/meta/test_wpm_global_barrier_behavior_20260813.ahk

; ==============================================================================
; MODULE: WPM Global Configuration Barrier Behaviour
; DESCRIPTION:
; Drives the real WPM persistence entry points with injected writers. The
; regression proves that candidate state is invisible during durable I/O and
; that a process-wide terminal transition refuses the mutation before any
; writer or in-memory publisher can run.
; ==============================================================================

#Requires AutoHotkey v2.0

#Include ../../ui/wpm/wpm_config.ahk
#Include ../../ui/wpm/wpm_widget.ahk

global _WPMGB_WriteCalls := 0
global _WPMGB_NotifyCalls := 0
global _WPMGB_WriteResult := true
global _WPMGB_ObservedState := 0
global _WPMGB_BuildCalls := 0
global _WPMGB_RestoreCalls := 0
global _WPMGB_RestoredGui := 0
global _WPMGB_HideCalls := 0
global _WPMGB_VisibleAtHide := 0
global _WPMGB_WriterCritical := []
global _WPMGB_NotifyCritical := []
global _WPMGB_RestoreCritical := []
global _WPMGB_HideCritical := []
global _WPMGB_ShowCritical := []
global _WPMGB_MoveCritical := []
global _WPMGB_ToggleCritical := []

class _WPMGB_DragGui {
	__New(X, Y) {
		this.x := X
		this.y := Y
		this.get_pos_critical := -1
	}

	GetPos(&X, &Y, *) {
		this.get_pos_critical := A_IsCritical
		X := this.x
		Y := this.y
	}
}

class _WPMGB_CloseGui {
	__New() {
		this.hide_calls := 0
		this.hide_critical := -1
	}

	Hide() {
		this.hide_calls += 1
		this.hide_critical := A_IsCritical
	}
}

class _WPMGB_SurfaceGui {
	__New() {
		this.destroy_calls := 0
		this.destroy_critical := -1
	}

	Destroy() {
		this.destroy_calls += 1
		this.destroy_critical := A_IsCritical
	}
}

class _WPMGB_Menu {
	__New() {
		this.events := []
	}

	_Record(Action, Label) {
		this.events.Push({ action: Action, label: Label,
			critical: A_IsCritical })
	}

	ToggleCheck(Label) => this._Record("toggle", Label)
	Enable(Label) => this._Record("enable", Label)
	Disable(Label) => this._Record("disable", Label)
}

_WPMGB_ResetFakes(WriteResult := true) {
	global _WPMGB_WriteCalls, _WPMGB_NotifyCalls, _WPMGB_WriteResult
	global _WPMGB_ObservedState, _WPMGB_BuildCalls
	global _WPMGB_RestoreCalls, _WPMGB_RestoredGui
	global _WPMGB_HideCalls, _WPMGB_VisibleAtHide
	global _WPMGB_WriterCritical, _WPMGB_NotifyCritical
	global _WPMGB_RestoreCritical, _WPMGB_HideCritical
	global _WPMGB_ShowCritical, _WPMGB_MoveCritical
	global _WPMGB_ToggleCritical
	_WPMGB_WriteCalls := 0
	_WPMGB_NotifyCalls := 0
	_WPMGB_WriteResult := WriteResult
	_WPMGB_ObservedState := 0
	_WPMGB_BuildCalls := 0
	_WPMGB_RestoreCalls := 0
	_WPMGB_RestoredGui := 0
	_WPMGB_HideCalls := 0
	_WPMGB_VisibleAtHide := 0
	_WPMGB_WriterCritical := []
	_WPMGB_NotifyCritical := []
	_WPMGB_RestoreCritical := []
	_WPMGB_HideCritical := []
	_WPMGB_ShowCritical := []
	_WPMGB_MoveCritical := []
	_WPMGB_ToggleCritical := []
}

_WPMGB_Writer(Path, Updates) {
	global _WPMGB_WriteCalls, _WPMGB_WriteResult, _WPMGB_ObservedState
	global _WPMGB_WriterCritical
	_WPMGB_WriteCalls += 1
	_WPMGB_WriterCritical.Push(A_IsCritical)
	_WPMGB_ObservedState := {
		visible: WPMWidget.visible,
		colors: WPMWidget.use_colors,
		graph: WPMWidget.show_graph,
		x: WPMWidget.pos_x,
		y: WPMWidget.pos_y,
	}
	return _WPMGB_WriteResult
}

_WPMGB_Notify(Message, Options) {
	global _WPMGB_NotifyCalls, _WPMGB_NotifyCritical
	_WPMGB_NotifyCalls += 1
	_WPMGB_NotifyCritical.Push(A_IsCritical)
}

_WPMGB_CountingBuild() {
	global _WPMGB_BuildCalls
	_WPMGB_BuildCalls += 1
	return { updates: [], noop: true }
}

_WPMGB_RecordRestore(GuiRef) {
	global _WPMGB_RestoreCalls, _WPMGB_RestoredGui
	global _WPMGB_RestoreCritical
	_WPMGB_RestoreCalls += 1
	_WPMGB_RestoredGui := GuiRef
	_WPMGB_RestoreCritical.Push(A_IsCritical)
}

_WPMGB_RecordHide() {
	global _WPMGB_HideCalls, _WPMGB_VisibleAtHide
	global _WPMGB_HideCritical
	_WPMGB_HideCalls += 1
	_WPMGB_VisibleAtHide := WPMWidget.visible
	_WPMGB_HideCritical.Push(A_IsCritical)
}

_WPMGB_RecordShow() {
	global _WPMGB_ShowCritical
	_WPMGB_ShowCritical.Push(A_IsCritical)
}

_WPMGB_RecordMove(GuiRef, X, Y) {
	global _WPMGB_MoveCritical
	_WPMGB_MoveCritical.Push(A_IsCritical)
}

_WPMGB_DefaultPos() => { x: 20, y: 30 }
_WPMGB_ShowPos() => { x: 40, y: 50 }

_WPMGB_ToggleTrue() {
	global _WPMGB_ToggleCritical
	_WPMGB_ToggleCritical.Push(A_IsCritical)
	WPMWidget.visible := !WPMWidget.visible
	return true
}

_WPMGB_ThrowingHide() {
	throw Error("injected surface-hide failure")
}

_WPMGB_SaveState() {
	global ConfigurationFile
	return {
		path: ConfigurationFile,
		visible: WPMWidget.visible,
		colors: WPMWidget.use_colors,
		graph: WPMWidget.show_graph,
		x: WPMWidget.pos_x,
		y: WPMWidget.pos_y,
	}
}

_WPMGB_RestoreState(Saved) {
	global ConfigurationFile
	ConfigurationFile := Saved.path
	WPMWidget.visible := Saved.visible
	WPMWidget.use_colors := Saved.colors
	WPMWidget.show_graph := Saved.graph
	WPMWidget.pos_x := Saved.x
	WPMWidget.pos_y := Saved.y
}





; ==============================================
; ==============================================
; ======= 1/ Owned candidate publication =======
; ==============================================
; ==============================================

_WPMGB_PublishesOnlyAfterWriter() {
	global ConfigurationFile, _WPMGB_WriteCalls, _WPMGB_ObservedState
	Saved := _WPMGB_SaveState()
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_gateway_order.toml"
		WPMWidget.use_colors := false
		WPMWidget.show_graph := false
		WPMWidget.pos_x := 10
		WPMWidget.pos_y := 20
		_WPMGB_ResetFakes()
		AssertTrue(WPMWidget_SaveConfig(true, true, 30, 40,
			_WPMGB_Writer, _WPMGB_Notify))
		AssertEqual(1, _WPMGB_WriteCalls,
			"one WPM candidate must perform exactly one owned writer call")
		AssertFalse(_WPMGB_ObservedState.colors,
			"colors must remain unpublished while the writer runs")
		AssertFalse(_WPMGB_ObservedState.graph,
			"graph mode must remain unpublished while the writer runs")
		AssertEqual(10, _WPMGB_ObservedState.x,
			"X must remain unpublished while the writer runs")
		AssertEqual(20, _WPMGB_ObservedState.y,
			"Y must remain unpublished while the writer runs")
		AssertTrue(WPMWidget.use_colors)
		AssertTrue(WPMWidget.show_graph)
		AssertEqual(30, WPMWidget.pos_x)
		AssertEqual(40, WPMWidget.pos_y)
	} finally _WPMGB_RestoreState(Saved)
}
Test("wpm-global-barrier-20260813: candidate publishes only after its owned writer",
	_WPMGB_PublishesOnlyAfterWriter)

_WPMGB_TerminalBarrierRefusesBeforeWriter() {
	global ConfigurationFile, _WPMGB_WriteCalls, _WPMGB_NotifyCalls
	global _WPMGB_BuildCalls
	Saved := _WPMGB_SaveState()
	Barrier := false
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_terminal_barrier.toml"
		WPMWidget.use_colors := false
		WPMWidget.show_graph := false
		WPMWidget.pos_x := 50
		WPMWidget.pos_y := 60
		_WPMGB_ResetFakes()
		Barrier := _ConfigWriteTerminalTryAcquire(ConfigurationFile)
		Assert(Barrier is Object,
			"the terminal barrier fixture must own the configuration transition")
		AssertFalse(WPMWidget_ToggleColorsConfig(_WPMGB_Writer, _WPMGB_Notify))
		AssertEqual(0, _WPMGB_WriteCalls,
			"an active terminal barrier must refuse before invoking the writer")
		AssertFalse(_WPMWidget_SaveBuilt(_WPMGB_CountingBuild,
			"the WPM candidate read", _WPMGB_Writer, _WPMGB_Notify))
		AssertEqual(0, _WPMGB_BuildCalls,
			"an active terminal barrier must refuse before reading candidate state")
		AssertEqual(2, _WPMGB_NotifyCalls,
			"each refused WPM mutation must surface exactly one failure")
		AssertFalse(WPMWidget.use_colors)
		AssertFalse(WPMWidget.show_graph)
		AssertEqual(50, WPMWidget.pos_x)
		AssertEqual(60, WPMWidget.pos_y)
	} finally {
		if Barrier is Object
			_ConfigWriteTerminalRelease(Barrier)
		_WPMGB_RestoreState(Saved)
	}
}
Test("wpm-global-barrier-20260813: terminal barrier refuses with zero writer and unchanged RAM",
	_WPMGB_TerminalBarrierRefusesBeforeWriter)

_WPMGB_CloseRefusalKeepsSurfaceVisible() {
	global ConfigurationFile, _WPMGB_WriteCalls, _WPMGB_NotifyCalls
	global _WPMGB_HideCalls
	Saved := _WPMGB_SaveState()
	Barrier := false
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_close_refusal.toml"
		WPMWidget.visible := true
		_WPMGB_ResetFakes()
		Barrier := _ConfigWriteTerminalTryAcquire(ConfigurationFile)
		Assert(Barrier is Object)
		AssertTrue(WPMWidget_Close(0, _WPMGB_Writer, _WPMGB_Notify,
			_WPMGB_RecordHide),
			"the close handler must suppress Gui.Close's implicit hide")
		AssertEqual(0, _WPMGB_WriteCalls,
			"terminal refusal must happen before the close writer")
		AssertEqual(0, _WPMGB_HideCalls,
			"terminal refusal must not invoke the surface-hide callback")
		AssertTrue(WPMWidget.visible,
			"terminal refusal must retain live visibility")
		AssertEqual(1, _WPMGB_NotifyCalls,
			"a refused close preference must surface exactly one failure")
	} finally {
		if Barrier is Object
			_ConfigWriteTerminalRelease(Barrier)
		_WPMGB_RestoreState(Saved)
	}
}
Test("wpm-global-barrier-20260813: terminal refusal cannot hide via window close",
	_WPMGB_CloseRefusalKeepsSurfaceVisible)

_WPMGB_CloseSuccessPublishesBeforeHide() {
	global ConfigurationFile, _WPMGB_WriteCalls, _WPMGB_NotifyCalls
	global _WPMGB_HideCalls, _WPMGB_VisibleAtHide, _WPMGB_ObservedState
	Saved := _WPMGB_SaveState()
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_close_success.toml"
		WPMWidget.visible := true
		_WPMGB_ResetFakes()
		AssertTrue(WPMWidget_Close(0, _WPMGB_Writer, _WPMGB_Notify,
			_WPMGB_RecordHide))
		AssertEqual(1, _WPMGB_WriteCalls,
			"one accepted close must perform exactly one owned writer call")
		AssertTrue(_WPMGB_ObservedState.visible,
			"the writer must observe the old live visibility")
		AssertFalse(WPMWidget.visible,
			"the successful commit must publish hidden visibility")
		AssertEqual(1, _WPMGB_HideCalls,
			"the surface-hide callback must run exactly once")
		AssertFalse(_WPMGB_VisibleAtHide,
			"live visibility must publish before the surface is hidden")
		AssertEqual(0, _WPMGB_NotifyCalls)
	} finally _WPMGB_RestoreState(Saved)
}
Test("wpm-global-barrier-20260813: window close persists then publishes then hides",
	_WPMGB_CloseSuccessPublishesBeforeHide)

_WPMGB_CloseHideFailureUsesGuiFallback() {
	global ConfigurationFile, _WPMGB_WriteCalls
	Saved := _WPMGB_SaveState()
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_close_hide_fallback.toml"
		WPMWidget.visible := true
		_WPMGB_ResetFakes()
		GuiRef := _WPMGB_CloseGui()
		AssertTrue(WPMWidget_Close(GuiRef, _WPMGB_Writer, _WPMGB_Notify,
			_WPMGB_ThrowingHide),
			"a secondary hide failure must not escape the native close callback")
		AssertEqual(1, _WPMGB_WriteCalls)
		AssertFalse(WPMWidget.visible,
			"durable hidden state must remain authoritative after a hide seam failure")
		AssertEqual(1, GuiRef.hide_calls,
			"the exact closing Gui must receive one deterministic fallback hide")
	} finally _WPMGB_RestoreState(Saved)
}
Test("wpm-global-barrier-20260813: close hide failure uses the native GUI fallback",
	_WPMGB_CloseHideFailureUsesGuiFallback)

_WPMGB_RejectedDragRestoresPhysicalWindow() {
	global ConfigurationFile, _WPMGB_RestoreCalls, _WPMGB_RestoredGui
	Saved := _WPMGB_SaveState()
	HadDragging := WPMWidget.HasOwnProp("_dragging")
	HadGui := WPMWidget.HasOwnProp("_gui")
	HadGraphGui := WPMWidget.HasOwnProp("_graph_gui")
	if HadDragging
		SavedDragging := WPMWidget._dragging
	if HadGui
		SavedGui := WPMWidget._gui
	if HadGraphGui
		SavedGraphGui := WPMWidget._graph_gui
	Barrier := false
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_rejected_drag.toml"
		WPMWidget.show_graph := false
		WPMWidget.pos_x := 90
		WPMWidget.pos_y := 100
		WPMWidget._dragging := true
		DraggedGui := _WPMGB_DragGui(400, 500)
		WPMWidget._gui := DraggedGui
		WPMWidget._graph_gui := false
		_WPMGB_ResetFakes()
		Barrier := _ConfigWriteTerminalTryAcquire(ConfigurationFile)
		Assert(Barrier is Object)
		WPMWidget_DragEnd(0, 0, 0, 0, _WPMGB_RecordRestore)
		AssertEqual(1, _WPMGB_RestoreCalls,
			"a rejected native drag must restore the physical window exactly once")
		Assert(ObjPtr(_WPMGB_RestoredGui) = ObjPtr(DraggedGui),
			"the rejected drag must restore the exact surface Windows moved")
		AssertEqual(90, WPMWidget.pos_x,
			"a rejected drag must retain the committed X anchor")
		AssertEqual(100, WPMWidget.pos_y,
			"a rejected drag must retain the committed Y anchor")
	} finally {
		if Barrier is Object
			_ConfigWriteTerminalRelease(Barrier)
		_WPMGB_RestoreState(Saved)
		if HadDragging
			WPMWidget._dragging := SavedDragging
		else
			WPMWidget.DeleteProp("_dragging")
		if HadGui
			WPMWidget._gui := SavedGui
		else
			WPMWidget.DeleteProp("_gui")
		if HadGraphGui
			WPMWidget._graph_gui := SavedGraphGui
		else
			WPMWidget.DeleteProp("_graph_gui")
	}
}
Test("wpm-global-barrier-20260813: rejected drag restores the physical GUI",
	_WPMGB_RejectedDragRestoresPhysicalWindow)

_WPMGB_MalformedSuccessStatusCannotPublish() {
	global ConfigurationFile, _WPMGB_WriteCalls
	Saved := _WPMGB_SaveState()
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_strict_status.toml"
		WPMWidget.visible := false
		_WPMGB_ResetFakes("1")
		AssertFalse(WPMWidget_SaveVisible(true, _WPMGB_Writer, _WPMGB_Notify),
			"a string success lookalike must not cross the strict boolean boundary")
		AssertEqual(1, _WPMGB_WriteCalls)
		AssertFalse(WPMWidget.visible,
			"a malformed writer status must leave visibility unpublished")
	} finally _WPMGB_RestoreState(Saved)
}
Test("wpm-global-barrier-20260813: malformed writer success cannot publish",
	_WPMGB_MalformedSuccessStatusCannotPublish)

_WPMGB_InheritedCriticalStopsAtCompleteUserActions() {
	global ConfigurationFile, _WPMGB_WriterCritical, _WPMGB_NotifyCritical
	global _WPMGB_RestoreCritical, _WPMGB_HideCritical
	global _WPMGB_ShowCritical, _WPMGB_MoveCritical, _WPMGB_ToggleCritical
	Saved := _WPMGB_SaveState()
	SavedCritical := A_IsCritical
	HadDragging := WPMWidget.HasOwnProp("_dragging")
	HadGui := WPMWidget.HasOwnProp("_gui")
	HadGraphGui := WPMWidget.HasOwnProp("_graph_gui")
	HadLblWpm := WPMWidget.HasOwnProp("_lbl_wpm")
	HadLblUnit := WPMWidget.HasOwnProp("_lbl_unit")
	if HadDragging
		SavedDragging := WPMWidget._dragging
	if HadGui
		SavedGui := WPMWidget._gui
	if HadGraphGui
		SavedGraphGui := WPMWidget._graph_gui
	if HadLblWpm
		SavedLblWpm := WPMWidget._lbl_wpm
	if HadLblUnit
		SavedLblUnit := WPMWidget._lbl_unit
	Barrier := false
	try {
		ConfigurationFile := A_Temp . "\ergopti_wpm_inherited_critical.toml"
		WPMWidget.visible := true
		WPMWidget.show_graph := false
		WPMWidget.pos_x := 10
		WPMWidget.pos_y := 20
		_WPMGB_ResetFakes()

		Critical("On")
		AssertTrue(WPMWidget_Close(0, _WPMGB_Writer, _WPMGB_Notify,
			_WPMGB_RecordHide))
		AssertTrue(A_IsCritical,
			"WPMWidget_Close must restore inherited Critical")
		FallbackGui := _WPMGB_CloseGui()
		WPMWidget.visible := true
		AssertTrue(WPMWidget_Close(FallbackGui, _WPMGB_Writer,
			_WPMGB_Notify, _WPMGB_ThrowingHide))
		AssertTrue(A_IsCritical,
			"the native close fallback must restore inherited Critical")

		WPMWidget.visible := false
		AssertTrue(WPMWidget_Toggle(_WPMGB_Writer, _WPMGB_Notify,
			_WPMGB_RecordShow, _WPMGB_RecordHide))
		AssertTrue(A_IsCritical,
			"WPMWidget_Toggle must restore inherited Critical")

		Surface := _WPMGB_DragGui(400, 500)
		WPMWidget._dragging := true
		WPMWidget._gui := Surface
		WPMWidget._graph_gui := false
		Barrier := _ConfigWriteTerminalTryAcquire(ConfigurationFile)
		AssertTrue(Barrier is Object)
		try WPMWidget_DragEnd(0, 0, 0, 0, _WPMGB_RecordRestore,
			_WPMGB_Writer, _WPMGB_Notify)
		finally {
			_ConfigWriteTerminalRelease(Barrier)
			Barrier := false
		}
		AssertTrue(A_IsCritical,
			"WPMWidget_DragEnd must restore inherited Critical")

		WPMWidget.visible := true
		WPMWidget._gui := Surface
		AssertTrue(WPMWidget_ResetPosition(_WPMGB_Writer, _WPMGB_Notify,
			_WPMGB_DefaultPos, _WPMGB_ShowPos, _WPMGB_RecordMove))
		AssertTrue(A_IsCritical,
			"WPMWidget_ResetPosition must restore inherited Critical")
		Critical("Off")

		for State in _WPMGB_WriterCritical
			AssertEqual(0, State,
				"WPM writers must never inherit a caller's Critical state")
		AssertEqual(1, _WPMGB_HideCritical.Length)
		AssertEqual(0, _WPMGB_HideCritical[1])
		AssertEqual(0, FallbackGui.hide_critical,
			"the native close fallback must run interruptibly")
		AssertEqual(1, _WPMGB_ShowCritical.Length)
		AssertEqual(0, _WPMGB_ShowCritical[1])
		AssertEqual(1, _WPMGB_RestoreCritical.Length)
		AssertEqual(0, _WPMGB_RestoreCritical[1])
		AssertEqual(0, Surface.get_pos_critical,
			"native drag geometry must be read interruptibly")
		AssertEqual(1, _WPMGB_MoveCritical.Length)
		AssertEqual(0, _WPMGB_MoveCritical[1])

		_WPMGB_ResetFakes()
		MenuRef := _WPMGB_Menu()
		WPMWidget.visible := false
		Critical("On")
		_ToggleWpmWidget(MenuRef, "widget", "colors", "graph",
			_WPMGB_ToggleTrue)
		AssertTrue(A_IsCritical,
			"the WPM menu toggle must restore inherited Critical")
		Critical("Off")
		AssertEqual(1, _WPMGB_ToggleCritical.Length)
		AssertEqual(0, _WPMGB_ToggleCritical[1])
		AssertEqual(3, MenuRef.events.Length)
		for Event in MenuRef.events
			AssertEqual(0, Event.critical,
				"WPM menu projection must update outside Critical")

		_WPMGB_ResetFakes()
		MenuRef := _WPMGB_Menu()
		WPMWidget.use_colors := false
		Critical("On")
		_ToggleWpmWidgetColors(MenuRef, "colors", _WPMGB_Writer,
			_WPMGB_Notify)
		AssertTrue(A_IsCritical)
		Critical("Off")
		AssertEqual(1, MenuRef.events.Length)
		AssertEqual(0, MenuRef.events[1].critical)

		_WPMGB_ResetFakes()
		MenuRef := _WPMGB_Menu()
		CompactGui := _WPMGB_SurfaceGui()
		GraphGui := _WPMGB_SurfaceGui()
		WPMWidget.visible := true
		WPMWidget.show_graph := false
		WPMWidget._gui := CompactGui
		WPMWidget._graph_gui := GraphGui
		WPMWidget._lbl_wpm := false
		WPMWidget._lbl_unit := false
		Critical("On")
		_ToggleWpmWidgetGraph(MenuRef, "graph", _WPMGB_Writer,
			_WPMGB_Notify, _WPMGB_RecordHide, _WPMGB_RecordShow)
		AssertTrue(A_IsCritical,
			"the WPM graph action must restore inherited Critical")
		Critical("Off")
		AssertEqual(0, _WPMGB_HideCritical[1])
		AssertEqual(0, _WPMGB_ShowCritical[1])
		AssertEqual(0, CompactGui.destroy_critical)
		AssertEqual(0, GraphGui.destroy_critical)
		AssertEqual(0, MenuRef.events[1].critical)
	} finally {
		Critical("Off")
		if Barrier is Object
			_ConfigWriteTerminalRelease(Barrier)
		_WPMGB_RestoreState(Saved)
		if HadDragging
			WPMWidget._dragging := SavedDragging
		else if WPMWidget.HasOwnProp("_dragging")
			WPMWidget.DeleteProp("_dragging")
		if HadGui
			WPMWidget._gui := SavedGui
		else if WPMWidget.HasOwnProp("_gui")
			WPMWidget.DeleteProp("_gui")
		if HadGraphGui
			WPMWidget._graph_gui := SavedGraphGui
		else if WPMWidget.HasOwnProp("_graph_gui")
			WPMWidget.DeleteProp("_graph_gui")
		if HadLblWpm
			WPMWidget._lbl_wpm := SavedLblWpm
		else if WPMWidget.HasOwnProp("_lbl_wpm")
			WPMWidget.DeleteProp("_lbl_wpm")
		if HadLblUnit
			WPMWidget._lbl_unit := SavedLblUnit
		else if WPMWidget.HasOwnProp("_lbl_unit")
			WPMWidget.DeleteProp("_lbl_unit")
		Critical(SavedCritical)
	}
}
Test("wpm-global-barrier-20260813: complete actions defuse inherited Critical "
	. "through native and menu effects (wpm-postcommit-inherited-critical)",
	_WPMGB_InheritedCriticalStopsAtCompleteUserActions)
