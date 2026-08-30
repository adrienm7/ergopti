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
