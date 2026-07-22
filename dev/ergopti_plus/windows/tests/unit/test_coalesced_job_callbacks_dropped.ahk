; tests/unit/test_coalesced_job_callbacks_dropped.ahk

; ==============================================================================
; MODULE: Coalesced Job Callback-Drop Regression Test
; DESCRIPTION:
; Behavioral regression test for the coalesced-job-callbacks-dropped finding.
;
; LLM_OllamaGenerate_Async coalesces rapid re-fires into a single pending slot
; (_LLM_Ollama_Pending) while a request is already in flight. Previously, when
; a second pending job overwrote a first one, the displaced job's callbacks
; were silently dropped -- violating the documented "exactly one of on_success /
; on_fail fires" async contract and stalling any future consumer that advances
; a state machine on the callback.
;
; The fix invokes the displaced job's on_fail() before overwriting the pending
; slot. This test drives the coalescing branch directly: it pre-loads a fake
; in-flight entry so .Count > 0 forces coalescing (no curl child is spawned),
; primes the pending slot, then fires a second async request to displace it and
; asserts the first job's on_fail spy ran exactly once.
;
; api_ollama.ahk is #Included by run_all.ahk, so this behavioral test calls the
; real LLM_OllamaGenerate_Async. The coalescing branch returns before any HTTP
; / curl dispatch, so the test has no OS side effects.
; ==============================================================================




; ===================================================
; ===================================================
; ======= 1/ Coalescing callback contract ===========
; ===================================================
; ===================================================

_CJCD_DisplacedJobGetsOnFail() {
	global _LLM_Ollama_Async, _LLM_Ollama_Pending
	; Save and isolate the global async state so the test is self-contained.
	saved_async := _LLM_Ollama_Async
	saved_pending := _LLM_Ollama_Pending
	; Force the coalescing branch: a non-empty registry makes
	; LLM_OllamaGenerate_Async park the job in _LLM_Ollama_Pending and return,
	; never dispatching curl.
	_LLM_Ollama_Async := Map(94001, Map("cancelled", false))
	_LLM_Ollama_Pending := ""

	fail_count := 0
	noop := (*) => 0
	first_fail := (*) => (fail_count += 1)

	; First call lands in the pending slot (registry already has 1 in-flight).
	LLM_OllamaGenerate_Async("m", "sys", "ctx", 0.1, noop, first_fail)
	AssertTrue(_LLM_Ollama_Pending is Map, "first coalesced job must be parked in the pending slot")
	AssertEqual(0, fail_count, "the parked job must not be failed before it is displaced")

	; Second call displaces the first -- its on_fail must fire exactly once.
	LLM_OllamaGenerate_Async("m", "sys", "ctx2", 0.1, noop, noop)
	AssertEqual(1, fail_count, "displaced coalesced job's on_fail must fire exactly once when superseded (coalesced-job-callbacks-dropped)")

	; Restore the global async state for downstream tests.
	_LLM_Ollama_Async := saved_async
	_LLM_Ollama_Pending := saved_pending
}
Test("api_ollama: displaced coalesced job's on_fail fires exactly once (coalesced-job-callbacks-dropped)", _CJCD_DisplacedJobGetsOnFail)
