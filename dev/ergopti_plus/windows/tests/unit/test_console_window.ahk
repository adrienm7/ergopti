; tests/unit/test_console_window.ahk

; ==============================================================================
; MODULE: Native Debug Console Placement Tests
; DESCRIPTION:
; Debug actions must place their owned window from the shared geometry instead
; of moving whichever application happens to have foreground focus.
; ==============================================================================

#Requires AutoHotkey v2.0

class _ConsoleTestNative {
	static Calls := []
	static Rect := 0
	static RefuseMove := false
	static RefuseOpen := false
	static RefuseActivate := false
	static ThrowFrame := false
	static Reset() {
		this.Calls := []
		this.Rect := {x: 10, y: 20, w: 300, h: 200}
		this.RefuseMove := false
		this.RefuseOpen := false
		this.RefuseActivate := false
		this.ThrowFrame := false
	}
	static Open(Kind) {
		this.Calls.Push(Kind)
		return !this.RefuseOpen
	}
	static Frame(Hwnd) {
		AssertEqual(A_ScriptHwnd, Hwnd, "placement must target the script window")
		if this.ThrowFrame
			throw Error("Console is no longer available.")
		return this.Rect
	}
	static Screen() {
		return {x: 100, y: 50, w: 1000, h: 800}
	}
	static Move(Hwnd, Rect) {
		AssertEqual(A_ScriptHwnd, Hwnd, "moving another application is forbidden")
		this.Calls.Push("move")
		if this.RefuseMove
			return false
		this.Rect := Rect
		return true
	}
	static Activate(Hwnd) {
		AssertEqual(A_ScriptHwnd, Hwnd, "only the owned debug window may activate")
		this.Calls.Push("activate")
		return !this.RefuseActivate
	}
}

_ConsoleTest_OpensAndPlaces() {
	for Kind in ["list_vars", "key_history"] {
		_ConsoleTestNative.Reset()
		AssertTrue(ConsoleWindow_Open(Kind, _ConsoleTestNative), "accepted placement succeeds")
		AssertEqual(Kind, _ConsoleTestNative.Calls[1], "the requested view opens first")
		AssertEqual(700, _ConsoleTestNative.Rect.w, "width follows shared ratio")
		AssertEqual(600, _ConsoleTestNative.Rect.h, "height follows shared ratio")
		AssertEqual(250, _ConsoleTestNative.Rect.x, "centering includes screen origin")
		AssertEqual(150, _ConsoleTestNative.Rect.y, "centering includes screen origin")
		AssertEqual("activate", _ConsoleTestNative.Calls[3], "the placed view comes forward")
	}
}
Test("Console: both debug views use owned centered geometry (native-console)", _ConsoleTest_OpensAndPlaces)

_ConsoleTest_PreservesLargeWindow() {
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.Rect := {x: 12, y: 34, w: 900, h: 700}
	AssertTrue(ConsoleWindow_Open("list_vars", _ConsoleTestNative), "large console opens")
	AssertEqual(2, _ConsoleTestNative.Calls.Length, "large window is not moved")
	AssertEqual(12, _ConsoleTestNative.Rect.x, "user placement remains intact")
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.Rect.w := 900
	AssertTrue(ConsoleWindow_Open("key_history", _ConsoleTestNative), "short console grows")
	AssertEqual(900, _ConsoleTestNative.Rect.w, "larger dimension must not shrink")
	AssertEqual(600, _ConsoleTestNative.Rect.h, "short dimension reaches minimum")
}
Test("Console: large dimensions and placement survive (native-console)", _ConsoleTest_PreservesLargeWindow)

_ConsoleTest_RefusesFailedPlacement() {
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.RefuseMove := true
	AssertFalse(ConsoleWindow_Open("list_vars", _ConsoleTestNative), "refused move is not success")
	AssertEqual(2, _ConsoleTestNative.Calls.Length, "refused placement does not activate")
}
Test("Console: native refusal stays observable (native-console)", _ConsoleTest_RefusesFailedPlacement)

_ConsoleTest_RejectsIncompleteOpen() {
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.RefuseOpen := true
	AssertFalse(ConsoleWindow_Open("list_vars", _ConsoleTestNative), "opening refusal is not success")
	AssertEqual(1, _ConsoleTestNative.Calls.Length, "refused opening must not move or activate")
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.ThrowFrame := true
	AssertFalse(ConsoleWindow_Open("key_history", _ConsoleTestNative), "a disappeared window is not success")
	AssertEqual(1, _ConsoleTestNative.Calls.Length, "a disappeared window must not move or activate")
	_ConsoleTestNative.Reset()
	_ConsoleTestNative.RefuseActivate := true
	AssertFalse(ConsoleWindow_Open("key_history", _ConsoleTestNative), "activation refusal is not success")
	AssertEqual(3, _ConsoleTestNative.Calls.Length, "activation was actually attempted")
	_ConsoleTestNative.Reset()
	AssertFalse(ConsoleWindow_Open("foreign_window", _ConsoleTestNative), "an unknown view must be refused")
	AssertEqual(0, _ConsoleTestNative.Calls.Length, "an unknown view never reaches the native boundary")
}
Test("Console: native failures and invalid views are refused (native-console)", _ConsoleTest_RejectsIncompleteOpen)
