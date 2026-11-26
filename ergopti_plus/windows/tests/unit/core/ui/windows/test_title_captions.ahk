; static/ergopti_plus/windows/tests/unit/core/ui/windows/test_title_captions.ahk

; ==============================================================================
; MODULE: Window Title Caption Corpus Consumer (AHK)
; DESCRIPTION:
; Replays _shared/tests/corpus/native_presentations/original_captions.json
; through the generated WindowTitle composer. The corpus captured, before the
; shared title policy existed, the prefixed captions a native notice showed in
; every locale; Windows composes every native caption through WindowTitle, so
; it must compose them by the same shared policy. The prefixed Linux notice the
; corpus captured left with the physical magic key (2026-11-21); the macOS
; dialog it keeps is unprefixed, so only the composition policy is replayed.
; ==============================================================================

#Requires AutoHotkey v2.0

_WTC_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\native_presentations\original_captions.json", "UTF-8"))
}

Test("WindowTitle composes the shared title policy (window-title-captions)", () => (
	Corpus := _WTC_Corpus(),
	Policy := Corpus["window_title_policy"],
	AssertEqual(Policy["prefix"], WindowTitle(), "an empty label is the bare prefix"),
	AssertEqual(Policy["prefix"] . Policy["separator"] . "Label", WindowTitle("Label"),
		"the prefix and separator are the shared policy's")
))
