; tests/meta/corpus/test_corpus_hotstring_backspace_steps.ahk

; ==============================================================================
; MODULE: Backspace Steps per Text Host (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/hotstrings/backspace_step_vectors.json, the
; table of what one Backspace erases in a Win32 EDIT, a RichEdit and Chromium
; measured on 2026-11-17, through HSE_BackspaceSegments, and its host classes
; through HSE_BackspaceHostFamily. The Backspace undo counts its steps there.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================
; =========================
; ======= 1/ Corpus =======
; =========================
; =========================

_CHBS_Corpus() {
	static Corpus := JsonParse(FileRead(A_ScriptDir
		. "\..\..\_shared\tests\corpus\hotstrings\backspace_step_vectors.json", "UTF-8"))
	return Corpus
}

_CHBS_Text(Vector) {
	Text := ""
	for Hex in Vector["codepoints"]
		Text .= Chr(Integer("0x" . Hex))
	return Text
}





; =========================
; =========================
; ======= 2/ Replay =======
; =========================
; =========================

_CHBS_TextsSplitAsMeasured() {
	Corpus := _CHBS_Corpus()
	AssertTrue(Corpus["texts"].Length >= 6, "the measured table is read")
	for Vector in Corpus["texts"] {
		Text := _CHBS_Text(Vector)
		for Family in Corpus["families"] {
			Label := Vector["id"] . " in " . Family
			Segments := HSE_BackspaceSegments(Text, Family)
			Joined := ""
			for Segment in Segments
				Joined .= Segment
			AssertEqual(Text, Joined, Label . ": the segments rebuild the text")
			AssertEqual(Vector["steps"][Family], Segments.Length, Label . ": the Backspace steps")
			AssertEqual(Vector["first_backspace_units"][Family], StrLen(Segments[Segments.Length]),
				Label . ": the UTF-16 units one Backspace erases")
			AssertEqual(Vector["steps"][Family], HSE_BackspaceSteps(Text, Family), Label . ": the count")
		}
	}
}
Test("hotstrings: Backspace steps follow the measured table per host family (backspace-steps)",
	_CHBS_TextsSplitAsMeasured)

_CHBS_HostsResolveTheirFamily() {
	Corpus := _CHBS_Corpus()
	AssertTrue(Corpus["hosts"].Length >= 8, "the host classes are read")
	for Host in Corpus["hosts"]
		AssertEqual(Host["family"], HSE_BackspaceHostFamily(Host["control_class"], Host["window_class"]),
			Host["id"] . ": the host family")
}
Test("hotstrings: the focused control's class names its Backspace family (backspace-steps)",
	_CHBS_HostsResolveTheirFamily)

_CHBS_UnknownFamilyFailsFast() {
	Threw := false
	try HSE_BackspaceSegments("a", "gtk")
	catch ValueError
		Threw := true
	AssertTrue(Threw, "an unknown family is an error, not a code-point count")
	AssertEqual(0, HSE_BackspaceSteps("", "richedit"), "an empty text has no step")
}
Test("hotstrings: an unknown Backspace family is refused (backspace-steps)", _CHBS_UnknownFamilyFailsFast)
