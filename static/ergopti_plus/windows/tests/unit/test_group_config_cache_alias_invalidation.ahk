; tests/unit/test_group_config_cache_alias_invalidation.ahk

; ==============================================================================
; MODULE: Regression — invalidating a TOML path must drop EVERY alias of it
; DESCRIPTION:
; ParseTomlGroupConfig caches a file's [_meta] block under the key it was CALLED
; with, not under the file it resolved to. The engine/tooltip resolver reaches
; personal_hotstrings.toml as the bare category "personal"; the hotstring config
; window reaches the same file by absolute path. One file, two cache entries.
;
; ROOT CAUSE ENCODED:
; _ParseTomlGroupConfig_InvalidatePath only ever deleted the absolute-path key —
; the only key the window's own reader creates. Editing a personal delay,
; priority, colour or show_tooltip therefore invalidated the entry the WINDOW
; reads and left the entry the ENGINE reads untouched. The republish that
; follows re-registered every personal hotstring from the pre-edit value while
; the window displayed the new one, and the tooltip (reading through the same
; stale entry) agreed with the engine, so even the preview-vs-engine guard had
; nothing to flag. No restart short of a full process reload cleared it.
;
; The fix resolves the file through one shared helper and evicts every cache key
; that resolves to it, so an alias cannot outlive its file.
; ==============================================================================

#Requires AutoHotkey v2.0





; ================================================================
; ================================================================
; ======= 1/ A bare-category cache entry must be evicted ========
; ================================================================
; ================================================================

_GCA_PersonalAliasIsEvictedByPathInvalidation() {
	global ScriptInformation, HotstringGroupConfig
	TmpPath := A_Temp . "\ergopti_gca_" . A_TickCount . ".toml"
	OldPath := ScriptInformation["PersonalTomlPath"]
	try {
		ScriptInformation["PersonalTomlPath"] := TmpPath
		if HotstringGroupConfig.Has("personal")
			HotstringGroupConfig.Delete("personal")
		if HotstringGroupConfig.Has(TmpPath)
			HotstringGroupConfig.Delete(TmpPath)

		FileAppend("[_meta]`r`ndelay = 0.5`r`n", TmpPath, "UTF-8")
		; The bare-category call is the one the engine and the tooltip make.
		First := ParseTomlGroupConfig("personal")
		AssertEqual(0.5, First.Delay,
			"the personal group's [_meta] delay must load — without this the case below cannot distinguish stale from absent")

		; Simulate the config window's write: the file changes on disk, then the
		; window invalidates BY PATH, which is the only key it knows.
		FileDelete(TmpPath)
		FileAppend("[_meta]`r`ndelay = 3.0`r`n", TmpPath, "UTF-8")
		_ParseTomlGroupConfig_InvalidatePath(TmpPath)

		Second := ParseTomlGroupConfig("personal")
		AssertEqual(3.0, Second.Delay,
			"invalidating a file path must drop EVERY cache entry that resolves to that file: the personal category is cached under the key 'personal' while the config window invalidates by absolute path, so a personal delay/priority edit re-registered the engine from the pre-edit value while the window displayed the new one")
	} finally {
		ScriptInformation["PersonalTomlPath"] := OldPath
		if HotstringGroupConfig.Has("personal")
			HotstringGroupConfig.Delete("personal")
		if HotstringGroupConfig.Has(TmpPath)
			HotstringGroupConfig.Delete(TmpPath)
		try HotstringsResolveBumpGen()
		try FileDelete(TmpPath)
	}
}


; The eviction must stay surgical: dropping unrelated categories on every write
; would turn a per-file invalidation into a full cache flush and re-read every
; bundled category file from the keyboard thread.
_GCA_UnrelatedCategoriesSurviveInvalidation() {
	global HotstringGroupConfig
	TmpPath := A_Temp . "\ergopti_gca_other_" . A_TickCount . ".toml"
	Sentinel := { Delay: 1.25, Color: "", ShowTooltip: "", Priority: "", Sections: Map() }
	HotstringGroupConfig["rolls"] := Sentinel
	try {
		_ParseTomlGroupConfig_InvalidatePath(TmpPath)
		Assert(HotstringGroupConfig.Has("rolls"),
			"invalidating one file must not evict a cache entry that resolves to a different file")
	} finally {
		if HotstringGroupConfig.Has("rolls")
			HotstringGroupConfig.Delete("rolls")
		try HotstringsResolveBumpGen()
	}
}


Test("toml_loader: invalidating a path evicts the bare-category alias of the same file",
	_GCA_PersonalAliasIsEvictedByPathInvalidation)
Test("toml_loader: invalidating a path leaves unrelated cached categories alone",
	_GCA_UnrelatedCategoriesSurviveInvalidation)
