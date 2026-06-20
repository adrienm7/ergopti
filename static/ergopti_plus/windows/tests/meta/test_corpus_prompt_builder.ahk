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

		NameCopy   := "[corpus:" . Id . "] " . SubStr(Desc, 1, 70)
		ExpCopy    := ExpMap
		BufCopy    := Buf
		CfgCopy    := AhkCfg
		PBRef      := PB

		Test(NameCopy, () =>
			_RunPromptBuilderVector(PBRef, BufCopy, CfgCopy, ExpCopy))
	}
}

_RunPromptBuilderVector(PB, Buf, Cfg, Exp) {
	Result := PB.Build(Buf, Cfg)

	if Exp.Has("max_tokens")
		AssertEq(Result["max_tokens"], Exp["max_tokens"])

	if Exp.Has("temperature")
		AssertEq(Result["temperature"], Exp["temperature"])

	if Exp.Has("min_words")
		AssertEq(Result["min_words"], Exp["min_words"])

	if Exp.Has("num_predictions")
		AssertEq(Result["num_predictions"], Exp["num_predictions"])

	if Exp.Has("context_tail")
		AssertEq(Result["context_tail"], Exp["context_tail"])

	if Exp.Has("language")
		AssertEq(Result["language"], Exp["language"])
}

_PromptBuilderCorpus_RegisterAll()
