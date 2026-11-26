; tests/fixtures/wpm_recovery_owner_body.ahk

; ==============================================================================
; MODULE: WPM Surface Recovery Child
; DESCRIPTION:
; Genuine display, builders and geometry own native HWNDs. Only reconstruction
; failures, clock/idle observations and graph pixels use explicit passive ports.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPMR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}
LoggerDebug(*) {
}
LoggerError(Tag, Template, Values*) {
	global _WPMR
	Message := Format(Template, Values*)
	if InStr(Message, "mode tick threw")
		_WPMR.RenderFailures += 1
	else if InStr(Message, "Surface reconstruction failed") && InStr(Message, "controlled recovery failure")
		_WPMR.BuildFailures += 1
	else
		_WPMR.Unexpected.Push(Message)
}
; Translation is a passive label port; it cannot affect surface ownership.
t(Key) => Key
_WPMZ_Now(*) {
	global _WPMR
	return _WPMR.Now
}
_WPMZ_MouseIdle() => 1000
_WPMZ_KeyboardIdle() => 0

_WPMR_Build(Graph) {
	global _WPMR
	_WPMR.Attempts += 1
	if _WPMR.Attempts == 1 && InStr(_WPMR.Mode, "-build")
		throw Error("controlled recovery failure: builder")
	Candidate := Graph ? WPMWidget_BuildGraph() : WPMWidget_BuildCompact()
	_WPMR.Windows.Push({Gui: Candidate, Hwnd: Candidate.Hwnd})
	return Candidate
}
_WPMR_BuildCompact() => _WPMR_Build(false)
_WPMR_BuildGraph() => _WPMR_Build(true)
_WPMR_ApplyGeometry(Candidate) {
	global _WPMR
	if _WPMR.Attempts == 1 && InStr(_WPMR.Mode, "-geometry")
		throw Error("controlled recovery failure: geometry")
	_WPMWidget_ApplySurfaceGeometry(Candidate)
	if InStr(_WPMR.Mode, "-successor") {
		Successor := WPMWidget.show_graph ? WPMWidget_BuildGraph() : WPMWidget_BuildCompact()
		_WPMR.Windows.Push({Gui: Successor, Hwnd: Successor.Hwnd})
		_WPMWidget_ApplySurfaceGeometry(Successor)
		_WPMR.Successor := Successor
	}
}
; This fixture qualifies lifecycle and native geometry, not GDI+ pixels.
WPMWidget_RenderGraph(*) {
	global _WPMR
	GuiRef := WPMWidget._graph_gui
	if !GuiRef || !DllCall("IsWindow", "Ptr", _WPMR.Initial, "Int") && _WPMR.Attempts == 0
		throw Error("controlled stale graph surface")
	_WPMR_Require(DllCall("IsWindow", "Ptr", GuiRef.Hwnd, "Int"), "Graph rendering needs its actual live HWND.")
	return true
}
GR_Show(Hwnd) {
	DllCall("ShowWindow", "Ptr", Hwnd, "Int", 4)
}

_WPMR_Exercise() {
	global _WPMR
	Graph := InStr(_WPMR.Mode, "graph-") == 1
	WPMWidget.visible := true, WPMWidget.show_graph := Graph, WPMWidget.use_colors := true
	WPMWidget.pos_x := 200, WPMWidget.pos_y := 300
	_WPMWidget_ResetRolling()
	WPMWidget_Push(false, true, false)
	_WPMR_Require(WPMWidget._ring.Length == 1 && WPMWidget._last_input_ms == _WPMR.Now,
		"An actual admitted producer owns the retained input sample.")
	if InStr(_WPMR.Mode, "-successor") {
		_WPMR_Require(!_WPMWidget_RebuildSurface(), "A retired candidate must not be declared ready after geometry yields.")
		Current := Graph ? WPMWidget._graph_gui : WPMWidget._gui
		_WPMR_Require(Current == _WPMR.Successor && _WPMR.Windows.Length == 2
			&& !DllCall("IsWindow", "Ptr", _WPMR.Windows[1].Hwnd, "Int")
			&& DllCall("IsWindow", "Ptr", _WPMR.Windows[2].Hwnd, "Int"),
			"Only the retired candidate may be destroyed; the genuine successor must remain current and alive.")
		WPMWidget_Tick()
		_WPMR_Require(_WPMR.Attempts == 1 && _WPMR.RenderFailures == 0 && _WPMR.BuildFailures == 0
			&& _WPMR.Unexpected.Length == 0 && DllCall("IsWindowVisible", "Ptr", Current.Hwnd, "Int")
			&& WPMWidget._ring.Length == 1 && WPMWidget._last_input_ms == _WPMR.Now,
			"The successor must render on the next tick without reconstruction or loss of admitted input.")
		return
	}
	InitialGui := Graph ? WPMWidget_BuildGraph() : WPMWidget_BuildCompact()
	_WPMR.Initial := InitialGui.Hwnd
	_WPMR.Windows.Push({Gui: InitialGui, Hwnd: InitialGui.Hwnd})
	_WPMWidget_ApplySurfaceGeometry(InitialGui)
	InitialGui.Destroy()
	_WPMR_Require(!DllCall("IsWindow", "Ptr", _WPMR.Initial, "Int"), "The initial HWND must really be gone.")

	WPMWidget.visible := false
	WPMWidget_Tick()
	WPMWidget.visible := true
	Suspend(true)
	try WPMWidget_Tick()
	finally Suspend(false)
	_WPMR_Require(_WPMR.Attempts == 0, "Hidden and suspended ticks must not construct a surface.")

	WPMWidget_Tick()
	Current := Graph ? WPMWidget._graph_gui : WPMWidget._gui
	_WPMR_Require(!Current && _WPMR.Attempts == 1 && _WPMR.RenderFailures == 1 && _WPMR.BuildFailures == 1,
		"The genuine render failure and controlled reconstruction failure must leave a retryable missing surface.")
	for Window in _WPMR.Windows
		_WPMR_Require(!DllCall("IsWindow", "Ptr", Window.Hwnd, "Int"), "A failed geometry candidate must retire its actual HWND.")
	_WPMR.Now += 1
	WPMWidget_Tick()
	Current := Graph ? WPMWidget._graph_gui : WPMWidget._gui
	_WPMR_Require(Current && _WPMR.Attempts == 2 && _WPMR.Unexpected.Length == 0,
		"A later ordinary tick must reconstruct and render without another error.")
	Hwnd := Current.Hwnd
	_WPMR_Require(DllCall("IsWindowVisible", "Ptr", Hwnd, "Int"), "The recovered native surface must be visible.")
	Rect := Buffer(16, 0)
	_WPMR_Require(DllCall("GetWindowRect", "Ptr", Hwnd, "Ptr", Rect, "Int"), "Read the real recovered native rectangle.")
	Width := Graph ? WPMWidgetConst.GRAPH_W : WPMWidgetConst.W
	Height := Graph ? WPMWidgetConst.GRAPH_H : WPMWidgetConst.H
	WPMWidget_ShowPos(&X, &Y)
	_WPMR_Require(NumGet(Rect, 0, "Int") == X && NumGet(Rect, 4, "Int") == Y
		&& NumGet(Rect, 8, "Int") - X == Width && NumGet(Rect, 12, "Int") - Y == Height,
		"The genuine geometry owner must size and anchor the recovered native surface.")
	_WPMR_Require(WPMWidget._ring.Length == 1 && WPMWidget._last_input_ms == _WPMR.Now - 1
		&& WPMWidget._last_ai_tick == _WPMR.Now - 1 && WPMWidget._graph_hist.Length >= 2,
		"Recovery must preserve admitted input, source clocks and rolling history.")
	WPMWidget_Tick()
	_WPMR_Require(_WPMR.Attempts == 2 && _WPMR.RenderFailures == 1 && _WPMR.BuildFailures == 1
		&& _WPMR.Unexpected.Length == 0, "The recovered owner must be reused by the following tick.")
	FileAppend("RECEIPT wpm-recovery-owner mode=" . _WPMR.Mode . " hwnd=" . Hwnd
		. " attempts=" . _WPMR.Attempts . " ring=" . WPMWidget._ring.Length . "`n", "*", "UTF-8-RAW")
}

_WPMR_Main() {
	global _WPMR
	if A_Args.Length != 2
		ExitApp(2)
	_WPMR := {Mode: A_Args[1], Now: 10000, Attempts: 0, Initial: 0, Successor: 0, Windows: [],
		RenderFailures: 0, BuildFailures: 0, Unexpected: []}
	Primary := 0
	try _WPMR_Exercise()
	catch Any as Failure
		Primary := Failure
	finally {
		try OnMessage(0x0232, WPMWidget_DragEnd, 0)
		for Window in _WPMR.Windows {
			if DllCall("IsWindow", "Ptr", Window.Hwnd, "Int")
				try Window.Gui.Destroy()
		}
		for Window in _WPMR.Windows {
			if DllCall("IsWindow", "Ptr", Window.Hwnd, "Int") && !IsObject(Primary)
				Primary := Error("An exact native recovery HWND failed to retire.")
		}
		WPMWidget._gui := false, WPMWidget._graph_gui := false
		WPMWidget._lbl_wpm := false, WPMWidget._lbl_unit := false, WPMWidget._lbl_strip := false
	}
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS wpm-recovery-owner " . _WPMR.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_WPMR_Main()
