; tests/meta/test_llm_tray_loaded_gate.ahk

; ==============================================================================
; MODULE: LLM Tray Loaded Gate Meta Test
; DESCRIPTION:
; Regression guard for the _LLM_Tray_Loaded init-order safety gate.
;
; _LLM_Tray holds the user's saved LLM settings only after LLM_Tray_Init()
; runs. Before that point the Map contains module-level placeholder defaults.
; SaveFullConfig() is fired by a -500 ms boot timer that can expire before
; LLM_Tray_Init() is called (LLM_Tray_Init is deferred to the tray-menu build
; step). When SaveFullConfig() called _LLM_Tray_SyncToFeatures() without
; checking whether LLM_Tray_Init had already run, it synced placeholder values
; (e.g. enabled=false) into the Features Map, which TOML_BatchWrite then wrote
; to config.toml — clobbering the user's saved LLM preferences.
;
; The fix:
;   - Declare global _LLM_Tray_Loaded := false at module load in tray_llm.ahk.
;   - Set _LLM_Tray_Loaded := true at the END of LLM_Tray_Init().
;   - Gate the _LLM_Tray_SyncToFeatures() call in SaveFullConfig() on the flag.
;
; This test asserts:
;   (a) tray_llm.ahk declares _LLM_Tray_Loaded := false before LLM_Tray_Init.
;   (b) LLM_Tray_Init() sets _LLM_Tray_Loaded := true before returning.
;   (c) SaveFullConfig() checks _LLM_Tray_Loaded before calling
;       _LLM_Tray_SyncToFeatures().
;
; SCOPE: source introspection of ui/tray_llm.ahk, ui/tray_llm/init.ahk,
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

_LTLG_FuncBody(Src, FnDecl) {
	FnPos := InStr(Src, FnDecl)
	if (!FnPos)
		return ""
	depth := 0
	i := FnPos
	Len := StrLen(Src)
	while (i <= Len) {
		ch := SubStr(Src, i, 1)
		if (ch == "{")
			depth++
		else if (ch == "}") {
			depth--
			if (depth <= 0)
				return SubStr(Src, FnPos, i - FnPos + 1)
		}
		i++
	}
	return SubStr(Src, FnPos)
}


; ================================================
; ================================================
; ======= 2/ Test implementations ================
; ================================================
; ================================================

_LTLG_CheckModuleLevelFlag() {
	Src := _LTLG_ReadSource("ui/tray_llm.ahk")
	Assert(Src != "", "ui/tray_llm.ahk must be readable")

	Assert(InStr(Src, "_LLM_Tray_Loaded  := false") || InStr(Src, "_LLM_Tray_Loaded := false"),
		"tray_llm.ahk must declare global _LLM_Tray_Loaded := false at module level")

	; Declaration must appear before LLM_Tray_Init is defined (or used)
	DeclPos := InStr(Src, "_LLM_Tray_Loaded")
	Assert(DeclPos > 0, "_LLM_Tray_Loaded must be present in tray_llm.ahk")
}

_LTLG_CheckInitSetsFlag() {
	Src := _LTLG_ReadSource("ui/tray_llm/init.ahk")
	Assert(Src != "", "ui/tray_llm/init.ahk must be readable")

	Body := _LTLG_FuncBody(Src, "LLM_Tray_Init(")
	Assert(Body != "", "LLM_Tray_Init must be present in ui/tray_llm/init.ahk")

	Assert(InStr(Body, "_LLM_Tray_Loaded := true"),
		"LLM_Tray_Init() must set _LLM_Tray_Loaded := true before returning")
}

_LTLG_CheckSaveConfigGated() {
	Src := _LTLG_ReadSource("ErgoptiPlus.ahk")
	Assert(Src != "", "ErgoptiPlus.ahk must be readable")

	Body := _LTLG_FuncBody(Src, "SaveFullConfig()")
	Assert(Body != "", "SaveFullConfig must be present in ErgoptiPlus.ahk")

	; _LLM_Tray_SyncToFeatures call must be guarded by _LLM_Tray_Loaded
	SyncPos   := InStr(Body, "_LLM_Tray_SyncToFeatures()")
	GatePos   := InStr(Body, "_LLM_Tray_Loaded")
	Assert(SyncPos > 0, "SaveFullConfig must call _LLM_Tray_SyncToFeatures()")
	Assert(GatePos > 0,
		"SaveFullConfig must check _LLM_Tray_Loaded before calling _LLM_Tray_SyncToFeatures()")
	Assert(GatePos < SyncPos,
		"_LLM_Tray_Loaded gate must appear before _LLM_Tray_SyncToFeatures() call in SaveFullConfig")
}


Test("meta llm-tray-loaded-gate: tray_llm.ahk declares _LLM_Tray_Loaded := false at module level",
	_LTLG_CheckModuleLevelFlag)

Test("meta llm-tray-loaded-gate: LLM_Tray_Init() sets _LLM_Tray_Loaded := true before returning",
	_LTLG_CheckInitSetsFlag)

Test("meta llm-tray-loaded-gate: SaveFullConfig() gates _LLM_Tray_SyncToFeatures on _LLM_Tray_Loaded",
	_LTLG_CheckSaveConfigGated)
