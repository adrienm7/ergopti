; tests/meta/test_tap_hold_menu_register_dispatch.ahk

; ==============================================================================
; MODULE: TapHolds Menu RegisterMenuItem Dispatch Meta Test
; DESCRIPTION:
; Regression guard for HIGH-07: fix-trapholds-menu-raw-add-drops-clicks.
;
; The Tap-Hold submenu's actionable items (_TH_DynResetDefaults,
; _TH_DynDisableAll, _TH_DynKeys, _BuildHoldPickerSubmenu) used raw
; Menu.Add(Label, Callback) for every actionable callback. AHK 2.0's
; WM_COMMAND -> menu-callback dispatch silently drops ~1 click in 3.
; lib/menu_dispatcher.ahk installs a parallel WM_COMMAND retry path, but ONLY
; for items registered via RegisterMenuItem(MenuObj, Label, Callback).
;
; Since the Tap-Hold block used raw .Add, those items were never in the retry
; path and roughly one in three clicks on reset-defaults, disable-all,
; per-key tap/hold pickers, or per-key disable silently did nothing.
;
; The fix replaces the five raw two-argument .Add calls with RegisterMenuItem,
; keeping the existing ObjBindMethod/bound-function callbacks:
;   _TH_DynResetDefaults  : M.Add  → RegisterMenuItem(M, ...)
;   _TH_DynDisableAll     : M.Add  → RegisterMenuItem(M, ...)
;   _TH_DynKeys disable   : KeyMenu.Add → RegisterMenuItem(KeyMenu, ...)
;   _TH_DynKeys tap-picker: KeyMenu.Add → RegisterMenuItem(KeyMenu, ...)
;   _BuildHoldPickerSubmenu: PickerMenu.Add → RegisterMenuItem(PickerMenu, ...)
;
; Parent-submenu adds (M.Add(ParentLabel, KeyMenu), KeyMenu.Add(HoldPickerLabel,
; HoldPickerMenu)) and separator adds (KeyMenu.Add()) remain as raw .Add —
; those are the sanctioned exceptions in the dispatcher documentation.
;
; SCOPE: source introspection of ui/tray_menu.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ============================================
; ============================================
; ======= 1/ Source scan helpers =============
; ============================================
; ============================================

_THRD_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}


; ================================================
; ================================================
; ======= 2/ Test implementations ================
; ================================================
; ================================================

_THRD_CheckResetDefaultsRegistered() {
	Src := _THRD_ReadSource("ui/tray_menu.ahk")
	Assert(Src != "", "ui/tray_menu.ahk must be readable")

	Body := _DriverFuncBody("_TH_DynResetDefaults")
	Assert(Body != "", "_TH_DynResetDefaults must be present in ui/tray_menu.ahk")

	Assert(InStr(Body, "RegisterMenuItem("),
		"_TH_DynResetDefaults must use RegisterMenuItem (not raw M.Add) for the reset-defaults action (HIGH-07)")
	Assert(!InStr(Body, "M.Add(t(" . Chr(34) . "tap_hold.reset_defaults" . Chr(34) . "), _TH_ResetAllToDefaults)"),
		"_TH_DynResetDefaults must NOT use raw M.Add for the reset-defaults callback — use RegisterMenuItem")
}

_THRD_CheckDisableAllRegistered() {
	Src := _THRD_ReadSource("ui/tray_menu.ahk")
	Assert(Src != "", "ui/tray_menu.ahk must be readable")

	Body := _DriverFuncBody("_TH_DynDisableAll")
	Assert(Body != "", "_TH_DynDisableAll must be present in ui/tray_menu.ahk")

	Assert(InStr(Body, "RegisterMenuItem("),
		"_TH_DynDisableAll must use RegisterMenuItem (not raw M.Add) for the disable-all action (HIGH-07)")
	Assert(!InStr(Body, "M.Add(t(" . Chr(34) . "tap_hold.disable_all" . Chr(34) . "), _TH_DisableAll)"),
		"_TH_DynDisableAll must NOT use raw M.Add for the disable-all callback — use RegisterMenuItem")
}

_THRD_CheckDynKeysRegistered() {
	Src := _THRD_ReadSource("ui/tray_menu.ahk")
	Assert(Src != "", "ui/tray_menu.ahk must be readable")

	Body := _DriverFuncBody("_TH_DynKeys")
	Assert(Body != "", "_TH_DynKeys must be present in ui/tray_menu.ahk")

	; Disable label and tap-picker must use RegisterMenuItem.
	Assert(InStr(Body, "RegisterMenuItem(KeyMenu, DisableLabel"),
		"_TH_DynKeys must use RegisterMenuItem for the per-key disable item (HIGH-07)")
	Assert(InStr(Body, "RegisterMenuItem(KeyMenu, TapPickerLabel"),
		"_TH_DynKeys must use RegisterMenuItem for the per-key tap-picker item (HIGH-07)")

	; Raw two-arg .Add for those callbacks must be absent.
	Assert(!InStr(Body, "KeyMenu.Add(DisableLabel, _TH_MakeDisableFn"),
		"_TH_DynKeys must NOT use raw KeyMenu.Add for the disable callback — use RegisterMenuItem")
	Assert(!InStr(Body, "KeyMenu.Add(TapPickerLabel, _TH_MakeTapPickerFn"),
		"_TH_DynKeys must NOT use raw KeyMenu.Add for the tap-picker callback — use RegisterMenuItem")
}

_THRD_CheckHoldPickerRegistered() {
	Src := _THRD_ReadSource("ui/tray_menu.ahk")
	Assert(Src != "", "ui/tray_menu.ahk must be readable")

	Body := _DriverFuncBody("_BuildHoldPickerSubmenu")
	Assert(Body != "", "_BuildHoldPickerSubmenu must be present in ui/tray_menu.ahk")

	Assert(InStr(Body, "RegisterMenuItem(PickerMenu, Label"),
		"_BuildHoldPickerSubmenu must use RegisterMenuItem for each hold option (HIGH-07)")
	Assert(!InStr(Body, "PickerMenu.Add(Label, _TH_MakeHoldFn"),
		"_BuildHoldPickerSubmenu must NOT use raw PickerMenu.Add for hold-option callbacks — use RegisterMenuItem")
}


Test("meta fix-tapholds-menu-raw-add: _TH_DynResetDefaults uses RegisterMenuItem",
	_THRD_CheckResetDefaultsRegistered)

Test("meta fix-tapholds-menu-raw-add: _TH_DynDisableAll uses RegisterMenuItem",
	_THRD_CheckDisableAllRegistered)

Test("meta fix-tapholds-menu-raw-add: _TH_DynKeys disable and tap-picker use RegisterMenuItem",
	_THRD_CheckDynKeysRegistered)

Test("meta fix-tapholds-menu-raw-add: _BuildHoldPickerSubmenu hold options use RegisterMenuItem",
	_THRD_CheckHoldPickerRegistered)
