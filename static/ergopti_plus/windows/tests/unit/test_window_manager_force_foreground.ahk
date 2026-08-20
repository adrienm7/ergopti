; tests/unit/test_window_manager_force_foreground.ahk

; ==============================================================================
; MODULE: Window Manager Foreground Confirmation Tests
; DESCRIPTION:
; Window-cycle activation must consume Win32 refusal returns and observe the
; foreground postcondition before it reports success. A failed request also
; removes its speculative WinEvent fence so the cycle can try another HWND.
; (AHK-20.)
; ==============================================================================

#Requires AutoHotkey v2.0

class _WMFFNative {
	static window_valid := true
	static attach_ok := true
	static detach_ok := true
	static bring_ok := true
	static foreground_ok := true
	static activate_ok := true
	static observe_target := true
	static foreground_hwnd := 99
	static calls := []

	static Reset() {
		_WMFFNative.window_valid := true
		_WMFFNative.attach_ok := true
		_WMFFNative.detach_ok := true
		_WMFFNative.bring_ok := true
		_WMFFNative.foreground_ok := true
		_WMFFNative.activate_ok := true
		_WMFFNative.observe_target := true
		_WMFFNative.foreground_hwnd := 99
		_WMFFNative.calls := []
	}

	static IsWindow(HWnd) {
		_WMFFNative.calls.Push("is-window:" . HWnd)
		return _WMFFNative.window_valid
	}

	static GetForegroundWindow() {
		_WMFFNative.calls.Push("get-foreground")
		return _WMFFNative.foreground_hwnd
	}

	static GetWindowThreadProcessId(HWnd) {
		_WMFFNative.calls.Push("thread:" . HWnd)
		return HWnd = 42 ? 20 : 10
	}

	static AttachThreadInput(ForeThread, TargThread, Attach) {
		_WMFFNative.calls.Push((Attach ? "attach:" : "detach:")
			. ForeThread . ":" . TargThread)
		return Attach ? _WMFFNative.attach_ok : _WMFFNative.detach_ok
	}

	static BringWindowToTop(HWnd) {
		_WMFFNative.calls.Push("bring:" . HWnd)
		return _WMFFNative.bring_ok
	}

	static SetForegroundWindow(HWnd) {
		_WMFFNative.calls.Push("set-foreground:" . HWnd)
		if (_WMFFNative.foreground_ok && _WMFFNative.observe_target)
			_WMFFNative.foreground_hwnd := HWnd
		return _WMFFNative.foreground_ok
	}

	static Activate(HWnd) {
		_WMFFNative.calls.Push("activate:" . HWnd)
		return _WMFFNative.activate_ok
	}
}

_WMFF_HasCall(Expected) {
	for Call in _WMFFNative.calls {
		if (Call = Expected)
			return true
	}
	return false
}

_WMFF_ClosedOrRefusedWindowFails() {
	_WMFFNative.Reset()
	_WMFFNative.window_valid := false
	AssertFalse(WMForceForeground(42, _WMFFNative),
		"a closed HWND must fail before any foreground mutation")
	AssertEqual(1, _WMFFNative.calls.Length,
		"a closed HWND must not reach thread attachment or activation calls")

	for Rejected in ["attach", "bring", "foreground", "activate"] {
		_WMFFNative.Reset()
		switch Rejected {
			case "attach": _WMFFNative.attach_ok := false
			case "bring": _WMFFNative.bring_ok := false
			case "foreground": _WMFFNative.foreground_ok := false
			case "activate": _WMFFNative.activate_ok := false
		}
		AssertFalse(WMForceForeground(42, _WMFFNative),
			Rejected . " refusing the request must be a failed activation")
	}
}
Test("Window manager: closed and refused HWNDs fail (window-manager-force-foreground)",
	_WMFF_ClosedOrRefusedWindowFails)

_WMFF_RequiresObservedForegroundAndDetaches() {
	_WMFFNative.Reset()
	_WMFFNative.observe_target := false
	AssertFalse(WMForceForeground(42, _WMFFNative),
		"accepted API calls are not success while another HWND remains foreground")
	AssertTrue(_WMFF_HasCall("detach:10:20"),
		"every attached request must detach even when its postcondition fails")

	_WMFFNative.Reset()
	AssertTrue(WMForceForeground(42, _WMFFNative),
		"an accepted request with the target observed foreground must succeed")
	AssertTrue(_WMFF_HasCall("detach:10:20"),
		"a successful request must also release its input-thread attachment")

	_WMFFNative.Reset()
	_WMFFNative.detach_ok := false
	AssertFalse(WMForceForeground(42, _WMFFNative),
		"a failed detach must not claim the complete activation transaction succeeded")
}
Test("Window manager: success requires foreground confirmation and detach (window-manager-force-foreground)",
	_WMFF_RequiresObservedForegroundAndDetaches)

_WMFF_GestureFailureClearsFenceAndFallsThrough() {
	ActivateBody := _DriverFuncBody("GestureActivateWindow")
	Assert(ActivateBody != "", "GestureActivateWindow must remain reachable")
	RequestPos := InStr(ActivateBody, "WMForceForeground(HWnd)")
	FailurePos := InStr(ActivateBody, "if !Activated", , RequestPos)
	DeletePos := InStr(ActivateBody, "_GestureSelfActivated.Delete(HWnd)", , FailurePos)
	Assert(RequestPos > 0 && FailurePos > RequestPos && DeletePos > FailurePos,
		"a refused activation must delete its speculative self-activation marker")

	for FuncName in ["GestureCycleWindows", "GestureCycleAppWindows"] {
		Body := _DriverFuncBody(FuncName)
		CallPos := InStr(Body, "GestureActivateWindow(Windows[Target])")
		SuccessPos := InStr(Body, "if Activated", , CallPos)
		Assert(CallPos > 0 && SuccessPos > CallPos,
			FuncName . " must return only on success so a false result tries the next candidate")
	}
}
Test("Gesture cycle: failed activation clears its fence and tries the next HWND (window-manager-force-foreground)",
	_WMFF_GestureFailureClearsFenceAndFallsThrough)
