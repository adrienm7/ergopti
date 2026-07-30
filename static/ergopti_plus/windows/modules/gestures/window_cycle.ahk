; modules/gestures/window_cycle.ahk

; ==============================================================================
; MODULE: Gesture Window-Cycle Tracker (AHK)
; DESCRIPTION:
; The manual-activation window recency tracker and the win-next / win-prev /
; cycle-app-windows gestures: enumerate cyclable windows, keep a most-recently-
; activated order, and activate the next/previous window or same-app window.
; Extracted from modules/gestures.ahk so the cycling logic lives on its own.
;
; STATE & LIFECYCLE:
; The recency order, the GESTURE_WIN_ORDER_MAX cap and the WinEvent hook install
; (CallbackCreate / SetWinEventHook / OnExit) remain at the top level of
; gestures.ahk; AHK resolves _GestureOnForeground across includes at load time,
; so the hook still binds the callback defined here. The shared globals
; (_GestureWinOrder, _GestureCycling, _GestureWinHook, _GestureCallbackPtr) are
; super-globals visible to these functions without redeclaration.
; ==============================================================================

#Requires AutoHotkey v2.0

; Returns the list of all visible, non-cloaked top-level windows on the
; current virtual desktop, ordered like the taskbar (oldest → newest Z-order).
; Filters out tool windows, the desktop shell, and the Settings host so the
; cycle stays on real user windows.
GestureGetCyclableWindows(ProcessFilter := "") {
		Result := []
		Ids := WMGetList()
		for _, HWnd in Ids {
				try {
						Title := WinGetTitle("ahk_id " . HWnd)
						if (Title = "") {
								continue
						}
						Style := WinGetStyle("ahk_id " . HWnd)
						; WS_VISIBLE = 0x10000000
						if !(Style & 0x10000000) {
								continue
						}
						ExStyle := WinGetExStyle("ahk_id " . HWnd)
						; WS_EX_TOOLWINDOW = 0x80 — skip tool palettes
						if (ExStyle & 0x80) {
								continue
						}
						WinClass := WinGetClass("ahk_id " . HWnd)
						if (WinClass = "Progman" || WinClass = "WorkerW" || WinClass = "Shell_TrayWnd") {
								continue
						}
						; DWMWA_CLOAKED = 14 — windows on other virtual desktops
						; Note: DwmGetWindowAttribute is Windows-only DWM API — no cross-platform port defined
			if WMIsCloaked(HWnd) {
								continue
						}
						if (ProcessFilter != "") {
								ProcName := WinGetProcessName("ahk_id " . HWnd)
								if (ProcName != ProcessFilter) {
										continue
								}
						}
						Result.Push(HWnd)
				} catch as Err {
						; A window closing mid-enumeration (a routine race, not a bug)
						; throws TargetError on the next WinGet* call for that HWnd — skip
						; just this window instead of aborting the whole cycle list.
						LoggerDebug("gestures", "GestureGetCyclableWindows: skipped ahk_id {1}: {2}.", HWnd, Err.Message)
						continue
				}
		}

		; Sort by HWND ascending (monotonic creation order) for a stable cycle
		; that does not shift when the active window changes Z-order position.
		N := Result.Length
		loop N - 1 {
				I := A_Index
				loop N - I {
						J := A_Index
						if (Result[J] > Result[J + 1]) {
								Tmp := Result[J]
								Result[J] := Result[J + 1]
								Result[J + 1] := Tmp
						}
				}
		}
		return Result
}





; ===================================================
; ===================================================
; ======= X/ Manual-activation window tracker =======
; ===================================================
; ===================================================

; WinEvent callback fired by Windows whenever a window gains foreground focus.
; Ignored when _GestureCycling is True so our own WinActivate calls do not
; corrupt the manually-built recency order.
_GestureOnForeground(hWinEventHook, Event, HWnd, IdObject, IdChild, Thread, Time) {
		global _GestureWinOrder, _GestureCycling, GESTURE_WIN_ORDER_MAX
		global _GestureSelfActivated, GESTURE_SELF_ACTIVATE_TTL_MS
		; Do not churn the tracker while paused — the driver is inert and any
		; recency recorded now would be stale by the time it resumes.
		if (A_IsSuspended) {
				return
		}
		if (_GestureCycling) {
				return
		}
		; The WinEvent for our own programmatic activation is delivered async (OUTOFCONTEXT),
		; after the _GestureCycling bracket has already cleared, so also consume a matching
		; self-activated HWND here. Delete on every match so a stale entry cannot linger;
		; only suppress when the activation is recent (gesture-cycle-winevent-async-fence).
		if (_GestureSelfActivated.Has(HWnd)) {
				Age := (A_TickCount - _GestureSelfActivated[HWnd]) & 0xFFFFFFFF
				_GestureSelfActivated.Delete(HWnd)
				if (Age < GESTURE_SELF_ACTIVATE_TTL_MS) {
						return
				}
		}
		; Skip non-window objects (menus, scroll bars, etc.)
		if (IdObject != 0) {
				return
		}
		; Remove existing entry for this HWND, then prepend it (most-recent first).
		; Stop copying once the cap is reached so the list cannot grow unbounded on
		; long-running sessions; oldest entries past the cap are dropped.
		NewOrder := [HWnd]
		for _, H in _GestureWinOrder {
				if (NewOrder.Length >= GESTURE_WIN_ORDER_MAX) {
						break
				}
				if (H != HWnd) {
						NewOrder.Push(H)
				}
		}
		_GestureWinOrder := NewOrder
}

; Cleans up the WinEvent hook and its machine-code thunk on script exit.
; Also force-releases any held mouse button so a Reload or ExitApp triggered
; while a click-toggle hold is active does not leave the button stuck OS-wide.
_GestureUnhook(*) {
		global _GestureWinHook, _GestureCallbackPtr
		; Release any OS-level held button before tearing down — the in-process
		; release paths (InputHook key-watcher, HookDispatcher cross-release) never
		; run during process exit, so the physical button stays down without this.
		try GestureReleaseLeftClick()
		try GestureReleaseRightClick()
		if (_GestureWinHook) {
		WMUnhookWinEvent(_GestureWinHook)
				_GestureWinHook := 0
		}
		if (_GestureCallbackPtr) {
				CallbackFree(_GestureCallbackPtr)
				_GestureCallbackPtr := 0
		}
}

; Returns _GestureWinOrder pruned to only currently-cyclable windows,
; preserving manual-activation recency order (most-recent at index 1).
; If the list is empty (first use before any manual activation was recorded),
; falls back to GestureGetCyclableWindows() so the feature still works on
; first launch. Accepts an optional ProcessFilter to restrict to one app.
_GestureOrderedWindows(ProcessFilter := "") {
		global _GestureWinOrder
		Cyclable := GestureGetCyclableWindows(ProcessFilter)
		; Build a Set for O(1) membership check
		CyclableSet := Map()
		for _, H in Cyclable {
				CyclableSet[H] := True
		}
		; Retain only HWNDs still alive and cyclable, in recency order
		Result := []
		for _, H in _GestureWinOrder {
				if CyclableSet.Has(H) {
						Result.Push(H)
				}
		}
		; If nothing was tracked yet, fall back to creation-order list
		if (Result.Length = 0) {
				return Cyclable
		}
		; Append any cyclable windows not yet seen in the tracker
		; (e.g. opened before ErgoptiPlus was running)
		TrackedSet := Map()
		for _, H in Result {
				TrackedSet[H] := True
		}
		for _, H in Cyclable {
				if !TrackedSet.Has(H) {
						Result.Push(H)
				}
		}
		return Result
}


; Activates the window at Windows[Target], restoring it if minimised.
; Returns True if the call did not throw — does NOT verify focus actually moved
; (Windows propagates focus async, and a strict check causes false negatives
; that make the cycle skip windows).
GestureActivateWindow(HWnd) {
		global _GestureSelfActivated, GESTURE_SELF_ACTIVATE_TTL_MS
		; AHK-24: prune stale entries before inserting — entries whose WinEvent never
		; arrived (failed/no-op activations, suspended-race) are never reclaimed by
		; _GestureOnForeground and would grow the Map unbounded over a long session.
		; The TTL prune keeps the Map bounded to in-flight self-activations within one
		; GESTURE_SELF_ACTIVATE_TTL_MS window, mirroring the cap on _GestureWinOrder.
		_StaleSelfActivated := []
		for _sa_hwnd, _sa_tick in _GestureSelfActivated {
				if ((A_TickCount - _sa_tick) & 0xFFFFFFFF >= GESTURE_SELF_ACTIVATE_TTL_MS)
						_StaleSelfActivated.Push(_sa_hwnd)
		}
		for _sa_hwnd in _StaleSelfActivated
				_GestureSelfActivated.Delete(_sa_hwnd)
		; Mark this as a self-induced activation so _GestureOnForeground can fence the async
		; EVENT_SYSTEM_FOREGROUND it triggers (gesture-cycle-winevent-async-fence).
		_GestureSelfActivated[HWnd] := A_TickCount
		try {
				if (WinGetMinMax("ahk_id " . HWnd) = -1) {
						WinRestore("ahk_id " . HWnd)
				}
		return WMForceForeground(HWnd)
		} catch as e {
				LoggerWarn("gestures", "WinActivate failed for HWND {1}: {2}.", HWnd, e.Message)
				return False
		}
}

; Computes the next index in a circular list of size N.
GestureNextIndex(Current, N, Forward) {
		if (Forward) {
				return (Current >= N) ? 1 : Current + 1
		}
		return (Current <= 1) ? N : Current - 1
}

; Cycles through every window across all applications on the current desktop.
; Forward=True selects the next window, Forward=False the previous one.
; Order follows manual user activation history (_GestureWinOrder), not Z-order.
; If the target window can't be activated, falls back to the next one in the
; cycle so the user never gets "stuck" at an unactivatable slot.
GestureCycleWindows(Forward) {
		global _GestureCycling
		; Capture the active HWND before releasing modifiers — the Send below can
		; briefly shift focus. WinExist returns the HWND directly (WMExists returns bool).
		Active := WinExist("A")
		; Release modifiers still held by the touchpad gesture (Ctrl+Win+Shift)
		; so WinActivate doesn't trigger the Start menu or other system shortcuts.
		Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
		Windows := _GestureOrderedWindows()
		N := Windows.Length
		if (N < 2) {
				LoggerDebug("gestures", "CycleWindows: only {1} window(s) — nothing to cycle.", N)
				return
		}
		Index := 0
		for I, HWnd in Windows {
				if (HWnd = Active) {
						Index := I
						break
				}
		}
		LoggerDebug("gestures", "CycleWindows: {1} window(s), active idx={2}, forward={3}.",
				N, Index, Forward)

		; Try up to N-1 candidates so we wrap around even if some windows refuse activation.
		Target := Index
		loop N - 1 {
				Target := GestureNextIndex(Target, N, Forward)
				; Suppress the WinEvent hook so this programmatic activation does not
				; reorder the manual history. Critical serializes the flag/activation
				; bracket against a second window-cycle gesture hotkey interleaving on
				; its own pseudo-thread mid-activation, which could otherwise clear
				; the flag early (unlike hook_dispatcher.ahk's shared-state mutations,
				; this plain global boolean had no Critical section at all).
				_PrevCrit := Critical("On")
				try {
						_GestureCycling := True
						Activated := GestureActivateWindow(Windows[Target])
				} finally {
						_GestureCycling := False
						Critical(_PrevCrit)
				}
				if Activated {
						LoggerDebug("gestures", "Activated HWND {1} (idx={2}).", Windows[Target], Target)
						return
				}
		}
		LoggerWarn("gestures", "CycleWindows: no candidate could be activated.")
}

; Cycles through windows belonging to the same process as the active window.
; Order follows manual user activation history, same as GestureCycleWindows.
GestureCycleAppWindows(Forward) {
		global _GestureCycling
		; Capture the active HWND before releasing modifiers — same race as CycleWindows.
		Active := WinExist("A")
		Send("{Blind}{LCtrl up}{RCtrl up}{LShift up}{RShift up}{LWin up}{RWin up}{LAlt up}{RAlt up}")
		if (!Active) {
				return
		}
		try ProcName := WinGetProcessName("ahk_id " . Active)
		catch {
				return
		}
		Windows := _GestureOrderedWindows(ProcName)
		N := Windows.Length
		if (N < 2) {
				LoggerDebug("gestures", "CycleAppWindows: only {1} window(s) for '{2}'.", N, ProcName)
				return
		}
		Index := 0
		for I, HWnd in Windows {
				if (HWnd = Active) {
						Index := I
						break
				}
		}
		LoggerDebug("gestures", "CycleAppWindows '{1}': {2} window(s), active idx={3}, forward={4}.",
				ProcName, N, Index, Forward)

		Target := Index
		loop N - 1 {
				Target := GestureNextIndex(Target, N, Forward)
				; Same Critical-serialized flag/activation bracket as GestureCycleWindows.
				_PrevCrit := Critical("On")
				try {
						_GestureCycling := True
						Activated := GestureActivateWindow(Windows[Target])
				} finally {
						_GestureCycling := False
						Critical(_PrevCrit)
				}
				if Activated {
						LoggerDebug("gestures", "Activated HWND {1} (idx={2}).", Windows[Target], Target)
						return
				}
		}
		LoggerWarn("gestures", "CycleAppWindows: no candidate could be activated.")
}
