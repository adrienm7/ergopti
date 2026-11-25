; tests/unit/modules/shortcuts/test_keep_awake_library_window.ahk

; ==============================================================================
; MODULE: Anti-Sleep Library Window (Windows)
; DESCRIPTION:
; Pins what the Windows library window writes for the other drivers: the
; presets document and an exported preset carry the switches as JSON
; booleans, and a taken preset or image id gets a fresh one.
;
; ROOT CAUSE ENCODED:
; The document was written with the generic encoder, so its switches became
; 1 and 0: a preset exported from Windows would be refused by the macOS and
; Linux store, which accepts booleans only.
; ==============================================================================

#Requires AutoHotkey v2.0

_TKAL_BooleansStayBooleans() {
	Preset := Map("id", "p", "keep_awake", 1, "auto_click", 0, "images", [Map("id", "b", "enabled", 1, "threshold", 0.9)])
	Text := KeepAwakeLibraryJson(Preset)
	AssertTrue(InStr(Text, '"keep_awake":true'), "keep_awake is a boolean: " . Text)
	AssertTrue(InStr(Text, '"auto_click":false'), "auto_click is a boolean: " . Text)
	AssertTrue(InStr(Text, '"enabled":true'), "enabled is a boolean: " . Text)
	AssertTrue(InStr(Text, '"threshold":0.9'), "a number stays a number: " . Text)
	Back := JsonParse(Text)
	AssertEqual(1, Back["keep_awake"], "the Windows store reads it back")
}
Test("keep-awake library: switches are written as JSON booleans (keep-awake-library-booleans)", _TKAL_BooleansStayBooleans)

_TKAL_FreshIds() {
	Taken := Map("vscode", true, "vscode_2", true)
	AssertEqual("teams", KeepAwakeLibraryFreshId("teams", (Id) => Taken.Has(Id)), "a free id is kept")
	AssertEqual("vscode_3", KeepAwakeLibraryFreshId("vscode", (Id) => Taken.Has(Id)), "a taken id gets the next number")
	AssertEqual("a_b", KeepAwakeLibraryFreshId("a b", (Id) => false), "characters outside an id are replaced")
}
Test("keep-awake library: an import never reuses a taken id (keep-awake-library-fresh-id)", _TKAL_FreshIds)
