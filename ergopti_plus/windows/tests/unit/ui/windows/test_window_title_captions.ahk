; static/ergopti_plus/windows/tests/unit/ui/windows/test_window_title_captions.ahk

; ==============================================================================
; MODULE: Window Title Caption Corpus Consumer (AHK)
; DESCRIPTION:
; Replays _shared/tests/corpus/native_presentations/original_captions.json
; through the generated WindowTitle composer. The corpus captured, before the
; shared title policy existed, the prefixed captions a native notice showed in
; every locale; Windows composes every native caption through WindowTitle, so
; it must give those exact captions from the same bare labels, warning sign
; included. The receivers the corpus names are a Linux notice and a macOS
; dialog: Windows shows neither, so only the composition is replayed here.
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

Test("WindowTitle reproduces every captured prefixed caption (window-title-captions)", () => (
	Corpus := _WTC_Corpus(),
	_WTC_AssertLocales(Corpus)
))

_WTC_AssertLocales(Corpus) {
	Checked := 0
	for Locale, Entry in Corpus["locales"] {
		Caption := Entry["captions"]["magic_key_source_notice"]
		Bare := Caption["original_bare_caption"]
		AssertEqual(Caption["original_native_caption"], WindowTitle(Bare), Locale . ": native caption")
		AssertEqual(Caption["original_warning_native_caption"], WindowTitle("⚠ " . Bare),
			Locale . ": warning caption")
		Checked += 1
	}
	AssertEqual(21, Checked, "every captured locale is replayed")
}
