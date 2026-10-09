; static/ergopti_plus/windows/tests/meta/test_corpus_prompt_builder.ahk

; ==============================================================================
; MODULE: PromptBuilder Corpus Consumer (AHK)
; DESCRIPTION:
; Validates the AHK PromptBuilder implementation against the cross-driver
; contract defined in _shared/tests/corpus/prompt_builder/vectors.json.
; Each vector seeds PromptBuilder.Build() with its buffer and config, then
; asserts max_tokens, temperature, context_tail, min_words, and num_predictions.
;
; COVERAGE:
; 1. Token budget computation   -- max_tokens from max_words setting.
; 2. Temperature computation    -- greedy snap, auto_raise, diversity cap.
; 3. Context tail extraction    -- last CONTEXT_TAIL_WORDS words of buffer.
; 4. Pass-through fields        -- min_words, num_predictions, language.
; REQUIRES: _generated/prompt_builder.ahk must be #Include'd before this file.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Corpus registration =====================
; ===================================================
; ===================================================

_PromptBuilderCorpus_RegisterAll() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\prompt_builder\vectors.json"

	if !FileExist(CorpusPath) {
		Test("PromptBuilder corpus: file exists", () => AssertTrue(false,
			"Corpus file not found: " . CorpusPath))
		return
	}

	Raw  := FileRead(CorpusPath, "UTF-8")
	Data := JsonParse(Raw)
	if !Data.Has("vectors") {
		Test("PromptBuilder corpus: valid structure", () => AssertTrue(false,
			"No 'vectors' key in corpus JSON."))
		return
	}

	PB := PromptBuilder()

	for Vec in Data["vectors"] {
		Id     := Vec.Has("id")          ? Vec["id"]          : "unknown"
		Desc   := Vec.Has("description") ? Vec["description"] : Id
		Buf    := Vec.Has("buffer")      ? Vec["buffer"]      : ""
		Cfg    := Vec.Has("config")      ? Vec["config"]      : Map()
		ExpMap := Vec.Has("expected")    ? Vec["expected"]    : Map()

		; Convert corpus config (Map with string keys) to AHK Map for Build()
		AhkCfg := Map()
		for k, v in Cfg {
			AhkCfg[k] := v
		}

		NameCopy := "[corpus:" . Id . "] " . SubStr(Desc, 1, 70)

		; The closure MUST be built by a factory call, not inline. A fat-arrow
		; declared in this loop captures the enclosing function's locals BY
		; REFERENCE, so every registered test would run with the values of the
		; LAST iteration — all vectors executing the last vector, reported under
		; their own names. That is exactly what this file did: the suite showed one
		; green test per vector while only the final one was ever evaluated.
		; A function call creates a fresh scope per iteration, so each closure
		; captures its own vector.
		Test(NameCopy, _PromptBuilderCorpus_MakeRunner(PB, Buf, AhkCfg, ExpMap))
	}
}

; Factory: returns a zero-arg closure bound to THIS vector's values.
_PromptBuilderCorpus_MakeRunner(PB, Buf, Cfg, Exp) {
	return () => _RunPromptBuilderVector(PB, Buf, Cfg, Exp)
}

_RunPromptBuilderVector(PB, Buf, Cfg, Exp) {
	Result := PB.Build(Buf, Cfg)

	if Exp.Has("max_tokens")
		AssertEqual(Exp["max_tokens"], Result["max_tokens"],
			"corpus field max_tokens")

	if Exp.Has("temperature")
		AssertEqual(Exp["temperature"], Result["temperature"],
			"corpus field temperature")

	if Exp.Has("min_words")
		AssertEqual(Exp["min_words"], Result["min_words"],
			"corpus field min_words")

	if Exp.Has("num_predictions")
		AssertEqual(Exp["num_predictions"], Result["num_predictions"],
			"corpus field num_predictions")

	if Exp.Has("context_tail")
		AssertEqual(Exp["context_tail"], Result["context_tail"],
			"corpus field context_tail")

	; The capped context itself. This assertion was missing, so every vector whose
	; only expectation is "context" — including the pre-existing
	; short_buffer_no_truncation — passed without exercising _CapContext at all.
	; That is what let the AHK side ship with no context_window_chars parameter
	; while the corpus stayed green.
	if Exp.Has("context")
		AssertEqual(Exp["context"], Result["context"],
			"corpus field context")

	; Upper bound on the capped context, for vectors that pin the limit rather than
	; the exact text. Was declared by context_truncation and asserted by nobody.
	if Exp.Has("context_length_max")
		AssertTrue(StrLen(Result["context"]) <= Exp["context_length_max"],
			"corpus field context_length_max: context is "
			. StrLen(Result["context"]) . " chars, limit is " . Exp["context_length_max"])

	if Exp.Has("language")
		AssertEqual(Exp["language"], Result["language"],
			"corpus field language")

	; Every expected field must be checked by one of the branches above. Without
	; this, adding a field to a corpus vector produces a test that passes while
	; asserting nothing — which is exactly how the "context" field went unchecked
	; and let the AHK builder ship without its context_window_chars parameter.
	static Known := Map(
		"max_tokens", true, "temperature", true, "min_words", true,
		"num_predictions", true, "context_tail", true, "context", true,
		"context_length_max", true,
		"language", true
	)
	for Key, _ in Exp {
		if !Known.Has(Key)
			AssertTrue(false,
				"corpus vector expects '" . Key . "' but this runner asserts nothing for it — "
				. "add a branch above or the vector is decorative")
	}
}

_PromptBuilderCorpus_RegisterAll()
