; tests/fixtures/spotlight_coordinate_owner_body.ahk

; ==============================================================================
; MODULE: Spotlight Native Coordinate Timer Fixture
; DESCRIPTION:
; Measures a real foreground GUI client origin and stationary physical pointer.
; A passive callback delegates the whole original tick on actual timer delivery.
; This observes HWND lifetime, not rendered pixels, DPI or hotkey delivery.
; ==============================================================================

#Requires AutoHotkey v2.0

global _SPCC_Seen := {Calls: 0, Done: false, Failure: 0, Receipt: 0, Windows: [],
	BeforeActive: false, AfterActive: false, Generation: 0, SameSession: false, SameWindows: false,
	Mode: "", BeforePointer: 0, AfterPointer: 0, BeforeCursor: 0, AfterCursor: 0,
	BeforeForeground: 0, AfterForeground: 0, BeforeLive: false, AfterLive: false,
	ElapsedBefore: -1, ElapsedAfter: -1, StartedTick: 0}
global _SPCC_OriginalMode := A_CoordModeMouse
if A_Args[1] == "screen-control"
	CoordMode("Mouse", "Screen")

_SPCC_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_SPCC_Error(Failure, Mode) {
	global _SPCC_Seen
	if !IsObject(_SPCC_Seen.Failure)
		_SPCC_Seen.Failure := Failure
	return true
}

_SPCC_Cursor() {
	Point := Buffer(8, 0)
	if !DllCall("User32\GetCursorPos", "Ptr", Point, "Int")
		throw OSError(A_LastError, -1, "GetCursorPos")
	return Map("x", NumGet(Point, 0, "Int"), "y", NumGet(Point, 4, "Int"))
}

_SPCC_SamePoint(Left, Right) {
	return Left is Map && Right is Map && Left["x"] == Right["x"] && Left["y"] == Right["y"]
}

_SPCC_Live(Windows) {
	if Windows.Length == 0
		return false
	for Hwnd in Windows {
		if !DllCall("User32\IsWindow", "Ptr", Hwnd, "Int")
			return false
	}
	return true
}

; The genuine SetTimer registration targets this wrapper. Main never calls it.
; Stop after the first completed delivery freezes that observation for Main.
_SpotlightTick() {
	global _SPCC_Seen, _Spotlight_State
	_SPCC_Seen.Calls += 1
	try {
		_SPCC_Seen.Mode := A_CoordModeMouse
		_SPCC_Seen.BeforePointer := MCGetPosStrict()
		_SPCC_Seen.BeforeCursor := _SPCC_Cursor()
		_SPCC_Seen.BeforeForeground := DllCall("User32\GetForegroundWindow", "Ptr")
		_SPCC_Seen.BeforeActive := _Spotlight_State["Phase"] == "active" && _Spotlight_State["Active"]
		_SPCC_Seen.Generation := _Spotlight_State["Generation"]
		_SPCC_Seen.Receipt := _Spotlight_State["Session"]
		if _SPCC_Seen.Receipt is Map
			_SPCC_Seen.Windows := _SPCC_Seen.Receipt["windows"].Clone()
		_SPCC_Seen.BeforeLive := _SPCC_Live(_SPCC_Seen.Windows)
		_SPCC_Seen.StartedTick := _Spotlight_State["StartedTick"]
		_SPCC_Seen.ElapsedBefore := A_TickCount - _SPCC_Seen.StartedTick
		_SPCC_ActualTick()
		_SPCC_Seen.AfterActive := _Spotlight_State["Phase"] == "active" && _Spotlight_State["Active"]
		_SPCC_Seen.SameSession := _Spotlight_State["Session"] is Map
			&& ObjPtr(_Spotlight_State["Session"]) == ObjPtr(_SPCC_Seen.Receipt)
			&& _Spotlight_State["Generation"] == _SPCC_Seen.Generation
		_SPCC_Seen.SameWindows := _SPCC_Seen.SameSession
			&& _Spotlight_State["Session"]["windows"].Length == _SPCC_Seen.Windows.Length
		if _SPCC_Seen.SameWindows {
			for Index, Hwnd in _SPCC_Seen.Windows {
				if _Spotlight_State["Session"]["windows"][Index] != Hwnd
					_SPCC_Seen.SameWindows := false
			}
		}
		_SPCC_Seen.AfterLive := _SPCC_Live(_SPCC_Seen.Windows)
		_SPCC_Seen.AfterPointer := MCGetPosStrict()
		_SPCC_Seen.AfterCursor := _SPCC_Cursor()
		_SPCC_Seen.AfterForeground := DllCall("User32\GetForegroundWindow", "Ptr")
		_SPCC_Seen.ElapsedAfter := A_TickCount - _SPCC_Seen.StartedTick
	} catch Any as Failure {
		if !IsObject(_SPCC_Seen.Failure)
			_SPCC_Seen.Failure := Failure
	} finally {
		try _SpotlightSessionTimerNative.Stop()
		catch Any as Failure {
			if !IsObject(_SPCC_Seen.Failure)
				_SPCC_Seen.Failure := Failure
		}
		_SPCC_Seen.Done := true
	}
}

_SPCC_Run() {
	global _SPCC_Seen, _SPCC_OriginalMode, _Spotlight_State
	global _SpotlightSessionCleanupDebt, _SpotlightPaintCleanupDebt, _GRBitmapCleanupDebt
	Primary := 0, Host := 0, HostHwnd := 0, Target := 0, OriginalPointer := 0, Generation := 0
	PreviousForeground := DllCall("User32\GetForegroundWindow", "Ptr")
	PreviousSuspended := A_IsSuspended
	PreviousCritical := Critical("Off")
	OnError(_SPCC_Error)
	try {
		_SPCC_Require(A_Args.Length == 2, "The child requires its exact mode and owned directory")
		Mode := A_Args[1]
		_SPCC_Require(Mode == "screen-control" || Mode == "default-client-offset", "Unknown coordinate mode")
		Desired := Mode == "screen-control" ? "Screen" : "Client"
		_SPCC_Require(_SPCC_OriginalMode == "Client" && A_CoordModeMouse == Desired,
			"PREREQUISITE: actual startup mouse mode must be Client; the control changes it to Screen")
		_SPCC_Require(!A_IsSuspended, "PREREQUISITE: child must start unsuspended")
		OriginalPointer := MCGetPosStrict()
		MonitorGetWorkArea(MonitorGetPrimary(), &Left, &Top, &Right, &Bottom)
		_SPCC_Require(Right - Left > 400 && Bottom - Top > 300, "PREREQUISITE: private GUI needs actual work area")
		Host := Gui("-Caption +ToolWindow -DPIScale", "Spotlight coordinate private owner")
		HostHwnd := Host.Hwnd
		Host.Show("x" . (Left + 120) . " y" . (Top + 100) . " w200 h140")
		WinActivate("ahk_id " . HostHwnd)
		_SPCC_Require(WinWaitActive("ahk_id " . HostHwnd, , 1)
			&& DllCall("User32\GetForegroundWindow", "Ptr") == HostHwnd,
			"PREREQUISITE: the exact private GUI must become native foreground")
		Origin := Buffer(8, 0)
		_SPCC_Require(DllCall("User32\ClientToScreen", "Ptr", HostHwnd, "Ptr", Origin, "Int"),
			"PREREQUISITE: the native client origin must be measurable")
		OriginX := NumGet(Origin, 0, "Int"), OriginY := NumGet(Origin, 4, "Int")
		_SPCC_Require(Abs(OriginX) > 5 || Abs(OriginY) > 5,
			"PREREQUISITE: actual client origin must differ from screen coordinates by more than five pixels")
		Target := Map("x", OriginX + 90, "y", OriginY + 70)
		_SPCC_Require(DllCall("User32\SetPhysicalCursorPos", "Int", Target["x"], "Int", Target["y"], "Int"),
			"PREREQUISITE: the native pointer must enter the private GUI")
		_SPCC_Require(_SPCC_SamePoint(Target, MCGetPosStrict()) && _SPCC_SamePoint(Target, _SPCC_Cursor()),
			"PREREQUISITE: actual physical and logical screen cursor readings must agree at this target")
		_SPCC_Require(SpotlightMouseAt(Target["x"], Target["y"], 3000),
			"PREREQUISITE: the genuine public entry must create and publish its native overlay")
		Generation := _Spotlight_State["Generation"]
		Started := A_TickCount
		while !_SPCC_Seen.Done && A_TickCount - Started < 1500
			Sleep(10)
		if IsObject(_SPCC_Seen.Failure)
			throw _SPCC_Seen.Failure
		_SPCC_Require(_SPCC_Seen.Done && _SPCC_Seen.Calls == 1,
			"PREREQUISITE: one genuine native timer delivery must complete")
		_SPCC_Require(_SPCC_Seen.Mode == Desired && _SPCC_Seen.BeforeActive && _SPCC_Seen.BeforeLive
			&& _SPCC_Seen.Generation == Generation && _SPCC_Seen.Receipt is Map,
			"PREREQUISITE: the delivered timer must observe the intended mode and actual admitted session")
		_SPCC_Require(_SPCC_Seen.ElapsedBefore >= 0 && _SPCC_Seen.ElapsedBefore < 1500
			&& _SPCC_Seen.ElapsedAfter >= _SPCC_Seen.ElapsedBefore && _SPCC_Seen.ElapsedAfter < 3000,
			"PREREQUISITE: delivery must precede the genuine overlay deadline")
		_SPCC_Require(_SPCC_Seen.BeforeForeground == HostHwnd && _SPCC_Seen.AfterForeground == HostHwnd
			&& DllCall("User32\GetForegroundWindow", "Ptr") == HostHwnd,
			"PREREQUISITE: the private GUI must remain foreground throughout the actual tick")
		_SPCC_Require(_SPCC_SamePoint(Target, _SPCC_Seen.BeforePointer)
			&& _SPCC_SamePoint(Target, _SPCC_Seen.AfterPointer)
			&& _SPCC_SamePoint(Target, _SPCC_Seen.BeforeCursor)
			&& _SPCC_SamePoint(Target, _SPCC_Seen.AfterCursor) && _SPCC_SamePoint(Target, MCGetPosStrict()),
			"PREREQUISITE: actual physical and screen pointers must stay stationary through delivery")
		FileAppend("OBS mode=" . Mode . " timer_mode=" . _SPCC_Seen.Mode . " calls=" . _SPCC_Seen.Calls
			. " client_origin_x=" . OriginX . " client_origin_y=" . OriginY
			. " pointer_x=" . Target["x"] . " pointer_y=" . Target["y"]
			. " elapsed_before=" . _SPCC_Seen.ElapsedBefore . " elapsed_after=" . _SPCC_Seen.ElapsedAfter
			. " generation=" . Generation
			. " windows=" . _SPCC_Seen.Windows.Length . " before_active=" . _SPCC_Seen.BeforeActive
			. " before_live=" . _SPCC_Seen.BeforeLive . " after_active=" . _SPCC_Seen.AfterActive
			. " after_live=" . _SPCC_Seen.AfterLive . " same_session=" . _SPCC_Seen.SameSession
			. " same_windows=" . _SPCC_Seen.SameWindows . "`n", "*", "UTF-8")
		_SPCC_Require(_SPCC_Seen.AfterActive && _SPCC_Seen.SameSession && _SPCC_Seen.SameWindows && _SPCC_Seen.AfterLive,
			"A stationary physical pointer must retain its exact Spotlight overlay after native timer delivery")
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			_SpotlightSessionTimerNative.Stop()
			if Generation
				_SpotlightDismiss(Generation)
			SessionReleased := _SpotlightSessionDrainDebt()
			PaintReleased := _SpotlightPaintDrainDebt()
			BitmapReleased := _GRBitmapDrainDebt()
			_SPCC_Require(SessionReleased && PaintReleased && BitmapReleased, "Native Spotlight cleanup debt must settle")
			_SPCC_Require(_GRBitmapCleanupDebt.Length == 0 && _SpotlightSessionCleanupDebt.Length == 0
				&& _SpotlightPaintCleanupDebt.Length == 0, "All native graphics debt must retire")
			for Hwnd in _SPCC_Seen.Windows
				_SPCC_Require(!DllCall("User32\IsWindow", "Ptr", Hwnd, "Int"), "Every exact overlay HWND must retire")
			if _SPCC_Seen.Receipt is Map
				_SPCC_Require(_SPCC_Seen.Receipt["windows"].Length == 0 && !_SPCC_Seen.Receipt["token"]
					&& !_SPCC_Seen.Receipt["module"], "The exact native session must relinquish every resource")
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try {
			if Target is Map && OriginalPointer is Map && _SPCC_SamePoint(Target, MCGetPosStrict()) {
				_SPCC_Require(DllCall("User32\SetPhysicalCursorPos", "Int", OriginalPointer["x"],
					"Int", OriginalPointer["y"], "Int"), "The exact fixture-owned pointer must restore")
				_SPCC_Require(_SPCC_SamePoint(OriginalPointer, MCGetPosStrict()), "The pointer restoration must be observed")
			}
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try {
			if HostHwnd && DllCall("User32\GetForegroundWindow", "Ptr") == HostHwnd
					&& PreviousForeground && DllCall("User32\IsWindow", "Ptr", PreviousForeground, "Int") {
				WinActivate("ahk_id " . PreviousForeground)
				_SPCC_Require(WinWaitActive("ahk_id " . PreviousForeground, , 1), "The exact prior foreground must restore")
			}
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try {
			if IsObject(Host) {
				Host.Destroy()
				_SPCC_Require(!DllCall("User32\IsWindow", "Ptr", HostHwnd, "Int"), "The exact private GUI must retire")
			}
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try {
			CoordMode("Mouse", _SPCC_OriginalMode)
			Suspend(PreviousSuspended)
			_SPCC_Require(A_CoordModeMouse == _SPCC_OriginalMode && A_IsSuspended == PreviousSuspended,
				"The actual mouse mode and native Suspend state must restore")
			OnError(_SPCC_Error, 0)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		} finally Critical(PreviousCritical)
	}
	if IsObject(_SPCC_Seen.Failure) && !IsObject(Primary)
		Primary := _SPCC_Seen.Failure
	if IsObject(Primary)
		throw Primary
	FileAppend("PASS spotlight-coordinate-owner " . A_Args[1] . "`n", "*", "UTF-8")
}

try {
	_SPCC_Run()
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL spotlight-coordinate-owner " . Failure.Message . " [" . Failure.File . ":" . Failure.Line . "]`n"
		. Failure.Stack . "`n", "*", "UTF-8")
	ExitApp(1)
}
