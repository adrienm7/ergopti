; tests/fixtures/wpm_empty_source_hold_owner_body.ahk

; ==============================================================================
; MODULE: WPM Empty Source Hold Child
; DESCRIPTION:
; The exact tick paints real native controls. No event precedes its first hidden
; oracle; a genuine AI push then proves that a zero-WPM source may still reveal.
; ==============================================================================

#Requires AutoHotkey v2.0

_WPMZ_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_WPMZ_KeepFailure(Failure) {
	global _WPMZ
	if !IsObject(_WPMZ.Failure)
		_WPMZ.Failure := Failure
}
_WPMZ_OnError(Failure, *) {
	_WPMZ_KeepFailure(Failure)
	return true
}
LoggerError(Tag, Template, Values*) {
	_WPMZ_KeepFailure(Error("Unexpected native WPM rebuild: " . Format(Template, Values*)))
}
LoggerDebug(*) {
}

_WPMZ_Now(Caller) {
	global _WPMZ
	_WPMZ_Require(_WPMZ.Now is Integer && _WPMZ.Now >= 0,
		"Every exact clock observation must remain in the native nonnegative integer domain.")
	_WPMZ.Reads[Caller] += 1
	return _WPMZ.Now
}
_WPMZ_MouseIdle() {
	global _WPMZ
	Actual := A_TimeIdleMouse
	_WPMZ.Mouse.Push(Actual)
	return Actual
}
_WPMZ_KeyboardIdle() {
	global _WPMZ
	Actual := A_TimeIdleKeyboard
	_WPMZ.Keyboard.Push(Actual)
	return Actual
}
_WPMZ_CheckPhase(Count, Pushes) {
	global _WPMZ
	if IsObject(_WPMZ.Failure)
		throw _WPMZ.Failure
	_WPMZ_Require(_WPMZ.Reads["tick"] == Count && _WPMZ.Reads["calc"] == Count
		&& _WPMZ.Reads["push"] == Pushes,
		"The genuine tick and calculator must return from their exact clock observations.")
	_WPMZ_Require(_WPMZ.Mouse.Length == Count && _WPMZ.Keyboard.Length == Count
		&& _WPMZ.Mouse[Count] is Integer && _WPMZ.Keyboard[Count] is Integer,
		"The actual idle pair used by this tick must be captured unchanged.")
	_WPMZ_Require(!(_WPMZ.Mouse[Count] < _WPMZ.Keyboard[Count]),
		"PREREQUISITE: actual native mouse activity must not outrank keyboard activity in this private tick.")
	_WPMZ_Require(!A_IsSuspended && WPMWidget.visible && !WPMWidget.show_graph
		&& WPMWidget._gui == _WPMZ.Gui && !_WPMWidget_TooltipUp(),
		"The exact compact GUI must remain enabled, unpaused and tooltip-free before any business oracle.")
}
_WPMZ_Observe(Phase) {
	global _WPMZ
	FileAppend("RECEIPT wpm-empty-source-hold-owner mode=" . _WPMZ.Mode . " phase=" . Phase
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " root=" . A_Args[2]
		. " now=" . _WPMZ.Now . " hold=" . WPMWidgetConst.COLOR_HOLD_MS
		. " ring=" . WPMWidget._ring.Length . " last_input=" . WPMWidget._last_input_ms
		. " hs_tick=" . WPMWidget._last_hs_tick . " ai_tick=" . WPMWidget._last_ai_tick . " ac_tick=" . WPMWidget._last_ac_tick
		. " tick_reads=" . _WPMZ.Reads["tick"] . " calc_reads=" . _WPMZ.Reads["calc"] . " push_reads=" . _WPMZ.Reads["push"]
		. " mouse_idle=" . _WPMZ.Mouse[_WPMZ.Mouse.Length] . " keyboard_idle=" . _WPMZ.Keyboard[_WPMZ.Keyboard.Length]
		. " hwnd=" . _WPMZ.Hwnd . " native_visible=" . DllCall("IsWindowVisible", "Ptr", _WPMZ.Hwnd, "Int")
		. " label=" . _WPMZ.Label.Value . " background=" . _WPMZ.Gui.BackColor
		. "`n", "*", "UTF-8-RAW")
}

_WPMZ_Exercise() {
	global _WPMZ
	_WPMZ_Require(WPMWidgetConst.COLOR_HOLD_MS >= 2 && WPMWidgetConst.COLOR_HOLD_MS < WPMWidgetConst.WINDOW_MS,
		"Actual shared source-color timing must be positive and narrower than the rolling window.")
	_WPMZ_Require(!IsSet(TooltipIsVisible) && !IsSet(LLM_TooltipIsVisible) && !_WPMWidget_TooltipUp(),
		"The private child creates neither tooltip subsystem nor tooltip instance.")
	Window := Gui("+AlwaysOnTop -Caption +ToolWindow", "Private WPM source hold fixture")
	_WPMZ.Gui := Window, _WPMZ.Hwnd := Window.Hwnd
	Window.BackColor := WPMWidgetConst.COLOR_BG_MANUAL
	_WPMZ.Label := Window.AddText("x0 y0 w160 h30", "not displayed")
	WPMWidget._lbl_wpm := _WPMZ.Label
	WPMWidget._lbl_strip := Window.AddText("x0 y30 w160 h5", "")
	WPMWidget._lbl_unit := Window.AddText("x0 y35 w160 h20", "private WPM")
	WPMWidget._gui := Window
	Window.Show("Hide w160 h60")
	WPMWidget.visible := true
	WPMWidget.show_graph := false
	WPMWidget.use_colors := true
	_WPMWidget_ResetRolling()
	_WPMZ_Require(!DllCall("IsWindowVisible", "Ptr", _WPMZ.Hwnd, "Int") && WPMWidget._ring.Length == 0
		&& WPMWidget._last_input_ms == 0 && WPMWidget._last_hs_tick == 0
		&& WPMWidget._last_ai_tick == 0 && WPMWidget._last_ac_tick == 0,
		"Actual reset must precede the first display attempt with no admitted input or source.")
	switch _WPMZ.Mode {
		case "ordinary-empty":
			_WPMZ.Now := WPMWidgetConst.WINDOW_MS + WPMWidgetConst.COLOR_HOLD_MS + 1
		case "second-era-empty":
			_WPMZ.Now := 0x100000000 + WPMWidgetConst.COLOR_HOLD_MS // 2
			_WPMZ_Require(_WPMZ.Now > 0xFFFFFFFF, "This vector must use full-width native uptime, not a DWORD reset.")
		default:
			throw ValueError("Unknown WPM source hold vector")
	}
	WPMWidget_Tick()
	_WPMZ_CheckPhase(1, 0)
	_WPMZ_Require(WPMWidget._ring.Length == 0 && WPMWidget._last_input_ms == 0,
		"No producer may fabricate input before the hidden-until-typed oracle.")
	_WPMZ_Observe("empty")
	_WPMZ_Require(!DllCall("IsWindowVisible", "Ptr", _WPMZ.Hwnd, "Int"),
		"An empty reset widget must stay natively hidden until an actual admitted source occurs.")

	; One real admitted AI event has zero WPM by the genuine calculator. It must
	; nevertheless reveal the widget in its actual canon source color.
	AdmittedTick := _WPMZ.Now
	WPMWidget_Push(false, true, false)
	_WPMZ_Require(WPMWidget._ring.Length == 1 && WPMWidget._ring[1]["t"] == AdmittedTick
		&& WPMWidget._ring[1]["ai"] && WPMWidget._last_ai_tick == AdmittedTick,
		"The genuine producer must own the affirmative source event and timestamp.")
	_WPMZ.Now += 1
	WPMWidget_Tick()
	_WPMZ_CheckPhase(2, 1)
	_WPMZ_Observe("admitted-ai")
	_WPMZ_Require(DllCall("IsWindowVisible", "Ptr", _WPMZ.Hwnd, "Int") && _WPMZ.Label.Value == "0"
		&& WPMWidget._last_wpm == 0 && StrLower(Window.BackColor) == StrLower(WPMWidgetConst.COLOR_BG_AI),
		"A real admitted zero-WPM AI source must reveal the actual compact GUI in its canon color.")
}

_WPMZ_Main() {
	global _WPMZ
	if A_Args.Length != 2
		ExitApp(2)
	_WPMZ := {Mode: A_Args[1], Now: 0, Reads: Map("tick", 0, "calc", 0, "push", 0),
		Mouse: [], Keyboard: [], Gui: 0, Hwnd: 0, Label: 0, Failure: 0}
	Primary := 0, PreviousCritical := Critical("Off"), PreviousSuspend := A_IsSuspended
	Suspend(false)
	OnError(_WPMZ_OnError)
	try _WPMZ_Exercise()
	catch Any as Failure
		Primary := IsObject(_WPMZ.Failure) ? _WPMZ.Failure : Failure
	finally {
		try {
			if IsObject(_WPMZ.Gui) {
				try _WPMZ.Gui.Destroy()
				catch Any as Failure
					_WPMZ_KeepFailure(Failure)
				if DllCall("IsWindow", "Ptr", _WPMZ.Hwnd, "Int")
					_WPMZ_KeepFailure(Error("The exact private WPM GUI did not retire."))
			}
			WPMWidget._gui := false, WPMWidget._lbl_wpm := false
			WPMWidget._lbl_strip := false, WPMWidget._lbl_unit := false
			_WPMZ.Gui := 0, _WPMZ.Label := 0
		} finally {
			OnError(_WPMZ_OnError, 0)
			Suspend(PreviousSuspend)
			Critical(PreviousCritical)
		}
	}
	if !IsObject(Primary) && IsObject(_WPMZ.Failure)
		Primary := _WPMZ.Failure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS wpm-empty-source-hold-owner " . _WPMZ.Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_WPMZ_Main()
