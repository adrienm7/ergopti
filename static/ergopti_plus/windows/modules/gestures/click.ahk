; modules/gestures/click.ahk

; ==============================================================================
; MODULE: Gesture Synthetic Click-Hold (AHK)
; DESCRIPTION:
; Owns the synthetic left/right "click-hold" subsystem: pressing and holding a
; mouse button on a gesture, and auto-releasing it on the next keystroke or the
; opposite physical click. Extracted from modules/gestures.ahk so that file keeps
; the gesture catalog and dispatch, while this module is the single owner of the
; click-hold state and its shared keyboard watcher.
;
; FEATURES & RATIONALE:
; 1. Single owner of hold state - GestureLeftClickHeld / GestureRightClickHeld and
;    the shared keyboard hook live here only, so no caller can leave a button down.
; 2. Shared-LButton safe - subscribes/unsubscribes through HookDispatcher rather
;    than bare Hotkey() calls, so the startup ~LButton/~RButton handler survives.
; 3. Suspend-aware watcher - GestureOnKeyDown releases both buttons and detaches
;    the hook when the script is suspended, so a hold never outlives a pause.
; ==============================================================================

#Requires AutoHotkey v2.0

; Click hold mode state - the single owner of the synthetic-hold flags and the
; shared keyboard hook used to auto-release them.
; Click hold mode state
global GestureLeftClickHeld  := False
global GestureRightClickHeld := False
global GestureKeyboardHook   := 0




; Activates or deactivates a left-button-held mode. Any subsequent keystroke
; (or physical left-click) automatically releases the button — typically
; firing the system's left-click action wherever the cursor is at that
; moment. Useful as a generic "press left button until I do something"
; toggle which covers context menus, drag-with-left-button workflows
; (browser gestures, 3D viewport rotation, …) and whatever else left-
; click means in the focused app, hence the broader naming over the
; previous "selection" wording.
GestureToggleLeftClick() {
	global GestureLeftClickHeld, GestureRightClickHeld

	if (GestureLeftClickHeld) {
		return GestureReleaseLeftClick()
	}

	LoggerDebug("gestures", "Enabling left-click hold mode…")
	PreviousCritical := Critical("On")
	DownAttempted := false
	try {
		; Prepare all fallible cleanup resources before the OS button is acquired
		GestureStartKeyboardWatcher()
		HookDispatcher.Register("mouse_rdown", GestureReleaseLeftClick)
		HookDispatcher.Register("mouse_ldown", GestureReleaseLeftClick)
		DownAttempted := true
		Click("Left", "Down")
		GestureLeftClickHeld := True
	} catch as e {
		; Click can fail after Windows accepted the synthetic Down. Keep every
		; recovery subscriber live until the compensating Up is known to have
		; succeeded; otherwise the driver publishes no hold and owns no retry while
		; the OS may still be dragging.
		if DownAttempted {
			try Click("Left", "Up")
			catch as cleanupError {
				GestureLeftClickHeld := True
				LoggerError("gestures", "Could not release left-click hold after setup failure; recovery ownership was retained: {1}.", cleanupError.Message)
				LoggerError("gestures", "Could not enable left-click hold mode: {1}.", e.Message)
				return false
			}
		}
		try {
			HookDispatcher.Unregister("mouse_rdown", GestureReleaseLeftClick)
		} catch as cleanupError {
			LoggerError("gestures", "Could not remove left-click right-button cleanup: {1}.", cleanupError.Message)
		}
		try {
			HookDispatcher.Unregister("mouse_ldown", GestureReleaseLeftClick)
		} catch as cleanupError {
			LoggerError("gestures", "Could not remove left-click left-button cleanup: {1}.", cleanupError.Message)
		}
		GestureLeftClickHeld := False
		if (!GestureRightClickHeld)
			GestureStopKeyboardWatcher()
		LoggerError("gestures", "Could not enable left-click hold mode: {1}.", e.Message)
		return false
	} finally {
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Left-click hold mode enabled.")
}

; Releases the left mouse button if it is currently held by the toggle.
GestureReleaseLeftClick(*) {
	global GestureLeftClickHeld, GestureRightClickHeld

    if (!GestureLeftClickHeld) {
        return true
	}

	PreviousCritical := Critical("On")
	ReleaseSucceeded := false
	try {
		LoggerDebug("gestures", "Disabling left-click hold mode…")
		try Click("Left", "Up")
		catch as e {
			LoggerError("gestures", "Could not release left-click hold; recovery ownership was retained: {1}.", e.Message)
			return false
		}
		GestureLeftClickHeld := False
		; Unsubscribe via HookDispatcher — Hotkey(…, "Off") would disable the shared
		; ~LButton/~RButton handlers that the dispatcher registered.
		try {
			HookDispatcher.Unregister("mouse_rdown", GestureReleaseLeftClick)
		} catch as e {
			LoggerError("gestures", "Could not remove left-click right-button cleanup: {1}.", e.Message)
		}
		try {
			HookDispatcher.Unregister("mouse_ldown", GestureReleaseLeftClick)
		} catch as e {
			LoggerError("gestures", "Could not remove left-click left-button cleanup: {1}.", e.Message)
		}
		ReleaseSucceeded := true
	} finally {
		; A refused Button Up retains both the held flag and its keyboard retry
		; owner. Retire the observer only after this transaction committed.
		if ReleaseSucceeded and !GestureRightClickHeld
			GestureStopKeyboardWatcher()
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Left-click hold mode disabled.")
	return true
}

; Installs a low-level keyboard hook to detect any key press.
; Uses no flags so both physical and synthetic keys cancel selection
; (e.g. a tap-hold that fires Ctrl+C should also stop the drag).
GestureStartKeyboardWatcher() {
    global GestureKeyboardHook

    GestureStopKeyboardWatcher()
    ; L3: Level 3 (higher than Ergopti's Level 2 hotkeys)
    ; 'V' option: non-consuming hook so keys pass through normally.
    GestureKeyboardHook := InputHook("V L3")
    GestureKeyboardHook.KeyOpt("{All}", "N")
    GestureKeyboardHook.OnKeyDown := GestureOnKeyDown
    GestureKeyboardHook.Start()
}

; Removes the keyboard hook.
GestureStopKeyboardWatcher() {
    global GestureKeyboardHook

    if (GestureKeyboardHook != 0 and IsObject(GestureKeyboardHook)) {
        try GestureKeyboardHook.Stop()
        GestureKeyboardHook := 0
    }
}

; Callback fired on any key press while a click hold is active.
GestureOnKeyDown(ih, vk, sc) {
	if A_IsSuspended {
		GestureReleaseLeftClick()
		GestureReleaseRightClick()
		return
	}

	; Any keystroke releases whichever button(s) are currently held. The release
	; transaction stops the shared observer only after every native Button Up
	; succeeds. Stopping it here first loses the keyboard retry path if Windows
	; refuses either release.
	GestureReleaseLeftClick()
	GestureReleaseRightClick()
}

; NOTE: the ~RButton / ~LButton cross-release hotkeys are registered
; dynamically via Hotkey() inside GestureToggleLeftClick / GestureToggleRightClick
; rather than as static #HotIf blocks. Static mouse-button hotkeys install the
; mouse hook at load-time, which blocks indefinitely on a headless CI runner
; that has no physical mouse hardware attached.

; Activates or deactivates a right-button-held mode. Mirrors GestureToggleLeftClick.
GestureToggleRightClick() {
	global GestureRightClickHeld, GestureLeftClickHeld

    if (GestureRightClickHeld) {
		return GestureReleaseRightClick()
	}

	LoggerDebug("gestures", "Enabling right-click hold mode…")
	PreviousCritical := Critical("On")
	DownAttempted := false
	try {
		; Prepare all fallible cleanup resources before the OS button is acquired
		GestureStartKeyboardWatcher()
		HookDispatcher.Register("mouse_rdown", GestureReleaseRightClick)
		HookDispatcher.Register("mouse_ldown", GestureReleaseRightClick)
		DownAttempted := true
		Click("Right", "Down")
		GestureRightClickHeld := True
	} catch as e {
		; Mirror the left-button transaction: a failed compensating Up retains the
		; exact logical hold and its recovery callbacks for a later retry.
		if DownAttempted {
			try Click("Right", "Up")
			catch as cleanupError {
				GestureRightClickHeld := True
				LoggerError("gestures", "Could not release right-click hold after setup failure; recovery ownership was retained: {1}.", cleanupError.Message)
				LoggerError("gestures", "Could not enable right-click hold mode: {1}.", e.Message)
				return false
			}
		}
		try {
			HookDispatcher.Unregister("mouse_rdown", GestureReleaseRightClick)
		} catch as cleanupError {
			LoggerError("gestures", "Could not remove right-click right-button cleanup: {1}.", cleanupError.Message)
		}
		try {
			HookDispatcher.Unregister("mouse_ldown", GestureReleaseRightClick)
		} catch as cleanupError {
			LoggerError("gestures", "Could not remove right-click left-button cleanup: {1}.", cleanupError.Message)
		}
		GestureRightClickHeld := False
		if (!GestureLeftClickHeld)
			GestureStopKeyboardWatcher()
		LoggerError("gestures", "Could not enable right-click hold mode: {1}.", e.Message)
		return false
	} finally {
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Right-click hold mode enabled.")
}

; Releases the right mouse button if it is currently held by the toggle.
GestureReleaseRightClick(*) {
	global GestureRightClickHeld, GestureLeftClickHeld

    if (!GestureRightClickHeld) {
        return true
	}

	PreviousCritical := Critical("On")
	ReleaseSucceeded := false
	try {
		LoggerDebug("gestures", "Disabling right-click hold mode…")
		try Click("Right", "Up")
		catch as e {
			LoggerError("gestures", "Could not release right-click hold; recovery ownership was retained: {1}.", e.Message)
			return false
		}
		GestureRightClickHeld := False
		; Unsubscribe via HookDispatcher — Hotkey(…, "Off") would disable the shared
		; ~LButton/~RButton handlers that the dispatcher registered.
		try {
			HookDispatcher.Unregister("mouse_rdown", GestureReleaseRightClick)
		} catch as e {
			LoggerError("gestures", "Could not remove right-click right-button cleanup: {1}.", e.Message)
		}
		try {
			HookDispatcher.Unregister("mouse_ldown", GestureReleaseRightClick)
		} catch as e {
			LoggerError("gestures", "Could not remove right-click left-button cleanup: {1}.", e.Message)
		}
		ReleaseSucceeded := true
	} finally {
		; Mirror the left-button ownership rule: no successful Up receipt means
		; the observer remains the retry owner.
		if ReleaseSucceeded and !GestureLeftClickHeld
			GestureStopKeyboardWatcher()
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Right-click hold mode disabled.")
	return true
}
