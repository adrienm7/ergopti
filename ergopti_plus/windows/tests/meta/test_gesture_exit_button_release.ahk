; tests/meta/test_gesture_exit_button_release.ahk

; ==============================================================================
; MODULE: Gesture Exit Button Release Meta Test
; DESCRIPTION:
; Static source guard for HIGH-03: fix-gesture-exit-button-release.
;
; GestureToggleLeftClick / GestureToggleRightClick inject a physical button-down
; via Click("Left","Down") / Click("Right","Down") and store the held state in
; GestureLeftClickHeld / GestureRightClickHeld. Every release path is in-process
; (InputHook key-watcher, HookDispatcher cross-release, next GestureDispatch).
;
; None of those paths run during process exit. If a Reload (e.g. on config change
; or tray-menu Reload) or ExitApp triggers while a hold is active, the old
; _GestureUnhook handler only freed the WinEvent hook and the thunk — it never
; issued the matching Click(...,"Up"), so the physical OS button stays stuck down
; system-wide. The desktop behaves as if the user is dragging; only pressing the
; physical button recovers.
;
; The fix extends _GestureUnhook to call GestureReleaseLeftClick() and
; GestureReleaseRightClick() (both try-wrapped so the handler never throws)
; before tearing down the WinEvent hook.
;
; This test asserts that _GestureUnhook source body references both release
; calls, encoding the root cause: held buttons must be released at exit.
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Test implementations ==================
; ==================================================
; ==================================================

_GEBR_CheckExitButtonRelease() {
	UnhookBody := _DriverFuncBody("_GestureUnhook")
	Assert(UnhookBody != "",
		"_GestureUnhook function must be present in modules/gestures.ahk")

	; The exit handler must call GestureReleaseLeftClick before teardown.
	Assert(InStr(UnhookBody, "GestureReleaseLeftClick()"),
		"_GestureUnhook must call GestureReleaseLeftClick() to release a held left button on exit (HIGH-03)")

	; The exit handler must call GestureReleaseRightClick before teardown.
	Assert(InStr(UnhookBody, "GestureReleaseRightClick()"),
		"_GestureUnhook must call GestureReleaseRightClick() to release a held right button on exit (HIGH-03)")

	; Both calls must be wrapped in try so the handler never throws and leaves
	; the WinEvent thunk dangling.
	Assert(InStr(UnhookBody, "try GestureReleaseLeftClick()"),
		"GestureReleaseLeftClick() call in _GestureUnhook must be try-wrapped to prevent exit hang")
	Assert(InStr(UnhookBody, "try GestureReleaseRightClick()"),
		"GestureReleaseRightClick() call in _GestureUnhook must be try-wrapped to prevent exit hang")

	; The release calls must appear BEFORE native ownership retirement so we do
	; not emit Click events after the hook is gone. The helper's refusal behavior
	; is exercised directly by the ahk-126 unit test.
	LeftReleasePos  := InStr(UnhookBody, "try GestureReleaseLeftClick()")
	RetireOwnerPos  := InStr(UnhookBody, "_GestureReleaseWinHook()")
	Assert(LeftReleasePos > 0 && RetireOwnerPos > 0
			&& LeftReleasePos < RetireOwnerPos,
		"GestureReleaseLeftClick() must run before gesture WinEvent ownership retirement")
}


Test("meta fix-gesture-exit-button-release: _GestureUnhook releases held mouse buttons before teardown",
	_GEBR_CheckExitButtonRelease)
