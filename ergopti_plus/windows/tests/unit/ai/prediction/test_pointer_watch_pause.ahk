; tests/unit/ai/prediction/test_pointer_watch_pause.ahk

; ==============================================================================
; MODULE: LLM Pointer-Watch Tick Under Pause
; DESCRIPTION:
; _LLM_PointerWatch_OnMoveTick is a recurring 50 ms SetTimer callback, and
; SetTimer threads keep running under native Suspend. The tick must be inert
; while paused (pointer-watch-timer-bypasses-suspend): no pointer sample and no
; change to the movement baseline. With no prediction work active the running
; tick drops the baseline before any pointer read, so the baseline alone shows
; whether the paused tick ran, and no case reads or moves the cursor.
; ==============================================================================

#Requires AutoHotkey v2.0

_PWP_PausedTickKeepsBaseline() {
	global _LLM_PointerWatch_LastX, _LLM_PointerWatch_LastY, _LLM_Bridge_Active
	HadX := IsSet(_LLM_PointerWatch_LastX)
	HadY := IsSet(_LLM_PointerWatch_LastY)
	SavedX := HadX ? _LLM_PointerWatch_LastX : 0
	SavedY := HadY ? _LLM_PointerWatch_LastY : 0
	SavedActive := _LLM_Bridge_Active
	WasSuspended := A_IsSuspended
	try {
		_LLM_Bridge_Active := false
		_LLM_PointerWatch_LastX := 1201
		_LLM_PointerWatch_LastY := 802
		Suspend(true)
		_LLM_PointerWatch_OnMoveTick()
		AssertTrue(IsSet(_LLM_PointerWatch_LastX) && _LLM_PointerWatch_LastX == 1201
			&& IsSet(_LLM_PointerWatch_LastY) && _LLM_PointerWatch_LastY == 802,
			"a paused pointer-watch tick must leave the movement baseline untouched")
		Suspend(false)
		_LLM_PointerWatch_OnMoveTick()
		AssertFalse(IsSet(_LLM_PointerWatch_LastX) || IsSet(_LLM_PointerWatch_LastY),
			"positive control: a running tick with no prediction work drops the baseline")
	} finally {
		if A_IsSuspended != WasSuspended
			Suspend(WasSuspended)
		_LLM_Bridge_Active := SavedActive
		if HadX
			_LLM_PointerWatch_LastX := SavedX
		else
			_LLM_PointerWatch_LastX := unset
		if HadY
			_LLM_PointerWatch_LastY := SavedY
		else
			_LLM_PointerWatch_LastY := unset
	}
}
Test("LLM pointer watch: a paused tick leaves its baseline untouched (pointer-watch-timer-bypasses-suspend)",
	_PWP_PausedTickKeepsBaseline)
