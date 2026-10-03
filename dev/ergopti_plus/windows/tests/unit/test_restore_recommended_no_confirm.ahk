; tests/unit/test_restore_recommended_no_confirm.ahk

; Regression restore-recommended-no-confirm. The macOS and Linux « Restaurer les
; valeurs conseillées » rows asked a default-No question before they applied;
; the maintainer retired that step on every driver, and on 2026-09-30 the
; « Tout effacer » question too. Windows never asked, and this pins it. Each
; case is a scope suite's own case, which clicks the real tray row (or calls the
; function the row binds) and checks the values its owner published; this
; counts the dialogs the MsgBox stub absorbed meanwhile. The stub answers every
; question with "", which reads as No, so a question in front of a scope row
; would also have stopped it. AI and Metrics offer only restore; the other
; scopes also exercise clear where their menus still declare it.

; Runs one scope case and asserts it showed no dialog.
; @param {String} Name The row, for the failure message.
; @param {Func} RestoreCase A scope suite case that restores or clears its scope.
_RRNC_NoDialog(Name, RestoreCase) {
	Before := TestMsgBoxCount()
	RestoreCase.Call()
	AssertEqual(Before, TestMsgBoxCount(), Name . ": a scope row shows no dialog")
}

; The stub the count relies on must count, or every case above passes vacuously.
_RRNC_StubCounts() {
	Before := TestMsgBoxCount()
	MsgBox("restore-recommended-no-confirm probe", "probe", "YesNo")
	AssertEqual(Before + 1, TestMsgBoxCount(), "the MsgBox stub must count every dialog")
}
Test("restore-recommended-no-confirm: the MsgBox stub counts the dialogs it absorbs", _RRNC_StubCounts)

Test("restore-recommended-no-confirm: Gestures restores without a dialog",
	_RRNC_NoDialog.Bind("Gestures", _ScopeGestureMenuOwnsParameters))
Test("restore-recommended-no-confirm: Tap-Holds restores without a dialog",
	_RRNC_NoDialog.Bind("Tap-Holds", _TapHoldScopeCase.Bind("recommended")))
Test("restore-recommended-no-confirm: Shortcuts restores without a dialog",
	_RRNC_NoDialog.Bind("Shortcuts", _ScopeShortcutsCase.Bind("recommended")))
Test("restore-recommended-no-confirm: Hotstrings restores without a dialog",
	_RRNC_NoDialog.Bind("Hotstrings", _HotstringsScopeManifestRows))
Test("restore-recommended-no-confirm: Layout restores without a dialog",
	_RRNC_NoDialog.Bind("Layout", _ScopeMenuCommandsCase.Bind("keyboard_layout", "_LAY_ScopeCommands", "layout_menu")))
Test("restore-recommended-no-confirm: AI restores without a dialog",
	_RRNC_NoDialog.Bind("AI", _ScopeMenuCommandsCase.Bind("llm", "_LLM_ScopeCommands", "llm_menu", ["recommended"])))
Test("restore-recommended-no-confirm: Metrics restores without a dialog",
	_RRNC_NoDialog.Bind("Metrics", _ScopeMenuCommandsCase.Bind("metrics", "_MET_ScopeCommands", "metrics_menu", ["recommended"])))
Test("restore-recommended-no-confirm: Configuration restores every category without a dialog",
	_RRNC_NoDialog.Bind("Configuration", _GlobalScopeComposition.Bind("recommended")))
Test("restore-recommended-no-confirm: Tap-Holds clears without a dialog",
	_RRNC_NoDialog.Bind("Tap-Holds", _TapHoldScopeCase.Bind("clear")))
Test("restore-recommended-no-confirm: Shortcuts clears without a dialog",
	_RRNC_NoDialog.Bind("Shortcuts", _ScopeShortcutsCase.Bind("clear")))
Test("restore-recommended-no-confirm: Configuration clears every category without a dialog",
	_RRNC_NoDialog.Bind("Configuration", _GlobalScopeComposition.Bind("clear")))
