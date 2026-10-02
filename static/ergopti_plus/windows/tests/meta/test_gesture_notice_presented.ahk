; tests/meta/test_gesture_notice_presented.ahk

; ==============================================================================
; MODULE: Gesture Conflict Notice Is Presented, Never Lost
; DESCRIPTION:
; The touchpad conflict notice holds the reload that applies a gesture
; assignment until the user answers it. It used to be AlwaysOnTop and opened
; without activation; once it became an ordinary window, the next click in
; another app covered it, and a second request for the same group returned
; without showing anything, so the assignment never took effect. The notice
; must be focused when it opens and presented again when it is requested
; while open (ui-focus-not-topmost).
;
; SCOPE: source introspection. Opening the notice shows and focuses a real
; window, which the headless runner may not do; the present helper itself is
; exercised in tests/unit/test_window_manager_present_window.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

_MetaGestureNoticePresented() {
	Body := _DriverFuncBody("GestureSystemNotice")
	Assert(Body != "", "GestureSystemNotice must exist in ui/gesture_conflicts.ahk")

	OpenPos := InStr(Body, 'if State["windows"].Has(Group) {')
	PresentPos := InStr(Body, 'WMPresentWindow(State["windows"][Group])', , Max(OpenPos, 1))
	ReturnPos := InStr(Body, "return true", , Max(PresentPos, 1))
	BuildPos := InStr(Body, "Gui_Create(")
	Assert(OpenPos > 0 && PresentPos > OpenPos && ReturnPos > PresentPos && BuildPos > ReturnPos,
		"a notice requested again while open must be presented before the early return")

	Assert(InStr(Body, "G.Show()") > 0, "the notice must be shown and focused when it opens")
	Assert(!InStr(Body, "NoActivate"),
		"the notice must not open inactive: as an ordinary window it is covered by the next click")
	Assert(!InStr(Body, "AlwaysOnTop"), "the notice must never be kept on top")
}
Test("gesture notice: focused on open and presented when requested again (ui-focus-not-topmost)",
	_MetaGestureNoticePresented)
