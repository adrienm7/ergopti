; tests/unit/test_foreground_keyboard_layout.ahk

; ==============================================================================
; MODULE: Foreground keyboard layout follows the focused control
; DESCRIPTION:
; GetForegroundKeyboardLayout read the layout of the foreground window's own
; thread. In a UWP app that window is the ApplicationFrameHost frame, while the
; focused CoreWindow runs on the app's thread, which may hold another layout.
; AutoHotkey's Send and hook resolve AltGr from the focused control's thread
; (keyboard_mouse.cpp GetFocusedCtrlThread), so the driver could decide the
; AltGr family, and poll for layout switches, on a layout the user was not
; typing with (focused-thread-hkl-2026-09-26). The cases drive the resolver
; through its port, so no window or keyboard state is involved.
; ==============================================================================

#Requires AutoHotkey v2.0

; A port where window Frame (thread 10, layout 0x0409) holds the foreground and
; its focused control is FocusHwnd; windows 7 and 8 belong to threads 10 and 20,
; whose layouts are 0x0409 and 0xFC06040C.
_FKL_Port(FocusHwnd, Frame := 7) {
	Threads := Map(7, 10, 8, 20)
	Layouts := Map(10, 0x0409, 20, 0xFC06040C)
	return Map(
		"foreground", () => Frame,
		"thread_of", (Hwnd) => Threads.Get(Hwnd, 0),
		"focus_of", (Tid) => FocusHwnd,
		"layout_of", (Tid) => Layouts.Get(Tid, 0))
}

_FKL_FocusedControlThreadWins() {
	AssertEqual(0xFC06040C, GetForegroundKeyboardLayout(_FKL_Port(8)),
		"a focused control on another thread (a UWP app's CoreWindow) must give that thread's layout")
}
Test("foreground layout: the focused control's thread decides the layout (focused-thread-hkl-2026-09-26)",
	_FKL_FocusedControlThreadWins)

_FKL_NoFocusKeepsTheTopLevelThread() {
	AssertEqual(0x0409, GetForegroundKeyboardLayout(_FKL_Port(0)),
		"without a focused control (or when GetGUIThreadInfo fails) the foreground window's thread decides")
	AssertEqual(0x0409, GetForegroundKeyboardLayout(_FKL_Port(7)),
		"a focused control on the frame's own thread gives the same layout")
}
Test("foreground layout: no focused control keeps the top-level thread (focused-thread-hkl-2026-09-26)",
	_FKL_NoFocusKeepsTheTopLevelThread)

_FKL_NoForegroundWindowIsZero() {
	AssertEqual(0, GetForegroundKeyboardLayout(_FKL_Port(8, 0)),
		"no foreground window must stay 0 for the callers' fallbacks")
}
Test("foreground layout: no foreground window gives 0 (focused-thread-hkl-2026-09-26)",
	_FKL_NoForegroundWindowIsZero)

_FKL_KeyloggerUsesTheOneResolver() {
	Body := _DriverFuncBody("KLPF_KeycodeLayout")
	Assert(Body != "", "KLPF_KeycodeLayout must exist")
	AssertTrue(InStr(Body, "KS_ResolveKeyboardLayout()") > 0,
		"the keylogger heatmap must resolve its layout through the driver's one resolver")
	AssertFalse(InStr(Body, "GetForegroundWindow") > 0,
		"the keylogger heatmap must not keep its own foreground-thread lookup")
}
Test("foreground layout: the keylogger heatmap reads the one resolver (focused-thread-hkl-2026-09-26)",
	_FKL_KeyloggerUsesTheOneResolver)
