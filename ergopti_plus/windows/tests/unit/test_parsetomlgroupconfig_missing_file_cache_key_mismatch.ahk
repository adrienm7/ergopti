; tests/unit/test_parsetomlgroupconfig_missing_file_cache_key_mismatch.ahk

; ==============================================================================
; MODULE: ParseTomlGroupConfig Cache-Key Invalidation Test
; DESCRIPTION:
; Behavioral regression for finding
; parsetomlgroupconfig-missing-file-cache-key-mismatch.
;
; Root cause: the missing-file early-return stored the empty Config under
; LowerCat while both the cache lookup and _ParseTomlGroupConfig_InvalidatePath
; key on CacheKey (= FilePath for explicit-path calls). With the keys mismatched,
; an explicit-path missing-file entry was unreachable by invalidation, so a stale
; empty Config could linger. The fix stores it under CacheKey, restoring the
; invariant that the store key, the lookup key and the invalidation key all
; agree for explicit-path calls.
;
; This pins that invariant directly: after a missing-file parse the entry must be
; reachable under the FilePath key (so invalidation can delete it), and after
; invalidation it must be gone. Before the fix the entry sits under "" and
; .Has(TmpPath) is false right after the parse, so the first assertion fails.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================================
; =========================================================
; ======= 1/ Store / lookup / invalidate key parity =======
; =========================================================
; =========================================================

_PTGKM_KeyParityAcrossStoreAndInvalidate() {
	global HotstringGroupConfig
	TmpPath := A_ScriptDir . "\ptgkm_invalidate.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	if HotstringGroupConfig.Has(TmpPath) {
		HotstringGroupConfig.Delete(TmpPath)
	}
	if HotstringGroupConfig.Has("") {
		HotstringGroupConfig.Delete("")
	}

	; Probe a missing file by explicit path: the empty Config must be cached
	; under the FilePath key so a later invalidation can reach it.
	ParseTomlGroupConfig("", TmpPath)
	Assert(HotstringGroupConfig.Has(TmpPath),
		"missing-file Config must be reachable under the FilePath key; otherwise _ParseTomlGroupConfig_InvalidatePath cannot evict it")

	; Invalidation keys on the same FilePath; it must clear the entry.
	_ParseTomlGroupConfig_InvalidatePath(TmpPath)
	Assert(!HotstringGroupConfig.Has(TmpPath),
		"after _ParseTomlGroupConfig_InvalidatePath the FilePath-keyed empty Config must be gone, so a re-probe re-reads disk instead of returning a stale empty Config")

	if HotstringGroupConfig.Has(TmpPath) {
		HotstringGroupConfig.Delete(TmpPath)
	}
}
Test("toml_loader: store/lookup/invalidate share the FilePath key (parsetomlgroupconfig-missing-file-cache-key-mismatch)",
	_PTGKM_KeyParityAcrossStoreAndInvalidate)
