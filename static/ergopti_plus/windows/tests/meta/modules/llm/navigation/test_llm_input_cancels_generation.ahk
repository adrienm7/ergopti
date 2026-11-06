; tests/meta/modules/llm/navigation/test_llm_input_cancels_generation.ahk

; ==============================================================================
; MODULE: LLM Input-Cancels-Generation Parity Test
; DESCRIPTION:
; Regression guard for the "génération en cours" spinner that lingered through
; user input. On macOS (the reference) ANY input cancels an in-progress
; generation: update_preview() calls engine.stop_timer() -> cancel_streaming() on
; EVERY keystroke, and the mouse_tap calls reset_predictions() on a click in any
; phase. Windows had diverged: LLM_Engine_OnKeystroke cancelled only the debounce
; timer (never the in-flight generation), so a superseded request kept the spinner
; alive and blocked Ollama's single queue, draining for many seconds after the
; user stopped typing; and the pointer dismiss gated on the shown-prediction
; predicate, so clicks / moves were ignored while the spinner was up.
;
; THE FIX (the contract this test pins):
;   1. LLM_Engine_OnKeystroke cancels in-flight generation every keystroke via
;      LLM_Engine_CancelInflight (mirrors macOS stop_timer -> cancel_streaming).
;   2. LLM_Engine_CancelInflight cancels streaming + async + remote in-flight work.
;   3. The pointer click handler (LLM_Bridge_OnPointerActivity) and the move-tick
;      gate on LLM_Bridge_HasActivePredictionWork() — the loading spinner and an
;      in-flight generation are cancellable, not only a shown prediction.
;   4. The retired _LLM_Bridge_PredictionShown predicate is gone (no dead code).
;
; Source-level (mirrors the sibling async-contract meta tests) because the bridge
; and engine reference dozens of cross-module functions that would all need
; stubbing to load standalone; the behavioural half lives in
; windows/tests/run_llm_pointer_dismiss.ahk.
; ==============================================================================

#Requires AutoHotkey v2.0





; ====================================
; ====================================
; ======= 1/ Cancel-on-input =========
; ====================================
; ====================================

_MetaCheckInputCancelsGeneration() {
	; (1) Every keystroke cancels in-flight generation before re-arming the debounce.
	KsBody := _DriverFuncBody("LLM_Engine_OnKeystroke")
	Assert(KsBody != "", "prediction_engine.ahk must define LLM_Engine_OnKeystroke()")
	Assert(InStr(KsBody, "LLM_Engine_CancelInflight("),
		"LLM_Engine_OnKeystroke must call LLM_Engine_CancelInflight() — every keystroke "
		. "cancels the in-flight generation (macOS update_preview -> stop_timer parity), "
		. "else a superseded request keeps the 'génération en cours' spinner alive")

	; (2) CancelInflight cancels every backend's in-flight work (streaming + async +
	; remote), mirroring macOS cancel_streaming.
	CiBody := _DriverFuncBody("LLM_Engine_CancelInflight")
	Assert(CiBody != "", "prediction_engine.ahk must define LLM_Engine_CancelInflight()")
	Assert(InStr(CiBody, "LLM_OllamaCancelStreams("),
		"LLM_Engine_CancelInflight must cancel Ollama streaming work")
	Assert(InStr(CiBody, "LLM_OllamaCancelAllAsync("),
		"LLM_Engine_CancelInflight must cancel Ollama async work")
	Assert(InStr(CiBody, "LLM_RemoteCancelAllAsync("),
		"LLM_Engine_CancelInflight must cancel remote (API) async work")

	; (3) Pointer click + move dismissal acts on ANY active prediction work — the
	; loading spinner and in-flight generation, not only a shown prediction.
	PaBody := _DriverFuncBody("LLM_Bridge_OnPointerActivity")
	Assert(PaBody != "", "llm_bridge.ahk must define LLM_Bridge_OnPointerActivity()")
	Assert(InStr(PaBody, "LLM_Bridge_HasActivePredictionWork("),
		"LLM_Bridge_OnPointerActivity must gate on HasActivePredictionWork (incl. loading), "
		. "so a click cancels the spinner — macOS mouse_tap dismisses in any phase")
	Assert(!InStr(PaBody, "_LLM_Bridge_PredictionShown"),
		"LLM_Bridge_OnPointerActivity must no longer gate on the retired _LLM_Bridge_PredictionShown")

	MtBody := _DriverFuncBody("_LLM_PointerWatch_OnMoveTick")
	Assert(MtBody != "", "llm_bridge.ahk must define _LLM_PointerWatch_OnMoveTick()")
	Assert(InStr(MtBody, "LLM_Bridge_HasActivePredictionWork("),
		"the move-tick must gate on HasActivePredictionWork so a deliberate move cancels "
		. "during loading too (not only over a shown prediction)")

	; (4) No grace shield against activity (maintainer decision 2026-11-06:
	; predictions run only while the user does nothing): pointer activity routes
	; through the shared activity cancel, which hides even a fresh prediction.
	Assert(!InStr(PaBody, "LLM_Tooltip_InGracePeriod("),
		"LLM_Bridge_OnPointerActivity must not shield a prediction in its grace window")
	Assert(InStr(PaBody, "LLM_Bridge_OnUserActivity("),
		"LLM_Bridge_OnPointerActivity must route through LLM_Bridge_OnUserActivity")
	UaBody := _DriverFuncBody("LLM_Bridge_OnUserActivity")
	Assert(UaBody != "" && InStr(UaBody, "LLM_Bridge_HasActivePredictionWork(")
		&& InStr(UaBody, "LLM_Engine_StopGeneration(") && !InStr(UaBody, "InGracePeriod"),
		"LLM_Bridge_OnUserActivity must cancel any active work without a grace shield")
	Assert(!InStr(UaBody, "_LLM_Bridge_ClearBuffer("),
		"activity is not navigation: the AI context survives a pointer move or a key")
	KdBody := _DriverFuncBody("_OnPrefixKeyDown")
	Assert(KdBody != "" && InStr(KdBody, "LLM_Bridge_OnKeyActivity(VK)"),
		"the physical key-down owner must report every key to LLM_Bridge_OnKeyActivity")
	FgBody := _DriverFuncBody("_AltGrFamilyOnForeground")
	Assert(FgBody != "" && InStr(FgBody, "LLM_Bridge_OnUserActivity("),
		"the foreground-change owner must cancel a pending prediction")

	; (5) The retired predicate must be fully removed (no dead code, §5.6).
	Assert(_DriverFuncBodyOrEmpty("_LLM_Bridge_PredictionShown") == "",
		"_LLM_Bridge_PredictionShown must be removed — both gates now use HasActivePredictionWork")
}

Test("meta llm: any input cancels in-progress generation (llm-spinner-lingers-through-input)",
	_MetaCheckInputCancelsGeneration)
