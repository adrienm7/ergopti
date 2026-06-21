; tests/meta/test_parser_ord_empty_token_crash.ahk

; ==============================================================================
; MODULE: LLM Parser Crash-Firewall Meta Test
; DESCRIPTION:
; Regression guard for finding parser-ord-empty-token-crash.
;
; LLM_Parser_ProcessPrediction runs deep inside the prediction engine's async
; poll / SetTimer callbacks, where AHK SWALLOWS any thrown exception - it never
; reaches the file logger. An unexpected token shape in adversarial model output
; (e.g. an "ins" op with no t1 key reached by the anchor loops, or an empty
; token handed to Ord()) would throw mid-alignment and silently abort the
; variant with zero diagnostics; to the user it looks like "the model failed".
;
; The fix is two-fold:
;   1. The public LLM_Parser_ProcessPrediction now delegates to a private
;      _LLM_Parser_ProcessPredictionImpl under try/catch and LoggerWarn()s on a
;      crash, so an edge-input failure degrades to a logged failed-variant
;      instead of a silent swallow.
;   2. The anchor / chunk loops guard every Map t1 / t2 access with .Has(...)
;      and skip empty tokens so Ord() never operates on an absent value (an
;      "ins" op carries only t2 - raw t1 access threw "Key not found").
;
; This is a meta-static test: it scans parser.ahk source text. A behavioral
; trigger of the exact pre-fix crash requires constructing a precise token
; alignment that is brittle to author by hand, whereas the source guard pins
; the root-cause invariants directly. It also includes a load-safe behavioral
; smoke check that adversarial blocks parse without propagating an exception
; (parser.ahk is already in the run_all include graph).
; ==============================================================================

#Requires AutoHotkey v2.0




; ==================================================
; ==================================================
; ======= 1/ Source scan helpers ===================
; ==================================================
; ==================================================

; Reads a windows/-relative source file. A_ScriptDir is the runner dir (tests/);
; its parent is the windows/ driver root.
_POETC_ReadSource(RelPath) {
	SplitPath(A_ScriptDir, , &Root)
	Path := StrReplace(Root, "\", "/") . "/" . RelPath
	return FileRead(Path)
}




; ==================================================
; ==================================================
; ======= 2/ Crash-firewall source guards ==========
; ==================================================
; ==================================================

_POETC_PublicWrapsImplInTryCatch() {
	Src := _POETC_ReadSource("modules/llm/parser.ahk")
	Seg := _DriverFuncBody("LLM_Parser_ProcessPrediction")
	Assert(Seg != "", "LLM_Parser_ProcessPrediction(full_text...) must exist in parser.ahk")
	Assert(InStr(Seg, "try {") > 0,
		"LLM_Parser_ProcessPrediction must wrap its work in try { } - async callbacks swallow thrown errors")
	Assert(InStr(Seg, "_LLM_Parser_ProcessPredictionImpl") > 0,
		"LLM_Parser_ProcessPrediction must delegate to _LLM_Parser_ProcessPredictionImpl inside the try")
	Assert(InStr(Seg, "catch as err") > 0,
		"LLM_Parser_ProcessPrediction must catch the impl crash so it never propagates into the swallowing async caller")
	Assert(InStr(Seg, "LoggerWarn") > 0,
		"the crash firewall must LoggerWarn() on a parser crash - a silent swallow leaves prediction failures undiagnosable")
}
Test("LLM parser: ProcessPrediction wraps impl in a logging crash firewall (parser-ord-empty-token-crash)", _POETC_PublicWrapsImplInTryCatch)

_POETC_ImplFunctionExists() {
	Src := _POETC_ReadSource("modules/llm/parser.ahk")
	Assert(InStr(Src, "_LLM_Parser_ProcessPredictionImpl(full_text") > 0,
		"the private _LLM_Parser_ProcessPredictionImpl implementation must exist - it carries the body the firewall wraps")
}
Test("LLM parser: private ProcessPrediction impl exists for the firewall (parser-ord-empty-token-crash)", _POETC_ImplFunctionExists)

_POETC_AnchorLoopsGuardKeyAccess() {
	Src := _POETC_ReadSource("modules/llm/parser.ahk")
	Seg := _DriverFuncBody("_LLM_Parser_ProcessPredictionImpl")
	Assert(Seg != "", "_LLM_Parser_ProcessPredictionImpl declaration must exist in parser.ahk")
	; The anchor loops walk stripped_ops / ops which can hold "ins" ops (t2 only,
	; no t1). A raw t1 access on such an op throws "Key not found"; the fix reads
	; it via .Has("t1") so Ord() never sees an absent value.
	Needle := ".Has(" . Chr(34) . "t1" . Chr(34) . ")"
	Assert(InStr(Seg, Needle) > 0,
		"the anchor / chunk loops must guard t1 access with .Has(t1) - an ins op has no t1 and raw access throws before Ord()")
}
Test("LLM parser: anchor loops guard t1 key access before Ord (parser-ord-empty-token-crash)", _POETC_AnchorLoopsGuardKeyAccess)




; ==================================================
; ==================================================
; ======= 3/ Behavioral smoke (no throw) ============
; ==================================================
; ==================================================

; parser.ahk is included by run_all.ahk before this file, so LLM_Parser_ProcessPrediction
; is callable here. It is a pure function with no OS/COM/network/hotkey side effects.
; A propagated exception on any of these adversarial blocks would surface as a test
; failure (RunTests wraps each callback in try/catch). The contract: never throw -
; degrade to "" (a failed variant) or a Map.
_POETC_AdversarialBlockDoesNotThrow(Block) {
	Result := LLM_Parser_ProcessPrediction("bonjour le monde", "le monde", Block, 1, 15)
	; Acceptable outcomes: a prediction Map, or "" (failed variant). Never a throw.
	AssertTrue((Result is Map) or (Result == ""),
		"adversarial block must degrade to a Map or empty string without throwing: <" . SubStr(Block, 1, 40) . ">")
}

_POETC_OnlyPunctuationTail() {
	; TAIL_CORRECTED carrying only punctuation tokens around the anchor logic.
	_POETC_AdversarialBlockDoesNotThrow("TAIL_CORRECTED: !!!,,,;;;`nNEXT_WORDS: ...")
}
Test("LLM parser: only-punctuation TAIL_CORRECTED does not throw (parser-ord-empty-token-crash)", _POETC_OnlyPunctuationTail)

_POETC_EmojiOnlyNextWords() {
	; NEXT_WORDS that is a single 4-byte astral emoji (surrogate pair) - exercises
	; the >= 128 Ord() word-classification path on a non-BMP token.
	Emoji := Chr(0x1F600)
	_POETC_AdversarialBlockDoesNotThrow("TAIL_CORRECTED: bonjour le monde`nNEXT_WORDS: " . Emoji)
}
Test("LLM parser: emoji-only NEXT_WORDS does not throw (parser-ord-empty-token-crash)", _POETC_EmojiOnlyNextWords)

_POETC_EmptyAfterClean() {
	; A block that cleans down to nothing meaningful (tags stripped, only dots).
	_POETC_AdversarialBlockDoesNotThrow("TAIL_CORRECTED: . . .`nNEXT_WORDS: . . .")
}
Test("LLM parser: empty-after-clean block does not throw (parser-ord-empty-token-crash)", _POETC_EmptyAfterClean)
