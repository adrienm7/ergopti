; platform/system/locale.ahk

; Native Windows UI-language observation, separate from regional formats.
#Requires AutoHotkey v2.0

; Returns the UI language's ISO 639 code, or "" if Windows cannot resolve it.
NativeSystemUiLanguageCode() {
	try {
		LanguageId := DllCall("Kernel32\GetUserDefaultUILanguage", "UShort")
		if !LanguageId
			return ""
		Buf := Buffer(32, 0)
		Len := DllCall("Kernel32\GetLocaleInfoW", "UInt", LanguageId, "UInt", 0x59,
			"Ptr", Buf, "Int", 16, "Int")
		return Len > 1 ? StrGet(Buf, "UTF-16") : ""
	} catch {
		return ""
	}
}
