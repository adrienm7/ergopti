; tests/meta/test_traymenu_separator_addstandard.ahk

; ==============================================================================
; MODULE: TrayMenu Separator-vs-AddStandard Meta Test
; DESCRIPTION:
; Static source guard for the finding traymenu-separator-addstandard.
;
; adapters/tray_menu.ahk TrayMenuSetMenu() builds the tray context menu from
; the shared Items array. A separator entry must be added with a zero-argument
; A_TrayMenu.Add(). The original code called A_TrayMenu.AddStandard() instead —
; a distinct API that appends the WHOLE default AHK script-control menu (a live
; Exit / Reload Script / Suspend Hotkeys), which the product UI deliberately
; hides. That dumped an unintended kill/reload surface into the user's menu and
; rendered the separator as a block of standard items.
;
; The fix: the separator branch calls A_TrayMenu.Add() (no args) and never
; A_TrayMenu.AddStandard(). This is a meta-static test (scans source text)
; because adapters/tray_menu.ahk's setMenu mutates the live A_TrayMenu and its
; actionable-item path now references RegisterMenuItem, which is not in the
; headless run_all include graph — calling it would be a load-time error.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Source scan helpers ====================
; ===================================================
; ===================================================

_TMSAS_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ===================================================
; ===================================================
; ======= 2/ Separator-API assertions ===============
; ===================================================
; ===================================================

_TMSAS_SeparatorUsesBareAdd() {
	Src := _TMSAS_ReadSource("adapters/tray_menu.ahk")
	Seg := _DriverFuncBody("TrayMenuSetMenu")
	Assert(Seg != "", "TrayMenuSetMenu(Items) must exist in adapters/tray_menu.ahk")
	Assert(InStr(Seg, "A_TrayMenu.Add()") > 0,
		"TrayMenuSetMenu separator branch must call A_TrayMenu.Add() (no args) for a separator")
}
Test("tray_menu: separator uses A_TrayMenu.Add() not AddStandard() (traymenu-separator-addstandard)", _TMSAS_SeparatorUsesBareAdd)

_TMSAS_NoAddStandard() {
	Src := _TMSAS_ReadSource("adapters/tray_menu.ahk")
	Seg := _DriverFuncBody("TrayMenuSetMenu")
	; Match the real call form A_TrayMenu.AddStandard so the explanatory
	; source comment (which names the bare AddStandard API) is not a false hit.
	Assert(InStr(Seg, "A_TrayMenu.AddStandard") = 0,
		"TrayMenuSetMenu must NOT call A_TrayMenu.AddStandard() — it dumps the default AHK Exit/Reload/Suspend menu the product UI hides")
}
Test("tray_menu: TrayMenuSetMenu never calls AddStandard() (traymenu-separator-addstandard)", _TMSAS_NoAddStandard)
