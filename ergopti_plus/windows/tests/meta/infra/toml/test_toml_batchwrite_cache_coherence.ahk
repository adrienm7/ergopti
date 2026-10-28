; tests/meta/infra/toml/test_toml_batchwrite_cache_coherence.ahk

; =============================================================================
; MODULE: TOML BatchWrite Cache Coherence Meta Test
; DESCRIPTION:
; Static source guard for the "toml-batchwrite-cache-mutation" finding.
; TOML_BatchWrite must deep-copy the parsed Map before mutating it, and must
; invalidate the cache on every failure return path, not only on success.
; =============================================================================

#Requires AutoHotkey v2.0

_TBCC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}





; =============================================
; =============================================
; ======= 1/ Cache coherence assertions =======
; =============================================
; =============================================

_TBCC_DeepCopyPresent() {
	Src := _TBCC_ReadSource("infra/toml/toml_helpers.ahk")
	Wrapper := _DriverFuncBody("TOML_BatchWrite")
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Wrapper != "" && Seg != "",
		"TOML_BatchWrite and its shared implementation must exist")
	Assert(InStr(Wrapper,
		'_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write", , , false, AdmissionFn)') > 0,
		"the public writer must delegate to the implementation whose cache isolation is checked below")

	; The parsed Map must be cloned before any mutation so that candidate
	; rendering and publication cannot mutate their source snapshot.
	Assert(RegExMatch(Seg,
		"Sections\s*:=\s*[A-Za-z_][A-Za-z0-9_]*\.Clone\(\)") > 0,
		"TOML_BatchWrite must Clone() the parsed Map before mutating it (F37)")
	Assert(InStr(Seg, "Sections[sec].Clone()") > 0,
		"TOML_BatchWrite must Clone() each section Map before mutating it (F37)")
}
Test("toml_helpers: TOML_BatchWrite deep-copies parsed Map before mutation", _TBCC_DeepCopyPresent)


_TBCC_FailurePathsInvalidateCache() {
	Src := _TBCC_ReadSource("infra/toml/toml_helpers.ahk")
	Wrapper := _DriverFuncBody("TOML_BatchWrite")
	Seg := _DriverFuncBody("_TOML_BatchWriteImpl")
	Assert(Wrapper != "" && Seg != "",
		"TOML_BatchWrite and its shared implementation must exist")
	Assert(InStr(Wrapper,
		'_TOML_BatchWriteImpl(Path, Updates, ExactSectionPrefixes, "write", , , false, AdmissionFn)') > 0,
		"cache invalidation must be checked on the implementation reached by the public writer")

	; Count distinct cache-invalidation blocks inside the function body.
	; There must be at least three: one for each failure return path
	; (FileOpen returns falsy, FileOpen throws, FileMove throws) plus
	; the existing success-path invalidation.
	DeleteCount := 0
	Pos := 1
	loop {
		Found := InStr(Seg, "_TOML_InvalidateParseCache(Path)", , Pos)
		if !Found
			break
		DeleteCount += 1
		Pos := Found + 1
	}
	Assert(DeleteCount >= 4,
		"TOML_BatchWrite must retire the parsed generation on failure paths and success (F37), found: " . DeleteCount)
	Invalidate := _DriverFuncBody("_TOML_InvalidateParseCache")
	Assert(Invalidate != "", "the actual invalidation owner must exist")
	Retire := InStr(Invalidate, "Owners.Delete(Key)")
	Probe := InStr(Invalidate, "_ParseTomlCache.Has(Path)")
	Assert(Retire > 0 && Probe > Retire,
		"an absent cache entry must still revoke an interrupted parse generation")
	Assert(InStr(Invalidate, "_ParseTomlCache.Delete(Path)") > Probe,
		"the shared owner must still evict an existing cached model")
}
Test("toml_helpers: TOML_BatchWrite invalidates cache on all failure paths", _TBCC_FailurePathsInvalidateCache)
