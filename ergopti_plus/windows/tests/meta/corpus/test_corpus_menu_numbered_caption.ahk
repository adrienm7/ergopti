; tests/meta/corpus/test_corpus_menu_numbered_caption.ahk

; ==============================================================================
; MODULE: Numbered Caption Corpus Consumer (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/menu/numbered_caption_vectors.json through the real
; menu renderer (MenuRenderer_CommandRow, MenuRenderer_TemplateRows and the native
; menu), with the frame and the mutations of test_manifest_menu_captions.ahk.
;
; FEATURES & RATIONALE:
; 1. "invalid-utf8" is the byte 0xFF in Lua. AHK strings are UTF-16, so the same
;    malformed native value is a lone surrogate.
; ==============================================================================

#Requires AutoHotkey v2.0



_CTNC_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir . "\..\..\_shared\tests\corpus\menu\numbered_caption_vectors.json", "UTF-8"))
	return Corpus
}

_CTNC_CountsAreCurrent() {
	Corpus := _CTNC_Corpus()
	AssertEqual(3, Corpus["positive"].Length, "the positive vectors changed")
	AssertEqual(6, Corpus["grammar_refusals"].Length, "the grammar refusals changed")
	AssertEqual(10, Corpus["ownership_refusals"].Length, "the ownership refusals changed")
}
Test("numbered caption corpus: the counts are current", _CTNC_CountsAreCurrent)

_CTNC_Mode(Id) {
	return Id == "invalid-utf8" ? "invalid utf16" : StrReplace(Id, "-", " ")
}

_CTNC_Register() {
	Corpus := _CTNC_Corpus()
	for Vector in Corpus["positive"]
		Test("numbered caption corpus: " . Vector["id"], _NC_WithFrame.Bind(Vector["format"],
			_NC_LiteralCaption.Bind(Vector["expected"], Vector.Has("value"))))
	for Vector in Corpus["grammar_refusals"]
		Test("numbered caption corpus: refuses " . Vector["id"], _NC_WithFrame.Bind(Vector["format"], _NC_BadFormat))
	for Vector in Corpus["ownership_refusals"]
		Test("numbered caption corpus: refuses " . Vector["id"], _NC_WithFrame.Bind("Caption {1}", _NC_BadOwner.Bind(_CTNC_Mode(Vector["id"]))))
}
_CTNC_Register()
