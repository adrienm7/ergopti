; tests/meta/test_toml_batchwrite_cache_coherence.ahk

; =============================================================================
; MODULE: TOML BatchWrite Cache Coherence Meta Test
; DESCRIPTION:
; Static source guard for the "toml-batchwrite-cache-mutation" finding.
; TOML_BatchWrite must deep-copy the cached Map before mutating it, and must
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
	Seg := _DriverFuncBody("TOML_BatchWrite")
	Assert(Seg != "", "TOML_BatchWrite declaration must exist")

	; The cached Map must be cloned before any mutation so that a write failure
	; cannot leave stale un-persisted values in the in-memory cache.
	Assert(InStr(Seg, "Cached.Clone()") > 0,
		"TOML_BatchWrite must Clone() the cached Map before mutating it (F37)")
	Assert(InStr(Seg, "Sections[sec].Clone()") > 0,
		"TOML_BatchWrite must Clone() each section Map before mutating it (F37)")
}
Test("toml_helpers: TOML_BatchWrite deep-copies cached Map before mutation", _TBCC_DeepCopyPresent)


_TBCC_FailurePathsInvalidateCache() {
	Src := _TBCC_ReadSource("infra/toml/toml_helpers.ahk")
	Seg := _DriverFuncBody("TOML_BatchWrite")
	Assert(Seg != "", "TOML_BatchWrite declaration must exist")

	; Count distinct cache-invalidation blocks inside the function body.
	; There must be at least three: one for each failure return path
	; (FileOpen returns falsy, FileOpen throws, FileMove throws) plus
	; the existing success-path invalidation.
	DeleteCount := 0
	Pos := 1
	loop {
		Found := InStr(Seg, "_ParseTomlCache.Delete(Path)", , Pos)
		if !Found
			break
		DeleteCount += 1
		Pos := Found + 1
	}
	Assert(DeleteCount >= 4,
		"TOML_BatchWrite must call _ParseTomlCache.Delete(Path) on all failure paths and on success (F37), found: " . DeleteCount)
}
Test("toml_helpers: TOML_BatchWrite invalidates cache on all failure paths", _TBCC_FailurePathsInvalidateCache)