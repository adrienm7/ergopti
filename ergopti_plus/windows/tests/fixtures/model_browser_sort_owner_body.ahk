; tests/fixtures/model_browser_sort_owner_body.ahk

; Genuine whole browser sorting and catalogue caches; no Array prototype patch,
; comparator stub, GUI, COM, backend request or configuration mutation.
#Requires AutoHotkey v2.0

global _MBS_AsyncFailure := 0

_MBS_Require(Condition, Message) {
	if !Condition
		throw Error(Message)
}

_MBS_Error(Failure, Mode) {
	global _MBS_AsyncFailure
	if !IsObject(_MBS_AsyncFailure)
		_MBS_AsyncFailure := Failure
	return true
}

_MBS_CheckNames(Actual, Expected, Context) {
	_MBS_Require(Actual is Array, Context . ": the sorted result must remain a native array.")
	_MBS_Require(Actual.Length == Expected.Length, Context . ": preserve the complete multiplicity.")
	for Index, Name in Expected
		_MBS_Require(Actual[Index] == Name, Context . ": wrong catalogue name at position " . Index . ".")
}

_MBS_Edges() {
	Empty := [], Singleton := ["Qwen3.5-0.8B"]
	_MBS_Require(Empty.Clone() is Array && Empty.Length == 0,
		"The native array positive control must support Clone without a prototype extension.")
	SortedEmpty := _LLM_ModelBrowser_Sort(Empty)
	_MBS_CheckNames(SortedEmpty, [], "Empty input")
	_MBS_Require(ObjPtr(SortedEmpty) != ObjPtr(Empty), "Empty sorting must return an independent array.")
	SortedSingleton := _LLM_ModelBrowser_Sort(Singleton)
	_MBS_CheckNames(SortedSingleton, ["Qwen3.5-0.8B"], "Singleton input")
	_MBS_Require(ObjPtr(SortedSingleton) != ObjPtr(Singleton), "Singleton sorting must return an independent array.")
	SortedEmpty.Push("private test marker")
	SortedSingleton[1] := "private test marker"
	_MBS_Require(Empty.Length == 0 && Singleton[1] == "Qwen3.5-0.8B",
		"Mutating either result must leave both original edge-case arrays unchanged.")
}

_MBS_Order() {
	; Independent fixed names/sizes come from the actual shipped catalogue,
	; not from sorting an expected list through the comparator under test.
	Input := ["Qwen3-Coder-30B-A3B-Instruct", "gemma-4-E4B", "Qwen3.5-0.8B", "gemma-4-E2B"]
	Expected := ["gemma-4-E2B", "gemma-4-E4B", "Qwen3.5-0.8B", "Qwen3-Coder-30B-A3B-Instruct"]
	_MBS_Require(_LLM_ModelBrowser_Compare("gemma-4-E2B", "gemma-4-E4B") < 0
		&& _LLM_ModelBrowser_Compare("Qwen3.5-0.8B", "Qwen3-Coder-30B-A3B-Instruct") < 0
		&& _LLM_ModelBrowser_Compare("Qwen3.5-0.8B", "gemma-4-E4B") > 0,
		"The real catalogue comparator must distinguish both family and numeric size before the sort oracle.")
	Result := _LLM_ModelBrowser_Sort(Input)
	_MBS_CheckNames(Result, Expected, "Real family and parameter ordering")
	_MBS_CheckNames(Input, ["Qwen3-Coder-30B-A3B-Instruct", "gemma-4-E4B", "Qwen3.5-0.8B", "gemma-4-E2B"],
		"Order input after sorting")
}

_MBS_Clone() {
	Input := ["Qwen3-Coder-30B-A3B-Instruct", "Qwen3.5-0.8B", "Qwen3-Coder-30B-A3B-Instruct", "gemma-4-E2B"]
	Original := Input.Clone()
	Result := _LLM_ModelBrowser_Sort(Input)
	_MBS_CheckNames(Result, ["gemma-4-E2B", "Qwen3.5-0.8B", "Qwen3-Coder-30B-A3B-Instruct", "Qwen3-Coder-30B-A3B-Instruct"],
		"Sorted copy with duplicate real model names")
	_MBS_Require(ObjPtr(Result) != ObjPtr(Input), "The public sorting helper must never return its caller's mutable array.")
	_MBS_CheckNames(Input, Original, "Original order and duplicates")
	Result[1] := "private test marker"
	Result.Push("second private test marker")
	_MBS_CheckNames(Input, Original, "Original after independent result mutations")
}

_MBS_Main() {
	global _SharedDir, _MBS_AsyncFailure
	Primary := 0, Mode := A_Args[1]
	_MBS_Require(Mode == "edges" || Mode == "order" || Mode == "clone", "The sort mode must be explicit.")
	OnError(_MBS_Error)
	try {
		Path := _SharedDir . "\modules\llm\models.json"
		Before := FSReadBytesStrict(Path), BeforeHash := CryptoSha256Bytes(Before)
		_MBS_Require(Before.Size > 0 && BeforeHash != "", "The private authentic catalogue RAW image must be readable.")
		Index := LLM_GetModelIndex(), CountBefore := Index.Count
		_MBS_Require(Index is Map && CountBefore >= 4 && ObjPtr(Index) == ObjPtr(LLM_GetModelIndex()),
			"The genuine flat catalogue getter must establish and reuse its real cache.")
		for Name, Params in Map("gemma-4-E2B", 5.12, "gemma-4-E4B", 8, "Qwen3.5-0.8B", 0.87,
			"Qwen3-Coder-30B-A3B-Instruct", 30.53) {
			_MBS_Require(Index.Has(Name) && LLM_GetModelInfo(Name)["params_b"] == Params,
				"Each independent expected parameter must match the shipped catalogue: " . Name)
		}
		FileAppend("RECEIPT model-browser-sort-owner mode=" . Mode . " phase=before-sort pid="
			. DllCall("Kernel32\GetCurrentProcessId", "UInt") . " catalogue_count=" . CountBefore . "`n", "*", "UTF-8-RAW")
		switch Mode {
			case "edges": _MBS_Edges()
			case "order": _MBS_Order()
			case "clone": _MBS_Clone()
		}
		After := FSReadBytesStrict(Path)
		_MBS_Require(After.Size == Before.Size && CryptoSha256Bytes(After) == BeforeHash,
			"Sorting and result mutation must leave the complete private catalogue file unchanged.")
		_MBS_Require(ObjPtr(Index) == ObjPtr(LLM_GetModelIndex()) && Index.Count == CountBefore,
			"Sorting must preserve the real catalogue cache identity and membership.")
		_MBS_Require(LLM_GetModelInfo("gemma-4-E2B")["params_b"] == 5.12
			&& LLM_GetModelInfo("gemma-4-E4B")["params_b"] == 8
			&& LLM_GetModelInfo("Qwen3.5-0.8B")["params_b"] == 0.87
			&& LLM_GetModelInfo("Qwen3-Coder-30B-A3B-Instruct")["params_b"] == 30.53,
			"The genuine model metadata must remain unchanged after the sorting oracle.")
	} catch Any as Failure {
		Primary := Failure
	} finally OnError(_MBS_Error, 0)
	if !IsObject(Primary) && IsObject(_MBS_AsyncFailure)
		Primary := _MBS_AsyncFailure
	if IsObject(Primary) {
		FileAppend("FAIL " . Primary.Message . " [" . Primary.File . ":" . Primary.Line . "]`n", "*", "UTF-8-RAW")
		ExitApp(1)
	}
	FileAppend("PASS model-browser-sort-owner " . Mode . "`n", "*", "UTF-8-RAW")
	ExitApp(0)
}

_MBS_Main()
