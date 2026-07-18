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
		GestureReleaseLeftClick()
		return
	}

	LoggerDebug("gestures", "Enabling left-click hold mode…")
	PreviousCritical := Critical("On")
	try {
		; Prepare all fallible cleanup resources before the OS button is acquired
		GestureStartKeyboardWatcher()
		HookDispatcher.Register("mouse_rdown", GestureReleaseLeftClick)
		HookDispatcher.Register("mouse_ldown", GestureReleaseLeftClick)
		Click("Left", "Down")
		GestureLeftClickHeld := True
	} catch as e {
		; A partial setup must never strand either a subscription or an OS button
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
		try {
			Click("Left", "Up")
		} catch as cleanupError {
			LoggerError("gestures", "Could not release left-click hold after setup failure: {1}.", cleanupError.Message)
		}
		GestureLeftClickHeld := False
		if (!GestureRightClickHeld)
			GestureStopKeyboardWatcher()
		LoggerError("gestures", "Could not enable left-click hold mode: {1}.", e.Message)
		return
	} finally {
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Left-click hold mode enabled.")
}

; Releases the left mouse button if it is currently held by the toggle.
GestureReleaseLeftClick(*) {
	global GestureLeftClickHeld, GestureRightClickHeld

    if (!GestureLeftClickHeld) {
        return
    }

	PreviousCritical := Critical("On")
	GestureLeftClickHeld := False
	try {
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
		LoggerDebug("gestures", "Disabling left-click hold mode…")
		try {
			Click("Left", "Up")
		} catch as e {
			LoggerError("gestures", "Could not release left-click hold: {1}.", e.Message)
		}
	} finally {
		; Stop the shared watcher only if the right click is also released
		if (!GestureRightClickHeld)
			GestureStopKeyboardWatcher()
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Left-click hold mode disabled.")
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
        ih.Stop()
        GestureReleaseLeftClick()
        GestureReleaseRightClick()
        return
    }

    ; Stop catching keys immediately to avoid recursion
    ih.Stop()

    ; Any keystroke releases whichever button(s) are currently held
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
        GestureReleaseRightClick()
        return
	}

	LoggerDebug("gestures", "Enabling right-click hold mode…")
	PreviousCritical := Critical("On")
	try {
		; Prepare all fallible cleanup resources before the OS button is acquired
		GestureStartKeyboardWatcher()
		HookDispatcher.Register("mouse_rdown", GestureReleaseRightClick)
		HookDispatcher.Register("mouse_ldown", GestureReleaseRightClick)
		Click("Right", "Down")
		GestureRightClickHeld := True
	} catch as e {
		; A partial setup must never strand either a subscription or an OS button
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
		try {
			Click("Right", "Up")
		} catch as cleanupError {
			LoggerError("gestures", "Could not release right-click hold after setup failure: {1}.", cleanupError.Message)
		}
		GestureRightClickHeld := False
		if (!GestureLeftClickHeld)
			GestureStopKeyboardWatcher()
		LoggerError("gestures", "Could not enable right-click hold mode: {1}.", e.Message)
		return
	} finally {
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Right-click hold mode enabled.")
}

; Releases the right mouse button if it is currently held by the toggle.
GestureReleaseRightClick(*) {
    global GestureRightClickHeld, GestureLeftClickHeld

    if (!GestureRightClickHeld) {
        return
    }

	PreviousCritical := Critical("On")
	GestureRightClickHeld := False
	try {
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
		LoggerDebug("gestures", "Disabling right-click hold mode…")
		try {
			Click("Right", "Up")
		} catch as e {
			LoggerError("gestures", "Could not release right-click hold: {1}.", e.Message)
		}
	} finally {
		; Stop the shared watcher only if the left click is also released
		if (!GestureLeftClickHeld)
			GestureStopKeyboardWatcher()
		Critical(PreviousCritical)
	}
	LoggerInfo("gestures", "Right-click hold mode disabled.")
}
