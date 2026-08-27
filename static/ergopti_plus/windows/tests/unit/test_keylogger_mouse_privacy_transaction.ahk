; tests/unit/test_keylogger_mouse_privacy_transaction.ahk

#Requires AutoHotkey v2.0


_KLMP_DownUpPrivacyMatrix() {
	Cases := [
		[true, 10, 4, 10, 4, false, false, true, "same authorized context"],
		[false, 10, 4, 10, 4, false, false, false, "private down"],
		[true, 10, 4, 10, 4, true, false, false, "private up"],
		[true, 10, 4, 11, 4, false, false, false, "different target HWND"],
		[true, 10, 4, 10, 5, false, false, false, "changed focus generation"],
		[true, 10, 4, 10, 4, false, true, false, "suspended release"]
	]
	for Row in Cases {
		Actual := _KL_Mouse_GestureAuthorized(
			Row[1], Row[2], Row[3], Row[4], Row[5], Row[6], Row[7])
		AssertEqual(Actual, Row[8], Row[9])
	}
}
Test("keylogger mouse: both gesture endpoints require one authorized context (mouse-cross-privacy-drag)",
	_KLMP_DownUpPrivacyMatrix)
