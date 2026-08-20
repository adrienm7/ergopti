; tests/meta/test_toml_batchwrite_atomic.ahk

; ==============================================================================
; MODULE: TOML BatchWrite Atomic Meta Test
; DESCRIPTION:
; Static source guard for the "toml-batchwrite-nonatomic-config-loss" finding.
; TOML_BatchWrite must use the write-through atomic filesystem adapter instead
; of deleting the destination or relying on a non-durable language-level move.
; ==============================================================================

#Requires AutoHotkey v2.0

_TBA_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}

_TBA_BatchWriteIsAtomic() {
	Src := _TBA_ReadSource("infra/toml/toml_helpers.ahk")
	Wrapper := _DriverFuncBody("TOML_BatchWrite")
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Wrapper != "" && Seg != "",
		"TOML_BatchWrite and its shared renderer must exist")
	Assert(InStr(Wrapper,
		'_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write")') > 0,
		"the public writer must select the shared renderer's write mode explicitly")
	
	Assert(InStr(Seg, "FileDelete(Path)") == 0,
		"TOML_BatchWrite must NOT delete the target file first (toml-batchwrite-nonatomic-config-loss)")
		
	Assert(InStr(Seg, "FSAtomicMoveReplace(tmp, Path)") > 0,
		"TOML_BatchWrite must publish through the write-through atomic adapter")
	Assert(InStr(Seg, "FileMove(") == 0,
		"TOML_BatchWrite must not bypass the write-through adapter")
	FlushPos := InStr(Seg, "FSFlushFileBuffers(f)")
	VerifyPos := InStr(Seg, "_TOML_StageMatches(tmp, body)")
	MovePos := InStr(Seg, "FSAtomicMoveReplace(tmp, Path)")
	Assert(FlushPos > 0 && VerifyPos > FlushPos && MovePos > VerifyPos,
		"flush and exact stage verification must precede atomic publication")
}
Test("toml_helpers: TOML_BatchWrite uses write-through atomic replace "
	. "(toml-write-through-atomic)", _TBA_BatchWriteIsAtomic)
