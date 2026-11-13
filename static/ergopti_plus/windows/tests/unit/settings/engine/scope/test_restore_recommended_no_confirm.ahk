; tests/unit/settings/engine/scope/test_restore_recommended_no_confirm.ahk

; Regression restore-recommended-no-confirm. The macOS and Linux « Restaurer les
; valeurs conseillées » rows asked a default-No question before they applied;
; the maintainer retired that step on every driver, and on 2026-09-30 the
; « Tout effacer » question too. Windows never asked, and this pins it. Each scope
; suite wraps its own case in _RRNC_NoDialog where it registers it: the case clicks
; the real tray row (or calls the function the row binds), checks the values its
; owner published, and also counts the dialogs the MsgBox stub absorbed meanwhile.
; Running those cases a second time here only for the count took minutes. The stub
; answers every question with "", which reads as No, so a question in front of a
; scope row would also have stopped it.

; Runs one scope case and asserts it showed no dialog.
; @param {String} Name The row, for the failure message.
; @param {Func} RestoreCase A scope suite case that restores or clears its scope.
_RRNC_NoDialog(Name, RestoreCase) {
	Before := TestMsgBoxCount()
	RestoreCase.Call()
	AssertEqual(Before, TestMsgBoxCount(), Name . ": a scope row shows no dialog")
}

; The stub the count relies on must count, or every wrapped case passes vacuously.
_RRNC_StubCounts() {
	Before := TestMsgBoxCount()
	MsgBox("restore-recommended-no-confirm probe", "probe", "YesNo")
	AssertEqual(Before + 1, TestMsgBoxCount(), "the MsgBox stub must count every dialog")
}
Test("restore-recommended-no-confirm: the MsgBox stub counts the dialogs it absorbs", _RRNC_StubCounts)
