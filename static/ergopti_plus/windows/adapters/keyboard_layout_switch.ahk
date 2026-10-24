; adapters/keyboard_layout_switch.ahk

; ==============================================================================
; MODULE: Keyboard Layout Switch (Windows)
; DESCRIPTION:
; Lists the keyboard layouts installed for the user and makes one active, for
; the automatic layout switch on a pause, a resume and a quit
; (_shared/modules/features/pause_switch_policy.ahk decides which).
;
; FEATURES & RATIONALE:
; 1. A layout is stored by its KLID, the registry name of the layout
;    ("0000040C", "A000040C"), never by its HKL: the handle of a layout with a
;    custom id ("0xF0C0040C") is assigned per session and changes when layouts
;    are added, the KLID does not. The HKL is found again from the installed
;    list at switch time.
; 2. The switch posts WM_INPUTLANGCHANGEREQUEST to the foreground window, the
;    request a user's own layout hotkey makes; with the Windows default « use
;    the same input method for all apps » it applies to the whole session.
; 3. Every native call is a port (list, registry, post), so the tests replay
;    every path without a desktop. A refusal returns false with its reason
;    logged, never a pretended switch.
; ==============================================================================

#Requires AutoHotkey v2.0




global KLS_WM_INPUTLANGCHANGEREQUEST := 0x0050
global KLS_LAYOUTS_KEY := "HKLM\SYSTEM\CurrentControlSet\Control\Keyboard Layouts"
; A layout handle whose high word starts with 0xF carries a layout id instead
; of a KLID: its low twelve bits name the registry "Layout Id" value.
global KLS_CUSTOM_LAYOUT_MASK := 0xF000
global KLS_LAYOUT_ID_MASK := 0x0FFF


/**
 * The KLID of an installed layout handle.
 * @param {Integer} Hkl Keyboard layout handle.
 * @param {Func} LookupFn Optional port: LookupFn(LayoutIdHex) returns the KLID
 *   whose "Layout Id" value is that four-digit hex id, or "".
 * @returns {String} The KLID, "" when a custom layout id has no registry entry.
 */
KLS_LayoutId(Hkl, LookupFn := 0) {
	global KLS_CUSTOM_LAYOUT_MASK, KLS_LAYOUT_ID_MASK
	if !(Hkl is Integer) || Hkl == 0
		throw TypeError("a keyboard layout handle is required")
	Device := (Hkl >> 16) & 0xFFFF
	if ((Device & KLS_CUSTOM_LAYOUT_MASK) == KLS_CUSTOM_LAYOUT_MASK) {
		if !HasMethod(LookupFn, "Call")
			LookupFn := _KLS_RegistryLookup
		return LookupFn.Call(Format("{:04x}", Device & KLS_LAYOUT_ID_MASK))
	}
	return Format("{:08X}", Device)
}

; Finds the KLID whose registry "Layout Id" is LayoutIdHex.
_KLS_RegistryLookup(LayoutIdHex) {
	global KLS_LAYOUTS_KEY
	Loop Reg, KLS_LAYOUTS_KEY, "K" {
		; Only layouts with a custom id carry the value: its absence is the
		; ordinary case for a standard layout, not a failure.
		LayoutId := RegRead(A_LoopRegKey . "\" . A_LoopRegName, "Layout Id", "")
		if (StrLower(LayoutId) == LayoutIdHex)
			return StrUpper(A_LoopRegName)
	}
	return ""
}

; The display name of a KLID, from its registry "Layout Text".
_KLS_RegistryLabel(Klid) {
	global KLS_LAYOUTS_KEY
	try return RegRead(KLS_LAYOUTS_KEY . "\" . Klid, "Layout Text")
	catch as Err {
		try LoggerWarn("KeyboardLayoutSwitch", "Layout {1} has no readable name: {2}.", Klid, Err.Message)
		return Klid
	}
}

/**
 * The installed layouts, in the order Windows lists them.
 * @param {Func} ListFn Optional port returning the installed HKLs (Array).
 * @param {Func} LookupFn Optional custom layout id port (see KLS_LayoutId).
 * @param {Func} LabelFn Optional port: LabelFn(Klid) returns its display name.
 * @returns {Array} Maps { id: KLID, label, hkl }; a layout whose KLID cannot be
 *   resolved is left out and logged.
 */
KLS_Choices(ListFn := 0, LookupFn := 0, LabelFn := 0) {
	if !HasMethod(ListFn, "Call")
		ListFn := KS_InstalledKeyboardLayouts
	if !HasMethod(LabelFn, "Call")
		LabelFn := _KLS_RegistryLabel
	Choices := []
	Seen := Map()
	for Hkl in ListFn.Call() {
		Klid := KLS_LayoutId(Hkl, LookupFn)
		if (Klid == "") {
			try LoggerWarn("KeyboardLayoutSwitch", "Installed layout {1} has no registry entry; it is not offered.",
				Format("0x{:X}", Hkl))
			continue
		}
		; Two languages can share one layout: the first handle Windows lists wins.
		if Seen.Has(Klid)
			continue
		Seen[Klid] := true
		Choices.Push(Map("id", Klid, "label", LabelFn.Call(Klid), "hkl", Hkl))
	}
	return Choices
}

/**
 * Makes one installed layout active in the foreground window.
 * @param {String} Klid Target layout id.
 * @param {Func} ListFn Optional installed-layout port (see KLS_Choices).
 * @param {Func} PostFn Optional port: PostFn(Hkl) posts the change request and
 *   throws when it cannot be delivered.
 * @param {Func} LookupFn Optional custom layout id port.
 * @returns {Integer|Boolean} 1 once the request is posted, false when the layout
 *   is not installed or the request could not be delivered.
 */
KLS_Select(Klid, ListFn := 0, PostFn := 0, LookupFn := 0) {
	if !(Klid is String) || Klid == ""
		throw ValueError("a layout id is required")
	if !HasMethod(PostFn, "Call")
		PostFn := _KLS_PostRequest
	for Choice in KLS_Choices(ListFn, LookupFn, (Id) => Id) {
		if (Choice["id"] != Klid)
			continue
		try PostFn.Call(Choice["hkl"])
		catch as Err {
			try LoggerError("KeyboardLayoutSwitch", "Layout {1} could not be requested: {2}.", Klid, Err.Message)
			return false
		}
		return 1
	}
	try LoggerError("KeyboardLayoutSwitch", "Layout {1} is not installed for this user.", Klid)
	return false
}

; Posts the language change to the foreground window, as the user's own layout
; hotkey does. PostMessage throws when there is no foreground window.
_KLS_PostRequest(Hkl) {
	global KLS_WM_INPUTLANGCHANGEREQUEST
	PostMessage(KLS_WM_INPUTLANGCHANGEREQUEST, 0, Hkl, , "A")
}
