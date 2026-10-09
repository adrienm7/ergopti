; ui/wpm/wpm_gdiplus_ownership.ahk

; ==============================================================================
; MODULE: WPM GDI+ ownership
; DESCRIPTION:
; Acquires the process-lifetime WPM graphics resources as one transaction and
; retains exact reverse-cleanup debt when a native release is refused.
; ==============================================================================

#Requires AutoHotkey v2.0





class _WPMGdipNative {
	static LoadModule() {
		return DllCall("Kernel32\LoadLibraryW", "Str", "gdiplus.dll", "Ptr")
	}

	static FreeModule(Module) {
		return DllCall("Kernel32\FreeLibrary", "Ptr", Module, "Int") != 0
	}

	static Startup(StartupInput, &Token) {
		return DllCall("gdiplus\GdiplusStartup", "Ptr*", &Token,
			"Ptr", StartupInput, "Ptr", 0)
	}

	static Shutdown(Token) {
		DllCall("gdiplus\GdiplusShutdown", "Ptr", Token)
		return true
	}

	static CreateFamily(Name, &Family) {
		return DllCall("gdiplus\GdipCreateFontFamilyFromName", "WStr", Name,
			"Ptr", 0, "Ptr*", &Family)
	}

	static DeleteFamily(Family) {
		return DllCall("gdiplus\GdipDeleteFontFamily", "Ptr", Family)
	}

	static CreateFont(Family, LabelPx, &Font) {
		return DllCall("gdiplus\GdipCreateFont", "Ptr", Family,
			"Float", LabelPx, "Int", 0, "Int", 2, "Ptr*", &Font)
	}

	static DeleteFont(Font) {
		return DllCall("gdiplus\GdipDeleteFont", "Ptr", Font)
	}

	static CreateFormat(&FormatHandle) {
		return DllCall("gdiplus\GdipCreateStringFormat", "Int", 0,
			"UShort", 0, "Ptr*", &FormatHandle)
	}

	static DeleteFormat(FormatHandle) {
		return DllCall("gdiplus\GdipDeleteStringFormat", "Ptr", FormatHandle)
	}

	static SetFormatAlign(FormatHandle) {
		return DllCall("gdiplus\GdipSetStringFormatAlign", "Ptr", FormatHandle,
			"Int", 1)
	}

	static SetFormatLineAlign(FormatHandle) {
		return DllCall("gdiplus\GdipSetStringFormatLineAlign", "Ptr", FormatHandle,
			"Int", 1)
	}
}





_WPMGdipNewReceipt() {
	return Map("module", 0, "token", 0, "family", 0, "font", 0,
		"format", 0)
}

; Releases only dependencies whose children were already released. A refused
; step leaves that handle and every dependency below it in the receipt so the
; caller can retry the exact cleanup later.
_WPMGdipRelease(Receipt, Native := _WPMGdipNative) {
	if !(Receipt is Map)
		return true
	try {
		if Receipt.Get("format", 0) {
			if Native.DeleteFormat(Receipt["format"]) != 0
				return false
			Receipt["format"] := 0
		}
		if Receipt.Get("font", 0) {
			if Native.DeleteFont(Receipt["font"]) != 0
				return false
			Receipt["font"] := 0
		}
		if Receipt.Get("family", 0) {
			if Native.DeleteFamily(Receipt["family"]) != 0
				return false
			Receipt["family"] := 0
		}
		if Receipt.Get("token", 0) {
			if Native.Shutdown(Receipt["token"]) != true
				return false
			Receipt["token"] := 0
		}
		if Receipt.Get("module", 0) {
			if Native.FreeModule(Receipt["module"]) != true
				return false
			Receipt["module"] := 0
		}
		return true
	} catch {
		return false
	}
}

_WPMGdipAcquire(LabelPx, Native := _WPMGdipNative) {
	Receipt := _WPMGdipNewReceipt()
	FailureMessage := ""
	try {
		if !IsNumber(LabelPx) or LabelPx <= 0
			throw ValueError("WPM GDI+ label size must be positive")
		Receipt["module"] := Native.LoadModule()
		if !Receipt["module"]
			throw Error("LoadLibraryW refused gdiplus.dll")

		StartupInput := Buffer(24, 0)
		NumPut("UInt", 1, StartupInput)
		Token := 0
		StartupStatus := Native.Startup(StartupInput, &Token)
		Receipt["token"] := Token
		if (StartupStatus != 0 or !Token)
			throw Error("GdiplusStartup failed with status " . StartupStatus)

		Family := 0
		FamilyStatus := Native.CreateFamily("Segoe UI", &Family)
		if (FamilyStatus != 0 or !Family) {
			if Family {
				Receipt["family"] := Family
				throw Error("Segoe UI family returned an ambiguous failed handle")
			}
			FamilyStatus := Native.CreateFamily("Arial", &Family)
		}
		Receipt["family"] := Family
		if (FamilyStatus != 0 or !Family)
			throw Error("no WPM font family could be created")

		Font := 0
		FontStatus := Native.CreateFont(Family, LabelPx, &Font)
		Receipt["font"] := Font
		if (FontStatus != 0 or !Font)
			throw Error("the WPM label font could not be created")

		FormatHandle := 0
		FormatStatus := Native.CreateFormat(&FormatHandle)
		Receipt["format"] := FormatHandle
		if (FormatStatus != 0 or !FormatHandle)
			throw Error("the WPM string format could not be created")
		if Native.SetFormatAlign(FormatHandle) != 0
			throw Error("the WPM horizontal string alignment was refused")
		if Native.SetFormatLineAlign(FormatHandle) != 0
			throw Error("the WPM vertical string alignment was refused")
		return Map("ok", true, "receipt", Receipt, "error", "")
	} catch as Err {
		FailureMessage := Err.Message
	}
	Released := _WPMGdipRelease(Receipt, Native)
	return Map("ok", false, "receipt", Released ? 0 : Receipt,
		"error", FailureMessage)
}





class _WPMGdipFrameNative {
	static CreateGraphics(MemDC, &Graphics) {
		return DllCall("gdiplus\GdipCreateFromHDC", "Ptr", MemDC,
			"Ptr*", &Graphics)
	}

	static DeleteGraphics(Graphics) {
		return DllCall("gdiplus\GdipDeleteGraphics", "Ptr", Graphics)
	}

	static SetSmoothing(Graphics) {
		return DllCall("gdiplus\GdipSetSmoothingMode", "Ptr", Graphics,
			"Int", 4)
	}

	static SetTextRendering(Graphics) {
		return DllCall("gdiplus\GdipSetTextRenderingHint", "Ptr", Graphics,
			"Int", 4)
	}

	static ScaleWorld(Graphics, Scale) {
		return DllCall("gdiplus\GdipScaleWorldTransform", "Ptr", Graphics,
			"Float", Scale, "Float", Scale, "Int", 0)
	}

	static CreatePath(&Path) {
		return DllCall("gdiplus\GdipCreatePath", "Int", 0, "Ptr*", &Path)
	}

	static DeletePath(Path) {
		return DllCall("gdiplus\GdipDeletePath", "Ptr", Path)
	}

	static AddPathArc(Path, X, Y, W, H, Start, Sweep) {
		return DllCall("gdiplus\GdipAddPathArc", "Ptr", Path,
			"Float", X, "Float", Y, "Float", W, "Float", H,
			"Float", Start, "Float", Sweep)
	}

	static ClosePath(Path) {
		return DllCall("gdiplus\GdipClosePathFigure", "Ptr", Path)
	}

	static CreateBrush(Color, &Brush) {
		return DllCall("gdiplus\GdipCreateSolidFill", "UInt", Color,
			"Ptr*", &Brush)
	}

	static DeleteBrush(Brush) {
		return DllCall("gdiplus\GdipDeleteBrush", "Ptr", Brush)
	}

	static FillPath(Graphics, Brush, Path) {
		return DllCall("gdiplus\GdipFillPath", "Ptr", Graphics,
			"Ptr", Brush, "Ptr", Path)
	}

	static CreatePen(Color, Width, &Pen) {
		return DllCall("gdiplus\GdipCreatePen1", "UInt", Color,
			"Float", Width, "Int", 2, "Ptr*", &Pen)
	}

	static DeletePen(Pen) {
		return DllCall("gdiplus\GdipDeletePen", "Ptr", Pen)
	}

	static DrawPath(Graphics, Pen, Path) {
		return DllCall("gdiplus\GdipDrawPath", "Ptr", Graphics,
			"Ptr", Pen, "Ptr", Path)
	}

	static SetClipPath(Graphics, Path) {
		return DllCall("gdiplus\GdipSetClipPath", "Ptr", Graphics,
			"Ptr", Path, "Int", 0)
	}

	static FillPolygon(Graphics, Brush, Points, Count) {
		return DllCall("gdiplus\GdipFillPolygon", "Ptr", Graphics,
			"Ptr", Brush, "Ptr", Points, "Int", Count, "Int", 0)
	}

	static DrawLines(Graphics, Pen, Points, Count) {
		return DllCall("gdiplus\GdipDrawLines", "Ptr", Graphics,
			"Ptr", Pen, "Ptr", Points, "Int", Count)
	}

	static ResetClip(Graphics) {
		return DllCall("gdiplus\GdipResetClip", "Ptr", Graphics)
	}

	static DrawString(Graphics, Text, Font, Rect, FormatHandle, Brush) {
		return DllCall("gdiplus\GdipDrawString", "Ptr", Graphics,
			"WStr", Text, "Int", -1, "Ptr", Font, "Ptr", Rect,
			"Ptr", FormatHandle, "Ptr", Brush)
	}
}





_WPMGdipNewFrameReceipt() {
	return Map("resources", [])
}

_WPMGdipFrameOwn(Receipt, Kind, Handle) {
	if !(Receipt is Map) or !(Receipt.Get("resources", 0) is Array)
		throw TypeError("WPM GDI+ frame receipt is invalid")
	if !Handle
		throw ValueError("WPM GDI+ cannot own a null " . Kind . " handle")
	Receipt["resources"].Push(Map("kind", Kind, "handle", Handle))
	return Handle
}

_WPMGdipFrameRequireCreated(Receipt, Kind, Status, Handle, Description) {
	if Handle
		_WPMGdipFrameOwn(Receipt, Kind, Handle)
	if (Status != 0 or !Handle)
		throw Error(Description . " failed with status " . Status)
	return Handle
}

_WPMGdipFrameRequireOk(Status, Description) {
	if Status != 0
		throw Error(Description . " failed with status " . Status)
}

; Releases in exact reverse acquisition order. If one native deletion is
; refused, the failed handle and every dependency below it remain in the
; receipt so a later frame can retry without creating an unbounded leak.
_WPMGdipFrameRelease(Receipt, Native := _WPMGdipFrameNative) {
	if !(Receipt is Map) or !(Receipt.Get("resources", 0) is Array)
		return true
	Resources := Receipt["resources"]
	while Resources.Length {
		Resource := Resources[Resources.Length]
		Status := -1
		try switch Resource["kind"] {
		case "brush": Status := Native.DeleteBrush(Resource["handle"])
		case "pen": Status := Native.DeletePen(Resource["handle"])
		case "path": Status := Native.DeletePath(Resource["handle"])
		case "graphics": Status := Native.DeleteGraphics(Resource["handle"])
		}
		catch
			return false
		if Status != 0
			return false
		Resources.Pop()
	}
	return true
}

_WPMGdipRunFrame(MemDC, DrawFn, Native := _WPMGdipFrameNative) {
	Receipt := _WPMGdipNewFrameReceipt()
	FailureMessage := ""
	try {
		if !HasMethod(DrawFn, "Call")
			throw TypeError("WPM GDI+ frame draw callback is not callable")
		Graphics := 0
		Status := Native.CreateGraphics(MemDC, &Graphics)
		_WPMGdipFrameRequireCreated(Receipt, "graphics", Status, Graphics,
			"GdipCreateFromHDC")
		_WPMGdipFrameRequireOk(Native.SetSmoothing(Graphics),
			"GdipSetSmoothingMode")
		_WPMGdipFrameRequireOk(Native.SetTextRendering(Graphics),
			"GdipSetTextRenderingHint")
		DrawFn.Call(Graphics, Receipt, Native)
	} catch as Err {
		FailureMessage := Err.Message
	}
	Released := _WPMGdipFrameRelease(Receipt, Native)
	if !Released and FailureMessage == ""
		FailureMessage := "native frame cleanup was refused"
	return Map("ok", FailureMessage == "" and Released,
		"receipt", Released ? 0 : Receipt, "error", FailureMessage)
}
