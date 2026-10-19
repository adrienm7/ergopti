; tests/unit/modules/shortcuts/test_program_picker_modal_owner.ahk

; Drive the actual native picker and its actual argument InputBox. Cancelled
; owners must retire the callback before it touches the destroyed ListBox.

_PPMO_Click(Hwnd, ClassNN) {
	Control := ControlGetHwnd(ClassNN, "ahk_id " . Hwnd)
	Id := DllCall("GetDlgCtrlID", "Ptr", Control, "Int")
	AssertTrue(Control && Id, "the actual picker button must have its native notification identity")
	PostMessage(0x111, Id, Control, , "ahk_id " . Hwnd)
}

_PPMO_Release(State) {
	; The unique label also finds a window when caption admission itself failed.
	for Hwnd in WinGetList("ahk_pid " . DriverPid) {
		if InStr(WinGetTitle("ahk_id " . Hwnd), State["label"], true)
			PostMessage(0x10, 0, 0, , "ahk_id " . Hwnd)
	}
}

_PPMO_Unhandled(State, Err, *) {
	State["errors"].Push(Err)
	; A baseline GUI callback exception must become a failing assertion below,
	; rather than leave a modal error popup blocking the runner indefinitely.
	return 1
}

_PPMO_Pump(State) {
	try {
		if A_TickCount - State["started"] > 5000
			throw Error("The real native program picker exceeded its fixture deadline")
		if State["phase"] == "open" {
			for Hwnd in WinGetList("ahk_pid " . DriverPid) {
				if WinGetTitle("ahk_id " . Hwnd) != State["title"] || WinGetClass("ahk_id " . Hwnd) == "#32770"
					continue
				State["picker"] := Hwnd
				AssertEqual(t("dialog.action_picker.program_add_argument"), ControlGetText("Button1", "ahk_id " . Hwnd))
				AssertEqual(t("button.save"), ControlGetText("Button3", "ahk_id " . Hwnd))
				AssertEqual(1, SendMessage(0x18B, 0, 0, "ListBox1", "ahk_id " . Hwnd), "the actual ListBox starts with the preserved argument")
				State["phase"] := "input"
				_PPMO_Click(Hwnd, "Button1")
				return
			}
		} else if State["phase"] == "input" {
			for Hwnd in WinGetList("ahk_class #32770 ahk_pid " . DriverPid) {
				if WinGetTitle("ahk_id " . Hwnd) != State["title"]
					continue
				State["input"] := Hwnd
				AssertTrue(ControlGetHwnd("Edit1", "ahk_id " . Hwnd), "the production AddArgument event must open an actual native InputBox")
				Mode := State["mode"]
				if Mode == "cancel-button"
					_PPMO_Click(State["picker"], "Button4")
				else if Mode == "close"
					PostMessage(0x10, 0, 0, , "ahk_id " . State["picker"])
				else if Mode == "escape" {
					; The native dialog manager sends IDCANCEL for Gui Escape.
					; Exercise that dispatcher even while InputBox owns its modal loop.
					PostMessage(0x111, 2, 0, , "ahk_id " . State["picker"])
				}
				else if Mode == "save"
					_PPMO_Click(State["picker"], "Button3")
				State["phase"] := Mode == "live" || Mode == "input-cancel" ? "answer" : "retire"
				return
			}
		} else if State["phase"] == "retire" {
			if WMHandleExists(State["picker"])
				return
			AssertTrue(WMHandleExists(State["input"]), "the real InputBox must outlive its destroyed picker before returning")
			State["retired_while_modal"] := true
			State["phase"] := "answer"
		} else if State["phase"] == "answer" {
			ControlSetText("new literal argument", "Edit1", "ahk_id " . State["input"])
			PostMessage(0x111, State["mode"] == "input-cancel" ? 2 : 1, 0, , "ahk_id " . State["input"])
			State["phase"] := "complete"
		} else if State["phase"] == "complete" {
			if WMHandleExists(State["input"])
				return
			if State["mode"] == "live" || State["mode"] == "input-cancel" {
				State["observed_count"] := SendMessage(0x18B, 0, 0, "ListBox1", "ahk_id " . State["picker"])
				_PPMO_Click(State["picker"], "Button3")
			}
			State["phase"] := "done"
		}
	} catch as Err {
		State["failure"] := Err
		; Fixture-owned native windows only; no process, clipboard or input output.
		_PPMO_Release(State)
	}
}

_PPMO_Case(Mode) {
	global _UserProgramEntries
	AssertTrue(ProgramActions_Available(), "the actual native fallback availability contract must be admitted")
	AssertTrue(ProgramActions_BindingSupported("gesture__tap_3"))
	Scalar := '{"version":1,"executable":"C:\\private\\program.exe","arguments":["kept argument"]}'
	AssertTrue(ProgramParameterParse(Scalar) is Map, "the independently authored initial descriptor must really parse")
	PreviousCritical := Critical("Off"), PreviousSuspend := A_IsSuspended
	Label := "Private program picker " . Mode . " " . A_TickCount
	State := Map("mode", Mode, "phase", "open", "picker", 0, "input", 0, "errors", [], "failure", 0,
		"retired_while_modal", false, "observed_count", -1, "started", A_TickCount,
		"label", Label, "title", WindowTitle(Label))
	Timer := _PPMO_Pump.Bind(State), ErrorFn := _PPMO_Unhandled.Bind(State)
	BeforeEntries := _UserProgramEntries.Count
	try {
		Suspend(false)
		OnError(ErrorFn, -1)
		SetTimer(Timer, 10)
		Result := _GesturePickProgram("gesture__tap_3", "run_program", Label, Scalar)
		SetTimer(Timer, 0)
		if IsObject(State["failure"])
			throw State["failure"]
		AssertTrue(State["picker"] && State["input"], "both actual native windows must have been observed")
		if State["errors"].Length
			AssertEqual(0, State["errors"].Length, "the retired AddArgument callback raised: " . State["errors"][1].Message)
		AssertEqual(0, State["errors"].Length, "no callback exception may be hidden by the native pump")
		AssertFalse(WMHandleExists(State["picker"]), "the exact picker must retire")
		AssertFalse(WMHandleExists(State["input"]), "its argument modal must finish too")
		AssertEqual(BeforeEntries, _UserProgramEntries.Count, "collecting a candidate never launches or registers a program")
		if Mode == "live" || Mode == "input-cancel" || Mode == "save" {
			AssertTrue(Result is Map && Result["has_value"], "a genuine Save retains the existing candidate API")
			AssertEqual("gesture__tap_3__run_program", Result["key"])
			Parsed := ProgramParameterParse(Result["value"])
			AssertTrue(Parsed is Map)
			AssertEqual("C:\private\program.exe", Parsed["executable"])
			AssertEqual(Mode == "live" ? 2 : 1, Parsed["arguments"].Length)
			AssertEqual("kept argument", Parsed["arguments"][1])
			if Mode == "live"
				AssertEqual("new literal argument", Parsed["arguments"][2])
			if Mode != "save"
				AssertEqual(Mode == "live" ? 2 : 1, State["observed_count"], "the actual current ListBox tracks only accepted arguments")
		} else
			AssertFalse(Result, "retired cancel/Close/Escape keeps the original false candidate receipt")
		if Mode != "live" && Mode != "input-cancel"
			AssertTrue(State["retired_while_modal"], "retirement must precede the old InputBox's successful return")
	} finally {
		SetTimer(Timer, 0)
		OnError(ErrorFn, 0)
		_PPMO_Release(State)
		Suspend(PreviousSuspend), Critical(PreviousCritical)
	}
}

for _PPMO_Mode in ["live", "input-cancel", "cancel-button", "close", "escape", "save"]
	Test("program picker: argument InputBox returns after " . _PPMO_Mode . " ownership (program-picker-modal-owner)", _PPMO_Case.Bind(_PPMO_Mode))
