; tests/unit/adapters/crash_report/test_screenshot_region_sequence.ahk

; ==============================================================================
; MODULE: Native Region Screenshot Clipboard Custody Tests
; DESCRIPTION:
; Runs the actual registered in-process capture with real clipboard images.
; Controlled copies, an external lock probe and native delayed rendering
; exercise custody without any keyboard injection or live screenshot selection.
; ==============================================================================

#Requires AutoHotkey v2.0

_GSQ_WriteBitmap(Path, Red, Blue) {
	Bytes := Buffer(58, 0)
	NumPut("UShort", 0x4D42, Bytes, 0)
	NumPut("UInt", 58, Bytes, 2)
	NumPut("UInt", 54, Bytes, 10)
	NumPut("UInt", 40, Bytes, 14)
	NumPut("Int", 1, "Int", 1, Bytes, 18)
	NumPut("UShort", 1, "UShort", 24, Bytes, 26)
	NumPut("UInt", 4, Bytes, 34)
	NumPut("UChar", Blue, "UChar", 0, "UChar", Red, Bytes, 54)
	File := FileOpen(Path, "w")
	try AssertEqual(58, File.RawWrite(Bytes), "the owned bitmap fixture must be complete")
	finally File.Close()
}

_GSQ_Done(State, Code, Output, ErrorText) {
	State.Code := Code
	State.Output := Output
	State.ErrorText := ErrorText
	State.Calls += 1
}

; Another process tries to open the clipboard while the capture holds it.
; @returns {Boolean} True when the external open was refused.
_GSQ_ExternalOpenRefused(Stem) {
	Script := Stem . "_probe.ahk"
	FileAppend("#NoTrayIcon`n"
		. 'Opened := DllCall("OpenClipboard", "Ptr", 0, "Int")`n'
		. "if Opened`n"
		. '`tDllCall("CloseClipboard")`n'
		. "ExitApp(Opened ? 1 : 2)`n", Script, "UTF-8")
	try ExitCode := RunWait('"' . A_AhkPath . '" "' . Script . '"', , "Hide")
	finally FileDelete(Script)
	AssertTrue(ExitCode == 1 || ExitCode == 2, "the external clipboard probe must report its open attempt")
	return ExitCode == 2
}

; Reads the stage's top-left pixel back through GDI+.
; @returns {String} "R,G,B".
_GSQ_StagePixel(Stage) {
	return _GestureScreenshotWithGdiplus(_GSQ_StagePixelGdip.Bind(Stage))
}

_GSQ_StagePixelGdip(Stage) {
	Image := 0
	_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipCreateBitmapFromFile", "WStr", Stage,
		"Ptr*", &Image, "Int"), "GdipCreateBitmapFromFile")
	try {
		Argb := 0
		_GestureScreenshotGdipCheck(DllCall("gdiplus\GdipBitmapGetPixel", "Ptr", Image,
			"Int", 0, "Int", 0, "UInt*", &Argb, "Int"), "GdipBitmapGetPixel")
		return ((Argb >> 16) & 0xFF) . "," . ((Argb >> 8) & 0xFF) . "," . (Argb & 0xFF)
	} finally {
		_GestureScreenshotGdipDispose(Image)
	}
}

; Probes the capture at its native phases. "acquired" runs while the original
; clipboard lock is held on the borrowed bitmap; "detached" after the release.
_GSQ_Probe(Probe, Phase, Bitmap) {
	Probe.Phases.Push(Phase)
	if Phase == "acquired" {
		for DiagnosticLine in _GSQ_BitmapDiagnostics(Bitmap)
			_TestAppendProgress("# " . DiagnosticLine)
		if Probe.Mode == "locked"
			Probe.LockObserved := _GSQ_ExternalOpenRefused(Probe.Stem)
	} else if Phase == "detached" && Probe.Mode == "after" {
		AssertTrue(CB_WriteBitmapFile(Probe.BluePath, &Sequence),
			"the controlled native copy must replace the clipboard after detachment")
		Probe.OwnedSequence := Sequence
	}
}

; The real publisher must share a DDB usable by another process. A DIB section
; remains process-local even when its handle reaches CF_BITMAP.
_GSQ_RequireDeviceBitmap() {
	AssertTrue(DllCall("OpenClipboard", "Ptr", A_ScriptHwnd, "Int"))
	try {
		Bitmap := DllCall("GetClipboardData", "UInt", 2, "Ptr")
		AssertTrue(Bitmap != 0, "the real immediate clipboard bitmap must exist")
		Info := Buffer(A_PtrSize == 8 ? 32 : 24, 0)
		AssertEqual(Info.Size, DllCall("Gdi32\GetObjectW", "Ptr", Bitmap,
			"Int", Info.Size, "Ptr", Info, "Int"), "the native BITMAP must be observable")
		AssertEqual(0, NumGet(Info, A_PtrSize == 8 ? 24 : 20, "Ptr"),
			"the immediate source must be a shareable DDB for the actual external pixel reader")
	} finally AssertTrue(DllCall("CloseClipboard", "Int"))
}

; WM_RENDERFORMAT must publish without reopening the clipboard held by its
; requester. The clipboard owns the bitmap after a successful SetClipboardData.
_GSQ_Render(Owner, Format, LParam, Msg, Hwnd) {
	if Hwnd != Owner.Hwnd || Format != 2
		return
	Owner.Calls += 1
	Bitmap := DllCall("LoadImageW", "Ptr", 0, "WStr", Owner.Path, "UInt", 0,
		"Int", 0, "Int", 0, "UInt", 0x10, "Ptr")
	if !Bitmap {
		Owner.ErrorText := "The delayed fixture bitmap could not be loaded."
		return 0
	}
	if !DllCall("SetClipboardData", "UInt", 2, "Ptr", Bitmap, "Ptr") {
		Owner.ErrorText := "The delayed clipboard format could not be rendered."
		DllCall("Gdi32\DeleteObject", "Ptr", Bitmap)
		return 0
	}
	Owner.Sequence := CB_GetSequenceNumber()
	return 0
}

/** Observes the borrowed native bitmap under the capture's own clipboard lock. */
_GSQ_BitmapDiagnostics(Bitmap) {
	Lines := []
	Lines.Push("REGION_BITMAP_OWNER handle=" . Bitmap
		. " owner=" . DllCall("User32\GetClipboardOwner", "Ptr")
		. " cf_dib=" . DllCall("User32\IsClipboardFormatAvailable", "UInt", 8, "Int")
		. " cf_dibv5=" . DllCall("User32\IsClipboardFormatAvailable", "UInt", 17, "Int"))
	DllCall("Kernel32\SetLastError", "UInt", 0)
	ObjectType := DllCall("Gdi32\GetObjectType", "Ptr", Bitmap, "UInt")
	Lines.Push("REGION_BITMAP_TYPE result=" . ObjectType . " last_error=" . A_LastError)
	Info := Buffer(A_PtrSize == 8 ? 32 : 24, 0)
	DllCall("Kernel32\SetLastError", "UInt", 0)
	Received := DllCall("Gdi32\GetObjectW", "Ptr", Bitmap, "Int", Info.Size, "Ptr", Info, "Int")
	Width := NumGet(Info, 4, "Int"), Height := NumGet(Info, 8, "Int")
	Lines.Push("REGION_BITMAP_OBJECT result=" . Received . " last_error=" . A_LastError
		. " width=" . Width . " height=" . Height
		. " bits_pixel=" . NumGet(Info, 18, "UShort")
		. " dib_bits=" . NumGet(Info, A_PtrSize == 8 ? 24 : 20, "Ptr"))
	for Flags in [0, 0x2000] {
		DllCall("Kernel32\SetLastError", "UInt", 0)
		Copy := DllCall("User32\CopyImage", "Ptr", Bitmap, "UInt", 0, "Int", 0, "Int", 0, "UInt", Flags, "Ptr")
		Lines.Push("REGION_BITMAP_COPY flags=" . Flags . " handle=" . Copy
			. " last_error=" . A_LastError . " borrowed=" . (Copy == Bitmap))
		if Copy && Copy != Bitmap
			Lines.Push("REGION_BITMAP_DELETE flags=" . Flags
				. " result=" . DllCall("Gdi32\DeleteObject", "Ptr", Copy, "Int"))
	}
	if Received < 24 || Width != 1 || Height != 1 {
		Lines.Push("REGION_BITMAP_PIXEL skipped=not_one_pixel_bitmap")
		return Lines
	}
	Dc := DllCall("User32\GetDC", "Ptr", 0, "Ptr")
	Lines.Push("REGION_BITMAP_DC handle=" . Dc . " last_error=" . A_LastError)
	if !Dc
		return Lines
	try {
		Header := Buffer(40, 0), Pixel := Buffer(4, 0)
		NumPut("UInt", 40, "Int", 1, "Int", 1, "UShort", 1, "UShort", 32, Header)
		NumPut("UInt", 4, Header, 20)
		Scanned := DllCall("Gdi32\GetDIBits", "Ptr", Dc, "Ptr", Bitmap, "UInt", 0, "UInt", 1,
			"Ptr", Pixel, "Ptr", Header, "UInt", 0, "Int")
		Lines.Push("REGION_BITMAP_PIXEL result=" . Scanned . " last_error=" . A_LastError
			. " bgra=" . Format("{:08X}", NumGet(Pixel, 0, "UInt")))
	} finally {
		Lines.Push("REGION_BITMAP_DC_RELEASE result=" . DllCall("User32\ReleaseDC", "Ptr", 0, "Ptr", Dc, "Int"))
	}
	return Lines
}

_GSQ_Receive(Mode) {
	global _GestureRegionCapture, _GSWO_Handles
	Stem := A_Temp . "\ergopti_region_sequence_" . A_ScriptHwnd . "_" . A_TickCount . "_" . Random(1000, 999999)
	RedPath := Stem . "_red.bmp", BluePath := Stem . "_blue.bmp"
	Old := _GSWO_Install()
	Token := 0, Snapshot := "", OwnedSequence := 0, Handle := 0, Stage := ""
	OwnerGui := 0, RenderFn := 0, Renderer := 0
	State := {Code: -1, Output: "", ErrorText: "", Calls: 0}
	Probe := {Mode: Mode, Stem: Stem, BluePath: BluePath, Phases: [], LockObserved: false, OwnedSequence: 0}
	Primary := 0
	PreviousCritical := Critical("Off")
	try {
		Token := CB_TryBeginOwnedTransaction("test_region_image_sequence")
		AssertTrue(Token != 0, "the native clipboard fixture must own its transaction")
		Snapshot := CB_SaveAll()
		AssertFalse(Snapshot is String && Snapshot == "__CB_SAVE_ERROR__", "the original clipboard must be retained")
		_GSQ_WriteBitmap(RedPath, 255, 0)
		_GSQ_WriteBitmap(BluePath, 0, 255)
		if Mode == "delayed" {
			OwnerGui := Gui("+ToolWindow -Caption")
			Renderer := {Hwnd: OwnerGui.Hwnd, Path: RedPath, Calls: 0, Sequence: 0, ErrorText: ""}
			RenderFn := _GSQ_Render.Bind(Renderer)
			OnMessage(0x305, RenderFn)
			AssertTrue(DllCall("OpenClipboard", "Ptr", OwnerGui.Hwnd, "Int"))
			try {
				AssertTrue(DllCall("EmptyClipboard", "Int"))
				DllCall("SetClipboardData", "UInt", 2, "Ptr", 0, "Ptr")
				AssertTrue(DllCall("IsClipboardFormatAvailable", "UInt", 2, "Int"),
					"the native owner must declare its delayed bitmap")
			} finally AssertTrue(DllCall("CloseClipboard", "Int"))
			AssertEqual(OwnerGui.Hwnd, DllCall("GetClipboardOwner", "Ptr"), "the fixture must retain its delayed source")
			OwnedSequence := CB_GetSequenceNumber()
		} else {
			AssertTrue(CB_WriteBitmapFile(RedPath), "the selected red bitmap must reach the native clipboard")
			_GSQ_RequireDeviceBitmap()
			OwnedSequence := CB_GetSequenceNumber()
		}
		AssertTrue(OwnedSequence > 0)
		ExpectedSequence := OwnedSequence
		_GSWO_SeedRegion()
		_GestureRegionCapture["clipboard_sequence"] := Mode == "unknown" ? 0 : ExpectedSequence
		AssertTrue(GestureRegionCaptureStartSaveWorker(1), "the actual region registrar must construct its worker")
		Job := _GSWO_JobByOwner("region_save", 1)
		Stage := Job["stage"]
		AssertFalse(FileExist(Stage), "the worker must use a fresh owned stage")
		Capture := _GSWO_Handles[1]["capture"]
		AssertTrue(IsObject(Capture), "the registrar must hand its native capture to the worker owner")
		if Mode == "before" {
			AssertTrue(CB_WriteBitmapFile(BluePath))
			OwnedSequence := CB_GetSequenceNumber()
			AssertTrue(OwnedSequence != ExpectedSequence, "the hostile copy must have a distinct sequence")
		}
		GestureScreenshotWorkerState.native_probe_fn := _GSQ_Probe.Bind(Probe)
		Handle := _GestureScreenshotSpawnNative(Capture, _GSQ_Done.Bind(State))
		AssertTrue(Handle.start(), "the actual native worker must start")
		Started := A_TickCount
		while State.Calls == 0 && TickElapsed(Started) < 20000
			Sleep(10)
		AssertEqual(1, State.Calls, "the exact worker must settle once")
		if Probe.OwnedSequence
			OwnedSequence := Probe.OwnedSequence
		if Mode == "before" || Mode == "unknown" {
			AssertTrue(State.Code != 0, "the worker must refuse lost clipboard custody: " . State.ErrorText)
			AssertTrue(InStr(State.ErrorText, "clipboard content changed") > 0,
				"the refusal must report its actual custody failure: " . State.ErrorText)
			AssertEqual(0, Probe.Phases.Length, "refused custody must never borrow the clipboard bitmap")
			AssertFalse(FileExist(Stage), "refused custody must never create a staged image")
		} else {
			AssertEqual(0, State.Code, "the native worker must succeed: " . State.ErrorText)
			AssertEqual("", State.ErrorText)
			AssertEqual("acquired,detached", Probe.Phases[1] . "," . Probe.Phases[2],
				"the bitmap must be borrowed under the lock, then detached before the save")
			AssertTrue(FileExist(Stage), "an admitted image must be saved")
			AssertEqual("255,0,0", _GSQ_StagePixel(Stage), "the stage must contain the selected red pixel")
			if Mode == "locked"
				AssertTrue(Probe.LockObserved, "another process cannot replace the bitmap during acquisition")
			if Mode == "after"
				AssertTrue(Probe.OwnedSequence > 0 && Probe.OwnedSequence != ExpectedSequence,
					"the later copy must hold its own clipboard sequence")
			if Mode == "delayed" {
				AssertEqual(1, Renderer.Calls, "the native delayed renderer must answer once")
				AssertEqual("", Renderer.ErrorText)
				AssertTrue(Renderer.Sequence > 0 && CB_GetSequenceNumber() > 0,
					"the real delayed owner must retain observable clipboard content")
			}
		}
	} catch as Err {
		Primary := Err
	} finally {
		try {
			if Probe.OwnedSequence
				OwnedSequence := Probe.OwnedSequence
			if IsObject(Renderer) && Renderer.Sequence
				OwnedSequence := Renderer.Sequence
			if Token {
				if OwnedSequence {
					CB_RestoreOwnedAllEventually(Snapshot, OwnedSequence, Token, "test_region_image_sequence", true)
					RestoreStarted := A_TickCount
					while CB_HasRestoreDebtForOwner(Token) && TickElapsed(RestoreStarted) < 5000 {
						CB_RetryRestoreDebt()
						Sleep(10)
					}
					AssertFalse(CB_HasRestoreDebtForOwner(Token), "the native fixture must settle its restore debt")
				} else
					CB_EndOwnedTransaction(Token)
			}
			for Path in [RedPath, BluePath, Stage]
				if Path != "" && FileExist(Path)
					FileDelete(Path)
		} catch as Err {
			if !IsObject(Primary)
				Primary := Err
		} finally {
			try {
				if IsObject(RenderFn)
					OnMessage(0x305, RenderFn, 0)
				if IsObject(OwnerGui)
					OwnerGui.Destroy()
			} catch as Err {
				if !IsObject(Primary)
					Primary := Err
			} finally {
				_GSWO_Restore(Old)
				Critical(PreviousCritical)
			}
		}
	}
	if IsObject(Primary)
		throw Primary
}

for _GSQ_Mode in ["current", "before", "locked", "after", "unknown", "delayed"]
	Test("region image custody: native " . _GSQ_Mode . " copy (region-image-sequence)", _GSQ_Receive.Bind(_GSQ_Mode))
