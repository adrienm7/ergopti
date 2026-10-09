; tests/unit/test_tooltip_latency_diagnostics.ahk

; ==============================================================================
; MODULE: Tooltip Latency Diagnostic Regression Tests
; DESCRIPTION:
; Phase tails must describe the same observation as the reported total latency.
; Independent marginal percentiles can describe an execution that never occurred.
; ==============================================================================

#Requires AutoHotkey v2.0

_TLD_CrossedPhaseTails(DistinctMaximum := false) {
	Samples := [], Show := [], Border := []
	Loop 100 {
		Samples.Push(A_Index <= 94 ? 1 : 10)
		Show.Push(A_Index <= 94 ? 1 : A_Index <= 97 ? 10 : 0)
		Border.Push(A_Index <= 97 ? 0 : 10)
	}
	if DistinctMaximum {
		Samples[100] := 20
		Border[100] := 20
	}
	Detail := _TBP_LatencyDetail(Samples, Map("show", Show, "border", Border))
	AssertContains(Detail, "p95 sample=95, actual=10.000 ms, border=0.000, show=10.000",
		"the p95 phases must describe the same original observation")
	AssertContains(Detail, DistinctMaximum
		? "max sample=100, actual=20.000 ms, border=20.000, show=0.000"
		: "max sample=95, actual=10.000 ms, border=0.000, show=10.000",
		"maximum phases must retain their own exact observation")
}
Test("Tooltip latency diagnostics: crossed phase tails retain one observation (tooltip-latency-diagnostic)",
	_TLD_CrossedPhaseTails)
Test("Tooltip latency diagnostics: maximum retains a separate observation (tooltip-latency-diagnostic)",
	_TLD_CrossedPhaseTails.Bind(true))

_TLD_PreservesOriginalOrder() {
	Samples := [3, 1, 2]
	Segments := Map("work", [3, 1, 2])
	Detail := _TBP_LatencyDetail(Samples, Segments)
	AssertContains(Detail, "p95 sample=1, actual=3.000 ms, work=3.000")
	AssertEqual(3, Samples.Length)
	AssertEqual(3, Segments["work"].Length)
	for SampleIndex, Expected in [3, 1, 2] {
		AssertEqual(Expected, Samples[SampleIndex])
		AssertEqual(Expected, Segments["work"][SampleIndex])
	}
}
Test("Tooltip latency diagnostics: sorting preserves original sample ownership (tooltip-latency-diagnostic)",
	_TLD_PreservesOriginalOrder)

_TLD_RejectsInvalidSamples(Samples, Segments) {
	Failure := 0
	try _TBP_LatencyDetail(Samples, Segments)
	catch as Err
		Failure := Err
	AssertTrue(Failure is ValueError, "invalid telemetry must fail explicitly before formatting")
}
Test("Tooltip latency diagnostics: empty samples fail fast (tooltip-latency-diagnostic)",
	_TLD_RejectsInvalidSamples.Bind([], Map()))
Test("Tooltip latency diagnostics: mismatched phases fail fast (tooltip-latency-diagnostic)",
	_TLD_RejectsInvalidSamples.Bind([1], Map("work", [])))
Test("Tooltip latency diagnostics: negative totals fail fast (tooltip-latency-diagnostic)",
	_TLD_RejectsInvalidSamples.Bind([-1], Map()))
Test("Tooltip latency diagnostics: string phase times fail fast (tooltip-latency-diagnostic)",
	_TLD_RejectsInvalidSamples.Bind([1], Map("work", ["1"])))
