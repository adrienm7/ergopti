; tests/unit/test_loadexttoml_skips_meta_sections.ahk

; ==============================================================================
; MODULE: LoadExtTomlFile Skips Meta Sections Test
; DESCRIPTION:
; Behavioral regression for loadexttoml-registers-meta-as-hotstrings.
;
; A personal_hotstrings.toml carries [_meta] / [_meta.sections] blocks that
; describe the file (file description, section labels). These are NOT hotstrings.
; LoadExtTomlFile registered every key="value" line via the simple entry pattern
; WITHOUT excluding the meta blocks, so the line `description = "Hotstrings
; personnels"` became a live trigger: typing "description" expanded to
; "Hotstrings personnels", and each [_meta.sections] label became a trigger too.
;
; The fix skips any section whose name is "_meta" or contains "_meta." (mirroring
; CountTomlSection and _HotstringsCacheBuildRows). This test feeds LoadExtTomlFile
; a TOML with meta blocks plus one real [[section]] entry and asserts that only
; the real entry registers — the meta keys must register nothing.
; ==============================================================================

#Requires AutoHotkey v2.0





; =====================================================
; =======================================================
; ======= 1/ Meta keys never register as triggers =======
; =======================================================
; =====================================================

; Case-insensitive lookup for a registered trigger abbreviation. Specs are of the
; form ":flags:abbrev"; the abbreviation is the segment after the second colon.
_LXTSM_HasTrigger(Abbrev) {
	global _Stub_HotstringRegistrations
	Target := StrLower(Abbrev)
	for Reg in _Stub_HotstringRegistrations {
		Parts := StrSplit(Reg.spec, ":")
		if (Parts.Length >= 3 and StrLower(Parts[3]) == Target)
			return true
	}
	return false
}

_LXTSM_MetaNotRegistered() {
	global ScriptInformation, _Stub_HotstringRegistrations
	if !IsSet(ScriptInformation)
		ScriptInformation := Map()
	if !ScriptInformation.Has("MagicKey")
		ScriptInformation["MagicKey"] := Chr(0x2605)

	TmpPath := A_ScriptDir . "\lxtsm_meta.toml"
	if FileExist(TmpPath)
		FileDelete(TmpPath)

	; Metadata blocks (file description + section labels) followed by one real
	; [[section]] entry — exactly the shape of a personal_hotstrings.toml.
	Content := "[_meta]`r`n"
		. "description = " . Chr(34) . "Hotstrings personnels" . Chr(34) . "`r`n"
		. "sections_order = [" . Chr(34) . "mysec" . Chr(34) . "]`r`n"
		. "[_meta.sections]`r`n"
		. "mysec = " . Chr(34) . "My section label" . Chr(34) . "`r`n"
		. "[[mysec]]`r`n"
		. Chr(34) . "abc" . Chr(34) . " = { output = " . Chr(34) . "expanded" . Chr(34)
		. ", is_word = true, auto_expand = true, is_case_sensitive = true, final_result = true }`r`n"
	FileAppend(Content, TmpPath, "UTF-8")

	ResetHotstringRecorders()
	LoadExtTomlFile(TmpPath, "test")

	AssertTrue(_LXTSM_HasTrigger("abc"),
		"the real [[mysec]] entry must still register as a hotstring")
	AssertTrue(!_LXTSM_HasTrigger("description"),
		"[_meta] 'description' key must NOT register (was expanding 'description' to 'Hotstrings personnels')")
	AssertTrue(!_LXTSM_HasTrigger("mysec"),
		"[_meta.sections] section labels must NOT register as hotstrings")

	FileDelete(TmpPath)
}
Test("toml_loader: LoadExtTomlFile skips [_meta]/[_meta.sections] (loadexttoml-registers-meta-as-hotstrings)",
	_LXTSM_MetaNotRegistered)
