; tests/meta/test_toml_batchwrite_atomic.ahk

; ==============================================================================
; MODULE: TOML BatchWrite Atomic Meta Test
; DESCRIPTION:
; Static source guard for the "toml-batchwrite-nonatomic-config-loss" finding.
; TOML_BatchWrite must use an atomic FileMove with overwrite=true instead of
; deleting the destination file first, to prevent config loss on crash.
; ==============================================================================

#Requires AutoHotkey v2.0

_TBA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TBA_BatchWriteIsAtomic() {
	Src := _TBA_ReadSource("infra/toml/toml_helpers.ahk")
	Seg := _DriverFuncBody("TOML_BatchWrite")
	Assert(Seg != "", "TOML_BatchWrite declaration must exist")
	
	Assert(InStr(Seg, "FileDelete(Path)") == 0,
		"TOML_BatchWrite must NOT delete the target file first (toml-batchwrite-nonatomic-config-loss)")
		
	Assert(InStr(Seg, "FileMove(tmp, Path, true)") > 0,
		"TOML_BatchWrite must use atomic FileMove with overwrite=true")
}
Test("toml_helpers: TOML_BatchWrite uses atomic FileMove", _TBA_BatchWriteIsAtomic)
