; SOURCE-ONLY regression cases for the existing Windows touchpad-registry test harness.
; NOT EXECUTED: requires AutoHotkey + original tests/unit/modules/gestures/test_touchpad_registry.ahk fixture.
; All I/O in these cases uses that fixture's in-memory seams, not the actual registry.

_WG_InvalidExistingBackupMustBlockApply() {
 global _TPR_Files
 _TPR_Reset(_TPR_UserSettings())
 _TPR_Files[_TPR_Path()] := "garbage"
 AssertFalse(_TPR_Apply(), "an unreadable/unrestorable prior backup must refuse new writes")
 AssertEqual(0, _TPR_Count("write "), "original user values must remain untouched")
}
; Current source returns true and writes all 34 values: the assertions above should fail.

; WG-003 manual native scenario, not automated here:
; 1. Run onboarding as standard Windows account A, with distinct account B as administrator.
; 2. Record PrecisionTouchPad values under HKU SID(A) and SID(B).
; 3. Configure gestures and enter B credentials at UAC.
; 4. Verify backup was A's while worker writes B's HKCU; A's gesture map remains unchanged.
; Negative control: consent-only elevation for admin A, or tray Apply before elevated restart.
