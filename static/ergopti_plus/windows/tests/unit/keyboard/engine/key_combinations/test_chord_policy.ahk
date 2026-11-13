; tests/unit/keyboard/engine/key_combinations/test_chord_policy.ahk

; ==============================================================================
; MODULE: Key Combination Chord Policy (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/tap_hold/key_combination_chords.json against
; KeyCombinationChordPolicy, as _shared/tests/lua/core/key_combination_chords_contract.lua
; does on macOS and Linux, with the same catalogue and the same refusals.
; The contract's plan_chord_copy has no Windows owner: the bulk copy is not offered.
; The engine that uses this policy is test_chord_engine.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0

_KCCP_Pairs() {
	return [Map("id", "caps_lock_then_tab", "first", "caps_lock", "second", "tab"),
		Map("id", "tab_then_caps_lock", "first", "tab", "second", "caps_lock")]
}

_KCCP_Policy(Symmetric) {
	return KeyCombinationChordPolicy(_KCCP_Pairs(),
		Map("caps_lock_then_tab", "copy", "tab_then_caps_lock", "paste"),
		KeyCombinationChordSettings(100, Symmetric))
}

_KCCP_Replay(Vector) {
	Chosen := _KCCP_Policy(Vector["symmetric"] ? 1 : 0).Choose(Vector["first"], Vector["second"], Vector["elapsed"])
	if !Vector["expected"] {
		AssertFalse(Chosen, "no chord is selected")
		return
	}
	Assert(Chosen is Map, "a chord is selected")
	AssertEqual(Vector["expected"], Chosen["action"], "action")
	AssertEqual(Vector["pair"], Chosen["pair_id"], "pair")
	AssertEqual("combination__" . Vector["pair"], Chosen["binding"], "binding")
}

_KCCP_RegisterCorpus() {
	global _SharedDir
	Corpus := JsonParse(FileRead(_SharedDir . "\tests\corpus\tap_hold\key_combination_chords.json", "UTF-8"))
	if Corpus["cases"].Length < 8
		throw Error("The key chord corpus lost its cases.")
	for Vector in Corpus["cases"]
		Test("key chord policy corpus: " . Vector["name"], _KCCP_Replay.Bind(Vector))
}
_KCCP_RegisterCorpus()

_KCCP_RefusesSettings() {
	Infinity := 1e308 * 10
	for Delay in [0, -1, Infinity, -Infinity, Infinity - Infinity, "100"]
		AssertThrows(KeyCombinationChordSettings.Bind(Delay, 0))
	for Symmetry in ["false", "0", 2, Map(), 1.0]
		AssertThrows(KeyCombinationChordSettings.Bind(100, Symmetry))
	AssertEqual(87, KeyCombinationChordSettings(87, 1)["simultaneous_threshold_ms"], "the delay is kept")
}
Test("key chord policy: requires a positive finite delay and an exact boolean", _KCCP_RefusesSettings)

_KCCP_NoneAndCatalogueOrder() {
	Infinity := 1e308 * 10
	Pairs := _KCCP_Pairs()
	Policy := KeyCombinationChordPolicy([Pairs[2], Pairs[1]],
		Map("caps_lock_then_tab", "copy", "tab_then_caps_lock", "none"),
		KeyCombinationChordSettings(80, 1))
	AssertEqual("tab_then_caps_lock", Policy.CanonicalPair("caps_lock_then_tab"), "the declared order owns symmetry")
	AssertEqual("", Policy.CanonicalPair("unknown"), "an unknown pair has no owner")
	AssertFalse(Policy.Choose("caps_lock", "tab", 1), "none stays neutral")
	AssertFalse(Policy.Choose("caps_lock", "tab", Infinity - Infinity), "a NaN delay selects nothing")
	AssertFalse(Policy.Choose("caps_lock", "tab", Infinity), "an infinite delay selects nothing")
}
Test("key chord policy: keeps none neutral and uses catalogue order for symmetry", _KCCP_NoneAndCatalogueOrder)

_KCCP_Build(Pairs, Chords, Settings) {
	return KeyCombinationChordPolicy(Pairs, Chords, Settings)
}

_KCCP_RefusesCatalogues() {
	One := _KCCP_Pairs()[1]
	Settings := KeyCombinationChordSettings(100, 0)
	Same := Map("id", "tab_then_tab", "first", "tab", "second", "tab")
	Twin := Map("id", "other", "first", "caps_lock", "second", "tab")
	for Pairs in [[Same], [One, One], [One, Twin]]
		AssertThrows(_KCCP_Build.Bind(Pairs, Map(), Settings))
	AssertThrows(_KCCP_Build.Bind([One], Map(One["id"], 5), Settings))
}
Test("key chord policy: refuses a catalogue with same-key or duplicate pairs", _KCCP_RefusesCatalogues)
