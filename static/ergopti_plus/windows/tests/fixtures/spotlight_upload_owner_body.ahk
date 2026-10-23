; tests/fixtures/spotlight_upload_owner_body.ahk

; ==============================================================================
; MODULE: Spotlight Native Upload Ownership Fixture
; DESCRIPTION:
; Uses real HWNDs, GDI+ painting and the real bitmap adapter. Only the native
; UpdateLayeredWindow outcome is controlled in refusal/exception modes. No
; physical pixel correctness, monitor discovery or public hotkey is claimed.
; ==============================================================================

#Requires AutoHotkey v2.0

global _SPBR_State := {Mode: A_Args[1], Hwnd: 0, Returned: 0, Paints: 0, Uploads: 0,
	Shows: 0, Destroys: 0, VisibleAtReturn: -1, AliveAtReturn: -1, AdapterResult: -1, Async: 0}

class _SPBR_Native extends _GRBitmapNative {
	static UpdateLayeredWindow(Handle, Dest, Size, MemoryDC, Source, Blend) {
		global _SPBR_State
		_SPBR_Require(Handle == _SPBR_State.Hwnd && DllCall("User32\IsWindow", "Ptr", Handle, "Int"),
			"the real adapter must upload only this fixture's live HWND")
		_SPBR_State.Uploads += 1
		if _SPBR_State.Mode == "refused"
			return false
		if _SPBR_State.Mode == "exception"
			throw Error("Controlled native bitmap upload exception")
		return super.UpdateLayeredWindow(Handle, Dest, Size, MemoryDC, Source, Blend)
	}
}

_SPBR_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_SPBR_Error(Failure, Mode) {
	global _SPBR_State
	if !IsObject(_SPBR_State.Async)
		_SPBR_State.Async := Failure
	return true
}

_SPBR_Create(Options) {
	global _SPBR_State
	Handle := GR_CreateWindow(Options)
	_SPBR_State.Hwnd := Handle
	_SPBR_Require(Handle != 0 && DllCall("User32\IsWindow", "Ptr", Handle, "Int"),
		"the real graphics adapter must create a private layered HWND")
	return Handle
}

_SPBR_Paint(Graphics, Width, Height) {
	global _SPBR_State
	_SPBR_State.Paints += 1
	_SPBR_Require(Graphics != 0 && Width == 64 && Height == 64,
		"the real GDI+ callback must receive the actual private surface")
	_SpotlightDrawCircleResources(Graphics, 4, 24, 2, 0x66FFDA00, 0xE6FFDA00)
}

_SPBR_Draw(Handle, PaintFn) {
	global _SPBR_State
	Result := _GRDrawBitmapRun(Handle, PaintFn, _SPBR_Native)
	_SPBR_State.AdapterResult := Result
	return Result
}

_SPBR_Show(Handle) {
	global _SPBR_State
	_SPBR_State.Shows += 1
	GR_Show(Handle)
	_SPBR_Require(DllCall("User32\IsWindowVisible", "Ptr", Handle, "Int") != 0,
		"the successful native show must actually reveal its private HWND")
}

_SPBR_Destroy(Handle) {
	global _SPBR_State
	_SPBR_Require(Handle == _SPBR_State.Hwnd, "retirement must target the exact acquired HWND")
	_SPBR_State.Destroys += 1
	GR_DestroyWindow(Handle)
	_SPBR_Require(!DllCall("User32\IsWindow", "Ptr", Handle, "Int"),
		"the exact private HWND must be destroyed")
}

_SPBR_Run() {
	global _SPBR_State, _GRBitmapCleanupDebt, _SpotlightPaintCleanupDebt
	SubjectFailure := 0
	try _SPBR_State.Returned := _SpotlightCreateOverlayWindow(
		Map("x", 0, "y", 0, "w", 64, "h", 64, "clickThrough", true, "alwaysOnTop", false),
		_SPBR_Paint, _SPBR_Create, _SPBR_Draw, _SPBR_Show, _SPBR_Destroy)
	catch Any as Failure
		SubjectFailure := Failure
	_SPBR_State.AliveAtReturn := DllCall("User32\IsWindow", "Ptr", _SPBR_State.Hwnd, "Int")
	_SPBR_State.VisibleAtReturn := DllCall("User32\IsWindowVisible", "Ptr", _SPBR_State.Hwnd, "Int")
	_SPBR_Require(_SPBR_State.Paints == 1 && _SPBR_State.Uploads == 1,
		"the complete real painting path must reach exactly one native upload")
	_SPBR_Require(_GRBitmapCleanupDebt.Length == 0 && _SpotlightPaintCleanupDebt.Length == 0,
		"the actual adapter and GDI+ paint must settle all acquired native resources")
	if _SPBR_State.Mode == "current" {
		if IsObject(SubjectFailure)
			throw SubjectFailure
		_SPBR_Require(_SPBR_State.AdapterResult == true, "the actual native bitmap upload must succeed")
		_SPBR_Require(_SPBR_State.Returned == _SPBR_State.Hwnd && _SPBR_State.AliveAtReturn,
			"a complete native draw and show must transfer the exact live HWND")
		_SPBR_Require(_SPBR_State.Shows == 1 && _SPBR_State.VisibleAtReturn && _SPBR_State.Destroys == 0,
			"the successful acquisition must show once and preserve caller-owned custody")
	} else {
		if _SPBR_State.Mode == "exception"
			_SPBR_Require(IsObject(SubjectFailure) && SubjectFailure.Message == "Controlled native bitmap upload exception",
				"the existing exceptional draw refusal must remain visible to its caller")
		else
			_SPBR_Require(_SPBR_State.AdapterResult == false, "the genuine adapter must report native upload refusal")
		_SPBR_Require(_SPBR_State.Returned == 0 && _SPBR_State.Shows == 0,
			"an uncommitted Spotlight bitmap must never be shown or transferred")
		_SPBR_Require(_SPBR_State.Destroys == 1 && !_SPBR_State.AliveAtReturn && !_SPBR_State.VisibleAtReturn,
			"the acquisition owner must destroy the exact refused HWND before returning")
	}
}

_SPBR_Main() {
	global _SPBR_State
	Primary := 0, ExportFailure := 0
	Receipt := _SpotlightSessionNewReceipt()
	OnError(_SPBR_Error)
	try {
		_SPBR_Require(_SPBR_State.Mode == "current" || _SPBR_State.Mode == "refused"
			|| _SPBR_State.Mode == "exception", "the private native upload mode must be known")
		_SpotlightSessionAcquireGdi(Receipt)
		_SPBR_Run()
		if IsObject(_SPBR_State.Async)
			throw _SPBR_State.Async
	} catch Any as Failure {
		Primary := Failure
	} finally {
		try {
			; The pre-cleanup oracle above is never inferred from this safety retirement.
			if _SPBR_State.Hwnd && DllCall("User32\IsWindow", "Ptr", _SPBR_State.Hwnd, "Int")
				_SPBR_Destroy(_SPBR_State.Hwnd)
		} catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		try _SPBR_Require(_SpotlightSessionRelease(Receipt), "the private GDI+ token and module must retire")
		catch Any as Failure {
			if !IsObject(Primary)
				Primary := Failure
		}
		OnError(_SPBR_Error, 0)
	}
	if !IsObject(Primary) && IsObject(_SPBR_State.Async)
		Primary := _SPBR_State.Async
	try FileAppend("RECEIPT spotlight-upload-owner mode=" . _SPBR_State.Mode
		. " pid=" . DllCall("Kernel32\GetCurrentProcessId", "UInt") . " hwnd=" . _SPBR_State.Hwnd
		. " returned=" . _SPBR_State.Returned . " paint=" . _SPBR_State.Paints . " upload=" . _SPBR_State.Uploads
		. " adapter_result=" . _SPBR_State.AdapterResult . " show=" . _SPBR_State.Shows
		. " alive_before_cleanup=" . _SPBR_State.AliveAtReturn . " visible_before_cleanup=" . _SPBR_State.VisibleAtReturn
		. " destroy_total=" . _SPBR_State.Destroys . "`n", "*", "UTF-8")
	catch Any as Failure
		ExportFailure := Failure
	if IsObject(Primary)
		throw Primary
	if IsObject(ExportFailure)
		throw ExportFailure
	FileAppend("PASS spotlight-upload-owner " . _SPBR_State.Mode . "`n", "*", "UTF-8")
}

try {
	_SPBR_Main()
	ExitApp(0)
} catch Any as Failure {
	FileAppend("FAIL spotlight-upload-owner " . Failure.Message . " file=" . Failure.File
		. " line=" . Failure.Line . "`n", "*", "UTF-8")
	ExitApp(1)
}
