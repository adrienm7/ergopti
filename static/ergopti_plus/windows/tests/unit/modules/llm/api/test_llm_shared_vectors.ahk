; tests/unit/modules/llm/api/test_llm_shared_vectors.ahk

; ==============================================================================
; MODULE: LLM Shared Vectors (Windows)
; DESCRIPTION:
; Replays the authored language-neutral vectors of the LLM figures through the
; real AutoHotkey twins: the diversity temperature of a variant, and the tokens
; and estimated cost of a remote answer, which the dashboard's AI tab reads.
; ==============================================================================

#Requires AutoHotkey v2.0





; ========================================
; ========================================
; ======= 1/ Diversity Temperature =======
; ========================================
; ========================================

_LSV_TemperatureCorpus() {
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\temperature_vectors.json", "UTF-8"))
}

_LSV_Temperature(Vector, Policy) {
	global _LLM_COMMON_INFERENCE
	_LLM_Common_GetInference()
	Saved := _LLM_COMMON_INFERENCE
	Patched := Saved.Clone()
	Patched["diversity_temperature"] := Policy
	_LLM_COMMON_INFERENCE := Patched
	try Got := Vector.Has("step")
		? LLM_ApiCommon_GetDiversityTemp(Vector["base"], Vector["index"], Vector["step"])
		: LLM_ApiCommon_GetDiversityTemp(Vector["base"], Vector["index"])
	finally _LLM_COMMON_INFERENCE := Saved
	Assert(Abs(Got - Vector["expected"]) < 0.000000001,
		"expected " . Vector["expected"] . ", got " . Got)
}





; ==================================
; ==================================
; ======= 2/ Usage And Cost ========
; ==================================
; ==================================

_LSV_UsageCorpus() {
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\remote_usage_vectors.json", "UTF-8"))
}

_LSV_Usage(Vector) {
	Usage := _LLMRemoteExtractUsage(Vector["format"], Vector["body"], "")
	for Field, Want in Vector["expected"]
		AssertEqual(Want, Usage[Field], Field)
}

_LSV_Cost(Vector, Prices) {
	global LLM_REMOTE_MODEL_PRICES
	Saved := LLM_REMOTE_MODEL_PRICES
	LLM_REMOTE_MODEL_PRICES := _LLMRemoteAdmitPrices(Prices)
	try Got := _LLMRemoteEstimateCost(Vector["model"], Vector["prompt_tokens"], Vector["completion_tokens"])
	finally LLM_REMOTE_MODEL_PRICES := Saved
	Assert(Abs(Got - Vector["expected"]) < 0.000000001, "expected " . Vector["expected"] . ", got " . Got)
}

_LSV_PriceAdmission() {
	Corpus := _LSV_UsageCorpus()
	Admitted := _LLMRemoteAdmitPrices(Corpus["model_prices"])
	for Name in Corpus["admitted_prices"]
		Assert(Admitted.Has(Name), Name . " is admitted")
	for Name in Corpus["skipped_prices"]
		AssertFalse(Admitted.Has(Name), Name . " is refused")
	AssertEqual(Corpus["admitted_prices"].Length, Admitted.Count, "no other row is admitted")
}





; ====================================
; ====================================
; ======= 3/ Auth Failures ===========
; ====================================
; ====================================

_LSV_AuthCorpus() {
	return JsonParse(FileRead(_SharedDir . "\tests\corpus\llm\auth_failure_vectors.json", "UTF-8"))
}

_LSV_AuthFailure(Vector) {
	Failure := Vector["failure"]
	Want := Vector["authentication"] ? true : false
	AssertEqual(Want, LLM_ApiCommon_IsAuthenticationFailure(Failure) ? true : false, Vector["name"])
}





; =================================
; =================================
; ======= 4/ Registration =========
; =================================
; =================================

_LSV_Register() {
	Temperature := _LSV_TemperatureCorpus(), Usage := _LSV_UsageCorpus()
	if Temperature["vectors"].Length != 15 || Usage["usage_vectors"].Length != 12 || Usage["cost_vectors"].Length != 5
		throw Error("The independent LLM figures corpus requires explicit review.")
	for Vector in Temperature["vectors"]
		Test("llm shared vectors: temperature " . Vector["id"], _LSV_Temperature.Bind(Vector, Temperature["policy"]))
	for Vector in Usage["usage_vectors"]
		Test("llm shared vectors: usage " . Vector["id"], _LSV_Usage.Bind(Vector))
	for Vector in Usage["cost_vectors"]
		Test("llm shared vectors: cost " . Vector["id"], _LSV_Cost.Bind(Vector, Usage["model_prices"]))
	Test("llm shared vectors: the price table admits finite nonnegative rows only", _LSV_PriceAdmission)
	Auth := _LSV_AuthCorpus()
	if Auth["vectors"].Length != 16
		throw Error("The authentication failure corpus requires explicit review.")
	for Vector in Auth["vectors"]
		Test("llm shared vectors: authentication failure " . Vector["name"], _LSV_AuthFailure.Bind(Vector))
}
_LSV_Register()
