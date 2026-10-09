; tests/unit/test_counttoml_overcounts_personal_meta_sections.ahk

; ==============================================================================
; MODULE: CountToml Meta-Section Over-Count Test
; DESCRIPTION:
; Behavioral regression for finding counttoml-overcounts-personal-meta-sections.
;
; CountTomlHotstrings / CountTomlSection excluded only the flat metadata section
; names ("_meta", "_meta.sections") with an equality check, so the dotted
; per-section form the config window writes ([_meta.sections.<name>]) slipped
; through and its delay/color/priority/description lines were counted as
; hotstrings. The fix skips any section whose name is "_meta" or starts with
; "_meta." (mirroring _HotstringsCacheBuildRows).
;
; This builds a TOML with a [_meta.sections.accents] block (4 metadata lines)
; plus a real [[accents]] section with exactly 3 entries and asserts the count
; is 3 (was 7 before the fix). toml_loader.ahk is in the run_all include graph
; and CountTomlHotstrings has no OS/COM/hotkey side effects, so this is safe as
; a behavioral headless-unit test.
; ==============================================================================

#Requires AutoHotkey v2.0




; ====================================================
; ====================================================
; ======= 1/ Dotted meta-section exclusion ===========
; ====================================================
; ====================================================

_CTOPMS_BuildEntry(Trigger, Output) {
	; A full inline-table hotstring entry exactly as the generator writes them.
	return Chr(34) . Trigger . Chr(34)
		. " = { output = " . Chr(34) . Output . Chr(34)
		. ", is_word = true, auto_expand = false, is_case_sensitive = true, final_result = false }`r`n"
}

_CTOPMS_DottedMetaNotCounted() {
	TmpPath := A_ScriptDir . "\ctopms_meta.toml"
	if FileExist(TmpPath) {
		FileDelete(TmpPath)
	}

	; A dotted per-section metadata block (4 lines) followed by a real section
	; carrying exactly 3 hotstring entries. The metadata lines must NOT count.
	Content := "[_meta.sections.accents]`r`n"
		. "delay = 0.3`r`n"
		. "color = " . Chr(34) . "#FFCC00" . Chr(34) . "`r`n"
		. "priority = 55`r`n"
		. "description = " . Chr(34) . "Accent helpers" . Chr(34) . "`r`n"
		. "`r`n"
		. "[[accents]]`r`n"
		. _CTOPMS_BuildEntry("aaa", "alpha")
		. _CTOPMS_BuildEntry("bbb", "beta")
		. _CTOPMS_BuildEntry("ccc", "gamma")
	FileAppend(Content, TmpPath, "UTF-8")

	; Explicit path bypasses the personal/_shared resolution; clear any stale
	; per-file count cache by using a fresh path name each run + final delete.
	AssertEqual(3, CountTomlHotstrings("x", TmpPath),
		"the four [_meta.sections.accents] metadata lines must NOT be counted as hotstrings; only the 3 real [[accents]] entries count")
	AssertEqual(3, CountTomlSection("x", "accents", TmpPath),
		"CountTomlSection must report 3 real entries for the accents section, ignoring the dotted meta block")
	AssertEqual(0, CountTomlSection("x", "_meta.sections.accents", TmpPath),
		"the dotted meta-section must carry zero counted hotstrings (its delay/color/priority/description lines are metadata, not entries)")

	FileDelete(TmpPath)
}
Test("toml_loader: dotted [_meta.sections.<x>] lines are not counted as hotstrings (counttoml-overcounts-personal-meta-sections)",
	_CTOPMS_DottedMetaNotCounted)
