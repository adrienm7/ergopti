; static/ergopti_plus/windows/tests/bench_parity_process_prediction.ahk

; ==============================================================================
; MODULE: process_prediction Cross-Driver Parity Probe (AHK side)
; DESCRIPTION:
; Diagnostic harness that runs the AHK LLM_Parser_ProcessPrediction against the
; cross-driver golden corpus generated from the shared Lua parser
; (_shared/tests/corpus/llm/process_prediction_vectors.json) and reports, per
; vector, whether the AHK physical output matches the oracle. The parity contract
; is the physical fields only: deletes / to_type / nw / has_corrections /
; disable_bold (chunks are display-only and computed differently per driver).
;
; Not a unit test — a one-shot probe to measure the current parity state before
; deciding whether to promote it into the suite or reconcile divergences.
;     "C:\Program Files\AutoHotkey\v2\AutoHotkey64.exe" bench_parity_process_prediction.ahk
; ==============================================================================

#Requires AutoHotkey v2.0+
SetWorkingDir(A_ScriptDir)
#Warn VarUnset, Off

#Include ../lib/json.ahk
#Include ../modules/llm/parser.ahk

_OUT := A_Temp . "\ergopti_parity_pp.txt"
_Emit(Line) {
	global _OUT
	FileAppend(Line . "`r`n", "*")
	try FileAppend(Line . "`r`n", _OUT, "UTF-8")
}

; True when the parser signalled "no prediction" (Lua returns nil; AHK returns
; either an empty string or no Map).
_IsNilPred(Pred) {
	if !IsObject(Pred)
		return true
	if (Pred is Map)
		return Pred.Count == 0
	return false
}

_BoolStr(V) => (V ? "true" : "false")

try FileDelete(_OUT)

CorpusPath := A_ScriptDir . "\..\..\_shared\tests\corpus\llm\process_prediction_vectors.json"
if !FileExist(CorpusPath) {
	_Emit("FATAL: corpus not found at " . CorpusPath)
	ExitApp(2)
}
Data := JsonParse(FileRead(CorpusPath, "UTF-8"))

_Emit("=== process_prediction AHK<->shared-Lua parity ===")
_Emit(Format("vectors: {1}", Data["vectors"].Length))
_Emit("")

Pass := 0
Fail := 0
for Vec in Data["vectors"] {
	Id    := Vec["id"]
	Full  := Vec["full_text"]
	Tail  := Vec["tail_text"]
	Block := Vec["block"]
	MinW  := Vec["min_words"]
	MaxW  := Vec["max_words"]
	Expd  := Vec["expected"]

	Pred := ""
	ThrewMsg := ""
	try {
		Pred := LLM_Parser_ProcessPrediction(Full, Tail, Block, MinW, MaxW)
	} catch as e {
		ThrewMsg := e.Message . "  [" . e.What . " @line " . e.Line . "]"
	}

	Mismatches := []
	if (ThrewMsg != "") {
		Mismatches.Push("THREW: " . ThrewMsg)
	} else if Expd["is_nil"] {
		if !_IsNilPred(Pred)
			Mismatches.Push("expected nil, got a prediction")
	} else {
		if _IsNilPred(Pred) {
			Mismatches.Push("expected a prediction, got nil")
		} else {
			ActDeletes := Pred.Has("deletes")         ? Pred["deletes"]         : ""
			ActToType  := Pred.Has("to_type")         ? Pred["to_type"]         : ""
			ActNw      := Pred.Has("nw")              ? Pred["nw"]              : ""
			ActHasCorr := Pred.Has("has_corrections") ? Pred["has_corrections"] : false
			ActDisable := Pred.Has("disable_bold")    ? Pred["disable_bold"]    : false
			if (ActDeletes != Expd["deletes"])
				Mismatches.Push(Format("deletes: got {1} want {2}", ActDeletes, Expd["deletes"]))
			if (ActToType != Expd["to_type"])
				Mismatches.Push(Format('to_type: got "{1}" want "{2}"', ActToType, Expd["to_type"]))
			if (ActNw != Expd["nw"])
				Mismatches.Push(Format('nw: got "{1}" want "{2}"', ActNw, Expd["nw"]))
			if (_BoolStr(ActHasCorr) != _BoolStr(Expd["has_corrections"]))
				Mismatches.Push(Format("has_corrections: got {1} want {2}", _BoolStr(ActHasCorr), _BoolStr(Expd["has_corrections"])))
			if (_BoolStr(ActDisable) != _BoolStr(Expd["disable_bold"]))
				Mismatches.Push(Format("disable_bold: got {1} want {2}", _BoolStr(ActDisable), _BoolStr(Expd["disable_bold"])))
		}
	}

	if (Mismatches.Length == 0) {
		Pass += 1
		_Emit(Format("PASS  {1}", Id))
	} else {
		Fail += 1
		_Emit(Format("FAIL  {1}", Id))
		for M in Mismatches
			_Emit("        " . M)
	}
}

_Emit("")
_Emit(Format("RESULT: {1} pass, {2} fail", Pass, Fail))
ExitApp(Fail > 0 ? 1 : 0)
