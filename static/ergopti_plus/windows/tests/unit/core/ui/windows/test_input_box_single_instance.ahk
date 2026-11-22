; tests/unit/core/ui/windows/test_input_box_single_instance.ahk

; ==============================================================================
; MODULE: One Input Box At A Time (PCK-17)
; DESCRIPTION:
; LLM_Menu_PromptNumeric releases Critical before its InputBox, and a box
; waits on its own thread: a second « Other value… » click opened a second box
; beside the first. A stand-in box waits here with a timeout; a timer
; thread asks for a second one while the first waits, as the second click does.
; ==============================================================================

#Requires AutoHotkey v2.0

global _IBSI_Second := 0

_IBSI_AskAgain() {
	global _IBSI_Second
	Started := A_TickCount
	Answer := Ui_InputBox("pck-17 second body", "pck-17 second box", "w240 h120 T2")
	_IBSI_Second := {Result: Answer.Result, Value: Answer.Value, Ms: A_TickCount - Started,
		Boxes: WinGetList(WindowTitle("pck-17 first box") . " ahk_pid " . DllCall("GetCurrentProcessId", "UInt")).Length}
}

_IBSI_OneBoxAtATime() {
	global _IBSI_Second
	_IBSI_Second := 0
	SavedCritical := A_IsCritical
	Critical("Off")
	Calls := []
	; The suite answers InputBox itself (suite-native-dialog-stubs): the first
	; box is an off-screen stand-in window that waits like a real box, so the
	; timer thread's second request meets the guard while it is open.
	TestInputBoxResponder(_IBSI_Box.Bind(Calls))
	try {
		SetTimer(_IBSI_AskAgain, -300)
		First := Ui_InputBox("pck-17 first body", "pck-17 first box", "w240 h120 T3", "kept")
	} finally {
		SetTimer(_IBSI_AskAgain, 0)
		Critical(SavedCritical)
	}
	try {
		AssertTrue(IsObject(_IBSI_Second), "the second request ran while the first box waited")
		AssertEqual("Cancel", _IBSI_Second.Result, "pck-17: a second request opens no second box")
		AssertTrue(_IBSI_Second.Ms < 1000, "pck-17: it answers at once instead of waiting on a box of its own: "
			. _IBSI_Second.Ms . " ms")
		AssertEqual(1, _IBSI_Second.Boxes, "the first box is still the one open")
		AssertEqual(1, Calls.Length, "the second request never reached a box")
		AssertEqual("Timeout", First.Result, "the first box keeps its own answer")
		AssertEqual("kept", First.Value)
		Again := Ui_InputBox("pck-17 third body", "pck-17 third box", "w240 h120 T0.3")
		AssertEqual("Timeout", Again.Result, "once the first box closed, the next request opens its own")
		AssertEqual(2, Calls.Length)
	} finally TestInputBoxResponder("")
}

; Stands in for a native box: a window under the box's caption, kept off the
; desktop, that waits for its timeout and answers with its default text.
_IBSI_Box(Calls, Prompt, Title, Options, Default) {
	Calls.Push(Title)
	Box := Gui("+ToolWindow", Title)
	try {
		Box.Show("NoActivate x-32000 y-32000 w240 h120")
		Sleep(RegExMatch(Options, "T([\d.]+)", &M) ? Integer(M[1] * 1000) : 0)
	} finally Box.Destroy()
	return {Result: "Timeout", Value: Default}
}
Test("native dialogs: a second input box request opens no second box (pck-17)", _IBSI_OneBoxAtATime)
