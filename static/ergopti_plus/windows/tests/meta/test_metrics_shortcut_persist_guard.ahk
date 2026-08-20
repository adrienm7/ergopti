; static/ergopti_plus/windows/tests/meta/test_metrics_shortcut_persist_guard.ahk

; ==============================================================================
; MODULE: MS_PromptShortcut Persist-Guard Meta Test
; DESCRIPTION:
; Static source guard for finding F38 (metrics-shortcut-bad-string-replayed-
; forever). Both slots now share one transaction owner: it rejects an invalid
; candidate, owns Hotkey rollback, commits once, then publishes the selected
; string. The prompt must not reintroduce a sibling ad-hoc branch.
; ==============================================================================

#Requires AutoHotkey v2.0




; ===================================================
; ===================================================
; ======= 1/ Persist-guard wiring assertion =========
; ===================================================
; ===================================================

_MSPG_PromptShortcutUsesGuard() {
	Body := _DriverFuncBody("MS_PromptShortcut")
	Assert(Body != "", "MS_PromptShortcut(which, ToggleFn) declaration must exist in metrics_shortcuts.ahk")
	Assert(InStr(Body, "return MS_CommitShortcutCandidate(which, raw, ToggleFn)") > 0,
		"MS_PromptShortcut must delegate typing and apps to the same tested transaction owner")
	Assert(InStr(Body, "MetricsShortcuts.typing_str :=") = 0
		and InStr(Body, "MetricsShortcuts.apps_str :=") = 0,
		"the prompt must not publish either shortcut outside the transaction owner")

	PublicTxn := _DriverFuncBody("MS_CommitShortcutCandidate")
	Assert(InStr(PublicTxn, "CS_SaveBuilt(") > 0
		and InStr(PublicTxn, "_MS_BuildShortcutPlan.Bind(") > 0,
		"the public owner must acquire config.toml before snapshotting either slot")
	Txn := _DriverFuncBody("_MS_BuildShortcutPlan")
	Assert(Txn != "", "the owned shortcut plan builder must exist")
	GuardPos := InStr(Txn, "if !MS_ShouldPersistShortcut(")
	ReservePos := InStr(Txn, "_HotkeyRegistrarReserveOwned(")
	UpdatesPos := InStr(Txn, "updates:")
	Assert(GuardPos > 0 and ReservePos > GuardPos and UpdatesPos > ReservePos,
		"an invalid candidate must stop before reserve-Off and durable persistence")
	Assert(InStr(Txn, "publish: _MS_PublishShortcutCandidate.Bind(") > 0
		and InStr(Txn, "rollback_updates:") > 0,
		"shortcut strings must publish through a plan carrying their reverse batch")
	Assert(InStr(Txn, "noop: true") = 0,
		"invalid syntax and owner collisions must not masquerade as successful no-ops")
	Assert(InStr(Txn, "_MS_TrySetHotkey(") = 0,
		"the metrics transaction must not bypass callback fencing with raw Hotkey calls")
	Assert(InStr(Txn, "LoggerWarn") > 0,
		"a rejected shortcut must remain visible in the log")
}
Test("metrics_shortcuts: prompt delegates both slots to the guarded transaction owner (F38)", _MSPG_PromptShortcutUsesGuard)
