; tests/unit/test_parsetomlgroupconfig_missing_file_cache_key.ahk

; ==============================================================================
; MODULE: ParseTomlGroupConfig Missing-File Cache-Key Test
; DESCRIPTION:
; Behavioral regression for finding parsetomlgroupconfig-missing-file-cache-key.
;
; ParseTomlGroupConfig looks up its cache under CacheKey (= FilePath when an
; explicit path is given). The missing-file early-return used to store the empty
; Config under LowerCat instead, so an explicit-path call for a missing file
; never cache-hit and re-stat'd the file on every resolve. The fix stores it
; under CacheKey, so after a missing-path call the cache is keyed by FilePath.
;
; This test calls ParseTomlGroupConfig("", <nonexistent path>) and asserts the
; entry is cached under the file path. Fails before the fix (cached under "").
; ==============================================================================

#Requires AutoHotkey v2.0





; ==================================================
; ==================================================
; ======= 1/ Missing-file cache-key behavior =======
; ==================================================
; ==================================================

_PTGMFK_MissingFileCachedUnderPath() {
	global HotstringGroupConfig
	; A deterministic path that cannot exist on the CI runner.
	TmpPath := A_ScriptDir . "\does_not_exist_ptgmfk.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}
	; Clear any stale cache entries from a previous run (both possible keys).
	if HotstringGroupConfig.Has(TmpPath) {
		HotstringGroupConfig.Delete(TmpPath)
	}
	if HotstringGroupConfig.Has("") {
		HotstringGroupConfig.Delete("")
	}

	; First resolve of a missing explicit-path file: must cache the empty Config.
	ParseTomlGroupConfig("", TmpPath)

	Assert(HotstringGroupConfig.Has(TmpPath),
		"missing-file Config must be cached under the FilePath CacheKey so explicit-path lookups cache-hit and invalidation can reach it")
	Assert(!HotstringGroupConfig.Has(""),
		"missing-file Config must NOT be cached under the bare LowerCat key when an explicit path was supplied")

	if HotstringGroupConfig.Has(TmpPath) {
		HotstringGroupConfig.Delete(TmpPath)
	}
}
Test("toml_loader: missing-file Config caches under FilePath key (parsetomlgroupconfig-missing-file-cache-key)",
	_PTGMFK_MissingFileCachedUnderPath)
