; platform/system/accessibility.ahk

; ==============================================================================
; MODULE: System Accessibility Adapter (AutoHotkey)
; DESCRIPTION:
; The Win32 and UI Automation calls the native windows and tooltips use to
; follow the user's accessibility settings and to reach a screen reader:
; whether high contrast is on and its system colours, whether a screen reader
; runs, the « Make text bigger » scale, an accessible name for a control whose
; visible text is a symbol, and a live-region announcement for a text that
; appears where no focus goes (a tooltip preview).
;
; FEATURES & RATIONALE:
; 1. Thin on purpose: each function is one native call, so the callers'
;    decisions (which colours, when to announce) stay pure and testable.
; 2. Reduced motion is not read here: no native Windows surface of the driver
;    animates, and the WebView2 pages get prefers-reduced-motion from the same
;    system setting through Chromium.
; 3. A failing native call is logged and answers the neutral value (no high
;    contrast, no screen reader, 100 %), so a broken query never hides a window.
; ==============================================================================





; ===================================
; ===================================
; ======= 1/ Native constants =======
; ===================================
; ===================================

; SystemParametersInfo actions and the HIGHCONTRAST flag.
global A11Y_SPI_GETHIGHCONTRAST := 0x0042
global A11Y_SPI_GETSCREENREADER := 0x0046
global A11Y_HCF_HIGHCONTRASTON := 0x0001

; GetSysColor indexes of the tooltip pair Windows recolours in high contrast.
global A11Y_SYSINDEX_INFOTEXT := 23
global A11Y_SYSINDEX_INFOBK := 24

; « Make text bigger » (Settings > Accessibility > Text size): 100 to 225 %.
global A11Y_TEXT_SCALE_KEY := "HKCU\Software\Microsoft\Accessibility"
global A11Y_TEXT_SCALE_VALUE := "TextScaleFactor"
global A11Y_TEXT_SCALE_DEFAULT := 100

; Dynamic annotation (IAccPropServices) of a control's MSAA name, which the UI
; Automation proxy of a Win32 control reports as its Name.
global A11Y_CLSID_ACC_PROP_SERVICES := "{b5f8350b-0548-48b1-a6ee-88bd00b4a5e7}"
global A11Y_IID_ACC_PROP_SERVICES := "{6e26e776-04f0-495d-80e4-3330352e3169}"
global A11Y_PROPID_ACC_NAME := "{608d3df8-8128-4aa7-a428-f55e49267291}"
global A11Y_OBJID_CLIENT := 0xFFFFFFFC
global A11Y_CHILDID_SELF := 0
; IAccPropServices::SetHwndProp and SetHwndPropStr, after IUnknown (3),
; SetPropValue, SetPropServer and ClearProps.
global A11Y_SET_HWND_PROP_SLOT := 6
global A11Y_SET_HWND_PROP_STR_SLOT := 7

; UI Automation LiveSetting (Polite) and the Win32 live-region event.
global A11Y_LIVE_SETTING_PROPERTY := "{c12bcd8e-2a8e-4950-8ae7-3625111d58eb}"
global A11Y_LIVE_SETTING_POLITE := 1
global A11Y_EVENT_OBJECT_LIVEREGIONCHANGED := 0x8019





; ==================================
; ==================================
; ======= 2/ System settings =======
; ==================================
; ==================================

; Whether Windows high contrast (a contrast theme) is on.
; @returns {Boolean}
A11ySystem_HighContrastOn() {
	global A11Y_SPI_GETHIGHCONTRAST, A11Y_HCF_HIGHCONTRASTON
	; HIGHCONTRASTW: cbSize, dwFlags, then the scheme name pointer (aligned).
	Size := 8 + A_PtrSize
	Info := Buffer(Size, 0)
	NumPut("UInt", Size, Info, 0)
	if !DllCall("SystemParametersInfoW", "UInt", A11Y_SPI_GETHIGHCONTRAST, "UInt", Size, "Ptr", Info, "UInt", 0, "Int") {
		try LoggerWarn("A11ySystem", "SPI_GETHIGHCONTRAST failed (error {1}); high contrast is taken as off.", A_LastError)
		return false
	}
	return (NumGet(Info, 4, "UInt") & A11Y_HCF_HIGHCONTRASTON) != 0
}

; Whether a screen reader (Narrator, NVDA, JAWS) told Windows it is running.
; @returns {Boolean}
A11ySystem_ScreenReaderOn() {
	global A11Y_SPI_GETSCREENREADER
	Running := Buffer(4, 0)
	if !DllCall("SystemParametersInfoW", "UInt", A11Y_SPI_GETSCREENREADER, "UInt", 0, "Ptr", Running, "UInt", 0, "Int") {
		try LoggerWarn("A11ySystem", "SPI_GETSCREENREADER failed (error {1}); no screen reader is assumed.", A_LastError)
		return false
	}
	return NumGet(Running, 0, "Int") != 0
}

; The « Make text bigger » scale, in percent (100 when never set).
; @returns {Integer} 100 to 225.
A11ySystem_TextScalePercent() {
	global A11Y_TEXT_SCALE_KEY, A11Y_TEXT_SCALE_VALUE, A11Y_TEXT_SCALE_DEFAULT
	; The largest scale Settings > Accessibility > Text size offers (an OS fact).
	static ScaleMax := 225
	try Value := RegRead(A11Y_TEXT_SCALE_KEY, A11Y_TEXT_SCALE_VALUE, A11Y_TEXT_SCALE_DEFAULT)
	catch as Err {
		try LoggerWarn("A11ySystem", "The text scale could not be read: {1}.", Err.Message)
		return A11Y_TEXT_SCALE_DEFAULT
	}
	if !IsInteger(Value)
		return A11Y_TEXT_SCALE_DEFAULT
	return Max(A11Y_TEXT_SCALE_DEFAULT, Min(ScaleMax, Integer(Value)))
}

; A system colour as the "RRGGBB" text a Gui option takes.
; @param Index {Integer} A GetSysColor index (A11Y_SYSINDEX_*).
; @returns {String}
A11ySystem_SysColorHex(Index) {
	Bgr := DllCall("GetSysColor", "Int", Index, "UInt")
	return Format("{1:02X}{2:02X}{3:02X}", Bgr & 0xFF, (Bgr >> 8) & 0xFF, (Bgr >> 16) & 0xFF)
}

; The settings the native tooltips follow, read in one place.
; @returns {Object} { HighContrast, TextScalePercent, InfoBkHex, InfoTextHex }.
A11ySystem_State() {
	global A11Y_SYSINDEX_INFOBK, A11Y_SYSINDEX_INFOTEXT
	return {
		HighContrast: A11ySystem_HighContrastOn(),
		TextScalePercent: A11ySystem_TextScalePercent(),
		InfoBkHex: A11ySystem_SysColorHex(A11Y_SYSINDEX_INFOBK),
		InfoTextHex: A11ySystem_SysColorHex(A11Y_SYSINDEX_INFOTEXT)
	}
}





; ==================================================
; ==================================================
; ======= 3/ Names and screen-reader notices =======
; ==================================================
; ==================================================

; Sets one dynamic annotation (IAccPropServices) on a window's client object.
; @param Hwnd {Integer} The window or control.
; @param PropGuid {String} The MSAA/UIA property GUID.
; @param Value {String|Integer} A string, or a 32-bit integer sent as VT_I4.
_A11ySystem_SetHwndProp(Hwnd, PropGuid, Value) {
	global A11Y_CLSID_ACC_PROP_SERVICES, A11Y_IID_ACC_PROP_SERVICES
	global A11Y_OBJID_CLIENT, A11Y_CHILDID_SELF, A11Y_SET_HWND_PROP_SLOT, A11Y_SET_HWND_PROP_STR_SLOT
	if !Hwnd || !DllCall("IsWindow", "Ptr", Hwnd, "Int")
		throw ValueError("No window to annotate", -1, Hwnd)
	Services := ComObject(A11Y_CLSID_ACC_PROP_SERVICES, A11Y_IID_ACC_PROP_SERVICES)
	PropId := Buffer(16, 0)
	if DllCall("ole32\CLSIDFromString", "WStr", PropGuid, "Ptr", PropId, "Int") != 0
		throw ValueError("The property GUID did not parse", -1, PropGuid)
	IsText := Value is String
	Slot := IsText ? A11Y_SET_HWND_PROP_STR_SLOT : A11Y_SET_HWND_PROP_SLOT
	Variant := Buffer(A_PtrSize = 8 ? 24 : 16, 0)
	if !IsText {
		NumPut("UShort", 3, Variant, 0)   ; VT_I4
		NumPut("Int", Value, Variant, 8)
	}
	; A GUID or VARIANT passed by value travels by reference on x64 and as its
	; 32-bit words on x86.
	Args := ["Ptr", Hwnd, "UInt", A11Y_OBJID_CLIENT, "UInt", A11Y_CHILDID_SELF]
	for Block in [PropId, IsText ? 0 : Variant] {
		if !IsObject(Block)
			continue
		if (A_PtrSize = 8)
			Args.Push("Ptr", Block)
		else
			Loop Block.Size // 4
				Args.Push("UInt", NumGet(Block, (A_Index - 1) * 4, "UInt"))
	}
	if IsText
		Args.Push("WStr", Value)
	ComCall(Slot, Services, Args*)
}

; Gives a control the accessible name a screen reader says, when its visible
; text is a symbol (« ↺ ») or nothing at all.
; @param Hwnd {Integer} The control's window handle.
; @param Name {String} The name, already translated.
; @returns {Boolean} Whether the name was set.
A11ySystem_SetAccessibleName(Hwnd, Name) {
	global A11Y_PROPID_ACC_NAME
	try {
		_A11ySystem_SetHwndProp(Hwnd, A11Y_PROPID_ACC_NAME, String(Name))
		return true
	} catch as Err {
		try LoggerWarn("A11ySystem", "The accessible name '{1}' could not be set: {2}.", Name, Err.Message)
		return false
	}
}

; Asks a running screen reader to say a text that appeared where no focus goes:
; the window becomes a polite live region named by the text, then announces
; its change. This is the Win32 live-region contract (IAccPropServices and
; EVENT_OBJECT_LIVEREGIONCHANGED). A UI Automation notification raised in
; process was refused: releasing its host provider blocked the window's own
; thread, which here is the keyboard driver's.
; @param Hwnd {Integer} A window of this process the text is shown in.
; @param Text {String} What to say.
; @returns {Boolean} Whether the live region was announced.
A11ySystem_Announce(Hwnd, Text) {
	global A11Y_PROPID_ACC_NAME, A11Y_LIVE_SETTING_PROPERTY, A11Y_LIVE_SETTING_POLITE
	global A11Y_EVENT_OBJECT_LIVEREGIONCHANGED, A11Y_OBJID_CLIENT, A11Y_CHILDID_SELF
	if (Text == "")
		return false
	try {
		_A11ySystem_SetHwndProp(Hwnd, A11Y_PROPID_ACC_NAME, String(Text))
		_A11ySystem_SetHwndProp(Hwnd, A11Y_LIVE_SETTING_PROPERTY, A11Y_LIVE_SETTING_POLITE)
		DllCall("NotifyWinEvent", "UInt", A11Y_EVENT_OBJECT_LIVEREGIONCHANGED, "Ptr", Hwnd,
			"Int", A11Y_OBJID_CLIENT, "Int", A11Y_CHILDID_SELF)
		return true
	} catch as Err {
		try LoggerWarn("A11ySystem", "The screen-reader live region could not be announced: {1}.", Err.Message)
		return false
	}
}
