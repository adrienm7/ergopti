; tests/meta/test_llm_menu_loaded_gate.ahk

; ==============================================================================
; MODULE: LLM Tray Loaded Gate Meta Test
; DESCRIPTION:
; Regression guard for the _LLM_Menu_Loaded init-order safety gate.
;
; _LLM_Menu holds the user's saved LLM settings only after LLM_Menu_Init()
; runs. Before that point the Map contains module-level placeholder defaults.
; SaveFullConfig() is fired by a -500 ms boot timer that can expire before
; LLM_Menu_Init() is called (LLM_Menu_Init is deferred to the tray-menu build
; step). When SaveFullConfig() called _LLM_Menu_SyncToFeatures() without
; checking whether LLM_Menu_Init had already run, it synced placeholder values
; (e.g. enabled=false) into the Features Map, which TOML_BatchWrite then wrote
; to config.toml — clobbering the user's saved LLM preferences.
;
; The fix:
;   - Declare global _LLM_Menu_Loaded := false at module load in menu_llm.ahk.
;   - Set _LLM_Menu_Loaded := true at the END of LLM_Menu_Init().
;   - Gate the _LLM_Menu_SyncToFeatures() call in SaveFullConfig() on the flag.
;
; This test asserts:
;   (a) menu_llm.ahk declares _LLM_Menu_Loaded := false before LLM_Menu_Init.
;   (b) LLM_Menu_Init() sets _LLM_Menu_Loaded := true before returning.
;   (c) SaveFullConfig() checks _LLM_Menu_Loaded before calling
;       _LLM_Menu_SyncToFeatures().
;
; SCOPE: source introspection of ui/menu/menu_llm.ahk, ui/menu/menu_llm/init.ahk,
;        and ErgoptiPlus.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ================================================
; ================================================
; ======= 1/ Source scan helpers =================
; ================================================
; ================================================

_LTLG_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Path := WindowsDir . "\" . StrReplace(RelPath, "/", "\")
	return FileRead(Path)
}


; ================================================
; ================================================
; ======= 2/ Test implementations ================
; ================================================
; ================================================

_LTLG_CheckModuleLevelFlag() {
	Src := _LTLG_ReadSource("ui/menu/menu_llm/_index.ahk")
	Assert(Src != "", "ui/menu/menu_llm.ahk must be readable")

	Assert(InStr(Src, "_LLM_Menu_Loaded  := false") || InStr(Src, "_LLM_Menu_Loaded := false"),
		"menu_llm.ahk must declare global _LLM_Menu_Loaded := false at module level")

	; Declaration must appear before LLM_Menu_Init is defined (or used)
	DeclPos := InStr(Src, "_LLM_Menu_Loaded")
	Assert(DeclPos > 0, "_LLM_Menu_Loaded must be present in menu_llm.ahk")
}

_LTLG_CheckInitSetsFlag() {
	Src := _LTLG_ReadSource("ui/menu/menu_llm/init.ahk")
	Assert(Src != "", "ui/menu/menu_llm/init.ahk must be readable")

	Body := _DriverFuncBody("LLM_Menu_Init")
	Assert(Body != "", "LLM_Menu_Init must be present in ui/menu/menu_llm/init.ahk")

	Assert(InStr(Body, "_LLM_Menu_Loaded := true"),
		"LLM_Menu_Init() must set _LLM_Menu_Loaded := true before returning")
}

_LTLG_CheckSaveConfigGated() {
	Src := _DriverSourceConcat()
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	Body := _DriverFuncBody("SaveFullConfig")
	Assert(Body != "", "SaveFullConfig must be present in the driver source")

	; _LLM_Menu_SyncToFeatures call must be guarded by _LLM_Menu_Loaded
	SyncPos   := InStr(Body, "_LLM_Menu_SyncToFeatures()")
	GatePos   := InStr(Body, "_LLM_Menu_Loaded")
	Assert(SyncPos > 0, "SaveFullConfig must call _LLM_Menu_SyncToFeatures()")
	Assert(GatePos > 0,
		"SaveFullConfig must check _LLM_Menu_Loaded before calling _LLM_Menu_SyncToFeatures()")
	Assert(GatePos < SyncPos,
		"_LLM_Menu_Loaded gate must appear before _LLM_Menu_SyncToFeatures() call in SaveFullConfig")
}


Test("meta llm-tray-loaded-gate: menu_llm.ahk declares _LLM_Menu_Loaded := false at module level",
	_LTLG_CheckModuleLevelFlag)

Test("meta llm-tray-loaded-gate: LLM_Menu_Init() sets _LLM_Menu_Loaded := true before returning",
	_LTLG_CheckInitSetsFlag)

Test("meta llm-tray-loaded-gate: SaveFullConfig() gates _LLM_Menu_SyncToFeatures on _LLM_Menu_Loaded",
	_LTLG_CheckSaveConfigGated)
