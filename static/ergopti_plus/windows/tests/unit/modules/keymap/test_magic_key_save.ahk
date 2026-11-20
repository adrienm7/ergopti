; tests/unit/modules/keymap/test_magic_key_save.ahk

; ==============================================================================
; MODULE: Modifiers + Magic Key Save Tests (Windows)
; DESCRIPTION:
; With [layout] ctrl_magic_save on, Windows registered one ^SCxxx hotkey: Ctrl
; alone saved, and Ctrl+Shift+★, Alt+★ or Win+Shift+★ reached the application
; as chords nothing binds. The three drivers now share one rule
; (_shared/shortcuts/data/magic_key_save.ahk and its Lua twin): every shortcut
; chord on the layout's own magic key sends its modifiers + S, ★ alone stays
; the magic key, and Ctrl+Alt (AltGr) keeps the layout's AltGr character.
; These cases replay the shared corpus and pin the hotkeys layout.ahk binds.
; ==============================================================================

#Requires AutoHotkey v2.0

_MKS_Corpus() {
	global _SharedDir
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\shortcuts\magic_key_save_vectors.json", "UTF-8"))
}

_MKS_Join(List) {
	if !(List is Array)
		return "pass"
	Text := ""
	for Index, Name in List
		Text .= (Index > 1 ? "+" : "") . Name
	return Text
}

_MKS_SharedVectorsCase() {
	Corpus := _MKS_Corpus()
	AssertEqual(Corpus["save_key"], MagicKeySaveSpec()["save_key"], "the corpus sends S")
	Assert(Corpus["vectors"].Length >= 50, "the corpus keeps every OS's cases")
	for Vector in Corpus["vectors"] {
		Input := Map("os", Vector["os"], "held", Vector["held"])
		for Gate, Value in Corpus["gates"]
			Input[Gate] := Value ? true : false
		for Gate, Value in Vector.Get("gates", Map())
			Input[Gate] := Value ? true : false
		Decision := MagicKeySaveResolve(Input)
		Expected := Vector["expected"]
		AssertEqual(Expected["action"], Decision["action"], Vector["id"])
		AssertEqual(Expected.Get("reason", ""), Decision["reason"], Vector["id"])
		AssertEqual(_MKS_Join(Expected.Get("sends", "")), _MKS_Join(Decision["sends"]), Vector["id"])
	}
	AssertThrows(() => MagicKeySaveDecide("windows", ["altgr"]), "Windows reports no AltGr modifier")
}
Test("magic key save: the shared corpus replays on the AHK twin (magic-key-save)", _MKS_SharedVectorsCase)

_MKS_HotkeysCase() {
	Bound := Map()
	for Save in MagicKeySaveWindowsHotkeys("SC02E")
		Bound[Save["hotkey"]] := Save["send"] . (Save["win_only"] ? " (broker)" : "")
	for Hotkey, Send in Map("^SC02E", "^s", "^+SC02E", "^+s", "!SC02E", "!s", "!+SC02E", "!+s",
			"#SC02E", "#s (broker)", "+#SC02E", "+#s", "^#SC02E", "^#s", "^!#SC02E", "^!#s",
			"^!+#SC02E", "^!+#s") {
		AssertTrue(Bound.Has(Hotkey), Hotkey . " saves")
		AssertEqual(Send, Bound.Get(Hotkey, ""), Hotkey)
	}
	for Hotkey in ["SC02E", "+SC02E", "^!SC02E", "^!+SC02E"]
		AssertFalse(Bound.Has(Hotkey), Hotkey . " keeps the layout's level: ★ alone, Shift or AltGr")
	AssertEqual(12, Bound.Count, "every combination with a shortcut modifier, AltGr excepted")
}
Test("magic key save: Windows binds every shortcut chord but AltGr (magic-key-save)", _MKS_HotkeysCase)

_MKS_RegistrationCase() {
	SplitPath(A_ScriptDir, , &WindowsDir)
	Code := _StripFullLineComments(FileRead(WindowsDir . "\modules\keymap\layout.ahk", "UTF-8"))
	Assert(InStr(Code, 'MagicEditorRecordLayoutFallback(Scan, _MagicKeySaveEmit.Bind("", Save["send"]), _RemapWinCriterion(Scan))') > 0,
		"Win+★ joins the Win broker as the key's layout fallback, behind the magic editor and the Win slots")
	Assert(InStr(Code, 'KeyboardShortcutRunLayoutChord(Variant)') > 0,
		"a keyboard slot set on the chord keeps it")
	Assert(InStr(Code, 'Hotkey(Save["hotkey"], _MagicKeySaveEmit.Bind(Variant, Save["send"]), "I3")') > 0,
		"the other chords take InputLevel 3, which repeats with the key")
}
Test("magic key save: layout.ahk binds the shared rule's hotkeys (magic-key-save)", _MKS_RegistrationCase)
