; tests/meta/test_config_window_patch_toml_meta_error.ahk

; ==============================================================================
; MODULE: HCW PatchTomlMeta Error Handling Meta Test
; DESCRIPTION:
; Static source guard for the "hcw-patch-toml-meta-bare-try" finding.
; _HCW_PatchTomlMeta must use a try/catch block with an explicit Logger call
; on failure instead of a bare try that swallows write errors silently.
; ==============================================================================

#Requires AutoHotkey v2.0


_PTME_PatchTomlMetaHasCatch() {
	Src := _DriverDirConcat("ui/hotstrings_config_window")
	Assert(Src != "", "Source file hotstrings_config_window.ahk must exist")

	Body := _DriverFuncBody("_HCW_PatchTomlMeta")
	Assert(Body != "", "_HCW_PatchTomlMeta declaration must exist")

	Assert(InStr(Body, "catch") > 0,
		"_HCW_PatchTomlMeta must have a catch block (not a bare try)")

	Assert(InStr(Body, "Logger") > 0,
		"_HCW_PatchTomlMeta catch block must call Logger to report the write failure")
}
Test("hotstrings_config_window: _HCW_PatchTomlMeta catch block logs write failure", _PTME_PatchTomlMetaHasCatch)