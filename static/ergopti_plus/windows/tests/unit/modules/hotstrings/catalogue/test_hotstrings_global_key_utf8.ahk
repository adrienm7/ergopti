; tests/unit/modules/hotstrings/catalogue/test_hotstrings_global_key_utf8.ahk

; ==============================================================================
; MODULE: Global Delimiter UTF-8 Reader Regressions
; DESCRIPTION:
; Real BOM-less UTF-8 override files must round-trip independently of the thread's
; ambient code page. Native BOM handling, comments and string escapes stay intact.
; ==============================================================================

#Requires AutoHotkey v2.0

_HGKU_Case(Mode) {
	SavedEncoding := A_FileEncoding
	Root := A_Temp . "\ergopti global utf8 §-" . A_ScriptHwnd . "-" . A_TickCount . "-" . Mode
	Owned := false
	try {
		FSCreateDirectoryExclusiveStrict(Root)
		Owned := true
		Path := Root . "\overrides.toml"
		Word := "§" . Chr(0x1F600) . "#" . Chr(34) . "\" . Chr(9)
		Consumed := "§" . Chr(0x1F600)
		; The writer's explicit encoding must work even when this thread uses ACP.
		FileEncoding("CP1252")
		Ambient := A_FileEncoding
		AssertEqual("CP1252", Ambient, "the fixture must exercise a real non-UTF-8 ambient code page")
		if Mode == "writer" {
			Overrides := Map("rolls", { Delay: 0.2, Color: "#112233", ShowTooltip: "",
				Priority: "", Sections: Map() })
			AssertTrue(_SaveOverrides(Overrides, 0, 0, Word, Consumed, Path),
				"the genuine override writer must publish its real BOM-less UTF-8 image")
		} else {
			Source := "[__global__] # delimiter owner`r`n"
				. 'word_delimiters = "§😀#\"\\\t" # ignored comment "quote"' . "`r`n"
				. 'consumed_delimiters = "§😀" # ignored comment' . "`r`n"
				. '[rolls] # ordinary sibling' . "`r`n"
				. 'delay = 0.2' . "`r`n" . 'color = "#112233"' . "`r`n"
			if Mode == "bom"
				Source := Chr(0xFEFF) . Source
			AssertTrue(FSWriteCreateDurable(Path, Source) == 1,
				"the fixture must author exact UTF-8 bytes without relying on FileEncoding")
		}
		Before := FSReadBytesStrict(Path)
		HasBom := Before.Size >= 3 && NumGet(Before, 0, "UChar") == 0xEF
			&& NumGet(Before, 1, "UChar") == 0xBB && NumGet(Before, 2, "UChar") == 0xBF
		AssertEqual(Mode == "bom", HasBom, "the intended physical BOM contract must be observed")
		AssertEqual(Word, _ParseGlobalKey(Path, "word_delimiters"),
			"Unicode, literal hashes, quotes, backslashes and tabs must survive the actual global reader")
		AssertEqual(Consumed, _ParseGlobalKey(Path, "consumed_delimiters"),
			"both global delimiter keys must use the file's UTF-8 contract")
		AssertEqual("", _ParseGlobalKey(Path, "missing_key"), "absent keys retain their existing sentinel")
		Sibling := _ParseOverrides(Path)
		AssertEqual(0.2, Sibling["rolls"].Delay, "the explicit UTF-8 sibling reader remains consistent")
		AssertEqual("#112233", Sibling["rolls"].Color)
		AssertEqual(Ambient, A_FileEncoding, "reading the file must not change the ambient thread encoding")
		After := FSReadBytesStrict(Path)
		AssertEqual(Before.Size, After.Size, "neither reader may rewrite the source")
		AssertEqual(Before.Size, DllCall("ntdll\RtlCompareMemory", "Ptr", Before,
			"Ptr", After, "UPtr", Before.Size, "UPtr"), "all source bytes remain unchanged")
	} finally {
		FileEncoding(SavedEncoding)
		if Owned
			DirDelete(Root, true)
	}
	AssertEqual(SavedEncoding, A_FileEncoding, "the fixture restores the exact incoming encoding")
}

for _HGKU_Mode in ["raw", "bom", "writer"]
	Test("Hotstrings global UTF-8: " . _HGKU_Mode . " retains exact delimiters (hotstrings-global-key-utf8)",
		_HGKU_Case.Bind(_HGKU_Mode))
