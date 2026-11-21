; tests/unit/hotstrings/engine/engine/test_end_character_vectors.ahk

; ==============================================================================
; MODULE: End-Character Corpus (hcd-2-bare-colon)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/end_character_vectors.json through the
; real matcher (HSE_FeedChar). Since the maintainer decision HCD-2 (2026-11-21)
; a bare ":" or ";" ends a trigger on the three OS; the no-break space the
; Ergopti layout types before them is still looked past and replaced. The
; shared engine (Linux) and the macOS expander replay the same vectors.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================================
; ====================================================
; ======= 1/ Corpus replay ===========================
; ====================================================
; ====================================================

_ECV_Vectors() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\hotstrings\end_character_vectors.json"
	return JsonParse(FileRead(Path, "UTF-8"))["vectors"]
}

_ECV_Replay(Vector) {
	global HSE_LastEndChar, HSE_TypoNbspStripped
	for Mapping in Vector["mappings"] {
		IsAuto := Mapping.Has("auto_expand") and Mapping["auto_expand"]
		CreateHotstring(IsAuto ? "*?" : "?", Mapping["trigger"], Mapping["replacement"],
			Map("OnlyText", true, "Priority", HSE_PRIORITY_COMMON))
	}
	Typed := Vector["typed"]
	Match := ""
	for Index, Char in Typed {
		Match := HSE_FeedChar(Char, true)
		if (Index < Typed.Length)
			AssertFalse(IsObject(Match), Vector["id"] . ": only the last character may fire")
	}
	Expected := Vector["expected"]
	if !Expected["fires"] {
		AssertFalse(IsObject(Match), Vector["id"] . ": nothing may fire")
		return
	}
	AssertTrue(IsObject(Match), Vector["id"] . ": the last character must fire")
	AssertEqual(Expected["replacement"], Match.Replacement, Vector["id"] . ": replacement")
	Replaced := Match.Length + (HSE_LastEndChar != "" ? 1 : 0) + (HSE_TypoNbspStripped ? 1 : 0)
	AssertEqual(Expected["backspace_count"], Replaced, Vector["id"] . ": replaced codepoints")
}

_ECV_Run(Vector) {
	_HOF_Run(_ECV_Replay.Bind(Vector))
}

for _ECV_Vector in _ECV_Vectors()
	Test("end character corpus: " . _ECV_Vector["id"] . " (hcd-2-bare-colon)", _ECV_Run.Bind(_ECV_Vector))
