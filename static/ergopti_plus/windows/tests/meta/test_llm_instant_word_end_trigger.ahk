; tests/meta/test_llm_instant_word_end_trigger.ahk

; ==============================================================================
; MODULE: LLM instant_on_word_end Trigger Meta Test
; DESCRIPTION:
; Static source guard for finding llm-instant-word-end-trigger (F-M07).
;
; The instant_on_word_end option was configurable + persisted + reloaded into
; _LLM_Engine, but no keystroke path consumed it — flipping it changed nothing
; (the prediction still only fired after the full debounce). The fix detects a
; completed word (a word char followed by whitespace/punctuation) in
; LLM_Bridge_OnChar and, when the flag is on, fires via a zero-delay
; LLM_Engine_OnKeystroke override instead of the debounce — macOS parity with
; engine.start_timer_word_end.
;
; Meta-static because modules/llm is not in the headless runner's include graph;
; it scans the function bodies via the move-resilient _DriverFuncBody helper and
; asserts the word-end path is DISTINCT from the debounce path.
; ==============================================================================

#Requires AutoHotkey v2.0


_LIWE_AssertWordEndTrigger() {
	; The trigger predicate must gate on the persisted flag.
	Trig := _DriverFuncBody("_LLM_Bridge_IsWordEndTrigger")
	Assert(Trig != "", "_LLM_Bridge_IsWordEndTrigger must exist (instant_on_word_end trigger)")
	Assert(InStr(Trig, "instant_on_word_end") > 0,
		"_LLM_Bridge_IsWordEndTrigger must gate on the instant_on_word_end flag (llm-instant-word-end-trigger)")

	; OnChar must route a word-end trigger to a zero-delay fire, distinct from the debounce.
	OnChar := _DriverFuncBody("LLM_Bridge_OnChar")
	Assert(OnChar != "", "LLM_Bridge_OnChar must exist")
	Assert(InStr(OnChar, "_LLM_Bridge_IsWordEndTrigger") > 0,
		"LLM_Bridge_OnChar must consult _LLM_Bridge_IsWordEndTrigger to fire instantly on a completed word (llm-instant-word-end-trigger)")
	Assert(InStr(OnChar, "LLM_Engine_OnKeystroke(_LLM_Bridge_Buffer, 0)") > 0,
		"LLM_Bridge_OnChar must arm a zero-delay (instant) fire on a word-end trigger, distinct from the debounce path (llm-instant-word-end-trigger)")

	; OnKeystroke must honour the delay override so the two paths actually differ.
	OnKey := _DriverFuncBody("LLM_Engine_OnKeystroke")
	Assert(InStr(OnKey, "delay_override_ms") > 0,
		"LLM_Engine_OnKeystroke must accept a delay override so the word-end path fires sooner than the debounce (llm-instant-word-end-trigger)")
}
Test("LLM: instant_on_word_end fires the prediction on a completed word (llm-instant-word-end-trigger)", _LIWE_AssertWordEndTrigger)
