; tests/meta/test_config_window_patch_toml_meta_error.ahk

; ==============================================================================
; MODULE: HCW PatchTomlMeta Error Handling Meta Test
; DESCRIPTION:
; Static source guard for the "hcw-patch-toml-meta-bare-try" finding.
; _HCW_PatchTomlMeta must use a try/catch block with an explicit Logger call
; on failure instead of a bare try that swallows write errors silently.
; ==============================================================================

#Requires AutoHotkey v2.0

_PTME_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_PTME_FuncBody(Src, FuncDef) {
	Idx := InStr(Src, FuncDef)
	if !Idx
		return ""
	Rest := SubStr(Src, Idx)
	End := InStr(Rest, "`n}")
	if End
		return SubStr(Rest, 1, End + 1)
	return Rest
}

_PTME_PatchTomlMetaHasCatch() {
	Src := _PTME_ReadSource("lib/hotstrings/hotstrings_config_window.ahk")
	Assert(Src != "", "Source file hotstrings_config_window.ahk must exist")

	Body := _PTME_FuncBody(Src, "_HCW_PatchTomlMeta(Path, Sec, Field, Value) {")
	Assert(Body != "", "_HCW_PatchTomlMeta declaration must exist")

	Assert(InStr(Body, "catch") > 0,
		"_HCW_PatchTomlMeta must have a catch block (not a bare try)")

	Assert(InStr(Body, "Logger") > 0,
		"_HCW_PatchTomlMeta catch block must call Logger to report the write failure")
}
Test("hotstrings_config_window: _HCW_PatchTomlMeta catch block logs write failure", _PTME_PatchTomlMetaHasCatch)