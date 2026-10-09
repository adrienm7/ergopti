; infra/menu_command_origin.ahk

; ==============================================================================
; MODULE: Menu Command Origin
; DESCRIPTION:
; Classifies WM_COMMAND messages without depending on menu dispatcher state.
; Menu selections and accelerators/control notifications share the same message,
; so both HIWORD(wParam) and lParam are required to establish the origin.
; ==============================================================================

#Requires AutoHotkey v2.0+





; =========================================
; =========================================
; ======= 1/ WM_COMMAND classification ====
; =========================================
; =========================================

; Returns true only for a menu selection. Accelerators use notify code 1;
; controls carry their HWND in lParam, including BN_CLICKED whose code is zero.
; @param WParam {Integer} WM_COMMAND identifier and notification code.
; @param LParam {Integer} Zero for menus/accelerators, control HWND otherwise.
; @return {Boolean} True only for a menu-originated command.
MenuCommandOrigin_IsMenuSelection(WParam, LParam) {
	NotifyCode := (WParam >> 16) & 0xFFFF
	return NotifyCode == 0 && LParam == 0
}
