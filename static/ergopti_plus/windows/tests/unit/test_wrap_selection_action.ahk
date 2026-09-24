; tests/unit/test_wrap_selection_action.ahk

; ==============================================================================
; MODULE: wrap_selection Action and its wrap_pair Parameter (Windows)
; DESCRIPTION:
; Replays _shared/tests/corpus/action_parameters/wrap_pair_vectors.json, which
; the macOS and Linux suites replay too, through GestureValidateActionParameter
; and GestureWrapPairFor over the real built-in catalogue, and checks that the
; action wraps the selection with the pair stored for its binding.
;
; ROOT CAUSE ENCODED:
; The only wrap action (surround_parens) wrapped the line in parentheses; no
; action could wrap the selection with a chosen pair, and parameter validation
; only knew URLs.
; ==============================================================================

#Requires AutoHotkey v2.0

; Runs Body with the built-in catalogue loaded from the shared JSON, then puts
; the harness globals back.
_WSA_WithCatalogue(Body) {
	global _WS_BUILTIN_PAIRS, _WS_BUILTIN_GROUPS
	SavedPairs := _WS_BUILTIN_PAIRS
	SavedGroups := _WS_BUILTIN_GROUPS
	try {
		_WS_LoadBuiltinCatalogue()
		AssertTrue(_WS_BUILTIN_PAIRS.Length >= 30, "the shared catalogue must load")
		return Body.Call()
	} finally {
		_WS_BUILTIN_PAIRS := SavedPairs
		_WS_BUILTIN_GROUPS := SavedGroups
	}
}

_WSA_ReplayCorpus() {
	global _SharedDir
	Path := _SharedDir . "\tests\corpus\action_parameters\wrap_pair_vectors.json"
	AssertTrue(FileExist(Path) != "", "the wrap-pair corpus must exist at " . Path)
	Corpus := JsonParse(FileRead(Path, "UTF-8"))
	AssertEqual("wrap_pair", GestureActionParameterSpec("wrap_selection"), "wrap_selection parameter kind")
	Checked := _WSA_WithCatalogue(() => _WSA_ReplayVectors(Corpus["vectors"]))
	AssertTrue(Checked >= 15, "expected at least 15 wrap-pair vectors, found " . Checked)
}

; @returns {Integer} The number of vectors replayed.
_WSA_ReplayVectors(Vectors) {
	Checked := 0
	for _, Vector in Vectors {
		Valid := !Vector.Has("valid") || Vector["valid"]
		ErrorText := ""
		AssertEqual(Valid, GestureValidateActionParameter("wrap_selection", Vector["value"], &ErrorText),
			Vector["id"] . ": validation")
		Pair := GestureWrapPairFor(Vector["value"])
		if Valid {
			AssertTrue(Pair is Map, Vector["id"] . ": a valid value names a pair")
			AssertEqual(Vector["left"], Pair["left"], Vector["id"] . ": left")
			AssertEqual(Vector["right"], Pair["right"], Vector["id"] . ": right")
		} else {
			AssertEqual("", Pair, Vector["id"] . ": an invalid value names no pair")
			AssertTrue(ErrorText != "", Vector["id"] . ": a refusal explains itself")
		}
		Checked += 1
	}
	return Checked
}
Test("wrap_selection: the wrap_pair parameter replays the shared corpus", _WSA_ReplayCorpus)

_WSA_WrapsWithTheBindingPair() {
	global GestureActionParameters, GESTURE_ACTIONS
	AssertTrue(GESTURE_ACTIONS.Has("wrap_selection"), "wrap_selection must be a registered action")
	Saved := GestureActionParameters
	try {
		GestureActionParameters := Map(GestureActionParameterKey("tap_3", "wrap_selection"), "«")
		_WSA_WithCatalogue(() => (
			AssertEqual("« été »", GestureWrapSelectionTransform("tap_3").Call("été"),
				"the stored pair wraps the selection"),
			AssertEqual("", GestureWrapSelectionTransform("tap_4"),
				"a binding without a stored pair builds no transform")
		))
	} finally {
		GestureActionParameters := Saved
	}
}
Test("wrap_selection: wraps with the pair stored for its binding", _WSA_WrapsWithTheBindingPair)
