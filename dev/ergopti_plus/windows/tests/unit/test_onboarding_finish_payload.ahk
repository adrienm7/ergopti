; tests/unit/test_onboarding_finish_payload.ahk

; ==============================================================================
; MODULE: Onboarding WebView Finish Payload Tests
; DESCRIPTION:
; The WebView bridge must reject a malformed ``answers`` value before it can
; enter the onboarding persistence/reload transaction. A scalar used to throw
; from ``answers.Has(...)``; an Array could instead reach the transaction with
; every choice silently defaulted.
; ==============================================================================

_TOFP_FinishRejectsNonMapAnswers() {
	for _, Answers in ["malformed", []] {
		Thrown := false
		Result := true
		try Result := _OnbWeb_Finish(Answers)
		catch
			Thrown := true
		AssertFalse(Thrown,
			"a non-Map finish payload must not throw from the deferred WebView callback")
		AssertFalse(Result,
			"a non-Map finish payload must be rejected before persistence")
	}
}
Test("onboarding WebView: finish rejects non-Map answers (AHK-147)",
	_TOFP_FinishRejectsNonMapAnswers)
