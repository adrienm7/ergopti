; tests/unit/test_healthcheck_copy_receipt.ahk

; ==============================================================================
; MODULE: Healthcheck Copy Receipt Tests
; DESCRIPTION:
; Verifies that the native Copy-and-Close button does not discard the report
; window when Windows refuses the clipboard write. A successful write must
; still close exactly once and carry the exact rendered report.
; ==============================================================================

#Requires AutoHotkey v2.0





; =========================================
; =========================================
; ======= 1/ Copy Receipt Ownership =======
; =========================================
; =========================================

TestHealthcheck_CopyRefusalKeepsWindowOpen() {
	Closed := 0
	WriteFn := (*) => false
	CloseFn := (*) => (Closed += 1)
	AssertFalse(_HealthCheck_CopyAndClose("diagnostic report", 0, WriteFn, CloseFn))
	AssertEqual(0, Closed,
		"a refused clipboard write must keep the diagnostic window available")
}
Test("healthcheck: copy refusal keeps report open (healthcheck-copy-receipt)",
	TestHealthcheck_CopyRefusalKeepsWindowOpen)

TestHealthcheck_CopySuccessClosesOnce() {
	Copied := ""
	Closed := 0
	WriteFn := (Text) => (Copied := Text, true)
	CloseFn := (*) => (Closed += 1)
	AssertTrue(_HealthCheck_CopyAndClose("diagnostic report", 0, WriteFn, CloseFn))
	AssertEqual("diagnostic report", Copied)
	AssertEqual(1, Closed)
}
Test("healthcheck: successful copy closes once (healthcheck-copy-receipt)",
	TestHealthcheck_CopySuccessClosesOnce)
