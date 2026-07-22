; static/ergopti_plus/windows/tests/meta/test_corpus_llm_parser.ahk

; ==============================================================================
; MODULE: LLM Parser Corpus Consumer (AHK)
; DESCRIPTION:
; Validates the AHK LLM response parsers against the cross-driver contract
; defined in _shared/tests/corpus/llm/parser_test_vectors.json.
; Each vector calls the parser function matching its "parser" field and
; asserts the extracted text equals expected.text (and ok = text != "").
;
; COVERAGE:
; 1. ollama_nonstream  -- LLM_ParseOllamaResponse + LLM_UnescapeJSON.
; 2. remote/openai     -- _LLMRemoteParseResponse("openai", ...).
; 3. remote/anthropic  -- _LLMRemoteParseResponse("anthropic", ...).
; 4. remote/gemini     -- _LLMRemoteParseResponse("gemini", ...).
; 5. all               -- all parsers tested on adversarial/malformed input.
; SKIPPED: ollama_stream_line vectors -- the streaming accumulator is an async
;          callback loop; it is tested directly in test_llm_api_ollama.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Helpers =================================
; ===================================================
; ===================================================

; Dispatch a corpus vector to the correct AHK parser and return the result.
; Returns a Map with keys "text" (string) and "ok" (bool).
_LLMCorpusDispatch(Vec) {
	Parser    := Vec.Has("parser") ? Vec["parser"] : ""
	Input     := Vec.Has("input")  ? Vec["input"]  : ""
	FmtName   := Vec.Has("format") ? Vec["format"]  : ""

	if (Parser = "ollama_nonstream") {
		Text := LLM_ParseOllamaResponse(Input)
		return Map("text", Text, "ok", Text != "")
	}
	if (Parser = "remote") {
		Text := _LLMRemoteParseResponse(FmtName, Input)
		return Map("text", Text, "ok", Text != "")
	}
	if (Parser = "all") {
		; All parsers must return empty on these adversarial inputs.
		R1 := LLM_ParseOllamaResponse(Input)
		R2 := _LLMRemoteParseResponse("openai", Input)
		R3 := _LLMRemoteParseResponse("anthropic", Input)
		R4 := _LLMRemoteParseResponse("gemini", Input)
		; Aggregate: ok = any parser returned non-empty (should be false for all)
		AllEmpty := (R1 = "" && R2 = "" && R3 = "" && R4 = "")
		BestText := (R1 != "") ? R1 : (R2 != "") ? R2 : (R3 != "") ? R3 : R4
		return Map("text", BestText, "ok", !AllEmpty)
	}
	; Unrecognised parser type -- return empty so the test skips gracefully.
	return Map("text", "", "ok", false)
}




; ===================================================
; ===================================================
; ======= 2/ Corpus test registration ================
; ===================================================
; ===================================================

_LLMParserCorpus_RegisterAll() {
	CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\llm\parser_test_vectors.json"

	if !FileExist(CorpusPath) {
		; Register a single failing test so the missing corpus is visible in CI.
		Test("LLM parser corpus: file exists", () => AssertTrue(false,
			"Corpus file not found: " . CorpusPath))
		return
	}

	Raw  := FileRead(CorpusPath, "UTF-8")
	Data := JsonParse(Raw)
	if !Data.Has("vectors") {
		Test("LLM parser corpus: valid structure", () => AssertTrue(false,
			"No 'vectors' key in corpus JSON."))
		return
	}

	for Vec in Data["vectors"] {
		Id     := Vec.Has("id")          ? Vec["id"]          : "unknown"
		Parser := Vec.Has("parser")      ? Vec["parser"]      : ""
		Desc   := Vec.Has("description") ? Vec["description"] : Id

		; Skip streaming vectors -- not testable with the sync parser API.
		if (Parser = "ollama_stream_line") {
			; Streaming accumulator tests live in test_llm_api_ollama.ahk.
			continue
		}

		; Skip vectors scoped to other drivers (e.g. driver=["macos"]).
		; A vector with no "driver" field is universal and runs on all drivers.
		if (Vec.Has("driver")) {
			DriverArr := Vec["driver"]
			IsAhk := false
			for D in DriverArr {
				if (D = "ahk") {
					IsAhk := true
					break
				}
			}
			if (!IsAhk)
				continue
		}

		; Capture loop variables for the closure.
		VecCopy    := Vec
		NameCopy   := "[corpus:" . Id . "] " . SubStr(Desc, 1, 70)
		ExpText    := VecCopy.Has("expected") && VecCopy["expected"].Has("text")
		             ? VecCopy["expected"]["text"] : ""
		ExpOk      := VecCopy.Has("expected") && VecCopy["expected"].Has("ok")
		             ? VecCopy["expected"]["ok"] : false

		Test(NameCopy, () => _RunLLMParserVector(VecCopy, ExpText, ExpOk))
	}
}

_RunLLMParserVector(Vec, ExpText, ExpOk) {
	Result   := _LLMCorpusDispatch(Vec)
	ActText  := Result["text"]
	ActOk    := Result["ok"]

	AssertEqual(ExpText, ActText)
	AssertEqual(ExpOk, ActOk)
}

_LLMParserCorpus_RegisterAll()
