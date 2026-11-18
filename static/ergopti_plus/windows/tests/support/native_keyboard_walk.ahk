; tests/support/native_keyboard_walk.ahk

; ==============================================================================
; MODULE: Native Keyboard Walk
; DESCRIPTION:
; Walks a native driver window with Tab, then back with Shift+Tab, the way a
; keyboard user does (WCAG 2.1.1, 2.1.2, 2.4.3). The keys are posted to the
; focused control of this thread's own window, so AutoHotkey's message loop
; and the dialog manager handle them as they handle a real key (a WantTab
; edit keeps the Tab, a control without a tab stop is skipped), and no key
; reaches another program. Shift is set in this thread's keyboard state only.
; The window stays off screen and without the activation it would take from
; the desktop; every window the capture shows is closed before it returns.
; ==============================================================================

#Requires AutoHotkey v2.0

; Classes of the controls a keyboard user must be able to reach. Labels,
; pictures, progress bars, separators, up-down buddies and status bars take no
; focus by design and are not listed.
global NATIVE_WALK_FOCUSABLE_CLASSES := Map("Button", true, "Edit", true, "ComboBox", true,
	"ListBox", true, "SysListView32", true, "SysTreeView32", true, "msctls_trackbar32", true,
	"SysLink", true, "SysDateTimePick32", true, "SysMonthCal32", true, "msctls_hotkey32", true,
	"SysTabControl32", true, "RICHEDIT50W", true)
; Button styles (the low nibble of the window style) that take no focus or
; share one stop with their group.
global NATIVE_WALK_BS_GROUPBOX := 0x7
global NATIVE_WALK_BS_RADIO := Map(0x4, true, 0x9, true)
global NATIVE_WALK_WS_GROUP := 0x20000
; Where a captured window is shown: far outside every monitor.
global NATIVE_WALK_OFFSCREEN := "x-32000 y-32000"

; The window's reachable stops in z-order: each focusable visible enabled
; control, and one stop per radio group (the dialog manager tabs to the group).
; @param GuiObj {Gui}
; @returns {Array} Maps ("hwnds" [members], "label").
NativeWalk_ExpectedStops(GuiObj) {
	Stops := []
	Group := 0
	Child := DllCall("GetWindow", "Ptr", GuiObj.Hwnd, "UInt", 5, "Ptr")   ; GW_CHILD
	while Child {
		Class := WinGetClass("ahk_id " . Child)
		Style := WinGetStyle("ahk_id " . Child)
		Usable := NATIVE_WALK_FOCUSABLE_CLASSES.Has(Class)
			&& DllCall("IsWindowVisible", "Ptr", Child) && DllCall("IsWindowEnabled", "Ptr", Child)
		Kind := Style & 0xF
		if Usable && Class == "Button" && Kind == NATIVE_WALK_BS_GROUPBOX
			Usable := false
		if Usable {
			Label := Class . " « " . ControlGetText(Child) . " »"
			if Class == "Button" && NATIVE_WALK_BS_RADIO.Has(Kind) {
				if !IsObject(Group) || (Style & NATIVE_WALK_WS_GROUP) {
					Group := Map("hwnds", [], "label", "radio group " . Label)
					Stops.Push(Group)
				}
				Group["hwnds"].Push(Child)
			} else {
				Group := 0
				Stops.Push(Map("hwnds", [Child], "label", Label))
			}
		} else if !(Class == "Button" && NATIVE_WALK_BS_RADIO.Has(Kind)) {
			Group := 0
		}
		Child := DllCall("GetWindow", "Ptr", Child, "UInt", 2, "Ptr")   ; GW_HWNDNEXT
	}
	return Stops
}

; The direct child of Window that holds Hwnd (a combo box's inner edit counts
; as its combo box), 0 when Hwnd is outside Window.
_NativeWalk_TopChild(Window, Hwnd) {
	while Hwnd {
		Parent := DllCall("GetAncestor", "Ptr", Hwnd, "UInt", 1, "Ptr")   ; GA_PARENT
		if Parent == Window
			return Hwnd
		Hwnd := Parent
	}
	return 0
}

; Posts one Tab (or Shift+Tab) to the focused control and lets this thread's
; message loop handle it.
_NativeWalk_Press(Focused, Backward) {
	State := Buffer(256, 0)
	if Backward {
		DllCall("GetKeyboardState", "Ptr", State)
		Saved := NumGet(State, 0x10, "UChar")
		NumPut("UChar", 0x80, State, 0x10)                 ; VK_SHIFT down
		DllCall("SetKeyboardState", "Ptr", State)
	}
	try {
		PostMessage(0x100, 0x09, 0x000F0001, Focused)      ; WM_KEYDOWN VK_TAB
		PostMessage(0x101, 0x09, 0xC00F0001, Focused)      ; WM_KEYUP VK_TAB
		Sleep(-1)
	} finally {
		if Backward {
			NumPut("UChar", Saved, State, 0x10)
			DllCall("SetKeyboardState", "Ptr", State)
		}
	}
}

; One direction of the walk from the first stop: the stops met in order until
; the focus comes back to the first one.
; @returns {Map} "order" (top-level hwnds met), "closed" (back at the start),
;   "stuck" (the hwnd a press could not leave, else 0), "left" (focus outside).
_NativeWalk_Direction(GuiObj, Start, Backward, Bound) {
	Result := Map("order", [Start], "closed", false, "stuck", 0, "left", false)
	DllCall("SetFocus", "Ptr", Start)
	loop Bound {
		Focused := DllCall("GetFocus", "Ptr")
		Before := _NativeWalk_TopChild(GuiObj.Hwnd, Focused)
		_NativeWalk_Press(Focused, Backward)
		After := _NativeWalk_TopChild(GuiObj.Hwnd, DllCall("GetFocus", "Ptr"))
		if !After {
			Result["left"] := true
			return Result
		}
		if After == Before {
			Result["stuck"] := Before
			return Result
		}
		if After == Start {
			Result["closed"] := true
			return Result
		}
		Result["order"].Push(After)
	}
	return Result
}

; Walks GuiObj, which must be shown, and names every keyboard failure.
; @param GuiObj {Gui}
; @returns {Map} "title", "stops" (expected count), "forward", "backward"
;   (hwnd arrays) and "problems" (an empty Array when the walk is clean).
NativeKeyboardWalk(GuiObj) {
	Title := WinGetTitle("ahk_id " . GuiObj.Hwnd)
	Stops := NativeWalk_ExpectedStops(GuiObj)
	Walk := Map("title", Title, "stops", Stops.Length, "forward", [], "backward", [], "problems", [])
	Problems := Walk["problems"]
	if Stops.Length == 0
		return Walk
	Start := DllCall("GetNextDlgTabItem", "Ptr", GuiObj.Hwnd, "Ptr", 0, "Int", 0, "Ptr")
	if !Start {
		Problems.Push(Title . ": no control takes the focus")
		return Walk
	}
	Start := _NativeWalk_TopChild(GuiObj.Hwnd, Start)
	; Every stop once, plus the press that comes back to the first.
	Bound := Stops.Length + 1
	for Direction in [false, true] {
		Name := Direction ? "Shift+Tab" : "Tab"
		Pass := _NativeWalk_Direction(GuiObj, Start, Direction, Bound)
		Walk[Direction ? "backward" : "forward"] := Pass["order"]
		if Pass["left"]
			Problems.Push(Title . ": " . Name . " moves the focus out of the window")
		else if Pass["stuck"] && Stops.Length > 1
			Problems.Push(Title . ": " . Name . " cannot leave " . _NativeWalk_Label(Pass["stuck"]) . " (keyboard trap)")
		else if !Pass["closed"] && Stops.Length > 1
			Problems.Push(Title . ": " . Name . " never comes back to the first control")
		Seen := Map()
		for Hwnd in Pass["order"] {
			if Seen.Has(Hwnd)
				Problems.Push(Title . ": " . Name . " meets " . _NativeWalk_Label(Hwnd) . " twice")
			Seen[Hwnd] := true
		}
	}
	Met := Map()
	for Hwnd in Walk["forward"]
		Met[Hwnd] := true
	for Stop in Stops {
		Reached := false
		for Hwnd in Stop["hwnds"]
			Reached := Reached || Met.Has(Hwnd)
		if !Reached
			Problems.Push(Title . ": Tab never reaches " . Stop["label"])
	}
	; Shift+Tab retraces Tab: the same stops after the first, in reverse.
	Back := Walk["backward"], Fore := Walk["forward"]
	Same := Back.Length == Fore.Length
	loop Fore.Length - 1
		Same := Same && Back[A_Index + 1] == Fore[Fore.Length - A_Index + 1]
	if !Same
		Problems.Push(Title . ": Shift+Tab does not retrace the Tab order")
	return Walk
}

_NativeWalk_Label(Hwnd) {
	return WinGetClass("ahk_id " . Hwnd) . " « " . ControlGetText(Hwnd) . " »"
}

; Whether the thread a timer interrupted is waiting (WinWaitClose, an
; InputHook or a Sleep) rather than still building its window: a control call
; such as Focus also runs timers, and closing the window there would destroy
; it under its opener. The stack names the built-in the opener waits in,
; in brackets, on the line after the timer's own frames.
_NativeWalk_OpenerWaits(Stack) {
	Lines := StrSplit(Stack, "`n", "`r")
	for Index, Line in Lines
		if Line == "> Timer"
			return Index < Lines.Length && RegExMatch(Lines[Index + 1], "\[(?:WinWaitClose|Sleep|\w+(?:\.Prototype)?\.Wait)\]")
	throw Error("The walk runs from a timer: its stack names the thread it interrupted.")
}

; Runs Open with every Gui it shows moved off screen, walks each one, closes
; it as its title bar's close button does, and returns the walks.
; A window Open waits on is walked on the first timer turn of that wait; one
; it leaves open is walked once Open returns.
; @param Open {Func} Opens one or more native windows.
; @returns {Array} The walks, one per window shown.
NativeKeyboardWalk_Capture(Open) {
	Walks := []
	Pending := []
	Shown := []
	InShow := false
	Saved := Gui.Prototype.GetOwnPropDesc("Show")
	Original := Saved.Call
	Hooked(GuiObj, Options := "") {
		Placed := RegExReplace(Options, "i)(?<!\S)(?:[xy](?:-?\d+|Center)|Center|NoActivate|Minimize|Maximize|Restore)(?!\S)", "")
		; Show pumps messages: the walk waits until the opener has gone on past it.
		InShow := true
		try Original(GuiObj, Trim(Placed) . " " . NATIVE_WALK_OFFSCREEN . " NoActivate")
		finally InShow := false
		for Known in Shown
			if Known["hwnd"] == GuiObj.Hwnd
				return
		Entry := Map("gui", GuiObj, "hwnd", GuiObj.Hwnd)
		Shown.Push(Entry)
		Pending.Push(Entry)
		SetTimer(WalkPending, -1)
	}
	; Opened is true once Open has returned: whatever it left open is walked.
	WalkPending(Opened := false) {
		if !Opened && (InShow || !_NativeWalk_OpenerWaits(Error().Stack)) {
			SetTimer(WalkPending, -1)
			return
		}
		while Pending.Length {
			Entry := Pending.RemoveAt(1)
			Hwnd := Entry["hwnd"]
			if !DllCall("IsWindow", "Ptr", Hwnd)
				continue
			Walks.Push(NativeKeyboardWalk(Entry["gui"]))
			PostMessage(0x0010, 0, 0, , "ahk_id " . Hwnd)    ; WM_CLOSE
			Sleep(-1)
		}
	}
	Gui.Prototype.DefineProp("Show", {Call: Hooked})
	try {
		Open.Call()
		WalkPending(true)
	} finally {
		SetTimer(WalkPending, 0)
		Gui.Prototype.DefineProp("Show", Saved)
		; A window whose Close only hides it is destroyed here.
		for Entry in Shown
			if DllCall("IsWindow", "Ptr", Entry["hwnd"])
				Entry["gui"].Destroy()
	}
	return Walks
}
