; infra/hotstrings/hotstring_backspace_steps.ahk

; ==============================================================================
; MODULE: Hotstring Backspace Steps per Text Host
; DESCRIPTION:
; What one Backspace erases depends on the control that has the focus, so the
; Backspace undo cannot count code points everywhere. Measured on Windows 11 on
; 2026-11-17 (_shared/tests/corpus/hotstrings/backspace_step_vectors.json):
; a Win32 EDIT erases one code point; a RichEdit erases a combining accent or a
; regional indicator alone but a skin tone, a ZWJ sequence or VS16 with its
; base; Chromium erases a combining accent alone but a whole emoji, flag or ZWJ
; cluster. Any other host keeps the code-point count.
;
; FEATURES & RATIONALE:
; 1. The family comes from the focused control's class, then the top-level
;    window's: the Store Notepad's RichEditD2DPT and the classic Notepad's Edit
;    share one window class.
; 2. Plain text, accents included, counts one step per code point in every
;    family, so only emoji change the Backspace count.
; ==============================================================================





; ==============================
; ==============================
; ======= 1/ Host family =======
; ==============================
; ==============================

; The test seam that reads a control's class; 0 reads it from Win32.
global _HSE_BACKSPACE_CLASS_PROBE := 0

; Installs the control-class reader, or restores the Win32 one with 0.
; @param ClassProbe {Func|0} (Hwnd) => class name, or false when unreadable.
HSE_BackspaceStepsConfigure(ClassProbe := 0) {
	global _HSE_BACKSPACE_CLASS_PROBE
	if ClassProbe != 0 && !HasMethod(ClassProbe, "Call")
		throw TypeError("HSE_BackspaceStepsConfigure expects a callable probe or 0.")
	_HSE_BACKSPACE_CLASS_PROBE := ClassProbe
}

; The Backspace family of a host from its class names.
; @param ControlClass {String} The focused control's class, "" when unreadable.
; @param WindowClass {String} The top-level window's class, "" when unknown.
; @returns {String} "edit", "richedit", "chromium" or "other".
HSE_BackspaceHostFamily(ControlClass, WindowClass) {
	if !(ControlClass is String) || !(WindowClass is String)
		throw TypeError("HSE_BackspaceHostFamily expects two class-name strings.")
	; WinForms text boxes are superclassed Win32 EDIT and RichEdit controls.
	if RegExMatch(ControlClass, "i)^(Edit|WindowsForms10\.EDIT\..*)$")
		return "edit"
	if InStr(ControlClass, "RichEdit")
		return "richedit"
	; The web content has its render widget; the omnibox and an Electron app
	; without one focus the top-level Chromium window itself.
	Chromium := "i)^(Chrome_RenderWidgetHostHWND|Chrome_WidgetWin_\d+)$"
	if RegExMatch(ControlClass, Chromium) || RegExMatch(WindowClass, Chromium)
		return "chromium"
	return "other"
}

; The Backspace family of the focused control.
; @param FocusToken {Integer} The focused control's HWND (WIGetFocusedControlToken).
; @param WindowClass {String} The top-level class of the output-host receipt.
; @returns {String} The family, as HSE_BackspaceHostFamily.
HSE_BackspaceFamilyOfFocus(FocusToken, WindowClass) {
	global _HSE_BACKSPACE_CLASS_PROBE
	ClassName := _HSE_BACKSPACE_CLASS_PROBE ? _HSE_BACKSPACE_CLASS_PROBE.Call(FocusToken)
		: _WIReadClassNameLocal(FocusToken)
	return HSE_BackspaceHostFamily(ClassName is String ? ClassName : "", WindowClass)
}





; ==================================
; ==================================
; ======= 2/ Backspace steps =======
; ==================================
; ==================================

; Splits a text into what successive Backspaces erase in a host family.
; @param Text {String} The text before the caret.
; @param Family {String} "edit", "richedit", "chromium" or "other".
; @returns {Array} The segments in text order; the last one goes first.
HSE_BackspaceSegments(Text, Family) {
	if !(Text is String)
		throw TypeError("HSE_BackspaceSegments expects a string, got " . Type(Text) . ".")
	if !(Family == "edit" || Family == "richedit" || Family == "chromium" || Family == "other")
		throw ValueError("Unknown Backspace host family: " . Family)
	Segments := []
	Clusters := Family == "richedit" || Family == "chromium"
	AfterJoiner := false
	RegionalOpen := false
	for Character in _TextCodepoints(Text) {
		Code := Ord(Character)
		Regional := Code >= 0x1F1E6 && Code <= 0x1F1FF
		Joins := Clusters && Segments.Length > 0 && (AfterJoiner
			|| Code == 0x200D
			|| (Code >= 0xFE00 && Code <= 0xFE0F)
			|| (Code >= 0x1F3FB && Code <= 0x1F3FF)
			|| (Family == "chromium" && Regional && RegionalOpen))
		if Joins
			Segments[Segments.Length] .= Character
		else
			Segments.Push(Character)
		; A flag is a pair of regional indicators: the third starts a new one.
		RegionalOpen := Regional && !(Joins && RegionalOpen)
		AfterJoiner := Clusters && Code == 0x200D
	}
	return Segments
}

; The number of Backspaces that erase a text in a host family.
; @param Text {String} The text before the caret.
; @param Family {String} "edit", "richedit", "chromium" or "other".
; @returns {Integer} The Backspace count.
HSE_BackspaceSteps(Text, Family) => HSE_BackspaceSegments(Text, Family).Length
